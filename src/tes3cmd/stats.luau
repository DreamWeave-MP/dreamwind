--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Record and subrecord counts across plugins (jess-plugin's `stats`, tes3cmd's `stats`).
]]

local tes3 = require '@dreamwind/tes3'

export type Stats = {
  --- Plugins counted.
  plugins: number,
  records: number,
  --- Records by tag.
  recordTypes: { [string]: number },
  --- Subrecords by `RECORD.SUBRECORD`.
  subrecordTypes: { [string]: number },
  --- Records by `RECORD.SUBRECORD`, for subrecords repeated within one record.
  listSubrecords: { [string]: number },
}

local function new(): Stats
  return { plugins = 0, records = 0, recordTypes = {}, subrecordTypes = {}, listSubrecords = {} }
end

--- Counts `plugin`'s records and subrecords into `stats`. Counting is by tag number, with one
--- scratch table reused for every record; tag names are made once per pair at the end.
local function add(stats: Stats, plugin: tes3.Plugin)
  stats.plugins += 1
  local count = plugin:count()
  stats.records += count
  local records: { [number]: number } = {}
  local subrecords: { [number]: { [number]: number } } = {}
  local lists: { [number]: { [number]: number } } = {}
  local perRecord: { [number]: number } = {}
  for i = 0, count - 1 do
    local record = plugin:code(i)
    records[record] = (records[record] or 0) + 1
    local totals = subrecords[record]
    if not totals then
      totals = {}
      subrecords[record] = totals
    end

    local source, start, finish = plugin:span(i)
    local p = start + 16
    while p < finish do
      local code = buffer.readu32(source, p)
      perRecord[code] = (perRecord[code] or 0) + 1
      p += 8 + buffer.readu32(source, p + 4)
    end

    for code, n in perRecord do
      totals[code] = (totals[code] or 0) + n
      if n > 1 then
        local listed = lists[record]
        if not listed then
          listed = {}
          lists[record] = listed
        end

        listed[code] = (listed[code] or 0) + 1
      end
    end

    table.clear(perRecord)
  end

  for record, n in records do
    local name = tes3.tags.display(record)
    stats.recordTypes[name] = (stats.recordTypes[name] or 0) + n
  end

  for into, from in { [stats.subrecordTypes] = subrecords, [stats.listSubrecords] = lists } do
    for record, counts in from do
      local prefix = tes3.tags.display(record) .. '.'
      for code, n in counts do
        local key = prefix .. tes3.tags.display(code)
        into[key] = (into[key] or 0) + n
      end
    end
  end
end

return table.freeze { add = add, new = new }
