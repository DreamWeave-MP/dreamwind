--!strict
-- The Definitive source corpus and the reviewed lists build_starwind.py and motherjungle_audit.py
-- carry, verbatim.

export type Source = { key: string, json: string, binary: string }

local sources = {}

sources.Included = {
  { key = 'Morrowind', json = 'Morrowind.json', binary = 'Morrowind.esm' },
  { key = 'Tribunal', json = 'Tribunal.json', binary = 'Tribunal.esm' },
  { key = 'Bloodmoon', json = 'Bloodmoon.json', binary = 'Bloodmoon.esm' },
  { key = 'Minimal', json = 'Minimal.json', binary = 'Minimal.esp' },
  { key = 'V115', json = 'StarwindRemasteredV1.15.json', binary = 'StarwindRemasteredV1.15.esm' },
  { key = 'Patch', json = 'StarwindRemasteredPatch.json', binary = 'StarwindRemasteredPatch.esm' },
  { key = 'Bings', json = 'bings race pack.json', binary = 'bings race pack.esp' },
  { key = 'Enhanced', json = 'Starwind Enhanced.json', binary = 'Starwind Enhanced.esm' },
  { key = 'PlanExp', json = 'StarwindPlanExp.json', binary = 'StarwindPlanExp.esp' },
  { key = 'AltStart', json = 'alt_start1.5.json', binary = 'alt_start1.5.esp' },
  {
    key = 'CPP',
    json = 'Starwind Community Patch Project.json',
    binary = 'Starwind Community Patch Project.esp',
  },
  { key = 'Naboo', json = 'naboo.json', binary = 'naboo.esp' },
  { key = 'PartyHats', json = 'PartyHats.json', binary = 'PartyHats.esp' },
} :: { Source }

sources.Excluded = { 'MPRecords', 'Vvardenfell' }

sources.Vanilla = { 'Morrowind', 'Tribunal', 'Bloodmoon' }

sources.MainQuestAnchors = {
  { 'Script', 'SW_ShadeAttackFinaleScr' },
  { 'Script', 'SW_ShadeDroidArmyFinaleScr' },
  { 'Script', 'SW_ShadeScriptCantinaTat' },
  { 'Script', 'SW_ShadeScriptManaan1' },
  { 'Script', 'SW_ShadeScriptMedical' },
  { 'Script', 'SW_ShadeTowerScr' },
  { 'Npc', 'SW_ShadePre' },
  { 'Npc', 'SW_ShadeManaan1' },
  { 'Npc', 'SW_ShadeMedicalTat' },
  { 'Npc', 'SW_ShadeTower' },
  { 'Npc', 'SW_ShipQuester' },
  { 'Dialogue', 'SW_PreTaris' },
  { 'Dialogue', 'SW_TarisChap1' },
  { 'Dialogue', 'SW_TarisChap1-2' },
  { 'Dialogue', 'SW_TarisChapX3-2' },
  { 'Dialogue', 'SW_TarisChapX3-3' },
  { 'Dialogue', 'SW_ShipOwn' },
}

sources.MainQuestCellReferenceAnchors = { 'SW_ShipQuester' }

-- Manually audited against the Definitive corpus: non-playable, with no NPC, dialogue, or script
-- references.
sources.DeadClasses = {
  'Apothecary',
  'Assassin Service',
  'Bard',
  'Battlemage Service',
  'Bookseller',
  'Clothier',
  'Dreamers',
  'Enchanter Service',
  'Gardener',
  'Gondolier',
  'Guild Guide',
  'Journalist',
  'Mabrigash',
  'Miner',
  'Necromancer',
  'Pawnbroker',
  'Pilgrim',
  'Priest Service',
  'Publican',
  'Shipmaster',
  'Sorcerer Service',
  'Warlock',
  'Wise Woman',
  'Wise Woman Service',
  'Witch',
}

-- The historical build.sh junk-cell list.
sources.JunkCells = {
  'ashinabi, smuggler den',
  'balmora, drarayne thelas\' storage',
  'balmora, hecerinde\'s house',
  'baram ancestral tomb',
  'berandas, propylon chamber',
  'cavern of the incarnate',
  'dantooine',
  'dantooine, cavern',
  'falensarano, propylon chamber',
  'gnisis, arvs-drelen',
  'gnisis, madach tradehouse',
  'hairat-vassamsi egg mine, queen\'s lair',
  'kashyyk',
  'koal cave',
  'kogoruhn, hall of maki',
  'kogoruhn, vault of aerode',
  'moonmoth legion fort, prison towers',
  'mournhold, great bazaar',
  'mournhold, plaza brindisi dorom',
  'mournhold, royal palace: basement',
  'mournhold, royal palace: helseth\'s chambers',
  'Nar Shaddaa, Hutt Base',
  'nerano ancestral tomb',
  'pelagiad, south wall',
  'seyda neen, census and excise office',
  'solstheim, gyldenhul barrow',
  'solstheim, legge',
  'surirulk',
  'testcell',
  'toddtest',
  'tukushapal',
  'vivec, palace of vivec',
  'yakin',
}

-- The 53 vanilla INFOs behind the unresolved Morag Tong, Hands of Almalexia, and Census and
-- Excise faction references, pruned from the staged masters before decoupling.
sources.DeadVanillaFactionInfos = {
  '10892597398701449',
  '15740996644818361',
  '18628248200029145',
  '27104661529628909',
  '27380594163115117',
  '46239530102619813',
  '68081962797431540',
  '84318339166287950',
  '138471225627324116',
  '175158043101416917',
  '209281375883337301',
  '227566641690323024',
  '233813539948315535',
  '387031381294227495',
  '524426342189474603',
  '786912151253629496',
  '801171242963610533',
  '917331001273226401',
  '959211469735030099',
  '999411412119813019',
  '1278371803083124313',
  '1404115803293832208',
  '1556426861203214287',
  '1922626285304825312',
  '1922919187540014555',
  '1933022293213049142',
  '2060515467642016544',
  '2170199432650617071',
  '2674120808223158958',
  '2689112858236774173',
  '2928598872632726697',
  '3014115110938721232',
  '3029810224114315641',
  '3099612586852222907',
  '3134028020260168750',
  '4947196993132126615',
  '7347299612038512802',
  '8077199921502012362',
  '10587309131832629595',
  '12276284861507021461',
  '12560149042482210158',
  '12957241603014511444',
  '13167128832337732279',
  '13369242242758228534',
  '15146151042139030418',
  '19491238341389220281',
  '20280268732850724042',
  '21710101122065519831',
  '22580190852053612072',
  '23187123271197316191',
  '23407321083087418600',
  '24702137811180913386',
  '30253208512738732261',
}

-- Vanilla regions Starwind reuses for weather, and the sleep encounters it doesn't want.
sources.RegionSleepCreatures = {
  { 'Ascadian Isles Region', 'ex_ascadianisles_sleep' },
  { 'Isinfier Plains Region', 'bm_ex_isinplains_sleep' },
  { 'Azura\'s Coast Region', 'ex_azurascoast_sleep' },
  { 'Bitter Coast Region', 'ex_bittercoast_sleep' },
  { 'Grazelands Region', 'ex_grazelands_sleep' },
  { 'Moesring Mountains Region', 'bm_ex_moemountains_sleep' },
  { 'Red Mountain Region', 'ex_RedMtn_all_sleep' },
  { 'West Gash Region', 'ex_westgash_sleep' },
}

return sources
