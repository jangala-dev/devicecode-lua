---@module 'fibers.utils.dlist'

---@class DListNode
---@field list DList|nil
---@field prev DListNode|nil
---@field next DListNode|nil
---@field value any
local DListNode = {}
DListNode.__index = DListNode

---@class DList
---@field head DListNode|nil
---@field tail DListNode|nil
---@field len integer
local DList = {}
DList.__index = DList

function DListNode:remove()
  local list = self.list
  if not list then
    return false
  end

  local p, n = self.prev, self.next
  if p then p.next = n else list.head = n end
  if n then n.prev = p else list.tail = p end

  list.len = list.len - 1

  self.list, self.prev, self.next = nil, nil, nil
  self.value = nil
  return true
end

function DList:push_tail(value)
  local node = setmetatable({ list = self, prev = self.tail, next = nil, value = value }, DListNode)
  if self.tail then
    self.tail.next = node
  else
    self.head = node
  end
  self.tail = node
  self.len = self.len + 1
  return node
end

function DList:pop_head()
  local node = self.head
  if not node then return nil end
  local value = node.value
  node:remove()
  return value
end

function DList:peek_head()
  local node = self.head
  return node and node.value or nil
end

function DList:empty()
  return self.len == 0
end

function DList:length()
  return self.len
end

---@return DList
local function new()
  return setmetatable({ head = nil, tail = nil, len = 0 }, DList)
end

return {
  new = new,
  DList = DList,
}
