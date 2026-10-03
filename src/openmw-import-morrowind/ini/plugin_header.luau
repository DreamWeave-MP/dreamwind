--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0
local parser = require './parser'
local host = require('@dream/vfs').host

local function read(path: string, encoding: string?): { name: string, masters: { string } }
  local header = host.readAt(path, 0, 16)

  local function check(condition: boolean, message: string)
    assert(condition, `dream.ini: invalid plugin header in {path}: {message}`)
  end

  check(buffer.len(header) == 16, 'unexpected end of file')
  check(buffer.readstring(header, 0, 4) == 'TES3', 'missing TES3 record')
  local size = buffer.readu32(header, 4)
  local metadata = assert(host.stat(path))
  check(metadata.size >= 16 + size, 'TES3 record extends past end of file')
  local record = host.readAt(path, 16, size)
  check(buffer.len(record) == size, 'TES3 record extends past end of file')
  local offset = 0
  local masters: { string } = {}

  while offset + 8 <= size do
    local tag, length = buffer.readstring(record, offset, 4), buffer.readu32(record, offset + 4)
    offset += 8
    check(offset + length <= size, 'subrecord extends past TES3 record')

    if tag == 'MAST' then
      local text = buffer.readstring(record, offset, length)
      local nul = string.find(text, '\0', 1, true)
      table.insert(
        masters,
        parser.decode(if nul then string.sub(text, 1, nul - 1) else text, encoding)
      )
    end

    offset += length
  end

  check(offset == size, 'trailing partial subrecord header in TES3 record')
  return { name = jess.fs.fileName(path) or path, masters = masters }
end

return table.freeze { read = read }
