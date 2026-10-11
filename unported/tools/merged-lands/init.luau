--!strict
--!native
--[[
@dreamwind/tools/merged-lands: Merged Lands 0.2.0, as a function of (state, openmw), openmw
being the load order's config from `jess.openmw.load`.

It merges the load order's LAND records the way Merged Lands does in its default OpenMW mode: each
plugin's terrain is measured against the terrain loaded before it, the vertices it changed win in
load order, seams between cells are averaged shut, and whatever then differs from what OpenMW would
load anyway goes into one plugin, with the LTEX records it uses. The plugin belongs last.

Settings come from merged_lands.toml beside the user's openmw.cfg when there is one, with
`state.mergedlands` laid over them:
  outputFile             string              --output-file; default "Merged Lands.omwaddon"
  outputDir              string              --output-file-dir, output_file_dir; default data-local, else the first data folder
  plugins                { string }          the plugins to merge; default openmw.cfg's content
  sortOrder              "default" | "none"  --sort-order: how `plugins` and the masters are ordered
  ignorePlugins          { string }          ignore_plugins
  ignorePluginsFromPath  { string }          ignore_plugins_from_path
  activate               boolean             enable the plugin in openmw.cfg; skipped when it isn't
                                             in a data folder
A plugin's `<name>.mergedlands.toml` patch file controls its merge as it does for the original.

The plugin is the original's byte for byte but for the header's timestamp. The original's Conflicts
images and --add-debug-vertex-colors aren't ported, and merged_lands.toml is read, never written.
Afterwards `state.mergedlands.report` holds
{ output, plugins, lands, merged, textures, seams, masters, activated }.

Ported from Merged Lands, David Von Derau's (DVD) tool, as its OpenMW fork has it
(https://github.com/Sophialovesmorrowind/OpenMWMergedLands):

MIT License

Copyright (c) 2022 David Von Derau

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
]]

type Strategy = 'Auto' | 'Resolve' | 'Overwrite' | 'Ignore'

type Settings = { included: boolean, strategy: Strategy }

-- A plugin's `.mergedlands.toml`: `mergedLands` marks one of the original's own outputs.
type Meta = {
  mergedLands: boolean,
  heightMap: Settings,
  vertexColors: Settings,
  textureIndices: Settings,
  worldMapData: Settings,
}

type Source = {
  name: string,
  path: string,
  plugin: Plugin,
  meta: Meta,
  -- The plugin's VTEX indices, to the merged LTEX list's.
  remap: { [number]: number },
  fallback: number,
}

type Contribution = { source: number, record: Record }

type LandCell = { gridX: number, gridY: number, contributions: { Contribution } }

-- One of LAND's arrays: `count` elements of `components` numbers, `size` bytes each.
type Kind = { count: number, size: number, components: number, read: (buffer, number) -> number }

-- A LAND record as the merge sees it: heights are absolute, textures are merged LTEX indices.
type Land = {
  objectFlags: number,
  flags: number,
  heights: buffer?,
  normals: buffer?,
  colors: buffer?,
  textures: buffer?,
  worldMap: buffer?,
}

-- Values measured against a reference: an element differs where `value` isn't `ref`. `value` is the
-- merge's to change only once `owned`.
type Relative = { ref: buffer, value: buffer, owned: boolean }

type Merged = {
  heights: Relative?,
  normals: Relative?,
  colors: Relative?,
  textures: Relative?,
  worldMap: Relative?,
  objectFlags: number,
  creator: Contribution,
  last: number,
}

-- What seam repair and cleaning need of a merged cell. Sides run bottom, top, left, right, 65
-- vertices each.
type Summary = {
  cell: LandCell,
  last: number,
  differs: boolean,
  sides: buffer?,
  sideRefs: buffer?,
  loadedSides: buffer?,
  normalSides: buffer?,
  normalRefSides: buffer?,
  loadedNormalSides: buffer?,
  textures: buffer?,
}

type Texture = {
  id: string,
  index: number,
  fileName: string,
  flags: string,
  source: number,
}

type Report = {
  output: string?,
  plugins: number,
  lands: number,
  merged: number,
  textures: number,
  seams: number,
  masters: { string },
  activated: boolean,
}

type Options = {
  outputFile: string?,
  outputDir: string?,
  plugins: { string }?,
  sortOrder: ('default' | 'none')?,
  ignorePlugins: { string }?,
  ignorePluginsFromPath: { string }?,
  activate: boolean?,
  report: Report?,
}

return function(state: { [string]: unknown }?, context: OpenMwContext?)
  local shared: { [string]: unknown } = state or {}
  local options: Options = (shared.mergedlands :: Options?) or {}
  shared.mergedlands = options

  local openmw: OpenMwContext = context
    or jess.openmw.default()
    or error 'merged-lands needs an OpenMW config'

  local DefaultOutput, VanillaOutput, ConfigName =
    'Merged Lands.omwaddon', 'Merged Lands.esp', 'merged_lands.toml'
  local Vertices, Deleted = 65 * 65, 0x20

  local DefaultIgnored = {
    'delta-merged.omwaddon',
    'deleted_groundcover.omwaddon',
    'S3LightFixes.omwaddon',
    'OMWLLFMod.omwaddon',
    'merged.omwaddon',
    'Merged Objects.esp',
  }

  local PluginExtensions: { [string]: boolean } =
    { esm = true, esp = true, omwaddon = true, omwgame = true }

  local Heights: Kind = { count = Vertices, size = 4, components = 1, read = buffer.readi32 }
  local Normals: Kind = { count = Vertices, size = 3, components = 3, read = buffer.readi8 }
  local Colors: Kind = { count = Vertices, size = 3, components = 3, read = buffer.readu8 }
  local Textures: Kind = { count = 256, size = 2, components = 1, read = buffer.readu16 }
  local WorldMap: Kind = { count = 81, size = 1, components = 1, read = buffer.readu8 }

  -- Every Relative without a reference of its own measures against these, which nothing writes.
  local zeros: { [Kind]: buffer } = {}
  for _, kind in { Heights, Normals, Colors, Textures, WorldMap } do
    zeros[kind] = buffer.create(kind.count * kind.size)
  end

  -- Rounds to the nearest f32, as the original's float math does at every step.
  local function f32(value: number): number return vector.create(value, 0, 0).x end

  -- Rust's `as` for a float headed to an integer: toward zero.
  local function truncate(value: number): number
    if value < 0 then return math.ceil(value) end

    return math.floor(value)
  end

  local function fileName(path: string): string return string.match(path, '[^/\\]*$') or path end

  local function extension(name: string): string
    return string.lower(string.match(name, '%.([^%.]*)$') or '')
  end

  local function stem(name: string): string
    local base = fileName(name)
    return string.match(base, '^(.*)%.[^%.]*$') or base
  end

  local function joinRelative(base: string, path: string): string
    if string.match(path, '^[/\\]') or string.match(path, '^%a:[/\\]') then return path end

    return jess.fs.join(base, path)
  end

  -- merged_lands.toml. A missing file is the original's first-run defaults; the original writes
  -- them out, this doesn't.
  type AppConfig = {
    outputDir: string?,
    ignorePlugins: { string },
    ignorePluginsFromPath: { string },
    generatedOutputDir: string?,
    generatedOutputFiles: { string },
  }

  local function stringList(value: unknown, key: string): { string }
    if value == nil then return {} end
    if type(value) ~= 'table' then error(`{ConfigName}: {key} must be a list of strings`) end

    local list = {}
    for _, item in value :: { unknown } do
      if type(item) ~= 'string' then error(`{ConfigName}: {key} must be a list of strings`) end

      table.insert(list, item)
    end

    return list
  end

  local function optionalString(value: unknown, key: string): string?
    if value == nil or type(value) == 'string' then return value :: string? end

    error(`{ConfigName}: {key} must be a string`)
  end

  local userConfigDir = openmw.userConfigDir

  local function readAppConfig(): AppConfig
    local path = jess.fs.join(userConfigDir, ConfigName)
    local text = jess.fs.read(path)
    if not text then
      return {
        ignorePlugins = table.clone(DefaultIgnored),
        ignorePluginsFromPath = {},
        generatedOutputFiles = {},
      }
    end

    local raw = jess.toml.decode(text)
    local outputDir =
      optionalString(raw.output_file_dir or raw.default_output_file_dir, 'output_file_dir')
    local fromPaths = raw.ignore_plugins_from_path
      or raw.ignore_plugins_from_paths
      or raw.ignore_paths
    local generatedDir = optionalString(raw.generated_output_dir, 'generated_output_dir')

    local config: AppConfig = {
      outputDir = if outputDir then joinRelative(userConfigDir, outputDir) else nil,
      ignorePlugins = stringList(raw.ignore_plugins, 'ignore_plugins'),
      ignorePluginsFromPath = {},
      generatedOutputDir = generatedDir,
      generatedOutputFiles = stringList(raw.generated_output_files, 'generated_output_files'),
    }

    for _, path in stringList(fromPaths, 'ignore_plugins_from_path') do
      table.insert(config.ignorePluginsFromPath, joinRelative(userConfigDir, path))
    end

    return config
  end

  local appConfig = readAppConfig()
  local encoding: Encoding = openmw.encoding or 'win1252'
  local outputName = options.outputFile or DefaultOutput

  local outputDir = options.outputDir
    or appConfig.outputDir
    or openmw.writableDataDir
    or error 'merged-lands: openmw.cfg sets no data-local or data folder, so set state.mergedlands.outputDir'

  if not jess.fs.isDir(outputDir) then jess.fs.createDir(outputDir) end

  -- Previous outputs never merge into the next one: the default names, this run's, and the ones
  -- merged_lands.toml says the original wrote here, if they're still around.
  local generated: { [string]: boolean } = {
    [string.lower(DefaultOutput)] = true,
    [string.lower(VanillaOutput)] = true,
    [string.lower(outputName)] = true,
  }

  local generatedDir = appConfig.generatedOutputDir
  if generatedDir and generatedDir ~= 'default_data_local' then
    local dir = joinRelative(userConfigDir, generatedDir)
    if string.lower(dir) == string.lower(outputDir) then
      for _, name in appConfig.generatedOutputFiles do
        if jess.fs.isFile(jess.fs.join(outputDir, name)) then
          generated[string.lower(name)] = true
        end
      end
    end
  end

  local ignored: { [string]: boolean } = {}
  for _, name in options.ignorePlugins or appConfig.ignorePlugins do
    ignored[string.lower(name)] = true
  end

  -- A path's folders and file, lowercase, for matching ignoring case and slash direction.
  local function pathParts(path: string): { string }
    local parts: { string } = {}
    for part in string.gmatch(string.lower(path), '[^/\\]+') do
      if part ~= '.' then table.insert(parts, part) end
    end

    return parts
  end

  local ignoredPaths: { { string } } = {}
  for _, path in options.ignorePluginsFromPath or appConfig.ignorePluginsFromPath do
    table.insert(ignoredPaths, pathParts(path))
  end

  local function underIgnoredPath(path: string): boolean
    local parts = pathParts(path)

    for _, prefix in ignoredPaths do
      if #prefix > #parts then continue end

      local matches = true
      for index, part in prefix do
        if parts[index] ~= part then
          matches = false
          break
        end
      end

      if matches then return true end
    end

    return false
  end

  type Entry = { name: string, path: string? }

  local entries: { Entry } = {}
  local explicit = options.plugins
  if explicit then
    for _, name in explicit do
      table.insert(entries, { name = name, path = openmw:resolve(name) })
    end
  else
    for _, entry in openmw:content() do
      table.insert(entries, { name = entry.name, path = entry.path })
    end
  end

  local kept: { Entry } = {}
  for _, entry in entries do
    local name = string.lower(fileName(entry.name))
    if generated[name] then continue end
    if ignored[string.lower(entry.name)] or ignored[name] then continue end
    if entry.path and #ignoredPaths > 0 and underIgnoredPath(entry.path :: string) then continue end

    table.insert(kept, entry)
  end

  local function isMaster(name: string): boolean return extension(name) == 'esm' end

  -- Masters first, then oldest first: the order Morrowind's launcher loads a plugin list in, and the
  -- order the original writes masters in. Ties keep their order.
  local function byDate(names: { string }, paths: { [string]: string? }): { string }
    local position, modified = {}, {}
    for index, name in names do
      position[name] = index
      local path = paths[name]
      modified[name] = (if path then jess.fs.modified(path) else nil) or 0
    end

    local sorted = table.clone(names)
    table.sort(sorted, function(left: string, right: string): boolean
      local leftPlugin, rightPlugin = not isMaster(left), not isMaster(right)
      if leftPlugin ~= rightPlugin then return rightPlugin end
      if modified[left] ~= modified[right] then return modified[left] < modified[right] end

      return position[left] < position[right]
    end)

    return sorted
  end

  local sortByDate = explicit ~= nil and options.sortOrder ~= 'none'

  if sortByDate then
    local names, paths = {}, {}
    for _, entry in kept do
      table.insert(names, entry.name)
      paths[entry.name] = entry.path
    end

    local byName = {}
    for _, entry in kept do
      byName[entry.name] = entry
    end

    kept = {}
    for _, name in byDate(names, paths) do
      table.insert(kept, byName[name])
    end
  end

  local paths: { string }, names: { string } = {}, {}
  for _, entry in kept do
    local path = entry.path
    if not path then
      print(`merged-lands: {entry.name} isn't in any data folder; skipping it`)
      continue
    end

    -- OpenMW's content list also names Lua script lists, which hold no terrain.
    if not PluginExtensions[extension(entry.name)] then continue end

    table.insert(paths, path)
    table.insert(names, entry.name)
  end

  local openOptions: OpenOptions = {
    types = { 'LAND', 'LTEX' },
    openmw = false,
    encoding = encoding,
  }

  -- Plugins come back in order, without the ones that failed.
  local opened, failures = jess.plugin.openAll(paths, openOptions)

  type Loaded = { name: string, path: string, plugin: Plugin }

  local loaded: { Loaded } = {}
  local nextOpened = 1
  for index, path in paths do
    local failure = failures[path]
    if failure then
      print(`merged-lands: failed to read {names[index]}: {failure}`)
      continue
    end

    table.insert(loaded, { name = names[index], path = path, plugin = opened[nextOpened] })
    nextOpened += 1
  end

  -- OpenMW loads content in the order given, so a plugin whose master is missing or later is a
  -- broken load order, and the original stops on it.
  local positions: { [string]: number } = {}
  for index, entry in loaded do
    positions[string.lower(entry.name)] = index
  end

  local orderProblems = {}
  for index, entry in loaded do
    for _, master in entry.plugin.masters do
      local position = positions[string.lower(master.name)]
      if not position then
        table.insert(orderProblems, `{entry.name} declares missing master {master.name}`)
      elseif position >= index then
        table.insert(
          orderProblems,
          `{entry.name} declares master {master.name} but loads before it`
        )
      end
    end
  end

  if #orderProblems > 0 then
    error(
      'merged-lands: the load order has missing or out-of-order masters:\n  '
        .. table.concat(orderProblems, '\n  ')
    )
  end

  local Strategies: { [string]: Strategy } =
    { Auto = 'Auto', Resolve = 'Resolve', Overwrite = 'Overwrite', Ignore = 'Ignore' }

  local function defaultMeta(): Meta
    return {
      mergedLands = false,
      heightMap = { included = true, strategy = 'Auto' },
      vertexColors = { included = true, strategy = 'Auto' },
      textureIndices = { included = true, strategy = 'Auto' },
      worldMapData = { included = true, strategy = 'Auto' },
    }
  end

  -- A patch file the original can't read counts as none, as it does for the original.
  local function settingsFrom(value: unknown): Settings?
    if value == nil then return { included = true, strategy = 'Auto' } end
    if type(value) ~= 'table' then return nil end

    local fields = value :: { [string]: unknown }
    local included, strategy = fields.included, fields.conflict_strategy
    if included ~= nil and type(included) ~= 'boolean' then return nil end

    if strategy ~= nil and (type(strategy) ~= 'string' or not Strategies[strategy]) then
      return nil
    end

    return {
      included = included ~= false,
      strategy = if strategy then Strategies[strategy :: string] else 'Auto',
    }
  end

  local function readMeta(pluginName: string): Meta
    local metaName = stem(pluginName) .. '.mergedlands.toml'
    local path = openmw:resolve(metaName)
    if not path then return defaultMeta() end

    local text = jess.fs.read(path)
    if not text then return defaultMeta() end

    -- `jess.toml.decode` throws on text that isn't TOML; the original skips such a file.
    local decoded, raw = pcall(jess.toml.decode, text)
    if not decoded then return defaultMeta() end

    local version = raw.version
    if type(version) ~= 'string' then return defaultMeta() end

    if version ~= '0' then
      print(`merged-lands: unsupported plugin meta file {metaName}`)
      return defaultMeta()
    end

    local metaType = raw.meta_type
    if metaType ~= 'Auto' and metaType ~= 'Patch' and metaType ~= 'MergedLands' then
      return defaultMeta()
    end

    local heightMap, vertexColors = settingsFrom(raw.height_map), settingsFrom(raw.vertex_colors)
    local textureIndices, worldMapData =
      settingsFrom(raw.texture_indices), settingsFrom(raw.world_map_data)
    if not heightMap or not vertexColors or not textureIndices or not worldMapData then
      return defaultMeta()
    end

    return {
      mergedLands = metaType == 'MergedLands',
      heightMap = heightMap,
      vertexColors = vertexColors,
      textureIndices = textureIndices,
      worldMapData = worldMapData,
    }
  end

  -- Every LTEX by id, numbered in the order the load order first defines them. Each plugin's LAND
  -- records number textures by its own LTEX list, so each plugin gets a map to these.
  local textures: { Texture } = {}
  local textureById: { [string]: Texture } = {}

  local sources: { Source } = {}
  local cells: { LandCell } = {}
  local cellByKey: { [number]: LandCell } = {}

  local function cellKey(gridX: number, gridY: number): number
    return (gridX + 65536) * 131072 + (gridY + 65536)
  end

  local landCount = 0

  for _, entry in loaded do
    local meta = readMeta(entry.name)
    if meta.mergedLands then continue end

    local source: Source = {
      name = entry.name,
      path = entry.path,
      plugin = entry.plugin,
      meta = meta,
      remap = {},
      fallback = 0,
    }
    table.insert(sources, source)
    local sourceIndex = #sources

    for record in entry.plugin:select { type = 'LTEX' } do
      local ltex = record :: LandscapeTextureRecord
      local id = ltex.id
      local texture = textureById[id]
      if not texture then
        if jess.meta(record).headerFlags.deleted then
          error(`merged-lands: {entry.name} adds the deleted LTEX {id}, as the original won't`)
        end

        texture = {
          id = id,
          index = #textures,
          fileName = ltex.fileName,
          flags = ltex.flags,
          source = sourceIndex,
        }
        table.insert(textures, texture)
        textureById[id] = texture
      end

      source.remap[ltex.index + 1] = texture.index + 1
    end

    -- A LAND pointing at an LTEX its plugin doesn't define gets the plugin's first texture instead
    -- of the black of no texture at all.
    local fallback = math.huge
    for _, index in source.remap do
      fallback = math.min(fallback, index)
    end
    source.fallback = if fallback == math.huge then 0 else fallback

    for record in entry.plugin:select { type = 'LAND' } do
      local grid = jess.land.read(record, {}).grid or { 0, 0 }
      local gridX, gridY = grid[1], grid[2]
      local key = cellKey(gridX, gridY)
      local cell = cellByKey[key]
      if not cell then
        cell = { gridX = gridX, gridY = gridY, contributions = {} }
        cellByKey[key] = cell
        table.insert(cells, cell)
      end

      -- A plugin with two LANDs for one cell counts its last, as the original's map does.
      local contributions = cell.contributions
      local last = contributions[#contributions]
      if last and last.source == sourceIndex then
        last.record = record
      else
        table.insert(contributions, { source = sourceIndex, record = record })
        landCount += 1
      end
    end
  end

  local function readLand(contribution: Contribution): Land
    local source = sources[contribution.source]
    local record = contribution.record
    local terrain = jess.land.read(record)

    local heights: buffer? = nil
    local steps = terrain.heights
    if steps then
      local offset = terrain.heightOffset :: number
      if offset ~= offset or math.abs(offset) >= 2147483648 then
        error(`merged-lands: {source.name} has a LAND with a height offset of {offset}`)
      end

      local base = truncate(offset)
      local absolute = buffer.create(Vertices * 4)
      for position = 0, Vertices * 4 - 4, 4 do
        buffer.writei32(absolute, position, (base + buffer.readi32(steps, position)) * 8)
      end

      heights = absolute
    end

    local textures: buffer? = nil
    local indices = terrain.textures
    if indices then
      local remap, fallback = source.remap, source.fallback
      local remapped = buffer.create(512)
      for position = 0, 510, 2 do
        local index = buffer.readu16(indices, position)
        if index == 0 then continue end

        buffer.writeu16(remapped, position, remap[index] or fallback)
      end

      textures = remapped
    end

    return {
      objectFlags = jess.meta(record).headerFlags.value,
      flags = terrain.flags or 0,
      heights = heights,
      normals = terrain.normals,
      colors = terrain.colors,
      textures = textures,
      worldMap = terrain.worldMap,
    }
  end

  local function uses(flags: number, bits: number): boolean return bit32.band(flags, bits) ~= 0 end

  -- Luau interns strings, so two buffers' bytes compare as one memcmp and a pointer check.
  local function sameBytes(left: buffer, right: buffer): boolean
    return buffer.tostring(left) == buffer.tostring(right)
  end

  local function sameElement(kind: Kind, left: buffer, right: buffer, position: number): boolean
    local size = kind.size
    if size == 4 then return buffer.readi32(left, position) == buffer.readi32(right, position) end
    if size == 2 then return buffer.readu16(left, position) == buffer.readu16(right, position) end
    if size == 1 then return buffer.readu8(left, position) == buffer.readu8(right, position) end

    return buffer.readu16(left, position) == buffer.readu16(right, position)
      and buffer.readu8(left, position + 2) == buffer.readu8(right, position + 2)
  end

  local function copy(source: buffer): buffer
    local target = buffer.create(buffer.len(source))
    buffer.copy(target, 0, source)
    return target
  end

  local function own(map: Relative)
    if map.owned then return end

    map.value = copy(map.value)
    map.owned = true
  end

  -- `values` measured against `reference` (zeros without one), or nil where nothing differs.
  local function relative(kind: Kind, reference: buffer?, values: buffer): Relative?
    local ref = reference or zeros[kind]
    if sameBytes(ref, values) then return nil end

    return { ref = ref, value = values, owned = false }
  end

  local function modified(map: Relative): boolean return not sameBytes(map.ref, map.value) end

  -- Normals only count where the heights under them changed too.
  local function mask(normals: Relative, heights: Relative?)
    own(normals)
    if not heights then
      buffer.copy(normals.value, 0, normals.ref)
      return
    end

    local heightRef, heightVal, normalRef, normalVal =
      heights.ref, heights.value, normals.ref, normals.value
    for vertex = 0, Vertices - 1 do
      local position = vertex * 4
      if buffer.readi32(heightVal, position) ~= buffer.readi32(heightRef, position) then
        continue
      end

      buffer.copy(normalVal, vertex * 3, normalRef, vertex * 3, 3)
    end
  end

  local function overwrite(kind: Kind, left: Relative, right: Relative): Relative
    own(left)
    local size, target, rightRef, rightVal = kind.size, left.value, right.ref, right.value
    for position = 0, (kind.count - 1) * size, size do
      if sameElement(kind, rightVal, rightRef, position) then continue end

      buffer.copy(target, position, rightVal, position, size)
    end

    return left
  end

  local function ignore(kind: Kind, left: Relative, right: Relative): Relative
    own(left)
    local size, target, leftRef, rightRef, rightVal =
      kind.size, left.value, left.ref, right.ref, right.value
    for position = 0, (kind.count - 1) * size, size do
      if not sameElement(kind, target, leftRef, position) then continue end
      if sameElement(kind, rightVal, rightRef, position) then continue end

      buffer.copy(target, position, rightVal, position, size)
    end

    return left
  end

  -- The original's weighted average for two conflicting values, in its f32 arithmetic, truncated
  -- toward zero. Only a patch file's `Resolve` asks for it.
  local function average(kind: Kind, left: number, right: number): number
    local leftWeight = f32(math.abs(left) / f32(math.abs(left) + math.abs(right)))
    local rightWeight = f32(1 - leftWeight)
    local leftPower, rightPower = f32(leftWeight ^ 1.5), f32(rightWeight ^ 1.5)
    leftWeight = f32(leftPower / f32(leftPower + rightPower))
    rightWeight = f32(1 - leftWeight)

    local value = truncate(f32(f32(leftWeight * left) + f32(rightWeight * right)))
    if kind == Normals then return math.clamp(value, -128, 127) end

    return value
  end

  local function writeComponent(kind: Kind, target: buffer, position: number, value: number)
    if kind == Heights then
      buffer.writei32(target, position, value)
    elseif kind == Textures then
      buffer.writeu16(target, position, value)
    elseif kind == Normals then
      buffer.writei8(target, position, value)
    else
      buffer.writeu8(target, position, value)
    end
  end

  local function resolve(kind: Kind, left: Relative, right: Relative): Relative
    own(left)
    local size, target, leftRef, rightRef, rightVal =
      kind.size, left.value, left.ref, right.ref, right.value
    local width = size // kind.components

    for position = 0, (kind.count - 1) * size, size do
      if sameElement(kind, rightVal, rightRef, position) then continue end

      if sameElement(kind, target, leftRef, position) then
        buffer.copy(target, position, rightVal, position, size)
        continue
      end

      for component = 0, kind.components - 1 do
        local at = position + component * width
        local leftValue, rightValue = kind.read(target, at), kind.read(rightVal, at)
        if leftValue == rightValue then continue end

        writeComponent(kind, target, at, average(kind, leftValue, rightValue))
      end
    end

    return left
  end

  local function combine(
    kind: Kind,
    left: Relative?,
    right: Relative?,
    strategy: Strategy
  ): Relative?
    if left and right then
      if strategy == 'Resolve' then return resolve(kind, left, right) end
      if strategy == 'Ignore' then return ignore(kind, left, right) end

      return overwrite(kind, left, right)
    end

    if left then return left end
    if right then return { ref = right.ref, value = right.value, owned = false } end

    return nil
  end

  -- Texture indices name textures, so there's nothing to average: the later plugin wins where it
  -- changed something, and the result is measured against what came before it.
  local function mergeTextures(old: Relative?, new: Relative?): Relative?
    if not new then return old end

    local before = if old then old.value else zeros[Textures]
    local merged = copy(before)
    local changed = false
    for position = 0, 510, 2 do
      local value = buffer.readu16(new.value, position)
      if value == buffer.readu16(new.ref, position) then continue end
      if buffer.readu16(merged, position) == value then continue end

      buffer.writeu16(merged, position, value)
      changed = true
    end

    if not changed then return old end

    return { ref = before, value = merged, owned = true }
  end

  local function describe(cell: LandCell, contribution: Contribution): string
    return `LAND ({cell.gridX}, {cell.gridY}) in {sources[contribution.source].name}`
  end

  -- One LAND over another, as the original's reference landmass stacks them: each part the later
  -- record has and flags replaces the earlier one's.
  local function stack(cell: LandCell, contribution: Contribution, below: Land?, above: Land): Land
    if not below then return table.clone(above) end

    if below.objectFlags ~= above.objectFlags then
      error(
        `merged-lands: {describe(cell, contribution)} has record flags {above.objectFlags}, but the LAND before it has {below.objectFlags}; the original stops here too`
      )
    end

    if bit32.band(above.objectFlags, Deleted) ~= 0 then
      error(`merged-lands: {describe(cell, contribution)} is deleted; the original stops here too`)
    end

    local stacked = table.clone(below)
    local flags = above.flags

    if uses(flags, 1) then
      if above.heights then
        stacked.heights = above.heights
        stacked.flags = bit32.bor(stacked.flags, 1)
      end

      if above.normals then
        stacked.normals = above.normals
        stacked.flags = bit32.bor(stacked.flags, 1)
      end
    end

    if uses(flags, 2) and above.colors then
      stacked.colors = above.colors
      stacked.flags = bit32.bor(stacked.flags, 2)
    end

    if uses(flags, 4) and above.textures then
      stacked.textures = above.textures
      stacked.flags = bit32.bor(stacked.flags, 4)
    end

    if uses(flags, 7) and above.worldMap then stacked.worldMap = above.worldMap end

    return stacked
  end

  -- The part of a LAND a patch file lets into the merge, or nil for none.
  local function allowed(land: Land, meta: Meta): Land?
    local flags = land.flags
    local heights = uses(flags, 1) and meta.heightMap.included
    local colors = uses(flags, 2) and meta.vertexColors.included
    local textures = uses(flags, 4) and meta.textureIndices.included
    local worldMap = uses(flags, 7) and meta.worldMapData.included
    if not heights and not colors and not textures and not worldMap then return nil end

    local filtered = table.clone(land)
    if not heights then
      filtered.heights, filtered.normals = nil, nil
      filtered.flags = bit32.band(filtered.flags, bit32.bnot(1))
    end

    if not colors then
      filtered.colors = nil
      filtered.flags = bit32.band(filtered.flags, bit32.bnot(2))
    end

    if not textures then
      filtered.textures = nil
      filtered.flags = bit32.band(filtered.flags, bit32.bnot(4))
    end

    if not worldMap then filtered.worldMap = nil end

    return filtered
  end

  local function loadOrderStrategy(strategy: Strategy): Strategy
    if strategy == 'Auto' then return 'Overwrite' end

    return strategy
  end

  -- A cell's merge, and the LAND OpenMW would load there without it.
  local function mergeCell(cell: LandCell): (Merged?, Land?)
    local merged: Merged? = nil
    local reference: Land?, loaded: Land? = nil, nil

    for _, contribution in cell.contributions do
      local source = sources[contribution.source]
      local meta = source.meta
      local land = readLand(contribution)
      local flags = land.flags

      local heightsIn = uses(flags, 1) and meta.heightMap.included
      local colorsIn = uses(flags, 2) and meta.vertexColors.included
      local texturesIn = uses(flags, 4) and meta.textureIndices.included
      local worldMapIn = uses(flags, 7) and meta.worldMapData.included

      local referenceHeights = if reference and uses(reference.flags, 1)
        then reference.heights
        else nil

      local heights = if heightsIn and land.heights
        then relative(Heights, referenceHeights, land.heights :: buffer)
        else nil

      local normals = if heightsIn and land.normals
        then relative(Normals, reference and reference.normals, land.normals :: buffer)
        else nil

      if normals then
        mask(normals, heights)
        if not modified(normals) then normals = nil end
      end

      local worldMap = if worldMapIn and land.worldMap
        then relative(WorldMap, reference and reference.worldMap, land.worldMap :: buffer)
        else nil

      local colors = if colorsIn and land.colors
        then relative(Colors, reference and reference.colors, land.colors :: buffer)
        else nil

      local textures = if texturesIn and land.textures
        then relative(Textures, reference and reference.textures, land.textures :: buffer)
        else nil

      if merged then
        local heightStrategy = loadOrderStrategy(meta.heightMap.strategy)
        merged.heights = combine(Heights, merged.heights, heights, heightStrategy)
        merged.normals = combine(Normals, merged.normals, normals, heightStrategy)

        local mergedNormals = merged.normals
        if mergedNormals then mask(mergedNormals, merged.heights) end

        merged.worldMap = combine(
          WorldMap,
          merged.worldMap,
          worldMap,
          loadOrderStrategy(meta.worldMapData.strategy)
        )
        merged.colors =
          combine(Colors, merged.colors, colors, loadOrderStrategy(meta.vertexColors.strategy))

        local textureStrategy = meta.textureIndices.strategy
        merged.textures = if textureStrategy == 'Auto' or textureStrategy == 'Overwrite'
          then mergeTextures(merged.textures, textures)
          else combine(Textures, merged.textures, textures, textureStrategy)

        merged.last = contribution.source
      elseif heights or normals or worldMap or colors or textures then
        merged = {
          heights = heights,
          normals = normals,
          colors = colors,
          textures = textures,
          worldMap = worldMap,
          objectFlags = land.objectFlags,
          creator = contribution,
          last = contribution.source,
        }
      end

      local filtered = allowed(land, meta)
      if filtered then reference = stack(cell, contribution, reference, filtered) end

      loaded = stack(cell, contribution, loaded, land)
    end

    return merged, loaded
  end

  -- The 65 vertices of each side of a cell, as positions in its arrays: bottom, top, left, right.
  local sideVertices: { number } = {}
  for index = 0, 64 do
    sideVertices[index + 1] = index
    sideVertices[65 + index + 1] = 64 * 65 + index
    sideVertices[130 + index + 1] = index * 65
    sideVertices[195 + index + 1] = index * 65 + 64
  end

  local function sideHeights(values: buffer): buffer
    local sides = buffer.create(260 * 4)
    for slot, vertex in sideVertices do
      buffer.writei32(sides, (slot - 1) * 4, buffer.readi32(values, vertex * 4))
    end

    return sides
  end

  local function sideNormals(values: buffer): buffer
    local sides = buffer.create(260 * 3)
    for slot, vertex in sideVertices do
      buffer.copy(sides, (slot - 1) * 3, values, vertex * 3, 3)
    end

    return sides
  end

  -- Whether `merged` differs from `loaded` anywhere but the vertices seam repair can still move.
  local function heightsDifferInside(merged: buffer, loaded: buffer): boolean
    for row = 1, 63 do
      for position = (row * 65 + 1) * 4, (row * 65 + 63) * 4, 4 do
        if buffer.readi32(merged, position) ~= buffer.readi32(loaded, position) then return true end
      end
    end

    return false
  end

  local function normalsDifferInside(merged: buffer, loaded: buffer): boolean
    for row = 1, 63 do
      for position = (row * 65 + 1) * 3, (row * 65 + 63) * 3, 3 do
        local low = buffer.readu16(merged, position) ~= buffer.readu16(loaded, position)
        local high = buffer.readu8(merged, position + 2) ~= buffer.readu8(loaded, position + 2)
        if low or high then return true end
      end
    end

    return false
  end

  local function summarize(cell: LandCell, merged: Merged, loaded: Land): Summary
    local summary: Summary = { cell = cell, last = merged.last, differs = false }

    local heights = merged.heights
    local loadedHeights = if uses(loaded.flags, 1) then loaded.heights else nil
    if heights then
      summary.sides, summary.sideRefs = sideHeights(heights.value), sideHeights(heights.ref)
      if not loadedHeights then
        summary.differs = true
      else
        summary.loadedSides = sideHeights(loadedHeights)
        summary.differs = not sameBytes(heights.value, loadedHeights)
          and heightsDifferInside(heights.value, loadedHeights)
      end
    end

    local normals = merged.normals
    if normals and not summary.differs then
      local loadedNormals = loaded.normals
      if not loadedNormals then
        summary.differs = true
      else
        summary.normalSides, summary.normalRefSides =
          sideNormals(normals.value), sideNormals(normals.ref)
        summary.loadedNormalSides = sideNormals(loadedNormals)
        summary.differs = not sameBytes(normals.value, loadedNormals)
          and normalsDifferInside(normals.value, loadedNormals)
      end
    end

    local parts: { { map: Relative?, loaded: buffer? } } = {
      { map = merged.worldMap, loaded = loaded.worldMap },
      { map = merged.colors, loaded = loaded.colors },
      { map = merged.textures, loaded = loaded.textures },
    }

    for _, part in parts do
      if summary.differs then break end

      local map = part.map
      if not map then continue end

      local against = part.loaded
      summary.differs = not against or not sameBytes(map.value, against)
    end

    local mergedTextures = merged.textures
    if mergedTextures then summary.textures = mergedTextures.value end

    return summary
  end

  local summaries: { Summary } = {}
  local summaryByKey: { [number]: Summary } = {}

  for _, cell in cells do
    local merged, loaded = mergeCell(cell)
    if not merged or not loaded then continue end

    local summary = summarize(cell, merged, loaded)
    table.insert(summaries, summary)
    summaryByKey[cellKey(cell.gridX, cell.gridY)] = summary
  end

  -- Seams: a vertex two or four cells share has to be the same height in each, or the ground tears.
  -- Corners get the average of every cell there, then each side's other vertices the midpoint of its
  -- two cells. Both round toward zero, as Rust's integer division does.
  local seams = 0

  local Corners = {
    -- A cell's corner as slots of two of its sides, and where the cell is from the corner's point.
    { first = 1, second = 131, dx = 0, dy = 0 },
    { first = 65, second = 196, dx = 64, dy = 0 },
    { first = 66, second = 195, dx = 0, dy = 64 },
    { first = 130, second = 260, dx = 64, dy = 64 },
  }

  local function writeSide(sides: buffer, slot: number, value: number)
    buffer.writei32(sides, (slot - 1) * 4, value)
  end

  local function readSide(sides: buffer, slot: number): number
    return buffer.readi32(sides, (slot - 1) * 4)
  end

  local cornersDone: { [number]: boolean } = {}
  for _, summary in summaries do
    if not summary.sides then continue end

    for _, corner in Corners do
      local pointX = summary.cell.gridX * 64 + corner.dx
      local pointY = summary.cell.gridY * 64 + corner.dy
      local point = (pointX + 4194304) * 8388608 + (pointY + 4194304)
      if cornersDone[point] then continue end

      cornersDone[point] = true

      local sharing: { { sides: buffer, corner: typeof(corner) } } = {}
      for _, other in Corners do
        local cellX = (pointX - other.dx) / 64
        local cellY = (pointY - other.dy) / 64
        local neighbor = summaryByKey[cellKey(cellX, cellY)]
        local sides = neighbor and neighbor.sides
        if sides then table.insert(sharing, { sides = sides, corner = other }) end
      end

      local total = 0
      for _, share in sharing do
        total += readSide(share.sides, share.corner.first)
      end

      local averaged = truncate(total / #sharing)
      for _, share in sharing do
        if readSide(share.sides, share.corner.first) == averaged then continue end

        writeSide(share.sides, share.corner.first, averaged)
        writeSide(share.sides, share.corner.second, averaged)
        seams += 1
      end
    end
  end

  -- Side slots start at 1 (bottom), 66 (top), 131 (left), and 196 (right); the corners are done.
  local function repairSide(near: buffer, nearFirst: number, far: buffer, farFirst: number)
    for index = 1, 63 do
      local nearHeight, farHeight =
        readSide(near, nearFirst + index), readSide(far, farFirst + index)
      if nearHeight == farHeight then continue end

      local midpoint = truncate((nearHeight + farHeight) / 2)
      writeSide(near, nearFirst + index, midpoint)
      writeSide(far, farFirst + index, midpoint)
      seams += 1
    end
  end

  for _, summary in summaries do
    local sides = summary.sides
    if not sides then continue end

    local cell = summary.cell
    local east = summaryByKey[cellKey(cell.gridX + 1, cell.gridY)]
    local eastSides = east and east.sides
    if eastSides then repairSide(sides, 196, eastSides, 131) end

    local north = summaryByKey[cellKey(cell.gridX, cell.gridY + 1)]
    local northSides = north and north.sides
    if northSides then repairSide(sides, 66, northSides, 1) end
  end

  -- A merged cell is only written where it differs from what OpenMW loads without it.
  local function differsOnSides(summary: Summary): boolean
    local sides, sideRefs, loadedSides = summary.sides, summary.sideRefs, summary.loadedSides
    if not sides or not sideRefs or not loadedSides then return false end

    local normalSides, normalRefSides, loadedNormalSides =
      summary.normalSides, summary.normalRefSides, summary.loadedNormalSides

    for slot = 1, 260 do
      local height = readSide(sides, slot)
      if height ~= readSide(loadedSides, slot) then return true end
      if not normalSides or not normalRefSides or not loadedNormalSides then continue end

      local normal = if height == readSide(sideRefs, slot) then normalRefSides else normalSides
      if not sameElement(Normals, normal, loadedNormalSides, (slot - 1) * 3) then return true end
    end

    return false
  end

  local written: { Summary } = {}
  for _, summary in summaries do
    if summary.differs or differsOnSides(summary) then table.insert(written, summary) end
  end

  table.sort(written, function(left: Summary, right: Summary): boolean
    if left.cell.gridX ~= right.cell.gridX then return left.cell.gridX < right.cell.gridX end

    return left.cell.gridY < right.cell.gridY
  end)

  -- LTEX records take the last file name the load order gives them.
  local namedBy: { [Texture]: number } = {}
  for sourceIndex, source in sources do
    for record in source.plugin:select { type = 'LTEX' } do
      local ltex = record :: LandscapeTextureRecord
      local texture = textureById[ltex.id]
      local name = ltex.fileName
      if name == '' or name == texture.fileName then continue end

      texture.fileName = name
      namedBy[texture] = sourceIndex
    end
  end

  -- Only the textures written LANDs use are kept, renumbered in their order. VTEX 0 is no texture.
  local used: { boolean } = { [1] = true }
  for _, summary in written do
    local indices = summary.textures
    if not indices then continue end

    for position = 0, 510, 2 do
      local index = buffer.readu16(indices, position)
      if index <= #textures then used[index + 1] = true end
    end
  end

  local renumbered: { [number]: number } = { [0] = 0 }
  local keptTextures: { Texture } = {}
  local nextIndex = 0
  for index = 0, #textures do
    if not used[index + 1] then continue end

    renumbered[index] = nextIndex
    if index > 0 then table.insert(keptTextures, textures[index]) end

    nextIndex += 1
  end

  local textureFallback = if nextIndex > 1 then 1 else 0

  -- Masters: every plugin a kept texture or a written LAND comes from.
  local masterSet: { [number]: boolean } = {}
  for _, texture in keptTextures do
    masterSet[namedBy[texture] or texture.source] = true
  end

  for _, summary in written do
    masterSet[summary.last] = true
  end

  local masterNames: { string } = {}
  local masterPaths: { [string]: string? } = {}
  for sourceIndex, source in sources do
    if not masterSet[sourceIndex] then continue end

    table.insert(masterNames, source.name)
    masterPaths[source.name] = source.path
  end

  if options.sortOrder ~= 'none' then masterNames = byDate(masterNames, masterPaths) end

  local masters: { Master | string } = {}
  for _, name in masterNames do
    local path = masterPaths[name]
    table.insert(masters, { name = name, size = (if path then jess.fs.size(path) else nil) or 0 })
  end

  local generatedPlugin = jess.plugin.new {
    author = 'Merged Lands by DVD',
    description = `Merges landscape changes inside of cells. Place at end of load order. Generated at {os.time()} UTC.`,
    masters = masters,
    encoding = encoding,
  }

  for newIndex, texture in keptTextures do
    local fields: RecordFields = {
      type = 'LandscapeTexture',
      flags = texture.flags,
      id = texture.id,
      index = newIndex - 1,
      fileName = texture.fileName,
    }
    generatedPlugin:insert(fields)
  end

  -- VHGT keeps a height per 8 units, as the difference from the vertex before it in its row (or
  -- below it, down the first column) in one signed byte; a steeper step is clamped, as the
  -- original's is.
  local function encodeHeights(heights: buffer): (number, buffer)
    local steps = buffer.create(Vertices * 4)
    local offset = truncate(buffer.readi32(heights, 0) / 8)
    local rowStep = 0

    for row = 0, 64 do
      local previous = 0
      local step = 0
      for column = 0, 64 do
        local vertex = row * 65 + column
        local pixel = truncate(buffer.readi32(heights, vertex * 4) / 8)
        if column == 0 then
          if row > 0 then
            local above = truncate(buffer.readi32(heights, (vertex - 65) * 4) / 8)
            rowStep += math.clamp(pixel - above, -128, 127)
          end

          step = rowStep
        else
          step += math.clamp(pixel - previous, -128, 127)
        end

        buffer.writei32(steps, vertex * 4, step)
        previous = pixel
      end
    end

    return offset, steps
  end

  local function toByte(value: number): number return truncate(math.clamp(value, -128, 127)) end

  -- The original's normals from heights, in its f32 arithmetic, reusing the merge's own normal
  -- wherever the height underneath didn't change and that normal isn't zero.
  local function computeNormals(heights: Relative, normals: Relative?): buffer
    local values, ref = heights.value, heights.ref
    local out = buffer.create(Vertices * 3)

    for row = 0, 64 do
      local fixedY = if row == 64 then 63 else row
      for column = 0, 64 do
        local vertex = row * 65 + column
        local fixedX = if column == 64 then 63 else column
        local fixed = fixedY * 65 + fixedX

        local height = buffer.readi32(values, fixed * 4) / 8
        local right = f32(buffer.readi32(values, (fixed + 1) * 4) / 8 - height)
        local up = f32(buffer.readi32(values, (fixed + 65) * 4) / 8 - height)

        local normalX, normalY = f32(-16 * right), f32(-16 * up)
        local squared = f32(f32(f32(normalX * normalX) + f32(normalY * normalY)) + 65536)
        local length = f32(f32(math.sqrt(squared)) / 127)

        buffer.writei8(out, vertex * 3, toByte(f32(normalX / length)))
        buffer.writei8(out, vertex * 3 + 1, toByte(f32(normalY / length)))
        buffer.writei8(out, vertex * 3 + 2, toByte(f32(256 / length)))
      end
    end

    if not normals then return out end

    local existing = normals.value
    for vertex = 0, Vertices - 1 do
      if buffer.readi32(values, vertex * 4) ~= buffer.readi32(ref, vertex * 4) then continue end

      local position = vertex * 3
      local nonzero = buffer.readu16(existing, position) ~= 0
        or buffer.readu8(existing, position + 2) ~= 0
      if nonzero then buffer.copy(out, position, existing, position, 3) end
    end

    return out
  end

  for _, summary in written do
    local cell = summary.cell
    local merged = mergeCell(cell) :: Merged
    local flags = 8

    local terrain: LandParts = {}
    local heights = merged.heights
    if heights then
      own(heights)
      local sides = summary.sides :: buffer
      for slot, vertex in sideVertices do
        buffer.writei32(heights.value, vertex * 4, readSide(sides, slot))
      end

      local normals = merged.normals
      if normals then mask(normals, heights) end

      local offset, steps = encodeHeights(heights.value)
      terrain.heightOffset, terrain.heights = offset, steps
      terrain.normals = computeNormals(heights, normals)
      flags = bit32.bor(flags, 1)
    end

    local colors = merged.colors
    if colors then
      terrain.colors = colors.value
      flags = bit32.bor(flags, 2)
    end

    local mergedTextures = merged.textures
    if mergedTextures then
      local remapped = buffer.create(512)
      for position = 0, 510, 2 do
        local index = buffer.readu16(mergedTextures.value, position)
        buffer.writeu16(remapped, position, renumbered[index] or textureFallback)
      end

      terrain.textures = remapped
      flags = bit32.bor(flags, 4)
    end

    -- The original writes WNAM only when the merge has one, whatever the flags say.
    local worldMap = merged.worldMap
    terrain.worldMap = if worldMap then worldMap.value else false

    terrain.flags = flags

    local fields: RecordFields = { type = 'Landscape', grid = { cell.gridX, cell.gridY } }
    if merged.objectFlags ~= 0 then
      fields.flags = (merged.creator.record :: LandscapeRecord).flags
    end

    local record = generatedPlugin:insert(fields)
    jess.land.write(record, terrain)
  end

  local staleMeta = jess.fs.join(outputDir, stem(outputName) .. '.mergedlands.toml')
  jess.fs.remove(staleMeta)

  local output = jess.fs.join(outputDir, outputName)
  jess.fs.remove(output)
  generatedPlugin:save(output, { backup = false })

  local activated = false
  if options.activate then
    -- `activate` throws for a plugin outside the data folders, where OpenMW wouldn't find it; the
    -- plugin is still written, and the report says it wasn't enabled.
    local ok, result = pcall(function() return openmw:activate(outputName) end)
    if not ok then
      print(`merged-lands: wrote {output} but didn't enable it, as OpenMW can't load it from there`)
    elseif result then
      openmw:save()
      activated = true
    end
  end

  print(
    `merged-lands: {#written} LAND and {#keptTextures} LTEX records from {#sources} plugins in {output}`
  )

  options.report = {
    output = output,
    plugins = #sources,
    lands = landCount,
    merged = #summaries,
    textures = #keptTextures,
    seams = seams,
    masters = masterNames,
    activated = activated,
  }
end
