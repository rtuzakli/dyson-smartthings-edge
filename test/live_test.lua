-- Run against a real Dyson on plain Lua 5.3 + luasocket + cjson:
--   DYSON_IP=... DYSON_SERIAL=... DYSON_TYPE=358K DYSON_PW=... lua5.3 test/live_test.lua
package.path = "./src/?.lua;" .. package.path
local socket = require "socket"
local cjson = require "cjson"
local mqtt = require "mqtt"
local dyson = require "dyson"

local ip, serial, ptype, pw = os.getenv("DYSON_IP"), os.getenv("DYSON_SERIAL"), os.getenv("DYSON_TYPE"), os.getenv("DYSON_PW")
local topics = dyson.topics(ptype, serial)
local raw = {}
local c = mqtt.new({
  socket_factory = function() return socket.tcp() end,
  host = ip, port = 1883, client_id = "lua-live-test", username = serial, password = pw, keepalive = 30,
  on_message = function(_, payload)
    local msg = cjson.decode(payload)
    if dyson.merge(raw, msg) then print("got", msg.msg) end
  end,
})
assert(c:connect())
assert(c:subscribe(topics.status))
assert(c:publish(topics.command, cjson.encode(dyson.request(dyson.REQUEST_STATE, os.date("!%Y-%m-%dT%H:%M:%SZ")))))
assert(c:publish(topics.command, cjson.encode(dyson.request(dyson.REQUEST_SENSORS, os.date("!%Y-%m-%dT%H:%M:%SZ")))))
local deadline = os.time() + 8
while os.time() < deadline do assert(c:poll(1)) end
c:close()
local d = dyson.derive(raw)
local keys = {}
for k in pairs(d) do keys[#keys + 1] = k end
table.sort(keys)
for _, k in ipairs(keys) do print(k, d[k]) end
assert(d.power ~= nil and d.temperature_c and d.humidity, "missing derived values")
print("LIVE OK")
