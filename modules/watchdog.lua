---@class modules.watchdog
---@field interface modules.watchdog.interface
return {
  id = "watchdog",
  version = "1.0.0",
  config = {
    watchdog = {
      type = "string",
      description = "Watch Dog Timer to use",
    },
    timeout = {
      type = "number",
      description = "How long without any activity before the system resets. Measured in ticks",
      default = 20*30,
    },
    enabled = {
      type = "boolean",
      description = "Enable the Watch Dog Timer",
      default = false
    }
  },
  setup = function (moduleConfig)
    print("Autodetecting watch dog")
    local watchdogp = peripheral.getName(peripheral.find("tm_wdt", function (name, _)
      -- If the name does not contain tm_wdt then it's directly attached.
      if string.find(name, 'tm_wdt') == nil then
        return true
      end
      end))
    -- TODO: Make this able to handle having multiple watchdogs attached.
    if watchdogp ~= nil then
      print(textutils.serialise(watchdogp))
      moduleConfig.watchdog.value = watchdogp
    else
      print("No watch dog found")
      -- force disable if no watch dog found
      moduleConfig.enabled.value = false
    end
  end,
  init = function(loaded, config)
    ---@class modules.watchdog.interface
    return {
      start = function()
        local wdt = nil
        if config.watchdog.enabled.value == true then
          wdt = peripheral.wrap(config.watchdog.watchdog.value)
          wdt.setTimeout(config.watchdog.timeout.value)
          wdt.setEnabled(true)
        end
        while true do
          -- sleep for half of the watch dog timeout
          sleep(config.watchdog.timeout.value / 20 / 2)
          if config.watchdog.enabled.value == true then
            wdt.reset()
          end
        end
      end
    }
  end
}