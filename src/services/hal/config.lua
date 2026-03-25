-- services/hal/config.lua
--
-- Config helpers for HAL-owned configuration.

local M = {}

local function is_plain_table(x)
	return type(x) == 'table' and getmetatable(x) == nil
end

local function deepcopy(x, seen)
	if type(x) ~= 'table' then
		return x
	end
	if getmetatable(x) ~= nil then
		error('hal config deepcopy: metatables are not supported', 2)
	end

	seen = seen or {}
	if seen[x] then
		return seen[x]
	end

	local out = {}
	seen[x] = out

	for k, v in pairs(x) do
		out[deepcopy(k, seen)] = deepcopy(v, seen)
	end
	return out
end

---@param payload any
---@return table|nil cfg
---@return string|nil err
function M.normalise(payload)
	if not is_plain_table(payload) then
		return nil, 'config/hal payload must be a plain table'
	end

	local serial_in = payload.serial
	if serial_in ~= nil and not is_plain_table(serial_in) then
		return nil, 'config/hal.serial must be a table if present'
	end

	local out = {
		serial = {},
	}

	for ref, rec in pairs(serial_in or {}) do
		if type(ref) ~= 'string' or ref == '' then
			return nil, 'config/hal.serial keys must be non-empty strings'
		end
		if not is_plain_table(rec) then
			return nil, ('config/hal.serial.%s must be a table'):format(ref)
		end

		local device = rec.device
		if type(device) ~= 'string' or device == '' then
			return nil, ('config/hal.serial.%s.device must be a non-empty string'):format(ref)
		end

		local baud = rec.baud
		if baud ~= nil then
			if type(baud) ~= 'number' or baud <= 0 or baud % 1 ~= 0 then
				return nil, ('config/hal.serial.%s.baud must be a positive integer'):format(ref)
			end
			baud = math.floor(baud)
		end

		local mode = rec.mode
		if mode ~= nil then
			if type(mode) ~= 'string' or mode == '' then
				return nil, ('config/hal.serial.%s.mode must be a non-empty string if present'):format(ref)
			end
		end

		out.serial[ref] = {
			device = device,
			baud   = baud,
			mode   = mode,
		}
	end

	return deepcopy(out), nil
end

---@param cfg table|nil
---@param ref string
---@return table|nil rec
---@return string|nil err
function M.get_serial(cfg, ref)
	if type(ref) ~= 'string' or ref == '' then
		return nil, 'serial ref must be a non-empty string'
	end
	if type(cfg) ~= 'table' or type(cfg.serial) ~= 'table' then
		return nil, 'hal config not loaded'
	end

	local rec = cfg.serial[ref]
	if type(rec) ~= 'table' then
		return nil, 'unknown serial ref: ' .. tostring(ref)
	end

	return {
		device = rec.device,
		baud   = rec.baud,
		mode   = rec.mode,
	}, nil
end

return M
