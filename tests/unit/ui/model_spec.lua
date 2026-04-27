local busmod = require 'bus'
local runfibers = require 'tests.support.run_fibers'
local model_mod = require 'services.ui.model'

local T = {}

local function model_next_change(model, last_seq, timeout)
	if type(model.next_change) == 'function' then
		return model:next_change(last_seq, timeout)
	end
	if type(model.await_seq_change) == 'function' then
		return model:await_seq_change(last_seq, timeout)
	end
	if type(model.next_change_op) == 'function' then
		local fibers = require 'fibers'
		return fibers.perform(model:next_change_op(last_seq, timeout))
	end
	if type(model.await_seq_change_op) == 'function' then
		local fibers = require 'fibers'
		return fibers.perform(model:await_seq_change_op(last_seq, timeout))
	end
	error('ui model does not expose a change-wait API')
end

function T.model_bootstraps_from_retained_state_and_replays_watchers()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local seed = bus:connect()
		seed:retain({ 'cfg', 'net' }, { rev = 1, data = { foo = 'bar' } })
		seed:retain({ 'svc', 'alpha', 'status' }, { state = 'running', ready = true, run_id = 'alpha-run-1' })

		local model = model_mod.start(bus:connect(), {
			queue_len = 32,
			sources = {
				{ name = 'cfg', pattern = { 'cfg', '#' } },
				{ name = 'svc', pattern = { 'svc', '#' } },
			},
		})

		local ok, err = model:await_ready(0.5)
		assert(ok == true, tostring(err))
		assert(model:is_ready() == true)

		local exact, xerr = model:get_exact({ 'cfg', 'net' })
		assert(xerr == nil)
		assert(exact.payload.rev == 1)
		assert(exact.payload.data.foo == 'bar')

		local snap, serr = model:snapshot({ 'svc', '#' })
		assert(serr == nil)
		assert(#snap.entries == 1)
		assert(snap.entries[1].payload.state == 'running')
		assert(snap.entries[1].payload.ready == true)

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

		local model = model_mod.start(bus:connect(), {
			queue_len = 32,
			sources = {
				{ name = 'cfg', pattern = { 'cfg', '#' } },
			},
		})
		assert(model:await_ready(0.5) == true)

		local watch = assert(model:open_watch({ 'cfg', '#' }, { queue_len = 16 }))
		watch:recv() -- replay retain
		watch:recv() -- replay_done

		local last_seq = model:seq()

		seed:retain({ 'cfg', 'wifi' }, { enabled = true })
		local ev1, err1 = watch:recv()
		assert(err1 == nil)
		assert(ev1.op == 'retain')
		assert(ev1.phase == 'live')
		assert(ev1.topic[2] == 'wifi')
		assert(ev1.payload.enabled == true)

		local seq1, seqerr1 = model_next_change(model, last_seq, 0.5)
		assert(seqerr1 == nil)
		assert(type(seq1) == 'number' and seq1 > last_seq)
		last_seq = seq1

		seed:unretain({ 'cfg', 'wifi' })
		local ev2, err2 = watch:recv()
		assert(err2 == nil)
		assert(ev2.op == 'unretain')
		assert(ev2.phase == 'live')
		assert(ev2.topic[2] == 'wifi')

		local seq2, seqerr2 = model_next_change(model, last_seq, 0.5)
		assert(seqerr2 == nil)
		assert(type(seq2) == 'number' and seq2 > last_seq)
	end, { timeout = 1.5 })
end

return T
