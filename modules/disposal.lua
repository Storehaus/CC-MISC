--- Disposal module for handling item disposal
---@class modules.disposal
return {
    id = "disposal",
    version = "1.0.0",
    config = {
        disposalItems = {
            type = "table",
            description = "Patterns to match items for disposal and their thresholds table<pattern: string, threshold: integer>",
            default = {}
        },
        checkFrequency = {
            type = "number",
            description = "Time in seconds to wait between checking for items to dispose",
            default = 60
        },
        disposalPatterns = {
            type = "table",
            description = "Array of patterns to match disposal inventories by name. Supports absolute item ID tags and patterns. Items matching these patterns will be used for disposal.",
            default = {
                "dropper_0",
                "dropper_1"
            }
        }
    },
    dependencies = {
        logger = { min = "1.1", optional = true },
        inventory = { min = "1.1" }
    },
    ---@param loaded {logger: modules.logger|nil, inventory: modules.inventory}
    init = function(loaded, config)
        local log = loaded.logger
        local inventory = loaded.inventory.interface

        local disposalLogger = setmetatable({}, {
            __index = function()
                return function() end
            end
        })
        if log then
            disposalLogger = log.interface.logger("disposal", "main")
        end

        ---@type table<string, integer> item name -> threshold
        local disposalThresholds = {}

        local function updateDisposalThresholds()
            disposalThresholds = {}
            for item, threshold in pairs(config.disposal.disposalItems.value) do
                disposalThresholds[item] = threshold
            end
        end

        ---@type table<string, fun(name: string, count: integer): boolean>
        local disposalHandlers = {}

        ---@param name string
        ---@param handler fun(name: string, count: integer): boolean
        local function addDisposalHandler(name, handler)
            disposalHandlers[name] = handler
        end

        ---Get list of attached inventories
        ---@return string[]
        local function getAttachedInventories()
            local attachedInventories = {}
            for _, v in ipairs(peripheral.getNames()) do
                if peripheral.hasType(v, "inventory") then attachedInventories[#attachedInventories + 1] = v end
            end
            return attachedInventories
        end

        ---Direct disposal handler that uses pattern matched blocks
        ---@param name string
        ---@param count integer
        ---@return boolean success
        local function directDisposalHandler(name, count)
            -- RE-VERIFY: Check current stock right before pushing
            local currentCount = inventory.getCount(name)
            local threshold = disposalThresholds[name] or 0
            
            -- Ensure we don't try to move more than exists or dip below threshold
            local safeCount = math.min(count, currentCount - threshold)

            if safeCount <= 0 then
                disposalLogger:debug("Aborting disposal for %s: count changed during execution", name)
                return false
            end

            disposalLogger:info("Using direct disposal for %u %s(s)", safeCount, name)

            local disposalInv = nil
            local patterns = config.disposal.disposalPatterns.value

            for _, invName in pairs(getAttachedInventories()) do
                for _, pattern in ipairs(patterns) do
                    if invName:find(pattern) then
                        disposalInv = invName
                        break
                    end
                end
                if disposalInv then break end
            end

            if not disposalInv then
                disposalLogger:warn("No disposal inventory found matching patterns")
                return false
            end

            -- Use the safeCount instead of the original count
            local pushed = inventory.pushItems(false, disposalInv, name, safeCount)

            if pushed > 0 then
                disposalLogger:info("Disposed %u %s(s) to %s", pushed, name, disposalInv)
                return true
            end

            return false
        end


        ---Check if an item should be disposed based on current inventory count
        ---@param name string
        ---@return boolean shouldDispose
        ---@return integer excessCount
        local function shouldDisposeItem(name)
            local threshold = disposalThresholds[name]
            if not threshold then return false, 0 end

            local currentCount = inventory.getCount(name)
            if currentCount > threshold then
                return true, currentCount - threshold
            end
            return false, 0
        end

        ---Request disposal of items
        ---@param name string
        ---@param count integer
        ---@return boolean success
        local function requestDisposal(name, count)
            disposalLogger:info("Requesting disposal of %u %s(s)", count, name)

            -- Try exact match handler first
            if disposalHandlers[name] then
                return disposalHandlers[name](name, count)
            -- Then try wildcard handler
            elseif disposalHandlers["*"] then
                return disposalHandlers["*"](name, count)
            -- Finally use direct disposal
            else
                return directDisposalHandler(name, count)
            end
        end

        ---Check all items and dispose excess
        local function checkAndDispose()
            disposalLogger:debug("Checking for items to dispose...")

            for item, threshold in pairs(disposalThresholds) do
                local shouldDispose, excessCount = shouldDisposeItem(item)
                if shouldDispose then
                    -- pcall prevents the module from crashing if the library throws an error
                    local ok, err = pcall(requestDisposal, item, excessCount)
                    if not ok then
                        disposalLogger:error("Error during disposal of %s: %s", item, err)
                    end
                end
            end
        end

        ---Main disposal checker loop
        local function disposalChecker()
            while true do
                sleep(config.disposal.checkFrequency.value)
                checkAndDispose()
            end
        end

        ---Initialize the disposal module with default handlers
        local function initialize()
            disposalLogger:info("Initializing disposal module...")
            
            -- Register default handler for all items
            addDisposalHandler("*", directDisposalHandler)
            
            disposalLogger:info("Disposal module initialized with direct disposal")
        end

        ---Test if an inventory name matches any disposal pattern
        ---@param inventoryName string
        ---@return boolean matches
        ---@return string|nil matchedPattern
        local function testDisposalPattern(inventoryName)
            local patterns = config.disposal.disposalPatterns.value
            for _, pattern in ipairs(patterns) do
                if inventoryName:find(pattern) then
                    return true, pattern
                end
            end
            return false, nil
        end

        ---Update disposal patterns dynamically
        ---@param newPatterns string[]
        local function updateDisposalPatterns(newPatterns)
            config.disposal.disposalPatterns.value = newPatterns
            disposalLogger:info("Updated disposal patterns to: %s", table.concat(newPatterns, ", "))
        end

        return {
            start = function()
                initialize()
                updateDisposalThresholds()
                disposalChecker()
            end,

            interface = {
                addDisposalHandler = addDisposalHandler,
                requestDisposal = requestDisposal,
                shouldDisposeItem = shouldDisposeItem,
                updateDisposalThresholds = updateDisposalThresholds,
                testDisposalPattern = testDisposalPattern,
                updateDisposalPatterns = updateDisposalPatterns
            }
        }
    end
}