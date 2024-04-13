---@class modules.chatbox
---@field interface modules.chatbox.interface
return {
    id = "chatbox",
    version = "1.0.0",
    config = {
        whitelist = {
            default = {},
            description =
            "Users to allow system usage to, in addition to the chatbox owner. In the form of username=true.",
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
        }
    },
    dependencies = {
        introspection = { min = "2.0", optional = true },
        inventory = { min = "2.0" }
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
                args[1] = getBestMatch(loaded.inventory.interface.listNames(), args[1])
                local count = loaded.inventory.interface.pushItems(periph.getInventory(), args[1],
                    tonumber(args[2]), nil, args[3], { allowBadTransfers = true })
                sendMessage(user, "Pushed &9%s &f%s.", count, args[1])
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
                    name = getBestMatch(listing, name)
                    if name then
                        local count = loaded.inventory.interface.pullItems(inv, name, 36 * 64)
                        ds = ds .. ("&9%u &fx %s\n"):format(count, name)
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
        ---@class modules.chatbox.interface
        return {
            start = function()
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
