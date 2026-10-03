--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
What a save's fields mean and what they point at (jess-save's `scan` and `plan_groups`): the
RefId and FormId fields OpenMW reads and the engine rule behind each, the subrecord groups an
object, inventory item, stolen item, or AI package spans, and the scans a check or strip makes.
Meanings are the snake_case codes jess-save uses; reports spell them camelCase.
]]

local Records = require './records'
local tes3 = require '@dreamwind/tes3'

type Plugin = tes3.Plugin
type Record = Records.Record

local tagAt, payload = Records.tagAt, Records.payload

--- Record types with the content-record layout whose NAME is the object's id.
local ObjectStateTagList = {
  'NPC_',
  'CREA',
  'CONT',
  'ACTI',
  'DOOR',
  'MISC',
  'WEAP',
  'ARMO',
  'CLOT',
  'BOOK',
  'ALCH',
  'INGR',
  'LIGH',
  'STAT',
}

local ObjectStateTags: { [string]: boolean } = {}
for _, tag in ObjectStateTagList do
  ObjectStateTags[tag] = true
end

--- The fourCC of the nearest AIPK before subrecord `k`, if any (and if it's four bytes).
local function aiPackageTypeBefore(r: Record, k: number): string?
  for j = k - 1, 0, -1 do
    if tagAt(r, j) == 'AIPK' then
      local data = payload(r, j)
      return if #data == 4 then data else nil
    end
  end

  return nil
end

--- Only AI Combat and Pursue write TARG as a RefNum; Escort, Follow, Activate, and GSCR write a RefId.
local function isAiRefnumTarget(r: Record, k: number): boolean
  local package = aiPackageTypeBefore(r, k)
  return package == 'COMB' or package == 'PURS'
end

local function isPlayerRecord(r: Record): boolean
  local name = Records.first(r, 'NAME')
  if not name then return false end

  local id = Records.refId(payload(r, name))
  return id ~= nil and string.lower(id) == 'player'
end

--- What the RefId in subrecord `k` means, as jess-save's `classify_openmw_save_ref_id_field`
--- names it, or nil for a field that holds none (or one the engine drops on its own).
local function refIdField(r: Record, k: number, inventoryItemsRemaining: number): string?
  local tag = tagAt(r, k) :: string
  if tagAt(r, k - 1) == 'FRMR' then
    if tag ~= 'NAME' then return nil end

    if inventoryItemsRemaining > 0 then return 'inventory_item_base_object' end

    if r.tag == 'CSTA' then return 'cell_ref_base_object' end
  end

  if r.tag == 'CSTA' and k == 0 and tag == 'NAME' then return 'saved_cell_state' end

  -- The saved player record: a missing race or class stops the load (openmw esmstore.cpp:805);
  -- missing head or hair renders the player without them (npcanimation.cpp:478-494).
  if r.tag == 'NPC_' and isPlayerRecord(r) then
    if tag == 'RNAM' then return 'player_race' end

    if tag == 'CNAM' then return 'player_class' end

    if tag == 'BNAM' then return 'player_head' end

    if tag == 'KNAM' then return 'player_hair' end
  end

  local record = r.tag
  if tag == 'NAME' then
    if record == 'GSCR' then return 'global_script' end

    if record == 'GLOB' then return 'global_variable' end

    if ObjectStateTags[record] then return 'saved_record_id' end

    if record == 'PLAY' then return 'player_ref_id' end

    if record == 'STLN' then return 'stolen_item_ref_id' end

    if record == 'MARK' then return 'custom_marker_cell' end
  end

  -- A missing birthsign makes the save fail to load (openmw player.cpp:372-375).
  if record == 'PLAY' and tag == 'SIGN' then return 'player_birthsign' end

  -- CellRef fields the engine keeps when their record is gone, breaking the object in play. These
  -- tags mean other things in dynamic records, so only object state in CSTA and PLAY counts.
  if record == 'CSTA' or record == 'PLAY' then
    if tag == 'ANAM' then return 'cell_ref_owner' end

    if tag == 'CNAM' then return 'cell_ref_owner_faction' end

    if tag == 'KNAM' then return 'cell_ref_key' end

    if tag == 'TNAM' then return 'cell_ref_trap_spell' end

    if tag == 'BNAM' then return 'cell_ref_global_variable' end

    if tag == 'DNAM' then return 'cell_ref_destination_cell' end

    if tag == 'CELL' then return 'ai_package_cell' end
  end

  if record == 'DCOU' and tag == 'ID__' then return 'death_count_actor' end

  if record == 'PROJ' then
    if tag == 'ID__' then return 'projectile_base_object' end

    if tag == 'BOW_' then return 'projectile_bow_object' end
  end

  if record == 'MPRJ' then
    if tag == 'ID__' then return 'magic_projectile_base_object' end

    if tag == 'SPEL' then return 'magic_projectile_spell' end
  end

  if tag == 'TARG' then
    if record == 'GSCR' then return 'global_script_target_ref_id' end

    if not isAiRefnumTarget(r, k) then return 'ai_target_ref_id' end
  end

  if tag == 'SPEL' then return 'spell_state_spell' end

  if tag == 'USED' then return 'spell_state_used_spell' end

  if tag == 'SLCT' then return 'selected_spell' end

  -- Active-spell SPID is always generated, and MGEF/ARG_ name built-in effects, skills, and
  -- attributes; none can be plugin content, and the engine drops dangling ones on update.
  return nil
end

--- What the FormId in subrecord `k` means (`classify_openmw_save_form_id_field`), or nil.
local function formIdField(r: Record, k: number): string?
  local tag = tagAt(r, k) :: string
  if tag == 'TARG' then return if isAiRefnumTarget(r, k) then 'ai_target_refnum' else nil end

  local record = r.tag
  if tag == 'FRMR' then
    if record == 'LUAM' then return 'lua_refnum' end

    if record == 'GSCR' then return 'global_script_target_refnum' end

    return 'object_refnum'
  end

  if record == 'CSTA' and tag == 'MVRF' then return 'moved_refnum' end

  if (record == 'PROJ' or record == 'MPRJ') and tag == 'ACTO' then
    return 'projectile_caster_refnum'
  end

  if record == 'MPRJ' and tag == 'ITEM' then return 'magic_projectile_item_refnum' end

  if tag == 'CAST' then return 'active_spell_caster_refnum' end

  if tag == 'ITEM' then return 'active_spell_item_refnum' end

  if tag == 'SUM_' then return 'active_spell_summon_refnum' end

  if tag == 'ACID' then return 'creature_summon_actor_refnum' end

  if tag == 'SPAW' then return 'creature_spawned_actor_refnum' end

  if tag == 'TAID' then return 'ai_target_actor_refnum' end

  return nil
end

--- The player's own NPC_ record is player state, never content.
local function isProtected(recordTag: string, meaning: string, id: string): boolean
  return recordTag == 'NPC_' and meaning == 'saved_record_id' and string.lower(id) == 'player'
end

export type RefIdField = { record: Record, subrecord: number, meaning: string, id: string }

--- Every RefId in the fields the scans know, in save order, with what each means. `protected`
--- keeps the player's own record id.
local function refIdFields(records: { Record }, protected: boolean?): { RefIdField }
  local out = {}
  for _, r in records do
    if not Records.isScannable(r.tag) then continue end

    local inventoryItemsRemaining = 0
    for k = 0, #r.subs - 1 do
      if tagAt(r, k) == 'ICNT' then
        inventoryItemsRemaining = Records.inventoryCount(payload(r, k))
        continue
      end

      local meaning = refIdField(r, k, inventoryItemsRemaining)
      if not meaning then continue end

      if meaning == 'inventory_item_base_object' then
        inventoryItemsRemaining = math.max(inventoryItemsRemaining - 1, 0)
      end

      local id = Records.refId(payload(r, k))
      if not id then continue end

      if not protected and isProtected(r.tag, meaning, id) then continue end

      table.insert(out, { record = r, subrecord = k, meaning = meaning, id = id })
    end
  end

  return out
end

--[[ Groups ]]

export type Range = { start: number, finish: number }

--- The CSTA object group subrecord `k` is in, `OBJE` up to the next `OBJE` or `MVRF`, and where its
--- FRMR is; nil outside one.
local function cstaReferenceGroup(r: Record, k: number): (Range?, number)
  if r.tag ~= 'CSTA' or k >= #r.subs then return nil, 0 end

  local start: number? = nil
  for j = k, 0, -1 do
    if tagAt(r, j) == 'OBJE' then
      start = j
      break
    end
  end

  if not start then return nil, 0 end

  local frmr = start + 1
  if tagAt(r, frmr) ~= 'FRMR' then return nil, 0 end

  local finish = #r.subs
  for j = frmr + 1, #r.subs - 1 do
    local tag = tagAt(r, j)
    if tag == 'OBJE' or tag == 'MVRF' then
      finish = j
      break
    end
  end

  if k < start or k >= finish then return nil, 0 end

  return { start = start, finish = finish }, frmr
end

--- A moved-reference marker: `MVRF` and the `NAME` cell id after it.
local function cstaMovedReferenceGroup(r: Record, k: number): Range?
  if r.tag ~= 'CSTA' or tagAt(r, k) ~= 'MVRF' then return nil end

  if tagAt(r, k + 1) ~= 'NAME' then return nil end

  return { start = k, finish = k + 2 }
end

--- The inventory item subrecord `k` is in: its FRMR up to the next item's (or the OBJE before it).
local function inventoryItemGroup(r: Record, k: number): Range?
  if k >= #r.subs then return nil end

  local start: number? = nil
  for j = k, 0, -1 do
    if tagAt(r, j) == 'FRMR' then
      start = j
      break
    end
  end

  if not start then return nil end

  local finish = #r.subs
  for j = start + 1, #r.subs - 1 do
    if tagAt(r, j) == 'FRMR' then
      finish = if j > 0 and tagAt(r, j - 1) == 'OBJE' then j - 1 else j
      break
    end
  end

  if k < start or k >= finish then return nil end

  return { start = start, finish = finish }
end

--- The ICNT an inventory group at `groupStart` counts toward.
local function inventoryCountFor(r: Record, groupStart: number): number?
  for j = groupStart - 1, 0, -1 do
    if tagAt(r, j) == 'ICNT' then return j end
  end

  return nil
end

--- A stolen item in STLN: its NAME up to the next NAME.
local function stolenItemGroup(r: Record, k: number): Range?
  if r.tag ~= 'STLN' or k >= #r.subs then return nil end

  local start: number? = nil
  for j = k, 0, -1 do
    if tagAt(r, j) == 'NAME' then
      start = j
      break
    end
  end

  if not start then return nil end

  local finish = #r.subs
  for j = start + 1, #r.subs - 1 do
    if tagAt(r, j) == 'NAME' then
      finish = j
      break
    end
  end

  if k < start or k >= finish then return nil end

  return { start = start, finish = finish }
end

--- An AI package: its AIPK up to the next AIPK, the sequence's LAST, or the record's end.
local function aiPackage(r: Record, k: number): Range?
  local start: number? = nil
  for j = k, 0, -1 do
    if tagAt(r, j) == 'AIPK' then
      start = j
      break
    end
  end

  if not start then return nil end

  local finish = #r.subs
  for j = start + 1, #r.subs - 1 do
    local tag = tagAt(r, j)
    if tag == 'AIPK' or tag == 'LAST' then
      finish = j
      break
    end
  end

  if k < start or k >= finish then return nil end

  return { start = start, finish = finish }
end

--- Saves write a locked object's level as FLTV, `i32::MAX` for a key-only (level 0) lock.
local function isPickableLockBefore(r: Record, k: number): boolean
  if k < 1 or tagAt(r, k - 1) ~= 'FLTV' then return false end

  local data = payload(r, k - 1)
  if #data ~= 4 then return false end

  local level = Records.i32At(data)
  return level > 0 and level ~= 2147483647
end

--- Whether subrecord `k` is in a CSTA object group whose FRMR points at content file `target`.
local function inTargetCstaGroup(r: Record, k: number, target: number): boolean
  if r.tag ~= 'CSTA' then return false end

  local group, frmr = cstaReferenceGroup(r, k)
  if not group then return false end

  local index, contentFile = Records.wideFormId(payload(r, frmr))
  return index ~= nil and contentFile == target
end

local DeletePolicies: { [string]: { [string]: string } } = {
  CSTA = { saved_cell_state = 'target_introduced_cell_state_can_be_removed' },
  GSCR = { global_script = 'target_introduced_global_script_state_can_be_removed' },
  GLOB = { global_variable = 'target_introduced_global_variable_state_can_be_removed' },
  DCOU = { death_count_actor = 'target_introduced_death_count_can_be_removed' },
  MARK = { custom_marker_cell = 'target_introduced_custom_marker_cell_can_be_removed' },
  PROJ = {
    projectile_base_object = 'target_introduced_projectile_state_can_be_removed',
    projectile_bow_object = 'target_introduced_projectile_state_can_be_removed',
  },

  MPRJ = {
    magic_projectile_base_object = 'target_introduced_magic_projectile_state_can_be_removed',
    magic_projectile_spell = 'target_introduced_magic_projectile_state_can_be_removed',
  },
}

--- Why a whole save record whose `meaning` field names a removed record can go, or nil.
local function deletePolicy(recordTag: string, meaning: string): string?
  local policies = DeletePolicies[recordTag]
  if policies then return policies[meaning] end

  if ObjectStateTags[recordTag] and meaning == 'saved_record_id' then
    return 'target_introduced_object_state_record_can_be_removed'
  end

  return nil
end

export type FieldEdit = { operation: string, range: Range, reason: string }

--- The fix for a target-only id in object state OpenMW keeps after load (owner, faction, trap,
--- global, a pickable lock's key, AI packages, stale spell and script state), or nil.
local function fieldEdit(r: Record, k: number, meaning: string): FieldEdit?
  local single = { start = k, finish = k + 1 }
  if meaning == 'cell_ref_owner' then
    return {
      operation = 'clear_cell_ref_field',
      range = single,
      reason = 'owner_npc_is_introduced_by_removed_dependency',
    }
  end

  if meaning == 'cell_ref_trap_spell' then
    return {
      operation = 'clear_cell_ref_field',
      range = single,
      reason = 'trap_spell_is_introduced_by_removed_dependency',
    }
  end

  if meaning == 'cell_ref_global_variable' then
    return {
      operation = 'clear_cell_ref_field',
      range = single,
      reason = 'ownership_global_is_introduced_by_removed_dependency',
    }
  end

  if meaning == 'cell_ref_owner_faction' then
    -- The faction rank (INDX) is written right after CNAM and means nothing without it.
    local width = if tagAt(r, k + 1) == 'INDX' then 2 else 1
    return {
      operation = 'clear_cell_ref_field',
      range = { start = k, finish = k + width },
      reason = 'owner_faction_is_introduced_by_removed_dependency',
    }
  end

  if meaning == 'cell_ref_key' then
    if not isPickableLockBefore(r, k) then return nil end

    return {
      operation = 'clear_cell_ref_field',
      range = single,
      reason = 'lock_key_is_introduced_by_removed_dependency',
    }
  end

  -- Spell state the engine discards when the spell is gone (openmw spells.cpp:223-249), and a
  -- global script target it tolerates; delete rather than block.
  if
    meaning == 'spell_state_spell'
    or meaning == 'selected_spell'
    or meaning == 'global_script_target_ref_id'
  then
    return {
      operation = 'delete_stale_state_field',
      range = single,
      reason = 'state_references_record_introduced_by_removed_dependency',
    }
  end

  if meaning == 'spell_state_used_spell' then
    -- SpellState writes a used power as USED + TIME; NpcStats writes a lone USED.
    local width = if tagAt(r, k + 1) == 'TIME' then 2 else 1
    return {
      operation = 'delete_stale_state_field',
      range = { start = k, finish = k + width },
      reason = 'state_references_record_introduced_by_removed_dependency',
    }
  end

  if meaning == 'ai_target_ref_id' or meaning == 'ai_package_cell' then
    local range = aiPackage(r, k)
    if not range then return nil end

    return {
      operation = 'delete_ai_package',
      range = range,
      reason = 'ai_package_targets_record_introduced_by_removed_dependency',
    }
  end

  return nil
end

--- Whether a strip has a planned fix for a target-only id in this field.
local function canPlanDelete(r: Record, k: number, meaning: string): boolean
  if deletePolicy(r.tag, meaning) or fieldEdit(r, k, meaning) then return true end

  if meaning == 'cell_ref_base_object' then return (cstaReferenceGroup(r, k)) ~= nil end

  if meaning == 'inventory_item_base_object' then
    local group = inventoryItemGroup(r, k)
    return group ~= nil and inventoryCountFor(r, group.start) ~= nil
  end

  if meaning == 'stolen_item_ref_id' then return stolenItemGroup(r, k) ~= nil end

  return false
end

--[[ Content file references ]]

export type Hit = {
  record: Record,
  subrecord: number,
  meaning: string,
  contentFile: number,
  localIndex: number,
}

--- Every FormId and serialized Lua RefNum the scans know, with the content file it points at.
local function contentFileHits(records: { Record }): { Hit }
  local hits = {}
  for _, r in records do
    if not Records.isScannable(r.tag) then continue end

    for k = 0, #r.subs - 1 do
      local meaning = formIdField(r, k)
      if meaning then
        local index, contentFile = Records.wideFormId(payload(r, k))
        if index then
          table.insert(hits, {
            record = r,
            subrecord = k,
            meaning = meaning,
            contentFile = contentFile,
            localIndex = index,
          })
        end
      elseif tagAt(r, k) == 'LUAD' then
        local s = r.subs[k + 1]
        -- decodeLuaData throws on a payload that isn't serialized Lua; such a payload holds no refs.
        local ok, value = pcall(tes3.save.decodeLuaData, r.source, s.payload, s.size)
        if not ok then continue end

        for _, ref in tes3.save.luaRefs(value :: tes3.LuaValue) do
          table.insert(hits, {
            record = r,
            subrecord = k,
            meaning = 'lua_serialized_refnum',
            contentFile = ref.contentFile,
            localIndex = ref.index,
          })
        end
      end
    end
  end

  return hits
end

local function hasUnknownUserdata(value: tes3.LuaValue): boolean
  if value.kind == 'userdata' then return true end

  for _, entry in value.entries or {} do
    if hasUnknownUserdata(entry.key) or hasUnknownUserdata(entry.value) then return true end
  end

  return false
end

--- Whether a record has a LUAD payload that doesn't decode or holds userdata jess can't read.
local function hasUnparsedLuaData(r: Record): boolean
  for _, s in r.subs do
    if s.tag ~= 'LUAD' then continue end

    -- decodeLuaData throws on a payload that isn't serialized Lua; that's unparsed.
    local ok, value = pcall(tes3.save.decodeLuaData, r.source, s.payload, s.size)
    if not ok or hasUnknownUserdata(value :: tes3.LuaValue) then return true end
  end

  return false
end

local KnownScans = {
  'openmw_refid_name_fields',
  'openmw_refid_projectile_fields',
  'openmw_refid_spell_fields',
  'openmw_refid_death_count_fields',
  'openmw_refid_player_birthsign_fields',
  'openmw_refid_cell_ref_ownership_lock_trap_fields',
  'openmw_string_cell_ref_global_and_destination_fields',
  'openmw_refid_ai_package_target_fields',
  'openmw_refid_custom_marker_fields',
  'openmw_csta_cell_state_fields',
  'openmw_formid_frmr_fields',
  'openmw_formid_csta_mvrf_fields',
  'openmw_formid_projectile_fields',
  'openmw_formid_global_script_fields',
  'openmw_formid_active_spell_fields',
  'openmw_formid_creature_state_fields',
  'openmw_formid_ai_sequence_fields',
  'openmw_lua_serialized_data',
}

export type Coverage = {
  status: string,
  knownScans: { string },
  unclassifiedRiskyRecords: { [string]: number },
}

--- Which records hold Lua data the scans can't classify.
local function coverage(records: { Record }): Coverage
  local risky: { [string]: number } = {}
  local any = false
  for _, r in records do
    if hasUnparsedLuaData(r) then
      risky[r.tag] = (risky[r.tag] or 0) + 1
      any = true
    end
  end

  return {
    status = if any then 'blocked_by_unclassified_lua' else 'known_fields',
    knownScans = table.clone(KnownScans),
    unclassifiedRiskyRecords = risky,
  }
end

return table.freeze {
  aiPackage = aiPackage,
  aiPackageTypeBefore = aiPackageTypeBefore,
  canPlanDelete = canPlanDelete,
  contentFileHits = contentFileHits,
  coverage = coverage,
  cstaMovedReferenceGroup = cstaMovedReferenceGroup,
  cstaReferenceGroup = cstaReferenceGroup,
  deletePolicy = deletePolicy,
  fieldEdit = fieldEdit,
  formIdField = formIdField,
  inTargetCstaGroup = inTargetCstaGroup,
  inventoryCountFor = inventoryCountFor,
  inventoryItemGroup = inventoryItemGroup,
  isPickableLockBefore = isPickableLockBefore,
  isProtected = isProtected,
  refIdField = refIdField,
  refIdFields = refIdFields,
  stolenItemGroup = stolenItemGroup,
}
