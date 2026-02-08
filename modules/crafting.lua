local common = require("common")
---@class modules.crafting
---@field interface modules.crafting.interface
return {
  id = "crafting",
  version = "1.4.6", -- Bumped version for fix
  config = {
    tagLookup = {
      type = "table",
      description = "Force a given item to be used for a tag lookup. Map from tag->item.",
      default = {}
    },
    aliases = {
      type = "table",
      description = "Manual Table of aliases. Map input -> output (e.g. 'foo' -> 'bar').",
      default = {}
    },
    persistence = {
      type = "boolean",
      description =
      "Save all the crafting caches to disk so jobs can be resumed later. (This uses a lot of disk space. ~300 nodes is >1MB, a craft that takes one type of item is 2 nodes / stack + 1 root node).",
      default = false, -- this is going to be elect-in for now
    },
    tickInterval = {
      type = "number",
      description = "Interval between crafting ticks in seconds.",
      default = 1,
    },
    cleanupInterval = {
      type = "number",
      description = "Interval between cleanup in seconds",
      default = 60,
    },
    autoCraftingRules = {
      type = "table",
      description = "Automatic crafting rules when item count is reached table<item: string, {threshold: integer, recipe: string}>",
      default = {}
    },
    autoSmeltingRules = {
      type = "table",
      description = "Automatic smelting rules when item count is reached table<item: string, {threshold: integer, output: string}>",
      default = {}
    }
  },
  dependencies = {
    logger = { min = "1.1", optional = true },
    inventory = { min = "1.1" }
  },
  init = function(loaded, config)
    local log = loaded.logger
    
    ---@alias ItemInfo {name: string, tag: boolean?}
    ---@alias ItemIndex integer

    ---@type ItemInfo[]
    local itemLookup = {}
    ---@type table<string,ItemIndex> lookup from name -> item_lookup index
    local itemNameLookup = {}

    local json = require("lib/json")
    local function saveItemLookup()
      local f = assert(fs.open("recipes/item_lookup.json", "w"))
      f.write(json.encode(itemLookup))
      f.close()
    end
    
    local function loadItemLookup()
      local f = fs.open("recipes/item_lookup.json", "r")
      if f then
        local contents = f.readAll() or "{}"
        f.close()
        local decoded = json.decode(contents)
        if type(decoded) == "table" then
          itemLookup = decoded
          for k, v in pairs(itemLookup) do
            local name = v.name or v[1]
            if name then
                itemNameLookup[name] = k
            end
          end
        else
          print("Warning: Invalid item lookup JSON format")
        end
      end
    end

    ---Get the index of a string or tag
    ---@param str string
    ---@param tag boolean|nil
    ---@return ItemIndex
    local function getOrCacheString(str, tag)
      common.enforceType(str, 1, "string")
      common.enforceType(tag, 2, "boolean", "nil")
      
      -- Manual Alias Resolution (Config)
      local aliases = config.crafting.aliases and config.crafting.aliases.value
      if aliases and aliases[str] then
        str = aliases[str]
      end

      if itemNameLookup[str] then
        return itemNameLookup[str]
      end
      local i = #itemLookup + 1
      itemLookup[i] = { name = str, tag = not not tag }
      itemNameLookup[str] = i
      saveItemLookup()
      return i
    end

    local jsonLogger = setmetatable({}, {
      __index = function() return function() end end
    })
    if log then
      jsonLogger = log.interface.logger("crafting", "json_importing")
    end
    local jsonTypeHandlers = {}
    local function addJsonTypeHandler(jsonType, handler)
      common.enforceType(jsonType, 1, "string")
      common.enforceType(handler, 2, "function")
      jsonTypeHandlers[jsonType] = handler
    end
    local function loadJson(json)
      common.enforceType(json, 1, "table")
      if jsonTypeHandlers[json.type] then
        jsonLogger:info("Importing JSON of type %s", json.type)
        jsonTypeHandlers[json.type](json)
        return true
      else
        jsonLogger:info("Skipping JSON of type %s, no handler available", json.type)
      end
    end

    ---@alias taskID string uuid foriegn key
    ---@alias JobId string
    local waitingQueue = {}
    local readyQueue = {}
    local craftingQueue = {}
    local doneLookup = {}
    local transferIdTaskLUT = {}
    local tickNode, changeNodeState, deleteTask
    local reservedItems = {}

    local function saveReservedItems()
      if not config.crafting.persistence.value then return end
      common.saveTableToFile(".cache/reserved_items.txt", reservedItems)
    end

    local function loadReservedItems()
      if not config.crafting.persistence.value then
        reservedItems = {}
        return
      end
      reservedItems = common.loadTableFromFile(".cache/reserved_items.txt") or {}
    end

    local function getCount(name)
      common.enforceType(name, 1, "string")
      local reservedCount = 0
      for k, v in pairs(reservedItems[name] or {}) do
        reservedCount = reservedCount + v
      end
      return loaded.inventory.interface.getCount(name) - reservedCount
    end

    local function allocateItems(name, amount, taskId)
      common.enforceType(name, 1, "string")
      common.enforceType(amount, 2, "integer")
      reservedItems[name] = reservedItems[name] or {}
      reservedItems[name][taskId] = (reservedItems[name][taskId] or 0) + amount
      saveReservedItems()
      return amount
    end

    local function deallocateItems(name, amount, taskId)
      common.enforceType(name, 1, "string")
      common.enforceType(amount, 2, "integer")
      if not reservedItems[name] or not reservedItems[name][taskId] then
        if log then
          -- craftLogger:debug("Attempt to deallocate...") -- craftLogger not defined yet
        end
        return 0
      end
      reservedItems[name][taskId] = reservedItems[name][taskId] - amount
      if reservedItems[name][taskId] == 0 then reservedItems[name][taskId] = nil end
      if not next(reservedItems[name]) then reservedItems[name] = nil end
      saveReservedItems()
      return amount
    end

    local cachedStackSizes = {}
    local function getStackSize(name)
      common.enforceType(name, 1, "string")
      if cachedStackSizes[name] then return cachedStackSizes[name] end
      local item = loaded.inventory.interface.getItem(name)
      cachedStackSizes[name] = (item and item.item and item.item.maxCount) or 64
      return cachedStackSizes[name]
    end

    local lastId = 0
    local function id()
      lastId = lastId + 1
      return lastId .. "$"
    end

    local craftableLists = {}
    local function addCraftableList(id, list)
      common.enforceType(id, 1, "string")
      common.enforceType(list, 2, "string[]")
      craftableLists[id] = list
    end

    local function listCraftables()
      local l = {}
      for k, v in pairs(craftableLists) do
        for i, s in ipairs(v) do table.insert(l, s) end
      end
      return l
    end

    local cachedTagLookup = {}
    local function saveCachedTags()
      local f = assert(fs.open(".cache/cached_tags.json", "w"))
      f.write(json.encode(cachedTagLookup))
      f.close()
    end

    local cachedTagPresence = {}
    local function loadCachedTags()
      local f = fs.open(".cache/cached_tags.json", "r")
      if f then
        cachedTagLookup = json.decode(f.readAll() or "{}")
        f.close()
        cachedTagPresence = {}
        for tag, names in pairs(cachedTagLookup) do
          cachedTagPresence[tag] = {}
          for _, name in ipairs(names) do
            cachedTagPresence[tag][name] = true
          end
        end
      end
    end

    -- Load aliases/tags from recipes.json
    local function loadAliases()
      if not fs.exists("recipes/recipes.json") then return end
      local f = fs.open("recipes/recipes.json", "r")
      if f then
        local content = f.readAll()
        f.close()
        local data = json.decode(content)
        if data and data.aliases then
            print("Loading aliases from recipes.json...")
            local count = 0
            for tag, items in pairs(data.aliases) do
                cachedTagLookup[tag] = items
                cachedTagPresence[tag] = cachedTagPresence[tag] or {}
                for _, item in ipairs(items) do
                    cachedTagPresence[tag][item] = true
                end
                count = count + 1
            end
            print("Loaded " .. count .. " aliases/tags.")
            saveCachedTags()
        end
      end
    end

    local function selectBestFromTag(tag)
      common.enforceType(tag, 1, "string")
      if config.crafting.tagLookup.value[tag] then
        return true, config.crafting.tagLookup.value[tag]
      end
      
      -- Ensure cache initialized
      if not cachedTagPresence[tag] then
        cachedTagPresence[tag] = {}
        cachedTagLookup[tag] = {}
        saveCachedTags()
      end
      
      -- 1. Gather all candidates (from Inventory Peripheral AND Aliases)
      -- Use a dictionary to avoid duplicates
      local candidates = {} 
      
      -- Check inventory peripheral
      local inventoryTags = loaded.inventory.interface.getTag(tag)
      if inventoryTags then
          for _, item in ipairs(inventoryTags) do
              candidates[item] = true
          end
      end
      
      -- Check cached aliases (from recipes.json)
      if cachedTagLookup[tag] then
          for _, item in ipairs(cachedTagLookup[tag]) do
              candidates[item] = true
          end
      end

      -- 2. Check counts for ALL candidates
      local itemsWithTagsCount = {}
      for name, _ in pairs(candidates) do
         -- Cache this item as belonging to this tag for future use
         if not cachedTagPresence[tag][name] then
             cachedTagPresence[tag][name] = true
             table.insert(cachedTagLookup[tag], name)
             saveCachedTags()
         end
         
         -- Check if we actually have it
         local count = loaded.inventory.interface.getCount(name)
         if count > 0 then
             table.insert(itemsWithTagsCount, { name = name, count = count })
         end
      end
      
      -- Sort by count to use most abundant item
      table.sort(itemsWithTagsCount, function(a, b) return a.count > b.count end)
      
      if itemsWithTagsCount[1] then
        return true, itemsWithTagsCount[1].name
      end

      -- 3. Check if we can craft any item belonging to this tag
      local craftableList = listCraftables()
      local isCraftableLUT = {}
      for k, v in pairs(craftableList) do
        isCraftableLUT[v] = true
      end

      -- Check all known aliases for craftability
      for name, _ in pairs(candidates) do
        if isCraftableLUT[name] then
          return true, name
        end
      end
      
      -- If we have aliases that we haven't checked (maybe because they weren't in candidates list above?)
      -- Fallback to strict cached lookup check
      for k, v in pairs(cachedTagLookup[tag]) do
        if isCraftableLUT[v] then
          return true, v 
        end
      end

      return false, tag
    end

    local function selectBestFromIndex(index)
      common.enforceType(index, 1, "integer")
      local itemInfo = assert(itemLookup[index], "Invalid item index")
      local name = itemInfo.name or itemInfo[1]
      if itemInfo.tag then
        -- Add # if missing for tag lookup, as aliases usually have it
        local lookupName = name
        if not lookupName:find("^#") then lookupName = "#" .. lookupName end
        return selectBestFromTag(lookupName)
      end
      return true, name
    end

    -- FIX: Select the best item from a list of options (instead of blindly picking the first)
    local function selectBestFromList(list)
      common.enforceType(list, 1, "integer[]")
      
      -- Try to find one we already have
      for _, itemIndex in ipairs(list) do
          local itemInfo = itemLookup[itemIndex]
          local name = itemInfo.name or itemInfo[1]
          if getCount(name) > 0 then
              return true, name
          end
      end

      -- Try to find one we can craft
      local craftableList = listCraftables()
      local isCraftableLUT = {}
      for k, v in pairs(craftableList) do
        isCraftableLUT[v] = true
      end
      for _, itemIndex in ipairs(list) do
          local itemInfo = itemLookup[itemIndex]
          local name = itemInfo.name or itemInfo[1]
          if isCraftableLUT[name] then
              return true, name
          end
      end
      
      -- Default to the first one if we can't find anything better
      local firstInfo = itemLookup[list[1]]
      return true, (firstInfo.name or firstInfo[1])
    end

    local function getBestItem(item)
      common.enforceType(item, 1, "integer[]", "integer")
      if type(item) == "table" then
        return selectBestFromList(item)
      elseif type(item) == "number" then
        return selectBestFromIndex(item)
      end
      error("Invalid type " .. type(item), 2)
    end

    local function getString(v)
      local itemInfo = itemLookup[v]
      assert(itemInfo, "Invalid key passed to getString")
      return (itemInfo.name or itemInfo[1]), itemInfo.tag
    end

    local function mergeInto(from, to)
      common.enforceType(from, 1, "table")
      common.enforceType(to, 1, "table")
      for k, v in pairs(from) do
        table.insert(to, v)
      end
    end

    local taskLookup = {}
    local jobLookup = {}

    local function shallowClone(t)
      common.enforceType(t, 1, "table")
      local nt = {}
      for k, v in pairs(t) do nt[k] = v end
      return nt
    end

    local function saveTaskLookup()
      if not config.crafting.persistence.value then return end
      local flatTaskLookup = {}
      for k, v in pairs(taskLookup) do
        flatTaskLookup[k] = shallowClone(v)
        local flatTask = flatTaskLookup[k]
        if v.parent then flatTask.parent = v.parent.taskId end
        if v.children then
          flatTask.children = {}
          for i, ch in pairs(v.children) do flatTask.children[i] = ch.taskId end
        end
      end
      local f = assert(fs.open(".cache/flat_task_lookup.json", "w"))
      f.write(json.encode(flatTaskLookup))
      f.close()
    end

    local function loadTaskLookup()
      if not config.crafting.persistence.value then
        taskLookup = {}
        return
      end
      local taskLoaderLogger = setmetatable({}, { __index = function() return function() end end })
      if log then taskLoaderLogger = log.interface.logger("crafting", "loadTaskLookup") end
      local f = fs.open(".cache/flat_task_lookup.json", "r")
      if f then
        local contents = f.readAll() or "{}"
        f.close()
        local decoded = json.decode(contents)
        if type(decoded) == "table" then
          taskLookup = decoded
        else
          taskLookup = {}
          print("Warning: Invalid task lookup JSON format")
        end
      else
        taskLookup = {}
      end
      jobLookup = {}
      waitingQueue = {}
      readyQueue = {}
      craftingQueue = {}
      doneLookup = {}
      for k, v in pairs(taskLookup) do
        taskLoaderLogger:debug("Loaded taskId=%s,state=%s", v.taskId, v.state)
        jobLookup[v.jobId] = jobLookup[v.jobId] or {}
        table.insert(jobLookup[v.jobId], v)
        if v.parent then v.parent = taskLookup[v.parent] end
        if v.children then
          for i, ch in pairs(v.children) do v.children[i] = taskLookup[ch] end
        end
        if v.state then
          if v.state == "WAITING" then table.insert(waitingQueue, v)
          elseif v.state == "READY" then table.insert(readyQueue, v)
          elseif v.state == "CRAFTING" then table.insert(craftingQueue, v)
          elseif v.state == "DONE" then doneLookup[v.taskId] = v
          else error("Invalid state on load") end
        end
      end
    end

    local craftLogger = setmetatable({}, { __index = function() return function() end end })
    if log then craftLogger = log.interface.logger("crafting", "request_craft") end
    local craft
    local requestCraftTypes = {}
    local function addCraftType(type, func)
      common.enforceType(type, 1, "string")
      common.enforceType(func, 1, "function")
      requestCraftTypes[type] = func
    end

    local function createMissingNode(name, count, jobId)
      common.enforceType(name, 1, "string")
      common.enforceType(count, 2, "integer")
      common.enforceType(jobId, 3, "string")
      return { name = name, jobId = jobId, taskId = id(), count = count, type = "MISSING" }
    end

    local function _attemptCraft(node, name, remaining, requestChain, jobId)
      common.enforceType(node, 1, "table")
      common.enforceType(name, 2, "string")
      common.enforceType(remaining, 3, "integer")
      common.enforceType(requestChain, 4, "table")
      common.enforceType(jobId, 5, "string")
      local success = false
      for k, v in pairs(requestCraftTypes) do
        success = v(node, name, remaining, requestChain)
        if success then
          craftLogger:debug("Recipe found. provider:%s,name:%s,count:%u,taskId:%s,jobId:%s", k, name, node.count, node.taskId, jobId)
          craftLogger:info("Recipe for %s was provided by %s", name, k)
          break
        end
      end
      if not success then
        craftLogger:debug("No recipe found for %s", name)
        for k, v in pairs(createMissingNode(name, remaining, jobId)) do node[k] = v end
      end
      return remaining - node.count
    end

    function craft(name, count, jobId, force, requestChain)
      common.enforceType(name, 1, "string")
      common.enforceType(count, 2, "integer")
      common.enforceType(jobId, 3, "string")
      common.enforceType(force, 4, "boolean", "nil")
      common.enforceType(requestChain, 5, "table", "nil")
      requestChain = shallowClone(requestChain or {})
      if requestChain[name] then return { createMissingNode(name, count, jobId) } end
      requestChain[name] = true
      local nodes = {}
      local remaining = count
      craftLogger:debug("Remaining craft count for %s is %u", name, remaining)
      while remaining > 0 do
        local node = { name = name, taskId = id(), jobId = jobId, priority = 1 }
        local available = getCount(name)
        if available > 0 and not force then
          local allocateAmount = allocateItems(name, math.min(available, remaining), node.taskId)
          node.type = "ITEM"
          node.count = allocateAmount
          remaining = remaining - allocateAmount
          craftLogger:debug("Item. name:%s,count:%u,taskId:%s,jobId:%s", name, allocateAmount, node.taskId, jobId)
        else
          remaining = _attemptCraft(node, name, remaining, requestChain, jobId)
        end
        table.insert(nodes, node)
      end
      return nodes
    end

    local function runOnAll(root, func)
      common.enforceType(root, 1, "table")
      common.enforceType(func, 2, "function")
      func(root)
      if root.children then
        for _, v in pairs(root.children) do runOnAll(v, func) end
      end
    end

    local function removeFromArray(arr, val)
      common.enforceType(arr, 1, type(val) .. "[]")
      for i, v in ipairs(arr) do
        if v == val then table.remove(arr, i) end
      end
    end

    function deleteTask(task)
      common.enforceType(task, 1, "table")
      if task.type == "ITEM" then deallocateItems(task.name, task.count, task.taskId) end
      if task.parent then removeFromArray(task.parent.children, task) end
      assert(task.state == "DONE", "Attempt to delete not done task.")
      doneLookup[task.taskId] = nil
      assert(task.children == nil, "Attempt to delete task with children.")
      taskLookup[task.taskId] = nil
      removeFromArray(jobLookup[task.jobId], task)
      if #jobLookup[task.jobId] == 0 then jobLookup[task.jobId] = nil end
    end

    local nodeStateLogger = setmetatable({}, { __index = function() return function() end end })
    if log then nodeStateLogger = log.interface.logger("crafting", "node_state") end
    
    function changeNodeState(node, newState)
      if not node then error("No node?", 2) end
      if node.state == newState then return end
      if node.state == "WAITING" then removeFromArray(waitingQueue, node)
      elseif node.state == "READY" then removeFromArray(readyQueue, node)
      elseif node.state == "CRAFTING" then removeFromArray(craftingQueue, node)
      elseif node.state == "DONE" then doneLookup[node.taskId] = nil end
      node.state = newState
      if node.state == "WAITING" then table.insert(waitingQueue, node)
      elseif node.state == "READY" then table.insert(readyQueue, node)
      elseif node.state == "CRAFTING" then table.insert(craftingQueue, node)
      elseif node.state == "DONE" then
        doneLookup[node.taskId] = node
        os.queueEvent("crafting_node_done", node.taskId)
      end
    end

    local function pushItems(to, name, toMove, slot)
      common.enforceType(to, 1, "string")
      common.enforceType(name, 2, "string")
      common.enforceType(toMove, 3, "integer")
      common.enforceType(slot, 4, "integer")
      local failCount = 0
      while toMove > 0 do
        local transfered = loaded.inventory.interface.pushItems(false, to, name, toMove, slot, nil, { optimal = false })
        toMove = toMove - transfered
        if transfered == 0 then
          failCount = failCount + 1
          if failCount > 3 then error(("Unable to move %s"):format(name)) end
        end
      end
    end

    local readyHandlers = {}
    local function addReadyHandler(nodeType, func)
      common.enforceType(nodeType, 1, "string")
      common.enforceType(func, 2, "function")
      readyHandlers[nodeType] = func
    end

    local craftingHandlers = {}
    local function addCraftingHandler(nodeType, func)
      common.enforceType(nodeType, 1, "string")
      common.enforceType(func, 2, "function")
      craftingHandlers[nodeType] = func
    end

    local function deleteNodeChildren(node)
      common.enforceType(node, 1, "table")
      if not node.children then return end
      for _, child in pairs(node.children) do deleteTask(child) end
      node.children = nil
    end

    function tickNode(node)
      saveTaskLookup()
      common.enforceType(node, 1, "table")
      if not node.state then
        if node.type == "ROOT" then node.startTime = os.epoch("utc") end
        if node.children then changeNodeState(node, "WAITING")
        else changeNodeState(node, "DONE") end
        return
      end
      if node.state == "WAITING" then
        if node.children then
          local allChildrenDone = true
          for _, child in pairs(node.children) do
            allChildrenDone = child.state == "DONE"
            if not allChildrenDone then break end
          end
          if allChildrenDone then
            deleteNodeChildren(node)
            removeFromArray(waitingQueue, node)
            if node.type == "ROOT" then
              nodeStateLogger:info("Finished jobId:%s in %.2fsec", node.jobId, (os.epoch("utc") - node.startTime) / 1000)
              os.queueEvent("craft_job_done", node.jobId)
              changeNodeState(node, "DONE")
              deleteTask(node)
              return
            end
            changeNodeState(node, "READY")
          end
        else changeNodeState(node, "READY") end
      elseif node.state == "READY" then
        assert(readyHandlers[node.type], "No readyHandler for type " .. (node.type or "nil"))
        readyHandlers[node.type](node)
      elseif node.state == "CRAFTING" then
        assert(craftingHandlers[node.type], "No craftingHandler for type " .. (node.type or "nil"))
        craftingHandlers[node.type](node)
      elseif node.state == "DONE" and node.children then
        deleteNodeChildren(node)
      end
    end

    local function updateWholeTree(tree)
      common.enforceType(tree, 1, "table")
      runOnAll(tree, tickNode)
    end

    local function removeChildrensParents(node)
      common.enforceType(node, 1, "table")
      for k, v in pairs(node.children) do v.parent = nil end
    end

    local function cancelTask(taskId)
      common.enforceType(taskId, 1, "string")
      craftLogger:debug("Cancelling task %s", taskId)
      local task = taskLookup[taskId]
      if task.state then
        if task.state == "WAITING" then
          removeFromArray(waitingQueue, task)
          removeChildrensParents(task)
        elseif task.state == "READY" then
          removeFromArray(readyQueue, task)
          removeChildrensParents(task)
        end
        if task.type == "ITEM" then deallocateItems(task.name, task.count, task.taskId) end
        return
      end
      taskLookup[taskId] = nil
    end

    local pendingJobs = {}
    local function savePendingJobs()
      if not config.crafting.persistence.value then return end
      local flatPendingJobs = {}
      for jobIndex, job in pairs(pendingJobs) do
        local clone = shallowClone(job)
        runOnAll(clone, function(node)
          node.parent = nil
          for k, v in pairs(node.children or {}) do node.children[k] = shallowClone(v) end
        end)
        flatPendingJobs[jobIndex] = clone
      end
      local f = assert(fs.open(".cache/pending_jobs.json", "w"))
      f.write(json.encode(flatPendingJobs))
      f.close()
    end

    local function loadPendingJobs()
      if not config.crafting.persistence.value then
        pendingJobs = {}
        return
      end
      local f = fs.open(".cache/pending_jobs.json", "r")
      if f then
        local contents = f.readAll() or "{}"
        f.close()
        local decoded = json.decode(contents)
        if type(decoded) == "table" then pendingJobs = decoded
        else pendingJobs = {} print("Warning: Invalid pending jobs JSON format") end
      else pendingJobs = {} end
      runOnAll(pendingJobs, function(node)
        for k, v in pairs(node.children or {}) do v.parent = node end
      end)
    end

    local function cancelCraft(jobId)
      common.enforceType(jobId, 1, "string")
      craftLogger:info("Cancelling job %s", jobId)
      local jobRoot = jobLookup[jobId]
      if pendingJobs[jobId] then
        jobRoot = pendingJobs[jobId]
        pendingJobs[jobId] = nil
        savePendingJobs()
        return
      elseif not jobLookup[jobId] then
        craftLogger:warn("Attempt to cancel non-existant job %s", jobId)
      end
      for k, v in pairs(jobRoot or {}) do cancelTask(v.taskId) end
      jobLookup[jobId] = nil
      saveTaskLookup()
    end

    local function listJobs()
      local runningJobs = {}
      for k, v in pairs(jobLookup) do runningJobs[#runningJobs + 1] = k end
      return runningJobs
    end

    local function listTasks(job)
      local tasks = {}
      for k, v in pairs(jobLookup[job]) do tasks[#tasks + 1] = v.taskId end
      return tasks
    end

    local function tickCrafting()
      while true do
        local nodesTicked = false
        for k, v in pairs(taskLookup) do tickNode(v) nodesTicked = true end
        if nodesTicked then
          craftLogger:debug("Nodes processed in crafting tick.")
          saveTaskLookup()
        end
        local sleepTime = 1
        if config.crafting and config.crafting.tickInterval and type(config.crafting.tickInterval.value) == "number" then
          sleepTime = config.crafting.tickInterval.value
        else craftLogger:warn("Using default sleep time...") end
        os.sleep(sleepTime)
      end
    end

    local inventoryTransferLogger
    if log then inventoryTransferLogger = log.interface.logger("crafting", "inventory_transfer_listener") end
    local function inventoryTransferListener()
      while true do
        local _, transferId = os.pullEvent("inventoryFinished")
        local node = transferIdTaskLUT[transferId]
        if node then
          transferIdTaskLUT[transferId] = nil
          removeFromArray(node.transfers, transferId)
          if #node.transfers == 0 then
            if log then inventoryTransferLogger:debug("Node DONE, taskId:%s, jobId:%s", node.taskId, node.jobId) end
            changeNodeState(node, "DONE")
            tickNode(node)
          end
        end
      end
    end

    local function createCraftJob(name, count)
      common.enforceType(name, 1, "string")
      common.enforceType(count, 2, "integer")
      local jobId = id()
      craftLogger:debug("New job. name:%s,count:%u,jobId:%s", name, count, jobId)
      craftLogger:info("Requested craft for %ux%s", count, name)
      local job = craft(name, count, jobId, true)
      local root = { jobId = jobId, children = job, type = "ROOT", taskId = id(), time = os.epoch("utc") }
      pendingJobs[jobId] = root
      savePendingJobs()
      return jobId
    end

    local function getJobInfo(root)
      common.enforceType(root, 1, "table")
      local ret = { success = true, toCraft = {}, toUse = {}, missing = {}, jobId = root.jobId }
      runOnAll(root, function(node)
        if node.type == "ITEM" then ret.toUse[node.name] = (ret.toUse[node.name] or 0) + node.count
        elseif node.type == "MISSING" then
          ret.success = false
          ret.missing[node.name] = (ret.missing[node.name] or 0) + node.count
        elseif node.type ~= "ROOT" then
          ret.toCraft[node.name] = (ret.toCraft[node.name] or 0) + (node.count or 0)
        end
      end)
      return ret
    end

    local function requestCraft(name, count)
      common.enforceType(name, 1, "string")
      common.enforceType(count, 2, "integer")
      local jobId = createCraftJob(name, count)
      craftLogger:debug("Request craft called for %u %s(s), returning job ID %s", count, name, jobId)
      local jobInfo = getJobInfo(pendingJobs[jobId])
      if not jobInfo.success then
        craftLogger:debug("Craft job failed, cancelling")
        savePendingJobs()
      end
      return jobInfo
    end

    local function startCraft(jobId)
      common.enforceType(jobId, 1, "string")
      craftLogger:debug("Start craft called for job ID %s", jobId)
      local job = pendingJobs[jobId]
      if not job then return false end
      local jobInfo = getJobInfo(job)
      if not jobInfo.success then return false end
      pendingJobs[jobId] = nil
      savePendingJobs()
      jobLookup[jobId] = {}
      runOnAll(job, function(node)
        taskLookup[node.taskId] = node
        table.insert(jobLookup[jobId], node)
      end)
      updateWholeTree(job)
      saveTaskLookup()
      return true
    end

    local cleanupLogger = setmetatable({}, { __index = function() return function() end end })
    if log then cleanupLogger = log.interface.logger("crafting", "cleanup") end
    local function cleanupHandler()
      while true do
        local sleepTime = 60
        if config.crafting and config.crafting.cleanupInterval and type(config.crafting.cleanupInterval.value) == "number" then
          sleepTime = config.crafting.cleanupInterval.value
        else cleanupLogger:warn("Using default sleep time...") end
        os.sleep(sleepTime)
        cleanupLogger:debug("Performing cleanup!")
        for k, v in pairs(pendingJobs) do
          if v.time + 200000 < os.epoch("utc") then pendingJobs[k] = nil end
        end
        for k, v in pairs(jobLookup) do
          if #v == 0 then jobLookup[k] = nil end
        end
        for name, nodes in pairs(reservedItems) do
          for nodeId, count in pairs(nodes) do
            if not taskLookup[nodeId] then deallocateItems(name, count, nodeId) end
          end
        end
      end
    end

    local autoCraftLogger = setmetatable({}, { __index = function() return function() end end })
    if log then autoCraftLogger = log.interface.logger("crafting", "auto_craft") end

    local function shouldAutoCraftItem(name)
      local rules = config.crafting and config.crafting.autoCraftingRules and config.crafting.autoCraftingRules.value or {}
      local rule = rules[name]
      if not rule or type(rule) ~= "table" or type(rule.threshold) ~= "number" then return false, 0 end
      local currentCount = getCount(name)
      if currentCount < rule.threshold then return true, rule.threshold - currentCount end
      return false, 0
    end

    local function shouldAutoSmeltItem(name)
      local rules = config.crafting and config.crafting.autoSmeltingRules and config.crafting.autoSmeltingRules.value or {}
      local rule = rules[name]
      if not rule or type(rule) ~= "table" or type(rule.threshold) ~= "number" or not rule.output then return false, 0 end
      local currentCount = getCount(name)
      if currentCount < rule.threshold then return true, rule.threshold - currentCount end
      return false, 0
    end

    local function checkAutoCrafting()
      autoCraftLogger:debug("Checking for auto-crafting/smelting opportunities...")
      local autoCraftingRules = config.crafting and config.crafting.autoCraftingRules and config.crafting.autoCraftingRules.value or {}
      for item, rule in pairs(autoCraftingRules) do
        if type(rule) == "table" and type(rule.threshold) == "number" then
          local shouldCraft, neededCount = shouldAutoCraftItem(item)
          if shouldCraft then
            local jobInfo = requestCraft(item, neededCount)
            if jobInfo.success then startCraft(jobInfo.jobId) end
          end
        else autoCraftLogger:warn("Invalid auto-crafting rule for item %s", item) end
      end
      local autoSmeltingRules = config.crafting and config.crafting.autoSmeltingRules and config.crafting.autoSmeltingRules.value or {}
      for item, rule in pairs(autoSmeltingRules) do
        if type(rule) == "table" and type(rule.threshold) == "number" and rule.output then
          local shouldSmelt, neededCount = shouldAutoSmeltItem(item)
          if shouldSmelt then
            local jobInfo = requestCraft(rule.output, neededCount)
            if jobInfo.success then startCraft(jobInfo.jobId) end
          end
        else autoCraftLogger:warn("Invalid auto-smelting rule for item %s", item) end
      end
    end

    local function autoCraftChecker()
      while true do
        local sleepTime = 10
        if config.crafting and config.crafting.tickInterval and type(config.crafting.tickInterval.value) == "number" then
          sleepTime = config.crafting.tickInterval.value * 10
        else autoCraftLogger:warn("Using default sleep time...") end
        sleep(sleepTime)
        checkAutoCrafting()
      end
    end

    local function jsonFileImport()
      print("JSON file importing ready..")
      while true do
        local e, transfer = os.pullEvent("file_transfer")
        for _, file in ipairs(transfer.getFiles()) do
          local contents = file.readAll()
          local json = json.decode(contents)
          if type(json) == "table" then
            if loadJson(json) then print(("Successfully imported %s"):format(file.getName()))
            else print(("Failed to import %s, no handler for %s"):format(file.getName(), json.type)) end
          else print(("Failed to import %s, not a JSON file"):format(file.getName())) end
          file.close()
        end
      end
    end

    ---@class modules.crafting.interface
    return {
      start = function()
        loadTaskLookup()
        loadItemLookup()
        loadReservedItems()
        loadCachedTags()
        loadPendingJobs()
        loadAliases() -- Load the tags/aliases from recipes.json on start
        parallel.waitForAny(tickCrafting, inventoryTransferListener, jsonFileImport, cleanupHandler, autoCraftChecker)
      end,
      requestCraft = requestCraft,
      startCraft = startCraft,
      loadJson = loadJson,
      listCraftables = listCraftables,
      cancelCraft = cancelCraft,
      listJobs = listJobs,
      listTasks = listTasks,
      recipeInterface = {
        changeNodeState = changeNodeState,
        tickNode = tickNode,
        getBestItem = getBestItem,
        getStackSize = getStackSize,
        mergeInto = mergeInto,
        craft = craft,
        pushItems = pushItems,
        addCraftingHandler = addCraftingHandler,
        addReadyHandler = addReadyHandler,
        addCraftType = addCraftType,
        deleteNodeChildren = deleteNodeChildren,
        deleteTask = deleteTask,
        getOrCacheString = getOrCacheString,
        addJsonTypeHandler = addJsonTypeHandler,
        addCraftableList = addCraftableList,
        createMissingNode = createMissingNode,
        getString = getString
      }
    }
  end
}