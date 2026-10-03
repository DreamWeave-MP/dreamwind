--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
A save's records as the save rules walk them: each record's tag and subrecords, with subrecord
positions 0-based as every report counts them, and the field readers the rules share.
]]

local tes3 = require '@dreamwind/tes3'

type Plugin = tes3.Plugin
type Subrecord = tes3.Subrecord

export type Record = {
  index: number,
  tag: string,
  source: buffer,
  subs: { Subrecord },
}

--- Record `index` (0-based) of `plugin`.
local function record(plugin: Plugin, index: number): Record
  return {
    index = index,
    tag = plugin:tag(index),
    source = (plugin:span(index)),
    subs = plugin:subrecords(index),
  }
end

--- Every record of `plugin`, in order.
local function all(plugin: Plugin): { Record }
  local out: { Record } = {}
  for i = 0, plugin:count() - 1 do
    out[i + 1] = record(plugin, i)
  end

  return out
end

--- Subrecord `k` (0-based) of `r`, or nil.
local function sub(r: Record, k: number): Subrecord? return r.subs[k + 1] end

--- The tag of subrecord `k` (0-based), or nil.
local function tagAt(r: Record, k: number): string?
  local s = r.subs[k + 1]
  return s and s.tag
end

--- Subrecord `k`'s payload as a string.
local function payload(r: Record, k: number): string
  local s = r.subs[k + 1]
  return buffer.readstring(r.source, s.payload, s.size)
end

--- The first subrecord tagged `tag`, 0-based, or nil.
local function first(r: Record, tag: string): number?
  for k, s in r.subs do
    if s.tag == tag then return k - 1 end
  end

  return nil
end

--- The little-endian u32, i32, or f32 at byte `at` (1-based) of `data`.
local function u32At(data: string, at: number?): number
  return string.unpack('<I4', data, at) :: number
end

local function i32At(data: string, at: number?): number
  return string.unpack('<i4', data, at) :: number
end

local function f32At(data: string, at: number?): number
  return string.unpack('<f', data, at) :: number
end

--- Bytes up to the first NUL, as UTF-8 with invalid bytes replaced (jess-omwaddon's
--- `trim_nul_string`).
local function trimNul(text: string): string
  local nul = string.find(text, '\0', 1, true)
  if nul then text = string.sub(text, 1, nul - 1) end

  return tes3.lossyUtf8(text)
end

--- Whether a character is a control character, as Rust's `char::is_control` says.
local function hasControl(text: string): boolean
  for _, codepoint in utf8.codes(text) do
    if codepoint < 0x20 or (codepoint >= 0x7f and codepoint < 0xa0) then return true end
  end

  return false
end

--- A RefId the way the save rules read one (jess-save's `decode_openmw_save_ref_id`): nil for an
--- empty one, the string of a sized (1) or plain (2) one, and any other payload taken as a plain
--- id when it's printable.
local function refId(data: string): string?
  if data == '' then return nil end

  local kind = string.byte(data, 1)
  if kind == 0 then return nil end

  if kind == 1 then
    if #data < 5 then return nil end

    local size = u32At(data, 2)
    if 4 + size > #data - 1 then return nil end

    return trimNul(string.sub(data, 6, 5 + size))
  end

  if kind == 2 then return trimNul(string.sub(data, 2)) end

  local value = trimNul(data)
  if value == '' or hasControl(value) then return nil end

  return value
end

--- An 8-byte `{ u32 index, i32 content file }` FormId, or nil for any other length.
local function wideFormId(data: string): (number?, number)
  if #data ~= 8 then return nil, 0 end

  return u32At(data, 1), i32At(data, 5)
end

--- The count an ICNT holds (0 when it's short).
local function inventoryCount(data: string): number
  if #data < 4 then return 0 end

  return u32At(data)
end

--- Whether a content file holds records: `.omwscripts` lists are plain text.
local function isRecordContentFile(name: string): boolean
  local extension = string.match(name, '%.([^./\\]*)$')
  if not extension then return false end

  extension = string.lower(extension)
  return extension == 'esm'
    or extension == 'esp'
    or extension == 'omwaddon'
    or extension == 'omwgame'
end

--- Every record a scan walks: all but the TES3 header and the SAVE record.
local function isScannable(tag: string): boolean return tag ~= 'TES3' and tag ~= 'SAVE' end

local function equalsIgnoringCase(a: string, b: string): boolean
  return a == b or string.lower(a) == string.lower(b)
end

return table.freeze {
  all = all,
  equalsIgnoringCase = equalsIgnoringCase,
  f32At = f32At,
  i32At = i32At,
  u32At = u32At,
  first = first,
  hasControl = hasControl,
  inventoryCount = inventoryCount,
  isRecordContentFile = isRecordContentFile,
  isScannable = isScannable,
  payload = payload,
  record = record,
  refId = refId,
  sub = sub,
  tagAt = tagAt,
  trimNul = trimNul,
  wideFormId = wideFormId,
}
