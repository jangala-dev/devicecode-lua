-- devicecode/authz.lua
--
-- Topic-aware principal and authoriser helpers.
--
-- Design intent for this step:
--   * keep enforcement in bus.lua
--   * keep policy definition here
--   * remain simple: admin may do everything, but via a rule engine
--   * default deny for missing/unknown principals

local trie = require 'trie'

local M = {}

local Authorizer = {}
Authorizer.__index = Authorizer

--------------------------------------------------------------------------------
-- trie.literal interoperability
--------------------------------------------------------------------------------

local LIT_MT = getmetatable(trie.literal('x'))

local function is_lit(tok)
	return type(tok) == 'table' and getmetatable(tok) == LIT_MT
end

local function unwrap_token(tok)
	if is_lit(tok) then
		return tok.v, true
	end
	return tok, false
end

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

local function copy_roles(roles)
	local out = {}
	if type(roles) ~= 'table' then
		return out
	end
	for i = 1, #roles do
		if type(roles[i]) == 'string' and roles[i] ~= '' then
			out[#out + 1] = roles[i]
		end
	end
	return out
end

local function has_role(principal, wanted)
	local roles = principal and principal.roles
	if type(roles) ~= 'table' then
		return false
	end
	for i = 1, #roles do
		if roles[i] == wanted then
			return true
		end
	end
	return false
end

local function action_matches(rule_action, action)
	if rule_action == '*' then return true end
	if type(rule_action) == 'string' then
		return rule_action == action
	end
	if type(rule_action) == 'table' then
		for i = 1, #rule_action do
			if rule_action[i] == '*' or rule_action[i] == action then
				return true
			end
		end
	end
	return false
end

local function role_matches(rule_roles, principal)
	if rule_roles == '*' then return true end
	if type(rule_roles) ~= 'table' then return false end
	for i = 1, #rule_roles do
		if has_role(principal, rule_roles[i]) then
			return true
		end
	end
	return false
end

local function principal_matches(sel, principal)
	if sel == '*' then return true end
	if type(principal) ~= 'table' then return false end

	if type(sel) == 'function' then
		return not not sel(principal)
	end

	if type(sel) ~= 'table' then
		return false
	end

	if sel.kind ~= nil and sel.kind ~= principal.kind then
		return false
	end

	if sel.id ~= nil and sel.id ~= principal.id then
		return false
	end

	if sel.roles ~= nil and not role_matches(sel.roles, principal) then
		return false
	end

	return true
end

local function topic_matches(pattern, topic, s_wild, m_wild, pi, ti)
	pi = pi or 1
	ti = ti or 1

	local pn = #pattern
	local tn = #topic

	while true do
		if pi > pn then
			return ti > tn
		end

		local p_raw, p_lit = unwrap_token(pattern[pi])

		if not p_lit and p_raw == m_wild then
			return true
		end

		if ti > tn then
			return false
		end

		local t_raw = unwrap_token(topic[ti])

		if (not p_lit) and p_raw == s_wild then
			pi = pi + 1
			ti = ti + 1
		elseif p_raw == t_raw then
			pi = pi + 1
			ti = ti + 1
		else
			return false
		end
	end
end

local function rule_topic_matches(rule_topic, topic, s_wild, m_wild)
	if rule_topic == '*' or rule_topic == nil then
		return true
	end
	if type(rule_topic) ~= 'table' or type(topic) ~= 'table' then
		return false
	end
	return topic_matches(rule_topic, topic, s_wild, m_wild)
end

local function effect_of(rule)
	if rule and rule.effect == 'deny' then
		return 'deny'
	end
	return 'allow'
end

--------------------------------------------------------------------------------
-- Principal constructors
--------------------------------------------------------------------------------

---@param name string
---@param opts? { roles?: string[] }
---@return table
function M.service_principal(name, opts)
	opts = opts or {}
	local roles = copy_roles(opts.roles or { 'admin' })
	return {
		kind  = 'service',
		id    = tostring(name),
		roles = roles,
	}
end

---@param id string
---@param opts? { roles?: string[] }
---@return table
function M.user_principal(id, opts)
	opts = opts or {}
	return {
		kind  = 'user',
		id    = tostring(id),
		roles = copy_roles(opts.roles or {}),
	}
end

---@param id string
---@param opts? { roles?: string[] }
---@return table
function M.peer_principal(id, opts)
	opts = opts or {}
	return {
		kind  = 'peer',
		id    = tostring(id),
		roles = copy_roles(opts.roles or {}),
	}
end

--------------------------------------------------------------------------------
-- Rule helpers
--------------------------------------------------------------------------------

---@param spec? table
---@return table
function M.rule(spec)
	spec = spec or {}
	return {
		principal = spec.principal or '*',
		action    = spec.action or '*',
		topic     = spec.topic or '*',
		effect    = spec.effect or 'allow',
		reason    = spec.reason,
	}
end

---@param roles string[]|string
---@param effect? '"allow"'|'"deny"'
---@return table[]
function M.rules_for_roles(roles, effect)
	if type(roles) == 'string' then roles = { roles } end
	return {
		M.rule {
			principal = { roles = roles },
			action    = '*',
			topic     = '*',
			effect    = effect or 'allow',
		},
	}
end

--------------------------------------------------------------------------------
-- Default rules
--------------------------------------------------------------------------------

local function default_rules()
	-- For now:
	--   * admin may do anything
	--   * everything else is denied by default
	--
	-- The point is to get the matching machinery in place now, while keeping
	-- policy broad until roles are defined properly.
	return M.rules_for_roles({ 'admin' }, 'allow')
end

--------------------------------------------------------------------------------
-- Authoriser
--------------------------------------------------------------------------------

---@param ctx table
---@param rule table
---@param s_wild string|number
---@param m_wild string|number
---@return boolean
local function rule_matches(ctx, rule, s_wild, m_wild)
	return principal_matches(rule.principal, ctx.principal)
		and action_matches(rule.action, ctx.action)
		and rule_topic_matches(rule.topic, ctx.topic, s_wild, m_wild)
end

--- Authorisation hook for bus.lua.
--- ctx = { bus, principal, action, topic, extra }
---@param ctx table
---@return boolean|nil ok
---@return string|nil reason
function Authorizer:allow(ctx)
	local p = ctx and ctx.principal or nil
	if type(p) ~= 'table' then
		return false, 'missing_principal'
	end

	local bus = ctx and ctx.bus or nil
	local s_wild = (bus and bus._s_wild) or '+'
	local m_wild = (bus and bus._m_wild) or '#'

	local rules = self.rules or {}
	for i = 1, #rules do
		local rule = rules[i]
		if rule_matches(ctx, rule, s_wild, m_wild) then
			if effect_of(rule) == 'deny' then
				return false, rule.reason or 'forbidden'
			end
			return true, nil
		end
	end

	return false, 'forbidden'
end

---@param opts? { rules?: table[] }
---@return table
function M.new(opts)
	opts = opts or {}
	return setmetatable({
		rules = opts.rules or default_rules(),
		opts  = opts,
	}, Authorizer)
end

return M
