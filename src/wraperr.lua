-- module wraperr - inspired by golang's errors

local wraperr = {}
wraperr.__index = wraperr

function wraperr:__tostring()
    return tostring(self.content) .. (self.wrapped and ": "..tostring(self.wrapped) or "")
end

function wraperr:wrap(err)
    self.wrapped = err
    return self
end

function wraperr:unwrap()
    return self.wrapped
end

function wraperr:is(err)
    -- Check if the current error object is the same as the given error
    if self == err then
        return true
    end
    -- If there is a wrapped error, recursively check it
    if self.wrapped then
        return self.wrapped:is(err)
    end
    -- If no match found, return false
    return false
end

function wraperr:as(target_err)
    -- Check if the current error's metatable matches the target metatable
    if getmetatable(self) == getmetatable(target_err) then
        return true, self
    elseif self.wrapped then
        -- Recursively check the wrapped error
        return self.wrapped:as(target_err)
    end

    return false, nil
end

local function custom(to_string)
    local mt = {
        __tostring = to_string,
        __index = wraperr,  -- Allows for using wraperr methods like wrap, unwrap, etc.
    }
    mt.new = function(error_tab)
        setmetatable(error_tab, mt)
        return error_tab
    end
    return mt
end

local function new(content)
    return setmetatable({content = content}, wraperr)
end

return {
    new = new,
    custom = custom,
}