--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
What `check` reports about a NIF.
]]

local Header = require '../header'

--- How much a finding matters, most severe first: OpenMW refuses the file; it loads but
--- something is dropped or drawn differently than authored; a file it refers to is missing;
--- collision differs from what the file seems to ask for; it costs frame time or memory for no
--- visible benefit; or it's worth knowing but not a problem.
export type Severity =
  'wont_load'
  | 'broken'
  | 'missing_asset'
  | 'collision'
  | 'performance'
  | 'info'

--- One thing a check found.
export type Finding = {
  severity: Severity,
  --- A stable `snake_case` identifier for the kind of finding, such as `unknown_record_type`.
  code: string,
  message: string,
  --- The record the finding is about, by 0-based index in the file.
  record: number?,
}

--- Counts from a NIF's scene graph. Only what OpenMW would draw counts as rendered: hidden
--- subtrees, collision nodes, and filtered shapes are left out.
export type Stats = {
  records: number,
  --- Records reachable from the roots; the rest are dead weight. After Morrowind, links OpenMW
  --- reads but never resolves (Havok constraints and actions, additional geometry data,
  --- animation notes) aren't followed, so this undercounts.
  reachableRecords: number,
  nodes: number,
  --- Rendered shapes; each is at least one draw call.
  shapes: number,
  vertices: number,
  triangles: number,
  --- Triangles OpenMW builds the collision shape from.
  collisionTriangles: number,
  --- Active controllers on reachable objects.
  controllers: number,
  --- Textures stored inside the file rather than referenced by path.
  embeddedTextures: number,
  embeddedTextureBytes: number,
  skinned: boolean,
}

--- Where a model's collision comes from (`bulletnifloader.cpp` `load`): the geometry under its
--- `RootCollisionNode`; the render geometry for the camera only; all render geometry; or nothing.
export type CollisionSource = 'root_collision_node' | 'camera_only' | 'render_geometry' | 'none'

--- How a model collides.
export type Collision = {
  source: CollisionSource,
  --- The `RootCollisionNode` used, by record index.
  node: number?,
  --- Whether root `MRK` string data or the `BSXFlags` editor marker bit hides editor markers.
  hidesMarkers: boolean,
  --- The root's `BSXFlags`, which decide collision from 10.0.1.0 on.
  bsxFlags: number?,
}

--- Everything `check` found out about one NIF.
export type Report = {
  --- The header, when it could be read.
  header: Header.Header?,
  --- Whether the records were read and checked, not just the header.
  deep: boolean,
  findings: { Finding },
  --- External texture paths as the file writes them, without duplicates, in file order.
  textures: { string },
  --- Scene graph counts, for deeply checked files.
  stats: Stats?,
  --- How OpenMW builds the model's collision, for deeply checked models.
  collision: Collision?,
}

--- Each severity's rank, most severe first.
local Ranks: { [Severity]: number } = table.freeze({
  wont_load = 1,
  broken = 2,
  missing_asset = 3,
  collision = 4,
  performance = 5,
  info = 6,
} :: { [Severity]: number })

return table.freeze { ranks = Ranks }
