--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Turns `schema.luau` into the codec modules under `nif/`: `scan.luau`, `structs.luau`, one
module per record type in `records/`, `load.luau` to require those on first use, `enums.luau`,
and `types.luau`:

  jess run generators/nif/generate.luau src/nif/internal

For every record and struct there are four straight-line functions: `scan` walks past its fields
collecting the links, `read` decodes them into one table, `write` encodes a table, and `links`
collects the links of a decoded one. A record's read, write, and links cover its bases' fields
too, so runs of fixed-size fields are read and written at constant offsets from one position and
native code checks their bounds once. Only the scanners load with the package; a record type's
module compiles the first time one is decoded.
]]

local Schema = require './schema'

type Field = Schema.Field
type Definition = Schema.Definition

local outDir = ...
if not outDir then error('usage: generate.luau <output folder>', 0) end

local Sizes: { [string]: number } = {
  u8 = 1,
  bool8 = 1,
  u16 = 2,
  i16 = 2,
  u32 = 4,
  i32 = 4,
  f32 = 4,
  link = 4,
  vec2 = 8,
  vec3 = 12,
  vec4 = 16,
  quat = 16,
  mat2 = 16,
  mat3 = 36,
  tri = 6,
  u16f32 = 6,
  f32x2 = 8,
  u32x3 = 12,
  u8x4 = 4,
}

local Scalars: { [string]: string } = {
  u8 = 'u8',
  bool8 = 'u8',
  u16 = 'u16',
  i16 = 'i16',
  u32 = 'u32',
  i32 = 'i32',
  f32 = 'f32',
}

--- Structs of fixed-size fields and no links, by size: read and written in place, not by a call.
local Inline: { [string]: number } = {}

local function sizeOf(kind: string): number?
  if string.sub(kind, 1, 5) == 'enum:' then return 4 end

  return Sizes[kind] or Inline[kind]
end

do
  local changed = true
  while changed do
    changed = false
    for name, definition in Schema.Structs do
      if Inline[name] then continue end

      local size = 0
      for _, field in definition.fields do
        local kind = field[2]
        local each = kind and kind ~= 'link' and sizeOf(kind)
        if
          not each
          or string.sub(field[1], 1, 1) == '_'
          or field.when
          or field.list
          or field.count
        then
          size = -1
          break
        end

        size += each * (field.fixed or 1)
      end

      if size > 0 then
        Inline[name] = size
        changed = true
      end
    end
  end
end

local function at(offset: number): string
  if offset == 0 then return 'p' end

  return `p + {offset}`
end

local function f32(offset: number): string return `buffer.readf32(b, {at(offset)})` end

local function vec3(offset: number): string
  return `vector.create({f32(offset)}, {f32(offset + 4)}, {f32(offset + 8)})`
end

--- The expression reading one `kind` element at `offset` past `p`. `inList` keeps a null link as
--- -1, so lists stay dense.
local function readElement(kind: string, offset: number, inList: boolean?): string
  if Inline[kind] then
    local parts, position = {}, offset
    for _, field in Schema.Structs[kind].fields do
      local fieldKind = field[2] :: string
      local each = sizeOf(fieldKind) :: number
      local value = readElement(fieldKind, position)
      if field.fixed then
        local elements = {}
        for i = 0, field.fixed - 1 do
          table.insert(elements, readElement(fieldKind, position + i * each))
        end

        value = `\{ {table.concat(elements, ', ')} }`
      end

      table.insert(parts, `{field[1]} = {value}`)
      position += each * (field.fixed or 1)
    end

    return `\{ {table.concat(parts, ', ')} }`
  end

  local scalar = Scalars[kind]
  if kind == 'bool8' then return `buffer.readu8(b, {at(offset)}) ~= 0` end

  if scalar then return `buffer.read{scalar}(b, {at(offset)})` end

  if string.sub(kind, 1, 5) == 'enum:' then
    -- Read twice rather than call: the second load shares the first's bounds check.
    local read = `buffer.readi32(b, {at(offset)})`
    return `Names.{string.sub(kind, 6)}[{read}] or {read}`
  end

  if kind == 'link' then
    if inList then return `buffer.readi32(b, {at(offset)})` end

    -- Raw: the record's constructor turns a negative index into nil.
    return `buffer.readi32(b, {at(offset)})`
  end

  if kind == 'vec2' then return `vector.create({f32(offset)}, {f32(offset + 4)}, 0)` end

  if kind == 'vec3' then return vec3(offset) end

  if kind == 'vec4' or kind == 'mat2' then
    return `\{ {f32(offset)}, {f32(offset + 4)}, {f32(offset + 8)}, {f32(offset + 12)} }`
  end

  if kind == 'quat' then
    return `\{ {f32(offset + 4)}, {f32(offset + 8)}, {f32(offset + 12)}, {f32(offset)} }`
  end

  if kind == 'mat3' then return `C.readMat3(b, {at(offset)})` end

  if kind == 'tri' then
    local u = function(k: number) return `buffer.readu16(b, {at(offset + k)})` end
    return `vector.create({u(0)}, {u(2)}, {u(4)})`
  end

  if kind == 'u16f32' then
    return `vector.create(buffer.readu16(b, {at(offset)}), buffer.readf32(b, {at(offset + 2)}), 0)`
  end

  if kind == 'f32x2' then return `\{ {f32(offset)}, {f32(offset + 4)} }` end

  if kind == 'u32x3' then
    local u = function(k: number) return `buffer.readu32(b, {at(offset + k)})` end
    return `\{ {u(0)}, {u(4)}, {u(8)} }`
  end

  if kind == 'u8x4' then
    local u = function(k: number) return `buffer.readu8(b, {at(offset + k)})` end
    return `\{ {u(0)}, {u(1)}, {u(2)}, {u(3)} }`
  end

  error(`no element reader for {kind}`)
end

--- The check that flags the writer when a float in `value` is NaN, so the save puts back the
--- source's NaN bits (`restoreNans` in `init.luau`); nil for kinds without floats.
local function nanCheck(kind: string, value: string): string?
  local parts: { string } = {}
  if kind == 'f32' then
    parts = { value }
  elseif kind == 'vec2' or kind == 'vec3' then
    parts = { value }
  elseif kind == 'vec4' or kind == 'quat' or kind == 'mat2' then
    parts = { `{value}[1]`, `{value}[2]`, `{value}[3]`, `{value}[4]` }
  elseif kind == 'mat3' then
    parts = { `{value}1`, `{value}2`, `{value}3` }
  elseif kind == 'u16f32' then
    parts = { `{value}.y` }
  elseif kind == 'f32x2' then
    parts = { `{value}[1]`, `{value}[2]` }
  else
    return nil
  end

  local tests = {}
  for _, part in parts do
    table.insert(tests, `{part} ~= {part}`)
  end

  return `if {table.concat(tests, ' or ')} then w.nan = true end`
end

--- The statements writing `value` as one `kind` element at `offset` past `p`.
local function writeElement(kind: string, value: string, offset: number): { string }
  if Inline[kind] then
    local lines, position = {}, offset
    for _, field in Schema.Structs[kind].fields do
      local fieldKind = field[2] :: string
      local each = sizeOf(fieldKind) :: number
      local part = value .. string.upper(string.sub(field[1], 1, 1)) .. string.sub(field[1], 2)
      local annotation = if fieldKind == 'vec3' then ': vector' else ''
      table.insert(lines, `local {part}{annotation} = {value}.{field[1]}`)
      for i = 0, (field.fixed or 1) - 1 do
        local element = if field.fixed then `{part}[{i + 1}]` else part
        for _, line in writeElement(fieldKind, element, position + i * each) do
          table.insert(lines, line)
        end

        local check = nanCheck(fieldKind, element)
        if check then table.insert(lines, check) end
      end

      position += each * (field.fixed or 1)
    end

    return lines
  end

  local scalar = Scalars[kind]
  if kind == 'bool8' then return { `buffer.writeu8(b, {at(offset)}, if {value} then 1 else 0)` } end

  if scalar then return { `buffer.write{scalar}(b, {at(offset)}, {value})` } end

  if string.sub(kind, 1, 5) == 'enum:' then
    -- A known name is one lookup; a number, or an unknown name to report, takes the call.
    local values = `Values.{string.sub(kind, 6)}`
    return {
      `buffer.writei32(b, {at(offset)}, {values}[{value}] or C.enumValue({values}, {value}))`,
    }
  end

  if kind == 'link' then
    return {
      `buffer.writei32(b, {at(offset)}, if {value} and {value} >= 0 then map[{value}] or -1 else -1)`,
    }
  end

  local lines = {}
  local function put(write: string, k: number, part: string)
    table.insert(lines, `buffer.write{write}(b, {at(offset + k)}, {part})`)
  end

  if kind == 'vec2' then
    put('f32', 0, `{value}.x`)
    put('f32', 4, `{value}.y`)
  elseif kind == 'vec3' then
    -- `value` is a local annotated `vector`, so native code lowers this to three stores.
    table.insert(lines, `{value}:writef32x3(b, {at(offset)})`)
  elseif kind == 'vec4' or kind == 'mat2' then
    for i = 1, 4 do
      put('f32', (i - 1) * 4, `{value}[{i}]`)
    end
  elseif kind == 'quat' then
    put('f32', 0, `{value}[4]`)
    for i = 1, 3 do
      put('f32', i * 4, `{value}[{i}]`)
    end
  elseif kind == 'mat3' then
    for row = 1, 3 do
      table.insert(lines, `local {value}{row}: vector = {value}[{row}]`)
      table.insert(lines, `{value}{row}:writef32x3(b, {at(offset + (row - 1) * 12)})`)
    end
  elseif kind == 'tri' then
    put('u16', 0, `{value}.x`)
    put('u16', 2, `{value}.y`)
    put('u16', 4, `{value}.z`)
  elseif kind == 'u16f32' then
    put('u16', 0, `{value}.x`)
    put('f32', 2, `{value}.y`)
  elseif kind == 'f32x2' then
    put('f32', 0, `{value}[1]`)
    put('f32', 4, `{value}[2]`)
  elseif kind == 'u32x3' then
    for i = 1, 3 do
      put('u32', (i - 1) * 4, `{value}[{i}]`)
    end
  elseif kind == 'u8x4' then
    for i = 1, 4 do
      put('u8', i - 1, `{value}[{i}]`)
    end
  else
    error(`no element writer for {kind}`)
  end

  return lines
end

--- Source text with indentation. Every block gets a blank line before and after it, which
--- the structural style asks for between compound statements, whatever StyLua later folds.
type Out = { lines: { string }, depth: number, pending: boolean }

local function blank(out: Out)
  local last = out.lines[#out.lines]
  if last and last ~= '' then table.insert(out.lines, '') end
end

local function opener(line: string?): boolean
  if not line then return true end

  local code = string.gsub(line, '^%s+', '')
  return string.sub(code, -4) == 'then'
    or string.sub(code, -2) == 'do'
    or string.sub(code, -1) == '{'
    or string.sub(code, 1, 9) == 'function '
    or string.sub(code, 1, 15) == 'local function '
    or code == 'else'
end

local function emit(out: Out, line: string)
  if out.pending then
    out.pending = false
    blank(out)
  end

  table.insert(out.lines, if line == '' then '' else string.rep('  ', out.depth) .. line)
end

--- A statement StyLua may wrap over several lines, set apart like a block.
local function spaced(out: Out, line: string)
  out.pending = false
  if not opener(out.lines[#out.lines]) then blank(out) end

  emit(out, line)
  out.pending = true
end

local function open(out: Out, line: string)
  out.pending = false
  if not opener(out.lines[#out.lines]) then blank(out) end

  emit(out, line)
  out.depth += 1
end

--- Switches the open `if` block to its `else` branch.
local function otherwise(out: Out)
  out.pending = false
  table.insert(out.lines, string.rep('  ', out.depth - 1) .. 'else')
end

local function close(out: Out, line: string?)
  out.depth -= 1
  out.pending = false
  table.insert(out.lines, string.rep('  ', out.depth) .. (line or 'end'))
  out.pending = true
end

local function isStruct(kind: string): boolean return Schema.Structs[kind] ~= nil end

local function isCustom(kind: string): boolean return string.sub(kind, 1, 7) == 'custom:' end

local function customName(kind: string): string return string.sub(kind, 8) end

local function isHidden(field: Field): boolean return string.sub(field[1], 1, 1) == '_' end

--- Lists of these are array views of the file's bytes (`array.luau`), not tables.
local ArrayKinds: { [string]: boolean } = {
  u8 = true,
  u16 = true,
  i32 = true,
  f32 = true,
  vec2 = true,
  vec3 = true,
  vec4 = true,
  quat = true,
  tri = true,
  u16f32 = true,
  f32x2 = true,
  u32x3 = true,
  u8x4 = true,
  link = true,
}

--- The array kind a list of `kind` reads as: links are their raw i32 indices, -1 for null.
local function arrayKind(kind: string): string return if kind == 'link' then 'i32' else kind end

local function isArray(field: Field): boolean
  return (field.list ~= nil or field.count ~= nil) and ArrayKinds[field[2] :: string] == true
end

--- A field is fixed-size when it sits in a run of constant offsets: one element, or `fixed` of
--- them, with no condition.
local function fixedSize(field: Field): number?
  local kind = field[2]
  if not kind or field.when or field.list or field.count then return nil end

  local size = sizeOf(kind)
  if not size then return nil end

  return size * (field.fixed or 1)
end

--- Whether a field from `from` on names `name` in an expression: its count, its scanner's count,
--- its condition, value, or arguments.
local function referenced(name: string, fields: { Field }, from: number): boolean
  local pattern = `%f[%w_]{name}%f[^%w_]`
  for i = from, #fields do
    local field = fields[i]
    local sources = { field.count, field.scanCount, field.when, field.expr, field.args }
    for _, source in sources do
      if string.find(source, pattern) then return true end
    end
  end

  return false
end

local function hasLinks(definition: Definition, seen: { [string]: boolean }?): boolean
  local visited: { [string]: boolean } = seen or {}
  for _, field in definition.fields do
    local kind = field[2]
    if kind == 'link' or kind == 'custom:textureMaps' or kind == 'custom:textureSource' then
      return true
    end

    if kind and isStruct(kind) and not visited[kind] then
      visited[kind] = true
      if hasLinks(Schema.Structs[kind], visited) then return true end
    end
  end

  return false
end

-- Reading.

--- A record's fields and its bases', root first; a struct's own.
local function flatten(definition: Definition): { Field }
  local chain = { definition }
  while chain[1].base do
    local base = chain[1].base :: string
    local found
    for _, entry in Schema.Records do
      if entry.name == base then found = entry.definition end
    end

    table.insert(chain, 1, found or error(`unknown base {base}`))
  end

  local fields, seen = {}, {}
  for _, link in chain do
    for _, field in link.fields do
      if seen[field[1]] then error(`field {field[1]} appears twice in one record`) end

      seen[field[1]] = true
      table.insert(fields, field)
    end
  end

  return fields
end

--- Reads every field into a local, then builds the record in one constructor, so its table is
--- sized once. `typed` puts the type name, the reader's third argument, in it. `fill` writes the
--- fields into `into` instead, refilling the array views, matrices, and structs it already holds,
--- so reading many records allocates little.
local function emitRead(out: Out, fields: { Field }, typed: boolean, fill: boolean?)
  local offset = 0
  local function flush()
    if offset == 0 then return end

    emit(out, `p += {offset}`)
    offset = 0
  end

  for index, field in fields do
    local name, kind = field[1], field[2]
    local size = fixedSize(field)
    if field.expr then
      emit(out, `local {name} = {field.expr}`)
    elseif size then
      local value
      if field.fixed then
        local parts = {}
        local each = sizeOf(kind) :: number
        for i = 0, field.fixed - 1 do
          table.insert(parts, readElement(kind, offset + i * each))
        end

        value = `\{ {table.concat(parts, ', ')} }`
      else
        value = readElement(kind, offset)
      end

      if kind == 'mat3' and not field.fixed then
        -- Exactly identity's bits read as the shared, frozen identity: most rotations are.
        local tests = {}
        for i = 0, 8 do
          local bits = if i % 4 == 0 then '0x3f800000' else '0'
          table.insert(tests, `buffer.readu32(b, {at(offset + i * 4)}) == {bits}`)
        end

        emit(out, `local {name} = Identity`)
        open(out, `if not ({table.concat(tests, ' and ')}) then`)
        local rows = {}
        for row = 0, 2 do
          local o = offset + row * 12
          table.insert(rows, `vector.create({f32(o)}, {f32(o + 4)}, {f32(o + 8)})`)
        end

        if fill then
          emit(out, `local reused = into.{name}`)
          open(out, 'if reused and reused ~= Identity then')
          for row = 1, 3 do
            emit(out, `reused[{row}] = {rows[row]}`)
          end

          emit(out, `{name} = reused`)
          otherwise(out)
        end

        spaced(out, `{name} = \{ {table.concat(rows, ', ')} }`)
        if fill then close(out) end

        close(out)
        offset += size
        continue
      end

      if fill and Inline[kind] and not field.fixed then
        emit(out, `local {name} = into.{name}`)
        open(out, `if {name} then`)
        local position = offset
        for _, part in Schema.Structs[kind].fields do
          local partKind = part[2] :: string
          local each = sizeOf(partKind) :: number
          local value = readElement(partKind, position)
          if part.fixed then
            local elements = {}
            for i = 0, part.fixed - 1 do
              table.insert(elements, readElement(partKind, position + i * each))
            end

            value = `\{ {table.concat(elements, ', ')} }`
          end

          emit(out, `{name}.{part[1]} = {value}`)
          position += each * (part.fixed or 1)
        end

        otherwise(out)
        spaced(out, `{name} = {readElement(kind, offset)}`)
        close(out)
        offset += size
        continue
      end

      offset += size
      local put = if string.find(value, '{', 1, true) then spaced else emit
      put(out, `local {name} = {value}`)
    else
      flush()
      local target = name
      if field.when then
        emit(out, `local {target}`)
        open(out, `if {field.when} then`)
      else
        emit(out, `local {target}`)
      end

      if kind == 'string' then
        -- Interned whole (`nif/text.luau`): cut at the first NUL, as OpenMW reads names, and
        -- decoded, once per spelling.
        emit(out, `local {name}Length = buffer.readu32(b, p)`)
        emit(out, `local {name}Token = Spellings:intern(b, p + 4, {name}Length)`)
        emit(out, `{target} = Strings[{name}Token]`)
        open(out, `if not {target} then`)
        emit(out, `{target} = Text.cut(b, p + 4, {name}Length)`)
        emit(out, `Strings[{name}Token] = {target}`)
        close(out)
        emit(out, `p += 4 + {name}Length`)
      elseif isCustom(kind) then
        local args = if field.args then `, {field.args}` else ''
        emit(out, `{target}, p = C.{customName(kind)}.read(b, p{args})`)
      elseif isStruct(kind) and not (field.list or field.count) then
        emit(out, `{target}, p = R.{kind}(b, p)`)
      else
        if field.list then
          emit(out, `local {name}Count = buffer.read{field.list}(b, p)`)
          emit(out, `p += {Sizes[field.list]}`)
        else
          emit(out, `local {name}Count = {field.count}`)
        end

        if isArray(field) then
          -- `open` walked these bytes, so they are in the buffer.
          local arrayType = arrayKind(kind)
          emit(out, `{target} = Empties.{arrayType}`)
          open(out, `if {name}Count > 0 then`)
          if fill then
            -- A view this record type left here before, of this kind and never edited, is refilled.
            emit(out, `local reused = into.{name}`)
            open(
              out,
              `if reused and not reused.owned and getmetatable(reused) == Metas.{arrayType} then`
            )
            emit(out, `reused.buffer, reused.offset, reused.count = b, p, {name}Count`)
            emit(out, `{target} = reused`)
            otherwise(out)
          end

          spaced(
            out,
            `{target} = setmetatable(\{ buffer = b, offset = p, count = {name}Count, stride = {sizeOf(
              kind
            )} }, Metas.{arrayType})`
          )
          if fill then close(out) end

          emit(out, `p += {name}Count * {sizeOf(kind)}`)
          close(out)
        else
          emit(out, `{target} = table.create({name}Count)`)
          open(out, `for i = 1, {name}Count do`)
          if isStruct(kind) and not Inline[kind] then
            emit(out, `{target}[i], p = R.{kind}(b, p)`)
          else
            emit(out, `{target}[i] = {readElement(kind, 0, true)}`)
            emit(out, `p += {sizeOf(kind)}`)
          end

          close(out)
        end
      end

      if field.when then close(out) end
    end

    if field.stash then emit(out, `S.{field.stash} = {name}`) end
  end

  flush()
  if fill then
    emit(out, 'into.type = typeName')
    for _, field in fields do
      if isHidden(field) then continue end

      local name = field[1]
      local single = field[2] == 'link' and not (field.list or field.count or field.fixed)
      emit(
        out,
        if single
          then `into.{name} = if {name} >= 0 then {name} else nil`
          else `into.{name} = {name}`
      )
    end

    emit(out, 'return p')
    return
  end

  local parts = if typed then { 'type = typeName' } else {}
  for _, field in fields do
    if isHidden(field) then continue end

    local name = field[1]
    local single = field[2] == 'link' and not (field.list or field.count or field.fixed)
    table.insert(
      parts,
      if single then `{name} = if {name} >= 0 then {name} else nil` else `{name} = {name}`
    )
  end

  spaced(out, `return \{ {table.concat(parts, ', ')} }, p`)
end

-- Scanning: the reader's walk, keeping only what later counts need and the links.

local function emitScan(out: Out, definition: Definition)
  local fields = definition.fields
  local offset = 0
  local function flush()
    if offset == 0 then return end

    emit(out, `p += {offset}`)
    offset = 0
  end

  for index, field in fields do
    local name, kind = field[1], field[2]
    local needsLocal = isHidden(field) or referenced(name, fields, index + 1)
    local size = fixedSize(field)
    if field.expr then
      emit(out, `local {name} = {field.expr}`)
    elseif size then
      if needsLocal then emit(out, `local {name} = {readElement(kind, offset)}`) end

      if kind == 'link' then
        local count = field.fixed or 1
        for i = 0, count - 1 do
          -- `scanLink`, inline: a link is listed when it isn't -1.
          local position = at(offset + i * 4)
          if i > 0 then blank(out) end

          open(out, `if buffer.readi32(b, {position}) >= 0 then`)
          emit(out, 'n += 1')
          emit(out, `L[n] = buffer.readi32(b, {position})`)
          close(out)
        end
      end

      offset += size
    else
      flush()
      if field.when then open(out, `if {field.when} then`) end

      if kind == 'string' then
        emit(out, `p += 4 + buffer.readu32(b, p)`)
      elseif isCustom(kind) then
        local args = if field.args then `, {field.args}` else ''
        emit(out, `p, n = C.{customName(kind)}(b, p, L, n{args})`)
      elseif isStruct(kind) and not (field.list or field.count) then
        emit(out, `p, n = Sc.{kind}(b, p, L, n)`)
      else
        local count
        if field.list then
          emit(out, `local {name}Count = buffer.read{field.list}(b, p)`)
          emit(out, `p += {Sizes[field.list]}`)
          count = `{name}Count`
        else
          count = field.scanCount or field.count :: string
        end

        if referenced(`{name}At`, fields, index + 1) then emit(out, `local {name}At = p`) end

        if kind == 'link' then
          open(out, `for _ = 1, {count} do`)
          emit(out, 'local link = buffer.readi32(b, p)')
          open(out, 'if link >= 0 then')
          emit(out, 'n += 1')
          emit(out, 'L[n] = link')
          close(out)
          emit(out, '')
          emit(out, 'p += 4')
          close(out)
        elseif isStruct(kind) and not Inline[kind] then
          open(out, `for _ = 1, {count} do`)
          emit(out, `p, n = Sc.{kind}(b, p, L, n)`)
          close(out)
        else
          emit(out, `p += ({count}) * {sizeOf(kind)}`)
        end
      end

      if field.when then close(out) end
    end

    if field.stash then emit(out, `S.{field.stash} = {name}`) end
  end

  flush()
end

-- Writing: fixed fields in runs, one reservation per run.

--- A writer keeps the output's buffer, position, and length in locals `b`, `p`, and `n`, and hands
--- them back to `w` only around calls that write through it.

--- Makes room for `size` more bytes at `p`, calling out only when the buffer must grow.
local function reserve(size: string): string
  return `if p + {size} > n then w.p = p Writer.reserve(w, {size}) b, n = w.b, w.n end`
end

--- A call that writes through `w`, with the locals handed over and taken back.
local function emitCall(out: Out, call: string)
  emit(out, 'w.p = p')
  emit(out, call)
  emit(out, 'b, p, n = w.b, w.p, w.n')
end

local function emitWriteRun(out: Out, run: { Field })
  local total = 0
  for _, field in run do
    total += fixedSize(field) :: number
  end

  emit(out, reserve(tostring(total)))
  local offset = 0
  for _, field in run do
    local name, kind = field[1], field[2]
    local value = if isHidden(field) then field.save :: string else `r.{name}`
    if field.fixed then
      local each = sizeOf(kind) :: number
      emit(out, `local {name} = {value}`)
      for i = 0, field.fixed - 1 do
        for _, line in writeElement(kind, `{name}[{i + 1}]`, offset + i * each) do
          emit(out, line)
        end

        local check = nanCheck(kind, `{name}[{i + 1}]`)
        if check then emit(out, check) end
      end
    else
      local check = nanCheck(kind, name)
      local lines = writeElement(kind, value, offset)
      local reused = kind == 'vec3' or kind == 'link' or string.sub(kind, 1, 5) == 'enum:'
      if #lines > 1 or check or reused then
        emit(
          out,
          if kind == 'vec3' then `local {name}: vector = {value}` else `local {name} = {value}`
        )
        lines = writeElement(kind, name, offset)
      end

      for _, line in lines do
        emit(out, line)
      end

      if check then emit(out, check) end
    end

    offset += fixedSize(field) :: number
  end

  emit(out, `p += {total}`)
end

local function emitWriteField(out: Out, field: Field)
  local name, kind = field[1], field[2]
  if field.when then open(out, `if r.{name} ~= nil then`) end

  if kind == 'string' then
    open(out, 'do')
    emit(out, `local text = Text.encode(r.{name})`)
    emit(out, 'local length = #text')
    emit(out, reserve '4 + length')
    emit(out, 'buffer.writeu32(b, p, length)')
    emit(out, 'buffer.writestring(b, p + 4, text)')
    emit(out, 'p += 4 + length')
    close(out)
  elseif isCustom(kind) then
    emitCall(out, `C.{customName(kind)}.write(w, r.{name}, map)`)
  elseif isStruct(kind) and not (field.list or field.count) then
    emitCall(out, `W.{kind}(w, r.{name}, map)`)
  else
    open(out, 'do')
    emit(out, `local values = r.{name}`)
    local count = if isArray(field) then 'values.count' else '#values'
    local each = sizeOf(kind)
    local prefix = if field.list then Sizes[field.list] else 0
    if isArray(field) and kind == 'link' then
      emit(out, reserve(`{prefix} + {count} * 4`))
    elseif isArray(field) then
      emit(out, `local length = {count} * values.stride`)
      emit(out, reserve(`{prefix} + length`))
    elseif each then
      emit(out, reserve(`{prefix} + {count} * {each}`))
    elseif prefix > 0 then
      emit(out, reserve(tostring(prefix)))
    end

    if field.list then
      emit(out, `buffer.write{field.list}(b, p, {count})`)
      emit(out, `p += {prefix}`)
    end

    if isArray(field) and kind == 'link' then
      emit(out, 'local source, offset = values.buffer, values.offset')
      open(out, `for i = 0, {count} - 1 do`)
      emit(out, 'local link = buffer.readi32(source, offset + i * 4)')
      emit(out, 'buffer.writei32(b, p, if link >= 0 then map[link] or -1 else -1)')
      emit(out, 'p += 4')
      close(out)
    elseif isArray(field) then
      emit(out, 'buffer.copy(b, p, values.buffer, values.offset, length)')
      emit(out, 'p += length')
    elseif each then
      open(out, 'for _, value in values do')
      for _, line in writeElement(kind, 'value', 0) do
        emit(out, line)
      end

      emit(out, `p += {each}`)
      close(out)
    else
      open(out, 'for _, value in values do')
      emitCall(out, `W.{kind}(w, value, map)`)
      close(out)
    end

    close(out)
  end

  if field.when then close(out) end
end

local function emitWrite(out: Out, definition: Definition)
  local body: Out = { lines = {}, depth = out.depth, pending = false }
  local run: { Field } = {}
  local function flush()
    if #run == 0 then return end

    emitWriteRun(body, run)
    run = {}
  end

  for _, field in definition.fields do
    if field.expr then continue end

    if fixedSize(field) then
      table.insert(run, field)
      continue
    end

    flush()
    if isHidden(field) then error(`hidden variable field {field[1]}`) end

    emitWriteField(body, field)
  end

  flush()
  if #body.lines == 0 then return end

  -- Keep only the locals the body reads, so none is declared and never used.
  local text = table.concat(body.lines, '\n')
  local names = { 'b', 'p', 'n' }
  if not string.find(text, '%(b, ') then table.remove(names, 1) end

  if not string.find(text, '> n then') then table.remove(names) end

  local list = table.concat(names, ', ')
  local values = {}
  for _, name in names do
    table.insert(values, `w.{name}`)
  end

  local take = `{list} = {table.concat(values, ', ')}`
  emit(out, `local {take}`)
  for _, line in body.lines do
    if string.find(line, '^%s*b, p, n = w%.b, w%.p, w%.n$') then
      line = string.gsub(line, 'b, p, n = w%.b, w%.p, w%.n', take)
    end

    table.insert(out.lines, line)
  end

  emit(out, 'w.p = p')
end

-- Collecting the links of a decoded table.

local function emitLinks(out: Out, definition: Definition)
  for _, field in definition.fields do
    local name, kind = field[1], field[2]
    if isHidden(field) or not kind then continue end

    if kind == 'link' and not (field.list or field.count or field.fixed) then
      emit(out, `local {name} = r.{name}`)
      open(out, `if {name} and {name} >= 0 then`)
      emit(out, 'n += 1')
      emit(out, `L[n] = {name}`)
      close(out)
    elseif kind == 'link' then
      emit(out, `local {name} = r.{name}`)
      open(out, `for i = 0, {name}.count - 1 do`)
      emit(out, `local value = buffer.readi32({name}.buffer, {name}.offset + i * 4)`)
      open(out, 'if value >= 0 then')
      emit(out, 'n += 1')
      emit(out, 'L[n] = value')
      close(out)
      close(out)
    elseif kind == 'custom:textureMaps' or kind == 'custom:textureSource' then
      emit(out, `n = C.{customName(kind)}.links(r.{name}, L, n)`)
    elseif isStruct(kind) and hasLinks(Schema.Structs[kind]) then
      if field.list or field.count then
        open(out, `for _, value in r.{name} do`)
        emit(out, `n = Lk.{kind}(value, L, n)`)
        close(out)
      else
        emit(out, `n = Lk.{kind}(r.{name}, L, n)`)
      end
    else
      continue
    end

    blank(out)
  end
end

-- The modules.

local function emitFunction(out: Out, header: string, body: () -> (), footer: string)
  open(out, header)
  local before = #out.lines
  body()
  if #out.lines > before and out.lines[#out.lines] ~= '' then blank(out) end

  emit(out, footer)
  close(out)
  blank(out)
end

local function lines(out: Out, list: { string })
  for _, line in list do
    table.insert(out.lines, line)
  end
end

local function sortedKeys<T>(map: { [string]: T }): { string }
  local keys = {}
  for key in map do
    table.insert(keys, key)
  end

  table.sort(keys)
  return keys
end

local Generated = '-- Generated by generator/generate.luau from generator/schema.luau. Do not edit.'

--- The scanners: what `open` runs over every record, and all it loads.
local function scanModule(): string
  local out: Out = { lines = {}, depth = 0, pending = false }
  lines(out, {
    '--!strict',
    '-- SPDX-License-Identifier: MIT OR Apache-2.0',
    Generated,
    '',
    'local C = require \'./custom_scan\'',
    '',
    'type Links = { number }',
    'export type Scanner = (buffer, number, Links, number) -> (number, number)',
    '',
    '--- Values a base record leaves for its derived records, which are scanned by another function.',
    'local S: { [string]: number } = {}',
    '',
    '--- Scanners by type name.',
    'local Sc: { [string]: Scanner } = {}',
    '',
  })

  local Bases: { [string]: Definition } = {}
  for _, entry in Schema.Records do
    Bases[entry.name] = entry.definition
  end

  local function define(name: string, definition: Definition)
    local base = definition.base
    if base and #definition.fields == 0 then
      emit(out, `Sc.{name} = Sc.{base}`)
      blank(out)
      return
    end

    emitFunction(
      out,
      `function Sc.{name}(b: buffer, p: number, L: Links, n: number): (number, number)`,
      function()
        -- The base records' fields, inline from the root down: a scan is one call per record.
        local chain = {}
        local ancestor = base
        while ancestor do
          local found = Bases[ancestor]
          table.insert(chain, 1, found)
          ancestor = found.base
        end

        for _, inherited in chain do
          emitScan(out, inherited)
        end

        emitScan(out, definition)
      end,
      'return p, n'
    )
  end

  for _, name in sortedKeys(Schema.Structs) do
    if not Inline[name] then define(name, Schema.Structs[name]) end
  end

  local names = {}
  for _, entry in Schema.Records do
    define(entry.name, entry.definition)
    table.insert(names, `'{entry.name}'`)
  end

  emit(out, '--- Every record type name, in the order the Rust `NiType` lists them.')
  emit(out, `local RecordNames = table.freeze \{ {table.concat(names, ', ')} }`)
  blank(out)
  emit(out, 'return table.freeze { scan = Sc, names = RecordNames }')
  return table.concat(out.lines, '\n') .. '\n'
end

--- A codec module's header: its requires and locals, only those `body` uses, so the analyzer
--- has nothing to call unused. `prefix` is where the sibling modules are, from the module.
local function codecModule(body: { string }, prefix: string, locals: { string }?): string
  local text = table.concat(body, '\n')
  local function uses(name: string): boolean
    return string.find(text, `%f[%w_]{name}%f[^%w_]`) ~= nil
  end

  local out = {
    '--!nonstrict',
    '-- SPDX-License-Identifier: MIT OR Apache-2.0',
    Generated,
    '-- Not strict: the checker does not know `vector:writef32x3`, which jess installs.',
    '',
  }

  local modules = {
    { 'Array', 'array' },
    { 'C', 'custom' },
    { 'Enums', 'enums' },
    { 'Structs', 'structs' },
    { 'Text', 'text' },
    { 'Types', 'types' },
    { 'Writer', 'writer' },
  }

  local needs = {
    Array = uses 'Array' or uses 'Metas' or uses 'Empties',
    C = uses 'C' or uses 'Identity',
    Enums = uses 'Names' or uses 'Values',
    Structs = uses 'R' or uses 'W' or uses 'Lk' or uses 'S',
    Text = uses 'Spellings' or uses 'Text',
    Types = true,
    Writer = true,
  }

  for _, module in modules do
    if needs[module[1]] then
      table.insert(out, `local {module[1]} = require '{prefix}{module[2]}'`)
    end
  end

  for _, line in
    {
      '',
      'type Record = Types.Record',
      'type Links = { number }',
      'type Map = { [number]: number }',
      'type Writer = Writer.Writer',
      '',
    }

  do
    table.insert(out, line)
  end

  if uses 'Names' and uses 'Values' then
    table.insert(out, 'local Names, Values = Enums.names, Enums.values')
  elseif uses 'Names' then
    table.insert(out, 'local Names = Enums.names')
  elseif uses 'Values' then
    table.insert(out, 'local Values = Enums.values')
  end

  if uses 'Metas' then table.insert(out, 'local Metas, Empties = Array.metas, Array.empty') end

  if uses 'Identity' then table.insert(out, 'local Identity = C.identity') end

  if uses 'Spellings' then
    table.insert(out, 'local Spellings: dream_intern_Pool = Text.pool')
    table.insert(out, 'local Strings = Text.decoded')
  end

  if uses 'S' then
    table.insert(
      out,
      '--- Values one field leaves for a later one, read by an expression; shared, since a'
    )
    table.insert(out, '--- struct reads what its record left.')
    table.insert(out, 'local S = Structs.stash')
  end

  for _, line in locals or {} do
    table.insert(out, line)
  end

  table.insert(out, '')
  for _, line in body do
    table.insert(out, line)
  end

  return table.concat(out, '\n') .. '\n'
end

--- The values records hold inside them, shared by the record modules.
local function structsModule(): string
  local out: Out = { lines = {}, depth = 0, pending = false }
  lines(out, { 'local R, W, Lk = {}, {}, {}', '' })

  for _, name in sortedKeys(Schema.Structs) do
    if Inline[name] then continue end

    local definition = Schema.Structs[name]
    open(out, `function R.{name}(b: buffer, p: number): (Types.{name}, number)`)
    emitRead(out, definition.fields, false)
    close(out)
    blank(out)
    emitFunction(
      out,
      `function W.{name}(w: Writer, r: Types.{name}, map: Map)`,
      function() emitWrite(out, definition) end,
      'return'
    )
    emitFunction(
      out,
      `function Lk.{name}(r: Types.{name}, L: Links, n: number): number`,
      function() emitLinks(out, definition) end,
      'return n'
    )
  end

  emit(out, 'return table.freeze { read = R, write = W, links = Lk, stash = S }')
  local body = out.lines
  -- The struct tables and the stash are this module's own, not `Structs`'.
  local text = codecModule(body, './')
  text = string.gsub(text, 'local S = Structs.stash', 'local S = {}')
  return (string.gsub(text, 'local Structs = require \'./structs\'\n', ''))
end

--- One record type's reader, writer, and link collector, each over its fields and its bases',
--- loaded the first time a record of the type is decoded.
local function recordModule(definition: Definition): string
  local fields = flatten(definition)
  local flat: Definition = { fields = fields }
  local out: Out = { lines = {}, depth = 0, pending = false }
  open(out, 'local function read(b: buffer, p: number, typeName: string): (Record, number)')
  emitRead(out, fields, true)
  close(out)
  blank(out)
  open(out, 'local function fill(b: buffer, p: number, typeName: string, into: Record): number')
  emitRead(out, fields, true, true)
  close(out)
  blank(out)
  emitFunction(
    out,
    'local function write(w: Writer, r: Record, map: Map)',
    function() emitWrite(out, flat) end,
    'return'
  )
  emitFunction(
    out,
    'local function links(r: Record, L: Links, n: number): number',
    function() emitLinks(out, flat) end,
    'return n'
  )
  emit(out, 'return table.freeze { read = read, fill = fill, write = write, links = links }')
  local text = table.concat(out.lines, '\n')
  local locals = {}
  for _, name in { 'R', 'W', 'Lk' } do
    if string.find(text, `%f[%w_]{name}%.`) then table.insert(locals, name) end
  end

  local declare = {}
  if #locals > 0 then
    local sources = { R = 'Structs.read', W = 'Structs.write', Lk = 'Structs.links' }
    local values = {}
    for _, name in locals do
      table.insert(values, sources[name])
    end

    declare = { `local {table.concat(locals, ', ')} = {table.concat(values, ', ')}` }
  end

  return codecModule(out.lines, '../', declare)
end

--- The record types that have a module: those with fields of their own, or none to inherit.
local function moduleOf(name: string): string
  for _, entry in Schema.Records do
    if entry.name ~= name then continue end

    local definition = entry.definition
    if definition.base and #definition.fields == 0 then
      return moduleOf(definition.base :: string)
    end

    return name
  end

  error(`unknown record {name}`)
end

--- The loader: each record type's module, required the first time it is asked for.
local function loadModule(): string
  local out: Out = { lines = {}, depth = 0, pending = false }
  lines(out, {
    '--!strict',
    '-- SPDX-License-Identifier: MIT OR Apache-2.0',
    Generated,
    '',
    'local Types = require \'./types\'',
    'local Writer = require \'./writer\'',
    '',
    '--- One record type\'s codec, from `records/`.',
    'export type Codec = {',
    '  read read: (b: buffer, p: number, typeName: string) -> (Types.Record, number),',
    '  read fill: (b: buffer, p: number, typeName: string, into: Types.Record) -> number,',
    '  read write: (w: Writer.Writer, r: Types.Record, map: { [number]: number }) -> (),',
    '  read links: (r: Types.Record, L: { number }, n: number) -> number,',
    '}',
    '',
    'local Load: { [string]: () -> Codec } = {}',
  })

  for _, entry in Schema.Records do
    local module = moduleOf(entry.name)
    if module == entry.name then
      spaced(
        out,
        `Load.{entry.name} = function(): Codec return require('./records/{entry.name}') end`
      )
    end
  end

  blank(out)
  for _, entry in Schema.Records do
    local module = moduleOf(entry.name)
    if module ~= entry.name then emit(out, `Load.{entry.name} = Load.{module}`) end
  end

  blank(out)
  lines(out, {
    '--- Codecs by record type name: a plain read once a type\'s module has loaded, which the first',
    '--- read of any name `scan.luau` knows does.',
    'local Codecs: { [string]: Codec } = setmetatable({}, {',
    '  __index = function(codecs: { [string]: Codec }, name: string): Codec',
    '    local codec = Load[name]()',
    '    rawset(codecs, name, codec)',
    '    return codec',
    '  end,',
    '})',
    '',
    'return Codecs',
  })
  return table.concat(out.lines, '\n') .. '\n'
end

local function enums(): string
  local out: Out = { lines = {}, depth = 0, pending = false }
  for _, line in
    {
      '--!strict',
      '-- SPDX-License-Identifier: MIT OR Apache-2.0',
      '-- Generated by generator/generate.luau from generator/schema.luau. Do not edit.',
      '',
    }

  do
    table.insert(out.lines, line)
  end

  open(out, 'local Names: { [string]: { [number]: string } } = {')
  for _, name in sortedKeys(Schema.Enums) do
    local parts = {}
    for _, entry in Schema.Enums[name] do
      table.insert(parts, `[{entry[2]}] = '{entry[1]}'`)
    end

    spaced(out, `{name} = table.freeze \{ {table.concat(parts, ', ')} },`)
  end

  close(out, '}')
  blank(out)
  emit(out, 'local Values: { [string]: { [string]: number } } = {}')
  open(out, 'for name, names in Names do')
  emit(out, 'local values: { [string]: number } = {}')
  open(out, 'for value, label in names do')
  emit(out, 'values[label] = value')
  close(out)
  blank(out)
  emit(out, 'Values[name] = table.freeze(values)')
  close(out)
  blank(out)
  emit(out, 'return table.freeze { names = table.freeze(Names), values = table.freeze(Values) }')
  return table.concat(out.lines, '\n') .. '\n'
end

-- Types: what a decoded record holds, field by field.

local KindTypes: { [string]: string } = {
  u8 = 'number',
  u16 = 'number',
  i16 = 'number',
  u32 = 'number',
  i32 = 'number',
  f32 = 'number',
  bool8 = 'boolean',
  string = 'string',
  link = 'number',
  vec2 = 'vector',
  vec3 = 'vector',
  vec4 = '{ number }',
  quat = '{ number }',
  mat2 = '{ number }',
  mat3 = '{ vector }',
  tri = 'vector',
  u16f32 = 'vector',
  f32x2 = '{ number }',
  u32x3 = '{ number }',
  u8x4 = '{ number }',
}

local KindDocs: { [string]: string } = {
  link = 'A record index.',
  vec2 = 'The z component is 0.',
  vec4 = '`{ r, g, b, a }`, or `{ x, y, z, w }`.',
  quat = '`{ x, y, z, w }`; the file stores w first.',
  mat2 = 'Column by column, as stored.',
  mat3 = 'The rows, as stored; a shared frozen identity when the file stores exactly that.',
  tri = 'Three vertex indices.',
}

local CustomTypes: { [string]: string } = {
  floatKeys = 'FloatKeys',
  morphKeys = 'FloatKeys',
  posKeys = 'PosKeys',
  rotKeys = 'RotKeys',
  colorKeys = 'ColorKeys',
  boundingVolume = 'BoundingVolume',
  textureMaps = 'TextureMaps',
  textureSource = 'TextureSource',
  sequenceTarget = 'SequenceTarget',
  nameControllerPairs = '{ { string | number } }',
  sharedNormals = '{ U16Array }',
  uvSets = '{ Vec2Array }',
}

local Prelude = [[
--- A float curve's keys, under the one name their interpolation uses.
export type FloatKeys = {
  LinKey: FloatLinKeys?,
  BezKey: FloatBezKeys?,
  TCBKey: FloatTcbKeys?,
}

--- A position curve's keys.
export type PosKeys = {
  LinKey: PosLinKeys?,
  BezKey: PosBezKeys?,
  TCBKey: PosTcbKeys?,
}

--- A rotation curve's keys: quaternions `{ x, y, z, w }`, or three Euler angle curves.
export type RotKeys = {
  LinKey: RotLinKeys?,
  BezKey: RotLinKeys?,
  TCBKey: RotTcbKeys?,
  EulerKey: { axisOrder: AxisOrder, axes: { { keys: FloatKeys } } }?,
}

--- A color curve's keys, linear only.
export type ColorKeys = { LinKey: ColorLinKeys }

--- A bounding volume: one of a sphere, an oriented box, or a union of volumes.
export type BoundingVolume = {
  boundData: {
    NiSphereBV: { bound: NiBound }?,
    NiBoxBV: { center: vector, axis: { vector }, extents: vector }?,
    NiUnionBV: { boundingVolumes: { BoundingVolume } }?,
  },
}

--- One texture map in a texturing property's slot.
export type TextureMap = {
  texture: number?,
  clampMode: ClampMode,
  filterMode: FilterMode,
  textureIndex: number,
  ps2L: number,
  ps2K: number,
  unknownFlag1: number,
  unknownFlag2: number,
}

--- The bump map's slot adds luma and a 2x2 displacement, column by column.
export type BumpMap = TextureMap & { lumaScale: number, lumaOffset: number, displacement: { number } }

--- A texturing property's maps by slot. `slots` is how many the file lists; a save lists at
--- least that many, and enough for every map. A decal slot with no map is `false`.
export type TextureMaps = {
  slots: number,
  base: TextureMap?,
  dark: TextureMap?,
  detail: TextureMap?,
  gloss: TextureMap?,
  glow: TextureMap?,
  bump: BumpMap?,
  decals: { TextureMap | false }?,
}

--- Where a texture's pixels are: a file, or an NiPixelData record.
export type TextureSource = { external: string?, internal: number? }

--- What a keyframe sequence animates: a file, or two numbers.
export type SequenceTarget = { External: string?, Internal: { number }? }
]]

--- Each array kind's type name.
local ArrayTypeNames: { [string]: string } = {}
for _, kind in Schema.ArrayKinds do
  ArrayTypeNames[kind.kind] = kind.type
end

local function fieldType(field: Field): string
  local kind = field[2] :: string
  local base
  if string.sub(kind, 1, 5) == 'enum:' then
    base = string.sub(kind, 6)
  elseif isCustom(kind) then
    base = CustomTypes[customName(kind)]
  elseif isStruct(kind) then
    base = kind
  else
    base = KindTypes[kind]
  end

  if isArray(field) then
    local name = ArrayTypeNames[arrayKind(kind)]
    return if field.when then `{name}?` else name
  end

  if field.list or field.count or field.fixed then return `\{ {base} }` end

  if field.when or kind == 'link' then return `{base}?` end

  return base
end

local function emitFields(out: Out, definition: Definition)
  for _, field in definition.fields do
    if isHidden(field) then continue end

    local kind = field[2] :: string
    local doc = field.doc or KindDocs[kind]
    if isArray(field) and kind == 'link' then
      doc = 'Array view of `i32` record indices; -1 for a null link.'
    elseif isArray(field) then
      doc = `Array view of \`{kind}\` elements.{if field.doc then ' ' .. field.doc else ''}`
    elseif kind == 'link' then
      doc = 'A record index, nil when null.'
    end

    if doc then emit(out, `--- {doc}`) end

    emit(out, `{field[1]}: {fieldType(field)},`)
  end
end

local function types(): string
  local out: Out = { lines = {}, depth = 0, pending = false }
  for _, line in
    {
      '--!strict',
      '-- SPDX-License-Identifier: MIT OR Apache-2.0',
      '-- Generated by generator/generate.luau from generator/schema.luau. Do not edit.',
      '',
      '--[[',
      'What a decoded Morrowind NIF record holds. A record type is its base type and its own fields;',
      '`type` names the record type. `Record` is any of them: test `record.type` to narrow one.',
      ']]',
      '',
      'local ArrayTypes = require \'./array_types\'',
      '',
    }

  do
    table.insert(out.lines, line)
  end

  emit(out, '--- Views of bulk data in the bytes it was read from; see `array.luau`.')
  emit(out, 'export type Array = ArrayTypes.Array')
  for _, kind in Schema.ArrayKinds do
    emit(out, `export type {kind.type} = ArrayTypes.{kind.type}`)
  end

  blank(out)
  for _, name in sortedKeys(Schema.Enums) do
    local labels = {}
    for _, entry in Schema.Enums[name] do
      table.insert(labels, `'{entry[1]}'`)
    end

    emit(out, '--- A value not in the list is kept as its number.')
    emit(out, `export type {name} = {table.concat(labels, ' | ')} | number`)
    blank(out)
  end

  for line in string.gmatch(Prelude, '[^\n]*\n') do
    table.insert(out.lines, string.sub(line, 1, -2))
  end

  for _, name in sortedKeys(Schema.Structs) do
    local definition = Schema.Structs[name]
    if definition.doc then emit(out, `--- {definition.doc}`) end

    open(out, `export type {name} = \{`)
    emitFields(out, definition)
    close(out, '}')
  end

  for _, entry in Schema.Records do
    local base = entry.definition.base
    emit(out, `--- {entry.name}{if base then `: an {base}, and its own fields` else ''}.`)
    open(out, `export type {entry.name} = \{`)
    emit(out, `type: '{entry.name}',`)
    emitFields(out, { fields = flatten(entry.definition) })
    close(out, '}')
  end

  local names = {}
  for _, entry in Schema.Records do
    table.insert(names, entry.name)
  end

  emit(out, '--- Any record.')
  emit(out, `export type Record = {table.concat(names, ' | ')}`)
  blank(out)
  emit(out, 'return {}')
  return table.concat(out.lines, '\n') .. '\n'
end

-- Arrays: a type and a method table per element kind, from `Schema.ArrayKinds`.

type ArrayKind = Schema.ArrayKind
type ArrayValue = Schema.ArrayValue

local Groups =
  table.freeze { x = true, y = true, z = true, w = true, r = true, g = true, b = true, a = true }

--- A `toTable` element's type.
local function elementType(kind: ArrayKind): string
  local values = kind.values
  if kind.shape == 'value' then return values[1].type end

  if kind.shape == 'list' then return '{ number }' end

  local parts = {}
  local grouped = false
  for _, value in values do
    if kind.shape == 'grouped' and Groups[value.name] then
      grouped = true
      continue
    end

    table.insert(parts, `{value.name}: {value.type}`)
  end

  if grouped then table.insert(parts, 2, 'value: { number }') end

  return `\{ {table.concat(parts, ', ')} }`
end

local function arrayTypes(): string
  local out: Out = { lines = {}, depth = 0, pending = false }
  lines(out, {
    '--!strict',
    '-- SPDX-License-Identifier: MIT OR Apache-2.0',
    Generated,
    '-- The array types, one per element kind, and each kind\'s stride.',
    '',
  })
  local kinds, names = {}, {}
  for _, kind in Schema.ArrayKinds do
    table.insert(kinds, `'{kind.kind}'`)
    table.insert(names, kind.type)
  end

  emit(out, `export type Kind = {table.concat(kinds, ' | ')}`)
  blank(out)
  lines(out, {
    '--- What every array has: the bytes, where element 1 starts, how many elements, and each one\'s',
    '--- size. `owned` is set once `set` has copied the bytes out of the file\'s buffer.',
    'export type ArrayFields = { buffer: buffer, offset: number, count: number, stride: number, owned: boolean? }',
    '',
  })

  for _, kind in Schema.ArrayKinds do
    local returns, params = {}, {}
    for _, value in kind.values do
      table.insert(returns, value.type)
      table.insert(params, `{value.name}: {value.type}`)
    end

    local result = if #returns == 1 then returns[1] else `({table.concat(returns, ', ')})`
    emit(out, `--- An array of {kind.doc}.`)
    open(out, `export type {kind.type} = \{`)
    emit(out, 'buffer: buffer,')
    emit(out, 'offset: number,')
    emit(out, 'count: number,')
    emit(out, 'stride: number,')
    emit(out, 'owned: boolean?,')
    emit(out, `kind: '{kind.kind}',`)
    emit(out, `get: (self: {kind.type}, index: number) -> {result},`)
    emit(out, `set: (self: {kind.type}, index: number, {table.concat(params, ', ')}) -> (),`)
    emit(out, `toTable: (self: {kind.type}) -> \{ {elementType(kind)} },`)
    close(out, '}')
  end

  emit(out, `export type Array = {table.concat(names, ' | ')}`)
  blank(out)
  open(out, 'local Strides: { [Kind]: number } = {')
  for _, kind in Schema.ArrayKinds do
    emit(out, `{kind.kind} = {kind.stride},`)
  end

  close(out, '}')
  blank(out)
  emit(out, 'return table.freeze { strides = table.freeze(Strides) }')
  return table.concat(out.lines, '\n') .. '\n'
end

local function readValue(value: ArrayValue): string
  local parts = {}
  for _, component in value.components do
    table.insert(parts, `buffer.read{component.encoding}(b, {at(component.offset)})`)
  end

  if value.type == 'number' then return parts[1] end

  if #parts == 2 then table.insert(parts, '0') end

  return `vector.create({table.concat(parts, ', ')})`
end

local function writeValue(value: ArrayValue): { string }
  local written = {}
  for i, component in value.components do
    local part = if value.type == 'number'
      then value.name
      else `{value.name}.{({ 'x', 'y', 'z' })[i]}`
    table.insert(written, `buffer.write{component.encoding}(bytes, {at(component.offset)}, {part})`)
  end

  return written
end

local function arrayAccess(): string
  local out: Out = { lines = {}, depth = 0, pending = false }
  lines(out, {
    '--!strict',
    '-- SPDX-License-Identifier: MIT OR Apache-2.0',
    Generated,
    '-- What an array does beyond being read in place: `get`, `set`, and `toTable` for each kind,',
    '-- loaded by `array.luau` the first time an array is asked for one.',
    '',
    'local Types = require \'./array_types\'',
    '',
    'type ArrayFields = Types.ArrayFields',
    '',
    '--- A kind\'s name and methods.',
    'type Methods = { [string]: unknown }',
    '',
    '--- Element `index`\'s byte position, checking it is one of the array\'s.',
    'local function at(array: ArrayFields, index: number): number',
    '  if index < 1 or index > array.count or index % 1 ~= 0 then',
    '    error(`index {index} is outside 1..{array.count}`, 3)',
    '  end',
    '',
    '  return array.offset + (index - 1) * array.stride',
    'end',
    '',
    '--- Copies the array\'s bytes out of the file\'s buffer before its first edit.',
    'local function own(array: ArrayFields)',
    '  if array.owned then return end',
    '',
    '  local length = array.count * array.stride',
    '  local bytes = buffer.create(length)',
    '  buffer.copy(bytes, 0, array.buffer, array.offset, length)',
    '  array.buffer, array.offset, array.owned = bytes, 0, true',
    'end',
    '',
  })
  local entries = {}
  for _, kind in Schema.ArrayKinds do
    local name, typeName = kind.type, `Types.{kind.type}`
    local returns, params, reads = {}, {}, {}
    for _, value in kind.values do
      table.insert(returns, value.type)
      table.insert(params, `{value.name}: {value.type}`)
      table.insert(reads, readValue(value))
    end

    local result = if #returns == 1 then returns[1] else `({table.concat(returns, ', ')})`
    open(out, `local {name}: Methods = \{`)
    emit(out, `kind = '{kind.kind}',`)
    close(out, '}')
    open(out, `function {name}.get(array: {typeName}, index: number): {result}`)
    emit(out, 'local b, p = array.buffer, at(array, index)')
    spaced(out, `return {table.concat(reads, ', ')}`)
    close(out)
    open(out, `function {name}.set(array: {typeName}, index: number, {table.concat(params, ', ')})`)
    emit(out, 'own(array)')
    emit(out, 'local bytes, p = array.buffer, at(array, index)')
    for _, value in kind.values do
      for _, line in writeValue(value) do
        emit(out, line)
      end
    end

    close(out)
    open(out, `function {name}.toTable(array: {typeName}): \{ {elementType(kind)} }`)
    emit(out, `local list = table.create(array.count) :: \{ {elementType(kind)} }`)
    emit(out, 'local b = array.buffer')
    open(out, 'for i = 1, array.count do')
    emit(out, 'local p = array.offset + (i - 1) * array.stride')
    if kind.shape == 'value' then
      emit(out, `list[i] = {reads[1]}`)
    elseif kind.shape == 'list' then
      spaced(out, `list[i] = \{ {table.concat(reads, ', ')} }`)
    else
      local parts, group = {}, {}
      for i, value in kind.values do
        if kind.shape == 'grouped' and Groups[value.name] then
          table.insert(group, reads[i])
        else
          table.insert(parts, `{value.name} = {reads[i]}`)
        end
      end

      if #group > 0 then table.insert(parts, 2, `value = \{ {table.concat(group, ', ')} }`) end

      spaced(out, `list[i] = \{ {table.concat(parts, ', ')} }`)
    end

    close(out)
    blank(out)
    emit(out, 'return list')
    close(out)
    table.insert(entries, `{kind.kind} = {name}`)
  end

  open(out, 'local Kinds: { [Types.Kind]: Methods } = {')
  for _, entry in entries do
    emit(out, `{entry},`)
  end

  close(out, '}')
  blank(out)
  emit(out, 'return table.freeze(Kinds)')
  return table.concat(out.lines, '\n') .. '\n'
end

local recordsDir = jess.fs.join(outDir, 'records')
local written: { [string]: boolean } = {}
for _, entry in Schema.Records do
  if moduleOf(entry.name) ~= entry.name then continue end

  local file = `{entry.name}.luau`
  written[file] = true
  jess.fs.write(jess.fs.join(recordsDir, file), recordModule(entry.definition))
end

for _, file in jess.fs.list(recordsDir) do
  if not written[file] then jess.fs.remove(jess.fs.join(recordsDir, file)) end
end

--- Each record type's base, and whether a type is or derives from another.
local function classesModule(): string
  local out = {
    '--!strict',
    '-- SPDX-License-Identifier: MIT OR Apache-2.0',
    Generated,
    '',
    '--- Each record type and the type it derives from.',
    'local Parents: { [string]: string } = {',
  }

  local names = {}
  for _, entry in Schema.Records do
    if entry.definition.base then table.insert(names, entry.name) end
  end

  table.sort(names)
  for _, name in names do
    for _, entry in Schema.Records do
      if entry.name == name then table.insert(out, `  {name} = '{entry.definition.base}',`) end
    end
  end

  for _, line in
    {
      '}',
      '',
      '--- Each type\'s ancestors, itself included, built the first time it is asked about.',
      'local Ancestors: { [string]: { [string]: boolean } } = {}',
      '',
      '--- Whether record type `name` is `class` or derives from it.',
      'local function is(name: string, class: string): boolean',
      '  local set = Ancestors[name]',
      '  if not set then',
      '    set = {}',
      '    local current: string? = name',
      '    while current do',
      '      set[current] = true',
      '      current = Parents[current]',
      '    end',
      '',
      '    Ancestors[name] = set',
      '  end',
      '',
      '  return set[class] == true',
      'end',
      '',
      'return table.freeze { parents = Parents, is = is }',
    }

  do
    table.insert(out, line)
  end

  return table.concat(out, '\n') .. '\n'
end

jess.fs.write(jess.fs.join(outDir, 'classes.luau'), classesModule())
jess.fs.write(jess.fs.join(outDir, 'scan.luau'), scanModule())
jess.fs.write(jess.fs.join(outDir, 'structs.luau'), structsModule())
jess.fs.write(jess.fs.join(outDir, 'load.luau'), loadModule())
jess.fs.write(jess.fs.join(outDir, 'enums.luau'), enums())
jess.fs.write(jess.fs.join(outDir, 'array_types.luau'), arrayTypes())
jess.fs.write(jess.fs.join(outDir, 'array_access.luau'), arrayAccess())
jess.fs.write(jess.fs.join(outDir, 'types.luau'), types())
print(
  `wrote scan, structs, load, enums, types, array_types, array_access, and records/ in {outDir}`
)
