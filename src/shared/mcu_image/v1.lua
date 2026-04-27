-- shared/mcu_image/v1.lua
--
-- Inspector for the Big Box signed MCU image container, format version 1.
-- This module performs CM5-side preflight checks that do not require OS
-- access.  Ed25519 verification is delegated to an optional verifier object;
-- the MCU remains the authoritative verifier/stager for release safety.

local cjson = require 'cjson.safe'
local blob_source = require 'shared.blob_source'

local M = {}

local HEADER_LEN = 32
local MAGIC = 'DCMCUIMG'

local function u16le(s, i)
	local b1, b2 = s:byte(i, i + 1)
	if not b1 or not b2 then return nil end
	return b1 + b2 * 256
end

local function u32le(s, i)
	local b1, b2, b3, b4 = s:byte(i, i + 3)
	if not b1 or not b2 or not b3 or not b4 then return nil end
	return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

local function read_all(source)
	local src, err = blob_source.normalise_source(source)
	if not src then return nil, err end
	local parts, off = {}, 0
	while true do
		local chunk, rerr = src:read_chunk(off, 64 * 1024)
		if chunk == nil then return nil, rerr or 'read_failed' end
		if chunk == '' then break end
		parts[#parts + 1] = chunk
		off = off + #chunk
	end
	return table.concat(parts), nil
end

local function is_hex64(s)
	if type(s) ~= 'string' or #s ~= 64 then return false end
	return s:match('^[0-9a-f]+$') ~= nil
end

local function require_string(t, key, where)
	local v = t and t[key]
	if type(v) ~= 'string' or v == '' then return nil, where .. '.' .. key .. '_required' end
	return v, nil
end

local function validate_manifest(m, opts)
	if type(m) ~= 'table' then return nil, 'manifest_not_object' end
	if m.schema ~= 1 then return nil, 'manifest_schema_unsupported' end
	if m.component ~= 'mcu' then return nil, 'manifest_component_not_mcu' end
	if type(m.target) ~= 'table' then return nil, 'manifest_target_required' end
	if type(m.build) ~= 'table' then return nil, 'manifest_build_required' end
	if type(m.payload) ~= 'table' then return nil, 'manifest_payload_required' end
	if type(m.signing) ~= 'table' then return nil, 'manifest_signing_required' end

	local _, err
	_, err = require_string(m.target, 'product_family', 'target'); if err then return nil, err end
	_, err = require_string(m.target, 'hardware_profile', 'target'); if err then return nil, err end
	_, err = require_string(m.target, 'mcu_board_family', 'target'); if err then return nil, err end
	_, err = require_string(m.build, 'version', 'build'); if err then return nil, err end
	_, err = require_string(m.build, 'build_id', 'build'); if err then return nil, err end
	_, err = require_string(m.build, 'image_id', 'build'); if err then return nil, err end
	if m.payload.format ~= 'raw-bin' then return nil, 'payload_format_unsupported' end
	if type(m.payload.length) ~= 'number' or m.payload.length <= 0 or m.payload.length % 1 ~= 0 then return nil, 'payload_length_invalid' end
	if not is_hex64(m.payload.sha256) then return nil, 'payload_sha256_invalid' end
	_, err = require_string(m.signing, 'key_id', 'signing'); if err then return nil, err end
	if m.signing.sig_alg ~= 'ed25519' then return nil, 'signature_algorithm_unsupported' end

	local expected = opts and opts.target or nil
	if type(expected) == 'table' then
		for _, k in ipairs({ 'product_family', 'hardware_profile', 'mcu_board_family' }) do
			if expected[k] ~= nil and m.target[k] ~= expected[k] then
				return nil, 'target_' .. k .. '_mismatch'
			end
		end
	end

	return true, nil
end

function M.inspect_bytes(data, opts)
	opts = opts or {}
	if type(data) ~= 'string' then return nil, 'data_required' end
	if #data < HEADER_LEN then return nil, 'short_header' end

	local magic = data:sub(1, 8)
	local format_version = u16le(data, 9)
	local header_len = u16le(data, 11)
	local manifest_len = u32le(data, 13)
	local signature_len = u32le(data, 17)
	local payload_len = u32le(data, 21)
	local flags = u32le(data, 25)
	local reserved = u32le(data, 29)

	if magic ~= MAGIC then return nil, 'bad_magic' end
	if format_version ~= 1 then return nil, 'unsupported_format_version' end
	if header_len ~= HEADER_LEN then return nil, 'bad_header_len' end
	if type(manifest_len) ~= 'number' or manifest_len <= 0 then return nil, 'bad_manifest_len' end
	if signature_len ~= 64 then return nil, 'bad_signature_len' end
	if type(payload_len) ~= 'number' or payload_len <= 0 then return nil, 'bad_payload_len' end
	if flags ~= 0 then return nil, 'bad_flags' end
	if reserved ~= 0 then return nil, 'bad_reserved' end

	local manifest_start = header_len + 1
	local manifest_end = manifest_start + manifest_len - 1
	local sig_start = manifest_end + 1
	local sig_end = sig_start + signature_len - 1
	local payload_start = sig_end + 1
	local payload_end = payload_start + payload_len - 1
	if payload_end > #data then return nil, 'layout_exceeds_file_length' end

	local manifest_bytes = data:sub(manifest_start, manifest_end)
	local signature = data:sub(sig_start, sig_end)
	local manifest, jerr = cjson.decode(manifest_bytes)
	if not manifest then return nil, 'manifest_json_invalid:' .. tostring(jerr) end

	local ok, merr = validate_manifest(manifest, opts)
	if not ok then return nil, merr end
	if manifest.payload.length ~= payload_len then return nil, 'payload_length_mismatch' end

	local verifier = opts.verifier
	if verifier and type(verifier.verify_message) == 'function' then
		local vok, verr = verifier:verify_message({
			key_id = manifest.signing.key_id,
			alg = manifest.signing.sig_alg,
			message = manifest_bytes,
			signature = signature,
			manifest = manifest,
		})
		if not vok then return nil, verr or 'signature_verify_failed' end
	elseif opts.require_signature == true then
		return nil, 'signature_verifier_unavailable'
	end

	return {
		format = 'dcmcu-v1',
		header = {
			manifest_len = manifest_len,
			signature_len = signature_len,
			payload_len = payload_len,
		},
		manifest = manifest,
		build = manifest.build,
		target = manifest.target,
		payload = manifest.payload,
		signing = manifest.signing,
		payload_offset = payload_start - 1,
		payload_len = payload_len,
	}, nil
end

function M.inspect_source(source, opts)
	local data, err = read_all(source)
	if not data then return nil, err end
	return M.inspect_bytes(data, opts)
end

return M
