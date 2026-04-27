local cjson = require 'cjson.safe'
local runfibers = require 'tests.support.run_fibers'
local ui_fakes = require 'tests.support.ui_fakes'

local T = {}

local function find_reply(frames, id)
	for i = 1, #frames do
		if frames[i].id == id then return frames[i] end
	end
	return nil
end

function T.ui_ws_client_handles_login_call_and_watch_lifecycle()
	runfibers.run(function(scope)
		local fake_ws = ui_fakes.fake_ws()
		local restore = ui_fakes.install_fake_websocket_module(fake_ws)
		local ws_client = require 'services.ui.transport.ws_client'

		local watch_tx, watch_rx = require('fibers.mailbox').new(16, { full = 'reject_newest' })
		local disconnected = 0
		local opened = 0
		local closed = 0
		local app = {
			login = function(username, password)
				assert(username == 'admin')
				assert(password == 'pw')
				return { session_id = 'sess-1', user = { id = 'admin' } }, nil
			end,
			logout = function(session_id)
				assert(session_id == 'sess-1')
				return { ok = true }, nil
			end,
			health = function()
				return { ok = true }, nil
			end,
			watch_open = function(session_id, pattern, opts)
				assert(session_id == 'sess-1')
				return {
					recv_op = function()
						return watch_rx:recv_op():wrap(function(item)
							if item == nil then return nil, 'closed' end
							return item, nil
						end)
					end,
					recv = function(self)
						return require('fibers').perform(self:recv_op())
					end,
					close = function(_, reason)
						watch_tx:close(reason or 'closed')
						return true
					end,
				}, nil
			end,
			get_session = function(session_id)
				return { session_id = session_id, user = { id = 'admin' } }, nil
			end,
			config_get = function() return { rev = 1 }, nil end,
			config_set = function() return { ok = true }, nil end,
			service_status = function() return { state = 'running' }, nil end,
			services_snapshot = function() return { meta = {}, status = {} }, nil end,
			fabric_status = function() return { links = {} }, nil end,
			fabric_link_status = function() return { session = {} }, nil end,
			model_exact = function() return { payload = {} }, nil end,
			model_snapshot = function() return { entries = {} }, nil end,
		}
		local stream = { _fake_ws = fake_ws }
		local req_headers = ui_fakes.make_headers({
			[':method'] = 'GET',
			[':path'] = '/ws',
		})
		local svc = { name = 'ui', obs_log = function() end }
		local ok, err = scope:spawn(function()
			ws_client.run(svc, app, stream, req_headers, {
				session_id_from_headers = function() return nil end,
				require_session = function(session_id)
					if session_id ~= 'sess-1' then return nil, 'bad session' end
					return { id = 'sess-1', principal = ui_fakes.principal('admin') }, nil
				end,
				open_user_conn = function(principal, origin_extra)
					assert(principal.id == 'admin')
					assert(type(origin_extra) == 'table')
					return { disconnect = function() disconnected = disconnected + 1 end }, nil
				end,
				on_opened = function() opened = opened + 1 end,
				on_closed = function() closed = closed + 1 end,
			})
		end)
		assert(ok, tostring(err))

		fake_ws:inject_text({ id = 1, op = 'hello' })
		fake_ws:inject_text({ id = 2, op = 'login', username = 'admin', password = 'pw' })
		fake_ws:inject_text({ id = 3, op = 'watch_open', watch_id = 'w1', pattern = { 'cfg', '#' } })
		watch_tx:send({ op = 'retain', phase = 'live', topic = { 'cfg', 'net' }, payload = { ok = true } })
		fake_ws:inject_text({ id = 4, op = 'logout' })
		fake_ws:disconnect('done')

		local deadline = require('fibers').now() + 1.0
		while #fake_ws.sent < 5 and require('fibers').now() < deadline do
			local _ = fake_ws:recv_sent()
		end
		assert(#fake_ws.sent >= 5 and closed == 1)

		local frames = fake_ws:sent_objects()
		assert(opened == 1)
		assert(disconnected >= 1)
		assert(find_reply(frames, 1).ok == true)
		assert(find_reply(frames, 2).data.session_id == 'sess-1')
		assert(find_reply(frames, 3).data.watch_id == 'w1')
		local saw_watch_event = false
		for i = 1, #frames do
			if frames[i].op == 'watch_event' and frames[i].watch_id == 'w1' then
				saw_watch_event = true
				assert(frames[i].event.payload.ok == true)
			end
		end
		assert(saw_watch_event == true)
		assert(find_reply(frames, 4).ok == true)

		restore()
	end, { timeout = 2.0 })
end

return T
