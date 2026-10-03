--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0
-- Order is dream-ini 1.0.0's MORROWIND_FALLBACK_KEYS, including the inconsistent weather ordering.

local keys: { string } = {}

local function add(section: string, fields: string)
  for field in string.gmatch(fields, '[^|]+') do
    table.insert(keys, section .. ':' .. field)
  end
end

add(
  'LightAttenuation',
  'UseConstant|ConstantValue|UseLinear|LinearMethod|LinearValue|LinearRadiusMult|UseQuadratic|QuadraticMethod|QuadraticValue|QuadraticRadiusMult|OutQuadInLin'
)
add(
  'Inventory',
  'DirectionalDiffuseR|DirectionalDiffuseG|DirectionalDiffuseB|DirectionalAmbientR|DirectionalAmbientG|DirectionalAmbientB|DirectionalRotationX|DirectionalRotationY|UniformScaling'
)
add(
  'Map',
  'Travel Siltstrider Red|Travel Siltstrider Green|Travel Siltstrider Blue|Travel Boat Red|Travel Boat Green|Travel Boat Blue|Travel Magic Red|Travel Magic Green|Travel Magic Blue|Show Travel Lines'
)
add(
  'Water',
  'Map Alpha|World Alpha|SurfaceTextureSize|SurfaceTileCount|SurfaceFPS|SurfaceTexture|SurfaceFrameCount|TileTextureDivisor|RippleTexture|RippleFrameCount|RippleLifetime|MaxNumberRipples|RippleScale|RippleRotSpeed|RippleAlphas|PSWaterReflectTerrain|PSWaterReflectUpdate|NearWaterRadius|NearWaterPoints|NearWaterUnderwaterFreq|NearWaterUnderwaterVolume|NearWaterIndoorTolerance|NearWaterOutdoorTolerance|NearWaterIndoorID|NearWaterOutdoorID|UnderwaterSunriseFog|UnderwaterDayFog|UnderwaterSunsetFog|UnderwaterNightFog|UnderwaterIndoorFog|UnderwaterColor|UnderwaterColorWeight'
)
add('PixelWater', 'SurfaceFPS|TileCount|Resolution')
add('Fonts', 'Font 0|Font 1|Font 2')
add(
  'FontColor',
  'color_normal|color_normal_over|color_normal_pressed|color_active|color_active_over|color_active_pressed|color_disabled|color_disabled_over|color_disabled_pressed|color_link|color_link_over|color_link_pressed|color_journal_link|color_journal_link_over|color_journal_link_pressed|color_journal_topic|color_journal_topic_over|color_journal_topic_pressed|color_answer|color_answer_over|color_answer_pressed|color_header|color_notify|color_big_normal|color_big_normal_over|color_big_normal_pressed|color_big_link|color_big_link_over|color_big_link_pressed|color_big_answer|color_big_answer_over|color_big_answer_pressed|color_big_header|color_big_notify|color_background|color_focus|color_health|color_magic|color_fatigue|color_misc|color_weapon_fill|color_magic_fill|color_positive|color_negative|color_count'
)

for index = 2, 20 do
  add('Level Up', `Level{index}`)
end

add('Level Up', 'Default')

for index = 1, 10 do
  add(`Question {index}`, 'Question|AnswerOne|AnswerTwo|AnswerThree|Sound')
end

for _, field in { 'Model', 'Texture', 'Texture Name' } do
  for index = 0, if field == 'Model' then 2 else 7 do
    add('Blood', `{field} {index}`)
  end
end

add('Movies', 'Company Logo|Morrowind Logo|New Game|Loading|Options Menu')
add(
  'Weather Thunderstorm',
  'Thunder Sound ID 0|Thunder Sound ID 1|Thunder Sound ID 2|Thunder Sound ID 3'
)
add(
  'Weather',
  'Sunrise Time|Sunset Time|Sunrise Duration|Sunset Duration|Hours Between Weather Changes'
)
add('Weather Thunderstorm', 'Thunder Frequency|Thunder Threshold')
add(
  'Weather',
  'EnvReduceColor|LerpCloseColor|BumpFadeColor|AlphaReduce|Minimum Time Between Environmental Sounds|Maximum Time Between Environmental Sounds|Sun Glare Fader Max|Sun Glare Fader Angle Max|Sun Glare Fader Color|Timescale Clouds|Precip Gravity|Rain Ripples|Rain Ripple Radius|Rain Ripples Per Drop|Rain Ripple Scale|Rain Ripple Speed|Fog Depth Change Speed|Sky Pre-Sunrise Time|Sky Post-Sunrise Time|Sky Pre-Sunset Time|Sky Post-Sunset Time|Ambient Pre-Sunrise Time|Ambient Post-Sunrise Time|Ambient Pre-Sunset Time|Ambient Post-Sunset Time|Fog Pre-Sunrise Time|Fog Post-Sunrise Time|Fog Pre-Sunset Time|Fog Post-Sunset Time|Sun Pre-Sunrise Time|Sun Post-Sunrise Time|Sun Pre-Sunset Time|Sun Post-Sunset Time|Stars Post-Sunset Start|Stars Pre-Sunrise Finish|Stars Fading Duration|Snow Ripples|Snow Ripple Radius|Snow Ripples Per Flake|Snow Ripple Scale|Snow Ripple Speed|Snow Gravity Scale|Snow High Kill|Snow Low Kill'
)

local Weathers = {
  'Clear',
  'Cloudy',
  'Foggy',
  'Thunderstorm',
  'Rain',
  'Overcast',
  'Ashstorm',
  'Blight',
  'Snow',
  'Blizzard',
}

for _, weather in Weathers do
  local section = 'Weather ' .. weather
  add(section, 'Cloud Texture|Clouds Maximum Percent|Transition Delta')

  for _, component in { 'Sky', 'Fog', 'Ambient', 'Sun' } do
    for _, time in { 'Sunrise', 'Day', 'Sunset', 'Night' } do
      add(section, `{component} {time} Color`)
    end
  end

  add(
    section,
    'Sun Disc Sunset Color|Land Fog Day Depth|Land Fog Night Depth|Wind Speed|Cloud Speed|Glare View'
  )

  if weather == 'Thunderstorm' then
    add(
      section,
      'Rain Loop Sound ID|Using Precip|Rain Diameter|Rain Height Min|Rain Height Max|Rain Threshold|Max Raindrops|Rain Entrance Speed|Ambient Loop Sound ID|Flash Decrement'
    )
  elseif weather == 'Rain' then
    add(
      section,
      'Rain Loop Sound ID|Using Precip|Rain Diameter|Rain Height Min|Rain Height Max|Rain Threshold|Rain Entrance Speed|Ambient Loop Sound ID|Max Raindrops'
    )
  elseif weather == 'Snow' then
    add(
      section,
      'Snow Diameter|Snow Height Min|Snow Height Max|Snow Entrance Speed|Max Snowflakes|Ambient Loop Sound ID|Snow Threshold'
    )
  else
    add(section, 'Ambient Loop Sound ID')

    if weather == 'Ashstorm' or weather == 'Blight' or weather == 'Blizzard' then
      add(section, 'Storm Threshold')
    end

    if weather == 'Blight' then add(section, 'Disease Chance') end
  end
end

local MoonFields = {
  'Size',
  'Axis Offset',
  'Speed',
  'Daily Increment',
  'Moon Shadow Early Fade Angle',
  'Fade Start Angle',
  'Fade End Angle',
  'Fade In Start',
  'Fade In Finish',
  'Fade Out Start',
  'Fade Out Finish',
}

for _, moon in { 'Secunda', 'Masser' } do
  for _, field in MoonFields do
    add('Moons', `{moon} {field}`)
  end
end

add('Moons', 'Script Color')
add('General', 'Werewolf FOV')
return table.freeze(keys)
