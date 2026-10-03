--!strict
--!native
-- The Starwind build against the Python pipeline, on the real sources:
--
--   jess run --package jpk/dreamwind tests/starwind/equivalence.luau <sw_merged> <output> [<python>]
--
-- builds into <output>, then checks the invariants sw_merged/index.md documents, the release
-- pair checked in beside index.md, and, given the .swbuild/definitive folder of a
-- `build_starwind.py --strict` run of the same sources, every output and report of that run.
-- Raises when anything fails. libs/cli/tests/starwind.rs runs it when JESS_STARWIND is set.
local compare = require './compare'
local starwind = require '@dreamwind/starwind'
local tes3conv = require '@dreamwind/tools/tes3conv'
local test = require '@jess/test'
local expect = test.expect
local suite = test.new()

local root: string, output: string, python: string? = ...

if not root or not output then
  error 'usage: equivalence.luau <sw_merged> <output> [<python .swbuild/definitive>]'
end

local timings: { [string]: number } = {}
local started = os.clock()
local manifest = starwind.build { root = root, output = output, strict = true, timings = timings }
local elapsed = os.clock() - started

local function json(path: string): { [string]: any }
  local text = jess.fs.read(path)

  if not text then error(`'{path}' doesn't exist`) end

  return tes3conv.json(text, true) :: { [string]: any }
end

local function open(path: string): Plugin return jess.plugin.open(path, { openmw = false }) end

local mine = {
  out = jess.fs.join(output, 'out'),
  reports = jess.fs.join(output, 'reports'),
}

local summaries: { string } = {}

local function plugins(name: string, left: string, right: string): compare.Comparison
  local result = compare.plugins(open(left), open(right))
  table.insert(summaries, compare.summary(name, result))
  return result
end

suite.describe('the invariants index.md documents', function()
  local closure = json(jess.fs.join(mine.reports, 'Starwind-Definitive-closure-audit.json'))
  local dialogue =
    json(jess.fs.join(mine.reports, 'Starwind-Definitive-dialogue-chain-audit.json')).summary
  local split = json(jess.fs.join(mine.reports, 'starwind-split-report.json'))

  suite.it('30,548 records, no masters, nothing unresolved', function()
    expect(closure.counts.records_including_header - 1).toBe(30548)
    expect(closure.counts.masters).toBe(0)
    expect(closure.counts.hard_unresolved_occurrences).toBe(0)
  end)

  suite.it('591 of 591 topics, dialogue exact', function()
    expect(dialogue.expected_live_dialogues).toBe(591)
    expect(dialogue.standalone_dialogues).toBe(591)

    local zeroKeys = {
      'missing_dialogues',
      'extra_dialogues',
      'missing_live_infos',
      'extra_dead_infos',
      'engine_order_mismatches',
      'standalone_physical_order_mismatches',
      'serialized_link_mismatches',
      'dialogue_content_mismatches',
      'info_content_mismatches',
      'standalone_orphan_infos',
    }

    for _, key in zeroKeys do
      expect(`{key}={dialogue[key]}`).toBe(`{key}=0`)
    end
  end)

  suite.it('13,330 data and 17,218 content records, rebuilding the monolith exactly', function()
    expect(split.data_records).toBe(13330)
    expect(split.content_records).toBe(17218)
    expect(split.reconstruction_exact).toBe(true)
    expect(split.data_to_content_dependency_count).toBe(0)
    expect(split.effective_record_mismatch_count).toBe(0)
    expect(split.new_unresolved_dependency_count).toBe(0)
  end)
end)

suite.describe('the release pair checked in beside index.md', function()
  suite.it('Star_Data, byte for byte', function()
    local result = plugins(
      'Star_Data (release)',
      jess.fs.join(mine.out, 'Star_Data.omwaddon'),
      jess.fs.join(root, 'Star_Data.omwaddon')
    )
    expect(result.identicalBytes).toBe(true)
  end)

  suite.it('Starwind, record for record', function()
    local result = plugins(
      'Starwind (release)',
      jess.fs.join(mine.out, 'Starwind.omwaddon'),
      jess.fs.join(root, 'Starwind.omwaddon')
    )
    expect(compare.equivalent(result)).toBe(true)
  end)
end)

if python then
  suite.describe('a Python build\'s outputs and reports', function()
    local outputs = jess.fs.join(python, 'out')
    local reports = jess.fs.join(python, 'reports')

    for _, name in { 'Starwind-Definitive.omwaddon', 'Star_Data.omwaddon', 'Starwind.omwaddon' } do
      suite.it(name, function()
        local result =
          plugins(`{name} (Python)`, jess.fs.join(mine.out, name), jess.fs.join(outputs, name))
        expect(compare.equivalent(result)).toBe(true)
      end)
    end

    local Paths = {
      'paths',
      'source',
      'data_output',
      'content_output',
      'source_json',
      'vanilla_load_order',
      'log',
      'standalone',
    }

    local DialoguePaths = {
      'reconstruction_stack',
      'starwind_ownership_source',
      'actor_population_source',
      'materialization_log',
      'provenance_sources',
    }

    local function reportCase(
      name: string,
      theirs: string,
      extra: { string }?,
      unordered: { string }?
    )
      suite.it(name, function()
        local ignore = table.clone(Paths)

        for _, key in extra or {} do
          table.insert(ignore, key)
        end

        local differences = compare.json(
          json(jess.fs.join(mine.reports, name)),
          json(theirs),
          { ignore = ignore, unordered = unordered }
        )
        expect(differences).toEqual {}
      end)
    end

    reportCase(
      'main-quest-preservation.json',
      jess.fs.join(reports, 'main-quest-preservation.json')
    )
    reportCase(
      'Starwind-Definitive-closure-audit.json',
      jess.fs.join(python, '..', 'reports', 'Starwind-Definitive-closure-audit.json')
    )
    reportCase(
      'Starwind-Definitive-dialogue-chain-audit.json',
      jess.fs.join(reports, 'Starwind-Definitive-dialogue-chain-audit.json'),
      DialoguePaths
    )
    reportCase(
      'Starwind-definitive-dialogue-source-hygiene.json',
      jess.fs.join(reports, 'Starwind-definitive-dialogue-source-hygiene.json')
    )
    reportCase(
      'starwind-split-report.json',
      jess.fs.join(reports, 'starwind-split-report.json'),
      nil,
      {
        'content_to_data_dependencies',
        'data_to_content_dependencies',
        'unresolved_dependencies',
        'new_unresolved_dependencies',
      }
    )
    -- The Python report replays dialogue against a legacy Solo build; see provenance.luau.
    reportCase(
      'late-actor-provenance.json',
      jess.fs.join(reports, 'late-actor-provenance.json'),
      { 'dialogue_liveness_audit' }
    )
  end)
end

local result = suite.run()
local names = {}

for name in timings do
  table.insert(names, name)
end

table.sort(names, function(left, right) return timings[left] > timings[right] end)

print(string.format('build: %.2f s', elapsed))

for _, name in names do
  print(string.format('  %-15s %6.2f s', name, timings[name]))
end

print(starwind.report.encode(manifest.split_counts))

for _, line in summaries do
  print(line)
end

for _, case in result.tests do
  print(`{if case.passed then 'ok  ' else 'FAIL'} {case.name}`)

  if not case.passed then print(case.error) end
end

print(`{result.passed} passed, {result.failed} failed`)

if result.failed > 0 then error(`{result.failed} Starwind equivalence checks failed`) end
