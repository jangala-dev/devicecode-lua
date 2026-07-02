---@module 'services.hal.drivers.signature_verify_openssl'

local fibers = require 'fibers'
local op     = require 'fibers.op'
local file   = require 'fibers.io.file'
local exec     = require 'fibers.io.exec'
local resource = require 'devicecode.support.resource'

local M = {}

---@class SignatureVerifyOpenSSL
---@field file any
---@field exec any
---@field tmpdir string
---@field backend_name string
local Driver = {}
Driver.__index = Driver

local function tmpfile_path(stream)
	if stream and type(stream.filename) == 'function' then
		return stream:filename()
	end
	return nil
end


local function classify_verify_failure(detail)
	local low = tostring(detail or ''):lower()
	return low:find('signature verification failure', 1, true) ~= nil
		or low:find('signature verify failure', 1, true) ~= nil
		or low:find('verification failure', 1, true) ~= nil
end

function Driver:verify_ed25519_op(pubkey_pem, message, signature)
	return op.guard(function ()
		if type(pubkey_pem) ~= 'string' or pubkey_pem == '' then
			return op.always(false, 'public_key_required')
		end
		if type(message) ~= 'string' then
			return op.always(false, 'message_required')
		end
		if type(signature) ~= 'string' or signature == '' then
			return op.always(false, 'signature_required')
		end

		return fibers.run_scope_op(function (scope)
			local function register_tmp(stream)
				scope:finally(function (_, status, primary)
					resource.terminate_checked(stream, primary or status or 'signature verify tmpfile closed', 'signature verify tmpfile cleanup failed')
				end)
			end

			local function write_tmp_bytes(label, data)
				-- Box the currently synchronous tmpfile creation inside one
				-- operation-owned subtree. Callers still receive a real Op.
				local stream, err = self.file.tmpfile(384, self.tmpdir)
				if not stream then
					return nil, label .. '_tmpfile_failed:' .. tostring(err)
				end

				register_tmp(stream)

				local path = tmpfile_path(stream)
				if type(path) ~= 'string' or path == '' then
					return nil, label .. '_tmpfile_path_unavailable'
				end

				local n, werr = fibers.perform(stream:write_op(data))
				if n == nil then
					return nil, label .. '_write_failed:' .. tostring(werr or 'write_failed')
				end

				local fok, ferr = fibers.perform(stream:flush_op())
				if fok == nil then
					return nil, label .. '_flush_failed:' .. tostring(ferr or 'flush_failed')
				end

				return { stream = stream, path = path }, nil
			end

			local pubf, perr = write_tmp_bytes('pubkey', pubkey_pem)
			if not pubf then
				return false, perr
			end

			local msgf, merr = write_tmp_bytes('message', message)
			if not msgf then
				return false, merr
			end

			local sigf, serr = write_tmp_bytes('signature', signature)
			if not sigf then
				return false, serr
			end

			local cmd = self.exec.command {
				'openssl',
				'pkeyutl',
				'-verify',
				'-pubin',
				'-inkey',  pubf.path,
				'-sigfile', sigf.path,
				'-in',      msgf.path,
				'-rawin',
				stdin = 'null',
				stdout = 'pipe',
				stderr = 'stdout',
			}

			local out, st, code, sig, cerr = fibers.perform(cmd:combined_output_op())
			local detail = tostring(cerr or out or '')

			if st == 'exited' and code == 0 then
				return true, nil
			end

			if st == 'exited' and code == 1 and classify_verify_failure(detail) then
				return false, 'signature_verify_failed'
			end

			if st == 'signalled' then
				return false, 'openssl_signalled:' .. tostring(sig)
			end

			if st == 'exited' then
				if detail == '' then
					detail = 'exit_' .. tostring(code)
				end
				return false, 'openssl_verify_failed:' .. detail
			end

			if detail == '' then
				detail = tostring(st or 'unknown')
			end
			return false, 'openssl_verify_failed:' .. detail
		end):wrap(function (st, rep, ok, err)
			if st ~= 'ok' then
				return false, tostring(err or rep)
			end
			return ok, err
		end)
	end)
end

function M.new(opts)
	opts = opts or {}
	return setmetatable({
		file         = opts.file or file,
		exec         = opts.exec or exec,
		tmpdir       = opts.tmpdir or os.getenv('TMPDIR') or '/tmp',
		backend_name = 'openssl-cli',
	}, Driver)
end

M.Driver = Driver
return M
