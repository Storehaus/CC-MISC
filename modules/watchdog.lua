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
      default = 20 * 30,
    },
    enabled = {
      type = "boolean",
      description = "Enable the Watch Dog Timer",
      default = false
    }
  },
  setup = function(moduleConfig)
    local watchdogLib = require '.watchdogLib'
    print("Autodetecting watch dog")
    local wd_side = watchdogLib.autodetectWatcdogSide()
    if wd_side ~= nil then
      moduleConfig.watchdog.value = wd_side
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
        local watchdogLib = require '.watchdogLib'
        if config.watchdog.enabled.value == true then
          watchdogLib.watchdogLoop(config.watchdog.watchdog.value, config.watchdog.timeout.value)
        else
          -- if the Watch Dog is disabled just empty loop
          while true do
            sleep(60)
          end
        end
      end
    }
  end
}
