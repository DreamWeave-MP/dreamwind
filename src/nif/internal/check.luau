--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
OpenMW compatibility checks for NIF files, the successor to OpenMW's `niftest`: a port of
jess-nif's `check`. A NIF is read the way OpenMW would read it, and the report says what OpenMW
would do with it: files it refuses to load, content it drops or draws differently than the author
intended, collision surprises, and performance smells. Every version gets header-level checks,
then its records are read by the multi-version reader and checked against the rules of OpenMW's
`nifosg` and `nifbullet` loaders (`check/rules.luau`).

Texture paths come back as the file spells them; resolving them against a VFS, the way
`correctTexturePath` does, is the caller's.
]]

local Classes = require './gamebryo/classes'
local Header = require './header'
local Reader = require './gamebryo/reader'
local Rules = require './check/rules'
local Types = require './check/types'

export type Severity = Types.Severity
export type Finding = Types.Finding
export type Stats = Types.Stats
export type Collision = Types.Collision
export type Report = Types.Report

local Ranks = Types.ranks

--- The finding code for why the reader refused a file.
local function readErrorCode(message: string): string
  local function startsWith(prefix: string): boolean
    return string.sub(message, 1, #prefix) == prefix
  end

  local function endsWith(suffix: string): boolean return string.sub(message, -#suffix) == suffix end

  if startsWith 'Failed to cast record pointer' then return 'wrong_link_type' end

  if string.find(message, ' links to record ', 1, true) then return 'link_out_of_range' end

  if endsWith 'missing root or data' then return 'skin_missing_root_or_data' end

  if startsWith 'Mismatch in ' and endsWith ' bone count' then return 'skin_bone_count_mismatch' end

  if startsWith 'Oops: Missing bone!' then return 'skin_missing_bone' end

  if startsWith 'Unknown record type' then return 'unknown_record_type' end

  if startsWith 'Record type is blank' then return 'blank_record_type' end

  return 'unreadable_record'
end

local function push(
  report: Report,
  severity: Severity,
  code: string,
  message: string,
  record: number?
)
  table.insert(
    report.findings,
    { severity = severity, code = code, message = message, record = record }
  )
end

--- What can be told from the header of files with a record type table.
local function checkHeaderRecords(b: buffer, report: Report, header: Header.Header)
  -- Every record type is looked up in OpenMW's factory before anything is read
  -- (niffile.cpp `Reader::parse`); the first unknown one fails the file.
  for index = 0, #header.recordTypeIndices - 1 do
    local name = Header.recordType(header, index)
    if not name then
      push(
        report,
        'wont_load',
        'invalid_record_type_index',
        `record {index} has a type index past the type table`,
        index
      )
      break
    end

    if not Classes.factory[name] then
      push(report, 'wont_load', 'unknown_record_type', `Unknown record type {name}`, index)
      break
    end
  end

  if #header.recordSizes == 0 then return end

  local roots = Header.roots(header, b)
  if not roots then
    -- OpenMW reads records by type rather than by size, so it may still load this.
    push(
      report,
      'info',
      'record_sizes_mismatch',
      'the header\'s record sizes don\'t add up to the file; OpenMW doesn\'t use them, but the roots can\'t be checked'
    )
    return
  end

  -- Out-of-range roots are warned about and skipped (niffile.cpp `Reader::parse`).
  for position, root in roots do
    if root < -1 or root >= #header.recordTypeIndices then
      push(
        report,
        'broken',
        'root_out_of_range',
        `Root {position - 1} does not point to a record: index {root}`
      )
    end
  end
end

local function wontLoad(report: Report): boolean
  for _, finding in report.findings do
    if finding.severity == 'wont_load' then return true end
  end

  return false
end

--- Checks a NIF, named by its path: only the file name is used, `.kf` files being checked as
--- animations.
local function check(name: string, data: buffer | string): Report
  local b = if type(data) == 'string' then buffer.fromstring(data) else data
  local report: Report =
    { header = nil, deep = false, findings = {}, textures = {}, stats = nil, collision = nil }
  -- The header reader throws OpenMW's message for a header it refuses.
  local ok, header = pcall(Header.parse, b)
  if not ok then
    push(report, 'wont_load', 'invalid_header', tostring(header))
    return report
  end

  report.header = header
  checkHeaderRecords(b, report, header)
  if not wontLoad(report) then
    -- The reader throws `{ message, record }` for a file OpenMW refuses.
    local read, file = pcall(Reader.open, b)
    if read then
      Rules.check(name, file, report)
    else
      local problem = file :: any
      local message = if type(problem) == 'table' then problem.message else tostring(problem)
      local record: number? = if type(problem) == 'table' then problem.record else nil
      local recordName = if record then Header.recordType(header, record) else nil
      local prefix = if recordName then `{recordName}: ` else ''
      push(report, 'wont_load', readErrorCode(message), prefix .. message, record)
    end
  end

  -- Most severe first, then by record, a finding about no record first; otherwise in the order
  -- found, as a stable sort keeps them.
  local order: { [Finding]: number } = {}
  for position, finding in report.findings do
    order[finding] = position
  end

  table.sort(report.findings, function(left: Finding, right: Finding): boolean
    local leftRank, rightRank = Ranks[left.severity], Ranks[right.severity]
    if leftRank ~= rightRank then return leftRank < rightRank end

    local leftRecord, rightRecord = left.record or -1, right.record or -1
    if leftRecord ~= rightRecord then return leftRecord < rightRecord end

    return order[left] < order[right]
  end)

  return report
end

return table.freeze { check = check }
