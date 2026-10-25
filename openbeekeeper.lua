-- OpenBeekeeper 0.7.1: scalable module discovery and interface binding.
local component = require("component")
local args = {...}
local command = args[1] or "scan"
local sideNames = {[0]="down", "up", "north", "south", "west", "east"}

local function read(method, ...)
  -- OpenOS callbacks may be callable proxy objects, not Lua functions.
  if method==nil then return nil,"method unavailable" end
  local ok,value,reason=pcall(method,...)
  if not ok then return nil,tostring(value) end
  return value,reason
end

-- One shared ME read interval, including separate CLI invocations.
-- This is a polling cooldown, not cancellation of an in-progress OC callback.
local ME_INTERVAL=20
local DRONE_TARGET=32
local snapshots={}
local function readME(entry,force)
  local ok,value,reason=pcall(function()
    local computer=require("computer")
    local fs=require("filesystem")
    local directory="/home/.openbeekeeper-data"
    local clockPath=directory.."/me-last-read"
    local now=computer.uptime()
    local machine=computer.address()
    local serialization=require("serialization")
    local cachePath=directory.."/me-cache-"..entry.address:gsub("[^%w%-]","_")
    local cached=snapshots[entry.address]
    if not cached and fs.exists(cachePath) then
      local f=io.open(cachePath,"r")
      if f then
        local text=f:read("*a"); f:close()
        local parsed,value=pcall(serialization.unserialize,text)
        if parsed then cached=value end
      end
    end
    if not force and type(cached)=="table" and cached.schema=="ME1" and cached.machine==machine
        and cached.endpoint==entry.address and type(cached.stamp)=="number"
        and cached.stamp<=now and now-cached.stamp<ME_INTERVAL and type(cached.items)=="table" then
      snapshots[entry.address]=cached
      print("ME cache: snapshot "..math.floor(now-cached.stamp).." seconds old.")
      return cached.items
    end
    local last
    if fs.exists(clockPath) then
      local file=assert(io.open(clockPath,"r"))
      local record=file:read("*a"); file:close()
      local id,stamp=record:match("^(%S+) (%S+)%s*$")
      local parsed=tonumber(stamp)
      assert(id and parsed and parsed>=0 and parsed<math.huge,"Invalid ME polling clock")
      -- A copied disk or a reset uptime must not inherit a stale cooldown.
      if id==machine and parsed<=now then last=parsed end
    end
    if last and now-last<ME_INTERVAL then
      local remaining=ME_INTERVAL-(now-last)
      print("ME cooldown: waiting "..math.ceil(remaining).." seconds...")
      os.sleep(remaining)
    end
    if not fs.exists(directory) then assert(fs.makeDirectory(directory)) end
    local file=assert(io.open(clockPath,"w"))
    assert(file:write(machine.." "..string.format("%.17g",computer.uptime()).."\n"))
    assert(file:flush())
    local closed,err=file:close()
    assert(closed~=false and not err,err or "Cannot save ME polling clock")
    -- Failed attempts also consume the interval, avoiding rapid retries.
    local items,readError=read(entry.proxy.getItemsInNetwork)
    if type(items)~="table" then return nil,readError end
    -- Keep only bee/sample descriptors, not a copy of a potentially huge base.
    local relevant={}
    for _,item in pairs(items) do
      if type(item)=="table" then
        local name=tostring(item.name or ""):lower()
        if name:find("bee_",1,true) or name:find("sample",1,true) then relevant[#relevant+1]=item end
      end
    end
    local snapshot={schema="ME1",machine=machine,endpoint=entry.address,stamp=computer.uptime(),items=relevant}
    snapshots[entry.address]=snapshot
    local saved,saveError=pcall(function()
      local text=serialization.serialize(snapshot)
      local f=assert(io.open(cachePath..".new","w"))
      assert(f:write(text)); assert(f:flush()); f:close()
      if fs.exists(cachePath) then assert(fs.remove(cachePath)) end
      assert(fs.rename(cachePath..".new",cachePath))
    end)
    if not saved then print("ME cache not saved: "..tostring(saveError)) end
    return relevant
  end)
  if not ok then return nil,tostring(value) end
  return value,reason
end

local function alive(v)
  return type(v)=="table" and (tonumber(v.size) or 0)>0
    and v.name~="minecraft:air" and v.name~="air"
end

local function bee(v)
  local name=tostring(v.name or "")
  local kind
  if name:find("bee_princess",1,true) then kind="princess"
  elseif name:find("bee_drone",1,true) then kind="drone"
  elseif name:find("bee_queen",1,true) then kind="queen" end
  if not kind then return end
  local individual=type(v.individual)=="table" and v.individual or {}
  return individual.ident,kind
end

local function discover()
  local entries,transposers,networks,catalogues={},{},{},{}
  local tools={exporters={},databases={}}
  for address,kind in component.list() do entries[#entries+1]={address=address,kind=kind} end
  table.sort(entries,function(a,b) return a.address<b.address end)
  for _,entry in ipairs(entries) do
    local methods=read(component.methods,entry.address)
    local proxy=read(component.proxy,entry.address)
    if type(methods)=="table" and proxy then
      entry.proxy=proxy
      entry.methods=methods
      if entry.kind=="transposer" then transposers[#transposers+1]=entry end
      -- Values are the direct-call flag, NOT an availability flag.
      -- false means a synchronized callback exists; only nil means absent.
      if methods.getItemsInNetwork~=nil then networks[#networks+1]=entry end
      if methods.listAllSpecies~=nil and methods.getBeeBreedingData~=nil then catalogues[#catalogues+1]=entry end
      if methods.exportIntoSlot~=nil and methods.setExportConfiguration~=nil then tools.exporters[#tools.exporters+1]=entry end
      if entry.kind=="database" or (methods.computeHash~=nil and methods.get~=nil and methods.indexOf~=nil) then
        tools.databases[#tools.databases+1]=entry
      end
    end
  end
  return transposers,networks,catalogues,tools
end

local function inspect(transposers,visitor,verbose)
  local count=0
  for _,entry in ipairs(transposers) do
    local t=entry.proxy
    if verbose then print("TRANSPOSER "..entry.address) end
    for side=0,5 do
      local size,reason=read(t.getInventorySize,side)
      if type(size)=="number" then
        local name=read(t.getInventoryName,side) or "unknown"
        if name=="gendustry:industrial_apiary" then count=count+1 end
        if verbose then print(string.format("  SIDE %d (%s): %s [%d]",side,sideNames[side],name,size)) end
        for slot=1,size do
          local v,err=read(t.getStackInSlot,side,slot)
          if alive(v) then
            if verbose then
              local id,kind=bee(v)
              print(string.format("    %d x%d %s%s",slot,v.size,tostring(v.label or v.name),
                kind and (" | "..kind.." | "..tostring(id or "ID unavailable")) or ""))
            end
            if visitor then visitor(v,"local") end
          elseif err and verbose then print("    slot "..slot..": "..tostring(err)) end
        end
      elseif verbose and reason and reason~="no inventory" then
        print("  SIDE "..side..": "..tostring(reason))
      end
    end
  end
  return count
end

local function listNetworks(networks)
  print("ME endpoints (multiple endpoints may share ONE network):")
  for i,e in ipairs(networks) do
    print(i,e.kind,e.address,"interface-config="..tostring(e.methods.setInterfaceConfiguration~=nil))
  end
  if #networks==0 then print("None. Connect an OC adapter to an ME interface.") end
  print("Numbers are temporary. Never use them as saved role bindings.")
end

local function listTools(tools)
  print("ME export-bus components (not network readers): "..#tools.exporters)
  for i,entry in ipairs(tools.exporters) do
    print("X"..i,entry.kind,entry.address)
    for side=0,5 do
      local config=read(entry.proxy.getExportConfiguration,side)
      if type(config)=="table" then print("  export side "..side.." ("..sideNames[side]..")") end
    end
  end
  print("OC databases: "..#tools.databases)
  for i,entry in ipairs(tools.databases) do print("D"..i,entry.kind,entry.address) end
  if #tools.exporters==0 then
    print("No export API found. The adapter must touch the AE cable block holding the bus.")
  end
end

local ROLE_PATH="/home/.openbeekeeper-data/roles"
local roleNames={"stock","transport","genes"}
local function readText(path)
  local f=io.open(path,"r"); if not f then return end
  local text=f:read("*a"); f:close(); return text
end
local function writeText(path,text)
  local f=assert(io.open(path,"w")); assert(f:write(text)); assert(f:flush())
  local closed,err=f:close(); assert(closed~=false and not err,err or "Cannot save roles")
end
local function parseRoles(text)
  if not text then return end
  if text:match("^OpenBeekeeper%-roles%-2\n") then
    local address=text:match("^OpenBeekeeper%-roles%-2\nnetwork ([%w%-]+)\n?$")
    assert(address,"Invalid shared network record")
    return {mode="shared",network=address,stock=address,transport=address,genes=address}
  end
  assert(text:match("^OpenBeekeeper%-roles%-1\n"),"Invalid roles header")
  local result={}
  for line in text:gmatch("[^\n]+") do
    if line~="OpenBeekeeper-roles-1" then
      local role,address=line:match("^(%a+) ([%w%-]+)$")
      assert((role=="stock" or role=="transport" or role=="genes") and not result[role],"Invalid roles record")
      result[role]=address
    end
  end
  for _,role in ipairs(roleNames) do assert(result[role],"Missing role: "..role) end
  assert(result.stock~=result.transport and result.stock~=result.genes and result.genes~=result.transport,
    "Roles need three distinct endpoints")
  return result
end
local function loadRoles()
  local text=readText(ROLE_PATH)
  if not text then text=readText(ROLE_PATH..".bak") end
  local ok,roles=pcall(parseRoles,text)
  if not ok then return nil,tostring(roles) end
  return roles
end
local function roleIndex(role,networks)
  local roles,err=loadRoles()
  if not roles then return nil,err or "No saved network. Use bees setup <ME number>." end
  if role=="network" then role="stock" end
  for i,entry in ipairs(networks) do if entry.address==roles[role] then return i end end
  return nil,"Missing "..role.." endpoint. Rebind roles after replacing a component."
end

-- Gendustry 1.12 GeneSampleInfo: species=root UID, chromosome=0-based, allele=UID.
-- Accept only recognizable structured NBT. A label/hash cannot prove a gene.
local function gene(v)
  if tostring(v.name or ""):lower():gsub("_","")~="gendustry:genesample" then return end
  local tag=type(v.tag)=="table" and v.tag or type(v.nbt)=="table" and v.nbt or nil
  if not tag or tag.species~="rootBees" or type(tag.allele)~="string" or tag.allele=="" then return end
  local chr=tonumber(tag.chromosome)
  if not chr or chr<0 or chr>12 or chr%1~=0 then return end
  return {root=tag.species,chromosome=chr,allele=tag.allele}
end

local transposers,networks,catalogues,tools=discover()
local pendingPath="/home/.openbeekeeper-data/interface-test-pending"
local function resetInterfaceTest()
  local pending=readText(pendingPath)
  if not pending then return end
  local interfaceAddress,databaseAddress=pending:match("^(%S+) (%S+)%s*$")
  assert(interfaceAddress and databaseAddress,"Invalid interface-test journal")
  local interface=component.proxy(interfaceAddress)
  local database=component.proxy(databaseAddress)
  local _,err=read(interface.setInterfaceConfiguration,1)
  assert(not err,err)
  local config,configError=read(interface.getInterfaceConfiguration,1)
  assert(not configError and not alive(config),"Cannot clear interface request slot 1")
  local _,dbError=read(database.clear,1)
  assert(not dbError,dbError)
  local value,getError=read(database.get,1)
  assert(not getError and not alive(value),"Cannot clear test database entry 1")
  assert(require("filesystem").remove(pendingPath))
  print("Test request cleared; temporary database entry cleared.")
end

-- Interface UUIDs and transposer UUIDs have no shared ordering or coordinates.
-- Correlate them by requesting one harmless item, never by list position.
local BIND_PATH="/home/.openbeekeeper-data/modules"
local BIND_PENDING="/home/.openbeekeeper-data/bind-pending"
local function bindModules(recover)
  local fs=require("filesystem")
  local function call(method,...)
    local value,err=read(method,...)
    assert(not err,err)
    assert(value~=false,"Component operation rejected")
    return value
  end
  local modules,interfaces={},{}
  for _,entry in ipairs(transposers) do
    local module={entry=entry,machines={}}
    for side=0,5 do
      local name=read(entry.proxy.getInventoryName,side)
      if name=="appliedenergistics2:interface" then
        assert(module.side==nil,"Several interfaces touch transposer "..entry.address)
        module.side=side
      elseif name=="gendustry:industrial_apiary" or name=="gendustry:mutatron"
          or name=="gendustry:mutatron_advanced" or name=="gendustry:imprinter"
          or name=="gendustry:sampler" or name=="forestry:analyzer" then
        module.machines[#module.machines+1]={side=side,name=name}
      end
    end
    if module.side~=nil and #module.machines>0 then modules[#modules+1]=module end
  end
  for _,entry in ipairs(networks) do
    if entry.methods.setInterfaceConfiguration~=nil and entry.methods.getInterfaceConfiguration~=nil then
      interfaces[#interfaces+1]=entry
    end
  end
  local function waitEmpty(module)
    for attempt=0,15 do
      local empty=true
      for slot=1,9 do
        if alive(call(module.entry.proxy.getStackInSlot,module.side,slot)) then empty=false end
      end
      if empty then return end
      if attempt<15 then os.sleep(1) end
    end
    error("Interface did not empty; check ME storage space and run bees bind-reset")
  end
  local function cleanup()
    local text=readText(BIND_PENDING)
    if not text then return end
    local address,dbAddress,slot=text:match("^OBBIND1\n(%S+) (%S+) (%d+)\n$")
    assert(address and dbAddress,"Invalid binding journal; preserve it for recovery")
    slot=tonumber(slot)
    local proxy=component.proxy(address)
    call(proxy.setInterfaceConfiguration,9)
    assert(call(proxy.getInterfaceConfiguration,9)==nil,"Request 9 remains configured")
    -- Clear the request before releasing the descriptor, including after a restart.
    local database=component.proxy(dbAddress)
    local value=call(database.get,slot)
    assert(not alive(value) or value.name=="minecraft:cobblestone","Reserved database entry changed")
    call(database.clear,slot)
    assert(call(database.get,slot)==nil,"Temporary database entry not cleared")
    assert(fs.remove(BIND_PENDING))
  end
  if recover then
    cleanup()
    for _,module in ipairs(modules) do waitEmpty(module) end
    print("Binding request cleared. No machine inventory was changed.")
    return
  end
  assert(not fs.exists(BIND_PENDING),"Unfinished binding. Run bees bind-reset first")
  assert(not fs.exists(pendingPath),"Finish bees interface-reset first")
  assert(#modules>0,"No processing module with an adjacent ME interface found")
  assert(#modules==#interfaces,"Need one configurable interface per module: modules="..#modules..", interfaces="..#interfaces)
  assert(#tools.databases>0,"One OC database is required")
  -- Never overwrite requests or draw conclusions from an already occupied buffer.
  for _,entry in ipairs(interfaces) do
    for slot=1,9 do
      assert(call(entry.proxy.getInterfaceConfiguration,slot)==nil,"Interface has existing requests: "..entry.address)
    end
  end
  for _,module in ipairs(modules) do
    for slot=1,9 do
      assert(not alive(call(module.entry.proxy.getStackInSlot,module.side,slot)),"Interface inventory must be empty: "..module.entry.address)
    end
  end
  local db,dbSlot
  for _,entry in ipairs(tools.databases) do
    for slot=1,81 do
      local value,err=read(entry.proxy.get,slot)
      if err then break end
      if value==nil then db,dbSlot=entry,slot; break end
    end
    if db then break end
  end
  assert(db,"No free OC database entry")
  if not fs.exists("/home/.openbeekeeper-data") then
    assert(fs.makeDirectory("/home/.openbeekeeper-data"))
  end
  local rows={"OpenBeekeeper-modules-1"}
  local used={}
  local ok,err=pcall(function()
    for index,interface in ipairs(interfaces) do
      -- Write ownership before any mutating call so interruption is recoverable.
      writeText(BIND_PENDING,"OBBIND1\n"..interface.address.." "..db.address.." "..dbSlot.."\n")
      if index==1 then
        assert(call(interface.proxy.store,{name="minecraft:cobblestone"},db.address,dbSlot,1),"No cobblestone available in ME")
      else
        -- Reuse the previous descriptor; no further ME inventory/store queries.
        assert(call(db.proxy.get,dbSlot).name=="minecraft:cobblestone","Marker descriptor missing")
      end
      local marker=call(db.proxy.get,dbSlot)
      assert(marker and marker.name=="minecraft:cobblestone","ME store did not find cobblestone")
      assert(call(interface.proxy.setInterfaceConfiguration,9,db.address,dbSlot,1),"Interface request rejected")
      local found
      for attempt=0,15 do
        found=nil
        for _,module in ipairs(modules) do
          local present=false
          for slot=1,9 do
            local value=call(module.entry.proxy.getStackInSlot,module.side,slot)
            if alive(value) then
              assert(value.name=="minecraft:cobblestone" and value.size==1,"Unexpected item in interface during binding")
              assert(not present,"Multiple marker stacks in an interface")
              present=true
            end
          end
          if present then assert(not found,"Marker visible at multiple modules"); found=module end
        end
        if found then break end
        if attempt<15 then os.sleep(1) end
      end
      assert(found,"No marker delivered within 15 seconds")
      assert(not used[found.entry.address],"Several interface components map to one module")
      used[found.entry.address]=true
      call(interface.proxy.setInterfaceConfiguration,9)
      assert(call(interface.proxy.getInterfaceConfiguration,9)==nil,"Cannot clear marker request")
      waitEmpty(found)
      rows[#rows+1]="interface "..found.entry.address.." "..found.side.." "..interface.address
      for _,machine in ipairs(found.machines) do
        rows[#rows+1]="machine "..found.entry.address.." "..machine.side.." "..machine.name
      end
      print("BOUND "..index.."/"..#interfaces..": "..found.entry.address.." -> "..interface.address.."; machines="..#found.machines)
      -- Retain journal ownership of the descriptor across modules and crashes.
    end
    cleanup()
    writeText(BIND_PATH..".new",table.concat(rows,"\n").."\n")
    if fs.exists(BIND_PATH..".bak") then assert(fs.remove(BIND_PATH..".bak")) end
    if fs.exists(BIND_PATH) then assert(fs.rename(BIND_PATH,BIND_PATH..".bak")) end
    assert(fs.rename(BIND_PATH..".new",BIND_PATH))
  end)
  if not ok then
    local cleaned,cleanupError=pcall(cleanup)
    if not cleaned then print("Cleanup pending: "..tostring(cleanupError)) end
    error(tostring(err))
  end
  print("Saved "..#interfaces.." module bindings. No bees moved; machine slots untouched.")
end

local function collectionPlan()
  local index,err=roleIndex("network",networks)
  assert(index,err)
  local items,readError=readME(networks[index])
  assert(type(items)=="table",readError or "ME inventory unavailable")
  local species,names,recipes={},{},{}
  local function entry(uid,label)
    if type(uid)~="string" or uid=="" then return end
    if not species[uid] then species[uid]={uid=uid,label=label or uid,princess=0,drone=0,queen=0,samples=0} end
    if label and label~="" then species[uid].label=label end
    return species[uid]
  end
  -- One world catalogue suffices; every housing exposes the same registry.
  for _,catalogue in ipairs(catalogues) do
    local data=read(catalogue.proxy.listAllSpecies)
    if type(data)=="table" then
      for _,v in pairs(data) do
        if type(v)=="table" then entry(v.uid,v.name) end
      end
      local mutations=read(catalogue.proxy.getBeeBreedingData)
      if type(mutations)=="table" then recipes=mutations end
      break
    end
  end
  for _,v in pairs(items) do
    if alive(v) then
      local uid,kind=bee(v)
      if uid then
        local e=entry(uid,type(v.individual)=="table" and v.individual.displayName)
        if e then e[kind]=e[kind]+v.size end
      end
      local g=gene(v)
      if g and g.chromosome==0 then entry(g.allele).samples=entry(g.allele).samples+v.size end
    end
  end
  -- Resolve names only after collecting all IDs, never use a label as a bee UID.
  for uid,e in pairs(species) do
    if names[e.label]==nil then names[e.label]=uid elseif names[e.label]~=uid then names[e.label]=false end
  end
  local unverified=0
  for _,v in pairs(items) do
    if alive(v) and v.name=="gendustry:gene_sample" and not gene(v) then
      local label=tostring(v.label or ""):match("^Bee Sample %- Species: (.+)$")
      local uid=label and names[label]
      if uid then species[uid].labelSample=true end
      unverified=unverified+v.size
    end
  end
  local owned={}
  for _,e in pairs(species) do
    if e.princess+e.drone+e.queen>0 then owned[#owned+1]=e end
  end
  table.sort(owned,function(a,b) return a.label<b.label end)
  print("COLLECTION PLAN / read-only; ME stock only (machines excluded)")
  print("P=princesses D=drones Q=queens; drone stock target/reserve: "..DRONE_TARGET.." per species")
  local ready,breed,blocked=0,0,0
  for _,e in ipairs(owned) do
    local action
    if e.drone<DRONE_TARGET then
      local deficit=DRONE_TARGET-e.drone
      if e.queen>0 then
        breed=breed+1; action="APIARY: finish queen cycle; stock deficit="..deficit
      elseif e.princess>0 and e.drone>0 then
        breed=breed+1; action="REPRODUCE: build stock to "..DRONE_TARGET.."; deficit="..deficit
      else
        blocked=blocked+1; action="MISSING PARENT: stock deficit="..deficit.."; preserve current stock"
      end
    elseif e.samples>0 then action="KEEP: structured species sample present; stock target reached"
    elseif e.labelSample then action="REVIEW: sample label present; identity not NBT-confirmed"
    elseif e.drone>DRONE_TARGET then
      ready=ready+1
      action="SAMPLE CANDIDATE: "..(e.drone-DRONE_TARGET).." surplus drones; reserve="..DRONE_TARGET.."; random chromosome, donor consumed"
    elseif e.queen>0 then
      breed=breed+1; action="APIARY: obtain sample donors above reserve="..DRONE_TARGET
    elseif e.princess>0 and e.drone>0 then
      breed=breed+1; action="REPRODUCE: obtain sample donors above reserve="..DRONE_TARGET
    else
      blocked=blocked+1; action="MISSING PARENT: stock target reached; need surplus donors; reserve="..DRONE_TARGET
    end
    print(string.format("%s P=%d D=%d Q=%d | %s | %s",e.label,e.princess,e.drone,e.queen,action,e.uid))
  end
  print(string.format("Owned species: %d | sample candidates: %d | reproduction: %d | missing parents: %d",#owned,ready,breed,blocked))
  print("NEXT MUTATIONS / only recipes whose result has no observed bee or sample")
  local candidateRows,seen={},{}
  local function resolve(value)
    if type(value)~="string" then return end
    if species[value] then return species[value] end
    local uid=names[value]; return uid and species[uid] or nil
  end
  for _,recipe in pairs(recipes) do
    if type(recipe)=="table" then
      local a,b,result=resolve(recipe.allele1),resolve(recipe.allele2),resolve(recipe.result)
      if a and b and result and result.princess+result.drone+result.queen==0
          and result.samples==0 and not result.labelSample then
        local p,d
        if a.princess>0 and b.drone>0 then p,d=a,b
        elseif b.princess>0 and a.drone>0 then p,d=b,a end
        if p then
          local key=p.uid.."/"..d.uid.."/"..result.uid
          if not seen[key] then
            seen[key]=true
            local conditions={}
            if type(recipe.specialConditions)=="table" then
              for _,v in pairs(recipe.specialConditions) do conditions[#conditions+1]=tostring(v) end
            elseif recipe.specialConditions~=nil and tostring(recipe.specialConditions)~="" then
              conditions[1]=tostring(recipe.specialConditions)
            end
            table.sort(conditions)
            local reserve=p.princess<2 and " | REVIEW: last princess of this species" or ""
            if d.drone<=DRONE_TARGET then reserve=reserve.." | REVIEW: would draw from drone reserve="..DRONE_TARGET end
            candidateRows[#candidateRows+1]=p.label.." (P) + "..d.label.." (D) -> "..result.label
              .." | "..tostring(recipe.chance or "?").."%"..reserve
              ..(#conditions>0 and " | CONDITIONS: "..table.concat(conditions,"; ") or "")
          end
        end
      end
    end
  end
  table.sort(candidateRows)
  for _,row in ipairs(candidateRows) do print(row) end
  if #candidateRows==0 then print("No available pair for an unobserved result in the current catalogue.") end
  print("Mutatron result selection is not exposed by the installed OC driver.")
  print("Plan only: no donors consumed, no requests configured, no jobs started.")
  if unverified>0 then print("Sample items without structured gene identity: "..unverified..". Label evidence requires review.") end
end

if command=="plan" then
  local ok,err=pcall(collectionPlan)
  if not ok then print("Planning stopped: "..tostring(err)); return false end
elseif command=="bind" or command=="bind-reset" then
  local ok,err=pcall(bindModules,command=="bind-reset")
  if not ok then print("Binding stopped: "..tostring(err)); return false end
  return true
elseif command=="modules" then
  local text=readText(BIND_PATH) or readText(BIND_PATH..".bak")
  print(text or "No module bindings. Run bees bind.")
  return true
elseif command=="scan" then
  print("OpenBeekeeper 0.7.1 - read-only discovery")
  print("Transposers: "..#transposers)
  local n=inspect(transposers,nil,true)
  print("Apiary adjacencies: "..n.." (duplicates possible; not a worker count)")
  listNetworks(networks)
  listTools(tools)
  print("Forestry catalogue endpoints: "..#catalogues)
elseif command=="me" then
  listNetworks(networks)
  listTools(tools)
elseif command=="interface-reset" then
  local ok,err=pcall(resetInterfaceTest)
  if not ok then print("Cleanup failed: "..tostring(err)); return false end
  return true
elseif command=="interface-test" then
  local ok,err=pcall(function()
    resetInterfaceTest()
    local interfaces={}
    for _,e in ipairs(networks) do
      if e.methods.setInterfaceConfiguration~=nil and e.methods.getInterfaceConfiguration~=nil then
        interfaces[#interfaces+1]=e
      end
    end
    assert(#interfaces==1,"Test requires exactly one configurable ME interface")
    assert(#tools.databases==1,"Test requires exactly one OC database")
    local interface=interfaces[1]
    local database=tools.databases[1]
    local entry,entryError=read(database.proxy.get,1)
    assert(not entryError and not alive(entry),"Database entry 1 must be empty")
    for slot=1,9 do
      local config,configError=read(interface.proxy.getInterfaceConfiguration,slot)
      assert(not configError and not alive(config),"All interface requests must be empty")
    end
    local candidates={}
    for _,e in ipairs(transposers) do
      local interfaceSides,apiarySides={},{}
      for side=0,5 do
        local name=read(e.proxy.getInventoryName,side)
        if name=="appliedenergistics2:interface" then interfaceSides[#interfaceSides+1]=side end
        if name=="gendustry:industrial_apiary" then apiarySides[#apiarySides+1]=side end
      end
      if #interfaceSides==1 and #apiarySides>0 then
        candidates[#candidates+1]={entry=e,source=interfaceSides[1],apiaries=apiarySides}
      end
    end
    assert(#candidates==1,"Test requires one unambiguous transposer with interface and apiaries")
    local station=candidates[1]
    local t=station.entry.proxy
    for slot=1,9 do
      local stack,stackError=read(t.getStackInSlot,station.source,slot)
      assert(not stackError and not alive(stack),"Interface inventory must be empty before test")
    end
    local destination
    for _,side in ipairs(station.apiaries) do
      local queen,qe=read(t.getStackInSlot,side,1)
      local drone,de=read(t.getStackInSlot,side,2)
      if not qe and not de and not alive(queen) and not alive(drone) then destination=side; break end
    end
    assert(destination,"An apiary must have empty queen and drone slots")
    local expected="forestry.speciesCultivated"
    local items,itemsError=readME(interface)
    assert(type(items)=="table",itemsError or "Cannot read ME")
    local chosen
    for _,v in pairs(items) do
      if alive(v) then local id,kind=bee(v); if id==expected and kind=="drone" then chosen=v; break end end
    end
    assert(chosen,"Put at least one Cultivated Drone in this ME network")
    print("Test route: interface side "..station.source.." -> apiary side "..destination..", drone slot 2")
    local fs=require("filesystem")
    if not fs.exists("/home/.openbeekeeper-data") then assert(fs.makeDirectory("/home/.openbeekeeper-data")) end
    -- Journal BEFORE any mutation. Recovery clears only initially empty entries.
    writeText(pendingPath,interface.address.." "..database.address.."\n")
    local _,storeError=read(interface.proxy.store,{name=chosen.name,label=chosen.label},database.address,1,1)
    assert(not storeError,storeError)
    local stored,getError=read(database.proxy.get,1)
    assert(not getError and alive(stored),"ME did not store a descriptor in database entry 1")
    local id,kind=bee(stored)
    assert(id==expected and kind=="drone","Stored database descriptor is not the expected drone")
    local _,setError=read(interface.proxy.setInterfaceConfiguration,1,database.address,1,1)
    assert(not setError,setError)
    local request,requestError=read(interface.proxy.getInterfaceConfiguration,1)
    assert(not requestError and alive(request) and request.size==1,"One-drone interface request was not applied")
    local sourceSlot
    for attempt=1,10 do
      for slot=1,9 do
        local v=read(t.getStackInSlot,station.source,slot)
        if alive(v) then
          local uid,beeKind=bee(v)
          assert(uid==expected and beeKind=="drone","Unexpected item appeared in interface; stopping")
          sourceSlot=slot; break
        end
      end
      if sourceSlot then break end
      if attempt<10 then os.sleep(1) end
    end
    assert(sourceSlot,"Interface did not supply the drone within 9 seconds")
    local queen,queenError=read(t.getStackInSlot,destination,1)
    local drone,droneError=read(t.getStackInSlot,destination,2)
    assert(not queenError and not droneError and not alive(queen) and not alive(drone),
      "Apiary is no longer empty; stopping before transfer")
    local moved,moveError=read(t.transferItem,station.source,destination,1,sourceSlot,2)
    assert(moved==1,moveError or "Drone transfer failed")
    local output,outputError=read(t.getStackInSlot,destination,2)
    local uid,beeKind=bee(output or {})
    assert(not outputError and alive(output) and output.size==1 and uid==expected and beeKind=="drone",
      "Destination verification failed; inspect apiary before repeating")
    print("SUCCESS: one Cultivated Drone transferred. No princess loaded; breeding not started.")
  end)
  local cleaned,cleanupError=pcall(resetInterfaceTest)
  if not cleaned then
    print("Request cleanup failed: "..tostring(cleanupError))
    print("Clear interface request slot 1 manually or run bees interface-reset before continuing.")
  end
  if not ok then print("Interface test stopped: "..tostring(err)) end
  return ok and cleaned
elseif command=="setup" then
  local selection={}
  local shared=not args[3] and not args[4]
  for i,role in ipairs(roleNames) do selection[role]=networks[tonumber(shared and args[2] or args[i+1])] end
  if not selection.stock or not selection.transport or not selection.genes then
    listNetworks(networks); print("Use: bees setup <ME number> (or legacy: <stock> <transport> <genes>)"); return false
  end
  local text="OpenBeekeeper-roles-1\n"
  for _,role in ipairs(roleNames) do text=text..role.." "..selection[role].address.."\n" end
  if shared then text="OpenBeekeeper-roles-2\nnetwork "..selection.stock.address.."\n" end
  local ok,err=pcall(function()
    parseRoles(text)
    local fs=require("filesystem")
    if not fs.exists("/home/.openbeekeeper-data") then assert(fs.makeDirectory("/home/.openbeekeeper-data")) end
    local old=readText(ROLE_PATH)
    if old then writeText(ROLE_PATH..".bak",old) end
    writeText(ROLE_PATH..".new",text)
    assert(readText(ROLE_PATH..".new")==text,"Roles write verification failed")
    if fs.exists(ROLE_PATH) then assert(fs.remove(ROLE_PATH)) end
    assert(fs.rename(ROLE_PATH..".new",ROLE_PATH),"Cannot publish roles file")
  end)
  if not ok then print("Roles not saved: "..tostring(err)); return false end
  if shared then
    print("Shared ME network saved: "..selection.stock.address)
    print("Bee stock and samples use ONE snapshot. Working buffer: local apiarist chest.")
  else
    for _,role in ipairs(roleNames) do print(role.." = "..selection[role].address) end
    print("Legacy split-network roles saved.")
  end
  print("Replacing a component requires rebinding; changing list order does not.")
elseif command=="roles" then
  local roles,err=loadRoles()
  if not roles then print(err or "No saved roles. Use bees setup."); return false end
  for _,role in ipairs(roles.mode=="shared" and {"network"} or roleNames) do
    local index=roleIndex(role,networks)
    print(role,roles[role],index and ("OK, current number "..index) or "MISSING - rebind required")
  end
elseif command=="catalog" then
  if #catalogues==0 then
    print("Connect an OC adapter to a normal Forestry apiary for the catalogue API.")
  end
  local serialization=require("serialization")
  for _,entry in ipairs(catalogues) do
    print("CATALOGUE "..entry.address)
    for _,method in ipairs({"listAllSpecies","getBeeBreedingData"}) do
      local data,err=read(entry.proxy[method])
      if type(data)=="table" then
        local count,examples=0,{}
        for _,v in pairs(data) do count=count+1; if #examples<3 then examples[#examples+1]=v end end
        print(method..": "..count.." records")
        for _,v in ipairs(examples) do print(serialization.serialize(v)) end
      else print(method..": "..tostring(err or "unavailable")) end
    end
  end
  print("listAllSpecies is mutation results, not a proven complete list of every species.")
elseif command=="probe" then
  local index=tonumber(args[2])
  if args[2]=="stock" or args[2]=="transport" or args[2]=="genes" or args[2]=="network" then
    local err; index,err=roleIndex(args[2],networks)
    if not index then print(err); return false end
  end
  local entry=index and networks[index]
  if not entry then listNetworks(networks); print("Use: lua openbeekeeper.lua probe <ME number>"); return end
  local items,err=readME(entry)
  if type(items)~="table" then print("ME read failed: "..tostring(err)); return end
  local serialization=require("serialization")
  local shown=0
  print("Endpoint: "..entry.address)
  for _,v in pairs(items) do
    if alive(v) then
      local _,kind=bee(v)
      if kind or tostring(v.name):lower():find("sample",1,true) then
        print(serialization.serialize(v)); shown=shown+1
        if shown==3 then break end
      end
    end
  end
  if shown==0 then print("Add a bee and a filled bee Gene Sample to this test network.") end
elseif command=="map" or command=="owned" then
  local stockIndex,geneIndex=tonumber(args[2]),tonumber(args[3])
  if not args[2] then
    local roles,err=loadRoles()
    if err then print(err); return false end
    if roles then
      stockIndex,err=roleIndex("stock",networks)
      if not stockIndex then print(err); return false end
      geneIndex,err=roleIndex("genes",networks)
      if not geneIndex then print(err); return false end
    end
  end
  if (args[2] and not networks[stockIndex]) or (args[3] and not networks[geneIndex]) then
    listNetworks(networks); print("Use: lua openbeekeeper.lua map [stock ME number] [archive ME number]"); return
  end
  local known={
    ["forestry.speciesCommon"]={label="Common"},
    ["forestry.speciesCultivated"]={label="Cultivated"},
    ["forestry.speciesDiligent"]={label="Diligent"},
    ["forestry.speciesNoble"]={label="Noble"}
  }
  local catalogRead=false
  for _,entry in ipairs(catalogues) do
    local species=read(entry.proxy.listAllSpecies)
    if type(species)=="table" then
      catalogRead=true
      for _,v in pairs(species) do
        if type(v)=="table" and type(v.uid)=="string" and v.uid~="" then
          known[v.uid]=known[v.uid] or {label=v.name or v.uid}
        end
      end
    end
  end
  local archiveReadable=false
  local unresolved=0
  local function collect(v,source)
    local id=bee(v)
    if type(id)=="string" and id~="" then
      known[id]=known[id] or {label=(v.individual or {}).displayName or id}
      known[id].bee=true
    end
    if source=="archive" or source=="combined" then
      local g=gene(v)
      if g and g.chromosome==0 then
        known[g.allele]=known[g.allele] or {label=g.allele}
        known[g.allele].gene=true
      elseif not g and type(v.tag)~="table" and type(v.nbt)~="table"
          and v.name=="gendustry:gene_sample" then
        -- Server-observed English display format. UI evidence only; never
        -- authorize consumption/imprinting from a display-label match.
        local name=tostring(v.label or ""):match("^Bee Sample %- Species: (.+)$")
        if name then
          local matches={}
          for uid,entry in pairs(known) do if entry.label==name then matches[#matches+1]=uid end end
          if #matches==1 then known[matches[1]].labelGene=true else unresolved=unresolved+1 end
        end
      end
    end
  end
  inspect(transposers,collect,false)
  local warnings={}
  local function readNetwork(index,source)
    if not index then return end
    local items,err=readME(networks[index])
    if type(items)~="table" then warnings[#warnings+1]=source..": "..tostring(err); return end
    if source=="archive" or source=="combined" then archiveReadable=true end
    if source=="combined" then
      -- Resolve live bee UIDs/names before matching any sample labels,
      -- independent of the ME result order (especially wild species).
      for _,v in pairs(items) do if alive(v) then collect(v,"stock") end end
      for _,v in pairs(items) do if alive(v) then collect(v,"archive") end end
    else
      for _,v in pairs(items) do if alive(v) then collect(v,source) end end
    end
  end
  if stockIndex and stockIndex==geneIndex then
    readNetwork(stockIndex,"combined")
  else
    readNetwork(stockIndex,"stock"); readNetwork(geneIndex,"archive")
  end
  local rows={}
  for id,v in pairs(known) do v.id=id; rows[#rows+1]=v end
  table.sort(rows,function(a,b) return a.label<b.label end)
  local gpu=component.isAvailable("gpu") and component.gpu or nil
  local previous=gpu and gpu.getForeground() or nil
  print("BEE MAP / collection preview")
  if catalogRead then
    print("Live mutation-result catalogue loaded; wild species may be absent.")
  else
    print("Common + Cultivated -> Diligent / Noble")
    print("Illustrative branch; server recipe catalogue not loaded.")
  end
  print("B=bee; G=NBT-confirmed species sample; L=matched sample label")
  print("Green=sample present (G/L); cyan=bee only; grey=unconfirmed")
  local countBees,countGenes,countLabel=0,0,0
  for _,v in ipairs(rows) do
    if v.bee then countBees=countBees+1 end
    if v.gene then countGenes=countGenes+1 elseif v.labelGene then countLabel=countLabel+1 end
    if command~="owned" or v.bee or v.gene or v.labelGene then
      if gpu then gpu.setForeground((v.gene or v.labelGene) and 0x55FF55 or v.bee and 0x55DDFF or 0xAAAAAA) end
      print(string.format("[%s] [%s] %-16s %s",v.bee and "B" or "-",
        v.gene and "G" or v.labelGene and "L" or "?",v.label,v.id))
    end
  end
  if gpu then gpu.setForeground(previous) end
  if not archiveReadable then print("Archive not read. No collection completeness claim.") end
  print(string.format("Catalogue: %d | bees: %d | NBT samples: %d | label matches: %d",#rows,countBees,countGenes,countLabel))
  print("L is display-label evidence, not NBT verification. No automatic actions rely on L.")
  if unresolved>0 then print("Unknown/ambiguous sample labels: "..unresolved) end
  print("Preview is not the full species list. Use bees owned for collected entries only.")
  for _,w in ipairs(warnings) do print("WARNING "..w) end
else
  print("Commands: scan | me | setup <ME number> | roles | catalog | probe <number/role> | map | owned | plan | bind | bind-reset | modules | interface-test | interface-reset")
end
print("Read-only. No items moved.")
