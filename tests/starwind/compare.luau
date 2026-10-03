--!strict
--!native
-- Plugin comparison for the Starwind equivalence checks: record for record, byte for byte, with
-- two allowances, both for things the Python build itself doesn't do the same way twice.
--
--   * renumbered: merge_to_master numbers a merged plugin's own references in hash-map order,
--     so two runs give the same references different FRMR indices. A CELL that matches with its
--     own references' indices left out counts as renumbered.
--   * NAM0 lost: deleting tombstoned references with tes3cmd also deletes the cell's NAM0 when it
--     sits after one of them, and then every reference reads as persistent. Which reference it
--     sits after follows the numbering. A CELL that matches with the indices and the references'
--     `temporary` left out counts as such.

export type Difference = { key: string, reason: string }

export type Comparison = {
  leftRecords: number,
  rightRecords: number,
  identicalBytes: boolean,
  sameOrder: boolean,
  equalRecords: number,
  renumberedCells: number,
  persistenceCells: { string },
  differences: { Difference },
  onlyLeft: { string },
  onlyRight: { string },
}

type Entry = { key: string, bytes: string, record: Record }

local compare = {}

local function keyOf(record: Record, seen: { [string]: number }): string
  local meta = jess.meta(record)
  local id = meta.id

  if not id then
    local value = record:decode() :: { [string]: unknown }?
    id = value and (value.effectId or value.skillId) :: string? or ''
  end

  local key = `{meta.tag} {string.lower(id :: string)}`
  local count = (seen[key] or 0) + 1
  seen[key] = count
  return if count == 1 then key else `{key} #{count}`
end

local function entries(plugin: Plugin): ({ Entry }, { [string]: Entry })
  local list: { Entry } = {}
  local byKey: { [string]: Entry } = {}
  local seen: { [string]: number } = {}

  for record in plugin:records() do
    if jess.meta(record).tag == 'TES3' then continue end

    local entry =
      { key = keyOf(record, seen), bytes = buffer.tostring(record:bytes()), record = record }
    table.insert(list, entry)
    byKey[entry.key] = entry
  end

  return list, byKey
end

-- A value as text with its keys sorted, so equal tables give equal text.
local function canonical(value: unknown): string
  if type(value) ~= 'table' then return tostring(value) end

  local keys = {}

  for key in value :: { [unknown]: unknown } do
    table.insert(keys, key)
  end

  table.sort(keys, function(left, right) return tostring(left) < tostring(right) end)

  local parts = {}

  for _, key in keys do
    table.insert(parts, `{tostring(key)}={canonical((value :: { [unknown]: unknown })[key])}`)
  end

  return '{' .. table.concat(parts, ',') .. '}'
end

-- A cell with its own references' indices left out, references sorted, and with
-- `withoutPersistence` their `temporary` too.
local function canonicalCell(record: Record, withoutPersistence: boolean): string
  local cell = record:decode() :: { [string]: unknown }
  local references = (cell.references or {}) :: { { [string]: unknown } }
  local texts = {}

  for _, reference in references do
    local copy = table.clone(reference)

    if copy.mastIndex == 0 then copy.refrIndex = nil end

    if withoutPersistence then copy.temporary = nil end

    table.insert(texts, canonical(copy))
  end

  table.sort(texts)
  cell.references = nil
  return canonical(cell) .. table.concat(texts, '\n')
end

function compare.plugins(left: Plugin, right: Plugin): Comparison
  local leftList, leftByKey = entries(left)
  local rightList, rightByKey = entries(right)
  local result: Comparison = {
    leftRecords = #leftList,
    rightRecords = #rightList,
    identicalBytes = buffer.tostring(left:bytes()) == buffer.tostring(right:bytes()),
    sameOrder = #leftList == #rightList,
    equalRecords = 0,
    renumberedCells = 0,
    persistenceCells = {},
    differences = {},
    onlyLeft = {},
    onlyRight = {},
  }

  for index, entry in leftList do
    local other = rightByKey[entry.key]

    if result.sameOrder and rightList[index].key ~= entry.key then result.sameOrder = false end

    if not other then
      table.insert(result.onlyLeft, entry.key)
    elseif other.bytes == entry.bytes then
      result.equalRecords += 1
    elseif jess.meta(entry.record).tag ~= 'CELL' then
      table.insert(result.differences, { key = entry.key, reason = 'bytes' })
    elseif canonicalCell(entry.record, false) == canonicalCell(other.record, false) then
      result.renumberedCells += 1
    elseif canonicalCell(entry.record, true) == canonicalCell(other.record, true) then
      table.insert(result.persistenceCells, entry.key)
    else
      table.insert(result.differences, { key = entry.key, reason = 'bytes' })
    end
  end

  for _, entry in rightList do
    if not leftByKey[entry.key] then table.insert(result.onlyRight, entry.key) end
  end

  return result
end

-- Whether two plugins hold the same records in the same order, allowing renumbered references
-- and lost NAM0s.
function compare.equivalent(result: Comparison): boolean
  return result.sameOrder
    and #result.differences == 0
    and #result.onlyLeft == 0
    and #result.onlyRight == 0
end

export type JsonOptions = { ignore: { string }?, unordered: { string }? }

-- Where two JSON documents differ, at most `limit` of them: numbers at f32 precision (the port
-- reads them back from plugins), keys named in `ignore` skipped (output paths), and lists named
-- in `unordered` compared as multisets (lists in reference order, which renumbering reorders).
function compare.json(
  left: unknown,
  right: unknown,
  options: JsonOptions?,
  limit: number?
): { string }
  local ignored, unordered = {}, {}

  for _, key in options and options.ignore or {} do
    ignored[key] = true
  end

  for _, key in options and options.unordered or {} do
    unordered[key] = true
  end

  local found: { string } = {}
  local most = limit or 20

  local function walk(a: unknown, b: unknown, path: string, key: string?)
    if #found >= most or (key and ignored[key]) then return end

    if type(a) == 'number' and type(b) == 'number' then
      if a ~= b and string.pack('<f', a) ~= string.pack('<f', b) then
        table.insert(found, `{path}: {a} vs {b}`)
      end

      return
    end

    if type(a) ~= type(b) then
      table.insert(found, `{path}: {tostring(a)} vs {tostring(b)}`)
      return
    end

    if type(a) ~= 'table' then
      if a ~= b then table.insert(found, `{path}: {tostring(a)} vs {tostring(b)}`) end

      return
    end

    local x, y = a :: { [unknown]: unknown }, b :: { [unknown]: unknown }

    if #x > 0 or #y > 0 then
      if #x ~= #y then
        table.insert(found, `{path}: {#x} items vs {#y}`)
        return
      end

      if key and unordered[key] then
        local counts: { [string]: number } = {}

        for _, item in x do
          local text = canonical(item)
          counts[text] = (counts[text] or 0) + 1
        end

        for _, item in y do
          local text = canonical(item)
          counts[text] = (counts[text] or 0) - 1
        end

        for text, count in counts do
          if count ~= 0 then
            table.insert(found, `{path}: {count} more of {string.sub(text, 1, 120)}`)
            return
          end
        end

        return
      end

      for index = 1, #x do
        walk(x[index], y[index], `{path}[{index}]`, key)
      end

      return
    end

    for name, item in x do
      if y[name] == nil and item ~= jess.null then
        table.insert(found, `{path}.{tostring(name)}: only left`)
      else
        walk(item, y[name], `{path}.{tostring(name)}`, tostring(name))
      end
    end

    for name, item in y do
      if x[name] == nil and item ~= jess.null then
        table.insert(found, `{path}.{tostring(name)}: only right`)
      end
    end
  end

  walk(left, right, '', nil)
  return found
end

function compare.summary(name: string, result: Comparison): string
  local lines = {
    string.format(
      '%-28s %d/%d records: %d byte-equal, %d renumbered cells, %d NAM0-lost cells, %d different, %d/%d only one side; order %s; file %s',
      name,
      result.leftRecords,
      result.rightRecords,
      result.equalRecords,
      result.renumberedCells,
      #result.persistenceCells,
      #result.differences,
      #result.onlyLeft,
      #result.onlyRight,
      if result.sameOrder then 'same' else 'differs',
      if result.identicalBytes then 'byte-identical' else 'not byte-identical'
    ),
  }

  for index = 1, math.min(6, #result.differences) do
    table.insert(lines, `  differs: {result.differences[index].key}`)
  end

  for index = 1, math.min(6, #result.onlyLeft) do
    table.insert(lines, `  only left: {result.onlyLeft[index]}`)
  end

  for index = 1, math.min(6, #result.onlyRight) do
    table.insert(lines, `  only right: {result.onlyRight[index]}`)
  end

  return table.concat(lines, '\n')
end

return compare
