local args = { ... }
local repositoryUrl = "https://raw.githubusercontent.com/Storehaus/CC-MISC/master/"

-- Check if first argument is a GitHub repository path (format: username/repo)
if args[2] == "internal_separate_repo_flag" then
    -- Internal flag detected - already on a separate repo, construct URL from first argument
    -- DO NOT load/installer again, just set the URL and continue normally
    local repoPath = args[1]
    repositoryUrl = "https://raw.githubusercontent.com/" .. repoPath .. "/master/"
    print("Running installer from repository: " .. repoPath)
elseif args[1] and args[1]:match("^[%w_-]+/[%w_-]+$") then
    local repoPath = args[1]
    print("Switching to repository: " .. repoPath)
    print("Executing installer from target repository...")
    
    -- Download and execute the installer from the target repository
    local newUrl = "https://raw.githubusercontent.com/" .. repoPath .. "/master/"
    local response = http.get(newUrl .. "installer.lua", nil, true)
    if response then
        local installerCode = response.readAll()
        response.close()
        
        -- Execute the installer from the target repository
        -- Add an internal flag to prevent infinite loops
        local newArgs = { repoPath, "internal_separate_repo_flag" }
        local chunk = load(installerCode, "installer", "t", _ENV)
        if chunk then
            chunk(unpack(newArgs))
        else
            print("Error: Failed to load installer from target repository")
            print("Falling back to default repository")
        end
    else
        print("Error: Could not fetch installer from " .. newUrl)
        print("Falling back to default repository")
    end
elseif args[1] == "dev" then
    repositoryUrl = "https://raw.githubusercontent.com/Storehaus/CC-MISC/dev/"
end

local function fromURL(url)
  return { url = url }
end

local function fromRepository(url)
  return fromURL(repositoryUrl .. url)
end

local craftInstall = {
  name = "Crafting Modules",
  files = {
    ["bfile.lua"] = fromRepository "bfile.lua",
    modules = {
      ["crafting.lua"] = fromRepository "modules/crafting.lua",
      ["furnace.lua"] = fromRepository "modules/furnace.lua",
      ["grid.lua"] = fromRepository "modules/grid.lua",
    },
    recipes = {
      ["grid_recipes.bin"] = fromRepository "recipes/grid_recipes.bin",
      ["item_lookup.bin"] = fromRepository "recipes/item_lookup.bin",
      ["furnace_recipes.bin"] = fromRepository "recipes/furnace_recipes.bin",
    }
  }
}

local logInstall = {
  name = "Logging Module",
  files = {
    modules = {
      ["logger.lua"] = fromRepository "modules/logger.lua"
    }
  }
}

local disposalInstall = {
  name = "Disposal Module",
  files = {
    modules = {
      ["disposal.lua"] = fromRepository "modules/disposal.lua"
    }
  }
}

local introspectionInstall = {
  name = "Introspection Module",
  files = {
    modules = {
      ["introspection.lua"] = fromRepository "modules/introspection.lua"
    }
  }
}

local chatboxInstall = {
  name = "Chatbox Module",
  files = {
    modules = {
      ["chatbox.lua"] = fromRepository "modules/chatbox.lua"
    }
  }
}

local baseInstall = {
  name = "Base MISC",
  files = {
    ["startup.lua"] = fromRepository "storage.lua",
    ["abstractInvLib.lua"] = fromURL "lib/abstractInvLib.lua", -- external library (update when upstream changes)
    ["common.lua"] = fromRepository "common.lua",
    modules = {
      ["inventory.lua"] = fromRepository "modules/inventory.lua",
      ["interface.lua"] = fromRepository "modules/interface.lua",
      ["modem.lua"] = fromRepository "modules/modem.lua",
    }
  }
}

local ioInstall = {
  name = "Generic I/O Module",
  files = {
    modules = {
      ["io.lua"] = fromRepository "modules/io.lua"
    }
  }
}

local watchdogInstall = {
  name = "Watch Dog Module",
  files = {
    ["watchdogLib.lua"] = fromRepository "shared/watchdogLib.lua",
    modules = {
      ["watchdog.lua"] = fromRepository "modules/watchdog.lua"
    }
  }
}

local serverInstallOptions = {
  name = "Server installation options",
  b = baseInstall,
  c = craftInstall,
  d = disposalInstall,
  i = introspectionInstall,
  l = logInstall,
  o = ioInstall,
  r = chatboxInstall,
  w = watchdogInstall
}

local terminalInstall = {
  name = "Access Terminal",
  files = {
    ["startup.lua"] = fromRepository "clients/terminal.lua",
    ["modemLib.lua"] = fromRepository "clients/modemLib.lua"
  }
}

local introspectionTermInstall = {
  name = "Access Terminal (Introspection)",
  files = {
    ["startup.lua"] = fromRepository "clients/terminal.lua",
    ["websocketLib.lua"] = fromRepository "clients/websocketLib.lua"
  }
}


local crafterInstall = {
  name = "Crafter Turtle",
  files = {
    ["startup.lua"] = fromRepository "clients/crafter.lua"
  }
}

local monitorInstall = {
  name = "Usage Monitor",
  files = {
    ["startup.lua"] = fromRepository "clients/usageMonitor.lua",
    ["modemLib.lua"] = fromRepository "clients/modemLib.lua"
  }
}

local introspectionMonInstall = {
  name = "Usage Monitor (Introspection)",
  files = {
    ["startup.lua"] = fromRepository "clients/usageMonitor.lua",
    ["websocketLib.lua"] = fromRepository "clients/websocketLib.lua"
  }
}

local clientWatchdogInstall = {
  name = "Watch Dog Module",
  files = {
    ["watchdogLib.lua"] = fromRepository "shared/watchdogLib.lua"
  }
}

local clientDisposalInstall = {
  name = "Disposal Module",
  files = {
    modules = {
      ["startup.lua"] = fromRepository "clients/disposal.lua"
    }
  }
}

local clientInstallOptions = {
  name = "Client installation options",
  t = terminalInstall,
  i = introspectionTermInstall,
  c = crafterInstall,
  d = clientDisposalInstall,
  m = monitorInstall,
  w = introspectionMonInstall,
  x = clientWatchdogInstall
}

local installOptions = {
  s = serverInstallOptions,
  c = clientInstallOptions
}

---Pass in a key, value table to have the user select a value from
---@generic T
---@param options table<string,T>
---@return T
local function getOption(options)
  while true do
    local _, ch = os.pullEvent("char")
    if options[ch] then
      return options[ch]
    end
  end
end

local function displayOptions(options)
  term.clear()
  term.setCursorPos(1, 1)
  term.setTextColor(colors.black)
  term.setBackgroundColor(colors.white)
  term.clearLine()
  print("MISC INSTALLER")
  term.setTextColor(colors.white)
  term.setBackgroundColor(colors.black)
  for k, v in pairs(options) do
    if k ~= "name" then
      print(string.format("[%s] %s", k, v.name))
    end
  end
end

local alwaysOverwrite = false

local function downloadFile(path, url)
  print(string.format("Installing %s to %s", url, path))
  local response = assert(http.get(url, nil, true), "Failed to get " .. url)
  local writeFile = true
  if fs.exists(path) and not alwaysOverwrite then
    term.write("%s already exists, overwrite? Y/n/always? ")
    local i = io.read():sub(1, 1)
    alwaysOverwrite = i == "a"
    writeFile = alwaysOverwrite or i ~= "n"
  end
  if writeFile then
    local f = assert(fs.open(path, "wb"), "Cannot open file " .. path)
    f.write(response.readAll())
    f.close()
  end
  response.close()
end

local function downloadFiles(folder, files)
  for k, v in pairs(files) do
    local path = fs.combine(folder, k)
    if v.url then
      downloadFile(path, v.url)
    else
      fs.makeDir(path)
      downloadFiles(path, v)
    end
  end
end

local function processOptions(options)
  displayOptions(options)
  local selection = getOption(options)
  if selection.files then
    downloadFiles("", selection.files)
  else
    processOptions(selection)
  end
end

processOptions(installOptions)