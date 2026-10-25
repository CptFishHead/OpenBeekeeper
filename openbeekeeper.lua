-- OpenBeekeeper: read-only OpenComputers inventory diagnostics.
-- Run from OpenOS: lua openbeekeeper.lua [transposer-address-prefix]
local component = require("component")
local args = {...}

local candidates = {}
for address in component.list("transposer", true) do
  if not args[1] or address:sub(1, #args[1]) == args[1] then
    candidates[#candidates + 1] = address
  end
end
table.sort(candidates)
if #candidates ~= 1 then
  io.stderr:write("Expected one transposer; found " .. #candidates .. ".\n")
  io.stderr:write("Use: lua openbeekeeper.lua <unique-address-prefix>\n")
  return
end

local t = component.proxy(candidates[1])
local sides = {[0] = "down", "up", "north", "south", "west", "east"}
local expected = {
  [2] = "gendustry:industrial_apiary",
  [3] = "forestry:bee_chest",
  [4] = "gendustry:mutatron"
}

-- Keep multiple return values: failures often return nil plus a reason.
local function read(method, ...)
  local ok, value, reason = pcall(method, ...)
  if not ok then return nil, tostring(value) end
  return value, reason
end

local function describe(stack)
  local name = tostring(stack.name or "unknown")
  local label = tostring(stack.label or name)
  local individual = stack.individual
  local kind = "item"
  if name:find("bee_princess", 1, true) then kind = "princess"
  elseif name:find("bee_drone", 1, true) then kind = "drone"
  elseif name:find("bee_queen", 1, true) then kind = "queen" end
  local extra = ""
  if type(individual) == "table" then
    extra = " | species=" .. tostring(individual.ident or "unknown")
      .. " | analyzed=" .. tostring(individual.isAnalyzed)
  elseif kind ~= "item" then
    extra = " | species ID unavailable through this transposer"
  end
  return label .. " | " .. name .. " | " .. kind .. extra
end

print("OpenBeekeeper - read-only scan")
print("Transposer: " .. t.address)
for side = 0, 5 do
  local size, reason = read(t.getInventorySize, side)
  if type(size) ~= "number" then
    print(string.format("SIDE %d (%s): %s", side, sides[side],
      tostring(reason or "no inventory")))
  else
    local name, nameReason = read(t.getInventoryName, side)
    print(string.format("SIDE %d (%s): %s [%d slots]", side, sides[side],
      tostring(name or nameReason or "unknown"), size))
    if expected[side] and name ~= expected[side] then
      print("  CHECK layout: expected " .. expected[side])
    end
    for slot = 1, size do
      local stack, stackReason = read(t.getStackInSlot, side, slot)
      if type(stack) == "table" and (tonumber(stack.size) or 0) > 0
          and stack.name ~= "minecraft:air" and stack.name ~= "air" then
        print(string.format("  %d x%d %s", slot, stack.size, describe(stack)))
      elseif stackReason then
        print("  Slot " .. slot .. ": " .. tostring(stackReason))
      end
    end
  end
end
print("Scan complete. No items moved.")
