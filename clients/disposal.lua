-- Disposal client for handling item disposal
local modem = peripheral.find("modem", function(name, modem)
    return true
end)
local modemName = peripheral.getName(modem)
rednet.open(modemName)
local networkName = modem.getNameLocal()

---@enum State
local STATES = {
    READY = "READY",
    ERROR = "ERROR",
    BUSY = "BUSY",
    DISPOSING = "DISPOSING",
    DONE = "DONE",
}

local state = STATES.READY
local connected = false
local port = 122
local keepAliveTimeout = 10
local w, h = term.getSize()
local banner = window.create(term.current(), 1, 1, w, 1)
local panel = window.create(term.current(), 1, 2, w, h - 1)

local lastStateChange = os.epoch("utc")

term.redirect(panel)

modem.open(port)

local function validateMessage(message)
    local valid = type(message) == "table" and message.protocol ~= nil
    valid = valid and (message.destination == networkName or message.destination == "*")
    valid = valid and message.source ~= nil
    return valid
end

local function getModemMessage(filter, timeout)
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

local lastChar = "|"
local charStateLookup = {
    ["|"] = "/",
    ["/"] = "-",
    ["-"] = "\\",
    ["\\"] = "|",
}
local lastCharUpdate = os.epoch("utc")

local function getActivityChar()
    if os.epoch("utc") - lastCharUpdate < 50 then
        return lastChar
    end
    lastCharUpdate = os.epoch("utc")
    lastChar = charStateLookup[lastChar]
    return lastChar
end

local function writeBanner()
    local x, y = term.getCursorPos()

    banner.setBackgroundColor(colors.gray)
    banner.setCursorPos(1, 1)
    banner.clear()
    if connected then
        banner.setTextColor(colors.green)
        banner.write("CONNECTED")
    else
        banner.setTextColor(colors.red)
        banner.write("DISCONNECTED")
    end
    banner.setTextColor(colors.white)
    banner.setCursorPos(w - state:len(), 1)
    banner.write(state)
    term.setCursorPos(x, y)

    local toDisplay = state
    if not connected then
        toDisplay = "!" .. toDisplay
    end

    os.setComputerLabel(
        ("%s %s - %s"):format(getActivityChar(), networkName, toDisplay))
end

local function keepAlive()
    while true do
        local modemMessage = getModemMessage(function(message)
            return validateMessage(message) and message.protocol == "KEEP_ALIVE"
        end, keepAliveTimeout)
        connected = modemMessage ~= nil
        if modemMessage then
            modem.transmit(port, port, {
                protocol = "KEEP_ALIVE",
                state = state,
                source = networkName,
                destination = "HOST",
            })
        end
        writeBanner()
    end
end

local function colWrite(fg, text)
    local oldFg = term.getTextColor()
    term.setTextColor(fg)
    term.write(text)
    term.setTextColor(oldFg)
end

local function saveState()
    -- local f = fs.open(".disposal", "wb")
    -- f.write(textutils.serialise({state=state,task=task}))
    -- f.close()
end

local lastState
---@param newState State
local function changeState(newState)
    if state ~= newState then
        lastStateChange = os.epoch("utc")
        if newState == "ERROR" then
            lastState = state
        end
    end
    state = newState
    saveState()
    modem.transmit(port, port, {
        protocol = "KEEP_ALIVE",
        state = state,
        source = networkName,
        destination = "HOST",
    })
    writeBanner()
end

---@type DisposalTask
local task

---@class DisposalTask
---@field name string
---@field count integer
---@field jobId string

local function signalDone()
    changeState(STATES.DONE)
    modem.transmit(port, port, {
        protocol = "DISPOSAL_DONE",
        destination = "HOST",
        source = networkName,
        jobId = task.jobId,
    })
end

local function tryToDispose()
    -- Check if we have the items to dispose
    local have = 0
    for slot = 1, 16 do
        local item = turtle.getItemDetail(slot)
        if item and item.name == task.name then
            have = have + item.count
        end
    end

    if have >= task.count then
        -- Dispose items (e.g., drop them)
        local remaining = task.count
        for slot = 1, 16 do
            if remaining <= 0 then break end
            local item = turtle.getItemDetail(slot)
            if item and item.name == task.name then
                local toDrop = math.min(item.count, remaining)
                turtle.select(slot)
                turtle.drop(toDrop)
                remaining = remaining - toDrop
            end
        end
        signalDone()
    else
        -- Not enough items to dispose
        changeState(STATES.ERROR)
    end
end

local protocols = {
    DISPOSE = function(message)
        task = message.task
        changeState(STATES.DISPOSING)
        tryToDispose()
    end
}

local interface
local function modemInterface()
    while true do
        local event = getModemMessage(validateMessage)
        assert(event, "Got no message?")
        if protocols[event.message.protocol] then
            protocols[event.message.protocol](event.message)
        end
    end
end

local interfaceLUT
interfaceLUT = {
    help = function()
        local maxw = 0
        local commandList = {}
        for k, v in pairs(interfaceLUT) do
            maxw = math.max(maxw, k:len() + 1)
            table.insert(commandList, k)
        end
        local elementW = math.floor(w / maxw)
        local formatStr = "%" .. maxw .. "s"
        for i, v in ipairs(commandList) do
            term.write(formatStr:format(v))
            if (i + 1) % elementW == 0 then
                print()
            end
        end
        print()
    end,
    clear = function()
        term.clear()
        term.setCursorPos(1, 1)
    end,
    info = function()
        print(("Local network name: %s"):format(networkName))
    end,
    reboot = function()
        os.reboot()
    end,
    reset = function()
        changeState(STATES.READY)
    end
}

function interface()
    print("Disposal turtle ready")
    while true do
        colWrite(colors.cyan, "] ")
        local input = io.read()
        if interfaceLUT[input] then
            interfaceLUT[input]()
        else
            colWrite(colors.red, "Invalid command.")
            print()
        end
    end
end

local function resumeState()
    if state == "DISPOSING" then
        tryToDispose()
    end
end

local retries = 0
local function errorChecker()
    resumeState()
    while true do
        if os.epoch("utc") - lastStateChange > 30000 then
            lastStateChange = os.epoch("utc")
            if state == STATES.DONE then
                signalDone()
                retries = retries + 1
                if retries > 2 then
                    print("Done too long")
                    changeState(STATES.ERROR)
                end
            elseif state == STATES.DISPOSING then
                retries = retries + 1
                if retries > 2 then
                    print("Disposing too long")
                    changeState(STATES.ERROR)
                end
            else
                retries = 0
            end
        end
        os.sleep(1)
        writeBanner()
    end
end

writeBanner()
local ok, err = pcall(parallel.waitForAny, interface, keepAlive, modemInterface, errorChecker)

os.setComputerLabel(("X %s - %s"):format(networkName, "OFFLINE"))
error(err)