-- devicecode/config_bootstrap.lua
--
-- Optional startup bootstrap for legacy checked-in config files under
-- src/configs/. This only seeds the pieces needed by the current runtime:
--   * config/hal    (serial refs for HAL-backed UART access)
--   * config/fabric (minimal UART fabric link, when fabric is enabled)

local cjson = require 'cjson.safe'

local M = {}

local function copy_plain(v, seen)
	if type(v) ~= 'table' then
		return v
	end
	if getmetatable(v) ~= nil then
		error('config bootstrap only supports plain tables', 2)
	end
	seen = seen or {}
	if seen[v] then
		return seen[v]
	end
	local out = {}
	seen[v] = out
	for k, val in pairs(v) do
		out[copy_plain(k, seen)] = copy_plain(val, seen)
	end
	return out
end

local function read_file(path)
	local f = io.open(path, 'rb')
	if not f then return nil end
	local s = f:read('*a')
	f:close()
	return s
end

local function strip_comment_lines(s)
	local out = {}
	for line in tostring(s):gmatch('([^\n]*)\n?') do
		if line == '' and #out > 0 and out[#out] == '' then
			break
		end
		if not line:match('^%s*//') then
			out[#out + 1] = line
		end
	end
	return table.concat(out, '\n')
end

local function resolve_path(name)
	if type(name) ~= 'string' or name == '' then
		return nil, 'config name must be a non-empty string'
	end

	local candidates = {}
	if name:find('/', 1, true) or name:sub(-5) == '.json' then
		candidates = {
			name,
			'./' .. name,
		}
	else
		candidates = {
			('./configs/%s.json'):format(name),
			('./src/configs/%s.json'):format(name),
		}
	end

	for i = 1, #candidates do
		local path = candidates[i]
		local data = read_file(path)
		if data ~= nil then
			return path, data
		end
	end

	return nil, ('config file not found for %s'):format(name)
end

local function load_selected(name)
	local path, data_or_err = resolve_path(name)
	if not path then
		return nil, nil, data_or_err
	end

	local decoded, err = cjson.decode(data_or_err)
	if type(decoded) ~= 'table' then
		decoded, err = cjson.decode(strip_comment_lines(data_or_err))
	end
	if type(decoded) ~= 'table' then
		return nil, nil, ('invalid JSON in %s: %s'):format(path, tostring(err or 'root must be an object'))
	end

	return decoded, path, nil
end

local function has_service(names, wanted)
	for i = 1, #names do
		if names[i] == wanted then
			return true
		end
	end
	return false
end

local function normalise_hal_cfg(raw)
	if type(raw) ~= 'table' then
		return nil
	end

	if type(raw.serial) == 'table' then
		return copy_plain(raw)
	end

	local managers = raw.managers
	local uart = type(managers) == 'table' and managers.uart or nil
	local serial_ports = type(uart) == 'table' and uart.serial_ports or nil
	if type(serial_ports) ~= 'table' then
		return nil
	end

	local out = {
		serial = {},
	}

	for i = 1, #serial_ports do
		local rec = serial_ports[i]
		if type(rec) == 'table' then
			local ref = rec.name
			local device = rec.device or rec.path
			if type(ref) == 'string' and ref ~= '' and type(device) == 'string' and device ~= '' then
				out.serial[ref] = {
					device = device,
					baud   = rec.baud,
					mode   = rec.mode,
				}
			end
		end
	end

	if next(out.serial) == nil then
		return nil
	end

	return out
end

local function first_serial_ref(hal_cfg)
	if type(hal_cfg) ~= 'table' or type(hal_cfg.serial) ~= 'table' then
		return nil
	end

	local best = nil
	for ref in pairs(hal_cfg.serial) do
		if best == nil or tostring(ref) < tostring(best) then
			best = ref
		end
	end
	return best
end

local function normalise_fabric_cfg(raw, opts, hal_cfg)
	if type(raw) == 'table' and type(raw.schema) == 'string' and type(raw.links) == 'table' then
		return copy_plain(raw)
	end

	local serial_ref = opts.fabric_serial_ref or first_serial_ref(hal_cfg)
	if type(serial_ref) ~= 'string' or serial_ref == '' then
		return nil, 'cannot derive fabric serial_ref from selected config'
	end

	local link_id = opts.fabric_link_id or 'mcu0'
	local peer_id = opts.fabric_peer_id or 'mcu-1'

	return {
		schema = 'devicecode.fabric/1',
		links = {
			[link_id] = {
				peer_id = peer_id,
				transport = {
					kind       = 'uart',
					serial_ref = serial_ref,
				},
				export = {
					publish = {},
				},
				import = {
					publish = {},
					call    = {},
				},
				proxy_calls = {},
			},
		},
	}, nil
end

function M.seed(conn, opts)
	opts = opts or {}

	local name = opts.name
	if type(name) ~= 'string' or name == '' then
		return nil, nil
	end

	local selected, path, err = load_selected(name)
	if not selected then
		return nil, err
	end

	local topics = {}
	local hal_cfg = normalise_hal_cfg(selected.hal)
	if hal_cfg ~= nil then
		conn:retain({ 'config', 'hal' }, hal_cfg)
		topics[#topics + 1] = 'config/hal'
	end

	if has_service(opts.service_names or {}, 'fabric') then
		local fabric_cfg, ferr = normalise_fabric_cfg(selected.fabric, opts, hal_cfg)
		if not fabric_cfg then
			return nil, ferr
		end
		conn:retain({ 'config', 'fabric' }, fabric_cfg)
		topics[#topics + 1] = 'config/fabric'
	end

	return {
		name   = name,
		path   = path,
		topics = topics,
	}, nil
end

return M
