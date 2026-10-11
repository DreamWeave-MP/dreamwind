--!strict
--!native
--[[
@dreamwind/tools/doctor: a load-order health check, for when the game is broken and you'd like to
know why. Call it with (state, openmw), openmw being the load order's config from
`jess.openmw.load`. It reads the load order and writes a report; it never changes a plugin or
openmw.cfg.

Options, from `state.doctor`:
  checks       { string }  masters, content, assets, meshes, dirt, conflicts; default all of them
  output       string      the report's path; default jess-doctor.yaml beside the user's openmw.cfg
  format       string      "yaml" (the default) or "json"
  minSeverity  string      "error", "warning", or "info" (the default): leaves out anything milder
  verbose      boolean     print every finding, not only the first few

Afterwards `state.doctor.report` holds the report written: { config, output, backup, contentFiles,
plugins, checks, summary, findings }, each finding { severity, check, plugins, records, files,
details, message, fix }.
]]

type Level = 'error' | 'warning' | 'info'

type Finding = {
  severity: Level,
  check: string,
  plugins: { string },
  records: { string }?,
  files: { string }?,
  details: { string }?,
  message: string,
  fix: string,
}

type Summary = { errors: number, warnings: number, info: number, byCheck: { [string]: number } }

type Report = {
  config: string,
  output: string,
  backup: string?,
  contentFiles: number,
  plugins: number,
  checks: { string },
  summary: Summary,
  findings: { Finding },
}

type Options = {
  checks: { string }?,
  output: string?,
  format: ('yaml' | 'json')?,
  minSeverity: Level?,
  verbose: boolean?,
  report: Report?,
}

type Loaded = { name: string, path: string, plugin: Plugin }

-- A kind of dirt `jess plugin clean` removes: `what` for one, `whats` for more (`what` + s).
type Dirt = { flag: string, severity: Level, what: string, whats: string? }

type Conflict = { loser: string, winner: string, records: { string }, manual: number }

-- `jess.plugin.assets` findings for one plugin and code.
type AssetGroup = {
  plugin: string,
  severity: Severity,
  code: string,
  records: { string },
  files: { string },
}

-- A document to write: one of a scalar, a list, or a map with its keys in order.
type Node = { scalar: (string | number | boolean)?, list: { Node }?, map: { Field }? }
type Field = { key: string, node: Node }

return function(state: { [string]: unknown }?, context: OpenMwContext?)
  local shared: { [string]: unknown } = state or {}
  local options: Options = (shared.doctor :: Options?) or {}
  shared.doctor = options

  local openmw: OpenMwContext = context
    or jess.openmw.default()
    or error 'doctor: there is no OpenMW config to check'

  local Checks = { 'masters', 'content', 'assets', 'meshes', 'dirt', 'conflicts' }
  local SeverityRank: { [string]: number } = { error = 1, warning = 2, info = 3 }
  local Formats: { [string]: string } = { yaml = 'yaml', json = 'json' }

  local function set(list: { string }): { [string]: boolean }
    local result = {}
    for _, value in list do
      result[value] = true
    end

    return result
  end

  -- @dreamwind/tools/tes3merge's default record types: conflicts in these it merges on its own.
  local MergeableTypes = set {
    'ACTI',
    'ALCH',
    'APPA',
    'ARMO',
    'BODY',
    'BOOK',
    'BSGN',
    'CELL',
    'CLAS',
    'CLOT',
    'CONT',
    'CREA',
    'DOOR',
    'ENCH',
    'GMST',
    'INGR',
    'LEVC',
    'LEVI',
    'LIGH',
    'LOCK',
    'MGEF',
    'MISC',
    'NPC_',
    'PROB',
    'RACE',
    'REPA',
    'SKIL',
    'SNDG',
    'SOUN',
    'SPEL',
    'STAT',
    'WEAP',
  }

  -- Record types a later plugin's copy doesn't simply replace: cells, dialogue, and path grids merge
  -- in the engine or aren't identified by id alone, landscape has no id, and each plugin keeps its own
  -- land textures. They're the bulk of most plugins, too.
  local IgnoredOverrides = { 'CELL', 'DIAL', 'INFO', 'PGRD', 'LAND', 'LTEX' }

  -- Every other record type: what the conflict check reads.
  local OverrideTypes = {
    'ACTI',
    'ALCH',
    'APPA',
    'ARMO',
    'BODY',
    'BOOK',
    'BSGN',
    'CLAS',
    'CLOT',
    'CONT',
    'CREA',
    'DOOR',
    'ENCH',
    'FACT',
    'GLOB',
    'GMST',
    'INGR',
    'LEVC',
    'LEVI',
    'LIGH',
    'LOCK',
    'MGEF',
    'MISC',
    'NPC_',
    'PROB',
    'RACE',
    'REGN',
    'REPA',
    'SCPT',
    'SKIL',
    'SNDG',
    'SOUN',
    'SPEL',
    'SSCR',
    'STAT',
    'WEAP',
  }

  -- Bethesda's masters carry what looks like dirt by design (Bloodmoon ships Tribunal's settings), and
  -- nobody should clean them.
  local Official = set { 'morrowind.esm', 'tribunal.esm', 'bloodmoon.esm' }

  -- The lint checks for dirt `jess plugin clean` removes, by the flag that removes it.
  local DirtChecks: { [string]: Dirt } = {
    evilGmsts = { flag = '--evil-gmsts', severity = 'warning', what = 'evil GMST' },
    junkCells = { flag = '--junk-cells', severity = 'warning', what = 'junk cell' },
    cellParams = { flag = '--cell-params', severity = 'info', what = 'repeated cell setting' },

    duplicateRecords = {
      flag = '--duplicate-records',
      severity = 'warning',
      what = 'record it defines twice',
      whats = 'records it defines twice',
    },
  }

  local DirtCheckNames = {}
  for check in DirtChecks do
    table.insert(DirtCheckNames, check)
  end

  -- A model that won't load is an error, and missing textures are worth fixing. Other collision and
  -- rendering findings are usually how the model looked in Morrowind too, except collision OpenMW
  -- drops.
  local MeshLevels: { [string]: Level } = {
    wontLoad = 'error',
    missingAsset = 'warning',
    collision = 'info',
    broken = 'info',
  }

  local LostCollision = set { 'noCollision', 'shapeWithoutCollision', 'lowercaseNcc' }

  -- Reference findings: a file nothing provides, or a record OpenMW reads wrong.
  local AssetSeverities: { [string]: Level } = { broken = 'warning', missingAsset = 'warning' }

  -- Plugins that can't be read are the content check's to report.
  local CheckedElsewhere = set { 'unreadablePlugin' }

  local enabled: { [string]: boolean } = {}
  for _, check in options.checks or Checks do
    if not table.find(Checks, check) then
      error(`doctor: unknown check "{check}"; expected {table.concat(Checks, ', ')}`)
    end

    enabled[check] = true
  end

  local format = Formats[options.format or 'yaml']
    or error(`doctor: unknown format "{options.format}"; expected yaml or json`)
  local minSeverity = SeverityRank[options.minSeverity or 'info']
    or error(
      `doctor: unknown minSeverity "{options.minSeverity}"; expected error, warning, or info`
    )

  local outputPath = options.output or jess.fs.join(openmw.userConfigDir, `jess-doctor.{format}`)
  local findings: { Finding } = {}

  local function add(finding: Finding) table.insert(findings, finding) end

  local function isScripts(name: string): boolean
    return string.find(string.lower(name), '%.omwscripts$') ~= nil
  end

  local function counted(count: number, one: string, many: string?): string
    return `{count} {if count == 1 then one else many or one .. 's'}`
  end

  local function quoted(name: string): string
    return if string.find(name, '[%s\'"]') then `"{name}"` else name
  end

  local content = openmw:content()
  local positions: { [string]: number } = {}
  local paths, names = {}, {}

  for index, entry in content do
    positions[string.lower(entry.name)] = index

    if not entry.path then
      if not enabled.content then continue end

      add {
        severity = 'error',
        check = 'missingContent',
        plugins = { entry.name },
        message = `{entry.name} is in the load order, but no data folder has it`,
        fix = `install the mod that provides {entry.name}, or remove content={entry.name} from openmw.cfg`,
      }
      continue
    end

    if isScripts(entry.name) then continue end

    table.insert(paths, entry.path)
    table.insert(names, entry.name)
  end

  -- The asset check reads the load order on its own, so it runs before the plugins here are open.
  local function checkAssets()
    local assets = jess.plugin.assets(nil, {
      openmw = openmw,
      encoding = openmw.encoding,
      meshes = enabled.meshes == true,
      references = false,
      -- The plugins are opened next, so what the check read goes back first.
      releaseMemory = true,
      show = 'collision',
    })

    if enabled.assets then
      local groups: { [string]: AssetGroup }, order: { AssetGroup } = {}, {}

      for _, finding in assets.findings do
        if not AssetSeverities[finding.severity] or CheckedElsewhere[finding.code] then continue end

        local key = `{finding.plugin}\0{finding.code}`
        local group = groups[key]
        if not group then
          group = {
            plugin = finding.plugin,
            severity = finding.severity,
            code = finding.code,
            records = {},
            files = {},
          }
          groups[key] = group
          table.insert(order, group)
        end

        table.insert(group.records, `{finding.recordType} {finding.id}`)
        if finding.path ~= '' and not table.find(group.files, finding.path) then
          table.insert(group.files, finding.path)
        end
      end

      for _, group in order do
        local missing = group.severity == 'missingAsset'
        add {
          severity = AssetSeverities[group.severity],
          check = if missing then 'missingAsset' else 'badRecord',
          plugins = { group.plugin },
          records = group.records,
          files = group.files,
          message = if missing
            then `{group.plugin} refers to {counted(#group.files, 'file')} nothing provides ({group.code})`
            else `{group.plugin} has {counted(#group.records, 'record')} OpenMW reads wrong ({group.code})`,
          fix = if missing
            then `install the mod that provides them, or fix the paths in {group.plugin}`
            else `fix these records in {group.plugin}, or ask its author to`,
        }
      end
    end

    if not enabled.meshes then return end

    for _, mesh in assets.meshes do
      local level: Level?, message: string?
      local details: { string }, seen: { [string]: boolean } = {}, {}

      for _, finding in mesh.findings do
        local found: Level? = if LostCollision[finding.code]
          then 'warning'
          else MeshLevels[finding.severity]
        if not found then continue end

        if not level or SeverityRank[found] < SeverityRank[level] then
          level, message = found, finding.message
        end

        local detail = `{finding.code}: {finding.message}`
        if seen[detail] then continue end

        seen[detail] = true
        table.insert(details, detail)
      end

      if not level or not message then continue end

      add {
        severity = level,
        check = 'mesh',
        plugins = {},
        records = mesh.usedBy,
        files = { mesh.path },
        details = details,
        message = `{mesh.path}: {message}`,
        fix = '`jess nif check` on the file for the details; `jess nif fix` repairs some',
      }
    end
  end

  if enabled.assets or enabled.meshes then checkAssets() end

  local needsRecords = enabled.dirt or enabled.conflicts
  local encoding: Encoding = openmw.encoding or 'win1252'

  -- Junk cells are only junk without references, so the dirt check reads plugins whole. Without it,
  -- only the record types compared are read, and without that, only the headers.
  local function recordTypes(): { string }?
    if enabled.dirt then return nil end
    if enabled.conflicts then return OverrideTypes end

    return {}
  end

  local openOptions: OpenOptions = { openmw = false, encoding = encoding, types = recordTypes() }

  -- Plugins come back in order, without the ones that failed.
  local opened, failures = jess.plugin.openAll(paths, openOptions)
  local plugins: { Loaded } = {}
  local nextOpened = 1

  for index, path in paths do
    local failure = failures[path]
    if not failure then
      table.insert(plugins, { name = names[index], path = path, plugin = opened[nextOpened] })
      nextOpened += 1
      continue
    end

    local name = names[index]
    add {
      severity = 'error',
      check = 'unreadablePlugin',
      plugins = { name },
      files = { path },
      message = `{name} can't be read: {failure}`,
      fix = `reinstall the mod that provides {name}, or remove content={name} from openmw.cfg`,
    }
  end

  local function checkMasters(loaded: Loaded, position: number)
    for _, master in loaded.plugin.masters do
      local masterPosition = positions[string.lower(master.name)]

      if not masterPosition then
        local installed = openmw:resolve(master.name) ~= nil
        add {
          severity = 'error',
          check = 'missingMaster',
          plugins = { loaded.name, master.name },
          message = `{loaded.name} needs {master.name}, which isn't in the load order`,
          fix = if installed
            then `add content={master.name} to openmw.cfg above content={loaded.name}`
            else `install {master.name}, or remove content={loaded.name} from openmw.cfg`,
        }
        continue
      end

      if masterPosition > position then
        add {
          severity = 'error',
          check = 'masterOrder',
          plugins = { loaded.name, master.name },
          message = `{loaded.name} loads before its master {master.name}`,
          fix = `move content={master.name} above content={loaded.name} in openmw.cfg`,
        }
        continue
      end

      local path = content[masterPosition].path
      local size = if path then jess.fs.size(path) else nil
      if not size or size == master.size then continue end

      add {
        severity = 'info',
        check = 'masterSize',
        plugins = { loaded.name, master.name },
        message = `{loaded.name} records {master.name} as {master.size} bytes; it's {size}`,
        fix = `\`jess plugin header {quoted(loaded.path)} --update-masters\` (OpenMW doesn't mind; Morrowind.exe and the CS do)`,
      }
    end
  end

  if enabled.masters then
    for _, loaded in plugins do
      checkMasters(loaded, positions[string.lower(loaded.name)])
    end
  end

  local function checkDirt(loaded: Loaded)
    local byCheck: { [string]: { string } } = {}

    for _, finding in loaded.plugin:lint { checks = DirtCheckNames, openmw = false } do
      local messages = byCheck[finding.check] or {}
      table.insert(messages, finding.message)
      byCheck[finding.check] = messages
    end

    for check, messages in byCheck do
      local dirt = DirtChecks[check]
      add {
        severity = dirt.severity,
        check = check,
        plugins = { loaded.name },
        details = messages,
        message = `{loaded.name} has {counted(#messages, dirt.what, dirt.whats)}`,
        fix = `\`jess plugin clean {quoted(loaded.path)} {dirt.flag}\``,
      }
    end
  end

  if enabled.dirt then
    for _, loaded in plugins do
      if not Official[string.lower(loaded.name)] then checkDirt(loaded) end
    end
  end

  -- Whether `plugin` lists `name` among its masters.
  local function hasMaster(plugin: Plugin, name: string): boolean
    for _, master in plugin.masters do
      if string.lower(master.name) == string.lower(name) then return true end
    end

    return false
  end

  local mergeOptions = shared.tes3merge :: { fileName: string?, report: unknown? }?
  local mergedName = mergeOptions and mergeOptions.fileName or 'Merged Objects.esp'
  -- TES3Merge is in use when its plugin loads; a run earlier in this state counts too.
  local tes3mergeEnabled = positions[string.lower(mergedName)] ~= nil
    or (mergeOptions and mergeOptions.report) ~= nil

  local function checkOverrides()
    local handles: { Plugin } = {}
    for _, loaded in plugins do
      table.insert(handles, loaded.plugin)
    end

    local identical: { [string]: { string } } = {}
    local conflicts: { [string]: Conflict } = {}
    local identicalOrder: { Loaded }, conflictOrder: { string } = {}, {}

    for _, record in jess.compare.overrides(handles, { ignore = IgnoredOverrides }) do
      local key = `{record.type} {record.id}`

      for _, copy in record.identical do
        local owner, earlier = plugins[copy.plugin], plugins[copy.sameAs]
        if Official[string.lower(owner.name)] or not hasMaster(owner.plugin, earlier.name) then
          continue
        end

        if not identical[owner.name] then
          identical[owner.name] = {}
          table.insert(identicalOrder, owner)
        end

        table.insert(identical[owner.name], key)
      end

      local winner = plugins[record.plugins[#record.plugins]]

      for _, position in record.overridden do
        local loser = plugins[position]
        if hasMaster(winner.plugin, loser.name) then continue end

        local pair = `{loser.name}\0{winner.name}`
        local conflict = conflicts[pair]
        if not conflict then
          conflict = { loser = loser.name, winner = winner.name, records = {}, manual = 0 }
          conflicts[pair] = conflict
          table.insert(conflictOrder, pair)
        end

        table.insert(conflict.records, key)
        if not MergeableTypes[record.type] then
          conflict.manual += 1
        end
      end
    end

    if enabled.dirt then
      for _, owner in identicalOrder do
        local records = identical[owner.name]
        add {
          severity = 'info',
          check = 'identicalToMaster',
          plugins = { owner.name },
          records = records,
          message = `{owner.name} has {counted(#records, 'record')} identical to its masters' copies`,
          fix = `\`jess plugin clean {quoted(owner.path)} --duplicate-records\``,
        }
      end
    end

    if not enabled.conflicts then return end

    for _, pair in conflictOrder do
      local conflict = conflicts[pair]
      local count, manual = #conflict.records, conflict.manual
      local mergeable = count - manual
      local fixes = {}

      if mergeable > 0 and not tes3mergeEnabled then
        table.insert(
          fixes,
          `merge them with @dreamwind/tools/tes3merge, and load {mergedName} last`
        )
      elseif mergeable > 0 then
        table.insert(
          fixes,
          `{mergedName} merges these; run @dreamwind/tools/tes3merge again after load order changes`
        )
      end

      if manual > 0 then
        table.insert(
          fixes,
          `patch the {counted(manual, 'record')} it can't merge in a plugin loading after {conflict.winner}, or drop one of the two`
        )
      end

      local message =
        `{conflict.winner} replaces {counted(count, 'record')} {conflict.loser} changed, dropping its changes`
      if mergeable > 0 then
        message ..= ` ({mergeable} of them @dreamwind/tools/tes3merge can merge)`
      end

      add {
        severity = if manual == 0 and tes3mergeEnabled then 'info' else 'warning',
        check = 'conflict',
        plugins = { conflict.loser, conflict.winner },
        records = conflict.records,
        message = message,
        fix = table.concat(fixes, '; '),
      }
    end
  end

  if needsRecords then checkOverrides() end

  if enabled.conflicts and tes3mergeEnabled and not positions[string.lower(mergedName)] then
    add {
      severity = 'warning',
      check = 'tes3merge',
      plugins = { mergedName },
      message = `@dreamwind/tools/tes3merge ran, but {mergedName} isn't in the load order`,
      fix = `add content={mergedName} to openmw.cfg, last, or run the merge with activate = true`,
    }
  end

  local kept: { Finding } = {}
  for _, finding in findings do
    if SeverityRank[finding.severity] <= minSeverity then table.insert(kept, finding) end
  end

  -- Findings of one severity are listed in this order.
  local CheckOrder = {
    'missingContent',
    'unreadablePlugin',
    'missingMaster',
    'masterOrder',
    'tes3merge',
    'conflict',
    'badRecord',
    'missingAsset',
    'mesh',
    'evilGmsts',
    'junkCells',
    'duplicateRecords',
    'masterSize',
    'cellParams',
    'identicalToMaster',
  }

  local CheckRank: { [string]: number } = {}
  for index, check in CheckOrder do
    CheckRank[check] = index
  end

  table.sort(kept, function(left: Finding, right: Finding): boolean
    if left.severity ~= right.severity then
      return SeverityRank[left.severity] < SeverityRank[right.severity]
    end

    if left.check ~= right.check then return CheckRank[left.check] < CheckRank[right.check] end

    return left.message < right.message
  end)

  local summary: Summary = { errors = 0, warnings = 0, info = 0, byCheck = {} }
  for _, finding in kept do
    if finding.severity == 'error' then
      summary.errors += 1
    elseif finding.severity == 'warning' then
      summary.warnings += 1
    else
      summary.info += 1
    end

    summary.byCheck[finding.check] = (summary.byCheck[finding.check] or 0) + 1
  end

  local checks = {}
  for _, check in Checks do
    if enabled[check] then table.insert(checks, check) end
  end

  local report: Report = {
    config = jess.fs.join(openmw.userConfigDir, 'openmw.cfg'),
    output = outputPath,
    contentFiles = #content,
    plugins = #plugins,
    checks = checks,
    summary = summary,
    findings = kept,
  }

  -- The report is written by hand, keys in a fixed order, so two runs' reports diff cleanly.
  local function scalar(value: string | number | boolean): Node return { scalar = value } end

  local function strings(values: { string }): Node
    local items = {}
    for _, value in values do
      table.insert(items, scalar(value))
    end

    return { list = items }
  end

  local function findingNode(finding: Finding): Node
    local fields: { Field } = {
      { key = 'severity', node = scalar(finding.severity) },
      { key = 'check', node = scalar(finding.check) },
      { key = 'plugins', node = strings(finding.plugins) },
      { key = 'message', node = scalar(finding.message) },
      { key = 'fix', node = scalar(finding.fix) },
    }

    local function optional(key: string, values: { string }?)
      if values and #values > 0 then table.insert(fields, { key = key, node = strings(values) }) end
    end

    optional('records', finding.records)
    optional('files', finding.files)
    optional('details', finding.details)
    return { map = fields }
  end

  local function reportNode(): Node
    local byCheck: { Field } = {}
    for _, check in CheckOrder do
      local count = summary.byCheck[check]
      if count then table.insert(byCheck, { key = check, node = scalar(count) }) end
    end

    local findingNodes = {}
    for _, finding in kept do
      table.insert(findingNodes, findingNode(finding))
    end

    local summaryFields: { Field } = {
      { key = 'errors', node = scalar(summary.errors) },
      { key = 'warnings', node = scalar(summary.warnings) },
      { key = 'info', node = scalar(summary.info) },
      { key = 'byCheck', node = { map = byCheck } },
    }

    return {
      map = {
        { key = 'config', node = scalar(report.config) },
        { key = 'contentFiles', node = scalar(report.contentFiles) },
        { key = 'plugins', node = scalar(report.plugins) },
        { key = 'checks', node = strings(report.checks) },
        { key = 'summary', node = { map = summaryFields } },
        { key = 'findings', node = { list = findingNodes } },
      },
    }
  end

  local JsonEscapes: { [string]: string } = {
    ['"'] = '\\"',
    ['\\'] = '\\\\',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
  }

  local function jsonString(text: string): string
    local escaped = string.gsub(
      text,
      '[%c"\\]',
      function(character: string): string
        return JsonEscapes[character] or string.format('\\u%04x', string.byte(character))
      end
    )

    return '"' .. escaped .. '"'
  end

  local function scalarText(value: string | number | boolean, yaml: boolean): string
    if type(value) == 'number' then
      return if value % 1 == 0 then string.format('%d', value) else tostring(value)
    end

    if type(value) == 'boolean' then return tostring(value) end

    local plain = string.find(value, '^[%w/][%w%s%.,_/%-%(%)]*$') ~= nil
      and not string.find(value, '%s$')
      and not tonumber(value)
      and not table.find({ 'true', 'false', 'null', 'yes', 'no', 'on', 'off' }, string.lower(value))
    if yaml and plain then return value end

    return jsonString(value)
  end

  local function yamlLines(node: Node, indent: string, lines: { string })
    for _, field in node.map or {} do
      local child = field.node
      local prefix = `{indent}{field.key}:`

      if child.scalar ~= nil then
        table.insert(lines, `{prefix} {scalarText(child.scalar, true)}`)
      elseif child.list and #child.list == 0 then
        table.insert(lines, `{prefix} []`)
      elseif child.map and #child.map == 0 then
        table.insert(lines, `{prefix} \{}`)
      elseif child.list then
        table.insert(lines, prefix)

        for _, item in child.list do
          if item.scalar ~= nil then
            table.insert(lines, `{indent}- {scalarText(item.scalar, true)}`)
            continue
          end

          local first = #lines + 1
          yamlLines(item, indent .. '  ', lines)
          lines[first] = indent .. '- ' .. string.sub(lines[first], #indent + 3)
        end
      else
        table.insert(lines, prefix)
        yamlLines(child, indent .. '  ', lines)
      end
    end
  end

  local function json(node: Node, indent: string): string
    if node.scalar ~= nil then return scalarText(node.scalar, false) end

    local inner = indent .. '  '
    local parts = {}

    if node.list then
      if #node.list == 0 then return '[]' end

      for _, item in node.list do
        table.insert(parts, inner .. json(item, inner))
      end

      return '[\n' .. table.concat(parts, ',\n') .. '\n' .. indent .. ']'
    end

    local fields = node.map or {}
    if #fields == 0 then return '{}' end

    for _, field in fields do
      table.insert(parts, `{inner}{jsonString(field.key)}: {json(field.node, inner)}`)
    end

    return '{\n' .. table.concat(parts, ',\n') .. '\n' .. indent .. '}'
  end

  local function render(): string
    if format == 'json' then return json(reportNode(), '') .. '\n' end

    local lines = {}
    yamlLines(reportNode(), '', lines)
    return table.concat(lines, '\n') .. '\n'
  end

  local written = jess.fs.write(outputPath, render(), { backup = true })
  report.backup = written.backup
  options.report = report

  local Shown = 10

  print(
    `doctor: {summary.errors} errors, {summary.warnings} warnings, {summary.info} info in {#content} content files`
  )

  local counts = {}
  for _, check in CheckOrder do
    local count = summary.byCheck[check]
    if count then table.insert(counts, `{check} {count}`) end
  end

  if #counts > 0 then print(`  by check: {table.concat(counts, ', ')}`) end

  local shown = 0
  for _, finding in kept do
    if not options.verbose and (finding.severity == 'info' or shown == Shown) then break end

    print(`  {finding.severity} {finding.check}: {finding.message}`)
    print(`    fix: {finding.fix}`)
    shown += 1
  end

  local hidden = #kept - shown
  if hidden > 0 then print(`  ... and {hidden} more in the report`) end

  if written.backup then
    print(`report: {written.path} (the last one is in {written.backup})`)
  else
    print(`report: {written.path}`)
  end
end
