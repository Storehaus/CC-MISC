local common = require("common")
---@class modules.crafting
---@field interface modules.crafting.interface
return {
  id = "crafting",
  version = "1.4.1",
    config = {
    tagLookup = {
      type = "table",
      description = "Force a given item to be used for a tag lookup. Map from tag->item.",
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
    ---@alias ItemInfo {[1]: string, tag: boolean?}

    ---@alias ItemIndex integer

    ---@type ItemInfo[]
    -- lookup into an ordered list of item names
    local itemLookup = {}
    ---@type table<string,ItemIndex> lookup from name -> item_lookup index
    local itemNameLookup = {}

    local bfile = require("bfile")
    bfile.addType("tag_boolean", function(f)
      if f.read(1) == "T" then
        return true
      end
      return false
    end, function(f, v)
      if v then
        f.write("T")
      else
        f.write("I")
      end
    end)
    bfile.newStruct("item_lookup_entry"):add("tag_boolean", "tag"):add("string", 1)
    bfile.newStruct("item_lookup"):constant("ILUT"):add("item_lookup_entry[*]", "^")

    local function saveItemLookup()
      bfile.getStruct("item_lookup"):writeFile("recipes/item_lookup.bin", itemLookup)
    end
    local function loadItemLookup()
      itemLookup = bfile.getStruct("item_lookup"):readFile("recipes/item_lookup.bin") or {}
      for k, v in pairs(itemLookup) do
        itemNameLookup[v[1]] = k
      end
    end

    ---Get the index of a string or tag, creating one if one doesn't exist already
    ---@param str string
    ---@param tag boolean|nil
    ---@return ItemIndex
    local function getOrCacheString(str, tag)
      common.enforceType(str, 1, "string")
      common.enforceType(tag, 2, "boolean", "nil")
      if itemNameLookup[str] then
        return itemNameLookup[str]
      end
      local i = #itemLookup + 1
      itemLookup[i] = { str, tag = not not tag }
      itemNameLookup[str] = i
      saveItemLookup() -- updated item lookup
      return i
    end

    local jsonLogger = setmetatable({}, {
      __index = function()
        return function()
        end
      end
    })
    if log then
      jsonLogger = log.interface.logger("crafting", "json_importing")
    end
    local jsonTypeHandlers = {}
    ---Add a JSON type handler, this should load a recipe from the given JSON table
    ---@param jsonType string
    ---@param handler fun(json: table)
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

    ---@type CraftingNode[] tasks that have unmet dependencies
    local waitingQueue = {}
    ---@type CraftingNode[] tasks that have all dependencies met
    local readyQueue = {}
    ---@type CraftingNode[] tasks that are in progress
    local craftingQueue = {}

    ---@type table<string,CraftingNode> tasks that have been completed, but are still relavant
    local doneLookup = {}

    ---@type table<string,CraftingNode>
    local transferIdTaskLUT = {}

    local tickNode, changeNodeState, deleteTask

    --- ITEM - this node represents a quantity of items from the network
    --- ROOT - this node represents the root of a crafting task

    ---@alias NodeState string | "WAITING" | "READY" | "CRAFTING" | "DONE"

    ---@class CraftingNode
    ---@field children CraftingNode[]|nil
    ---@field parent CraftingNode|nil
    ---@field type "ITEM" | "ROOT" | "MISSING"
    ---@field name string
    ---@field count integer amount of this item to produce
    ---@field taskId string
    ---@field jobId string
    ---@field state NodeState
    ---@field priority integer TODO

    ---@type table<string,table<string,integer>> item name -> count reserved
    local reservedItems = {}

    bfile.addAlias("string_uint16_map", "map<string,uint16>")
    bfile.newStruct("reserved_items"):add("map<string,string_uint16_map>", "^")

    local function saveReservedItems()
      if not config.crafting.persistence.value then
        return
      end
      common.saveTableToFile(".cache/reserved_items.txt", reservedItems)
    end

    local function loadReservedItems()
      if not config.crafting.persistence.value then
        reservedItems = {}
        return
      end
      reservedItems = common.loadTableFromFile(".cache/reserved_items.txt") or {}
    end

    ---Get count of item in system, excluding reserved
    ---@param name string
    ---@return integer
    local function getCount(name)
      common.enforceType(name, 1, "string")
      local reservedCount = 0
      for k, v in pairs(reservedItems[name] or {}) do
        -- TODO add check to ensure this is not leaked
        reservedCount = reservedCount + v
      end
      return loaded.inventory.interface.getCount(name) - reservedCount
    end

    ---Reserve amount of item name
    ---@param name string
    ---@param amount integer
    ---@param taskId string
    ---@return integer
    local function allocateItems(name, amount, taskId)
      common.enforceType(name, 1, "string")
      common.enforceType(amount, 2, "integer")
      reservedItems[name] = reservedItems[name] or {}
      reservedItems[name][taskId] = (reservedItems[name][taskId] or 0) + amount
      saveReservedItems()
      return amount
    end

    ---Free amount of item name
    ---@param name string
    ---@param amount integer
    ---@param taskId string
    ---@return integer
    local function deallocateItems(name, amount, taskId)
      common.enforceType(name, 1, "string")
      common.enforceType(amount, 2, "integer")

      -- Ensure reservedItems[name] and reservedItems[name][taskId] exist
      if not reservedItems[name] or not reservedItems[name][taskId] then
        -- Items were not reserved, this can happen when crafting completes successfully
        -- and items were already consumed, or when tasks are cleaned up properly
        if log then
          craftLogger:debug("Attempt to deallocate items that are not reserved (name: %s, amount: %d, taskId: %s)", name, amount, taskId)
        else
          print("Attempt to deallocate items that are not reserved")
        end
        return 0
      end

      reservedItems[name][taskId] = reservedItems[name][taskId] - amount
      assert(reservedItems[name][taskId] >= 0, "We have negative items reserved?")
      if reservedItems[name][taskId] == 0 then
        reservedItems[name][taskId] = nil
      end
      if not next(reservedItems[name]) then
        reservedItems[name] = nil
      end
      saveReservedItems()
      return amount
    end

    local cachedStackSizes = {}

    ---Get the maximum stacksize of an item by name
    ---@param name string
    local function getStackSize(name)
      common.enforceType(name, 1, "string")
      if cachedStackSizes[name] then
        return cachedStackSizes[name]
      end
      local item = loaded.inventory.interface.getItem(name)
      cachedStackSizes[name] = (item and item.item and item.item.maxCount) or 64
      return cachedStackSizes[name]
    end

    local lastId = 0
    ---Get a psuedorandom uuid
    ---@return string
    local function id()
      lastId = lastId + 1
      local genId = lastId .. "$"
      return genId
    end

    ---@type table<string,string[]>
    local craftableLists = {}
    ---Set the table of craftable items for a given id
    ---@param id string ID of crafting module/type
    ---@param list string[] table of craftable item names, assigned by reference
    local function addCraftableList(id, list)
      common.enforceType(id, 1, "string")
      common.enforceType(list, 2, "string[]")
      craftableLists[id] = list
    end

    ---List all the items that are craftable
    ---@return string[]
    local function listCraftables()
      local l = {}
      for k, v in pairs(craftableLists) do
        for i, s in ipairs(v) do
          table.insert(l, s)
        end
      end
      return l
    end

    bfile.newStruct("cached_tags"):add("map<string,string[uint16]>", "^")

    ---@type table<string,string[]> tag -> item names
    local cachedTagLookup = {}

    local function saveCachedTags()
      bfile.getStruct("cached_tags"):writeFile(".cache/cached_tags.bin", cachedTagLookup)
    end

    ---@type table<string,table<string,boolean>> tag -> item name -> is it in cached_tag_lookup
    local cachedTagPresence = {}

    local function loadCachedTags()
      cachedTagLookup = bfile.getStruct("cached_tags"):readFile(".cache/cached_tags.bin") or {}
      cachedTagPresence = {}
      for tag, names in pairs(cachedTagLookup) do
        cachedTagPresence[tag] = {}
        for _, name in ipairs(names) do
          cachedTagPresence[tag][name] = true
        end
      end
    end


    ---Select the best item from a tag
    ---@param tag string
    ---@return boolean success
    ---@return string itemName
    local function selectBestFromTag(tag)
      common.enforceType(tag, 1, "string")
      if config.crafting.tagLookup.value[tag] then
        return true, config.crafting.tagLookup.value[tag]
      end
      if not cachedTagPresence[tag] then
        cachedTagPresence[tag] = {}
        cachedTagLookup[tag] = {}
        saveCachedTags()
      end
      -- first check if we have anything
      local itemsWithTag = loaded.inventory.interface.getTag(tag)
      local itemsWithTagsCount = {}
      for k, v in ipairs(itemsWithTag) do
        if not cachedTagPresence[tag][v] then
          -- update the cache if it's not in there already
          cachedTagPresence[tag][v] = true
          table.insert(cachedTagLookup[tag], v)
          saveCachedTags()
        end
        itemsWithTagsCount[k] = { name = v, count = loaded.inventory.interface.getCount(v) }
      end
      table.sort(itemsWithTagsCount, function(a, b) return a.count > b.count end)
      if itemsWithTagsCount[1] then
        return true, itemsWithTagsCount[1].name
      end

      -- then check if we can craft anything
      local craftableList = listCraftables()
      local isCraftableLUT = {}
      for k, v in pairs(craftableList) do
        isCraftableLUT[v] = true
      end

      for k, v in pairs(cachedTagLookup[tag]) do
        if isCraftableLUT[v] then
          return true, v -- this is not the best way of doing this.
        end
      end

      -- no solution found
      return false, tag
    end

    ---Select the best item from an index
    ---@param index ItemIndex
    ---@return boolean success
    ---@return string itemName
    local function selectBestFromIndex(index)
      common.enforceType(index, 1, "integer")
      local itemInfo = assert(itemLookup[index], "Invalid item index")
      if itemInfo.tag then
        return selectBestFromTag(itemInfo[1])
      end
      return true, itemInfo[1]
    end

    ---Select the best item from a list of ItemIndex
    ---@param list ItemIndex[]
    ---@return boolean success
    ---@return string itemName
    local function selectBestFromList(list)
      common.enforceType(list, 1, "integer[]")
      return true, itemLookup[list[1]][1]
    end

    ---Select the best item
    ---@param item ItemIndex[]|ItemIndex
    ---@return boolean success
    ---@return string name itemname if success, otherwise tag
    local function getBestItem(item)
      common.enforceType(item, 1, "integer[]", "integer")
      if type(item) == "table" then
        return selectBestFromList(item)
      elseif type(item) == "number" then
        return selectBestFromIndex(item)
      end
      error("Invalid type " .. type(item), 2)
    end

    ---Get the string for a given index
    ---@param v integer
    ---@return string string
    ---@return boolean tag
    local function getString(v)
      local itemInfo = itemLookup[v]
      assert(itemInfo, "Invalid key passed to getString")
      return itemInfo[1], itemInfo.tag
    end

    ---Merge from into the end of to
    ---@param from table
    ---@param to table
    local function mergeInto(from, to)
      common.enforceType(from, 1, "table")
      common.enforceType(to, 1, "table")
      for k, v in pairs(from) do
        table.insert(to, v)
      end
    end


    ---Lookup from taskId to the corrosponding CraftingNode
    ---@type table<string,CraftingNode>
    local taskLookup = {}

    ---Lookup from jobId to the corrosponding CraftingNode
    ---@type table<string,CraftingNode[]>
    local jobLookup = {}

    ---Shallow clone a table
    ---@param t table
    ---@return table
    local function shallowClone(t)
      common.enforceType(t, 1, "table")
      local nt = {}
      for k, v in pairs(t) do
        nt[k] = v
      end
      return nt
    end

    local function saveTaskLookup()
      if not config.crafting.persistence.value then
        return
      end
      local flatTaskLookup = {}
      for k, v in pairs(taskLookup) do
        flatTaskLookup[k] = shallowClone(v)
        local flatTask = flatTaskLookup[k]
        if v.parent then
          flatTask.parent = v.parent.taskId
        end
        if v.children then
          flatTask.children = {}
          for i, ch in pairs(v.children) do
            flatTask.children[i] = ch.taskId
          end
        end
      end
      local f = assert(fs.open(".cache/flat_task_lookup.bin", "wb"))
      f.write(bfile.serialise(flatTaskLookup))
      f.close()
    end

    local function loadTaskLookup()
      if not config.crafting.persistence.value then
        taskLookup = {}
        return
      end
      local taskLoaderLogger = setmetatable({}, {
        __index = function()
          return function()
          end
        end
      })
      if log then
        taskLoaderLogger = log.interface.logger("crafting", "loadTaskLookup")
      end
      local f = fs.open(".cache/flat_task_lookup.bin", "rb")
      if f then
        taskLookup = bfile.unserialise(f.readAll() or "")
        f.close()
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
        if v.parent then
          v.parent = taskLookup[v.parent]
        end
        if v.children then
          for i, ch in pairs(v.children) do
            v.children[i] = taskLookup[ch]
          end
        end
        if v.state then
          if v.state == "WAITING" then
            table.insert(waitingQueue, v)
          elseif v.state == "READY" then
            table.insert(readyQueue, v)
          elseif v.state == "CRAFTING" then
            table.insert(craftingQueue, v)
          elseif v.state == "DONE" then
            doneLookup[v.taskId] = v
          else
            error("Invalid state on load")
          end
        end
      end
    end

    local craftLogger = setmetatable({}, {
      __index = function()
        return function()
        end
      end
    })
    if log then
      craftLogger = log.interface.logger("crafting", "request_craft")
    end
    local craft
    ---@type table<string,fun(node:CraftingNode,name:string,count:integer,request_chain:table):boolean>
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
      return {
        name = name,
        jobId = jobId,
        taskId = id(),
        count = count,
        type = "MISSING"
      }
    end

    ---Attempt a craft
    ---@param node CraftingNode
    ---@param name string
    ---@param remaining integer
    ---@param requestChain table
    ---@param jobId string
    ---@return number
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
          craftLogger:debug("Recipe found. provider:%s,name:%s,count:%u,taskId:%s,jobId:%s", k, name, node.count,
            node.taskId, jobId)
          craftLogger:info("Recipe for %s was provided by %s", name, k)
          break
        end
      end
      if not success then
        craftLogger:debug("No recipe found for %s", name)
        for k, v in pairs(createMissingNode(name, remaining, jobId)) do
          node[k] = v
        end
      end
      return remaining - node.count
    end

    ---@param name string item name
    ---@param count integer
    ---@param jobId string
    ---@param force boolean|nil
    ---@param requestChain table<string,boolean>|nil table of item names that have been requested
    ---@return CraftingNode[] leaves ITEM|MISSING|other node
    function craft(name, count, jobId, force, requestChain)
      common.enforceType(name, 1, "string")
      common.enforceType(count, 2, "integer")
      common.enforceType(jobId, 3, "string")
      common.enforceType(force, 4, "boolean", "nil")
      common.enforceType(requestChain, 5, "table", "nil")
      requestChain = shallowClone(requestChain or {})
      if requestChain[name] then
        return { createMissingNode(name, count, jobId) }
      end
      requestChain[name] = true
      ---@type CraftingNode[]
      local nodes = {}
      local remaining = count
      craftLogger:debug("Remaining craft count for %s is %u", name, remaining)
      while remaining > 0 do
        ---@type CraftingNode
        local node = {
          name = name,
          taskId = id(),
          jobId = jobId,
          priority = 1,
        }
        -- First check if we have any of this
        local available = getCount(name)
        if available > 0 and not force then
          -- we do, so allocate it
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

    ---Run the given function an all nodes of the given tree
    ---@param root CraftingNode root
    ---@param func fun(node: CraftingNode)
    local function runOnAll(root, func)
      common.enforceType(root, 1, "table")
      common.enforceType(func, 2, "function")
      func(root)
      if root.children then
        for _, v in pairs(root.children) do
          runOnAll(v, func)
        end
      end
    end

    ---Remove an object from a table
    ---@generic T : any
    ---@param arr T[]
    ---@param val T
    local function removeFromArray(arr, val)
      common.enforceType(arr, 1, type(val) .. "[]")
      for i, v in ipairs(arr) do
        if v == val then
          table.remove(arr, i)
        end
      end
    end

    ---Delete a given task, asserting the task is DONE and has no children
    ---@param task CraftingNode
    function deleteTask(task)
      common.enforceType(task, 1, "table")
      if task.type == "ITEM" then
        deallocateItems(task.name, task.count, task.taskId)
      end
      if task.parent then
        removeFromArray(task.parent.children, task)
      end
      assert(task.state == "DONE", "Attempt to delete not done task.")
      doneLookup[task.taskId] = nil
      assert(task.children == nil, "Attempt to delete task with children.")
      taskLookup[task.taskId] = nil
      removeFromArray(jobLookup[task.jobId], task)
      if #jobLookup[task.jobId] == 0 then
        jobLookup[task.jobId] = nil
      end
    end

    local nodeStateLogger = setmetatable({}, {
      __index = function()
        return function()
        end
      end
    })
    if log then
      nodeStateLogger = log.interface.logger("crafting", "node_state")
    end
    ---Safely change a node to a new state
    ---Only modifies the node's state and related caches
    ---@param node CraftingNode
    ---@param newState NodeState
    function changeNodeState(node, newState)
      if not node then
        error("No node?", 2)
      end
      if node.state == newState then
        return
      end
      if node.state == "WAITING" then
        removeFromArray(waitingQueue, node)
      elseif node.state == "READY" then
        removeFromArray(readyQueue, node)
      elseif node.state == "CRAFTING" then
        removeFromArray(craftingQueue, node)
      elseif node.state == "DONE" then
        doneLookup[node.taskId] = nil
      end
      node.state = newState
      if node.state == "WAITING" then
        table.insert(waitingQueue, node)
      elseif node.state == "READY" then
        table.insert(readyQueue, node)
      elseif node.state == "CRAFTING" then
        table.insert(craftingQueue, node)
      elseif node.state == "DONE" then
        doneLookup[node.taskId] = node
        os.queueEvent("crafting_node_done", node.taskId)
      end
    end

    ---Protected pushItems, errors if it cannot move
    ---enough items to a slot
    ---@param to string
    ---@param name string
    ---@param toMove integer
    ---@param slot integer
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
          if failCount > 3 then
            error(("Unable to move %s"):format(name))
          end
        end
      end
    end

    ---@type table<string,fun(node: CraftingNode)> Process an item in the READY state
    local readyHandlers = {}

    ---@param nodeType string
    ---@param func fun(node: CraftingNode)>
    local function addReadyHandler(nodeType, func)
      common.enforceType(nodeType, 1, "string")
      common.enforceType(func, 2, "function")
      readyHandlers[nodeType] = func
    end

    ---@type table<string,fun(node: CraftingNode)> Process an item that is in the CRAFTING state
    local craftingHandlers = {}

    ---@param nodeType string
    ---@param func fun(node: CraftingNode)>
    local function addCraftingHandler(nodeType, func)
      common.enforceType(nodeType, 1, "string")
      common.enforceType(func, 2, "function")
      craftingHandlers[nodeType] = func
    end

    ---Deletes all the node's children, calling delete_task on each
    local function deleteNodeChildren(node)
      common.enforceType(node, 1, "table")
      if not node.children then
        return
      end
      for _, child in pairs(node.children) do
        deleteTask(child)
      end
      node.children = nil
    end

    ---Update the state of the given node
    ---@param node CraftingNode
    function tickNode(node)
      saveTaskLookup()
      common.enforceType(node, 1, "table")
      if not node.state then
        if node.type == "ROOT" then
          node.startTime = os.epoch("utc")
        end
        -- This is an uninitialized node
        -- leaf -> set state to READY
        -- otherwise -> set state to WAITING
        if node.children then
          changeNodeState(node, "WAITING")
        else
          changeNodeState(node, "DONE")
        end
        return
      end
      -- this is a node that has been updated before
      if node.state == "WAITING" then
        if node.children then
          -- this has children it depends upon
          local allChildrenDone = true
          for _, child in pairs(node.children) do
            allChildrenDone = child.state == "DONE"
            if not allChildrenDone then
              break
            end
          end
          if allChildrenDone then
            -- this is ready to be crafted
            deleteNodeChildren(node)
            removeFromArray(waitingQueue, node)
            if node.type == "ROOT" then
              -- This task is the root of a job
              nodeStateLogger:info("Finished jobId:%s in %.2fsec", node.jobId, (os.epoch("utc") - node.startTime) / 1000)
              os.queueEvent("craft_job_done", node.jobId)
              changeNodeState(node, "DONE")
              deleteTask(node)
              return
            end
            changeNodeState(node, "READY")
          end
        else
          changeNodeState(node, "READY")
        end
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

    ---Update every node on the tree
    ---@param tree CraftingNode
    local function updateWholeTree(tree)
      common.enforceType(tree, 1, "table")
      -- traverse to each node of the tree
      runOnAll(tree, tickNode)
    end

    ---Remove the parent of each child
    ---@param node CraftingNode
    local function removeChildrensParents(node)
      common.enforceType(node, 1, "table")
      for k, v in pairs(node.children) do
        v.parent = nil
      end
    end

    ---Safely cancel a task by ID
    ---@param taskId string
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
        if task.type == "ITEM" then
          deallocateItems(task.name, task.count, task.taskId)
        end
        -- if it's not in these two states, then it's not cancellable
        return
      end
      taskLookup[taskId] = nil
    end

    ---@type table<JobId,CraftingNode>
    local pendingJobs = {}

    local function savePendingJobs()
      if not config.crafting.persistence.value then
        return
      end
      local flatPendingJobs = {}
      for jobIndex, job in pairs(pendingJobs) do
        local clone = shallowClone(job)
        runOnAll(clone, function(node)
          node.parent = nil
          for k, v in pairs(node.children or {}) do
            node.children[k] = shallowClone(v)
          end
        end)
        flatPendingJobs[jobIndex] = clone
      end
      local f = assert(fs.open(".cache/pending_jobs.bin", "wb"))
      f.write(bfile.serialise(flatPendingJobs))
      f.close()
    end

    local function loadPendingJobs()
      if not config.crafting.persistence.value then
        pendingJobs = {}
        return
      end
      local f = fs.open(".cache/pending_jobs.bin", "rb")
      if f then
        pendingJobs = bfile.unserialise(f.readAll() or "")
        f.close()
      else
        pendingJobs = {}
      end
      runOnAll(pendingJobs, function(node)
        for k, v in pairs(node.children or {}) do
          v.parent = node
        end
      end)
    end

    ---Cancel a job by given id
    ---@param jobId any
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
      for k, v in pairs(jobRoot or {}) do
        cancelTask(v.taskId)
      end
      jobLookup[jobId] = nil
      saveTaskLookup()
    end

    ---Get a list of all running jobIds
    ---@return string[]
    local function listJobs()
      local runningJobs = {}
      for k, v in pairs(jobLookup) do
        runningJobs[#runningJobs + 1] = k
      end
      return runningJobs
    end

    ---Get a list of taskIds for a given job
    local function listTasks(job)
      local tasks = {}
      for k, v in pairs(jobLookup[job]) do
        tasks[#tasks + 1] = v.taskId
      end
      return tasks
    end

    local function tickCrafting()
      while true do
        local nodesTicked = false
        for k, v in pairs(taskLookup) do
          tickNode(v)
          nodesTicked = true
        end
        if nodesTicked then
          craftLogger:debug("Nodes processed in crafting tick.")
          saveTaskLookup()
        end
        -- Use default value if config is not properly initialized
        local sleepTime = 1
        if config.crafting and config.crafting.tickInterval and type(config.crafting.tickInterval.value) == "number" then
          sleepTime = config.crafting.tickInterval.value
        else
          craftLogger:warn("Using default sleep time for crafting tick (config.crafting.tickInterval.value not available)")
        end
        os.sleep(sleepTime)
      end
    end

    local inventoryTransferLogger
    if log then
      inventoryTransferLogger = log.interface.logger("crafting", "inventory_transfer_listener")
    end
    local function inventoryTransferListener()
      while true do
        local _, transferId = os.pullEvent("inventoryFinished")
        ---@type CraftingNode
        local node = transferIdTaskLUT[transferId]
        if node then
          transferIdTaskLUT[transferId] = nil
          removeFromArray(node.transfers, transferId)
          if #node.transfers == 0 then
            if log then
              inventoryTransferLogger:debug("Node DONE, taskId:%s, jobId:%s", node.taskId, node.jobId)
            end
            -- all transfers finished
            changeNodeState(node, "DONE")
            tickNode(node)
          end
        end
      end
    end


    ---@param name string
    ---@param count integer
    ---@return JobId pendingJobId
    local function createCraftJob(name, count)
      common.enforceType(name, 1, "string")
      common.enforceType(count, 2, "integer")
      local jobId = id()

      craftLogger:debug("New job. name:%s,count:%u,jobId:%s", name, count, jobId)
      craftLogger:info("Requested craft for %ux%s", count, name)
      local job = craft(name, count, jobId, true)

      ---@type CraftingNode
      local root = {
        jobId = jobId,
        children = job,
        type = "ROOT",
        taskId = id(),
        time = os.epoch("utc"),
      }

      pendingJobs[jobId] = root
      savePendingJobs()

      return jobId
    end

    ---@alias jobInfo {success: boolean, toCraft: table<string,integer>, toUse: table<string,integer>, missing: table<string,integer>|nil, jobId: JobId}

    ---Extract information from a job root
    ---@param root CraftingNode
    ---@return jobInfo
    local function getJobInfo(root)
      common.enforceType(root, 1, "table")
      local ret = {}
      ret.success = true
      ret.toCraft = {}
      ret.toUse = {}
      ret.missing = {}
      ret.jobId = root.jobId
      runOnAll(root, function(node)
        if node.type == "ITEM" then
          ret.toUse[node.name] = (ret.toUse[node.name] or 0) + node.count
        elseif node.type == "MISSING" then
          ret.success = false
          ret.missing[node.name] = (ret.missing[node.name] or 0) + node.count
        elseif node.type ~= "ROOT" then
          ret.toCraft[node.name] = (ret.toCraft[node.name] or 0) + (node.count or 0)
        end
      end)
      return ret
    end

    ---Request a craft job, returning info about it
    ---@param name string
    ---@param count integer
    ---@return jobInfo
    local function requestCraft(name, count)
      common.enforceType(name, 1, "string")
      common.enforceType(count, 2, "integer")
      local jobId = createCraftJob(name, count)
      craftLogger:debug("Request craft called for %u %s(s), returning job ID %s", count, name, jobId)
      local jobInfo = getJobInfo(pendingJobs[jobId])
      if not jobInfo.success then
        craftLogger:debug("Craft job failed, cancelling")
        -- cancelCraft(jobId)
        savePendingJobs()
      end
      return jobInfo
    end

    ---Start a given job, if it's pending
    ---@param jobId JobId
    ---@return boolean success
    local function startCraft(jobId)
      common.enforceType(jobId, 1, "string")
      craftLogger:debug("Start craft called for job ID %s", jobId)
      local job = pendingJobs[jobId]
      if not job then
        return false
      end
      local jobInfo = getJobInfo(job)
      if not jobInfo.success then
        return false -- cannot start unsuccessful job
      end
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

    local cleanupLogger = setmetatable({}, {
      __index = function()
        return function()
        end
      end
    })
    if log then
      cleanupLogger = log.interface.logger("crafting", "cleanup")
    end
    local function cleanupHandler()
      while true do
        -- Use default value if config is not properly initialized
        local sleepTime = 60
        if config.crafting and config.crafting.cleanupInterval and type(config.crafting.cleanupInterval.value) == "number" then
          sleepTime = config.crafting.cleanupInterval.value
        else
          cleanupLogger:warn("Using default sleep time for cleanup handler (config.crafting.cleanupInterval.value not available)")
        end
        os.sleep(sleepTime)
        cleanupLogger:debug("Performing cleanup!")
        for k, v in pairs(pendingJobs) do
          if v.time + 200000 < os.epoch("utc") then
            -- this job is too old
            cleanupLogger:debug("Removing JobId %s from the pending queue, as it is too old.", v.jobId)
            pendingJobs[k] = nil
          end
        end
        for k, v in pairs(jobLookup) do
          if #v == 0 then
            cleanupLogger:debug("No tasks with JobId %s, removing from the lookkup.", k)
            jobLookup[k] = nil
          end
        end
        for name, nodes in pairs(reservedItems) do
          for nodeId, count in pairs(nodes) do
            if not taskLookup[nodeId] then
              cleanupLogger:debug("Deallocating %u of item %s, Node %s is not in the task lookup.", count, name, nodeId)
              deallocateItems(name, count, nodeId)
            end
          end
        end
      end
    end

    ---Auto-crafting/smelting functionality
    local autoCraftLogger = setmetatable({}, {
      __index = function()
        return function()
        end
      end
    })
    if log then
      autoCraftLogger = log.interface.logger("crafting", "auto_craft")
    end

    ---Check if an item should be auto-crafted based on current inventory count
    ---@param name string
    ---@return boolean shouldCraft
    ---@return integer neededCount
    local function shouldAutoCraftItem(name)
      local rules = config.crafting and config.crafting.autoCraftingRules and config.crafting.autoCraftingRules.value or {}
      local rule = rules[name]
      if not rule or type(rule) ~= "table" or type(rule.threshold) ~= "number" then return false, 0 end

      local currentCount = getCount(name)
      if currentCount < rule.threshold then
        return true, rule.threshold - currentCount
      end
      return false, 0
    end

    ---Check if an item should be auto-smelted based on current inventory count
    ---@param name string
    ---@return boolean shouldSmelt
    ---@return integer neededCount
    local function shouldAutoSmeltItem(name)
      local rules = config.crafting and config.crafting.autoSmeltingRules and config.crafting.autoSmeltingRules.value or {}
      local rule = rules[name]
      if not rule or type(rule) ~= "table" or type(rule.threshold) ~= "number" or not rule.output then return false, 0 end

      local currentCount = getCount(name)
      if currentCount < rule.threshold then
        return true, rule.threshold - currentCount
      end
      return false, 0
    end

    ---Check all items and trigger auto-crafting/smelting
    local function checkAutoCrafting()
      autoCraftLogger:debug("Checking for auto-crafting/smelting opportunities...")

      -- Check auto-crafting rules with proper null checks
      local autoCraftingRules = config.crafting and config.crafting.autoCraftingRules and config.crafting.autoCraftingRules.value or {}
      for item, rule in pairs(autoCraftingRules) do
        if type(rule) == "table" and type(rule.threshold) == "number" then
          local shouldCraft, neededCount = shouldAutoCraftItem(item)
          if shouldCraft then
            autoCraftLogger:info("Auto-crafting %u %s(s) (threshold: %u)", neededCount, item, rule.threshold)
            local jobInfo = requestCraft(item, neededCount)
            if jobInfo.success then
              startCraft(jobInfo.jobId)
            end
          end
        else
          autoCraftLogger:warn("Invalid auto-crafting rule for item %s", item)
        end
      end

      -- Check auto-smelting rules with proper null checks
      local autoSmeltingRules = config.crafting and config.crafting.autoSmeltingRules and config.crafting.autoSmeltingRules.value or {}
      for item, rule in pairs(autoSmeltingRules) do
        if type(rule) == "table" and type(rule.threshold) == "number" and rule.output then
          local shouldSmelt, neededCount = shouldAutoSmeltItem(item)
          if shouldSmelt then
            autoCraftLogger:info("Auto-smelting to produce %u %s(s) (threshold: %u)", neededCount, rule.output, rule.threshold)
            -- This would need integration with furnace module
            -- For now, we'll just request crafting of the output item
            local jobInfo = requestCraft(rule.output, neededCount)
            if jobInfo.success then
              startCraft(jobInfo.jobId)
            end
          end
        else
          autoCraftLogger:warn("Invalid auto-smelting rule for item %s", item)
        end
      end
    end

    ---Auto-crafting/smelting checker loop
    local function autoCraftChecker()
      while true do
        -- Use default value if config is not properly initialized
        local sleepTime = 10
        if config.crafting and config.crafting.tickInterval and type(config.crafting.tickInterval.value) == "number" then
          sleepTime = config.crafting.tickInterval.value * 10
        else
          autoCraftLogger:warn("Using default sleep time for auto-craft checker (config.crafting.tickInterval.value not available)")
        end
        sleep(sleepTime) -- Check every 10 crafting ticks (or default)
        checkAutoCrafting()
      end
    end

    local function jsonFileImport()
      print("JSON file importing ready..")
      while true do
        local e, transfer = os.pullEvent("file_transfer")
        for _, file in ipairs(transfer.getFiles()) do
          local contents = file.readAll()
          local json = textutils.unserialiseJSON(contents)
          if type(json) == "table" then
            if loadJson(json) then
              print(("Successfully imported %s"):format(file.getName()))
            else
              print(("Failed to import %s, no handler for %s"):format(file.getName(), json.type))
            end
          else
            print(("Failed to import %s, not a JSON file"):format(file.getName()))
          end
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
