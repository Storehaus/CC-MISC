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
    if log then
      ailLogger = loaded.logger.interface.logger("inventory", "abstractInvLib")
    end
    ailLogger = config.inventory.logAIL.value and ailLogger
    local storage
    if ailLogger then
      storage = require("abstractInvLib")(inventories, nil, { redirect = function(s) ailLogger:debug(s) end })
    else
      storage = require("abstractInvLib")(inventories, nil)
    end
    storage.setBatchLimit(config.inventory.executeLimit.value)
    local transferQueue = {}
    local transferTimer
    local inventoryLock = false

    ---Signal the system to perform a transfer
    local function performTransfer()
      if transferTimer then
        os.cancelTimer(transferTimer)
        transferTimer = nil
      end
      os.queueEvent("_performTransfer")
    end

    local function defrag()
      inventoryLock = true
      storage.defrag()
      inventoryLock = false
    end

    ---Queue handling function
    ---Waits to do an optimal transfer of the whole queue
    local function queueHandler()
      local logger = setmetatable({}, {
        __index = function()
          return function()
          end
        end
      })
      if log then
        logger = loaded.logger.interface.logger("inventory", "queueHandler")
      end
      if #transferQueue > 0 then
        performTransfer()
      end
      while true do
        os.pullEvent("_performTransfer")
        if transferTimer then
          os.cancelTimer(transferTimer)
          transferTimer = nil
        end
        while inventoryLock do
          os.sleep(0)
        end
        if logger then
          logger:debug("Starting transfer")
        end
        local transferQueueCopy = { table.unpack(transferQueue) }
        transferQueue = {}
        for _, v in pairs(transferQueueCopy) do
          local transfer = v
          logger:debug("Transfer %s %s %s %s %s %s %s %s", table.unpack(transfer))
          local retVal = table.pack(pcall(function() return storage[transfer[2]](table.unpack(transfer, 3, transfer.n)) end))
          if not retVal[1] then
            logger:error("Transfer %s %s failed with %s", transfer[1], transfer[2], retVal[2])
            error(retVal[2])
          end
          logger:debug("Transfer %s %s finished, returned %s", transfer[1], transfer[2], retVal[2])
          os.queueEvent("inventoryFinished", transfer[1], table.unpack(retVal, 2))
        end
        if config.inventory.defragEachTransfer.value then
          defrag()
        end
        os.queueEvent("inventoryUpdate", storage.list())
        if #transferQueue > 0 then
          performTransfer()
        end
      end
    end

    ---Handles timers
    local function timerHandler()
      while true do
        local e, id = os.pullEvent("timer")
        if id == transferTimer then
          performTransfer()
        end
      end
    end

    ---Add the given arguments to the queue
    ---@param id string
    ---@param ... any
    local function addToQueue(id, ...)
      table.insert(transferQueue, table.pack(id, ...))
      if (#transferQueue > config.inventory.flushLimit.value) then
        performTransfer()
      elseif not transferTimer then
        transferTimer = os.startTimer(config.inventory.flushTimer.value)
      end
    end

    ---Generate a pseudo random ID
    ---@return string
    local function getID()
      return tostring({})
    end

    ---Add the given arguments to the queue, generating an id
    ---@param ... any
    ---@return string
    local function queueAction(...)
      local id = getID()
      addToQueue(id, ...)
      return id
    end

    ---Push items to an inventory
    ---@param async boolean|nil
    ---@param targetInventory string|AbstractInventory|Inventory
    ---@param name string|number
    ---@param amount nil|number
    ---@param toSlot nil|number
    ---@param nbt nil|string
    ---@param options nil|TransferOptions
    ---@return integer|string count event name in case of async
    local function pushItems(async, targetInventory, name, amount, toSlot, nbt, options)
      if async then
        return queueAction("pushItems", targetInventory, name, amount, toSlot, nbt, options)
      end
      performTransfer()
      
      -- WORKAROUND: Split exactly 64 into two moves to bypass the library bug
      if amount == 64 or amount == 16 then
          local first = storage.pushItems(targetInventory, name, amount-1, toSlot, nbt, options)
          local second = storage.pushItems(targetInventory, name, 1, toSlot, nbt, options)
          return first + second
      end
      
      return storage.pushItems(targetInventory, name, amount, toSlot, nbt, options)
    end

    ---Pull items from an inventory
    ---@param async boolean|nil
    ---@param fromInventory string|AbstractInventory|Inventory
    ---@param fromSlot string|number
    ---@param amount nil|number
    ---@param toSlot nil|number
    ---@param nbt nil|string
    ---@param options nil|TransferOptions
    ---@return integer|string count event name in case of async
    local function pullItems(async, fromInventory, fromSlot, amount, toSlot, nbt, options)
      if async then
        return queueAction("pullItems", fromInventory, fromSlot, amount, toSlot, nbt, options)
      end
      performTransfer()
      return storage.pullItems(fromInventory, fromSlot, amount, toSlot, nbt, options)
    end

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
    module.pushItems = pushItems
    module.pullItems = pullItems
    module.defrag = defrag
    module.start = function()
      parallel.waitForAny(queueHandler, timerHandler)
    end
    module.gui = function(frame)
      frame:addLabel():setPosition(2, 2):setText("Transfer Queue Length:")
      local queueSizeLabel = frame:addLabel():setPosition(2, 3):setFontSize(3)
      frame:addButton():setPosition(2, 11):setSize("parent.w-2", 3):setText("Flush Queue"):onClick(performTransfer)
      frame:addButton():setPosition(2, 15):setSize("parent.w-2", 3):setText("Clear Queue"):onClick(function()
        transferQueue = {}
      end)
      frame:addThread():start(function()
        while true do
          os.pullEvent()
          queueSizeLabel:setText(#transferQueue)
        end
      end)
    end
    module.performTransfer = performTransfer

    return module
  end,
}
