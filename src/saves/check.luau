--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Whether a save loads with a load order (jess-save's `check`), and an OpenMW save's own structure
(`validate`). The check compares the save's content list with the active content, then looks up
every id the save references in the active content and the save's own dynamic records; severity
follows what the engine does with a missing record (`docs/save-strip.md` has the sources).
]]

local LoadOrder = require './loadorder'
local Read = require './read'
local Records = require './records'
local Scan = require './scan'
local tes3 = require '@dreamwind/tes3'

type Plugin = tes3.Plugin
type Record = Records.Record
type Save = Read.Save

local camelCase = tes3.text.camelCase

--- Record types OpenMW writes as dynamic records (player-made spells, potions, the player).
local DynamicTagList = {
  'ALCH',
  'ARMO',
  'BOOK',
  'CLAS',
  'CLOT',
  'ENCH',
  'NPC_',
  'MISC',
  'ACTI',
  'SPEL',
  'WEAP',
  'LEVC',
  'LEVI',
  'CREA',
  'CONT',
  'LIGH',
  'STAT',
  'DOOR',
  'PROB',
  'INGR',
}

local DynamicTags: { [string]: boolean } = {}
for _, tag in DynamicTagList do
  DynamicTags[tag] = true
end

--[[ Structure ]]

--- Each CSTA object group's and moved reference's layout problems, at the subrecord it's about.
local function cstaProblems(records: { Record }): { tes3.Diagnostic }
  local out = {}
  for _, r in records do
    if r.tag ~= 'CSTA' then continue end

    for k = 0, #r.subs - 1 do
      local tag = Records.tagAt(r, k)
      local offset = r.subs[k + 1].start
      if tag == 'OBJE' then
        if Records.tagAt(r, k + 1) ~= 'FRMR' then
          table.insert(
            out,
            { offset = offset, message = `#{r.index} CSTA OBJE #{k} is not followed by FRMR` }
          )
        elseif Records.tagAt(r, k + 2) ~= 'NAME' then
          table.insert(out, {
            offset = offset,
            message = `#{r.index} CSTA OBJE #{k} FRMR #{k + 1} is not followed by NAME`,
          })
        end
      elseif tag == 'MVRF' and Records.tagAt(r, k + 1) ~= 'NAME' then
        table.insert(
          out,
          { offset = offset, message = `#{r.index} CSTA MVRF #{k} is not followed by NAME` }
        )
      end
    end
  end

  return out
end

--- The CSTA layout problems' messages.
local function cstaMessages(plugin: Plugin): { string }
  local out = {}
  for _, diagnostic in cstaProblems(Records.all(plugin)) do
    table.insert(out, diagnostic.message)
  end

  return out
end

--- Why OpenMW wouldn't load a save of this format version, or nil when it would.
local function compatibilityProblem(compatibility: tes3.Compatibility): string?
  if compatibility.kind == 'tooOld' then
    return `save format {compatibility.version} is older than OpenMW supports ({compatibility.minimum})`
  end

  if compatibility.kind == 'tooNew' then
    return `save format {compatibility.version} is newer than jess understands ({compatibility.maximum})`
  end

  return nil
end

--- jess-plugin's error offset and message from a thrown `... at offset N`.
local function offsetOf(problem: string): (number, string)
  local message, offset = string.match(problem, '^(.*) at offset (%d+)$')
  if message then return tonumber(offset) :: number, message end

  return 0, problem
end

export type Validation = { checks: { string }, diagnostics: { tes3.Diagnostic } }

--- Checks an OpenMW save's own structure without a load order: the file's framing, a readable
--- SAVE header, a format version OpenMW loads, and cell state laid out the way the engine reads it.
local function validate(plugin: Plugin): Validation
  local checks = { 'structure', 'saveMetadata', 'saveFormat', 'cellState' }
  local diagnostics = plugin:validateProfile 'omwsave'
  -- profile throws on metadata that doesn't read; that's the finding.
  local ok, problem = pcall(tes3.save.profile, plugin)
  if not ok then
    local offset, message = offsetOf(tostring(problem))
    table.insert(
      diagnostics,
      { offset = offset, message = `not a readable OpenMW save: {message} at offset {offset}` }
    )
    return { checks = checks, diagnostics = diagnostics }
  end

  -- compatibility throws when the format version doesn't read.
  local read, compatibility = pcall(tes3.save.compatibility, plugin)
  if read then
    local text = compatibilityProblem(compatibility :: tes3.Compatibility)
    if text then table.insert(diagnostics, { offset = 0, message = text }) end
  else
    local offset, message = offsetOf(tostring(compatibility))
    table.insert(
      diagnostics,
      { offset = offset, message = `failed to read the save format: {message} at offset {offset}` }
    )
  end

  for _, diagnostic in cstaProblems(Records.all(plugin)) do
    table.insert(diagnostics, diagnostic)
  end

  return { checks = checks, diagnostics = diagnostics }
end

local function structureProblems(plugin: Plugin): { string }
  local problems = {}
  for _, diagnostic in plugin:validateProfile(plugin.profile) do
    table.insert(problems, `offset {diagnostic.offset}: {diagnostic.message}`)
  end

  -- compatibility throws when the format version doesn't read.
  local ok, compatibility = pcall(tes3.save.compatibility, plugin)
  if not ok then error(`failed to read OpenMW save version: {compatibility}`, 0) end

  local text = compatibilityProblem(compatibility :: tes3.Compatibility)
  if text then table.insert(problems, text) end

  for _, message in cstaMessages(plugin) do
    table.insert(problems, message)
  end

  return problems
end

--[[ Ids ]]

--- The ids of the save's own dynamic records (player-made spells and potions, the player), as
--- tokens of `ids`, the pool content ids read in `encoding` are interned in.
local function dynamicIds(
  records: { Record },
  ids: LoadOrder.Pool,
  encoding: string
): { [number]: boolean }
  local known: { [number]: boolean } = {}
  for _, r in records do
    if not DynamicTags[r.tag] then continue end

    local name = Records.first(r, 'NAME')
    if not name then continue end

    local id = Records.refId(Records.payload(r, name))
    if id then known[LoadOrder.token(ids, id, encoding, true) :: number] = true end
  end

  return known
end

--- Every record id defined by the active content, read in `encoding`, and by the save's own
--- dynamic records, as tokens of `ids`.
local function knownIds(
  records: { Record },
  order: LoadOrder.LoadOrder,
  encoding: string,
  warnings: { string },
  ids: LoadOrder.Pool
): { [number]: boolean }
  local known = dynamicIds(records, ids, encoding)
  for _, content in order.content do
    local path = content.path
    if not path or not Records.isRecordContentFile(path) then continue end

    local plugin, problem = LoadOrder.openContent(order, path, encoding)
    if not plugin then
      table.insert(
        warnings,
        `could not read active content '{content.name}' ({problem}); ids it defines are reported as missing`
      )
      continue
    end

    for _, token in LoadOrder.ids(plugin, ids).tokens do
      if token then known[token] = true end
    end
  end

  return known
end

--[[ Findings ]]

export type Finding = {
  severity: string,
  problem: string,
  id: string,
  recordIndex: number,
  recordType: string,
  subrecordIndex: number,
  subrecordType: string,
}

--- What the engine does when this field names a missing record: a severity and problem, or nil
--- when it drops it harmlessly.
local function assess(r: Record, k: number, meaning: string): (string?, string)
  if meaning == 'player_birthsign' then return 'will_not_load', 'missing_birthsign' end

  if meaning == 'player_race' then return 'will_not_load', 'missing_player_race' end

  if meaning == 'player_class' then return 'will_not_load', 'missing_player_class' end

  if meaning == 'player_head' then return 'broken', 'player_head_missing' end

  if meaning == 'player_hair' then return 'broken', 'player_hair_missing' end

  if meaning == 'cell_ref_trap_spell' then return 'broken', 'trapped_object_cannot_be_opened' end

  if meaning == 'cell_ref_global_variable' then
    return 'broken', 'object_ownership_global_missing'
  end

  if meaning == 'cell_ref_destination_cell' then return 'broken', 'door_leads_to_missing_cell' end

  if meaning == 'cell_ref_owner' then return 'broken', 'owned_by_missing_npc' end

  if meaning == 'cell_ref_owner_faction' then return 'broken', 'owned_by_missing_faction' end

  if meaning == 'cell_ref_key' and not Scan.isPickableLockBefore(r, k) then
    return 'broken', 'key_only_lock_key_missing'
  end

  if meaning == 'ai_target_ref_id' or meaning == 'ai_package_cell' then
    local package = Scan.aiPackageTypeBefore(r, k)
    if package == 'FOLL' or package == 'ESCO' then
      return 'broken', 'npc_follows_or_escorts_missing_target'
    end
  end

  -- In PLAY, the NAME after FRMR is the player's base record and the NAME after MARK the Mark cell
  -- (dropped); the remaining one is the player's current cell.
  if meaning == 'player_ref_id' and r.tag == 'PLAY' then
    local previous = Records.tagAt(r, k - 1)
    if previous ~= 'FRMR' and previous ~= 'MARK' then return 'warning', 'player_cell_missing' end
  end

  return nil, ''
end

local function scanReferences(
  records: { Record },
  known: { [number]: boolean },
  ids: LoadOrder.Pool,
  encoding: string
): ({ Finding }, { [string]: number })
  local findings: { Finding } = {}
  local dropped: { [string]: number } = {}
  for _, field in Scan.refIdFields(records, true) do
    if field.id == '' then continue end

    local token = LoadOrder.token(ids, field.id, encoding)
    if token and known[token] then continue end

    local r, k = field.record, field.subrecord
    local severity, problem = assess(r, k, field.meaning)
    if severity then
      table.insert(findings, {
        severity = camelCase(severity),
        problem = camelCase(problem),
        id = field.id,
        recordIndex = r.index,
        recordType = r.tag,
        subrecordIndex = k,
        subrecordType = Records.tagAt(r, k) :: string,
      })
    else
      local key = camelCase(field.meaning)
      dropped[key] = (dropped[key] or 0) + 1
    end
  end

  return findings, dropped
end

--- Whether the content both lists share appears in the same order in each.
local function sameRelativeOrder(dependencies: { string }, active: { LoadOrder.Content }): boolean
  local inSave: { [string]: boolean } = {}
  for _, dependency in dependencies do
    inSave[string.lower(dependency)] = true
  end

  local inActive: { [string]: boolean } = {}
  local activeOrder = {}
  for _, content in active do
    local lower = string.lower(content.name)
    inActive[lower] = true
    if inSave[lower] then table.insert(activeOrder, lower) end
  end

  local saveOrder = {}
  for _, dependency in dependencies do
    local lower = string.lower(dependency)
    if inActive[lower] then table.insert(saveOrder, lower) end
  end

  if #activeOrder ~= #saveOrder then return false end

  for i, name in activeOrder do
    if saveOrder[i] ~= name then return false end
  end

  return true
end

export type MissingContent = { name: string, strippable: boolean }

export type Check = {
  input: string,
  verdict: string,
  loads: boolean,
  formatVersion: number,
  strippableFormat: boolean,
  structureProblems: { string },
  loadOrderChecked: boolean,
  missingContent: { MissingContent },
  addedContent: { string },
  orderChanged: boolean,
  findings: { Finding },
  droppedOnLoad: { [string]: number },
  warnings: { string },
}

export type CheckOptions = {
  --- The load order to check against; without one only the save's structure is checked.
  loadOrder: LoadOrder.LoadOrder?,
  --- Why the load order couldn't be had, reported as a warning (a config that failed to load).
  loadOrderError: string?,
}

--- Whether `save` loads with `options.loadOrder`, as it is in memory.
local function check(save: Save, options: CheckOptions?): Check
  Read.requireOpenMw(save, 'check')
  local given: CheckOptions = options or {}
  local plugin = save.plugin
  local ok, profile = pcall(tes3.save.profile, plugin)
  if not ok then error(`failed to read the save metadata of '{save.name}': {profile}`, 0) end

  local metadata = profile :: tes3.SaveProfile
  local problems = structureProblems(plugin)
  local warnings: { string } = {}
  local missing: { MissingContent } = {}
  local added: { string } = {}
  local orderChanged = false
  local findings: { Finding } = {}
  local dropped: { [string]: number } = {}
  local order = given.loadOrder
  if given.loadOrderError then
    table.insert(warnings, `could not load the OpenMW config ({given.loadOrderError})`)
  end

  if order then
    local active: { [string]: boolean } = { ['builtin.omwscripts'] = true }
    for _, content in order.content do
      active[string.lower(content.name)] = true
    end

    local resolves: { [string]: boolean } = {}
    local function resolve(name: string): boolean
      local lower = string.lower(name)
      local found = resolves[lower]
      if found == nil then
        found = order.resolve(name) ~= nil
        resolves[lower] = found
      end

      return found
    end

    for _, dependency in metadata.dependencies do
      if active[string.lower(dependency)] then continue end

      -- Strip tells an uninstalled file's records apart by what the rest defines.
      local othersInstalled = true
      for _, other in metadata.dependencies do
        if
          string.lower(other) == string.lower(dependency) or not Records.isRecordContentFile(other)
        then
          continue
        end

        if not resolve(other) then
          othersInstalled = false
          break
        end
      end

      table.insert(
        missing,
        { name = dependency, strippable = othersInstalled or resolve(dependency) }
      )
    end

    local needed: { [string]: boolean } = {}
    for _, dependency in metadata.dependencies do
      needed[string.lower(dependency)] = true
    end

    for _, content in order.content do
      if not needed[string.lower(content.name)] then table.insert(added, content.name) end
    end

    orderChanged = not sameRelativeOrder(metadata.dependencies, order.content)
    -- Save text is UTF-8, so ids read from content in any other code page than the engine's
    -- wouldn't match the save's.
    local records = Records.all(plugin)
    local encoding = order.encoding or plugin.encoding
    local ids = LoadOrder.pool()
    local known = knownIds(records, order, encoding, warnings, ids)
    findings, dropped = scanReferences(records, known, ids, encoding)
  end

  local function has(severity: string): boolean
    for _, finding in findings do
      if finding.severity == severity then return true end
    end

    return false
  end

  local verdict = if #problems > 0
    then 'invalidStructure'
    elseif has 'willNotLoad' then 'willNotLoad'
    elseif has 'broken' then 'brokenState'
    elseif #missing > 0 or #findings > 0 then 'loadsWithWarnings'
    elseif order then 'loadsCleanly'
    else 'structureValid'

  local version = metadata.formatVersion
  return {
    input = save.name,
    verdict = verdict,
    loads = verdict ~= 'invalidStructure' and verdict ~= 'willNotLoad',
    formatVersion = version,
    strippableFormat = version >= tes3.save.MinMutationFormatVersion
      and version <= tes3.save.CurrentFormatVersion,
    structureProblems = problems,
    loadOrderChecked = order ~= nil,
    missingContent = missing,
    addedContent = added,
    orderChanged = orderChanged,
    findings = findings,
    droppedOnLoad = dropped,
    warnings = warnings,
  }
end

return table.freeze {
  check = check,
  cstaMessages = cstaMessages,
  dynamicIds = dynamicIds,
  validate = validate,
}
