-- tools/test_firmware_update.lua
--
-- Usage:
--   cd devicecode-lua
--   DEVICECODE_HAL_BACKEND=openwrt \
--   DEVICECODE_STATE_DIR=/tmp/devicecode \
--   DEVICECODE_NODE_ID=cm5-local \
--   luajit tools/test_firmware_update.lua /root/mcu-firmware/devicecode_sealed.bin [config_name] [link_id] [peer_id]
--
-- Defaults:
--   config_name = mcu-dev
--   link_id     = mcu0
--   peer_id     = mcu-1

local function add_path(prefix)
	package.path = prefix .. '?.lua;' .. prefix .. '?/init.lua;' .. package.path
end

local function script_dir()
	local script = arg and arg[0] or ''
	local dir = script:match('^(.*[/\\])')
	if dir then
		return dir
	end
	return './'
end

local root = script_dir() .. '../'
add_path(root .. 'src/')
add_path(root)
add_path(root .. 'vendor/lua-fibers/src/')
add_path(root .. 'vendor/lua-bus/src/')
add_path(root .. 'vendor/lua-trie/src/')

local cjson  = require 'cjson.safe'
local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'
local busmod = require 'bus'

local authz       = require 'devicecode.authz'
local mainmod     = require 'devicecode.main'
local blob_source = require 'services.fabric.blob_source'

local function usage()
	io.stderr:write(
		'usage: luajit tools/test_firmware_update.lua <image.bin> [config_name] [link_id] [peer_id]\n'
	)
	os.exit(2)
end

local function encode_json(v)
	local s, err = cjson.encode(v)
	if s ~= nil then return s end
	return '<json encode failed: ' .. tostring(err) .. '>'
end

local function wait_for_link_ready(conn, link_id, peer_id, timeout_s)
	local sub = conn:subscribe({ 'state', 'fabric', 'link', link_id }, {
		queue_len = 32,
		full      = 'drop_oldest',
	})
	local deadline = fibers.now() + timeout_s

	while fibers.now() < deadline do
		local msg, err = fibers.perform(sub:recv_op())
		if not msg then
			sub:unsubscribe()
			return nil, 'link state subscription ended: ' .. tostring(err)
		end

		local payload = msg.payload
		if type(payload) == 'table'
			and payload.status == 'ready'
			and payload.ready == true
			and payload.peer_id == peer_id then
			sub:unsubscribe()
			return payload, nil
		end
	end

	sub:unsubscribe()
	return nil, 'timed out waiting for fabric link ready'
end

local function poll_transfer(req_conn, transfer_id, timeout_s)
	local deadline = fibers.now() + timeout_s
	local last_line = nil

	while fibers.now() < deadline do
		local reply, err = req_conn:call(
			{ 'rpc', 'fabric', 'transfer_status' },
			{ transfer_id = transfer_id },
			{ timeout = 2.0 }
		)

		if reply and reply.ok == true and type(reply.transfer) == 'table' then
			local tr = reply.transfer
			local line = table.concat({
				tostring(tr.status or '?'),
				tostring(tr.bytes_done or 0) .. '/' .. tostring(tr.size or 0),
				tostring(tr.chunks_done or 0) .. '/' .. tostring(tr.chunks or 0),
			}, '  ')

			if line ~= last_line then
				io.stdout:write('[transfer] ' .. line .. '\n')
				last_line = line
			end

			if tr.status == 'done' or tr.status == 'aborted' then
				return tr, nil
			end
		elseif err ~= nil then
			io.stdout:write('[transfer] status poll error: ' .. tostring(err) .. '\n')
		end

		sleep.sleep(0.2)
	end

	return nil, 'timed out waiting for transfer completion'
end

local function wait_for_peer_dump(req_conn, peer_id, timeout_s)
	local deadline = fibers.now() + timeout_s

	while fibers.now() < deadline do
		local reply = req_conn:call(
			{ 'rpc', 'peer', peer_id, 'hal', 'dump' },
			{ source = 'firmware_update_test' },
			{ timeout = 1.0 }
		)

		if reply ~= nil then
			return reply, nil
		end

		sleep.sleep(0.5)
	end

	return nil, 'timed out waiting for peer hal/dump after transfer'
end

local function main(scope)
	local image_path = arg[1]
	if image_path == nil or image_path == '' then
		usage()
	end

	local config_name = arg[2] or 'mcu-dev'
	local link_id     = arg[3] or os.getenv('DEVICECODE_FABRIC_LINK_ID') or 'mcu0'
	local peer_id     = arg[4] or os.getenv('DEVICECODE_FABRIC_PEER_ID') or 'mcu-1'
	local env         = os.getenv('DEVICECODE_ENV') or 'dev'
	local transfer_timeout_s = tonumber(os.getenv('DEVICECODE_TRANSFER_TIMEOUT_S')) or 900.0

	local source, serr = blob_source.from_file(image_path, { format = 'bin' })
	if not source then
		error('failed to read image: ' .. tostring(serr), 0)
	end

	io.stdout:write('[image] ' .. tostring(source:name()) .. '\n')
	io.stdout:write('[image] size=' .. tostring(source:size()) .. ' sha256=' .. tostring(source:sha256hex()) .. '\n')

	local bus = busmod.new({
		q_length   = 10,
		full       = 'drop_oldest',
		s_wild     = '+',
		m_wild     = '#',
		authoriser = authz.new(),
	})

	local req_conn = bus:connect({
		principal = authz.service_principal('firmware-update-test'),
	})

	local child, cerr = scope:child()
	if not child then
		error('failed to create runtime child scope: ' .. tostring(cerr), 0)
	end

	local ok_spawn, spawn_err = scope:spawn(function()
		return mainmod.run(child, {
			env          = env,
			config_name  = config_name,
			services_csv = 'hal,fabric',
			bus          = bus,
		})
	end)
	if not ok_spawn then
		error('failed to start runtime: ' .. tostring(spawn_err), 0)
	end

	io.stdout:write('[runtime] waiting for fabric link ' .. link_id .. ' -> ' .. peer_id .. '\n')
	local ready, rerr = wait_for_link_ready(req_conn, link_id, peer_id, 20.0)
	if not ready then
		child:cancel('ready_failed')
		error(tostring(rerr), 0)
	end

	io.stdout:write('[runtime] link ready: ' .. encode_json(ready) .. '\n')

	local reply, call_err = req_conn:call(
		{ 'rpc', 'fabric', 'send_firmware' },
		{
			link_id = link_id,
			source  = source,
			meta    = {
				kind   = 'firmware.rp2350',
				name   = source:name(),
				format = 'bin',
			},
		},
		{ timeout = 10.0 }
	)

	if not reply then
		child:cancel('send_failed')
		error('send_firmware rpc failed: ' .. tostring(call_err), 0)
	end

	io.stdout:write('[send] ' .. encode_json(reply) .. '\n')

	if reply.ok ~= true or type(reply.transfer_id) ~= 'string' or reply.transfer_id == '' then
		child:cancel('send_rejected')
		error('send_firmware rejected', 0)
	end

	local transfer_id = reply.transfer_id
	io.stdout:write('[transfer] timeout_budget=' .. tostring(transfer_timeout_s) .. 's\n')

	local final_status, ferr = poll_transfer(req_conn, transfer_id, transfer_timeout_s)
	if not final_status then
		child:cancel('transfer_timeout')
		error(tostring(ferr), 0)
	end

	io.stdout:write('[final] ' .. encode_json(final_status) .. '\n')

	if final_status.status ~= 'done' then
		child:cancel('transfer_failed')
		error('transfer ended in state: ' .. tostring(final_status.status), 0)
	end

	io.stdout:write('[post] transfer reached done; MCU should reboot immediately after this\n')
	io.stdout:write('[post] waiting for peer hal/dump to succeed again\n')

	local dump, derr = wait_for_peer_dump(req_conn, peer_id, 30.0)
	if dump then
		io.stdout:write('[peer] ' .. encode_json(dump) .. '\n')
	else
		io.stdout:write('[peer] ' .. tostring(derr) .. '\n')
	end

	child:cancel('done')
end

fibers.run(function(scope)
	main(scope)
end)
