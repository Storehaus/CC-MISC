-- Sever library for interacting with clients using https://github.com/SkyTheCodeMaster/cc-websocket-bridge

local function deepCloneNoFunc(t)
  local nt = {}
  for k, v in pairs(t) do
    if type(v) == "table" then
      nt[k] = deepCloneNoFunc(v)
    elseif type(v) ~= "function" then
      nt[k] = v
    end
  end
  return nt
end

---@class modules.introspection
---@field interface modules.introspection.interface
return {
  id = "introspection",
  version = "2.0.0",
  config = {
    url = {
      type = "string",
      description = "URL to service hosting https://github.com/SkyTheCodeMaster/cc-websocket-bridge.",
    },
    introspection = {
      type = "table",
      description = "table<string,string> of player names to introspection peripheral names",
      default = { ["ShreksHellraiser"] = "manipulator_0" }
    }
  },
  dependencies = {
    interface = { min = "2.0" }
  },
  init = function(loaded, config)
    local introspection = {}
    for k, v in pairs(config.introspection.introspection.value) do
      introspection[k] = peripheral.call(v, "getInventory")
    end

    local interface = {}
    local ws = assert(http.websocket(config.introspection.url.value)) --[[@as Websocket]]

    local function handleUpdate(list)
      ws.send(textutils.serialise {
        list = deepCloneNoFunc(list),
        protocol = "storage_system_update",
        destination = "*",
        source = "HOST",
      })
    end
    loaded.interface.interface.addInventoryUpdateHandler(handleUpdate)

    local function validateMessage(message)
      local valid = type(message) == "table" and message.protocol ~= nil
      valid = valid and (message.destination == "HOST")
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

    local function handleMessage(event)
      local message = event.message
      if message.method == "pushItems" or message.method == "pullItems" then
        local periphName = config.introspection.introspection.value[message.args[1]]
        local periph = peripheral.wrap(periphName or message.args[1])
        if periphName and periph and periph.getInventory then
          message.args[1] = periph.getInventory()
          message.args[6] = message.args[6] or {}
          message.args[6].optimal = false
          message.args.n = 7
        end
      end
      local response = deepCloneNoFunc(table.pack(loaded.interface.interface.callMethod(message.method, message.args)))
      ws.send(textutils.serialise {
        destination = message.source,
        protocol = "storage_system_websocket",
        response = response,
        method = message.method,
        source = "HOST",
      })
    end

    local function callIntrospection(event)
      local message = event.message
      local periph = introspection[message.player]
      if periph then
        local response = deepCloneNoFunc(table.pack(periph[message.method](table.unpack(message.args, 1, message.args.n))))
        ws.send(textutils.serialise {
          destination = message.source,
          protocol = "call_introspection",
          response = response,
          method = message.method,
          source = "HOST"
        })
      else
        ws.send(textutils.serialise {
          destination = message.source,
          protocol = "call_introspection",
          response = "ACCESS DENIED",
          method = message.method,
          source = "HOST",
        })
      end
    end

    interface.start = function()
      while true do
        local event = getWebsocketMessage(validateMessage)
        assert(event, "Got no message??")
        local message = event.message
        if message.protocol == "storage_system_websocket" and message.method and message.args then
          handleMessage(event)
        elseif message.protocol == "call_introspection" and message.method and message.args and message.player
            and config.introspection.introspection.value[message.player] then
          callIntrospection(event)
        end
      end
    end
    ---@class modules.introspection.interface
    return interface
  end
}
