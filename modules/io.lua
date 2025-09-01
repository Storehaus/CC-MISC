---@class modules.io
---@field interface modules.io.interface
return {
  id = "io",
  version = "1.0.0",
  config = {
    import = {
      ---@type {inventory:string,slots:integer[]|{min:integer,max:integer}?,whitelist:string[]?,blacklist:string[],min:integer?}[]
      default = {},
      type = "table",
      description = "List of import rules of the format. See docs for info."
    },
    export = {
      ---@type {inventory:string, name:string, nbt:string?, min:integer?, slots:integer[]|{min:integer,max:integer}?}[]
      default = {},
      type = "table",
      description = "List of export rules of the format. See docs for info."
    },
    delay = {
      default = 5,
      type = "number",
      description = "Interval to perform i/o."
    }
  },
  ---@param loaded {inventory: modules.inventory}
  init = function(loaded, config)
    local function dumbImport(periph, slots, rule)
      if not periph.list then
        for _, slot in ipairs(slots) do
          loaded.inventory.interface.pullItems(true, rule.inventory, slot)
        end
      else
        local list = periph.list()
        for _, slot in ipairs(slots) do
          if list[slot] then
            loaded.inventory.interface.pullItems(true, rule.inventory, slot)
          end
        end
      end
    end
    local function smartImport(periph, slots, rule)
      local wllut
      if rule.whitelist then
        wllut = {}
        for _, v in pairs(rule.whitelist) do
          wllut[v] = true
        end
      end
      local bllut = {}
      for _, v in pairs(rule.blacklist or {}) do
        bllut[v] = true
      end
      local list = periph.list()
      local remaining = rule.min and loaded.inventory.interface.getUsage().free - rule.min
      for _, slot in ipairs(slots) do
        if remaining and remaining < 1 then
          return
        end
        if list[slot] then
          local moved
          local name = list[slot].name
          if wllut and wllut[name] then
            loaded.inventory.interface.pullItems(true, rule.inventory, slot)
            moved = true
          elseif not (wllut or bllut[name]) then
            loaded.inventory.interface.pullItems(true, rule.inventory, slot)
            moved = true
          end
          if remaining and moved then
            remaining = remaining - 1
          end
        end
      end
    end
    local function processImport(rule)
      local slots = rule.slots
      local min, max = slots and slots.min, slots and slots.max
      local periph = peripheral.wrap(rule.inventory) --[[@as Inventory|table]]
      if not slots then
        min, max = 1, periph.size()
      end
      if min and max then
        slots = {}
        for i = min, max do
          slots[#slots + 1] = i
        end
      end
      if not (rule.whitelist or rule.blacklist or rule.min) then
        -- nice and simple
        dumbImport(periph, slots, rule)
        return
      end
      smartImport(periph, slots, rule)
    end

    local function processImports()
      for _, rule in pairs(config.io.import.value) do
        processImport(rule)
      end
    end

    local function processExport(rule)
      local slots = rule.slots
      local min, max = slots and slots.min, slots and slots.max
      local periph = peripheral.wrap(rule.inventory) --[[@as Inventory|table]]
      if not slots then
        min, max = 1, periph.size()
      end
      if min and max then
        slots = {}
        for i = min, max do
          slots[#slots + 1] = i
        end
      end

      local remaining = rule.min and loaded.inventory.interface.getCount(rule.name, rule.nbt) - rule.min
      for _, slot in ipairs(slots) do
        if remaining then
          if remaining < 1 then
            return
          end
          local moved = loaded.inventory.interface.pushItems(false, rule.inventory, rule.name, remaining, slot, rule.nbt)
          remaining = remaining - moved
        else
          loaded.inventory.interface.pushItems(true, rule.inventory, rule.name, nil, slot, rule.nbt)
        end
      end
    end

    local function processExports()
      for _, rule in pairs(config.io.export.value) do
        processExport(rule)
      end
    end
    ---@class modules.io.interface
    return {
      start = function()
        while true do
          sleep(config.io.delay.value)
          processImports()
          processExports()
        end
      end
    }
  end
}
