-- tests/support/stack_diag.lua
--
-- Small diagnostics helper for stack/integration tests.

local cjson  = require 'cjson.safe'
local fibers = require 'fibers'

local safe = require 'coxpcall'

local M = {}

local function encode_one(v)
	local ok, s = safe.pcall(cjson.encode, v)
	if ok and s then
		return s
	end
	return tostring(v)
end

local function topic_str(topic)
	if type(topic) ~= 'table' then
		return tostring(topic)
	end
	local parts = {}
	for i = 1, #topic do
		parts[i] = tostring(topic[i])
	end
	return table.concat(parts, '/')
end

local function push_limited(t, v, maxn)
	t[#t + 1] = v
	if #t > maxn then
		table.remove(t, 1)
	end
end

---@param scope Scope
---@param bus Bus
---@param specs table[]   -- { { label = "obs", topic = {"obs", "#"} }, ... }
---@param opts? { max_records?: integer }
---@return table recorder
function M.start(scope, bus, specs, opts)
	opts = opts or {}
	local max_records = opts.max_records or 200

	local rec = {
		records = {},
		errors  = {},
	}

	local conn = bus:connect()

	local function append_record(r)
		push_limited(rec.records, r, max_records)
	end

	local function append_error(s)
		push_limited(rec.errors, s, max_records)
	end

	for i = 1, #specs do
		local spec = specs[i]
		local label = spec.label or ('sub' .. tostring(i))
		local topic = assert(spec.topic, 'stack_diag: missing spec.topic')

		local ok_spawn, err = scope:spawn(function()
			local sub = conn:subscribe(topic, {
				queue_len = 128,
				full      = 'drop_oldest',
			})

			append_record({
				t     = fibers.now(),
				label = label,
				kind  = 'subscribed',
				topic = topic,
			})

			while true do
				local msg, rerr = sub:recv()
				if not msg then
					append_error(('[%s] subscription ended: %s'):format(label, tostring(rerr)))
					return
				end

				append_record({
					t       = fibers.now(),
					label   = label,
					kind    = 'msg',
					topic   = msg.topic,
					payload = msg.payload,
					id      = msg.id,
				})
			end
		end)

		if not ok_spawn then
			append_error(('[%s] failed to spawn recorder: %s'):format(label, tostring(err)))
		end
	end

	return rec
end

---@param rec table
---@param opts? { max_records?: integer }
---@return string
function M.render(rec, opts)
	opts = opts or {}
	local max_records = opts.max_records or 120

	local out = {}

	local records = rec.records or {}
	local start_idx = math.max(1, #records - max_records + 1)

	out[#out + 1] = ('records=%d errors=%d'):format(#records, #(rec.errors or {}))

	if rec.errors and #rec.errors > 0 then
		out[#out + 1] = '-- recorder errors --'
		for i = 1, #rec.errors do
			out[#out + 1] = tostring(rec.errors[i])
		end
	end

	out[#out + 1] = '-- bus trace --'
	for i = start_idx, #records do
		local r = records[i]
		if r.kind == 'subscribed' then
			out[#out + 1] = ('[%0.6f] %-10s subscribed %s'):format(
				tonumber(r.t) or 0,
				tostring(r.label),
				topic_str(r.topic)
			)
		else
			out[#out + 1] = ('[%0.6f] %-10s %s -> %s'):format(
				tonumber(r.t) or 0,
				tostring(r.label),
				topic_str(r.topic),
				encode_one(r.payload)
			)
		end
	end

	return table.concat(out, '\n')
end

---@param fake_hal any
---@param opts? { max_calls?: integer }
---@return string
function M.render_fake_hal(fake_hal, opts)
	opts = opts or {}
	local max_calls = opts.max_calls or 80

	local calls = (fake_hal and fake_hal.calls) or {}
	local start_idx = math.max(1, #calls - max_calls + 1)

	local out = {}
	out[#out + 1] = ('fake_hal.calls=%d'):format(#calls)
	out[#out + 1] = '-- fake HAL calls --'

	for i = start_idx, #calls do
		local c = calls[i]
		out[#out + 1] = ('[%d] %s req=%s'):format(
			i,
			tostring(c.method),
			encode_one(c.req)
		)
	end

	return table.concat(out, '\n')
end

---@param message string
---@param rec table
---@param fake_hal any
---@return string
function M.explain(message, rec, fake_hal)
	local parts = {
		tostring(message),
		'',
		M.render(rec),
		'',
		M.render_fake_hal(fake_hal),
	}
	return table.concat(parts, '\n')
end

---@param rec table
---@param opts? { max_records?: integer }
---@return string
function M.render_records(rec, opts)
	return M.render(rec, opts)
end

return M
