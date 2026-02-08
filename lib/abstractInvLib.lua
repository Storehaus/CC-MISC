--- Inventory Abstraction Library
-- Inventory Peripheral API compatible library that caches the contents of chests, and allows for very fast transfers of items between AbstractInventory objects.
-- Transfers can occur from slot to slot, or by item name and nbt data.
-- This can also transfer to / from normal inventories, just pass in the peripheral name.
-- Use {optimal=false} to transfer to / from non-inventory peripherals.

-- Now you can wrap arbritrary slot ranges
-- To do so, rather than passing in the inventory name when constructing (or adding/removing inventories)
-- you simply pass in a table of the following format
-- {name: string, minSlot: integer?, maxSlot: integer?, slots: integer[]?}
-- If slots is provided that overwrites anything in minSlot and maxSlot
-- minSlot defaults to 1, and maxSlot defaults to the inventory size

-- Transfers with this inventory are parallel safe iff
-- * assumeLimits = true
-- * The limits of the abstractInventorys involved have already been cached
--  * refreshStorage() will do this
-- * The transfer is to an abstractInventory, or to an un-optimized peripheral
-- Though keep the 256 event queue limit in mind, as going over it will result in a stalled thread.

-- Copyright 2022 Mason Gulu
-- Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
-- The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

-- Thank PG231 for the improved defrag!

-- Updated 7/22/23 - Support for higher slot limit inventories

-- Updated 4/12/24 - Added .run() and a built in transfer queue system

-- Updated 4/14/24 - Added item allocation

local expect = require("cc.expect").expect

local abstractInventory

local function ate(table, item) -- add to end
  table[#table + 1] = item
end

local function shallowClone(t)
  local ct = {}
  for k, v in pairs(t) do
    ct[k] = v
  end
  return ct
end

---Execute a table of functions in batches
---@param func function[]
---@param skipPartial? boolean Only do complete batches and skip the remainder.
---@param limit integer
---@return function[] skipped Functions that were skipped as they didn't fit.
local function batchExecute(func, skipPartial, limit)
  local batches = #func / limit
  batches = skipPartial and math.floor(batches) or math.ceil(batches)
  for batch = 1, batches do
    local start = ((batch - 1) * limit) + 1
    local batch_end = math.min(start + limit - 1, #func)
    parallel.waitForAll(table.unpack(func, start, batch_end))
  end
  return table.pack(table.unpack(func, 1 + limit * batches))
end

---Safely call an inventory "peripheral"
---@param name string|AbstractInventory|table
---@param func string
---@param ... unknown
---@return unknown
local function call(name, func, ...)
  local args = table.pack(...)
  if (func == "pullItems" or func == "pushItems") and type(args[1]) == "table" then
    assert(type(name) == "string", "Cannot transfer items between two peripheral tables")
    name, args[1] = args[1], name
    if func == "pullItems" then
      func = "pushItems"
    else
      func = "pullItems"
    end
  end
  if type(name) == "string" then
    return peripheral.call(name, func, table.unpack(args, 1, args.n))
  elseif type(name) == "table" then
    return name[func](table.unpack(args, 1, args.n))
  end
  error(("type(name)=%s"):format(type(name)), 2)
end



---Perform an optimal transfer
---@param fromInventory AbstractInventory
---@param toInventory AbstractInventory
---@param from string|integer
---@param amount integer?
---@param toSlot integer?
---@param nbt string?
---@param options TransferOptions
---@param calln number?
---@param executeLimit integer
---@return unknown
local function optimalTransfer(fromInventory, toInventory, from, amount, toSlot, nbt, options, calln, executeLimit)
  local theoreticalAmountMoved = 0
  local actualAmountMoved = 0
  local transferCache = {}
  local badTransfer
  while theoreticalAmountMoved < amount do
    -- find the cachedItem item in fromInventory
    ---@type CachedItem|nil
    local cachedItem
    if type(from) == "number" then
      cachedItem = fromInventory._getGlobalSlot(from)
      if not (cachedItem and cachedItem.item) or fromInventory._isSlotBusy(from) then
        -- this slot is empty
        break
      end
    else
      cachedItem = fromInventory._getItem(from, nbt)
      if not (cachedItem and cachedItem.item) then
        -- no slots with this item
        break
      end
    end
    -- check how many items there are available to move
    local itemsToMove = cachedItem.item.count
    -- find where the item will be put
    local destinationInfo
    if toSlot then
      destinationInfo = toInventory._getGlobalSlot(toSlot)
      if not destinationInfo then
        local info = toInventory._getLookupSlot(toSlot)
        destinationInfo = toInventory._cacheItem(nil, info.inventory, info.slot)
      end
    else
      destinationInfo = toInventory._getSlotWithSpace(cachedItem.item.name, nbt)
      if not destinationInfo then
        local slot, inventory, capacity = toInventory._getEmptySpace()
        if not (slot and inventory) then
          break
        end
        destinationInfo = toInventory._cacheItem(nil, inventory, slot)
      end
    end

    local slotCapacity = toInventory._getRealItemLimit(destinationInfo,
      cachedItem.item.name, cachedItem.item.nbt)
    if destinationInfo.item then
      slotCapacity = slotCapacity - destinationInfo.item.count
    end
    itemsToMove = math.min(itemsToMove, slotCapacity, amount - theoreticalAmountMoved)
    if destinationInfo.item and (destinationInfo.item.name ~= cachedItem.item.name) then
      itemsToMove = 0
    end
    if itemsToMove == 0 then
      break
    end

    -- queue a transfer of that item
    local toInv, fromInv, fslot, limit, tslot = destinationInfo.inventory, cachedItem.inventory, cachedItem.slot,
        itemsToMove, destinationInfo.slot

    if limit ~= 0 then
      ate(transferCache, function()
        local itemsMoved = call(toInv, "pullItems", fromInv, fslot, limit, tslot)
        if options.itemMovedCallback then
          options.itemMovedCallback()
        end
        actualAmountMoved = actualAmountMoved + itemsMoved
        if not options.allowBadTransfers and itemsToMove ~= itemsMoved then
          error(("Expected to move %d items, moved %d. (in call %s)"):format(itemsToMove, itemsMoved, calln))
        elseif not itemsToMove == itemsMoved then
          badTransfer = true
        end
      end)
    end
    theoreticalAmountMoved = theoreticalAmountMoved + itemsToMove

    -- update our cache to include the predicted transfer
    if not destinationInfo.item then
      destinationInfo.item = shallowClone(cachedItem.item)
      destinationInfo.item.count = 0
    end

    destinationInfo.item.count = destinationInfo.item.count + itemsToMove
    -- unique code
    toInventory._cacheItem(destinationInfo.item, destinationInfo.inventory, destinationInfo.slot)

    -- update the other inventory's cache of that item to include the predicted transfer
    local updatedItem = shallowClone(cachedItem.item)
    updatedItem.count = updatedItem.count - itemsToMove

    if updatedItem.count == 0 then
      fromInventory._updateItem(nil, cachedItem.inventory, cachedItem.slot)
    else
      fromInventory._updateItem(updatedItem, cachedItem.inventory, cachedItem.slot)
    end
  end

  batchExecute(transferCache, nil, executeLimit)
  if badTransfer then
    -- refresh inventories
    toInventory.refreshStorage(options.autoDeepRefresh)
    fromInventory.refreshStorage(options.autoDeepRefresh)
  end
  return actualAmountMoved
end

---@class Item This is pulled directly from list(), or from getItemDetail(), so it may have more fields
---@field name string Name of this item
---@field nbt string|nil
---@field count number

---@class TransferOptions
---@field optimal boolean|nil Try to optimize item movements, true default
---@field allowBadTransfers boolean|nil Recover from item transfers not going as planned (probably caused by someone tampering with the inventory)
---@field autoDeepRefresh boolean|nil Whether to do a deep refresh upon a bad transfer (requires bad transfers to be allowed)
---@field itemMovedCallback nil|fun(): nil Function called anytime an item is moved

---@class CachedItem
---@field item Item|nil If an item is in this slot, this field will be an Item
---@field inventory string Inventory peripheral name
---@field slot number Slot in inventory this CachedItem represents
---@field globalSlot number Global slot of this CachedItem, spans across all wrapped inventories
---@field capacity number

---@alias invPeripheral {list: function, pullItems: function, pushItems: function, getItemLimit: function, getItemDetail: function, size: function}

---Wrap inventories and create an abstractInventory
---@param inventories table<integer,string|invPeripheral|{name: string|invPeripheral, minSlot: integer?, maxSlot: integer?, slots: integer[]?}> Table of inventory peripheral names to wrap
---@param assumeLimits boolean? Default true, assume the limit of each slot is the same, saves a TON of time
---@param logSettings {filename: string, cache: boolean?, optimal: boolean, unoptimal: boolean, api: boolean, redirect: fun(s:string)}?
---@return AbstractInventory
function abstractInventory(inventories, assumeLimits, logSettings)
  expect(1, inventories, "table")
  expect(2, assumeLimits, "nil", "boolean")
  ---@class AbstractInventory
  local api = {}
  api.abstractInventory = true
  api.assumeLimits = assumeLimits

  local uid = tostring(api)
  api.uid = uid

  if api.assumeLimits == nil then
    api.assumeLimits = true
  end

  local function optional(option, def)
    if option == nil then
      return def
    end
    return option
  end

  ---@alias TaskID integer

  ---@class InventoryTask
  ---@field type "pull"|"push"
  ---@field id TaskID
  ---@field args any[]

  ---Queue of inventory transfers
  ---@type InventoryTask[]
  local taskQueue = {}

  local maxExecuteLimit = 200
  local executeLimit = 200

  local nextTaskId = 1

  local maxSimiltaneousOperations = 8

  local running = false

  local logCache = optional(logSettings and logSettings.cache, true)
  local logOptimal = optional(logSettings and logSettings.optimal, true)
  local logUnoptimal = optional(logSettings and logSettings.unoptimal, true)
  local logApi = optional(logSettings and logSettings.api, true)
  local logDefrag = optional(logSettings and logSettings.defrag, true)

  local logFilename = logSettings and logSettings.filename
  if logFilename then
    local logf = assert(fs.open(logFilename, "w"))
    logf.close()
  end

  local lastCallN = 0

  local function log(formatString, ...)
    if logSettings and logSettings.redirect then
      logSettings.redirect(formatString:format(...))
    elseif logFilename then
      local logf = assert(fs.open(logFilename, "a"))
      logf.write(string.format(formatString, ...) .. "\n")
      logf.close()
    end
  end
  ---Log function entry
  ---@param doLog boolean?
  ---@param s string function name
  ---@param ... any
  ---@return number calln
  local function logEntry(doLog, s, ...)
    lastCallN = lastCallN + 1
    if doLog then
      local args = table.pack(...)
      local argFormat = string.rep("%s, ", args.n)
      local formatString = string.format("[%u] -> %s(%s)", lastCallN, s, argFormat)
      log(formatString, ...)
    end
    return lastCallN
  end
  ---Log function exit
  ---@param doLog boolean?
  ---@param calln number
  ---@param s string function name
  ---@param ... any return values
  ---@return ...
  local function logExit(doLog, calln, s, ...)
    if doLog then
      local retv = table.pack(...)
      local retFormat = string.rep("%s, ", retv.n)
      local formatString = string.format("[%u] %s(...) -> %s", calln, s, retFormat)
      log(formatString, ...)
    end
    return ...
  end

  ---@type table<string,table<string,CachedItem>>
  local itemNameNBTLUT = {}
  -- [item.name][nbt][CachedItem] -> CachedItem

  ---@type table<string,table<string,table<CachedItem,CachedItem>>>
  local itemSpaceLUT = {}
  -- [item.name][nbt][CachedItem] -> CachedItem

  ---Keeps track of items that have at least 2 entries to itemSpaceLUT.
  ---@type table<string,table<string,number>>
  local defraggableLUT = {}
  -- [ite.name][nbt] -> number

  ---@type table<string,table<integer,CachedItem>>
  local inventorySlotLUT = {}
  -- [inventory][slot] = CachedItem

  ---@type table<string,integer>
  local inventoryLimit = {}
  -- [inventory] = number

  ---@type table<string,table<integer,boolean|nil>>
  local emptySlotLUT = {}
  -- [inventory][slot] = true|nil

  ---@type table<integer,{inventory:string, slot:integer}>
  local slotNumberLUT = {}
  -- [global slot] -> {inventory:string, slot:number}

  ---@type table<string,table<integer,integer>>
  local inventorySlotNumberLUT = {}
  -- [inventory][slot] -> global slot:number

  ---@type table<string,table<string,boolean>>
  local tagLUT = {}
  -- [tag] -> string[]

  ---@type table<string,table<string,table>>
  local deepItemLUT = {}
  -- [name][nbt] -> ItemInfo

  ---@alias ItemHandle {type:"handle"}

  ---@type table<ItemHandle,{name:string,nbt:string,amount:integer,handle:ItemHandle}>
  local reservedItemLUT = {}
  -- [handle] -> item reservation

  ---@type table<integer,boolean>
  local busySlots = {}

  local function removeSlotFromEmptySlots(inventory, slot)
    emptySlotLUT[inventory] = emptySlotLUT[inventory] or {}
    emptySlotLUT[inventory][slot] = nil
    if not next(emptySlotLUT[inventory]) then
      emptySlotLUT[inventory] = nil
    end
  end
  function api._isSlotBusy(slot)
    return busySlots[slot]
  end

  ---Cache a given item, ensuring that whatever was in the slot beforehand is wiped properly
  ---And the caches are managed correctly.
  ---@param item table|nil
  ---@param inventory string|invPeripheral
  ---@param slot number
  ---@return CachedItem
  local function cacheItem(item, inventory, slot)
    local calln = logEntry(logCache, "cacheItem(%s, %s, %s)",
      select(2, pcall(textutils.serialise, item, { compact = true })),
      inventory, slot)
    expect(1, item, "table", "nil")
    expect(2, inventory, "string", "table")
    expect(3, slot, "number")
    local nbt = (item and item.nbt) or "NONE"
    if item and item.name == "" then
      item = nil
    end
    inventorySlotLUT[inventory] = inventorySlotLUT[inventory] or {}
    if inventorySlotLUT[inventory][slot] then
      local oldCache = inventorySlotLUT[inventory][slot]
      local oldItem = oldCache.item
      if oldItem and oldItem.name then
        -- There was an item in this slot before, clean up the caches
        local oldNBT = oldItem.nbt or "NONE"
        if itemNameNBTLUT[oldItem.name] and itemNameNBTLUT[oldItem.name][oldNBT] then
          itemNameNBTLUT[oldItem.name][oldNBT][oldCache] = nil
        end
        if itemSpaceLUT[oldItem.name] and itemSpaceLUT[oldItem.name][oldNBT] then
          itemSpaceLUT[oldItem.name][oldNBT][oldCache] = nil
          if defraggableLUT[oldItem.name] and defraggableLUT[oldItem.name][oldNBT] then
            local newSpaces = defraggableLUT[oldItem.name][oldNBT] - 1
            if newSpaces >= 2 then
              defraggableLUT[oldItem.name][oldNBT] = newSpaces
            else
              defraggableLUT[oldItem.name][oldNBT] = nil
              if not next(defraggableLUT[oldItem.name]) then
                defraggableLUT[oldItem.name] = nil
              end
            end
          end
        end
      end
    end
    removeSlotFromEmptySlots(inventory, slot)
    if not inventorySlotLUT[inventory][slot] then
      inventorySlotLUT[inventory][slot] = {
        item = item,
        inventory = inventory,
        slot = slot,
        globalSlot = inventorySlotNumberLUT[inventory][slot]
      }
    end
    if not inventorySlotLUT[inventory][slot].capacity then
      if api.assumeLimits and inventoryLimit[inventory] then
        inventorySlotLUT[inventory][slot].capacity = inventoryLimit[inventory]
      else
        inventorySlotLUT[inventory][slot].capacity = call(inventory, "getItemLimit", slot)
      end
      inventoryLimit[inventory] = inventorySlotLUT[inventory][slot].capacity
    end
    ---@type CachedItem
    local cachedItem = inventorySlotLUT[inventory][slot]
    cachedItem.item = item
    if item and item.name and item.count > 0 then
      itemNameNBTLUT[item.name] = itemNameNBTLUT[item.name] or {}
      itemNameNBTLUT[item.name][nbt] = itemNameNBTLUT[item.name][nbt] or {}
      itemNameNBTLUT[item.name][nbt][cachedItem] = cachedItem
      if item.tags then
        for k, v in pairs(item.tags) do
          tagLUT[k] = tagLUT[k] or {}
          tagLUT[k][item.name] = true
        end
      end
      if emptySlotLUT[inventory] then
        -- There's an item in this slot, therefor this slot is not empty
        emptySlotLUT[inventory][slot] = nil
      end
      if item.count < (item.maxCount * (cachedItem.capacity / 64)) then
        -- There's space left in this slot, add it to the cache
        itemSpaceLUT[item.name] = itemSpaceLUT[item.name] or {}
        itemSpaceLUT[item.name][nbt] = itemSpaceLUT[item.name][nbt] or {}
        defraggableLUT[item.name] = defraggableLUT[item.name] or {}
        if next(itemSpaceLUT[item.name][nbt]) then
          defraggableLUT[item.name][nbt] = (defraggableLUT[item.name][nbt] or 1) + 1
        end
        itemSpaceLUT[item.name][nbt][cachedItem] = cachedItem
      end
    else
      -- There is no item in this slot, this slot is empty
      emptySlotLUT[inventory] = emptySlotLUT[inventory] or {}
      emptySlotLUT[inventory][slot] = true
    end
    logExit(logCache, calln, "cacheItem", select(2, pcall(textutils.serialise, cachedItem, { compact = true })))
    return cachedItem
  end
  api._cacheItem = cacheItem

  ---Cache what's in a given slot
  ---@param inventory string
  ---@param slot number
  ---@return CachedItem
  local function cacheSlot(inventory, slot)
    local calln = logEntry(logCache, "cacheSlot", inventory, slot)
    return logExit(logCache, calln, "cacheSlot", cacheItem(call(inventory, "getItemDetail", slot), inventory, slot))
  end

  ---Refresh a CachedItem
  ---@param item CachedItem
  local function refreshItem(item)
    cacheSlot(item.inventory, item.slot)
  end

  local function refreshInventory(inventory, deep)
    local deepCacheFunctions = {}
    local inventoryName, slots, minSlot, maxSlot
    if type(inventory) == "table" then
      inventoryName = assert(inventory.name or (inventory.list and inventory), "Invalid inventory")
      slots = inventory.slots
      minSlot = inventory.minSlot or 1
      maxSlot = inventory.maxSlot or
          assert(call(inventoryName, "size"), ("%s is not a valid inventory."):format(inventoryName))
    else
      inventoryName = inventory
      minSlot = 1
      maxSlot = assert(call(inventoryName, "size"), ("%s is not a valid inventory."):format(inventoryName))
    end
    if not slots then
      slots = {}
      for i = minSlot, maxSlot do
        slots[#slots + 1] = i
      end
    end
    emptySlotLUT[inventoryName] = {}
    for _, i in ipairs(slots) do
      emptySlotLUT[inventoryName][i] = true
      local slotnumber = #slotNumberLUT + 1
      slotNumberLUT[slotnumber] = { inventory = inventoryName, slot = i }
      inventorySlotNumberLUT[inventoryName] = inventorySlotNumberLUT[inventoryName] or {}
      inventorySlotNumberLUT[inventoryName][i] = slotnumber
    end
    inventoryLimit[inventoryName] = call(inventoryName, "getItemLimit", 1) -- this should make transfers from/to this inventory parallel safe.
    local listings = call(inventoryName, "list")
    if not deep then
      for _, i in ipairs(slots) do
        if listings[i] then
          cacheItem(listings[i], inventoryName, i)
        end
      end
    else
      for _, i in ipairs(slots) do
        local listing = listings[i]
        if listing then
          deepCacheFunctions[#deepCacheFunctions + 1] = function()
            deepItemLUT[listing.name] = deepItemLUT[listing.name] or {}
            if deepItemLUT[listing.name][listing.nbt or "NONE"] then
              local item = shallowClone(deepItemLUT[listing.name][listing.nbt or "NONE"])
              item.count = listing.count
              cacheItem(item, inventoryName, i)
            else
              local item = call(inventoryName, "getItemDetail", i)
              cacheItem(item, inventoryName, i)
              if item then
                deepItemLUT[item.name][item.nbt or "NONE"] = item
              end
            end
          end
        end
      end
    end
    return deepCacheFunctions
  end

  ---Recache the inventory contents
  ---@param deep nil|boolean call getItemDetail on every slot
  function api.refreshStorage(deep)
    if type(deep) == "nil" then
      deep = true
    end
    itemNameNBTLUT, itemSpaceLUT, inventorySlotLUT, inventoryLimit, emptySlotLUT, slotNumberLUT, inventorySlotNumberLUT, tagLUT, deepItemLUT, reservedItemLUT =
        {}, {}, {}, {}, {}, {}, {}, {}, {}, {}
    local inventoryRefreshers = {}
    local deepCacheFunctions = {}
    for _, inventory in pairs(inventories) do
      table.insert(inventoryRefreshers, function()
        for k, v in ipairs(refreshInventory(inventory, deep) or {}) do
          deepCacheFunctions[#deepCacheFunctions + 1] = v
        end
      end)
    end
    batchExecute(inventoryRefreshers, nil, executeLimit)
    batchExecute(deepCacheFunctions, nil, executeLimit)
  end

  ---Get an inventory slot for a given item
  ---@param name string
  ---@param nbt nil|string
  ---@return nil|CachedItem
  local function getItem(name, nbt)
    nbt = nbt or "NONE"
    if not (itemNameNBTLUT[name] and itemNameNBTLUT[name][nbt]) then
      return
    end
    ---@type CachedItem
    local cached = next(itemNameNBTLUT[name][nbt])
    return cached
  end

  ---@return string|nil inventory
  ---@return integer|nil slot
  local function getEmptySlot()
    local inv = next(emptySlotLUT)
    if not inv then
      return
    end
    local slot = next(emptySlotLUT[inv])
    if not slot then
      emptySlotLUT[inv] = nil
      return getEmptySlot()
    end
    return inv, slot
  end

  ---Get an inventory slot that has space for a given item
  ---@param name string
  ---@param nbt nil|string
  ---@return nil|CachedItem
  local function getSlotWithSpace(name, nbt)
    nbt = nbt or "NONE"
    if not (itemSpaceLUT[name] and itemSpaceLUT[name][nbt]) then
      return
    end
    ---@type CachedItem
    local cached = next(itemSpaceLUT[name][nbt])
    return cached
  end
  api._getSlotWithSpace = getSlotWithSpace

  ---@return integer|nil slot
  ---@return string|nil inventory
  ---@return integer capacity
  local function getEmptySpace()
    local inv, freeSlot = getEmptySlot()
    local space
    if inv and freeSlot and inventorySlotLUT[inv] and inventorySlotLUT[inv][freeSlot] then
      space = inventorySlotLUT[inv][freeSlot].capacity
    elseif inv and freeSlot then
      cacheItem(nil, inv, freeSlot)
      space = inventorySlotLUT[inv][freeSlot].capacity
    else
      space = 0 -- no slot found
    end
    return freeSlot, inv, space
  end

  ---@param name string
  ---@param nbt string|nil
  ---@return CachedItem|nil
  function api._getSlotFor(name, nbt)
    return getSlotWithSpace(name, nbt)
  end

  ---@return integer|nil slot
  ---@return string|nil inventory
  ---@return integer capacity
  function api._getEmptySpace()
    return getEmptySpace()
  end

  ---@param item table|nil
  ---@param inventory string
  ---@param slot integer
  ---@return CachedItem
  function api._updateItem(item, inventory, slot)
    return cacheItem(item, inventory, slot)
  end

  ---@return CachedItem|nil
  function api._getItem(name, nbt)
    nbt = nbt or "NONE"
    if not (itemNameNBTLUT[name] and itemNameNBTLUT[name][nbt]) then
      return
    end
    return next(itemNameNBTLUT[name][nbt])
  end

  ---Get the number of items of this type you could store in this inventory
  ---@param item CachedItem
  ---@param name string
  ---@param nbt string|nil
  function api._getRealItemLimit(item, name, nbt)
    local slotLimit = item.capacity
    local stackSize = 64
    if item.item then
      stackSize = item.item.maxCount
    end
    return (slotLimit / 64) * stackSize
  end

  ---@param slot integer
  ---@return CachedItem
  local function getGlobalSlot(slot)
    local slotInfo = slotNumberLUT[slot]
    inventorySlotLUT[slotInfo.inventory] = inventorySlotLUT[slotInfo.inventory] or {}
    if not inventorySlotLUT[slotInfo.inventory][slotInfo.slot] then
      cacheSlot(slotInfo.inventory, slotInfo.slot)
    end
    return inventorySlotLUT[slotInfo.inventory][slotInfo.slot]
  end

  ---@param slot integer
  ---@return CachedItem|nil
  function api._getGlobalSlot(slot)
    return getGlobalSlot(slot)
  end

  function api._getLookupSlot(slot)
    return slotNumberLUT[slot]
  end

  local defaultOptions = {
    optimal = true,
    allowBadTransfers = false,
    autoDeepRefresh = false,
    itemMovedCallback = nil,
  }



  ---Perform a defrag on an individual item
  ---@param name string
  ---@param nbt string?
  ---@param skipPartial boolean?
  ---@param schedule function[]?
  ---@return function[] leftovers transfers that need to be performed still
  local function defragItem(name, nbt, skipPartial, schedule)
    nbt = nbt or "NONE"
    local callN = logEntry(logDefrag, "defragItem", name, nbt, skipPartial, schedule)
    schedule = schedule or {}
    ---@type {item: CachedItem, free: number, amt: number}[]
    local pad = {}
    itemSpaceLUT[name] = itemSpaceLUT[name] or {}
    for item in pairs(itemSpaceLUT[name][nbt] or {}) do
      pad[#pad + 1] = {
        item = item,
        free = item.item.maxCount - item.item.count,
        amt = item.item.count,
      }
    end
    local i, j = 1, #pad
    while i < j do
      local item = pad[j].item
      local toItem = pad[i].item
      local toMove = math.min(pad[i].free, pad[j].amt)
      schedule[#schedule + 1] = function()
        call(item.inventory, "pushItems", toItem.inventory, item.slot, toMove, toItem.slot)
        refreshItem(item)
        refreshItem(toItem)
      end
      pad[i].free = pad[i].free - toMove
      pad[j].amt = pad[j].amt - toMove
      if pad[i].free == 0 then i = i + 1 end
      if pad[j].amt == 0 then j = j - 1 end
    end
    schedule = batchExecute(schedule, skipPartial, executeLimit)
    return logExit(logDefrag, callN, "defragItem", schedule)
  end

  local function pullItemsOptimal(fromInventory, fromSlot, amount, toSlot, nbt, options)
    local calln = logEntry(logOptimal, "pullItemsOptimal", fromInventory, fromSlot, amount, toSlot, nbt)
    if type(fromInventory) == "string" or not fromInventory.abstractInventory then
      fromInventory = abstractInventory({ fromInventory })
      fromInventory.refreshStorage()
    end
    local ret = optimalTransfer(fromInventory, api, fromSlot, amount, toSlot, nbt, options, calln, executeLimit)
    logExit(logOptimal, calln, "pullItemsOptimal", ret)
    return ret
  end

  local function pushItemsUnoptimal(targetInventory, name, amount, toSlot, nbt, options)
    local calln = logEntry(logUnoptimal, "pushItemsUnoptimal", targetInventory, name, amount, toSlot, nbt)
    -- This is to a normal inventory
    local totalMoved = 0
    local rep = true
    while totalMoved < amount and rep do
      local item
      if type(name) == "number" then
        -- perform lookup
        item = getGlobalSlot(name)
      else
        item = getItem(name, nbt)
      end
      if not (item and item.item) then
        return logExit(logUnoptimal, calln, "pushItemsUnoptimal", totalMoved, "NO ITEM")
      end
      local itemCount = item.item.count
      rep = (itemCount - totalMoved) < amount
      local expectedMove = math.min(amount - totalMoved, 64)
      local remainingItems = math.max(0, itemCount - expectedMove)
      item.item.count = remainingItems
      if item.count == 0 then
        cacheItem(nil, item.inventory, item.slot)
      else
        cacheItem(item.item, item.inventory, item.slot)
      end
      local amountMoved = call(item.inventory, "pushItems", targetInventory, item.slot, amount - totalMoved, toSlot)
      totalMoved = totalMoved + amountMoved
      refreshItem(item)
      if options.itemMovedCallback then
        options.itemMovedCallback()
      end
      if amountMoved < itemCount then
        return logExit(logUnoptimal, calln, "pushItemsUnoptimal", totalMoved, "TARGET FULL")
      end
    end
    return logExit(logUnoptimal, calln, "pushItemsUnoptimal", totalMoved)
  end

  local function pushItemsOptimal(targetInventory, name, amount, toSlot, nbt, options)
    local calln = logEntry(logOptimal, "pushItemsOptimal", targetInventory, name, amount, toSlot, nbt)
    if type(targetInventory) == "string" or not targetInventory.abstractInventory then
      -- We'll see if this is a good optimization or not
      targetInventory = abstractInventory({ targetInventory })
      targetInventory.refreshStorage()
    end
    local ret = optimalTransfer(api, targetInventory, name, amount, toSlot, nbt, options, calln, executeLimit)
    return logExit(logOptimal, calln, "pushItemsOptimal", ret)
  end

  ---@param targetInventory string|AbstractInventory
  ---@param name string|number|ItemHandle
  ---@param amount nil|number
  ---@param toSlot nil|number
  ---@param nbt nil|string
  ---@param options nil|TransferOptions
  ---@return integer count
  local function doPushItems(targetInventory, name, amount, toSlot, nbt, options)
    local calln = logEntry(logApi, "doPushItems", targetInventory, name, amount, toSlot, nbt)
    amount = amount or 64
    -- apply ItemHandle
    local h
    if type(name) == "table" and name.type == "handle" then
      h = reservedItemLUT[name]
      name = h.name
      nbt = h.nbt
      amount = math.min(amount, h.amount + api.getCount(name, nbt))
    elseif type(name) == "string" then
      amount = math.min(amount, api.getCount(name, nbt))
    end
    options = options or {}
    for k, v in pairs(defaultOptions) do
      if options[k] == nil then
        options[k] = v
      end
    end
    if type(targetInventory) == "string" then
      local test = peripheral.wrap(targetInventory)
      if not (test and test.size) then
        options.optimal = false
      end
    end
    local ret
    if type(targetInventory) == "string" and not options.optimal then
      ret = pushItemsUnoptimal(targetInventory, name, amount, toSlot, nbt, options)
    else
      ret = pushItemsOptimal(targetInventory, name, amount, toSlot, nbt, options)
    end
    if h then
      h.amount = math.max(0, h.amount - ret)
    end
    return logExit(logApi, calln, "doPushItems", ret)
  end

  ---Push items to an inventory
  ---@param targetInventory string|AbstractInventory
  ---@param name string|number|ItemHandle
  ---@param amount nil|number
  ---@param toSlot nil|number
  ---@param nbt nil|string
  ---@param options nil|TransferOptions
  ---@return integer count
  function api.pushItems(targetInventory, name, amount, toSlot, nbt, options)
    expect(1, targetInventory, "string", "table")
    expect(2, name, "string", "number", "table")
    expect(3, amount, "nil", "number")
    expect(4, toSlot, "nil", "number")
    expect(5, nbt, "nil", "string")
    expect(6, options, "nil", "table")

    if not running then
      return doPushItems(targetInventory, name, amount, toSlot, nbt, options)
    end

    return api.await(api.queuePush(targetInventory, name, amount, toSlot, nbt, options))
  end

  local function pullItemsUnoptimal(fromInventory, fromSlot, amount, toSlot, nbt, options)
    local calln = logEntry(logUnoptimal, "pullItemsUnoptimal", fromInventory, fromSlot, amount, toSlot, nbt)
    assert(type(fromSlot) == "number", "Must pull from a slot #")
    local itemsPulled = 0
    while itemsPulled < amount do
      local freeSlot, freeInventory, space
      freeSlot, freeInventory, space = getEmptySpace()
      if toSlot then
        local toItem = getGlobalSlot(toSlot)
        freeSlot, freeInventory, space = toItem.slot, toItem.inventory, toItem.capacity
      end
      if not (freeSlot and freeInventory) then
        return logExit(logUnoptimal, calln, "pullItemsUnoptimal", itemsPulled, "OUT OF SPACE")
      end
      local limit = math.min(amount - itemsPulled, space)
      busySlots[inventorySlotNumberLUT[freeInventory][freeSlot]] = true
      cacheItem({ name = "UNKNOWN", count = 64, maxCount = 64 }, freeInventory, freeSlot)
      local moved = call(freeInventory, "pullItems", fromInventory, fromSlot, limit, freeSlot)
      local movedItem = cacheSlot(freeInventory, freeSlot)
      busySlots[inventorySlotNumberLUT[freeInventory][freeSlot]] = nil
      if options.itemMovedCallback then
        options.itemMovedCallback()
      end
      itemsPulled = itemsPulled + moved
      if moved > 0 then
        defragItem(movedItem.item.name, movedItem.item.nbt)
      end
      if moved < limit then
        -- there's no more items to pull
        return logExit(logUnoptimal, calln, "pullItemsUnoptimal", itemsPulled, "OUT OF ITEMS")
      end
    end
    return logExit(logUnoptimal, calln, "pullItemsUnoptimal", itemsPulled)
  end

  local function doPullItems(fromInventory, fromSlot, amount, toSlot, nbt, options)
    local calln = logEntry(logApi, "doPullItems", fromInventory, fromSlot, amount, toSlot, nbt)
    options = options or {}
    for k, v in pairs(defaultOptions) do
      if options[k] == nil then
        options[k] = v
      end
    end
    amount = amount or 64
    nbt = nbt or "NONE"
    if type(fromInventory) == "string" then
      local test = peripheral.wrap(fromInventory)
      if not (test and test.size) then
        options.optimal = false
      end
    end
    if options.optimal == nil then options.optimal = true end
    local ret
    if type(fromInventory) == "string" and not options.optimal then
      ret = pullItemsUnoptimal(fromInventory, fromSlot, amount, toSlot, nbt, options)
    else
      ret = pullItemsOptimal(fromInventory, fromSlot, amount, toSlot, nbt, options)
    end
    return logExit(logApi, calln, "doPullItems", ret)
  end

  ---Pull items from an inventory
  ---@param fromInventory string|AbstractInventory
  ---@param fromSlot string|number
  ---@param amount nil|number
  ---@param toSlot nil|number
  ---@param nbt nil|string
  ---@param options nil|TransferOptions
  ---@return integer count
  function api.pullItems(fromInventory, fromSlot, amount, toSlot, nbt, options)
    expect(1, fromInventory, "table", "string")
    expect(2, fromSlot, "number", "string")
    expect(3, amount, "nil", "number")
    expect(4, toSlot, "nil", "number")
    expect(5, nbt, "nil", "string")
    expect(6, options, "nil", "table")

    if not running then
      return doPullItems(fromInventory, fromSlot, amount, toSlot, nbt, options)
    end
    return api.await(api.queuePull(fromInventory, fromSlot, amount, toSlot, nbt, options))
  end

  ---Queue a transfer
  ---@param type "push"|"pull"
  ---@param args any[]
  ---@return TaskID
  local function queue(type, args)
    taskQueue[#taskQueue + 1] = {
      type = type,
      args = args,
      id = nextTaskId
    }
    nextTaskId = nextTaskId + 1
    return nextTaskId - 1
  end

  ---Pull items from an inventory
  ---@param fromInventory string|AbstractInventory
  ---@param fromSlot string|number
  ---@param amount nil|number
  ---@param toSlot nil|number
  ---@param nbt nil|string
  ---@param options nil|TransferOptions
  ---@return TaskID task
  function api.queuePull(fromInventory, fromSlot, amount, toSlot, nbt, options)
    expect(1, fromInventory, "table", "string")
    expect(2, fromSlot, "number", "string")
    expect(3, amount, "nil", "number")
    expect(4, toSlot, "nil", "number")
    expect(5, nbt, "nil", "string")
    expect(6, options, "nil", "table")

    assert(running, "Call .run() to queue transfers!")

    return queue("pull", { fromInventory, fromSlot, amount, toSlot, nbt, options })
  end

  ---Push items to an inventory
  ---@param targetInventory string|AbstractInventory
  ---@param name string|number|ItemHandle
  ---@param amount nil|number
  ---@param toSlot nil|number
  ---@param nbt nil|string
  ---@param options nil|TransferOptions
  ---@return integer count
  function api.queuePush(targetInventory, name, amount, toSlot, nbt, options)
    expect(1, targetInventory, "string", "table")
    expect(2, name, "string", "number", "table")
    expect(3, amount, "nil", "number")
    expect(4, toSlot, "nil", "number")
    expect(5, nbt, "nil", "string")
    expect(6, options, "nil", "table")

    assert(running, "Call .run() to queue transfers!")

    return queue("push", { targetInventory, name, amount, toSlot, nbt, options })
  end

  ---@param task InventoryTask
  local function processTask(task)
    local result
    if task.type == "pull" then
      result = doPullItems(table.unpack(task.args))
    else
      result = doPushItems(table.unpack(task.args))
    end
    os.queueEvent("ail_task_complete", uid, task.id, result)
  end

  local function waitToDoTasks()
    local tid = os.startTimer(1)
    while true do
      local e, id = os.pullEvent()
      if e == "timer" and id == tid then
        return
      elseif e == "ail_start_transfer" and id == uid then
        os.cancelTimer(tid)
        return
      end
    end
  end

  ---Reserve an item for later use
  ---@param amount integer
  ---@param item string
  ---@param nbt nil|string
  ---@return ItemHandle?
  function api.allocateItem(amount, item, nbt)
    expect(1, item, "string")
    expect(2, nbt, "nil", "string")
    nbt = nbt or "NONE"
    ---@type ItemHandle
    local h = { type = "handle" }

    if api.getCount(item, nbt) < amount then
      return
    end
    reservedItemLUT[h] = {
      amount = amount,
      name = item,
      nbt = nbt,
      handle = h
    }
    return h
  end

  ---@param handle ItemHandle
  function api.freeItem(handle)
    reservedItemLUT[handle] = nil
  end

  ---Check if a given handle is still valid. (Invalid when count = 0)
  ---@param handle ItemHandle
  ---@return boolean
  function api.isHandleValid(handle)
    return not not reservedItemLUT[handle]
  end

  ---Call this to batch all AIL calls and execute multiple in parallel.
  function api.run()
    running = true
    while true do
      waitToDoTasks()
      if #taskQueue > 0 then
        local taskFuncs = {}
        for i, v in ipairs(taskQueue) do
          taskFuncs[i] = function()
            processTask(v)
          end
        end
        taskQueue = {}

        local batchSize = math.min(#taskFuncs, maxSimiltaneousOperations)
        executeLimit = math.floor(maxExecuteLimit / batchSize)
        batchExecute(taskFuncs, nil, batchSize)

        os.queueEvent("ail_transfer_complete", uid)
      end
    end
  end

  ---Perform the transfer queue immediately
  function api.performTransfer()
    os.queueEvent("ail_start_transfer", uid)
  end

  ---Wait for a task to complete
  ---@param task TaskID
  ---@return integer
  function api.await(task)
    while true do
      local _, ailid, tid, result = os.pullEvent("ail_task_complete")
      if ailid == uid and tid == task then
        return result
      end
    end
  end

  ---Get the amount of this item in storage
  ---@param item string
  ---@param nbt nil|string
  ---@return integer
  function api.getCount(item, nbt)
    expect(1, item, "string")
    expect(2, nbt, "nil", "string")
    nbt = nbt or "NONE"
    if not (itemNameNBTLUT[item] and itemNameNBTLUT[item][nbt]) then
      return 0
    end
    local totalCount = 0
    for k, v in pairs(itemNameNBTLUT[item][nbt]) do
      totalCount = totalCount + v.item.count
    end
    for _, v in pairs(reservedItemLUT) do
      if v.name == item and v.nbt == nbt then
        totalCount = totalCount - v.amount
      end
    end
    return totalCount
  end

  ---Get a list of all items in this storage
  ---@return CachedItem[] list
  function api.listItems()
    ---@type CachedItem[]
    local t = {}
    for name, nbtt in pairs(itemNameNBTLUT) do
      for nbt, cachedItem in pairs(nbtt) do
        ate(t, cachedItem)
      end
    end
    return t
  end

  ---Get a list of all item names in this storage
  ---@return string[]
  function api.listNames()
    local t = {}
    for k, v in pairs(itemNameNBTLUT) do
      t[#t + 1] = k
    end
    return t
  end

  ---Get the NBT hashes for a given item name
  ---@param name string
  ---@return string[]
  function api.listNBT(name)
    local t = {}
    for k, v in pairs(itemNameNBTLUT[name] or {}) do
      t[#t + 1] = k
    end
    return t
  end

  ---Rearrange items to make the most efficient use of space
  function api.defrag()
    local schedule = {}
    for name, nbts in pairs(defraggableLUT) do
      for nbt in pairs(nbts) do
        schedule = defragItem(name, nbt, true, schedule)
      end
    end
    batchExecute(schedule, nil, executeLimit)
  end

  ---Get a CachedItem by name/nbt
  ---@param name string
  ---@param nbt nil|string
  ---@return CachedItem|nil
  function api.getItem(name, nbt)
    expect(1, name, "string")
    expect(2, nbt, "nil", "string")
    return getItem(name, nbt) -- this can be nil
  end

  ---Get a CachedItem by slot
  ---@param slot integer
  ---@return CachedItem
  function api.getSlot(slot)
    expect(1, slot, "number")
    return getGlobalSlot(slot)
  end

  ---Change the max number of functions to run in parallel
  ---@param n integer
  function api.setBatchLimit(n)
    expect(1, n, "number")
    assert(n > 0, "Attempt to set negative/0 batch limit.")
    if n < 10 then
      error(string.format("Attempt to set batch limit too low. (%u)."):format(n))
    end
    if n > 230 then
      error(
        string.format(
          "Attempt to set batch limit to %u, the event queue is 256 elements long. This is very likely to result in dropped events.",
          n), 2)
    end
    maxExecuteLimit = n
    executeLimit = n
  end

  ---Get an inventory peripheral compatible list of items in this storage
  ---@return table
  function api.list()
    local t = {}
    for itemName, nbtTable in pairs(itemNameNBTLUT) do
      for nbt, cachedItems in pairs(nbtTable) do
        for item, _ in pairs(cachedItems) do
          t[inventorySlotNumberLUT[item.inventory][item.slot]] = item.item
        end
      end
    end
    return t
  end

  ---Get a list of item name indexed counts of each item
  ---@return table<string,integer>
  function api.listItemAmounts()
    local t = {}
    for _, itemName in ipairs(api.listNames()) do
      t[itemName] = 0
      for _, nbt in ipairs(api.listNBT(itemName)) do
        t[itemName] = t[itemName] + api.getCount(itemName, nbt)
      end
    end
    return t
  end

  ---Get a list of items with the given tag
  ---@param tag string
  ---@return string[]
  function api.getTag(tag)
    local t = {}
    for k, v in pairs(tagLUT[tag] or {}) do
      table.insert(t, k)
    end
    return t
  end

  ---Get the slot usage of this inventory
  ---@return {free: integer, used:integer, total:integer}
  function api.getUsage()
    local ret = {}
    ret.total = api.size()
    ret.used = 0
    for i, _ in pairs(api.list()) do
      ret.used = ret.used + 1
    end
    ret.free = ret.total - ret.used
    return ret
  end

  ---Get the amount of slots in this inventory
  ---@return integer
  function api.size()
    return #slotNumberLUT
  end

  ---Get item information from a slot
  ---@param slot integer
  ---@return Item
  function api.getItemDetail(slot)
    expect(1, slot, "number")
    local item = getGlobalSlot(slot)
    if item.item == nil then
      refreshItem(item)
    end
    return item.item
  end

  ---Get maximum number of items that can be in a slot
  ---@param slot integer
  ---@return integer
  function api.getItemLimit(slot)
    expect(1, slot, "number")
    local item = getGlobalSlot(slot)
    return item.limit
  end

  ---pull all items from an inventory
  ---@param inventory string|AbstractInventory
  ---@return integer moved total items moved
  function api.pullAll(inventory)
    if type(inventory) == "string" or not inventory.abstractInventory then
      inventory = abstractInventory({ inventory })
      inventory.refreshStorage()
    end
    local moved = 0
    for k, _ in pairs(inventory.list()) do
      moved = moved + api.pullItems(inventory, k)
    end
    return moved
  end

  local function getItemIndex(t, item)
    for k, v in ipairs(t) do
      if v == item then
        return k
      end
    end
  end

  ---Add an inventory to the storage object
  ---@param inventory string|invPeripheral
  ---@return boolean success
  function api.addInventory(inventory)
    expect(1, inventory, "string", "table")
    if getItemIndex(inventories, inventory) then
      return false
    end
    table.insert(inventories, inventory)
    api.refreshStorage(true)
    return true
  end

  ---Remove an inventory from the storage object
  ---@param inventory string|invPeripheral
  ---@return boolean success
  function api.removeInventory(inventory)
    expect(1, inventory, "string", "table")
    local index = getItemIndex(inventories, inventory)
    if not index then
      return false
    end
    table.remove(inventories, index)
    api.refreshStorage(true)
    return true
  end

  ---Get the number of free slots in this inventory
  ---@return integer
  function api.freeSpace()
    local count = 0
    for _, inventorySlots in pairs(emptySlotLUT) do
      for _, _ in pairs(inventorySlots) do
        count = count + 1
      end
    end
    return count
  end

  ---Get the number of items of this type you could store in this inventory
  ---@param name string
  ---@param nbt string|nil
  ---@return integer count
  function api.totalSpaceForItem(name, nbt)
    expect(1, name, "string")
    expect(2, nbt, "string", "nil")
    local count = 0
    for inventory, inventorySlots in pairs(emptySlotLUT) do
      for slot in pairs(inventorySlots) do
        count = count + api._getRealItemLimit(inventorySlotLUT[inventory][slot], name, nbt)
      end
    end
    nbt = nbt or "NONE"
    if itemSpaceLUT[name] and itemSpaceLUT[name][nbt] then
      for _, cached in pairs(itemSpaceLUT[name][nbt]) do
        count = count + (cached.capacity - cached.item.count)
      end
    end
    return count
  end

  api.refreshStorage(true)

  return api
end

return abstractInventory
