--!strict
--!native
-- Plugins built from bytes for dream.tes3cmd's suites: the synthetic plugins jess's CLI tests
-- (`libs/cli/tests/common/mod.rs`, `libs/cli/tests/plugin.rs`) write, spelled the same way.

local function u32(value: number): string return string.pack('<I4', value) end

local function f32(value: number): string return string.pack('<f', value) end

local function subrecord(tag: string, payload: string): string
  return tag .. u32(#payload) .. payload
end

local function record(tag: string, payload: string, flags: number?): string
  return tag .. u32(#payload) .. u32(0) .. u32(flags or 0) .. payload
end

local function fixed(text: string, n: number): string return text .. string.rep('\0', n - #text) end

local function hedr(count: number, fileType: number?): string
  return subrecord(
    'HEDR',
    f32(1.3) .. u32(fileType or 0) .. fixed('test', 32) .. fixed('synthetic', 256) .. u32(count)
  )
end

local function nam0(count: number): string return subrecord('NAM0', u32(count)) end

local function masterEntry(name: string, size: number): string
  return subrecord('MAST', name .. '\0') .. subrecord('DATA', string.pack('<I8', size))
end

local function header(count: number, masters: { { name: string, size: number } }?): string
  local parts = { hedr(count) }
  for _, master in masters or {} do
    table.insert(parts, masterEntry(master.name, master.size))
  end

  return record('TES3', table.concat(parts))
end

local function plugin(records: { string }, masters: { { name: string, size: number } }?): string
  return header(#records, masters) .. table.concat(records)
end

local function cell(): string
  local first = subrecord('FRMR', string.rep('\1', 4))
    .. subrecord('NAME', 'first_ref')
    .. subrecord('DATA', string.rep('\1', 24))
  local second = subrecord('FRMR', string.rep('\2', 4))
    .. subrecord('NAME', 'second_ref')
    .. subrecord('DATA', string.rep('\2', 24))
  return plugin {
    record(
      'CELL',
      subrecord('NAME', 'synthetic_cell') .. subrecord('DATA', u32(1)) .. nam0(2) .. first .. second
    ),
  }
end

local function dirty(): string
  local records = {
    record('STAT', subrecord('NAME', 'dup_static') .. subrecord('MODL', 'a.nif')),
    record('STAT', subrecord('NAME', 'dup_static') .. subrecord('MODL', 'b.nif')),
    record('GMST', subrecord('NAME', 'fWerewolfHealth') .. subrecord('FLTV', f32(2))),
    record(
      'CELL',
      subrecord('NAME', 'dirty_cell')
        .. subrecord('DATA', u32(1))
        .. subrecord('WHGT', '\7')
        .. subrecord('WHGT', '\7')
        .. nam0(1)
        .. subrecord('FRMR', string.rep('\1', 4))
        .. subrecord('NAME', 'kept_ref')
    ),
    record('CELL', subrecord('NAME', 'junk_cell') .. subrecord('DATA', u32(0))),
  }
  return record('TES3', hedr(999)) .. table.concat(records)
end

local function fogbug(): string
  return plugin {
    record(
      'CELL',
      subrecord('NAME', 'foggy_cell')
        .. subrecord('DATA', u32(1))
        .. subrecord('AMBI', string.rep('\0', 16))
    ),
  }
end

local function fogsync(fog: string, name: string): string
  return plugin {
    record(
      'CELL',
      subrecord('NAME', name)
        .. subrecord('DATA', u32(1) .. fog)
        .. subrecord('AMBI', string.rep('\0', 12) .. f32(0.5))
    ),
  }
end

local function scripts(): string
  return plugin {
    record(
      'SCPT',
      subrecord('NAME', 'script_id')
        .. subrecord(
          'SCTX',
          'Begin script_id\nGetSoundPlaying foo\nPositionCell 0 0 0 0 Balmora\nEnd'
        )
    ),
    record(
      'INFO',
      subrecord('NAME', 'info_id') .. subrecord('TEXT', 'PositionCell 0 0 0 0 Balmora')
    ),
    record('DOOR', subrecord('NAME', 'door_id') .. subrecord('SCRI', 'script_id')),
  }
end

local function infoIds(): string
  local function info(id: string): string
    return record('INFO', subrecord('INAM', id) .. subrecord('NAME', 'Same\nmulti-line response'))
  end

  return plugin { info '111', info '222' }
end

local function topic(name: string): string return plugin { record('DIAL', subrecord('NAME', name)) } end

--- A cell with references, its name and region the strings a modify rewrites.
local function namedCell(): string
  local reference = subrecord('FRMR', u32(1))
    .. subrecord('NAME', 'chair')
    .. subrecord('DATA', string.rep('\0', 24))
  return plugin {
    record(
      'CELL',
      subrecord('NAME', 'Old Cell')
        .. subrecord('DATA', u32(0) .. u32(3) .. u32(4))
        .. subrecord('RGNN', 'Old Region')
        .. nam0(1)
        .. reference
    ),
  }
end

local function stat(id: string, model: string?): string
  return record('STAT', subrecord('NAME', id) .. (if model then subrecord('MODL', model) else ''))
end

--- Every named synthetic plugin, in a stable order.
local function all(): { { name: string, bytes: string } }
  return {
    { name = 'cell.esp', bytes = cell() },
    { name = 'dirty.esp', bytes = dirty() },
    { name = 'fogbug.esp', bytes = fogbug() },
    { name = 'fogsync.esp', bytes = fogsync(f32(0.25), 'fogsync_cell') },
    { name = 'tiny-fog.esp', bytes = fogsync(string.pack('<I4', 0x00223344), 'tiny_fog') },
    { name = 'scripts.esp', bytes = scripts() },
    { name = 'info-ids.esp', bytes = infoIds() },
    { name = 'named-cell.esp', bytes = namedCell() },
    { name = 'topics.esp', bytes = topic 'to rescue me' },
    { name = 'stat.esp', bytes = plugin { stat('marker', 'marker.nif'), stat 'foo foo' } },
  }
end

return table.freeze {
  all = all,
  cell = cell,
  dirty = dirty,
  f32 = f32,
  fixed = fixed,
  fogbug = fogbug,
  fogsync = fogsync,
  hedr = hedr,
  header = header,
  infoIds = infoIds,
  masterEntry = masterEntry,
  nam0 = nam0,
  namedCell = namedCell,
  plugin = plugin,
  record = record,
  scripts = scripts,
  stat = stat,
  subrecord = subrecord,
  topic = topic,
  u32 = u32,
}
