--- Disposal module for handling item disposal
---@class modules.disposal
return {
    id = "disposal",
    version = "1.0.0",
    config = {
        disposalItems = {
            type = "table",
            description = "Items to dispose and their thresholds table<item: string, threshold: integer>",
            default = {
                ["minecraft:dirt"] = 512  -- Default: dispose excess dirt above 512
            }
        },
        checkFrequency = {
            type = "number",
            description = "Time in seconds to wait between checking for items to dispose",
            default = 60
        },
        disposalPrefix = {
            type = "string",
            description = "Prefix that disposal blocks must have in their name to be used for fallback disposal",
            default = "disposal_"
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

        ---Direct disposal handler that uses name pattern matched blocks
        ---@param name string
        ---@param count integer
        ---@return boolean success
        local function directDisposalHandler(name, count)
            disposalLogger:info("Using direct disposal for %u %s(s)", count, name)
            
            -- Try to find a disposal inventory with the configured prefix
            local disposalInv = nil
            local prefix = config.disposal.disposalPrefix.value
            disposalLogger:debug("Looking for disposal inventories with prefix: %s", prefix)
            
            for _, inv in pairs(inventory.listInventories()) do
                local invName = inv:getName()
                if invName:sub(1, prefix:len()) == prefix then
                    disposalInv = inv
                    disposalLogger:info("Found disposal inventory: %s", invName)
                    break
                end
            end
            
            if not disposalInv then
                disposalLogger:warn("No disposal inventory found with prefix '%s'", prefix)
                return false
            end
            
            -- Pull items from storage and push to disposal inventory
            local pulled = inventory.pullItems(false, "storage", name, count)
            if pulled > 0 then
                local pushed = inventory.pushItems(false, disposalInv:getName(), name, pulled)
                disposalLogger:info("Disposed %u %s(s) to %s", pushed, name, disposalInv:getName())
                return pushed > 0
            end
            
            disposalLogger:warn("Direct disposal failed for %u %s(s)", count, name)
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
                    disposalLogger:info("Found %u excess %s(s) to dispose (threshold: %u)", excessCount, item, threshold)
                    requestDisposal(item, excessCount)
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
                updateDisposalThresholds = updateDisposalThresholds
            }
        }
    end
}