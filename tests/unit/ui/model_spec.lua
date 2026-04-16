local busmod = require 'bus'
local mailbox = require 'fibers.mailbox'
local runfibers = require 'tests.support.run_fibers'
local model_mod = require 'services.ui.model'
local ui_fakes = require 'tests.support.ui_fakes'

local T = {}

local function recv_mailbox(rx, timeout)
	local fibers = require 'fibers'
	local sleep = require 'fibers.sleep'
	local which, item, err = fibers.perform(fibers.named_choice({
		item = rx:recv_op(),
		timeout = sleep.sleep_op(timeout or 1.0):wrap(function() return nil, 'timeout' end),
	}))
	if which == 'timeout' then return nil, 'timeout' end
	return item, err
end

function T.model_bootstraps_from_retained_state_and_replays_watchers()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local seed = bus:connect()
		seed:retain({ 'cfg', 'net' }, { rev = 1, data = { foo = 'bar' } })
		seed:retain({ 'svc', 'alpha', 'status' }, { state = 'running' })

		local report_tx, report_rx = mailbox.new(16, { full = 'reject_newest' })
		local model = model_mod.start(bus:connect(), {
			report_tx = report_tx,
			queue_len = 32,
			sources = {
				{ name = 'cfg', pattern = { 'cfg', '#' } },
				{ name = 'svc', pattern = { 'svc', '#' } },
			},
		})

		local ok, err = model:await_ready(0.5)
		assert(ok == true, tostring(err))
		local rep = recv_mailbox(report_rx, 0.5)
		assert(rep.tag == 'model_ready')

		local exact, xerr = model:get_exact({ 'cfg', 'net' })
		assert(xerr == nil)
		assert(exact.payload.rev == 1)
		assert(exact.payload.data.foo == 'bar')

		local snap, serr = model:snapshot({ 'svc', '#' })
		assert(serr == nil)
		assert(#snap.entries == 1)
		assert(snap.entries[1].payload.state == 'running')

		local watch, werr = model:open_watch({ 'cfg', '#' }, { queue_len = 16 })
		assert(watch ~= nil, tostring(werr))
		local ev1 = select(1, watch:recv())
		assert(ev1.op == 'retain')
		assert(ev1.phase == 'replay')
		assert(ev1.topic[1] == 'cfg')
		local ev2 = select(1, watch:recv())
		assert(ev2.op == 'replay_done')
		watch:close('done')
	end, { timeout = 1.5 })
end

function T.model_emits_live_retain_and_unretain_with_seq_reports()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local seed = bus:connect()
		seed:retain({ 'cfg', 'net' }, { rev = 1 })

		local report_tx, report_rx = mailbox.new(16, { full = 'reject_newest' })
		local model = model_mod.start(bus:connect(), {
			report_tx = report_tx,
			queue_len = 32,
			sources = {
				{ name = 'cfg', pattern = { 'cfg', '#' } },
			},
		})
		assert(model:await_ready(0.5) == true)
		recv_mailbox(report_rx, 0.5) -- model_ready

		local watch = assert(model:open_watch({ 'cfg', '#' }, { queue_len = 16 }))
		watch:recv() -- replay retain
		watch:recv() -- replay_done

		seed:retain({ 'cfg', 'wifi' }, { enabled = true })
		local ev1, err1 = watch:recv()
		assert(err1 == nil)
		assert(ev1.op == 'retain')
		assert(ev1.phase == 'live')
		assert(ev1.topic[2] == 'wifi')
		assert(ev1.payload.enabled == true)
		local rep1 = recv_mailbox(report_rx, 0.5)
		assert(rep1.tag == 'model_seq')
		assert(type(rep1.seq) == 'number' and rep1.seq >= 1)

		seed:unretain({ 'cfg', 'wifi' })
		local ev2, err2 = watch:recv()
		assert(err2 == nil)
		assert(ev2.op == 'unretain')
		assert(ev2.phase == 'live')
		assert(ev2.topic[2] == 'wifi')
		local rep2 = recv_mailbox(report_rx, 0.5)
		assert(rep2.tag == 'model_seq')
		assert(type(rep2.seq) == 'number' and rep2.seq >= rep1.seq)
	end, { timeout = 1.5 })
end

return T
