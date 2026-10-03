--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
TES3 content in Luau: Morrowind and OpenMW plugins (`.esp`, `.esm`, `.omwaddon`) and saves
(`.ess`, `.omwsave`), read and written raw-preserving.

`open` frames every record and subrecord of a file's bytes and keeps where each record is; nothing
is decoded. `plugin:decode(i)` reads a record into the table jess-omwaddon's serde shape gives
(field names camelCase), `encode` writes such a table back as record bytes, and `plugin:save()`
copies every untouched record's original bytes, so an unedited plugin saves byte for byte.
]]

local Decode = require '@self/decode'
local Display = require '@self/display'
local Encode = require '@self/encode'
local Plugin = require '@self/plugin'
local Records = require '@self/records'
local Save = require '@self/save'
local Schema = require '@self/schema'
local Tags = require '@self/tags'
local Text = require '@self/text'
local Writeback = require '@self/writeback'

export type Plugin = Plugin.Plugin
export type OpenOptions = Plugin.OpenOptions
export type Header = Plugin.Header
export type Master = Plugin.Master
export type Subrecord = Plugin.Subrecord
export type Diagnostic = Plugin.Diagnostic
export type Profile = Plugin.Profile
export type FileType = Plugin.FileType
export type Value = Decode.Value
export type LuaValue = Save.LuaValue
export type LuaRef = Save.LuaRef
export type SaveProfile = Save.Profile
export type Compatibility = Save.Compatibility
export type StringField = Records.StringField
export type Key = Records.Key

--- Every record type jess-omwaddon decodes: its tag and its name.
local RecordTypes: { { tag: string, name: string } } = {}
for _, spec in Decode.specs do
  table.insert(RecordTypes, { tag = spec.tag, name = spec.name })
end

table.freeze(RecordTypes)

--- Opens a TES3 file from its bytes.
local function open(bytes: buffer | string, options: OpenOptions?): Plugin
  local source = if type(bytes) == 'string' then buffer.fromstring(bytes) else bytes
  return Plugin.parse(source, options)
end

return table.freeze {
  checkRoundTrip = Plugin.checkRoundTrip,
  checks = Plugin.checks,
  decode = Decode.decode,
  default = Decode.default,
  --- Readable record values: what `jess plugin dump` prints.
  display = Display,
  encode = Encode.encode,
  new = Plugin.new,
  open = open,
  recordTypes = RecordTypes,
  lossyUtf8 = Plugin.lossyUtf8,
  records = Records,
  save = Save,
  schema = Schema,
  tagNamed = Decode.tagNamed,
  tags = Tags,
  text = Text,
  typeName = Decode.typeName,
  writeback = Writeback,
}
