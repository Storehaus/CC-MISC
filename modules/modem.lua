---@class modules.modem
---@field interface modules.modem.interface
return {
id = "modem",
version = "1.1.0",
config = {
  modem = {
    type = "string",
    description = "Modem to use for communication",
  },
  port = {
    type = "number",
    description = "Port to host communication on",
    default=50
  },
  updatePort = {
    type = "number",
    description = "Port to send storage content updates on",
    default=51
  }
},
dependencies = {
  logger = {min="1.1",optional=true},
  interface = {min="1.1"}
},
init = function(loaded, config)
  local log = loaded.logger
  local logger = setmetatable({}, {__index=function () return function () end end})
  local port = config.modem.port.value
  local updatePort = config.modem.updatePort.value
  if log then
    logger = log.interface.logger("modem","main")
  end
  local interface = {}
  assert(loaded.interface, "modem requires interface to be loaded")
  local modem = assert(peripheral.wrap(config.modem.modem.value), "Invalid modem provided.")
  modem.open(port)

  local function handleUpdate(list)
    modem.transmit(updatePort, port, {
      list = list,
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

  local function handleMessage(event)
    if not event then return end
    local message = event.message
    local response = table.pack(loaded.interface.interface.callMethod(message.method, message.args))
    modem.transmit(event.reply, port, {
      destination = message.source,
      protocol = "storage_system_modem",
      response = response,
      method = message.method,
      source = "HOST",
    })
  end

  interface.start = function()
    while true do
      local event = getModemMessage(validateMessage)
      assert(event, "Got no message??")
      local message = event.message
      if message.protocol == "storage_system_modem" and message.method and message.args then
        handleMessage(event)
      end
    end
  end
  ---@class modules.modem.interface
  return interface
end
}