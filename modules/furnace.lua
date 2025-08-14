--- Furnace crafting recipe handler
---@class modules.furnace
return {
  id = "furnace",
  version = "0.0.0",
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

    local bfile = require("bfile")
    local structFurnaceRecipe = bfile.newStruct("furnace_recipe"):add("string", "output"):add("uint16", "input")

    local function updateCraftableList()
      local list = {}
      for k, v in pairs(recipes) do
        table.insert(list, k)
      end
      crafting.addCraftableList("furnace", list)
    end

    local function saveFurnaceRecipes()
      local f = assert(fs.open("recipes/furnace_recipes.bin", "wb"))
      f.write("FURNACE0")       -- "versioned"
      for k, v in pairs(recipes) do
        structFurnaceRecipe:writeHandle(f, {
          input = crafting.getOrCacheString(v),
          output = k
        })
      end
      f.close()
      updateCraftableList()
    end

    local function loadFurnaceRecipes()
      local f = fs.open("recipes/furnace_recipes.bin", "rb")
      if not f then
        recipes = {}
        return
      end
      assert(f.read(8) == "FURNACE0", "Invalid furnace recipe file.")
      while f.read(1) do
        f.seek(nil, -1)
        local recipeInfo = structFurnaceRecipe:readHandle(f)
        _, recipes[recipeInfo.output] = crafting.getBestItem(recipeInfo.input)
      end
      f.close()
      updateCraftableList()
    end

    local function jsonTypeHandler(json)
      local input = json.ingredient.item
      local output = json.result
      recipes[output] = input
      saveFurnaceRecipes()
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
      if not requires then
        return false
      end
      local fuel, multiple, toCraft = getFuel(count) --[[@as integer]]
      node.type = "furnace"
      node.count = toCraft
      node.done = 0
      node.children = crafting.craft(requires, toCraft, node.jobId, nil, requestChain)
      node.ingredient = requires
      node.fuel = fuel --[[@as string]]
      node.multiple = multiple
      node.smelting = {}
      node.fuelNeeded = {}
      node.children = crafting.craft(fuel --[[@as string]], math.floor(toCraft / multiple), node.jobId, false,
        requestChain)
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
        while remaining > 0 do
          for furnace = 1, #attachedFurnaces do
            usedFurances[furnace] = true
            local toAssign = node.multiple
            local fuelNeeded = math.floor(toAssign / node.multiple)
            local absFurnace = require("abstractInvLib")({ attachedFurnaces[furnace] })
            local fmoved = loaded.inventory.interface.pushItems(false, absFurnace, node.fuel, fuelNeeded, 2)
            local moved = loaded.inventory.interface.pushItems(false, absFurnace, node.ingredient, toAssign,
              1)
            node.smelting[attachedFurnaces[furnace]] = (node.smelting[furnace] or 0) + toAssign - moved
            node.fuelNeeded[attachedFurnaces[furnace]] = (node.fuelNeeded[furnace] or 0) + fuelNeeded -
                fmoved
            node.hasBucket = true
            remaining = remaining - toAssign
            if remaining == 0 then
              break
            end
          end
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
