local errors = require 'services.ui.errors'
local queries = require 'services.ui.queries'
local topics = require 'services.ui.topics'

local T = {}

local function fake_model(entries)
	entries = entries or {}
	local by_key = {}
	for i = 1, #entries do
		by_key[topics.topic_key(entries[i].topic)] = entries[i]
	end

	return {
		get_exact = function(_, topic)
			local rec = by_key[topics.topic_key(topic)]
			if not rec then return nil, errors.not_found('not found') end
			return rec, nil
		end,
		snapshot = function(_, pattern)
			local out = {}
			for i = 1, #entries do
				if topics.match(pattern, entries[i].topic) then
					out[#out + 1] = entries[i]
				end
			end
			topics.sort_entries(out)
			return { seq = 7, entries = out }, nil
		end,
	}
end

function T.services_snapshot_merges_meta_and_status_by_name()
	local model = fake_model({
		{ topic = { 'svc', 'alpha', 'meta' }, payload = { role = 'a' } },
		{ topic = { 'svc', 'beta', 'meta' }, payload = { role = 'b' } },
		{ topic = { 'svc', 'alpha', 'status' }, payload = { state = 'running', ready = true, run_id = 'alpha-run-1' } },
	})
	local out, err = queries.services_snapshot(model)
	assert(err == nil)
	assert(out.meta.alpha.role == 'a')
	assert(out.meta.beta.role == 'b')
	assert(out.status.alpha.state == 'running')
	assert(out.status.alpha.ready == true)
end

function T.fabric_status_and_link_status_return_aggregated_view()
	local model = fake_model({
		{ topic = { 'state', 'fabric' }, payload = { kind = 'fabric.summary' } },
		{ topic = { 'state', 'fabric', 'link', 'wan0', 'session' }, payload = { ready = true } },
		{ topic = { 'state', 'fabric', 'link', 'wan0', 'bridge' }, payload = { connected = true } },
		{ topic = { 'state', 'fabric', 'link', 'wan0', 'transfer' }, payload = { idle = true } },
	})
	local out, err = queries.fabric_status(model)
	assert(err == nil)
	assert(out.main.kind == 'fabric.summary')
	assert(out.links.wan0.transfer.idle == true)

	local link, lerr = queries.fabric_link_status(model, 'wan0')
	assert(lerr == nil)
	assert(link.session.ready == true)
	assert(link.bridge.connected == true)
	assert(link.transfer.idle == true)
end


return T
