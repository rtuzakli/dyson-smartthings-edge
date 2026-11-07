-- Minimal MQTT 3.1.1 client (QoS 0 publish/subscribe) over an injectable TCP socket.
-- The socket factory is injected so the same code runs on cosock (hub) and luasocket (tests).

local M = {}
M.__index = M

local PACKET = {
  CONNECT = 1, CONNACK = 2, PUBLISH = 3, PUBACK = 4, SUBSCRIBE = 8, SUBACK = 9,
  PINGREQ = 12, PINGRESP = 13, DISCONNECT = 14,
}
M.PACKET = PACKET

local function enc_str(s)
  return string.char(#s // 256, #s % 256) .. s
end

local function enc_len(n)
  local out = {}
  repeat
    local b = n % 128
    n = n // 128
    if n > 0 then b = b + 128 end
    out[#out + 1] = string.char(b)
  until n == 0
  return table.concat(out)
end

local function packet(first_byte, body)
  return string.char(first_byte) .. enc_len(#body) .. body
end

function M.encode_connect(client_id, username, password, keepalive)
  local flags = 0x02
  local payload = enc_str(client_id)
  if username then
    flags = flags | 0x80
    payload = payload .. enc_str(username)
    if password then
      flags = flags | 0x40
      payload = payload .. enc_str(password)
    end
  end
  local body = enc_str("MQTT") .. string.char(4, flags, keepalive // 256, keepalive % 256) .. payload
  return packet(PACKET.CONNECT << 4, body)
end

function M.encode_publish(topic, payload)
  return packet(PACKET.PUBLISH << 4, enc_str(topic) .. payload)
end

function M.encode_subscribe(packet_id, topic)
  return packet((PACKET.SUBSCRIBE << 4) | 0x02,
    string.char(packet_id // 256, packet_id % 256) .. enc_str(topic) .. string.char(0))
end

function M.decode_publish(flags, body)
  if #body < 2 then return nil, "short publish" end
  local tlen = body:byte(1) * 256 + body:byte(2)
  if #body < 2 + tlen then return nil, "short publish topic" end
  local topic = body:sub(3, 2 + tlen)
  local pos = 3 + tlen
  local qos = (flags >> 1) & 0x03
  local packet_id
  if qos > 0 then
    if #body < pos + 1 then return nil, "short publish id" end
    packet_id = body:byte(pos) * 256 + body:byte(pos + 1)
    pos = pos + 2
  end
  return { topic = topic, payload = body:sub(pos), qos = qos, packet_id = packet_id }
end

-- opts: socket_factory, host, port, client_id, username, password, keepalive, now, on_message
function M.new(opts)
  local self = setmetatable({}, M)
  self.opts = opts
  self.keepalive = opts.keepalive or 30
  self.now = opts.now or os.time
  self.next_id = 1
  return self
end

local MAX_BODY = 65536

-- Returns type, flags, body; or nil, "timeout"; or nil, err.
function M:read_packet(timeout)
  local sock = self.sock
  if not sock then return nil, "closed" end -- closed from another coroutine (settings changed)
  sock:settimeout(timeout)
  local b1, err = sock:receive(1)
  if not b1 then return nil, err end
  sock:settimeout(5)
  local len, mult, done = 0, 1, false
  for _ = 1, 4 do
    local b, e = sock:receive(1)
    if not b then return nil, e or "closed" end
    local v = b:byte()
    len = len + (v & 0x7f) * mult
    mult = mult * 128
    if v < 128 then
      done = true
      break
    end
  end
  if not done then return nil, "bad remaining length" end
  if len > MAX_BODY then return nil, "packet too large" end
  local body = ""
  if len > 0 then
    body, err = sock:receive(len)
    if not body then return nil, err or "closed" end
  end
  local first = b1:byte()
  return first >> 4, first & 0x0f, body
end

function M:send(data)
  if not self.sock then return nil, "closed" end
  local ok, err = self.sock:send(data)
  if not ok then return nil, err end
  self.last_send = self.now()
  return true
end

function M:connect()
  local o = self.opts
  local sock, serr0 = o.socket_factory()
  if not sock then return nil, "socket: " .. tostring(serr0) end
  self.sock = sock
  sock:settimeout(10)
  local ok, err = sock:connect(o.host, o.port or 1883)
  if not ok then return nil, "connect: " .. tostring(err) end
  local sent, serr = self:send(M.encode_connect(o.client_id, o.username, o.password, self.keepalive))
  if not sent then return nil, serr end
  local ptype, flags, body = self:read_packet(10)
  if not ptype then return nil, "no CONNACK: " .. tostring(flags) end
  if ptype ~= PACKET.CONNACK or #body < 2 then return nil, "unexpected packet " .. ptype end
  if body:byte(2) ~= 0 then return nil, "CONNACK refused rc=" .. body:byte(2) end
  self.last_recv = self.now()
  return true
end

function M:subscribe(topic)
  local id = self.next_id
  self.next_id = (self.next_id % 65535) + 1
  return self:send(M.encode_subscribe(id, topic))
end

function M:publish(topic, payload)
  return self:send(M.encode_publish(topic, payload))
end

-- Handle one inbound packet or keepalive tick. Returns true, or nil, err ("timeout" is not an error).
function M:poll(timeout)
  local now = self.now()
  if now - (self.last_send or 0) >= self.keepalive // 2 then
    local ok, err = self:send(packet(PACKET.PINGREQ << 4, ""))
    if not ok then return nil, err end
  end
  -- A ping goes out every keepalive/2 and the broker answers each one, so a healthy link is never
  -- silent this long.
  if now - (self.last_recv or now) > self.keepalive + 5 then
    return nil, "keepalive timeout"
  end
  local ptype, flags, body = self:read_packet(timeout)
  if not ptype then
    -- read_packet returns nil, err: err arrives in the second slot.
    if flags == "timeout" then return true end
    return nil, flags or "closed"
  end
  self.last_recv = self.now()
  if ptype == PACKET.PUBLISH then
    local msg, err = M.decode_publish(flags, body)
    if not msg then return nil, err end
    if msg.qos == 1 then
      self:send(packet(PACKET.PUBACK << 4, string.char(msg.packet_id // 256, msg.packet_id % 256)))
    end
    if self.opts.on_message then self.opts.on_message(msg.topic, msg.payload) end
  end
  return true
end

function M:close()
  if self.sock then
    pcall(function() self.sock:send(packet(PACKET.DISCONNECT << 4, "")) end)
    pcall(function() self.sock:close() end)
    self.sock = nil
  end
end

return M
