local Driver = require "st.driver"
local capabilities = require "st.capabilities"
local json = require "st.json"
local log = require "log"
local cosock = require "cosock"

local mqtt = require "mqtt"
local dyson = require "dyson"
local VERSION = require "driver_version"

-- st.mdns ships with newer hub firmware; without it the driver falls back to stored addresses.
local has_mdns, mdns = pcall(require, "st.mdns")

-- The profile keeps this name; SmartThings updates it in place on each driver install.
local PROFILE = "dyson-358k"
local NS = "fabrictitle08390"
local ANGLE_ID = NS .. ".oscillationAngle"
local ACTIVITY_ID = NS .. ".activity"
-- Humidifier: Auto switch (with the auto target in its text) and a Target slider shown only in manual.
local AUTO_ID = NS .. ".autoHumidity"
local TARGET_ID = NS .. ".targetHumidity"
local ATTENTION_ID = NS .. ".attention"
-- Attention as detected/clear, so a routine can notify on any problem (dyson.attention_alert).
local ALERT_ID = NS .. ".attentionAlert"
local AIR_ID = NS .. ".airQuality"
-- After a command, the link counts as dead if the Dyson sends nothing for this long.
local COMMAND_REPLY_SECONDS = 10
-- Persisted device field: name of the profile the driver last assigned to the device.
local PROFILE_FIELD = "profile"
local DEFAULT_IP = "0.0.0.0"
local SENSOR_REFRESH_SECONDS = 60
-- Re-send every value this often, so an event the cloud rejected does not stay missing until the
-- value changes. The early re-sends below cover driver updates, so hourly is enough.
local RESEND_ALL_SECONDS = 60 * 60
-- Events right after a driver update can be dropped by the cloud for a minute or more (seen with a new
-- custom capability); re-send everything at these times after connecting, then every RESEND_ALL_SECONDS.
local EARLY_RESENDS = { 30, 120 }
local HEPA_REPLACE_PERCENT = 5
local HIDDEN = { visibility = { displayed = false } }
-- Persisted device field: the broker address of the last successful connection.
local LAST_IP_FIELD = "last_ip"
-- Unreachable this long: Attention says so and the routine alert goes up. Shorter outages (a Wi-Fi
-- drop, a Dyson reboot, the first mDNS lookup) only change the text, so they do not notify.
local OFFLINE_ALERT_SECONDS = 5 * 60
-- Persisted device field: the problems the routine alert last announced, one per line, so a driver
-- restart does not announce them again.
local ALERTED_FIELD = "alerted_problems"

-- device.id -> { gen = n, client = mqtt client or nil, raw = {} (Dyson fields),
--   last = {} (values sent; cleared for re-sends), logged = {} (log/skip markers; kept) }
local conns = {}

local function now_iso()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

-- The MQTT password should not ship inside the driver package (profile defaults are uploaded with
-- it). The driver keeps the last real password in a persisted device field, which lives on the hub,
-- so the profile can carry the placeholder "password". A password entered in the app replaces it.
local PASSWORD_FIELD = "mqtt_password"
local PLACEHOLDER_PASSWORD = "password"

local function real_password(v)
  return type(v) == "string" and v ~= "" and v ~= PLACEHOLDER_PASSWORD
end

local function effective_password(device)
  local p = device.preferences and device.preferences.localPassword
  if real_password(p) then
    if device:get_field(PASSWORD_FIELD) ~= p then device:set_field(PASSWORD_FIELD, p, { persist = true }) end
    return p
  end
  local stored = device:get_field(PASSWORD_FIELD)
  if real_password(stored) then return stored end
  return nil
end

-- Serial and model: the settings if they hold real values, else what discovery (network id) and
-- model detection found; both are kept in persisted fields after a successful connect.
local SERIAL_FIELD, MODEL_FIELD = "serial", "model"
local MODEL_DETECT_SECONDS = 8

local function real_value(v, placeholder)
  return type(v) == "string" and v ~= "" and v ~= placeholder
end

local function device_serial(device)
  local p = device.preferences or {}
  if real_value(p.serialNumber, dyson.PLACEHOLDER_SERIAL) then return p.serialNumber end
  local _, serial = dyson.parse_network_id(device.device_network_id)
  return serial or device:get_field(SERIAL_FIELD)
end

local function device_model(device)
  local p = device.preferences or {}
  if real_value(p.productType, dyson.AUTO_MODEL) then return p.productType end
  return device:get_field(MODEL_FIELD)
end

local function device_prefix(device)
  local prefix = dyson.parse_network_id(device.device_network_id)
  if prefix then return prefix end
  local model = device_model(device)
  return model and model:match("^(%d+)")
end

-- nil when the device can try to connect, else the Attention text explaining what is missing.
local function setup_problem(device)
  if not device_serial(device) then return dyson.SETUP_TEXT.no_serial end
  if not effective_password(device) then return dyson.SETUP_TEXT.no_password end
  if not device_model(device) and #dyson.model_candidates(device_prefix(device)) == 0 then
    return dyson.SETUP_TEXT.no_model
  end
  return nil
end

-- Broker address, in order: the Dyson found over mDNS (follows DHCP changes), the last address
-- that worked, then the IP preference. Returns host, source; or nil when none is known.
local function resolve_host(device)
  local p = device.preferences
  if has_mdns then
    local ok, res, err = pcall(mdns.discover, dyson.MDNS_SERVICE, dyson.MDNS_DOMAIN)
    if ok and res then
      local addr = dyson.pick_mdns_address(res.found, device_serial(device))
      if addr then return addr, "mDNS" end
      log.info("dyson: no matching Dyson in mDNS reply")
    else
      log.warn("dyson: mDNS lookup failed: " .. tostring(ok and err or res))
    end
  end
  local last = dyson.ipv4(device:get_field(LAST_IP_FIELD))
  if last then return last, "last known" end
  local pref = dyson.ipv4(p.ipAddress)
  if pref and pref ~= DEFAULT_IP then return pref, "preference" end
  return nil
end

local function emit(device, component_id, event)
  local component = device.profile.components[component_id]
  if not component then
    log.warn("dyson: profile lacks component " .. component_id)
    return
  end
  device:emit_component_event(component, event)
end

local function emit_supported(device)
  local c = capabilities
  emit(device, "main", c.airPurifierFanMode.supportedAirPurifierFanModes(dyson.FAN_MODES, HIDDEN))
  emit(device, "main", c.airQualityHealthConcern.supportedAirQualityValues(dyson.CONCERN_VALUES, HIDDEN))
  emit(device, "main", c.tvocHealthConcern.supportedTvocValues(dyson.CONCERN_VALUES, HIDDEN))
  emit(device, "main", c.formaldehydeHealthConcern.supportedFormaldehydeValues(dyson.CONCERN_VALUES, HIDDEN))
  emit(device, "filter", c.filterState.supportedFilterCommands({ "resetFilter" }, HIDDEN))
  emit(device, "deepClean", c.filterState.supportedFilterCommands({}, HIDDEN))
  emit(device, "humidifier", c.mode.supportedModes(dyson.HUMIDITY_MODES, HIDDEN))
  emit(device, "oscillation", c.mode.supportedModes(dyson.OSCILLATION_MODES, HIDDEN))
  emit(device, "airflow", c.mode.supportedModes(dyson.AIRFLOW_MODES, HIDDEN))
  emit(device, "sleepTimer", c.mode.supportedModes(dyson.SLEEP_TIMER_MODES, HIDDEN))
  emit(device, "waterHardness", c.mode.supportedModes(dyson.WATER_HARDNESS_MODES, HIDDEN))
end

local function on_off(cap, v)
  return v and cap.switch.on() or cap.switch.off()
end

-- Emits make(value) unless value is what was last sent under component_id.key. Returns true when
-- the value is in place (sent now or before).
local function emit_once(device, conn, component_id, key, value, make)
  if value == nil then return false end
  local cache_key = component_id .. "." .. key
  if conn.last[cache_key] == value then return true end
  -- The hub caches capability definitions; a just-changed custom capability can lack an
  -- attribute for a while. Skip that value instead of crashing the session.
  local ok, event = pcall(make, value)
  if not ok or event == nil then
    if not conn.logged["skip." .. cache_key] then
      conn.logged["skip." .. cache_key] = true
      log.warn("dyson: cannot build event " .. cache_key .. ": " .. tostring(event))
    end
    return false
  end
  conn.last[cache_key] = value
  emit(device, component_id, event)
  return true
end

local function load_alerted(device)
  local set = {}
  for p in tostring(device:get_field(ALERTED_FIELD) or ""):gmatch("[^\n]+") do set[p] = true end
  return set
end

-- Attention message, then the routine alert (after the message, so the device page already shows
-- it when the notification arrives). parts lists the problems in text. raise = false updates only
-- the message: a connection problem that has not lasted OFFLINE_ALERT_SECONDS yet.
local function set_attention(device, conn, text, parts, raise)
  if text == nil then return end
  emit_once(device, conn, "main", "attention", text, function(v) return capabilities[ATTENTION_ID].message(v) end)
  if not raise then return end
  parts = parts or {}
  local alert = dyson.attention_alert(text)
  -- A new problem while the alert already says "detected" is sent again as a state change, so
  -- routines fire for it too (as for a repeated button push).
  local fresh = alert == dyson.ALERT_DETECTED and dyson.has_new_problem(conn.alerted, parts)
  if fresh then conn.last["main.attention_alert"] = nil end
  local in_place = emit_once(device, conn, "main", "attention_alert", alert, function(v)
    local attr = capabilities[ALERT_ID].alert
    if fresh then return attr(v, { state_change = true }) end
    return attr(v)
  end)
  if not in_place then return end
  local set, lines = {}, {}
  for _, p in ipairs(parts) do
    if not set[p] then
      set[p] = true
      lines[#lines + 1] = p
    end
  end
  conn.alerted = set
  local joined = table.concat(lines, "\n")
  if (device:get_field(ALERTED_FIELD) or "") ~= joined then
    device:set_field(ALERTED_FIELD, joined, { persist = true })
  end
end

local function emit_changed(device, conn, d)
  local c = capabilities
  local function once(component_id, key, value, make)
    emit_once(device, conn, component_id, key, value, make)
  end

  once("main", "power", d.power, function(v) return on_off(c.switch, v) end)
  once("main", "fan_mode", d.fan_mode, function(v) return c.airPurifierFanMode.airPurifierFanMode(v) end)
  once("main", "percent", d.percent, function(v) return c.fanSpeedPercent.percent(v) end)
  once("main", "temperature", d.temperature_c, function(v)
    return c.temperatureMeasurement.temperature({ value = v, unit = "C" })
  end)
  once("main", "humidity", d.humidity, function(v) return c.relativeHumidityMeasurement.humidity(v) end)
  -- One standard measurement per pollutant, so the app draws a history graph for each.
  once("main", "pm25", d.pm25, function(v) return c.dustSensor.fineDustLevel(v) end)
  once("main", "pm10", d.pm10, function(v) return c.dustSensor.dustLevel(v) end)
  -- Dyson reports VOC and NO2 as a 0-10 index; both are mapped to a believable concentration so
  -- the app's number and graph follow the Dyson level (dyson.voc_ugm3, dyson.NO2_PPM_PER_INDEX).
  once("main", "voc", d.voc_ugm3, function(v)
    return c.tvocMeasurement.tvocLevel({ value = v, unit = "ug/m3" })
  end)
  -- NO2 is scaled so the app's own NO2 bar lands on the Dyson level color (dyson.NO2_PPM_PER_INDEX).
  once("main", "no2", d.no2_bar_ppm, function(v)
    return c.nitrogenDioxideMeasurement.nitrogenDioxide({ value = v, unit = "ppm" })
  end)
  once("main", "hcho", d.hcho_mgm3, function(v)
    return c.formaldehydeMeasurement.formaldehydeLevel({ value = v, unit = "mg/m^3" })
  end)
  -- The app shows TVOC and formaldehyde as bare numbers; these rows add the Dyson level as text.
  once("main", "voc_level", d.level.voc and dyson.CONCERN_FOR_LEVEL[d.level.voc], function(v)
    return c.tvocHealthConcern.tvocHealthConcern(v)
  end)
  once("main", "hcho_level", d.level.hcho and dyson.CONCERN_FOR_LEVEL[d.level.hcho], function(v)
    return c.formaldehydeHealthConcern.formaldehydeHealthConcern(v)
  end)
  local overall = d.level.overall
  once("main", "aq", overall and dyson.CONCERN_FOR_LEVEL[overall], function(v)
    return c.airQualityHealthConcern.airQualityHealthConcern(v)
  end)
  once("filter", "hepa", d.hepa_life, function(v) return c.filterState.filterLifeRemaining(v) end)
  once("filter", "hepa_status", d.hepa_life and (d.hepa_life <= HEPA_REPLACE_PERCENT), function(v)
    return c.filterStatus.filterStatus(v and "replace" or "normal")
  end)
  once("status", "fault", d.fault, function(v)
    return c.hardwareFault.hardwareFault(v and "detected" or "clear")
  end)
  if d.fault_detail and d.warning_text ~= dyson.NO_PROBLEM and conn.logged.fault_detail ~= d.fault_detail then
    conn.logged.fault_detail = d.fault_detail
    log.warn("dyson: device reports " .. d.fault_detail)
  end
  once("status", "rssi", d.rssi, function(v) return c.signalStrength.rssi({ value = v, unit = "dBm" }) end)
  local now, act = d.now or {}, c[ACTIVITY_ID]
  once("main", "act_purifier", now.purifier, function(v) return act.purifier(v) end)
  once("main", "act_humidifier", now.humidifier, function(v) return act.humidifier(v) end)
  once("main", "act_night", now.night_mode, function(v) return act.nightMode(v) end)
  local ball, air = dyson.level_ball, c[AIR_ID]
  once("main", "air_overall", ball(d.level.overall), function(v) return air.overall(v) end)
  once("main", "air_pm25", ball(d.level.pm25), function(v) return air.fineDust(v) end)
  once("main", "air_pm10", ball(d.level.pm10), function(v) return air.dust(v) end)
  once("main", "air_voc", ball(d.level.voc), function(v) return air.voc(v) end)
  once("main", "air_no2", ball(d.level.no2), function(v) return air.nitrogenDioxide(v) end)
  once("main", "air_hcho", ball(d.level.hcho), function(v) return air.formaldehyde(v) end)
  set_attention(device, conn, d.warning_text, d.warning_parts, true)

  once("humidifier", "on", d.humidification, function(v) return on_off(c.switch, v) end)
  once("humidifier", "mode", d.humidity_mode, function(v) return c.mode.mode(v) end)
  once("humidifier", "auto", d.humidity_auto, function(v) return c[AUTO_ID].autoMode(v) end)
  once("humidifier", "auto_text", d.humidity_auto_text, function(v) return c[AUTO_ID].display(v) end)
  once("humidifier", "target", d.humidity_target_pct, function(v)
    return c[TARGET_ID].target({ value = v, unit = "%" })
  end)
  once("oscillation", "mode", d.oscillation, function(v) return c.mode.mode(v) end)
  once("oscillation", "lower", d.lower_angle, function(v) return c[ANGLE_ID].lowerAngle(v) end)
  once("oscillation", "upper", d.upper_angle, function(v) return c[ANGLE_ID].upperAngle(v) end)
  once("airflow", "mode", d.airflow, function(v) return c.mode.mode(v) end)
  once("nightMode", "on", d.night_mode, function(v) return on_off(c.switch, v) end)
  once("sleepTimer", "mode", d.sleep_timer, function(v) return c.mode.mode(v) end)
  once("monitoring", "on", d.monitoring, function(v) return on_off(c.switch, v) end)
  once("waterHardness", "mode", d.water_hardness, function(v) return c.mode.mode(v) end)
  once("deepClean", "life", d.clean_life, function(v) return c.filterState.filterLifeRemaining(v) end)
  once("deepClean", "status", d.clean_needed, function(v)
    return c.filterStatus.filterStatus(v and "replace" or "normal")
  end)
  if d.cleaning and conn.logged.cleaning ~= true then
    log.info("dyson: deep clean running, " .. tostring(d.clean_minutes_left) .. " min left")
  end
  conn.logged.cleaning = d.cleaning
end

local function send_request(_, conn, kind)
  if not (conn.client and conn.topics) then return nil, "not connected" end
  return conn.client:publish(conn.topics.command, json.encode(dyson.request(kind, now_iso())))
end

-- Ask for the state on every candidate model topic; the topic the Dyson answers on names the model.
local function detect_model(device, conn, client, serial)
  conn.detected = nil
  for _, model in ipairs(dyson.model_candidates(device_prefix(device))) do
    local t = dyson.topics(model, serial)
    client:subscribe(t.status)
    client:publish(t.command, json.encode(dyson.request(dyson.REQUEST_STATE, now_iso())))
  end
  local deadline = os.time() + MODEL_DETECT_SECONDS
  while not conn.detected and os.time() < deadline do
    if not client:poll(1) then break end
  end
  if conn.detected then
    device:set_field(MODEL_FIELD, conn.detected, { persist = true })
    log.info("dyson: detected model " .. conn.detected)
  end
  return conn.detected
end

local function handle_message(device, conn, _, payload)
  local ok, msg = pcall(json.decode, payload)
  if not ok or type(msg) ~= "table" then
    log.warn("dyson: undecodable payload")
    return
  end
  conn.awaiting_reply = nil
  -- A state change can come from a fault (e.g. tank removed stops the machine); fetch the faults.
  if msg.msg == "STATE-CHANGE" and conn.client then send_request(device, conn, dyson.REQUEST_FAULTS) end
  if dyson.merge(conn.raw, msg) then
    emit_changed(device, conn, dyson.derive(conn.raw))
  end
end

-- One connection attempt. Returns when the link drops or the generation changes.
local function session(device, conn, gen, host, source)
  local serial, model = device_serial(device), device_model(device)
  conn.topics = nil
  local client = mqtt.new({
    socket_factory = function()
      local s, e = cosock.socket.tcp()
      if s then return s end
      log.warn("dyson: tcp() failed: " .. tostring(e))
      if cosock.socket.tcp4 then return cosock.socket.tcp4() end
      return nil, e
    end,
    host = host,
    port = 1883,
    client_id = "st-" .. device.id:sub(1, 8) .. "-" .. os.time(),
    username = serial,
    password = effective_password(device),
    keepalive = 30,
    on_message = function(topic, payload)
      if not conn.topics then
        conn.detected = conn.detected or dyson.model_from_topic(topic, serial)
        return
      end
      handle_message(device, conn, topic, payload)
    end,
  })
  local ok, err = client:connect()
  if not ok then
    client:close()
    return nil, err
  end
  conn.client = client
  if not model then
    model = detect_model(device, conn, client, serial)
    if not model then
      conn.client = nil
      client:close()
      return nil, "model not detected"
    end
  end
  local topics = dyson.topics(model, serial)
  conn.topics = topics
  client:subscribe(topics.status)
  client:subscribe(topics.faults)
  emit_supported(device)
  send_request(device, conn, dyson.REQUEST_STATE)
  send_request(device, conn, dyson.REQUEST_SENSORS)
  send_request(device, conn, dyson.REQUEST_FAULTS)
  -- The state reply also refreshes Attention; without one within COMMAND_REPLY_SECONDS the link
  -- counts as dead, so an old setup or offline message does not stay up on a silent link.
  conn.awaiting_reply, conn.awaiting_what = os.time(), "state request"
  conn.down_since = nil
  device:online()
  for field, value in pairs({ [LAST_IP_FIELD] = host, [SERIAL_FIELD] = serial, [MODEL_FIELD] = model }) do
    if device:get_field(field) ~= value then device:set_field(field, value, { persist = true }) end
  end
  log.info("dyson: driver " .. VERSION .. " connected to " .. host .. " (" .. source .. ")")

  local last_sensor = os.time()
  local connected_at = os.time()
  local last_resend = os.time()
  local early = 1
  local result_err
  while conns[device.id] and conns[device.id].gen == gen do
    local pok, perr = client:poll(2)
    if not pok then
      result_err = perr
      break
    end
    if conn.awaiting_reply and os.time() - conn.awaiting_reply >= COMMAND_REPLY_SECONDS then
      result_err = "no reply to " .. (conn.awaiting_what or "command") .. " within " .. COMMAND_REPLY_SECONDS .. " s"
      break
    end
    local due_early = EARLY_RESENDS[early] and os.time() - connected_at >= EARLY_RESENDS[early]
    if due_early or os.time() - last_resend >= RESEND_ALL_SECONDS then
      if due_early then early = early + 1 end
      last_resend = os.time()
      conn.last = {}
      if next(conn.raw) then emit_changed(device, conn, dyson.derive(conn.raw)) end
    end
    if os.time() - last_sensor >= SENSOR_REFRESH_SECONDS then
      last_sensor = os.time()
      send_request(device, conn, dyson.REQUEST_SENSORS)
      send_request(device, conn, dyson.REQUEST_FAULTS)
    end
  end
  conn.client = nil
  conn.topics = nil
  client:close()
  return true, result_err
end

local function run(device, gen)
  local backoff = 2
  while conns[device.id] and conns[device.id].gen == gen do
    local conn = conns[device.id]
    local problem = setup_problem(device)
    if problem then
      set_attention(device, conn, problem, { problem }, true)
      device:offline()
      cosock.socket.sleep(10)
    else
      -- Connection problem for Attention, and whether it raises the alert at once. A wrong password
      -- does; "not found" and "model not detected" can be passing, like a dropped link.
      local text, at_once
      local host, source = resolve_host(device)
      if not host then
        log.warn("dyson: Dyson not found over mDNS and no IP address set")
        text = dyson.SETUP_TEXT.not_found
      else
        local ok, err, link_err = pcall(session, device, conn, gen, host, source)
        if not ok then
          log.error("dyson: session crashed: " .. tostring(err))
        elseif err == nil and link_err then
          log.warn("dyson: connect to " .. host .. " failed: " .. tostring(link_err))
          if link_err == "model not detected" then
            text = dyson.SETUP_TEXT.no_model
          else
            text = dyson.setup_text_for_error(link_err)
            at_once = text ~= nil
          end
        else
          backoff = 2
          -- No error means the session ended on purpose (settings changed, driver restarting).
          if link_err then log.warn("dyson: link dropped: " .. tostring(link_err)) end
        end
      end
      local current = conns[device.id]
      if current and current.gen == gen then
        device:offline()
        current.awaiting_reply = nil
        current.down_since = current.down_since or os.time()
        local long = os.time() - current.down_since >= OFFLINE_ALERT_SECONDS
        if not text and long then text = dyson.SETUP_TEXT.offline end
        if text then set_attention(device, current, text, { text }, at_once or long) end
        -- Sleep in 1 s steps so a command from the app can trigger an immediate retry.
        local woken = false
        for _ = 1, backoff do
          if current.wake then
            woken = true
            break
          end
          cosock.socket.sleep(1)
        end
        current.wake = false
        backoff = woken and 2 or math.min(backoff * 2, 60)
      end
    end
  end
end

local function start(_, device)
  -- Devices created before 0.1.0 use an older profile name (dyson-358k.v4/.v5); move them once.
  if device:get_field(PROFILE_FIELD) ~= PROFILE then
    log.info("dyson: driver " .. VERSION .. ", switching device to profile " .. PROFILE)
    device:try_update_metadata({ profile = PROFILE })
    device:set_field(PROFILE_FIELD, PROFILE, { persist = true })
  end
  local prev = conns[device.id]
  local gen = (prev and prev.gen or 0) + 1
  if prev and prev.client then pcall(function() prev.client:close() end) end
  conns[device.id] = { gen = gen, raw = {}, last = {}, logged = {}, alerted = load_alerted(device) }
  cosock.spawn(function() run(device, gen) end, "dyson-" .. device.id)
end

local function stop(_, device)
  local c = conns[device.id]
  if c and c.client then pcall(function() c.client:close() end) end
  conns[device.id] = nil
end

local function send_state(device, data)
  if not data then
    log.warn("dyson: rejected invalid command")
    return
  end
  local conn = conns[device.id]
  if not (conn and conn.client) then
    log.warn("dyson: command dropped, not connected; reconnecting now")
    if conn then conn.wake = true end
    return
  end
  if not conn.topics then
    log.warn("dyson: command dropped, still connecting")
    return
  end
  local ok = conn.client:publish(conn.topics.command, json.encode(dyson.state_set(data, now_iso())))
  -- Ask for the state too: the Dyson always answers that, so silence means the link is dead.
  if ok then ok = send_request(device, conn, dyson.REQUEST_STATE) end
  if not ok then
    conn.awaiting_reply, conn.awaiting_what = 0, "command"
  elseif not conn.awaiting_reply then
    conn.awaiting_reply, conn.awaiting_what = os.time(), "command"
  end
end

-- Current device state, from the Dyson's own messages. Never use conn.last for this: it is
-- cleared for every re-send, and a cleared power value made the monitoring toggle switch the
-- Dyson off.
local function live_state(device)
  local conn = conns[device.id]
  if not conn then return {} end
  return dyson.derive(conn.raw)
end

local function power_is_on(device)
  return live_state(device).power == true
end

local function handle_switch(on)
  return function(_, device, cmd)
    local component = cmd.component
    if component == "main" then
      send_state(device, dyson.commands.power(on))
    elseif component == "humidifier" then
      send_state(device, dyson.commands.humidification(on))
    elseif component == "nightMode" then
      send_state(device, dyson.commands.night_mode(on))
    elseif component == "monitoring" then
      send_state(device, dyson.commands.monitoring(on, power_is_on(device)))
    else
      log.warn("dyson: switch on unknown component " .. tostring(component))
    end
  end
end

local MODE_BUILDERS = {
  humidifier = dyson.commands.humidity_mode,
  oscillation = dyson.commands.oscillation,
  airflow = dyson.commands.airflow,
  sleepTimer = dyson.commands.sleep_timer,
  waterHardness = dyson.commands.water_hardness,
}

local function handle_set_mode(_, device, cmd)
  local builder = MODE_BUILDERS[cmd.component]
  if not builder then
    log.warn("dyson: setMode on unknown component " .. tostring(cmd.component))
    return
  end
  if cmd.component == "oscillation" then
    local d = live_state(device)
    send_state(device, builder(cmd.args.mode, d.lower_angle, d.upper_angle))
  else
    send_state(device, builder(cmd.args.mode))
  end
end

local function handle_angle(device, which, value)
  local d = live_state(device)
  send_state(device, dyson.commands.angle(which, value, d.lower_angle, d.upper_angle))
end

local function handle_refresh(_, device)
  local conn = conns[device.id]
  if conn and conn.client then
    conn.last = {}
    send_request(device, conn, dyson.REQUEST_STATE)
    send_request(device, conn, dyson.REQUEST_SENSORS)
    send_request(device, conn, dyson.REQUEST_FAULTS)
  end
end

-- "Scan nearby": one device per Dyson found over mDNS, keyed by serial so a scan never duplicates.
local function discovery(driver, _, _)
  log.info("dyson: discovery started")
  if not has_mdns then
    log.warn("dyson: this hub has no mDNS support; discovery needs it")
    return
  end
  local known = {}
  for _, d in ipairs(driver:get_devices()) do
    local serial = device_serial(d)
    if serial then known[serial] = true end
  end
  local ok, res = pcall(mdns.discover, dyson.MDNS_SERVICE, dyson.MDNS_DOMAIN)
  if not (ok and res) then
    log.warn("dyson: mDNS lookup failed: " .. tostring(res))
    return
  end
  for _, found in ipairs(dyson.mdns_devices(res.found)) do
    if known[found.serial] then
      log.info("dyson: " .. found.serial .. " already added")
    else
      known[found.serial] = true
      local created, err = driver:try_create_device({
        type = "LAN",
        device_network_id = dyson.network_id(found.prefix, found.serial),
        label = dyson.label_for_prefix(found.prefix),
        profile = PROFILE,
        manufacturer = "Dyson",
        model = found.prefix,
        vendor_provided_label = "Dyson " .. found.prefix,
      })
      log.info("dyson: added " .. found.serial .. " -> " .. tostring(created) .. " " .. tostring(err))
    end
  end
end

local c = capabilities
local driver = Driver("dyson-humidify-cool-local", {
  discovery = discovery,
  lifecycle_handlers = {
    init = start,
    infoChanged = start,
    removed = stop,
  },
  capability_handlers = {
    [c.switch.ID] = {
      [c.switch.commands.on.NAME] = handle_switch(true),
      [c.switch.commands.off.NAME] = handle_switch(false),
    },
    [c.airPurifierFanMode.ID] = {
      [c.airPurifierFanMode.commands.setAirPurifierFanMode.NAME] = function(_, device, cmd)
        send_state(device, dyson.commands.fan_mode(cmd.args.airPurifierFanMode))
      end,
    },
    [c.fanSpeedPercent.ID] = {
      [c.fanSpeedPercent.commands.setPercent.NAME] = function(_, device, cmd)
        send_state(device, dyson.commands.percent(cmd.args.percent))
      end,
    },
    [c.mode.ID] = {
      [c.mode.commands.setMode.NAME] = handle_set_mode,
    },
    [c.filterState.ID] = {
      [c.filterState.commands.resetFilter.NAME] = function(_, device, cmd)
        if cmd.component == "filter" then
          send_state(device, dyson.commands.reset_filter())
        else
          log.warn("dyson: resetFilter ignored on " .. tostring(cmd.component))
        end
      end,
    },
    [AUTO_ID] = {
      setAutoMode = function(_, device, cmd)
        send_state(device, dyson.commands.humidity_auto(cmd.args.state, live_state(device).humidity_target_pct))
      end,
    },
    [TARGET_ID] = {
      setTarget = function(_, device, cmd) send_state(device, dyson.commands.humidity_target(cmd.args.target)) end,
    },
    [ANGLE_ID] = {
      setLowerAngle = function(_, device, cmd) handle_angle(device, "lower", cmd.args.angle) end,
      setUpperAngle = function(_, device, cmd) handle_angle(device, "upper", cmd.args.angle) end,
    },
    [c.refresh.ID] = {
      [c.refresh.commands.refresh.NAME] = handle_refresh,
    },
  },
})

driver:run()
