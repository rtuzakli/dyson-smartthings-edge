package.path = "./src/?.lua;" .. package.path
local mqtt = require "mqtt"
local dyson = require "dyson"

local function eq(a, b, name)
  if a ~= b then error(string.format("%s: expected %s got %s", name, tostring(b), tostring(a)), 2) end
end
local function hex(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end

-- packet encoding
eq(hex(mqtt.encode_connect("c", "u", "p", 30)), "101300044d51545404c2001e000163000175000170", "connect")
eq(hex(mqtt.encode_publish("a/b", "hi")), "30070003612f626869", "publish")
eq(hex(mqtt.encode_subscribe(1, "t")), "82060001000174" .. "00", "subscribe")
local long = string.rep("x", 200)
eq(hex(mqtt.encode_publish("t", long)):sub(1, 6), "30cb01", "remaining length varint")
local m = mqtt.decode_publish(0, "\0\3a/bhi")
eq(m.topic, "a/b", "decode topic"); eq(m.payload, "hi", "decode payload")

-- fake socket round trip
local inbox = "\32\2\0\0" .. "\48\7\0\3a/bhi" .. "\208\0"
local pos, sent = 1, {}
local fake = {
  settimeout = function() end, connect = function() return true end,
  send = function(_, d) sent[#sent + 1] = d return #d end,
  receive = function(_, n)
    if pos > #inbox then return nil, "timeout" end
    local s = inbox:sub(pos, pos + n - 1); pos = pos + n; return s
  end,
  close = function() end,
}
local got
local c = mqtt.new({ socket_factory = function() return fake end, host = "h", client_id = "c", on_message = function(t, p) got = t .. ":" .. p end })
assert(c:connect())
assert(c:poll(1)); eq(got, "a/b:hi", "poll publish")
assert(c:poll(1))  -- PINGRESP
assert(c:poll(1))  -- timeout is not an error

-- dyson state derivation using a real device capture
local raw = {}
dyson.merge(raw, { msg = "CURRENT-STATE", ["product-state"] = {
  fpwr = "ON", auto = "ON", nmod = "ON", fnsp = "AUTO", oson = "ON", ancp = "BRZE", fdir = "ON",
  hume = "HUMD", haut = "ON", humt = "0070", rect = "0045", rhtm = "ON", sltm = "OFF",
  wath = "1350", cltr = "1346", clcr = "CLNO", cdrr = "0060", hflr = "0100", cflr = "INV",
  ercd = "NONE", wacd = "NONE", osal = "0180", osau = "0180" }, rssi = "-51" })
dyson.merge(raw, { msg = "ENVIRONMENTAL-CURRENT-SENSOR-DATA", data = {
  tact = "2958", hact = "0045", pm25 = "0002", pm10 = "0001", p25r = "0003", p10r = "0003",
  va10 = "0006", noxl = "0002", hcho = "0043", hchr = "0118", sltm = "OFF" } })
local d = dyson.derive(raw)
eq(d.power, true, "power"); eq(d.fan_mode, "auto", "fan_mode"); eq(d.night_mode, true, "night")
eq(d.oscillation, "Breeze", "osc"); eq(d.airflow, "Front", "airflow")
eq(d.humidification, true, "hume"); eq(d.humidity_mode, "Auto", "hum mode")
eq(d.monitoring, true, "rhtm"); eq(d.sleep_timer, "Off", "sleep")
eq(d.water_hardness, "Medium", "wath"); eq(d.clean_life, 100, "clean life"); eq(d.clean_needed, false, "clean")
eq(d.cleaning, false, "cleaning"); eq(d.hepa_life, 100, "hepa"); eq(d.carbon_life, nil, "carbon INV")
eq(d.fault, false, "fault"); eq(d.rssi, -51, "rssi")
eq(d.temperature_c, 22.7, "temp"); eq(d.humidity, 45, "hum%")
eq(d.pm25, 3, "pm25 prefers p25r"); eq(d.pm10, 3, "pm10 prefers p10r")
eq(d.voc_index, 0.6, "voc"); eq(d.no2_index, 0.2, "no2"); eq(d.hcho_mgm3, 0.118, "hcho uses hchr")
eq(d.level.pm25, "good", "pm25 level"); eq(d.level.hcho, "fair", "hcho 0.118 fair"); eq(d.level.overall, "fair", "overall includes hcho")
eq(d.percent, nil, "percent unknown in AUTO")

dyson.merge(raw, { msg = "STATE-CHANGE", ["product-state"] = {
  auto = { "ON", "OFF" }, fnsp = { "AUTO", "0004" }, oson = { "ON", "OFF" }, haut = { "ON", "OFF" },
  humt = { "0070", "0055" }, sltm = { "OFF", "0083" }, wacd = { "NONE", "W1" }, fdir = { "ON", "OFF" } } })
d = dyson.derive(raw)
eq(d.fan_mode, "medium", "manual mode"); eq(d.percent, 40, "percent"); eq(d.oscillation, "Off", "osc off")
eq(d.humidity_mode, "55%", "manual humidity"); eq(d.sleep_timer, "1 h 23 min left", "sleep left")
eq(d.fault, false, "warning code alone is not a hardware fault"); eq(d.warning_text, "Dyson warning W1", "w1 text"); eq(d.airflow, "Back", "back airflow")

-- commands
local cmd = dyson.commands
eq(cmd.percent(35).fnsp, "0004", "percent step"); eq(cmd.percent(0).fpwr, "OFF", "percent 0 off")
eq(cmd.fan_mode("high").fnsp, "0010", "high"); eq(cmd.fan_mode("auto").auto, "ON", "auto")
eq(cmd.fan_mode("sleep"), nil, "sleep is not a fan mode")
eq(cmd.oscillation("45°").ancp, "0045", "osc 45"); eq(cmd.oscillation("Breeze").ancp, "BRZE", "breeze")
eq(cmd.oscillation("Off").oson, "OFF", "osc off"); eq(cmd.oscillation("bogus"), nil, "osc invalid")
eq(cmd.airflow("Back").fdir, "OFF", "back"); eq(cmd.airflow("x"), nil, "airflow invalid")
eq(cmd.humidity_mode("Auto").haut, "ON", "hum auto"); eq(cmd.humidity_mode("45%").humt, "0045", "humt")
eq(cmd.humidity_mode("45%").haut, "OFF", "manual disables auto")
eq(cmd.humidity_mode("80%"), nil, "humt range"); eq(cmd.humidity_mode("%45"), nil, "old prefix form rejected"); eq(cmd.humidity_mode("abc"), nil, "humt parse")
eq(cmd.humidification(false).hume, "OFF", "hume off")
eq(cmd.water_hardness("Hard").wath, "0675", "hard"); eq(cmd.water_hardness("x"), nil, "wath invalid")
eq(cmd.sleep_timer("2 h").sltm, "0120", "sleep 2h"); eq(cmd.sleep_timer("Off").sltm, "OFF", "sleep off")
eq(cmd.sleep_timer("3 h"), nil, "sleep invalid")
eq(cmd.night_mode(true).nmod, "ON", "night"); eq(cmd.monitoring(true, false).fpwr, "OFF", "monitor keeps power")
eq(cmd.reset_filter().rstf, "RSTF", "reset filter")
eq(d.lower_angle, 180, "osal"); eq(d.upper_angle, 180, "osau")

-- Dyson app bands: <=35 good, <=53 fair, <=70 poor, else very poor; overall = worst of four
local r2 = {}
dyson.merge(r2, { msg = "ENVIRONMENTAL-CURRENT-SENSOR-DATA", data = { p25r = "0054", p10r = "0040", va10 = "0090", noxl = "0010" } })
local d2 = dyson.derive(r2)
eq(d2.level.pm25, "poor", "pm25 poor"); eq(d2.level.pm10, "good", "pm10 good")
eq(d2.level.voc, "veryPoor", "voc 9 very poor"); eq(d2.level.no2, "good", "no2 1")
eq(d.no2_bar_ppm, 0.005, "no2 0.2 index -> bar ppm"); eq(d2.no2_bar_ppm, 0.025, "no2 1 index -> bar ppm")
local r3 = {}
dyson.merge(r3, { msg = "ENVIRONMENTAL-CURRENT-SENSOR-DATA", data = { noxl = "0100" } })
eq(dyson.derive(r3).no2_bar_ppm, 0.25, "no2 10 index -> bar end")
eq(d2.level.overall, "veryPoor", "overall worst"); eq(dyson.CONCERN_FOR_LEVEL[d2.level.overall], "unhealthy", "st concern")

-- MyDyson app scales (2026-11-07): boundaries, whole-number VOC/NO2, PM extra levels
local function lv(field, raw_value)
  local r = {}
  dyson.merge(r, { msg = "ENVIRONMENTAL-CURRENT-SENSOR-DATA", data = { [field] = raw_value } })
  return dyson.derive(r).level
end
eq(lv("hchr", "0097").hcho, "good", "hcho 0.097"); eq(lv("hchr", "0098").hcho, "fair", "hcho 0.098")
eq(lv("hchr", "0245").hcho, "fair", "hcho 0.245"); eq(lv("hchr", "0246").hcho, "poor", "hcho 0.246")
eq(lv("hchr", "0490").hcho, "poor", "hcho 0.490"); eq(lv("hchr", "0491").hcho, "veryPoor", "hcho 0.491")
eq(lv("hchr", "2000").hcho, "veryPoor", "hcho has no level past very poor")
eq(lv("va10", "0039").voc, "good", "voc 3.9 shows 3"); eq(lv("va10", "0040").voc, "fair", "voc 4")
eq(lv("noxl", "0089").no2, "poor", "no2 8.9 shows 8"); eq(lv("noxl", "0100").no2, "veryPoor", "no2 10 stays very poor")
eq(lv("p25r", "0150").pm25, "veryPoor", "pm25 150"); eq(lv("p25r", "0151").pm25, "extremelyPoor", "pm25 151")
eq(lv("p25r", "0251").pm25, "severe", "pm25 251"); eq(lv("p10r", "0420").pm10, "extremelyPoor", "pm10 420")
eq(lv("p10r", "0421").pm10, "severe", "pm10 421")
eq(dyson.CONCERN_FOR_LEVEL.severe, "hazardous", "severe concern")
for _, l in ipairs(dyson.LEVELS) do
  local found = false
  for _, v in ipairs(dyson.CONCERN_VALUES) do found = found or v == dyson.CONCERN_FOR_LEVEL[l] end
  eq(found, true, "concern listed for " .. l)
end

-- oscillation angles: 5..355, equal or >= 30 apart, other edge moves to stay valid
local a = cmd.angle("lower", 100, 180, 180)
eq(a.osal, "0100", "lower"); eq(a.osau, "0180", "upper kept"); eq(a.ancp, "CUST", "cust")
a = cmd.angle("lower", 170, 150, 180); eq(a.osau, "0200", "upper pushed to span")
a = cmd.angle("upper", 20, 5, 355); eq(a.osal, "0005", "lower kept"); eq(a.osau, "0035", "upper clamped to span")
a = cmd.angle("lower", 350, 100, 200); eq(a.osal, "0325", "lower capped"); eq(a.osau, "0355", "upper max")
a = cmd.angle("lower", 180, 100, 180); eq(a.osal, "0180", "equal allowed"); eq(a.osau, "0180", "fixed")
eq(cmd.angle("lower", 400, 100, 200), nil, "range"); eq(cmd.angle("side", 100), nil, "which")

-- mDNS: pick our Dyson by serial, skip other named Dysons and IPv6, accept one unnamed host
local function rec(name, addr) return { service_info = { name = name }, host_info = { address = addr } } end
local SERIAL = "AB1-EU-CDE2345F"
eq(dyson.pick_mdns_address({ rec("358_" .. SERIAL, "fe80::1"), rec("358_" .. SERIAL, "192.168.1.50") }, SERIAL),
  "192.168.1.50", "serial match, ipv6 skipped")
eq(dyson.pick_mdns_address({ rec("527_OTHER-SERIAL", "192.168.1.60"), rec("358_" .. SERIAL, "192.168.1.50") }, SERIAL),
  "192.168.1.50", "other dyson skipped")
eq(dyson.pick_mdns_address({ rec("527_OTHER-SERIAL", "192.168.1.60") }, SERIAL), nil, "only another dyson")
eq(dyson.pick_mdns_address({ rec("", "192.168.1.50"), rec(nil, "192.168.1.50") }, SERIAL), "192.168.1.50", "one unnamed host")
eq(dyson.pick_mdns_address({ rec("", "192.168.1.50"), rec("", "192.168.1.51") }, SERIAL), nil, "two unnamed hosts")
eq(dyson.pick_mdns_address(nil, SERIAL), nil, "no reply")
eq(dyson.ipv4("192.168.1.300"), nil, "octet range"); eq(dyson.ipv4("0.0.0.0"), "0.0.0.0", "zero ip parses")
-- Status card: a ball per function, short warning, level text
local function now(fields)
  local r = {}
  dyson.merge(r, { msg = "CURRENT-STATE", ["product-state"] = fields })
  local d = dyson.derive(r)
  return d.now, d.warning_text
end
local n = now({ fpwr = "ON", psta = "CLNG", fnst = "FAN", msta = "HUMD", hume = "HUMD", fdir = "ON" })
eq(n.purifier, "🟢", "purifier running"); eq(n.humidifier, "🟢", "humidifier running"); eq(n.cooling, nil, "no cooling row")
n = now({ fpwr = "ON", psta = "OFF", fnst = "FAN", msta = "OFF", hume = "HUMD", fdir = "OFF" })
eq(n.humidifier, "🟡", "humidity target reached")
n = now({ fpwr = "ON", psta = "OFF", fnst = "OFF", msta = "OFF", hume = "OFF", fdir = "ON" })
eq(n.purifier, "🟡", "auto idle"); eq(n.humidifier, "⚪", "humidifier off")
n = now({ fpwr = "OFF", rhtm = "ON", psta = "OFF", fnst = "OFF" })
eq(n.purifier, "⚪", "power off")
n = now({ fpwr = "ON", clcr = "CLAC", cdrr = "0042", fnst = "OFF", hume = "HUMD" })
eq(n.humidifier, "🔵 42 min", "deep clean")
eq(now({ fpwr = "ON" }), nil, "state unknown")
n = now({ fpwr = "ON", fnst = "FAN", msta = "OFF", nmod = "ON" })
eq(n.night_mode, "🟢", "night mode on")
n = now({ fpwr = "OFF", fnst = "OFF", nmod = "OFF" })
eq(n.night_mode, "⚪", "night mode off")
eq(now({ fpwr = "ON", fnst = "FAN" }).night_mode, nil, "night mode unknown")
eq(select(2, now({ ercd = "NONE", wacd = "NONE" })), "None", "no problem")
eq(select(2, now({ ercd = "NONE", wacd = "FLTR" })), "Replace the filter", "known warning")
eq(select(2, now({ ercd = "02C9", wacd = "W1" })), "Dyson warning W1, Dyson error 02C9", "unknown codes named")
eq(dyson.level_ball("fair"), "🟡", "level ball"); eq(dyson.level_ball("severe"), "⚫", "severe ball"); eq(dyson.level_ball(nil), nil, "no level")

-- CURRENT-FAULTS (status/faults): tank removed seen as product-warnings.tnkp = FAIL
local rf = {}
dyson.merge(rf, { msg = "CURRENT-STATE", ["product-state"] = {
  fpwr = "ON", psta = "CLNG", fnst = "OFF", msta = "OFF", ercd = "NONE", wacd = "NONE" } })
dyson.merge(rf, { msg = "CURRENT-FAULTS", ["product-warnings"] = { tnkp = "FAIL", tnke = "OK", fltr = "OK" },
  ["product-errors"] = { amf1 = "OK" } })
local df = dyson.derive(rf)
eq(df.warning_text, "Water tank removed", "tank removed")
eq(df.now.purifier, "🔴", "psta CLNG but fan off is not purifying")
eq(df.fault, false, "tank warning is not a hardware fault")
dyson.merge(rf, { msg = "CURRENT-FAULTS", ["product-warnings"] = { tnkp = "OK", etwd = "FAIL" },
  ["product-errors"] = { amf1 = "FAIL" } })
df = dyson.derive(rf)
eq(df.warning_text, "Dyson error amf1, Dyson warning etwd", "unknown fault keys named, errors first")
eq(df.fault, true, "product error is a hardware fault")
dyson.merge(rf, { msg = "CURRENT-FAULTS", ["product-warnings"] = { tnkp = "OK" } })
eq(dyson.derive(rf).warning_text, "None", "faults cleared")
eq(dyson.attention_alert("None"), "clear", "no problem, no alert")
eq(dyson.attention_alert("Water tank empty"), "detected", "any message is an alert")
eq(dyson.attention_alert(nil), nil, "unknown state sends nothing")
local _, parts = dyson.warning_text("NONE", "NONE", { ["product-warnings.tnkp"] = "FAIL", ["product-warnings.fltr"] = "FAIL" })
eq(#parts, 2, "every problem listed")
eq(dyson.has_new_problem({ ["Water tank removed"] = true }, { "Water tank removed" }), false, "same problem is not new")
eq(dyson.has_new_problem({ ["Water tank removed"] = true }, { "Water tank removed", "Replace the filter" }), true, "added problem is new")
eq(dyson.has_new_problem({ ["Water tank removed"] = true, ["Replace the filter"] = true }, { "Replace the filter" }), false, "fewer problems is not new")
eq(dyson.topics("358K", "S").faults, "358K/S/status/faults", "faults topic")
-- humidity target: picker stays "Auto"; target shown separately
local rh = {}
dyson.merge(rh, { msg = "CURRENT-STATE", ["product-state"] = { hume = "HUMD", haut = "ON", humt = "0070", rect = "0045" } })
local dh = dyson.derive(rh)
eq(dh.humidity_mode, "Auto", "picker stays Auto"); eq(dh.humidity_target_pct, 45, "auto target"); eq(dh.humidity_auto, "on", "auto on"); eq(dh.humidity_auto_text, "On (45%)", "auto text")
eq(dyson.commands.humidity_mode("Auto (45%)").haut, "ON", "old auto label still accepted from routines")
eq(dyson.commands.humidity_mode("Auto (x"), nil, "broken auto label rejected")
dyson.merge(rh, { msg = "STATE-CHANGE", ["product-state"] = { haut = { "ON", "OFF" } } })
dh = dyson.derive(rh)
eq(dh.humidity_mode, "70%", "manual mode"); eq(dh.humidity_target_pct, 70, "manual target"); eq(dh.humidity_auto, "off", "auto off"); eq(dh.humidity_auto_text, "Off", "manual text")
eq(dyson.commands.humidity_target(52).humt, "0050", "target rounds to 5"); eq(dyson.commands.humidity_target(52).haut, "OFF", "slider is manual")
eq(dyson.commands.humidity_target(80), nil, "target range"); eq(dyson.commands.humidity_target("x"), nil, "target number")
eq(dyson.commands.humidity_auto("on").haut, "ON", "auto on cmd")
eq(dyson.commands.humidity_auto("off", 40).humt, "0040", "auto off keeps current target")
eq(dyson.commands.humidity_auto("maybe"), nil, "auto state")

-- TVOC index mapped onto UBA bands (ug/m3), each Dyson level in its band
eq(dyson.voc_ugm3(0), 0, "voc 0"); eq(dyson.voc_ugm3(0.5), 38, "voc 0.5")
eq(dyson.voc_ugm3(4), 300, "voc 4 = fair starts at 300"); eq(dyson.voc_ugm3(3.9) < 300, true, "3.9 still good band")
eq(dyson.voc_ugm3(7), 1000, "voc 7"); eq(dyson.voc_ugm3(9), 3000, "voc 9"); eq(dyson.voc_ugm3(10), 10000, "voc 10")
eq(dyson.voc_ugm3(nil), nil, "voc unknown")
-- discovery helpers
eq(dyson.network_id("358", "AB1-EU-CDE2345F"), "dyson:358:AB1-EU-CDE2345F", "network id")
local np, ns = dyson.parse_network_id("dyson:358:AB1-EU-CDE2345F")
eq(np, "358", "prefix from id"); eq(ns, "AB1-EU-CDE2345F", "serial from id")
eq(dyson.parse_network_id("dyson-358k-1794012285"), nil, "old network ids carry no serial")
local cands = dyson.model_candidates("358")
eq(cands[1], "358K", "K first"); eq(#cands, 4, "four candidates"); eq(dyson.model_candidates("358K")[1], "358K", "full model kept")
eq(#dyson.model_candidates(nil), 0, "no prefix, no candidates")
eq(dyson.model_from_topic("358K/S-1/status/current", "S-1"), "358K", "model from topic")
eq(dyson.model_from_topic("358K/S-1/status/faults", "S-1"), nil, "only the state topic")
eq(dyson.model_from_topic("358K/OTHER/status/current", "S-1"), nil, "other serial")
local md = dyson.mdns_devices({ rec("358_" .. SERIAL, "fe80::1"), rec("358_" .. SERIAL, "192.168.1.50"), rec("438_AB-CD-EFGH1234", "192.168.1.60") })
eq(#md, 2, "one entry per serial"); eq(md[1].ip, "192.168.1.50", "IPv4 kept after IPv6"); eq(md[1].prefix, "358", "prefix"); eq(md[2].serial, "AB-CD-EFGH1234", "second dyson")
eq(dyson.setup_text_for_error("CONNACK refused rc=5"), "Local MQTT password is wrong", "rc 5")
eq(dyson.setup_text_for_error("connect: timeout"), nil, "other errors")
-- a client closed from another coroutine reports "closed" instead of crashing
local closed = mqtt.new({ socket_factory = function() return nil end })
local cok, cerr = closed:publish("t", "x"); eq(cok, nil, "send after close"); eq(cerr, "closed", "send reason")
local pok2, perr2 = closed:poll(1); eq(pok2, nil, "poll after close"); eq(perr2, "closed", "poll reason")
print("UNIT OK")
