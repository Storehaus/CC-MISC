local common = require "common"
---@class modules.interface
---@field interface modules.interface.interface
return {
  id = "interface",
  version = "2.0.0",
  dependencies = {
    inventory = { min = "2.0" },
    crafting = { optional = true, min = "2.0" },
  },
  ---@param loaded {inventory: modules.inventory, crafting: modules.crafting|nil, grid: modules.grid|nil}
  init = function(loaded, config)
    loaded = loaded
    ---@class genericinterface
    local genericInterface = {}
    ---Push items to an inventory
    ---@param targetInventory string
    ---@param name string|number
    ---@param amount nil|number
    ---@param toSlot nil|number
    ---@param nbt nil|string
    ---@param options nil|TransferOptions
    ---@return integer|string count
    function genericInterface.pushItems(targetInventory, name, amount, toSlot, nbt, options)
      return loaded.inventory.interface.pushItems(targetInventory, name, amount, toSlot, nbt, options)
    end

    ---Pull items from an inventory
    ---@param fromInventory string|AbstractInventory
    ---@param fromSlot string|number
    ---@param amount nil|number
    ---@param toSlot nil|number
    ---@param nbt nil|string
    ---@param options nil|TransferOptions
    ---@return integer|string count
    function genericInterface.pullItems(fromInventory, fromSlot, amount, toSlot, nbt, options)
      return loaded.inventory.interface.pullItems(fromInventory, fromSlot, amount, toSlot, nbt, options)
    end

    function genericInterface.queuePull(fromInventory, fromSlot, amount, toSlot, nbt, options)
      return loaded.inventory.interface.queuePull(fromInventory, fromSlot, amount, toSlot, nbt, options)
    end

    function genericInterface.queuePush(targetInventory, name, amount, toSlot, nbt, options)
      return loaded.inventory.interface.queuePush(targetInventory, name, amount, toSlot, nbt, options)
    end

    function genericInterface.performTransfer()
      return loaded.inventory.interface.performTransfer()
    end

    ---List the items in this storage
    ---@return {name:string, nbt:string, count:integer}
    function genericInterface.list()
      local list = {}
      local names = loaded.inventory.interface.listNames()
      for _, name in pairs(names) do
        local nbts = loaded.inventory.interface.listNBT(name)
        for _, nbt in pairs(nbts) do
          local item = loaded.inventory.interface.getItem(name, nbt)
          if item then
            local itemClone = {}
            for k, v in pairs(item.item) do
              itemClone[k] = v
            end
            itemClone.name = name
            itemClone.nbt = nbt
            itemClone.count = loaded.inventory.interface.getCount(name, nbt)
            table.insert(list, itemClone)
          end
        end
      end
      return list
    end

    ---List the craftable items in the inventory
    ---@return string[]
    function genericInterface.listCraftables()
      if not loaded.crafting then
        return {}
      end
      return loaded.crafting.interface.listCraftables()
    end

    ---Request a craft
    ---@param name string
    ---@param count integer
    ---@return table
    function genericInterface.requestCraft(name, count)
      common.enforceType(name, 1, "string")
      common.enforceType(count, 2, "integer")
      if not loaded.crafting then
        return {} -- TODO define better behavior for when a module is not loaded
      end
      return loaded.crafting.interface.requestCraft(name, count)
    end

    ---Start a craft job
    ---@param jobID string
    ---@return boolean
    function genericInterface.startCraft(jobID)
      common.enforceType(jobID, 1, "string")
      if not loaded.crafting then
        return false
      end
      return loaded.crafting.interface.startCraft(jobID)
    end

    ---Cancel a craft job
    ---@param jobID string
    function genericInterface.cancelCraft(jobID)
      common.enforceType(jobID, 1, "string")
      if not loaded.crafting then
        return
      end
      return loaded.crafting.interface.cancelCraft(jobID)
    end

    ---Add a grid recipe manually
    ---@param name string
    ---@param produces integer
    ---@param recipe string[] table of ITEM NAMES, this does NOT support tags
    ---@param shaped boolean
    function genericInterface.addGridRecipe(name, produces, recipe, shaped)
      common.enforceType(name, 1, "string")
      common.enforceType(produces, 2, "integer")
      common.enforceType(recipe, 3, "string[]")
      common.enforceType(shaped, 4, "boolean")
      if not loaded.grid then
        return false
      end
      return loaded.grid.interface.addGridRecipe(name, produces, recipe, shaped)
    end

    ---Remove a grid recipe
    ---@param name string
    ---@return boolean
    function genericInterface.removeGridRecipe(name)
      common.enforceType(name, 1, "string")
      if not loaded.grid then
        return false
      end
      return loaded.grid.interface.removeGridRecipe(name)
    end

    ---List all active crafting jobIds
    ---@return string[]
    function genericInterface.listCraftJobs()
      if not loaded.crafting then
        return {}
      end
      return loaded.crafting.interface.listJobs()
    end

    ---Get the status of crafting
    ---@return {jobs: integer, tasks: integer}
    function genericInterface.getCraftStatus()
      if not loaded.crafting then
        return { jobs = 0, tasks = 0 }
      end
      local jobs = loaded.crafting.interface.listJobs()
      local tasks = 0
      for k, v in pairs(jobs) do
        tasks = tasks + #loaded.crafting.interface.listTasks(v)
      end
      return { jobs = #jobs, tasks = tasks }
    end

    ---Get the slot usage of this inventory
    ---@return {free: integer, used:integer, total:integer}
    function genericInterface.getUsage()
      return loaded.inventory.interface.getUsage()
    end

    local loadedModules = {}
    for k, v in pairs(loaded) do
      loadedModules[k] = v.version
    end

    ---Get a list of loaded modules and their versions
    ---@return table<string,string> modules name -> version
    function genericInterface.getModules()
      return loadedModules
    end

    ---Get the current config environment
    ---@return table
    function genericInterface.getConfig()
      return config
    end

    ---Set a config value
    ---@param module string
    ---@param setting string
    ---@param value any
    ---@return boolean
    function genericInterface.setConfigValue(module, setting, value)
      return config.set(config[module][setting], value)
    end

    local interface = {}
    local inventoryUpdateHandlers = {}
    local craftJobDoneHandlers = {}
    ---Add a handler for the inventoryUpdate event
    ---@param handler fun(list: table)
    function interface.addInventoryUpdateHandler(handler)
      common.enforceType(handler, 1, "function")
      table.insert(inventoryUpdateHandlers, handler)
    end

    ---Add a handler for the craft_job_done event
    ---@param handler fun(list: string)
    function interface.addCraftJobDoneHandler(handler)
      common.enforceType(handler, 1, "function")
      table.insert(craftJobDoneHandlers, handler)
    end

    ---Poll for inventoryUpdate events, and distribute to all inventoryUpdateHandlers
    local function inventoryUpdateHandler()
      while true do
        local e = { os.pullEvent() }
        if e[1] == "inventoryUpdate" then
          local list = genericInterface.list()
          for _, f in pairs(inventoryUpdateHandlers) do
            f(list)
          end
        elseif e[1] == "craft_job_done" then
          for _, f in pairs(craftJobDoneHandlers) do
            f(e[2])
          end
        end
      end
    end
    ---Call a genericInterface method by name
    ---@param method string
    ---@param args table
    ---@return ...
    function interface.callMethod(method, args)
      common.enforceType(method, 1, "string")
      local desiredMethod = genericInterface[method]
      assert(desiredMethod, method .. " is not a valid method")
      return desiredMethod(table.unpack(args, 1, args.n))
    end

    function interface.start()
      inventoryUpdateHandler()
    end

    ---@class modules.interface.interface
    return interface
  end
}
