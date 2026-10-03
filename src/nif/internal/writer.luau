--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

local Text = require './text'

--- A growing output buffer: `b` holds the bytes written so far, `p` is the next free byte, `n` is
--- `b`'s length (`buffer.len` is a call, and the writers check room before every run), and `nan`
--- says a float written since it was last cleared was NaN.
export type Writer = { b: buffer, p: number, n: number, nan: boolean }

--- Makes room for `size` more bytes at `w.p`, doubling the buffer as needed.
local function reserve(w: Writer, size: number)
  local need = w.p + size
  local length = w.n
  if need <= length then return end

  while length < need do
    length *= 2
  end

  local grown = buffer.create(length)
  buffer.copy(grown, 0, w.b, 0, w.p)
  w.b, w.n = grown, length
end

local function new(size: number): Writer
  local length = math.max(size, 64)
  return { b = buffer.create(length), p = 0, n = length, nan = false }
end

--- The bytes written, trimmed to their length.
local function finish(w: Writer): buffer
  if w.p == w.n then return w.b end

  local out = buffer.create(w.p)
  buffer.copy(out, 0, w.b, 0, w.p)
  return out
end

--- A string as a u32 length and its Windows-1252 bytes, with no terminator.
local function writeString(w: Writer, text: string)
  local value = Text.encode(text)
  local length = #value
  reserve(w, 4 + length)
  buffer.writeu32(w.b, w.p, length)
  buffer.writestring(w.b, w.p + 4, value)
  w.p += 4 + length
end

--- A link as its index in the saved file: -1 when null or when its record is not saved.
local function link(value: number?, map: { [number]: number }): number
  if not value or value < 0 then return -1 end

  return map[value] or -1
end

return table.freeze {
  new = new,
  reserve = reserve,
  finish = finish,
  string = writeString,
  link = link,
}
