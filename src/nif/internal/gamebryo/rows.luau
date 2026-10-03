--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Lists of fixed-size structs as views of the file's bytes: a list is where its first element
starts, how many there are, how far apart, and the function that reads one. Reading the list
reads none of them; element `i` becomes a table the first time it is asked for, and stays that
table. A collision mesh's thousands of triangles cost one small table to read. `#rows`,
`rows[i]`, and `for i, row in rows` work as on a plain list.
]]

export type Read = (b: buffer, at: number) -> any

export type Rows = {
  buffer: buffer,
  offset: number,
  count: number,
  stride: number,
  read: Read,
  --- The elements made so far, by index.
  made: { any }?,
}

local Meta = {}

Meta.__len = function(rows: Rows): number return rows.count end

Meta.__index = function(rows: Rows, key: unknown): any
  if type(key) ~= 'number' or key < 1 or key > rows.count or key % 1 ~= 0 then return nil end

  local made: { any } = rows.made or {}
  rows.made = made
  local row = made[key]
  if row ~= nil then return row end

  row = rows.read(rows.buffer, rows.offset + (key - 1) * rows.stride)
  made[key] = row
  return row
end

Meta.__iter = function(rows: Rows): () -> (number?, any)
  local i, count = 0, rows.count
  return function()
    i += 1
    if i > count then return nil, nil end

    return i, Meta.__index(rows, i)
  end
end

--- `count` elements `stride` bytes apart from `offset` in `b`, each read by `read`.
local function new(b: buffer, offset: number, count: number, stride: number, read: Read): Rows
  return setmetatable(
    { buffer = b, offset = offset, count = count, stride = stride, read = read },
    Meta
  ) :: any
end

local function isRows(value: unknown): boolean
  return type(value) == 'table' and getmetatable(value :: any) == Meta
end

return table.freeze { new = new, isRows = isRows }
