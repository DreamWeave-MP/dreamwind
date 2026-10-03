--!strict
--!native
-- late_actor_provenance.py: the actors that appear only after dialogue liveness and the second
-- closure, and why each was imported. A diagnostic, never a deletion list.
--
-- The Python report replays dialogue against two legacy defaults (a Solo build under
-- .swbuild/solo, and the canonical vanilla JSON) instead of the Definitive build's own inputs,
-- and a checkout without that Solo build fails here. This one uses the Definitive build's:
-- the projection the dialogue audit already made from the staged masters and the
-- pre-decoupling plugin.

local dialogue = require './dialogue'
local hygiene = require './hygiene'
local report = require './report'
local tes3 = require '../lib/tes3'

type Record = tes3.Record
type Records = tes3.Records
type Table = tes3.Table
type Value = tes3.Value
type Json = report.Json

local provenance = {}

local ActorTypes = { NPC = true, NPC_ = true, CREA = true, Npc = true, Creature = true }

local function norm(value: Value?): string return string.lower(tes3.string(value)) end

local function afterSnapshot(log: { string }): number
  for index, line in log do
    if line == 'Dialogue liveness population end' then return index + 1 end
  end

  return #log + 1
end

local function snapshot(log: { string }): { [string]: { [string]: string } }
  local actors = {}
  local inside = false

  for _, line in log do
    if line == 'Dialogue liveness population begin' then
      inside = true
    elseif line == 'Dialogue liveness population end' then
      inside = false
    elseif inside and string.sub(line, 1, 24) == 'Dialogue liveness actor\t' then
      local fields = string.split(line, '\t')

      if #fields == 6 then
        actors[string.lower(fields[3])] = {
          id = string.lower(fields[3]),
          type = fields[2],
          race = string.lower(fields[4]),
          class = string.lower(fields[5]),
          sex = string.lower(fields[6]),
        }
      end
    end
  end

  return actors
end

local function copies(log: { string }): { [string]: Json }
  local result: { [string]: Json } = {}

  for index = afterSnapshot(log), #log do
    local id, kind, source = string.match(
      log[index],
      'Copying \'(.+)\' %(([^)]+)%) to \'Starwind%.esp\' from \'([^\']+)\''
    )

    if id and ActorTypes[kind :: string] and result[norm(id)] == nil then
      result[norm(id)] =
        report.object { 'id', id, 'type', kind, 'source_master', source, 'copy_log_line', index }
    end
  end

  return result
end

local function imports(log: { string }): { [string]: { { [string]: Json } } }
  local result: { [string]: { { [string]: Json } } } = {}
  local current: { [string]: Json }? = nil

  for index = afterSnapshot(log), #log do
    local line = log[index]

    if line == 'Dependency import:' then
      current = report.object { 'log_line', index }
      continue
    end

    if not current then continue end

    local entry = current :: { [string]: Json }
    local pass = string.match(line, '^  pass=(.+)$')
    local targetType, targetId = string.match(line, '^  target=([^ ]+) \'(.+)\'$')
    local sourceType, sourceId = string.match(line, '^  source=([^ ]+) \'(.+)\'$')
    local field = string.match(line, '^  field=(.+)$')

    if pass then
      report.set(entry, 'pass', pass)
    elseif targetType then
      report.set(entry, 'target_type', targetType)
      report.set(entry, 'target_id', targetId)
    elseif sourceType then
      report.set(entry, 'source_type', sourceType)
      report.set(entry, 'source_id', sourceId)
    elseif field then
      report.set(entry, 'field', field)
    end

    if entry.target_id ~= nil and entry.field ~= nil then
      local key = norm(entry.target_id :: string)
      result[key] = result[key] or {}
      table.insert(result[key], entry)
      current = nil
    end
  end

  return result
end

local function compactActor(record: Record, source: string, index: number): { [string]: Json }
  local npc = record.type == 'Npc'

  return report.object {
    'id',
    tes3.string(record.id),
    'type',
    record.type :: Json,
    'race',
    if npc then tes3.string(record.race) else '',
    'class',
    if npc then tes3.string(record.class) else '',
    'faction',
    if npc then tes3.string(record.faction) else '',
    'sex',
    if npc
      then (if tes3.hasFlag(string.upper(tes3.string(record.npcFlags)), 'FEMALE')
        then 'female'
        else 'male')
      else '',
    'script',
    tes3.string(record.script),
    'source',
    source,
    'source_record_index',
    index,
  }
end

-- Every scalar in a value with its dotted path, as `record_values` walks it.
local function values(value: Value?, path: string, out: { { path: string, value: Value } })
  if type(value) == 'table' then
    local tbl = value :: Table

    if #tbl > 0 then
      for index, item in tbl do
        values(item, `{path}[{(index :: number) - 1}]`, out)
      end
    else
      for key, item in tbl do
        local name = string.gsub(
          tostring(key),
          '(%u)',
          function(letter: string) return '_' .. string.lower(letter) end
        )
        values(item, if path == '' then name else `{path}.{name}`, out)
      end
    end
  elseif value ~= nil then
    table.insert(out, { path = path, value = value })
  end
end

local function escapePattern(text: string): string
  return (string.gsub(text, '[%^%$%(%)%%%.%[%]%*%+%-%?]', '%%%0'))
end

-- Whether `text` names `id` as a whole word: no word character or hyphen on either side.
local function mentions(text: string, id: string): boolean
  local start = 1

  while true do
    local first, last = string.find(text, escapePattern(id), start)

    if not first then return false end

    local before = if first > 1 then string.sub(text, first - 1, first - 1) else ''
    local after = string.sub(text, (last :: number) + 1, (last :: number) + 1)

    if not string.find(before, '^[%w_-]$') and not string.find(after, '^[%w_-]$') then
      return true
    end

    start = first + 1
  end
end

type Hits = { [string]: { Json } }

local function scan(
  records: Records,
  label: string,
  file: string,
  ids: { [string]: boolean }
): (Hits, Hits, Hits)
  local exact, scripts, placed = {}, {}, {}

  for id in ids do
    exact[id], scripts[id], placed[id] = report.array(), report.array(), report.array()
  end

  for position, record in records do
    local kind = record.type

    if kind == 'Dialogue' or kind == 'DialogueInfo' then continue end

    local recordId = norm(record.id)
    local fields = {}
    values(record, '', fields)

    for _, field in fields do
      local target = string.lower(tostring(field.value))

      if not ids[target] or (field.path == 'id' and target == recordId) then continue end

      local hit = report.object {
        'source',
        label,
        'source_file',
        file,
        'record_type',
        kind :: Json,
        'record_id',
        tes3.string(record.id),
        'record_index',
        position - 1,
        'field',
        field.path,
      }
      table.insert(exact[target], hit)

      if kind == 'Cell' and string.find(field.path, 'references', 1, true) then
        table.insert(placed[target], hit)
      end
    end

    if kind == 'Script' then
      local text = string.lower(tes3.string(record.text))

      for id in ids do
        if mentions(text, id) then
          table.insert(
            scripts[id],
            report.object {
              'source',
              label,
              'source_file',
              file,
              'record_type',
              kind :: Json,
              'record_id',
              tes3.string(record.id),
              'record_index',
              position - 1,
            }
          )
        end
      end
    end
  end

  return exact, scripts, placed
end

local function classify(
  references: { Json },
  nonDialogue: { Json },
  candidates: { Json },
  causal: { Json }
): (string, string)
  local categories: { [string]: boolean } = {}

  for _, value in references do
    categories[(value :: { [string]: Json }).hygiene_classification :: string] = true
  end

  local onlyDirt = categories.PROBABLE_TESCS_LINK_DIRT == true
    and next(categories, next(categories)) == nil

  if #nonDialogue > 0 then
    return 'D', 'has a surviving non-dialogue dependency in the final standalone'
  elseif #references > 0 and onlyDirt then
    return 'A', 'all surviving speaker_id INFOs are probable TESCS link dirt'
  elseif categories.NEW_INFO then
    return 'C', 'at least one surviving speaker_id INFO is a new Starwind INFO'
  elseif categories.MODIFIED_PARENT then
    return 'B', 'at least one surviving speaker_id INFO semantically modifies its parent'
  elseif #causal > 0 then
    return 'D', 'post-dialogue dependency telemetry identifies the import cause'
  elseif #references == 0 and #candidates > 0 then
    return 'D', 'no surviving dependency found; canonical source has candidate references to trace'
  elseif #references == 0 then
    return 'D', 'not explained solely by probable link dirt or a Starwind semantic INFO'
  end

  return 'D',
    'surviving speaker_id INFO is inherited or otherwise not a classified Starwind modification'
end

export type Inputs = {
  log: { string },
  logPath: string,
  final: Records,
  finalPath: string,
  projection: {
    [string]: {
      order: { string },
      infos: { [string]: { record: Record, source: string, sourceIndex: number } },
    },
  },
  audit: Json,
  -- Read only when there are late actors.
  vanillaSources: () -> { hygiene.Source },
  starwindSources: () -> { hygiene.Source },
}

export type Paths = { report: string, markdown: string, cleanup: string }

local function writeMarkdown(path: string, result: { [string]: Json })
  local lines = {
    '# Late Actor Provenance',
    '',
    `Second-closure actors: **{result.late_actor_count}** ({result.snapshot_actor_count} pre-liveness, {result.final_actor_count} final).`,
    '',
    '| Class | Count |',
    '| --- | ---: |',
  }

  local classes = result.late_actor_class_counts :: { [string]: Json }
  local names = {}

  for name in classes do
    table.insert(names, name)
  end

  table.sort(names)

  for _, name in names do
    table.insert(lines, `| {name} | {classes[name]} |`)
  end

  table.insert(lines, '')
  table.insert(lines, '| Actor | Master | Class | Dialogue refs | Other refs | Causal imports |')
  table.insert(lines, '| --- | --- | --- | ---: | ---: | ---: |')

  for _, value in result.actors :: { Json } do
    local row = value :: { [string]: Json }
    local why = row.why_imported_on_second_closure :: { [string]: Json }
    table.insert(
      lines,
      `| \`{(row.actor :: { [string]: Json }).id}\` | \`{row.source_master or '?'}\` | {why.reason_class} | {why.direct_live_dialogue_speaker_id_references} | {why.non_dialogue_exact_references} | {why.causal_dependency_imports} |`
    )
  end

  jess.fs.write(path, table.concat(lines, '\n') .. '\n', { backup = false })
end

local function writeCleanup(path: string, byFile: { [string]: Json })
  local lines = {
    '#!/usr/bin/env bash',
    'set -euo pipefail',
    '',
    '# Generated by late_actor_provenance.py. REVIEW BEFORE EXECUTION.',
    '# Run from the sw_merged/plugins directory, or set TES3CMD explicitly.',
    'TES3CMD="${TES3CMD:-../tes3cmd}"',
    '',
  }

  local binaries = {
    ['StarwindRemasteredPatch.json'] = 'StarwindRemasteredPatch.esm',
    ['StarwindRemasteredV1.15.json'] = 'StarwindRemasteredV1.15.esm',
  }
  local sources = {}

  for source in byFile do
    table.insert(sources, source)
  end

  table.sort(sources)

  for _, source in sources do
    local binary = binaries[source]

    if not binary then error(`no binary mapping for {source}`) end

    local ids = byFile[source] :: { Json }
    table.insert(lines, `# {binary}: {#ids} Class-A INFOs`)
    local command = { '"$TES3CMD"', 'delete', '--type', 'INFO' }

    for _, id in ids do
      table.insert(command, '--exact-id')
      table.insert(command, id :: string)
    end

    table.insert(command, binary)
    table.insert(lines, table.concat(command, ' '))
    table.insert(lines, '')
  end

  jess.fs.write(path, table.concat(lines, '\n'), { backup = false })
end

function provenance.report(inputs: Inputs, paths: Paths): { [string]: Json }
  local before = snapshot(inputs.log)
  local copied = copies(inputs.log)
  local causes = imports(inputs.log)
  local final: { [string]: { [string]: Json } } = {}

  for position, record in inputs.final do
    if (record.type == 'Npc' or record.type == 'Creature') and not tes3.isDeleted(record) then
      final[norm(record.id)] = compactActor(record, inputs.finalPath, position - 1)
    end
  end

  local infoTopics: { [string]: string } = {}
  local topic = ''

  for _, record in inputs.final do
    if record.type == 'Dialogue' then
      topic = tes3.string(record.id)
    elseif record.type == 'DialogueInfo' and tes3.string(record.id) ~= '' then
      infoTopics[norm(record.id)] = topic
    end
  end

  local lateIds = {}

  for id in final do
    if not before[id] then table.insert(lateIds, id) end
  end

  table.sort(lateIds)
  local rows = report.array()
  local classes: { [string]: number } = {}
  local classA: { [string]: { [string]: boolean } } = {}

  if #lateIds > 0 then
    local lateSet = {}

    for _, id in lateIds do
      lateSet[id] = true
    end

    -- The layered hygiene classification of V1.15 and the Patch, by topic and INFO.
    local hygieneRows: { [string]: { [string]: Json } } = {}
    local state = hygiene.vanillaState(inputs.vanillaSources())

    for _, source in inputs.starwindSources() do
      local classified = hygiene.classify(source, state)

      for _, value in classified.records :: { Json } do
        local row = value :: { [string]: Json }
        hygieneRows[`{row.topic}\0{row.info_id}`] = row
      end

      hygiene.apply(state, source.records, source.label)
    end

    local exact, scripts, placed =
      scan(inputs.final, 'Starwind-Standalone.omwaddon', inputs.finalPath, lateSet)
    local sourceExact, sourceScripts, sourcePlaced = {}, {}, {}

    for id in lateSet do
      sourceExact[id], sourceScripts[id], sourcePlaced[id] =
        report.array(), report.array(), report.array()
    end

    local vanillaActors: { [string]: { [string]: Json } } = {}
    local sourceList = table.clone(inputs.vanillaSources())

    for _, source in inputs.starwindSources() do
      table.insert(sourceList, source)
    end

    for _, source in sourceList do
      local e, s, p = scan(source.records, source.label, source.path, lateSet)

      for id in lateSet do
        table.move(e[id], 1, #e[id], #sourceExact[id] + 1, sourceExact[id])
        table.move(s[id], 1, #s[id], #sourceScripts[id] + 1, sourceScripts[id])
        table.move(p[id], 1, #p[id], #sourcePlaced[id] + 1, sourcePlaced[id])
      end
    end

    -- Bloodmoon, Tribunal, Morrowind: addVanillaRefs's lookup order.
    local vanilla = inputs.vanillaSources()

    for position = #vanilla, 1, -1 do
      local source = vanilla[position]

      for index, record in source.records do
        if (record.type == 'Npc' or record.type == 'Creature') and not tes3.isDeleted(record) then
          local id = norm(record.id)

          if vanillaActors[id] == nil then
            vanillaActors[id] = compactActor(record, source.binary or source.label, index - 1)
          end
        end
      end
    end

    for _, id in lateIds do
      local actor = final[id]
      local direct = report.array()

      for topicId, item in inputs.projection do
        for _, entry in item.infos do
          if norm(entry.record.speakerId) ~= id then continue end

          local record = entry.record
          local key = `{topicId}\0{norm(record.id)}`
          local row = hygieneRows[key]
          local data = (record.data or {}) :: Table
          table.insert(
            direct,
            report.object {
              'dial',
              topicId,
              'info_id',
              tes3.string(record.id),
              'source',
              entry.source,
              'source_record_index',
              entry.sourceIndex,
              'hygiene_classification',
              if row then row.category else 'INHERITED_VANILLA',
              'tescs_dirt_confidence',
              if row then row.tescs_dirt_confidence else nil,
              'changed_links',
              if row then row.changed_links else report.object {},
              'parent_source',
              if row then row.parent_source else nil,
              'parent_record_index',
              if row then row.parent_record_index else nil,
              'speaker_id',
              tes3.string(record.speakerId),
              'speaker_race',
              tes3.string(record.speakerRace),
              'speaker_class',
              tes3.string(record.speakerClass),
              'speaker_faction',
              tes3.string(record.speakerFaction),
              'speaker_cell',
              tes3.string(record.speakerCell),
              'speaker_sex',
              (data.speakerSex or '') :: Json,
              'speaker_rank',
              (data.speakerRank or -1) :: Json,
              'player_faction',
              tes3.string(record.playerFaction),
              'text',
              tes3.string(record.text),
              'result',
              '',
              'filters',
              report.snake((record.filters or report.array()) :: Json),
            }
          )
        end
      end

      local nonDialogue = report.array()

      for _, value in exact[id] do
        local hit = value :: { [string]: Json }

        if hit.record_type ~= 'Npc' and hit.record_type ~= 'Creature' then
          table.insert(nonDialogue, hit)
        end
      end

      local causal = report.array()

      for _, entry in causes[id] or {} do
        if string.lower(tes3.string(entry.source_type :: string)) == 'info' then
          report.set(entry, 'source_topic', infoTopics[norm(entry.source_id :: string)] or '')
        end

        table.insert(causal, entry)
      end

      local class, rationale = classify(direct, nonDialogue, sourceExact[id], causal)
      classes[class] = (classes[class] or 0) + 1
      local copy = copied[id] :: { [string]: Json }?
      local vanillaActor = vanillaActors[id]

      if class == 'A' then
        for _, value in direct do
          local reference = value :: { [string]: Json }

          if reference.hygiene_classification == 'PROBABLE_TESCS_LINK_DIRT' then
            local source = reference.source :: string
            classA[source] = classA[source] or {}
            classA[source][norm(reference.info_id :: string)] = true
          end
        end
      end

      table.insert(
        rows,
        report.object {
          'actor',
          actor,
          'source_master',
          (copy and copy.source_master) or (vanillaActor and vanillaActor.source) or nil,
          'source_record_index',
          vanillaActor and vanillaActor.source_record_index or nil,
          'copy_log_line',
          copy and copy.copy_log_line or nil,
          'why_imported_on_second_closure',
          report.object {
            'direct_live_dialogue_speaker_id_references',
            #direct,
            'non_dialogue_exact_references',
            #nonDialogue,
            'source_reference_candidates',
            #sourceExact[id],
            'causal_dependency_imports',
            #causal,
            'reason_class',
            class,
            'classification_rationale',
            rationale,
          },
          'surviving_info_references',
          direct,
          'non_dialogue_references',
          nonDialogue,
          'script_text_mentions',
          scripts[id],
          'placed_references',
          placed[id],
          'source_reference_candidates',
          sourceExact[id],
          'source_script_text_mentions',
          sourceScripts[id],
          'source_placed_references',
          sourcePlaced[id],
          'causal_dependency_imports',
          causal,
        }
      )
    end
  end

  local classNames = {}

  for name in classes do
    table.insert(classNames, name)
  end

  table.sort(classNames)
  local classPairs = {}

  for _, name in classNames do
    table.insert(classPairs, name)
    table.insert(classPairs, classes[name])
  end

  local byFile = report.dict()

  for source, ids in classA do
    local list = {}

    for id in ids do
      table.insert(list, id)
    end

    table.sort(list)
    byFile[source] = report.array(list)
  end

  local snapshotCount, finalCount = 0, 0

  for _ in before do
    snapshotCount += 1
  end

  for _ in final do
    finalCount += 1
  end

  local result = report.object {
    'version',
    1,
    'log',
    inputs.logPath,
    'standalone',
    inputs.finalPath,
    'snapshot_actor_count',
    snapshotCount,
    'final_actor_count',
    finalCount,
    'late_actor_count',
    #rows,
    'late_actor_class_counts',
    report.object(classPairs),
    'class_a_info_ids_by_source',
    byFile,
    'dialogue_liveness_audit',
    inputs.audit,
    'actors',
    rows,
  }

  report.write(paths.report, result)
  writeMarkdown(paths.markdown, result)

  if next(byFile) ~= nil then writeCleanup(paths.cleanup, byFile) end

  return result
end

return provenance
