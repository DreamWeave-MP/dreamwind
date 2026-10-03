--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0
export type MultiMap = { [string]: { string } }
export type Warning = { kind: string, message: string, key: string?, line: string?, file: string? }
export type Event = { kind: string, path: string, modified: number? }

--- The options `importMaps` and `importPaths` share, as `dreamIni` takes them.
export type ImportOptions = {
  game: string?,
  gameFiles: boolean?,
  fonts: boolean?,
  archives: boolean?,
  verbose: boolean?,
  encoding: string?,
  dataDirs: { string }?,
  dataLocal: string?,
  resources: string?,
  userData: string?,
  cfgDir: string?,
}

--- `importMaps`' options: the shared ones and the INI's nominal location, which places the
--- default `Data Files` folder.
export type MapsOptions = ImportOptions & { iniPath: string? }

--- `importPaths`' options: the shared ones and the files to read.
export type PathsOptions = ImportOptions & { ini: string, cfg: string? }

--- What a preserved openmw.cfg takes from an import besides its changed keys, as dream-ini's
--- `PreservedCfgUpdate` carries it: whether the content and archive lists were imported, and the
--- folder overrides. `archives` is on unless turned off, as in the import options.
export type Update = {
  gameFiles: boolean?,
  archives: boolean?,
  dataLocal: string?,
  resources: string?,
  userData: string?,
}

export type Result = {
  cfg: MultiMap,
  text: string,
  warnings: { Warning },
  events: { Event },
  changedKeys: { string },
}

--- One import, options read and defaults filled: what the content and archive resolution runs on.
export type Request = {
  cfg: MultiMap,
  ini: MultiMap,
  iniPath: string,
  cfgDir: string?,
  dataDirs: { string },
  dataDirBase: string?,
  verbose: boolean,
}

return table.freeze {}
