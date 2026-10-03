--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
tes3cmd in Luau: what `jess plugin` does to plugins, over `@dreamwind/tes3`. Lint and clean,
validate, header edits and master sync, selectors and the delete, modify, and extract they drive,
readable dumps and byte layouts, stats, comparisons (bytes, common records, diffs, overrides,
overlapping topics), and `.esp`/`.esm` conversion.

Plugins are `@dreamwind/tes3` plugins: every edit here changes one in memory, and `files` writes
it back. Checks that read master files find them through a master source (`masters`).
]]

local Compare = require '@self/compare'
local Display = require '@self/display'
local Edit = require '@self/edit'
local Files = require '@self/files'
local Lint = require '@self/lint'
local Masters = require '@self/masters'
local Numbers = require '@self/numbers'
local Select = require '@self/select'
local Stats = require '@self/stats'

export type Severity = Lint.Severity
export type Finding = Lint.Finding
export type CheckSet = Lint.CheckSet
export type CleanChecks = Lint.CleanChecks
export type CleanReport = Lint.CleanReport
export type Validation = Lint.Validation
export type HeaderUpdate = Lint.HeaderUpdate
export type MasterSizeChange = Lint.MasterSizeChange
export type MasterSource = Masters.Source
export type SelectorSpec = Select.Spec
export type Selector = Select.Selector
export type Selection = Select.Selection
export type Deleted = Edit.Deleted
export type Replacement = Edit.Replacement
export type ModifyReport = Edit.ModifyReport
export type RecordLayout = Display.RecordLayout
export type SubrecordLayout = Display.SubrecordLayout
export type Stats = Stats.Stats
export type Key = Compare.Key
export type ByteComparison = Compare.ByteComparison
export type DiffReport = Compare.DiffReport
export type FieldChange = Compare.FieldChange
export type ChangedRecord = Compare.ChangedRecord
export type TopicOverlap = Compare.TopicOverlap
export type Override = Compare.Override
export type Written = Files.Written
export type LintParts = Lint.Parts
export type ConvertOptions = Files.ConvertOptions
export type Converted = Files.Converted

return table.freeze {
  --- Every lint check: its label, severity, and whether it reads masters.
  checks = Lint.Checks,
  --- The check set a preset (`all`, `recommended`) names.
  preset = Lint.preset,
  --- The check set the names give (any spelling), or the recommended one for none.
  checkSet = Lint.checks,
  --- A check's label for any of its spellings.
  parseCheck = Lint.parseCheck,
  lint = Lint.lint,
  --- The per-record checks' findings for a slice of the records, which `lint` joins when given
  --- every slice's: what a worker lints of a plugin it reads itself.
  lintSlice = Lint.lintSlice,
  clean = Lint.clean,
  validate = Lint.validate,
  hasVersion = Lint.hasVersion,
  updateHeader = Lint.updateHeader,
  syncMasters = Lint.syncMasters,

  masters = Masters,

  --- A selector from a spec.
  selector = Select.new,
  select = Select,

  delete = Edit.deleteMatching,
  replace = Edit.replaceMatching,
  extract = Edit.extractMatching,
  parseReplacement = Edit.parseReplacement,

  dump = Display.dump,
  layout = Display.layout,

  stats = Stats,

  compare = Compare,

  files = Files,

  floatText = Numbers.floatText,
}
