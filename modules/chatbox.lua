---@class modules.chatbox
---@field interface modules.chatbox.interface
return {
  id = "chatbox",
  version = "1.0.0",
  config = {
    useEnderChestDeposit = {
      default = false,
      description = "Items within vanilla enderchest will automatically be deposited into storage",
      type = "boolean",
    },
    whitelist = {
      default = {},
      description = "Users to allow system usage to, in addition to the chatbox owner. In the form of username=true.",
      type = "table",
    },
    command = {
      default = "misc",
      description = "Command subcommands will be placed under.",
      type = "string",
    },
    name = {
      default = "MISC",
      description = "Chatbox bot name to use.",
      type = "string"
    },
    introspection = {
      default = {},
      description = "If introspection is not present, this serves as a lookup from username->introspection module.",
      type = "table"
    },
    lists = {
      default = {},
      description = "A list of items to deposit at once",
      type = "table"
    },
    enable_ender_storage = {
      default = false,
      description = "Enable public storage pulling",
      type = "boolean"
    },
    ender_storage = {
      default = "ender_storage_161",
      description = "Ender storage to use for misc public <..>",
      type = "string"
    }
  },
  dependencies = {
    introspection = { min = "1.0", optional = true },
    inventory = { min = "1.0" }
  },
  ---@param loaded {inventory: modules.inventory, introspection: modules.introspection}
  init = function(loaded, config)
    sleep(1)
    assert(chatbox and chatbox.isConnected(), "This module requires a registered chatbox.")
    local function sendMessage(user, message, ...)
      chatbox.tell(user, message:format(...), config.chatbox.name.value, nil, "format")
    end
    local function getIntrospection(user)
      return (config.introspection and config.introspection.introspection.value[user]) or
          config.chatbox.introspection.value[user]
    end
    local function linearize(tab)
      local lt = {}
      for k, v in pairs(tab) do
        lt[#lt + 1] = v.name
      end
      return lt
    end
    local function getMatches(list, str)
      local filtered = {}
      if pcall(string.match, "", str) then
        for _, v in ipairs(list) do
          local ok, matches = pcall(string.match, v, str)
          if ok and matches then
            filtered[#filtered + 1] = v
          end
        end
      end
      table.sort(filtered, function(a, b)
        return math.abs(#a - #str) < math.abs(#b - #str)
      end)
      return filtered
    end
    local function getBestMatch(list, str)
      return getMatches(list, str)[1]
    end
    local lists = config.chatbox.lists.value

    local chests = {}

    local ok, err = pcall(function()
      local data = http.get("https://p.sc3.io/pEMm8H7MdJ").readAll()
      for _, v in pairs(textutils.unserialiseJSON(data)) do
        local value = v.name or v.label:match("^[^,]+")
        value = value:lower():gsub(" ", "")
        chests[value] = v
      end
    end)

    if not ok then printError("Online database not loaded: " .. err) end


    local commands = {
      withdraw = function(user, args)
        local introspection = getIntrospection(user)
        if not introspection then
          sendMessage(user, "&cYou do not have a configured introspection module for this MISC system.")
          return
        end
        if #args < 1 then
          sendMessage(user, "usage: withdraw [name] <count> <nbt>")
        end
        local periph = peripheral.wrap(introspection) --[[@as table]]
        if args[1] then
          args[1] = getBestMatch(loaded.inventory.interface.listNames(), args[1])
        else
          sendMessage(user, "&cEither you passed no item, or thats invalid. Try again.")
          args[1] = getBestMatch(loaded.inventory.interface.listNames(), ":")
        end
        if not args[1] then
          sendMessage(user, "&cEither you passed no item, or thats invalid. Try again.")
          return
        end

        local count = 0
        if args[3] == "*" then
          local variants = loaded.inventory.interface.listNBT(args[1])
          for _, nbt in ipairs(variants) do
            count = count +
                loaded.inventory.interface.pushItems(false, periph.getInventory(), args[1], tonumber(args[2]), nil, nbt,
                  { allowBadTransfers = true })
          end
        else
          count = loaded.inventory.interface.pushItems(false, periph.getInventory(), args[1],
            tonumber(args[2]), nil, args[3], { allowBadTransfers = true })
        end

        sendMessage(user, "Pushed &9%s &f%s.", count, args[1])
      end,
      public = function(user, args)
        if not config.chatbox.enable_ender_storage.value then
          sendMessage(user, "Public ender storage pulling is not enabled. Set chatbox.enable_ender_storage to `true`!",
            count, args[1])
          return
        end
        local introspection = getIntrospection(user)
        if not introspection then
          sendMessage(user, "&cYou do not have a configured introspection module for this MISC system.")
          return
        end
        if #args < 1 then
          sendMessage(user, "usage: public [storage name] <count> <type>")
          return
        end

        if not chests[args[1]] then
          sendMessage(user,
            table.concat((function(t)
              local r = {}
              for k in pairs(t) do r[#r + 1] = k end; return r
            end)(chests), ", "))
          return
        end

        chest = chests[args[1]]
        local periph = peripheral.wrap(introspection) --[[@as table]]
        local estorage = peripheral.wrap(config.chatbox.ender_storage.value) --[[@as table]]

        estorage.setFrequency(colors[chest.named[1]], colors[chest.named[2]], colors[chest.named[3]])

        local targetCount = tonumber(args[2])
        local pulled = 0

        for slot, item in ipairs(estorage.list()) do
          if not item then goto continue end

          if args[4] and item.name ~= args[4] then
            goto continue
          end

          local remaining = targetCount - pulled
          if remaining <= 0 then break end

          local pulledNow = periph.getInventory().pullItems(
            config.chatbox.ender_storage.value,
            slot,
            math.min(remaining, item.count)
          )

          pulled = pulled + pulledNow

          ::continue::
        end
        sendMessage(user, "Withdrawed %s from %s.", pulled, args[1])
      end,
      balance = function(user, args)
        if #args < 1 then
          sendMessage(user, "usage: balance [name] <nbt>")
          return
        end
        args[1] = getBestMatch(loaded.inventory.interface.listNames(), args[1])
        local count = loaded.inventory.interface.getCount(args[1], args[2])
        sendMessage(user, "The system has &9%u &f%s", count, args[1])
      end,
      deposit = function(user, args)
        local introspection = getIntrospection(user)
        if not introspection then
          sendMessage(user, "&cYou do not have a configured introspection module for this MISC system.")
          return
        end
        if #args < 1 then
          sendMessage(user, "usage: deposit [name...]")
          return
        end
        local inv = peripheral.wrap(introspection).getInventory() --[[@as table]]
        local listing = linearize(inv.list())
        local ds = "Deposited:\n"
        for _, name in pairs(args) do
          local isListing = name:match("list:")
          local tbl
          if isListing then
            local tableName = name:gsub("list:", "")
            if lists[tableName] then
              tbl = lists[tableName]
            else
              sendMessage(user, "Invalid list: " .. tableName)
              return
            end
            for i, v in ipairs(tbl) do
              local count = loaded.inventory.interface.pullItems(false, inv, v, 36 * 64)
              ds = ds .. ("&9%u &fx %s\n"):format(count, v)
            end
          else
            name = getBestMatch(listing, name)
            if name then
              local count = loaded.inventory.interface.pullItems(false, inv, name, 36 * 64)
              ds = ds .. ("&9%u &fx %s\n"):format(count, name)
            end
          end
        end
        sendMessage(user, ds)
      end,
      list = function(user, args)
        if #args < 1 then
          sendMessage(user, "usage: list [name]")
          return
        end
        local matches = getMatches(loaded.inventory.interface.listNames(), args[1])
        local ms = ("'&9%s&f' matches:\n"):format(args[1])
        for i = 1, 10 do
          if not matches[i] then
            break
          end
          ms = ms .. ("&9%u &fx %s\n"):format(loaded.inventory.interface.getCount(matches[i]), matches[i])
        end
        sendMessage(user, ms)
      end
    }

    function depositIntoEnderChest(user)
      local introspection = getIntrospection(user)
      local enderChest = peripheral.wrap(introspection).getEnder()
      for i = 1, enderChest.size(), 1 do
        loaded.inventory.interface.performTransfer()
        if enderChest.getItemDetail(i) == nil then
          goto continue
        end
        loaded.inventory.interface.pullItems(false, enderChest, i, nil, nil, nil, { optimal = true })
        --loaded.inventory.interface.pullItems(false, enderChest,i, 64)
        loaded.inventory.interface.performTransfer()

        ::continue::
      end
      sendMessage(user, "Ender Chest deposited")
    end

    ---@class modules.chatbox.interface
    return {
      start = function()
        if config.chatbox.useEnderChestDeposit.value then
          commands["enderdeposit"] = function(user, args)
            depositIntoEnderChest(user)
          end
        end
        while true do
          local event, user, command, args, data = os.pullEvent("command")
          local verified = data.ownerOnly
          if not verified and config.chatbox.whitelist.value[user] then
            verified = true
          end
          if verified and command == config.chatbox.command.value then
            if commands[args[1]] then
              commands[args[1]](user, { table.unpack(args, 2, #args) })
            else -- show helptext
              local ht = "Valid commands are: "
              for k, v in pairs(commands) do
                ht = ht .. k .. " "
              end
              sendMessage(user, ht)
            end
          end
        end
      end
    }
  end
}
