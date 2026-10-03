--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Bulk data as views of the bytes it was read from. An array is its `buffer`, the `offset` of
element 1, its `count`, and the `stride` of one element, laid out as the file lays it out (little
endian, no padding), so the fastest read is a loop of `buffer.read*` over those four fields, and
saving it is one copy. `get` and `set` take 1-based indices and hand over values without
allocating: a `vector` for two or three floats, several results for anything wider. The first
`set` copies the view's bytes out of the file's buffer, so editing never touches the source.
]]

local Types = require './array_types'
local Writer = require './writer'

type Writer = Writer.Writer

export type Kind = Types.Kind
export type Array = Types.Array
export type ArrayFields = Types.ArrayFields

local Strides = Types.strides

--- A kind's methods and its name and stride, read through its metatable.
type Methods = { [string]: unknown }

--- One metatable per kind. Its methods (`array_access.luau`) load the first time any array is
--- asked for one, and then sit in `__index` directly.
type Meta = {
  __index: Methods | (ArrayFields, string) -> unknown,
  __len: (ArrayFields) -> number,
}

local Metas: { [Kind]: Meta } = {}
local Kinds: { [Meta]: Kind } = {}

local function length(array: ArrayFields): number return array.count end

local function install()
  local methods: { [Kind]: Methods } = require './array_access'
  for kind, meta in Metas do
    meta.__index = methods[kind]
  end
end

for kind in Strides do
  local meta: Meta = { __index = {}, __len = length }
  meta.__index = function(_: ArrayFields, key: string): unknown
    install()
    return (meta.__index :: Methods)[key]
  end
  Metas[kind], Kinds[meta] = meta, kind
end

--- An array of `kind`: the fields given the kind's metatable.
local function make(fields: ArrayFields, kind: Kind): Array
  return setmetatable(fields, Metas[kind]) :: Array
end

--- One frozen empty array per kind, shared by every empty list: most lists in a file are, and an
--- empty array has nothing to set.
local Empty: { [Kind]: Array } = {}
for kind in Metas do
  Empty[kind] = table.freeze(
    make(
      { buffer = buffer.create(0), offset = 0, count = 0, stride = Strides[kind], owned = true },
      kind
    )
  )
end

--- A view of `count` elements of `kind` at `offset` in `b`, which must hold them: the readers only
--- view bytes `open` has already walked past.
local function view(b: buffer, offset: number, count: number, kind: Kind): Array
  if count == 0 then return Empty[kind] end

  return make({ buffer = b, offset = offset, count = count, stride = Strides[kind] }, kind)
end

--- A new array of `count` zeroed elements.
local function new(kind: Kind, count: number): Array
  local stride = Strides[kind]
  return make({
    buffer = buffer.create(count * stride),
    offset = 0,
    count = count,
    stride = stride,
    owned = true,
  }, kind)
end

--- What fills each lazy array's bytes, until something reads it.
local Pending: { [ArrayFields]: (b: buffer) -> () } = setmetatable({}, { __mode = 'k' }) :: any

--- Each kind's metatable for lazy arrays, made when a kind first has one.
local LazyMetas: { [Kind]: Meta } = {}

--- A lazy array's bytes, filled the first time anything but its count is read; then it is an
--- ordinary array of its kind.
local function fill(array: ArrayFields, kind: Kind)
  local stride = Strides[kind]
  local b = buffer.create(array.count * stride)
  local pending = Pending[array]
  Pending[array] = nil
  pending(b)
  rawset(array :: any, 'buffer', b)
  rawset(array :: any, 'offset', 0)
  setmetatable(array :: any, Metas[kind])
end

--- An array of `count` elements of `kind` whose bytes `filler` writes into a new buffer the
--- first time the array is read: a value derived from the file (a remapped index list) costs
--- nothing until something reads it. `#array` and `count` don't fill it.
local function lazy(kind: Kind, count: number, filler: (b: buffer) -> ()): Array
  if count == 0 then return Empty[kind] end

  local meta = LazyMetas[kind]
  if not meta then
    local made: Meta = { __index = {}, __len = length }
    made.__index = function(array: ArrayFields, key: string): unknown
      fill(array, kind)
      return (array :: any)[key]
    end

    meta = made
    LazyMetas[kind], Kinds[made] = made, kind
  end

  local array = { count = count, stride = Strides[kind], owned = true } :: any
  Pending[array] = filler
  return setmetatable(array, meta :: any) :: any
end

local function write(w: Writer, array: ArrayFields)
  local length = array.count * array.stride
  Writer.reserve(w, length)
  buffer.copy(w.b, w.p, array.buffer, array.offset, length)
  w.p += length
end

local function sum(array: ArrayFields): number
  local b, offset, total = array.buffer, array.offset, 0
  for i = 0, array.count - 1 do
    total += buffer.readu16(b, offset + i * 2)
  end

  return total
end

local function isArray(value: unknown): boolean
  return type(value) == 'table' and Kinds[getmetatable(value) :: Meta] ~= nil
end

--- An array's kind, or nil for any other value.
local function kindOf(value: unknown): Kind?
  if type(value) ~= 'table' then return nil end

  return Kinds[getmetatable(value) :: Meta]
end

return table.freeze {
  --- Each kind's metatable and shared empty array, for readers that make arrays themselves.
  metas = Metas,
  empty = Empty,
  view = view,
  new = new,
  lazy = lazy,
  write = write,
  sum = sum,
  isArray = isArray,
  kindOf = kindOf,
  strides = Strides,
}
