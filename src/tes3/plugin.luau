--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
The raw-preserving TES3 spine (jess-plugin's `RawPlugin`): a plugin is the bytes it was read from
and, per record, where its bytes are. Opening one frames every record and subrecord, checking that
each fits, and keeps nothing else: a record's subrecords are walked again when asked for, which is
cheaper than holding millions of them. An untouched record saves by copying its original bytes,
so an unedited plugin saves byte for byte. An edited record holds its whole new bytes, header
included; deleting one drops it from the list.

Records are numbered from 0, as `jess plugin dump` numbers them. Errors read as jess-plugin's
`ParseError` does: the problem, then `at offset N`.
]]

local Decode = require './decode'
local Encode = require './encode'
local Tags = require './tags'
local Text = require './text'
local Writeback = require './writeback'
local Writer = require './writer'
local bytes = require '@dream/bytes'

type Value = Decode.Value

local RecordHeaderLength = 16
local SubrecordHeaderLength = 8
local HedrLength = 300
local HedrFileTypeOffset = 4
local HedrAuthorOffset = 8
local HedrAuthorLength = 32
local HedrDescriptionOffset = 40
local HedrDescriptionLength = 256
local HedrRecordCountOffset = 296
local MaxLimitedSizeStringsFormat = 22
local FlagIgnored = 0x1000

local TES3 = Tags.code 'TES3'
local HEDR = Tags.code 'HEDR'
local MAST = Tags.code 'MAST'
local DATA = Tags.code 'DATA'
local FORM = Tags.code 'FORM'
local CELL = Tags.code 'CELL'
local SAVE = Tags.code 'SAVE'
local FRMR = Tags.code 'FRMR'
local MVRF = Tags.code 'MVRF'
local CNDT = Tags.code 'CNDT'
local NAM0 = Tags.code 'NAM0'

export type Profile = 'raw' | 'tes3' | 'omwaddon' | 'omwsave'
export type FileType = 'plugin' | 'master' | 'save'

--- Which parts of a CELL a filtered open keeps: both unless one is false.
export type CellParts = { header: boolean?, references: boolean? }

--- What a filtered open keeps of a record of a tag: nothing, nothing but checked like a whole
--- record, the whole record, or (for a CELL) some of its parts.
export type Keep = 'skip' | 'framed' | 'whole' | CellParts

export type OpenOptions = {
  encoding: string?,
  profile: Profile?,
  --- Called once per record with its tag; anything other than `'whole'` leaves something out.
  keep: ((tag: string) -> Keep)?,
}

export type Header = {
  version: number,
  fileType: FileType,
  author: string,
  description: string,
  recordCount: number,
}

--- A master: its name, its size when the plugin was saved, and where its MAST and DATA are in
--- the TES3 record (0-based subrecord positions).
export type Master = { name: string, size: number, mast: number, data: number }

--- A subrecord: its tag, its payload's size, and where it is. `source` is the plugin's original
--- bytes or an edited record's own; `start` is its header, `payload` its payload, `finish` its end.
export type Subrecord = {
  tag: string,
  code: number,
  size: number,
  start: number,
  payload: number,
  finish: number,
}

export type Diagnostic = { offset: number, message: string }

export type PluginData = {
  --- The bytes the plugin was read from.
  source: buffer,
  encoding: string,
  profile: Profile,
  --- Per record (1-based): where it starts in `source`, its new bytes when edited, and the CELL
  --- parts a filtered open kept of it (bit 1 the header, bit 2 the references; 3 for all).
  starts: { number },
  bodies: { buffer | false },
  parts: { number },
  revision: number,
  --- What whole-plugin header questions need, from one walk over the record types, kept until the
  --- next edit: whether a SAVE record is there, and how many TES3 headers.
  facts: { revision: number, save: boolean, headers: number }?,
}

local Plugin = {}
Plugin.__index = Plugin

export type Plugin = typeof(setmetatable({} :: PluginData, Plugin))

local function fail(offset: number, message: string): never error(`{message} at offset {offset}`, 0) end

local NextRevision = 1

local function revise(): number
  NextRevision += 1
  return NextRevision
end

--[[ Framing ]]

--- Checks the subrecords in `[from, to)` of `source` fit; returns where the first whose tag
--- `stop` names starts (or `to`), and the subrecord count before it.
local function walk(
  source: buffer,
  from: number,
  to: number,
  stop: { [number]: boolean }?
): (number, number)
  local p, count = from, 0
  while p < to do
    if p + SubrecordHeaderLength > to then fail(p, 'truncated subrecord header') end

    local tag = buffer.readu32(source, p)
    if stop and stop[tag] then return p, count end

    local finish = p + SubrecordHeaderLength + buffer.readu32(source, p + 4)
    if finish > to then fail(p, `subrecord {Tags.display(tag)} extends past record payload`) end

    p, count = finish, count + 1
  end

  return p, count
end

local ReferenceTags = { [NAM0] = true, [MVRF] = true, [FRMR] = true }

local function keepOf(keep: Keep): number
  if keep == 'whole' then return 3 end

  if type(keep) == 'table' then
    local bits = 0
    if keep.header ~= false then
      bits += 1
    end

    if keep.references ~= false then
      bits += 2
    end

    return bits
  end

  return 0
end

--- A CELL cut down to `parts` (bits 1 header, 2 references), or nil when that leaves nothing
--- out. References a filtered open doesn't keep are never framed.
local function cutCell(source: buffer, start: number, finish: number, parts: number): buffer?
  local payload = start + RecordHeaderLength
  if bit32.btest(parts, 2) then walk(source, payload, finish, nil) end

  local split = walk(source, payload, finish, ReferenceTags)
  local dropHeader = not bit32.btest(parts, 1) and split > payload
  local dropReferences = not bit32.btest(parts, 2) and split < finish
  if not dropHeader and not dropReferences then return nil end

  local w = Writer.new(finish - start)
  Writer.copy(w, source, start, RecordHeaderLength)
  if not dropHeader then Writer.copy(w, source, payload, split - payload) end

  if not dropReferences then Writer.copy(w, source, split, finish - split) end

  local out = Writer.finish(w)
  buffer.writeu32(out, 4, buffer.len(out) - RecordHeaderLength)
  return out
end

local function parse(source: buffer, options: OpenOptions?): Plugin
  local encoding = options and options.encoding or 'win1252'
  Text.label(encoding)
  local profile: Profile = options and options.profile or 'raw'
  local keep = options and options.keep
  local n = buffer.len(source)
  if n >= 4294967295 then fail(0, 'plugin is 4 GiB or larger') end

  local starts: { number }, bodies: { buffer | false }, parts: { number } = {}, {}, {}
  if not keep then
    -- Every record and subrecord framed in one native walk; its problems read as the walk below
    -- words them.
    local spans, framed, problem, at = bytes.frame(source, {
      header = RecordHeaderLength,
      lengthAt = 4,
      inner = { header = SubrecordHeaderLength, lengthAt = 4 },
    })

    for i = 1, framed do
      starts[i], bodies[i], parts[i] = buffer.readu32(spans, (i - 1) * 8), false, 3
    end

    if problem then
      local where = at :: number
      if problem == 'truncated' then fail(where, 'truncated record header') end

      if problem == 'innerTruncated' then fail(where, 'truncated subrecord header') end

      local tag = Tags.display(buffer.readu32(source, where))
      if problem == 'overrun' then fail(where, `record {tag} extends past end of file`) end

      fail(where, `subrecord {tag} extends past record payload`)
    end

    return setmetatable(
      {
        source = source,
        encoding = encoding,
        profile = profile,
        starts = starts,
        bodies = bodies,
        parts = parts,
        revision = 0,
      } :: PluginData,
      Plugin
    )
  end

  local count, p = 0, 0
  while p < n do
    if p + RecordHeaderLength > n then fail(p, 'truncated record header') end

    local tag = buffer.readu32(source, p)
    local finish = p + RecordHeaderLength + buffer.readu32(source, p + 4)
    local kept = 3
    if keep then
      local choice = keep(Tags.name(tag))
      if choice == 'skip' then
        -- A skipped record running past the end ends the plugin there.
        p = math.min(finish, n)
        continue
      end

      kept = if choice == 'framed' then -1 elseif tag == CELL then keepOf(choice) else 3
    end

    if finish > n then fail(p, `record {Tags.display(tag)} extends past end of file`) end

    if kept == 3 then
      walk(source, p + RecordHeaderLength, finish, nil)
      count += 1
      starts[count], bodies[count], parts[count] = p, false, 3
    elseif kept == -1 then
      walk(source, p + RecordHeaderLength, finish, nil)
    else
      local cut = cutCell(source, p, finish, kept)
      count += 1
      starts[count], bodies[count], parts[count] = p, cut or false, if cut then kept else 3
    end

    p = finish
  end

  return setmetatable(
    {
      source = source,
      encoding = encoding,
      profile = profile,
      starts = starts,
      bodies = bodies,
      parts = parts,
      revision = 0,
    } :: PluginData,
    Plugin
  )
end

--[[ Reading records ]]

local function slot(self: Plugin, index: number): number
  local i = index + 1
  if i < 1 or i > #self.starts or i % 1 ~= 0 then
    fail(buffer.len(self.source), 'record index out of bounds')
  end

  return i
end

--- How many records the plugin holds, header included.
function Plugin.count(self: Plugin): number return #self.starts end

--- Where record `index`'s bytes are: the buffer, where they start, and where they end.
function Plugin.span(self: Plugin, index: number): (buffer, number, number)
  local i = slot(self, index)
  local body = self.bodies[i]
  if body then return body, 0, buffer.len(body) end

  local start = self.starts[i]
  return self.source, start, start + RecordHeaderLength + buffer.readu32(self.source, start + 4)
end

--- Record `index`'s tag as a number (see `tags.luau`).
function Plugin.code(self: Plugin, index: number): number
  local i = slot(self, index)
  local body = self.bodies[i]
  if body then return buffer.readu32(body, 0) end

  return buffer.readu32(self.source, self.starts[i])
end

--- Record `index`'s tag: `LIGH`.
function Plugin.tag(self: Plugin, index: number): string return Tags.name(self:code(index)) end

--- The record header's flags (bytes 12 to 16).
function Plugin.flags(self: Plugin, index: number): number
  local source, start = self:span(index)
  return buffer.readu32(source, start + 12)
end

--- The payload size the record header states.
function Plugin.size(self: Plugin, index: number): number
  local source, start = self:span(index)
  return buffer.readu32(source, start + 4)
end

--- Where record `index` was in the original bytes, header included: `start, finish`. An inserted
--- record's range is empty, where it was put.
function Plugin.range(self: Plugin, index: number): (number, number)
  local i = slot(self, index)
  local start = self.starts[i]
  if start < 0 then return -start - 1, -start - 1 end

  return start, start + RecordHeaderLength + buffer.readu32(self.source, start + 4)
end

--- Record `index`'s bytes, header included, as a new buffer.
function Plugin.bytes(self: Plugin, index: number): buffer
  local source, start, finish = self:span(index)
  local out = buffer.create(finish - start)
  buffer.copy(out, 0, source, start, finish - start)
  return out
end

--- Whether record `index` was edited, so it saves from new bytes.
function Plugin.isDirty(self: Plugin, index: number): boolean
  return self.bodies[slot(self, index)] ~= false
end

--- Whether a filtered open left part of record `index` out.
function Plugin.isPartial(self: Plugin, index: number): boolean
  return self.parts[slot(self, index)] ~= 3
end

--- The CELL parts a filtered open kept of record `index`, or nil when it kept it whole.
function Plugin.keptParts(self: Plugin, index: number): CellParts?
  local bits = self.parts[slot(self, index)]
  if bits == 3 then return nil end

  return { header = bit32.btest(bits, 1), references = bit32.btest(bits, 2) }
end

--- Whether any record was opened only in part.
function Plugin.hasPartialRecords(self: Plugin): boolean
  for _, bits in self.parts do
    if bits ~= 3 then return true end
  end

  return false
end

--- Record `index`'s subrecords, in order.
function Plugin.subrecords(self: Plugin, index: number): { Subrecord }
  local source, start, finish = self:span(index)
  local out = {}
  local p = start + RecordHeaderLength
  while p < finish do
    local tag = buffer.readu32(source, p)
    local size = buffer.readu32(source, p + 4)
    table.insert(out, {
      tag = Tags.name(tag),
      code = tag,
      size = size,
      start = p,
      payload = p + SubrecordHeaderLength,
      finish = p + SubrecordHeaderLength + size,
    })
    p += SubrecordHeaderLength + size
  end

  return out
end

--- The first subrecord of record `index` with tag `code` (a number): where its payload starts
--- and its size, or nil.
function Plugin.findSubrecord(self: Plugin, index: number, code: number): (buffer?, number, number)
  local source, start, finish = self:span(index)
  local p = start + RecordHeaderLength
  while p < finish do
    local size = buffer.readu32(source, p + 4)
    if buffer.readu32(source, p) == code then return source, p + SubrecordHeaderLength, size end

    p += SubrecordHeaderLength + size
  end

  return nil, 0, 0
end

--- The plugin's bytes: untouched records copied from the original, edited ones rebuilt, deleted
--- ones left out. Runs of untouched records copy in one go.
function Plugin.save(self: Plugin): buffer
  local source, starts, bodies = self.source, self.starts, self.bodies
  local total = 0
  for i, start in starts do
    local body = bodies[i]
    total += if body
      then buffer.len(body)
      else RecordHeaderLength + buffer.readu32(source, start + 4)
  end

  local out = buffer.create(total)
  local at, runStart, runEnd = 0, 0, 0
  for i, start in starts do
    local body = bodies[i]
    if body then
      if runEnd > runStart then
        buffer.copy(out, at, source, runStart, runEnd - runStart)
        at += runEnd - runStart
      end

      runStart, runEnd = 0, 0
      buffer.copy(out, at, body)
      at += buffer.len(body)
      continue
    end

    local finish = start + RecordHeaderLength + buffer.readu32(source, start + 4)
    if start == runEnd and runEnd > runStart then
      runEnd = finish
    else
      if runEnd > runStart then
        buffer.copy(out, at, source, runStart, runEnd - runStart)
        at += runEnd - runStart
      end

      runStart, runEnd = start, finish
    end
  end

  if runEnd > runStart then buffer.copy(out, at, source, runStart, runEnd - runStart) end

  return out
end

--[[ Editing records ]]

local function touch(self: Plugin) self.revision = revise() end

--- Checks `payload` is whole subrecords, as the record it goes into needs.
local function checkPayload(payload: buffer, offset: number, length: number)
  walk(payload, offset, offset + length, nil)
end

local function asBuffer(value: buffer | string): buffer
  if type(value) == 'string' then return buffer.fromstring(value) end

  return value
end

--- A record of `header`'s first 16 bytes and `payload`, its size set to the payload's.
local function assemble(
  header: buffer,
  headerAt: number,
  payload: buffer,
  at: number,
  length: number
): buffer
  local out = buffer.create(RecordHeaderLength + length)
  buffer.copy(out, 0, header, headerAt, RecordHeaderLength)
  buffer.writeu32(out, 4, length)
  buffer.copy(out, RecordHeaderLength, payload, at, length)
  return out
end

--- Replaces record `index`'s payload, keeping its header but for the size.
function Plugin.replacePayload(self: Plugin, index: number, payload: buffer | string)
  touch(self)
  local data = asBuffer(payload)
  local source, start = self:span(index)
  checkPayload(data, 0, buffer.len(data))
  self.bodies[slot(self, index)] = assemble(source, start, data, 0, buffer.len(data))
end

--- Replaces record `index` with whole new bytes of the same tag; the flags come from them and the
--- size is recomputed.
function Plugin.replaceBytes(self: Plugin, index: number, bytes: buffer | string)
  touch(self)
  local data = asBuffer(bytes)
  if buffer.len(data) < RecordHeaderLength then fail(0, 'truncated record header') end

  local i = slot(self, index)
  local source, start = self:span(index)
  if buffer.readu32(data, 0) ~= buffer.readu32(source, start) then
    fail(self:range(index), 'replacement record has a different tag')
  end

  local length = buffer.len(data) - RecordHeaderLength
  checkPayload(data, RecordHeaderLength, length)
  local out = assemble(source, start, data, RecordHeaderLength, length)
  buffer.copy(out, 8, data, 8, 8)
  self.bodies[i] = out
end

--- Inserts a record, given as its whole bytes, at position `index` (0-based); the records from
--- there move up one.
function Plugin.insert(self: Plugin, index: number, bytes: buffer | string)
  touch(self)
  local count = #self.starts
  if index < 0 or index > count or index % 1 ~= 0 then
    fail(buffer.len(self.source), 'record index out of bounds')
  end

  local data = asBuffer(bytes)
  if buffer.len(data) < RecordHeaderLength then fail(0, 'truncated record header') end

  local length = buffer.len(data) - RecordHeaderLength
  if buffer.readu32(data, 4) ~= length then
    fail(4, `record {Tags.display(buffer.readu32(data, 0))} size doesn't match its bytes`)
  end

  checkPayload(data, RecordHeaderLength, length)
  local position = if index > 0
    then select(2, self:range(index - 1))
    elseif count > 0 then (self:range(0))
    else buffer.len(self.source)
  local out = buffer.create(buffer.len(data))
  buffer.copy(out, 0, data)
  table.insert(self.starts, index + 1, -position - 1)
  table.insert(self.bodies, index + 1, out)
  table.insert(self.parts, index + 1, 3)
end

--- Deletes record `index` from the saved output.
function Plugin.delete(self: Plugin, index: number)
  touch(self)
  local i = slot(self, index)
  table.remove(self.starts, i)
  table.remove(self.bodies, i)
  table.remove(self.parts, i)
end

--- Keeps only the records `keep` accepts (called with each 0-based index, in order).
function Plugin.retain(self: Plugin, keep: (index: number) -> boolean)
  touch(self)
  local starts: { number }, bodies: { buffer | false }, parts: { number } = {}, {}, {}
  local n = 0
  for i, start in self.starts do
    if not keep(i - 1) then continue end

    n += 1
    starts[n], bodies[n], parts[n] = start, self.bodies[i], self.parts[i]
  end

  self.starts, self.bodies, self.parts = starts, bodies, parts
end

--- One subrecord's bytes, header included, as `(buffer, start, finish)` or replaced.
type Piece = { b: buffer, s: number, e: number }

local function pieces(self: Plugin, index: number): ({ Piece }, buffer, number)
  local source, start, finish = self:span(index)
  local out = {}
  local p = start + RecordHeaderLength
  while p < finish do
    local e = p + SubrecordHeaderLength + buffer.readu32(source, p + 4)
    table.insert(out, { b = source, s = p, e = e })
    p = e
  end

  return out, source, start
end

local function rebuild(
  self: Plugin,
  index: number,
  list: { Piece },
  header: buffer,
  headerAt: number
)
  local length = 0
  for _, piece in list do
    length += piece.e - piece.s
  end

  local out = buffer.create(RecordHeaderLength + length)
  buffer.copy(out, 0, header, headerAt, RecordHeaderLength)
  buffer.writeu32(out, 4, length)
  local at = RecordHeaderLength
  for _, piece in list do
    buffer.copy(out, at, piece.b, piece.s, piece.e - piece.s)
    at += piece.e - piece.s
  end

  self.bodies[slot(self, index)] = out
end

local function subrecordOutOfBounds(self: Plugin, index: number): never
  local _, _, finish = self:span(index)
  return fail(finish, 'subrecord index out of bounds')
end

local function newPiece(header: buffer, at: number, payload: buffer): Piece
  local length = buffer.len(payload)
  local b = buffer.create(SubrecordHeaderLength + length)
  buffer.copy(b, 0, header, at, 4)
  buffer.writeu32(b, 4, length)
  buffer.copy(b, SubrecordHeaderLength, payload)
  return { b = b, s = 0, e = buffer.len(b) }
end

--- Replaces subrecord `sub` (0-based) of record `index` and rebuilds the record.
function Plugin.replaceSubrecord(self: Plugin, index: number, sub: number, payload: buffer | string)
  touch(self)
  local list, header, at = pieces(self, index)
  local piece = list[sub + 1]
  if not piece or sub % 1 ~= 0 then subrecordOutOfBounds(self, index) end

  list[sub + 1] = newPiece(piece.b, piece.s, asBuffer(payload))
  rebuild(self, index, list, header, at)
end

--- Deletes subrecord `sub` of record `index`.
function Plugin.deleteSubrecord(self: Plugin, index: number, sub: number)
  touch(self)
  local list, header, at = pieces(self, index)
  if not list[sub + 1] or sub % 1 ~= 0 then subrecordOutOfBounds(self, index) end

  table.remove(list, sub + 1)
  rebuild(self, index, list, header, at)
end

--- Deletes the subrecords at `subs` (0-based, any order, repeats allowed) of record `index` in
--- one rebuild; returns how many went.
function Plugin.deleteSubrecords(self: Plugin, index: number, subs: { number }): number
  touch(self)
  local list, header, at = pieces(self, index)
  local remove: { [number]: boolean } = {}
  local count = 0
  local sorted = table.clone(subs)
  table.sort(sorted)
  for _, sub in sorted do
    if not list[sub + 1] or sub % 1 ~= 0 then
      local _, _, finish = self:span(index)
      fail(finish, `subrecord index {sub} out of bounds`)
    end

    if not remove[sub] then
      remove[sub] = true
      count += 1
    end
  end

  if count == 0 then return 0 end

  local kept = {}
  for i, piece in list do
    if not remove[i - 1] then table.insert(kept, piece) end
  end

  rebuild(self, index, kept, header, at)
  return count
end

--- Deletes every subrecord of record `index` with tag `tag`; returns how many.
function Plugin.deleteSubrecordsByTag(self: Plugin, index: number, tag: string): number
  touch(self)
  local code = Tags.code(tag)
  local list, header, at = pieces(self, index)
  local kept = {}
  for _, piece in list do
    if buffer.readu32(piece.b, piece.s) ~= code then table.insert(kept, piece) end
  end

  local count = #list - #kept
  if count > 0 then rebuild(self, index, kept, header, at) end

  return count
end

--[[ CELL references ]]

export type CellGroups = {
  --- The subrecords before the references: `[0, header)`.
  header: number,
  --- The NAM0 subrecord's position, if there is one.
  nam0: number?,
  --- Each reference's subrecords: `{ first, last }` (0-based, inclusive).
  references: { { number } },
}

local function codesOf(self: Plugin, index: number): { number }
  local source, start, finish = self:span(index)
  local codes = {}
  local p = start + RecordHeaderLength
  while p < finish do
    table.insert(codes, buffer.readu32(source, p))
    p += SubrecordHeaderLength + buffer.readu32(source, p + 4)
  end

  return codes
end

--- Where the reference whose FRMR is at `frmr` (1-based) starts: at its MVRF when it's a moved
--- reference (MVRF, an optional CNDT, then the FRMR), else at the FRMR (`Cell::getNextRef` in
--- OpenMW's `components/esm3/loadcell.cpp`).
local function movedStart(codes: { number }, frmr: number): number
  if codes[frmr - 1] == MVRF then return frmr - 1 end

  if codes[frmr - 1] == CNDT and codes[frmr - 2] == MVRF then return frmr - 2 end

  return frmr
end

--- A CELL's subrecords grouped by reference, or nil for another record.
function Plugin.cellGroups(self: Plugin, index: number): CellGroups?
  if self:code(index) ~= CELL then return nil end

  local codes = codesOf(self, index)
  local headerEnd = #codes
  local nam0: number? = nil
  local references = {}
  local current: number? = nil
  for i, code in codes do
    if code == NAM0 and not current then nam0 = i - 1 end

    if code ~= FRMR then continue end

    local start = movedStart(codes, i)
    if headerEnd == #codes then headerEnd = start - 1 end

    if current then table.insert(references, { current - 1, start - 2 }) end

    current = start
  end

  if current then table.insert(references, { current - 1, #codes - 1 }) end

  return { header = headerEnd, nam0 = nam0, references = references }
end

--- The subrecords before a CELL's first reference, `[0, n)`, or nil for another record.
function Plugin.cellHeaderSubrecords(self: Plugin, index: number): number?
  if self:code(index) ~= CELL then return nil end

  -- Walks only up to the first reference, keeping the two codes before it for `movedStart`.
  local source, start, finish = self:span(index)
  local p = start + RecordHeaderLength
  local n, previous, before = 0, 0, 0
  while p < finish do
    local code = buffer.readu32(source, p)
    if code == FRMR then
      if previous == MVRF then return n - 1 end

      if previous == CNDT and before == MVRF then return n - 2 end

      return n
    end

    before, previous = previous, code
    n += 1
    p += SubrecordHeaderLength + buffer.readu32(source, p + 4)
  end

  return n
end

--- Deletes the CELL references at `refs` (0-based) and updates NAM0; returns how many went.
function Plugin.deleteCellReferences(self: Plugin, index: number, refs: { number }): number
  touch(self)
  local groups = self:cellGroups(index)
  if not groups then return fail(self:range(index), 'record is not CELL') end

  local remove: { [number]: boolean } = {}
  for _, ref in refs do
    if not groups.references[ref + 1] then
      local _, _, finish = self:span(index)
      fail(finish, 'CELL reference index out of bounds')
    end

    remove[ref + 1] = true
  end

  local count = 0
  for _ in remove do
    count += 1
  end

  if count == 0 then return 0 end

  -- NAM0 counts the (temporary) references after it; it usually sits inside the last persistent
  -- reference's group, and stays when that reference goes.
  local codes = codesOf(self, index)
  local nam0 = table.find(codes, NAM0)
  local list, header, at = pieces(self, index)
  local dropped: { [number]: boolean } = {}
  for i, group in groups.references do
    if not remove[i] then continue end

    for sub = group[1] + 1, group[2] + 1 do
      if sub ~= nam0 then dropped[sub] = true end
    end
  end

  if nam0 then
    local remaining = 0
    for i, group in groups.references do
      if not remove[i] and group[1] + 1 > nam0 then
        remaining += 1
      end
    end

    local value = buffer.create(4)
    buffer.writeu32(value, 0, remaining)
    local piece = list[nam0]
    list[nam0] = newPiece(piece.b, piece.s, value)
  end

  local kept = {}
  for i, piece in list do
    if not dropped[i] then table.insert(kept, piece) end
  end

  rebuild(self, index, kept, header, at)
  return count
end

--[[ The TES3 header ]]

local function tes3Index(self: Plugin): number
  if #self.starts == 0 then fail(0, 'empty plugin') end

  if self:code(0) ~= TES3 then fail(self:range(0), 'first record is not TES3') end

  return 0
end

--- Whether the header's text is UTF-8: in an OpenMW save, which OpenMW writes without an
--- encoder (`StateManager::saveGame` in `apps/openmw/mwstate/statemanagerimp.cpp`), else in the
--- plugin's code page.
--- Whether a SAVE record is there, and how many TES3 headers: walked once per revision.
local function codeFacts(self: Plugin): (boolean, number)
  local facts = self.facts
  if facts and facts.revision == self.revision then return facts.save, facts.headers end

  local save, headers = false, 0
  local source, bodies = self.source, self.bodies
  for i, start in self.starts do
    local body = bodies[i]
    local code = if body then buffer.readu32(body, 0) else buffer.readu32(source, start)
    if code == SAVE then
      save = true
    elseif code == TES3 then
      headers += 1
    end
  end

  self.facts = { revision = self.revision, save = save, headers = headers }
  return save, headers
end

local function headerIsUtf8(self: Plugin): boolean
  if self.profile == 'omwsave' then return true end

  return (codeFacts(self))
end

--- Bytes as UTF-8, invalid sequences replaced by U+FFFD the way Rust's `from_utf8_lossy` does.
local function lossyUtf8(text: string): string
  if utf8.len(text) then return text end

  local out = {}
  local i, n = 1, #text
  while i <= n do
    local byte = string.byte(text, i)
    local width, low, high = 0, 0x80, 0xbf
    if byte < 0x80 then
      width = 1
    elseif byte >= 0xc2 and byte <= 0xdf then
      width = 2
    elseif byte >= 0xe0 and byte <= 0xef then
      width = 3
      if byte == 0xe0 then
        low = 0xa0
      elseif byte == 0xed then
        high = 0x9f
      end
    elseif byte >= 0xf0 and byte <= 0xf4 then
      width = 4
      if byte == 0xf0 then
        low = 0x90
      elseif byte == 0xf4 then
        high = 0x8f
      end
    end

    if width == 0 then
      table.insert(out, '\u{FFFD}')
      i += 1
      continue
    end

    local good = 1
    for k = 1, width - 1 do
      local next = string.byte(text, i + k)
      local from, to = if k == 1 then low else 0x80, if k == 1 then high else 0xbf
      if not next or next < from or next > to then break end

      good += 1
    end

    if good == width then
      table.insert(out, string.sub(text, i, i + width - 1))
    else
      table.insert(out, '\u{FFFD}')
    end

    i += good
  end

  return table.concat(out)
end

local function headerDecode(
  self: Plugin,
  utf: boolean,
  source: buffer,
  offset: number,
  length: number
): string
  if not utf then return Text.decode(source, offset, length, self.encoding) end

  local text = buffer.readstring(source, offset, length)
  local nul = string.find(text, '\0', 1, true)
  if nul then text = string.sub(text, 1, nul - 1) end

  return lossyUtf8(text)
end

--- Encodes a string field's new value for `field` (`BOOK TEXT`), NUL-terminated when `nul`.
local function encodeField(
  encoding: string,
  value: string,
  nul: boolean,
  field: string,
  offset: number
): string
  if string.find(value, '\0', 1, true) then
    fail(offset, `{field}: string field replacement contains NUL`)
  end

  local encoded, missing = Text.encode(value, encoding)
  if not encoded then
    local what = if missing then Text.describe(missing) else 'the text'
    return fail(
      offset,
      `{field}: {what} can't be written in {Text.name(encoding)}, the plugin's encoding`
    )
  end

  return if nul then encoded .. '\0' else encoded
end

local function headerEncode(
  self: Plugin,
  utf: boolean,
  value: string,
  field: string,
  offset: number
): string
  if not utf then return encodeField(self.encoding, value, false, field, offset) end

  if string.find(value, '\0', 1, true) then
    fail(offset, `{field}: string field replacement contains NUL`)
  end

  return value
end

--- The `FORM` format version in the TES3 record; 0 without one.
function Plugin.formatVersion(self: Plugin): number
  tes3Index(self)
  local source, at, size = self:findSubrecord(0, FORM)
  if not source then return 0 end

  if size ~= 4 then fail(at, 'FORM payload is not 4 bytes') end

  return buffer.readu32(source, at)
end

local function hedr(self: Plugin): (buffer, number, number)
  tes3Index(self)
  local source, at, size = self:findSubrecord(0, HEDR)
  if not source then
    local _, start = self:span(0)
    fail(start + RecordHeaderLength, 'TES3 record has no HEDR subrecord')
  end

  return source :: buffer, at, size
end

--- Where a size-prefixed header string at `cursor` (relative to the HEDR payload) is.
local function sizedString(
  source: buffer,
  at: number,
  size: number,
  cursor: number
): (number, number)
  if cursor + 4 > size then fail(at + cursor, 'truncated HEDR string size') end

  local start = cursor + 4
  local finish = start + buffer.readu32(source, at + cursor)
  if finish > size then fail(at + start, 'HEDR string extends past payload') end

  return start, finish
end

local FileTypes: { [number]: FileType } = { [0] = 'plugin', [1] = 'master', [32] = 'save' }

--- The TES3 header's HEDR fields. Its text is decoded from the plugin's encoding, or from UTF-8
--- in an OpenMW save.
function Plugin.header(self: Plugin): Header
  local source, at, size = hedr(self)
  local variable = self:formatVersion() > MaxLimitedSizeStringsFormat
  local utf = headerIsUtf8(self)
  if size < 4 then fail(at, 'truncated HEDR version') end

  local version = buffer.readf32(source, at)
  if size < 8 then fail(at + HedrFileTypeOffset, 'truncated HEDR file type') end

  local typeValue = buffer.readu32(source, at + HedrFileTypeOffset)
  local fileType = FileTypes[typeValue]
  if not fileType then fail(at + HedrFileTypeOffset, `invalid TES3 file type {typeValue}`) end

  local author, description, recordCount
  if variable then
    local a, b = sizedString(source, at, size, HedrAuthorOffset)
    local c, d = sizedString(source, at, size, b)
    if d + 4 > size then fail(at + d, 'truncated HEDR record count') end

    author = headerDecode(self, utf, source, at + a, b - a)
    description = headerDecode(self, utf, source, at + c, d - c)
    recordCount = buffer.readu32(source, at + d)
  else
    if size < HedrLength then fail(at, 'HEDR payload is too short') end

    author = headerDecode(self, utf, source, at + HedrAuthorOffset, HedrAuthorLength)
    description = headerDecode(self, utf, source, at + HedrDescriptionOffset, HedrDescriptionLength)
    recordCount = buffer.readu32(source, at + HedrRecordCountOffset)
  end

  return {
    version = version,
    fileType = fileType,
    author = author,
    description = description,
    recordCount = recordCount,
  }
end

--- The TES3 master list: each MAST and the DATA after it.
function Plugin.masters(self: Plugin): { Master }
  tes3Index(self)
  local utf = headerIsUtf8(self)
  local subs = self:subrecords(0)
  local source = self:span(0)
  local out = {}
  local i = 1
  while i <= #subs do
    local sub = subs[i]
    if sub.code ~= MAST then
      i += 1
      continue
    end

    local data = subs[i + 1]
    if not data then fail(sub.start, 'TES3 MAST subrecord is missing following DATA') end

    if data.code ~= DATA then fail(data.start, 'TES3 MAST subrecord is not followed by DATA') end

    if data.size ~= 8 then fail(data.payload, 'TES3 master DATA payload is not 8 bytes') end

    table.insert(out, {
      name = headerDecode(self, utf, source, sub.payload, sub.size),
      size = buffer.readu32(source, data.payload)
        + buffer.readu32(source, data.payload + 4) * 4294967296,
      mast = i - 1,
      data = i,
    })
    i += 2
  end

  return out
end

local function updateHedr(self: Plugin, update: (payload: buffer) -> ())
  local source, at, size = hedr(self)
  local payload = buffer.create(size)
  buffer.copy(payload, 0, source, at, size)
  update(payload)
  for i, sub in self:subrecords(0) do
    if sub.code == HEDR then
      self:replaceSubrecord(0, i - 1, payload)
      return
    end
  end
end

local function u64(value: number): buffer
  local out = buffer.create(8)
  buffer.writeu32(out, 0, value % 4294967296)
  buffer.writeu32(out, 4, value // 4294967296)
  return out
end

--- Sets the stored size of the master named `name` (ignoring ASCII case); whether it changed.
function Plugin.setMasterSize(self: Plugin, name: string, size: number): boolean
  local lower = string.lower(name)
  for _, master in self:masters() do
    if string.lower(master.name) ~= lower then continue end

    if master.size == size then return false end

    self:replaceSubrecord(0, master.data, u64(size))
    return true
  end

  return false
end

--- Replaces the master list with `masters` (`{ name, size }`, in load order), MAST/DATA pairs
--- after HEDR like the game writes them, keeping every other header subrecord. A master already in
--- the list keeps its MAST bytes. Whether it changed.
function Plugin.setMasters(self: Plugin, masters: { { name: string, size: number } }): boolean
  local current = self:masters()
  if #current == #masters then
    local same = true
    for i, master in current do
      if master.name ~= masters[i].name or master.size ~= masters[i].size then
        same = false
        break
      end
    end

    if same then return false end
  end

  local utf = headerIsUtf8(self)
  local source, start = self:span(0)
  local subs = self:subrecords(0)
  local kept: { [number]: boolean } = {}
  local names: { string } = {}
  for _, master in masters do
    local found: string? = nil
    for k, old in current do
      if kept[k] or old.name ~= master.name then continue end

      kept[k] = true
      local sub = subs[old.mast + 1]
      found = buffer.readstring(source, sub.payload, sub.size)
      break
    end

    table.insert(names, found or (headerEncode(self, utf, master.name, 'TES3 MAST', start) .. '\0'))
  end

  local w = Writer.new(buffer.len(source))
  local function push(code: number, data: string)
    Writer.u32(w, code)
    Writer.u32(w, #data)
    Writer.string(w, data)
  end

  for _, sub in subs do
    if sub.code == MAST or sub.code == DATA then continue end

    push(sub.code, buffer.readstring(source, sub.payload, sub.size))
    if sub.code ~= HEDR then continue end

    for k, name in names do
      push(MAST, name)
      push(DATA, buffer.tostring(u64(masters[k].size)))
    end
  end

  self:replacePayload(0, Writer.finish(w))
  return true
end

local function recordCountOffset(
  source: buffer,
  at: number,
  size: number,
  variable: boolean
): number
  if not variable then
    if size < HedrLength then fail(at, 'HEDR payload is too short') end

    return HedrRecordCountOffset
  end

  local _, b = sizedString(source, at, size, HedrAuthorOffset)
  local _, d = sizedString(source, at, size, b)
  if d + 4 > size then fail(at + d, 'truncated HEDR record count') end

  return d
end

--- Sets the HEDR record count to the records the plugin holds, header aside; whether it changed.
function Plugin.updateRecordCount(self: Plugin): boolean
  local _, headers = codeFacts(self)
  local count = #self.starts - headers

  if self:header().recordCount == count then return false end

  local source, at, size = hedr(self)
  local offset =
    recordCountOffset(source, at, size, self:formatVersion() > MaxLimitedSizeStringsFormat)
  updateHedr(self, function(payload) buffer.writeu32(payload, offset, count) end)
  return true
end

--- After an edit that added or removed records (`changed`), sets the record count, unless `mode`
--- is `'keep'` (a plugin only partly loaded counts what it left out) or there's no TES3 header.
--- Whether the count changed.
function Plugin.applyRecordCount(self: Plugin, mode: 'update' | 'keep', changed: boolean): boolean
  if mode ~= 'update' or not changed or #self.starts == 0 or self:code(0) ~= TES3 then
    return false
  end

  return self:updateRecordCount()
end

local FileTypeValues: { [string]: number } = { plugin = 0, master = 1, save = 32 }

--- Sets the HEDR file type; whether it changed.
function Plugin.setFileType(self: Plugin, fileType: FileType): boolean
  local value = FileTypeValues[fileType] or error(`unknown file type '{fileType}'`)
  if self:header().fileType == fileType then return false end

  updateHedr(self, function(payload) buffer.writeu32(payload, HedrFileTypeOffset, value) end)
  return true
end

--- `\n` and `\r` spelled with a backslash become the characters; a leading `+` appends.
local function resolveUpdate(current: string, update: string): string
  update = string.gsub(string.gsub(update, '\\n', '\n'), '\\r', '\r')
  if string.sub(update, 1, 1) == '+' then return current .. string.sub(update, 2) end

  return update
end

local function setHeaderText(self: Plugin, which: 'author' | 'description', value: string): boolean
  local source, at = hedr(self)
  if self:formatVersion() > MaxLimitedSizeStringsFormat then
    fail(at, `updating variable-size HEDR {which} strings is not supported`)
  end

  local header = self:header()
  local current = if which == 'author' then header.author else header.description
  local text = resolveUpdate(current, value)
  if text == current then return false end

  local offset = if which == 'author' then HedrAuthorOffset else HedrDescriptionOffset
  local length = if which == 'author' then HedrAuthorLength else HedrDescriptionLength
  local field = `TES3 HEDR {which}`
  local encoded = headerEncode(self, headerIsUtf8(self), text, field, at + offset)
  if #encoded >= length then
    fail(at + offset, `header string is too long for {length}-byte field`)
  end

  updateHedr(self, function(payload)
    buffer.fill(payload, offset, 0, length)
    buffer.writestring(payload, offset, encoded)
  end)
  return true
end

--- Sets the HEDR author (`\n` escapes and a leading `+` to append); whether it changed.
function Plugin.setAuthor(self: Plugin, author: string): boolean
  return setHeaderText(self, 'author', author)
end

--- Sets the HEDR description, like `setAuthor`.
function Plugin.setDescription(self: Plugin, description: string): boolean
  return setHeaderText(self, 'description', description)
end

--- Replaces a string subrecord's value, encoded in the plugin's encoding, NUL-terminated when its
--- old payload was.
function Plugin.replaceString(self: Plugin, index: number, sub: number, value: string)
  local subs = self:subrecords(index)
  local entry = subs[sub + 1]
  if not entry or sub % 1 ~= 0 then subrecordOutOfBounds(self, index) end

  local source = self:span(index)
  local nul = entry.size > 0 and buffer.readu8(source, entry.finish - 1) == 0
  local field = `{Tags.display(self:code(index))} {Tags.display(entry.code)}`
  local payload = encodeField(self.encoding, value, nul, field, entry.payload)
  self:replaceSubrecord(index, sub, payload)
end

--- Replaces several typed string fields of record `index` at once (`subrecord` 0-based), each
--- encoded as `replaceString` encodes it, rebuilding the record once.
function Plugin.replaceStrings(
  self: Plugin,
  index: number,
  changes: { { subrecord: number, value: string } }
)
  if #changes == 0 then return end

  touch(self)
  local list, header, at = pieces(self, index)
  local code = Tags.display(self:code(index))
  for _, change in changes do
    local sub = change.subrecord
    local piece = list[sub + 1]
    if not piece or sub % 1 ~= 0 then subrecordOutOfBounds(self, index) end

    local size = piece.e - piece.s - SubrecordHeaderLength
    local nul = size > 0 and buffer.readu8(piece.b, piece.e - 1) == 0
    local field = `{code} {Tags.display(buffer.readu32(piece.b, piece.s))}`
    local payload =
      encodeField(self.encoding, change.value, nul, field, piece.s + SubrecordHeaderLength)
    list[sub + 1] = newPiece(piece.b, piece.s, asBuffer(payload))
  end

  rebuild(self, index, list, header, at)
end

--[[ Profiles ]]

local Vanilla: { [string]: { string } } = {
  TES3 = { 'HEDR', 'MAST', 'DATA' },
  ACTI = { 'NAME', 'MODL', 'FNAM', 'SCRI', 'DELE' },
  ALCH = { 'NAME', 'MODL', 'TEXT', 'SCRI', 'FNAM', 'ALDT', 'ENAM', 'DELE' },
  APPA = { 'NAME', 'MODL', 'FNAM', 'AADT', 'SCRI', 'ITEX', 'DELE' },
  ARMO = { 'NAME', 'MODL', 'FNAM', 'AODT', 'SCRI', 'ITEX', 'ENAM', 'INDX', 'BNAM', 'CNAM', 'DELE' },
  BODY = { 'NAME', 'MODL', 'FNAM', 'BYDT', 'DELE' },
  BOOK = { 'NAME', 'MODL', 'FNAM', 'BKDT', 'SCRI', 'ITEX', 'ENAM', 'TEXT', 'DELE' },
  BSGN = { 'NAME', 'FNAM', 'TNAM', 'DESC', 'NPCS', 'DELE' },
  CELL = {
    'NAME',
    'DATA',
    'DELE',
    'INTV',
    'WHGT',
    'AMBI',
    'RGNN',
    'NAM5',
    'NAM0',
    'MVRF',
    'CNDT',
    'FRMR',
    'UNAM',
    'XSCL',
    'ANAM',
    'BNAM',
    'XSOL',
    'CNAM',
    'INDX',
    'XCHG',
    'NAM9',
    'DODT',
    'DNAM',
    'FLTV',
    'KNAM',
    'TNAM',
  },
  CLAS = { 'NAME', 'FNAM', 'CLDT', 'DESC', 'DELE' },
  CLOT = { 'NAME', 'MODL', 'FNAM', 'CTDT', 'SCRI', 'ITEX', 'ENAM', 'INDX', 'BNAM', 'CNAM', 'DELE' },
  CONT = { 'NAME', 'MODL', 'FNAM', 'CNDT', 'FLAG', 'SCRI', 'NPCO', 'DELE' },
  CREA = {
    'NAME',
    'MODL',
    'CNAM',
    'FNAM',
    'SCRI',
    'NPDT',
    'FLAG',
    'XSCL',
    'NPCO',
    'NPCS',
    'AIDT',
    'DODT',
    'DNAM',
    'AI_W',
    'AI_T',
    'AI_F',
    'AI_E',
    'AI_A',
    'CNDT',
    'DELE',
    'INDX',
  },
  DIAL = { 'NAME', 'DATA', 'DELE' },
  DOOR = { 'NAME', 'MODL', 'FNAM', 'SCRI', 'SNAM', 'ANAM', 'DELE' },
  ENCH = { 'NAME', 'ENDT', 'ENAM', 'DELE' },
  FACT = { 'NAME', 'FNAM', 'RNAM', 'FADT', 'ANAM', 'INTV', 'DELE' },
  GLOB = { 'NAME', 'DELE', 'FNAM', 'FLTV' },
  GMST = { 'NAME', 'STRV', 'INTV', 'FLTV' },
  INFO = {
    'INAM',
    'PNAM',
    'NNAM',
    'DATA',
    'ONAM',
    'RNAM',
    'CNAM',
    'FNAM',
    'ANAM',
    'DNAM',
    'SNAM',
    'NAME',
    'SCVR',
    'INTV',
    'FLTV',
    'BNAM',
    'QSTN',
    'QSTF',
    'QSTR',
    'DELE',
  },
  INGR = { 'NAME', 'MODL', 'FNAM', 'IRDT', 'SCRI', 'ITEX', 'DELE' },
  LAND = { 'INTV', 'DATA', 'DELE', 'VNML', 'VHGT', 'WNAM', 'VCLR', 'VTEX' },
  LEVC = { 'NAME', 'DATA', 'NNAM', 'INDX', 'CNAM', 'INTV', 'DELE' },
  LEVI = { 'NAME', 'DATA', 'NNAM', 'INDX', 'INAM', 'INTV', 'DELE' },
  LIGH = { 'NAME', 'MODL', 'FNAM', 'ITEX', 'LHDT', 'SCRI', 'SNAM', 'DELE' },
  LOCK = { 'NAME', 'MODL', 'FNAM', 'LKDT', 'SCRI', 'ITEX', 'DELE' },
  LTEX = { 'NAME', 'INTV', 'DATA', 'DELE' },
  MGEF = {
    'INDX',
    'MEDT',
    'ITEX',
    'PTEX',
    'BSND',
    'CSND',
    'HSND',
    'ASND',
    'CVFX',
    'BVFX',
    'HVFX',
    'AVFX',
    'DESC',
  },
  MISC = { 'NAME', 'MODL', 'FNAM', 'MCDT', 'SCRI', 'ITEX', 'DELE' },
  NPC_ = {
    'NAME',
    'MODL',
    'FNAM',
    'RNAM',
    'CNAM',
    'ANAM',
    'BNAM',
    'KNAM',
    'SCRI',
    'NPDT',
    'FLAG',
    'NPCS',
    'NPCO',
    'AIDT',
    'DODT',
    'DNAM',
    'AI_W',
    'AI_T',
    'AI_F',
    'AI_E',
    'AI_A',
    'CNDT',
    'DELE',
  },
  PGRD = { 'NAME', 'DATA', 'PGRP', 'PGRC', 'DELE' },
  PROB = { 'NAME', 'MODL', 'FNAM', 'PBDT', 'SCRI', 'ITEX', 'DELE' },
  RACE = { 'NAME', 'FNAM', 'RADT', 'DESC', 'NPCS', 'DELE' },
  REGN = { 'NAME', 'FNAM', 'WEAT', 'BNAM', 'CNAM', 'SNAM', 'DELE' },
  REPA = { 'NAME', 'MODL', 'FNAM', 'RIDT', 'SCRI', 'ITEX', 'DELE' },
  SCPT = { 'SCHD', 'SCVR', 'SCDT', 'SCTX', 'DELE' },
  SKIL = { 'INDX', 'SKDT', 'DESC' },
  SNDG = { 'NAME', 'DATA', 'CNAM', 'SNAM', 'DELE' },
  SOUN = { 'NAME', 'FNAM', 'DATA', 'DELE' },
  SPEL = { 'NAME', 'FNAM', 'SPDT', 'ENAM', 'DELE' },
  SSCR = { 'NAME', 'DATA', 'DELE' },
  STAT = { 'NAME', 'MODL', 'DELE' },
  WEAP = { 'NAME', 'MODL', 'FNAM', 'WPDT', 'SCRI', 'ITEX', 'ENAM', 'DELE' },
}

local VanillaSets: { [number]: { [number]: boolean } } = {}
for tag, list in Vanilla do
  local set = {}
  for _, sub in list do
    set[Tags.code(sub)] = true
  end

  VanillaSets[Tags.code(tag)] = set
end

local OpenMwRecords: { [number]: boolean } = {}
for _, tag in { 'LUAL', 'FILT', 'DBGP', 'SELG', 'ATTR', 'WTYP' } do
  OpenMwRecords[Tags.code(tag)] = true
end

--- Subrecords OpenMW adds to vanilla record types; `'*'` is an extension in any record.
local OpenMwSubrecords: { { string } } = {
  { 'TES3', 'FORM' },
  { '*', 'ENID' },
  { '*', 'ENSK' },
  { '*', 'ENAT' },
  { 'DIAL', 'ID__' },
  { '*', 'ATTR' },
  { '*', 'MASK' },
  { '*', 'MISK' },
  { 'BOOK', 'SKIL' },
  { 'FACT', 'SKIL' },
  { 'NPC_', 'SKIL' },
  { 'RACE', 'SKIL' },
}

local function isOpenMwSubrecord(record: string, sub: string): boolean
  for _, entry in OpenMwSubrecords do
    if entry[2] == sub and (entry[1] == '*' or entry[1] == record) then return true end
  end

  return false
end

--- Vanilla-format problems in one record: an OpenMW-only or unknown record type, or subrecords
--- the original format doesn't have.
function Plugin.recordProfileDiagnostics(
  self: Plugin,
  index: number,
  profile: Profile
): { Diagnostic }
  if profile ~= 'tes3' then return {} end

  local code = self:code(index)
  local allowed = VanillaSets[code]
  local display = Tags.display(code)
  if not allowed then
    local what = if OpenMwRecords[code]
      then 'is an OpenMW-only record type'
      else 'is not a Morrowind record type'
    return { { offset = (self:range(index)), message = `{display} {what}` } }
  end

  local out = {}
  local dirty = self:isDirty(index)
  local _, origin = self:range(index)
  for _, sub in self:subrecords(index) do
    if allowed[sub.code] then continue end

    local what = if isOpenMwSubrecord(Tags.name(code), sub.tag)
      then 'is an OpenMW extension'
      else 'is not part of the Morrowind format'
    local offset = if dirty then origin else sub.start
    table.insert(out, { offset = offset, message = `{display}.{Tags.display(sub.code)} {what}` })
  end

  return out
end

--- What each profile checks, by name.
local Checks: { [string]: { string } } = {
  raw = { 'structure' },
  omwsave = { 'structure' },
  tes3 = { 'structure', 'morrowind_format' },
  omwaddon = { 'structure', 'openmw_record_types', 'dialogue_order' },
}

local function checks(profile: Profile): { string }
  return Checks[profile] or error(`unknown profile '{profile}'`)
end

local OpenMwLoads: { [number]: boolean } = { [Tags.code 'WTYP'] = true, [Tags.code 'ATTR'] = true }
for code in VanillaSets do
  OpenMwLoads[code] = true
end

local Ignore: { [number]: boolean } = {}
for _, tag in { 'MGEF', 'SKIL', 'FILT', 'DBGP', 'LUAL' } do
  Ignore[Tags.code(tag)] = true
end

local DIAL, INFO = Tags.code 'DIAL', Tags.code 'INFO'

--- Where a problem in a record is, in the original bytes when it has any.
local function errorOffset(message: string): (number, string)
  local text, offset = string.match(message, '^(.*) at offset (%d+)$')
  if text then return tonumber(offset) :: number, text end

  return 0, message
end

--- Checks the plugin against `profile` as far as framing and tags tell: every profile checks the
--- structure every engine relies on (a readable TES3 header first and nowhere else, well-formed
--- masters, tags that are text); `tes3` adds what vanilla Morrowind doesn't know, `omwaddon` what
--- OpenMW's content loader refuses or skips (`ESMStore::load` in `mwworld/esmstore.cpp`).
function Plugin.validateProfile(self: Plugin, profile: Profile): { Diagnostic }
  checks(profile)
  local out: { Diagnostic } = {}
  local count = #self.starts
  if count == 0 then
    table.insert(out, { offset = 0, message = 'the file has no records, not even a TES3 header' })
  elseif self:code(0) ~= TES3 then
    table.insert(out, {
      offset = (self:range(0)),
      message = `the first record is {Tags.display(self:code(0))}, not the TES3 header`,
    })
  else
    for _, check in { Plugin.header, Plugin.masters } :: { (Plugin) -> any } do
      local ok, problem = pcall(check, self)
      if ok then continue end

      local offset, message = errorOffset(tostring(problem))
      table.insert(out, { offset = offset, message = message })
    end
  end

  for i = 1, count - 1 do
    if self:code(i) == TES3 then
      table.insert(out, { offset = (self:range(i)), message = 'a second TES3 header' })
    end
  end

  for i = 0, count - 1 do
    local code = self:code(i)
    local start = self:range(i)
    if not Tags.isText(code) then
      local name = Tags.name(code)
      table.insert(out, {
        offset = start,
        message = `record type [{string.byte(name, 1)}, {string.byte(name, 2)}, {string.byte(
          name,
          3
        )}, {string.byte(name, 4)}] isn't text; the file is damaged here`,
      })
      continue
    end

    local dirty = self:isDirty(i)
    local _, origin = self:range(i)
    for _, sub in self:subrecords(i) do
      if Tags.isText(sub.code) then continue end

      local name = sub.tag
      table.insert(out, {
        offset = if dirty then origin else sub.start,
        message = `{Tags.display(code)} subrecord type [{string.byte(name, 1)}, {string.byte(
          name,
          2
        )}, {string.byte(name, 3)}, {string.byte(name, 4)}] isn't text; the record is damaged here`,
      })
    end
  end

  if profile == 'tes3' then
    for i = 0, count - 1 do
      for _, diagnostic in self:recordProfileDiagnostics(i, 'tes3') do
        table.insert(out, diagnostic)
      end
    end
  elseif profile == 'omwaddon' then
    local inDialogue = false
    for i = 1, count - 1 do
      local code = self:code(i)
      if bit32.btest(self:flags(i), FlagIgnored) or code == TES3 then continue end

      if code == INFO then
        if not inDialogue then
          table.insert(out, {
            offset = (self:range(i)),
            message = 'INFO has no DIAL before it; OpenMW skips it ("info record without dialog")',
          })
        end
      elseif Ignore[code] then
      -- Loaded outside the stores, leaving the current topic alone.
      elseif code == DIAL then
        inDialogue = true
      elseif OpenMwLoads[code] then
        inDialogue = false
      else
        table.insert(out, {
          offset = (self:range(i)),
          message = `{Tags.display(code)} isn't a record type OpenMW loads; it refuses the file ("Unknown record")`,
        })
      end
    end
  end

  return out
end

--[[ Typed records ]]

--- Record `index` decoded, or nil for a tag no record type has.
function Plugin.decode(self: Plugin, index: number): Value?
  local source, start, finish = self:span(index)
  return Decode.decode(source, start, finish, self.encoding)
end

--- A record value's bytes in this plugin's encoding.
function Plugin.encode(self: Plugin, value: Value): buffer
  return Encode.encode(value, self.encoding)
end

--- Writes `value` over record `index` (of the same type), re-encoding only the subrecords that
--- changed (`writeback.luau`); whether anything did.
function Plugin.set(self: Plugin, index: number, value: Value): boolean
  local code = self:code(index)
  if not Decode.typeName(Tags.name(code)) then
    fail(self:range(index), `record {index} is a {Tags.display(code)}, which has no typed form`)
  end

  local problem = self:recordProfileDiagnostics(index, self.profile)[1]
  if problem then fail(problem.offset, problem.message) end

  local encoded = Encode.encode(value, self.encoding)
  if buffer.readu32(encoded, 0) ~= code then
    fail(
      self:range(index),
      `record {index} is a {Tags.display(code)}, not a {Tags.display(buffer.readu32(encoded, 0))}`
    )
  end

  local original = buffer.tostring(self:bytes(index))
  local bytes = buffer.tostring(encoded)
  -- A record that doesn't decode is replaced whole, as jess-omwaddon's editor does.
  local decoded, old =
    pcall(Decode.decode, buffer.fromstring(original), 0, #original, self.encoding)
  if decoded and old then
    local oldEncoded = buffer.tostring(Encode.encode(old, self.encoding))
    local minimal = Writeback.minimal(original, oldEncoded, bytes, self.encoding)
    if not minimal then return false end

    bytes = minimal
  end

  self:replaceBytes(index, bytes)
  return true
end

--- Inserts a record value at `index` (0-based); the records from there move up one.
function Plugin.insertValue(self: Plugin, index: number, value: Value)
  self:insert(index, Encode.encode(value, self.encoding))
end

--[[ Building ]]

--- An empty plugin: a version 1.3 TES3 header with no masters or records.
local function new(fileType: FileType?, options: OpenOptions?): Plugin
  local hedrPayload = buffer.create(HedrLength)
  buffer.writef32(hedrPayload, 0, 1.3)
  buffer.writeu32(hedrPayload, HedrFileTypeOffset, if fileType == 'master' then 1 else 0)
  local bytes = buffer.create(RecordHeaderLength + SubrecordHeaderLength + HedrLength)
  buffer.writeu32(bytes, 0, TES3)
  buffer.writeu32(bytes, 4, SubrecordHeaderLength + HedrLength)
  buffer.writeu32(bytes, RecordHeaderLength, HEDR)
  buffer.writeu32(bytes, RecordHeaderLength + 4, HedrLength)
  buffer.copy(bytes, RecordHeaderLength + SubrecordHeaderLength, hedrPayload)
  return parse(bytes, options)
end

--- Checks that opening and saving `bytes` gives them back: byte for byte, or with `excluded`
--- record types left out of both sides, record by record. `ignoreCruft` skips anything before the
--- first `TES3`. Returns nil, or why not.
local function checkRoundTrip(bytes: buffer, excluded: { string }?, ignoreCruft: boolean?): string?
  local source = bytes
  if ignoreCruft then
    local text = buffer.tostring(bytes)
    local at = string.find(text, 'TES3', 1, true)
    if at and at > 1 then
      source = buffer.create(buffer.len(bytes) - at + 1)
      buffer.copy(source, 0, bytes, at - 1)
    end
  end

  local ok, plugin = pcall(parse, source, nil)
  if not ok then return `failed to parse plugin: {plugin}` end

  local saved = (plugin :: Plugin):save()
  if not excluded or #excluded == 0 then
    if buffer.tostring(saved) == buffer.tostring(source) then return nil end

    return 'codec changed bytes'
  end

  local skip: { [number]: boolean } = {}
  for _, tag in excluded do
    skip[Tags.code(tag)] = true
  end

  local function filtered(p: Plugin): string
    local parts = {}
    for i = 0, p:count() - 1 do
      if not skip[p:code(i)] then table.insert(parts, buffer.tostring(p:bytes(i))) end
    end

    return table.concat(parts)
  end

  local reopened, again = pcall(parse, saved, nil)
  if not reopened then return `failed to parse plugin: {again}` end

  if filtered(again :: Plugin) == filtered(plugin :: Plugin) then return nil end

  return 'codec changed bytes'
end

return table.freeze {
  Plugin = Plugin,
  checkRoundTrip = checkRoundTrip,
  checks = checks,
  lossyUtf8 = lossyUtf8,
  new = new,
  parse = parse,
}
