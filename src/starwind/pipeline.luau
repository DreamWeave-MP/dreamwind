--!strict
--!native
-- build_starwind.py's stages, over record lists instead of files in a work folder.

local addVanillaRefs = require '@dreamwind/tools/add-vanilla-refs'
local bytes = require '@dream/bytes'
local mergeToMaster = require '@dreamwind/tools/merge-to-master'
local sources = require './sources'
local surgery = require './surgery'
local tes3 = require '../lib/tes3'
local tes3conv = require '@dreamwind/tools/tes3conv'

type Table = tes3.Table
type Record = tes3.Record
type Records = tes3.Records

-- The staged plugins, by the file name the Python build gives each.
export type Work = { [string]: Records }

local pipeline = {}

local VanillaLazy = { Cell = true, Landscape = true, PathGrid = true }

export type Compiled = {
  -- Each source's records in its JSON's order, as the Python audits read the JSON.
  raw: { [string]: Records },
  -- Each source's JSON file and its SHA-256, by source key.
  files: { [string]: { path: string, sha256: string } },
}

-- Every included source, read from `plugins` (the sw_merged/plugins folder). The Bethesda
-- masters' cells, landscape, and path grids are read only if something asks for them: nothing in
-- the build copies them, and they are most of Morrowind.json.
function pipeline.compile(plugins: string): (Work, Compiled)
  local work: Work = {}
  local compiled: Compiled = { raw = {}, files = {} }
  local vanilla = {}

  for _, key in sources.Vanilla do
    vanilla[key] = true
  end

  for _, source in sources.Included do
    local path = jess.fs.join(plugins, source.json)
    local text = jess.fs.read(path)

    if not text then error(`missing definitive source JSON: {source.json}`) end

    local records =
      tes3conv.decode(text, { lazy = if vanilla[source.key] then VanillaLazy else nil })
    compiled.raw[source.binary] = records
    compiled.files[source.key] = { path = path, sha256 = bytes.sha256(text) }
    -- `tes3conv -o source.json source.esm` sorts what it writes.
    work[source.binary] = tes3conv.sort(records)
  end

  return work, compiled
end

-- The staged plugins, in the order build_starwind.py lists its sources: tes3cmd backups never
-- exist here, so this is its `active_staged_plugins`.
function pipeline.active(work: Work): { Records }
  local list = {}

  for _, source in sources.Included do
    local records = work[source.binary]

    if records then table.insert(list, records) end
  end

  return list
end

local function apply(work: Work, names: { string }, edit: (records: Records) -> Records?)
  for _, name in names do
    local records = work[name]

    if not records then error(`'{name}' isn't staged`) end

    local replaced = edit(records)

    if replaced then work[name] = replaced end
  end
end

-- `tes3cmd modify [--type T] [--exact-id ID] --replace "/from/to/"`: the replacement runs on each
-- field of each subrecord, never on the "Field:value" text a dump shows. A record's string fields
-- stand in for its subrecords' fields.
local function replaceFieldValues(
  records: Records,
  kind: string,
  id: string?,
  from: string,
  to: string
): number
  local changed = 0

  for index, record in records do
    if record.type ~= kind or (id and surgery.id(record) ~= string.lower(id)) then continue end

    local copy: Table? = nil

    for field, value in record do
      if type(value) ~= 'string' or field == 'type' then continue end

      local replaced, count = tes3.replaceNoCase(value, from, to)

      if count > 0 then
        copy = copy or table.clone(record);
        (copy :: Table)[field] = replaced
      end
    end

    if copy then
      records[index] = copy
      changed += 1
    end
  end

  return changed
end

-- motherjungle_audit.common_preprocess(work, "definitive").
local function commonPreprocess(work: Work)
  local v115, patch = 'StarwindRemasteredV1.15.esm', 'StarwindRemasteredPatch.esm'
  local enhanced = 'Starwind Enhanced.esm'

  apply(work, { v115, patch }, function(records)
    surgery.replaceScriptText(records, 'who\'s ship', 'whose ship')
    return nil
  end)

  apply(
    work,
    { patch },
    function(records) return (surgery.deleteIds(records, { 'Script' }, { 'sw_' })) end
  )

  for _, records in pipeline.active(work) do
    surgery.destroyBytecode(records)
  end

  apply(work, { patch }, function(records)
    replaceFieldValues(
      records,
      'Weapon',
      'sw_grplasm',
      'Name:44mm Pasma Grenade',
      'Name:44mm Plasma Grenade'
    )
    return nil
  end)

  apply(work, { v115, patch }, function(records)
    replaceFieldValues(records, 'Activator', nil, 'Name:Asteriod', 'Name:Asteroid')
    return nil
  end)

  for _, cell in sources.JunkCells do
    apply(
      work,
      { v115, patch },
      function(records) return (surgery.deleteIds(records, { 'Cell', 'PathGrid' }, { cell })) end
    )
  end

  apply(work, { v115, patch }, function(records) return (surgery.deleteExteriorCells(records)) end)

  apply(work, { patch }, function(records)
    local kept = surgery.deleteIds(records, { 'GameSetting' }, { 'sEffectTurnUndead' })
    return (surgery.deleteIds(kept, { 'MagicEffect' }, { '101' }))
  end)

  apply(work, { patch, v115 }, function(records)
    surgery.deleteLeveledCreatures(records, 'sw_sandcreatures', 'SW_Rakhoul1')
    return nil
  end)

  if work[enhanced] then
    apply(
      work,
      { enhanced },
      function(records) return (surgery.deleteIds(records, { 'Cell' }, { 'Tatooine' })) end
    )

    local function instances(name: string, options: surgery.InstanceDelete)
      apply(work, { name }, function(records)
        surgery.deleteInstances(records, options)
        return nil
      end)
    end

    local office = 'Taris, Central Plaza: Government Office'
    local tower = 'Taris, Central Plaza: Capital Tower Upper Level'
    instances(enhanced, { exactIds = { 'Taris, Central Plaza' }, instance = 'MastIdx:5' })
    instances(patch, { exactIds = { 'Taris, Central Plaza' }, instance = 'ObjIdx:8517' })
    instances(enhanced, { match = office, instance = 'SW_In_TableGround' })
    instances(patch, { match = office, instance = 'SW_In_TableGround' })
    instances(patch, { exactIds = { tower }, instance = 'SW_In_TableGround' })
    instances(patch, { exactIds = { tower }, instance = 'SW_In_TableGround' })
    instances(patch, { exactIds = { 'Taris, Upper City Cantina' }, instance = 'Sign' })
    instances(enhanced, { exactIds = { 'Taris, Upper City Cantina' }, instance = 'MastIdx:5' })
    instances(patch, { exactIds = { 'Nar Shaddaa, Lower City' }, instance = 'X:9336' })
    instances(enhanced, { exactIds = { 'Nar Shaddaa, Lower City' }, instance = 'MastIdx:5' })
    instances(patch, { exactIds = { 'Nar Shaddaa, Customs' }, instance = 'SW_SignCantina' })
    instances(enhanced, { exactIds = { 'Nar Shaddaa, Customs' }, instance = 'MastIdx:5' })
    instances(enhanced, { exactIds = { 'Starwind test cell' }, instance = 'MastIdx:5' })

    apply(work, { enhanced }, function(records)
      surgery.deleteFemaleBodyParts(records, 'swe_mandochest')
      return nil
    end)
  end

  apply(work, { v115 }, function(records)
    surgery.deleteScripts(records, 'DoNothing', 'Door', 'in_t_door_small')
    return nil
  end)
end

-- build_starwind.preprocess_definitive_sources, without the main-quest check.
function pipeline.preprocess(work: Work)
  apply(
    work,
    { 'Morrowind.esm', 'Tribunal.esm', 'Bloodmoon.esm', 'StarwindRemasteredV1.15.esm' },
    function(records) return (surgery.deleteIds(records, { 'Class' }, sources.DeadClasses)) end
  )

  commonPreprocess(work)

  local bings = 'bings race pack.esp'

  apply(work, { bings }, function(records)
    local orphans = {}

    for _, record in records do
      if record.type == 'Bodypart' and tes3.lower(record.race) == 'bng_mustafarian' then
        table.insert(orphans, tes3.string(record.id))
      end
    end

    local kept = records

    if #orphans > 0 then kept = surgery.deleteIds(kept, { 'Bodypart' }, orphans) end

    kept = surgery.deleteExteriorCells(kept)
    return (surgery.deleteIds(kept, { 'Cell' }, { 'nar shaddaa, h.t. parnell\'s oddities' }))
  end)

  apply(work, { 'naboo.esp' }, function(records)
    local kept = surgery.deleteIds(records, nil, {
      'Nab_HeaviestJunk',
      'passtheday',
      'nab_byebye',
      'dayispassed',
      'mothball',
      'NerevarAwakened ',
    })
    surgery.deleteScripts(kept, 'Script:Nab_ByeBye')
    surgery.deleteScripts(kept, 'Script:passtheday')
    surgery.deleteInventory(kept, 'ZE_Items', 'Nab_HeaviestJunk')
    return kept
  end)
end

-- `merge_to_master <plugin> <master>` in the work folder: the master's file is replaced by the
-- merge, and every other master the plugin names is read from the folder as it is now.
function pipeline.mtm(
  work: Work,
  plugin: string,
  master: string,
  onMerge: ((string, Records) -> ())?
)
  local masters: { [string]: Records } = {}

  for name, records in work do
    masters[string.lower(name)] = records
  end

  if onMerge then onMerge(master, work[master]) end

  work[master] =
    mergeToMaster.merge(work[plugin], work[master], { masterName = master, masters = masters })
end

pipeline.Canonical = 'Starwind-Definitive.omwaddon'

-- build_starwind.merge_definitive: the canonical merge, then the equipment enchantment policy.
-- `onMerge` sees each master before it's replaced, as merge_to_master's backups keep it.
function pipeline.merge(work: Work, onMerge: ((string, Records) -> ())?): Records
  pipeline.mtm(work, 'bings race pack.esp', 'Starwind Enhanced.esm', onMerge)

  local patchPlugins = {
    'Starwind Enhanced.esm',
    'StarwindPlanExp.esp',
    'alt_start1.5.esp',
    'Starwind Community Patch Project.esp',
    'naboo.esp',
  }

  for _, plugin in patchPlugins do
    pipeline.mtm(work, plugin, 'StarwindRemasteredPatch.esm', onMerge)
  end

  pipeline.mtm(work, 'StarwindRemasteredPatch.esm', 'StarwindRemasteredV1.15.esm', onMerge)
  work[pipeline.Canonical] = work['StarwindRemasteredV1.15.esm']
  work['StarwindRemasteredV1.15.esm'] = nil
  pipeline.mtm(work, 'PartyHats.esp', pipeline.Canonical, onMerge)
  surgery.setEnchantCapacity(work[pipeline.Canonical], 375)
  return work[pipeline.Canonical]
end

export type Decoupled = { final: Records, preAddVanilla: Records, log: { string } }

-- build_starwind.decouple: the canonical merge folded into Minimal, the reviewed edits to the
-- staged masters and the merged plugin, addVanillaRefs, and the tombstones stripped.
function pipeline.decouple(work: Work): Decoupled
  local starwind = 'Starwind.esp'
  pipeline.mtm(work, pipeline.Canonical, 'Minimal.esp')
  work[starwind] = work['Minimal.esp']
  work['Minimal.esp'] = nil

  apply(
    work,
    { 'Morrowind.esm', 'Tribunal.esm', 'Bloodmoon.esm' },
    function(records)
      return (surgery.deleteIds(records, { 'DialogueInfo' }, sources.DeadVanillaFactionInfos))
    end
  )

  for _, pair in sources.RegionSleepCreatures do
    apply(work, { starwind, 'Morrowind.esm', 'Bloodmoon.esm' }, function(records)
      surgery.clearSleepCreature(records, pair[1], pair[2])
      return nil
    end)
  end

  apply(work, { starwind }, function(records)
    local kept = surgery.deleteExteriorCells(records)
    kept = surgery.deleteType(kept, 'Landscape')
    return (surgery.deleteType(kept, 'LandscapeTexture'))
  end)

  local preAddVanilla = table.clone(work[starwind])
  local bases = { work['Bloodmoon.esm'], work['Tribunal.esm'], work['Morrowind.esm'] }
  local decoupled, log = addVanillaRefs.run(
    work[starwind],
    bases,
    { names = { 'Bloodmoon.esm', 'Tribunal.esm', 'Morrowind.esm' } }
  )

  -- Tombstones have served their purpose during import and are not part of the distributable.
  surgery.deleteDeletedInstances(decoupled)
  work[pipeline.Canonical] = decoupled
  work[starwind] = nil
  return { final = decoupled, preAddVanilla = preAddVanilla, log = log }
end

return pipeline
