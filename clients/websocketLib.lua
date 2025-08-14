-- Client library for interacting with a server using https://github.com/SkyTheCodeMaster/cc-websocket-bridge

local lib = {}
local name
local ws
local timeout = 4000
local maxRetries = 10

local function validateMessage(message)
  local valid = type(message) == "table" and message.protocol ~= nil
  valid = valid and (message.destination == name or message.destination == "*")
  valid = valid and message.source ~= nil
  return valid
end
local function getWebsocketMessage(filter, timeout)
  local timer
  if timeout then
    timer = os.startTimer(timeout)
  end
  while true do
    ---@type string, string, integer, integer, any, integer
    local event, id, message = os.pullEvent()
    if event == "websocket_message" then
      ---@diagnostic disable-next-line: cast-local-type
      message = textutils.unserialise(message --[[@as string]]) --[[@as table]]
      if (filter == nil or filter(message)) then
        if timeout then
          os.cancelTimer(timer)
        end
        return {
          message = message,
        }
      end
    elseif event == "timer" and timeout and id == timer then
      return
    end
  end
end
local function interface(method, ...)
  local message = {
    method = method,
    args = table.pack(...),
    protocol = "storage_system_websocket",
    source = name,
    destination = "HOST"
  }
  ws.send(textutils.serialise(message))
  local waitStart = os.epoch("utc")
  local failures = 0
  while true do
    local event = getWebsocketMessage(validateMessage, 4)
    if event then
      local recMessage = event.message
      if recMessage.protocol == "storage_system_websocket" and recMessage.method == method then
        return table.unpack(recMessage.response)
      end
    end
    if waitStart + timeout < os.epoch("utc") then
      if failures < maxRetries then
        print("Response timed out, retrying.")
        ws.send(message)
        failures = failures + 1
        waitStart = os.epoch("utc")
      else
        error(("Got no response after %u failures."):format(failures), 2)
      end
    end
  end
end

---Call methods on a given player's introspection peripheral
---@param player string
---@param method string
---@param ... any
function lib.callIntrospection(player, method, ...)
  local message = {
    player = player,
    method = method,
    args = table.pack(...),
    protocol = "call_introspection",
    source = name,
    destination = "HOST"
  }
  ws.send(textutils.serialise(message))
  local waitStart = os.epoch("utc")
  local failures = 0
  while true do
    local event = getWebsocketMessage(validateMessage, 4)
    if event then
      local recMessage = event.message
      if recMessage.protocol == "call_introspection" and recMessage.method == method then
        return table.unpack(recMessage.response)
      end
    end
    if waitStart + timeout < os.epoch("utc") then
      if failures < maxRetries then
        print("Response timed out, retrying.")
        ws.send(message)
        failures = failures + 1
        waitStart = os.epoch("utc")
      else
        error(("Got no response after %u failures."):format(failures), 2)
      end
    end
  end
end

---Connect to the storage system
function lib.connect(url)
  name = "client_" .. os.epoch("utc")
  ws = assert(http.websocket(url))
end

---Pull items from an inventory
---@param async boolean
---@param player string|AbstractInventory
---@param fromSlot string|number
---@param amount nil|number
---@param toSlot nil|number
---@param nbt nil|string
---@param options nil|TransferOptions
function lib.pullItems(async, player, fromSlot, amount, toSlot, nbt, options)
  return interface("pullItems", async, player, fromSlot, amount, toSlot, nbt, options)
end

---Push items to an inventory
---@param async boolean
---@param player string
---@param name string|number
---@param amount nil|number
---@param toSlot nil|number
---@param nbt nil|string
---@param options nil|TransferOptions
function lib.pushItems(async, player, name, amount, toSlot, nbt, options)
  return interface("pushItems", async, player, name, amount, toSlot, nbt, options)
end

---List inventory contents
function lib.list()
  return interface("list")
end

function lib.requestCraft(name, count)
  return interface("requestCraft", name, count)
end

---Subscribe to transfers
function lib.subscribe()
  while true do
    local event = getWebsocketMessage(validateMessage)
    assert(event, "Got no event")
    if event.message.protocol == "storage_system_update" then
      os.queueEvent("update", event.message.list)
    end
  end
end

function lib.performTransfer()
  return interface("performTransfer")
end

function lib.listCraftables()
  return interface("listCraftables")
end

function lib.startCraft(jobID)
  return interface("startCraft", jobID)
end

function lib.cancelCraft(jobID)
  return interface("cancelCraft", jobID)
end

function lib.addGridRecipe(name, produces, recipe, shaped)
  return interface("addGridRecipe", name, produces, recipe, shaped)
end

function lib.getUsage()
  return interface("getUsage")
end

function lib.removeGridRecipe(name)
  return interface("removeGridRecipe", name)
end

---@type genericinterface
return setmetatable(lib, {
  __index = function(t, k)
    return function(...)
      return interface(k, ...)
    end
  end
})
