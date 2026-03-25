-- services/hal/backends/openwrt/serial.lua
--
-- Serial stream capability for the OpenWrt HAL backend.
--
-- First pass:
--   * resolve logical serial ref via HAL-owned config
--   * reject double-open for the same ref
--   * best-effort configure with stty
--   * open the device path as a duplex Stream
--   * clear registry entry when the stream is closed

local file   = require 'fibers.io.file'
local op     = require 'fibers.op'

local common = require 'services.hal.backends.openwrt.common'
local hcfg   = require 'services.hal.config'

local M = {}

local function parse_mode(mode)
	mode = mode or '8N1'
	local db, par, sb = tostring(mode):match('^(%d)([NEO])(%d)$')
	if not db then
		return nil, 'unsupported serial mode: ' .. tostring(mode)
	end

	db = tonumber(db)
	sb = tonumber(sb)

	local parity
	if par == 'N' then
		parity = 'none'
	elseif par == 'E' then
		parity = 'even'
	elseif par == 'O' then
		parity = 'odd'
	else
		return nil, 'unsupported parity in mode: ' .. tostring(mode)
	end

	return {
		data_bits = db,
		stop_bits = sb,
		parity    = parity,
	}, nil
end

local function stty_args(device, baud, mode)
	local out = { '-F', device, 'raw', '-echo' }

	if baud then
		out[#out + 1] = tostring(baud)
	end

	local pmode, err = parse_mode(mode or '8N1')
	if not pmode then
		return nil, err
	end

	out[#out + 1] = 'cs' .. tostring(pmode.data_bits)

	if pmode.stop_bits == 2 then
		out[#out + 1] = 'cstopb'
	else
		out[#out + 1] = '-cstopb'
	end

	if pmode.parity == 'none' then
		out[#out + 1] = '-parenb'
		out[#out + 1] = '-parodd'
	elseif pmode.parity == 'even' then
		out[#out + 1] = 'parenb'
		out[#out + 1] = '-parodd'
	elseif pmode.parity == 'odd' then
		out[#out + 1] = 'parenb'
		out[#out + 1] = 'parodd'
	end

	return out, nil
end

local function emit_serial_state(self, ref, status, fields)
	local host = self._host
	if not host or type(host.retain) ~= 'function' then
		return
	end

	local payload = {
		ref    = ref,
		status = status,
		at     = host.wall and host.wall() or nil,
		ts     = host.now and host.now() or nil,
	}

	for k, v in pairs(fields or {}) do
		payload[k] = v
	end

	host.retain({ 'state', 'hal', 'serial', ref }, payload)
end

local function unregister_serial_stream(self, ref, stream)
	local reg = self._serial_streams
	local rec = reg and reg[ref]
	if rec and rec.stream == stream then
		reg[ref] = nil
		emit_serial_state(self, ref, 'closed')
		if self._host and type(self._host.event) == 'function' then
			self._host.event('serial_stream_closed', { ref = ref })
		end
	end
end

local function wrap_stream_close(self, ref, stream)
	-- Prevent double wrapping.
	if stream._devicecode_serial_wrapped then
		return stream
	end
	stream._devicecode_serial_wrapped = true

	local old_close_op = stream.close_op
	if type(old_close_op) ~= 'function' then
		error('serial stream capability missing close_op()', 2)
	end

	stream.close_op = function(s)
		return op.guard(function()
			return old_close_op(s):wrap(function(ok, err)
				if ok ~= nil then
					unregister_serial_stream(self, ref, s)
				end
				return ok, err
			end)
		end)
	end

	return stream
end

function M.open_serial_stream(self, req, _msg)
	local ref = req and req.ref
	if type(ref) ~= 'string' or ref == '' then
		return { ok = false, err = 'ref must be a non-empty string' }
	end

	local reg = self._serial_streams
	if type(reg) ~= 'table' then
		self._serial_streams = {}
		reg = self._serial_streams
	end

	if reg[ref] ~= nil then
		return { ok = false, err = 'serial ref already open: ' .. tostring(ref) }
	end

	local get_cfg = self._host and self._host.get_hal_config
	if type(get_cfg) ~= 'function' then
		return { ok = false, err = 'HAL config getter is unavailable' }
	end

	local cfg = get_cfg()
	local rec, err = hcfg.get_serial(cfg, ref)
	if not rec then
		return { ok = false, err = tostring(err) }
	end

	local args, aerr = stty_args(rec.device, rec.baud, rec.mode)
	if not args then
		return { ok = false, err = tostring(aerr) }
	end

	-- Best-effort device configuration.
	do
		local cmd = { 'stty' }
		for i = 1, #args do cmd[#cmd + 1] = args[i] end
		local ok_cfg, cfg_err = common.cmd_ok(table.unpack(cmd))
		if not ok_cfg then
			return { ok = false, err = 'stty failed: ' .. tostring(cfg_err) }
		end
	end

	local s, oerr = file.open(rec.device, 'r+')
	if not s then
		return { ok = false, err = 'open failed: ' .. tostring(oerr) }
	end

	pcall(function()
		if s.setvbuf then s:setvbuf('no') end
	end)

	s = wrap_stream_close(self, ref, s)

	reg[ref] = {
		stream    = s,
		opened_at = self._host and self._host.now and self._host.now() or nil,
	}

	emit_serial_state(self, ref, 'open', {
		baud = rec.baud,
		mode = rec.mode,
	})

	if self._host and type(self._host.event) == 'function' then
		self._host.event('serial_stream_opened', {
			ref  = ref,
			baud = rec.baud,
			mode = rec.mode,
		})
	end

	return {
		ok     = true,
		stream = s,
		info   = {
			ref  = ref,
			baud = rec.baud,
			mode = rec.mode,
		},
	}
end

function M.close_open_serial_streams(self)
	local reg = self._serial_streams or {}
	for ref, rec in pairs(reg) do
		local s = rec and rec.stream
		if s and s.close_op then
			pcall(function()
				require('fibers').perform(s:close_op())
			end)
		end
		reg[ref] = nil
	end
end

return M
