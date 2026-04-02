-- services/net/compiler_adapter.lua
--
-- Small adapter around the net compiler.

local compiler = require 'services.net.compiler'

local M = {}

function M.compile_bundle_from_config(cfg, rev, gen)
	return compiler.compile_bundle(cfg, {
		rev = rev,
		gen = gen,
	})
end

return M
