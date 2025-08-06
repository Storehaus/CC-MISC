-- storage terminal turtle for the system
local lib

local wirelessMode = not turtle
local turtleMode = turtle
local inventory, invPeripheral, importStart, importEnd, pollFrequency, exportStart, exportEnd, player

local mainFg = colors.white
local mainBg = colors.black

local selectBg, selectFg, menuFg, menuBg, headerFg, headerBg, searchFg, searchBg, listBg, listFg, errFg, tabFg, tabBg

local function refreshTurtleInventory()
    local turtleInventory = {}
    local f = {}
    for i = 1, 16 do
        f[i] = function()
            turtleInventory[i] = turtle.getItemDetail(i, true)
        end
    end
    parallel.waitForAll(table.unpack(f))
    return turtleInventory
end

local themes = { "default", "amber", "green", "aqua", "graphite", "hotdogstand", "turtle" }

local function firstTimeSetup()
    settings.define("misc.turtle", { description = "Should this terminal be in turtle mode?", type = "boolean" })
    settings.define("misc.websocketURL",
        { description = "URL of the websocket to use for wireless communication", type = "string" })
    settings.define("misc.wireless",
        {
            description = "Should this terminal be in wireless mode? (Use websocket + introspection module)",
            type = "boolean"
        })
    settings.define("misc.importStart", { description = "Overwrite the default starting import slot", type = "number" })
    settings.define("misc.importEnd", { description = "Overwrite the default ending import slot", type = "number" })
    settings.define("misc.exportStart", { description = "Overwrite the default starting export slot", type = "number" })
    settings.define("misc.exportEnd", { description = "Overwrite the default ending export slot", type = "number" })
    settings.define("misc.player", { description = "Player to use for wireless mode", type = "string" })
    settings.define("misc.inventory", {
        description = "Inventory to use when not wireless, and not a turtle",
        type = "string"
    })
    settings.define("misc.dropOnExport",
        { description = "If this turtle should drop items on export.", type = "boolean" })

    settings.set("misc.turtle", not not (turtle))
    if settings.get("misc.turtle") then
        print("Assuming turtle mode..")
        sleep(1)
        settings.save()
        return
    end
    print("Should this operate in wireless mode?")
    print("Wireless mode would be for introspection module use.")
    print("Otherwise, this will act as an item terminal with a redirectable i/o inventory.")
    print("y/n? ")
    local choice
    while choice ~= 'y' and choice ~= 'n' do
        choice = read()
    end
    wirelessMode = choice == 'y'
    settings.set("misc.wireless", wirelessMode)
    if wirelessMode then
        print("Enter the URL of the websocket relay service you would like to use.")
        settings.set("misc.websocketURL", read())
        print("Enter the player name")
        settings.set("misc.player", read())
    else
        print("Enter the name of the I/O inventory peripheral")
        settings.set("misc.inventory", read())
    end
    settings.save()
end

local themeInfo = "The theme to use. Available themes : "
for _, v in pairs(themes) do
    themeInfo = themeInfo .. " " .. v
end
settings.define("misc.theme", { description = themeInfo, type = "string", default = "default" })

settings.load()
if settings.get("misc.turtle") == nil then
    firstTimeSetup()
end


turtleMode = settings.get("misc.turtle")
wirelessMode = settings.get("misc.wireless")
player = settings.get("misc.player")
local websocketURL = settings.get("misc.websocketURL")
inventory = settings.get("misc.inventory")

if wirelessMode then
    lib = require("websocketLib")
    lib.connect(websocketURL)
else
    lib = require("modemLib")
    local modem = peripheral.getName(peripheral.find("modem"))
    lib.connect(modem)
    if turtleMode then
        inventory = peripheral.call(modem, "getNameLocal")
        invPeripheral = turtle
        invPeripheral.list = refreshTurtleInventory
        importStart = settings.get("misc.importStart") or 1
        importEnd = settings.get("misc.importEnd") or 8
        exportStart = settings.get("misc.exportStart") or 9
        exportEnd = settings.get("misc.exportEnd") or 16
    end
end
if not turtleMode then
    if wirelessMode then
        importStart = settings.get("misc.importStart") or 19
        importEnd = settings.get("misc.importEnd") or 19
        exportStart = settings.get("misc.exportStart") or 20
        exportEnd = settings.get("misc.exportEnd") or 27
        inventory = player
    else
        invPeripheral = peripheral.wrap(inventory) --[[@as Inventory]]
        local size = invPeripheral.size()
        importStart = settings.get("misc.importStart") or 1
        importEnd = settings.get("misc.importEnd") or math.floor(size / 2)
        exportStart = settings.get("misc.exportStart") or importEnd + 1
        exportEnd = settings.get("misc.exportEnd") or size
    end
    pollFrequency = 3
end

local function processTurtleInventory()
    while true do
        os.pullEvent("do_turtle_transfers")
        for i = importStart, importEnd do
            if turtle.getItemDetail(i) then
                lib.pullItems(true, inventory, i, nil, nil, nil, { optimal = false })
            end
        end
        if settings.get("misc.dropOnExport") then
            for i = exportStart, exportEnd do
                if turtle.getItemDetail(i) then
                    turtle.select(i)
                    turtle.drop()
                end
            end
        end
        lib.performTransfer()
    end
end

local function debounceTurtleInventory()
    local dropExportTimer
    while true do
        local e, id = os.pullEvent()
        if e == "turtle_inventory" then
            if dropExportTimer then
                os.cancelTimer(dropExportTimer)
            end
            dropExportTimer = os.startTimer(0.1)
        elseif e == "timer" and id == dropExportTimer then
            dropExportTimer = nil
            os.queueEvent("do_turtle_transfers")
        end
    end
end

local function inventoryPoll()
    local slotActive = false
    local slotActiveTicks = 0
    while true do
        sleep((slotActive and pollFrequency / 3) or pollFrequency)
        slotActiveTicks = slotActiveTicks + 1
        if slotActiveTicks > 5 then
            slotActive = false
        end
        local listing = (wirelessMode and lib.callIntrospection(player, "list")) or invPeripheral.list()
        for i = importStart, importEnd do
            if listing[i] then
                slotActive = true
                slotActiveTicks = 0
                lib.pullItems(true, inventory, i, nil, nil, nil, { optimal = false })
            end
        end
    end
end

local SEARCH, CRAFT, INFO, REQUEST, SYSINFO

local display = window.create(term.current(), 1, 1, term.getSize())
term.redirect(display)
local mode = ""
local modes = { "SEARCH", "CRAFT", "CONFIG", "SYSINFO" }
local modeLookup
local w, h = display.getSize()
local itemCountW = 5
local itemNameW = w - itemCountW

local function resetPalette(dev)
    dev = dev or display
    for i = 0, 15 do
        dev.setPaletteColor(2 ^ i, term.nativePaletteColor(2 ^ i))
    end
end

-- theme setup
local function themeSetup(dev)
    dev = dev or display
    resetPalette(dev)
    mainFg = colors.white
    mainBg = colors.black
    selectBg, selectFg, menuFg, menuBg, headerFg, headerBg, searchFg, searchBg, listBg, listFg, errFg, tabFg, tabBg = nil,
        nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
    local theme = settings.get("misc.theme")
    if theme == "amber" then
        mainFg = colors.orange
        dev.setPaletteColor(colors.orange, 0xFFCC00)
    elseif theme == "green" then
        mainFg = colors.green
        dev.setPaletteColor(colors.green, 0x33FF00)
    elseif theme == "aqua" then
        mainBg = colors.white
        mainFg = colors.black
        menuBg = colors.lightGray
        menuFg = colors.black
        tabBg = colors.blue
        tabFg = colors.white
        selectBg = colors.blue
        selectFg = colors.white
        headerBg = colors.gray
        listBg = colors.cyan
        dev.setPaletteColor(colors.blue, 0x4588cb)
        dev.setPaletteColor(colors.white, 0xffffff)
        dev.setPaletteColor(colors.black, 0x0f0f0f)
        dev.setPaletteColor(colors.gray, 0xb9b9b9)
        dev.setPaletteColor(colors.lightGray, 0xe7e7e7)
        dev.setPaletteColor(colors.cyan, 0xdee4e9) -- blue tinted gray
    elseif theme == "graphite" then
        mainBg = colors.white
        mainFg = colors.black
        menuBg = colors.lightGray
        menuFg = colors.black
        tabBg = colors.blue
        tabFg = colors.white
        selectBg = colors.blue
        selectFg = colors.white
        headerBg = colors.gray
        listBg = colors.cyan
        dev.setPaletteColor(colors.blue, 0x556077) -- desaturated blue
        dev.setPaletteColor(colors.white, 0xffffff)
        dev.setPaletteColor(colors.black, 0x0f0f0f)
        dev.setPaletteColor(colors.gray, 0xbebebe)
        dev.setPaletteColor(colors.lightGray, 0xe7e7e7)
        dev.setPaletteColor(colors.cyan, 0xe1e5ee) -- blue tinted gray
    elseif theme == "hotdogstand" then
        mainBg = colors.red
        mainFg = colors.white
        tabBg = colors.black
        tabFg = colors.white
        menuFg = colors.white
        menuBg = colors.red
        headerBg = colors.white
        headerFg = colors.black
        searchBg = colors.white
        searchFg = colors.black
        listBg = colors.yellow
        listFg = colors.black
        selectBg = colors.black
        selectFg = colors.white
        dev.setPaletteColor(colors.yellow, 0xffff00)
        dev.setPaletteColor(colors.red, 0xff0000)
        dev.setPaletteColor(colors.white, 0xffffff)
        dev.setPaletteColor(colors.black, 0x000000)
    elseif theme == "turtle" then
        mainFg = colors.white
        mainBg = colors.gray
        menuBg = colors.yellow
        menuFg = colors.white
        tabBg = colors.black
        tabFg = colors.white
        headerBg = colors.yellow
        selectBg = colors.black
        selectFg = colors.white

        dev.setPaletteColor(colors.gray, 0xCEB15F)   -- turtle slot color
        dev.setPaletteColor(colors.yellow, 0xdba519) -- turtle yellow
        dev.setPaletteColor(colors.white, 0xfcfcfc)  -- off white
        dev.setPaletteColor(colors.black, 0x1c0a11)  -- off black
    end

    -- selected item in lists
    selectBg = selectBg or mainFg
    selectFg = selectFg or mainBg

    -- top menu bar
    menuFg = menuFg or mainBg
    menuBg = menuBg or mainFg

    -- selected tab
    tabFg = tabFg or menuBg
    tabBg = tabBg or menuFg

    -- page headers
    headerFg = headerFg or mainFg
    headerBg = headerBg or mainBg

    -- search bars
    searchFg = searchFg or mainFg
    searchBg = searchBg or mainBg

    -- lists
    listFg = listFg or mainFg
    listBg = listBg or mainBg

    -- failure indicating color
    errFg = errFg or colors.red
end
themeSetup()

local function formatItem(name, count)
    return ("%-" .. itemCountW .. "s %-" .. itemNameW .. "s"):format(count, name)
end
local function setColors(fg, bg, device)
    device = device or display
    device.setTextColor(fg)
    device.setBackgroundColor(bg)
end
local function clearLine(y, device)
    device = device or display
    device.setCursorPos(1, y)
    device.clearLine()
end
local function text(x, y, t, device)
    device = device or display
    device.setCursorPos(math.floor(x), math.floor(y))
    device.write(t)
end

---@param t any[]
---@param pattern string
---@param sort nil|fun(a: any, b: any): boolean
---@param match nil|fun(val: any, pattern: string): boolean
---@return any[]
local function filterList(t, pattern, sort, match)
    table.sort(t, sort)
    local sifted = {}
    if pcall(string.match, "", pattern) then
        for k, v in pairs(t) do
            local ok, matches
            if not match then
                ok, matches = pcall(string.match, v, pattern)
            else
                ok, matches = pcall(match, v, pattern)
            end
            if ok and matches then
                table.insert(sifted, v)
            end
        end
    end
    return sifted
end

local craftInfo

local function getFirstItemOnScreen(item, list)
    return math.max(math.min(math.max(1, item - 5), #list - h + 4), 1)
end

local function getLastItemOnScreen(item, list)
    local scroll = getFirstItemOnScreen(item, list)
    return math.min(scroll + h + 1, #list)
end

local function getYWithScroll(scroll, item)
    return 4 - scroll + item
end

---@param filter string
---@param selected integer
---@param list any[] filtered list
---@param header string
---@param dataFormatter fun(item: any): string
local function drawSearch(filter, selected, list, header, dataFormatter)
    setColors(searchFg, searchBg)
    clearLine(2)
    text(1, 2, filter)
    setColors(headerFg, headerBg)
    clearLine(3)
    text(1, 3, header)
    setColors(listFg, listBg)
    for y = 4, h do
        clearLine(y)
    end
    local screenScroll = getFirstItemOnScreen(selected, list)
    for i = screenScroll, getLastItemOnScreen(screenScroll, list) do
        local item = list[i]
        local y = getYWithScroll(screenScroll, i)
        if y > 3 then
            if i == selected then
                setColors(selectFg, selectBg)
            end
            clearLine(y)
            text(1, y, dataFormatter(item))
            setColors(listFg, listBg)
        end
    end
    setColors(mainFg, mainBg)
    display.setCursorBlink(true)
    display.setCursorPos(filter:len() + 1, 2)
end

---@param drawFunc function
local function draw(drawFunc, ...)
    display.setVisible(false)
    display.setCursorBlink(false)
    setColors(mainFg, mainBg)
    display.clear()
    setColors(menuFg, menuBg)
    display.setCursorPos(1, 1)
    display.clearLine()
    if modeLookup[mode] then
        for k, v in ipairs(modes) do
            if v == mode then
                setColors(tabFg, tabBg)
            end
            display.write(" " .. v .. " ")
            setColors(menuFg, menuBg)
        end
    else
        local w, _ = display.getSize()
        display.setCursorPos((w - #mode) / 2, 1)
        display.write(mode)
    end
    setColors(mainFg, mainBg)
    drawFunc(...)
    display.setVisible(true)
end

---@return function? newMode
local function handleClicks(x, y)
    local sx = 1
    if y == 1 then
        for i, m in ipairs(modes) do
            if x >= sx and x < sx + #m + 2 then
                -- on the button
                return modeLookup[m]
            end
            sx = sx + #m + 2
        end
    end
end

local function doTransfers(item, target)
    local moved = true
    local firstTry = true
    while moved and target > 0 do
        if firstTry then
            firstTry = false
        else
            sleep(1)
        end
        moved = false
        local listing = (wirelessMode and lib.callIntrospection(player, "list")) or invPeripheral.list()
        for i = exportStart, exportEnd do
            if not listing[i] then
                lib.pushItems(true, inventory, item.name, target, i, item.nbt, { optimal = false })
                target = target - item.maxCount
                moved = true
                if target <= 0 then
                    break
                end
            end
        end
    end
    return target
end

---Request an item
---@param requestingCraft boolean
---@param item string
---@param amount integer?
local function requestItem(requestingCraft, item, amount)
    amount = amount or 0
    if amount == 0 then
        return
    end
    if requestingCraft then
        lib.requestCraft(item.name, amount)
        return
    end
    amount = math.min(amount, item.count)
    doTransfers(item, amount)
    lib.performTransfer()
end

local function isEnter(key)
    return key == keys.enter or key == keys.numPadEnter
end


local function cycleTheme()
    local current = settings.get("misc.theme")
    local next
    for i, theme in ipairs(themes) do
        if theme == current then
            next = i + 1
            break
        end
    end
    if next then
        if next > #themes then
            next = 1
        end
        settings.set("misc.theme", themes[next])
        settings.save()
        themeSetup()
    end
end

local filter = ""
---Handle creating and drawing a searchable menu
---@param drawer fun(filter: string, selected: integer, sifted: any[])
---@param listProvider fun(): any[]
---@param onSelect fun(selected: any, index: integer)
---@param event nil|fun(e: any[]): boolean?
---@param sort nil|fun(a: any, b: any): boolean
---@param match nil|fun(val: any, pattern: string): boolean
---@param tab function? mode to switch to upon pushing tab
---@param selected integer?
local function searchableMenu(drawer, listProvider, onSelect, event, sort, match, tab, selected)
    local sifted = filterList(listProvider(), filter, sort, match)
    selected = selected or 1
    local controlHeld = false
    while true do
        draw(drawer, filter, selected, sifted)
        local e = { os.pullEvent() }
        if event then
            if event(e) then
                sifted = filterList(listProvider(), filter, sort, match)
            end
        end
        if e[1] == "char" then
            filter = filter .. e[2]
            sifted = filterList(listProvider(), filter, sort, match)
        elseif e[1] == "key" then
            local key = e[2]
            if key == keys.backspace then
                filter = filter:sub(1, -2)
                sifted = filterList(listProvider(), filter, sort, match)
                selected = math.min(math.max(selected, 1), #sifted)
            elseif key == keys.up then
                selected = math.max(selected - 1, 1)
            elseif key == keys.down then
                selected = math.min(selected + 1, #sifted)
            elseif isEnter(key) then
                if selected > 0 and sifted[selected] then
                    return onSelect(sifted[selected], selected)
                end
            elseif key == keys.tab and tab then
                return tab()
            elseif controlHeld and key == keys.u then
                filter = ""
                sifted = filterList(listProvider(), filter, sort, match)
                selected = math.min(selected, #sifted)
            elseif controlHeld and key == keys.c then
                cycleTheme()
            elseif key == keys.leftCtrl then
                controlHeld = true
            end
        elseif e[1] == "key_up" and e[2] == keys.leftCtrl then
            controlHeld = false
        elseif e[1] == "mouse_click" and e[4] > 3 then
            selected = math.max(math.min(getFirstItemOnScreen(selected, sifted) + e[4] - 4, #sifted), 1)
            if sifted[selected] then
                return onSelect(sifted[selected], selected)
            end
        elseif e[1] == "mouse_click" then
            local nm = handleClicks(e[3], e[4])
            if nm then
                return nm()
            end
        elseif e[1] == "mouse_scroll" then
            selected = math.max(math.min(selected + e[2], #sifted), 1)
        end
    end
end

local search_selected = 1
function SEARCH()
    local list = lib.list()
    mode = "SEARCH"

    local drawer = function(filter, selected, sifted)
        drawSearch(filter, selected, sifted, formatItem("Name", "Count"), function(item)
            return formatItem(item.displayName, item.count)
        end)
    end

    local match = function(v, filter)
        return v.name:match(filter) or v.displayName:lower():match(filter) or v.displayName:match(filter)
    end

    local sort = function(a, b)
        if a.count ~= b.count then
            return a.count > b.count
        end
        return a.name < b.name
    end

    local onSelect = function(selected, index)
        search_selected = index
        return INFO(selected)
    end

    local event = function(e)
        if e[1] == "update" then
            list = e[2]
            return true
        end
    end

    return searchableMenu(drawer, function() return list end, onSelect, event, sort, match, CRAFT, search_selected)
end

function CRAFT()
    mode = "CRAFT"
    local craftables = lib.listCraftables()

    local drawer = function(craftFilter, selectedCraft, siftedCraftables)
        drawSearch(craftFilter, selectedCraft, siftedCraftables, "Name", function(item)
            return item
        end)
    end

    local onSelect = function(selected)
        return REQUEST(selected)
    end

    return searchableMenu(drawer, function() return craftables end, onSelect, nil, nil, nil, CONFIG)
end

---Read some number from the user
---@param input number|string
---@return number
local function scroll_read(input)
    ---@type string
    input = tostring(input)
    local shiftHeld = false
    local x, y = term.getCursorPos()
    while true do
        term.setCursorPos(x, y)
        term.write((" "):rep(#input + 1))
        term.setCursorPos(x, y)
        term.write(input)
        local e, char = os.pullEvent()
        if e == "char" and tonumber(char) then
            input = input .. char
        elseif e == "key" then
            if char == keys.backspace then
                input = input:sub(1, -2)
            elseif char == keys.enter then
                return tonumber(input) or 0
            elseif char == keys.leftShift then
                shiftHeld = true
            end
        elseif e == "key_up" and char == keys.leftShift then
            shiftHeld = false
        elseif e == "mouse_scroll" then
            local scrollAmount = ((shiftHeld and 8) or 1) * -char
            local newValue = math.max(scrollAmount + (tonumber(input) or 0), 0)
            newValue = math.ceil(newValue / scrollAmount) * scrollAmount
            input = tostring(newValue)
        elseif e == "mouse_click" then
            if char == 1 then
                return tonumber(input) or 0
            elseif char == 2 then
                return 0
            end
        end
    end
end

function INFO(item)
    mode = "INFO"
    local itemAmount = math.min(item.maxCount, item.count)
    draw(function()
        setColors(headerFg, headerBg)
        clearLine(2)
        text(1, 2, ("%u x %s"):format(item.count, item.displayName))
        setColors(mainFg, mainBg)
        text(1, 3, item.name)
        text(1, 4, item.nbt)
        if item.enchantments then
            text(1, 5, "Enchantments")
            for k, v in ipairs(item.enchantments) do
                text(1, 5 + k, v.displayName or v.name)
            end
        end
        text(1, h, "Withdraw: ")
        display.setCursorBlink(true)
    end)
    itemAmount = scroll_read(itemAmount)
    requestItem(false, item, tonumber(itemAmount or 0))
    return SEARCH()
end

function REQUEST(item)
    mode = "REQUEST"
    if not item then
        return CRAFT()
    end
    while true do
        draw(function()
            setColors(headerFg, headerBg)
            clearLine(2)
            text(1, 2, item)
            setColors(mainFg, mainBg)
            text(1, 3, "Quantity? ")
            display.setCursorPos(1, 3)
            display.clearLine()
        end)
        local input = scroll_read(1)
        if input == 0 then
            return CRAFT()
        end
        local num_input = tonumber(input)
        if num_input and num_input > 0 then
            craftInfo = lib.requestCraft(item, tonumber(input))
            break
        end
    end

    local oldTerm = term.current()
    local viewTerm = window.create(oldTerm, 1, 5, term.getSize())
    setColors(mainFg, mainBg, viewTerm)
    viewTerm.clear()
    local height = 5
    for _ in pairs(craftInfo.missing) do height = height + 1 end
    local hasUse = false
    for _ in pairs(craftInfo.toUse) do
        hasUse = true; height = height + 1
    end
    for _ in pairs(craftInfo.toCraft) do height = height + 1 end
    local win = window.create(viewTerm, 1, 1, term.getSize(), height)
    setColors(mainFg, mainBg, win)
    win.clear()
    local line = 1
    draw(function()
        setColors(headerFg, headerBg)
        clearLine(2)
        text(1, 2, (craftInfo.success and "Press y to craft, n to cancel") or "Press n to cancel the craft")
        setColors(mainFg, mainBg)
        text(1, 3, ("Requested %s"):format(item))
        text(1, 4, (craftInfo.success and "Success") or "Failure")
        if not craftInfo.success then
            setColors(errFg, mainBg, win)
            text(1, line, "Missing:", win)
            line = line + 1
            for k, v in pairs(craftInfo.missing) do
                text(1, line, ("%ux%s"):format(v, k), win)
                line = line + 1
            end
            setColors(mainFg, mainBg, win)
        end
        if hasUse then
            text(1, line, "To use:", win)
            line = line + 1
            for k, v in pairs(craftInfo.toUse) do
                text(1, line, ("%ux%s"):format(v, k), win)
                line = line + 1
            end
        end
        text(1, line, "To craft:", win)
        line = line + 1
        for k, v in pairs(craftInfo.toCraft) do
            text(1, line, ("%ux%s"):format(v, k), win)
            line = line + 1
        end
    end)
    local scrollPos = 1
    win.reposition(1, scrollPos)

    while true do
        local e = { os.pullEvent() }
        if e[1] == "char" then
            local ch = e[2]
            if craftInfo then
                if ch == 'y' and craftInfo.success then
                    lib.startCraft(craftInfo.jobId)
                    craftInfo = nil
                    return SEARCH()
                elseif ch == 'n' then
                    if craftInfo.success then
                        lib.cancelCraft(craftInfo.jobId)
                    end
                    craftInfo = nil
                    return SEARCH()
                end
            end
        elseif e[1] == "key" then
            local key = e[2]
            if key == keys.down then
                scrollPos = math.max(3 - line, scrollPos - 1)
                viewTerm.clear()
                win.reposition(1, scrollPos)
            elseif key == keys.up then
                scrollPos = math.min(1, scrollPos + 1)
                viewTerm.clear()
                win.reposition(1, scrollPos)
            end
        elseif e[1] == "mouse_scroll" then
            scrollPos = math.min(1, math.max(3 - line, scrollPos - e[2]))
            viewTerm.clear()
            win.reposition(1, scrollPos)
        end
    end
end

local function getConfigListString(item)
    local s = ""
    local i = item.parentStructure
    while i and i.parentStructure do
        if i.last then
            s = " " .. s
        else
            s = "\149" .. s
        end
        i = i.parentStructure
    end
    if item.parentStructure then
        if item.last then
            s = s .. "\141"
        else
            s = s .. "\157"
        end
    end
    if item.type == "table" then
        s = s .. "\8"
    end
    s = s .. item.key
    if item.type ~= "table" then
        s = s .. string.format("=%s", item.value)
    end
    return s
end

---@param dev Window
---@param t table
---@param onChange fun(selected: tableStructure)
local function tableExplorer(dev, t, onChange)
    setColors(listFg, listBg, dev)
    local selected = 1
    ---@alias tableStructure {parent: table, parentStructure: table?, key: any, value: any, level: integer, type: string, last: boolean}
    ---@type tableStructure[]
    local tableStructure = {}
    local function traverse(t, l, ps)
        local i
        for k, v in pairs(t) do
            i = #tableStructure + 1
            tableStructure[i] = { parent = t, parentStructure = ps, key = k, value = v, type = type(v), level = l }
            if type(v) == "table" then
                traverse(v, l + 1, tableStructure[i])
            end
        end
        if i then
            tableStructure[i].last = true
        end
    end
    traverse(t, 1)
    onChange(tableStructure[selected])
    return {
        ---Pass in an event
        ---@param e table
        event = function(e)
            if e[1] == "key" then
                if e[2] == keys.up then
                    selected = math.max(selected - 1, 1)
                elseif e[2] == keys.down then
                    selected = math.min(selected + 1, #tableStructure)
                end
                onChange(tableStructure[selected])
            elseif e[1] == "mouse_scroll" then
                selected = math.max(math.min(selected + e[2], #tableStructure), 1)
                onChange(tableStructure[selected])
            elseif e[1] == "mouse_click" then
                local w, h = dev.getSize()
                local firstElement = math.min(math.max(selected - math.floor(h / 2), 1), #tableStructure - h + 1)
                local x, y = dev.getPosition()
                selected = math.max(math.min(firstElement + e[4] - y, #tableStructure), 1)
                onChange(tableStructure[selected])
            end
        end,
        ---Update the table
        ---@param nt table?
        update = function(nt)
            if nt then
                t = nt
            end
            tableStructure = {}
            traverse(t, 1)
            selected = math.min(selected, #tableStructure)
            onChange(tableStructure[selected])
        end,
        draw = function()
            setColors(listFg, listBg, dev)
            dev.clear()
            local w, h = dev.getSize()
            local firstElement = math.min(math.max(selected - math.floor(h / 2), 1), #tableStructure - h + 1)
            for y = 1, h do
                local item = tableStructure[y + firstElement - 1]
                if item then
                    if firstElement + y - 1 == selected then
                        setColors(selectFg, selectBg, dev)
                    end
                    clearLine(y, dev)
                    text(1, y, getConfigListString(item), dev)
                    setColors(listFg, listBg, dev)
                end
            end
            setColors(mainBg, mainFg, dev)
        end
    }
end

local function handleEditEvents(ctrlHeld, e, tab, selected, parent)
    if e[1] == "key" then
        if e[2] == keys.leftCtrl then
            ctrlHeld = true
        end
        if ctrlHeld then
            if selected and e[2] == keys.k then
                -- change key
                setColors(mainFg, mainBg)
                clearLine(h)
                display.write("Enter new key: ")
                local nk = read()
                if nk ~= "" then
                    ---@diagnostic disable-next-line: cast-local-type
                    nk = tonumber(nk) or nk
                    local ok = selected.key
                    selected.parent[ok] = nil
                    selected.parent[nk] = selected.value
                    tab.update()
                end
                ctrlHeld = false
            elseif selected and e[2] == keys.g then
                -- change value
                setColors(mainFg, mainBg)
                clearLine(h)
                display.write("Enter new value: ")
                local v = read()
                if v ~= "" then
                    if tonumber(v) then
                        selected.type = "number"
                        parent[selected.key] = tonumber(v)
                    elseif v == "true" or v == "false" then
                        selected.type = "boolean"
                        parent[selected.key] = v == "true"
                    else
                        local ok, result = pcall(textutils.unserialise, v)
                        if ok and type(result) == "table" then
                            selected.type = "table"
                            parent[selected.key] = result
                        else
                            selected.type = "string"
                            parent[selected.key] = v
                        end
                    end
                    tab.update()
                end
                ctrlHeld = false
            elseif e[2] == keys.n or e[2] == keys.r then
                -- new element
                if e[2] == keys.n and selected and selected.type == "table" then
                    parent = selected.value
                end
                parent[#parent + 1] = "new value"
                tab.update()
                ctrlHeld = false
            end
        elseif selected and e[2] == keys.delete then
            -- delete the selected element
            parent[selected.key] = nil
            tab.update()
        else
            tab.event(e)
        end
    elseif e[1] == "key_up" then
        if e[2] == keys.leftCtrl then
            ctrlHeld = false
        end
    else
        tab.event(e)
    end
    return ctrlHeld
end

local function editTable(splitDesc, setting)
    local mid = 5 + #splitDesc
    local win = window.create(display, 1, mid, w, h - mid)
    ---@type tableStructure
    local selected
    local tab = tableExplorer(win, setting.value, function(s)
        selected = s
    end)
    local ctrlHeld = false
    local fstring = "%-9s%s"
    while true do
        draw(function()
            setColors(mainFg, mainBg)
            local y = 2
            local revPath = {}
            local node = selected
            while node do
                revPath[#revPath + 1] = node.key
                node = node.parentStructure
            end
            local path = setting.location
            for i = #revPath, 1, -1 do
                if type(revPath[i]) == "number" then
                    path = path .. "[" .. revPath[i] .. "]"
                else
                    path = path .. "." .. revPath[i]
                end
            end
            setColors(headerFg, headerBg)
            clearLine(y)
            text(1, y, path)
            setColors(mainFg, mainBg)
            y = y + 1
            for _, v in ipairs(splitDesc) do
                text(1, y, v)
                y = y + 1
            end
            local hw = math.floor(w / 2)
            text(2, y, fstring:format("key ^k", selected and selected.key))
            y = y + 1
            local valStr = selected and selected.value
            if selected and selected.type == "table" then
                valStr = "{}"
            elseif not selected then
                valStr = "nil"
            end
            text(2, y, fstring:format("value ^g", valStr))
            y = y + 1
            text(1, h, "Cancel ^c")
            local nstring = "New ^n/^r"
            text(math.floor((w - #nstring) / 2), h, nstring)
            local dstring = "Done ^d"
            text(w - #dstring, h, dstring)
            tab.draw()
        end)
        local e = { os.pullEvent() }
        ctrlHeld = handleEditEvents(ctrlHeld, e, tab, selected, (selected and selected.parent) or setting.value)
        if ctrlHeld and e[1] == "key" then
            if e[2] == keys.d then
                -- done, apply changes
                lib.setConfigValue(setting.module, setting.setting, setting.value)
                return CONFIG()
            elseif e[2] == keys.c then
                -- cancel changes
                return CONFIG()
            end
        end
    end
end

function EDIT(setting)
    mode = "EDIT"
    local splitDesc = require("cc.strings").wrap("Description: " .. setting.description, w)
    if setting.type == "table" then
        return editTable(splitDesc, setting)
    end
    while true do
        local y = 2
        draw(function()
            setColors(headerFg, headerBg)
            text(1, y, setting.location)
            setColors(mainFg, mainBg)
            y = y + 1
            for _, v in ipairs(splitDesc) do
                text(1, y, v)
                y = y + 1
            end
            text(1, y, "Current value:")
            y = y + 1
            text(1, y, setting.value)
            y = y + 1
            text(1, y, "Type: " .. setting.type)
            y = y + 1
            text(1, y, "Enter a new value, empty to cancel.")
            y = y + 1
        end)
        display.setCursorPos(1, y)
        local i = read()
        if i == "" then
            return CONFIG()
        end
        if setting.type == "number" and tonumber(i) then
            lib.setConfigValue(setting.module, setting.setting, tonumber(i))
            return CONFIG()
        elseif setting.type == "string" then
            lib.setConfigValue(setting.module, setting.setting, i)
            return CONFIG()
        elseif setting.type == "boolean" and i == "true" or i == "false" then
            lib.setConfigValue(setting.module, setting.setting, i == "true")
            return CONFIG()
        end
    end
end

function CONFIG()
    mode = "CONFIG"
    local configOptions = lib.getConfig()
    local configList = {}
    local longestLocation = 0
    for module, moduleSettings in pairs(configOptions) do
        for setting, settingContent in pairs(moduleSettings) do
            local s = { module = module, setting = setting, location = ("%s.%s"):format(module, setting) }
            for k, v in pairs(settingContent) do
                s[k] = v
            end
            longestLocation = math.max(longestLocation, #s.location)
            configList[#configList + 1] = s
        end
    end

    local fstring = "%-" .. longestLocation .. "s %-10s %-20s"
    local drawer = function(filter, selected, sifted)
        drawSearch(filter, selected, sifted, fstring:format("Location", "Value", "Description"),
            function(item)
                return fstring:format(item.location, item.value, item.description)
            end)
    end

    local match = function(v, filter)
        return v.module:match(filter) or v.setting:match(filter) or v.location:match(filter)
    end

    local sort = function(a, b)
        return a.location < b.location
    end

    local onSelect = function(setting)
        return EDIT(setting)
    end

    return searchableMenu(drawer, function() return configList end, onSelect, nil, sort, match, SYSINFO)
end

function SYSINFO()
    mode = "SYSINFO"
    local timer = os.startTimer(1)
    while true do
        local usage = lib.getUsage()
        local status = lib.getCraftStatus()
        draw(function()
            setColors(headerFg, headerBg)
            clearLine(2)
            text(1, 2, "System Info")
            setColors(mainFg, mainBg)
            text(1, 3, ("%u Used / %u Total (%u Free)"):format(usage.used, usage.total, usage.free))
            text(1, 4, ("Crafting jobs active: %u"):format(status.jobs))
            text(1, 5, ("Crafting tasks active: %u"):format(status.tasks))
        end)
        local e = { os.pullEvent() }
        if e[1] == "mouse_click" then
            local nm = handleClicks(e[3], e[4])
            if nm then
                return nm()
            end
        elseif e[1] == "timer" and e[2] == timer then
            timer = os.startTimer(1)
        elseif e[1] == "key" and e[2] == keys.tab then
            return SEARCH()
        end
    end
end

modeLookup = { SEARCH = SEARCH, CRAFT = CRAFT, CONFIG = CONFIG, SYSINFO = SYSINFO }

local funcs = { lib.subscribe, SEARCH }

local watchdogAvaliable = fs.exists("watchdogLib.lua")
if watchdogAvaliable then
  local watchdogLib = require '.watchdogLib'
  local wdFunc = watchdogLib.watchdogLoopFromSettings()
  if wdFunc ~= nil then
      funcs[#funcs+1] = wdFunc
  end
end

if turtleMode then
    funcs[#funcs + 1] = debounceTurtleInventory
    funcs[#funcs + 1] = processTurtleInventory
else
    funcs[#funcs + 1] = inventoryPoll
end

parallel.waitForAny(table.unpack(funcs))
