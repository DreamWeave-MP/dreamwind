--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
A growable byte buffer: what encoding a record and rebuilding one write into. `n` is the length
written; `finish` copies exactly that many bytes out.
]]

export type Writer = { b: buffer, n: number }

local function new(capacity: number?): Writer
  return { b = buffer.create(math.max(capacity or 256, 16)), n = 0 }
end

local function reserve(w: Writer, extra: number)
  local need = w.n + extra
  local size = buffer.len(w.b)
  if need <= size then return end

  while size < need do
    size *= 2
  end

  local grown = buffer.create(size)
  buffer.copy(grown, 0, w.b, 0, w.n)
  w.b = grown
end

local function u8(w: Writer, value: number)
  reserve(w, 1)
  buffer.writeu8(w.b, w.n, value)
  w.n += 1
end

local function u16(w: Writer, value: number)
  reserve(w, 2)
  buffer.writeu16(w.b, w.n, value)
  w.n += 2
end

local function u32(w: Writer, value: number)
  reserve(w, 4)
  buffer.writeu32(w.b, w.n, value)
  w.n += 4
end

local function i32(w: Writer, value: number)
  reserve(w, 4)
  buffer.writei32(w.b, w.n, value)
  w.n += 4
end

local function f32(w: Writer, value: number)
  reserve(w, 4)
  buffer.writef32(w.b, w.n, value)
  w.n += 4
end

local function f64(w: Writer, value: number)
  reserve(w, 8)
  buffer.writef64(w.b, w.n, value)
  w.n += 8
end

--- A u64 held exactly in a number (up to 2^53).
local function u64(w: Writer, value: number)
  reserve(w, 8)
  buffer.writeu32(w.b, w.n, value % 4294967296)
  buffer.writeu32(w.b, w.n + 4, value // 4294967296)
  w.n += 8
end

local function string_(w: Writer, value: string)
  local length = #value
  reserve(w, length)
  buffer.writestring(w.b, w.n, value)
  w.n += length
end

local function zeros(w: Writer, count: number)
  reserve(w, count)
  buffer.fill(w.b, w.n, 0, count)
  w.n += count
end

--- `length` bytes of `source` from `offset`.
local function copy(w: Writer, source: buffer, offset: number, length: number)
  reserve(w, length)
  buffer.copy(w.b, w.n, source, offset, length)
  w.n += length
end

--- The bytes written, as a buffer of exactly their length.
local function finish(w: Writer): buffer
  local out = buffer.create(w.n)
  buffer.copy(out, 0, w.b, 0, w.n)
  return out
end

return table.freeze {
  copy = copy,
  f32 = f32,
  f64 = f64,
  finish = finish,
  i32 = i32,
  new = new,
  reserve = reserve,
  string = string_,
  u16 = u16,
  u32 = u32,
  u64 = u64,
  u8 = u8,
  zeros = zeros,
}
