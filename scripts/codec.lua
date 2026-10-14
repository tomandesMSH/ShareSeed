-- Share code format.
--
--   SS1.<seed>.<payload>
--
-- <seed> is the run seed as the game prints it, without the space, so people can read it.
-- <payload> is base64url over a bit stream:
--   version 4 | seed 32 | player type 10 | difficulty 3 | challenge 10
--   profile: mode 1 (0 = raw 640 bits, 1 = first bit + Elias-gamma run lengths)
--   counters (format 2+): present 1, then gamma(value + 1) for each of codec.COUNTERS
--   floor rerolls (format 2+): gamma(count + 1), then per floor: stage 5 | gamma(rerolls)
--                               | (format 3+) the floor's stage seed after the rerolls 32
--   unlock events: gamma(count + 1), then per event: achievement 10 | stage 5 | stage type 3 | room index + 512 10
--   checksum 16 over all preceding bytes
--
-- A profile is a 640-character string of "0"/"1", one per vanilla achievement (index = achievement id).
-- Counters are the sharer's values of the event counters that run generation reads, as an array
-- in codec.COUNTERS order, or nil when unknown (format 1 codes).

local codec = {}

codec.NUM_ACHIEVEMENTS = 640
-- Event counters that run generation reads (found with the trace build of the native helper on
-- Repentance+ v1.9.7.12): 11 Isaac kills (curse chance), 20 donation machine, 21 Eden tokens,
-- 24/25 ??? and Lamb kills (room chance), 114 Eden's Blessing items, 115 Greed donation machine.
codec.COUNTERS = { 11, 20, 21, 24, 25, 114, 115 }
codec.MAX_COUNTER = 32767
local VERSION = 3
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

local function writer()
  local w = { bits = {} }
  function w.put(v, n)
    for i = n - 1, 0, -1 do w.bits[#w.bits + 1] = (v >> i) & 1 end
  end
  function w.gamma(v) -- v >= 1
    local len = 0
    while (v >> (len + 1)) > 0 do len = len + 1 end
    w.put(0, len)
    w.put(v, len + 1)
  end
  function w.bytes()
    local out = {}
    for i = 1, #w.bits, 8 do
      local b = 0
      for j = 0, 7 do b = (b << 1) | (w.bits[i + j] or 0) end
      out[#out + 1] = b
    end
    return out
  end
  return w
end

local function reader(bytes)
  local r = { pos = 0, total = #bytes * 8 }
  function r.get(n)
    local v = 0
    for _ = 1, n do
      if r.pos >= r.total then error("code is too short", 0) end
      local byte = bytes[(r.pos >> 3) + 1]
      v = (v << 1) | ((byte >> (7 - (r.pos & 7))) & 1)
      r.pos = r.pos + 1
    end
    return v
  end
  function r.gamma()
    local len = 0
    while r.get(1) == 0 do
      len = len + 1
      if len > 32 then error("code is corrupted", 0) end
    end
    return (1 << len) | r.get(len)
  end
  return r
end

local function checksum(bytes, n)
  local h = 0x811C
  for i = 1, n do h = ((h ~ bytes[i]) * 0x0101 + 0x3D) & 0xFFFF end
  return h
end

local function b64encode(bytes)
  local out, buf, nbits = {}, 0, 0
  for _, b in ipairs(bytes) do
    buf, nbits = (buf << 8) | b, nbits + 8
    while nbits >= 6 do
      nbits = nbits - 6
      local c = (buf >> nbits) & 63
      out[#out + 1] = B64:sub(c + 1, c + 1)
    end
  end
  if nbits > 0 then
    local c = (buf << (6 - nbits)) & 63
    out[#out + 1] = B64:sub(c + 1, c + 1)
  end
  return table.concat(out)
end

local function b64decode(s)
  local out, buf, nbits = {}, 0, 0
  for i = 1, #s do
    local c = B64:find(s:sub(i, i), 1, true)
    if not c then error("code contains an invalid character", 0) end
    buf, nbits = ((buf << 6) | (c - 1)) & 0xFFFFFF, nbits + 6
    if nbits >= 8 then
      nbits = nbits - 8
      out[#out + 1] = (buf >> nbits) & 0xFF
    end
  end
  return out
end

local function write_profile(w, profile)
  local runs, cur, len = {}, profile:sub(1, 1), 0
  for i = 1, #profile do
    local ch = profile:sub(i, i)
    if ch == cur then len = len + 1 else runs[#runs + 1] = len; cur, len = ch, 1 end
  end
  runs[#runs + 1] = len

  local rle = writer()
  rle.put(profile:sub(1, 1) == "1" and 1 or 0, 1)
  for _, r in ipairs(runs) do rle.gamma(r) end

  if #rle.bits < #profile then
    w.put(1, 1)
    for _, b in ipairs(rle.bits) do w.put(b, 1) end
  else
    w.put(0, 1)
    for i = 1, #profile do w.put(profile:sub(i, i) == "1" and 1 or 0, 1) end
  end
end

local function read_profile(r)
  local n = codec.NUM_ACHIEVEMENTS
  local out = {}
  if r.get(1) == 0 then
    for i = 1, n do out[i] = r.get(1) == 1 and "1" or "0" end
  else
    local bit = r.get(1)
    local count = 0
    while count < n do
      local len = r.gamma()
      if count + len > n then error("code is corrupted", 0) end
      local ch = bit == 1 and "1" or "0"
      for i = count + 1, count + len do out[i] = ch end
      count, bit = count + len, 1 - bit
    end
  end
  return table.concat(out)
end

local function seed_text(seed)
  return (Seeds.Seed2String(seed):gsub(" ", ""))
end

-- run = { seed, playerType, difficulty, challenge, profile, counters, rerolls = { ["stage"] = n },
--         events = { {ach, stage, stageType, room}, ... } }
-- rerolls: how often a floor was regenerated with the `reseed` command as it began (mods like
-- Treasure Room Start do this); rerollSeeds = { ["stage"] = seed }: the stage seed it ended up with.
-- Reseeding is deterministic, so the replay rerolls until it has the same seed.
function codec.encode(run)
  local w = writer()
  w.put(VERSION, 4)
  w.put(run.seed & 0xFFFFFFFF, 32)
  w.put(run.playerType, 10)
  w.put(run.difficulty, 3)
  w.put(run.challenge, 10)
  write_profile(w, run.profile)
  if run.counters then
    w.put(1, 1)
    for i = 1, #codec.COUNTERS do
      w.gamma(math.max(0, math.min(codec.MAX_COUNTER, run.counters[i] or 0)) + 1)
    end
  else
    w.put(0, 1)
  end
  local floors = {}
  for stage, n in pairs(run.rerolls or {}) do
    stage = tonumber(stage)
    local seed = (run.rerollSeeds or {})[tostring(stage)]
    if stage and stage >= 1 and stage < 32 and n > 0 then floors[#floors + 1] = { stage, n, seed or 0 } end
  end
  table.sort(floors, function(a, b) return a[1] < b[1] end)
  w.gamma(#floors + 1)
  for _, f in ipairs(floors) do
    w.put(f[1], 5)
    w.gamma(f[2])
    w.put(f[3] & 0xFFFFFFFF, 32)
  end
  w.gamma(#run.events + 1)
  for _, e in ipairs(run.events) do
    w.put(e.ach, 10)
    w.put(e.stage, 5)
    w.put(e.stageType, 3)
    w.put(e.room + 512, 10)
  end
  local bytes = w.bytes()
  local sum = checksum(bytes, #bytes)
  bytes[#bytes + 1] = sum >> 8
  bytes[#bytes + 1] = sum & 0xFF
  return "SS1." .. seed_text(run.seed) .. "." .. b64encode(bytes)
end

-- Returns run, or nil and an error message.
function codec.decode(code)
  if type(code) ~= "string" then return nil, "no code given" end
  code = code:gsub("%s", "")
  local seedPart, payload = code:match("^SS1%.([%w]+)%.([%w%-_]+)$")
  if not payload then return nil, "that doesn't look like a ShareSeed code (it should start with SS1.)" end

  local ok, res = pcall(function()
    local bytes = b64decode(payload)
    if #bytes < 3 then error("code is too short", 0) end
    local stored = (bytes[#bytes - 1] << 8) | bytes[#bytes]
    if checksum(bytes, #bytes - 2) ~= stored then error("code is damaged (checksum mismatch), copy it again", 0) end
    local r = reader(bytes)
    local version = r.get(4)
    if version < 1 or version > VERSION then error("code was made by a newer ShareSeed (format " .. version .. ")", 0) end
    local run = { events = {} }
    run.seed = r.get(32)
    run.playerType = r.get(10)
    run.difficulty = r.get(3)
    run.challenge = r.get(10)
    run.profile = read_profile(r)
    if version >= 2 and r.get(1) == 1 then
      run.counters = {}
      for i = 1, #codec.COUNTERS do run.counters[i] = r.gamma() - 1 end
    end
    if version >= 2 then
      run.rerolls, run.rerollSeeds = {}, {}
      for _ = 1, r.gamma() - 1 do
        local stage = tostring(r.get(5)) -- string keys: the run record is saved as JSON
        run.rerolls[stage] = r.gamma()
        if version >= 3 then
          local seed = r.get(32)
          if seed ~= 0 then run.rerollSeeds[stage] = seed end
        end
      end
    end
    for _ = 1, r.gamma() - 1 do
      run.events[#run.events + 1] = { ach = r.get(10), stage = r.get(5), stageType = r.get(3), room = r.get(10) - 512 }
    end
    return run
  end)
  if not ok then return nil, res end
  if seed_text(res.seed) ~= seedPart:upper() then return nil, "the seed in the code doesn't match its contents" end
  return res
end

function codec.count_unlocked(profile)
  local _, n = profile:gsub("1", "")
  return n
end

return codec
