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

---@class UARTOpenOpts
---@field read boolean
---@field write boolean
local UARTOpenOpts = {}
UARTOpenOpts.__index = UARTOpenOpts

---Create a new UARTOpenOpts.
---At least one of read or write must be true.
---@param read boolean
---@param write boolean
---@return UARTOpenOpts?
---@return string error
function new.UARTOpenOpts(read, write)
    if type(read) ~= 'boolean' or type(write) ~= 'boolean' then
        return nil, "read and write must be booleans"
    end
    if not read and not write then
        return nil, "at least one of read or write must be true"
    end
    return setmetatable({
        read  = read,
        write = write,
    }, UARTOpenOpts), ""
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
---@field ns string
---@field key string
local ControlStoreGetOpts = {}
ControlStoreGetOpts.__index = ControlStoreGetOpts

function new.ControlStoreGetOpts(ns, key)
    if type(ns) ~= 'string' or ns == '' then return nil, 'invalid ns' end
    if type(key) ~= 'string' or key == '' then return nil, 'invalid key' end
    return setmetatable({ ns = ns, key = key }, ControlStoreGetOpts), ''
end

---@class ControlStorePutOpts
---@field ns string
---@field key string
---@field value table
local ControlStorePutOpts = {}
ControlStorePutOpts.__index = ControlStorePutOpts

function new.ControlStorePutOpts(ns, key, value)
    if type(ns) ~= 'string' or ns == '' then return nil, 'invalid ns' end
    if type(key) ~= 'string' or key == '' then return nil, 'invalid key' end
    if type(value) ~= 'table' then return nil, 'invalid value' end
    return setmetatable({ ns = ns, key = key, value = value }, ControlStorePutOpts), ''
end

---@class ControlStoreDeleteOpts
---@field ns string
---@field key string
local ControlStoreDeleteOpts = {}
ControlStoreDeleteOpts.__index = ControlStoreDeleteOpts

function new.ControlStoreDeleteOpts(ns, key)
    if type(ns) ~= 'string' or ns == '' then return nil, 'invalid ns' end
    if type(key) ~= 'string' or key == '' then return nil, 'invalid key' end
    return setmetatable({ ns = ns, key = key }, ControlStoreDeleteOpts), ''
end

---@class ControlStoreListOpts
---@field ns string
local ControlStoreListOpts = {}
ControlStoreListOpts.__index = ControlStoreListOpts

function new.ControlStoreListOpts(ns)
    if type(ns) ~= 'string' or ns == '' then return nil, 'invalid ns' end
    return setmetatable({ ns = ns }, ControlStoreListOpts), ''
end

---@class ControlStoreStatusOpts
---@field verbose boolean|nil
local ControlStoreStatusOpts = {}
ControlStoreStatusOpts.__index = ControlStoreStatusOpts

function new.ControlStoreStatusOpts(verbose)
    if verbose ~= nil and type(verbose) ~= 'boolean' then return nil, 'invalid verbose' end
    return setmetatable({ verbose = verbose }, ControlStoreStatusOpts), ''
end


---@class ArtifactStoreCreateSinkOpts
---@field meta table|nil
---@field policy string|nil
local ArtifactStoreCreateSinkOpts = {}
ArtifactStoreCreateSinkOpts.__index = ArtifactStoreCreateSinkOpts

function new.ArtifactStoreCreateSinkOpts(meta, policy)
    if meta ~= nil and type(meta) ~= 'table' then return nil, 'invalid meta' end
    if policy ~= nil and type(policy) ~= 'string' then return nil, 'invalid policy' end
    return setmetatable({ meta = meta, policy = policy }, ArtifactStoreCreateSinkOpts), ''
end

---@class ArtifactStoreImportPathOpts
---@field path string
---@field meta table|nil
---@field policy string|nil
local ArtifactStoreImportPathOpts = {}
ArtifactStoreImportPathOpts.__index = ArtifactStoreImportPathOpts

function new.ArtifactStoreImportPathOpts(path, meta, policy)
    if type(path) ~= 'string' or path == '' then return nil, 'invalid path' end
    if meta ~= nil and type(meta) ~= 'table' then return nil, 'invalid meta' end
    if policy ~= nil and type(policy) ~= 'string' then return nil, 'invalid policy' end
    return setmetatable({ path = path, meta = meta, policy = policy }, ArtifactStoreImportPathOpts), ''
end

---@class ArtifactStoreImportSourceOpts
---@field source table
---@field meta table|nil
---@field policy string|nil
local ArtifactStoreImportSourceOpts = {}
ArtifactStoreImportSourceOpts.__index = ArtifactStoreImportSourceOpts

function new.ArtifactStoreImportSourceOpts(source, meta, policy)
    if type(source) ~= 'table' then return nil, 'invalid source' end
    if meta ~= nil and type(meta) ~= 'table' then return nil, 'invalid meta' end
    if policy ~= nil and type(policy) ~= 'string' then return nil, 'invalid policy' end
    return setmetatable({ source = source, meta = meta, policy = policy }, ArtifactStoreImportSourceOpts), ''
end

---@class ArtifactStoreOpenOpts
---@field artifact_ref string
local ArtifactStoreOpenOpts = {}
ArtifactStoreOpenOpts.__index = ArtifactStoreOpenOpts

function new.ArtifactStoreOpenOpts(artifact_ref)
    if type(artifact_ref) ~= 'string' or artifact_ref == '' then return nil, 'invalid artifact_ref' end
    return setmetatable({ artifact_ref = artifact_ref }, ArtifactStoreOpenOpts), ''
end

---@class ArtifactStoreDeleteOpts
---@field artifact_ref string
local ArtifactStoreDeleteOpts = {}
ArtifactStoreDeleteOpts.__index = ArtifactStoreDeleteOpts

function new.ArtifactStoreDeleteOpts(artifact_ref)
    if type(artifact_ref) ~= 'string' or artifact_ref == '' then return nil, 'invalid artifact_ref' end
    return setmetatable({ artifact_ref = artifact_ref }, ArtifactStoreDeleteOpts), ''
end

---@class ArtifactStoreStatusOpts
---@field verbose boolean|nil
local ArtifactStoreStatusOpts = {}
ArtifactStoreStatusOpts.__index = ArtifactStoreStatusOpts

function new.ArtifactStoreStatusOpts(verbose)
    if verbose ~= nil and type(verbose) ~= 'boolean' then return nil, 'invalid verbose' end
    return setmetatable({ verbose = verbose }, ArtifactStoreStatusOpts), ''
end

---@class SignatureVerifyEd25519Opts
---@field pubkey_pem string
---@field message string
---@field signature string
local SignatureVerifyEd25519Opts = {}
SignatureVerifyEd25519Opts.__index = SignatureVerifyEd25519Opts

function new.SignatureVerifyEd25519Opts(pubkey_pem, message, signature)
    if type(pubkey_pem) ~= 'string' or pubkey_pem == '' then return nil, 'invalid public_key' end
    if type(message) ~= 'string' then return nil, 'invalid message' end
    if type(signature) ~= 'string' or signature == '' then return nil, 'invalid signature' end
    return setmetatable({ pubkey_pem = pubkey_pem, message = message, signature = signature }, SignatureVerifyEd25519Opts), ''
end


---@class UpdaterPrepareOpts
---@field target string|nil
---@field metadata table|nil
local UpdaterPrepareOpts = {}
UpdaterPrepareOpts.__index = UpdaterPrepareOpts

---Create a new UpdaterPrepareOpts.
---@param target string|nil
---@param metadata table|nil
---@return UpdaterPrepareOpts?
---@return string error
function new.UpdaterPrepareOpts(target, metadata)
    if target ~= nil and (type(target) ~= 'string' or target == '') then
        return nil, "invalid target"
    end
    if metadata ~= nil and type(metadata) ~= 'table' then
        return nil, "invalid metadata"
    end
    return setmetatable({ target = target, metadata = metadata }, UpdaterPrepareOpts), ""
end

---@class UpdaterStageOpts
---@field artifact_ref string
---@field metadata table|nil
---@field expected_image_id string|nil
local UpdaterStageOpts = {}
UpdaterStageOpts.__index = UpdaterStageOpts

---Create a new UpdaterStageOpts.
---@param artifact_ref string
---@param metadata table|nil
---@param expected_image_id string|nil
---@return UpdaterStageOpts?
---@return string error
function new.UpdaterStageOpts(artifact_ref, metadata, expected_image_id)
    if type(artifact_ref) ~= 'string' or artifact_ref == '' then
        return nil, "invalid artifact_ref"
    end
    if metadata ~= nil and type(metadata) ~= 'table' then
        return nil, "invalid metadata"
    end
    if expected_image_id ~= nil and type(expected_image_id) ~= 'string' then
        return nil, "invalid expected_image_id"
    end
    return setmetatable({ artifact_ref = artifact_ref, metadata = metadata, expected_image_id = expected_image_id }, UpdaterStageOpts), ""
end

---@class UpdaterCommitOpts
---@field mode string|nil
---@field metadata table|nil
local UpdaterCommitOpts = {}
UpdaterCommitOpts.__index = UpdaterCommitOpts

---Create a new UpdaterCommitOpts.
---@param mode string|nil
---@param metadata table|nil
---@return UpdaterCommitOpts?
---@return string error
function new.UpdaterCommitOpts(mode, metadata)
    if mode ~= nil and type(mode) ~= 'string' then
        return nil, "invalid mode"
    end
    if metadata ~= nil and type(metadata) ~= 'table' then
        return nil, "invalid metadata"
    end
    return setmetatable({ mode = mode, metadata = metadata }, UpdaterCommitOpts), ""
end

---@class UpdaterStatusOpts
---@field verbose boolean|nil
local UpdaterStatusOpts = {}
UpdaterStatusOpts.__index = UpdaterStatusOpts

---Create a new UpdaterStatusOpts.
---@param verbose boolean|nil
---@return UpdaterStatusOpts?
---@return string error
function new.UpdaterStatusOpts(verbose)
    if verbose ~= nil and type(verbose) ~= 'boolean' then
        return nil, "invalid verbose"
    end
    return setmetatable({ verbose = verbose }, UpdaterStatusOpts), ""
end

return {
    ModemGetOpts = ModemGetOpts,
    ModemConnectOpts = ModemConnectOpts,
    FilesystemReadOpts = FilesystemReadOpts,
    FilesystemWriteOpts = FilesystemWriteOpts,
    ControlStoreGetOpts = ControlStoreGetOpts,
    ControlStorePutOpts = ControlStorePutOpts,
    ControlStoreDeleteOpts = ControlStoreDeleteOpts,
    ControlStoreListOpts = ControlStoreListOpts,
    ControlStoreStatusOpts = ControlStoreStatusOpts,
    ArtifactStoreCreateSinkOpts = ArtifactStoreCreateSinkOpts,
    ArtifactStoreImportPathOpts = ArtifactStoreImportPathOpts,
    ArtifactStoreImportSourceOpts = ArtifactStoreImportSourceOpts,
    ArtifactStoreOpenOpts = ArtifactStoreOpenOpts,
    ArtifactStoreDeleteOpts = ArtifactStoreDeleteOpts,
    ArtifactStoreStatusOpts = ArtifactStoreStatusOpts,
    SignatureVerifyEd25519Opts = SignatureVerifyEd25519Opts,
    UARTOpenOpts = UARTOpenOpts,
    UARTWriteOpts = UARTWriteOpts,
    MemoryGetOpts = MemoryGetOpts,
    CpuGetOpts = CpuGetOpts,
    ThermalGetOpts = ThermalGetOpts,
    PlatformGetOpts = PlatformGetOpts,
    PowerActionOpts = PowerActionOpts,
    UpdaterPrepareOpts = UpdaterPrepareOpts,
    UpdaterStageOpts = UpdaterStageOpts,
    UpdaterCommitOpts = UpdaterCommitOpts,
    UpdaterStatusOpts = UpdaterStatusOpts,
    new = new,
}
