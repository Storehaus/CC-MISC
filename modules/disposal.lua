--- Disposal module for handling item disposal
---@class modules.disposal
return {
    id = "disposal",
    version = "1.0.0",
    config = {
        disposalItems = {
            type = "table",
            description = "Items to dispose and their thresholds table<item: string, threshold: integer>",
            default = {}
        },
        checkFrequency = {
            type = "number",
            description = "Time in seconds to wait between checking for items to dispose",
            default = 60
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

            if disposalHandlers[name] then
                return disposalHandlers[name](name, count)
            else
                disposalLogger:warn("No disposal handler for item %s", name)
                return false
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

        ---Handle disposal completion
        ---@param jobId string
        local function handleDisposalDone(jobId)
            disposalLogger:info("Disposal job %s completed", jobId)
        end

        return {
            start = function()
                updateDisposalThresholds()
                disposalChecker()
            end,

            interface = {
                addDisposalHandler = addDisposalHandler,
                requestDisposal = requestDisposal,
                shouldDisposeItem = shouldDisposeItem,
                handleDisposalDone = handleDisposalDone,
                updateDisposalThresholds = updateDisposalThresholds
            }
        }
    end
}