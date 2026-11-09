-- Pure Dyson 358K (Purifier Humidify+Cool) protocol helpers: topics, state derivation,
-- command payloads. No SmartThings or socket dependencies so it tests on plain Lua.
-- Field meanings follow libdyson-neon (dyson_pure_humidify_cool.py, dyson_pure_cool.py).

local M = {}

function M.topics(product_type, serial)
  local base = product_type .. "/" .. serial
  return { status = base .. "/status/current", faults = base .. "/status/faults", command = base .. "/command" }
end

-- STATE-CHANGE reports [old, new] pairs; CURRENT-STATE reports plain values.
local function newest(v)
  if type(v) == "table" then return v[2] end
  return v
end

local function num(v)
  return tonumber(newest(v))
end

-- Merge a decoded Dyson message into the raw field cache. Returns true if it carried state.
function M.merge(raw, msg)
  local kind = msg.msg
  if kind == "CURRENT-STATE" or kind == "STATE-CHANGE" then
    for k, v in pairs(msg["product-state"] or {}) do raw[k] = newest(v) end
    if msg.rssi then raw.rssi = msg.rssi end -- top-level, not in product-state
    return true
  elseif kind == "ENVIRONMENTAL-CURRENT-SENSOR-DATA" then
    for k, v in pairs(msg.data or {}) do raw[k] = newest(v) end
    return true
  elseif kind == "CURRENT-FAULTS" then
    -- Groups: product-errors, product-warnings, module-errors, module-warnings; each key is "OK"
    -- or "FAIL". Stored as raw.faults["product-warnings.tnkp"] = "FAIL".
    raw.faults = {}
    for group, entries in pairs(msg) do
      if type(entries) == "table" then
        for k, v in pairs(entries) do raw.faults[group .. "." .. k] = newest(v) end
      end
    end
    return true
  end
  return false
end

local function round(x, places)
  local m = 10 ^ places
  return math.floor(x * m + 0.5) / m
end

-- Mode labels shown in SmartThings. Order is the order of the picker.
M.OFF = "Off"
M.OSCILLATION_MODES = { M.OFF, "45°", "90°", "Breeze", "Custom" }
local OSC_CODE = { ["45°"] = "0045", ["90°"] = "0090", Breeze = "BRZE", Custom = "CUST" }
local OSC_LABEL = { ["0045"] = "45°", ["0090"] = "90°", BRZE = "Breeze", CUST = "Custom" }

M.FRONT, M.BACK = "Front", "Back"
M.AIRFLOW_MODES = { M.FRONT, M.BACK }

M.AUTO = "Auto"
M.HUMIDITY_MODES = { M.AUTO, "30%", "35%", "40%", "45%", "50%", "55%", "60%", "65%", "70%" }

M.HUMIDITY_MIN, M.HUMIDITY_MAX = 30, 70

M.WATER_HARDNESS_MODES = { "Soft", "Medium", "Hard" }
local HARDNESS_CODE = { Soft = "2025", Medium = "1350", Hard = "0675" }
local HARDNESS_LABEL = { ["2025"] = "Soft", ["1350"] = "Medium", ["0675"] = "Hard" }

M.SLEEP_TIMER_MODES = { M.OFF, "15 min", "30 min", "45 min", "1 h", "2 h", "4 h", "8 h" }
local SLEEP_MINUTES = {
  ["15 min"] = 15, ["30 min"] = 30, ["45 min"] = 45, ["1 h"] = 60, ["2 h"] = 120,
  ["4 h"] = 240, ["8 h"] = 480,
}

M.FAN_MODES = { "auto", "low", "medium", "high" }
local SPEED_FOR_MODE = { low = 3, medium = 6, high = 10 }

-- Dyson app levels, in order: Good, Fair, Poor, Very poor, Extremely poor, Severe.
-- Only PM uses the last two.
M.LEVELS = { "good", "fair", "poor", "veryPoor", "extremelyPoor", "severe" }
-- SmartThings airQualityHealthConcern has six values too; map them one to one, in order.
M.CONCERN_FOR_LEVEL = {
  good = "good", fair = "moderate", poor = "slightlyUnhealthy", veryPoor = "unhealthy",
  extremelyPoor = "veryUnhealthy", severe = "hazardous",
}
M.CONCERN_VALUES = { "good", "moderate", "slightlyUnhealthy", "unhealthy", "veryUnhealthy", "hazardous" }
local LEVEL_RANK = {}
for i, v in ipairs(M.LEVELS) do LEVEL_RANK[v] = i end

-- Upper bound of each level; above the last bound is the next level.
-- Copied from the scale screens of the MyDyson app (2026-11-07, PH 358K).
local BANDS = {
  pm25 = { 35, 53, 70, 150, 250 },
  pm10 = { 50, 75, 100, 350, 420 },
  voc = { 3, 6, 8 },
  no2 = { 3, 6, 8 },
  hcho = { 0.097, 0.245, 0.490 },
}
-- The app shows VOC and NO2 as whole numbers (index 0.5 shows as 0) and bands them as shown.
local WHOLE_INDEX = { voc = true, no2 = true }

-- The SmartThings app draws its own NO2 bar for nitrogenDioxideMeasurement and reads the value as
-- ppm. Measured 2026-11-07 with virtual devices: the bar is linear, the full width is ~0.31 ppm,
-- and the marker stops at 82% from ~0.25 ppm. Dyson sends a 0-10 index, not ppm. At 0.025 ppm
-- per index point the bar color follows the Dyson level: 3 -> 25% green-yellow,
-- 6 -> 50% yellow, 8 -> 66% orange, 10 -> 82% red. The ppm number shown is therefore not a
-- real concentration.
M.NO2_PPM_PER_INDEX = 0.025

-- TVOC: SmartThings' tvocMeasurement only takes ppm, ppb or ug/m3, and Dyson sends a 0-10 index.
-- The index is mapped piecewise onto the common indoor TVOC guide bands (German UBA, ug/m3) so each
-- Dyson level lands in the matching band: good 0-<4 -> 0-300, fair 4-<7 -> 300-1000,
-- poor 7-<9 -> 1000-3000, very poor 9-10 -> 3000-10000. The number is not a real concentration.
local VOC_POINTS = { { 0, 0 }, { 4, 300 }, { 7, 1000 }, { 9, 3000 }, { 10, 10000 } }

function M.voc_ugm3(index)
  if index == nil then return nil end
  if index <= 0 then return 0 end
  for i = 2, #VOC_POINTS do
    local x0, y0 = VOC_POINTS[i - 1][1], VOC_POINTS[i - 1][2]
    local x1, y1 = VOC_POINTS[i][1], VOC_POINTS[i][2]
    if index <= x1 then return math.floor(y0 + (index - x0) * (y1 - y0) / (x1 - x0) + 0.5) end
  end
  return VOC_POINTS[#VOC_POINTS][2]
end

local function level(kind, value)
  if value == nil then return nil end
  if WHOLE_INDEX[kind] then value = math.floor(value) end
  local bands = BANDS[kind]
  for i, upper in ipairs(bands) do
    if value <= upper then return M.LEVELS[i] end
  end
  return M.LEVELS[#bands + 1]
end

local function worst(...)
  local result
  for i = 1, select("#", ...) do
    local l = select(i, ...)
    if l and (result == nil or LEVEL_RANK[l] > LEVEL_RANK[result]) then result = l end
  end
  return result
end

M.ANGLE_MIN, M.ANGLE_MAX, M.ANGLE_MIN_SPAN = 5, 355, 30

local function sleep_label(sltm)
  local minutes = num(sltm)
  if not minutes or minutes <= 0 then return M.OFF end
  if minutes >= 60 then
    return string.format("%d h %02d min left", minutes // 60, minutes % 60)
  end
  return string.format("%d min left", minutes)
end

-- Readable text for Dyson warning (wacd) and error (ercd) codes. Dyson does not publish them;
-- add codes here as they are observed. Unknown codes are shown as the raw code.
M.WARNING_TEXT = {
  FLTR = "Replace the filter", -- Dyson4J protocol notes
}
M.ERROR_TEXT = {}

-- Entries of the CURRENT-FAULTS report (status/faults topic) that are not "OK".
-- tnkp was seen as FAIL with the water tank removed (2026-11-07). The others are read from their
-- names and not yet seen failing.
M.FAULT_TEXT = {
  ["product-warnings.tnkp"] = "Water tank removed",
  ["product-warnings.tnke"] = "Water tank empty",
  ["product-warnings.fltr"] = "Replace the filter",
  ["product-warnings.cldu"] = "Deep clean needed",
}
local function active_faults(faults)
  local keys = {}
  for k, v in pairs(faults or {}) do
    if v ~= "OK" and v ~= "NONE" then keys[#keys + 1] = k end
  end
  table.sort(keys)
  return keys
end

local function is_error_key(key)
  return key:find("errors", 1, true) ~= nil
end

-- Text of the "Attention" section; the layout hides the section while it equals NO_PROBLEM.
M.NO_PROBLEM = "None"

-- Returns the Attention text and the list of problems in it (empty for NO_PROBLEM). The text can
-- be shortened to "<first> and N more"; the list always holds every problem.
function M.warning_text(err, warn, faults)
  local parts = {}
  for _, k in ipairs(active_faults(faults)) do
    local short = k:match("%.(.+)$") or k
    parts[#parts + 1] = M.FAULT_TEXT[k] or ((is_error_key(k) and "Dyson error " or "Dyson warning ") .. short)
  end
  if warn and warn ~= "NONE" then parts[#parts + 1] = M.WARNING_TEXT[warn] or ("Dyson warning " .. warn) end
  if err and err ~= "NONE" then parts[#parts + 1] = M.ERROR_TEXT[err] or ("Dyson error " .. err) end
  if #parts == 0 then return M.NO_PROBLEM, parts end
  local text = table.concat(parts, ", ")
  if #text > 80 then text = parts[1] .. string.format(" and %d more", #parts - 1) end
  return text, parts
end

-- Routine trigger for the Attention section (custom attentionAlert): "detected" while it shows any
-- message (warnings, errors, setup problems), "clear" while it shows NO_PROBLEM. The message itself
-- is free text, which routines cannot match reliably.
M.ALERT_DETECTED, M.ALERT_CLEAR = "detected", "clear"

function M.attention_alert(text)
  if text == nil then return nil end
  return text == M.NO_PROBLEM and M.ALERT_CLEAR or M.ALERT_DETECTED
end

-- True when parts (a list of problem texts) holds one that is not in announced (a set of texts).
-- A new problem re-announces a "detected" alert, so routines also notify about a second problem.
function M.has_new_problem(announced, parts)
  for _, p in ipairs(parts or {}) do
    if not (announced and announced[p]) then return true end
  end
  return false
end

-- A hardware fault is an error code or a failing *-errors entry; warnings (tank, filter) are not.
function M.has_error(err, faults)
  if err and err ~= "NONE" then return true end
  for _, k in ipairs(active_faults(faults)) do
    if is_error_key(k) then return true end
  end
  return false
end

-- What each function does right now, as one ball:
-- 🟢 running, 🟡 idle (on, but waiting: auto mode with clean air, humidity target reached),
-- 🔴 stopped by a warning (e.g. tank removed), ⚪ off, 🔵 deep clean. Only the ball is shown;
-- the row label names the function.
-- fnst says whether the fan turns: with the tank removed psta stayed CLNG while fnst went OFF and
-- the machine stopped (2026-11-07). msta HUMD = humidifying. There is no real cooling: the fan always
-- blows through the filter, so the purifier ball also says whether air is moving.
M.RUNNING, M.IDLE, M.STOPPED, M.OFF_BALL = "🟢", "🟡", "🔴", "⚪"

function M.right_now(raw, d)
  if raw.fnst == nil and raw.msta == nil then return nil end
  local night
  if d.night_mode ~= nil then night = d.night_mode and M.RUNNING or M.OFF_BALL end
  if d.power == false then
    return { purifier = M.OFF_BALL, humidifier = M.OFF_BALL, night_mode = night }
  end
  local blocked = #active_faults(raw.faults) > 0
  local waiting = blocked and M.STOPPED or M.IDLE
  local fan = raw.fnst == "FAN"
  local out = { purifier = fan and M.RUNNING or waiting, night_mode = night }
  if d.cleaning then
    local left = d.clean_minutes_left
    out.humidifier = left and string.format("🔵 %d min", left) or "🔵 Cleaning"
  elseif raw.msta == "HUMD" then
    out.humidifier = M.RUNNING
  elseif raw.hume == "HUMD" then
    out.humidifier = waiting
  else
    out.humidifier = M.OFF_BALL
  end
  return out
end

-- Level ball for the status card, in the Dyson app's colours.
M.LEVEL_BALL = { good = "🟢", fair = "🟡", poor = "🟠", veryPoor = "🔴", extremelyPoor = "🟣", severe = "⚫" }

function M.level_ball(level)
  return level and M.LEVEL_BALL[level] or nil
end

-- Derive normalized values from raw Dyson fields. Absent keys mean "unknown".
function M.derive(raw)
  local out = {}
  if raw.fpwr then out.power = (raw.fpwr == "ON") end

  local speed = num(raw.fnsp)
  if speed then out.percent = math.max(0, math.min(100, speed * 10)) end
  if raw.auto == "ON" or raw.fnsp == "AUTO" then
    out.fan_mode = "auto"
  elseif speed then
    out.fan_mode = speed <= 3 and "low" or (speed <= 7 and "medium" or "high")
  end

  if raw.nmod then out.night_mode = (raw.nmod == "ON") end
  if raw.rhtm then out.monitoring = (raw.rhtm == "ON") end
  if raw.sltm then out.sleep_timer = sleep_label(raw.sltm) end

  if raw.oson == "OFF" then
    out.oscillation = M.OFF
  elseif raw.oson == "ON" then
    out.oscillation = OSC_LABEL[raw.ancp] or "Custom"
  end
  out.lower_angle = num(raw.osal)
  out.upper_angle = num(raw.osau)
  if raw.fdir then out.airflow = (raw.fdir == "ON") and M.FRONT or M.BACK end

  if raw.hume then out.humidification = (raw.hume == "HUMD") end
  if raw.haut == "ON" then
    out.humidity_mode = M.AUTO
  elseif num(raw.humt) then
    out.humidity_mode = string.format("%d%%", num(raw.humt))
  end
  -- The picker keeps a stable "Auto" (routines compare against it); the target the Dyson works
  -- towards is shown separately: rect in auto mode, humt otherwise.
  out.auto_target_humidity = num(raw.rect)
  if raw.haut then
    out.humidity_auto = (raw.haut == "ON") and "on" or "off"
    local rect = num(raw.rect)
    out.humidity_auto_text = raw.haut ~= "ON" and "Off" or (rect and string.format("On (%d%%)", rect) or "On")
  end
  local target = raw.haut == "ON" and out.auto_target_humidity or num(raw.humt)
  if target then out.humidity_target_pct = math.max(M.HUMIDITY_MIN, math.min(M.HUMIDITY_MAX, target)) end

  if raw.wath then out.water_hardness = HARDNESS_LABEL[raw.wath] end
  -- cltr counts down from the hardness interval (hours) to the next deep clean.
  local cltr, interval = num(raw.cltr), num(raw.wath)
  if cltr and interval and interval > 0 then
    out.clean_life = math.max(0, math.min(100, math.floor(cltr * 100 / interval + 0.5)))
    out.clean_needed = cltr <= 0
  end
  out.clean_hours_left = cltr
  if raw.clcr then out.cleaning = (raw.clcr ~= "CLNO") end
  out.clean_minutes_left = num(raw.cdrr)

  out.hepa_life = num(raw.hflr)
  out.carbon_life = num(raw.cflr) -- "INV" (combined filter) -> nil

  local err, warn = raw.ercd, raw.wacd
  if err or warn or raw.faults then
    out.fault = M.has_error(err, raw.faults)
    out.fault_detail = string.format("error=%s warning=%s faults=%s", tostring(err), tostring(warn),
      table.concat(active_faults(raw.faults), ","))
    out.warning_text, out.warning_parts = M.warning_text(err, warn, raw.faults)
  end
  out.now = M.right_now(raw, out)
  out.rssi = num(raw.rssi)

  local tact = num(raw.tact)
  if tact then out.temperature_c = round(tact / 10 - 273.15, 1) end
  out.humidity = num(raw.hact)
  out.pm25 = num(raw.p25r) or num(raw.pm25)
  out.pm10 = num(raw.p10r) or num(raw.pm10)
  local va10, noxl, hchr = num(raw.va10), num(raw.noxl), num(raw.hchr)
  if va10 then
    out.voc_index = va10 / 10
    out.voc_ugm3 = M.voc_ugm3(out.voc_index)
  end
  if noxl then
    out.no2_index = noxl / 10
    out.no2_bar_ppm = round(out.no2_index * M.NO2_PPM_PER_INDEX, 3)
  end
  if hchr then out.hcho_mgm3 = round(hchr / 1000, 3) end

  out.level = {
    pm25 = level("pm25", out.pm25),
    pm10 = level("pm10", out.pm10),
    voc = level("voc", out.voc_index),
    no2 = level("no2", out.no2_index),
    hcho = level("hcho", out.hcho_mgm3),
  }
  -- The Dyson app rates overall air quality by the worst of PM2.5, PM10, VOC, NO2 and HCHO
  -- (seen 2026-11-07: HCHO 0.110 "Fair" with all others "Good" gives overall "Fair").
  out.level.overall = worst(out.level.pm25, out.level.pm10, out.level.voc, out.level.no2, out.level.hcho)
  return out
end

local function four(n)
  return string.format("%04d", n)
end

-- Each builder returns a Dyson "data" table, or nil for an invalid request.
M.commands = {}

function M.commands.power(on)
  return { fpwr = on and "ON" or "OFF" }
end

function M.commands.fan_mode(mode)
  if mode == "auto" then return { fpwr = "ON", auto = "ON" } end
  local step = SPEED_FOR_MODE[mode]
  if not step then return nil end
  return { fpwr = "ON", auto = "OFF", fnsp = four(step) }
end

function M.commands.percent(percent)
  if type(percent) ~= "number" then return nil end
  if percent <= 0 then return { fpwr = "OFF" } end
  local step = math.max(1, math.min(10, math.ceil(percent / 10)))
  return { fpwr = "ON", auto = "OFF", fnsp = four(step) }
end

function M.commands.night_mode(on)
  return { nmod = on and "ON" or "OFF" }
end

-- Dyson expects fpwr alongside rhtm; pass the current power state.
function M.commands.monitoring(on, power_on)
  return { fpwr = power_on and "ON" or "OFF", rhtm = on and "ON" or "OFF" }
end

-- The 358K ignores ancp CUST unless the angle range comes with it (seen 2026-11-07: the command
-- got an empty STATE-CHANGE and the app waited forever). Send the current range if it is a valid
-- sweep, else 135-225 (90 degrees around the front).
M.CUSTOM_DEFAULT_LOWER, M.CUSTOM_DEFAULT_UPPER = 135, 225

function M.commands.oscillation(label, lower, upper)
  if label == M.OFF then return { oson = "OFF" } end
  local code = OSC_CODE[label]
  if not code then return nil end
  local out = { fpwr = "ON", oson = "ON", ancp = code }
  if code == "CUST" then
    if not (lower and upper and upper - lower >= M.ANGLE_MIN_SPAN) then
      lower, upper = M.CUSTOM_DEFAULT_LOWER, M.CUSTOM_DEFAULT_UPPER
    end
    out.osal, out.osau = four(lower), four(upper)
  end
  return out
end

-- Set one oscillation edge, moving the other edge if needed to keep a valid sweep:
-- both edges in 5..355 and either equal or at least 30 degrees apart.
function M.commands.angle(which, value, lower, upper)
  if type(value) ~= "number" or (which ~= "lower" and which ~= "upper") then return nil end
  value = math.floor(value + 0.5)
  if value < M.ANGLE_MIN or value > M.ANGLE_MAX then return nil end
  lower = lower or M.ANGLE_MIN
  upper = upper or M.ANGLE_MAX
  if which == "lower" then
    lower = math.min(value, M.ANGLE_MAX - M.ANGLE_MIN_SPAN)
    if upper ~= lower and upper < lower + M.ANGLE_MIN_SPAN then upper = lower + M.ANGLE_MIN_SPAN end
  else
    upper = math.max(value, M.ANGLE_MIN + M.ANGLE_MIN_SPAN)
    if lower ~= upper and lower > upper - M.ANGLE_MIN_SPAN then lower = upper - M.ANGLE_MIN_SPAN end
  end
  return { fpwr = "ON", oson = "ON", ancp = "CUST", osal = four(lower), osau = four(upper) }
end

function M.commands.airflow(label)
  if label == M.FRONT then return { fdir = "ON" } end
  if label == M.BACK then return { fdir = "OFF" } end
  return nil
end

function M.commands.humidification(on)
  return { hume = on and "HUMD" or "OFF" }
end

function M.commands.humidity_mode(label)
  if label == M.AUTO or (type(label) == "string" and label:match("^" .. M.AUTO .. " %(%d+%%%)$")) then
    return { hume = "HUMD", haut = "ON" }
  end
  local pct = type(label) == "string" and tonumber(label:match("^(%d+)%%$"))
  if not pct or pct < M.HUMIDITY_MIN or pct > M.HUMIDITY_MAX then return nil end
  return { hume = "HUMD", haut = "OFF", humt = four(pct) }
end

-- Humidity control card: Auto switch and Target slider. Moving the slider sets a manual target;
-- switching Auto off keeps the target the Dyson is using now.
function M.commands.humidity_auto(state, current_target)
  if state == "on" then return { hume = "HUMD", haut = "ON" } end
  if state ~= "off" then return nil end
  local pct = tonumber(current_target) or 45
  pct = math.max(M.HUMIDITY_MIN, math.min(M.HUMIDITY_MAX, math.floor(pct / 5 + 0.5) * 5))
  return { hume = "HUMD", haut = "OFF", humt = four(pct) }
end

function M.commands.humidity_target(target)
  local pct = tonumber(target)
  if not pct then return nil end
  pct = math.floor(pct / 5 + 0.5) * 5
  if pct < M.HUMIDITY_MIN or pct > M.HUMIDITY_MAX then return nil end
  return { hume = "HUMD", haut = "OFF", humt = four(pct) }
end

function M.commands.water_hardness(label)
  local code = HARDNESS_CODE[label]
  if not code then return nil end
  return { wath = code }
end

function M.commands.sleep_timer(label)
  if label == M.OFF then return { sltm = "OFF" } end
  local minutes = SLEEP_MINUTES[label]
  if not minutes then return nil end
  return { sltm = four(minutes) }
end

function M.commands.reset_filter()
  return { rstf = "RSTF" }
end

function M.state_set(data, now)
  return { msg = "STATE-SET", time = now, ["mode-reason"] = "LAPP", data = data }
end

function M.request(kind, now)
  return { msg = kind, time = now }
end

M.REQUEST_STATE = "REQUEST-CURRENT-STATE"
M.REQUEST_SENSORS = "REQUEST-PRODUCT-ENVIRONMENT-CURRENT-SENSOR-DATA"
M.REQUEST_FAULTS = "REQUEST-CURRENT-FAULTS"

-- Dyson advertises its local broker over mDNS as "<type prefix>_<serial>", e.g. "358_AB1-EU-CDE2345F"
-- (seen 2026-11-07 on the 358K, A record = broker address).
M.MDNS_SERVICE, M.MDNS_DOMAIN = "_dyson_mqtt._tcp", "local"

local function ipv4(addr)
  if type(addr) ~= "string" then return nil end
  local a, b, c, d = addr:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return nil end
  for _, octet in ipairs({ a, b, c, d }) do
    if tonumber(octet) > 255 then return nil end
  end
  return addr
end
M.ipv4 = ipv4

-- Placeholders in the profile: the driver then uses what discovery and detection found.
M.PLACEHOLDER_SERIAL, M.AUTO_MODEL = "SERIAL", "auto"

-- Devices created by discovery carry type prefix and serial in their network id.
function M.network_id(prefix, serial)
  return "dyson:" .. prefix .. ":" .. serial
end

function M.parse_network_id(id)
  if type(id) ~= "string" then return nil end
  local prefix, serial = id:match("^dyson:(%w+):(.+)$")
  return prefix, serial
end

-- Dyson devices found in an st.mdns discover() "found" list: { {prefix, serial, ip} }.
function M.mdns_devices(found)
  local out, seen = {}, {}
  for _, f in ipairs(found or {}) do
    local name = f.service_info and f.service_info.name or ""
    local prefix, serial = name:match("^(%w+)_([%w%-]+)")
    local addr = ipv4(f.host_info and f.host_info.address)
    if prefix and serial then
      if not seen[serial] then
        seen[serial] = { prefix = prefix, serial = serial, ip = addr }
        out[#out + 1] = seen[serial]
      elseif not seen[serial].ip then
        seen[serial].ip = addr -- the IPv4 record can come after an IPv6 one
      end
    end
  end
  return out
end

-- mDNS names carry only the numeric type ("358"); the MQTT topics use the full model ("358K").
-- These are tried at first connect; the one the Dyson answers on wins.
function M.model_candidates(prefix)
  if type(prefix) ~= "string" or prefix == "" then return {} end
  if not prefix:match("^%d+$") then return { prefix } end
  return { prefix .. "K", prefix .. "E", prefix .. "M", prefix }
end

function M.model_from_topic(topic, serial)
  if type(topic) ~= "string" or type(serial) ~= "string" then return nil end
  local model, rest = topic:match("^([^/]+)/(.+)$")
  if rest == serial .. "/status/current" then return model end
  return nil
end

local LABELS = { ["358"] = "Dyson Humidify+Cool" }
function M.label_for_prefix(prefix)
  return LABELS[prefix] or ("Dyson " .. tostring(prefix))
end

-- Messages for the Attention section while the device cannot connect.
M.SETUP_TEXT = {
  no_password = "Enter the local MQTT password in Settings",
  wrong_password = "Local MQTT password is wrong",
  no_serial = "Serial number missing in Settings",
  no_model = "Model not detected: set Product type in Settings",
  not_found = "Dyson not found on the network",
  offline = "Dyson not reachable",
}

function M.setup_text_for_error(err)
  local rc = tostring(err):match("CONNACK refused rc=(%d+)")
  if rc == "4" or rc == "5" then return M.SETUP_TEXT.wrong_password end
  return nil
end

-- Pick the broker address from an st.mdns discover() "found" list. A record whose service name
-- carries the serial wins. A named record without the serial is another Dyson and is skipped.
-- Records without a name are accepted only if exactly one address remains.
function M.pick_mdns_address(found, serial)
  local others, other_count = {}, 0
  for _, f in ipairs(found or {}) do
    local addr = ipv4(f.host_info and f.host_info.address)
    local name = f.service_info and f.service_info.name or ""
    if addr and serial and serial ~= "" and name:find(serial, 1, true) then return addr end
    if addr and name == "" then
      if not others[addr] then
        others[addr] = true
        other_count = other_count + 1
      end
    end
  end
  if other_count == 1 then return next(others) end
  return nil
end

return M
