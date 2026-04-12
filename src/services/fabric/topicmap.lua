-- services/fabric/topicmap.lua
--
-- Topic pattern matching and remapping.

local M = {}

function M.match(pattern, topic)
    local plus = {}
    local hash = nil

    local pi, ti = 1, 1
    while true do
        local p = pattern[pi]
        if p == nil then
            return topic[ti] == nil, { plus = plus, hash = hash }
        end

        if p == '#' then
            local tail = {}
            while topic[ti] ~= nil do
                tail[#tail + 1] = topic[ti]
                ti = ti + 1
            end
            hash = tail
            return true, { plus = plus, hash = hash }
        end

        local tv = topic[ti]
        if tv == nil then
            return false, nil
        end

        if p == '+' then
            plus[#plus + 1] = tv
        elseif p ~= tv then
            return false, nil
        end

        pi = pi + 1
        ti = ti + 1
    end
end

function M.substitute(template, caps)
    local out = {}
    local plus_i = 1

    for i = 1, #template do
        local tok = template[i]
        if tok == '+' then
            out[#out + 1] = assert(caps.plus[plus_i], 'topicmap: missing + capture')
            plus_i = plus_i + 1
        elseif tok == '#' then
            for j = 1, #((caps.hash) or {}) do
                out[#out + 1] = caps.hash[j]
            end
        else
            out[#out + 1] = tok
        end
    end

    return out
end

function M.apply_first(rules, topic, src_key, dst_key)
    for i = 1, #(rules or {}) do
        local r = rules[i]
        local ok, caps = M.match(assert(r[src_key]), topic)
        if ok then
            return M.substitute(assert(r[dst_key]), caps), r
        end
    end
    return nil, nil
end

return M
