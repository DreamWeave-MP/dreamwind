--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Plugin lint checks and safe cleaning (jess-omwaddon's `lint`, tes3cmd's `lint` and `clean`).
`lint` reports findings for the checks asked for; `clean` removes the safe subset (duplicate
records, evil GMSTs, junk cells, duplicate cell parameters). Checks that compare with master files
find them through a master source (`masters.luau`).
]]

local Masters = require './masters'
local Numbers = require './numbers'
local bytes = require '@dream/bytes'
local intern = require '@dream/intern'
local tes3 = require '@dreamwind/tes3'

type Plugin = tes3.Plugin
type Source = Masters.Source

export type Severity = 'error' | 'warning' | 'info'
--- A finding; `check` is the check's camelCase name, as jess's Luau API spells it.
export type Finding = { check: string, severity: Severity, message: string }

--- Every check, by label, in declaration order, with its severity and whether it needs masters.
local Checks: { { label: string, severity: Severity, masters: boolean } } = {
  { label = 'duplicate-records', severity = 'warning', masters = false },
  { label = 'evil-gmsts', severity = 'warning', masters = false },
  { label = 'cell-params', severity = 'warning', masters = false },
  { label = 'junk-cells', severity = 'warning', masters = false },
  { label = 'record-count', severity = 'warning', masters = false },
  { label = 'missing-author', severity = 'info', masters = false },
  { label = 'missing-description', severity = 'info', masters = false },
  { label = 'missing-master', severity = 'error', masters = true },
  { label = 'master-sync', severity = 'warning', masters = true },
  { label = 'missing-version', severity = 'info', masters = false },
  { label = 'overrides', severity = 'info', masters = true },
  { label = 'fogbug', severity = 'warning', masters = false },
  { label = 'fogsync', severity = 'warning', masters = false },
  { label = 'autocalc-spells', severity = 'info', masters = false },
  { label = 'bloodmoon-dependency', severity = 'error', masters = false },
  { label = 'cell-00', severity = 'warning', masters = false },
  { label = 'deprecated-lists', severity = 'warning', masters = false },
  { label = 'dialogue-teleports', severity = 'warning', masters = false },
  { label = 'duplicate-info', severity = 'warning', masters = false },
  { label = 'expansion-dependency', severity = 'error', masters = false },
  { label = 'getsoundplaying', severity = 'info', masters = false },
  { label = 'menumode', severity = 'info', masters = false },
  { label = 'modified-info', severity = 'warning', masters = true },
  { label = 'modified-info-id', severity = 'warning', masters = false },
  { label = 'no-bloodmoon-functions', severity = 'info', masters = false },
  { label = 'no-tribunal-functions', severity = 'info', masters = false },
  { label = 'scripted-doors', severity = 'info', masters = false },
}

local Recommended = {
  'junk-cells',
  'missing-version',
  'fogbug',
  'fogsync',
  'bloodmoon-dependency',
  'deprecated-lists',
  'dialogue-teleports',
  'expansion-dependency',
  'modified-info-id',
}

local Severities: { [string]: Severity } = {}
local NeedsMasters: { [string]: boolean } = {}
for _, check in Checks do
  Severities[check.label] = check.severity
  NeedsMasters[check.label] = check.masters
end

--- A label as scripts spell it (jess-omwaddon's `camel_case_name`), dropping every separator:
--- `evilGmsts`, `cell00`.
local function camelCase(label: string): string
  return (string.gsub(label, '[-_](.?)', string.upper))
end

--- The check's label (`duplicate-records`) for any of its spellings: label, `snake_case`, or camelCase.
local function parseCheck(name: string): string
  for _, check in Checks do
    local label = check.label
    if name == label or name == string.gsub(label, '-', '_') or name == camelCase(label) then
      return label
    end
  end

  return error(`unknown lint check '{name}'`, 0)
end

export type CheckSet = { [string]: boolean }

--- The checks a preset (`all` or `recommended`) names.
local function preset(name: string): CheckSet
  local set: CheckSet = {}
  if name == 'all' then
    for _, check in Checks do
      set[check.label] = true
    end
  elseif name == 'recommended' then
    for _, label in Recommended do
      set[label] = true
    end
  else
    error(`unknown preset '{name}': expected all or recommended`, 0)
  end

  return set
end

--- The checks named (any spelling), or the recommended ones when none are.
local function checks(names: { string }?): CheckSet
  if not names or #names == 0 then return preset 'recommended' end

  local set: CheckSet = {}
  for _, name in names do
    set[parseCheck(name)] = true
  end

  return set
end

local function finding(check: string, message: string): Finding
  return { check = camelCase(check), severity = Severities[check], message = message }
end

local function display(plugin: Plugin, index: number): string
  return tes3.tags.display(plugin:code(index))
end

local function idOf(plugin: Plugin, index: number): string
  return tes3.records.id(plugin, index) or ''
end

--- Whether a description has a line that starts with `version` (ignoring case and indent).
local function hasVersion(description: string): boolean
  for line in string.gmatch(description .. '\n', '([^\n]*)\n') do
    line = string.gsub(line, '\r$', '')
    if string.sub(string.lower(string.match(line, '^%s*(.*)$') :: string), 1, 7) == 'version' then
      return true
    end
  end

  return false
end

local CELL, GMST, SPEL, SCPT, INFO, DOOR, TES3 =
  tes3.tags.code 'CELL',
  tes3.tags.code 'GMST',
  tes3.tags.code 'SPEL',
  tes3.tags.code 'SCPT',
  tes3.tags.code 'INFO',
  tes3.tags.code 'DOOR',
  tes3.tags.code 'TES3'
local TEXT, SCTX = tes3.tags.code 'TEXT', tes3.tags.code 'SCTX'
local DATA, SCRI, NAME, NAM0 =
  tes3.tags.code 'DATA', tes3.tags.code 'SCRI', tes3.tags.code 'NAME', tes3.tags.code 'NAM0'

--[[ Evil GMSTs ]]

type Evil = { expansion: string, kind: string, value: string | number }

--- tes3cmd's Evil GMSTs (`%EVIL_TB`, `%EVIL_BM`), by lowercase id: the 11 Tribunal and 61
--- Bloodmoon GMSTs the Construction Set copies into plugins with the expansions' default values.
--- One of these is only evil while it still has that value.
local EvilGmsts: { [string]: Evil } = {}
do
  local function add(id: string, expansion: string, kind: string, value: string | number)
    EvilGmsts[id] = { expansion = expansion, kind = kind, value = value }
  end

  local tribunalStrings = {
    { 'scompanionshare', 'Companion Share' },
    { 'scompanionwarningbuttonone', 'Let the mercenary quit.' },
    { 'scompanionwarningbuttontwo', 'Return to Companion Share display.' },
    {
      'scompanionwarningmessage',
      'Your mercenary is poorer now than when he contracted with you.  Your mercenary will quit if you do not give him gold or goods to bring his Profit Value to a positive value.',
    },
    { 'sdeletenote', 'Delete Note?' },
    { 'seffectsummonfabricant', 'sEffectSummonFabricant' },
    { 'slevitatedisabled', 'Levitation magic does not work here.' },
    { 'smagicfabricantid', 'Fabricant' },
    { 'smaxsale', 'Max Sale' },
    { 'sprofitvalue', 'Profit Value' },
    { 'steleportdisabled', 'Teleportation magic does not work here.' },
  }

  for _, entry in tribunalStrings do
    add(entry[1], 'Tribunal', 'STRV', entry[2])
  end

  local bloodmoonFloats = {
    { 'fcombatdistancewerewolfmod', 0.3 },
    { 'ffleedistance', 3000 },
    { 'fwerewolfacrobatics', 150 },
    { 'fwerewolfagility', 150 },
    { 'fwerewolfalchemy', 1 },
    { 'fwerewolfalteration', 1 },
    { 'fwerewolfarmorer', 1 },
    { 'fwerewolfathletics', 150 },
    { 'fwerewolfaxe', 1 },
    { 'fwerewolfblock', 1 },
    { 'fwerewolfbluntweapon', 1 },
    { 'fwerewolfconjuration', 1 },
    { 'fwerewolfdestruction', 1 },
    { 'fwerewolfenchant', 1 },
    { 'fwerewolfendurance', 150 },
    { 'fwerewolffatigue', 400 },
    { 'fwerewolfhandtohand', 100 },
    { 'fwerewolfhealth', 2 },
    { 'fwerewolfheavyarmor', 1 },
    { 'fwerewolfillusion', 1 },
    { 'fwerewolfintellegence', 1 },
    { 'fwerewolflightarmor', 1 },
    { 'fwerewolflongblade', 1 },
    { 'fwerewolfluck', 1 },
    { 'fwerewolfmagicka', 100 },
    { 'fwerewolfmarksman', 1 },
    { 'fwerewolfmediumarmor', 1 },
    { 'fwerewolfmerchantile', 1 },
    { 'fwerewolfmysticism', 1 },
    { 'fwerewolfpersonality', 1 },
    { 'fwerewolfrestoration', 1 },
    { 'fwerewolfrunmult', 1.5 },
    { 'fwerewolfsecurity', 1 },
    { 'fwerewolfshortblade', 1 },
    { 'fwerewolfsilverweapondamagemult', 1.5 },
    { 'fwerewolfsneak', 1 },
    { 'fwerewolfspear', 1 },
    { 'fwerewolfspeechcraft', 1 },
    { 'fwerewolfspeed', 150 },
    { 'fwerewolfstrength', 150 },
    { 'fwerewolfunarmored', 100 },
    { 'fwerewolfwillpower', 1 },
  }

  for _, entry in bloodmoonFloats do
    add(entry[1] :: string, 'Bloodmoon', 'FLTV', string.pack('<f', entry[2] :: number))
  end

  local bloodmoonInts = {
    { 'iwerewolfbounty', 10000 },
    { 'iwerewolffightmod', 100 },
    { 'iwerewolffleemod', 100 },
    { 'iwerewolfleveltoattack', 20 },
  }

  for _, entry in bloodmoonInts do
    add(entry[1] :: string, 'Bloodmoon', 'INTV', string.pack('<i4', entry[2] :: number))
  end

  local bloodmoonStrings = {
    { 'seditnote', 'Edit Note' },
    { 'seffectsummoncreature01', 'sEffectSummonCreature01' },
    { 'seffectsummoncreature02', 'sEffectSummonCreature02' },
    { 'seffectsummoncreature03', 'sEffectSummonCreature03' },
    { 'seffectsummoncreature04', 'sEffectSummonCreature04' },
    { 'seffectsummoncreature05', 'sEffectSummonCreature05' },
    { 'smagiccreature01id', 'sMagicCreature01ID' },
    { 'smagiccreature02id', 'sMagicCreature02ID' },
    { 'smagiccreature03id', 'sMagicCreature03ID' },
    { 'smagiccreature04id', 'sMagicCreature04ID' },
    { 'smagiccreature05id', 'sMagicCreature05ID' },
    { 'swerewolfalarmmessage', 'You have been detected changing from a werewolf state.' },
    { 'swerewolfpopup', 'Werewolf' },
    { 'swerewolfrefusal', 'You cannot do this as a werewolf.' },
    { 'swerewolfrestmessage', 'You cannot rest in werewolf form.' },
  }

  for _, entry in bloodmoonStrings do
    add(entry[1], 'Bloodmoon', 'STRV', entry[2])
  end
end

--- The expansion a GMST is an evil copy of, matching the id ignoring case and the value exactly
--- (a string with its trailing NULs ignored), as tes3cmd does; nil otherwise.
local function evilGmst(plugin: Plugin, index: number, id: string): string?
  if plugin:code(index) ~= GMST then return nil end

  local evil = EvilGmsts[string.lower(id)]
  if not evil then return nil end

  local source, at, size = plugin:findSubrecord(index, tes3.tags.code(evil.kind))
  if not source then return nil end

  local payload = buffer.readstring(source :: buffer, at, size)
  if evil.kind == 'STRV' then payload = string.gsub(payload, '%z+$', '') end

  return if payload == evil.value then evil.expansion else nil
end

--[[ Cells ]]

--- A CELL with nothing but its name, data, and reference count, so no references either.
local function isJunkCell(plugin: Plugin, index: number): boolean
  if plugin:code(index) ~= CELL then return false end

  local source, start, finish = plugin:span(index)
  local p = start + 16
  while p < finish do
    local code = buffer.readu32(source, p)
    if code ~= NAME and code ~= DATA and code ~= NAM0 then return false end

    p += 8 + buffer.readu32(source, p + 4)
  end

  return true
end

--- Appends each repeated header subrecord (NAME and NAM0 aside) of CELL `index` to `out`:
--- `{ record, subrecord }`, 0-based.
local function cellDuplicates(plugin: Plugin, index: number, out: { { number } })
  local header = plugin:cellHeaderSubrecords(index) :: number
  local source, start = plugin:span(index)
  local seen: { [string]: boolean } = {}
  local p = start + 16
  for k = 0, header - 1 do
    local code, size = buffer.readu32(source, p), buffer.readu32(source, p + 4)
    if code ~= NAME and code ~= NAM0 then
      local key = buffer.readstring(source, p, 8 + size)
      if seen[key] then
        table.insert(out, { index, k })
      else
        seen[key] = true
      end
    end

    p += 8 + size
  end
end

--- Each repeated CELL header subrecord (NAME and NAM0 aside): `{ record, subrecord }`, 0-based.
local function duplicateCellParams(plugin: Plugin): { { number } }
  local out = {}
  for i = 0, plugin:count() - 1 do
    if plugin:code(i) == CELL then cellDuplicates(plugin, i, out) end
  end

  return out
end

--[[ Masters ]]

--- A master's path and size, if the source finds it.
local function masterFile(name: string, masters: Source): (string?, number)
  local path = masters.locate(name)
  if not path then return nil, 0 end

  local size = Masters.size(masters, path)
  if not size then error(`failed to read master '{name}': no such file`, 0) end

  return path, size
end

--- Every record of the plugin's masters that can be found, by `TAG\0id`: the master it's in and
--- where (a later master's copy wins). Masters are read in the plugin's code page, as its ids are.
export type MasterRecords = { [string]: { plugin: Plugin, index: number } }

local function masterRecords(plugin: Plugin, masters: Source): MasterRecords
  local records: MasterRecords = {}
  for _, master in plugin:masters() do
    local path = masters.locate(master.name)
    if not path then continue end

    local contents = Masters.read(masters, path)
    if not contents then error(`failed to read master '{master.name}': no such file`, 0) end

    -- tes3.open throws on a master that doesn't frame; that's the error to report.
    local ok, opened = pcall(
      function(): tes3.Plugin return tes3.open(contents, { encoding = plugin.encoding }) end
    )
    if not ok then error(`failed to read master '{master.name}': {opened}`, 0) end

    local other = opened :: Plugin
    for k = 0, other:count() - 1 do
      local id = tes3.records.id(other, k)
      if id then
        records[tes3.tags.name(other:code(k)) .. '\0' .. id] = { plugin = other, index = k }
      end
    end
  end

  return records
end

--- Whether record `index` of `plugin` is byte for byte the master's copy `found`.
local function sameAsMaster(
  plugin: Plugin,
  index: number,
  found: { plugin: Plugin, index: number }
): boolean
  local source, start, finish = plugin:span(index)
  local other, otherStart, otherFinish = found.plugin:span(found.index)
  local length = finish - start
  if otherFinish - otherStart ~= length then return false end

  local i = 0
  while i + 4 <= length do
    if buffer.readu32(source, start + i) ~= buffer.readu32(other, otherStart + i) then
      return false
    end

    i += 4
  end

  while i < length do
    if buffer.readu8(source, start + i) ~= buffer.readu8(other, otherStart + i) then
      return false
    end

    i += 1
  end

  return true
end

--- An INFO's string fields joined by line breaks, as jess-omwaddon's `string_values` gives
--- them: every one, or with `textOnly` only the response text. Walks the subrecords in place.
local function infoText(plugin: Plugin, index: number, textOnly: boolean): string
  local source, start, finish = plugin:span(index)
  local first: string? = nil
  local values: { string }? = nil
  local p = start + 16
  while p < finish do
    local code, size = buffer.readu32(source, p), buffer.readu32(source, p + 4)
    -- An INFO's response text is its NAME (and a TEXT, if one is there).
    local wanted = if textOnly
      then code == NAME or code == TEXT
      else tes3.records.fieldName(INFO, code) ~= nil
    if wanted then
      local value = tes3.text.decode(source, p + 8, size, plugin.encoding)
      if not first then
        first = value
      else
        values = values or { first :: string }
        table.insert(values :: { string }, value)
      end
    end

    p += 8 + size
  end

  if values then return table.concat(values, '\n') end

  return first or ''
end

--- Where `decode` would cut the text of `size` bytes at `at`: a final NUL dropped, then at the
--- first NUL. Its length.
local function cutLength(source: buffer, at: number, size: number): number
  local finish = at + size
  if size > 0 and buffer.readu8(source, finish - 1) == 0 then
    finish -= 1
  end

  for i = at, finish - 1 do
    if buffer.readu8(source, i) == 0 then return i - at end
  end

  return finish - at
end

--- An INFO's response text as a token of `pool` (ASCII case ignored, every other byte exact, so
--- equal tokens are texts equal ignoring ASCII case once decoded), or nil when it's empty. The text
--- is interned from the record's bytes; only an INFO with several text fields makes a string.
local function infoTextToken(plugin: Plugin, index: number, pool: dream_intern_Pool): number?
  local source, start, finish = plugin:span(index)
  local firstAt, firstLength, parts = -1, 0, nil :: { string }?
  local p = start + 16
  while p < finish do
    local code, size = buffer.readu32(source, p), buffer.readu32(source, p + 4)
    if code == NAME or code == TEXT then
      local length = cutLength(source, p + 8, size)
      if firstAt < 0 then
        firstAt, firstLength = p + 8, length
      else
        parts = parts or { buffer.readstring(source, firstAt, firstLength) }
        table.insert(parts :: { string }, buffer.readstring(source, p + 8, length))
      end
    end

    p += 8 + size
  end

  if parts then return pool:intern(table.concat(parts, '\n')) end

  if firstAt < 0 or firstLength == 0 then return nil end

  return pool:intern(source, firstAt, firstLength)
end

--[[ Lint ]]

--- The order lint reports in, jess-omwaddon's: each entry a check, or a group of checks that
--- report together (`header`, `expansions`, `masters`).
local Units = {
  'record-count',
  'header',
  'duplicate-records',
  'evil-gmsts',
  'cell-params',
  'junk-cells',
  'fogbug',
  'fogsync',
  'autocalc-spells',
  'cell-00',
  'deprecated-lists',
  'dialogue-teleports',
  'duplicate-info',
  'getsoundplaying',
  'menumode',
  'modified-info-id',
  'scripted-doors',
  'expansions',
  'masters',
  'overrides',
  'modified-info',
}

--- The checks that look at one record at a time: a slice of the records is linted for them on
--- its own (`lintSlice`), and the slices' findings joined in order are the plugin's.
local PerRecord: { [string]: boolean } = {
  ['evil-gmsts'] = true,
  ['cell-params'] = true,
  ['junk-cells'] = true,
  fogbug = true,
  fogsync = true,
  ['autocalc-spells'] = true,
  ['cell-00'] = true,
  ['deprecated-lists'] = true,
  ['dialogue-teleports'] = true,
  getsoundplaying = true,
  menumode = true,
  ['scripted-doors'] = true,
}

--- Findings by unit (see `Units`).
export type Parts = { [string]: { Finding } }

local function add(parts: Parts, unit: string, check: string, message: string)
  local list = parts[unit]
  if not list then
    list = {}
    parts[unit] = list
  end

  table.insert(list, finding(check, message))
end

--- Byte ranges to match, one per record: its buffer (false for none), offset, and length.
type Ranges = { sources: { buffer | false }, offsets: { number }, lengths: { number } }

--- Which of `ranges` `regex` matches: those in `base` in one native call, any other one (a record
--- an edit rebuilt) by itself.
local function matchRanges(regex: dream_bytes_Regex, base: buffer, ranges: Ranges): { boolean }
  local sources, offsets, lengths = ranges.sources, ranges.offsets, ranges.lengths
  local hits: { boolean }, slots: { number } = {}, {}
  local spans = buffer.create(#sources * 8)
  local used = 0
  for k, source in sources do
    hits[k] = false
    if not source then continue end

    if source ~= base then
      hits[k] = regex:isMatch(source, offsets[k], lengths[k])
      continue
    end

    buffer.writeu32(spans, used * 8, offsets[k])
    buffer.writeu32(spans, used * 8 + 4, offsets[k] + lengths[k])
    used += 1
    slots[used] = k
  end

  if used == 0 then return hits end

  local flags = regex:matchSpans(base, spans, used)
  for j = 1, used do
    if buffer.readu8(flags, j - 1) == 1 then hits[slots[j]] = true end
  end

  return hits
end

--- Each record's whole bytes.
local function recordRanges(plugin: Plugin, indices: { number }): Ranges
  local sources: { buffer | false }, offsets: { number }, lengths: { number } = {}, {}, {}
  for k, i in indices do
    local source, start, finish = plugin:span(i)
    sources[k], offsets[k], lengths[k] = source, start, finish - start
  end

  return { sources = sources, offsets = offsets, lengths = lengths }
end

--- Each script's text where it lies: its SCTX payload up to its first NUL, the bytes decoding
--- keeps (a final NUL dropped, then cut at the first), or false for a script with no SCTX.
local function scriptRanges(plugin: Plugin, indices: { number }): Ranges
  local sources: { buffer | false }, offsets: { number }, lengths: { number } = {}, {}, {}
  for k, i in indices do
    local source, at, size = plugin:findSubrecord(i, SCTX)
    if not source then
      sources[k], offsets[k], lengths[k] = false, 0, 0
      continue
    end

    local nul = bytes.find(source, '\0', at)
    sources[k], offsets[k] = source, at
    lengths[k] = if nul and nul < at + size then nul - at else size
  end

  return { sources = sources, offsets = offsets, lengths = lengths }
end

--- Whether any of `ranges` matches.
local function anyMatch(regex: dream_bytes_Regex, base: buffer, ranges: Ranges): boolean
  for _, hit in matchRanges(regex, base, ranges) do
    if hit then return true end
  end

  return false
end

--[[
Patterns run over record bytes in place, never decoding a record to look at it. jess-omwaddon
matches its patterns on decoded text (Unicode case folding and word boundaries); each such check
here has the same pattern in ASCII mode run first over the raw bytes, and decodes only the records
it finds. That never misses: every code page a plugin is read in maps each byte to one character
and ASCII to itself, none of them has a character that folds to an ASCII letter (U+017F, U+212A),
and an ASCII word boundary is found wherever a Unicode one is next to an ASCII letter. Words found
with `string.lower` and a plain search (autocalc, menumode, the expansion functions) match the raw bytes
exactly in ASCII mode.
]]

local DeprecatedLists = [[(?i)\b(additem|removeitem)\b.*\b(leveled|levi|levc)]]
local GetSoundPlaying = [[(?i)\bgetsoundplaying\b]]
local Patterns = table.freeze {
  deprecatedLists = bytes.regex(DeprecatedLists),
  deprecatedListsBytes = bytes.regex(DeprecatedLists, { unicode = false }),
  getSoundPlaying = bytes.regex(GetSoundPlaying),
  getSoundPlayingBytes = bytes.regex(GetSoundPlaying, { unicode = false }),
  teleports = bytes.regex [[(?i)\b(position|positioncell)\b]],
  -- Next to a subrecord header in the raw record, a word boundary may not be one: none is asked.
  teleportsBytes = bytes.regex([[(?i)position]], { unicode = false }),
  autocalc = bytes.regex([[(?i)autocalc]], { unicode = false }),
  menuMode = bytes.regex([[(?i)menumode]], { unicode = false }),
  bloodmoon = bytes.regex([[(?i)togglecollisiongrid|getsoundplaying]], { unicode = false }),
  tribunal = bytes.regex([[(?i)startscript|modregion]], { unicode = false }),
}

--- Records by type, in order, for records `first` to `last` (0-based, inclusive).
local function recordsByCode(plugin: Plugin, first: number, last: number): { [number]: { number } }
  local byCode: { [number]: { number } } = {}
  for i = first, last do
    local code = plugin:code(i)
    local list = byCode[code]
    if not list then
      list = {}
      byCode[code] = list
    end

    table.insert(list, i)
  end

  return byCode
end

--- Runs the per-record checks in `has` over the records `byCode` lists, into `parts`.
local function recordChecks(
  plugin: Plugin,
  has: CheckSet,
  byCode: { [number]: { number } },
  parts: Parts
)
  local function indicesOf(code: number): { number } return byCode[code] or {} end

  local base = plugin.source
  if has['evil-gmsts'] then
    for _, i in indicesOf(GMST) do
      local id = tes3.records.id(plugin, i)
      local expansion = if id then evilGmst(plugin, i, id) else nil
      if expansion then
        add(
          parts,
          'evil-gmsts',
          'evil-gmsts',
          `GMST {id} at record {i} has {expansion}'s default value`
        )
      end
    end
  end

  -- The cell checks, in one pass over the cells.
  if has['cell-params'] or has['junk-cells'] or has.fogbug or has.fogsync or has['cell-00'] then
    local duplicates: { { number } } = {}
    local scratch = buffer.create(8)
    for _, i in indicesOf(CELL) do
      if has['cell-params'] then cellDuplicates(plugin, i, duplicates) end

      if has['junk-cells'] and isJunkCell(plugin, i) then
        add(parts, 'junk-cells', 'junk-cells', `CELL {idOf(plugin, i)} at record {i}`)
      end

      if has.fogbug or has.fogsync then
        local ambient = tes3.records.cellAmbientFogDensity(plugin, i)
        if has.fogbug and tes3.records.cellIsInterior(plugin, i) and ambient == 0 then
          add(
            parts,
            'fogbug',
            'fogbug',
            `CELL {idOf(plugin, i)} at record {i} has zero fog density`
          )
        end

        local data = if has.fogsync and ambient
          then tes3.records.cellDataFogDensity(plugin, i)
          else nil
        if ambient and data then
          -- Compared bit for bit, as the Rust check compares `to_bits`.
          buffer.writef32(scratch, 0, ambient)
          buffer.writef32(scratch, 4, data)
          if buffer.readu32(scratch, 0) ~= buffer.readu32(scratch, 4) then
            add(
              parts,
              'fogsync',
              'fogsync',
              `CELL {idOf(plugin, i)} at record {i} DATA fog {Numbers.floatText(data)} differs from AMBI fog {Numbers.floatText(
                ambient
              )}`
            )
          end
        end
      end

      if has['cell-00'] and tes3.records.cellIsExterior(plugin, i) then
        local source, start, finish = plugin:span(i)
        local p = start + 16
        while p < finish do
          local code, size = buffer.readu32(source, p), buffer.readu32(source, p + 4)
          if
            code == DATA
            and size >= 12
            and buffer.readu32(source, p + 12) == 0
            and buffer.readu32(source, p + 16) == 0
          then
            add(parts, 'cell-00', 'cell-00', `CELL {idOf(plugin, i)} at record {i}`)
          end

          p += 8 + size
        end
      end
    end

    for _, entry in duplicates do
      local tag = plugin:subrecords(entry[1])[entry[2] + 1].tag
      add(parts, 'cell-params', 'cell-params', `duplicate {tag} in CELL record {entry[1]}`)
    end
  end

  if has['autocalc-spells'] then
    local spells = indicesOf(SPEL)
    for k, hit in matchRanges(Patterns.autocalc, base, recordRanges(plugin, spells)) do
      if hit then
        add(
          parts,
          'autocalc-spells',
          'autocalc-spells',
          `SPEL {idOf(plugin, spells[k])} at record {spells[k]}`
        )
      end
    end
  end

  local scripts = indicesOf(SCPT)
  local texts = if has['deprecated-lists']
      or has.getsoundplaying
      or has.menumode
    then scriptRanges(plugin, scripts)
    else nil

  local function scriptRegex(check: string, exact: dream_bytes_Regex, superset: dream_bytes_Regex)
    for k, hit in matchRanges(superset, base, texts :: Ranges) do
      if not hit then continue end

      local i = scripts[k]
      if exact:isMatch(tes3.records.scriptText(plugin, i) :: string) then
        add(parts, check, check, `SCPT {idOf(plugin, i)} at record {i}`)
      end
    end
  end

  if has['deprecated-lists'] then
    scriptRegex('deprecated-lists', Patterns.deprecatedLists, Patterns.deprecatedListsBytes)
  end

  if has['dialogue-teleports'] then
    local infos = indicesOf(INFO)
    for k, hit in matchRanges(Patterns.teleportsBytes, base, recordRanges(plugin, infos)) do
      if not hit then continue end

      local i = infos[k]
      if Patterns.teleports:isMatch(infoText(plugin, i, false)) then
        add(
          parts,
          'dialogue-teleports',
          'dialogue-teleports',
          `INFO {idOf(plugin, i)} at record {i}`
        )
      end
    end
  end

  if has.getsoundplaying then
    scriptRegex('getsoundplaying', Patterns.getSoundPlaying, Patterns.getSoundPlayingBytes)
  end

  if has.menumode then
    local ranges = texts :: Ranges
    for k, hit in matchRanges(Patterns.menuMode, base, ranges) do
      if ranges.sources[k] and not hit then
        add(parts, 'menumode', 'menumode', `SCPT {idOf(plugin, scripts[k])} at record {scripts[k]}`)
      end
    end
  end

  if has['scripted-doors'] then
    for _, i in indicesOf(DOOR) do
      if plugin:findSubrecord(i, SCRI) then
        add(parts, 'scripted-doors', 'scripted-doors', `DOOR {idOf(plugin, i)} at record {i}`)
      end
    end
  end
end

--- The per-record checks' findings (see `PerRecord`) for records `first` to `last` (0-based,
--- inclusive), by check: what `lint` joins, slice by slice, when the slices are linted apart.
local function lintSlice(plugin: Plugin, set: CheckSet?, first: number, last: number): Parts
  local parts: Parts = {}
  recordChecks(plugin, set or preset 'recommended', recordsByCode(plugin, first, last), parts)
  return parts
end

--- The findings of the checks in `set` (default: recommended) on `plugin`; masters resolve through
--- `masters` (default: none). When the per-record checks were linted apart (`lintSlice`), `slices`
--- gives their findings, in record order and covering every record; it's called after every other
--- check ran.
local function lint(
  plugin: Plugin,
  set: CheckSet?,
  masters: Source?,
  slices: (() -> { Parts })?
): { Finding }
  local has = set or preset 'recommended'
  local source = masters or Masters.none()
  local count = plugin:count()
  local parts: Parts = {}
  -- Most checks look at one record type: each type's records, in order, listed once.
  local byCode = recordsByCode(plugin, 0, count - 1)
  local function indicesOf(code: number): { number } return byCode[code] or {} end

  -- Ids compared ignoring ASCII case are tokens, interned from the record bytes once.
  local nocase: dream_intern_Pool = intern.new 'ascii-nocase'
  local tokens: { number | false } = {}
  local function tokenAt(index: number): number?
    local cached = tokens[index + 1]
    if cached ~= nil then return cached or nil end

    local idSource, at, length = tes3.records.idSpan(plugin, index)
    if not idSource then
      tokens[index + 1] = false
      return nil
    end

    local token = nocase:intern(idSource, at, length)
    tokens[index + 1] = token
    return token
  end

  -- Most checks look records up by id, so each id is read once.
  local ids: { string | false } = {}
  local function idAt(index: number): string?
    local cached = ids[index + 1]
    if cached ~= nil then return cached or nil end

    local id = tes3.records.id(plugin, index)
    ids[index + 1] = id or false
    return id
  end

  if has['record-count'] then
    local header = plugin:header()
    local actual = count - #indicesOf(TES3)
    if header.recordCount ~= actual then
      add(
        parts,
        'record-count',
        'record-count',
        `HEDR has {header.recordCount}, actual is {actual}`
      )
    end
  end

  if has['missing-author'] or has['missing-description'] or has['missing-version'] then
    local header = plugin:header()
    if has['missing-author'] and header.author == '' then
      add(parts, 'header', 'missing-author', 'TES3 author is empty')
    end

    if has['missing-description'] and header.description == '' then
      add(parts, 'header', 'missing-description', 'TES3 description is empty')
    end

    if has['missing-version'] and not hasVersion(header.description) then
      add(parts, 'header', 'missing-version', 'TES3 description has no Version line')
    end
  end

  if has['duplicate-records'] then
    -- jess-omwaddon keys `TAG:id` lowercased, so tags that differ only in case share ids.
    local seen: { [string]: { [number]: number } } = {}
    local ofCode: { [number]: { [number]: number } } = {}
    for i = 0, count - 1 do
      local token = tokenAt(i)
      if not token then continue end

      local code = plugin:code(i)
      local ofType = ofCode[code]
      if not ofType then
        local lower = string.lower(tes3.tags.display(code))
        ofType = seen[lower] or {}
        seen[lower], ofCode[code] = ofType, ofType
      end

      local first = ofType[token]
      ofType[token] = i
      if first then
        add(
          parts,
          'duplicate-records',
          'duplicate-records',
          `{display(plugin, i)} {idAt(i)} at record {i} duplicates record {first}`
        )
      end
    end
  end

  if has['duplicate-info'] then
    local seen: { [number]: number } = {}
    for _, i in indicesOf(INFO) do
      local token = tokenAt(i)
      if not token then continue end

      local first = seen[token]
      seen[token] = i
      if first then
        add(
          parts,
          'duplicate-info',
          'duplicate-info',
          `INFO {idAt(i)} at record {i} duplicates record {first}`
        )
      end
    end
  end

  if has['modified-info-id'] then
    local texts: dream_intern_Pool = intern.new 'ascii-nocase'
    local byText: { [number]: number } = {}
    for _, i in indicesOf(INFO) do
      local token = tokenAt(i)
      if not token then continue end

      local text = infoTextToken(plugin, i, texts)
      if not text then continue end

      local before = byText[text]
      byText[text] = i
      if before and tokenAt(before) ~= token then
        add(
          parts,
          'modified-info-id',
          'modified-info-id',
          `INFO {idAt(i)} at record {i} duplicates text from {idAt(before)}`
        )
      end
    end
  end

  if
    has['bloodmoon-dependency']
    or has['expansion-dependency']
    or has['no-bloodmoon-functions']
    or has['no-tribunal-functions']
  then
    local bloodmoonMaster, tribunalMaster = false, false
    for _, master in plugin:masters() do
      local lower = string.lower(master.name)
      if lower == 'bloodmoon.esm' then bloodmoonMaster = true end

      if lower == 'tribunal.esm' then tribunalMaster = true end
    end

    local texts = scriptRanges(plugin, indicesOf(SCPT))
    local usesBloodmoon = anyMatch(Patterns.bloodmoon, plugin.source, texts)
    local usesTribunal = anyMatch(Patterns.tribunal, plugin.source, texts)
    if has['bloodmoon-dependency'] and usesBloodmoon and not bloodmoonMaster then
      add(
        parts,
        'expansions',
        'bloodmoon-dependency',
        'Bloodmoon function use without Bloodmoon.esm master'
      )
    end

    if
      has['expansion-dependency']
      and (usesBloodmoon or usesTribunal)
      and not bloodmoonMaster
      and not tribunalMaster
    then
      add(
        parts,
        'expansions',
        'expansion-dependency',
        'expansion function use without expansion master'
      )
    end

    if has['no-bloodmoon-functions'] and bloodmoonMaster and not usesBloodmoon then
      add(
        parts,
        'expansions',
        'no-bloodmoon-functions',
        'Bloodmoon.esm is listed but no Bloodmoon functions were detected'
      )
    end

    if has['no-tribunal-functions'] and tribunalMaster and not usesTribunal then
      add(
        parts,
        'expansions',
        'no-tribunal-functions',
        'Tribunal.esm is listed but no Tribunal functions were detected'
      )
    end
  end

  if has['missing-master'] or has['master-sync'] then
    for _, master in plugin:masters() do
      local path, size = masterFile(master.name, source)
      if path and has['master-sync'] and master.size ~= size then
        add(
          parts,
          'masters',
          'master-sync',
          `{master.name} DATA has {master.size}, actual is {size} ({path})`
        )
      elseif not path and has['missing-master'] then
        add(parts, 'masters', 'missing-master', master.name)
      end
    end
  end

  local found: MasterRecords? = nil
  local function mastersOf(): MasterRecords
    found = found or masterRecords(plugin, source)
    return found :: MasterRecords
  end

  if has.overrides and next(mastersOf()) then
    local records = mastersOf()
    for i = 0, count - 1 do
      local code = plugin:code(i)
      if code == TES3 then continue end

      local id = idAt(i)
      if id and records[tes3.tags.name(code) .. '\0' .. id] then
        add(parts, 'overrides', 'overrides', `{display(plugin, i)} {id} at record {i}`)
      end
    end
  end

  if has['modified-info'] and next(mastersOf()) then
    local records = mastersOf()
    for _, i in indicesOf(INFO) do
      local id = idAt(i)
      local master = if id then records['INFO\0' .. id] else nil
      if master and not sameAsMaster(plugin, i, master) then
        add(parts, 'modified-info', 'modified-info', `INFO {id} at record {i}`)
      end
    end
  end

  -- The per-record checks last, so slices linted elsewhere had the whole-plugin checks' time.
  if slices then
    for _, slice in slices() do
      for unit, findings in slice do
        if not PerRecord[unit] then continue end

        local list = parts[unit]
        if not list then
          list = {}
          parts[unit] = list
        end

        table.move(findings, 1, #findings, #list + 1, list)
      end
    end
  else
    recordChecks(plugin, has, byCode, parts)
  end

  local out: { Finding } = {}
  for _, unit in Units do
    local findings = parts[unit]
    if findings then table.move(findings, 1, #findings, #out + 1, out) end
  end

  return out
end

--[[ Clean ]]

export type CleanChecks = {
  duplicateRecords: boolean?,
  evilGmsts: boolean?,
  junkCells: boolean?,
  cellParams: boolean?,
}

export type CleanReport = {
  removedRecords: number,
  removedSubrecords: number,
  --- The positions the removed records had before cleaning, ascending (0-based).
  removedRecordIndices: { number },
  --- Whether the header's record count was set to match.
  recordCountUpdated: boolean,
}

--- The record types a duplicate of a master's copy is removed from.
local CleanableTags = {
  'ACTI',
  'ALCH',
  'APPA',
  'ARMO',
  'BODY',
  'BOOK',
  'BSGN',
  'CELL',
  'CLAS',
  'CLOT',
  'CONT',
  'CREA',
  'DOOR',
  'ENCH',
  'FACT',
  'GLOB',
  'GMST',
  'INFO',
  'INGR',
  'LAND',
  'LEVC',
  'LEVI',
  'LIGH',
  'LOCK',
  'MGEF',
  'MISC',
  'NPC_',
  'PGRD',
  'PROB',
  'RACE',
  'REGN',
  'REPA',
  'SCPT',
  'SKIL',
  'SNDG',
  'SOUN',
  'SPEL',
  'SSCR',
  'STAT',
  'WEAP',
}

local Cleanable: { [number]: boolean } = {}
for _, tag in CleanableTags do
  Cleanable[tes3.tags.code(tag)] = true
end

--- Removes the safe dirt `which` sets to true (with none, every kind not set to false), and sets the header's
--- record count to match when records went, unless `recordCount` is `'keep'`.
local function clean(
  plugin: Plugin,
  which: CleanChecks?,
  masters: Source?,
  recordCount: ('update' | 'keep')?
): CleanReport
  local want: CleanChecks = which or {}
  if not (want.duplicateRecords or want.evilGmsts or want.junkCells or want.cellParams) then
    want = {
      duplicateRecords = want.duplicateRecords ~= false,
      evilGmsts = want.evilGmsts ~= false,
      junkCells = want.junkCells ~= false,
      cellParams = want.cellParams ~= false,
    }
  end

  local count = plugin:count()
  local remove: { [number]: boolean } = {}
  if want.duplicateRecords then
    local seen: { [string]: boolean } = {}
    for i = 0, count - 1 do
      local id = tes3.records.id(plugin, i)
      if not id then continue end

      local key = string.lower(`{display(plugin, i)}:{id}`)
      if seen[key] then
        remove[i] = true
      else
        seen[key] = true
      end
    end

    local records = masterRecords(plugin, masters or Masters.none())
    for i = 0, count - 1 do
      local code = plugin:code(i)
      if code == TES3 or not Cleanable[code] then continue end

      local id = tes3.records.id(plugin, i)
      local master = if id then records[tes3.tags.name(code) .. '\0' .. id] else nil
      if master and sameAsMaster(plugin, i, master) then remove[i] = true end
    end
  end

  if want.evilGmsts then
    for i = 0, count - 1 do
      if plugin:code(i) ~= GMST then continue end

      local id = tes3.records.id(plugin, i)
      if id and evilGmst(plugin, i, id) then remove[i] = true end
    end
  end

  if want.junkCells then
    for i = 0, count - 1 do
      if isJunkCell(plugin, i) then remove[i] = true end
    end
  end

  local indices = {}
  for i in remove do
    table.insert(indices, i)
  end

  table.sort(indices)
  if #indices > 0 then plugin:retain(function(i) return not remove[i] end) end

  local removedSubrecords = 0
  if want.cellParams then
    local deletions = duplicateCellParams(plugin)
    removedSubrecords = #deletions
    for k = #deletions, 1, -1 do
      plugin:deleteSubrecord(deletions[k][1], deletions[k][2])
    end
  end

  local updated = plugin:applyRecordCount(recordCount or 'update', #indices > 0)
  return {
    removedRecords = #indices,
    removedSubrecords = removedSubrecords,
    removedRecordIndices = indices,
    recordCountUpdated = updated,
  }
end

--[[ Validate ]]

--- What `validate` ran (camelCase, like `recordContents`) and found.
export type Validation = { checks: { string }, diagnostics: { tes3.Diagnostic } }

--- Checks `plugin` against `profile` (jess-omwaddon's `validate`): its framing and tags, and for
--- `omwaddon` also that every record OpenMW loads reads the way its loaders read it, since one
--- that doesn't stops the file loading.
local function validate(plugin: Plugin, profile: tes3.Profile): Validation
  local names = table.clone(tes3.checks(profile))
  local diagnostics = plugin:validateProfile(profile)
  if profile == 'omwaddon' then
    table.insert(names, 'record_contents')
    for i = 0, plugin:count() - 1 do
      if not tes3.typeName(plugin:tag(i)) then continue end

      -- A record that doesn't decode is the finding; its error is the message.
      local ok, problem = pcall(plugin.decode, plugin, i)
      if ok then continue end

      local id = tes3.records.fieldId(plugin, i)
      local named = if id and id ~= '' then ` {id}` else ''
      table.insert(diagnostics, {
        offset = (plugin:range(i)),
        message = `{display(plugin, i)}{named} doesn't read the way OpenMW reads it: {problem}`,
      })
    end

    -- Stable, as Rust's `sort_by_key` is: ties keep their order.
    local order: { [tes3.Diagnostic]: number } = {}
    for i, diagnostic in diagnostics do
      order[diagnostic] = i
    end

    table.sort(diagnostics, function(a: tes3.Diagnostic, b: tes3.Diagnostic)
      if a.offset ~= b.offset then return a.offset < b.offset end

      return order[a] < order[b]
    end)
  end

  for i, name in names do
    names[i] = tes3.text.camelCase(name)
  end

  return { checks = names, diagnostics = diagnostics }
end

--[[ Header ]]

export type MasterSizeChange = { name: string, oldSize: number, newSize: number, path: string }

--- Sets every master's recorded size to its file's size.
local function syncMasters(plugin: Plugin, masters: Source): { MasterSizeChange }
  local changes = {}
  for _, master in plugin:masters() do
    local path, size = masterFile(master.name, masters)
    if not path then error(`failed to resolve TES3 master '{master.name}'`, 0) end

    if plugin:setMasterSize(master.name, size) then
      table.insert(
        changes,
        { name = master.name, oldSize = master.size, newSize = size, path = path }
      )
    end
  end

  return changes
end

export type HeaderUpdate = {
  author: string?,
  description: string?,
  fileType: tes3.FileType?,
  --- Set each master's recorded size to its file's size.
  syncMasters: boolean?,
  --- Set the record count to the number of records.
  recordCount: boolean?,
}

--- Applies `update` to the TES3 header; whether anything changed, and the masters synced.
local function updateHeader(
  plugin: Plugin,
  update: HeaderUpdate,
  masters: Source?
): (boolean, { MasterSizeChange })
  local changed = false
  if update.author then changed = plugin:setAuthor(update.author) or changed end

  if update.description then changed = plugin:setDescription(update.description) or changed end

  if update.fileType then changed = plugin:setFileType(update.fileType) or changed end

  local synced = {}
  if update.syncMasters then
    synced = syncMasters(plugin, masters or Masters.none())
    changed = changed or #synced > 0
  end

  if update.recordCount then changed = plugin:updateRecordCount() or changed end

  return changed, synced
end

return table.freeze {
  Checks = Checks,
  camelCase = camelCase,
  checks = checks,
  clean = clean,
  hasVersion = hasVersion,
  lint = lint,
  lintSlice = lintSlice,
  parseCheck = parseCheck,
  preset = preset,
  syncMasters = syncMasters,
  updateHeader = updateHeader,
  validate = validate,
}
