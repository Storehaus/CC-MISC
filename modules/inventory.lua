local common = require("common")
---@class modules.inventory
---@field interface modules.inventory.interface

---@return string[]
local function getAttachedInventories()
  local attachedInventories = {}
  for _, v in ipairs(peripheral.getNames()) do
    if peripheral.hasType(v, "inventory") then attachedInventories[#attachedInventories + 1] = v end
  end
  return attachedInventories
end

return {
  id = "inventory",
  version = "1.2.4",
  config = {
    inventories = {
      type = "table",
      description = "List of storage peripherals to use for the main storage",
      default = {},
    },
    inventoryAddPatterns = {
      type = "table",
      description = "List of lua patterns, peripheral names that match this pattern will be added to the storage.",
      default = {
        "minecraft:chest_.+",
      },
    },
    inventoryRemovePatterns = {
      type = "table",
      description = "List of lua patterns, peripheral names that match this pattern will be removed from the storage.",
      default = {
        "minecraft:furnace_.+"
      },
    },
    flushTimer = {
      type = "number",
      description = "Time to wait after a transfer is queued before performing the transfers",
      default = 1,
    },
    flushLimit = {
      type = "number",
      description = "Immediately flush the transfer queue when this many transfers are in it",
      default = 5,
    },
    defragOnStart = {
      type = "boolean",
      description = "Defragment the storage on storage system start",
      default = true
    },
    defragEachTransfer = {
      type = "boolean",
      description = "Defragment the storage each time the queue is flushed.",
      default = false
    },
    executeLimit = {
      type = "number",
      description = "Maximum number of transfers for abstractInvLib to execute in parallel.",
      default = 100,
    },
    logAIL = {
      type = "boolean",
      description = "Enable logging for abstractInvLib.",
      default = false
    }
  },
  dependencies = {
    logger = { min = "1.1", optional = true },
  },
  init = function(loaded, config)
    local log = loaded.logger
    local inventories = {}
    for i, v in ipairs(config.inventory.inventories.value) do
      inventories[i] = v
    end
    -- add from patterns
    local attachedInventories = getAttachedInventories()
    for _, v in ipairs(attachedInventories) do
      for _, pattern in ipairs(config.inventory.inventoryAddPatterns.value) do
        if v:match(pattern) then
          inventories[#inventories + 1] = v
        end
      end
    end

    -- remove from patterns
    for i = #inventories, 1, -1 do
      for _, pattern in ipairs(config.inventory.inventoryRemovePatterns.value) do
        if string.match(inventories[i], pattern) then
          table.remove(inventories, i)
        end
      end
    end


    local ailLogger = setmetatable({}, {
      __index = function()
        return function()
        end
      end
    })
    if log and config.inventory.logAIL.value then
      ailLogger = loaded.logger.interface.logger("inventory", "abstractInvLib")
    end
    local storage = require("abstractInvLib")(inventories, nil, { redirect = function(s) ailLogger:debug(s) end })
    storage.setBatchLimit(config.inventory.executeLimit.value)

    if config.inventory.defragOnStart.value then
      print("Defragmenting...")
      local t0 = os.epoch("utc")
      storage.defrag()
      common.printf("Defrag done in %.2f seconds.",
        (os.epoch("utc") - t0) / 1000)
    end

    ---@class modules.inventory.interface : AbstractInventory
    local module = {}
    for k, v in pairs(storage) do
      if k:sub(1, 1) ~= "_" then
        module[k] = v
      end
    end
    module.start = storage.run

    return module
  end,
}
