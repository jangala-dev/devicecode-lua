local new = {}

---@class ModemGetOpts
---@field field string
---@field timescale? number
local ModemGetOpts = {}
ModemGetOpts.__index = ModemGetOpts

---Create a new ModemGetOpts.
---@param field string
---@param timescale? number
---@return ModemGetOpts?
---@return string error
function new.ModemGetOpts(field, timescale)
    if type(field) ~= 'string' or field == '' then
        return nil, "invalid field"
    end

    if timescale ~= nil and (type(timescale) ~= 'number' or timescale < 0) then
        return nil, "invalid timescale"
    end

    return setmetatable({
        field = field,
        timescale = timescale,
    }, ModemGetOpts), ""
end

---@class ModemConnectOpts
---@field connection_string string
local ModemConnectOpts = {}
ModemConnectOpts.__index = ModemConnectOpts

---Create a new ModemConnectOpts.
---@param connection_string string
---@return ModemConnectOpts?
---@return string error
function new.ModemConnectOpts(connection_string)
    if type(connection_string) ~= 'string' or connection_string == '' then
        return nil, "invalid connection string"
    end
    return setmetatable({
        connection_string = connection_string,
    }, ModemConnectOpts), ""
end

---@class ModemSignalUpdateOpts
---@field frequency number
local ModemSignalUpdateOpts = {}
ModemSignalUpdateOpts.__index = ModemSignalUpdateOpts

---Create a new ModemSignalUpdateOpts.
---@param frequency number
---@return ModemSignalUpdateOpts?
---@return string error
function new.ModemSignalUpdateOpts(frequency)
    if type(frequency) ~= 'number' or frequency <= 0 then
        return nil, "invalid frequency"
    end
    return setmetatable({
        frequency = frequency,
    }, ModemSignalUpdateOpts), ""
end

---@class FilesystemReadOpts
---@field filename string
local FilesystemReadOpts = {}
FilesystemReadOpts.__index = FilesystemReadOpts

--- Validate that a filename contains no path separators or .. segments
---@param filename string
---@return boolean valid
---@return string? error
local function validate_filename(filename)
    if type(filename) ~= 'string' or filename == '' then
        return false, "filename must be a non-empty string"
    end

    if filename:find('/') or filename:find('\\') then
        return false, "filename cannot contain path separators"
    end

    if filename == '..' or filename:find('^%.%.') or filename:find('%.%.') then
        return false, "filename cannot contain .. segments"
    end

    return true, nil
end

---Create a new FilesystemReadOpts
---@param filename string
---@return FilesystemReadOpts?
---@return string error
function new.FilesystemReadOpts(filename)
    local valid, err = validate_filename(filename)
    if not valid then
        return nil, err
    end
    return setmetatable({
        filename = filename,
    }, FilesystemReadOpts), ""
end

---@class FilesystemWriteOpts
---@field filename string
---@field data string
local FilesystemWriteOpts = {}
FilesystemWriteOpts.__index = FilesystemWriteOpts

---Create a new FilesystemWriteOpts
---@param filename string
---@param data string
---@return FilesystemWriteOpts?
---@return string error
function new.FilesystemWriteOpts(filename, data)
    local valid, err = validate_filename(filename)
    if not valid then
        return nil, err
    end
    if type(data) ~= 'string' then
        return nil, "invalid data"
    end
    return setmetatable({
        filename = filename,
        data = data,
    }, FilesystemWriteOpts), ""
end

----------------------------------------------------------------------
-- UART
----------------------------------------------------------------------

---@class UARTOpenOpts
local UARTOpenOpts = {}
UARTOpenOpts.__index = UARTOpenOpts

---@param opts table|nil
---@return UARTOpenOpts?|nil
---@return string
function new.UARTOpenOpts(opts)
    if opts ~= nil and type(opts) ~= 'table' then
        return nil, 'invalid uart open opts'
    end

    opts = opts or {}

    -- Deliberately empty for now.
    -- On current OpenWrt targets UART line settings are assumed to come from
    -- platform/devicetree configuration. Runtime termios configuration can be
    -- added later without changing the capability surface.
    for k in pairs(opts) do
        return nil, 'unsupported uart open option: ' .. tostring(k)
    end

    return setmetatable({}, UARTOpenOpts), ''
end

---@class UARTWriteOpts
---@field data string
local UARTWriteOpts = {}
UARTWriteOpts.__index = UARTWriteOpts

---Create a new UARTWriteOpts.
---@param data string
---@return UARTWriteOpts?
---@return string error
function new.UARTWriteOpts(data)
    if type(data) ~= 'string' or data == '' then
        return nil, "data must be a non-empty string"
    end
    return setmetatable({
        data = data,
    }, UARTWriteOpts), ""
end

---@class MemoryGetOpts
---@field field string
---@field max_age number
local MemoryGetOpts = {}
MemoryGetOpts.__index = MemoryGetOpts

---Create a new MemoryGetOpts.
---@param field string
---@param max_age number
---@return MemoryGetOpts?
---@return string error
function new.MemoryGetOpts(field, max_age)
    if type(field) ~= 'string' or field == '' then
        return nil, "invalid field"
    end
    if type(max_age) ~= 'number' or max_age < 0 then
        return nil, "invalid max_age"
    end
    return setmetatable({ field = field, max_age = max_age }, MemoryGetOpts), ""
end

---@class CpuGetOpts
---@field field string
---@field max_age number
local CpuGetOpts = {}
CpuGetOpts.__index = CpuGetOpts

---Create a new CpuGetOpts.
---@param field string
---@param max_age number
---@return CpuGetOpts?
---@return string error
function new.CpuGetOpts(field, max_age)
    if type(field) ~= 'string' or field == '' then
        return nil, "invalid field"
    end
    if type(max_age) ~= 'number' or max_age < 0 then
        return nil, "invalid max_age"
    end
    return setmetatable({ field = field, max_age = max_age }, CpuGetOpts), ""
end

---@class ThermalGetOpts
---@field max_age number
local ThermalGetOpts = {}
ThermalGetOpts.__index = ThermalGetOpts

---Create a new ThermalGetOpts.
---@param max_age number
---@return ThermalGetOpts?
---@return string error
function new.ThermalGetOpts(max_age)
    if type(max_age) ~= 'number' or max_age < 0 then
        return nil, "invalid max_age"
    end
    return setmetatable({ max_age = max_age }, ThermalGetOpts), ""
end

---@class PlatformGetOpts
---@field field string
---@field max_age number
local PlatformGetOpts = {}
PlatformGetOpts.__index = PlatformGetOpts

---Create a new PlatformGetOpts.
---@param field string
---@param max_age number
---@return PlatformGetOpts?
---@return string error
function new.PlatformGetOpts(field, max_age)
    if type(field) ~= 'string' or field == '' then
        return nil, "invalid field"
    end
    if type(max_age) ~= 'number' or max_age < 0 then
        return nil, "invalid max_age"
    end
    return setmetatable({ field = field, max_age = max_age }, PlatformGetOpts), ""
end

---@class PowerActionOpts
---@field delay? number
local PowerActionOpts = {}
PowerActionOpts.__index = PowerActionOpts

---Create a new PowerActionOpts.
---@param delay? number
---@return PowerActionOpts?
---@return string error
function new.PowerActionOpts(delay)
    if delay ~= nil and (type(delay) ~= 'number' or delay < 0) then
        return nil, "invalid delay"
    end
    return setmetatable({ delay = delay }, PowerActionOpts), ""
end

---@class ControlStoreGetOpts
---@field key string
local ControlStoreGetOpts = {}
ControlStoreGetOpts.__index = ControlStoreGetOpts

---@class ControlStorePutOpts
---@field key string
---@field data string
local ControlStorePutOpts = {}
ControlStorePutOpts.__index = ControlStorePutOpts

---@class ControlStoreDeleteOpts
---@field key string
local ControlStoreDeleteOpts = {}
ControlStoreDeleteOpts.__index = ControlStoreDeleteOpts

---@class ControlStoreListOpts
---@field prefix string|nil
local ControlStoreListOpts = {}
ControlStoreListOpts.__index = ControlStoreListOpts

local function valid_store_key(key)
	return type(key) == 'string'
		and key ~= ''
		and not key:find('[/\\]', 1)
		and key:match('^[%w%._%-]+$') ~= nil
end

---@param key string
---@return ControlStoreGetOpts?|nil
---@return string
function new.ControlStoreGetOpts(key)
	if not valid_store_key(key) then
		return nil, 'invalid key'
	end
	return setmetatable({ key = key }, ControlStoreGetOpts), ''
end

---@param key string
---@param data string
---@return ControlStorePutOpts?|nil
---@return string
function new.ControlStorePutOpts(key, data)
	if not valid_store_key(key) then
		return nil, 'invalid key'
	end
	if type(data) ~= 'string' then
		return nil, 'data must be a string'
	end
	return setmetatable({ key = key, data = data }, ControlStorePutOpts), ''
end

---@param key string
---@return ControlStoreDeleteOpts?|nil
---@return string
function new.ControlStoreDeleteOpts(key)
	if not valid_store_key(key) then
		return nil, 'invalid key'
	end
	return setmetatable({ key = key }, ControlStoreDeleteOpts), ''
end

---@param prefix string|nil
---@return ControlStoreListOpts?|nil
---@return string
function new.ControlStoreListOpts(prefix)
	if prefix ~= nil and type(prefix) ~= 'string' then
		return nil, 'invalid prefix'
	end
	return setmetatable({ prefix = prefix }, ControlStoreListOpts), ''
end

---@class SignatureVerifyEd25519Opts
---@field pubkey_pem string
---@field message string
---@field signature string
local SignatureVerifyEd25519Opts = {}
SignatureVerifyEd25519Opts.__index = SignatureVerifyEd25519Opts

---@param pubkey_pem string
---@param message string
---@param signature string
---@return SignatureVerifyEd25519Opts?
---@return string
function new.SignatureVerifyEd25519Opts(pubkey_pem, message, signature)
	if type(pubkey_pem) ~= 'string' or pubkey_pem == '' then
		return nil, 'invalid pubkey_pem'
	end
	if type(message) ~= 'string' then
		return nil, 'invalid message'
	end
	if type(signature) ~= 'string' or signature == '' then
		return nil, 'invalid signature'
	end

	return setmetatable({
		pubkey_pem = pubkey_pem,
		message    = message,
		signature  = signature,
	}, SignatureVerifyEd25519Opts), ''
end

----------------------------------------------------------------------
-- Artifact store
----------------------------------------------------------------------

---@class ArtifactStoreCreateSinkOpts
---@field meta table
---@field policy string|nil
local ArtifactStoreCreateSinkOpts = {}
ArtifactStoreCreateSinkOpts.__index = ArtifactStoreCreateSinkOpts

---@class ArtifactStoreImportPathOpts
---@field path string
---@field meta table
---@field policy string|nil
local ArtifactStoreImportPathOpts = {}
ArtifactStoreImportPathOpts.__index = ArtifactStoreImportPathOpts

---@class ArtifactStoreImportSourceOpts
---@field source any
---@field meta table
---@field policy string|nil
local ArtifactStoreImportSourceOpts = {}
ArtifactStoreImportSourceOpts.__index = ArtifactStoreImportSourceOpts

---@class ArtifactStoreOpenOpts
---@field artifact_ref string
local ArtifactStoreOpenOpts = {}
ArtifactStoreOpenOpts.__index = ArtifactStoreOpenOpts

---@class ArtifactStoreDeleteOpts
---@field artifact_ref string
local ArtifactStoreDeleteOpts = {}
ArtifactStoreDeleteOpts.__index = ArtifactStoreDeleteOpts

---@class ArtifactStoreStatusOpts
local ArtifactStoreStatusOpts = {}
ArtifactStoreStatusOpts.__index = ArtifactStoreStatusOpts

local function valid_artifact_ref(ref)
	return type(ref) == 'string' and ref ~= '' and ref:match('^[A-Za-z0-9_.-]+$') ~= nil
end

local function valid_artifact_policy(policy)
	return policy == nil
		or policy == 'transient_only'
		or policy == 'prefer_durable'
		or policy == 'require_durable'
end

local function valid_blob_source(source)
	return type(source) == 'table'
		and type(source.read_chunk_op) == 'function'
end

---@param meta table|nil
---@param policy string|nil
---@return ArtifactStoreCreateSinkOpts?|nil
---@return string
function new.ArtifactStoreCreateSinkOpts(meta, policy)
	if meta ~= nil and type(meta) ~= 'table' then
		return nil, 'invalid meta'
	end
	if not valid_artifact_policy(policy) then
		return nil, 'invalid policy'
	end

	return setmetatable({
		meta   = meta or {},
		policy = policy,
	}, ArtifactStoreCreateSinkOpts), ''
end

---@param path string
---@param meta table|nil
---@param policy string|nil
---@return ArtifactStoreImportPathOpts?|nil
---@return string
function new.ArtifactStoreImportPathOpts(path, meta, policy)
	if type(path) ~= 'string' or path == '' then
		return nil, 'invalid path'
	end
	if meta ~= nil and type(meta) ~= 'table' then
		return nil, 'invalid meta'
	end
	if not valid_artifact_policy(policy) then
		return nil, 'invalid policy'
	end

	return setmetatable({
		path   = path,
		meta   = meta or {},
		policy = policy,
	}, ArtifactStoreImportPathOpts), ''
end

---@param source any
---@param meta table|nil
---@param policy string|nil
---@return ArtifactStoreImportSourceOpts?|nil
---@return string
function new.ArtifactStoreImportSourceOpts(source, meta, policy)
	if not valid_blob_source(source) then
		return nil, 'invalid source'
	end
	if meta ~= nil and type(meta) ~= 'table' then
		return nil, 'invalid meta'
	end
	if not valid_artifact_policy(policy) then
		return nil, 'invalid policy'
	end

	return setmetatable({
		source = source,
		meta   = meta or {},
		policy = policy,
	}, ArtifactStoreImportSourceOpts), ''
end

---@param artifact_ref string
---@return ArtifactStoreOpenOpts?|nil
---@return string
function new.ArtifactStoreOpenOpts(artifact_ref)
	if not valid_artifact_ref(artifact_ref) then
		return nil, 'invalid artifact_ref'
	end
	return setmetatable({
		artifact_ref = artifact_ref,
	}, ArtifactStoreOpenOpts), ''
end

---@param artifact_ref string
---@return ArtifactStoreDeleteOpts?|nil
---@return string
function new.ArtifactStoreDeleteOpts(artifact_ref)
	if not valid_artifact_ref(artifact_ref) then
		return nil, 'invalid artifact_ref'
	end
	return setmetatable({
		artifact_ref = artifact_ref,
	}, ArtifactStoreDeleteOpts), ''
end

---@return ArtifactStoreStatusOpts
---@return string
function new.ArtifactStoreStatusOpts()
	return setmetatable({}, ArtifactStoreStatusOpts), ''
end

----------------------------------------------------------------------
-- UART
----------------------------------------------------------------------

---@class UARTOpenOpts
local UARTOpenOpts = {}
UARTOpenOpts.__index = UARTOpenOpts

---@param opts table|nil
---@return UARTOpenOpts?|nil
---@return string
function new.UARTOpenOpts(opts)
    if opts ~= nil and type(opts) ~= 'table' then
        return nil, 'invalid uart open opts'
    end

    opts = opts or {}

    -- Deliberately empty for now.
    -- On current OpenWrt targets UART line settings are assumed to come from
    -- platform/devicetree configuration. Runtime termios configuration can be
    -- added later without changing the capability surface.
    for k in pairs(opts) do
        return nil, 'unsupported uart open option: ' .. tostring(k)
    end

    return setmetatable({}, UARTOpenOpts), ''
end

return {
    ModemGetOpts = ModemGetOpts,
    ModemConnectOpts = ModemConnectOpts,
    FilesystemReadOpts = FilesystemReadOpts,
    FilesystemWriteOpts = FilesystemWriteOpts,
    UARTOpenOpts = UARTOpenOpts,
    UARTWriteOpts = UARTWriteOpts,
    MemoryGetOpts = MemoryGetOpts,
    CpuGetOpts = CpuGetOpts,
    ThermalGetOpts = ThermalGetOpts,
    PlatformGetOpts = PlatformGetOpts,
    PowerActionOpts = PowerActionOpts,
    ControlStoreGetOpts = ControlStoreGetOpts,
    ControlStorePutOpts = ControlStorePutOpts,
    ControlStoreDeleteOpts = ControlStoreDeleteOpts,
    ControlStoreListOpts = ControlStoreListOpts,
    SignatureVerifyEd25519Opts = SignatureVerifyEd25519Opts,
    ArtifactStoreCreateSinkOpts = ArtifactStoreCreateSinkOpts,
    ArtifactStoreImportPathOpts = ArtifactStoreImportPathOpts,
    ArtifactStoreImportSourceOpts = ArtifactStoreImportSourceOpts,
    ArtifactStoreOpenOpts = ArtifactStoreOpenOpts,
    ArtifactStoreDeleteOpts = ArtifactStoreDeleteOpts,
    ArtifactStoreStatusOpts = ArtifactStoreStatusOpts,
    new = new,
}
