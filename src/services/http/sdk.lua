-- services/http/sdk.lua
-- Op-native bus client for cap/http/<id>.

local topics = require 'services.http.topics'

local M = {}
local Ref = {}
Ref.__index = Ref

function M.new_ref(conn, id)
	return setmetatable({ conn = conn, id = id or 'main' }, Ref)
end

local function call_opts(opts)
	local out = {}
	for k, v in pairs(opts or {}) do out[k] = v end
	if out.timeout == nil and out.deadline == nil then
		out.timeout = false
	end
	return out
end

function Ref:call_op(verb, args, opts)
	return self.conn:call_op(topics.rpc(self.id, verb), args or {}, call_opts(opts))
end

function Ref:status_op(opts) return self:call_op('status', {}, opts) end
function Ref:listen_op(args, opts) return self:call_op('listen', args or {}, opts) end
function Ref:open_exchange_op(args, opts) return self:call_op('open-exchange', args or {}, opts) end
function Ref:exchange_op(args, opts) return self:call_op('exchange', args or {}, opts) end
function Ref:connect_ws_op(args, opts) return self:call_op('connect-ws', args or {}, opts) end

M.Ref = Ref
return M
