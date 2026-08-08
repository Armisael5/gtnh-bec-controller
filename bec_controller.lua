-- BEC Controller
-- Author: Armisael/nex5
-- Version: 3
-- Automates the Bose-Einstein Condensate network: pulls a recipe from
-- Input Subnet, splits it among the IONodes, tracks nanite tiers as
-- they change, ships output back to the main network, resets for the
-- next batch. Loops forever. Ctrl+Alt+C to exit.

local component = require("component")
local computer = require("computer")
local filesystem = require("filesystem")
local sides = require("sides")

-- ============================================================
-- Logging + display
-- ============================================================

local LEVEL = { DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4 }
local LEVEL_NAMES = { [1] = "DEBUG", [2] = "INFO", [3] = "WARN", [4] = "ERROR" }
local FILE_LOG_LEVEL = LEVEL.DEBUG   -- everything goes to the log file
local SCREEN_LOG_LEVEL = LEVEL.INFO  -- only meaningful events show on screen
local MAX_RECENT_LINES = 30
local MAX_LOG_SIZE = 512 * 1024 -- rotate log.log to log.old past this size

local LOG_PATH = "/home/log.log"
local LOG_PATH_OLD = "/home/log.old"

local function openLogFile()
  return assert(io.open(LOG_PATH, "a"))
end

local logFileOk, logFileResult = pcall(openLogFile)
if not logFileOk then
  print("FATAL: could not open " .. LOG_PATH .. ": " .. tostring(logFileResult))
  os.exit(1)
end
local logFile = logFileResult
local logFileBytes = 0
do
  local ok, size = pcall(filesystem.size, LOG_PATH)
  if ok and size then logFileBytes = size end
end

local recentLines = {}
local timeOffset = nil -- real-world epoch minus computer.uptime(), set by syncRealTime()

local gpuAddress, gpu, screenAddress
for address in component.list("gpu", true) do gpuAddress = address end
for address in component.list("screen", true) do screenAddress = address end
if gpuAddress then
  gpu = component.proxy(gpuAddress)
  if screenAddress then
    pcall(gpu.bind, screenAddress)
    pcall(function() component.proxy(screenAddress).turnOn() end)
  end
end

local status = {
  phase = "Starting up",
  recipeName = nil,
  recipeCopies = nil,
  currentTier = nil,
}

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
local function humanizeTierName(name)
  if not name then return nil end
  return TIER_DISPLAY_NAMES[name] or (name .. " Nanite")
end

local function stripFormatting(text)
  text = text:gsub("\194\167.", "")
  text = text:gsub("\167.", "")
  return text
end

local render

local function formatUptime(uptime)
  local total = math.floor(uptime)
  local days = math.floor(total / 86400)
  local hours = math.floor((total % 86400) / 3600)
  local minutes = math.floor((total % 3600) / 60)
  local seconds = total % 60
  if days > 0 then
    return string.format("%dd %02d:%02d:%02d", days, hours, minutes, seconds)
  end
  return string.format("%02d:%02d:%02d", hours, minutes, seconds)
end

-- filesystem.lastModified() reports the real host-system unix time
local function formatEpoch(epoch)
  return os.date("%Y-%m-%d %H:%M:%S", epoch)
end

local function currentTimestamp()
  if timeOffset then
    return formatEpoch(timeOffset + computer.uptime())
  end
  return formatUptime(computer.uptime())
end

-- Cycle log.log
local function rotateLogIfNeeded()
  if logFileBytes < MAX_LOG_SIZE then return end
  pcall(function() logFile:close() end)
  pcall(filesystem.remove, LOG_PATH_OLD)
  pcall(filesystem.rename, LOG_PATH, LOG_PATH_OLD)
  logFile = openLogFile()
  logFileBytes = 0
end

local function log(level, message)
  local fileLine = "[" .. currentTimestamp() .. "] [" .. LEVEL_NAMES[level] .. "] " .. tostring(message)
  if level >= FILE_LOG_LEVEL then
    local line = fileLine .. "\n"
    local writeOk = pcall(function() logFile:write(line) end)
    if writeOk then
      pcall(function() logFile:flush() end)
      logFileBytes = logFileBytes + #line
      rotateLogIfNeeded()
    end
  end
  if level >= SCREEN_LOG_LEVEL then
    local screenLine = (level == LEVEL.INFO) and tostring(message)
      or ("[" .. LEVEL_NAMES[level] .. "] " .. tostring(message))
    table.insert(recentLines, screenLine)
    while #recentLines > MAX_RECENT_LINES do table.remove(recentLines, 1) end
    render()
  end
end

-- Visually separates one batch's log entries from the next.
local function logSeparator()
  log(LEVEL.INFO, string.rep("_", 28))
  log(LEVEL.INFO, "")
end

render = function()
  if not gpu then return end
  local ok, w, h = pcall(gpu.getResolution)
  if not ok then return end
  pcall(gpu.setBackground, 0x000000)
  pcall(gpu.setForeground, 0xFFFFFF)
  pcall(gpu.fill, 1, 1, w, h, " ")

  pcall(gpu.setForeground, 0x66CCFF)
  pcall(gpu.set, 2, 1, "BEC Controller")
  pcall(gpu.setForeground, 0xFFFFFF)

  local recipeText = "-"
  if status.recipeName then
    recipeText = status.recipeName .. "  x" .. tostring(status.recipeCopies)
  end

  pcall(gpu.set, 2, 3, "Status:         " .. status.phase)
  pcall(gpu.set, 2, 4, "Recipe:         " .. recipeText)
  pcall(gpu.set, 2, 5, "Requested Tier: " .. (status.currentTier or "-"))

  pcall(gpu.set, 2, 7, string.rep("_", math.max(0, w - 2)))

  local startRow = 8
  local n = #recentLines
  local visibleRows = math.max(0, h - startRow + 1)
  local firstShown = math.max(1, n - visibleRows + 1)
  local row = startRow
  for i = firstShown, n do
    local line = recentLines[i]
    pcall(gpu.set, 2, row, line:sub(1, math.max(0, w - 2)))
    row = row + 1
  end
end

local function setPhase(phase)
  status.phase = phase
  render()
end

-- OpenComputers' built-in interrupt (Ctrl+Alt+C) raises a plain Lua error
-- with this message - just as catchable as any other error, not a special
-- hard-kill. Any pcall boundary that sees it should treat it as a clean
-- shutdown request rather than an unexpected crash.
local function isInterrupted(err)
  return tostring(err):find("interrupted", 1, true) ~= nil
end

local function performShutdown()
  log(LEVEL.WARN, "Interrupted - exiting.")
  pcall(function() logFile:close() end)
  if gpu then
    local ok, w, h = pcall(gpu.getResolution)
    pcall(gpu.setBackground, 0x000000)
    pcall(gpu.setForeground, 0xFFFFFF)
    if ok then pcall(gpu.fill, 1, 1, w, h, " ") end
  end
  os.exit(0)
end

local function fatalError(message)
  log(LEVEL.ERROR, message)
  status.phase = "FATAL: " .. message
  render()
  while true do os.sleep(5) end
end

local function syncRealTime()
  local tmpPath = "/tmp/bec_controller_time.tmp"
  local file = io.open(tmpPath, "w")
  if not file then
    log(LEVEL.WARN, "couldn't open temp file for time sync - log timestamps will use uptime, not real time.")
    return
  end
  file:write("")
  file:close()

  local ok, millis = pcall(filesystem.lastModified, tmpPath)
  pcall(filesystem.remove, tmpPath)
  if not ok or not millis then
    log(LEVEL.WARN, "couldn't read temp file mtime - log timestamps will use uptime, not real time.")
    return
  end

  local epoch = math.floor(millis / 1000)
  timeOffset = epoch - computer.uptime()
  log(LEVEL.DEBUG, "Time synced: " .. formatEpoch(epoch))
end

-- ============================================================
-- Config
-- ============================================================

local TIERS_IN_ORDER = {
  "naniteCarbon", "naniteSilver", "naniteGold", "naniteTranscendentMetal",
  "naniteSixPhasedCopper", "naniteWhiteDwarfMatter", "naniteBlackDwarfMatter",
  "naniteUniversium", "naniteEternity", "naniteMagmatter",
}
local SWAP_SETTLE_TIME = 0.1
local OUTPUT_SETTLE_TIME = 0.1
local REDSTONE_PULSE_DURATION = 0.2
local NANITE_POLL_INTERVAL = 0.3
local GATE_POLL_INTERVAL = 0.5
local RECIPE_POLL_INTERVAL = 0.5
local NODE_STARTUP_TIMEOUT = 30
local NODE_STARTUP_POLL_INTERVAL = 0.3
local TIER_SWAP_FAILURE_TIMEOUT = 30
local BLOCK_FILTER = "meow"
local MAX_NODES = 16
local IO_PORT_SLOT = 7 -- the ME IO Port's single item slot (both transposers)
local NANITE_TRANSPOSER_MARKER_SLOT = 12 -- dummy marking the nanite-swap transposer
local OUTPUT_TRANSPOSER_MARKER_SLOT = 11 -- dummy marking the output-subnet transposer

-- ============================================================
-- Discovery helpers
-- ============================================================

local function findMarkedInterface(label)
  for address in component.list("me_interface", true) do
    local proxy = component.proxy(address)
    local ok, items = pcall(proxy.getItemsInNetwork)
    if ok and items then
      for _, item in pairs(items) do
        if item.label == label then
          return address, proxy, items
        end
      end
    end
  end
  return nil
end

local inputInterfaceAddress = nil

local function getInputInterface()
  if inputInterfaceAddress then
    return inputInterfaceAddress, component.proxy(inputInterfaceAddress)
  end
  local address, proxy = findMarkedInterface("Input")
  inputInterfaceAddress = address
  return address, proxy
end

local function findAllIoNodes()
  local list = {}
  for address in component.list("bec_io_node", true) do
    table.insert(list, address)
  end
  return list
end

local function findGtMachineByName(name)
  for address in component.list("gt_machine", true) do
    local proxy = component.proxy(address)
    local ok, actualName = pcall(proxy.getName)
    if ok and actualName == name then
      return address, proxy
    end
  end
  return nil
end

local function findBecStorage()
  for address in component.list("bec_storage", true) do
    return address, component.proxy(address)
  end
  return nil
end

local function findRedstone()
  for address in component.list("redstone", true) do
    return address, component.proxy(address)
  end
  return nil
end

-- Finds the transposer with a permanent dummy item in markerSlot, and
-- returns its address, the marker side, and the other active side. Both
-- the nanite-swap transposer (marker in slot 12) and the output-subnet
-- transposer (marker in slot 11) are this same physical pattern.
local function findTransposerByMarkerSlot(markerSlot)
  for address in component.list("transposer", true) do
    local transposer = component.proxy(address)
    local activeSides = {}
    local markerSide
    for side = 0, 5 do
      local ok, size = pcall(transposer.getInventorySize, side)
      if ok and size and size > 0 then
        table.insert(activeSides, side)
        local stackOk, stack = pcall(transposer.getStackInSlot, side, markerSlot)
        if stackOk and stack then markerSide = side end
      end
    end
    if markerSide then
      local otherSide
      for _, side in ipairs(activeSides) do
        if side ~= markerSide then otherSide = side end
      end
      return address, markerSide, otherSide
    end
  end
  return nil
end

local function findNaniteTransposer()
  return findTransposerByMarkerSlot(NANITE_TRANSPOSER_MARKER_SLOT)
end

local function findOutputTransposer()
  return findTransposerByMarkerSlot(OUTPUT_TRANSPOSER_MARKER_SLOT)
end

-- Which of a transposer's two candidate sides currently holds a drive in
-- IO_PORT_SLOT - the drive physically moves back and forth between them.
local function findDriveSide(transposer, sideA, sideB)
  for _, side in ipairs({ sideA, sideB }) do
    local ok, stack = pcall(transposer.getStackInSlot, side, IO_PORT_SLOT)
    if ok and stack then return side end
  end
  return nil
end

local function findStorageBus()
  for address in component.list("me_storagebus", true) do
    return address, component.proxy(address)
  end
  return nil
end

-- ============================================================
-- Step 1: identify recipe from Input Subnet's items
-- ============================================================

local function isFluidEntry(entry)
  return entry.amount ~= nil and entry.damage == nil
end

local function scanRecipePatterns()
  local patterns = {}
  for address in component.list("fluid_interface", true) do
    local proxy = component.proxy(address)
    for slot = 1, 36 do
      local ok, pattern = pcall(proxy.getInterfacePattern, slot)
      if ok and pattern and pattern.inputs then
        table.insert(patterns, pattern)
      end
    end
  end
  return patterns
end

-- Cache patterns from Mainnet interface for recipe identification
-- and calculating parallels
local cachedPatterns = nil
local function getCachedPatterns(forceRescan)
  if forceRescan or cachedPatterns == nil then
    log(LEVEL.DEBUG, (cachedPatterns == nil and "Caching recipe patterns" or "Refreshing pattern cache") .. "...")
    cachedPatterns = scanRecipePatterns()
    log(LEVEL.DEBUG, "Cached " .. #cachedPatterns .. " pattern(s).")
  end
  return cachedPatterns
end

local function tryMatch(pattern, stock)
  local patternKeys = {}
  local minCopies = nil
  for _, ingredient in ipairs(pattern.inputs) do
    if not isFluidEntry(ingredient) then
      local key = ingredient.name .. ":" .. tostring(ingredient.damage)
      patternKeys[key] = true
      local have = stock[key] or 0
      if have < ingredient.size then return nil end
      local copies = math.floor(have / ingredient.size)
      if minCopies == nil or copies < minCopies then minCopies = copies end
    end
  end
  for key in pairs(stock) do
    if not patternKeys[key] then return nil end
  end
  return minCopies
end

-- One attempt at identification.
-- Returns nil if Input Subnet is simply empty
local function tryIdentifyRecipe()
  local inputAddress, inputProxy = getInputInterface()
  if not inputAddress then
    return nil, "could not find Input Subnet interface"
  end
  local itemsOk, inputItems = pcall(inputProxy.getItemsInNetwork)
  if not itemsOk or not inputItems then
    return nil, "could not read Input Subnet items"
  end

  local stock = {}
  local stockCount = 0
  for _, item in pairs(inputItems) do
    if item.label ~= "Input" then
      local key = item.name .. ":" .. tostring(item.damage)
      stock[key] = (stock[key] or 0) + item.size
      stockCount = stockCount + 1
    end
  end

  if stockCount == 0 then
    return nil -- nothing to match yet; skip touching the pattern interfaces entirely
  end

  local function findMatchOnce(patterns)
    for _, pattern in ipairs(patterns) do
      local copies = tryMatch(pattern, stock)
      if copies and copies > 0 then return pattern, copies end
    end
    return nil
  end

  local matched, copies = findMatchOnce(getCachedPatterns(false))
  if not matched then
    -- Miss against the cache, possible new pattern
    -- Refresh once and retry before giving up.
    matched, copies = findMatchOnce(getCachedPatterns(true))
  end
  if not matched then
    local stockDescription = {}
    for key, amount in pairs(stock) do
      table.insert(stockDescription, key .. " x" .. amount)
    end
    fatalError("Input Subnet has items but no recipe pattern matches (possible mixed recipe): "
      .. table.concat(stockDescription, ", "))
  end

  local outputLabel = stripFormatting(matched.outputs and matched.outputs[1] and matched.outputs[1].label or "?")
  return { copies = copies, name = outputLabel }
end

-- Returns how many items (excluding the "Input" marker) are currently in
-- Input Subnet, or nil if the interface couldn't be reached.
local function getInputSubnetItemCount()
  local inputAddress, inputProxy = getInputInterface()
  if not inputAddress then return nil end
  local ok, items = pcall(inputProxy.getItemsInNetwork)
  if not ok or not items then return nil end
  local count = 0
  for _, item in pairs(items) do
    if item.label ~= "Input" then
      count = count + item.size
    end
  end
  return count
end

local function waitForRecipe()
  setPhase("Waiting for recipe")
  while true do
    local recipe = tryIdentifyRecipe()
    if recipe then return recipe end
    os.sleep(RECIPE_POLL_INTERVAL)
  end
end

-- ============================================================
-- Step 2: split parallels across nodes (minimize max load per node)
-- ============================================================

local function splitParallels(totalCopies, nodeAddresses)
  local nodesUsed = math.min(totalCopies, #nodeAddresses, MAX_NODES)
  local base = math.floor(totalCopies / nodesUsed)
  local remainder = totalCopies % nodesUsed

  local assignments = {}
  for i = 1, nodesUsed do
    local count = base
    if i <= remainder then count = count + 1 end
    table.insert(assignments, { address = nodeAddresses[i], count = count })
  end
  return assignments
end

-- ============================================================
-- Step 3: gate check
-- ============================================================

local function checkGate(entanglerProxy, storageProxy)
  local hasWorkOk, hasWork = pcall(entanglerProxy.hasWork)
  local activeOk, active = pcall(entanglerProxy.isMachineActive)
  local entanglerIdle = hasWorkOk and (not hasWork) and activeOk and (not active)

  local inputAddress, inputProxy = getInputInterface()
  local fluidsOk, fluids = false, nil
  if inputProxy then
    fluidsOk, fluids = pcall(inputProxy.getFluidsInNetwork)
  end
  local fluidCount = 0
  if fluidsOk and fluids then
    for _ in pairs(fluids) do fluidCount = fluidCount + 1 end
  end
  local inputEmpty = (fluidCount == 0)

  local condOk, condensate = pcall(storageProxy.getStoredCondensate)
  local hasCondensate = false
  if condOk and condensate then
    for _ in pairs(condensate) do hasCondensate = true break end
  end

  return entanglerIdle and inputEmpty and hasCondensate
end

-- ============================================================
-- Nanite swap
-- ============================================================

local storageBusSide = nil

local function makeNaniteSwapper()
  local transposerAddress, fillSide, drainSide = findNaniteTransposer()
  if not transposerAddress then
    return nil, "could not find nanite-swap transposer"
  end
  local transposer = component.proxy(transposerAddress)
  local storageBusAddress, storageBus = findStorageBus()
  if not storageBusAddress then
    return nil, "could not find me_storagebus"
  end

  local function moveTo(targetSide)
    local driveSide = findDriveSide(transposer, fillSide, drainSide)
    if not driveSide then return false, "drive not found in slot 7" end
    if driveSide == targetSide then return true end
    local ok, err = pcall(transposer.transferItem, driveSide, targetSide, 1, IO_PORT_SLOT, 1)
    if not ok then return false, "transfer failed: " .. tostring(err) end
    os.sleep(SWAP_SETTLE_TIME)
    return true
  end

  local function swapToTier(tierName)
    local fillOk, fillErr = moveTo(fillSide)
    if not fillOk then return false, "move to FillDrive: " .. tostring(fillErr) end
    local filterOk, filterResult = pcall(storageBus.setStorageOreFilter, storageBusSide, tierName)
    if not filterOk then return false, "setStorageOreFilter: " .. tostring(filterResult) end
    local drainOk, drainErr = moveTo(drainSide)
    if not drainOk then return false, "move to EmptyDrive: " .. tostring(drainErr) end
    return true
  end

  local function emptyWithoutRefill()
    local ok1, err1 = moveTo(fillSide)
    if not ok1 then return false, err1 end
    local filterOk, filterResult = pcall(storageBus.setStorageOreFilter, storageBusSide, BLOCK_FILTER)
    if not filterOk then return false, "setStorageOreFilter: " .. tostring(filterResult) end
    local ok2, err2 = moveTo(drainSide)
    if not ok2 then return false, err2 end
    return true
  end

  return { swapToTier = swapToTier, emptyWithoutRefill = emptyWithoutRefill }
end

-- ============================================================
-- Output shuttle + redstone pulse
-- ============================================================

local function shipOutputToMainnet()
  local transposerAddress, dummySide, restSide = findOutputTransposer()
  if not transposerAddress then
    return false, "could not find output transposer"
  end
  local transposer = component.proxy(transposerAddress)

  local driveSide = findDriveSide(transposer, dummySide, restSide)
  if not driveSide then return false, "output drive not found in slot 7" end

  if driveSide ~= dummySide then
    local ok, err = pcall(transposer.transferItem, driveSide, dummySide, 1, IO_PORT_SLOT, 1)
    if not ok then return false, "move to dummy side failed: " .. tostring(err) end
  end
  os.sleep(OUTPUT_SETTLE_TIME)
  local nowSide = findDriveSide(transposer, dummySide, restSide)
  if nowSide and nowSide ~= restSide then
    local ok, err = pcall(transposer.transferItem, nowSide, restSide, 1, IO_PORT_SLOT, 1)
    if not ok then return false, "move back to resting side failed: " .. tostring(err) end
  end
  os.sleep(OUTPUT_SETTLE_TIME)
  return true
end

local function pulseRedstoneReturnDrives()
  local address, rs = findRedstone()
  if not address then return false, "no redstone component found" end
  local NSEW = {
    [sides.north] = 15, [sides.south] = 15,
    [sides.east] = 15, [sides.west] = 15,
  }
  local NSEW_OFF = {
    [sides.north] = 0, [sides.south] = 0,
    [sides.east] = 0, [sides.west] = 0,
  }
  local onOk, onErr = pcall(rs.setOutput, NSEW)
  if not onOk then return false, "setOutput high failed: " .. tostring(onErr) end
  os.sleep(REDSTONE_PULSE_DURATION)
  local offOk, offErr = pcall(rs.setOutput, NSEW_OFF)
  if not offOk then return false, "setOutput low failed: " .. tostring(offErr) end
  return true
end

-- ============================================================
-- Startup checks
-- ============================================================

local function resetAllIoNodesOff()
  local count = 0
  for address in component.list("bec_io_node", true) do
    pcall(component.proxy(address).setWorkAllowed, false)
    count = count + 1
  end
  if count == 0 then fatalError("no IONodes found") end
  log(LEVEL.DEBUG, "Disabled " .. count .. " IONode(s) at startup.")
end

-- Tries every side, writing BLOCK_FILTER and reading it back to confirm
-- which one actually took - that's the real side for this build, and
-- this call already needed to write BLOCK_FILTER at startup anyway.
local function resetStorageBusFilter()
  local address, bus = findStorageBus()
  if not address then fatalError("could not find me_storagebus at startup") end
  for side = 0, 5 do
    local setOk = pcall(bus.setStorageOreFilter, side, BLOCK_FILTER)
    if setOk then
      local getOk, filter = pcall(bus.getStorageOreFilter, side)
      if getOk and filter == BLOCK_FILTER then
        storageBusSide = side
        log(LEVEL.DEBUG, "Storage bus side detected: " .. side)
        return
      end
    end
  end
  fatalError("could not determine which side the storage bus is on")
end

local function driveHasItems(stack)
  return stack.getAvailableItems ~= nil and next(stack.getAvailableItems) ~= nil
end

local function verifyNaniteDriveReady()
  local transposerAddress, fillSide, drainSide = findNaniteTransposer()
  if not transposerAddress then fatalError("could not find nanite-swap transposer at startup") end
  local transposer = component.proxy(transposerAddress)
  local drive
  for _, side in ipairs({ fillSide, drainSide }) do
    local ok, stack = pcall(transposer.getStackInSlot, side, IO_PORT_SLOT)
    if ok and stack then drive = stack end
  end
  if not drive then fatalError("no drive found in the nanite-swap transposer at startup") end
  if not driveHasItems(drive) then fatalError("nanite drive is empty at startup") end
end

local function verifyOutputDriveReady()
  local transposerAddress, dummySide, restSide = findOutputTransposer()
  if not transposerAddress then fatalError("could not find output transposer at startup") end
  local transposer = component.proxy(transposerAddress)
  local drive
  for _, side in ipairs({ dummySide, restSide }) do
    local ok, stack = pcall(transposer.getStackInSlot, side, IO_PORT_SLOT)
    if ok and stack then drive = stack end
  end
  if not drive then fatalError("no drive found in the output transposer at startup") end
  if driveHasItems(drive) then fatalError("output drive is not empty at startup") end
end

-- ============================================================
-- One full cycle
-- ============================================================

local function runOneCycle()
  status.recipeName = nil
  status.recipeCopies = nil
  status.currentTier = nil
  render()

  local recipe = waitForRecipe()
  local batchStartUptime = computer.uptime()
  status.recipeName = recipe.name
  status.recipeCopies = recipe.copies
  logSeparator()
  log(LEVEL.INFO, recipe.name .. " x" .. recipe.copies)

  setPhase("Splitting parallels")
  local allNodes = findAllIoNodes()
  if #allNodes == 0 then fatalError("no IONodes found") end
  local assignments = splitParallels(recipe.copies, allNodes)
  for _, a in ipairs(assignments) do
    log(LEVEL.DEBUG, "assign " .. a.address .. " -> " .. a.count)
  end

  setPhase("Waiting for Entangler")
  log(LEVEL.INFO, "Entangling fluids...")
  local entanglerAddress, entanglerProxy = findGtMachineByName("multi.bec.generator")
  if not entanglerAddress then fatalError("could not find Entangler (multi.bec.generator)") end
  local storageAddress, storageProxy = findBecStorage()
  if not storageAddress then fatalError("could not find bec_storage") end

  while not checkGate(entanglerProxy, storageProxy) do
    os.sleep(GATE_POLL_INTERVAL)
  end

  setPhase("Starting IONodes")
  log(LEVEL.INFO, "Starting " .. #assignments .. "x IONodes")
  for _, a in ipairs(assignments) do
    local node = component.proxy(a.address)
    local minOk = pcall(node.setMinParallel, a.count)
    local maxOk = pcall(node.setMaxParallel, a.count)
    if not minOk or not maxOk then
      log(LEVEL.WARN, a.address .. " failed to set parallel count to " .. a.count)
    end
  end
  for _, a in ipairs(assignments) do
    local node = component.proxy(a.address)
    local ok = pcall(node.setWorkAllowed, true)
    if not ok then
      log(LEVEL.WARN, a.address .. " failed to enable work.")
    end
  end

  local pending = {}
  for _, a in ipairs(assignments) do pending[a.address] = true end
  local waited = 0
  while next(pending) and waited < NODE_STARTUP_TIMEOUT do
    for address in pairs(pending) do
      local node = component.proxy(address)
      local ok, hasWork = pcall(node.hasWork)
      if ok and hasWork then
        pcall(node.setWorkAllowed, false)
        pending[address] = nil
        log(LEVEL.DEBUG, address .. " picked up work, disabled.")
      end
    end
    if next(pending) then
      os.sleep(NODE_STARTUP_POLL_INTERVAL)
      waited = waited + NODE_STARTUP_POLL_INTERVAL
    end
  end
  if next(pending) then
    local stuck = {}
    for address in pairs(pending) do table.insert(stuck, address) end
    fatalError(#stuck .. " IONode(s) never picked up work within " .. NODE_STARTUP_TIMEOUT .. "s: "
      .. table.concat(stuck, ", "))
  end

  setPhase("Crafting")
  log(LEVEL.INFO, "Crafting...")
  local swapper, swapperErr = makeNaniteSwapper()
  if not swapper then fatalError(tostring(swapperErr)) end

  -- Reference node: one with the highest assigned count (the "slow" group)
  table.sort(assignments, function(x, y) return x.count > y.count end)
  local referenceAddress = assignments[1].address
  local referenceNode = component.proxy(referenceAddress)
  log(LEVEL.DEBUG, "Reference node: " .. referenceAddress .. " (" .. assignments[1].count .. ")")

  local currentlyProvidedTier = nil
  local tierSwapFailureSeconds = 0
  while true do
    local allDone = true
    for _, a in ipairs(assignments) do
      local node = component.proxy(a.address)
      local ok, hasWork = pcall(node.hasWork)
      if not (ok and not hasWork) then
        allDone = false
        break
      end
    end
    if allDone then
      local elapsed = math.floor(computer.uptime() - batchStartUptime)
      local minutes = math.floor(elapsed / 60)
      local seconds = elapsed % 60
      log(LEVEL.INFO, string.format("Recipe finished processing in %02d:%02d", minutes, seconds))
      break
    end

    local reqOk, required = pcall(referenceNode.getRequiredTier)
    if reqOk and required and required.tier and required.tier ~= currentlyProvidedTier then
      local tierName = TIERS_IN_ORDER[required.tier]
      if tierName then
        log(LEVEL.DEBUG, "Required tier changed -> " .. tierName)
        local ok, err = swapper.swapToTier(tierName)
        if ok then
          currentlyProvidedTier = required.tier
          status.currentTier = humanizeTierName(required.name)
          tierSwapFailureSeconds = 0
          render()
        else
          log(LEVEL.WARN, "swap FAILED: " .. tostring(err))
          tierSwapFailureSeconds = tierSwapFailureSeconds + NANITE_POLL_INTERVAL
        end
      else
        log(LEVEL.WARN, "Reference node requires unrecognized tier index "
          .. tostring(required.tier) .. " - cannot supply nanites.")
        tierSwapFailureSeconds = tierSwapFailureSeconds + NANITE_POLL_INTERVAL
      end
      if tierSwapFailureSeconds >= TIER_SWAP_FAILURE_TIMEOUT then
        fatalError("nanite tier swap has failed repeatedly for "
          .. TIER_SWAP_FAILURE_TIMEOUT .. "s - giving up.")
      end
    end

    os.sleep(NANITE_POLL_INTERVAL)
  end

  setPhase("Emptying nanite bus")
  local emptyOk, emptyErr = swapper.emptyWithoutRefill()
  if not emptyOk then fatalError("emptying nanite bus subnet: " .. tostring(emptyErr)) end
  status.currentTier = nil
  log(LEVEL.DEBUG, "Nanite bus subnet emptied.")

  setPhase("Shipping output")
  local shipOk, shipErr = shipOutputToMainnet()
  if not shipOk then fatalError("shipping output: " .. tostring(shipErr)) end
  log(LEVEL.DEBUG, "Output shipped to mainnet.")

  -- If anything's left in Input Subnet, it wasn't fully consumed
  -- Probably a multiplied pattern
  -- Don't send drives back and risk recipes being combined
  local remaining = getInputSubnetItemCount()
  if remaining == nil then
    fatalError("could not verify Input Subnet is empty after shipping output")
  elseif remaining > 0 then
    fatalError("Input Subnet still has " .. remaining .. " item(s) after shipping output - "
      .. "refusing to return drives to Pending Subnet.")
  end

  setPhase("Returning input drives")
  local pulseOk, pulseErr = pulseRedstoneReturnDrives()
  if not pulseOk then fatalError("redstone pulse: " .. tostring(pulseErr)) end
  log(LEVEL.DEBUG, "Drive-return pulse sent.")
end

-- ============================================================
-- Auto-update
-- ============================================================

local VERSION = 3
local SCRIPT_PATH = "/home/bec_controller.lua"
local SHRC_PATH = "/home/.shrc"
local UPDATE_VERSION_URL = "https://raw.githubusercontent.com/Armisael5/gtnh-bec-controller/main/VERSION"
local UPDATE_SCRIPT_URL = "https://raw.githubusercontent.com/Armisael5/gtnh-bec-controller/main/bec_controller.lua"

-- .shrc runs automatically whenever a shell starts, including at boot. If
-- this script isn't already registered there, add it - so running it once
-- after downloading is all a user has to do to get auto-run on future boots.
local function ensureAutorun()
  local content = ""
  local readFile = io.open(SHRC_PATH, "r")
  if readFile then
    content = readFile:read("*a") or ""
    readFile:close()
  end
  if content:find(SCRIPT_PATH, 1, true) then return end

  local appendFile = io.open(SHRC_PATH, "a")
  if not appendFile then
    log(LEVEL.WARN, "couldn't register autorun in " .. SHRC_PATH)
    return
  end
  appendFile:write(SCRIPT_PATH .. "\n")
  appendFile:close()
  log(LEVEL.DEBUG, "Registered autorun in " .. SHRC_PATH .. " - will start automatically on boot.")
end

local function httpGet(url)
  local internetAddress
  for address in component.list("internet", true) do internetAddress = address end
  if not internetAddress then return nil, "no Internet Card found" end
  local internet = component.proxy(internetAddress)

  local requestOk, handle = pcall(internet.request, url)
  if not requestOk or not handle then
    return nil, "request failed: " .. tostring(handle)
  end

  local chunks = {}
  local attempts = 0
  while true do
    local ok, chunk, reason = pcall(handle.read)
    if ok then
      if not chunk then
        pcall(handle.close)
        return table.concat(chunks)
      end
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

-- Set instead of acted on directly - the reboot that applies an update has
-- to happen outside any pcall (same rule as os.exit/performShutdown), so
-- this just signals startup() to stop early and let the caller reboot.
local updateApplied = false

local function checkForUpdate()
  local remoteVersionStr, versionErr = httpGet(UPDATE_VERSION_URL)
  if not remoteVersionStr then
    log(LEVEL.DEBUG, "update check skipped: " .. tostring(versionErr))
    return
  end
  local remoteVersion = tonumber(remoteVersionStr:match("%d+"))
  if not remoteVersion or remoteVersion <= VERSION then
    log(LEVEL.DEBUG, "up to date (v" .. VERSION .. ").")
    return
  end

  log(LEVEL.WARN, "update available: v" .. VERSION .. " -> v" .. remoteVersion .. ", downloading...")
  local newScript, scriptErr = httpGet(UPDATE_SCRIPT_URL)
  if not newScript or #newScript == 0 then
    log(LEVEL.WARN, "update download failed: " .. tostring(scriptErr))
    return
  end

  local file = io.open(SCRIPT_PATH, "w")
  if not file then
    log(LEVEL.WARN, "update failed: could not open " .. SCRIPT_PATH .. " for writing")
    return
  end
  file:write(newScript)
  file:close()

  log(LEVEL.WARN, "updated to v" .. remoteVersion .. " - rebooting to apply.")
  updateApplied = true
end

-- ============================================================
-- Persistent loop
-- ============================================================

local function startup()
  setPhase("Starting Up (Registering Autorun)")
  ensureAutorun()

  setPhase("Starting Up (Checking for Updates)")
  checkForUpdate()
  if updateApplied then return end

  setPhase("Starting Up (Syncing Real Time)")
  syncRealTime()

  log(LEVEL.DEBUG, "BEC Controller starting.")

  setPhase("Starting Up (Disabling IONodes)")
  resetAllIoNodesOff()

  setPhase("Starting Up (Resetting Nanite Filter)")
  resetStorageBusFilter()

  setPhase("Starting Up (Verifying Nanite Drive)")
  verifyNaniteDriveReady()

  setPhase("Starting Up (Verifying Output Drive)")
  verifyOutputDriveReady()

  setPhase("Starting Up (Caching Recipe Patterns)")
  getCachedPatterns(false) -- cache patterns once at startup
end

local startupOk, startupErr = pcall(startup)
if not startupOk then
  if isInterrupted(startupErr) then
    performShutdown()
  else
    fatalError("unexpected error during startup: " .. tostring(startupErr))
  end
elseif updateApplied then
  pcall(function() logFile:close() end)
  computer.shutdown(true)
end

while true do
  local ok, err = pcall(runOneCycle)
  if not ok then
    if isInterrupted(err) then
      performShutdown()
    else
      fatalError("unexpected error: " .. tostring(err))
    end
  end
end
