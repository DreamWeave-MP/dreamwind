--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
OpenMW's `components/nif/physics.hpp` values and checks the schema can't state as steps.
]]

local G = require '../stream'
local L = require '../links'

type Stream = G.Stream

local custom = {}

--- One `TriangleData`: three `u16` vertices, the welding info, and, up to Oblivion, a normal.
local function packedTriangle(b: buffer, p: number): any
  return {
    triangle = { buffer.readu16(b, p), buffer.readu16(b, p + 2), buffer.readu16(b, p + 4) },
    weldingInfo = buffer.readu16(b, p + 6),
    normal = vector.zero,
  }
end

local function packedTriangleWithNormal(b: buffer, p: number): any
  local triangle = packedTriangle(b, p)
  triangle.normal =
    vector.create(buffer.readf32(b, p + 8), buffer.readf32(b, p + 12), buffer.readf32(b, p + 16))
  return triangle
end

--- `hkPackedNiTriStripsData`'s triangles after a `u32` count, each read when asked for; up to
--- Oblivion they carry normals. Like jess-nif, the count isn't checked against the file size.
function custom.packedTriangles(s: Stream, p: number): (any, number)
  local count = buffer.readu32(s.b, p)
  local normals = s.version <= 0x14000005
  local stride = if normals then 20 else 8
  if p + 4 + count * stride > s.n then
    G.fail(`Failed to read TriangleData: {stride} bytes at offset {p + 4} of {s.n}`)
  end

  return G.rows(
    s,
    p + 4,
    count,
    stride,
    if normals then packedTriangleWithNormal else packedTriangle
  )
end

--- `bhkPoseArray`'s poses: a `u32` count of poses, each a `u32` count of bone transforms.
function custom.poses(s: Stream, p: number): ({ { any } }, number)
  local b = s.b
  local count = buffer.readu32(b, p)
  p += 4
  local poses: { { any } } = {}
  for i = 1, count do
    local length = buffer.readu32(b, p)
    p += 4
    if p + length * 40 > s.n then
      G.fail(`Failed to read bhkPoseArray: 40 bytes at offset {p} of {s.n}`)
    end

    local pose = table.create(length) :: { any }
    for j = 1, length do
      pose[j] = {
        translation = vector.create(
          buffer.readf32(b, p),
          buffer.readf32(b, p + 4),
          buffer.readf32(b, p + 8)
        ),
        rotation = {
          buffer.readf32(b, p + 16),
          buffer.readf32(b, p + 20),
          buffer.readf32(b, p + 24),
          buffer.readf32(b, p + 12),
        },
        scale = vector.create(
          buffer.readf32(b, p + 28),
          buffer.readf32(b, p + 32),
          buffer.readf32(b, p + 36)
        ),
      }
      p += 40
    end

    poses[i] = pose
  end

  return poses, p
end

--- `bhkConstraint`'s entities, which its info holds.
function custom.constraintLinks(r: any, records: { any }, classes: { string }, index: number)
  L.link(r.info.entityA, 'bhkEntity', records, classes, index)
  L.link(r.info.entityB, 'bhkEntity', records, classes, index)
end

--- `bhkBallSocketConstraintChain`'s entities; OpenMW leaves its info's links unresolved.
function custom.constraintChainLinks(
  r: any,
  records: { any },
  classes: { string },
  index: number
)
  L.links(r.constraintChainInfo.entities, 'bhkRigidBody', records, classes, index)
end

return custom
