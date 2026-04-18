local fibers = require 'fibers'

local M = {}

local function roles_copy(t)
	local out = {}
	for i = 1, #(t or {}) do out[i] = t[i] end
	return out
end

local function principal_view(p)
	if type(p) ~= 'table' then
		return { id = tostring(p) }
	end
	return {
		id = p.id or p.name or tostring(p),
		kind = p.kind,
		roles = roles_copy(p.roles),
	}
end

function M.new_store(opts)
	opts = opts or {}
	local now = opts.now or fibers.now
	local by_id = {}
	local store = {}

	function store:create(session_id, principal, ttl_s)
		local rec = {
			id = session_id,
			principal = principal,
			user = principal_view(principal),
			created_at = now(),
			expires_at = now() + (ttl_s or 3600),
		}
		by_id[session_id] = rec
		return rec
	end

	function store:get(session_id)
		local rec = by_id[session_id]
		if not rec then return nil end
		if rec.expires_at <= now() then
			by_id[session_id] = nil
			return nil
		end
		return rec
	end

	function store:touch(session_id, ttl_s)
		local rec = self:get(session_id)
		if not rec then return nil end
		rec.expires_at = now() + (ttl_s or 3600)
		return rec
	end

	function store:delete(session_id)
		by_id[session_id] = nil
		return true
	end

	function store:prune()
		local t = now()
		local removed = 0
		for sid, rec in pairs(by_id) do
			if rec.expires_at <= t then
				by_id[sid] = nil
				removed = removed + 1
			end
		end
		return removed
	end

	function store:count()
		local n = 0
		for _ in pairs(by_id) do n = n + 1 end
		return n
	end

	function store:public(rec)
		if not rec then return nil end
		return {
			session_id = rec.id,
			user = {
				id = rec.user.id,
				kind = rec.user.kind,
				roles = roles_copy(rec.user.roles),
			},
			created_at = rec.created_at,
			expires_at = rec.expires_at,
		}
	end

	return store
end

return M
