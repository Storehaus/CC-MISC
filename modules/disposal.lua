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
        inventory = { min = "1.1" },
        modem = { min = "1.0" }
    },
    ---@param loaded {logger: modules.logger|nil, inventory: modules.inventory, modem: modules.modem}
    init = function(loaded, config)
        local log = loaded.logger
        local inventory = loaded.inventory.interface
        local modem = loaded.modem.interface

        local disposalLogger = setmetatable({}, {
            __index = function()
                return function() end
            end
        })
        if log then
            disposalLogger = log.interface.logger("disposal", "main")
        end

        local networkName = modem.getNetworkName()
        local port = 122

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

        ---@type table<string, DisposalTurtle>
        local disposalTurtles = {}

        ---@class DisposalTurtle
        ---@field name string
        ---@field state string
        ---@field lastSeen integer
        ---@field pendingJobs integer

        ---@param name string
        ---@param handler fun(name: string, count: integer): boolean
        local function addDisposalHandler(name, handler)
            disposalHandlers[name] = handler
        end

        ---Discover and track disposal turtles on the network
        local function discoverTurtles()
            disposalLogger:debug("Discovering disposal turtles...")
            
            -- Send discovery message to find disposal turtles
            modem.transmit(port, port, {
                protocol = "DISCOVERY",
                destination = "*",
                source = networkName,
            })
            
            -- Wait for responses
            local startTime = os.epoch("utc")
            while os.epoch("utc") - startTime < 5000 do
                local event = getModemMessage(function(message)
                    return validateMessage(message) and 
                           message.protocol == "DISCOVERY_RESPONSE" and
                           message.source ~= networkName
                end, 1)
                
                if event then
                    local turtleName = event.message.source
                    disposalTurtles[turtleName] = {
                        name = turtleName,
                        state = "READY",
                        lastSeen = os.epoch("utc"),
                        pendingJobs = 0
                    }
                    disposalLogger:info("Discovered disposal turtle: %s", turtleName)
                end
            end
        end

        ---Get the best available disposal turtle
        ---@return DisposalTurtle|nil
        local function getBestTurtle()
            local bestTurtle = nil
            local minJobs = math.huge
            
            for _, turtle in pairs(disposalTurtles) do
                if turtle.state == "READY" and turtle.pendingJobs < minJobs then
                    bestTurtle = turtle
                    minJobs = turtle.pendingJobs
                end
            end
            
            return bestTurtle
        end

        ---Send disposal request to a turtle
        ---@param turtle DisposalTurtle
        ---@param name string
        ---@param count integer
        ---@return boolean success
        local function sendDisposalRequest(turtle, name, count)
            local jobId = ("%s_%s_%u"):format(name, turtle.name, os.epoch("utc"))
            
            turtle.pendingJobs = turtle.pendingJobs + 1
            turtle.state = "BUSY"
            
            disposalLogger:debug("Sending disposal request to %s: %u %s(s)", turtle.name, count, name)
            
            modem.transmit(port, port, {
                protocol = "DISPOSE",
                destination = turtle.name,
                source = networkName,
                task = {
                    name = name,
                    count = count,
                    jobId = jobId
                }
            })
            
            -- Wait for response
            local startTime = os.epoch("utc")
            while os.epoch("utc") - startTime < 10000 do
                local event = getModemMessage(function(message)
                    return validateMessage(message) and 
                           message.protocol == "DISPOSAL_DONE" and
                           message.jobId == jobId
                end, 1)
                
                if event then
                    turtle.pendingJobs = turtle.pendingJobs - 1
                    turtle.state = "READY"
                    disposalLogger:info("Disposal completed by %s: %u %s(s)", turtle.name, count, name)
                    return true
                end
            end
            
            -- Timeout
            turtle.pendingJobs = turtle.pendingJobs - 1
            turtle.state = "READY"
            disposalLogger:warn("Disposal request to %s timed out", turtle.name)
            return false
        end

        ---Default disposal handler that uses turtles
        ---@param name string
        ---@param count integer
        ---@return boolean success
        local function turtleDisposalHandler(name, count)
            local turtle = getBestTurtle()
            if turtle then
                return sendDisposalRequest(turtle, name, count)
            else
                disposalLogger:warn("No disposal turtles available for %s", name)
                return false
            end
        end

        ---Fallback disposal handler that drops items into a disposal inventory
        ---@param name string
        ---@param count integer
        ---@return boolean success
        local function fallbackDisposalHandler(name, count)
            disposalLogger:info("Using fallback disposal for %u %s(s)", count, name)
            
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
                disposalLogger:info("Disposed %u %s(s) via fallback to %s", pushed, name, disposalInv:getName())
                return pushed > 0
            end
            
            disposalLogger:warn("Fallback disposal failed for %u %s(s)", count, name)
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

            -- First try exact match
            if disposalHandlers[name] then
                return disposalHandlers[name](name, count)
            -- Then try wildcard handler
            elseif disposalHandlers["*"] then
                return disposalHandlers["*"](name, count)
            -- Finally try fallback handler
            elseif disposalHandlers["fallback"] then
                return disposalHandlers["fallback"](name, count)
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

        ---Initialize the disposal module with default handlers
        local function initialize()
            disposalLogger:info("Initializing disposal module...")
            
            -- Register default handlers
            addDisposalHandler("*", turtleDisposalHandler) -- Default handler for all items
            addDisposalHandler("fallback", fallbackDisposalHandler) -- Fallback handler
            
            -- Discover turtles on the network
            discoverTurtles()
            
            disposalLogger:info("Disposal module initialized with %u turtles", #disposalTurtles)
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
                handleDisposalDone = handleDisposalDone,
                updateDisposalThresholds = updateDisposalThresholds,
                discoverTurtles = discoverTurtles,
                getBestTurtle = getBestTurtle
            }
        }
    end
}