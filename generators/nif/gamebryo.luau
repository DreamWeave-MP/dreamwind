--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Turns `gamebryo_schema.luau` into the multi-version reader's codec modules under
`nif/gamebryo/`: `structs.luau`, one module per record class in `records/`, and `load.luau`,
which requires those on first use:

  jess run jpk/dreamwind/generators/nif/gamebryo.luau jpk/dreamwind/src/nif/internal/gamebryo

A record class's `read` is one straight-line function over its bases' fields and its own, every
field a local until one table constructor at the end; its `check` is OpenMW's post-load pass:
every link must point to a record of the class it names, then the class's own checks.

The schema's steps, in reading order:

- `{ name, kind, when?, count?, list?, fixed?, default? }` reads a field. `when` is a Luau
  condition; `count` an element count expression, `list` the type of a count read first
  (`'u32'` or `'u16'`), `fixed` a constant count. A name starting with `_` stays a local; a
  repeated name assigns the same local; a dotted name assigns into a table local.
- `{ name, expr = '...', when? }` computes a field from earlier ones.
- `{ skip = n | 'expr', when? }` skips bytes.
- `{ ret = 'condition' }` stops reading when the condition holds.
- `{ check = 'condition', message = 'template' }` fails unless the condition holds.

A class's `first` steps are read before its base's fields, the most derived class's first; a
`bare` class reads none of its bases' fields, which keep their defaults; `bases` names bases
whose fields are read only when a condition holds, as `{ NiGeometry = 'BV < SSE' }`. `ret`
ends the whole read, so only a class nothing derives from, or a struct, may use it.

Conditions and expressions see `V` (version), `UV` (user version), `BV` (Bethesda version),
`RN` (the record's name), and every earlier field by name. `@a.b.c.d` is a version;
`FO3`, `SKY`, `SSE`, `FO4`, `F76`, `STF` are Bethesda versions; `VER_MW`, `VER_OB_OLD`,
`VER_OB`, `VER_BGS` are file versions.

Kinds: `u8 i8 u16 i16 u32 i32 u64 f32 f16 bool string sstring estring palette vec2 vec3 vec4
quat mat3 sphere`, `link:<Class>` (`link:any` is checked only for its range), `links:<Class>`,
a struct's name, and `custom:<name>(args)`, a function of `nif/gamebryo/custom.luau` taking the
stream, the position, and the args, returning the value and the position after it. A `link:`
field with a `count`, `list`, or `fixed` is a list of links, checked like `links:`.
]]

local Classes = require '../../src/nif/internal/gamebryo/classes'
local Schema = require './gamebryo_schema'

-- Each part registers its header's classes and structs.
require './gamebryo/base'
require './gamebryo/node'
require './gamebryo/property'
require './gamebryo/texture'
require './gamebryo/effect'
require './gamebryo/extra'
require './gamebryo/data'
require './gamebryo/controller'
require './gamebryo/physics'
require './gamebryo/particle'

type Step = Schema.Step
type Definition = Schema.Definition

local outDir = ...
if not outDir then error('usage: gamebryo.luau <output folder>', 0) end

local Sizes: { [string]: number } = {
  u8 = 1,
  i8 = 1,
  u16 = 2,
  i16 = 2,
  f16 = 2,
  u32 = 4,
  i32 = 4,
  f32 = 4,
  u64 = 8,
  vec2 = 8,
  vec3 = 12,
  vec4 = 16,
  quat = 16,
  mat3 = 36,
  sphere = 16,
}

--- `Read::MIN_SIZE`, which counts are checked against before reading.
local MinSizes: { [string]: number } = {
  bool = 1,
  string = 4,
  sstring = 4,
  estring = 1,
  palette = 4,
}

--- Element kinds read as array views of the file's bytes (`nif/array.luau`).
local Views: { [string]: string } = {
  u8 = 'u8',
  u16 = 'u16',
  i32 = 'i32',
  f32 = 'f32',
  vec2 = 'vec2',
  vec3 = 'vec3',
  vec4 = 'vec4',
  quat = 'quat',
}

local Constants: { [string]: string } = {
  FO3 = '34',
  SKY = '83',
  SSE = '100',
  FO4 = '130',
  F76 = '155',
  STF = '172',
  VER_MW = '0x04000002',
  VER_OB_OLD = '0x0A000102',
  VER_OB = '0x14000005',
  VER_BGS = '0x14020007',
}

--- An expression with its versions and constants written out.
local function expand(text: string): string
  text = string.gsub(
    text,
    '@(%d+)%.(%d+)%.(%d+)%.(%d+)',
    function(a: string, b: string, c: string, d: string)
      local value = (
        (tonumber(a) :: number * 256 + tonumber(b) :: number) * 256 + tonumber(c) :: number
      )
          * 256
        + tonumber(d) :: number
      return string.format('0x%08X', value)
    end
  )
  text = string.gsub(
    text,
    '%f[%w_]([%u_%d]+)%f[^%w_]',
    function(word: string) return Constants[word] or word end
  )
  return text
end

--- Lines written so far, the indentation depth, and whether a block just closed, so the next
--- statement at its depth needs a blank line before it.
type Out = { lines: { string }, depth: number, pending: boolean? }

--- Whether `line` opens a block or table, which the next line may follow without a blank line.
local function opener(line: string?): boolean
  if not line or line == '' then return true end

  local code = string.gsub(line, '^%s+', '')
  return string.sub(code, -4) == 'then'
    or string.sub(code, -2) == 'do'
    or string.sub(code, -1) == '{'
    or code == 'else'
    or string.sub(code, 1, 9) == 'function '
    or string.sub(code, 1, 15) == 'local function '
end

local function blank(out: Out)
  if not opener(out.lines[#out.lines]) then table.insert(out.lines, '') end
end

local function emit(out: Out, line: string)
  if out.pending then
    out.pending = false
    blank(out)
  end

  table.insert(out.lines, string.rep('  ', out.depth) .. line)
end

--- Opens a block, after a blank line unless it starts its own block: compound statements are
--- paragraphs, as the Luau style has them.
local function open(out: Out, line: string)
  out.pending = false
  blank(out)
  emit(out, line)
  out.depth += 1
end

local function close(out: Out, line: string?)
  out.depth -= 1
  out.pending = false
  emit(out, line or 'end')
  out.pending = line == nil or line == 'end'
end

local function isLink(kind: string): boolean return string.sub(kind, 1, 5) == 'link:' end

local function isLinks(kind: string): boolean return string.sub(kind, 1, 6) == 'links:' end

local function isCustom(kind: string): boolean return string.sub(kind, 1, 7) == 'custom:' end

local function isStruct(kind: string): boolean return Schema.structs[kind] ~= nil end

--- The custom function's name and its argument list, from `custom:name(args)`.
local function customCall(kind: string): (string, string)
  local name, args = string.match(kind, '^custom:([%w_]+)%((.*)%)$')
  if name then return name, if args == '' then '' else ', ' .. expand(args :: string) end

  return string.sub(kind, 8), ''
end

local function minSize(kind: string): number
  if isLink(kind) or isLinks(kind) then return 4 end

  return Sizes[kind]
    or MinSizes[kind]
    or (if isStruct(kind) then Schema.structs[kind].min or 0 else 0)
end

--- The value a field holds when its step doesn't run.
local function default(step: Step): string
  if step.default then return expand(step.default) end

  local kind = step[2] :: string
  if step.count or step.list then
    if Views[kind] then return `Empties.{Views[kind]}` end

    return 'G.empty'
  end

  if step.fixed then return 'G.empty' end

  if
    Sizes[kind]
    and kind ~= 'vec2'
    and kind ~= 'vec3'
    and kind ~= 'vec4'
    and kind ~= 'quat'
    and kind ~= 'mat3'
    and kind ~= 'sphere'
  then
    return '0'
  end

  if kind == 'bool' then return 'false' end

  if kind == 'string' or kind == 'sstring' or kind == 'estring' or kind == 'palette' then
    return '\'\''
  end

  if kind == 'vec2' or kind == 'vec3' then return 'vector.zero' end

  if kind == 'vec4' then return 'G.zero4' end

  if kind == 'quat' then return 'G.unitQuat' end

  if kind == 'mat3' then return 'G.identity()' end

  if kind == 'sphere' then return 'G.noSphere' end

  if isLink(kind) then return '-1' end

  if isLinks(kind) then return 'G.empty' end

  if isStruct(kind) then return `D.{kind}()` end

  return 'nil'
end

local function at(offset: number): string return if offset == 0 then 'p' else `p + {offset}` end

--- A struct of unconditional fixed-size fields as one constructor reading at constant offsets,
--- and its size; nil for any other struct, which is read by a call.
local function inlineStruct(kind: string): (string?, number)
  local definition = Schema.structs[kind]
  if not definition or definition.base then return nil, 0 end

  local parts, offset = {}, 0
  for _, step in definition.fields do
    local name, fieldKind = step[1], step[2]
    if
      not name
      or not fieldKind
      or step.when
      or step.count
      or step.list
      or step.fixed
      or step.expr
      or step.skip
      or step.ret
      or step.check
    then
      return nil, 0
    end

    local f = function(k: number): string return `buffer.readf32(b, {at(offset + k)})` end
    local value, size
    if
      fieldKind == 'u8'
      or fieldKind == 'i8'
      or fieldKind == 'u16'
      or fieldKind == 'i16'
      or fieldKind == 'u32'
      or fieldKind == 'i32'
      or fieldKind == 'f32'
    then
      value, size = `buffer.read{fieldKind}(b, {at(offset)})`, Sizes[fieldKind]
    elseif fieldKind == 'f16' then
      value, size = `buffer.readu16(b, {at(offset)})`, 2
    elseif fieldKind == 'vec2' then
      value, size = `vector.create({f(0)}, {f(4)}, 0)`, 8
    elseif fieldKind == 'vec3' then
      value, size = `vector.create({f(0)}, {f(4)}, {f(8)})`, 12
    elseif fieldKind == 'vec4' then
      -- A call, not a constructor: the formatter would break four reads over several lines.
      value, size = `G.vec4(b, {at(offset)})`, 16
    elseif fieldKind == 'quat' then
      value, size = `G.quat(b, {at(offset)})`, 16
    elseif fieldKind == 'mat3' then
      value, size = `G.mat3(b, {at(offset)})`, 36
    else
      return nil, 0
    end

    if string.sub(name, 1, 1) ~= '_' then table.insert(parts, `{name} = {value}`) end

    offset += size
  end

  return `\{ {table.concat(parts, ', ')} }`, offset
end

--- Whether `expression` reads only the file's versions, which a whole file shares.
local function versionOnly(expression: string): boolean
  local text = string.gsub(expand(expression), '0x%x+', '')
  for word in string.gmatch(text, '[%a_][%w_]*') do
    if
      word ~= 'V'
      and word ~= 'UV'
      and word ~= 'BV'
      and word ~= 'and'
      and word ~= 'or'
      and word ~= 'not'
    then
      return false
    end
  end

  return true
end

--- Whether every `kind` struct in a file takes the same bytes: fixed-size fields, read or not by
--- the versions alone. A list of them is read as rows (`G.structRows`), each element when it is
--- asked for.
local function versionFixed(kind: string): boolean
  local definition = Schema.structs[kind]
  if not definition or definition.base then return false end

  for _, step in definition.fields do
    if step.count or step.list or step.fixed or step.expr or step.ret or step.check then
      return false
    end

    if step.when and not versionOnly(step.when) then return false end

    if step.skip then
      if type(step.skip) ~= 'number' then return false end

      continue
    end

    local fieldKind = step[2]
    if not fieldKind then return false end

    local fixed = Sizes[fieldKind] ~= nil
      or fieldKind == 'bool'
      or isLink(fieldKind)
      or (isStruct(fieldKind) and (inlineStruct(fieldKind) ~= nil or versionFixed(fieldKind)))
    if not fixed then return false end
  end

  return true
end

local function f32(offset: number): string
  return if offset == 0 then 'buffer.readf32(b, p)' else `buffer.readf32(b, p + {offset})`
end

--- Reads one `kind` value into `target` and moves `p` past it.
local function readInto(out: Out, target: string, kind: string)
  local size = Sizes[kind]
  if
    kind == 'u8'
    or kind == 'i8'
    or kind == 'u16'
    or kind == 'i16'
    or kind == 'u32'
    or kind == 'i32'
    or kind == 'f32'
  then
    emit(out, `{target} = buffer.read{kind}(b, p)`)
    emit(out, `p += {size}`)
  elseif kind == 'f16' then
    emit(out, `{target} = buffer.readu16(b, p)`)
    emit(out, 'p += 2')
  elseif kind == 'u64' then
    emit(out, `{target} = buffer.readu32(b, p) + buffer.readu32(b, p + 4) * 4294967296`)
    emit(out, 'p += 8')
  elseif kind == 'bool' then
    open(out, 'if V < 0x04010000 then')
    emit(out, `{target} = buffer.readi32(b, p) ~= 0`)
    emit(out, 'p += 4')
    close(out, 'else')
    out.depth += 1
    emit(out, `{target} = buffer.readi8(b, p) ~= 0`)
    emit(out, 'p += 1')
    close(out)
  elseif kind == 'string' then
    -- The string table, from 20.1.0.1, inline: most strings in later files.
    open(out, 'if V >= 0x14010001 then')
    emit(
      out,
      `{target} = s.strings[buffer.readu32(b, p) + 1] or G.stringIndex(s, buffer.readu32(b, p))`
    )
    emit(out, 'p += 4')
    close(out, 'else')
    out.depth += 1
    emit(out, `{target}, p = G.sizedU32(s, p)`)
    close(out)
  elseif kind == 'sstring' then
    emit(out, `{target}, p = G.sizedU32(s, p)`)
  elseif kind == 'estring' then
    emit(out, `{target}, p = G.export(s, p)`)
  elseif kind == 'palette' then
    emit(out, `{target}, p = G.palette(s, p)`)
  elseif kind == 'vec2' then
    emit(out, `{target} = vector.create({f32(0)}, {f32(4)}, 0)`)
    emit(out, 'p += 8')
  elseif kind == 'vec3' then
    emit(out, `{target} = vector.create({f32(0)}, {f32(4)}, {f32(8)})`)
    emit(out, 'p += 12')
  elseif kind == 'vec4' then
    emit(out, `{target} = \{ {f32(0)}, {f32(4)}, {f32(8)}, {f32(12)} }`)
    emit(out, 'p += 16')
  elseif kind == 'quat' then
    emit(out, `{target} = \{ {f32(4)}, {f32(8)}, {f32(12)}, {f32(0)} }`)
    emit(out, 'p += 16')
  elseif kind == 'mat3' then
    emit(out, `{target} = G.mat3(b, p)`)
    emit(out, 'p += 36')
  elseif kind == 'sphere' then
    emit(
      out,
      `{target} = \{ center = vector.create({f32(0)}, {f32(4)}, {f32(8)}), radius = {f32(12)} }`
    )
    emit(out, 'p += 16')
  elseif isLink(kind) then
    emit(out, `{target} = buffer.readi32(b, p)`)
    emit(out, 'p += 4')
    emit(out, `if {target} < -1 then G.invalidLink({target}) end`)
  elseif isLinks(kind) then
    open(out, 'do')
    emit(out, 'local count = buffer.readu32(b, p)')
    emit(out, 'p += 4')
    emit(out, `{target} = G.links(s, p, count)`)
    emit(out, 'p += count * 4')
    close(out)
  elseif isStruct(kind) then
    local inline, size = inlineStruct(kind)
    if inline then
      emit(out, `{target} = {inline}`)
      emit(out, `p += {size}`)
    else
      emit(out, `{target}, p = R.{kind}(s, p)`)
    end
  elseif isCustom(kind) then
    local name, args = customCall(kind)
    emit(out, `{target}, p = C.{name}(s, p{args})`)
  else
    error(`no reader for kind {kind}`)
  end
end

--- Reads `count` elements of `kind` into `target`.
local function readArray(out: Out, target: string, kind: string, count: string, checked: boolean)
  -- Views are most of a mesh, so they're made here, without `checkSize` and `G.view` as calls:
  -- the bounds check covers both, and `G.viewFail` tells them apart for the message.
  local view = Views[kind]
  if view then
    local size = Sizes[kind]
    open(out, `if p + {count} * {size} > s.n then`)
    emit(out, `G.viewFail(s, p, {count}, '{view}', {size}, {checked})`)
    close(out)
    emit(
      out,
      `{target} = if {count} == 0 then Empties.{view} else setmetatable(\{ buffer = b, offset = p, count = {count}, stride = {size} }, Metas.{view})`
    )
    emit(out, `p += {count} * {size}`)
    return
  end

  if checked and minSize(kind) > 0 then emit(out, `G.checkSize(s, {count} * {minSize(kind)})`) end

  -- Fixed-size structs are read when an element is asked for, not here (`nif/gamebryo/rows.luau`).
  if isStruct(kind) then
    local inline, size = inlineStruct(kind)
    if inline then
      emit(out, `{target}, p = G.rows(s, p, {count}, {size}, W.{kind})`)
      return
    end

    if versionFixed(kind) then
      emit(out, `{target}, p = G.structRows(s, p, {count}, R.{kind})`)
      return
    end
  end

  -- Not `list`, which a field may be called.
  open(out, 'do')
  emit(out, `local __list = table.create({count})`)
  open(out, `for i = 1, {count} do`)
  readInto(out, '__list[i]', kind)
  close(out)
  emit(out, `{target} = __list`)
  close(out)
end

local function readStep(out: Out, step: Step)
  local name = step[1] :: string
  local kind = step[2]
  if step.expr then
    emit(out, `{name} = {expand(step.expr)}`)
    return
  end

  assert(kind, `step {name} has no kind`)
  if step.list then
    open(out, 'do')
    local reader = if step.list == 'u16' then 'readu16' else 'readu32'
    emit(out, `local count = buffer.{reader}(b, p)`)
    emit(out, `p += {if step.list == 'u16' then 2 else 4}`)
    readArray(out, name, kind, 'count', true)
    close(out)
  elseif step.count then
    open(out, 'do')
    emit(out, `local count = {expand(step.count)}`)
    readArray(out, name, kind, 'count', true)
    close(out)
  elseif step.fixed then
    readArray(out, name, kind, tostring(step.fixed), false)
  else
    readInto(out, name, kind)
  end
end

--- The fields a definition stores and the locals it reads into, bases first.
local function flatten(definition: Definition, classes: boolean): { Step }
  local chain, names = { definition }, { '' }
  local base = definition.base
  while base do
    local parent = (if classes then Schema.classes[base] else Schema.structs[base]) :: Definition
    assert(parent, `unknown base {base}`)
    table.insert(chain, 1, parent)
    table.insert(names, 1, base)
    base = parent.base
  end

  local conditions: { [string]: string } = {}
  for _, link in chain do
    for name, condition in link.bases or {} do
      conditions[name] = condition
    end
  end

  local steps, bare = {}, 0
  for i = #chain, 1, -1 do
    for _, step in chain[i].first or {} do
      table.insert(steps, step)
    end

    if chain[i].bare and bare == 0 then bare = i end
  end

  for i, link in chain do
    local condition = conditions[names[i]]
    for _, step in link.fields do
      if condition then
        assert(not step.ret and not step.check, `{names[i]}'s fields can't be conditional`)
        step = table.clone(step)
        step.when = if step.when then `({condition}) and ({step.when})` else condition
      end

      if i < bare then
        local unread = table.clone(step)
        unread.unread = true
        table.insert(steps, unread)
      else
        table.insert(steps, step)
      end
    end
  end

  return steps
end

--- Declares each local once, with its default, in first-seen order; returns the stored names.
--- Conditional steps whose field gets its default in an `else` branch, when the step doesn't run.
local ElseDefault: { [Step]: boolean } = {}

local function declare(out: Out, steps: { Step }): { string }
  local seen, stored, uses = {}, {}, {}
  for _, step in steps do
    local name = step[1]
    if name then uses[name] = (uses[name] or 0) + 1 end
  end

  local stopped = false
  for _, step in steps do
    if step.ret then stopped = true end

    local name = step[1]
    if not name or seen[name] or string.find(name, '.', 1, true) then continue end

    seen[name] = true
    -- A default is built only when the field isn't read: a field every read assigns needs none,
    -- and a field one conditional step assigns gets it in that step's `else`.
    local always = not stopped and not step.when and not step.unread
    local otherwise = not stopped and step.when ~= nil and not step.unread and uses[name] == 1
    if otherwise then ElseDefault[step] = true end

    emit(out, if always or otherwise then `local {name}` else `local {name} = {default(step)}`)
    if string.sub(name, 1, 1) ~= '_' then table.insert(stored, name) end
  end

  return stored
end

local function emitSteps(out: Out, steps: { Step })
  local depth = 0
  for _, step in steps do
    if step.unread then continue end

    if step.ret then
      open(out, `if not ({expand(step.ret)}) then`)
      depth += 1
      continue
    end

    if step.check then
      emit(out, `if not ({expand(step.check)}) then G.fail(\`{step.message}\`) end`)
      continue
    end

    local when = step.when and expand(step.when)
    if when then open(out, `if {when} then`) end

    if step.skip then
      local length = if type(step.skip) == 'number'
        then tostring(step.skip)
        else expand(step.skip :: string)
      emit(out, `p = G.skip(s, p, {length})`)
    else
      readStep(out, step)
    end

    if when and ElseDefault[step] then
      close(out, 'else')
      out.depth += 1
      emit(out, `{step[1]} = {default(step)}`)
    end

    if when then close(out) end
  end

  for _ = 1, depth do
    close(out)
  end
end

local function emitReader(
  out: Out,
  header: string,
  definition: Definition,
  classes: boolean,
  typeName: boolean
)
  local steps = flatten(definition, classes)
  open(out, header)
  emit(out, 'local b, V, UV, BV = s.b, s.version, s.userVersion, s.bethVersion')
  if typeName then emit(out, 'local RN = s.recordName') end

  local stored = declare(out, steps)
  emitSteps(out, steps)
  local parts = if typeName then { 'type = RN' } else {}
  for _, name in stored do
    table.insert(parts, `{name} = {name}`)
  end

  -- A paragraph of its own: the formatter breaks a long constructor over several lines.
  table.insert(out.lines, '')
  emit(out, `return \{ {table.concat(parts, ', ')} }, p`)
  close(out)
end

--- The links a class holds and the checks OpenMW runs after loading, bases first.
local function emitCheck(out: Out, definition: Definition)
  local steps = flatten(definition, true)
  local chain = { definition }
  local base = definition.base
  while base do
    table.insert(chain, 1, Schema.classes[base])
    base = Schema.classes[base].base
  end

  open(out, 'local function check(r: any, records: { any }, classes: { string }, index: number)')
  local seen, anyLinks = {}, {}
  for _, step in steps do
    local name, kind = step[1], step[2]
    if not name or not kind or seen[name] or string.sub(name, 1, 1) == '_' then continue end

    seen[name] = true
    if kind == 'link:any' then
      -- Checked in `post`, after the links of a class.
      table.insert(anyLinks, name)
    elseif isLink(kind) and (step.count or step.list or step.fixed) then
      -- Most lists and links are empty or -1: those cost a test, not a call.
      open(out, `if #r.{name} > 0 then`)
      emit(out, `L.links(r.{name}, '{string.sub(kind, 6)}', records, classes, index)`)
      close(out)
    elseif isLink(kind) then
      open(out, `if r.{name} >= 0 then`)
      emit(out, `L.link(r.{name}, '{string.sub(kind, 6)}', records, classes, index)`)
      close(out)
    elseif isLinks(kind) then
      open(out, `if #r.{name} > 0 then`)
      emit(out, `L.links(r.{name}, '{string.sub(kind, 7)}', records, classes, index)`)
      close(out)
    end
  end

  for _, name in anyLinks do
    emit(out, `L.any(r.{name}, records)`)
  end

  for _, link in chain do
    for _, post in link.post or {} do
      emit(out, `C.{post}(r, records, classes, index)`)
    end
  end

  close(out)
end

local Header = {
  '--!nonstrict',
  '-- SPDX-License-Identifier: MIT OR Apache-2.0',
  '-- @generated by generator/gamebryo.luau from generator/gamebryo_schema.luau. Do not edit.',
  '',
}

local function moduleText(body: { string }, prefix: string, extra: { string }?): string
  local text = table.concat(body, '\n')
  local out = table.clone(Header)
  local function uses(name: string): boolean
    return string.find(text, `%f[%w_]{name}%f[^%w_]`) ~= nil
  end

  if uses 'G' or uses 'Empties' then table.insert(out, `local G = require '{prefix}stream'`) end

  if uses 'C' then table.insert(out, `local C = require '{prefix}custom'`) end

  if uses 'R' or uses 'D' or uses 'W' then
    table.insert(out, `local Structs = require '{prefix}structs'`)
  end

  if uses 'L' then table.insert(out, `local L = require '{prefix}links'`) end

  if uses 'Empties' and uses 'Metas' then
    table.insert(out, `local Array = require '{prefix}../array'`)
    table.insert(out, 'local Empties, Metas = Array.empty, Array.metas')
  elseif uses 'Empties' then
    table.insert(out, `local Empties = require('{prefix}../array').empty`)
  end

  if uses 'R' then table.insert(out, 'local R = Structs.read') end

  if uses 'D' then table.insert(out, 'local D = Structs.default') end

  if uses 'W' then table.insert(out, 'local W = Structs.rows') end

  for _, line in extra or {} do
    table.insert(out, line)
  end

  table.insert(out, '')
  table.move(body, 1, #body, #out + 1, out)
  return table.concat(out, '\n') .. '\n'
end

local function sorted(map: { [string]: any }): { string }
  local list = {}
  for key in map do
    table.insert(list, key)
  end

  table.sort(list)
  return list
end

local function structsModule(): string
  local out: Out = { lines = {}, depth = 0 }
  emit(out, 'local read, default, rows, shared = {}, {}, {}, {}')
  for _, name in sorted(Schema.structs) do
    local definition = Schema.structs[name]
    emit(out, '')
    emitReader(
      out,
      `function read.{name}(s: G.Stream, p: number): (any, number)`,
      definition,
      false,
      false
    )
    emit(out, '')
    local parts = {}
    local seen = {}
    for _, step in flatten(definition, false) do
      local field = step[1]
      if
        not field
        or seen[field]
        or string.sub(field, 1, 1) == '_'
        or string.find(field, '.', 1, true)
      then
        continue
      end

      seen[field] = true
      table.insert(parts, `{field} = {default(step)}`)
    end

    -- The reader is read-only, so a struct's default is one frozen table, made when first used.
    open(out, `function default.{name}(): any`)
    emit(out, `local made = shared.{name}`)
    emit(out, 'if made then return made end')
    emit(out, '')
    emit(out, `made = table.freeze(\{ {table.concat(parts, ', ')} })`)
    emit(out, `shared.{name} = made`)
    emit(out, 'return made')
    close(out)
    local inline = inlineStruct(name)
    if inline then
      emit(out, '')
      emit(out, `function rows.{name}(b: buffer, p: number): any return {inline} end`)
    end
  end

  emit(out, '')
  emit(out, 'return { read = read, default = default, rows = rows }')
  -- A struct reads other structs through `read`, defined above, not a require of itself.
  local text = moduleText(out.lines, './')
  text = string.gsub(text, 'local Structs = require \'./structs\'\n', '')
  text = string.gsub(text, 'local R = Structs.read\n', 'local R = read\n')
  text = string.gsub(text, 'local D = Structs.default\n', 'local D = default\n')
  text = string.gsub(text, 'local W = Structs.rows\n', 'local W = rows\n')
  text = string.gsub(text, '\nlocal read, default, rows, shared = {}, {}, {}, {}\n', '\n')
  text = string.gsub(text, '(\n\n)', '\nlocal read, default, rows, shared = {}, {}, {}, {}\n%1', 1)
  return text
end

local function recordModule(class: string): string
  local definition = Schema.classes[class]
  local out: Out = { lines = {}, depth = 0 }
  emitReader(
    out,
    'local function read(s: G.Stream, p: number): (any, number)',
    definition,
    true,
    true
  )
  emit(out, '')
  emitCheck(out, definition)
  emit(out, '')
  emit(out, 'return table.freeze { read = read, check = check }')
  return moduleText(out.lines, '../')
end

local concrete = {}
for _, entry in Classes.factory do
  concrete[entry[1]] = true
end

local written, missing = 0, {}
jess.fs.write(jess.fs.join(outDir, 'structs.luau'), structsModule())
for _, class in sorted(concrete) do
  if not Schema.classes[class] then
    table.insert(missing, class)
    continue
  end

  jess.fs.write(jess.fs.join(outDir, 'records', `{class}.luau`), recordModule(class))
  written += 1
end

local load = table.clone(Header)
table.insert(
  load,
  '--- Each record class\'s codec, required the first time a record of it is read.'
)
table.insert(load, 'local Codecs = setmetatable({}, {')
table.insert(load, '  __index = function(codecs, class)')
table.insert(load, '    local codec = Requires[class]')
table.insert(load, '    if not codec then return nil end')
table.insert(load, '')
table.insert(load, '    local loaded = codec()')
table.insert(load, '    rawset(codecs, class, loaded)')
table.insert(load, '    return loaded')
table.insert(load, '  end,')
table.insert(load, '})')
table.insert(load, '')
local requires = { 'Requires = {' }
for _, class in sorted(concrete) do
  if Schema.classes[class] then
    local line = `  {class} = function() return require('./records/{class}') end,`
    if #line <= 100 then
      table.insert(requires, line)
    else
      -- Too long for one line: the formatter breaks it, so it is a paragraph of its own.
      if requires[#requires] ~= '' then table.insert(requires, '') end

      table.insert(requires, `  {class} = function()`)
      table.insert(requires, `    return require('./records/{class}')`)
      table.insert(requires, '  end,')
      table.insert(requires, '')
    end
  end
end

table.insert(requires, '}')
table.insert(load, 4, 'local Requires')
table.insert(load, 5, '')
for i, line in requires do
  table.insert(load, 5 + i, line)
end

table.insert(load, '')
table.insert(load, 'return Codecs')
jess.fs.write(jess.fs.join(outDir, 'load.luau'), table.concat(load, '\n') .. '\n')
print(`wrote structs, load, and {written} record classes; {#missing} classes have no schema yet`)
