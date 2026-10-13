-- Mech Crafter: a 5x5 mechanical crafting station run by a computer.
--
-- When a Factory Controller gauge for one of your recipes is below its target,
-- this orders the ingredients through a Stock Ticker, fills the crafters in the
-- recipe's pattern and pulses PULSE_SIDE to start the craft. The crafters'
-- output goes wherever your build sends it. Gauge data comes from the Factory
-- Monitor computer over rednet.

-- Peripheral names: right-click a block's wired modem to see its name.
INPUT_CHEST = "minecraft:chest_0"   -- ingredient packages unpack into this
STORAGE = nil                       -- optional: where "Return them" sends unordered items
CRAFTERS = nil                      -- nil = find the connected crafter grid
STOCK_TICKER = nil                  -- nil = find it
PACKAGER = nil                      -- optional, only used for the package log

PULSE_SIDE = "back"                 -- side facing a crafter
STATION_ADDRESS = "MechCrafter"     -- address ingredient orders are sent to

MAX_SETS_PER_ORDER = 8              -- crafts' worth of ingredients per order
MAX_OPEN_ORDERS = 2                 -- per recipe
MAX_QUEUED_SETS = 16                -- per recipe: ordered + waiting in the chest, not yet crafted
ORDER_TIMEOUT_MINUTES = 5           -- give up on an order that hasn't fully arrived
CRAFT_TIMEOUT_SECONDS = 30          -- crafters must be ready for the next craft within this
RETRY_PULSES = 3                    -- if a craft doesn't start (e.g. the base unloaded), pulse again this many times
RETRY_SECONDS = 20                  -- seconds between those retries
AUTO_UPDATE = true        -- install new versions from GitHub automatically, keeping these settings


-- ============================================================ basics

local DIR = "/mechcraft"
local VERSION = "1.0"

local function now() return os.epoch("utc") / 1000 end

local function readFile(path, default)
  if not fs.exists(path) then return default end
  local f = fs.open(path, "r")
  local data = textutils.unserialize(f.readAll())
  f.close()
  if data == nil then return default end
  return data
end

local function writeFile(path, data)
  local tmp = path .. ".tmp"
  local f = fs.open(tmp, "w")
  f.write(textutils.serialize(data))
  f.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(tmp, path)
end

local function pretty(id)
  if not id then return "?" end
  local name = id:gsub("^[^:]+:", ""):gsub("_", " ")
  return (name:gsub("(%a)(%w*)", function(a, b) return a:upper() .. b end))
end

local function clip(s, n)
  s = tostring(s)
  if #s > n then return s:sub(1, math.max(1, n - 1)) .. "." end
  return s
end

local function fmtNum(n)
  n = math.floor(n or 0)
  if n >= 1000000 then return string.format("%.1fM", n / 1000000) end
  if n >= 10000 then return string.format("%.1fk", n / 1000) end
  return tostring(n)
end

local function sum(t)
  local s = 0
  for _, v in pairs(t) do s = s + v end
  return s
end

-- ============================================================ saved data

-- recipes[name] = { name, output, makes, cells = { ["r,c"] = itemId }, paused, error }
local recipes = readFile(DIR .. "/recipes", {})
-- calibration[slot] = { r = row, c = col }
local calibration = readFile(DIR .. "/calibration", {})
local state = readFile(DIR .. "/state", nil) or {
  ledger = {},      -- [recipe] = { [item] = count } ingredients ready to craft
  orders = {},      -- open ingredient orders
  manual = {},      -- [recipe] = extra crafts requested by hand
  made = {},        -- [recipe] = crafts done
  active = nil,     -- craft in progress
  nextOrder = 1,
  recent = {},      -- { t, recipe, items } outputs not yet visible in gauge stock
  guard = {},       -- [recipe] = { stock, crafted } runaway-crafting check
}

local function saveRecipes() writeFile(DIR .. "/recipes", recipes) end
local function saveCalibration() writeFile(DIR .. "/calibration", calibration) end
local function saveState() writeFile(DIR .. "/state", state) end

-- ============================================================ log

local logLines = readFile(DIR .. "/log", {})
local LOG_KEEP = 200
local dirty = true

local function log(level, msg)
  local t = os.date and os.date("%H:%M:%S") or tostring(math.floor(now()))
  table.insert(logLines, { t = t, level = level, msg = msg })
  while #logLines > LOG_KEEP do table.remove(logLines, 1) end
  writeFile(DIR .. "/log", logLines)
  dirty = true
end

-- ============================================================ peripherals

local P = {}
local problems = {}
local resolvedAt = 0
local needResolve = true

local function findCrafter()
  local best, bestSize = nil, 0
  for _, name in ipairs(peripheral.getNames()) do
    if name:find("mechanical_crafter", 1, true) then
      local ok, size = pcall(peripheral.call, name, "size")
      if ok and size and size > bestSize then best, bestSize = name, size end
    end
  end
  return best
end

local function resolve()
  P.input = INPUT_CHEST
  P.storage = STORAGE
  P.crafter = CRAFTERS or findCrafter()
  P.ticker = STOCK_TICKER
  if not P.ticker then
    local t = peripheral.find("Create_StockTicker")
    P.ticker = t and peripheral.getName(t)
  end
  P.packager = PACKAGER
  if not P.packager then
    local p = peripheral.find("Create_Packager")
    P.packager = p and peripheral.getName(p)
  end

  problems = {}
  local function need(name, label)
    if not name or not peripheral.isPresent(name) then
      table.insert(problems, label .. " not found" .. (name and (": " .. name) or ""))
      return false
    end
    return true
  end
  need(P.input, "Input chest")
  need(P.crafter, "Crafters")
  need(P.ticker, "Stock Ticker")
  P.size = 0
  if P.crafter and peripheral.isPresent(P.crafter) then
    local ok, size = pcall(peripheral.call, P.crafter, "size")
    P.size = ok and size or 0
  end
  return #problems == 0
end

local function call(name, method, ...)
  if not name then return false, "no peripheral" end
  return pcall(peripheral.call, name, method, ...)
end

-- Item totals and slot list of an inventory.
local function contents(name)
  local ok, items = call(name, "list")
  if not ok or type(items) ~= "table" then return nil end
  local totals, slots = {}, {}
  for slot, item in pairs(items) do
    totals[item.name] = (totals[item.name] or 0) + item.count
    table.insert(slots, { slot = slot, name = item.name, count = item.count })
  end
  table.sort(slots, function(a, b) return a.slot < b.slot end)
  return totals, slots
end

-- ============================================================ recipes

local function recipeNeed(r)
  local need = {}
  for _, id in pairs(r.cells) do need[id] = (need[id] or 0) + 1 end
  return need
end

local function sortedRecipeNames()
  local names = {}
  for name in pairs(recipes) do table.insert(names, name) end
  table.sort(names)
  return names
end

local slotForCell = {}
local function rebuildSlotMap()
  slotForCell = {}
  for slot, pos in pairs(calibration) do
    slotForCell[pos.r .. "," .. pos.c] = slot
  end
end
rebuildSlotMap()

local function uncalibratedCells(r)
  local missing = 0
  for key in pairs(r.cells) do
    if not slotForCell[key] then missing = missing + 1 end
  end
  return missing
end

local function ledgerOf(name)
  state.ledger[name] = state.ledger[name] or {}
  return state.ledger[name]
end

local function setsIn(have, need)
  local sets = math.huge
  for id, n in pairs(need) do
    sets = math.min(sets, math.floor((have[id] or 0) / n))
  end
  if sets == math.huge then return 0 end
  return sets
end

local function openSets(name)
  local s = 0
  for _, o in ipairs(state.orders) do
    if o.recipe == name then s = s + o.sets end
  end
  return s
end

local function openOrderCount(name)
  local c = 0
  for _, o in ipairs(state.orders) do
    if o.recipe == name then c = c + 1 end
  end
  return c
end

-- ============================================================ factory data (from the monitor)

local factory = { gauges = {}, at = 0, paused = false }

local function gaugeFor(itemId)
  local best
  for _, g in ipairs(factory.gauges) do
    if g.item == itemId then
      local deficit = (g.target or 0) - (g.stock or 0)
      if not best or deficit > best.deficit then
        best = { g = g, deficit = deficit }
      end
    end
  end
  return best and best.g
end

local function factoryFresh()
  return now() - factory.at < 15
end

-- ============================================================ engine

local recipeStatus = {}  -- [name] = { text, color }
local recipeMissing = {} -- [name] = { { item, have, need } } while blocked on ingredients

-- Why the network is short of an item, judged from the gauge that makes it.
local function supplyState(itemId)
  local g = gaugeFor(itemId)
  if not factoryFresh() then return "no factory data" end
  if not g then return "no gauge makes it" end
  if g.paused or factory.paused then return "its gauge is paused" end
  if (g.promised or 0) > 0 then return "+" .. g.promised .. " on the way" end
  if g.waiting then return "its gauge is waiting for inputs" end
  if g.satisfied then return "gauge target too low" end
  return "gauge short, not ordered yet"
end
local activity = "Starting"
local calibrating = false
local pendingAction = nil

local function setStatus(name, text, color)
  local s = recipeStatus[name]
  if not s or s.text ~= text then dirty = true end
  recipeStatus[name] = { text = text, color = color or colors.white }
end

local function pauseRecipe(name, why)
  local r = recipes[name]
  if not r then return end
  r.paused = true
  r.error = why
  saveRecipes()
  log("error", name .. ": " .. why)
end

-- Match what's physically in the input chest against what we've accounted for.
-- New items are credited to open orders (oldest first); anything left over is
-- an "extra" nobody ordered.
local extras = {}
local function reconcile()
  local phys = contents(P.input)
  if not phys then return end
  local changed = false

  local claimed = {}
  for _, items in pairs(state.ledger) do
    for id, n in pairs(items) do claimed[id] = (claimed[id] or 0) + n end
  end
  for _, o in ipairs(state.orders) do
    for id, n in pairs(o.got) do claimed[id] = (claimed[id] or 0) + n end
  end

  -- Someone took items out: shrink our records to match, newest claims first.
  for id, n in pairs(claimed) do
    local short = n - (phys[id] or 0)
    if short > 0 then
      for i = #state.orders, 1, -1 do
        local o = state.orders[i]
        local take = math.min(short, o.got[id] or 0)
        if take > 0 then
          o.got[id] = o.got[id] - take
          o.remaining[id] = (o.remaining[id] or 0) + take
          short = short - take
          changed = true
        end
      end
      for name, items in pairs(state.ledger) do
        if short <= 0 then break end
        local take = math.min(short, items[id] or 0)
        if take > 0 then
          items[id] = items[id] - take
          short = short - take
          changed = true
          log("warn", "Input chest is missing " .. take .. " " .. pretty(id) .. " (" .. name .. ")")
        end
      end
      claimed[id] = phys[id] or 0
    end
  end

  local surplus = {}
  for id, n in pairs(phys) do
    local s = n - (claimed[id] or 0)
    if s > 0 then surplus[id] = s end
  end

  for _, o in ipairs(state.orders) do
    for id, rem in pairs(o.remaining) do
      local take = math.min(rem, surplus[id] or 0)
      if take > 0 then
        o.remaining[id] = rem - take
        o.got[id] = (o.got[id] or 0) + take
        surplus[id] = surplus[id] - take
        changed = true
      end
    end
  end
  -- Leftovers nobody ordered (late packages, items dropped in by hand) go to
  -- the first recipe that uses them, so they get crafted instead of sitting there.
  for _, name in ipairs(sortedRecipeNames()) do
    local r = recipes[name]
    if not r.paused then
      for id in pairs(recipeNeed(r)) do
        local n = surplus[id] or 0
        if n > 0 then
          local ledger = ledgerOf(name)
          ledger[id] = (ledger[id] or 0) + n
          surplus[id] = nil
          changed = true
          log("info", "Using " .. n .. " leftover " .. pretty(id) .. " for " .. name)
        end
      end
    end
  end
  extras = surplus

  -- Finished or expired orders hand their items to the recipe's ledger.
  local t = now()
  for i = #state.orders, 1, -1 do
    local o = state.orders[i]
    local complete = sum(o.remaining) == 0
    local expired = t - o.at > ORDER_TIMEOUT_MINUTES * 60
    if complete or expired then
      local ledger = ledgerOf(o.recipe)
      for id, n in pairs(o.got) do ledger[id] = (ledger[id] or 0) + n end
      table.remove(state.orders, i)
      if complete then
        log("info", "Order #" .. o.id .. " arrived (" .. o.recipe .. " x" .. o.sets .. ")")
      else
        log("warn", "Order #" .. o.id .. " timed out, " .. sum(o.remaining) .. " items never arrived")
      end
      dirty = true
      changed = true
    end
  end
  if changed then saveState() end
end

local function recentItems(name)
  local t, n = now(), 0
  for i = #state.recent, 1, -1 do
    local e = state.recent[i]
    if t - e.t > 20 then
      table.remove(state.recent, i)
    elseif e.recipe == name then
      n = n + e.items
    end
  end
  return n
end

local function unitMultiplier(g, r)
  if g.unit == "STACKS" then return r.stack or 64 end
  if g.unit == "ITEMS" or g.unit == nil then return 1 end
  return nil  -- fluid gauge, not ours
end

-- How many more crafts the gauge wants beyond what's already on the way.
local function wantedSets(name, r)
  local want = state.manual[name] or 0
  local g = gaugeFor(r.output)
  if g and factoryFresh() and not factory.paused and not g.paused then
    local mult = unitMultiplier(g, r)
    if mult then
      local deficit = g.target * mult - g.stock - g.promised - recentItems(name)
      if deficit > 0 then want = want + math.ceil(deficit / r.makes) end
    end
  end
  return want, g
end

local lastOrderAt = {}

local function inputFreeSlots()
  local okS, size = call(P.input, "size")
  local _, slots = contents(P.input)
  if not okS or not size or not slots then return 0 end
  return size - #slots
end

local function orderIngredients(name, r)
  recipeMissing[name] = nil
  local want, g = wantedSets(name, r)
  local ledgerSets = setsIn(ledgerOf(name), recipeNeed(r))
  local active = (state.active and state.active.recipe == name) and 1 or 0
  local pipeline = openSets(name) + ledgerSets + active
  local sets = math.min(want - pipeline, MAX_SETS_PER_ORDER, MAX_QUEUED_SETS - pipeline)

  if want == 0 then
    if g then
      setStatus(name, "Stocked", colors.lime)
    elseif not factoryFresh() then
      setStatus(name, "No factory data", colors.orange)
    else
      setStatus(name, "No gauge", colors.lightGray)
    end
    return
  end
  if sets <= 0 then
    if pipeline >= MAX_QUEUED_SETS then
      setStatus(name, "Working (" .. pipeline .. " queued, max " .. MAX_QUEUED_SETS .. ")", colors.yellow)
    else
      setStatus(name, "Working", colors.yellow)
    end
    return
  end
  if openOrderCount(name) >= MAX_OPEN_ORDERS then
    setStatus(name, "Waiting for delivery", colors.yellow)
    return
  end
  if lastOrderAt[name] and now() - lastOrderAt[name] < 5 then return end

  local ok, stock = call(P.ticker, "stock")
  if not ok or type(stock) ~= "table" then
    setStatus(name, "Can't read stock", colors.red)
    return
  end
  local have = {}
  for _, s in pairs(stock) do have[s.name] = (have[s.name] or 0) + s.count end

  local need = recipeNeed(r)

  -- Partial leftovers already in the chest count toward this order, minus
  -- what earlier open orders are already counting on.
  local ledger = ledgerOf(name)
  local leftover = {}
  for id, n in pairs(need) do
    leftover[id] = math.max(0, (ledger[id] or 0) - n * ledgerSets)
  end
  for _, o in ipairs(state.orders) do
    if o.recipe == name and o.fromLeftover then
      for id, n in pairs(o.fromLeftover) do leftover[id] = math.max(0, (leftover[id] or 0) - n) end
    end
  end
  local function request(k)
    local req, used = {}, {}
    for id, n in pairs(need) do
      used[id] = math.min(leftover[id], n * k)
      req[id] = n * k - used[id]
    end
    return req, used
  end
  local function fits(req)
    for id, n in pairs(req) do
      if (have[id] or 0) < n then return false end
    end
    return true
  end

  while sets > 0 and not fits((request(sets))) do sets = sets - 1 end
  if sets == 0 then
    local req = request(1)
    local missing, info = {}, {}
    for id, n in pairs(req) do
      if (have[id] or 0) < n then
        table.insert(missing, pretty(id) .. ": have " .. (have[id] or 0) .. ", need " .. n .. " (" .. supplyState(id) .. ")")
        table.insert(info, { item = id, have = have[id] or 0, need = n })
      end
    end
    recipeMissing[name] = info
    setStatus(name, "Missing " .. table.concat(missing, "; "), colors.red)
    return
  end

  -- Only order what will fit in the input chest, keeping two slots spare.
  local free = inputFreeSlots()
  while sets > 0 do
    local slotsNeeded = 0
    for _, n in pairs((request(sets))) do slotsNeeded = slotsNeeded + math.ceil(n / 64) end
    if slotsNeeded <= free - 2 then break end
    sets = sets - 1
  end
  if sets <= 0 then
    setStatus(name, "Input chest full", colors.orange)
    return
  end

  local req, used = request(sets)
  local filters, total = {}, 0
  for id, n in pairs(req) do
    if n > 0 then
      table.insert(filters, { name = id, _requestCount = n })
      total = total + n
    end
  end
  if total == 0 then return end
  local okReq, sent = call(P.ticker, "requestFiltered", STATION_ADDRESS, table.unpack(filters))
  lastOrderAt[name] = now()
  if not okReq or not sent or sent == 0 then
    setStatus(name, "Order failed", colors.red)
    log("error", "Stock Ticker couldn't send ingredients for " .. name .. ": " .. tostring(sent))
    return
  end

  local remaining = {}
  for id, n in pairs(req) do
    if n > 0 then remaining[id] = n end
  end
  table.insert(state.orders, {
    id = state.nextOrder, recipe = name, sets = sets,
    remaining = remaining, got = {}, at = now(), fromLeftover = used,
  })
  state.nextOrder = state.nextOrder + 1
  saveState()
  if sent < total then
    log("warn", "Order #" .. (state.nextOrder - 1) .. ": only " .. sent .. " of " .. total .. " items sent")
  else
    log("info", "Ordered " .. sets .. "x " .. name .. " ingredients (#" .. (state.nextOrder - 1) .. ")")
  end
  setStatus(name, "Ordered", colors.yellow)
end

local function pulse()
  rs.setOutput(PULSE_SIDE, true)
  sleep(0.15)
  rs.setOutput(PULSE_SIDE, false)
end

-- Put everything in the crafters back into the input chest.
local function clearCrafters()
  local _, slots = contents(P.crafter)
  if not slots then return false end
  for _, s in ipairs(slots) do
    call(P.crafter, "pushItems", P.input, s.slot)
  end
  local totals = contents(P.crafter)
  return totals ~= nil and next(totals) == nil
end

local function finishCraft(name)
  local r = recipes[name]
  local makes = r and r.makes or 1
  state.active = nil
  state.made[name] = (state.made[name] or 0) + 1
  if (state.manual[name] or 0) > 0 then state.manual[name] = state.manual[name] - 1 end
  table.insert(state.recent, { t = now(), recipe = name, items = makes })
  local guard = state.guard[name] or { crafted = 0 }
  guard.crafted = guard.crafted + makes
  state.guard[name] = guard
  saveState()
  dirty = true
end

local function giveBack(name, need)
  local ledger = ledgerOf(name)
  for id, n in pairs(need) do ledger[id] = (ledger[id] or 0) + n end
  state.active = nil
  saveState()
end

-- After a pulse the crafters empty their slots the moment the craft starts.
-- If they don't (usually because the base was unloaded mid-craft), pulse
-- again, up to RETRY_PULSES more times, RETRY_SECONDS apart.
local function waitForStart(name)
  local tries = 0
  while true do
    local start = now()
    while now() - start < (tries == 0 and 5 or RETRY_SECONDS) do
      sleep(0.25)
      local c = contents(P.crafter)
      if c and next(c) == nil then
        if tries > 0 then log("info", name .. " started after " .. (tries + 1) .. " pulses") end
        return true
      end
    end
    if tries >= RETRY_PULSES then return false end
    tries = tries + 1
    log("info", name .. " didn't start, pulsing again (" .. tries .. " of " .. RETRY_PULSES .. ")")
    pulse()
    activity = "Crafting " .. name .. " (retry " .. tries .. " of " .. RETRY_PULSES .. ")"
    dirty = true
  end
end

-- A craft was running when the computer stopped or errored. Work out what happened.
local function recoverActive()
  local a = state.active
  if not a then return end
  local name = a.recipe
  local crafterItems = contents(P.crafter)
  if not crafterItems then return end
  if a.filled and next(crafterItems) == nil then
    log("info", "Recovered finished " .. name .. " craft")
    finishCraft(name)
    return
  end
  if a.filled and next(crafterItems) ~= nil then
    -- The crafters are still loaded (the base or computer was unloaded mid-craft):
    -- just pulse again instead of starting over.
    log("info", "Resuming " .. name .. " craft after a restart")
    activity = "Resuming " .. name
    pulse()
    if waitForStart(name) then
      finishCraft(name)
      return
    end
    clearCrafters()
    giveBack(name, a.need)
    pauseRecipe(name, "Crafters didn't start after " .. (RETRY_PULSES + 1) .. " pulses. Check rotation and the pattern")
    return
  end
  if next(crafterItems) ~= nil then clearCrafters() end
  giveBack(name, a.need)
  log("warn", "Interrupted " .. name .. " craft, ingredients returned")
end

local failStreak = {}

-- Crafters only accept items while idle, so a refused item means the last
-- craft is still running. Keep offering the first item until one goes in.
-- If they stay busy (often a craft frozen when the base unloaded), pulse to
-- nudge them, up to RETRY_PULSES times RETRY_SECONDS apart.
local function waitForIdle(step, name)
  for attempt = 0, RETRY_PULSES do
    local start = now()
    while now() - start < (attempt == 0 and CRAFT_TIMEOUT_SECONDS or RETRY_SECONDS) do
      local ok, n = call(P.input, "pushItems", P.crafter, step.from, 1, step.to)
      if ok and n == 1 then return true end
      sleep(0.5)
    end
    if attempt < RETRY_PULSES then
      log("info", "Crafters still busy, pulsing (" .. (attempt + 1) .. " of " .. RETRY_PULSES .. ")")
      activity = "Crafters busy, retry " .. (attempt + 1) .. " of " .. RETRY_PULSES
      pulse()
    end
  end
  return false
end

local function craftOnce(name, r)
  local need = recipeNeed(r)

  -- Crafters must start empty.
  local inCrafter = contents(P.crafter)
  if not inCrafter then return false end
  if next(inCrafter) ~= nil then
    log("warn", "Crafters weren't empty, moved leftovers to the input chest")
    if not clearCrafters() then
      setStatus(name, "Crafters busy", colors.red)
      return false
    end
  end

  -- Plan which chest slot feeds which crafter.
  local _, slots = contents(P.input)
  if not slots then return false end
  local avail = {}
  for _, s in ipairs(slots) do
    avail[s.name] = avail[s.name] or {}
    table.insert(avail[s.name], { slot = s.slot, left = s.count })
  end
  local plan = {}
  local cellKeys = {}
  for key in pairs(r.cells) do table.insert(cellKeys, key) end
  table.sort(cellKeys)
  for _, key in ipairs(cellKeys) do
    local id = r.cells[key]
    local toSlot = slotForCell[key]
    if not toSlot then
      pauseRecipe(name, "Grid cell " .. key .. " isn't calibrated")
      return false
    end
    local src
    for _, a in ipairs(avail[id] or {}) do
      if a.left > 0 then src = a break end
    end
    if not src then
      setStatus(name, "Ingredients missing from chest", colors.red)
      return false
    end
    src.left = src.left - 1
    table.insert(plan, { from = src.slot, to = toSlot, id = id })
  end

  -- Claim the ingredients before moving anything so a crash can't lose them.
  local ledger = ledgerOf(name)
  for id, n in pairs(need) do ledger[id] = (ledger[id] or 0) - n end
  state.active = { recipe = name, need = need, at = now(), filled = false }
  saveState()
  activity = "Crafting " .. name
  dirty = true

  if not waitForIdle(plan[1], name) then
    clearCrafters()
    giveBack(name, need)
    pauseRecipe(name, "Crafters stayed busy after " .. RETRY_PULSES .. " retries. Is their output blocked?")
    return false
  end

  -- Fill the rest in the same tick.
  local failed = 0
  local tasks = {}
  for i = 2, #plan do
    local step = plan[i]
    tasks[#tasks + 1] = function()
      local ok, n = call(P.input, "pushItems", P.crafter, step.from, 1, step.to)
      if not ok or n ~= 1 then failed = failed + 1 end
    end
  end
  if #tasks > 0 then parallel.waitForAll(table.unpack(tasks)) end

  if failed > 0 then
    clearCrafters()
    giveBack(name, need)
    failStreak[name] = (failStreak[name] or 0) + 1
    log("warn", name .. ": " .. failed .. " crafter(s) refused an item")
    if failStreak[name] >= 3 then
      pauseRecipe(name, "Crafters keep refusing items (slot covers?)")
    end
    return false
  end
  state.active.filled = true
  saveState()

  pulse()

  if waitForStart(name) then
    failStreak[name] = 0
    finishCraft(name)
    return true
  end

  clearCrafters()
  giveBack(name, need)
  pauseRecipe(name, "Crafters didn't start after " .. (RETRY_PULSES + 1) .. " pulses. Check rotation and the pattern")
  return false
end

-- Stop if we keep crafting but the gauge's stock never rises (output not reaching the network).
local function runawayCheck(name, r)
  local g = gaugeFor(r.output)
  local guard = state.guard[name]
  if not g or not guard then return end
  if guard.stock == nil or g.stock > guard.stock then
    guard.stock = g.stock
    guard.crafted = 0
    return
  end
  local limit = math.max(256, (g.target or 0) * (unitMultiplier(g, r) or 1) * 4)
  if guard.crafted > limit then
    pauseRecipe(name, "Crafted " .. guard.crafted .. " but gauge stock didn't rise. Is the output reaching the network?")
    guard.crafted = 0
  end
end

local function returnExtras()
  if not P.storage then return end
  local _, slots = contents(P.input)
  if not slots then return end
  local left = {}
  for id, n in pairs(extras) do left[id] = n end
  local moved = 0
  for _, s in ipairs(slots) do
    local n = math.min(left[s.name] or 0, s.count)
    if n > 0 then
      local ok, m = call(P.input, "pushItems", P.storage, s.slot, n)
      if ok and m then
        moved = moved + m
        left[s.name] = left[s.name] - m
      end
    end
  end
  log("info", "Returned " .. moved .. " extra items to storage")
end

local function engineTick()
  if needResolve or now() - resolvedAt > 10 then
    needResolve = false
    resolvedAt = now()
    resolve()
  end
  if #problems > 0 then
    activity = "Setup needed"
    needResolve = true
    return
  end
  recoverActive()
  reconcile()

  if pendingAction == "return_extras" then
    pendingAction = nil
    returnExtras()
    reconcile()
  end

  for _, name in ipairs(sortedRecipeNames()) do
    local r = recipes[name]
    if r.paused then
      setStatus(name, "Paused", colors.red)
    else
      runawayCheck(name, r)
      if not r.paused then orderIngredients(name, r) end
    end
  end

  -- Craft whatever has a full set of ingredients ready.
  for _, name in ipairs(sortedRecipeNames()) do
    local r = recipes[name]
    if not r.paused and not calibrating then
      local ready = setsIn(ledgerOf(name), recipeNeed(r))
      if ready > 0 then
        if uncalibratedCells(r) > 0 then
          pauseRecipe(name, "Crafters aren't calibrated for this pattern")
        else
          craftOnce(name, r)
          return
        end
      end
    end
  end
  activity = (#state.orders > 0) and "Waiting for ingredients" or "Idle"
end

local function engineLoop()
  while true do
    if not calibrating then
      local ok, err = pcall(engineTick)
      if not ok then
        log("error", "Engine: " .. tostring(err))
        sleep(2)
      end
    end
    sleep(0.5)
  end
end

-- ============================================================ network

local function openModems()
  for _, side in ipairs(rs.getSides()) do
    if peripheral.hasType(side, "modem") and not rednet.isOpen(side) then
      rednet.open(side)
    end
  end
end

local function statusMessage()
  local list = {}
  for _, name in ipairs(sortedRecipeNames()) do
    local r = recipes[name]
    local s = recipeStatus[name] or { text = "" }
    table.insert(list, {
      name = name, output = r.output, made = state.made[name] or 0,
      queued = openSets(name) + setsIn(ledgerOf(name), recipeNeed(r)),
      status = s.text, paused = r.paused or false, missing = recipeMissing[name],
    })
  end
  return {
    kind = "crafter", t = now(), activity = activity,
    active = state.active and state.active.recipe or nil,
    recipes = list, orders = #state.orders, problems = problems,
  }
end

local function netLoop()
  openModems()
  local lastSend = 0
  while true do
    local timer = os.startTimer(1)
    local ev = { os.pullEvent() }
    if ev[1] == "rednet_message" and ev[4] == "cfm-gauges" and type(ev[3]) == "table" then
      local msg = ev[3]
      factory.gauges = msg.gauges or {}
      factory.paused = msg.paused or false
      factory.at = now()
    elseif ev[1] == "package_received" and type(ev[2]) == "table" then
      local pkg = ev[2]
      local okA, address = pcall(pkg.getAddress)
      if okA and address and address:lower() == STATION_ADDRESS:lower() then
        local count = 0
        local okL, items = pcall(pkg.list)
        if okL and items then for _, it in pairs(items) do count = count + it.count end end
        local oid = ""
        local okO, hasOrder = pcall(pkg.hasOrderData)
        if okO and hasOrder then
          local okD, order = pcall(pkg.getOrderData)
          if okD and order then oid = " order " .. tostring(order.getOrderID()) end
        end
        log("info", "Package received:" .. oid .. ", " .. count .. " items")
      end
    elseif ev[1] == "peripheral" or ev[1] == "peripheral_detach" then
      openModems()
      needResolve = true
    end
    if now() - lastSend >= 2 then
      lastSend = now()
      pcall(rednet.broadcast, statusMessage(), "cfm-crafter")
    end
    if ev[1] ~= "timer" or ev[2] ~= timer then os.cancelTimer(timer) end
  end
end

-- ============================================================ terminal UI

local W, H = term.getSize()
local screen = "status"
local buttons = {}
local selected = nil      -- selected recipe on the recipes screen
local ed = nil            -- recipe editor state
local cal = nil           -- calibration state
local logScroll = 0
local prompt = nil        -- { label, onDone } text input on the bottom line

local ITEM_COLORS = {
  colors.red, colors.orange, colors.yellow, colors.lime, colors.green, colors.cyan,
  colors.lightBlue, colors.blue, colors.purple, colors.magenta, colors.pink, colors.brown,
}
local function itemColor(id)
  local h = 0
  for i = 1, #id do h = (h * 31 + id:byte(i)) % 1000003 end
  return ITEM_COLORS[h % #ITEM_COLORS + 1]
end
local function textOn(bg)
  if bg == colors.yellow or bg == colors.lime or bg == colors.white or bg == colors.lightBlue
    or bg == colors.pink or bg == colors.orange or bg == colors.cyan then
    return colors.black
  end
  return colors.white
end

local function put(x, y, text, fg, bg)
  term.setCursorPos(x, y)
  if bg then term.setBackgroundColor(bg) end
  term.setTextColor(fg or colors.white)
  term.write(text)
end

local function fill(x, y, w, h, bg)
  term.setBackgroundColor(bg)
  for i = 0, h - 1 do
    term.setCursorPos(x, y + i)
    term.write(string.rep(" ", w))
  end
end

local function button(x, y, label, bg, action, fg)
  label = " " .. label .. " "
  put(x, y, label, fg or textOn(bg), bg)
  table.insert(buttons, { x = x, y = y, w = #label, h = 1, action = action })
  return x + #label + 1
end

local function region(x, y, w, h, action)
  table.insert(buttons, { x = x, y = y, w = w, h = h, action = action })
end

local function abbrev(id)
  local p = pretty(id):gsub("%s", "")
  return p:sub(1, 4)
end

-- 5x5 grid drawn at (gx, gy), cells 5 wide and 3 tall.
local GX, GY, CW, CH = 18, 3, 5, 3
local function drawGrid(cellText, onCell)
  for r = 1, 5 do
    for c = 1, 5 do
      local x = GX + (c - 1) * CW
      local y = GY + (r - 1) * CH
      local id, label, bg = cellText(r, c)
      bg = bg or (((r + c) % 2 == 0) and colors.gray or colors.lightGray)
      fill(x, y, CW, CH, bg)
      if label then
        put(x + math.floor((CW - #label) / 2), y + 1, label, textOn(bg), bg)
      end
      if onCell then
        region(x, y, CW, CH, function(btn) onCell(r, c, btn) end)
      end
    end
  end
end

local function header()
  fill(1, 1, W, 1, colors.gray)
  put(2, 1, "MECH CRAFTER", colors.white, colors.gray)
  local x = 16
  for _, tab in ipairs({ { "status", "Status" }, { "recipes", "Recipes" }, { "setup", "Setup" }, { "log", "Log" } }) do
    local active = screen == tab[1]
    x = button(x, 1, tab[2], active and colors.lightBlue or colors.gray, function()
      screen = tab[1]
    end, active and colors.black or colors.lightGray)
  end
  local dot = (#problems > 0) and colors.red or colors.lime
  put(W - 1, 1, "\7", dot, colors.gray)
end

local function drawStatus()
  put(2, 3, "Activity: ", colors.lightGray, colors.black)
  put(12, 3, clip(activity, W - 12), colors.white, colors.black)
  local fresh = factoryFresh()
  put(2, 4, "Factory:  ", colors.lightGray, colors.black)
  if fresh then
    put(12, 4, #factory.gauges .. " gauges" .. (factory.paused and " (controller paused)" or ""), colors.lime, colors.black)
  else
    put(12, 4, "no data from the Factory Monitor", colors.orange, colors.black)
  end

  local y = 6
  if #problems > 0 then
    for _, p in ipairs(problems) do
      put(2, y, clip(p, W - 2), colors.red, colors.black)
      y = y + 1
    end
    put(2, y, "Fix the names at the top of the program.", colors.lightGray, colors.black)
    return
  end

  put(2, y, "Recipe", colors.lightGray, colors.black)
  put(20, y, "Stock", colors.lightGray, colors.black)
  put(31, y, "Queue", colors.lightGray, colors.black)
  put(37, y, "Made", colors.lightGray, colors.black)
  y = y + 1
  local names = sortedRecipeNames()
  if #names == 0 then
    put(2, y, "No recipes yet. Open the Recipes tab.", colors.lightGray, colors.black)
  end
  for _, name in ipairs(names) do
    if y > H - 2 then break end
    local r = recipes[name]
    local g = gaugeFor(r.output)
    local stock = "-"
    if g then stock = fmtNum(g.stock) .. "/" .. fmtNum(g.target * (unitMultiplier(g, r) or 1)) end
    local queued = openSets(name) + setsIn(ledgerOf(name), recipeNeed(r))
    put(2, y, clip(name, 17), colors.white, colors.black)
    put(20, y, clip(stock, 10), colors.white, colors.black)
    put(31, y, tostring(queued), colors.white, colors.black)
    put(37, y, fmtNum(state.made[name] or 0), colors.white, colors.black)
    local s = recipeStatus[name] or { text = "", color = colors.white }
    local text = r.paused and ("Paused: " .. (r.error or "")) or s.text
    y = y + 1
    put(4, y, clip(text, r.paused and (W - 14) or (W - 4)), r.paused and colors.red or s.color, colors.black)
    if r.paused then
      button(W - 9, y, "Resume", colors.green, function()
        r.paused, r.error = false, nil
        failStreak[name] = 0
        if state.guard[name] then state.guard[name].crafted = 0 end
        saveRecipes()
        log("info", "Resumed " .. name)
      end)
    end
    y = y + 1
  end

  local extraCount = sum(extras)
  if extraCount > 0 then
    if P.storage then
      put(2, H, clip(extraCount .. " unordered items in input chest", W - 18), colors.orange, colors.black)
      button(W - 15, H, "Return them", colors.orange, function() pendingAction = "return_extras" end)
    else
      put(2, H, clip(extraCount .. " unordered items in input chest (take them out)", W - 2), colors.orange, colors.black)
    end
  end
end

local function drawRecipes()
  local names = sortedRecipeNames()
  local y = 3
  if #names == 0 then
    put(2, y, "No recipes yet. Add one below.", colors.lightGray, colors.black)
  end
  for _, name in ipairs(names) do
    if y > H - 3 then break end
    local r = recipes[name]
    local isSel = selected == name
    local bg = isSel and colors.blue or colors.black
    fill(1, y, W, 1, bg)
    put(2, y, clip(name, 16), colors.white, bg)
    put(19, y, clip(pretty(r.output) .. " x" .. r.makes, 20), colors.lightGray, bg)
    local manual = state.manual[name] or 0
    if manual > 0 then put(40, y, "+" .. manual .. " queued", colors.yellow, bg) end
    region(1, y, W, 1, function() selected = name end)
    y = y + 1
  end

  local x = 2
  x = button(x, H - 1, "New", colors.green, function()
    ed = { r = { name = "", output = nil, makes = 1, cells = {} }, original = nil, sel = nil, scroll = 0 }
    screen = "editor"
  end)
  if selected and recipes[selected] then
    x = button(x, H - 1, "Edit", colors.blue, function()
      local r = recipes[selected]
      local copy = { name = r.name, output = r.output, makes = r.makes, stack = r.stack, cells = {} }
      for k, v in pairs(r.cells) do copy.cells[k] = v end
      ed = { r = copy, original = r.name, sel = nil, scroll = 0 }
      screen = "editor"
    end)
    x = button(x, H - 1, "Delete", colors.red, function()
      recipes[selected] = nil
      state.ledger[selected] = nil
      state.manual[selected] = nil
      saveRecipes()
      saveState()
      log("info", "Deleted recipe " .. selected)
      selected = nil
    end)
    x = button(x, H - 1, "Craft +1", colors.cyan, function()
      state.manual[selected] = (state.manual[selected] or 0) + 1
      saveState()
    end)
    x = button(x, H - 1, "+8", colors.cyan, function()
      state.manual[selected] = (state.manual[selected] or 0) + 8
      saveState()
    end)
    if (state.manual[selected] or 0) > 0 then
      button(x, H - 1, "Clear queue", colors.gray, function()
        state.manual[selected] = 0
        saveState()
      end)
    end
  end
end

local paletteCache, paletteAt = {}, 0
local function palette()
  if now() - paletteAt > 1 then
    paletteAt = now()
    local totals = contents(P.input) or {}
    local list = {}
    for id, n in pairs(totals) do table.insert(list, { id = id, count = n }) end
    table.sort(list, function(a, b) return pretty(a.id) < pretty(b.id) end)
    paletteCache = list
  end
  return paletteCache
end

local function drawEditor()
  fill(1, 1, W, 1, colors.gray)
  put(2, 1, ed.original and ("Edit " .. clip(ed.original, 20)) or "New recipe", colors.white, colors.gray)

  -- Palette: items in the input chest
  put(1, 2, "Input chest:", colors.lightGray, colors.black)
  local list = palette()
  local rows = H - 4
  local maxScroll = math.max(0, #list - rows)
  ed.scroll = math.max(0, math.min(ed.scroll, maxScroll))
  for i = 1, rows do
    local item = list[i + ed.scroll]
    local y = 2 + i
    if item then
      local isSel = ed.sel == item.id
      local bg = isSel and colors.white or colors.black
      fill(1, y, 16, 1, bg)
      put(1, y, " ", colors.white, itemColor(item.id))
      put(3, y, clip(pretty(item.id), 14), isSel and colors.black or colors.white, bg)
      region(1, y, 16, 1, function() ed.sel = (ed.sel ~= item.id) and item.id or nil end)
    end
  end
  if #list == 0 then put(1, 4, "(empty: put the", colors.lightGray, colors.black) put(1, 5, " ingredients in)", colors.lightGray, colors.black) end
  if maxScroll > 0 then
    button(1, H - 1, "\30", colors.gray, function() ed.scroll = ed.scroll - 3 end)
    button(6, H - 1, "\31", colors.gray, function() ed.scroll = ed.scroll + 3 end)
  end

  drawGrid(function(r, c)
    local id = ed.r.cells[r .. "," .. c]
    if id then return id, abbrev(id), itemColor(id) end
  end, function(r, c, btn)
    local key = r .. "," .. c
    if btn == 2 or (ed.r.cells[key] and ed.r.cells[key] == ed.sel) or not ed.sel then
      ed.r.cells[key] = nil
    else
      ed.r.cells[key] = ed.sel
    end
  end)

  -- Side panel
  local x = 44
  put(x, 3, "Name", colors.lightGray, colors.black)
  put(x, 4, clip(ed.r.name ~= "" and ed.r.name or "-", 8), colors.white, colors.black)
  region(x, 3, 8, 2, function()
    prompt = { label = "Recipe name: ", onDone = function(text) if text ~= "" then ed.r.name = text end end }
  end)
  put(x, 6, "Output", colors.lightGray, colors.black)
  put(x, 7, clip(ed.r.output and pretty(ed.r.output) or "-", 8), colors.white, colors.black)
  region(x, 6, 8, 2, function()
    if ed.sel then
      ed.r.output = ed.sel
    else
      prompt = { label = "Output item id: ", onDone = function(text) if text:find(":") then ed.r.output = text end end }
    end
  end)
  put(x, 9, "Makes", colors.lightGray, colors.black)
  button(x - 1, 10, "-", colors.gray, function() ed.r.makes = math.max(1, ed.r.makes - 1) end)
  put(x + 3, 10, tostring(ed.r.makes), colors.white, colors.black)
  button(x + 5, 10, "+", colors.gray, function() ed.r.makes = ed.r.makes + 1 end)
  button(x - 1, 12, "Clear", colors.gray, function() ed.r.cells = {} end)
  button(x - 1, 14, "Save ", colors.green, function()
    local r = ed.r
    if r.name == "" then ed.msg = "Give it a name (click Name)" return end
    if not r.output then ed.msg = "Pick an item, then click Output" return end
    if next(r.cells) == nil then ed.msg = "Place at least one item" return end
    if recipes[r.name] and r.name ~= ed.original then ed.msg = "That name is taken" return end
    if ed.original and ed.original ~= r.name then
      recipes[ed.original] = nil
      state.ledger[r.name], state.ledger[ed.original] = state.ledger[ed.original], nil
      state.made[r.name], state.made[ed.original] = state.made[ed.original], nil
      state.manual[r.name], state.manual[ed.original] = state.manual[ed.original], nil
    end
    r.paused, r.error = false, nil
    recipes[r.name] = r
    saveRecipes()
    saveState()
    log("info", "Saved recipe " .. r.name)
    selected = r.name
    screen = "recipes"
    ed = nil
  end)
  button(x - 1, 16, "Back ", colors.red, function() screen = "recipes" ed = nil end)

  if ed and ed.msg then put(18, H, clip(ed.msg, W - 18), colors.orange, colors.black) end
  if ed and not ed.msg then
    put(18, H, clip(ed.sel and ("Placing: " .. pretty(ed.sel) .. " (click again to drop)") or "Pick an item on the left, then click cells", W - 18), colors.lightGray, colors.black)
  end
end

local function drawSetup()
  local y = 3
  local rows = {
    { "Input chest", P.input }, { "Storage (optional)", P.storage },
    { "Crafters", P.crafter }, { "Stock Ticker", P.ticker }, { "Packager (log)", P.packager },
  }
  for _, row in ipairs(rows) do
    local ok = row[2] and peripheral.isPresent(row[2])
    put(2, y, ok and "\4" or "x", ok and colors.lime or colors.red, colors.black)
    put(4, y, row[1], colors.lightGray, colors.black)
    put(20, y, clip(row[2] or "not found", W - 20), ok and colors.white or colors.red, colors.black)
    y = y + 1
  end
  local mapped = 0
  for _ in pairs(calibration) do mapped = mapped + 1 end
  put(2, y + 1, "Crafter slots: " .. (P.size or 0) .. ", calibrated: " .. mapped, colors.white, colors.black)
  put(2, y + 2, "Address: " .. STATION_ADDRESS .. "   Pulse side: " .. PULSE_SIDE, colors.lightGray, colors.black)
  local x = 2
  x = button(x, H - 1, "Calibrate", colors.blue, function()
    cal = { slot = 1, size = P.size or 0, step = "start" }
    screen = "calibrate"
  end)
  x = button(x, H - 1, "Use reading order", colors.gray, function()
    calibration = {}
    for i = 1, math.min(P.size or 0, 25) do
      calibration[i] = { r = math.floor((i - 1) / 5) + 1, c = (i - 1) % 5 + 1 }
    end
    saveCalibration()
    rebuildSlotMap()
    log("info", "Calibration set to reading order")
  end)
  button(x, H - 1, "Test pulse", colors.gray, function() pulse() end)
end

local function drawCalibrate()
  fill(1, 1, W, 1, colors.gray)
  put(2, 1, "Calibrate crafters", colors.white, colors.gray)
  put(1, 3, "Put any item in", colors.lightGray, colors.black)
  put(1, 4, "the input chest.", colors.lightGray, colors.black)
  put(1, 6, "Slot " .. math.min(cal.slot, cal.size) .. " of " .. cal.size, colors.white, colors.black)
  local msg = cal.msg or ""
  local y = 8
  for line in (msg .. "\n"):gmatch("(.-)\n") do
    put(1, y, clip(line, 16), colors.yellow, colors.black)
    y = y + 1
  end
  drawGrid(function(r, c)
    for slot, pos in pairs(cal.map) do
      if pos.r == r and pos.c == c then return nil, tostring(slot), colors.green end
    end
  end, function(r, c)
    if cal.waiting then
      cal.map[cal.slot] = { r = r, c = c }
      cal.waiting = false
    end
  end)
  button(44, 14, "Skip ", colors.gray, function() if cal.waiting then cal.waiting = false cal.skip = true end end)
  button(44, 16, "Stop ", colors.red, function() cal.cancel = true cal.waiting = false end)
end

local function drawLog()
  local rows = H - 2
  local first = math.max(1, #logLines - rows + 1 - logScroll)
  local y = 3
  for i = first, math.min(#logLines, first + rows - 1) do
    local e = logLines[i]
    local color = (e.level == "error" and colors.red) or (e.level == "warn" and colors.orange) or colors.white
    put(1, y, e.t, colors.gray, colors.black)
    put(10, y, clip(e.msg, W - 10), color, colors.black)
    y = y + 1
  end
end

local function draw()
  buttons = {}
  term.setBackgroundColor(colors.black)
  term.clear()
  if screen == "editor" and ed then
    drawEditor()
  elseif screen == "calibrate" and cal then
    drawCalibrate()
  else
    header()
    if screen == "status" then drawStatus()
    elseif screen == "recipes" then drawRecipes()
    elseif screen == "setup" then drawSetup()
    elseif screen == "log" then drawLog() end
  end
  if prompt then
    fill(1, H, W, 1, colors.blue)
    put(1, H, prompt.label, colors.white, colors.blue)
  end
end

local function click(x, y, btn)
  for i = #buttons, 1, -1 do
    local b = buttons[i]
    if x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h then
      b.action(btn)
      return
    end
  end
end

-- Calibration runs inside the UI so it can wait for clicks.
local function runCalibration()
  calibrating = true
  cal.map = {}
  local function waitClick()
    cal.waiting = true
    while cal.waiting do
      draw()
      local ev, btn, x, y = os.pullEvent()
      if ev == "mouse_click" then click(x, y, btn) end
    end
  end

  -- Let any running craft finish first.
  local waitStart = now()
  while state.active and now() - waitStart < 60 do
    cal.msg = "Waiting for the\ncurrent craft..."
    draw()
    sleep(0.5)
  end
  if not clearCrafters() then
    cal.msg = "Couldn't empty\nthe crafters."
    draw()
    sleep(3)
  end

  for slot = 1, cal.size do
    if cal.cancel then break end
    cal.slot = slot
    local _, slots = contents(P.input)
    local marker = slots and slots[1]
    if not marker then
      cal.msg = "Input chest is\nempty. Add an\nitem, then retry."
      draw()
      sleep(3)
      break
    end
    local ok, n = call(P.input, "pushItems", P.crafter, marker.slot, 1, slot)
    if ok and n == 1 then
      cal.msg = "Click the cell\nwhere this item\nappeared:\n" .. clip(pretty(marker.name), 16)
      waitClick()
      call(P.crafter, "pushItems", P.input, slot)
    else
      cal.msg = "Slot " .. slot .. " refused\nthe item, skipped."
      draw()
      sleep(1)
    end
  end

  if not cal.cancel and next(cal.map) then
    calibration = cal.map
    saveCalibration()
    rebuildSlotMap()
    local n = 0
    for _ in pairs(cal.map) do n = n + 1 end
    log("info", "Calibrated " .. n .. " crafter slots")
  end
  clearCrafters()
  calibrating = false
  cal = nil
  screen = "setup"
end

local function uiLoop()
  local redraw = os.startTimer(1)
  while true do
    if screen == "calibrate" and cal and cal.step == "start" then
      cal.step = "running"
      local ok, err = pcall(runCalibration)
      if not ok then
        calibrating = false
        cal = nil
        screen = "setup"
        log("error", "Calibration: " .. tostring(err))
      end
    end
    draw()
    if prompt then
      term.setCursorPos(#prompt.label + 1, H)
      term.setTextColor(colors.white)
      term.setBackgroundColor(colors.blue)
      local text = read()
      local p = prompt
      prompt = nil
      p.onDone(text or "")
    else
      local ev, a, b, c = os.pullEvent()
      if ev == "mouse_click" then
        if ed then ed.msg = nil end
        click(b, c, a)
      elseif ev == "mouse_scroll" then
        if screen == "editor" and ed then ed.scroll = ed.scroll + a end
        if screen == "log" then logScroll = math.max(0, logScroll - a) end
      elseif ev == "timer" and a == redraw then
        redraw = os.startTimer(1)
      elseif ev == "term_resize" then
        W, H = term.getSize()
      end
    end
  end
end

-- ============================================================ start

if not fs.exists(DIR) then fs.makeDir(DIR) end
resolve()
log("info", "Mech Crafter " .. VERSION .. " started")
local function readyToUpdate()
  -- never in the middle of a craft or calibration
  return state.active == nil and not calibrating
end

-- ============================================================ auto-update

-- Every UPDATE_CHECK_MINUTES this checks GitHub for a newer version. A new
-- version is downloaded, checked that it loads, given your current settings
-- (the UPPERCASE lines at the top of this file), saved, and the computer
-- reboots into it. Set AUTO_UPDATE = false at the top to turn this off.
local UPDATE_REPO = "levisnakes/cc-mech-crafter"
local UPDATE_FILE = "mech_crafter.lua"
local UPDATE_CHECK_MINUTES = 15
local PROGRAM_PATH = (shell and shell.getRunningProgram()) or "startup.lua"
local SHA_FILE = "/.version_" .. UPDATE_FILE

-- Settings are the top-of-file assignments to UPPERCASE names, before the
-- first "local" line or "-- ====" section. Tables can span several lines.
local function splitSettings(src)
  local settings, rest = {}, {}
  local inSettings = true
  for line in (src .. "\n"):gmatch("(.-)\n") do
    if inSettings and (line:match("^local ") or line:match("^%-%- ====")) then inSettings = false end
    table.insert(inSettings and settings or rest, line)
  end
  return settings, rest
end

local function braceDelta(line)
  local code = line:gsub('"[^"]*"', ""):gsub("%-%-.*$", "")
  local _, opens = code:gsub("{", "")
  local _, closes = code:gsub("}", "")
  return opens - closes
end

-- [NAME] = the full statement text, possibly several lines
local function statements(lines)
  local out = {}
  local i = 1
  while i <= #lines do
    local name = lines[i]:match("^([%u_][%u%d_]*)%s*=")
    if name then
      local block = { lines[i] }
      local depth = braceDelta(lines[i])
      while depth > 0 and i < #lines do
        i = i + 1
        table.insert(block, lines[i])
        depth = depth + braceDelta(lines[i])
      end
      out[name] = table.concat(block, "\n")
    end
    i = i + 1
  end
  return out
end

-- New file, with each setting that already exists replaced by your value.
local function mergeSettings(oldSrc, newSrc)
  local oldSettings = statements((splitSettings(oldSrc)))
  local newSettings, rest = splitSettings(newSrc)
  local out = {}
  local i = 1
  while i <= #newSettings do
    local line = newSettings[i]
    local name = line:match("^([%u_][%u%d_]*)%s*=")
    if name and oldSettings[name] then
      table.insert(out, oldSettings[name])
      local depth = braceDelta(line)
      while depth > 0 and i < #newSettings do
        i = i + 1
        depth = depth + braceDelta(newSettings[i])
      end
    else
      table.insert(out, line)
    end
    i = i + 1
  end
  for _, line in ipairs(rest) do table.insert(out, line) end
  local merged = table.concat(out, "\n")
  -- splitting added one trailing newline's worth of empty line; match the source
  if newSrc:sub(-1) == "\n" and merged:sub(-1) ~= "\n" then merged = merged .. "\n" end
  return (merged:gsub("\n\n$", "\n"))
end

local function fetch(url, headers)
  local ok, h = pcall(http.get, url, headers)
  if not ok or not h then return nil end
  local body = h.readAll()
  h.close()
  return body
end

local function readText(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  local t = f.readAll()
  f.close()
  return t
end

local function writeText(path, text)
  local f = fs.open(path, "w")
  f.write(text)
  f.close()
end

local function checkForUpdate(atBoot)
  if AUTO_UPDATE == false or not http then return end
  local sha = fetch("https://api.github.com/repos/" .. UPDATE_REPO .. "/commits/main",
    { ["Accept"] = "application/vnd.github.sha", ["User-Agent"] = "cc-auto-update" })
  if not sha then return end
  sha = sha:match("^%s*(%x+)%s*$")
  if not sha or #sha < 40 or readText(SHA_FILE) == sha then return end

  local newSrc = fetch("https://raw.githubusercontent.com/" .. UPDATE_REPO .. "/" .. sha .. "/" .. UPDATE_FILE)
  if not newSrc or not _G.load(newSrc, UPDATE_FILE) then return end
  local oldSrc = readText(PROGRAM_PATH)
  if not oldSrc then return end
  local merged = mergeSettings(oldSrc, newSrc)
  if not _G.load(merged, UPDATE_FILE) then return end
  if merged == oldSrc then
    writeText(SHA_FILE, sha)
    return
  end

  -- at boot nothing is running yet, so there is nothing to wait for
  while not atBoot and not readyToUpdate() do sleep(5) end
  writeText(PROGRAM_PATH .. ".old", oldSrc)
  writeText(PROGRAM_PATH, merged)
  writeText(SHA_FILE, sha)
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  print("Updated to " .. sha:sub(1, 7) .. ", restarting...")
  if not atBoot then sleep(1) end
  os.reboot()
end

local function updateLoop()
  while true do
    sleep(UPDATE_CHECK_MINUTES * 60)
    pcall(checkForUpdate)
  end
end

-- Check for a new version as soon as the computer starts, before the
-- program runs, so a restart always picks up the latest version.
local function bootUpdate()
  if AUTO_UPDATE == false or not http then return end
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  print("Checking for updates...")
  pcall(checkForUpdate, true)
end

bootUpdate()
parallel.waitForAny(engineLoop, netLoop, uiLoop, updateLoop)
