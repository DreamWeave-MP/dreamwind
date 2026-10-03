--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0
local parser, importer = require '@self/ini/parser', require '@self/ini/importer'
local types = require '@self/ini/types'
local writers = require '@self/ini/writers'

export type MultiMap = types.MultiMap
export type Warning = types.Warning
export type Event = types.Event
export type ImportOptions = types.ImportOptions
export type MapsOptions = types.MapsOptions
export type PathsOptions = types.PathsOptions
export type Update = types.Update
export type Result = types.Result
export type Request = types.Request

--- The dream-ini release this port follows, to the byte.
local Version = '1.0.1'

return table.freeze {
  version = Version,
  parseIni = parser.parseIni,
  parseCfg = parser.parseCfg,
  serializeCfg = parser.serializeCfg,
  importMaps = importer.importMaps,
  importPaths = importer.importPaths,
  readPluginHeader = require('@self/ini/plugin_header').read,
  saveCfg = writers.saveCfg,
  saveResolvedCfg = writers.saveResolvedCfg,
  loadDocument = writers.loadDocument,
  applyUpdate = writers.applyUpdate,
  renderDocument = writers.renderDocument,
  saveDocument = writers.saveDocument,
  saveResolvedDocument = writers.saveResolvedDocument,
}
