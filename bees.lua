-- Stable launcher installed as /usr/bin/bees.lua.
local args={...}
local root="/home/.openbeekeeper/"
local management={update=true,reinstall=true,repair=true,check=true,rollback=true}
local target=management[args[1]] and "install.lua" or "openbeekeeper.lua"
local chunk,err=loadfile(root..target)
if not chunk then
  io.stderr:write("OpenBeekeeper is missing or damaged: "..tostring(err).."\n")
  io.stderr:write("Run: lua /home/beekeeper-setup.lua reinstall\n")
  return false
end
return chunk(table.unpack(args))
