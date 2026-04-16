local topics = require 'services.ui.topics'
local safe = require 'coxpcall'

local T = {}

function T.normalise_topic_accepts_concrete_and_wildcard_tokens()
	local t, err = topics.normalise_topic({ 'cfg', 'net', 1 }, { allow_wildcards = false, allow_numbers = true })
	assert(err == nil)
	assert(type(t) == 'table')
	assert(t[1] == 'cfg')
	assert(t[2] == 'net')
	assert(t[3] == 1)

	local w, werr = topics.normalise_topic({ 'svc', '+', '#' }, { allow_wildcards = true })
	assert(werr == nil)
	assert(w[2] == '+')
	assert(w[3] == '#')
end

function T.normalise_topic_rejects_sparse_and_wildcards_when_concrete()
	local ok_sparse, err_sparse = safe.pcall(function()
		return topics.normalise_topic({ [1] = 'cfg', [3] = 'net' }, { allow_wildcards = true })
	end)
	assert(ok_sparse == true)
	local _, nerr = topics.normalise_topic({ [1] = 'cfg', [3] = 'net' }, { allow_wildcards = true })
	assert(tostring(nerr):match('dense array'))

	local _, err = topics.normalise_topic({ 'cfg', '+' }, { allow_wildcards = false })
	assert(tostring(err):match('concrete'))
end

function T.copy_plain_deep_copies_plain_tables()
	local src = { a = 1, b = { c = 2 } }
	local out = topics.copy_plain(src)
	assert(out ~= src)
	assert(out.b ~= src.b)
	assert(out.b.c == 2)
	out.b.c = 9
	assert(src.b.c == 2)
end

function T.match_supports_single_and_multi_wildcards()
	assert(topics.match({ 'cfg', '+' }, { 'cfg', 'net' }) == true)
	assert(topics.match({ 'cfg', '#' }, { 'cfg', 'net', 'extra' }) == true)
	assert(topics.match({ 'cfg', '+' }, { 'cfg', 'net', 'extra' }) == false)
	assert(topics.match({ 'svc', '+', 'status' }, { 'svc', 'alpha', 'status' }) == true)
end

return T
