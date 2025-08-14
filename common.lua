local function saveTableToFile(file, table, compact, repetitions)
  if type(compact) == "nil" then compact = true end
  local f = fs.open(file, "w")
  if not f then
    return false
  end
  f.write(textutils.serialise(table, { compact = compact, allow_repetitions = repetitions }))
  f.close()
  return true
end

local function loadTableFromFile(file)
  local f = fs.open(file, "r")
  if not f then
    print("no file :(", file)
    return nil
  end
  local t = textutils.unserialise(f.readAll() --[[@as string]])
  f.close()
  return t --[[@as table]]
end

local function printf(s, ...)
  print(s:format(...))
end

local function f(s)
  local env = setmetatable({}, { __index = _ENV })
  local f = (debug.getinfo(2, "f") or {}).func
  if f then
    for i = 1, math.huge do
      local k, v = debug.getupvalue(f, i)
      if not k then break end
      env[k] = v
    end
  end
  for i = 1, math.huge do
    local k, v = debug.getlocal(2, i)
    if not k then break end
    env[k] = v
  end
  return s:gsub("%$%b{}",
    function(c) return table.concat({ assert(load("return " .. c:sub(3, -2), "=codestr", "t", env))() }, " ") end)
end

-- Probably an abomination. I don't remember much about what it does.
local function layout(t, startX, startY, fullWidth, fullHeight, itemHeight)
  local w, h = 1, 1
  itemHeight = itemHeight or 3
  itemHeight = "(" .. itemHeight .. ")"
  local lineHeight = "(" .. itemHeight .. "+1)"
  startX, startY = startX or 2, startY or 2
  startX, startY = "(" .. startX .. ")", "(" .. startY .. ")"
  fullWidth, fullHeight = fullWidth or "(parent.w-2)", fullHeight or "(parent.h-2)"
  fullWidth, fullHeight = "(" .. fullWidth .. ")", "(" .. fullHeight .. ")"
  -- initial pass to get the width and height of the 2D array
  for k, v in pairs(t) do
    h = math.max(k, h)
    for k2, v2 in pairs(v) do
      w = math.max(k2, w)
    end
  end
  -- second pass to do width/height processing on each element
  local layoutInfo = {}
  for y = 1, h do
    layoutInfo[y] = {}
    for x = 1, w do
      local item = t[y][x]
      layoutInfo[y][x] = {
        w = 1,
        h = 1,
        x = x,
        y = y,
        processed = false
      } -- cell width/height
      if item == "up" then
        assert(y ~= 1, "Attempt to expand element above first row")
        layoutInfo[y][x] = layoutInfo[y - 1][x]
        -- TODO change this so that the height is set to the distance between the two
        layoutInfo[y][x].h = y - layoutInfo[y][x].y + 1
      elseif item == "left" then
        assert(x ~= 1, "Attempt to expand element to left of first column")
        layoutInfo[y][x] = layoutInfo[y][x - 1]
        layoutInfo[y][x].w = x - layoutInfo[y][x].x + 1
      elseif type(item) == "table" then
        -- this is an element
      elseif type(item) == "nil" then
        layoutInfo[y][x].processed = true
      else
        error("Invalid entry at " .. x .. "," .. y)
      end
    end
  end

  local calw, calh = "(" .. fullWidth .. "/" .. w .. ")", itemHeight
  for y = 1, h do
    for x = 1, w do
      if not layoutInfo[y][x].processed then
        local item = layoutInfo[y][x]
        item.processed = true
        -- set position and size of element, based on the calculated values
        local dw, dh = calw .. "*" .. item.w .. "-1-.2", calh .. "+" .. item.h - 1 .. "*" .. lineHeight
        t[y][x]:setSize(dw, dh)
        local dx, dy = calw .. "*" .. (x - 1) .. "+0.2+" .. startX, lineHeight .. "*" .. (y - 1) .. "+" .. startY
        t[y][x]:setPosition(dx, dy)
        print(dw, dh)
        print(dx, dy)
      end
    end
  end
end

---@alias handle table file handle
---@param f handle
---@param i integer
local function writeUInt16(f, i)
  f.write(string.pack(">I2", i))
end
---@param f handle
---@param i integer
local function writeUInt8(f, i)
  f.write(string.pack("I1", i))
end
---@param f handle
---@param str string
local function writeString(f, str)
  writeUInt16(f, str:len())
  f.write(str)
end

---@param f handle
---@param t table
local function writeUInt16T(f, t)
  writeUInt8(f, #t)
  for k, v in ipairs(t) do
    writeUInt16(f, v)
  end
end

---@param f handle
---@return integer
local function readUInt16(f)
  return select(1, string.unpack(">I2", f.read(2)))
end
---@param f handle
---@return integer
local function readUInt8(f)
  return select(1, string.unpack("I1", f.read(1)))
end
---@param f handle
---@return string
local function readString(f)
  local length = string.unpack(">I2", f.read(2))
  local str = f.read(length)
  return str
end

local function readUInt16T(f)
  local length = readUInt8(f)
  local t = {}
  for i = 1, length do
    t[i] = readUInt16(f)
  end
  return t
end

local function checkType(value, targetType)
  assert(type(targetType) == "string", "Type is not a string")
  if targetType:sub(-2) == "[]" then
    -- this is an array type
    if type(value) ~= "table" then
      return false
    end
    for i, val in pairs(value) do
      if not checkType(val, targetType:sub(1, -3)) then
        return false
      end
    end
    return true
  elseif targetType == "integer" then
    return type(value) == "number" and math.ceil(value) == math.floor(value)
  end
  return type(value) == targetType
end

---Assert that the given argument is of an accepted type
---@param value any
---@param argPos integer
---@param ... string types, supports array-likes with [], and integer types
local function enforceType(value, argPos, ...)
  for _, targetType in ipairs({ ... }) do
    if checkType(value, targetType) then
      return
    end
  end
  error(
  ("Argument #%u invalid, expected %s, got %s"):format(argPos, textutils.serialise({ ... }, { compact = true }),
    type(value)), 2)
end

return {
  saveTableToFile = saveTableToFile,
  loadTableFromFile = loadTableFromFile,
  printf = printf,
  f = f,
  layout = layout,
  readString = readString,
  readUInt16 = readUInt16,
  readUInt16T = readUInt16T,
  readUInt8 = readUInt8,
  writeString = writeString,
  writeUInt16 = writeUInt16,
  writeUInt16T = writeUInt16T,
  writeUInt8 = writeUInt8,
  enforceType = enforceType
}
