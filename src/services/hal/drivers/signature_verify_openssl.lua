local fibers = require 'fibers'
local file = require 'fibers.io.file'
local exec = require 'fibers.io.exec'

local perform = fibers.perform

local M = {}
local Driver = {}
Driver.__index = Driver

local function close_best_effort(stream)
	if not stream then return end
	pcall(function() stream:close() end)
end

local function tmpfile_path(stream)
	if stream and type(stream.filename) == 'function' then
		return stream:filename()
	end
	return nil
end

local function write_temp_bytes(self, label, data)
	local stream, err = self.file.tmpfile(384, self.tmpdir)
	if not stream then return nil, 'tmpfile_failed:' .. tostring(err) end
	local path = tmpfile_path(stream)
	if type(path) ~= 'string' or path == '' then
		close_best_effort(stream)
		return nil, 'tmpfile_path_unavailable'
	end
	local n, werr = stream:write(data)
	if n == nil then
		close_best_effort(stream)
		return nil, label .. '_write_failed:' .. tostring(werr or 'write_failed')
	end
	local ok, ferr = stream:flush()
	if ok == nil then
		close_best_effort(stream)
		return nil, label .. '_flush_failed:' .. tostring(ferr or 'flush_failed')
	end
	return { stream = stream, path = path }, nil
end

function Driver:verify_ed25519(pubkey_pem, message, signature)
	if type(pubkey_pem) ~= 'string' or pubkey_pem == '' then return nil, 'public_key_required' end
	if type(message) ~= 'string' then return nil, 'message_required' end
	if type(signature) ~= 'string' or signature == '' then return nil, 'signature_required' end

	local pubf, perr = write_temp_bytes(self, 'pubkey', pubkey_pem)
	if not pubf then return nil, perr end
	local msgf, merr = write_temp_bytes(self, 'message', message)
	if not msgf then close_best_effort(pubf.stream); return nil, merr end
	local sigf, serr = write_temp_bytes(self, 'signature', signature)
	if not sigf then close_best_effort(pubf.stream); close_best_effort(msgf.stream); return nil, serr end

	local out, st, code, sig, cerr
	local cmd = self.exec.command('openssl', 'pkeyutl', '-verify', '-pubin', '-inkey', pubf.path, '-sigfile', sigf.path, '-in', msgf.path, '-rawin')
	out, st, code, sig, cerr = perform(cmd:combined_output_op())

	close_best_effort(pubf.stream)
	close_best_effort(msgf.stream)
	close_best_effort(sigf.stream)

	if st == 'exited' and code == 0 then
		return true, nil
	end

	local detail = tostring(cerr or out or '')
	local low = detail:lower()
	if st == 'exited' and code == 1 and (low:find('signature verification failure', 1, true) or low:find('signature verify failure', 1, true) or low:find('verification failure', 1, true)) then
		return false, 'signature_verify_failed'
	end
	if st == 'signalled' then
		return nil, 'openssl_signalled:' .. tostring(sig)
	end
	if st == 'exited' then
		if detail == '' then detail = 'exit_' .. tostring(code) end
		return nil, 'openssl_verify_failed:' .. detail
	end
	if detail == '' then detail = tostring(st or 'unknown') end
	return nil, 'openssl_verify_failed:' .. detail
end

function M.new(opts)
	opts = opts or {}
	return setmetatable({
		file = opts.file or file,
		exec = opts.exec or exec,
		tmpdir = opts.tmpdir or os.getenv('TMPDIR') or '/tmp',
	}, Driver)
end

return M
