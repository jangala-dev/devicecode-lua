-- fibers.lua
---@module 'fibers'

local Op        = require 'fibers.op'
local Runtime   = require 'fibers.runtime'
local Scope     = require 'fibers.scope'
local Performer = require 'fibers.performer'

local unpack = rawget(table, 'unpack') or _G.unpack
local pack   = rawget(table, 'pack') or function (...)
	return { n = select('#', ...), ... }
end

local function raise_string(err)
	if type(err) == 'string' or type(err) == 'number' then
		error(err, 0)
	end
	error(tostring(err), 0)
end

----------------------------------------------------------------------
-- Core entry point
----------------------------------------------------------------------

--- Run a main function under the scheduler's root scope.
---
--- main_fn is called as main_fn(scope, ...).
---
--- On success:
---   returns ...results... from main_fn directly.
---
--- On failure or cancellation:
---   raises a string/number (never a table).
---
---@param main_fn fun(s: any, ...): any
---@param ... any
---@return any ...
local function run(main_fn, ...)
    if Runtime.current_fiber() then  error('fibers.run must not be called from inside a fiber', 2) end
    if type(main_fn) ~= 'function' then error('fibers.run expects a function', 2) end

	local root = Scope.root()
	local args = pack(...)

	local box = {
		status  = nil, -- 'ok'|'cancelled'|'failed'
		primary = nil, -- primary/reason (for non-ok)
		results = nil, -- packed results (for ok)
		-- report = nil, -- optional: ScopeReport
	}

	root:spawn(function ()
		-- Scope.run returns:
		--   on ok:     'ok', rep, ...results...
		--   on not ok: st,  rep, primary
		local r = pack(Scope.run(main_fn, unpack(args, 1, args.n)))

		local st   = r[1]
		-- local rep = r[2]
		box.status = st
		-- box.report = rep

		if st == 'ok' then
			-- Preserve multi-return values for handoff back to the caller.
			if r.n > 2 then
				box.results = pack(unpack(r, 3, r.n))
			else
				box.results = pack()
			end
		else
			box.primary = r[3]
		end

		Runtime.stop()
	end)

	Runtime.main()

	if box.status == 'ok' then
		local res = box.results
		if res and res.n and res.n > 0 then
			return unpack(res, 1, res.n)
		end
		return
	end

	raise_string(box.primary or box.status or 'fibers.run: missing status')
end

----------------------------------------------------------------------
-- Spawn
----------------------------------------------------------------------

--- Spawn a fiber under the current scope.
--- fn is called as fn(...).
---@param fn fun(...): any
---@param ... any
---@return boolean ok, any|nil err
local function spawn(fn, ...)
    if type(fn) ~= 'function' then error('fibers.spawn expects a function', 2) end

	local s    = Scope.current()
	local args = { ... }

	local function shim(_, ...)
		return fn(...)
	end

	return s:spawn(shim, unpack(args))
end

return {
	spawn = spawn,
	run   = run,

	perform     = Performer.perform,

	now = Runtime.now,

	choice    = Op.choice,
	guard     = Op.guard,
	with_nack = Op.with_nack,
	always    = Op.always,
	never     = Op.never,
	bracket   = Op.bracket,

	race           = Op.race,
	first_ready    = Op.first_ready,
	named_choice   = Op.named_choice,
	boolean_choice = Op.boolean_choice,

	-- Scope utilities re-exported
	run_scope                  = Scope.run, -- now returns: st, rep, ...
	run_scope_op               = Scope.run_op, -- now yields: st, rep, ...
	set_unscoped_error_handler = Scope.set_unscoped_error_handler,
	current_scope              = Scope.current,
}
