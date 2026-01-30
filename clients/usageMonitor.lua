-- Settings Setup
local monitorSide
if not settings.get("misc.monitor") then
  settings.define("misc.monitor", { description = "Monitor side to display on.", type = "string" })
  print("What side is the monitor on?")
  monitorSide = read()
  settings.set("misc.monitor", monitorSide)
  settings.save()
end

local wirelessMode = fs.exists("websocketLib.lua")
if wirelessMode and not settings.get("misc.websocketURL") then
  settings.define("misc.websocketURL",{ description = "URL of the websocket to use for wireless communication", type = "string" })
  print("Enter the URL of the websocket relay service you would like to use.")
  settings.set("misc.websocketURL", read())
  settings.save()
end


if not settings.get("misc.style") then
  settings.define("misc.style", { description = "Display style: horizontal, vertical, big, text, pie", type = "string" })
  print("Choose display style (horizontal, vertical, big, text, pie):")
  local s = read()
  if s == "" then s = "horizontal" end
  settings.set("misc.style", s)
  settings.save()
end


if not settings.get("misc.scale") then
  settings.define("misc.scale", { description = "Text scale (0.5 to 5)", type = "number" })
  print("Enter text scale (default 0.5):")
  local s = read()
  local n = tonumber(s)
  if not n then n = 0.5 end
  settings.set("misc.scale", n)
  settings.save()
end

if not settings.get("misc.percentageCutoff") and settings.get("misc.style") == "pie" then
  settings.define("misc.percentageCutoff", { description = "Percentage cutoff (1 to 100)", type = "number" })
  print("Enter percentage cutoff (default 5):")
  local s = read()
  local n = tonumber(s) / 100
  if not n then n = 0.1 end
  settings.set("misc.percentageCutoff", n)
  settings.save()
end


if not settings.get("misc.theme") then
  settings.define("misc.theme", { description = "Display theme: light, dark", type = "string" })
  print("Choose display theme (light, dark):")
  local t = read()
  if t == "" then t = "light" end
  settings.set("misc.theme", t)
  settings.save()
end

settings.load()

-- Peripheral Setup
monitorSide = settings.get("misc.monitor")
local monitor = assert(peripheral.wrap(monitorSide), "Invalid monitor")
local textScale = settings.get("misc.scale")

-- Library Setup
local lib
if not wirelessMode then
  lib = require("modemLib")
  local modem = peripheral.getName(peripheral.find("modem"))
  lib.connect(modem)
else
  lib = require("websocketLib")
  local websocket = settings.get("misc.websocketURL")
  lib.connect(websocket)
end

-- Configuration Colors
local currentTheme = settings.get("misc.theme") or "light"

local function setThemeColors()
  if currentTheme == "dark" then
    -- Dark theme: pure black background, light text
    return {
      labelFG = colors.white,
      labelBG = colors.black,
      usedBG = colors.red,
      freeBG = colors.gray,
      alertColor = colors.orange,
      pieColors = {colors.blue, colors.green, colors.orange, colors.purple, colors.cyan, colors.yellow, colors.lime, colors.pink},
      otherColor = colors.lightGray
    }
  else
    -- Light theme: pure white background, dark text
    return {
      labelFG = colors.black,
      labelBG = colors.white,
      usedBG = colors.red,
      freeBG = colors.gray,
      alertColor = colors.orange,
      pieColors = {colors.blue, colors.green, colors.orange, colors.purple, colors.cyan, colors.yellow, colors.lime, colors.pink},
      otherColor = colors.lightGray
    }
  end
end

local colorsConfig = setThemeColors()
local labelFG = colorsConfig.labelFG
local labelBG = colorsConfig.labelBG
local usedBG = colorsConfig.usedBG
local freeBG = colorsConfig.freeBG
local alertColor = colorsConfig.alertColor
local pieColors = colorsConfig.pieColors
local otherColor = colorsConfig.otherColor

-- Custom Font Definition
local bigFont = {
  ["0"] = {
    "  ___  ",
    " / _ \\ ",
    "| | | |",
    "| |_| |",
    " \\___/ "
  },
  ["1"] = {
    "  _  ",
    " / | ",
    " | | ",
    " | | ",
    " |_| "
  },
  ["2"] = {
    "  ____  ",
    " |___ \\ ",
    "  __) | ",
    " / __/  ",
    "|_____| "
  },
  ["3"] = {
    " _____ ",
    "|___ / ",
    "  |_ \\ ",
    " ___) |",
    "|____/ "
  },
  ["4"] = {
    " _  _   ",
    "| || |  ",
    "| || |_ ",
    "|__  _| ",
    "   |_|  "
  },
  ["5"] = {
    " ____  ",
    "| ___| ",
    "|___ \\ ",
    " ___) |",
    "|____/ "
  },
  ["6"] = {
    "  __   ",
    " / /_  ",
    "| '_ \\ ",
    "| (_) |",
    " \\___/ "
  },
  ["7"] = {
    " _____ ",
    "|___  |",
    "  / /  ",
    " / /   ",
    "/_/    "
  },
  ["8"] = {
    "  ___  ",
    " ( _ ) ",
    " / _ \\ ",
    "| (_) |",
    " \\___/ "
  },
  ["9"] = {
    "  ___  ",
    " / _ \\ ",
    "| (_) |",
    " \\__, |",
    "   /_/ "
  },
  ["%"] = {
    " _  __",
    "(_)/ /",
    "  / / ",
    " / /_ ",
    "/_/(_)"
  }
}

-- Drawing Helpers
local function setColors(fg, bg)
  monitor.setTextColor(fg)
  monitor.setBackgroundColor(bg)
end

local function fillRect(x, y, width, height, char)
  local str = string.rep(char or " ", width)
  for i = 0, height - 1 do
    monitor.setCursorPos(x, y + i)
    monitor.write(str)
  end
end

local function centerText(y, text)
  local w, _ = monitor.getSize()
  monitor.setCursorPos(math.floor((w - #text) / 2) + 1, y)
  monitor.write(text)
end

local function getPercentage(usage)
  if usage.total == 0 then return 0 end
  return usage.used / usage.total
end

-- Renders the custom ASCII font
local function drawBigNumbers(text, startY, fg, bg)
  setColors(fg, bg)
  -- Calculate total width first to center
  local totalWidth = 0
  local charGrids = {}
  
  for i = 1, #text do
    local c = string.sub(text, i, i)
    local grid = bigFont[c] or bigFont["0"]
    table.insert(charGrids, grid)
    totalWidth = totalWidth + #grid[1]
  end
  
  -- Add spacing
  totalWidth = totalWidth + (#charGrids - 1)
  
  local w, _ = monitor.getSize()
  local startX = math.floor((w - totalWidth) / 2) + 1
  
  local currentX = startX
  for _, grid in ipairs(charGrids) do
    for r = 1, #grid do
      monitor.setCursorPos(currentX, startY + r - 1)
      monitor.write(grid[r])
    end
    currentX = currentX + #grid[1] + 1
  end
end

-- Style Definitions
local styles = {}

-- 1. Original Horizontal Bar
styles.horizontal = function(usage, w, h)
  local barH = h - 2
  if barH < 1 then barH = 1 end

  -- Header
  setColors(labelFG, labelBG)
  monitor.clear()
  local slots = string.format("Total %u", usage.total)
  centerText(1, slots)

  -- Footer Stats
  local used = string.format("Used %u", usage.used)
  monitor.setCursorPos(1, h)
  monitor.write(used)

  local free = string.format("Free %u", usage.free)
  monitor.setCursorPos(w - #free + 1, h)
  monitor.write(free)

  -- The Bar
  local pct = getPercentage(usage)
  local usedWidth = math.floor(pct * w)
  
  setColors(labelFG, usedBG)
  fillRect(1, 2, usedWidth, barH)
  setColors(labelFG, freeBG)
  fillRect(usedWidth + 1, 2, w - usedWidth, barH)
end

-- 2. Vertical Bar (Cloned style, vertical graph)
styles.vertical = function(usage, w, h)
  local barH = h - 2
  if barH < 1 then barH = 1 end
  
  setColors(labelFG, labelBG)
  monitor.clear()

  -- Header
  local slots = string.format("Total %u", usage.total)
  centerText(1, slots)
  
  -- Footer Stats
  local used = string.format("Used %u", usage.used)
  local free = string.format("Free %u", usage.free)
  
  -- If narrow, stack used/free, otherwise put on same line
  if (w < #used + #free + 2) then
    monitor.setCursorPos(1, h-1)
    monitor.write(used)
    monitor.setCursorPos(1, h)
    monitor.write(free)
    barH = barH - 1 -- Reduce bar height for extra text line
  else
    monitor.setCursorPos(1, h)
    monitor.write(used)
    monitor.setCursorPos(w - #free + 1, h)
    monitor.write(free)
  end

  -- The Vertical Bar
  local pct = getPercentage(usage)
  local usedHeight = math.floor(pct * barH)
  local freeHeight = barH - usedHeight

  -- Draw Free (Top part of bar)
  setColors(labelFG, freeBG)
  fillRect(1, 2, w, freeHeight)
  
  -- Draw Used (Bottom part of bar)
  setColors(labelFG, usedBG)
  fillRect(1, 2 + freeHeight, w, usedHeight)
end

-- 3. Big Text (Custom Font)
styles.big = function(usage, w, h)
  local pct = getPercentage(usage)
  
  local bg = freeBG
  if pct > 0.75 then bg = usedBG 
  elseif pct > 0.5 then bg = alertColor end

  -- Use theme-aware text color
  local textColor = currentTheme == "dark" and colors.white or colors.black
  setColors(textColor, bg)
  monitor.clear()

  local text = string.format("%d%%", math.floor(pct * 100))
  
  -- Center vertically (font is 5 high)
  local fontY = math.floor((h - 5) / 2) + 1
  drawBigNumbers(text, fontY, textColor, bg)
  
  -- Subtext
  monitor.setTextScale(0.5)
  local w2, h2 = monitor.getSize()
  setColors(textColor, bg)
  centerText(h2, string.format("%u / %u", usage.used, usage.total))
  monitor.setTextScale(textScale)
end

-- 4. Text List (Detailed info)
styles.text = function(usage, w, h)
  setColors(labelFG, labelBG)
  monitor.clear()
  
  local lines = {
    "--- STATUS ---",
    "",
    "Total: " .. usage.total,
    "Used:  " .. usage.used,
    "Free:  " .. usage.free,
    ""
  }
  
  local pct = getPercentage(usage)
  table.insert(lines, "Full:  " .. math.floor(pct * 100) .. "%")

  local startY = math.floor((h - #lines) / 2) + 1
  if startY < 1 then startY = 1 end

  for i, line in ipairs(lines) do
    monitor.setCursorPos(2, startY + i - 1)
    monitor.write(line)
  end
end

-- 5. Pie Chart (Top Items)
styles.pie = function(usage, w, h)
  setColors(labelFG, labelBG)
  monitor.clear()

  -- Draw Header and Footer Stats
  local slots = string.format("Total %u", usage.total)
  centerText(1, slots)

  local used = string.format("Used %u", usage.used)
  monitor.setCursorPos(1, h)
  monitor.write(used)

  local free = string.format("Free %u", usage.free)
  monitor.setCursorPos(w - #free + 1, h)
  monitor.write(free)
  
  if not usage.items then
    centerText(math.floor(h/2), "No item data")
    return
  end

  -- Calculate Total Item Count from items list for accurate percentages
  local totalItems = 0
  for _, item in ipairs(usage.items) do
    totalItems = totalItems + (item.count or 0)
  end

  if totalItems == 0 then
    centerText(math.floor(h/2), "Inventory Empty")
    return
  end

  -- Sort items by count desc
  table.sort(usage.items, function(a,b) return (a.count or 0) > (b.count or 0) end)

  -- Create Slices (threshold 10%)
  local slices = {}
  local otherCount = 0
  local colorIdx = 1

  for _, item in ipairs(usage.items) do
    local pct = item.count / totalItems
    if pct >= settings.get("misc.percentageCutoff") then
      table.insert(slices, {
        label = item.displayName or item.name or "Unknown",
        pct = pct,
        color = pieColors[colorIdx] or colors.white
      })
      colorIdx = (colorIdx % #pieColors) + 1
    else
      otherCount = otherCount + item.count
    end
  end

  if otherCount > 0 then
    table.insert(slices, {
      label = "Other",
      pct = otherCount / totalItems,
      color = otherColor
    })
  end

  -- Calculate screen geometry
  -- Aspect ratio correction: Circle is drawn 1.5x wider than tall to look round on CC monitors
  
  -- Constrain by height (leave 1 line top/bottom for header/footer)
  -- Usable height = h - 2
  local usableH = h - 2
  if usableH < 1 then usableH = 1 end
  
  local radiusH = usableH / 2
  
  -- Constrain by width (use ~50% of width for pie, leave 50% for legend)
  local radiusW = (w * 0.5) / 3
  
  local radius = math.min(radiusH, radiusW)
  if radius < 2 then radius = 2 end

  local centerX = math.floor(radius * 1.5) + 2 -- Shift right slightly
  local centerY = math.floor(usableH / 2) + 2 -- +2 because y starts at 2 (after header)

  -- Draw Pie
  -- Iterate bounding box of circle
  for y = centerY - radius, centerY + radius do
    for x = centerX - (radius*1.5), centerX + (radius*1.5) do
       local dx = (x - centerX) / 1.5 -- Correct aspect ratio (CC pixels are tall)
       local dy = (y - centerY)
       
       local dist = math.sqrt(dx*dx + dy*dy)
       if dist <= radius then
         -- Calculate Angle (-pi to pi)
         local angle = math.atan2(dy, dx) 
         -- Normalize to 0 to 1
         local normalizedAngle = (angle + math.pi) / (2 * math.pi)
         
         -- Find which slice covers this angle
         local currentPct = 0
         local pixelColor = labelBG
         for _, slice in ipairs(slices) do
            if normalizedAngle >= currentPct and normalizedAngle < (currentPct + slice.pct) then
               pixelColor = slice.color
               break
            end
            currentPct = currentPct + slice.pct
         end
         
         -- Draw only if inside bounds and not overwriting header/footer
         if x >= 1 and x <= w and y >= 2 and y <= h - 1 then
            monitor.setBackgroundColor(pixelColor)
            monitor.setCursorPos(x, y)
            monitor.write(" ")
         end
       end
    end
  end

  -- Draw Legend (Right side)
  local legendX = math.floor(centerX + (radius * 1.5)) + 2
  local legendY = math.floor((usableH - #slices) / 2) + 2
  if legendY < 2 then legendY = 2 end

  if legendX < w then
    for i, slice in ipairs(slices) do
      local yPos = legendY + i - 1
      if yPos <= h - 1 then
        monitor.setCursorPos(legendX, yPos)
        monitor.setBackgroundColor(slice.color)
        monitor.write(" ") -- Color swatch
        monitor.setBackgroundColor(labelBG)
        monitor.setTextColor(labelFG)
        local pctStr = math.floor(slice.pct * 100) .. "%"
        monitor.write(" " .. pctStr .. " " .. slice.label)
      end
    end
  end
end

-- Main Logic
local function writeUsage(providedItems)
  local usage = lib.getUsage()
  
  -- Refresh settings in case they changed while running
  settings.load() 
  local currentStyle = settings.get("misc.style")
  local currentScale = settings.get("misc.scale")
  local currentTheme = settings.get("misc.theme") or "light"

  -- Update theme colors if theme changed
  local newTheme = settings.get("misc.theme") or "light"
  if newTheme ~= currentTheme then
    currentTheme = newTheme
    local colorsConfig = setThemeColors()
    labelFG = colorsConfig.labelFG
    labelBG = colorsConfig.labelBG
    usedBG = colorsConfig.usedBG
    freeBG = colorsConfig.freeBG
    alertColor = colorsConfig.alertColor
    pieColors = colorsConfig.pieColors
    otherColor = colorsConfig.otherColor
  end

  -- If in pie mode, we need item data.
  -- Use providedItems (from update event) or fetch fresh list if missing.
  if currentStyle == "pie" then
    if providedItems then
      usage.items = providedItems
    elseif lib.list then
      -- Fallback for initial render or manual refresh
      -- We wrap in pcall just in case lib.list isn't available/fails
      local ok, res = pcall(lib.list)
      if ok then usage.items = res end
    end
  end
  
  monitor.setTextScale(currentScale)
  local w, h = monitor.getSize()

  local drawFunc = styles[currentStyle] or styles.horizontal
  
  -- Protected call to prevent crashing on drawing errors
  local ok, err = pcall(drawFunc, usage, w, h)
  if not ok then
    -- Use theme-aware colors for error display
    local errorBG = currentTheme == "dark" and colors.black or colors.white
    local errorFG = currentTheme == "dark" and colors.red or colors.red
    monitor.setBackgroundColor(errorBG)
    monitor.clear()
    monitor.setCursorPos(1,1)
    monitor.setTextColor(errorFG)
    print("Draw Error: " .. tostring(err))
    monitor.write("Style Error")
  end
end

local function handleUpdates()
  while true do
    local _, list = os.pullEvent("update")
    writeUsage(list)
  end
end

-- Initial Draw
writeUsage()

-- Loop Setup
local watchdogAvaliable = fs.exists("watchdogLib.lua")
local funcs = {lib.subscribe, handleUpdates}

if watchdogAvaliable then
  local watchdogLib = require '.watchdogLib'
  local wdFunc = watchdogLib.watchdogLoopFromSettings()
  if wdFunc ~= nil then
      funcs[#funcs+1] = wdFunc
  end
end

parallel.waitForAny(table.unpack(funcs))