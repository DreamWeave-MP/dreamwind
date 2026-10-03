--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0
-- The writers: the imported map as a new openmw.cfg, spelled as given or resolved, and a
-- preserved document written back. Every write goes through a temporary file beside the target
-- and a rename, so a failure leaves whatever was there whole.
local types, options, config, document =
  require './types', require './options', require './config', require './document'
type MultiMap = types.MultiMap
type Update = types.Update
type Document = document.Document

--- The folder an output's document belongs to: the file's folder, or the working directory for a
--- bare name (`save_cfg_output_to_path`).
local function directoryOf(path: string): string return jess.fs.parent(path) or '' end

--- `cfg` written to `path` as a new openmw.cfg with every value spelled as given, in key order,
--- ending in openmw-config's serializer stamp (`save_cfg_output_to_path`).
local function saveCfg(cfg: MultiMap, path: string)
  cfg = options.multimap('ini.saveCfg', cfg)
  document.replaceFile(path, config.document(cfg, directoryOf(path), true):toString())
end

--- `cfg` written to `path` with its folders resolved against the file's folder, the way dream-ini
--- writes an import whose output lives elsewhere (`save_resolved_cfg_to_path`).
local function saveResolvedCfg(cfg: MultiMap, path: string)
  cfg = options.multimap('ini.saveResolvedCfg', cfg)
  document.replaceFile(path, config.resolvedText(config.document(cfg, directoryOf(path))))
end

local UpdateSpec: options.Spec = {
  gameFiles = 'boolean',
  archives = 'boolean',
  dataLocal = 'string',
  resources = 'string',
  userData = 'string',
}
table.freeze(UpdateSpec)

local function applyUpdate(
  target: Document,
  result: { cfg: MultiMap, changedKeys: { string } },
  update: Update?
)
  local read = options.read('ini.applyUpdate', update, UpdateSpec)
  document.apply(target, {
    cfg = options.multimap('ini.applyUpdate', result.cfg),
    changedKeys = result.changedKeys,
  }, read :: Update)
end

--- A loaded document's resolved text written to `path`
--- (`save_resolved_configuration_to_path`).
local function saveResolvedDocument(target: Document, path: string)
  document.replaceFile(path, config.resolvedText(target.config))
end

return table.freeze {
  saveCfg = saveCfg,
  saveResolvedCfg = saveResolvedCfg,
  loadDocument = document.load,
  applyUpdate = applyUpdate,
  renderDocument = document.render,
  saveDocument = document.save,
  saveResolvedDocument = saveResolvedDocument,
}
