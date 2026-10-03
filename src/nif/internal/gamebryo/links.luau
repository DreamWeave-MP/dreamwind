--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
OpenMW's post-load link resolution (`RecordPtrT::post`): a link must point to a record, and the
record must be of the class the link names or derive from it.
]]

local Classes = require './classes'
local G = require './stream'

local Parents = Classes.parents

--- Each class's ancestors, itself included, built the first time it is asked about.
local Is: { [string]: { [string]: boolean } } = setmetatable({}, {
  __index = function(is: { [string]: { [string]: boolean } }, class: string): { [string]: boolean }
    local set: { [string]: boolean } = {}
    local current: string? = class
    while current do
      if current == 'Record' then break end

      set[current :: string] = true
      current = Parents[current :: string]
    end

    rawset(is, class, set)
    return set
  end,
}) :: any

--- While set, the link pass collects each link's index here instead of checking it: a record's
--- links in the order OpenMW's `post` resolves them, for walks over the graph.
local collecting: { number }? = nil

--- The record names of the file being checked (`setNames`).
local names: { string } = {}

local function link(
  index: number,
  class: string,
  records: { any },
  classes: { string },
  owner: number
)
  if collecting then
    table.insert(collecting, index)
    return
  end

  if index < 0 then return end

  local target = records[index + 1]
  if not target then
    G.fail(`{names[owner + 1]} links to record {index}, past the {#records} records`)
  end

  if not Is[classes[index + 1]][class] then
    G.fail(`Failed to cast record pointer to {class}: record {index} is a {names[index + 1]}`)
  end
end

local function links(
  list: { number },
  class: string,
  records: { any },
  classes: { string },
  owner: number
)
  if collecting then
    for _, index in list do
      table.insert(collecting, index)
    end

    return
  end

  -- `link` for each, inline: a list is checked in one call.
  local is, count = Is, #records
  for _, index in list do
    if index < 0 then continue end

    if index >= count then
      G.fail(`{names[owner + 1]} links to record {index}, past the {count} records`)
    end

    if not is[classes[index + 1]][class] then
      G.fail(`Failed to cast record pointer to {class}: record {index} is a {names[index + 1]}`)
    end
  end
end

--- Names the records of the file whose links are checked next, for the messages.
local function setNames(list: { string }) names = list end

--- `RecordPtrT<Record>::post`: `mRecords.at(index)` throws for an index past the records. Not a
--- link the graph is walked by, so never collected.
local function any(index: number, records: { any })
  if collecting then return end

  if index >= #records then G.fail(`Record index {index} is past the {#records} records`) end
end

--- Every link record `index` holds, by running its class's link pass in collecting mode. The
--- file has been checked, so nothing in the pass fails.
local function of(
  record: any,
  check: (any, { any }, { string }, number) -> (),
  records: { any },
  classes: { string },
  index: number
): { number }
  local list = {}
  collecting = list
  check(record, records, classes, index)
  collecting = nil
  return list
end

return table.freeze { link = link, links = links, any = any, is = Is, of = of, setNames = setNames }
