---@class modules.monitor
---@field interface modules.chatbox.interface
local PixelUI = require("pixelui")
local pretty = require('cc.pretty');

local Rectangle = setmetatable({}, { __index = PixelUI.Widget })
Rectangle.__index = Rectangle

local nativeTerminal = nil
function ps(a)
  return pretty.render(pretty.pretty(a))
end

function pprint(...)
  if nativeTerminal ~= nil then
    local z = term.redirect(nativeTerminal)
    print(...)
    term.redirect(z)
  else
    print(z)
  end
end

function Rectangle:new(props)
  return PixelUI.Widget.new(self, props)
end

function Rectangle:render()
  if not self.visible then return end

  local absX, absY = self:getAbsolutePos()
  local w, h = self.width, self.height

  term.setBackgroundColor(colors.red)

  term.setCursorPos(absX, absY)
  term.write(string.rep(" ", w))

  for y = absY + 1, absY + h - 1 do
    term.setCursorPos(absX, y)
    term.write(" ")
  end

  term.setCursorPos(absX, absY + h)
  term.write(string.rep(" ", w))

  for y = absY + 1, absY + h - 1 do
    term.setCursorPos(absX + w - 1, y)
    term.write(" ")
  end

  term.setBackgroundColor(colors.black)
end

PixelUI.registerPlugin({
  id = "rectangle_plugin",
  widgets = {
    rectangle = Rectangle
  }
})

PixelUI.loadPlugin("rectangle_plugin")

return {
  id = "monitor",
  version = "1.0.0",
  config = {

  },
  dependencies = {

  },

  init = function(loaded)
    local monitor = peripheral.find("monitor");

    monitor.setTextScale(0.5)
    local w, h = monitor.getSize()

    function pixUI()
      PixelUI.rectangle({
        x = 1,
        y = 1,
        width = w,
        height = h - 1,
      })

      PixelUI.label({
        x = 3,
        y = 3,
        text = "MISC Monitor"
      })

      local top = {}
      local freeUsageBar;
      local usedUsageBar;
      local slotsInfo;

      PixelUI.spawnThread(function() -- updates the top every 25s
        while true do
          local amounts = loaded.inventory.interface.listItemAmounts();
          local sorted = {}
          for k, v in pairs(amounts) do
            table.insert(sorted, { key = k, value = v })
          end
          table.sort(sorted, function(a, b)
            return a.value > b.value
          end)
          for i, x in ipairs(sorted) do
            if i > h - 7 then
              break
            end
            setmetatable(x, {
              __tostring = function()
                return x.value .. " " .. x.key:gsub("^[^:]*:", "")
              end
            })
            top[i] = x
          end


          local zzz = loaded.inventory.interface.getUsage()

          if freeUsageBar and usedUsageBar and slotsInfo then
            freeUsageBar.value = (zzz.free / zzz.total) * 100
            usedUsageBar.value = (zzz.used / zzz.total) * 100
            slotsInfo.text = "Free: " .. zzz.free .. ", used: " .. zzz.used .. ", total: " .. zzz.total
            --slotsInfo.text = "test"
          end
          PixelUI.sleep(2) -- Yield control back to UI
        end
      end, "updateTopItems")

      local crafting = loaded.crafting.interface.recipeInterface
      crafting.addReadyHandler("ITEM", function(node)
        pprint(ps(node))
      end)
      local c = PixelUI.container({
        x = 3,
        y = 4,
        width = w / 2.5,
        height = h - 5,
        border = true,
        isScrollable = false
      })

      c:addChild(
        PixelUI.listView({
          x = 2,
          y = 2,
          width = c.width - 2,
          height = c.height - 2,
          items = top,
          onSelect = function(self, idx, item)
            --pprint(top[item].key, math.min(top[item].value,64))
          end
        })
      )
      local c_2 = PixelUI.container({
        x = c.width + 4,
        y = 4,
        width = w - c.width - 5,
        height = math.min((h / 2) - 5, 9),
        border = true,
        isScrollable = false
      })

      c_2:addChild(
        PixelUI.label({
          x = 2,
          y = 2,
          text = "Used"
        })
      )
      usedUsageBar = PixelUI.progressBar({
        x = 2,
        y = 3,
        width = c_2.width - 1,
        value = 0,
      })

      c_2:addChild(
        usedUsageBar
      )
      c_2:addChild(
        PixelUI.label({
          x = 2,
          y = 5,
          text = "Free"
        })
      )
      freeUsageBar = PixelUI.progressBar({
        x = 2,
        y = 6,
        width = c_2.width - 1,
        value = 0,
      });

      c_2:addChild(freeUsageBar)
      slotsInfo = PixelUI.label({
        x = 2,
        y = 8,
        width = c_2.width - 1,
        text = "Free: 12049, used: 91029125, total: 102959125",
        align = "center"
      })
      c_2:addChild(slotsInfo)

      local data = { { x = 1, y = 10 }, { x = 2, y = 25 }, { x = 3, y = 15 }, { x = 4, y = 30 } }
      PixelUI.chart({
        x = c_2.x,
        y = c_2.y + c_2.height + 1,
        width = c_2.width,
        height = h - c_2.height - 6,
        data = data,
        chartType = "line",
        title = "Sample Chart",
        xLabel = "Time",
        yLabel = "Value"
      })
    end

    ---@class modules.chatbox.interface
    return {
      start = function()
        nativeTerminal = term.redirect(monitor)
        local m, b = term.getSize();

        PixelUI.init()
        pixUI()
        PixelUI.run({
          animationInterval = 0.5
        })
        term.redirect(o)
      end
    }
  end
}
