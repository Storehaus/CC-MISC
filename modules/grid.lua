--- Grid crafting recipe handler
local common = require("common")
local json = require("lib/json")

---@class modules.grid
return {
  id = "grid",
  version = "1.4.3",
  config = {
    port = {
      type = "number",
      description = "Port to host crafting turtles on.",
      default = 121
    },
    keepAlive = {
      type = "number",
      description = "Keep alive ping frequency",
      default = 8,
    }
  },
  dependencies = {
    logger = { min = "1.1", optional = true },
    crafting = { min = "1.4" },
    interface = { min = "1.4" }
  },
  ---@param loaded {crafting: modules.crafting, logger: modules.logger|nil}
  init = function(loaded, config)
    ---@alias RecipeEntry ItemIndex|ItemIndex[]

    ---@class GridRecipe
    ---@field produces integer
    ---@field recipe RecipeEntry[]
    ---@field width integer|nil
    ---@field height integer|nil
    ---@field shaped boolean|nil
    ---@field name string
    ---@field requires table<ItemIndex,integer>

    ---@type table<string,GridRecipe>
    local gridRecipes = {}

    local crafting = loaded.crafting.interface.recipeInterface

    ---Cache information about a GridRecipe that can be inferred from stored data
    ---@param recipe GridRecipe
    local function cacheAdditional(recipe)
      recipe.requires = {}
      for k, v in ipairs(recipe.recipe) do
        -- v can be an integer (ItemIndex) or a table (array of ItemIndex options)
        -- We only cache single items. 0 is Air.
        if type(v) == "number" and v ~= 0 then
          -- FIX: Convert integer ID to string. JSON object keys MUST be strings.
          local key = tostring(v)
          recipe.requires[key] = (recipe.requires[key] or 0) + 1
        end
      end
    end

    local function updateCraftableList()
      local list = {}
      for k, v in pairs(gridRecipes) do
        table.insert(list, k)
      end
      crafting.addCraftableList("grid", list)
    end

    ---Add a grid recipe manually
    ---@param name string
    ---@param produces integer
    ---@param recipe string[] table of ITEM NAMES.
    ---@param shaped boolean
    local function addGridRecipe(name, produces, recipe, shaped)
      common.enforceType(name, 1, "string")
      common.enforceType(produces, 2, "integer")
      common.enforceType(recipe, 3, "string[]")
      common.enforceType(shaped, 4, "boolean")
      local gridRecipe = {}
      gridRecipe.shaped = shaped
      gridRecipe.produces = produces
      gridRecipe.name = name
      gridRecipe.recipe = {}
      if shaped then
        for i = 1, 9 do
          local itemName = recipe[i]
          gridRecipe.recipe[i] = (itemName and crafting.getOrCacheString(itemName)) or 0
        end
        gridRecipe.width = 3
        gridRecipe.height = 3
      else
        gridRecipe.length = #recipe
        for _, v in ipairs(recipe) do
          table.insert(gridRecipe.recipe, crafting.getOrCacheString(v))
        end
      end
      gridRecipes[name] = gridRecipe
      cacheAdditional(gridRecipe)
      updateCraftableList()
    end

    ---Remove a grid recipe
    local function removeGridRecipe(name)
      common.enforceType(name, 1, "string")
      if gridRecipes[name] then
        gridRecipes[name] = nil
        return true
      end
      updateCraftableList()
      return false
    end

    ---Load the grid recipes from a file
    local function loadGridRecipes()
      if not fs.exists("recipes/recipes.json") then return end

      local f = fs.open("recipes/recipes.json", "r")
      if f then
        local contents = f.readAll() or "{}"
        f.close()
        
        local status, decoded = pcall(json.decode, contents)
        if not status then
            print("Error decoding recipes.json: " .. tostring(decoded))
            return 
        end

        if type(decoded) == "table" and decoded.recipes and decoded.recipes.crafting then
          
          -- Helper: Parses "minecraft:stone" or "#minecraft:logs" into the internal ID
          local function parseItemString(str)
            local name = str
            local isTag = false
            -- Check if it starts with # (Tag)
            if type(name) == "string" and name:sub(1, 1) == "#" then
              name = name:sub(2)
              isTag = true
            end
            -- Delegate to crafting module so IDs are consistent and aliases work
            return crafting.getOrCacheString(name, isTag)
          end

          -- Helper: Handles string vs table (array of options)
          local function parseIngredient(raw)
            if type(raw) == "table" then
              local options = {}
              for _, v in pairs(raw) do
                table.insert(options, parseItemString(v))
              end
              return options
            else
              return parseItemString(raw)
            end
          end

          for _, recipe in ipairs(decoded.recipes.crafting) do
            if (recipe.type == "minecraft:crafting_shaped" or recipe.type == "minecraft:crafting_shapeless") 
               and recipe.result and recipe.result.item then
              
              local recipeName = recipe.result.item
              local count = recipe.result.count or 1
              
              local gridRecipe = {}
              gridRecipe.shaped = (recipe.type == "minecraft:crafting_shaped")
              gridRecipe.produces = count
              gridRecipe.name = recipeName
              gridRecipe.recipe = {}

              local valid = true

              if gridRecipe.shaped then
                if not recipe.pattern or type(recipe.key) ~= "table" then
                    valid = false
                else
                    gridRecipe.width = recipe.pattern[1]:len()
                    gridRecipe.height = #recipe.pattern
                    
                    local keys = { [" "] = 0 }
                    for char, value in pairs(recipe.key) do
                      keys[char] = parseIngredient(value)
                    end

                    for row, rowString in ipairs(recipe.pattern) do
                      for i = 1, rowString:len() do
                        local char = rowString:sub(i, i)
                        table.insert(gridRecipe.recipe, keys[char] or 0)
                      end
                    end
                end
              else 
                -- Handle Shapeless
                if not recipe.ingredients then
                    valid = false
                else
                    gridRecipe.length = #recipe.ingredients
                    for _, ingredient in ipairs(recipe.ingredients) do
                      table.insert(gridRecipe.recipe, parseIngredient(ingredient))
                    end
                end
              end

              if valid then
                  cacheAdditional(gridRecipe)
                  gridRecipes[recipeName] = gridRecipe
              else
                  print("Skipped invalid recipe: " .. tostring(recipeName))
              end
            end
          end
        end
      end
      updateCraftableList()
    end


    ---@class Turtle
    ---@field name string
    ---@field task nil|GridNode
    ---@field state "READY" | "ERROR" | "BUSY" | "CRAFTING" | "DONE"

    local attachedTurtles = {}
    local modem = assert(peripheral.wrap(config.modem.modem.value), "Bad modem specified.")
    modem.open(config.grid.port.value)

    local function emptyTurtle(turtle)
      local ids = {}
      for _, slot in pairs(turtle.itemSlots) do
        ids[loaded.inventory.interface.pullItems(true, turtle.name, slot)] = true
      end
      repeat
        local e = { os.pullEvent("inventoryFinished") }
        ids[e[2]] = nil
      until not next(ids)
    end

    local function turtleCraftingDone(turtle)
      if turtle.task then
        crafting.changeNodeState(turtle.task, "DONE")
        crafting.deleteNodeChildren(turtle.task)
        crafting.deleteTask(turtle.task)
        turtle.task = nil
      end
      turtle.state = "BUSY"
    end

    local protocolHandlers = {
      KEEP_ALIVE = function(message)
        attachedTurtles[message.source] = attachedTurtles[message.source] or {
          name = message.source
        }
        local turtle = attachedTurtles[message.source]
        turtle.state = message.state
        turtle.itemSlots = message.itemSlots
      end,
      CRAFTING_DONE = function(message)
        local turtle = attachedTurtles[message.source]
        turtle.itemSlots = message.itemSlots
        emptyTurtle(turtle)
        turtleCraftingDone(turtle)
      end,
      EMPTY = function(message)
        local turtle = attachedTurtles[message.source]
        turtle.itemSlots = message.itemSlots
        emptyTurtle(turtle)
      end,
      NEW_RECIPE = function(message)
        addGridRecipe(message.name, message.amount, message.recipe, message.shaped)
      end,
      REMOVE_RECIPE = function(message)
        removeGridRecipe(message.name)
      end
    }

    local function validateMessage(message)
      local valid = type(message) == "table" and message.protocol ~= nil
      valid = valid and message.destination == "HOST" and message.source ~= nil
      return valid
    end

    local function getModemMessage(filter, timeout)
      common.enforceType(filter, 1, "function", "nil")
      common.enforceType(timeout, 2, "integer", "nil")
      local timer
      if timeout then
        timer = os.startTimer(timeout)
      end
      while true do
        ---@type string, string, integer, integer, any, integer
        local event, side, channel, reply, message, distance = os.pullEvent()
        if event == "modem_message" and (filter == nil or filter(message)) then
          if timeout then
            os.cancelTimer(timer)
          end
          return {
            side = side,
            channel = channel,
            reply = reply,
            message = message,
            distance = distance
          }
        elseif event == "timer" and timeout and side == timer then
          return
        end
      end
    end

    local function sendMessage(message, destination, protocol)
      message.source = "HOST"
      message.destination = destination
      message.protocol = protocol
      modem.transmit(config.grid.port.value, config.grid.port.value, message)
    end

    local function modemMessageHandler()
      while true do
        local modemMessage = getModemMessage(validateMessage)
        if modemMessage then
          local message = modemMessage.message
          if protocolHandlers[message.protocol] then
            local response = protocolHandlers[message.protocol](message)
            if response then
              response.destination = response.destination or message.source
              response.source = "HOST"
              modem.transmit(config.grid.port.value, config.grid.port.value, response)
            end
          end
        end
      end
    end

    local function keepAlive()
      while true do
        modem.transmit(config.grid.port.value, config.grid.port.value, {
          protocol = "KEEP_ALIVE",
          source = "HOST",
          destination = "*",
        })
        os.sleep(config.grid.keepAlive.value)
      end
    end

    ---@param node GridRecipe
    ---@param name string
    ---@param count integer
    ---@param requestChain table Do not modify, just pass through to calls to craft
    ---@return boolean
    local function craftType(node, name, count, requestChain)
      -- attempt to craft this
      local recipe = gridRecipes[name]
      if not recipe then
        return false
      end
      node.type = "grid"
      local toCraft = math.ceil(count / recipe.produces)
      
      ---@type table<integer,{name: string, max: integer, count: integer}>
      local plan = {}
      for k, v in pairs(recipe.recipe) do
        if v ~= 0 then
          -- This calls crafting.getBestItem, which uses the alias logic in crafting.lua
          local success, itemName = crafting.getBestItem(v)
          plan[k] = {}
          if success then
            plan[k].name = itemName
            plan[k].max = crafting.getStackSize(plan[k].name)
            toCraft = math.min(toCraft, plan[k].max)
          else
            plan[k].tag = itemName
          end
        end
      end
      node.plan = plan
      node.toCraft = toCraft
      node.width = recipe.width
      node.height = recipe.height
      node.children = {}
      node.name = name
      local requiredItemCounts = {}
      for k, v in pairs(plan) do
        v.count = toCraft
        if v.tag then
          table.insert(node.children, crafting.createMissingNode(v.tag, v.count, node.jobId))
        else
          requiredItemCounts[v.name] = (requiredItemCounts[v.name] or 0) + v.count
        end
      end
      for k, v in pairs(requiredItemCounts) do
        crafting.mergeInto(crafting.craft(k, v, node.jobId, nil, requestChain), node.children)
      end
      for k, v in pairs(node.children) do
        v.parent = node
      end
      node.count = toCraft * recipe.produces
      return true
    end
    crafting.addCraftType("grid", craftType)

    local function readyHandler(node)
      local availableTurtle
      for k, v in pairs(attachedTurtles) do
        if v.state == "READY" then
          availableTurtle = v
          break
        end
      end
      if availableTurtle then
        crafting.changeNodeState(node, "CRAFTING")
        local nodeCopy = {}
        for k, v in pairs(node) do
          nodeCopy[k] = v
        end
        nodeCopy.parent = nil
        nodeCopy.children = nil
        sendMessage({ task = nodeCopy }, availableTurtle.name, "CRAFT")
        availableTurtle.task = node
        node.turtle = availableTurtle.name
        local transfers = {}
        for slot, v in pairs(node.plan) do
          local x = (slot - 1) % (node.width or 3) + 1
          local y = math.floor((slot - 1) / (node.width or 3))
          local turtleSlot = y * 4 + x
          table.insert(transfers, function() crafting.pushItems(availableTurtle.name, v.name, v.count, turtleSlot) end)
        end
        availableTurtle.state = "BUSY"
        parallel.waitForAll(table.unpack(transfers))
      end
    end
    crafting.addReadyHandler("grid", readyHandler)

    local function craftingHandler(node)
    end
    crafting.addCraftingHandler("grid", craftingHandler)
    
    return {
      start = function()
        loadGridRecipes()
        parallel.waitForAny(modemMessageHandler, keepAlive)
      end,
      addGridRecipe = addGridRecipe,
      removeGridRecipe = removeGridRecipe,
    }
  end
}