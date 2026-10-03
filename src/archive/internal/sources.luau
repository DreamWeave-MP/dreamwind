--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0
-- What builders hold until they write, and where the bytes go when they do. A member is bytes
-- copied when added, a host file read when written, or another archive's entry decoded when
-- written. An archive goes into one buffer, or to a host file as it is made, as the crate streams
-- it, with the index written over its placeholder at the end.
local types = require './types'
local util = require './util'
local host = require('@dream/vfs').host

type Source = types.Source
type Backend = types.Backend

local fail, Messages = util.fail, util.Messages

--- A payload's length, a string's or a buffer's.
local function length(data: buffer | string): number
  return if type(data) == 'string' then #data else buffer.len(data :: buffer)
end

--- A payload added from memory. A string can't change, so it is kept as it is; a buffer is
--- copied, since its owner can write it before the archive is.
local function fromBytes(value: buffer | string): Source
  if type(value) == 'string' then return { kind = 'bytes', bytes = value, length = #value } end

  local source = value :: buffer
  local copy = buffer.create(buffer.len(source))
  buffer.copy(copy, 0, source)
  return { kind = 'bytes', bytes = copy, length = buffer.len(copy) }
end

--- A host file, its size taken now and its bytes when written.
local function fromFile(path: string): Source
  return { kind = 'file', path = path, length = util.hostFileSize(path) }
end

local function fromArchive(backend: Backend, index: number, length: number): Source
  return { kind = 'archive', backend = backend, index = index, length = length }
end

--- The member's bytes, which must still be as long as when it was added.
local function load(source: Source): buffer | string
  if source.kind == 'bytes' then return source.bytes :: buffer | string end

  if source.kind == 'file' then
    local data = util.readHostFile(source.path :: string)
    if buffer.len(data) ~= source.length then fail(Messages.sourceChanged) end

    return data
  end

  local data = (source.backend :: Backend).decode(source.index :: number)
  if buffer.len(data) ~= source.length then fail(Messages.outOfBounds) end

  return data
end

--- Every file below `root` and the archive path it gets: its path relative to `root`, with `/`.
local function collect(root: string): { { archivePath: string, path: string, size: number } }
  -- host.stat throws for a path it can't ask about.
  local ok, result = pcall(host.stat, root)
  if not ok then fail(util.hostMessage(result)) end

  local info = result :: { isDir: boolean }?
  if not info then fail 'No such file or directory (os error 2)' end

  if not (info :: { isDir: boolean }).isDir then fail 'Not a directory (os error 20)' end

  -- host.list throws when a folder below `root` can't be read.
  local listed, rows = pcall(host.list, root, { recursive = true } :: { recursive: boolean? })
  if not listed then fail(util.hostMessage(rows)) end

  local prefix = if string.byte(root, -1) == 47 then root else `{root}/`
  local files = {}
  for _, row in rows :: { { path: string, isDir: boolean, size: number } } do
    if row.isDir then continue end

    local path = row.path
    local relative = if string.sub(path, 1, #prefix) == prefix
      then string.sub(path, #prefix + 1)
      else path
    table.insert(files, { archivePath = relative, path = path, size = row.size })
  end

  return files
end

export type Sink = {
  out: buffer?,
  pieces: { buffer },
  length: number,
  writer: Writer?,
}

type Writer = {
  write: (self: Writer, data: buffer | string) -> number,
  writeAt: (self: Writer, position: number, data: buffer) -> number,
  close: (self: Writer) -> unknown,
}

--- A sink collecting the archive in memory: straight into one buffer when its size is known.
local function memorySink(total: number?): Sink
  return { out = if total then buffer.create(total) else nil, pieces = {}, length = 0 }
end

--- A sink writing to `path`, created now, as `File::create` does before anything is written.
local function fileSink(path: string): Sink
  -- host.openWrite throws for a path it can't create.
  local ok, result = pcall(host.openWrite, path, nil)
  if not ok then fail(util.hostMessage(result)) end

  return { pieces = {}, length = 0, writer = result :: Writer }
end

local function add(sink: Sink, data: buffer | string)
  local writer, out = sink.writer, sink.out
  if writer then
    -- Writer.write throws with the operating system's reason.
    local ok, result = pcall(writer.write, writer, data)
    if not ok then fail(util.hostMessage(result)) end
  elseif out then
    if type(data) == 'string' then
      buffer.writestring(out, sink.length, data)
    else
      buffer.copy(out, sink.length, data :: buffer)
    end
  else
    table.insert(
      sink.pieces,
      if type(data) == 'string' then buffer.fromstring(data) else data :: buffer
    )
  end

  sink.length += length(data)
end

--- The archive in one buffer, with `head` over its first bytes when given; for a file sink,
--- `head` is written over its placeholder and the file closed.
local function finish(sink: Sink, head: buffer?): buffer?
  local writer = sink.writer
  if writer then
    -- Writer.writeAt and Writer.close throw with the operating system's reason.
    if head then
      local ok, result = pcall(writer.writeAt, writer, 0, head)
      if not ok then fail(util.hostMessage(result)) end
    end

    local ok, result = pcall(writer.close, writer)
    if not ok then fail(util.hostMessage(result)) end

    return nil
  end

  local out = sink.out
  if not out then
    local joined = buffer.create(sink.length)
    local position = 0
    for _, piece in sink.pieces do
      buffer.copy(joined, position, piece)
      position += buffer.len(piece)
    end

    out = joined
  end

  if head then buffer.copy(out :: buffer, 0, head) end

  return out
end

return table.freeze {
  fromBytes = fromBytes,
  length = length,
  fromFile = fromFile,
  fromArchive = fromArchive,
  load = load,
  collect = collect,
  memorySink = memorySink,
  fileSink = fileSink,
  add = add,
  finish = finish,
}
