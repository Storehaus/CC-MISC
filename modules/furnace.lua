--- Furnace crafting recipe handler
-- 2 laptops from an AI cluster were sacrificed in fixing of this code
local json = require("lib/json")
---@class modules.furnace
return {
  id = "furnace",
  version = "0.0.1",
  config = {
    fuels = {
      type = "table",
      description = "List of fuels table<item: string,{smelts: integer, bucket: boolean}>",
      default = { ["minecraft:coal"] = { smelts = 8 }, ["minecraft:charcoal"] = { smelts = 8 } }
    },
    checkFrequency = {
      type = "number",
      description = "Time in seconds to wait between checking each furnace",
      default = 5
    }
  },
  dependencies = {
    logger = { min = "1.1", optional = true },
    crafting = { min = "1.4" },
    inventory = { min = "1.2" }
  },
  ---@param loaded {crafting: modules.crafting, logger: modules.logger|nil, inventory: modules.inventory}
  init = function(loaded, config)
    local crafting = loaded.crafting.interface.recipeInterface
    ---@type table<string,string> output->input
    local recipes = {}

    local function updateCraftableList()
      local list = {}
      for k, v in pairs(recipes) do
        table.insert(list, k)
      end
      crafting.addCraftableList("furnace", list)
    end

    local function loadFurnaceRecipes()
      local f = fs.open("recipes/recipes.json", "r")
      if f then
        local contents = f.readAll() or "{}"
        f.close()
        local decoded = json.decode(contents)
        if type(decoded) == "table" and decoded.recipes and decoded.recipes.furnace then
          for _, recipe in ipairs(decoded.recipes.furnace) do
            if recipe.type == "minecraft:smelting" then
              recipes[recipe.result] = recipe.ingredient
            end
          end
        end
      end
      updateCraftableList()
    end

    local function jsonTypeHandler(json)
      local input = json.ingredient.item
      local output = json.result
      recipes[output] = input
      updateCraftableList()
    end
    crafting.addJsonTypeHandler("minecraft:smelting", jsonTypeHandler)

    ---Get a fuel for an item, and how many items is optimal if toSmelt is provided
    ---@param toSmelt integer? ensure there's enough of this fuel to smelt this many items
    ---@return string fuel
    ---@return integer multiple
    ---@return integer optimal
    local function getFuel(toSmelt)
      ---@type {diff:integer,fuel:string,optimal:integer,multiple:integer}[]
      local fuelDiffs = {}
      for k, v in pairs(config.furnace.fuels.value) do
        -- measure the difference in terms of
        -- how far off the closest multiple of the fuel is from the desired amount
        local multiple = v.smelts
        local optimal = math.ceil((toSmelt or 0) / multiple) * multiple
        if loaded.inventory.interface.getCount(k) >= optimal / multiple then
          fuelDiffs[#fuelDiffs + 1] = {
            diff = optimal - toSmelt,
            optimal = optimal,
            fuel = k,
            multiple = multiple
          }
        end
      end
      table.sort(fuelDiffs, function(a, b)
        return a.diff < b.diff
      end)
      -- Fix: Handle case where no fuel is found in inventory
      if #fuelDiffs == 0 then
        return nil, nil, toSmelt
      end
      -- TODO: Replace this hack with a proper optimizer that respects what is in storage.
      return fuelDiffs[1].fuel, fuelDiffs[1].multiple, toSmelt -- fuelDiffs[1].optimal
    end

    ---@class FurnaceNode : CraftingNode
    ---@field type "furnace"
    ---@field done integer count smelted
    ---@field multiple integer fuel multiple
    ---@field fuel string
    ---@field ingredient string
    ---@field smelting table<string,integer> amount to smelt in each furnace
    ---@field fuelNeeded table<string,integer> amount of fuel each furnace requires
    ---@field hasBucket boolean

    ---@type string[]
    local attachedFurnaces = {}
    for _, v in ipairs(peripheral.getNames()) do
      if peripheral.hasType(v, "minecraft:furnace") then
        attachedFurnaces[#attachedFurnaces + 1] = v
      end
    end

    ---@param node FurnaceNode
    ---@param name string
    ---@param count integer
    ---@param requestChain table Do not modify, just pass through to calls to craft
    ---@return boolean
    local function craftType(node, name, count, requestChain)
      local requires = recipes[name]
      if not requires then return false end

      local fuel, multiple = getFuel(count)
      if not fuel then
        -- Optional: Log that no fuel was found
        return false 
      end

      node.type = "furnace"
      node.count = count
      node.done = 0
      node.ingredient = requires
      node.fuel = fuel
      node.multiple = multiple
      node.smelting = {}
      node.fuelNeeded = {}

      node.children = crafting.craft(requires, count, node.jobId, nil, requestChain)
      node.children = crafting.craft(fuel, math.ceil(count / multiple), node.jobId, false, requestChain)

      return true
    end

    crafting.addCraftType("furnace", craftType)


    ---@type table<FurnaceNode,FurnaceNode>
    local smelting = {}

    ---@param node FurnaceNode
    local function readyHandler(node)
      local usedFurances = {}
      local remaining = node.count
      if #attachedFurnaces > 0 then
        local furnaceIndex = 1
        while remaining > 0 and furnaceIndex <= #attachedFurnaces do
          local furnace = attachedFurnaces[furnaceIndex]
          usedFurances[furnaceIndex] = true
          local toAssign = math.min(node.multiple, remaining)
          local fuelNeeded = math.ceil(toAssign / node.multiple)
          local absFurnace = require("abstractInvLib")({ furnace })
          local fmoved = loaded.inventory.interface.pushItems(false, absFurnace, node.fuel, fuelNeeded, 2)
          local moved = loaded.inventory.interface.pushItems(false, absFurnace, node.ingredient, toAssign, 1)
          node.smelting[furnace] = (node.smelting[furnace] or 0) + toAssign - moved
          node.fuelNeeded[furnace] = (node.fuelNeeded[furnace] or 0) + fuelNeeded - fmoved
          node.hasBucket = true
          remaining = remaining - toAssign
          furnaceIndex = furnaceIndex + 1
        end
        local ordered = {}
        for k, v in pairs(usedFurances) do
          ordered[#ordered + 1] = k
        end
        table.sort(ordered)
        for i = #ordered, 1, -1 do
          table.remove(attachedFurnaces, ordered[i])
        end
        crafting.changeNodeState(node, "CRAFTING")
        smelting[node] = node
      end
    end
    crafting.addReadyHandler("furnace", readyHandler)

    local function craftingHandler(node)

    end
    crafting.addCraftingHandler("furnace", craftingHandler)

    ---@param node FurnaceNode
    local function checkNodeFurnaces(node)
      for furnace, remaining in pairs(node.smelting) do
        local absFurnace = require("abstractInvLib")({ furnace })
        local crafted = loaded.inventory.interface.pullItems(false, absFurnace, 3)
        node.done = node.done + crafted
        if config.furnace.fuels.value[node.fuel].bucket and node.hasBucket then
          local i = loaded.inventory.interface.pullItems(false, absFurnace, 2)
          if i > 0 then
            node.hasBucket = false
          end
        end
        if remaining > 0 then
          local amount = loaded.inventory.interface.pushItems(false, absFurnace, node.ingredient, remaining, 1)
          node.smelting[furnace] = remaining - amount
        end
        if node.fuelNeeded[furnace] > 0 then
          local famount = loaded.inventory.interface.pushItems(false, absFurnace, node.fuel,
            node.fuelNeeded[furnace], 2)
          if famount == 0 and config.furnace.fuels.value[node.fuel].bucket then
            -- remove the bucket
            loaded.inventory.interface.pullItems(true, absFurnace, 2)
          end
          node.fuelNeeded[furnace] = node.fuelNeeded[furnace] - famount
        end
      end
      if node.done == node.count then
        crafting.changeNodeState(node, "DONE")
        for furnace in pairs(node.smelting) do
          table.insert(attachedFurnaces, furnace)
        end
        smelting[node] = nil
      end

    end

    local function furnaceChecker()
      while true do
        sleep(config.furnace.checkFrequency.value)
        for node in pairs(smelting) do
          checkNodeFurnaces(node)
        end
      end
    end

    return {
      start = function()
        loadFurnaceRecipes()
        furnaceChecker()
      end
    }
  end
}