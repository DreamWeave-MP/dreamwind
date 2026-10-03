--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
The multi-version reader's records: every class OpenMW's `components/nif` reads, field by field
in reading order, with the version conditions its `read` functions test. `gamebryo.luau`
documents the steps and turns this into the readers. Class names are OpenMW's (`classes.luau`);
a struct is a value read in place inside a record. Each section follows one OpenMW header.
]]

export type Step = {
  [number]: string?,
  when: string?,
  count: string?,
  list: string?,
  fixed: number?,
  default: string?,
  expr: string?,
  skip: (number | string)?,
  ret: string?,
  check: string?,
  message: string?,
  doc: string?,
  --- A base's field the class doesn't read: declared with its default, never read.
  unread: boolean?,
}

export type Definition = {
  base: string?,
  fields: { Step },
  --- Steps read before the base's fields, as when a class reads a value and then its base.
  first: { Step }?,
  --- The class reads none of its bases' fields: they keep their defaults.
  bare: boolean?,
  --- Conditions on bases' fields: a base named here reads its fields only when its condition
  --- holds; otherwise they keep their defaults.
  bases: { [string]: string }?,
  --- Checks OpenMW runs after loading, beyond links: functions of `nif/gamebryo/custom.luau`.
  post: { string }?,
  --- `Read::MIN_SIZE`, for counts of this struct.
  min: number?,
  doc: string?,
}

local classes: { [string]: Definition } = {}
local structs: { [string]: Definition } = {}

local function class(
  name: string,
  base: string?,
  fields: { Step },
  extra: {
    post: { string }?,
    first: { Step }?,
    bare: boolean?,
    bases: { [string]: string }?,
    doc: string?,
  }?
)
  assert(not classes[name], `class {name} is defined twice`)
  classes[name] = {
    base = base,
    fields = fields,
    first = extra and extra.first,
    bare = extra and extra.bare,
    bases = extra and extra.bases,
    post = extra and extra.post,
    doc = extra and extra.doc,
  }
end

local function struct(name: string, fields: { Step }, extra: { min: number?, doc: string? }?)
  assert(not structs[name], `struct {name} is defined twice`)
  structs[name] = { fields = fields, min = extra and extra.min, doc = extra and extra.doc }
end

--- A class that adds nothing to its base.
local function same(name: string, base: string) class(name, base, {}) end

return table.freeze {
  classes = classes,
  structs = structs,
  class = class,
  struct = struct,
  same = same,
}
