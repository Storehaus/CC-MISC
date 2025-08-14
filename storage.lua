local common = require("common")
local printf = common.printf

---@type table array of module filenames to load
local moduleFilenames = {}

local function loadModuleList(filename)
  local f = assert(fs.open(filename, "r"))
  local line = f.readLine()
  while line do
    if line:sub(-4) == ".lua" then
      line = line:sub(1, -5)
    end
    line:gsub("/", ".")
    table.insert(moduleFilenames, line)
    line = f.readLine()
  end
end

local function loadModulesFolder(foldername)
  local list = fs.list(foldername)
  for _, fn in ipairs(list) do
    if not fs.isDir(fn) and fn:sub(-4) == ".lua" then
      local moduleFn = foldername .. "." .. fn:gsub("/", "."):sub(1, -5)
      table.insert(moduleFilenames, moduleFn)
    end
  end
end

local args = { ... }
if args[1] then
  if fs.isDir(args[1]) then
    loadModulesFolder(args[1])
  else
    loadModuleList(args[1])
  end
else
  print("No file/folder specified, loading from /modules/")
  loadModulesFolder("modules")
end

--- Load section

-- A module should return a table that contains at least the following fields
---@class module
---@field id string
---@field config table<string, configspec>?
---@field init fun(modules:table,config:table):table
---@field dependencies table<string,{min:string?,max:string?,optional:boolean?}>

---@class configspec
---@field default any
---@field type string

---@type table loaded config information
local config = {}


---@type module[] table of modules to sort to determine load order
local unorderedModules = {}

---@type table<string,module>
local loaded = {}
for _, v in ipairs(moduleFilenames) do
  ---@type module
  local mod = require(v)
  table.insert(unorderedModules, mod)
  loaded[mod.id] = mod
  config[mod.id] = mod.config
  printf("Loaded %s v%s", mod.id, mod.version)
end

-- Load order determination

local function protectedIndex(t, ...)
  local curIndex = t
  for k, v in pairs({ ... }) do
    curIndex = curIndex[v]
    if curIndex == nil then
      return nil
    end
  end
  return curIndex
end

---@type module[] table of sorted modules to sort to determine load order
local moduleInitOrder = {}

local function split(inputstr, sep)
  if sep == nil then
    sep = "%s"
  end
  local t = {}
  for str in string.gmatch(inputstr, "([^" .. sep .. "]+)") do
    table.insert(t, str)
  end
  return t
end


---Check if a given version is within the given range, if no max is given all MINOR versions are accepted
---@param ver string
---@param min string
---@param max string?
---@return boolean
---@nodiscard
local function checkSemVer(ver, min, max)
  local verSplit = split(ver, ".")
  local minSplit = split(min, ".")
  -- check min
  local verMajor = tonumber(verSplit[1])
  local verMinor = tonumber(verSplit[2])
  local minMajor = tonumber(minSplit[1])
  local minMinor = tonumber(minSplit[2])

  if verMajor < minMajor or (verMajor == minMajor and verMinor < minMinor) then
    return false
  end

  if max then
    local maxSplit = split(max, ".")
    local maxMajor = tonumber(maxSplit[1])
    local maxMinor = tonumber(maxSplit[2])
    if verMajor > maxMajor or (verMajor == maxMajor and verMinor > maxMinor) then
      return false
    end
  elseif verMajor > minMajor then
    return false
  end
  return true
end

-- https://en.wikipedia.org/wiki/Topological_sorting#Depth-first_search
---@param module module
local function visit(module)
  if module.permanant then
    return
  elseif module.temporary then
    error("Cyclic dependency tree")
  end
  module.temporary = true

  for id, info in pairs(module.dependencies or {}) do
    local depModule = loaded[id]
    if depModule then
      if not checkSemVer(depModule.version, info.min, info.max) then
        if info.max then
          error(("Module %s requires %s [v%s.*,v%s.*]. v%s loaded."):format(module.id, id, info.min, info.max,
            depModule.version))
        else
          error(("Module %s requires %s v%s.*. v%s loaded."):format(module.id, id, info.min, depModule.version))
        end
      end
      visit(depModule)
    elseif not info.optional then
      error(("Module %s requires %s, which is not present."):format(module.id, id))
    end
  end

  module.temporary = nil
  module.permanant = true
  table.insert(moduleInitOrder, module)
end

local function getUnmarked()
  for k, v in pairs(unorderedModules) do
    if not v.permanant then
      return v
    end
  end
  return nil
end

local unmarked = getUnmarked()
while unmarked do
  visit(unmarked)
  unmarked = getUnmarked()
end

for k, v in pairs(unorderedModules) do
  v.permanant = nil
end

--- Config validation section

local function getValue(type)
  while true do
    term.write("Please input a " .. type .. ": ")
    local input = io.read()
    if type == "table" then
      local val = textutils.unserialise(input)
      if val then
        return val
      end
    elseif type == "number" then
      local val = tonumber(input)
      if val then
        return val
      end
    elseif type == "string" then
      if input ~= "" then
        return input
      end
    else
      error(("Invalid type %s"):format(type))
    end
  end
end

local loadedConfig = common.loadTableFromFile("config.lua") or {}
for id, spec in pairs(config) do
  for name, info in pairs(spec) do
    local loadedValue = protectedIndex(loadedConfig, id, name, "value")
    if loadedValue == nil then
      loadedValue = config[id][name].default
    end
    config[id][name].value = loadedValue
    config[id][name].id = id
    config[id][name].name = name
    if type(config[id][name].value) ~= info.type then
      if loaded[id].setup then
        loaded[id].setup(config[id])
        assert(type(config[id][name].value) == info.type,
          ("Module %s setup failed to set %s"):format(id, name))
        -- if a module has a first time setup defined, call it
      else
        print(("Config option %s.%s is invalid"):format(id, name, info.type))
        print(config[id][name].description)
        config[id][name].value = getValue(config[id][name].type)
      end
    end
  end
end

-- Persist old settings
for k, v in pairs(loadedConfig) do
  config[k] = config[k] or v
end

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

local function saveConfig()
  common.saveTableToFile("config.txt", deepCloneNoFunc(config), false, true)
end
saveConfig()

---Attempt to the given setting to the given value
---@param setting table
---@param value any
---@return boolean success
config.set = function(setting, value)
  if type(value) == setting.type then
    setting.value = value
    saveConfig()
    return true
  end
  if setting.type == "number" and tonumber(value) then
    setting.value = tonumber(value)
    saveConfig()
    return true
  end
  if setting.type == "table" and value then
    local val = textutils.unserialise(value)
    if type(val) == "table" then
      setting.value = val
      saveConfig()
      return true
    end
  end
  return false
end

config.save = saveConfig

--- Initialization section

---@type thread[] array of functions to run all the modules
local moduleExecution = {}
---@type table<thread,string|nil>
local moduleFilters = {}
---@type string[]
local moduleIds = {}
for _, mod in ipairs(moduleInitOrder) do
  if mod.init then
    local t0 = os.clock()
    -- The table returned by init will be placed into [id].interface
    loaded[mod.id].interface = mod.init(loaded, config)
    if loaded[mod.id].interface.start then
      table.insert(moduleExecution, coroutine.create(loaded[mod.id].interface.start))
      table.insert(moduleIds, mod.id)
    end
    printf("Initialized %s in %.2f seconds", mod.id, os.clock() - t0)
  else
    printf("Failed to initialize %s, no init function", mod.id)
  end
end

--- Execution section

---Save a crash report
---@param module string module name that crashed
---@param stacktrace string module stacktrace
---@param error string
local function saveCrashReport(module, stacktrace, error)
  local f, reason = fs.open("crash.txt", "w")
  if not f then
    print("Unable to save crash report!")
    print(reason)
    return
  end
  f.write("===MISC Crash Report===\n")
  f.write(("Generated on %s\n"):format(os.date()))
  f.write(("There were %u modules loaded.\n"):format(#moduleFilenames))
  for _, v in ipairs(moduleInitOrder) do
    local icon = "-"
    if v.id == module then
      icon = "*"
    end
    f.write(("%s %s v%s\n"):format(icon, v.id, v.version))
  end
  f.write("--- ERROR\n")
  f.write(error)
  f.write("\n--- STACKTRACE\n")
  f.write(stacktrace)
  f.close()
end

print("Starting execution...")
while true do
  local timerId = os.startTimer(0)
  local e = table.pack(os.pullEventRaw())
  os.cancelTimer(timerId)
  if e[1] == "terminate" then
    print("Terminated.")
    return
  end
  for i, co in ipairs(moduleExecution) do
    if not moduleFilters[co] or moduleFilters[co] == "" or moduleFilters[co] == e[1] then
      local ok, filter = coroutine.resume(co, table.unpack(e, 1, e.n))
      if not ok then
        term.setTextColor(colors.red)
        print("Module errored:")
        print(filter)
        print("Saving crash report to 'crash.txt'...")
        saveCrashReport(moduleIds[i], debug.traceback(co), filter)
        return
      end
      moduleFilters[co] = filter
    end
  end
end
