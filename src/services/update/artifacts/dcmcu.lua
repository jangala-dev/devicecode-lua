-- services/update/artifacts/dcmcu.lua
--
-- Strict .dcmcu v1 identity parser used by the Lua update manager before
-- admitting an MCU update job.  The MCU remains the authority for full image
-- verification; this parser extracts only the canonical job identity.

local fibers   = require 'fibers'
local cjson    = require 'cjson.safe'
local resource = require 'devicecode.support.resource'

local M = {}

local MAGIC = 'DCMCUIMG'
local FORMAT_VERSION = 1
local MIN_HEADER_LEN = 16
local MAX_HEADER_LEN = 4096
local MAX_MANIFEST_LEN = 1024 * 1024

local function u16le(s, i)
	local b1, b2 = s:byte(i, i + 1)
	if b1 == nil or b2 == nil then return nil end
	return b1 + b2 * 0x100
end

local function u32le(s, i)
	local b1, b2, b3, b4 = s:byte(i, i + 3)
	if b1 == nil or b2 == nil or b3 == nil or b4 == nil then return nil end
	return b1 + b2 * 0x100 + b3 * 0x10000 + b4 * 0x1000000
end

local function non_empty_string(v)
	return type(v) == 'string' and v ~= ''
end

local function is_lower_hex_64(v)
	return type(v) == 'string' and #v == 64 and v:match('^[0-9a-f]+$') ~= nil
end

local function read_exact(source, n)
	local parts = {}
	local have = 0
	while have < n do
		local chunk, err = fibers.perform(source:read_chunk_op(n - have))
		if err ~= nil then return nil, err end
		if chunk == nil then return nil, 'dcmcu_unexpected_eof' end
		if type(chunk) ~= 'string' then return nil, 'dcmcu_source_chunk_not_string' end
		if chunk == '' then return nil, 'dcmcu_empty_source_chunk' end
		parts[#parts + 1] = chunk
		have = have + #chunk
	end
	return table.concat(parts), nil
end

local function manifest_identity(manifest)
	if type(manifest) ~= 'table' then return nil, 'dcmcu_manifest_not_object' end
	if manifest.schema ~= 1 then return nil, 'dcmcu_manifest_schema_unsupported' end
	if manifest.component ~= 'mcu' then return nil, 'dcmcu_component_not_mcu' end

	local build = manifest.build
	if type(build) ~= 'table' then return nil, 'dcmcu_build_required' end
	if not non_empty_string(build.image_id) then return nil, 'dcmcu_image_id_required' end

	local payload = manifest.payload
	if type(payload) ~= 'table' then return nil, 'dcmcu_payload_required' end
	if type(payload.length) ~= 'number' or payload.length < 0 or payload.length ~= math.floor(payload.length) then
		return nil, 'dcmcu_payload_length_invalid'
	end
	if not is_lower_hex_64(payload.sha256) then return nil, 'dcmcu_payload_sha256_invalid' end

	return {
		format = 'dcmcu-v1',
		component = 'mcu',
		image_id = build.image_id,
		version = non_empty_string(build.version) and build.version or nil,
		build_id = non_empty_string(build.build_id) and build.build_id or nil,
		payload_length = payload.length,
		payload_sha256 = payload.sha256,
	}, nil
end

function M.identity_from_header_bytes(raw)
	if type(raw) ~= 'string' then return nil, 'dcmcu_bytes_required' end
	if #raw < MIN_HEADER_LEN then return nil, 'dcmcu_header_too_short' end
	if raw:sub(1, #MAGIC) ~= MAGIC then return nil, 'dcmcu_bad_magic' end

	local version = u16le(raw, 9)
	local header_len = u16le(raw, 11)
	local manifest_len = u32le(raw, 13)
	if version ~= FORMAT_VERSION then return nil, 'dcmcu_version_unsupported' end
	if type(header_len) ~= 'number' or header_len < MIN_HEADER_LEN or header_len > MAX_HEADER_LEN then
		return nil, 'dcmcu_header_len_invalid'
	end
	if type(manifest_len) ~= 'number' or manifest_len <= 0 or manifest_len > MAX_MANIFEST_LEN then
		return nil, 'dcmcu_manifest_len_invalid'
	end
	if #raw < header_len + manifest_len then return nil, 'dcmcu_manifest_incomplete' end

	local manifest_raw = raw:sub(header_len + 1, header_len + manifest_len)
	local manifest, err = cjson.decode(manifest_raw)
	if manifest == nil then return nil, 'dcmcu_manifest_json_invalid:' .. tostring(err or 'decode_failed') end
	return manifest_identity(manifest)
end

function M.identity_from_source_op(source)
	return fibers.run_scope_op(function (scope)
		if type(source) ~= 'table' or type(source.read_chunk_op) ~= 'function' then
			return nil, 'dcmcu_source_required'
		end
		scope:finally(function (_, status, primary)
			resource.terminate_checked(source, primary or status or 'dcmcu source closed', 'dcmcu source cleanup failed')
		end)

		local header, herr = read_exact(source, MIN_HEADER_LEN)
		if not header then return nil, herr end
		local header_len = u16le(header, 11)
		local manifest_len = u32le(header, 13)
		if type(header_len) ~= 'number' or type(manifest_len) ~= 'number' then
			return nil, 'dcmcu_header_invalid'
		end
		if header_len < MIN_HEADER_LEN or header_len > MAX_HEADER_LEN then
			return nil, 'dcmcu_header_len_invalid'
		end
		if manifest_len <= 0 or manifest_len > MAX_MANIFEST_LEN then
			return nil, 'dcmcu_manifest_len_invalid'
		end

		local rest_len = header_len + manifest_len - #header
		local rest, rerr = read_exact(source, rest_len)
		if not rest then return nil, rerr end
		return M.identity_from_header_bytes(header .. rest)
	end):wrap(function (st, report, identity, err)
		if st == 'ok' then return identity, err end
		return nil, identity or err or report or st or 'dcmcu_identity_failed'
	end)
end

M._test = {
	u16le = u16le,
	u32le = u32le,
	manifest_identity = manifest_identity,
}

return M
