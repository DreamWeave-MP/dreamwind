--!strict
--!native
-- The tes3cmd edits build_starwind.py makes to its staged plugins, as edits to record lists.
--
-- Each function says which tes3cmd command it stands for. They follow what tes3cmd does to the
-- binary, not what the command line seems to ask for, since that is what the Python build ships:
--   * `--replace` rewrites each subrecord field's value, never the "Field:value" text a dump
--     shows, so `--replace "/Name:Asteriod/Name:Asteroid/"` changes nothing;
--   * a scalar option given twice keeps the last value: `--instance-match MastIdx:5
--     --instance-match SW_In_TableGround` matches SW_In_TableGround alone;
--   * `--sub-no-match "ENAM:"` excludes no subrecord, since a subrecord's text doesn't start with
--     its tag, so the enchantment normalization reaches every CLOT, ARMO, and WEAP;
--   * deleting a LEVC creature's CNAM leaves its INTV behind, and tes3 reads that level onto the
--     entry before it;
--   * `s/.*//ig` on a script's bytecode empties it: tes3cmd holds bytecode as hex digits;
--   * deleting subrecords or instances rebuilds every record the command picks, and a rebuilt
--     record loses its header flags: `delete --sub-match Script:Nab_ByeBye naboo.esp` clears
--     PERSISTENT and BLOCKED from all of Naboo;
--   * a CELL's NAM0 (how many references are temporary) rides along with the reference before
--     it, so deleting that reference deletes the count, and tes3 then reads every reference left
--     in the cell as persistent. tes3cmd's attempt to rewrite the count never finds it.
-- Matching is case-insensitive throughout, as tes3cmd's is.

local tes3 = require '../lib/tes3'
local tes3conv = require '@dreamwind/tools/tes3conv'

type Table = tes3.Table
type Value = tes3.Value
type Record = tes3.Record
type Records = tes3.Records

local surgery = {}

-- tes3cmd's record id: lowercased NAME (or INAM), a magic effect's or skill's index, an interior
-- cell's name, an exterior cell's "name (x, y)" (region, else "wilderness", for a nameless one),
-- and a path grid's cell name, with its grid when that isn't (0, 0).
function surgery.id(record: Record): string
  local kind = record.type

  if kind == 'MagicEffect' then
    return tostring(tes3.EffectIndex[tes3.string(record.effectId)])
  elseif kind == 'Skill' then
    return tostring(tes3.SkillIndex[tes3.string(record.skillId)])
  elseif kind == 'Cell' then
    local name = tes3.string(record.name)

    if tes3.isInterior(record) then return string.lower(name) end

    if name == '' then name = tes3.string(record.region) end

    if name == '' then name = 'wilderness' end

    local grid = (record.data :: Table).grid :: Table
    return string.lower(`{name} ({grid[1]}, {grid[2]})`)
  elseif kind == 'PathGrid' then
    local name = tes3.string(record.cell)
    local grid = ((record.data or {}) :: Table).grid :: Table?
    local x, y = grid and grid[1] or 0, grid and grid[2] or 0

    if x == 0 and y == 0 then return string.lower(name) end

    return string.lower(`{name} ({x}, {y})`)
  elseif kind == 'Landscape' then
    local grid = record.grid :: Table
    return `({grid[1]}, {grid[2]})`
  end

  return tes3.lower(record.id)
end

local function idSet(ids: { string }): { [string]: boolean }
  local set = {}

  for _, id in ids do
    set[string.lower(id)] = true
  end

  return set
end

-- A record tes3cmd built anew from its kept subrecords, as `delete --sub-match` and
-- `--instance-match` do to every record they pick: the record header's flags are gone, and only a
-- DELE subrecord still marks it deleted.
local function rebuilt(record: Record): Record
  local copy = table.clone(record)
  copy.flags = if tes3.isDeleted(record) then 'DELETED' else ''
  return copy
end

surgery.rebuilt = rebuilt

local function keep(records: Records, drop: (record: Record) -> boolean): (Records, number)
  local kept: Records = { records[1] }
  local dropped = 0

  for index = 2, #records do
    local record = records[index]

    if drop(record) then
      dropped += 1
    else
      table.insert(kept, record)
    end
  end

  return kept, dropped
end

-- `tes3cmd delete [--type T]... --exact-id ID...`: whole records.
function surgery.deleteIds(records: Records, types: { string }?, ids: { string }): (Records, number)
  local wanted = idSet(ids)
  local typeSet: { [string]: boolean }? = nil

  if types then
    typeSet = {}

    for _, kind in types do
      (typeSet :: { [string]: boolean })[kind] = true
    end
  end

  return keep(records, function(record)
    if typeSet and not typeSet[record.type :: string] then return false end

    return wanted[surgery.id(record)] == true
  end)
end

-- `tes3cmd delete --type CELL --exterior`.
function surgery.deleteExteriorCells(records: Records): (Records, number)
  return keep(
    records,
    function(record) return record.type == 'Cell' and not tes3.isInterior(record) end
  )
end

function surgery.deleteType(records: Records, kind: string): (Records, number)
  return keep(records, function(record) return record.type == kind end)
end

local function float(value: Value?, places: number): string
  return string.format(`%.{places}f`, tonumber(value) or 0)
end

local function vector(prefix: string, value: Value?, places: number): string
  local triple = (value or {}) :: Table
  return `{prefix}X:{float(triple[1], places)}  {prefix}Y:{float(triple[2], places)}  {prefix}Z:{float(
    triple[3],
    places
  )}`
end

-- The text tes3cmd matches `--instance-match` against: each subrecord of the reference's FRMR
-- group as tes3cmd prints it, run together.
function surgery.instanceText(reference: Table): string
  local parts = {
    `ObjIdx:{reference.refrIndex}  MastIdx:{reference.mastIndex}`,
    `Name:{tes3.string(reference.id)}`,
  }

  local function add(label: string, value: Value?)
    if value ~= nil and value ~= jess.null then table.insert(parts, `{label}:{tostring(value)}`) end
  end

  if reference.scale ~= nil then table.insert(parts, `Scale:{float(reference.scale, 2)}`) end

  add('Owner_Actor', reference.owner)
  add('Global', reference.ownerGlobal)
  add('Owner_Faction', reference.ownerFaction)
  add('Soul', reference.soul)

  if reference.chargeLeft ~= nil then
    table.insert(parts, `Enchant_Charge:{float(reference.chargeLeft, 2)}`)
  end

  add('Health_Left', reference.healthLeft)
  add('Owned', reference.objectCount)

  local destination = reference.destination :: Table?

  if destination then
    local translation, rotation = destination.translation :: Table, destination.rotation :: Table
    table.insert(
      parts,
      `X:{float(translation[1], 2)}  Y:{float(translation[2], 2)}  Z:{float(translation[3], 2)}  X_Angle:{float(
        rotation[1],
        2
      )}  Y_Angle:{float(rotation[2], 2)}  Z_Angle:{float(rotation[3], 2)}`
    )
    add('Destination', destination.cell)
  end

  add('Lock_Level', reference.lockLevel)
  add('Key', reference.key)
  add('Trap_Spell', reference.trap)

  if reference.deleted then table.insert(parts, 'DELETED:0') end

  local translation, rotation = reference.translation :: Table, reference.rotation :: Table

  if translation and rotation then
    table.insert(
      parts,
      `X:{float(translation[1], 3)}  Y:{float(translation[2], 3)}  Z:{float(translation[3], 3)}  X_Angle:{float(
        rotation[1],
        4
      )}  Y_Angle:{float(rotation[2], 4)}  Z_Angle:{float(rotation[3], 4)}`
    )
  end

  return table.concat(parts)
end

-- Every string in a value, run together: enough of a record's dump for `--match` on the names
-- and ids it holds.
local function strings(value: Value?, parts: { string })
  if type(value) == 'string' then
    table.insert(parts, value)
  elseif type(value) == 'table' then
    for _, item in value do
      strings(item, parts)
    end
  end
end

function surgery.recordText(record: Record): string
  local parts = {}

  if record.type == 'Cell' then
    strings(record.name, parts)
    strings(record.region, parts)

    for _, reference in (record.references or {}) :: { Table } do
      table.insert(parts, surgery.instanceText(reference))
    end
  else
    strings(record, parts)
  end

  return table.concat(parts, '\n')
end

export type InstanceDelete = { match: string?, exactIds: { string }?, instance: string }

-- `tes3cmd delete --type CELL [--exact-id ID] [--match TEXT] --instance-match TEXT`: references
-- whose text holds `instance`, in the cells the other options pick. Returns how many went.
function surgery.deleteInstances(records: Records, options: InstanceDelete): number
  local ids = options.exactIds and idSet(options.exactIds)
  local deleted = 0

  for index, record in records do
    if record.type ~= 'Cell' then continue end

    if ids and not ids[surgery.id(record)] then continue end

    if
      options.match and not tes3.containsNoCase(surgery.recordText(record), options.match :: string)
    then
      continue
    end

    -- The cell as tes3 wrote it: references sorted, and NAM0 after the last persistent one.
    -- tes3cmd groups subrecords from each FRMR to the next, so NAM0 travels with that reference.
    local references = table.clone((record.references or {}) :: { Table })
    tes3conv.sortReferences(references)
    local owner: Table? = nil

    for position, reference in references do
      if not tes3conv.isPersistent(reference) then
        owner = if position > 1 then references[position - 1] else nil
        break
      end
    end

    local kept = {}
    local lostCount = false

    for _, reference in references do
      if tes3.containsNoCase(surgery.instanceText(reference), options.instance) then
        deleted += 1
        lostCount = lostCount or reference == owner
      else
        table.insert(kept, reference)
      end
    end

    if #kept == #references then continue end

    -- Without its NAM0, tes3 reads every reference in the cell as persistent.
    if lostCount then
      for position, reference in kept do
        if reference.temporary then
          local copy = table.clone(reference)
          copy.temporary = false
          kept[position] = copy
        end
      end
    end

    local copy = rebuilt(record)
    copy.references = kept
    records[index] = copy
  end

  return deleted
end

-- `tes3cmd modify --type SCPT --replace "/from/to/"`: a case-insensitive, global replacement in
-- script text.
function surgery.replaceScriptText(records: Records, from: string, to: string): number
  local changed = 0

  for index, record in records do
    if record.type ~= 'Script' then continue end

    local text, count = tes3.replaceNoCase(tes3.string(record.text), from, to)

    if count > 0 then
      local copy = table.clone(record)
      copy.text = text
      records[index] = copy
      changed += 1
    end
  end

  return changed
end

local Base64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local Base64Values: { [number]: number } = {}

for index = 1, #Base64 do
  Base64Values[string.byte(Base64, index)] = index - 1
end

local function base64Decode(text: string): string
  local bytes = {}
  local bits, count = 0, 0

  for index = 1, #text do
    local value = Base64Values[string.byte(text, index)]

    if value == nil then continue end

    bits = bit32.bor(bit32.lshift(bits, 6), value)
    count += 6

    if count >= 8 then
      count -= 8
      table.insert(bytes, string.char(bit32.band(bit32.rshift(bits, count), 0xFF)))
    end
  end

  return table.concat(bytes)
end

local function base64Encode(data: string): string
  local parts = {}

  for index = 1, #data, 3 do
    local a, b, c = string.byte(data, index, index + 2)
    local value = bit32.lshift(a, 16) + bit32.lshift(b or 0, 8) + (c or 0)

    local function digit(shift: number): string
      local at = bit32.band(bit32.rshift(value, shift), 63) + 1
      return string.sub(Base64, at, at)
    end

    table.insert(
      parts,
      digit(18) .. digit(12) .. (b and digit(6) or '=') .. (c and digit(0) or '=')
    )
  end

  return table.concat(parts)
end

surgery.base64Decode = base64Decode
surgery.base64Encode = base64Encode

-- tes3conv's bytes fields are base64 of a u32 length and the bytes.
local function bytesField(text: string): string return string.sub(base64Decode(text), 5) end

local function toBytesField(bytes: string): string
  return base64Encode(string.pack('<I4', #bytes) .. bytes)
end

surgery.bytesField = bytesField
surgery.toBytesField = toBytesField

-- `tes3cmd modify --type SCPT --sub-match "Bytecode:" --replace "/.*//"`: tes3cmd holds the
-- bytecode as hex digits, so the whole of it goes. The header's bytecode length stays as it was.
function surgery.destroyBytecode(records: Records): number
  local changed = 0
  local destroyed = toBytesField ''

  for index, record in records do
    if record.type ~= 'Script' then continue end

    local bytecode = tes3.string(record.bytecode)

    if destroyed ~= bytecode then
      local copy = table.clone(record)
      copy.bytecode = destroyed
      records[index] = copy
      changed += 1
    end
  end

  return changed
end

-- `tes3cmd delete --type LEVC --exact-id ID --sub-match TEXT`: the CNAM subrecords naming a
-- creature that holds TEXT. Its INTV stays, and tes3 reads it as the level of the entry before.
function surgery.deleteLeveledCreatures(records: Records, id: string, text: string): number
  local deleted = 0

  for index, record in records do
    if record.type ~= 'LeveledCreature' or surgery.id(record) ~= string.lower(id) then continue end

    local creatures = {}
    local before = deleted

    for _, entry in (record.creatures or {}) :: { Table } do
      local creature = tes3.string(entry[1])

      if tes3.containsNoCase(`Creature:{creature}`, text) then
        local last = creatures[#creatures]

        if not last then error(`tes3 can't read {id}: its first INTV has no CNAM`) end

        creatures[#creatures] = { last[1], entry[2] }
        deleted += 1
      else
        table.insert(creatures, entry)
      end
    end

    local copy = rebuilt(record)

    if deleted > before then copy.creatures = creatures end

    records[index] = copy
  end

  return deleted
end

-- `tes3cmd delete --type ARMO --match TEXT --sub-match "Female_Body_ID:"`: every female body
-- part of the matching armor.
function surgery.deleteFemaleBodyParts(records: Records, match: string): number
  local changed = 0

  for index, record in records do
    if record.type ~= 'Armor' or not tes3.containsNoCase(surgery.recordText(record), match) then
      continue
    end

    local parts = {}

    for _, part in (record.bipedObjects or {}) :: { Table } do
      local copy = table.clone(part)
      copy.femaleBodypart = ''
      table.insert(parts, copy)
    end

    local copy = rebuilt(record)
    copy.bipedObjects = parts
    records[index] = copy
    changed += 1
  end

  return changed
end

-- `tes3cmd delete [--type T] [--exact-id ID] --sub-match TEXT` against a script: the SCRI
-- subrecord, when its "Script:id" text holds TEXT. Every record the type and id pick is rebuilt,
-- whether it had a script or not: without a type, that is every record in the plugin.
function surgery.deleteScripts(records: Records, text: string, kind: string?, id: string?): number
  local changed = 0

  for index = 2, #records do
    local record = records[index]

    if kind and record.type ~= kind then continue end

    if id and surgery.id(record) ~= string.lower(id) then continue end

    local copy = rebuilt(record)
    local script = record.script

    if
      type(script) == 'string'
      and script ~= ''
      and tes3.containsNoCase(`Script:{script}`, text)
    then
      copy.script = ''
      changed += 1
    end

    records[index] = copy
  end

  return changed
end

-- `tes3cmd delete --type CONT --exact-id ID --sub-match TEXT`: inventory entries whose
-- "Count:n  Object:id" text holds TEXT.
function surgery.deleteInventory(records: Records, id: string, text: string): number
  local deleted = 0

  for index, record in records do
    if record.type ~= 'Container' or surgery.id(record) ~= string.lower(id) then continue end

    local inventory = {}

    for _, entry in (record.inventory or {}) :: { Table } do
      if tes3.containsNoCase(`Count:{entry[1]}  Object:{tes3.string(entry[2])}`, text) then
        deleted += 1
      else
        table.insert(inventory, entry)
      end
    end

    local copy = rebuilt(record)
    copy.inventory = inventory
    records[index] = copy
  end

  return deleted
end

-- `tes3cmd modify --type REGN --exact-id REGION --sub-match "Sleep_Creature_ID:" --replace
-- "/CREATURE//"`.
function surgery.clearSleepCreature(records: Records, region: string, creature: string): number
  local changed = 0

  for index, record in records do
    if record.type ~= 'Region' or surgery.id(record) ~= string.lower(region) then continue end

    local current = tes3.string(record.sleepCreature)
    local cleared, count = tes3.replaceNoCase(current, creature, '')

    if count > 0 then
      local copy = table.clone(record)
      copy.sleepCreature = cleared
      records[index] = copy
      changed += 1
    end
  end

  return changed
end

-- `tes3cmd modify --sub-no-match "ENAM:" --type CLOT --type ARMO --type WEAP --run
-- '$R->set({f=>"enchantment"}, 375)'`: every one of them, enchanted or not.
function surgery.setEnchantCapacity(records: Records, capacity: number): number
  local changed = 0

  for index, record in records do
    local kind = record.type

    if kind ~= 'Clothing' and kind ~= 'Armor' and kind ~= 'Weapon' then continue end

    local data = record.data :: Table

    if data.enchantment ~= capacity then
      local copy = table.clone(record)
      local fields = table.clone(data)
      fields.enchantment = capacity
      copy.data = fields
      records[index] = copy
      changed += 1
    end
  end

  return changed
end

-- `tes3cmd delete --instance-match DELE`: references whose text holds "dele", which is every
-- deleted reference and any whose id, owner, or destination happens to spell it.
function surgery.deleteDeletedInstances(records: Records): number
  return surgery.deleteInstances(records, { instance = 'DELE' })
end

return surgery
