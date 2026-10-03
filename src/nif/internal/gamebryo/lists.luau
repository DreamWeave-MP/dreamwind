--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Lists of `u16` lists the file stores back to back (match groups, triangle strips): read as
where the first starts and how many there are, nothing more. Where each one starts is worked out
the first time any is asked for, and each list is a view of the file's bytes made when it is
asked for. A shape with five hundred match groups costs one small table to read. `#lists`,
`lists[i]`, and `for i, list in lists` work as on a plain list of views.
]]

local Array = require '../array'

export type Lists = {
  buffer: buffer,
  --- Where the first list (or its length) starts.
  start: number,
  count: number,
  --- Each list's length, when the file stores them apart (strips); otherwise each list starts
  --- with its own `u16` length (match groups).
  lengths: Array.Array?,
  --- Each list's start and length, interleaved, once worked out.
  spans: { number }?,
  --- The lists made so far, by index.
  made: { Array.Array }?,
}

local Meta = {}

local function spansOf(lists: Lists): { number }
  local spans = lists.spans
  if spans then return spans end

  local b, count, lengths = lists.buffer, lists.count, lists.lengths
  local made = table.create(count * 2) :: { number }
  local p = lists.start
  for i = 1, count do
    local length
    if lengths then
      length = buffer.readu16(lengths.buffer, lengths.offset + (i - 1) * 2)
    else
      length = buffer.readu16(b, p)
      p += 2
    end

    made[i * 2 - 1], made[i * 2] = p, length
    p += length * 2
  end

  lists.spans = made
  return made
end

Meta.__len = function(lists: Lists): number return lists.count end

Meta.__index = function(lists: Lists, key: unknown): Array.Array?
  if type(key) ~= 'number' or key < 1 or key > lists.count or key % 1 ~= 0 then return nil end

  local made: { Array.Array } = lists.made or {}
  lists.made = made
  local list = made[key]
  if list then return list end

  local spans = spansOf(lists)
  list = Array.view(lists.buffer, spans[key * 2 - 1], spans[key * 2], 'u16')
  made[key] = list
  return list
end

Meta.__iter = function(lists: Lists): () -> (number?, Array.Array?)
  local i, count = 0, lists.count
  return function()
    i += 1
    if i > count then return nil, nil end

    return i, Meta.__index(lists, i)
  end
end

--- `count` lists of `u16`s from `start` in `b`, each after its own `u16` length.
local function prefixed(b: buffer, start: number, count: number): Lists
  return setmetatable({ buffer = b, start = start, count = count }, Meta) :: any
end

--- Lists of `u16`s from `start` in `b`, one per entry of `lengths`, back to back.
local function sized(b: buffer, start: number, lengths: Array.Array): Lists
  return setmetatable(
      { buffer = b, start = start, count = lengths.count, lengths = lengths },
      Meta
    ) :: any
end

local function isLists(value: unknown): boolean
  return type(value) == 'table' and getmetatable(value :: any) == Meta
end

return table.freeze { prefixed = prefixed, sized = sized, isLists = isLists }
