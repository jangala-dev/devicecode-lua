local fibers    = require 'fibers'
local op        = require 'fibers.op'
local runfibers = require 'tests.support.run_fibers'

local backend_mod = require 'services.hal.drivers.signature_verify_openssl'

local T = {}

local function make_stream(path, cfg)
	cfg = cfg or {}
	cfg.writes = cfg.writes or {}
	cfg.closed = 0

	local stream = {}

	function stream:filename()
		return path
	end

	function stream:write_op(data)
		if cfg.write_err then
			return op.always(nil, cfg.write_err)
		end
		cfg.writes[#cfg.writes + 1] = data
		return op.always(#data, nil)
	end

	function stream:flush_op()
		if cfg.flush_err then
			return op.always(nil, cfg.flush_err)
		end
		return op.always(true, nil)
	end

	function stream:close_op()
		cfg.closed = cfg.closed + 1
		return op.always(true, nil)
	end

	function stream:terminate(_reason)
		cfg.closed = cfg.closed + 1
		return true, nil
	end

	return stream, cfg
end

local function make_fake_file(tmp_specs)
	local i = 0

	return {
		tmpfile = function(_perms, _tmpdir)
			i = i + 1
			local spec = tmp_specs[i]
			if not spec then
				return nil, 'unexpected tmpfile request #' .. tostring(i)
			end
			if spec.err then
				return nil, spec.err
			end

			local stream, state = make_stream('/tmp/sv-' .. tostring(i), spec)
			spec._state = state
			return stream
		end,
	}
end

local function make_fake_exec(result, capture)
	capture = capture or {}

	return {
		command = function(...)
			local args = { ... }
			if type(args[1]) == 'table' and args[2] == nil then
				capture.spec = args[1]
				capture.argv = args[1]
			else
				capture.argv = args
			end

			return {
				combined_output_op = function()
					return op.always(
						result.out,
						result.st,
						result.code,
						result.sig,
						result.err
					)
				end,
			}
		end,
	}
end

function T.verify_ed25519_rejects_invalid_inputs_before_touching_file_or_exec()
	runfibers.run(function()
		local calls = { tmpfile = 0, command = 0 }

		local driver = backend_mod.new({
			file = {
				tmpfile = function()
					calls.tmpfile = calls.tmpfile + 1
					return nil, 'should not be called'
				end,
			},
			exec = {
				command = function()
					calls.command = calls.command + 1
					return {
						combined_output_op = function()
							return op.always('', 'exited', 0, nil, nil)
						end,
					}
				end,
			},
			tmpdir = '/tmp',
		})

		local ok, err = fibers.perform(driver:verify_ed25519_op('', 'msg', 'sig'))
		assert(ok == false)
		assert(err == 'public_key_required')
		assert(calls.tmpfile == 0)
		assert(calls.command == 0)
	end)
end

function T.verify_ed25519_success_writes_all_inputs_and_invokes_openssl()
	runfibers.run(function()
		local specs = {
			{},
			{},
			{},
		}
		local capture = {}

		local driver = backend_mod.new({
			file = make_fake_file(specs),
			exec = make_fake_exec({
				out  = 'Signature Verified Successfully\n',
				st   = 'exited',
				code = 0,
				sig  = nil,
				err  = nil,
			}, capture),
			tmpdir = '/tmp',
		})

		local ok, err = fibers.perform(driver:verify_ed25519_op(
			'PUBKEY',
			'MESSAGE',
			'SIGNATURE'
		))

		assert(ok == true)
		assert(err == nil)

		assert(specs[1]._state.writes[1] == 'PUBKEY')
		assert(specs[2]._state.writes[1] == 'MESSAGE')
		assert(specs[3]._state.writes[1] == 'SIGNATURE')

		assert(specs[1]._state.closed == 1)
		assert(specs[2]._state.closed == 1)
		assert(specs[3]._state.closed == 1)

		assert(capture.argv[1] == 'openssl')
		assert(capture.argv[2] == 'pkeyutl')
		assert(capture.argv[3] == '-verify')
		assert(capture.argv[4] == '-pubin')
		assert(capture.argv[5] == '-inkey')
		assert(capture.argv[6] == '/tmp/sv-1')
		assert(capture.argv[7] == '-sigfile')
		assert(capture.argv[8] == '/tmp/sv-3')
		assert(capture.argv[9] == '-in')
		assert(capture.argv[10] == '/tmp/sv-2')
		assert(capture.argv[11] == '-rawin')
		assert(capture.spec.stdin == 'null')
		assert(capture.spec.stdout == 'pipe')
		assert(capture.spec.stderr == 'stdout')
	end)
end

function T.verify_ed25519_classifies_bad_signature()
	runfibers.run(function()
		local driver = backend_mod.new({
			file = make_fake_file({ {}, {}, {} }),
			exec = make_fake_exec({
				out  = 'Signature Verification Failure\n',
				st   = 'exited',
				code = 1,
				sig  = nil,
				err  = nil,
			}),
			tmpdir = '/tmp',
		})

		local ok, err = fibers.perform(driver:verify_ed25519_op(
			'PUBKEY',
			'MESSAGE',
			'SIGNATURE'
		))

		assert(ok == false)
		assert(err == 'signature_verify_failed')
	end)
end

function T.verify_ed25519_surfaces_write_failure_with_labelled_error()
	runfibers.run(function()
		local specs = {
			{},
			{ write_err = 'diskfull' },
			{},
		}

		local driver = backend_mod.new({
			file = make_fake_file(specs),
			exec = make_fake_exec({
				out  = '',
				st   = 'exited',
				code = 0,
				sig  = nil,
				err  = nil,
			}),
			tmpdir = '/tmp',
		})

		local ok, err = fibers.perform(driver:verify_ed25519_op(
			'PUBKEY',
			'MESSAGE',
			'SIGNATURE'
		))

		assert(ok == false)
		assert(err == 'message_write_failed:diskfull')
	end)
end

return T
