--!strict
--!native
--[[
@dreamwind/starwind: the Starwind Merged Plugin Project's Definitive build, build_starwind.py's
pipeline in Luau, with no other program run.

  build(options) -> Manifest

`options.root` is the sw_merged folder (its `plugins` folder holds the JSON sources). The build
writes what build_starwind.py --strict writes, under `options.output` (default
`<root>/.swbuild/definitive`):

  out/Starwind-Definitive.omwaddon    the masterless monolith
  out/Star_Data.omwaddon              definitions
  out/Starwind.omwaddon               content, mastered on Star_Data
  reports/                            the main-quest, hygiene, closure, dialogue, late-actor,
                                      and split reports
  build-manifest.json

`options.keepWork` also keeps work/Starwind-Definitive-pre-addVanilla.omwaddon and
work/decoupleLog.txt. `options.strict` fails on dialogue order and link drift too. It raises
where the Python build exits non-zero, with the same message. `options.timings`, a table, gets
each stage's seconds.

The stages, the tools they replace, and the record semantics are in the modules: `pipeline`
(the build graph), `surgery` (tes3cmd), @dreamwind/tools/merge-to-master, add-vanilla-refs, and
tes3conv, `audit` (main-quest guard and closure), `dialogue`, `hygiene`, `provenance`, and
`split`.
]]

local audit = require '@self/audit'
local dialogue = require '@self/dialogue'
local hygiene = require '@self/hygiene'
local pipeline = require '@self/pipeline'
local provenance = require '@self/provenance'
local report = require '@self/report'
local sources = require '@self/sources'
local split = require '@self/split'
local surgery = require '@self/surgery'
local tes3 = require './lib/tes3'
local tes3conv = require '@dreamwind/tools/tes3conv'
local core = require '@dreamwind/tes3'

type Records = tes3.Records
type Json = report.Json

export type Options = {
  root: string,
  output: string?,
  strict: boolean?,
  keepWork: boolean?,
  timings: { [string]: number }?,
}

local function ensureDir(path: string)
  if not jess.fs.isDir(path) then jess.fs.createDir(path) end
end

-- The Definitive sources other than Bethesda's and Minimal, as the dialogue audit's provenance.
local function provenanceKeys(): { string }
  local keys = {}

  for _, source in sources.Included do
    if not table.find({ 'Morrowind', 'Tribunal', 'Bloodmoon', 'Minimal' }, source.key) then
      table.insert(keys, source.key)
    end
  end

  return keys
end

local function sourceByKey(key: string): sources.Source
  for _, source in sources.Included do
    if source.key == key then return source end
  end

  error(`no source {key}`)
end

local function build(options: Options): { [string]: Json }
  local root = options.root
  local plugins = jess.fs.join(root, 'plugins')
  local output = options.output or jess.fs.join(root, '.swbuild', 'definitive')
  local out, reports, work =
    jess.fs.join(output, 'out'), jess.fs.join(output, 'reports'), jess.fs.join(output, 'work')
  ensureDir(output)
  ensureDir(out)
  ensureDir(reports)

  local timings = options.timings or {}
  local clock = os.clock()

  local function stage(name: string)
    local now = os.clock()
    timings[name] = (timings[name] or 0) + now - clock
    clock = now
  end

  local paths = {
    final = jess.fs.join(out, 'Starwind-Definitive.omwaddon'),
    data = jess.fs.join(out, 'Star_Data.omwaddon'),
    content = jess.fs.join(out, 'Starwind.omwaddon'),
    hygiene = jess.fs.join(reports, 'Starwind-definitive-dialogue-source-hygiene.json'),
    mainQuest = jess.fs.join(reports, 'main-quest-preservation.json'),
    closure = jess.fs.join(reports, 'Starwind-Definitive-closure-audit.json'),
    dialogue = jess.fs.join(reports, 'Starwind-Definitive-dialogue-chain-audit.json'),
    lateActors = jess.fs.join(reports, 'late-actor-provenance.json'),
    lateActorsMarkdown = jess.fs.join(reports, 'late-actor-provenance.md'),
    lateActorsCleanup = jess.fs.join(reports, 'late-actor-provenance-cleanup.sh'),
    split = jess.fs.join(reports, 'starwind-split-report.json'),
    log = jess.fs.join(work, 'decoupleLog.txt'),
    preAddVanilla = jess.fs.join(work, 'Starwind-Definitive-pre-addVanilla.omwaddon'),
    manifest = jess.fs.join(output, 'build-manifest.json'),
  }

  local staged, compiled = pipeline.compile(plugins)
  stage 'compile'

  local function raw(key: string): hygiene.Source
    local source = sourceByKey(key)
    return {
      path = compiled.files[key].path,
      records = compiled.raw[source.binary],
      binary = source.binary,
      label = key,
    }
  end

  local hygieneLabels = {
    Minimal = 'Minimal',
    V115 = 'V1.15',
    Patch = 'RemasteredPatch',
    Bings = 'Bings',
    Enhanced = 'Enhanced',
    PlanExp = 'PlanExp',
    AltStart = 'AltStart',
    CPP = 'CPP',
    Naboo = 'Naboo',
    PartyHats = 'PartyHats',
  }

  local function labelled(key: string): hygiene.Source
    local source = raw(key)
    source.label = hygieneLabels[key] or key
    return source
  end

  local vanilla = { raw 'Morrowind', raw 'Tribunal', raw 'Bloodmoon' }
  local corpus = {}

  local corpusKeys = {
    'Minimal',
    'V115',
    'Patch',
    'Bings',
    'Enhanced',
    'PlanExp',
    'AltStart',
    'CPP',
    'Naboo',
    'PartyHats',
  }

  for _, key in corpusKeys do
    table.insert(corpus, labelled(key))
  end

  hygiene.audit(vanilla, corpus, { labelled 'V115', labelled 'Patch' }, paths.hygiene)
  stage 'hygiene'

  local checks: { Json } = {}

  local function active(): { audit.Staged }
    local list = {}

    for _, source in sources.Included do
      local records = staged[source.binary]

      if records then
        table.insert(list, { name = jess.fs.join(work, source.binary), records = records })
      end
    end

    return list
  end

  audit.mainQuest('before-definitive-preprocess', active(), checks, paths.mainQuest)
  pipeline.preprocess(staged)
  audit.mainQuest('after-definitive-preprocess', active(), checks, paths.mainQuest)
  stage 'preprocess'

  local canonical = pipeline.merge(staged)
  audit.mainQuest(
    'after-canonical-merge',
    { { name = jess.fs.join(work, pipeline.Canonical), records = canonical } },
    checks,
    paths.mainQuest
  )
  stage 'merge'

  local decoupled = pipeline.decouple(staged)
  stage 'decouple'

  local final = tes3conv.plugin(decoupled.final)
  jess.fs.replace(paths.final, final:save())

  if options.keepWork then
    ensureDir(work)
    jess.fs.replace(paths.preAddVanilla, tes3conv.plugin(decoupled.preAddVanilla):save())
    jess.fs.write(paths.log, table.concat(decoupled.log, '\n') .. '\n', { backup = false })
  end

  stage 'write'

  -- Every check from here reads the monolith as written.
  local finalBytes = assert(jess.fs.readBuffer(paths.final), `failed to read '{paths.final}'`)
  local written = split.readBack(core.open(finalBytes))
  local finalRecords: Records = { written.header }
  table.move(written.records, 1, #written.records, 2, finalRecords)
  stage 'read back'

  audit.mainQuest(
    'after-master-decoupling',
    { { name = paths.final, records = finalRecords } },
    checks,
    paths.mainQuest
  )

  local closure = audit.closure(finalRecords, paths.closure, function()
    local all = {}

    for _, source in sources.Included do
      table.insert(all, compiled.raw[source.binary])
    end

    return all
  end)

  if closure.hard > 0 then
    error(`unresolved hard dependencies: {closure.hard} (see {paths.closure})`)
  end

  stage 'closure'

  local keys = provenanceKeys()
  local provenanceNames = {}

  for _, key in keys do
    table.insert(provenanceNames, compiled.files[key].path)
  end

  local dialogueReport, projection, liveness = dialogue.audit {
    final = { name = paths.final, records = finalRecords },
    starwind = { name = paths.preAddVanilla, records = decoupled.preAddVanilla },
    bases = {
      { name = jess.fs.join(work, 'Morrowind.esm'), records = staged['Morrowind.esm'] },
      { name = jess.fs.join(work, 'Tribunal.esm'), records = staged['Tribunal.esm'] },
      { name = jess.fs.join(work, 'Bloodmoon.esm'), records = staged['Bloodmoon.esm'] },
    },
    log = decoupled.log,
    logPath = paths.log,
    provenance = function()
      local list = {}

      for _, key in keys do
        table.insert(
          list,
          { name = compiled.files[key].path, records = compiled.raw[sourceByKey(key).binary] }
        )
      end

      return list
    end,
    provenanceNames = provenanceNames,
    reportPath = paths.dialogue,
  }

  local summary = dialogueReport.summary :: { [string]: Json }
  local hard = {}

  local hardKeys = {
    'missing_dialogues',
    'extra_dialogues',
    'extra_dead_infos',
    'missing_live_infos',
    'engine_order_mismatches',
    'potentially_competing_inversions',
    'dialogue_content_mismatches',
    'info_content_mismatches',
    'standalone_orphan_infos',
  }

  for _, key in hardKeys do
    if summary[key] ~= 0 then table.insert(hard, `{key}={summary[key]}`) end
  end

  if #hard > 0 then error(`definitive dialogue validation failed: {table.concat(hard, ', ')}`) end

  stage 'dialogue audit'

  -- The late-actor report replays the dialogue audit's projection, from the same inputs.
  provenance.report({
    log = decoupled.log,
    logPath = paths.log,
    final = finalRecords,
    finalPath = paths.final,
    projection = projection,
    audit = liveness,
    vanillaSources = function() return vanilla end,
    starwindSources = function() return { labelled 'V115', labelled 'Patch' } end,
  }, {
    report = paths.lateActors,
    markdown = paths.lateActorsMarkdown,
    cleanup = paths.lateActorsCleanup,
  })
  stage 'late actors'

  local splitResult = split.split(decoupled.final, {
    source = paths.final,
    data = paths.data,
    content = paths.content,
    report = paths.split,
  }, written)
  stage 'split'

  if options.strict then
    local structural = {}

    local structuralKeys = {
      'engine_order_mismatches',
      'standalone_physical_order_mismatches',
      'serialized_link_mismatches',
    }

    for _, key in structuralKeys do
      if summary[key] ~= 0 then table.insert(structural, `{key}={summary[key]}`) end
    end

    if #structural > 0 then
      error(`strict dialogue validation failed: {table.concat(structural, ', ')}`)
    end
  end

  local included = {}

  for _, source in sources.Included do
    table.insert(included, source.key)
    table.insert(
      included,
      report.object {
        'path',
        compiled.files[source.key].path,
        'sha256',
        compiled.files[source.key].sha256,
      }
    )
  end

  local splitReport = splitResult.report
  local splitCounts = report.object {}

  local countKeys = {
    'source_records',
    'data_records',
    'content_records',
    'reconstruction_exact',
    'effective_record_mismatch_count',
    'data_to_content_dependency_count',
    'new_unresolved_dependency_count',
  }

  for _, key in countKeys do
    report.set(splitCounts, key, splitReport[key])
  end

  local manifest = report.object {
    'edition',
    'definitive',
    'included_sources',
    report.object(included),
    'excluded_sources',
    report.array(table.clone(sources.Excluded) :: { Json }),
    'output',
    paths.final,
    'source_hygiene_report',
    paths.hygiene,
    'closure_report',
    paths.closure,
    'dialogue_report',
    paths.dialogue,
    'late_actor_provenance_report',
    paths.lateActors,
    'split_report',
    paths.split,
    'main_quest_guard_report',
    paths.mainQuest,
    'closure_counts',
    closure.counts,
    'split_counts',
    splitCounts,
  }

  report.write(paths.manifest, manifest)
  stage 'manifest'
  return manifest
end

return {
  build = build,
  audit = audit,
  dialogue = dialogue,
  hygiene = hygiene,
  pipeline = pipeline,
  provenance = provenance,
  report = report,
  sources = sources,
  split = split,
  surgery = surgery,
}
