-- Tests src/init.lua against a fake SmartThings runtime, a fake Dyson broker and a fake clock.
-- Run (needs lua-cjson): lua5.3 test/init_test.lua
package.path = "./src/?.lua;" .. package.path
local cjson = require "cjson"

local function eq(a, b, name)
  if a ~= b then error(string.format("%s: expected %s got %s", name, tostring(b), tostring(a)), 2) end
end

-- clock: os.time is what init.lua uses for every timer
local clock = 1000
os.time = function() return clock end

-- log
local logs = {}
local function logger(level) return function(m) logs[#logs + 1] = level .. " " .. tostring(m) end end
package.loaded["log"] = { info = logger("I"), warn = logger("W"), error = logger("E"), debug = logger("D"),
  trace = logger("T") }
local function logged(pattern)
  local n = 0
  for _, l in ipairs(logs) do if l:find(pattern, 1, true) then n = n + 1 end end
  return n
end

package.loaded["st.json"] = { encode = cjson.encode, decode = cjson.decode }

-- capabilities: any capability/attribute exists unless listed in `missing` (the hub's cache can lack
-- a new attribute; the real library then returns nil for it)
local missing = {}
local function attribute(cap, attr)
  return setmetatable({}, {
    __call = function(_, value)
      if type(value) == "table" and value.value ~= nil then
        return { cap = cap, attr = attr, value = value.value, unit = value.unit }
      end
      return { cap = cap, attr = attr, value = value }
    end,
    __index = function(_, enum) return function() return { cap = cap, attr = attr, value = enum } end end,
  })
end
local function capability(id)
  local cap = { ID = id, NAME = id }
  cap.commands = setmetatable({}, { __index = function(_, name) return { NAME = name } end })
  return setmetatable(cap, { __index = function(_, attr)
    if missing[id .. "." .. attr] then return nil end
    return attribute(id, attr)
  end })
end
package.loaded["st.capabilities"] = setmetatable({}, { __index = function(_, id) return capability(id) end })

local driver_cfg
package.loaded["st.driver"] = function(_, cfg)
  driver_cfg = cfg
  return { run = function() end }
end

-- cosock: spawned tasks are coroutines the test resumes; sleeping advances the clock
local tasks = {}
package.loaded["cosock"] = {
  spawn = function(fn) tasks[#tasks + 1] = coroutine.create(fn) end,
  socket = { sleep = function(s) clock = clock + s; coroutine.yield("sleep") end },
}

local mdns_found = {
  { service_info = { name = "358_SER-1" }, host_info = { address = "fe80::1" } },
  { service_info = { name = "358_SER-1" }, host_info = { address = "192.168.1.50" } },
}
package.loaded["st.mdns"] = { discover = function() return { found = mdns_found } end }

-- Dyson broker: records subscriptions and published commands; inbox holds messages to deliver
local broker = { subscribed = {}, published = {}, inbox = {} }
package.loaded["mqtt"] = { new = function(opts)
  local client = {}
  function client:connect()
    broker.host, broker.user, broker.password = opts.host, opts.username, opts.password
    if broker.accept_password and opts.password ~= broker.accept_password then return nil, "CONNACK refused rc=5" end
    return true
  end
  function client:subscribe(topic) broker.subscribed[#broker.subscribed + 1] = topic; return true end
  function client:publish(topic, payload)
    local msg = cjson.decode(payload)
    broker.published[#broker.published + 1] = { topic = topic, msg = msg }
    -- model detection: only the real model's topic answers
    local model, serial = topic:match("^([^/]+)/([^/]+)/command$")
    if broker.respond_model and msg.msg == "REQUEST-CURRENT-STATE" and model == broker.respond_model then
      broker.inbox[#broker.inbox + 1] = { topic = model .. "/" .. serial .. "/status/current",
        msg = { msg = "CURRENT-STATE", ["product-state"] = { fpwr = "ON", fnst = "FAN", msta = "OFF" } } }
    end
    return true
  end
  function client:poll(timeout)
    local m = table.remove(broker.inbox, 1)
    if m then
      local topic, body = "358K/SER-1/status/current", m
      if type(m.msg) == "table" then topic, body = m.topic, m.msg end
      opts.on_message(topic, cjson.encode(body))
      return true
    end
    clock = clock + timeout
    coroutine.yield("poll")
    return true
  end
  function client:close() end
  return client
end }

-- device
local events = {}
local function make_device(id, network_id, prefs)
  local d = { id = id, device_network_id = network_id, preferences = prefs, fields = {},
    profile = { components = setmetatable({}, { __index = function(_, k) return { id = k } end }) } }
  function d:emit_component_event(component, ev)
    events[#events + 1] = { dev = self.id, comp = component.id, cap = ev.cap, attr = ev.attr, value = ev.value, unit = ev.unit }
  end
  function d:get_field(k) return self.fields[k] end
  function d:set_field(k, v) self.fields[k] = v end
  function d:online() self.is_online = true end
  function d:offline() self.is_online = false; self.offline_count = (self.offline_count or 0) + 1 end
  function d:try_update_metadata(m) self.metadata = m end
  return d
end
local device = make_device("dev-1", "dyson-358k-1794012285",
  { serialNumber = "SER-1", productType = "358K", localPassword = "pw", ipAddress = "0.0.0.0" })
local fields = device.fields

local function latest(comp, cap, attr)
  for i = #events, 1, -1 do
    local e = events[i]
    if e.comp == comp and e.cap == cap and e.attr == attr then return e.value, e.unit end
  end
end
local function count(comp, cap, attr)
  local n = 0
  for _, e in ipairs(events) do if e.comp == comp and e.cap == cap and e.attr == attr then n = n + 1 end end
  return n
end
local function last_command()
  for i = #broker.published, 1, -1 do
    local m = broker.published[i].msg
    if m.msg == "STATE-SET" then return m.data end
  end
end
local function requests(kind)
  local n = 0
  for _, p in ipairs(broker.published) do if p.msg.msg == kind then n = n + 1 end end
  return n
end

require "init"
local task
local function step()
  local ok, err = coroutine.resume(task)
  assert(ok, err)
end

-- start: profile move, connect via mDNS, subscriptions, initial requests
driver_cfg.lifecycle_handlers.init(nil, device)
eq(device.metadata and device.metadata.profile, "dyson-358k", "profile set once")
task = tasks[#tasks]
step()
eq(broker.host, "192.168.1.50", "mDNS IPv4 address used"); eq(broker.user, "SER-1", "serial is the MQTT user")
eq(broker.password, "pw", "password from settings"); eq(fields.mqtt_password, "pw", "password kept on the hub")
eq(broker.subscribed[1], "358K/SER-1/status/current", "state topic"); eq(broker.subscribed[2], "358K/SER-1/status/faults", "fault topic")
eq(requests("REQUEST-CURRENT-STATE"), 1, "state requested"); eq(requests("REQUEST-CURRENT-FAULTS"), 1, "faults requested")
eq(device.is_online, true, "online"); eq(fields.last_ip, "192.168.1.50", "address remembered")

-- state, sensors and faults arrive
broker.inbox = {
  { msg = "CURRENT-STATE", ["product-state"] = { fpwr = "ON", auto = "ON", fnsp = "AUTO", fnst = "FAN", psta = "CLNG",
    hume = "HUMD", haut = "ON", humt = "0070", rect = "0045", msta = "HUMD", nmod = "ON", rhtm = "ON", oson = "ON",
    ancp = "BRZE", osal = "0180", osau = "0180", fdir = "ON", ercd = "NONE", wacd = "NONE" } },
  { msg = "ENVIRONMENTAL-CURRENT-SENSOR-DATA", data = { tact = "2958", hact = "0045", p25r = "0003", p10r = "0003",
    va10 = "0005", noxl = "0002", hchr = "0110" } },
  { msg = "CURRENT-FAULTS", ["product-warnings"] = { tnkp = "OK", tnke = "OK" }, ["product-errors"] = { amf1 = "OK" } },
}
step()
local ACT, AIR = "fabrictitle08390.activity", "fabrictitle08390.airQuality"
eq(latest("main", "switch", "switch"), "on", "power event")
eq(latest("main", ACT, "purifier"), "🟢", "purifier ball"); eq(latest("main", ACT, "humidifier"), "🟢", "humidifier ball")
eq(latest("main", ACT, "nightMode"), "🟢", "night mode ball"); eq(latest("humidifier", "fabrictitle08390.targetHumidity", "target"), 45, "target slider shows the auto target")
eq(latest("humidifier", "fabrictitle08390.autoHumidity", "autoMode"), "on", "auto switch on")
eq(latest("humidifier", "fabrictitle08390.autoHumidity", "display"), "On (45%)", "auto text carries the target")
eq(latest("humidifier", "mode", "mode"), "Auto", "picker stays Auto")
eq(latest("main", AIR, "overall"), "🟡", "overall ball (HCHO fair)"); eq(latest("main", AIR, "voc"), "🟢", "voc ball")
local voc, unit = latest("main", "tvocMeasurement", "tvocLevel")
eq(voc, 38, "tvoc mapped value"); eq(unit, "ug/m3", "tvoc unit")
eq(latest("main", "fabrictitle08390.attention", "message"), "None", "no problem")

-- an early re-send (30 s after connect) clears the sent-values cache and re-emits at once
local power_events = count("main", "switch", "switch")
clock = clock + 31
step()
eq(count("main", "switch", "switch"), power_events + 1, "re-send emitted immediately")

-- humidity control: the slider sets a manual target, Auto switches back
driver_cfg.capability_handlers["fabrictitle08390.targetHumidity"].setTarget(nil, device, { args = { target = 50 } })
eq(last_command().humt, "0050", "slider target"); eq(last_command().haut, "OFF", "slider is manual")
driver_cfg.capability_handlers["fabrictitle08390.autoHumidity"].setAutoMode(nil, device, { args = { state = "on" } })
eq(last_command().haut, "ON", "auto switch on")
driver_cfg.capability_handlers["fabrictitle08390.autoHumidity"].setAutoMode(nil, device, { args = { state = "off" } })
eq(last_command().humt, "0045", "auto off keeps the target in use")

-- regression: right after a re-send, toggling monitoring must keep the Dyson on
driver_cfg.capability_handlers["switch"]["off"](nil, device, { component = "monitoring", command = "off" })
eq(last_command().fpwr, "ON", "monitoring toggle keeps power on"); eq(last_command().rhtm, "OFF", "monitoring off")

-- regression: Custom oscillation carries a range (the Dyson ignores CUST alone)
driver_cfg.capability_handlers["mode"]["setMode"](nil, device, { component = "oscillation", args = { mode = "Custom" } })
eq(last_command().ancp, "CUST", "custom"); eq(last_command().osal, "0135", "default lower"); eq(last_command().osau, "0225", "default upper")

-- regression: the start angle keeps the live end angle
broker.inbox = { { msg = "STATE-CHANGE", ["product-state"] = { ancp = { "BRZE", "CUST" }, osal = { "0180", "0135" },
  osau = { "0180", "0225" } } } }
step()
driver_cfg.capability_handlers["fabrictitle08390.oscillationAngle"].setLowerAngle(nil, device, { args = { angle = 100 } })
eq(last_command().osal, "0100", "new start"); eq(last_command().osau, "0225", "end kept")

-- tank removed: Attention message, purifier stopped, logged once, not repeated by a re-send
broker.inbox = {
  { msg = "STATE-CHANGE", ["product-state"] = { fnst = { "FAN", "OFF" }, msta = { "HUMD", "OFF" } } },
  { msg = "CURRENT-FAULTS", ["product-warnings"] = { tnkp = "FAIL" } },
}
step()
eq(latest("main", "fabrictitle08390.attention", "message"), "Water tank removed", "tank message")
eq(latest("main", ACT, "purifier"), "🔴", "stopped by warning")
eq(latest("status", "hardwareFault", "hardwareFault"), "clear", "warning is not a hardware fault")
eq(logged("device reports"), 1, "fault logged once")
clock = clock + 120
step()
eq(logged("device reports"), 1, "re-send does not repeat the fault log")

-- hub cache lacks a new attribute: the value is skipped and the session keeps running
missing[ACT .. ".nightMode"] = true
broker.inbox = { { msg = "STATE-CHANGE", ["product-state"] = { nmod = { "ON", "OFF" } } } }
step()
eq(coroutine.status(task), "suspended", "session survives a missing attribute")
eq(logged("cannot build event main.act_night"), 1, "missing attribute logged")
missing[ACT .. ".nightMode"] = nil

-- a command that gets no answer marks the link dead within 10 s and goes offline
local offline_before, state_requests = device.offline_count or 0, requests("REQUEST-CURRENT-STATE")
driver_cfg.capability_handlers["switch"]["on"](nil, device, { component = "nightMode", command = "on" })
for _ = 1, 8 do step() end
eq(logged("no reply to command within 10 s"), 1, "dead link detected")
eq((device.offline_count or 0) > offline_before, true, "went offline after dead link")
eq(requests("REQUEST-CURRENT-STATE") > state_requests + 1, true, "reconnected and asked for state again")
eq(device.is_online, true, "online again after reconnect")

-- the profile carries the placeholder: the driver uses the password kept on the hub
device.preferences.localPassword = "password"
broker.password = nil
driver_cfg.lifecycle_handlers.infoChanged(nil, device)
task = tasks[#tasks]
step()
eq(broker.password, "pw", "stored password used when the setting is the placeholder")
eq(device.is_online, true, "online with the stored password")
-- no password anywhere: stays offline instead of connecting
fields.mqtt_password = nil
local connects = broker.host
broker.host = nil
driver_cfg.lifecycle_handlers.infoChanged(nil, device)
task = tasks[#tasks]
step()
eq(broker.host, nil, "no connect without a password"); eq(device.is_online, false, "offline without a password")
broker.host = connects

-- Scan nearby: one new device per Dyson on the network, none for a Dyson already added
local created = {}
local fake_driver = { get_devices = function() return { device } end,
  try_create_device = function(_, info) created[#created + 1] = info; return true end }
mdns_found = {
  { service_info = { name = "358_SER-1" }, host_info = { address = "192.168.1.50" } },
  { service_info = { name = "358_SER-2" }, host_info = { address = "192.168.1.51" } },
}
driver_cfg.discovery(fake_driver, {}, function() return false end)
eq(#created, 1, "only the new Dyson is added")
eq(created[1].device_network_id, "dyson:358:SER-2", "network id carries type and serial")
eq(created[1].profile, "dyson-358k", "profile"); eq(created[1].label, "Dyson Humidify+Cool", "label")

-- the discovered device: placeholders in settings, model detected from the topic the Dyson answers
local dev2 = make_device("dev-2", "dyson:358:SER-2",
  { serialNumber = "SERIAL", productType = "auto", localPassword = "pw2", ipAddress = "0.0.0.0" })
broker.subscribed, broker.respond_model = {}, "358K"
driver_cfg.lifecycle_handlers.init(nil, dev2)
local task2 = tasks[#tasks]
assert(coroutine.resume(task2))
eq(broker.host, "192.168.1.51", "found by serial over mDNS"); eq(broker.user, "SER-2", "serial from network id")
eq(dev2.fields.model, "358K", "model detected"); eq(dev2.fields.serial, "SER-2", "serial remembered")
local faults_topic = false
for _, t in ipairs(broker.subscribed) do faults_topic = faults_topic or t == "358K/SER-2/status/faults" end
eq(faults_topic, true, "subscribed on the detected model's topics"); eq(dev2.is_online, true, "online")
broker.respond_model = nil

-- setup problems show in Attention
local function attention(id)
  for i = #events, 1, -1 do
    local e = events[i]
    if e.dev == id and e.cap == "fabrictitle08390.attention" then return e.value end
  end
end
local dev3 = make_device("dev-3", "dyson:358:SER-3",
  { serialNumber = "SERIAL", productType = "auto", localPassword = "password", ipAddress = "0.0.0.0" })
driver_cfg.lifecycle_handlers.init(nil, dev3)
assert(coroutine.resume(tasks[#tasks]))
eq(attention("dev-3"), "Enter the local MQTT password in Settings", "missing password explained")
eq(dev3.is_online, false, "offline without password")

mdns_found = { { service_info = { name = "358_SER-4" }, host_info = { address = "192.168.1.52" } } }
broker.accept_password = "right"
local dev4 = make_device("dev-4", "dyson:358:SER-4",
  { serialNumber = "SERIAL", productType = "358K", localPassword = "wrong", ipAddress = "0.0.0.0" })
driver_cfg.lifecycle_handlers.init(nil, dev4)
assert(coroutine.resume(tasks[#tasks]))
eq(attention("dev-4"), "Local MQTT password is wrong", "wrong password explained")
broker.accept_password = nil

print("INIT OK")
