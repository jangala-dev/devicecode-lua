-- fibers/io/exec_backend/stdio.lua
--
-- Shared stdio wiring for exec backends.
--
-- Takes ExecStreamConfig values (as constructed by fibers.exec)
-- and turns them into:
--   * child_spec.{stdin_fd, stdout_fd, stderr_fd}
--   * child_only : set of fds only used in the child
--   * parent_fds : { stdin = fd?, stdout = fd?, stderr = fd? } for pipes
--
---@module 'fibers.io.exec_backend.stdio'

local M = {}

---@param s any
---@return integer|nil fd, string|nil err
local function stream_fileno(s)
	if type(s) ~= 'table' then
		return nil, 'stream is not a table'
	end
	local io_backend = s.io
	if type(io_backend) ~= 'table' or type(io_backend.fileno) ~= 'function' then
		return nil, 'stream backend does not support fileno()'
	end
	return io_backend:fileno()
end

--- Build child stdio fd mapping and parent pipe ends from a high-level spec.
---
--- Callbacks:
---   open_dev_null(is_output:boolean) -> fd|nil, err|nil
---   make_pipe() -> rd_fd|nil, wr_fd|nil, err|nil
---   set_cloexec(fd) -> ok:boolean, err|nil
---   close_fd(fd) -> ()
---
---@param spec ExecProcSpec
---@param open_dev_null fun(is_output: boolean): integer|nil, string|nil
---@param make_pipe fun(): integer|nil, integer|nil, string|nil
---@param set_cloexec fun(fd: integer): boolean, string|nil
---@param close_fd fun(fd: integer)
---@return table|nil child_spec, table|nil child_only, table|nil parent_fds, string|nil err
function M.build_child_stdio(spec, open_dev_null, make_pipe, set_cloexec, close_fd)
	assert(type(spec) == 'table', 'build_child_stdio: spec must be a table')
	assert(type(open_dev_null) == 'function', 'build_child_stdio: open_dev_null must be a function')
	assert(type(make_pipe) == 'function', 'build_child_stdio: make_pipe must be a function')
	assert(type(set_cloexec) == 'function', 'build_child_stdio: set_cloexec must be a function')
	assert(type(close_fd) == 'function', 'build_child_stdio: close_fd must be a function')

	local child_only = {} -- [fd] = true  (used only in child)
	local parent_fds = {} -- stdin/stdout/stderr -> parent end for pipes

	local child_spec = {
		argv      = spec.argv,
		cwd       = spec.cwd,
		env       = spec.env,
		flags     = spec.flags,
		stdin_fd  = nil,
		stdout_fd = nil,
		stderr_fd = nil,
	}

	local function fail(msg)
		for fd in pairs(child_only) do
			close_fd(fd)
		end
		for _, fd in pairs(parent_fds) do
			if fd then
				close_fd(fd)
			end
		end
		return nil, nil, nil, msg
	end

	--- Configure a single stdio stream.
	--- kind: "stdin" | "stdout" | "stderr"
	--- cfg : ExecStreamConfig|nil
	local function configure_stream(kind, cfg)
		-- Allow callers to omit stdin/stdout/stderr in the spec; treat as inherit.
		cfg = cfg or { mode = 'inherit' }

		local is_output = (kind ~= 'stdin')
		local field     = kind .. '_fd'
		local mode      = cfg.mode or 'inherit'

		-- inherit
		if mode == 'inherit' then
			child_spec[field] = nil
			return true

			-- /dev/null
		elseif mode == 'null' then
			local fd, err = open_dev_null(is_output)
			if not fd then
				return false, err
			end
			child_only[fd]    = true
			child_spec[field] = fd
			return true

			-- pipe (child ↔ parent)
		elseif mode == 'pipe' then
			local rd, wr, err = make_pipe()
			if not (rd and wr) then
				return false, err
			end

			local child_fd, parent_fd
			if is_output then
				-- child writes, parent reads
				child_fd, parent_fd = wr, rd
			else
				-- child reads, parent writes
				child_fd, parent_fd = rd, wr
			end

			child_only[child_fd] = true
			child_spec[field]    = child_fd
			parent_fds[kind]     = parent_fd

			local ok, cerr = set_cloexec(parent_fd)
			if not ok then
				return false, cerr or ('set_cloexec(' .. kind .. ' parent fd) failed')
			end
			return true

			-- user-supplied stream: just borrow the underlying fd
		elseif mode == 'stream' then
			local fd, err = stream_fileno(cfg.stream)
			if not fd then
				return false, err
			end
			child_spec[field] = fd
			return true

			-- stderr = "stdout"
		elseif kind == 'stderr' and mode == 'stdout' then
			-- stdout config may itself be missing; default to inherit in that case.
			local out_cfg  = spec.stdout or { mode = 'inherit' }
			local out_mode = out_cfg.mode or 'inherit'

			if out_mode == 'inherit' and child_spec.stdout_fd == nil then
				-- Share inherited stdout (fd 1).
				child_spec.stderr_fd = 1
			elseif child_spec.stdout_fd ~= nil then
				-- Share whatever stdout was configured to use.
				child_spec.stderr_fd = child_spec.stdout_fd
			else
				return false, "stderr='stdout' but stdout not configured"
			end
			return true

		else
			return false, 'invalid ' .. kind .. ' mode: ' .. tostring(mode)
		end
	end


	do
		local ok, err = configure_stream('stdin', spec.stdin)
		if not ok then
			return fail(err)
		end
	end

	do
		local ok, err = configure_stream('stdout', spec.stdout)
		if not ok then
			return fail(err)
		end
	end

	do
		local ok, err = configure_stream('stderr', spec.stderr)
		if not ok then
			return fail(err)
		end
	end

	return child_spec, child_only, parent_fds, nil
end

--- Best-effort close of fds that are only needed in the child.
---@param child_only table<integer, boolean>|nil
---@param close_fd fun(fd: integer)
function M.close_child_only(child_only, close_fd)
	if not child_only then return end
	for fd in pairs(child_only) do
		close_fd(fd)
	end
end

--- Best-effort close of parent pipe ends (used on error paths).
---@param parent_fds table<string, integer|nil>|nil
---@param close_fd fun(fd: integer)
function M.close_parent_fds(parent_fds, close_fd)
	if not parent_fds then return end
	for _, fd in pairs(parent_fds) do
		if fd then
			close_fd(fd)
		end
	end
end

--- Map parent pipe fds back into Streams, given an open_stream callback.
---
--- open_stream(role, fd) -> Stream
---
---@param parent_fds table<string, integer|nil>|nil
---@param open_stream fun(role: '"stdin"'|'"stdout"'|'"stderr"', fd: integer): Stream
---@return { stdin: Stream|nil, stdout: Stream|nil, stderr: Stream|nil }
function M.build_parent_streams(parent_fds, open_stream)
	parent_fds = parent_fds or {}

	local stdin, stdout, stderr

	if parent_fds.stdin then
		stdin = open_stream('stdin', parent_fds.stdin)
	end
	if parent_fds.stdout then
		stdout = open_stream('stdout', parent_fds.stdout)
	end
	if parent_fds.stderr then
		stderr = open_stream('stderr', parent_fds.stderr)
	end

	return {
		stdin  = stdin,
		stdout = stdout,
		stderr = stderr,
	}
end

return M
