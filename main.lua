-- ShareSeed: share a seed together with the sharer's unlocks, so the other player gets the same run
-- no matter what they have unlocked themselves.
--
-- How it works: the game checks unlocks in hundreds of places (item pools, room and boss selection,
-- how many rooms a floor gets, floor variants, doors, starting items, ...), and a few save-file
-- counters (curse chance, room chances, ...). Lua can't change what those checks read, so for a
-- shared run ShareSeed changes the save itself: it writes the player's real unlocks and counters to
-- its own mod data first (the "swap journal"), then sets the save to the sharer's, and puts the
-- real ones back when the shared run is over. If the game crashes in between, the journal is still
-- there and the next launch restores it.
--
-- The save is only ever changed in a run, never while the main menu is up: the menus are built from
-- the unlocks when they open, and changing them under an open menu crashes the game (seen when
-- locking a Dead God profile from the title screen). A code played from the menu goes through a
-- normal run that is thrown away at once.
--
-- Unlocking an achievement this way also unlocks it on Steam, which can't be undone, so playing a
-- code that would do that asks for confirmation first.

local mod = RegisterMod("ShareSeed", 1)
local json = require("json")
local codec = include("scripts.codec")

local N = codec.NUM_ACHIEVEMENTS

local function log(msg) Isaac.DebugString("[ShareSeed] " .. msg) end

if not REPENTOGON then
  log("REPENTOGON is not installed; ShareSeed needs it and is disabled.")
  mod:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, function()
    Isaac.ConsoleOutput("ShareSeed needs REPENTOGON (repentogon.com) and is disabled.\n")
  end)
  return
end

local function pgd() return Isaac.GetPersistentGameData() end

------------------------------------------------------------------------------------------------
-- Save state: what the save currently holds, and setting it
------------------------------------------------------------------------------------------------

local function current_profile()
  local t, p = {}, pgd()
  for a = 1, N do t[a] = p:Unlocked(a) and "1" or "0" end
  return table.concat(t)
end

local function current_counters()
  local t, p = {}, pgd()
  for i, id in ipairs(codec.COUNTERS) do t[i] = p:GetEventCounter(id) end
  return t
end

local function same_counters(a, b)
  for i = 1, #codec.COUNTERS do
    if math.min(codec.MAX_COUNTER, a[i] or 0) ~= math.min(codec.MAX_COUNTER, b[i] or 0) then return false end
  end
  return true
end

-- Counters can only change while the save isn't read-only, i.e. not during a seeded run. Changing
-- one can unlock achievements tied to it, so counters go first and achievements after.
local function quietly(fn, ...)
  local popups = Options.DisplayPopups
  Options.DisplayPopups = 0 -- no achievement papers while the save is being changed
  local ok, res = pcall(fn, ...)
  Options.DisplayPopups = popups
  if not ok then error(res, 0) end
  return res
end

local function set_counters_raw(counters)
  local p = pgd()
  for i, id in ipairs(codec.COUNTERS) do
    local want, cur = counters[i] or 0, p:GetEventCounter(id)
    if cur ~= want and not (cur >= codec.MAX_COUNTER and want >= codec.MAX_COUNTER) then
      p:IncreaseEventCounter(id, want - cur)
    end
  end
  return same_counters(current_counters(), counters)
end
local function set_counters(counters) return quietly(set_counters_raw, counters) end

-- Achievements can always be set: Unlock forces past the read-only flag and lockachievement clears
-- the flag directly. Unlocking one can unlock others (Dead God, say), hence the passes.
local function set_profile_raw(profile)
  local p = pgd()
  for _ = 1, 4 do
    local changed = false
    for a = 1, N do
      local want, has = profile:sub(a, a) == "1", p:Unlocked(a)
      if want and not has then
        p:Unlock(a, true)
        changed = true
      elseif has and not want then
        Isaac.ExecuteCommand("lockachievement " .. a)
        changed = true
      end
    end
    if not changed then break end
  end
  local now = current_profile()
  if now ~= profile then
    local wrong = {}
    for a = 1, N do
      if now:sub(a, a) ~= profile:sub(a, a) then wrong[#wrong + 1] = a .. (now:sub(a, a) == "1" and "+" or "-") end
    end
    log("couldn't set " .. #wrong .. " achievement(s) (+ = stays unlocked, - = stays locked): " .. table.concat(wrong, " ", 1, math.min(#wrong, 60)))
  end
  return now == profile
end
local function set_profile(profile) return quietly(set_profile_raw, profile) end

------------------------------------------------------------------------------------------------
-- Run record and swap journal (both in this save slot's mod data)
------------------------------------------------------------------------------------------------

-- run = { seed, playerType, difficulty, challenge, profile, counters, rerolls, events, shared,
--         fired = { [i] = true }, ended }
-- swap = { profile, counters } (the player's real ones), ach / ctr = whether the save currently
--        holds the sharer's achievements / counters instead, applied / appliedCounters = what
--        was written, verify = the session that put the real ones back.
--
-- The journal outlives the restore: the game saves through Steam Cloud, and if it closes before
-- the restored save is synced (a crash, a forced quit), Steam brings back the older copy, the one
-- with the sharer's unlocks, on the next launch. So the journal is only dropped once a later
-- session has seen the player's own state in the save; until then it can put it right again.
local SESSION = tostring(Isaac.GetTime()) .. "-" .. tostring(Random())
local run
local swap
local pending -- decoded code waiting for its run to start
local status = ""

local function save()
  local ok, data = pcall(json.encode, { run = run, swap = swap })
  if ok then mod:SaveData(data) end
end

local function load()
  run, swap = nil, nil
  if mod:HasData() then
    local ok, data = pcall(json.decode, mod:LoadData())
    if ok and type(data) == "table" then
      if type(data.run) == "table" then run = data.run end
      if type(data.swap) == "table" and type(data.swap.profile) == "string" then swap = data.swap end
    end
  end
  if run then
    run.events = run.events or {}
    local fired = {}
    for k, v in pairs(run.fired or {}) do fired[tonumber(k)] = v end
    run.fired = fired
  end
end

-- The player's own unlocks and counters, whatever the save holds right now.
local function own_profile()
  if swap and swap.ach then return swap.profile end
  return current_profile()
end

local function own_counters()
  if swap and swap.ctr then return swap.counters end
  return current_counters()
end

local function own_unlocked(a) return own_profile():sub(a, a) == "1" end

-- Whether the save holds a shared run's unlocks or counters right now.
local function swapping() return swap ~= nil and (swap.ach or swap.ctr) end

-- Start swapping: remember the real state first. Returns false if it couldn't be saved.
local verify_restore

local function begin_swap()
  verify_restore() -- only reads the save, so it's fine in the menus too
  if swapping() then return true end
  swap = { profile = current_profile(), counters = current_counters(), ach = false, ctr = false }
  save()
  return true
end

-- Put the player's real unlocks back; counters too when the save allows it right now.
local function restore(why)
  if not swap then return true end
  if swap.ach then
    swap.ach = not set_profile(swap.profile)
  end
  if swap.ctr then
    swap.ctr = not set_counters(swap.counters)
    -- counters can unlock things: check the achievements once more
    if not swap.ctr and current_profile() ~= swap.profile then swap.ach = not set_profile(swap.profile) end
  end
  local done = not swap.ach and not swap.ctr
  log((done and "restored your own unlocks" or "restored your own unlocks (counters still pending)") .. " (" .. why .. ")")
  if done then swap.verify = SESSION end
  save()
  return done
end

-- In a later session: is the save still the player's own? If Steam Cloud brought back a copy with
-- the sharer's state, mark those parts as swapped again so the usual restore puts them right.
-- Anything that changed some other way since (new unlocks of the player's own) is kept.
function verify_restore()
  if not swap or swapping() or swap.verify == SESSION then return end
  local cur, real, ap = current_profile(), swap.profile, swap.applied or ""
  local t, reverted = {}, 0
  for a = 1, N do
    local c, r, x = cur:sub(a, a), real:sub(a, a), ap:sub(a, a)
    if c ~= r and c == x then reverted = reverted + 1; t[a] = r else t[a] = c end
  end
  local cc, rc, ac = current_counters(), swap.counters, swap.appliedCounters or {}
  local ctrReverted = false
  for i = 1, #codec.COUNTERS do
    if cc[i] ~= rc[i] then
      if ac[i] ~= nil and cc[i] == ac[i] then ctrReverted = true else rc[i] = cc[i] end
    end
  end
  if reverted > 0 or ctrReverted then
    log("the save came back with a shared run's state (Steam Cloud kept an older copy): putting yours back")
    swap.profile = table.concat(t)
    swap.ach, swap.ctr = reverted > 0, ctrReverted
  else
    swap = nil
  end
  save()
end

local function effective_profile(r)
  local t = {}
  for i = 1, N do t[i] = r.profile:sub(i, i) end
  for i, e in ipairs(r.events) do
    if r.fired[i] and e.ach >= 1 and e.ach <= N then t[e.ach] = "1" end
  end
  return table.concat(t)
end

-- The counter values written for a shared run. Run generation only looks at whether Isaac kills
-- (11) is above zero (curse chance) and whether ??? + Lamb kills (24 + 25) is (a room chance), while
-- the game unlocks achievements from them at higher values (Isaac kills 5: The Polaroid, 10:
-- Something Icky; Lamb kills > 0: The Gate is Open; both > 0: Golden God), also while it draws the
-- file-select screen. Counters can't be put back during a seeded run, so they may still be in the
-- save then: these values give the same run and never reach a threshold. The Greed donation
-- machine counter (115) unlocks at 500 and only matters in Greed mode, so it isn't swapped.
local function safe_counters(r)
  local c, own = {}, own_counters()
  for i, id in ipairs(codec.COUNTERS) do c[i] = r.counters[i] or 0 end
  local idx = {}
  for i, id in ipairs(codec.COUNTERS) do idx[id] = i end
  c[idx[11]] = math.min(c[idx[11]], 1)
  local bbLamb = c[idx[24]] + c[idx[25]] > 0
  c[idx[24]], c[idx[25]] = bbLamb and 1 or 0, 0
  c[idx[115]] = own[idx[115]]
  return c
end

-- Make the save hold the sharer's state for record r. Returns achievementsOk, countersOk.
local function apply_shared(r)
  begin_swap()
  local profile = effective_profile(r)
  local ctrOk = true
  if r.counters then
    local want = safe_counters(r)
    swap.appliedCounters = want
    if not same_counters(current_counters(), want) then
      swap.ctr = true
      ctrOk = set_counters(want)
    end
  end
  swap.ach, swap.applied = true, profile
  local achOk = set_profile(profile)
  save()
  return achOk, ctrOk
end

local function matches_shared(r)
  return current_profile() == effective_profile(r)
    and (not r.counters or same_counters(current_counters(), safe_counters(r)))
end

local function current_params()
  local game = Game()
  return {
    seed = game:GetSeeds():GetStartSeed(),
    playerType = Isaac.GetPlayer(0):GetPlayerType(),
    difficulty = game.Difficulty,
    challenge = Isaac.GetChallenge(),
  }
end

local function same_run(a, b)
  return a and b and a.seed == b.seed and a.playerType == b.playerType
    and a.difficulty == b.difficulty and a.challenge == b.challenge
end

local function share_code()
  if not run then return nil end
  return codec.encode(run)
end

local function player_name(ptype)
  local cfg = EntityConfig and EntityConfig.GetPlayer and EntityConfig.GetPlayer(ptype)
  return cfg and cfg:GetName() or ("character " .. ptype)
end

local DIFFICULTY = { [0] = "Normal", "Hard", "Greed", "Greedier" }

local function describe(r)
  local s = string.format("%s, %s, %s, sharer has %d/%d unlocks", Seeds.Seed2String(r.seed),
    player_name(r.playerType), DIFFICULTY[r.difficulty] or ("mode " .. r.difficulty),
    codec.count_unlocked(r.profile), N)
  if r.challenge ~= 0 then s = s .. ", challenge " .. r.challenge end
  if #r.events > 0 then s = s .. ", " .. #r.events .. " mid-run unlock(s)" end
  return s
end

-- How many achievements playing r would unlock that the player doesn't have (they'd unlock on Steam).
local function new_unlocks(r)
  local own, n = own_profile(), 0
  local want = effective_profile(r)
  for _, e in ipairs(r.events) do if e.ach >= 1 and e.ach <= N then want = want:sub(1, e.ach - 1) .. "1" .. want:sub(e.ach + 1) end end
  for a = 1, N do
    if want:sub(a, a) == "1" and own:sub(a, a) == "0" then n = n + 1 end
  end
  return n
end

------------------------------------------------------------------------------------------------
-- Starting a shared run
------------------------------------------------------------------------------------------------

local function notify(text, kind)
  status = text
  log(text)
  if ImGui and ImGui.PushNotification then ImGui.PushNotification(text, kind or 0, 8000) end
end

local function unfired(r)
  local t = {}
  for i = 1, #r.events do t[i] = false end
  return t
end

local queuedStart -- { playerType, challenge, difficulty, seed, custom } to start on the next frame
local bounce -- { record = r } or { after = params }: waiting for a normal run so counters can be set
local confirmCode -- code the player was warned about; playing it again goes ahead

local function start_shared(r)
  pending = r
  queuedStart = { playerType = r.playerType, challenge = r.challenge, difficulty = r.difficulty,
    seed = r.seed, custom = true }
end

-- Counters can't change during a seeded run: go through a normal run (thrown away straight away).
local function start_bounce(b)
  bounce = b
  log("starting a normal run for a moment so the save's counters can be changed")
  queuedStart = { playerType = PlayerType.PLAYER_ISAAC, challenge = 0, difficulty = 0,
    seed = Random() % 0x7FFFFFFF + 1, custom = false }
end

local inRun = false

local function play(code)
  local r, err = codec.decode(code)
  if not r then
    notify("ShareSeed: " .. err, 3)
    return false
  end
  local pcfg = EntityConfig and EntityConfig.GetPlayer and EntityConfig.GetPlayer(r.playerType)
  if EntityConfig and EntityConfig.GetPlayer and not pcfg then
    notify("ShareSeed: this code uses a character you don't have (modded character " .. r.playerType .. ")", 3)
    return false
  end
  local extra = new_unlocks(r)
  if extra > 0 and confirmCode ~= code then
    confirmCode = code
    notify(string.format("ShareSeed: the sharer has %d unlock(s) you don't. Playing this code unlocks them "
      .. "in your save for the run (you get your own back afterwards), but Steam will keep them as "
      .. "unlocked achievements. Play the code again to go ahead.", extra), 2)
    return false
  end
  confirmCode = nil
  r.shared, r.fired = true, unfired(r)
  notify("ShareSeed: starting " .. describe(r), 1)
  begin_swap() -- the journal is written before anything changes, and before any run starts
  if not inRun then
    start_bounce({ record = r })
    return true
  end
  local achOk, ctrOk = apply_shared(r)
  if not achOk then
    restore("couldn't apply the code")
    notify("ShareSeed: couldn't set the save to the sharer's unlocks; nothing was started", 3)
    return false
  end
  if ctrOk then start_shared(r) else start_bounce({ record = r }) end
  return true
end

local function stop()
  pending, bounce = nil, nil
  if run and run.shared then
    run = nil
  end
  if not swapping() then
    save()
    notify("ShareSeed: you're on your own unlocks.", 0)
    return
  end
  local done = inRun and restore("asked")
  save()
  notify(done and "ShareSeed: back to your own unlocks." or
    "ShareSeed: your own unlocks come back as soon as you start (or continue) a run.", 0)
end

------------------------------------------------------------------------------------------------
-- Run lifecycle
------------------------------------------------------------------------------------------------

local restartGuard = 0
local floorTrack, replay_rerolls -- floor rerolls, below

-- Eden's Blessing items are taken out of their counter while the run starts, so the values that
-- shaped a run are the ones from just before it: sampled every frame in the menus and during runs
-- (not in the frames between starting a run and MC_POST_GAME_STARTED).
local prerunCounters
local function sample_counters() prerunCounters = own_counters() end

-- After a `luamod` reload no save slot is loaded again, so read this slot's data right away.
pcall(load)

mod:AddCallback(ModCallbacks.MC_POST_SAVESLOT_LOAD, function(_, _, selected)
  if not selected then return end
  load()
  if swap and swap.ach then
    -- Left over from a crash or a forced quit during a shared run. Not touched here (see the top
    -- of the file); the first run started or continued sets it right.
    notify("ShareSeed: this save still holds a shared run's unlocks (the game closed during it). "
      .. "Start or continue any run to get your own back.", 2)
  end
end)

mod:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, function(_, continued)
  inRun = true
  local params = current_params()
  local seeds = Game():GetSeeds()
  if not bounce then verify_restore() end

  if bounce then
    -- the throwaway normal run: the save is writable now
    local b = bounce
    bounce = nil
    if b.record then
      apply_shared(b.record)
      start_shared(b.record)
    else
      restore("normal run")
      queuedStart = b.after
    end
    return
  end

  if continued then
    if not run then load() end
    if run and run.shared and same_run(run, params) then
      apply_shared(run)
      if not matches_shared(run) then log("couldn't set every counter for the continued run; later floors may differ") end
      status = "Shared run: " .. describe(run)
    else
      if swapping() then restore("continued your own run") end
      if not (run and same_run(run, params)) then
        params.profile, params.events, params.fired, params.shared = own_profile(), {}, {}, false
        params.counters = own_counters()
        run = params
      end
      save()
    end
    return
  end

  local record
  if pending and same_run(pending, params) then
    record, pending = pending, nil
  elseif run and run.shared and same_run(run, params) then
    record = run -- restarted the shared run (R key, or from the death screen)
    record.fired = unfired(record)
    record.ended = nil
  end

  -- The run was generated with whatever the save held when it started. If that was wrong, set it
  -- right and start the same run again.
  if record then
    if not matches_shared(record) and restartGuard < 2 then
      restartGuard = restartGuard + 1
      local achOk, ctrOk = apply_shared(record)
      log("restarting run so it starts with the sharer's unlocks")
      if ctrOk or not achOk then start_shared(record) else start_bounce({ record = record }) end
      return
    end
  elseif swapping() and restartGuard < 2 then
    restartGuard = restartGuard + 1
    params.custom = seeds:IsCustomRun()
    if restore("started a run of your own") then
      log("restarting run so it starts with your own unlocks")
      queuedStart = params
    else
      start_bounce({ after = params })
    end
    return
  end
  restartGuard = 0

  if record then
    run = record
    run.rerollsDone = {}
    replay_rerolls(Game():GetLevel():GetStage())
    status = "Shared run: " .. describe(run)
    notify("ShareSeed: playing " .. describe(run), 1)
  else
    params.profile, params.events, params.fired, params.shared = own_profile(), {}, {}, false
    params.counters = prerunCounters or own_counters()
    params.rerolls, params.rerollSeeds = {}, {}
    if floorTrack and floorTrack.rerolls > 0 and floorTrack.frame <= 1 and floorTrack.start == params.seed then
      params.rerolls[tostring(floorTrack.stage)] = floorTrack.rerolls
      params.rerollSeeds[tostring(floorTrack.stage)] = floorTrack.seed
    end
    run = params
    status = "Your run. Share code ready."
  end
  save()
end)

local function run_queued()
  if not queuedStart then return end
  local p = queuedStart
  queuedStart = nil
  -- The Seeds-object overload doesn't reproduce the run, so start from the plain seed.
  Isaac.StartNewGame(p.playerType, p.challenge, p.difficulty, p.seed, p.custom)
end

mod:AddCallback(ModCallbacks.MC_MAIN_MENU_RENDER, function()
  sample_counters()
  run_queued()
end)

mod:AddCallback(ModCallbacks.MC_POST_RENDER, function()
  if inRun then sample_counters() end -- for a restart from inside a run
  run_queued()
end)

-- A finished shared run can't be continued; its counters stay swapped for a restart from the death
-- screen, and go back when the next run of the player's own starts.
mod:AddCallback(ModCallbacks.MC_POST_GAME_END, function()
  if run and run.shared then
    run.ended = true
    save()
  end
end)

mod:AddCallback(ModCallbacks.MC_PRE_GAME_EXIT, function()
  inRun = false
  -- Leaving a shared run: the player's own unlocks and counters go back before the menus open.
  if swapping() and not pending and not queuedStart and not bounce then restore("left the run") end
  save()
end)

-- Sharer side: remember achievements unlocked mid-run, and where, so the replay unlocks them at the
-- same point.
mod:AddCallback(ModCallbacks.MC_POST_ACHIEVEMENT_UNLOCK, function(_, ach)
  -- only real unlocks in the run (the file-select screen re-checks every save it draws)
  if not inRun or not run or run.shared or swapping() or ach < 1 or ach > N then return end
  local level = Game():GetLevel()
  run.events[#run.events + 1] = {
    ach = ach,
    stage = level:GetStage(),
    stageType = level:GetStageType(),
    room = level:GetCurrentRoomIndex(),
  }
  save()
end)

-- Replay side: fire recorded unlocks.
local function fire_events(predicate)
  if not run or not run.shared or #run.events == 0 then return end
  local changed = false
  for i, e in ipairs(run.events) do
    if not run.fired[i] and predicate(e) then
      run.fired[i] = true
      changed = true
    end
  end
  if changed then
    swap.ach = true
    set_profile(effective_profile(run))
    save()
  end
end

mod:AddCallback(ModCallbacks.MC_PRE_SPAWN_CLEAN_AWARD, function()
  local level = Game():GetLevel()
  local stage, stype, room = level:GetStage(), level:GetStageType(), level:GetCurrentRoomIndex()
  fire_events(function(e) return e.stage == stage and e.stageType == stype and e.room == room end)
end)

mod:AddCallback(ModCallbacks.MC_POST_NEW_LEVEL, function()
  local stage = Game():GetLevel():GetStage()
  fire_events(function(e) return e.stage < stage end)
end)

------------------------------------------------------------------------------------------------
-- Floor rerolls
--
-- Some mods (Treasure Room Start, for one) regenerate a floor with the `reseed` command the moment
-- it begins, on normal runs only. Reseeding is deterministic, so the sharer side counts those
-- rerolls and the replay does the same number. A floor counts as rerolled when it is generated
-- again with a new stage seed within a frame of the last generation; rerolls the player causes
-- later (Forget Me Now, say) aren't counted, since the replaying player repeats those themselves.
------------------------------------------------------------------------------------------------

-- floorTrack = { stage, stageType, frame, natural, seed, rerolls } for the floor being played
local reseeding = false

function replay_rerolls(stage)
  if not run or not run.shared or not run.rerolls then return end
  local key = tostring(stage)
  local n = run.rerolls[key]
  run.rerollsDone = run.rerollsDone or {}
  if not n or run.rerollsDone[key] then return end
  run.rerollsDone[key] = true
  local target = run.rerollSeeds and run.rerollSeeds[key]
  local seeds = Game():GetSeeds()
  local function seed() return seeds:GetStageSeed(stage) & 0xFFFFFFFF end
  local done = 0
  reseeding = true
  if target then
    -- reroll until the floor has the sharer's seed (the count alone can be thrown off)
    while seed() ~= target and done < 64 do
      Isaac.ExecuteCommand("reseed")
      done = done + 1
    end
  else
    for _ = 1, n do Isaac.ExecuteCommand("reseed") end
    done = n
  end
  reseeding = false
  if target and seed() ~= target then
    notify("ShareSeed: couldn't reproduce the sharer's floor " .. stage .. " (it was rerolled by a mod); "
      .. "the run will differ from here", 3)
  else
    log("rerolled floor " .. stage .. " " .. done .. " time(s), like the sharer's run")
  end
  save()
end

mod:AddCallback(ModCallbacks.MC_POST_NEW_LEVEL, function()
  if reseeding then return end
  local game, level = Game(), Game():GetLevel()
  local stage, stype, frame = level:GetStage(), level:GetStageType(), game:GetFrameCount()
  local seed = game:GetSeeds():GetStageSeed(stage) & 0xFFFFFFFF
  local start = game:GetSeeds():GetStartSeed()
  local t = floorTrack
  -- same run (a new run's first floor isn't a reroll of the last one's), same floor, a new seed
  if t and t.start == start and t.stage == stage and t.stageType == stype and frame - t.frame <= 1
      and frame >= t.frame and seed ~= t.seed and seed ~= t.natural then
    t.rerolls, t.frame, t.seed = t.rerolls + 1, frame, seed
    if run and not run.shared and inRun and not bounce and not pending and not queuedStart
        and run.seed == start then
      run.rerolls, run.rerollSeeds = run.rerolls or {}, run.rerollSeeds or {}
      run.rerolls[tostring(stage)] = t.rerolls
      run.rerollSeeds[tostring(stage)] = seed
      save()
    end
    return
  end
  floorTrack = { start = start, stage = stage, stageType = stype, frame = frame, natural = seed, seed = seed, rerolls = 0 }
  if inRun and frame > 0 then replay_rerolls(stage) end -- a run's first floor: MC_POST_GAME_STARTED
end)

------------------------------------------------------------------------------------------------
-- Console command
------------------------------------------------------------------------------------------------

local HELP = [[
shareseed            copy this run's share code to the clipboard
shareseed play       play the code on your clipboard
shareseed play CODE  play CODE
shareseed info CODE  show what's in a code (no CODE = clipboard)
shareseed stop       go back to your own unlocks
]]

local function copy_code()
  local code = share_code()
  if not code then return nil end
  Isaac.SetClipboard(code)
  return code
end

-- Output goes through ConsoleOutput: returning a string from MC_EXECUTE_CMD crashes the game when
-- the command is typed into the REPENTOGON console (seen on REPENTOGON 1.1.3).
local function handle_command(sub, rest)
  if sub == "" or sub == "code" then
    local code = copy_code()
    if not code then return "No run yet. Start a run first." end
    return "Copied to clipboard:\n" .. code .. "\n" .. describe(run)
  elseif sub == "play" then
    local code = rest ~= "" and rest or Isaac.GetClipboard()
    play(code)
    return status
  elseif sub == "info" then
    local r, err = codec.decode(rest ~= "" and rest or Isaac.GetClipboard())
    if not r then return err end
    local extra = new_unlocks(r)
    return describe(r) .. (extra > 0 and ("\n" .. extra .. " of the sharer's unlocks would be new to you (and to Steam)") or "")
  elseif sub == "stop" then
    stop()
    return status
  end
  return HELP
end

mod:AddCallback(ModCallbacks.MC_EXECUTE_CMD, function(_, cmd, args)
  if cmd ~= "shareseed" and cmd ~= "ss" then return end
  local sub, rest = (args or ""):match("^%s*(%S*)%s*(.-)%s*$")
  local ok, out = pcall(handle_command, sub, rest)
  local text = (ok and "" or "ShareSeed error: ") .. tostring(out)
  if text:sub(-1) ~= "\n" then text = text .. "\n" end
  Isaac.ConsoleOutput(text)
end)

if Console and Console.RegisterCommand then
  Console.RegisterCommand("shareseed", "Share a seed with your unlocks, or play someone else's",
    HELP, false, AutocompleteType and AutocompleteType.NONE or 0)
end

------------------------------------------------------------------------------------------------
-- ImGui window (open the console with ~, then ShareSeed in the menu bar)
------------------------------------------------------------------------------------------------

local W = "shareseedWindow"
local inputCode = ""
local shownCode, shownStatus

local function build_ui()
  if not ImGui or ImGui.ElementExists("shareseedMenu") then return end
  ImGui.CreateMenu("shareseedMenu", "ShareSeed")
  ImGui.AddElement("shareseedMenu", "shareseedMenuOpen", ImGuiElement.MenuItem, "Share / play a seed")
  ImGui.CreateWindow(W, "ShareSeed")
  ImGui.LinkWindowToElement(W, "shareseedMenuOpen")
  ImGui.SetWindowSize(W, 760, 500)

  ImGui.AddElement(W, "shareseedDeco1", ImGuiElement.SeparatorText, "Share this run")
  ImGui.AddText(W, "Start or continue a run to get its code.", true, "shareseedCode")
  ImGui.AddButton(W, "shareseedCopy", "Copy code", function()
    local code = copy_code()
    notify(code and "ShareSeed: code copied to clipboard" or "ShareSeed: no run in progress", code and 1 or 2)
  end)

  ImGui.AddElement(W, "shareseedDeco2", ImGuiElement.SeparatorText, "Play a friend's code")
  ImGui.AddInputText(W, "shareseedInput", "Code", function(v) inputCode = v end, "", "SS1.XXXXXXXX....")
  ImGui.AddButton(W, "shareseedPaste", "Paste", function()
    inputCode = Isaac.GetClipboard() or ""
    ImGui.UpdateData("shareseedInput", ImGuiData.Value, inputCode)
  end, true)
  ImGui.AddElement(W, "shareseedDeco3", ImGuiElement.SameLine)
  ImGui.AddButton(W, "shareseedPlay", "Play this code", function()
    if play(inputCode) then ImGui.Hide() end
  end, true)
  ImGui.AddElement(W, "shareseedDeco4", ImGuiElement.SameLine)
  ImGui.AddButton(W, "shareseedStop", "Use my own unlocks", stop, true)
  ImGui.AddText(W, "", true, "shareseedPreview")

  ImGui.AddElement(W, "shareseedDeco5", ImGuiElement.Separator)
  ImGui.AddText(W, "", true, "shareseedStatus")
end

local lastPreviewInput

local function refresh_ui()
  if not ImGui or not ImGui.ElementExists(W) then return end
  local code = inRun and share_code() or nil
  if code ~= shownCode then
    shownCode = code
    ImGui.UpdateText("shareseedCode", code and (code .. "\n" .. describe(run)) or "Start or continue a run to get its code.")
  end
  if inputCode ~= lastPreviewInput then
    lastPreviewInput = inputCode
    local r, err = codec.decode(inputCode)
    local text = ""
    if inputCode ~= "" then
      if r then
        local extra = new_unlocks(r)
        text = "-> " .. describe(r) .. (extra > 0 and ("\n   " .. extra .. " of the sharer's unlocks are new to you; "
          .. "Steam would keep them") or "")
      else
        text = "-> " .. err
      end
    end
    ImGui.UpdateText("shareseedPreview", text)
  end
  if status ~= shownStatus then
    shownStatus = status
    ImGui.UpdateText("shareseedStatus", status)
  end
end

build_ui()

mod:AddCallback(ModCallbacks.MC_POST_RENDER, refresh_ui)
mod:AddCallback(ModCallbacks.MC_MAIN_MENU_RENDER, refresh_ui)

-- Short reminder on screen at the start of a shared run.
local bannerFrames = 0
mod:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, function()
  bannerFrames = (run and run.shared) and 300 or 0
end)
mod:AddCallback(ModCallbacks.MC_POST_RENDER, function()
  if bannerFrames <= 0 or not run then return end
  bannerFrames = bannerFrames - 1
  local a = math.min(1, bannerFrames / 60)
  Isaac.RenderText("ShareSeed: sharer's unlocks (" .. codec.count_unlocked(run.profile) .. "/" .. N .. ")",
    60, 245, 1, 1, 1, a)
end)

-- Put the player's own unlocks back when the mod is unloaded in a run (luamod). In the menus the
-- journal stays and the next run with ShareSeed enabled restores it.
mod:AddCallback(ModCallbacks.MC_PRE_MOD_UNLOAD, function(_, m)
  if m == mod and swapping() and inRun then restore("mod unloaded") end
end)

SHARESEED_API = {
  codec = codec,
  play = play,
  stop = stop,
  share_code = share_code,
  own_profile = own_profile,
  own_counters = own_counters,
  own_unlocked = own_unlocked,
  current_profile = current_profile,
  get_run = function() return run end,
  get_swap = function() return swap end,
  swapping = swapping,
  restore = restore,
  -- the sharer's profile while the save holds it, nil otherwise
  get_applied = function() return (swap and swap.ach and run and run.shared) and effective_profile(run) or nil end,
}
