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
            f.write("FURNACE0") -- "versioned"
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
            if not toSmelt or toSmelt <= 0 then return nil, 0, 0 end
            
            local fuelDiffs = {}
            for fuelItem, fuelData in pairs(config.furnace.fuels.value) do
                if loaded.inventory.interface.getCount(fuelItem) > 0 then
                    local multiple = fuelData.smelts
                    local required = math.ceil(toSmelt / multiple)
                    local available = math.min(
                        loaded.inventory.interface.getCount(fuelItem),
                        required
                    )
                    
                    local optimal = available * multiple
                    table.insert(fuelDiffs, {
                        optimal = optimal,
                        fuel = fuelItem,
                        multiple = multiple,
                        available = available
                    })
                end
            end
            
            if #fuelDiffs == 0 then
                error("No available fuel for "..toSmelt.." items")
            end
            
            table.sort(fuelDiffs, function(a, b)
                return a.optimal > b.optimal  -- Prioritize highest yielding fuel
            end)
            
            local best = fuelDiffs[1]
            return best.fuel, best.multiple, best.optimal
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
            node.children = crafting.craft(fuel --[[@as string]], math.ceil(toCraft / multiple), node.jobId, false,
                requestChain)
            return true
        end
        crafting.addCraftType("furnace", craftType)


        ---@type table<FurnaceNode,FurnaceNode>
        local smelting = {}

        ---@param node FurnaceNode
        local function readyHandler(node)
            local remaining = node.count
            
            while remaining > 0 and #attachedFurnaces > 0 do
                local furnaceName = table.remove(attachedFurnaces, 1)
                local furnace = require("abstractInvLib")({ furnaceName })
                
                -- Calculate capacity for this furnace
                local smeltCapacity = math.min(
                    remaining,
                    node.multiple * (loaded.inventory.interface.getItemSpace(furnace, 2) or 0)
                )
                
                if smeltCapacity > 0 then
                    -- Move fuel first (exact needed amount)
                    local fuelNeeded = math.ceil(smeltCapacity / node.multiple)
                    local movedFuel = loaded.inventory.interface.pushItems(
                        false, furnace, node.fuel, fuelNeeded, 2
                    )
                    
                    -- Only move items if fuel was successfully inserted
                    if movedFuel > 0 then
                        local movedItems = loaded.inventory.interface.pushItems(
                            false, furnace, node.ingredient, smeltCapacity, 1
                        )
                        
                        -- Update tracking
                        node.smelting[furnaceName] = movedItems
                        node.fuelInserted[furnaceName] = movedFuel
                        remaining = remaining - movedItems
                        
                        -- Bucket handling
                        if config.furnace.fuels.value[node.fuel].bucket then
                            node.hasBucket = true
                        end
                    end
                end
            end
            
            crafting.changeNodeState(node, "CRAFTING")
            smelting[node] = node
        end
        crafting.addReadyHandler("furnace", readyHandler)
        
        local function craftingHandler(node)
        
        end
        crafting.addCraftingHandler("furnace", craftingHandler)
        
        ---@param node FurnaceNode
        local function checkNodeFurnaces(node)
            for furnaceName in pairs(node.smelting) do
                local furnace = require("abstractInvLib")({ furnaceName })
                
                -- 1. Pull finished items first
                local pulled = loaded.inventory.interface.pullItems(furnace, false, 3, 64)
                node.done = node.done + pulled
                
                -- 2. Handle bucket fuels
                if node.hasBucket then
                    loaded.inventory.interface.pullItems(furnace, false, 2, 1) -- Pull empty bucket
                    node.hasBucket = false
                end
                
                -- 3. Check smelting status
                local currentFuel = loaded.inventory.interface.getItem(furnace, 2)
                local currentInput = loaded.inventory.interface.getItem(furnace, 1)
                
                -- Only clear if furnace is actually idle
                if not currentInput and not currentFuel then
                    -- Pull any residual output
                    local residual = loaded.inventory.interface.pullItems(furnace, false, 3, 64)
                    node.done = node.done + residual
                    
                    -- Free up furnace
                    table.insert(attachedFurnaces, furnaceName)
                    node.smelting[furnaceName] = nil
                    node.fuelInserted[furnaceName] = nil
                elseif node.smelting[furnaceName] > 0 then
                    -- Verify fuel requirement
                    local neededFuel = math.ceil(node.smelting[furnaceName] / node.multiple)
                    local existingFuel = currentFuel and currentFuel.count or 0
                    
                    -- Calculate additional fuel needed
                    local addFuel = math.max(0, neededFuel - existingFuel)
                    if addFuel > 0 then
                        local moved = loaded.inventory.interface.pushItems(
                            false, furnace, node.fuel, addFuel, 2
                        )
                        node.fuelInserted[furnaceName] = (node.fuelInserted[furnaceName] or 0) + moved
                    end
                end
            end

            -- Completion check
            if node.done >= node.count then
                crafting.changeNodeState(node, "DONE")
                smelting[node] = nil
                
                -- Reclaim all furnaces
                for furnaceName in pairs(node.smelting) do
                    table.insert(attachedFurnaces, furnaceName)
                end
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