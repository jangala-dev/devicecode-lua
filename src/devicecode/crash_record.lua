-- devicecode/crash_record.lua
--
-- Carries the reason for a devicecode exit across the restart, so the next
-- process can send it to the cloud. Logs are in RAM and the reason would
-- otherwise be lost at the next reboot.
--
-- The record lives in tmpfs, which survives a process restart but not a reboot.
-- Every operation reads and rewrites the file, because main and the metrics
-- service each hold their own store. Nothing here may stop devicecode running,
-- so all failures are swallowed.
--
-- A record is one of:
--   service_failed  a service failed, returned or was cancelled unexpectedly
--   boot_failed     a service could not be loaded or started
--   main_error      an error reached the top without an earlier record
--   signal          a deliberate stop (no log is kept)
--   unknown_exit    the previous process ended without writing anything, so it
--                   was killed; the system log is kept as the only evidence

local cjson  = require 'cjson.safe'
local exec   = require 'fibers.io.exec'
local fibers = require 'fibers'
local op     = require 'fibers.op'
local sleep  = require 'fibers.sleep'
local time   = require 'fibers.utils.time'

local M = {}

M.DEFAULT_PATH     = '/tmp/devicecode-crash.json'
M.MAX_REASON       = 200
M.MAX_LOG          = 2048
M.MAX_LINE         = 200
M.RING_LINES       = 20
M.FULL_LOG_CRASHES = 3   -- crashes per boot that keep a log, for metered SIMs
M.MAX_PENDING      = 5
M.SEND_INTERVAL_S  = 600 -- between sends once past the first crashes, and between retries
M.LOGREAD_TIMEOUT_S = 5

local SENSITIVE_KEY_PARTS = {
	apikey = true, auth = true, authorization = true, credential = true, credentials = true,
	hostname = true, iccid = true, imei = true, key = true, mac = true, pass = true,
	passwd = true, password = true, psk = true, salt = true, secret = true, token = true,
	user = true, username = true,
}

local LOG_LEVELS = { info = true, warn = true, error = true, fatal = true }

-- Already shown, or not useful in one line of a log.
local SKIP_FIELDS = {
	at = true, level = true, message = true, service = true, summary = true,
	t = true, ts = true, what = true,
}

local function is_sensitive_key(key)
	for part in tostring(key):lower():gmatch('[^_%-%.]+') do
		if SENSITIVE_KEY_PARTS[part] then return true end
	end
	return false
end

--- Where a value starting at `first` ends: at its closing quote if it has one,
--- honouring backslash escapes, otherwise at the next separator.
local function value_end(text, first, quote)
	if quote == '' then
		local _, last = text:find('^[^%s,"\'}%]]*', first)
		return last
	end
	local i = first
	while i <= #text do
		local c = text:sub(i, i)
		if c == '\\' then
			i = i + 2
		elseif c == quote then
			break
		else
			i = i + 1
		end
	end
	return i - 1
end

--- Mask the value of any key=value or "key":"value" with a sensitive key. Other
--- values are scanned too, since one can hold another pair.
local function redact_pairs(text)
	local out, pos = {}, 1
	while true do
		local s, e, key, quote = text:find('([%w_%-%.]+)["\']?%s*[=:]%s*(["\']?)', pos)
		if not s then break end
		out[#out + 1] = text:sub(pos, e)
		pos = e + 1
		if is_sensitive_key(key) then
			out[#out + 1] = '[redacted]'
			pos = value_end(text, pos, quote) + 1
		end
	end
	out[#out + 1] = text:sub(pos)
	return table.concat(out)
end

--- Remove secrets and identifiers from free text.
---@param text string
---@return string
function M.redact(text)
	text = tostring(text)
	text = text:gsub('://[^/%s@]+@', '://[redacted]@')
	text = text:gsub('([Tt]hing%s+)%S+', '%1[redacted]')
	text = text:gsub('([Bb]earer%s+)%S+', '%1[redacted]')
	text = redact_pairs(text)
	text = text:gsub('%x%x[:%-]%x%x[:%-]%x%x[:%-]%x%x[:%-]%x%x[:%-]%x%x', '[mac]')
	text = text:gsub('%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x', '[uuid]')
	text = text:gsub('%d+', function(digits)
		if #digits >= 14 then return '[id]' end
		return digits
	end)
	return text
end

local function format_log_line(mono, service, level, payload)
	local parts = { string.format('%.0f %s %s', mono, tostring(service), tostring(level)) }
	if type(payload) ~= 'table' then
		parts[#parts + 1] = tostring(payload)
	else
		if payload.what ~= nil then parts[#parts + 1] = tostring(payload.what) end
		local text = payload.summary or payload.message
		if text ~= nil then parts[#parts + 1] = tostring(text) end

		local keys = {}
		for k, v in pairs(payload) do
			local tv = type(v)
			if type(k) == 'string' and not SKIP_FIELDS[k]
				and (tv == 'string' or tv == 'number' or tv == 'boolean') then
				keys[#keys + 1] = k
			end
		end
		table.sort(keys)
		for _, k in ipairs(keys) do
			local value = is_sensitive_key(k) and '[redacted]' or tostring(payload[k])
			parts[#parts + 1] = k .. '=' .. value
		end
	end
	return M.redact(table.concat(parts, ' ')):sub(1, M.MAX_LINE)
end

--- The newest text that fits, cut at a line boundary where possible.
local function keep_tail(text, max)
	if #text <= max then return text end
	local tail = text:sub(-max)
	local newline = tail:find('\n', 1, true)
	return newline and tail:sub(newline + 1) or tail
end

local function read_boot_id()
	local f = io.open('/proc/sys/kernel/random/boot_id', 'r')
	if not f then return 'unknown' end
	local id = f:read('*l')
	f:close()
	return id or 'unknown'
end

--- Must run in a fiber.
local function read_system_log()
	local cmd = exec.command { 'logread', '-l', '40', stdin = 'null', stdout = 'pipe', stderr = 'null' }
	local which, output = fibers.perform(op.named_choice({
		done    = cmd:output_op(),
		timeout = sleep.sleep_op(M.LOGREAD_TIMEOUT_S),
	}))
	if which == 'done' and type(output) == 'string' then return output end
	return ''
end

local Store = {}
Store.__index = Store

---@param opts? { path: string?, boot_id: string?, monotonic: function?, read_system_log: function? }
function M.new(opts)
	opts = opts or {}
	return setmetatable({
		path            = opts.path or os.getenv('DEVICECODE_CRASH_FILE') or M.DEFAULT_PATH,
		boot_id         = opts.boot_id or read_boot_id(),
		monotonic       = opts.monotonic or time.monotonic,
		read_system_log = opts.read_system_log or read_system_log,
		ring            = {},
	}, Store)
end

function Store:load()
	local state
	local f = io.open(self.path, 'r')
	if f then
		state = cjson.decode(f:read('*a') or '')
		f:close()
	end
	if type(state) ~= 'table' or state.boot_id ~= self.boot_id or type(state.pending) ~= 'table' then
		return { boot_id = self.boot_id, seq = 0, crashes = 0, pending = {}, next_send = 0 }
	end
	return state
end

function Store:save(state)
	local tmp = self.path .. '.tmp'
	local f = io.open(tmp, 'w')
	if not f then return end
	local ok = f:write(cjson.encode(state))
	f:close()
	if ok then os.rename(tmp, self.path) else os.remove(tmp) end
end

--- Add a record for this run. The first record of a run wins.
function Store:add(state, fields, log_text)
	state.seq = state.seq + 1
	local rec = {
		seq     = state.seq,
		kind    = fields.kind,
		service = fields.service,
		status  = fields.status,
		mono    = self.monotonic(),
		reason  = M.redact(fields.reason or ''):sub(1, M.MAX_REASON),
	}
	if log_text then
		state.crashes = state.crashes + 1
		if state.crashes <= M.FULL_LOG_CRASHES and log_text ~= '' then
			rec.log = keep_tail(M.redact(log_text), M.MAX_LOG)
		end
	end
	state.pending[#state.pending + 1] = rec
	-- Keep the first crashes, which have logs, and the newest. seq still shows the count.
	while #state.pending > M.MAX_PENDING do
		table.remove(state.pending, M.FULL_LOG_CRASHES + 1)
	end
	state.recorded = true
end

local function guarded(fn)
	return function(...)
		local ok, a = pcall(fn, ...)
		if ok then return a end
		return nil
	end
end

--- Call once at process start, in a fiber. Reports a previous process that ended
--- without a record.
Store.begin_run = guarded(function(self)
	local state = self:load()
	if state.running and not state.recorded then
		self:add(state, {
			kind   = 'unknown_exit',
			reason = 'previous process ended without a record',
		}, self.read_system_log())
	end
	state.running  = true
	state.recorded = false
	self:save(state)
end)

--- Keep a recent log line, ready for a crash record.
Store.note_log = guarded(function(self, service, level, payload)
	if not LOG_LEVELS[level] then return end
	local ring = self.ring
	ring[#ring + 1] = format_log_line(self.monotonic(), service, level, payload)
	if #ring > M.RING_LINES then table.remove(ring, 1) end
end)

local function record_once(self, fields, log_text)
	local state = self:load()
	if state.recorded then return end
	self:add(state, fields, log_text)
	self:save(state)
end

---@param fields { service: string, status: string, primary: any }
Store.record_failure = guarded(function(self, fields)
	record_once(self, {
		kind    = 'service_failed',
		service = fields.service,
		status  = fields.status,
		reason  = tostring(fields.primary),
	}, table.concat(self.ring, '\n'))
end)

---@param fields { service: string?, what: string, err: any }
Store.record_boot_failure = guarded(function(self, fields)
	record_once(self, {
		kind    = 'boot_failed',
		service = fields.service,
		status  = fields.what,
		reason  = tostring(fields.err),
	}, table.concat(self.ring, '\n'))
end)

Store.record_error = guarded(function(self, err)
	record_once(self, { kind = 'main_error', reason = tostring(err) }, table.concat(self.ring, '\n'))
end)

Store.record_signal = guarded(function(self, reason)
	record_once(self, { kind = 'signal', reason = tostring(reason) }, nil)
end)

--- The next record to send, unless sending must wait.
---@param now number monotonic seconds
---@return table? record
Store.next_pending = guarded(function(self, now)
	local state = self:load()
	if now < (state.next_send or 0) then return nil end
	return state.pending[1]
end)

--- The cloud accepted this record.
Store.mark_sent = guarded(function(self, seq, now)
	local state = self:load()
	for i, rec in ipairs(state.pending) do
		if rec.seq == seq then
			table.remove(state.pending, i)
			break
		end
	end
	state.next_send = (seq > M.FULL_LOG_CRASHES) and (now + M.SEND_INTERVAL_S) or 0
	self:save(state)
end)

--- The cloud refused the record: keep it and try again later.
Store.mark_failed = guarded(function(self, now)
	local state = self:load()
	state.next_send = now + M.SEND_INTERVAL_S
	self:save(state)
end)

return M
