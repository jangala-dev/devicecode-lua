-- trie.lua
-- Modes:
--   pubsub   : wildcards allowed in stored keys; literal queries
--   retained : literal stored keys; wildcards allowed in queries
--   literal  : exact match only
--
-- No ordering guarantees: child iteration uses pairs().

local M = {}

--------------------------------------------------------------------------------
-- Literal wrapper (escape hatch)
--------------------------------------------------------------------------------

local LIT_MT = {}
LIT_MT.__index = LIT_MT

function M.literal(v)
    local tv = type(v)
    if tv ~= "string" and tv ~= "number" then
        error("literal value must be a string or number", 2)
    end
    return setmetatable({ v = v }, LIT_MT)
end

--------------------------------------------------------------------------------
-- Dense array validation
--------------------------------------------------------------------------------

local function array_len(t, errlvl)
    if type(t) ~= "table" then
        error("tokens must be a table (dense array)", errlvl)
    end

    local n = 0
    for _ in ipairs(t) do n = n + 1 end

    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or k % 1 ~= 0 or k > n then
            error("token arrays must use 1..n integer keys only", errlvl)
        end
    end

    return n
end

--------------------------------------------------------------------------------
-- Core trie
--------------------------------------------------------------------------------

local function Node()
    -- c   : children map
    -- has : whether this node stores a value
    -- v   : stored value
    -- k   : stored key tokens (presentation form, including '+'/'#' where applicable)
    return { c = {}, has = false, v = nil, k = nil }
end

local function insert(root, tokens_compiled, value, key_tokens)
    local node = root
    for i = 1, #tokens_compiled do
        local t = tokens_compiled[i]
        local child = node.c[t]
        if not child then
            child = Node()
            node.c[t] = child
        end
        node = child
    end
    node.has, node.v, node.k = true, value, key_tokens
    return true
end

local function get_node(root, tokens_compiled)
    local node = root
    for i = 1, #tokens_compiled do
        node = node.c[tokens_compiled[i]]
        if not node then return nil end
    end
    return node
end

local function remove(root, tokens_compiled)
    local node, stack = root, {}

    for i = 1, #tokens_compiled do
        local t = tokens_compiled[i]
        local child = node.c[t]
        if not child then return false end
        stack[#stack + 1] = { node, t }
        node = child
    end

    if not node.has then return false end
    node.has, node.v, node.k = false, nil, nil

    for i = #stack, 1, -1 do
        local parent, tok = stack[i][1], stack[i][2]
        local child = parent.c[tok]
        if child.has or next(child.c) ~= nil then break end
        parent.c[tok] = nil
    end

    return true
end

local function visit_all(start_node, visit)
    local stack = { start_node }
    while #stack > 0 do
        local node = stack[#stack]
        stack[#stack] = nil
        if node.has then
            visit(node.k, node.v)
        end
        for _, child in pairs(node.c) do
            stack[#stack + 1] = child
        end
    end
end

--------------------------------------------------------------------------------
-- Token compilation
--------------------------------------------------------------------------------

-- Returns:
--   compiled : tokens with SW/MW sentinels substituted where allowed
--   shown    : tokens in "presentation" form (keeps '+'/'#' symbols)
local function compile(cfg, tokens, allow_wild, errlvl)
    local n = array_len(tokens, errlvl)
    local compiled = {}
    local shown    = {}

    for i = 1, n do
        local tok = tokens[i]
        local was_lit = (getmetatable(tok) == LIT_MT)

        if was_lit then
            tok = tok.v
        else
            local tt = type(tok)
            if tt ~= "string" and tt ~= "number" then
                error("token parts must be strings or numbers", errlvl)
            end
        end

        -- Default: shown == tok as provided (post literal unwrap).
        shown[i] = tok

        if allow_wild and not was_lit then
            if tok == cfg.single then
                compiled[i] = cfg.SW
                -- shown[i] stays as cfg.single (e.g. "+")
            elseif tok == cfg.multi then
                if i ~= n then
                    error("multi wildcard must be last", errlvl)
                end
                compiled[i] = cfg.MW
                -- shown[i] stays as cfg.multi (e.g. "#")
            else
                compiled[i] = tok
            end
        else
            compiled[i] = tok
        end
    end

    return compiled, shown
end

--------------------------------------------------------------------------------
-- Shared DFS walk
--------------------------------------------------------------------------------

local function dfs_walk(root, q, on_done, on_step)
    local n = #q
    local nodes = { root }
    local idxs  = { 1 }
    local top   = 1

    local function push(child, next_i)
        top = top + 1
        nodes[top] = child
        idxs[top] = next_i
    end

    while top > 0 do
        local node = nodes[top]
        local i = idxs[top]
        nodes[top], idxs[top] = nil, nil
        top = top - 1

        if i > n then
            on_done(node)
        else
            on_step(node, i, q[i], push)
        end
    end
end

--------------------------------------------------------------------------------
-- Matchers
--------------------------------------------------------------------------------

local function match_stored(root, cfg, q, visit)
    local SW, MW = cfg.SW, cfg.MW

    dfs_walk(
        root, q,
        function(node)
            if node.has then visit(node.k, node.v) end
            local mwc = node.c[MW]
            if mwc then visit_all(mwc, visit) end
        end,
        function(node, i, tok, push)
            local child = node.c[tok]
            if child then push(child, i + 1) end

            child = node.c[SW]
            if child then push(child, i + 1) end

            child = node.c[MW]
            if child then visit_all(child, visit) end
        end
    )
end

local function match_query(root, cfg, q, visit)
    local SW, MW = cfg.SW, cfg.MW

    dfs_walk(
        root, q,
        function(node)
            if node.has then visit(node.k, node.v) end
        end,
        function(node, i, tok, push)
            if tok == MW then
                visit_all(node, visit)
            elseif tok == SW then
                for _, child in pairs(node.c) do
                    push(child, i + 1)
                end
            else
                local child = node.c[tok]
                if child then push(child, i + 1) end
            end
        end
    )
end

--------------------------------------------------------------------------------
-- Constructors
--------------------------------------------------------------------------------

local MODES = {
    pubsub   = { key_wild = true,  query_wild = false, matcher = match_stored },
    retained = { key_wild = false, query_wild = true,  matcher = match_query  },
    literal  = { key_wild = false, query_wild = false, matcher = nil          },
}

local function new(mode, single, multi)
    local spec = MODES[mode]
    if not spec then
        error("unknown mode", 3)
    end

    local cfg = { SW = {}, MW = {} }

    if spec.key_wild or spec.query_wild then
        cfg.single = single or "+"
        cfg.multi  = multi  or "#"

        local ts, tm = type(cfg.single), type(cfg.multi)
        if (ts ~= "string" and ts ~= "number") or (tm ~= "string" and tm ~= "number") then
            error("wildcard symbols must be strings or numbers", 3)
        end
        if cfg.single == cfg.multi then
            error("wildcards must differ", 3)
        end
    end

    local root = Node()
    local matcher = spec.matcher
    local api = {}

    function api:insert(key, value)
        if value == nil then error("value required", 2) end
        local compiled, shown = compile(cfg, key, spec.key_wild, 4)
        return insert(root, compiled, value, shown)
    end

    function api:retrieve(key)
        local compiled = compile(cfg, key, spec.key_wild, 4)
        local node = get_node(root, compiled)
        return (node and node.has) and node.v or nil
    end

    function api:delete(key)
        local compiled = compile(cfg, key, spec.key_wild, 4)
        return remove(root, compiled)
    end

    -- visit(key_tokens, value)
    function api:each(query, visit)
        if type(visit) ~= "function" then error("visit must be a function", 2) end
        local q = compile(cfg, query, spec.query_wild, 4)

        if matcher then
            matcher(root, cfg, q, visit)
        else
            local node = get_node(root, q)
            if node and node.has then
                visit(node.k, node.v)
            end
        end

        return true
    end

    return api
end

function M.new_pubsub(single, multi)    return new("pubsub", single, multi) end
function M.new_retained(single, multi)  return new("retained", single, multi) end
function M.new_literal()                return new("literal") end

return M
