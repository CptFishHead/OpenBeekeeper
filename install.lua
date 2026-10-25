-- OpenBeekeeper installer/manager. OpenOS, Lua 5.2. No optional data card required.
local fs=require("filesystem")
local component=require("component")
local shell=require("shell")
local computer=require("computer")
local args={...}
local action=args[1] or "install"
local base="https://raw.githubusercontent.com/CptFishHead/OpenBeekeeper/"
local root="/home/.openbeekeeper"
local work="/home/.openbeekeeper-install"
local backups="/home/openbeekeeper-backup"
local data="/home/.openbeekeeper-data"
local keys={"openbeekeeper.lua","install.lua","bees.lua","VERSION","README.md","package.manifest"}
local allowed={}
for _,k in ipairs(keys) do allowed[k]=true end

local function target(key)
  assert(allowed[key],"Unknown managed file")
  if key=="bees.lua" then return "/usr/bin/bees.lua" end
  return root.."/"..key
end
local function read(path)
  local file,err=io.open(path,"rb")
  if not file then return nil,err end
  local content=file:read("*a")
  file:close()
  return content
end
local function write(path,content)
  local file=assert(io.open(path,"wb"))
  assert(file:write(content))
  assert(file:flush())
  local ok,err=file:close()
  assert(ok~=false and not err,err or "Close failed")
end
local function directory(path)
  if not fs.exists(path) then assert(fs.makeDirectory(path)) end
end
local function remove(path)
  if fs.exists(path) then assert(fs.remove(path),"Cannot remove "..path) end
end
local function pointer(path,content)
  -- Never expose a partially written recovery pointer after a disk error.
  local temporary=path..".new"
  write(temporary,content)
  assert(read(temporary)==content,"Pointer verification failed")
  remove(path)
  assert(fs.rename(temporary,path),"Cannot publish pointer: "..path)
end
local function checksum(content)
  local a,b=1,0
  for i=1,#content do a=(a+content:byte(i))%65521; b=(b+a)%65521 end
  return string.format("%08x",b*65536+a)
end
local function verify(path,entry)
  local content,err=read(path)
  assert(content,"Missing file: "..path..": "..tostring(err))
  assert(#content==entry.size and checksum(content)==entry.sum,"Checksum mismatch: "..path)
  if entry.key:match("%.lua$") then assert(loadfile(path)) end
end
local function parse(content)
  assert(type(content)=="string" and #content<16384,"Missing/oversized manifest")
  local result={files={}}
  local seen={}
  for line in (content.."\n"):gmatch("([^\n]*)\n") do
    line=line:gsub("\r$","")
    if line=="OpenBeekeeper-package-1" then
      assert(not result.header,"Duplicate header"); result.header=true
    elseif line:match("^revision ") then
      assert(not result.revision,"Duplicate revision")
      result.revision=line:match("^revision (%x+)$")
      assert(result.revision and #result.revision==40,"Invalid revision")
    elseif line:match("^version ") then
      assert(not result.version,"Duplicate version")
      result.version=line:match("^version ([%w%.%-]+)$")
      assert(result.version,"Invalid version")
    elseif line:match("^file ") then
      local key,size,sum=line:match("^file ([%w%.%-]+) (%d+) (%x+)$")
      assert(key and allowed[key] and key~="package.manifest" and not seen[key],"Invalid/duplicate file")
      size=tonumber(size)
      assert(size>0 and size<=1048576 and #sum==8,"Invalid file metadata")
      seen[key]=true
      result.files[#result.files+1]={key=key,size=size,sum=sum:lower()}
    else assert(line=="","Invalid manifest line") end
  end
  assert(result.header and result.revision and result.version,"Incomplete manifest")
  for _,key in ipairs(keys) do assert(key=="package.manifest" or seen[key],"Missing manifest entry: "..key) end
  return result
end
local function unique(parent,prefix)
  directory(parent)
  local p=parent.."/"..prefix..tostring(math.floor(computer.uptime()*1000))
  while fs.exists(p) do p=p.."-new" end
  directory(p)
  return p
end
local function backupPath(path)
  assert(type(path)=="string" and path:match("^/home/openbeekeeper%-backup/backup%-%d+[%-new]*$"),"Invalid backup path")
  return path
end
local function restore(path)
  path=backupPath(path)
  local journal=assert(read(path.."/restore.list"),"Backup journal missing")
  local entries,seen={},{}
  for line in journal:gmatch("[^\n]+") do
    local key,existed,size,sum=line:match("^([%w%.%-]+) ([01]) (%d+) (%x+)$")
    assert(key and allowed[key] and not seen[key],"Invalid backup journal")
    seen[key]=true
    local e={key=key,existed=existed=="1",size=tonumber(size),sum=sum}
    if e.existed then
      local old=assert(read(path.."/"..key),"Backup missing: "..key)
      assert(#old==e.size and checksum(old)==sum,"Backup damaged: "..key)
    end
    entries[#entries+1]=e
  end
  for _,key in ipairs(keys) do assert(seen[key],"Incomplete backup") end
  -- Validate every backup before changing any installed file.
  for _,e in ipairs(entries) do
    local dest=target(e.key)
    if e.existed then
      directory(fs.path(dest))
      write(dest,assert(read(path.."/"..e.key)))
      local restored=assert(read(dest))
      assert(#restored==e.size and checksum(restored)==e.sum,"Restore verification failed")
    else remove(dest) end
  end
end
local function recover()
  local pending=read(work.."/pending")
  if pending then
    print("Recovering interrupted installation...")
    restore(pending)
    remove(work.."/pending")
    print("Previous files restored.")
  end
end
local function check()
  assert(not fs.exists(work.."/pending"),"Interrupted installation. Run setup reinstall to recover.")
  local manifest=parse(assert(read(target("package.manifest")),"Not installed. Run setup first."))
  local failures=0
  print("OpenBeekeeper "..manifest.version.." / "..manifest.revision:sub(1,8))
  for _,e in ipairs(manifest.files) do
    local ok,err=pcall(verify,target(e.key),e)
    print((ok and "OK   " or "FAIL ")..e.key)
    if not ok then failures=failures+1; print(tostring(err)) end
  end
  local version=read(target("VERSION"))
  if not version or version:gsub("%s+$","")~=manifest.version then
    failures=failures+1; print("FAIL Version metadata")
  end
  print("Internet card: "..tostring(component.isAvailable("internet")))
  assert(failures==0,tostring(failures).." file(s) failed. Run bees reinstall.")
  print("Installation verified. Machine layout/ME access needs a separate bees scan.")
  return true
end
local function download(url,path)
  assert(shell.execute("wget -fq "..url.." "..path),"Download failed: "..url)
  assert(fs.exists(path) and fs.size(path)>0,"Download missing/empty: "..path)
end
local function install()
  recover()
  assert(component.isAvailable("internet"),"Internet card required")
  directory(root); directory(data)
  local stage=unique(work,"stage-")
  print("Downloading release manifest...")
  -- Branch URLs can be cached after a release. Only the mutable manifest
  -- needs a fresh URL; payload files remain pinned to an immutable commit.
  local fresh=tostring(math.floor(computer.uptime()*1000))
  download(base.."main/package.manifest?fresh="..fresh,stage.."/package.manifest")
  local manifestText=assert(read(stage.."/package.manifest"))
  local manifest=parse(manifestText)
  if action=="update" and read(target("package.manifest"))==manifestText then
    local ok=pcall(check)
    if ok then
      remove(stage.."/package.manifest"); remove(stage)
      print("Already up to date."); return true
    end
    print("Installed files damaged; downloading clean copies.")
  end
  -- Fetch all files from ONE immutable commit, not a moving branch.
  for i,e in ipairs(manifest.files) do
    print(string.format("[%d/%d] %s",i,#manifest.files,e.key))
    download(base..manifest.revision.."/"..e.key,stage.."/"..e.key)
    verify(stage.."/"..e.key,e)
  end
  assert(read(stage.."/VERSION"):gsub("%s+$","")==manifest.version,"Version mismatch")
  local backup=unique(backups,"backup-")
  local journal={}
  -- Back up every managed target before the first replacement.
  for _,key in ipairs(keys) do
    local dest=target(key)
    if fs.exists(dest) then
      assert(not fs.isDirectory(dest),"Managed target is a directory: "..dest)
      local old=assert(read(dest))
      write(backup.."/"..key,old)
      assert(read(backup.."/"..key)==old,"Backup write failed")
      journal[#journal+1]=key.." 1 "..#old.." "..checksum(old)
    else journal[#journal+1]=key.." 0 0 00000001" end
  end
  write(backup.."/restore.list",table.concat(journal,"\n").."\n")
  pointer(work.."/pending",backup)
  local ok,err=pcall(function()
    for _,e in ipairs(manifest.files) do
      local dest=target(e.key); directory(fs.path(dest))
      write(dest,assert(read(stage.."/"..e.key)))
      verify(dest,e)
    end
    write(target("package.manifest"),manifestText)
    assert(read(target("package.manifest"))==manifestText,"Manifest write failed")
    pointer(work.."/last-backup",backup)
    remove(work.."/pending")
  end)
  if not ok then
    local restored,restoreError=pcall(restore,backup)
    if restored then remove(work.."/pending") end
    error("Install failed: "..tostring(err).."\nBackup: "..backup..
      (restored and "\nPrevious files restored." or "\nRecovery failed: "..tostring(restoreError)))
  end
  local cleaned,cleanupError=pcall(function()
    for _,key in ipairs(keys) do remove(stage.."/"..key) end
    remove(stage)
  end)
  if not cleaned then print("Installed; temporary files remain: "..tostring(cleanupError)) end
  print("Installed OpenBeekeeper "..manifest.version)
  print("Backup: "..backup)
  print("Data preserved: "..data)
  print("Run: bees check | bees catalog | bees me | bees map")
  return true
end

local ok,result=pcall(function()
  if action=="check" then return check() end
  if action=="rollback" then
    recover()
    local path=assert(read(work.."/last-backup"),"No rollback backup")
    pointer(work.."/pending",backupPath(path))
    restore(path); remove(work.."/pending")
    print("Previous managed files restored. Data untouched."); return true
  end
  assert(action=="install" or action=="update" or action=="reinstall" or action=="repair",
    "Use: install | update | reinstall | repair | check | rollback")
  return install()
end)
if not ok then io.stderr:write("OpenBeekeeper: "..tostring(result).."\n"); return false end
return result
