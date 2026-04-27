-- shared/crypto/provider.lua
--
-- Minimal provider adapter/factory.  Providers are ordinary Lua objects that
-- implement crypto operations and may expose :new_verifier(opts).  This module
-- intentionally knows nothing about HAL, bus topics, OpenSSL, files or any
-- other OS boundary.

local M = {}

local Provider = {}
Provider.__index = Provider

local function assert_backend(backend)
	if type(backend) ~= 'table' then
		error('crypto provider backend required', 3)
	end
	if type(backend.new_verifier) ~= 'function' and type(backend.verify_ed25519) ~= 'function' then
		error('crypto provider backend must implement :new_verifier() or :verify_ed25519()', 3)
	end
	return backend
end

--- Return a provider backend after validating its shape.
---@param opts { backend: table }
---@return table
function M.new(opts)
	opts = type(opts) == 'table' and opts or {}
	return assert_backend(opts.backend)
end

--- Wrap a raw operation provider as a verifier provider when it does not
--- provide :new_verifier itself.
---@param backend table
---@return table
function M.with_verifier_factory(backend)
	backend = assert_backend(backend)
	if type(backend.new_verifier) == 'function' then return backend end
	local verifier_mod = require 'shared.crypto.verifier'
	return setmetatable({ backend = backend }, Provider)
end

function Provider:verify_ed25519(...)
	return self.backend:verify_ed25519(...)
end

function Provider:new_verifier(opts)
	opts = type(opts) == 'table' and opts or {}
	local keyring = assert(opts.keyring, 'crypto verifier keyring required')
	local verifier_mod = require 'shared.crypto.verifier'
	return verifier_mod.new({ provider = self, keyring = keyring })
end

return M
