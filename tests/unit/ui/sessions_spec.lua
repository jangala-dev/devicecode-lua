local sessions = require 'services.ui.sessions'

local T = {}

function T.session_store_create_touch_delete_and_public_view()
	local now = 100
	local store = sessions.new_store({ now = function() return now end })
	local rec = store:create('s1', { id = 'alice', kind = 'user', roles = { 'admin' }, secret = true }, 10)
	assert(rec.id == 's1')
	assert(store:count() == 1)

	local got = store:get('s1')
	assert(got ~= nil)
	assert(got.user.id == 'alice')
	assert(got.user.secret == nil)

	now = 105
	store:touch('s1', 20)
	assert(store:get('s1').expires_at == 125)

	local pub = store:public(store:get('s1'))
	assert(pub.session_id == 's1')
	assert(pub.user.id == 'alice')
	assert(pub.user.kind == 'user')
	assert(pub.user.roles[1] == 'admin')

	store:delete('s1')
	assert(store:get('s1') == nil)
	assert(store:count() == 0)
end

function T.session_store_prunes_expired_sessions()
	local now = 0
	local store = sessions.new_store({ now = function() return now end })
	store:create('a', { id = 'a' }, 5)
	store:create('b', { id = 'b' }, 10)
	now = 6
	assert(store:get('a') == nil)
	assert(store:get('b') ~= nil)
	assert(store:prune() == 0)
	now = 11
	assert(store:prune() == 1)
	assert(store:count() == 0)
end

return T
