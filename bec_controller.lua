-- BEC Controller
-- Author: Armisael/nex5
-- Version: 1
-- Automates the Bose-Einstein Condensate network: identifies the recipe in the
-- Input Subnet, splits it across the IONodes, supplies nanite tiers as they
-- change and resets for the next batch.
-- Ctrl+Alt+C to exit.

local component = require("component")
local computer = require("computer")
local event = require("event")
local filesystem = require("filesystem")
local serialization = require("serialization")

local VERSION = "1"
local SCRIPT_PATH = "/home/bec_controller.lua"
local SHRC_PATH = "/home/.shrc"
local CONFIG_PATH = "/home/config.cfg"
local LOG_PATH = "/home/log.log"
local LOG_PATH_OLD = "/home/log.old"
local DATA_CACHE_PATH = "/home/data.cache"
local UPDATE_VERSION_URL = "https://raw.githubusercontent.com/Armisael5/gtnh-bec-controller/main/VERSION"
local UPDATE_SCRIPT_URL = "https://raw.githubusercontent.com/Armisael5/gtnh-bec-controller/main/bec_controller.lua"
local IONODE_ICON_URL = "https://raw.githubusercontent.com/Armisael5/gtnh-bec-controller/refs/heads/main/images/IONode_icon.png"

local MAX_LOG_SIZE = 512 * 1024
local MAX_RECENT_LINES = 30
local NANITE_TIER_COUNT = 10
local IO_NODES_PER_ARRAY = 16
local NANITE_CRAFT_TIMEOUT = 10
local NANITE_CRAFT_POLL_INTERVAL = 0.05
local DRIVE_MOVE_TIMEOUT = 1
local DRIVE_MOVE_RETRY_INTERVAL = 0.05
local REDSTONE_PULSE_DURATION = 0.2
local NANITE_POLL_INTERVAL = 0.3
local GATE_POLL_INTERVAL = 0.5
local INPUT_SETTLE_TIME = 0.5
local NODE_STARTUP_TIMEOUT = 30
local NODE_STARTUP_POLL_INTERVAL = 0.3
local TIER_SWAP_FAILURE_TIMEOUT = 30
local IO_PORT_SLOT = 7
local EXTRACTION_MARKER_SLOT = 12
local DIODE_WATER_SLOT = 19
local DIODE_WATER_FLUID = "water"
local DIODE_RECIPE_FILTER_SLOTS = { 1, 2, 3, 4 }

local TIER_DISPLAY_NAMES = {
  Carbon = "Carbon Nanite",
  Silver = "Silver Nanite",
  Gold = "Gold Nanite",
  Transcendent = "Transcendent Nanite",
  SixPhasedCopper = "Six-Phased Copper Nanite",
  WhiteDwarf = "White Dwarf Nanite",
  BlackDwarf = "Black Dwarf Nanite",
  Universium = "Universium Nanite",
  Eternity = "Eternity Nanite",
  MagMatter = "Magmatter Nanite",
}

local ENTANGLED_FLUID_NAMES = {
  ["molten.bedrockium"] = "entangled_bedrockium",
  ["molten.celestialtungsten"] = "entangled_celestialtungsten",
  ["molten.chromaticglass"] = "entangled_chromaticglass",
  ["molten.cosmicneutronium"] = "entangled_cosmicneutronium",
  ["molten.eternity"] = "entangled_eternity",
  ["molten.hypogen"] = "entangled_hypogen",
  ["molten.infinity"] = "entangled_infinity",
  ["molten.magmatter"] = "entangled_magmatter",
  ["molten.magnetohydrodynamicallyconstrainedstarmatter"] = "entangled_mhdcsm",
  ["molten.neutronium"] = "entangled_neutronium",
  ["molten.spacetime"] = "entangled_spacetime",
  ["molten.transcendentmetal"] = "entangled_transcendentmetal",
  ["molten.universium"] = "entangled_universium",
  ["phononmedium"] = "entangled_phononmedium",
  ["quarkgluonplasma"] = "entangled_quarkgluonplasma",
  ["spatialfluid"] = "entangled_space",
  ["dimensionallyshiftedsuperfluid"] = "entangled_dimshiftedsuperfluid",
  ["temporalfluid"] = "entangled_time",
  ["boundlesscosmicsolder"] = "entangled_cosmicsolder",
}

local CONFIG_DEFAULTS = {
  { "enableAutoUpdate", true },
  { "enableAutoStart", true },
  { "discordWebhookURL", "" },
  { "errorPingUserID", "" },
  { "onlySendErrors", false },
}

local config = {}
for _, entry in ipairs(CONFIG_DEFAULTS) do config[entry[1]] = entry[2] end

local status = { phase = "Starting up" }

local function firstComponent(componentType)
  for address in component.list(componentType, true) do
    return address, component.proxy(address)
  end
end

local function addresses(componentType)
  local list = {}
  for address in component.list(componentType, true) do table.insert(list, address) end
  return list
end

-- check() returns true when done, false plus a reason to give up, or nil to keep waiting.
-- Returns true, or false plus that reason (nil on timeout).
local function poll(timeout, interval, check)
  local deadline = computer.uptime() + timeout
  while true do
    local done, err = check()
    if done then return true end
    if err then return false, err end
    if computer.uptime() >= deadline then return false end
    os.sleep(interval)
  end
end

local function stripFormatting(text)
  return (text:gsub("\194\167.", ""):gsub("\167.", ""))
end

-- Logging and screen

local LEVEL = { DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4 }
local LEVEL_NAMES = { "DEBUG", "INFO", "WARN", "ERROR" }

local logFile = io.open(LOG_PATH, "a")
if not logFile then
  print("FATAL: could not open " .. LOG_PATH)
  os.exit(1)
end
local logFileBytes = filesystem.size(LOG_PATH) or 0
local recentLines = {}
local timeOffset -- real epoch minus computer.uptime(), once syncRealTime() succeeds

local gpu
do
  local gpuAddress, gpuProxy = firstComponent("gpu")
  local screenAddress, screen = firstComponent("screen")
  if gpuAddress then
    gpu = gpuProxy
    if screenAddress then
      pcall(gpu.bind, screenAddress)
      pcall(screen.turnOn)
    end
  end
end

local function clearScreen()
  local ok, w, h = pcall(gpu.getResolution)
  if not ok then return end
  pcall(gpu.setBackground, 0x000000)
  pcall(gpu.setForeground, 0xFFFFFF)
  pcall(gpu.fill, 1, 1, w, h, " ")
  return w, h
end

local function render()
  if not gpu then return end
  local w, h = clearScreen()
  if not w then return end
  pcall(gpu.setForeground, 0x66CCFF)
  pcall(gpu.set, 2, 1, "BEC Controller")
  pcall(gpu.setForeground, 0xFFFFFF)

  local recipeText = status.recipeName and (status.recipeName .. "  x" .. tostring(status.recipeOutputCount)) or "-"
  pcall(gpu.set, 2, 3, "Status:         " .. status.phase)
  pcall(gpu.set, 2, 4, "Recipe:         " .. recipeText)
  pcall(gpu.set, 2, 5, "Requested Tier: " .. (status.currentTier or "-"))
  pcall(gpu.set, 2, 6, "Progress:       " .. (status.progressPercent and (status.progressPercent .. "%") or "-"))
  pcall(gpu.set, 2, 7, string.rep("_", math.max(0, w - 2)))

  local startRow = 8
  local first = math.max(1, #recentLines - math.max(0, h - startRow + 1) + 1)
  for i = first, #recentLines do
    pcall(gpu.set, 2, startRow + i - first, recentLines[i]:sub(1, math.max(0, w - 2)))
  end
end

local function setPhase(phase)
  status.phase = phase
  render()
end

local function formatUptime(uptime)
  local total = math.floor(uptime)
  local days = math.floor(total / 86400)
  local clock = string.format("%02d:%02d:%02d", math.floor(total % 86400 / 3600), math.floor(total % 3600 / 60), total % 60)
  return days > 0 and (days .. "d " .. clock) or clock
end

local function timestamp()
  local t = computer.uptime() + (timeOffset or 0)
  local millis = string.format(".%03d", math.floor(t % 1 * 1000))
  return (timeOffset and os.date("%Y-%m-%d %H:%M:%S", math.floor(t)) or formatUptime(t)) .. millis
end

local function rotateLogIfNeeded()
  if logFileBytes < MAX_LOG_SIZE then return end
  pcall(logFile.close, logFile)
  pcall(filesystem.remove, LOG_PATH_OLD)
  pcall(filesystem.rename, LOG_PATH, LOG_PATH_OLD)
  logFile = assert(io.open(LOG_PATH, "a"))
  logFileBytes = 0
end

local function log(level, message)
  message = tostring(message)
  local line = "[" .. timestamp() .. "] [" .. LEVEL_NAMES[level] .. "] " .. message .. "\n"
  if pcall(logFile.write, logFile, line) then
    pcall(logFile.flush, logFile)
    logFileBytes = logFileBytes + #line
    rotateLogIfNeeded()
  end
  if level >= LEVEL.INFO then
    table.insert(recentLines, level == LEVEL.INFO and message or ("[" .. LEVEL_NAMES[level] .. "] " .. message))
    while #recentLines > MAX_RECENT_LINES do table.remove(recentLines, 1) end
    render()
  end
end

local function logSeparator()
  log(LEVEL.INFO, string.rep("_", 28))
  log(LEVEL.INFO, "")
end

-- filesystem.lastModified() reports the host system's real time.
local function syncRealTime()
  local tmpPath = "/tmp/bec_controller_time.tmp"
  local file = io.open(tmpPath, "w")
  if file then file:close() end
  local ok, millis = pcall(filesystem.lastModified, tmpPath)
  pcall(filesystem.remove, tmpPath)
  if not file or not ok or not millis then
    log(LEVEL.WARN, "couldn't sync real time - log timestamps will use uptime.")
    return
  end
  local epoch = math.floor(millis / 1000)
  timeOffset = epoch - computer.uptime()
  log(LEVEL.DEBUG, "Time synced: " .. os.date("%Y-%m-%d %H:%M:%S", epoch))
end

-- Networking and Discord

local function httpRequest(url, postData, headers)
  local address, internet = firstComponent("internet")
  if not address then return nil, "no Internet Card found" end
  local requestOk, handle = pcall(internet.request, url, postData, headers)
  if not requestOk or not handle then return nil, "request failed: " .. tostring(handle) end

  local chunks, attempts = {}, 0
  while true do
    local ok, chunk = pcall(handle.read)
    if ok and not chunk then
      pcall(handle.close)
      return table.concat(chunks)
    elseif ok then
      table.insert(chunks, chunk)
    else
      attempts = attempts + 1
      if attempts > 50 then
        pcall(handle.close)
        return nil, "timed out: " .. tostring(chunk)
      end
      os.sleep(0.1)
    end
  end
end

local function jsonEscape(text)
  local escapes = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
  return (text:gsub('[%c"\\]', function(c) return escapes[c] or string.format("\\u%04x", c:byte()) end))
end

local function sendDiscordMessage(content)
  if config.discordWebhookURL == "" then return end
  local body = '{"content":"' .. jsonEscape(content) .. '","username":"BEC Controller","avatar_url":"' .. IONODE_ICON_URL .. '"}'
  local ok, err = httpRequest(config.discordWebhookURL, body, { ["Content-Type"] = "application/json" })
  if not ok then log(LEVEL.WARN, "Discord webhook failed: " .. tostring(err)) end
end

local function fatalError(message)
  log(LEVEL.ERROR, message)
  -- Cached data may be what caused the failure, so make the next start rescan.
  pcall(filesystem.remove, DATA_CACHE_PATH)
  setPhase("FATAL: " .. message)
  sendDiscordMessage(config.errorPingUserID ~= "" and (message .. " <@" .. config.errorPingUserID .. ">") or message)
  while true do os.sleep(5) end
end

local function isInterrupted(err)
  return tostring(err):find("interrupted", 1, true) ~= nil
end

local function performShutdown()
  log(LEVEL.WARN, "Interrupted - exiting.")
  pcall(logFile.close, logFile)
  if gpu then clearScreen() end
  os.exit(0)
end

-- Persistent cache: one serialized table in DATA_CACHE_PATH, one key per section.

local dataCache

local function getCachedSection(key)
  if not dataCache then
    dataCache = {}
    local file = io.open(DATA_CACHE_PATH, "r")
    if file then
      local ok, value = pcall(serialization.unserialize, file:read("*a"))
      file:close()
      if ok and type(value) == "table" then
        dataCache = value
      else
        log(LEVEL.WARN, DATA_CACHE_PATH .. " is unreadable - rescanning.")
      end
    end
  end
  return dataCache[key]
end

local function saveCachedSection(key, value)
  getCachedSection(key)
  dataCache[key] = value
  local ok, err = pcall(function()
    local file = assert(io.open(DATA_CACHE_PATH, "w"))
    file:write(serialization.serialize(dataCache))
    file:close()
  end)
  if not ok then log(LEVEL.WARN, "couldn't write " .. DATA_CACHE_PATH .. ": " .. tostring(err)) end
end

-- Nanite extraction transposer, between two IO Ports: { address, markerSide, otherSide },
-- where markerSide's port holds the slot-12 dummy and otherSide's port is where the cell rests.

local function scanExtractionTransposer()
  for address in component.list("transposer", true) do
    local transposer = component.proxy(address)
    local activeSides, markerSide = {}, nil
    for side = 0, 5 do
      local ok, size = pcall(transposer.getInventorySize, side)
      if ok and size and size > 0 then
        table.insert(activeSides, side)
        local markerOk, marker = pcall(transposer.getStackInSlot, side, EXTRACTION_MARKER_SLOT)
        if markerOk and marker then markerSide = side end
      end
    end
    if markerSide then
      local otherSide
      for _, side in ipairs(activeSides) do
        if side ~= markerSide then otherSide = side end
      end
      return { address = address, markerSide = markerSide, otherSide = otherSide }
    end
  end
end

local extraction
local extractionFromFile = false

local function getExtraction(forceRescan)
  if not forceRescan and not extraction then
    local cached = getCachedSection("extraction")
    if type(cached) == "table" and cached.address and component.list("transposer", true)[cached.address] then
      extraction, extractionFromFile = cached, true
      log(LEVEL.DEBUG, "Loaded extraction transposer from " .. DATA_CACHE_PATH .. ".")
    end
  end
  if forceRescan or not extraction then
    log(LEVEL.DEBUG, "Scanning transposers...")
    extraction, extractionFromFile = scanExtractionTransposer(), false
    if extraction then saveCachedSection("extraction", extraction) end
  end
  return extraction
end

-- Only this script moves the cell, so its side is never read back.
local function moveCell(fromSide, toSide)
  local transposer = component.proxy(extraction.address)
  local ok, err = poll(DRIVE_MOVE_TIMEOUT, DRIVE_MOVE_RETRY_INTERVAL, function()
    local transferOk, moved = pcall(transposer.transferItem, fromSide, toSide, 1, IO_PORT_SLOT, 1)
    if not transferOk then return false, tostring(moved) end
    return moved == 1
  end)
  if ok then return true end
  return false, err or ("no cell in slot " .. IO_PORT_SLOT .. " on side " .. fromSide)
end

local function extractNanites()
  local ok, err = moveCell(extraction.otherSide, extraction.markerSide)
  if not ok then return false, "move to extraction port: " .. err end
  ok, err = moveCell(extraction.markerSide, extraction.otherSide)
  if not ok then return false, "move back to resting port: " .. err end
  return true
end

-- Returns an error, or nil plus the side the cell is on.
local function findExtractionCell()
  if not getExtraction() then
    return "could not find the nanite extraction transposer (slot " .. EXTRACTION_MARKER_SLOT .. " dummy)"
  end
  local transposer = component.proxy(extraction.address)
  for _, side in ipairs({ extraction.otherSide, extraction.markerSide }) do
    local ok, stack = pcall(transposer.getStackInSlot, side, IO_PORT_SLOT)
    if ok and stack then return nil, side end
  end
  return "no extraction cell found"
end

local function verifyExtractionCell()
  local err, side = findExtractionCell()
  if err and extractionFromFile then
    log(LEVEL.DEBUG, "Cached extraction transposer failed the cell check (" .. err .. ") - rescanning.")
    getExtraction(true)
    err, side = findExtractionCell()
  end
  if err then fatalError(err .. " at startup") end
  -- A run interrupted mid-extraction leaves the cell in the dummy's port.
  if side ~= extraction.otherSide then
    local ok, moveErr = moveCell(side, extraction.otherSide)
    if not ok then fatalError("returning extraction cell at startup: " .. moveErr) end
    log(LEVEL.DEBUG, "Returned extraction cell to its resting port.")
  end
end

-- The Input Subnet's interface is the build's only me_interface.
-- Returns its items, or nil plus a reason.
local function inputItems()
  local address, proxy = firstComponent("me_interface")
  if not address then return nil, "could not find the Input Subnet's ME interface" end
  local ok, items = pcall(proxy.getItemsInNetwork)
  if not ok or not items then return nil, "could not read Input Subnet items" end
  return items
end

-- Recipe identification

local function isFluidEntry(entry)
  return entry.amount ~= nil and entry.damage == nil
end

local function itemKey(entry)
  return entry.name .. ":" .. tostring(entry.damage)
end

local function compactPatternEntries(entries)
  local compact = {}
  for key, entry in pairs(entries or {}) do
    compact[key] = { name = entry.name, damage = entry.damage, size = entry.size, amount = entry.amount, label = entry.label }
  end
  return compact
end

local function scanRecipePatterns()
  local patterns = {}
  for address in component.list("fluid_interface", true) do
    local proxy = component.proxy(address)
    for slot = 1, 36 do
      local ok, pattern = pcall(proxy.getInterfacePattern, slot)
      if ok and pattern and pattern.inputs then
        table.insert(patterns, { inputs = compactPatternEntries(pattern.inputs), outputs = compactPatternEntries(pattern.outputs) })
      end
    end
  end
  return patterns
end

local recipePatterns

local function getRecipePatterns(forceRescan)
  if not forceRescan and not recipePatterns then
    local cached = getCachedSection("patterns")
    if type(cached) == "table" then
      recipePatterns = cached
      log(LEVEL.DEBUG, "Loaded " .. #recipePatterns .. " pattern(s) from " .. DATA_CACHE_PATH .. ".")
    end
  end
  if forceRescan or not recipePatterns then
    log(LEVEL.DEBUG, (recipePatterns and "Refreshing" or "Caching") .. " recipe patterns...")
    recipePatterns = scanRecipePatterns()
    log(LEVEL.DEBUG, "Cached " .. #recipePatterns .. " pattern(s).")
    saveCachedSection("patterns", recipePatterns)
  end
  return recipePatterns
end

-- Copies of the pattern the stock holds, or nil unless the stock is exactly the pattern's item inputs.
local function patternCopies(pattern, stock)
  local required = {}
  for _, ingredient in pairs(pattern.inputs) do
    if not isFluidEntry(ingredient) then
      required[itemKey(ingredient)] = (required[itemKey(ingredient)] or 0) + ingredient.size
    end
  end
  for key in pairs(stock) do
    if not required[key] then return nil end
  end
  local copies
  for key, size in pairs(required) do
    copies = math.min(copies or math.huge, math.floor((stock[key] or 0) / size))
  end
  return copies and copies > 0 and copies or nil
end

local function entangledFluidName(plainName)
  return ENTANGLED_FLUID_NAMES[plainName]
    or fatalError("no known Entangled fluid for '" .. plainName .. "' - add it to ENTANGLED_FLUID_NAMES")
end

local function checkDiodeCapacity(fluidCount, what)
  if fluidCount > #DIODE_RECIPE_FILTER_SLOTS then
    fatalError(what .. " " .. fluidCount .. " Entangled fluids, more than the " .. #DIODE_RECIPE_FILTER_SLOTS .. " the Diode can filter for.")
  end
end

-- Returns nil while the Input Subnet is empty, or nil plus a reason when it can't be read.
local function tryIdentifyRecipe()
  local items, err = inputItems()
  if not items then return nil, err end
  if #items == 0 then return nil end
  local stock = {}
  for _, item in ipairs(items) do stock[itemKey(item)] = (stock[itemKey(item)] or 0) + item.size end

  local function findMatch(patterns)
    for _, pattern in ipairs(patterns) do
      local copies = patternCopies(pattern, stock)
      if copies then return pattern, copies end
    end
  end
  local matched, copies = findMatch(getRecipePatterns(false))
  if not matched then matched, copies = findMatch(getRecipePatterns(true)) end
  if not matched then
    local described = {}
    for key, amount in pairs(stock) do table.insert(described, key .. " x" .. amount) end
    fatalError("Input Subnet has items but no recipe pattern matches (possible mixed recipe): " .. table.concat(described, ", "))
  end

  local output = matched.outputs and matched.outputs[1]
  local recipe = {
    copies = copies,
    name = stripFormatting(output and output.label or "?"),
    outputCount = copies * (output and output.size or 1),
    fluids = {},
  }
  for _, ingredient in pairs(matched.inputs) do
    if isFluidEntry(ingredient) then
      table.insert(recipe.fluids, {
        plainName = ingredient.name,
        entangledName = entangledFluidName(ingredient.name),
        amountPerCopy = ingredient.amount,
      })
    end
  end
  checkDiodeCapacity(#recipe.fluids, recipe.name .. " recipe needs")
  return recipe
end

local function waitForRecipe()
  setPhase("Waiting for recipe")
  -- redstone_changed events that fired during the last batch were consumed by its sleeps.
  local recipe, err = tryIdentifyRecipe()
  while not recipe do
    if err then log(LEVEL.WARN, err) end
    local _, _, side, _, newValue = event.pull("redstone_changed")
    if newValue and newValue > 0 then
      log(LEVEL.DEBUG, "Input Subnet signal on side " .. tostring(side) .. " (" .. newValue .. ")")
      os.sleep(INPUT_SETTLE_TIME)
      recipe, err = tryIdentifyRecipe()
    else
      err = nil
    end
  end
  return recipe
end

local function splitParallels(totalCopies, nodeAddresses)
  local nodesUsed = math.min(totalCopies, #nodeAddresses)
  local base, remainder = math.floor(totalCopies / nodesUsed), totalCopies % nodesUsed
  local assignments = {}
  for i = 1, nodesUsed do
    table.insert(assignments, { address = nodeAddresses[i], count = base + (i <= remainder and 1 or 0) })
  end
  return assignments
end

-- Condensate and Diode

local function condensateGateOpen(storage, recipe)
  local ok, condensate = pcall(storage.getStoredCondensate)
  if not ok or not condensate then return false end
  for _, fluid in ipairs(recipe.fluids) do
    if (condensate[fluid.entangledName] or 0) < fluid.amountPerCopy * recipe.copies then return false end
  end
  return true
end

local function findDiode()
  local address, diode = firstComponent("bec_diode")
  if not address then fatalError("could not find bec_diode") end
  return diode
end

-- An empty filter list blocks every condensate, so the water slot is never cleared.
local function initializeDiodeWaterFilter()
  local diode = findDiode()
  local ok, err = pcall(diode.setCondensateFilterAt, DIODE_WATER_SLOT, DIODE_WATER_FLUID)
  if not ok then fatalError("could not set Diode water filter: " .. tostring(err)) end
  log(LEVEL.DEBUG, "Diode water filter set on slot " .. DIODE_WATER_SLOT .. ".")
  ok, err = pcall(diode.setWorkAllowed, true)
  if not ok then fatalError("could not turn on bec_diode: " .. tostring(err)) end
  log(LEVEL.DEBUG, "Diode work allowed.")
end

local function setDiodeRecipeFilters(fluidNames)
  local diode = findDiode()
  for i, slot in ipairs(DIODE_RECIPE_FILTER_SLOTS) do
    local ok, err = pcall(diode.setCondensateFilterAt, slot, fluidNames[i])
    if not ok then fatalError("setting Diode filter slot " .. slot .. ": " .. tostring(err)) end
  end
end

local function setDiodeFiltersForRecipe(recipe)
  local names = {}
  for _, fluid in ipairs(recipe.fluids) do table.insert(names, fluid.entangledName) end
  setDiodeRecipeFilters(names)
  log(LEVEL.DEBUG, "Diode filters set for recipe fluids.")
end

local function setDiodeFiltersFromNodes(assignments)
  local required, names = {}, {}
  for _, a in ipairs(assignments) do
    local ok, condensate = pcall(component.proxy(a.address).getRequiredCondensate)
    for fluidName in pairs(ok and condensate or {}) do
      if not required[fluidName] then
        required[fluidName] = true
        table.insert(names, fluidName)
      end
    end
  end
  checkDiodeCapacity(#names, "resumed IONodes require")
  setDiodeRecipeFilters(names)
  log(LEVEL.DEBUG, "Diode filters set from resumed IONodes' required condensate.")
end

-- Nanites. Each tier has an AE2 pattern on the nanite subnet's ME controller, with its
-- output renamed to the tier number.

local nanitePatterns = {}

local function nanitePattern(tier)
  if nanitePatterns[tier] then return nanitePatterns[tier] end
  local address, controller = firstComponent("me_controller")
  if not address then return nil, "could not find the nanite subnet's ME controller" end
  local ok, craftables = pcall(controller.getCraftables, { label = tostring(tier) })
  if not ok then return nil, tostring(craftables) end
  if not craftables or not craftables[1] then return nil, 'no nanite pattern with output labelled "' .. tier .. '"' end
  local stackOk, stack = pcall(craftables[1].getStack)
  if not stackOk or type(stack) ~= "table" or type(stack.size) ~= "number" or stack.size < 1 then
    return nil, 'could not read the output of the nanite pattern labelled "' .. tier .. '"'
  end
  -- request() takes an output item count, not a number of pattern runs.
  nanitePatterns[tier] = { craftable = craftables[1], outputPerCraft = stack.size }
  return nanitePatterns[tier]
end

local function requestNanites(tier, runs)
  local job, reason
  for _ = 1, 2 do
    local pattern, err = nanitePattern(tier)
    if not pattern then return false, err end
    local amount = runs * pattern.outputPerCraft
    local ok, result, resultReason = pcall(pattern.craftable.request, amount)
    if ok and result then
      job = result
      log(LEVEL.DEBUG, string.format('Requested %d of nanite pattern "%d" (%d run(s) x %d per craft).', amount, tier, runs, pattern.outputPerCraft))
      break
    end
    reason = ok and resultReason or result
    -- Cached craftables go stale when their chunk reloads.
    nanitePatterns[tier] = nil
  end
  if not job then return false, "nanite request failed: " .. tostring(reason) end

  -- hasFailed() alone can't be trusted: OC's CraftingStatus.save() marks every unfinished request failed
  -- with reason "no link". isCanceled() also covers real failures, whose reason starts "request failed".
  local ok, err = poll(NANITE_CRAFT_TIMEOUT, NANITE_CRAFT_POLL_INTERVAL, function()
    local doneOk, done = pcall(job.isDone)
    if doneOk and done then return true end
    local canceledOk, canceled = pcall(job.isCanceled)
    if canceledOk and canceled then
      local _, _, reason = pcall(job.hasFailed)
      if type(reason) == "string" and reason:find("^request failed") then return false, "nanite " .. reason end
      return false, "nanite crafting was canceled"
    end
  end)
  if ok then return true end
  return false, err or ("nanite crafting not done after " .. NANITE_CRAFT_TIMEOUT .. "s")
end

-- IONode supervision

local function activeNodes(assignments)
  local list = {}
  for _, a in ipairs(assignments) do
    local ok, hasWork = pcall(component.proxy(a.address).hasWork)
    if ok and hasWork then table.insert(list, a.address) end
  end
  return list
end

-- getWorkMaxProgress() scales with the node's parallel count.
local function progressFraction(node)
  local progressOk, progress = pcall(node.getWorkProgress)
  local maxOk, maxProgress = pcall(node.getWorkMaxProgress)
  if progressOk and maxOk and progress and maxProgress and maxProgress ~= 0 then return progress / maxProgress end
end

-- The least-progressed node sets the batch time, so its nanite tier is the one supplied.
local function electReference(nodeAddresses)
  local bestAddress, bestFraction
  for _, address in ipairs(nodeAddresses) do
    local fraction = progressFraction(component.proxy(address))
    if fraction and (not bestFraction or fraction < bestFraction) then
      bestAddress, bestFraction = address, fraction
    end
  end
  return bestAddress
end

local function requiredTier(node)
  local ok, required = pcall(node.getRequiredTier)
  if ok and required and required.tier then return required end
end

local function superviseCrafting(assignments)
  local runs = math.max(1, math.ceil(#addresses("bec_io_node") / IO_NODES_PER_ARRAY))
  log(LEVEL.DEBUG, "Nanite pattern runs: " .. runs .. " per tier change.")

  local referenceAddress = electReference(activeNodes(assignments)) or fatalError("no active IONodes to craft with")
  local reference = component.proxy(referenceAddress)
  log(LEVEL.DEBUG, "Reference node: " .. referenceAddress)

  local providedTier
  local swapFailureSeconds = 0

  local function supply(required)
    local tier = required.tier
    if type(tier) == "number" and tier >= 1 and tier <= NANITE_TIER_COUNT then
      log(LEVEL.DEBUG, "Required tier changed -> " .. tostring(required.name) .. " (" .. tier .. ")")
      local ok, err = extractNanites()
      if ok then ok, err = requestNanites(tier, runs) end
      if ok then
        providedTier = tier
        status.currentTier = required.name and (TIER_DISPLAY_NAMES[required.name] or (required.name .. " Nanite"))
        swapFailureSeconds = 0
        render()
        return
      end
      log(LEVEL.WARN, "swap FAILED: " .. tostring(err))
    else
      log(LEVEL.WARN, "Reference node requires unrecognized tier index " .. tostring(tier) .. " - cannot supply nanites.")
    end
    swapFailureSeconds = swapFailureSeconds + NANITE_POLL_INTERVAL
    if swapFailureSeconds >= TIER_SWAP_FAILURE_TIMEOUT then
      fatalError("nanite tier swap has failed repeatedly for " .. TIER_SWAP_FAILURE_TIMEOUT .. "s - giving up.")
    end
  end

  while true do
    local active = activeNodes(assignments)
    if #active == 0 then return end

    local referenceActive = false
    for _, address in ipairs(active) do
      if address == referenceAddress then referenceActive = true end
    end
    local required = referenceActive and requiredTier(reference) or nil
    -- providedTier is nil only before the first swap, right after the initial election.
    if not referenceActive or (required and providedTier and required.tier ~= providedTier) then
      local newAddress = electReference(active)
      if newAddress then
        referenceAddress, reference = newAddress, component.proxy(newAddress)
        log(LEVEL.DEBUG, "Reference node: " .. referenceAddress)
        required = requiredTier(reference) or required
      end
    end

    if required and required.tier ~= providedTier then supply(required) end

    local fraction = progressFraction(reference)
    if fraction then
      status.progressPercent = math.floor(fraction * 100)
      render()
    end
    os.sleep(NANITE_POLL_INTERVAL)
  end
end

local function pulseRedstoneReturnDrives()
  local address, redstone = firstComponent("redstone")
  if not address then return false, "no redstone component found" end
  local function setAll(level)
    local levels = {}
    for side = 0, 5 do levels[side] = level end
    return pcall(redstone.setOutput, levels)
  end
  local ok, err = setAll(15)
  if not ok then return false, "setOutput high failed: " .. tostring(err) end
  os.sleep(REDSTONE_PULSE_DURATION)
  ok, err = setAll(0)
  if not ok then return false, "setOutput low failed: " .. tostring(err) end
  return true
end

-- recipe is nil for a batch resumed after a restart.
local function finishBatch(assignments, recipe, batchStartUptime)
  local elapsed = math.floor(computer.uptime() - batchStartUptime)
  local timeStr = string.format("%02d:%02d", math.floor(elapsed / 60), elapsed % 60)
  log(LEVEL.INFO, "Recipe finished processing in " .. timeStr)
  if not config.onlySendErrors then
    local count = recipe and recipe.outputCount
    if not count then
      count = 0
      for _, a in ipairs(assignments) do count = count + a.count end
    end
    sendDiscordMessage((recipe and recipe.name or "Unknown Item") .. " x" .. count .. " finished processing in " .. timeStr)
  end

  setPhase("Clearing Diode filters")
  setDiodeRecipeFilters({})
  log(LEVEL.DEBUG, "Diode recipe filters cleared.")

  setPhase("Extracting nanites")
  local ok, err = extractNanites()
  if not ok then fatalError("extracting nanites: " .. tostring(err)) end
  status.currentTier = nil
  log(LEVEL.DEBUG, "Nanites extracted.")

  local remaining = inputItems()
  if not remaining then fatalError("could not verify Input Subnet is empty after the batch") end
  local remainingCount = 0
  for _, item in ipairs(remaining) do remainingCount = remainingCount + item.size end
  if remainingCount > 0 then
    fatalError("Input Subnet still has " .. remainingCount .. " item(s) after the batch - refusing to return drives to Pending Subnet.")
  end

  setPhase("Returning input drives")
  ok, err = pulseRedstoneReturnDrives()
  if not ok then fatalError("redstone pulse: " .. tostring(err)) end
  log(LEVEL.DEBUG, "Drive-return pulse sent.")
end

local function runBatch(assignments, recipe, batchStartUptime)
  status.recipeName = recipe and recipe.name
  status.recipeOutputCount = recipe and recipe.outputCount
  setPhase("Crafting")
  log(LEVEL.INFO, "Crafting...")
  superviseCrafting(assignments)
  finishBatch(assignments, recipe, batchStartUptime)
end

local function waitForCondensate(recipe)
  setPhase("Waiting for Condensate")
  log(LEVEL.INFO, "Waiting for entangled condensate...")
  for _, fluid in ipairs(recipe.fluids) do
    log(LEVEL.DEBUG, "  need " .. (fluid.amountPerCopy * recipe.copies) .. "L " .. fluid.entangledName .. " (from " .. fluid.plainName .. ")")
  end
  local address, storage = firstComponent("bec_storage")
  if not address then fatalError("could not find bec_storage") end
  while not condensateGateOpen(storage, recipe) do os.sleep(GATE_POLL_INTERVAL) end
  setPhase("Setting Diode filters")
  setDiodeFiltersForRecipe(recipe)
end

-- Each node is enabled until it picks up its share, then disabled so it can't start another.
local function startNodes(assignments)
  setPhase("Starting IONodes")
  log(LEVEL.INFO, "Starting " .. #assignments .. "x IONodes")
  local setupStart = computer.uptime()
  for _, a in ipairs(assignments) do
    local node = component.proxy(a.address)
    local minOk = pcall(node.setMinParallel, a.count)
    local maxOk = pcall(node.setMaxParallel, a.count)
    if not minOk or not maxOk then log(LEVEL.WARN, a.address .. " failed to set parallel count to " .. a.count) end
  end
  log(LEVEL.DEBUG, string.format("Set parallels on %d node(s) in %dms", #assignments, math.floor((computer.uptime() - setupStart) * 1000 + 0.5)))
  for _, a in ipairs(assignments) do
    if not pcall(component.proxy(a.address).setWorkAllowed, true) then log(LEVEL.WARN, a.address .. " failed to enable work.") end
  end

  local pending = {}
  for _, a in ipairs(assignments) do pending[a.address] = true end
  local started = poll(NODE_STARTUP_TIMEOUT, NODE_STARTUP_POLL_INTERVAL, function()
    for address in pairs(pending) do
      local node = component.proxy(address)
      local ok, hasWork = pcall(node.hasWork)
      if ok and hasWork then
        pcall(node.setWorkAllowed, false)
        pending[address] = nil
        log(LEVEL.DEBUG, address .. " picked up work, disabled.")
      end
    end
    return next(pending) == nil
  end)
  if not started then
    local stuck = {}
    for address in pairs(pending) do table.insert(stuck, address) end
    fatalError(#stuck .. " IONode(s) never picked up work within " .. NODE_STARTUP_TIMEOUT .. "s: " .. table.concat(stuck, ", "))
  end
end

local function findInProgressAssignments()
  local assignments = {}
  for address in component.list("bec_io_node", true) do
    local node = component.proxy(address)
    local workOk, hasWork = pcall(node.hasWork)
    if workOk and hasWork then
      local countOk, count = pcall(node.getMaxParallel)
      table.insert(assignments, { address = address, count = countOk and count or 0 })
    end
  end
  return assignments
end

local function runOneCycle()
  status.recipeName, status.recipeOutputCount, status.currentTier, status.progressPercent = nil, nil, nil, nil
  render()

  local resumed = findInProgressAssignments()
  if #resumed > 0 then
    logSeparator()
    log(LEVEL.WARN, "Resuming " .. #resumed .. " in-progress IONode(s) from before restart.")
    setPhase("Setting Diode filters (resumed)")
    setDiodeFiltersFromNodes(resumed)
    runBatch(resumed, nil, computer.uptime())
    return
  end

  local recipe = waitForRecipe()
  local batchStartUptime = computer.uptime()
  status.recipeName, status.recipeOutputCount = recipe.name, recipe.outputCount
  logSeparator()
  log(LEVEL.INFO, recipe.name .. " x" .. recipe.outputCount)

  setPhase("Splitting parallels")
  local nodes = addresses("bec_io_node")
  if #nodes == 0 then fatalError("no IONodes found") end
  local assignments = splitParallels(recipe.copies, nodes)
  for _, a in ipairs(assignments) do log(LEVEL.DEBUG, "assign " .. a.address .. " -> " .. a.count) end

  waitForCondensate(recipe)
  startNodes(assignments)
  runBatch(assignments, recipe, batchStartUptime)
end

-- Startup

local function loadConfig()
  local file = io.open(CONFIG_PATH, "r")
  if not file then
    file = io.open(CONFIG_PATH, "w")
    if file then
      for _, entry in ipairs(CONFIG_DEFAULTS) do file:write(entry[1] .. "=" .. tostring(entry[2]) .. "\n") end
      file:close()
    end
    return
  end
  for line in file:lines() do
    local key, raw = line:match("^%s*(%a+)%s*=%s*(.-)%s*$")
    if key and config[key] ~= nil then
      local value = raw:match('^"(.*)"$') or raw:match("^'(.*)'$") or raw
      if type(config[key]) == "boolean" then value = value:lower() == "true" end
      config[key] = value
    end
  end
  file:close()
end

local function readShrc()
  local file = io.open(SHRC_PATH, "r")
  if not file then return "" end
  local content = file:read("*a") or ""
  file:close()
  return content
end

-- .shrc runs at every shell start, including boot.
local function ensureAutorun()
  if readShrc():find(SCRIPT_PATH, 1, true) then return end
  local file = io.open(SHRC_PATH, "a")
  if not file then
    log(LEVEL.WARN, "couldn't register autorun in " .. SHRC_PATH)
    return
  end
  file:write(SCRIPT_PATH .. "\n")
  file:close()
  log(LEVEL.DEBUG, "Registered autorun in " .. SHRC_PATH .. " - will start automatically on boot.")
end

local function removeAutorun()
  local content = readShrc()
  if not content:find(SCRIPT_PATH, 1, true) then return end
  local kept = {}
  for line in (content .. "\n"):gmatch("(.-)\n") do
    if not line:find(SCRIPT_PATH, 1, true) then table.insert(kept, line) end
  end
  local file = io.open(SHRC_PATH, "w")
  if not file then
    log(LEVEL.WARN, "couldn't unregister autorun in " .. SHRC_PATH)
    return
  end
  file:write(table.concat(kept, "\n") .. (#kept > 0 and "\n" or ""))
  file:close()
  log(LEVEL.DEBUG, "Removed autorun entry from " .. SHRC_PATH .. " (enableAutoStart=false).")
end

-- Compares dotted versions part by part ("2.10" is newer than "2.9"); missing parts count as 0.
local function isNewerVersion(candidate, current)
  local function parts(version)
    local list = {}
    for number in version:gmatch("%d+") do table.insert(list, tonumber(number)) end
    return list
  end
  local a, b = parts(candidate), parts(current)
  for i = 1, math.max(#a, #b) do
    if (a[i] or 0) ~= (b[i] or 0) then return (a[i] or 0) > (b[i] or 0) end
  end
  return false
end

-- Returns true once a newer script has been written over this one.
local function applyUpdate()
  local remoteVersionText, versionErr = httpRequest(UPDATE_VERSION_URL)
  if not remoteVersionText then
    log(LEVEL.DEBUG, "update check skipped: " .. tostring(versionErr))
    return false
  end
  local remoteVersion = remoteVersionText:match("%d[%d.]*")
  if not remoteVersion or not isNewerVersion(remoteVersion, VERSION) then
    log(LEVEL.DEBUG, "up to date (v" .. VERSION .. ").")
    return false
  end

  log(LEVEL.WARN, "update available: v" .. VERSION .. " -> v" .. remoteVersion .. ", downloading...")
  local script, scriptErr = httpRequest(UPDATE_SCRIPT_URL)
  if not script or #script == 0 then
    log(LEVEL.WARN, "update download failed: " .. tostring(scriptErr))
    return false
  end
  local file = io.open(SCRIPT_PATH, "w")
  if not file then
    log(LEVEL.WARN, "update failed: could not open " .. SCRIPT_PATH .. " for writing")
    return false
  end
  file:write(script)
  file:close()
  log(LEVEL.WARN, "updated to v" .. remoteVersion .. " - rebooting to apply.")
  return true
end

-- Returns true when an update was applied and the computer should reboot.
local function startup()
  setPhase("Starting Up (Loading Config)")
  loadConfig()

  setPhase("Starting Up (Registering Autorun)")
  if config.enableAutoStart then ensureAutorun() else removeAutorun() end

  setPhase("Starting Up (Checking for Updates)")
  if config.enableAutoUpdate and applyUpdate() then return true end

  setPhase("Starting Up (Syncing Real Time)")
  syncRealTime()
  log(LEVEL.DEBUG, "BEC Controller starting.")

  setPhase("Starting Up (Disabling IONodes)")
  local nodes = addresses("bec_io_node")
  if #nodes == 0 then fatalError("no IONodes found") end
  for _, address in ipairs(nodes) do pcall(component.proxy(address).setWorkAllowed, false) end
  log(LEVEL.DEBUG, "Disabled " .. #nodes .. " IONode(s) at startup.")

  setPhase("Starting Up (Verifying Extraction Cell)")
  verifyExtractionCell()

  setPhase("Starting Up (Finding Nanite Patterns)")
  local _, patternErr = nanitePattern(1)
  if patternErr then fatalError(patternErr .. " at startup") end

  setPhase("Starting Up (Setting Diode Water Filter)")
  initializeDiodeWaterFilter()

  setPhase("Starting Up (Loading Recipe Patterns)")
  getRecipePatterns(false)
  return false
end

local function handleError(err, context)
  if isInterrupted(err) then performShutdown() end
  fatalError("unexpected error" .. context .. ": " .. tostring(err))
end

local startupOk, rebootForUpdate = pcall(startup)
if not startupOk then
  handleError(rebootForUpdate, " during startup")
elseif rebootForUpdate then
  pcall(logFile.close, logFile)
  computer.shutdown(true)
end

while true do
  local ok, err = pcall(runOneCycle)
  if not ok then handleError(err, "") end
end
