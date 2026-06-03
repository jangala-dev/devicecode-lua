--
-- Backend selector for process management.
-- Prefers pidfd backend where available, falls back to SIGCHLD/self-pipe.
--
---@module 'fibers.io.exec_backend'

---@class ExecProcSpec
---@field argv   string[]
---@field env    table<string,string|nil>|nil
---@field cwd    string|nil
---@field flags  table|nil
---@field stdin  ExecStreamConfig
---@field stdout ExecStreamConfig
---@field stderr ExecStreamConfig

--- Backend module interface.
---@class ExecBackendModule
---@field is_supported fun(): boolean
---@field start fun(spec: ExecProcSpec): ProcHandle|nil, string|nil

---@type string[]
local candidates = {
	'fibers.io.exec_backend.pidfd', -- Linux pidfd backend
	'fibers.io.exec_backend.sigchld', -- Portable SIGCHLD + self-pipe backend (luaposix)
	'fibers.io.exec_backend.nixio', -- Portable SIGCHLD + self-pipe backend (nixio)
}

---@type ExecBackendModule|nil
local chosen

for _, name in ipairs(candidates) do
	local ok, mod = pcall(require, name)
	if ok and type(mod) == 'table' and mod.is_supported and mod.is_supported() then
		---@cast mod ExecBackendModule
		chosen = mod
		break
	end
end

if not chosen then
	error('fibers.io.exec_backend: no suitable process backend available on this platform')
end

---@return ExecBackendModule
return chosen
