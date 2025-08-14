-- Watch Dog code is here for clients to be able to use it
if not settings.getDetails("misc.watchdogEnabled") then
  settings.define("misc.watchdogEnabled",
    { description = "Enable the Watch Dog from Tom's Peripherals", type = "boolean" })
  settings.save()
end

if not settings.getDetails("misc.watchdogSide") then
  settings.define("misc.watchdogSide",
    { description = "Side that the Watch Dog is on", type = "string", default = "auto" })
  settings.save()
end

---Determin the watch dog side
---@return string|nil
local function autodetectWatcdogSide()
  local watchdogp = peripheral.getName(peripheral.find("tm_wdt", function(wd_name, _)
    -- If the name does not contain tm_wdt then it's directly attached.
    if string.find(wd_name, 'tm_wdt') == nil then
      return true
    end
  end)
  )
  -- TODO: Make this able to handle having multiple watchdogs attached.
  if watchdogp ~= nil then
    return watchdogp
  else
    print("No watch dog found")
    return nil
  end
end

--- Check if the watch dog is enabled in the settings and has a valid side set
--- @return boolean
local function watchdogEnabled()
  if not settings.get("misc.watchdogEnabled") then
    return false
  else
    if settings.get("misc.watchdogSide") == "auto" then
      if autodetectWatcdogSide() ~= nil then
        return true
      else
        return false
      end
    else
      return true
    end
  end
end

---Loop reseting the watch dog timer
---@param wdSide string|nil side to use. If set to auto or nil then autodetct it.
---@param wdTimeout number|nil watchdog timeout in ticks default is 600
---@param sleepTime number|nil time to sleep in the loop default to half the timeout window
local function watchdogLoop(wdSide, wdTimeout, sleepTime)
  if wdSide == nil or wdSide == "auto" then
    wdSide = autodetectWatcdogSide()
    if wdSide == nil then
      error("No Watch Dog detected")
    end
  end
  if wdTimeout == nil then
    wdTimeout = 600
  end
  if sleepTime == nil then
    sleepTime = wdTimeout / 40
  end
  local wdt = peripheral.wrap(wdSide)
  wdt.setEnabled(false)
  -- Sleep for one tick to prevent a race condition
  sleep(0.05)
  wdt.setTimeout(wdTimeout)
  wdt.setEnabled(true)
  while true do
    sleep(sleepTime)
    wdt.reset()
  end
end

---Loop for use with parallel.waitForAny
---@param allowSetup boolean|nil allow running the setup before the function or nil is returned.
---@return function|nil
local function watchdogLoopFromSettings(allowSetup)
  if allowSetup == nil then
    allowSetup = true
  end
  if allowSetup then
    if settings.get("misc.watchdogEnabled") == nil then
      local completion = require "cc.completion"
      local options = { "yes", "no" }
      print("Do you want to enable the watch dog?")
      write("> ")
      local resp = read(nil, nil, function(text) return completion.choice(text, options) end)
      if resp == "yes" then
        settings.set("misc.watchdogEnabled", true)
      else
        settings.set("misc.watchdogEnabled", false)
      end
      settings.save()
    end
  end
  if watchdogEnabled() then
    local function returnFunc()
      watchdogLoop(settings.get("misc.watchdogSide"))
    end
    return returnFunc
  else
    return nil
  end
end


return {
  watchdogEnabled = watchdogEnabled,
  autodetectWatcdogSide = autodetectWatcdogSide,
  watchdogLoop = watchdogLoop,
  watchdogLoopFromSettings = watchdogLoopFromSettings
}
