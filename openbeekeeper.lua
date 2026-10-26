-- OpenBeekeeper 0.11.4: unattended bee genetics with exact database references.
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
local SPECIES_GENE_CHANCE=0.077 -- User-confirmed server probability per donor.
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

local function hasConditions(recipe)
  local c=recipe.specialConditions
  if type(c)=="table" then return next(c)~=nil end
  return c~=nil and c~=false and c~=""
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
    local module={entry=entry,machines={},interfaceSides={}}
    for side=0,5 do
      local name=read(entry.proxy.getInventoryName,side)
      if name=="appliedenergistics2:interface" then
        module.interfaceSides[#module.interfaceSides+1]=side
      elseif name=="gendustry:industrial_apiary" or name=="gendustry:mutatron"
          or name=="gendustry:mutatron_advanced" or name=="gendustry:imprinter"
          or name=="gendustry:sampler" or name=="forestry:analyzer" then
        module.machines[#module.machines+1]={side=side,name=name}
      end
    end
    if #module.machines>0 then
      assert(#module.interfaceSides<=1,"Several interfaces touch processing transposer "..entry.address)
      if #module.interfaceSides==1 then
        module.side=module.interfaceSides[1]
        modules[#modules+1]=module
      end
    end
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
  assert(#interfaces>=#modules,"Need one configurable interface per module: modules="..#modules..", interfaces="..#interfaces)
  assert(#tools.databases>0,"One OC database is required")
  -- Never overwrite requests or draw conclusions from an already occupied buffer.
  local candidates={}
  for _,entry in ipairs(interfaces) do
    local empty=true
    for slot=1,9 do
      if call(entry.proxy.getInterfaceConfiguration,slot)~=nil then empty=false end
    end
    if empty then candidates[#candidates+1]=entry
    else print("SKIP existing requests: "..entry.address) end
  end
  assert(#candidates>=#modules,"Not enough interfaces without existing requests: modules="..#modules..", candidates="..#candidates)
  print("Binding "..#modules.." modules using "..#candidates.." empty-configuration candidates")
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
  local bound=0
  local ok,err=pcall(function()
    for index,interface in ipairs(candidates) do
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
      call(interface.proxy.setInterfaceConfiguration,9)
      assert(call(interface.proxy.getInterfaceConfiguration,9)==nil,"Cannot clear marker request")
      if found then
        assert(not used[found.entry.address],"Several interface components map to one module")
        used[found.entry.address]=true
        waitEmpty(found)
        bound=bound+1
        rows[#rows+1]="interface "..found.entry.address.." "..found.side.." "..interface.address
        for _,machine in ipairs(found.machines) do
          rows[#rows+1]="machine "..found.entry.address.." "..machine.side.." "..machine.name
        end
        print("BOUND "..bound.."/"..#modules..": "..found.entry.address.." -> "..interface.address.."; machines="..#found.machines)
      else
        print("SKIP no marker delivered within 15 seconds: "..interface.address)
      end
      if bound==#modules then break end
      -- Retain journal ownership of the descriptor across modules and crashes.
    end
    cleanup()
    assert(bound==#modules,"Incomplete binding: bound="..bound..", modules="..#modules..". No marker delivered within 15 seconds for remaining modules; previous map preserved")
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
  print("Saved "..bound.." module bindings. No bees moved; machine slots untouched.")
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
  print(string.format("Species gene chance: %.1f%% per donor; 95%% success needs %d donors above reserve (not a guarantee).",
    SPECIES_GENE_CHANCE*100,math.ceil(math.log(0.05)/math.log(1-SPECIES_GENE_CHANCE))))
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
  print("NEXT MUTATIONS / all recipes allowed; conditions are shown but not verified")
  local candidateRows,seen={},{}
  local function resolve(value)
    if type(value)~="string" then return end
    if species[value] then return species[value] end
    local uid=names[value]; return uid and species[uid] or nil
  end
  for _,recipe in pairs(recipes) do
    if type(recipe)=="table" then
      local a,b,result=resolve(recipe.allele1),resolve(recipe.allele2),resolve(recipe.result)
      if a and b and result and result.princess+result.drone+result.queen==0 then
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
              ..((result.samples>0 or result.labelSample) and " | RECOVER: species sample present, no living bees" or "")
              ..(#conditions>0 and " | CONDITIONS: "..table.concat(conditions,"; ") or "")
          end
        end
      end
    end
  end
  table.sort(candidateRows)
  for _,row in ipairs(candidateRows) do print(row) end
  if #candidateRows==0 then print("No available pair for a species without living bees in the current catalogue.") end
  print("Mutatron result selection is not exposed by the installed OC driver.")
  print("Plan only: no donors consumed, no requests configured, no jobs started.")
  if unverified>0 then print("Sample items without structured gene identity: "..unverified..". Label evidence requires review.") end
end

-- Same-species reproduction only. Mutation, imprinting and destructive sampling
-- are deliberately separate jobs; this runner never feeds those machines.
-- BEGIN EMBEDDED AUTOMATION
local climateDefaults = {
  ["extrabees.species.abyss"]={"HELLISH","ARID"},
  ["extrabees.species.acidic"]={"WARM","DAMP"},
  ["extrabees.species.alcohol"]={"NORMAL","NORMAL"},
  ["extrabees.species.ancient"]={"NORMAL","NORMAL"},
  ["extrabees.species.arid"]={"HOT","ARID"},
  ["extrabees.species.artic"]={"ICY","NORMAL"},
  ["extrabees.species.barren"]={"HOT","ARID"},
  ["extrabees.species.basalt"]={"HELLISH","ARID"},
  ["extrabees.species.bauxite"]={"NORMAL","NORMAL"},
  ["extrabees.species.black"]={"NORMAL","NORMAL"},
  ["extrabees.species.blooming"]={"NORMAL","NORMAL"},
  ["extrabees.species.blue"]={"NORMAL","NORMAL"},
  ["extrabees.species.blutonium"]={"NORMAL","NORMAL"},
  ["extrabees.species.boggy"]={"NORMAL","NORMAL"},
  ["extrabees.species.bone"]={"HOT","ARID"},
  ["extrabees.species.brown"]={"NORMAL","NORMAL"},
  ["extrabees.species.caustic"]={"WARM","DAMP"},
  ["extrabees.species.celebratory"]={"ICY","NORMAL"},
  ["extrabees.species.cinnabar"]={"NORMAL","NORMAL"},
  ["extrabees.species.classical"]={"NORMAL","NORMAL"},
  ["extrabees.species.coal"]={"NORMAL","NORMAL"},
  ["extrabees.species.coffee"]={"NORMAL","NORMAL"},
  ["extrabees.species.copper"]={"NORMAL","NORMAL"},
  ["extrabees.species.corrosive"]={"WARM","DAMP"},
  ["extrabees.species.creeper"]={"HOT","ARID"},
  ["extrabees.species.creosote"]={"NORMAL","NORMAL"},
  ["extrabees.species.cyan"]={"NORMAL","NORMAL"},
  ["extrabees.species.cyanite"]={"NORMAL","NORMAL"},
  ["extrabees.species.darkened"]={"HELLISH","ARID"},
  ["extrabees.species.decomposing"]={"HOT","ARID"},
  ["extrabees.species.desolate"]={"HOT","ARID"},
  ["extrabees.species.diamond"]={"NORMAL","NORMAL"},
  ["extrabees.species.distilled"]={"NORMAL","NORMAL"},
  ["extrabees.species.ecstatic"]={"NORMAL","NORMAL"},
  ["extrabees.species.emerald"]={"NORMAL","NORMAL"},
  ["extrabees.species.energetic"]={"NORMAL","NORMAL"},
  ["extrabees.species.excited"]={"NORMAL","NORMAL"},
  ["extrabees.species.farm"]={"NORMAL","NORMAL"},
  ["extrabees.species.freezing"]={"ICY","NORMAL"},
  ["extrabees.species.fruit"]={"NORMAL","NORMAL"},
  ["extrabees.species.fuel"]={"NORMAL","NORMAL"},
  ["extrabees.species.fungal"]={"NORMAL","NORMAL"},
  ["extrabees.species.glowstone"]={"HELLISH","ARID"},
  ["extrabees.species.glutinous"]={"WARM","DAMP"},
  ["extrabees.species.gnawing"]={"HOT","ARID"},
  ["extrabees.species.gold"]={"NORMAL","NORMAL"},
  ["extrabees.species.granite"]={"NORMAL","NORMAL"},
  ["extrabees.species.gray"]={"NORMAL","NORMAL"},
  ["extrabees.species.greek"]={"NORMAL","NORMAL"},
  ["extrabees.species.green"]={"NORMAL","NORMAL"},
  ["extrabees.species.growing"]={"NORMAL","NORMAL"},
  ["extrabees.species.hazardous"]={"HOT","ARID"},
  ["extrabees.species.infectious"]={"NORMAL","NORMAL"},
  ["extrabees.species.ink"]={"NORMAL","DAMP"},
  ["extrabees.species.iron"]={"NORMAL","NORMAL"},
  ["extrabees.species.jaded"]={"NORMAL","NORMAL"},
  ["extrabees.species.lapis"]={"NORMAL","NORMAL"},
  ["extrabees.species.latex"]={"NORMAL","NORMAL"},
  ["extrabees.species.lead"]={"NORMAL","NORMAL"},
  ["extrabees.species.lightblue"]={"NORMAL","NORMAL"},
  ["extrabees.species.lightgray"]={"NORMAL","NORMAL"},
  ["extrabees.species.limegreen"]={"NORMAL","NORMAL"},
  ["extrabees.species.magenta"]={"NORMAL","NORMAL"},
  ["extrabees.species.malicious"]={"WARM","DAMP"},
  ["extrabees.species.marble"]={"NORMAL","NORMAL"},
  ["extrabees.species.milk"]={"NORMAL","NORMAL"},
  ["extrabees.species.mineral"]={"NORMAL","NORMAL"},
  ["extrabees.species.mystical"]={"NORMAL","NORMAL"},
  ["extrabees.species.nickel"]={"NORMAL","NORMAL"},
  ["extrabees.species.nuclear"]={"NORMAL","NORMAL"},
  ["extrabees.species.ocean"]={"NORMAL","DAMP"},
  ["extrabees.species.oil"]={"NORMAL","NORMAL"},
  ["extrabees.species.orange"]={"NORMAL","NORMAL"},
  ["extrabees.species.pink"]={"NORMAL","NORMAL"},
  ["extrabees.species.platinum"]={"NORMAL","NORMAL"},
  ["extrabees.species.prehistoric"]={"NORMAL","NORMAL"},
  ["extrabees.species.primeval"]={"NORMAL","NORMAL"},
  ["extrabees.species.purple"]={"NORMAL","NORMAL"},
  ["extrabees.species.pyrite"]={"NORMAL","NORMAL"},
  ["extrabees.species.quantum"]={"NORMAL","NORMAL"},
  ["extrabees.species.radioactive"]={"NORMAL","NORMAL"},
  ["extrabees.species.red"]={"NORMAL","NORMAL"},
  ["extrabees.species.relic"]={"NORMAL","NORMAL"},
  ["extrabees.species.resin"]={"NORMAL","NORMAL"},
  ["extrabees.species.ripening"]={"NORMAL","NORMAL"},
  ["extrabees.species.river"]={"NORMAL","DAMP"},
  ["extrabees.species.rock"]={"NORMAL","NORMAL"},
  ["extrabees.species.roman"]={"NORMAL","NORMAL"},
  ["extrabees.species.rotten"]={"HOT","ARID"},
  ["extrabees.species.ruby"]={"NORMAL","NORMAL"},
  ["extrabees.species.sapphire"]={"NORMAL","NORMAL"},
  ["extrabees.species.shadow"]={"HELLISH","ARID"},
  ["extrabees.species.silver"]={"NORMAL","NORMAL"},
  ["extrabees.species.sodalite"]={"NORMAL","NORMAL"},
  ["extrabees.species.spatial"]={"COLD","NORMAL"},
  ["extrabees.species.sphalerite"]={"NORMAL","NORMAL"},
  ["extrabees.species.sticky"]={"NORMAL","NORMAL"},
  ["extrabees.species.stone"]={"NORMAL","NORMAL"},
  ["extrabees.species.sugar"]={"NORMAL","NORMAL"},
  ["extrabees.species.swamp"]={"NORMAL","DAMP"},
  ["extrabees.species.sweet"]={"NORMAL","NORMAL"},
  ["extrabees.species.tempered"]={"HELLISH","ARID"},
  ["extrabees.species.thriving"]={"NORMAL","NORMAL"},
  ["extrabees.species.tin"]={"NORMAL","NORMAL"},
  ["extrabees.species.titanium"]={"NORMAL","NORMAL"},
  ["extrabees.species.tungstate"]={"NORMAL","NORMAL"},
  ["extrabees.species.unstable"]={"NORMAL","NORMAL"},
  ["extrabees.species.unusual"]={"COLD","NORMAL"},
  ["extrabees.species.virulent"]={"WARM","DAMP"},
  ["extrabees.species.viscous"]={"WARM","DAMP"},
  ["extrabees.species.volcanic"]={"HELLISH","ARID"},
  ["extrabees.species.water"]={"NORMAL","DAMP"},
  ["extrabees.species.white"]={"NORMAL","NORMAL"},
  ["extrabees.species.yellorium"]={"NORMAL","NORMAL"},
  ["extrabees.species.yellow"]={"NORMAL","NORMAL"},
  ["extrabees.species.zinc"]={"NORMAL","NORMAL"},
  ["forestry.speciesAgrarian"]={"NORMAL","NORMAL"},
  ["forestry.speciesAustere"]={"HOT","ARID"},
  ["forestry.speciesAvenging"]={"NORMAL","NORMAL"},
  ["forestry.speciesBoggy"]={"NORMAL","DAMP"},
  ["forestry.speciesCommon"]={"NORMAL","NORMAL"},
  ["forestry.speciesCultivated"]={"NORMAL","NORMAL"},
  ["forestry.speciesDemonic"]={"HELLISH","ARID"},
  ["forestry.speciesDiligent"]={"NORMAL","NORMAL"},
  ["forestry.speciesEdenic"]={"WARM","DAMP"},
  ["forestry.speciesEnded"]={"COLD","NORMAL"},
  ["forestry.speciesExotic"]={"WARM","DAMP"},
  ["forestry.speciesFarmerly"]={"NORMAL","NORMAL"},
  ["forestry.speciesFiendish"]={"HELLISH","ARID"},
  ["forestry.speciesForest"]={"NORMAL","NORMAL"},
  ["forestry.speciesFrugal"]={"HOT","ARID"},
  ["forestry.speciesGlacial"]={"ICY","NORMAL"},
  ["forestry.speciesHermitic"]={"NORMAL","NORMAL"},
  ["forestry.speciesHeroic"]={"NORMAL","NORMAL"},
  ["forestry.speciesIcy"]={"ICY","NORMAL"},
  ["forestry.speciesImperial"]={"NORMAL","NORMAL"},
  ["forestry.speciesIndustrious"]={"NORMAL","NORMAL"},
  ["forestry.speciesLeporine"]={"NORMAL","NORMAL"},
  ["forestry.speciesMajestic"]={"NORMAL","NORMAL"},
  ["forestry.speciesMarshy"]={"NORMAL","DAMP"},
  ["forestry.speciesMeadows"]={"NORMAL","NORMAL"},
  ["forestry.speciesMerry"]={"ICY","NORMAL"},
  ["forestry.speciesMiry"]={"NORMAL","DAMP"},
  ["forestry.speciesModest"]={"HOT","ARID"},
  ["forestry.speciesMonastic"]={"NORMAL","NORMAL"},
  ["forestry.speciesNoble"]={"NORMAL","NORMAL"},
  ["forestry.speciesPhantasmal"]={"COLD","NORMAL"},
  ["forestry.speciesRural"]={"NORMAL","NORMAL"},
  ["forestry.speciesSecluded"]={"NORMAL","NORMAL"},
  ["forestry.speciesSinister"]={"HELLISH","ARID"},
  ["forestry.speciesSpectral"]={"COLD","NORMAL"},
  ["forestry.speciesSteadfast"]={"NORMAL","NORMAL"},
  ["forestry.speciesTipsy"]={"ICY","NORMAL"},
  ["forestry.speciesTricky"]={"NORMAL","NORMAL"},
  ["forestry.speciesTropical"]={"WARM","DAMP"},
  ["forestry.speciesUnweary"]={"NORMAL","NORMAL"},
  ["forestry.speciesValiant"]={"NORMAL","NORMAL"},
  ["forestry.speciesVengeful"]={"NORMAL","NORMAL"},
  ["forestry.speciesVindictive"]={"NORMAL","NORMAL"},
  ["forestry.speciesWintry"]={"ICY","NORMAL"},
  ["gendustry.bee.blue"]={"NORMAL","NORMAL"},
  ["gendustry.bee.brown"]={"NORMAL","NORMAL"},
  ["gendustry.bee.cyan"]={"NORMAL","NORMAL"},
  ["gendustry.bee.gray"]={"NORMAL","NORMAL"},
  ["gendustry.bee.green"]={"NORMAL","NORMAL"},
  ["gendustry.bee.lightblue"]={"NORMAL","NORMAL"},
  ["gendustry.bee.lime"]={"NORMAL","NORMAL"},
  ["gendustry.bee.magenta"]={"NORMAL","NORMAL"},
  ["gendustry.bee.orange"]={"NORMAL","NORMAL"},
  ["gendustry.bee.pink"]={"NORMAL","NORMAL"},
  ["gendustry.bee.purple"]={"NORMAL","NORMAL"},
  ["gendustry.bee.red"]={"NORMAL","NORMAL"},
  ["gendustry.bee.silver"]={"NORMAL","NORMAL"},
  ["gendustry.bee.white"]={"NORMAL","NORMAL"},
  ["gendustry.bee.yellow"]={"NORMAL","NORMAL"},
}
-- Preferred climates below are facts extracted from the installed client mods.
-- They are not a server measurement. Unknowns wait; GUI-confirmed overrides win.
local CLIMATE_PATH='/home/.openbeekeeper-data/climate'
local temperatures={ICY=true,COLD=true,NORMAL=true,WARM=true,HOT=true,HELLISH=true}
local humidities={ARID=true,NORMAL=true,DAMP=true}
local emulators={
  ['Plains Emulation Upgrade']={name='plains',t=0.8,h=0.4},
  ['Jungle Emulation Upgrade']={name='jungle',t=0.95,h=0.9},
  ['Desert Emulation Upgrade']={name='desert',t=2,h=0},
  ['Winter Emulation Upgrade']={name='winter',t=0.25,h=0.8},
  ['Ocean Emulation Upgrade']={name='ocean',t=0.5,h=0.5},
  ['Hell Emulation Upgrade']={name='hell',t=2,h=0,hell=true}
}
local function climateConfiguration()
  local raw=readText(CLIMATE_PATH)
  if not raw then return {schema='CLIMATE1',roles={},manual={},species={}} end
  local ok,v=pcall(require('serialization').unserialize,raw)
  assert(ok and type(v)=='table' and v.schema=='CLIMATE1' and type(v.roles)=='table'
    and type(v.manual)=='table' and type(v.species)=='table','Invalid climate configuration')
  return v
end
local function climateOfApiary(proxy,side)
  local base,heat,wet,signature,score=nil,0,0,{},0
  for slot=3,6 do
    local v,err=read(proxy.getStackInSlot,side,slot); assert(not err,err)
    if alive(v) then
      signature[#signature+1]=slot..':'..tostring(v.name)..':'..tostring(v.damage)..':'..tostring(v.label)..':'..v.size
      if v.label=='Light Upgrade' or v.label=='Seal Upgrade' then score=score+1 end
      local e=emulators[v.label]
      if e then
        if base then return {signature=table.concat(signature,'|'),unknown='multiple emulators'} end
        base=e
      elseif v.label=='Heater Upgrade' then heat=heat+0.25*v.size
      elseif v.label=='Cooler Upgrade' then heat=heat-0.25*v.size
      elseif v.label=='Humidifier Upgrade' then wet=wet+0.25*v.size
      elseif v.label=='Dryer Upgrade' then wet=wet-0.25*v.size end
    end
  end
  local result={signature=table.concat(signature,'|'),profile=base and base.name or 'native',score=score}
  if base then
    local t,h=base.t+heat,base.h+wet
    result.temperature=base.hell and 'HELLISH' or t>1 and 'HOT' or t>0.85 and 'WARM' or t>0.35 and 'NORMAL' or t>0 and 'COLD' or 'ICY'
    result.humidity=h>0.85 and 'DAMP' or h>=0.3 and 'NORMAL' or 'ARID'
  end
  return result
end
local function climateZone(machine,configuration,observed)
  local z={}
  for k,v in pairs(observed or climateOfApiary(machine.module.t,machine.side)) do z[k]=v end
  z.role=configuration.roles[machine.key] or (z.profile~='native' and not z.unknown and 'incubator' or 'unassigned')
  local manual=configuration.manual[machine.key]
  if manual and manual.signature==z.signature then z.temperature=manual.temperature; z.humidity=manual.humidity end
  return z
end
local function preferredClimate(uid,configuration)
  local v=configuration.species[uid] or climateDefaults[uid]
  if v then return v[1],v[2] end
end
local function climateCommand()
  local config=climateConfiguration()
  local rows={}
  local raw=assert(readText(BIND_PATH),'Run bees bind first')
  for line in raw:gmatch('[^\n]+') do
    local address,side,name=line:match('^machine (%S+) (%d+) (%S+)$')
    if name=='gendustry:industrial_apiary' then
      side=tonumber(side)
      local proxy=component.proxy(address)
      assert(read(proxy.getInventoryName,side)==name,'Apiary binding changed')
      rows[#rows+1]={key=address..':'..side,module={t=proxy},side=side}
    end
  end
  table.sort(rows,function(a,b) return a.key<b.key end)
  local action=args[2]
  local changed=false
  if action=='breeding' then
    assert(args[3]=='native','Use bees zones breeding native to explicitly select non-emulated apiaries')
    local count=0
    for _,m in ipairs(rows) do
      local z=climateOfApiary(m.module.t,m.side)
      if z.profile=='native' and not z.unknown then config.roles[m.key]='breeding'; count=count+1 end
    end
    print('Explicitly assigned breeding apiaries:',count); changed=true
  elseif action=='role' or action=='climate' or action=='clear' then
    local m=assert(rows[tonumber(args[3])],'Unknown apiary number; run bees zones')
    if action=='role' then
      assert(args[4]=='breeding' or args[4]=='incubator' or args[4]=='off','Role: breeding/incubator/off')
      config.roles[m.key]=args[4]
    elseif action=='climate' then
      local t,h=tostring(args[4]):upper(),tostring(args[5]):upper()
      assert(temperatures[t] and humidities[h],'Use ICY/COLD/NORMAL/WARM/HOT/HELLISH and ARID/NORMAL/DAMP')
      config.manual[m.key]={temperature=t,humidity=h,signature=climateOfApiary(m.module.t,m.side).signature}
      config.roles[m.key]='incubator'
    else config.manual[m.key]=nil; config.roles[m.key]=nil end
    changed=true
  elseif action=='species' then
    local uid=args[3]; local t,h=tostring(args[4]):upper(),tostring(args[5]):upper()
    assert(type(uid)=='string' and uid~='' and temperatures[t] and humidities[h],'Use bees zones species <UID> <TEMP> <HUMIDITY>')
    config.species[uid]={t,h}; changed=true
  else assert(action==nil,'Use zones, zones breeding native, zones role/climate/clear <number>, zones species <UID> <TEMP> <HUMIDITY>') end
  if changed then
    local fs=require('filesystem')
    if not fs.exists('/home/.openbeekeeper-data') then assert(fs.makeDirectory('/home/.openbeekeeper-data')) end
    local text=require('serialization').serialize(config)
    writeText(CLIMATE_PATH..'.new',text)
    assert(readText(CLIMATE_PATH..'.new')==text,'Climate write verification failed')
    if fs.exists(CLIMATE_PATH) then writeText(CLIMATE_PATH..'.bak',assert(readText(CLIMATE_PATH))); assert(fs.remove(CLIMATE_PATH)) end
    assert(fs.rename(CLIMATE_PATH..'.new',CLIMATE_PATH))
  end
  print('APIARY ZONES / numbers are temporary; saved keys are transposer + side')
  for i,m in ipairs(rows) do
    local z=climateZone(m,config)
    print(i,z.role,z.profile,z.temperature or '?',z.humidity or '?',m.key)
  end
  print('Emulator climate is computed from installed client rules; altitude/server changes may require a GUI-confirmed override.')
  print('No bee or upgrade moved. Breeding and incubation roles are separate.')
end
-- Embedded in openbeekeeper.lua by tools/embed_automation.py; no runtime module dependency.
local function automate()
  local fs=require("filesystem")
  local ser=require("serialization")
  local computer=require("computer")
  local event=require("event")
  local dir="/home/.openbeekeeper-data/"
  local path=dir.."automation"
  local optionsPath=dir..'automation-options'
  local function call(method,...)
    local value,err=read(method,...); assert(not err,err); return value
  end
  local function parse(text,schema)
    local ok,value=pcall(ser.unserialize,text)
    assert(ok and type(value)=="table" and value.schema==schema,"Invalid "..schema.." journal; preserve it")
    return value
  end
  local options=readText(optionsPath)
  options=options and parse(options,'AUTOOPTIONS1') or {schema='AUTOOPTIONS1',batch=64,queue=0,mutations=true,sampling=true}
  assert(type(options.batch)=='number' and options.batch%1==0 and options.batch>=1 and options.batch<=64
    and type(options.queue)=='number' and options.queue%1==0 and options.queue>=0 and options.queue<=128
    and type(options.mutations)=='boolean' and type(options.sampling)=='boolean','Invalid automation options; preserve configuration')
  if args[2]=='config' then
    local key,value=args[3],args[4]
    if key then
      assert(key=='batch' or key=='queue' or key=='mutations' or key=='sampling','Options: batch, queue, mutations, sampling')
      if key=='batch' or key=='queue' then
        value=value=='auto' and key=='queue' and 0 or tonumber(value)
        assert(value and value%1==0 and value>=(key=='batch' and 1 or 0) and value<=(key=='batch' and 64 or 128),'Invalid option value')
      else assert(value=='on' or value=='off','Use on/off'); value=value=='on' end
      options[key]=value
      if not fs.exists(dir) then assert(fs.makeDirectory(dir)) end
      writeText(optionsPath,ser.serialize(options))
    end
    print('AUTO CONFIG batch='..options.batch..'; queue='..(options.queue==0 and 'auto' or options.queue)..'; mutations='..tostring(options.mutations)..'; sampling='..tostring(options.sampling))
    return true
  end
  local raw=readText(path..".new") or readText(path)
  local st=raw and parse(raw,"AUTO1") or {schema="AUTO1",refs={},apiaries={},seq=0,cycles=0,samples=0,mutations=0}
  st.flows=st.flows or {}
  if st.flow then st.seq=st.seq+1; st.flows[tostring(st.seq)]=st.flow; st.flow=nil end
  local flow,currentID
  if args[2]=="status" then
    print("AUTOMATION: apiary cycles="..st.cycles.."; sampled drones="..st.samples.."; mutations="..st.mutations)
    for id,f in pairs(st.flows) do print("FLOW",id,f.mode,f.target,"step="..f.step,f.op and (f.op.key..' '..f.op.phase) or 'queued',f.wait or '') end
    for key,job in pairs(st.apiaries) do print("APIARY",key,job.uid) end
    if st.reset then print('RESET CLEANUP PENDING; use bees auto reset; archive: '..tostring(st.reset.archive)) end
    print(st.wait or "No resource wait recorded."); return true
  end
  assert(args[2]==nil or args[2]=="resume" or args[2]=="reset" or args[2]=='check',"Use bees auto [resume/status/check/config/reset]")
  assert(args[3]==nil or (args[2]=='reset' and args[3]=='empty'),'Use bees auto reset [empty]')
  assert(not st.reset or args[2]=="reset","Reset cleanup is pending; use bees auto reset before resuming")
  assert(not fs.exists(BIND_PENDING) and not fs.exists(pendingPath),"Finish bind/interface recovery first")
  local function save()
    if not fs.exists(dir) then assert(fs.makeDirectory(dir)) end
    local text=ser.serialize(st)
    writeText(path..".new",text); assert(readText(path..".new")==text,"Automation journal verification failed")
    if fs.exists(path) then writeText(path..".bak",assert(readText(path))); assert(fs.remove(path)) end
    assert(fs.rename(path..".new",path))
  end
  local networkIndex,networkError=roleIndex("network",networks)
  assert(networkIndex,networkError)
  local me=networks[networkIndex]
  if st.network then assert(st.network==me.address,"Saved automation ME endpoint changed") end
  st.network=me.address
  local byT,byME,modules,machines,groups={},{},{},{},{apiary={},analyzer={},imprinter={},sampler={},mutatron={}}
  for _,v in ipairs(transposers) do byT[v.address]=v end
  for _,v in ipairs(networks) do byME[v.address]=v end
  local binding=assert(readText(BIND_PATH),"Run bees bind first")
  assert(binding:match("^OpenBeekeeper%-modules%-1\n"),"Invalid module bindings")
  for line in binding:gmatch("[^\n]+") do
    local address,side,iface=line:match("^interface (%S+) (%d+) (%S+)$")
    if address then
      local t=assert(byT[address],"Missing bound transposer "..address)
      local m=assert(byME[iface],"Missing bound interface "..iface)
      side=tonumber(side)
      assert(not modules[address] and side<=5,"Duplicate/invalid module")
      assert(call(t.proxy.getInventoryName,side)=="appliedenergistics2:interface","Changed interface adjacency")
      assert(t.methods.store~=nil and t.methods.compareStackToDatabase~=nil,"Transposer needs store and compareStackToDatabase for exact bee identity")
      modules[address]={address=address,t=t.proxy,m=m.proxy,source=side,interface=iface}
    end
  end
  local kinds={['gendustry:industrial_apiary']='apiary',['forestry:analyzer']='analyzer',
    ['gendustry:imprinter']='imprinter',['gendustry:sampler']='sampler',['gendustry:mutatron']='mutatron'}
  for line in binding:gmatch("[^\n]+") do
    local address,side,name=line:match("^machine (%S+) (%d+) (%S+)$")
    local kind=name and kinds[name]
    if kind then
      local module=assert(modules[address],"Machine has no module")
      side=tonumber(side); local key=address..":"..side
      assert(not machines[key] and side<=5 and call(module.t.getInventoryName,side)==name,"Changed/duplicate machine adjacency")
      local machine={key=key,module=module,side=side,kind=kind}
      machines[key]=machine; groups[kind][#groups[kind]+1]=machine
    end
  end
  if args[2]=='reset' then
    local manuallyEmpty=args[3]=='empty' or (st.reset and st.reset.empty)
    local function refuse(reason)
      error('RESET REFUSED: '..reason..'; use bees auto status and resume existing work with bees auto. Empty machines alone do not prove internal work finished.')
    end
    if not manuallyEmpty and next(st.apiaries) then refuse('active apiary ownership remains in the journal') end
    for id,f in pairs(manuallyEmpty and {} or st.flows) do
      local op=f.op
      if op then
        if op.phase~='feeding' or op.capture or op.handed then refuse('flow '..id..' may be processing internally') end
        for _,feed in ipairs(op.feeds or {}) do
          if feed.armed or feed.loaded then refuse('flow '..id..' has armed/loaded input') end
        end
      end
    end
    local legacy=readText(dir..'apiary-run.new') or readText(dir..'apiary-run')
    if legacy and not parse(legacy,'APIARY1').finished then refuse('unfinished legacy apiary journal; resume/adopt it first') end
    local function waitBuffer(module)
      for attempt=0,15 do
        local occupied=false
        for slot=1,9 do if alive(call(module.t.getStackInSlot,module.source,slot)) then occupied=true end end
        if not occupied then return end
        if attempt==15 then refuse('occupied staging buffer '..module.interface..'; ME is not accepting items') end
        assert(event.pull(1)~='interrupted','Reset paused; repeat bees auto reset to continue')
      end
    end
    local hasInterfaceWork=st.lease or st.resource or next(st.leases or {}) or next(st.resources or {})
    for _,module in pairs(modules) do
      for slot=1,9 do
        if call(module.m.getInterfaceConfiguration,slot)~=nil or alive(call(module.t.getStackInSlot,module.source,slot)) then hasInterfaceWork=true end
      end
    end
    local hasOutputs=false
    local function resetOutputs(kind)
      if kind=='apiary' then return 7,15 elseif kind=='analyzer' then return 9,12
      elseif kind=='mutatron' then return 3,3 else return 4,4 end
    end
    for _,m in pairs(machines) do
      local slots=m.kind=='apiary' and {1,2}
        or m.kind=='analyzer' and {1,3,4,5,6,7,8}
        or m.kind=='mutatron' and {1,2} or {3}
      for _,slot in ipairs(slots) do
        if alive(call(m.module.t.getStackInSlot,m.side,slot)) then refuse('occupied '..m.kind..' '..m.key..' slot '..slot) end
      end
      local lo,hi=resetOutputs(m.kind)
      for slot=lo,hi do if alive(call(m.module.t.getStackInSlot,m.side,slot)) then hasOutputs=true end end
    end
    local databases={}
    for _,entry in ipairs(tools.databases) do databases[entry.address]=entry.proxy end
    local occupied={}
    for id,r in pairs(st.refs) do
      if type(r)~='table' or not databases[r.database] or type(r.slot)~='number' or r.slot<1 or r.slot>81 or r.slot%1~=0 then refuse('invalid/missing owned database reference '..id) end
      local key=r.database..':'..r.slot
      if occupied[key] then refuse('duplicate owned database reference '..key) end
      occupied[key]=true
      local value=call(databases[r.database].get,r.slot)
      if value~=nil then
        local uid,kind=bee(value)
        local matches=r.uid and uid==r.uid and kind==r.kind
          or not r.uid and r.name and value.name==r.name and value.label==r.label
        if not matches then refuse('owned database slot changed externally: '..key..'; preserve its descriptor') end
      end
    end
    if st.lastResetArchive and not st.reset and not hasOutputs and not hasInterfaceWork and not next(st.refs) and not next(st.flows) then
      -- Repair an interrupted final backup write without revisiting old refs.
      save()
      local text=assert(readText(path))
      writeText(path..'.bak',text); assert(readText(path..'.bak')==text,'Reset backup verification failed')
      print('AUTO RESET already complete; archive: '..st.lastResetArchive); return true
    end
    if not st.reset then
      local n=1
      while fs.exists(path..'-reset-'..n..'.index') or fs.exists(path..'-reset-'..n..'.main') or fs.exists(path..'-reset-'..n..'.new') or fs.exists(path..'-reset-'..n..'.bak') do n=n+1 end
      local archive=path..'-reset-'..n
      if not fs.exists(dir) then assert(fs.makeDirectory(dir)) end
      local rows={'OpenBeekeeper-automation-reset-1'}
      for _,variant in ipairs({{path,'.main'},{path..'.new','.new'},{path..'.bak','.bak'}}) do
        local text=readText(variant[1])
        if text then
          writeText(archive..variant[2],text)
          assert(readText(archive..variant[2])==text,'Reset archive verification failed')
          rows[#rows+1]=variant[2]
        end
      end
      local index=table.concat(rows,'\n')..'\n'
      writeText(archive..'.index',index); assert(readText(archive..'.index')==index,'Reset archive index verification failed')
      st.reset={archive=archive,empty=manuallyEmpty or nil}; save()
    end
    local reset=st.reset
    assert(type(reset.archive)=='string' and fs.exists(reset.archive..'.index'),'Reset archive missing; preserve journal')
    local interfaceArchive=reset.archive..'.interfaces'
    if not fs.exists(interfaceArchive) then
      local saved={schema='AUTOINTERFACES1',interfaces={}}
      for _,module in pairs(modules) do
        local slots={}; saved.interfaces[module.interface]=slots
        for slot=1,9 do slots[slot]=call(module.m.getInterfaceConfiguration,slot) end
      end
      local text=ser.serialize(saved)
      writeText(interfaceArchive..'.new',text)
      assert(readText(interfaceArchive..'.new')==text,'Interface archive verification failed')
      assert(fs.rename(interfaceArchive..'.new',interfaceArchive))
    end
    parse(assert(readText(interfaceArchive)),'AUTOINTERFACES1')
    for _,module in pairs(modules) do
      for slot=1,9 do
        if call(module.m.getInterfaceConfiguration,slot)~=nil then call(module.m.setInterfaceConfiguration,slot) end
        assert(call(module.m.getInterfaceConfiguration,slot)==nil,'Cannot clear reset interface '..module.interface..' slot '..slot)
      end
    end
    st.lease=nil; st.leases={}; st.resource=nil; st.resources={}; save()
    for _,module in pairs(modules) do waitBuffer(module) end
    -- Output extraction is idempotent: archive the queue first, move only the
    -- actual remaining stacks, and clear descriptors only after ME accepts them.
    for _,m in pairs(machines) do
      local lo,hi=resetOutputs(m.kind)
      for slot=lo,hi do
        local v=call(m.module.t.getStackInSlot,m.side,slot)
        while alive(v) do
          local moved=call(m.module.t.transferItem,m.side,m.module.source,v.size,slot)
          assert(type(moved)=='number' and moved>=0 and moved<=v.size,'Invalid reset output transfer')
          if moved==0 then
            waitBuffer(m.module)
            moved=call(m.module.t.transferItem,m.side,m.module.source,v.size,slot)
            assert(type(moved)=='number' and moved>0 and moved<=v.size,'Reset output transfer blocked at '..m.key..' slot '..slot..'; fix ME supply and repeat bees auto reset')
          end
          print('RESET RETURN',m.kind,moved,v.label or v.name)
          v=call(m.module.t.getStackInSlot,m.side,slot)
        end
      end
    end
    for _,module in pairs(modules) do waitBuffer(module) end
    if reset.clearing then
      local r=assert(st.refs[reset.clearing],'Reset reference missing')
      if call(databases[r.database].get,r.slot)~=nil then refuse('interrupted database clear is ambiguous at '..r.database..':'..r.slot..'; inspect/archive the descriptor before manually clearing this slot') end
      st.refs[reset.clearing]=nil; reset.clearing=nil; save()
    end
    local ids={}; for id in pairs(st.refs) do ids[#ids+1]=id end; table.sort(ids)
    for _,id in ipairs(ids) do
      local r=st.refs[id]
      reset.clearing=id; save()
      call(databases[r.database].clear,r.slot)
      assert(call(databases[r.database].get,r.slot)==nil,'Could not clear owned database entry; reset remains pending')
      st.refs[id]=nil; reset.clearing=nil; save()
    end
    st={schema='AUTO1',refs={},apiaries={},flows={},seq=0,cycles=0,samples=0,mutations=0,
      network=me.address,migrated=true,climateRouting=true,lastResetArchive=reset.archive}
    save()
    local text=assert(readText(path))
    writeText(path..'.bak',text); assert(readText(path..'.bak')==text,'Reset backup verification failed')
    print('AUTO RESET complete; old journal archived at '..reset.archive..'.*')
    print('Bindings, climate zones and ME roles preserved. Run bees auto to plan from current stock.')
    return true
  end
  for _,kind in ipairs({'apiary','analyzer','imprinter','sampler','mutatron'}) do
    table.sort(groups[kind],function(a,b) if a.side~=b.side then return a.side<b.side end return a.key<b.key end)
  end
  local zones={breeding=0,incubator=0,unassigned=0,off=0}
  local configuration=climateConfiguration()
  for _,m in ipairs(groups.apiary) do
    local zone=climateZone(m,configuration)
    zones[zone.role]=(zones[zone.role] or 0)+1
  end
  local capabilities={queen=#groups.analyzer>0 and zones.incubator>0}
  local prepare=#groups.analyzer>0 and #groups.imprinter>0
  capabilities.multiply=prepare and zones.breeding>0
  capabilities.restore=capabilities.multiply
  capabilities.mutate=prepare and options.mutations and #groups.mutatron>0 and zones.incubator>0
  capabilities.sample=prepare and options.sampling and #groups.sampler>0
  print('MODULES apiaries='..#groups.apiary..' breeding='..zones.breeding..' incubator='..zones.incubator..' unassigned='..zones.unassigned..'; analyzers='..#groups.analyzer..' imprinters='..#groups.imprinter..' mutatrons='..#groups.mutatron..' samplers='..#groups.sampler..' databases='..#tools.databases)
  print('ENABLED breeding='..tostring(capabilities.multiply)..' mutations='..tostring(capabilities.mutate)..' sampling='..tostring(capabilities.sample)..'; analyzer batch='..options.batch)
  if zones.unassigned>0 then print('Unassigned apiaries do not run; configure bees zones before starting.') end
  if args[2]=='check' then
    for _,m in pairs(machines) do
      local slots={}
      local last=m.kind=='apiary' and 15 or m.kind=='analyzer' and 12 or 4
      for slot=1,last do
        local v=call(m.module.t.getStackInSlot,m.side,slot)
        if alive(v) then slots[#slots+1]=slot..'='..tostring(v.label or v.name)..' x'..v.size end
      end
      local owner=st.apiaries[m.key] and 'apiary cycle' or 'none'
      for id,f in pairs(st.flows) do
        if f.op and f.op.key==m.key then owner='flow '..id..' '..f.op.phase end
      end
      print('INVENTORY',m.kind,m.key,#slots>0 and table.concat(slots,'; ') or 'empty','owner='..owner)
      if m.kind=='imprinter' then
        local template=call(m.module.t.getStackInSlot,m.side,1)
        if not alive(template) or template.name~='gendustry:gene_template' then print('MISSING template at '..m.key) end
      end
    end
    print('Read-only check. Change topology with bees bind; assign roles with bees zones; policy with bees auto config.')
    return true
  end
  local names,aliases,recipes={},{},{}
  for _,v in ipairs(catalogues) do
    local list=read(v.proxy.listAllSpecies)
    if type(list)=="table" then
      for _,x in pairs(list) do if type(x)=="table" and x.uid then names[x.uid]=x.name or x.uid end end
      recipes=call(v.proxy.getBeeBreedingData) or {}; break
    end
  end
  if not next(names) then print('Forestry catalogue unavailable: existing species can breed; new mutation recipes are unavailable.') end
  local stock,samples={},{}
  local function adjust(v,count)
    local uid,kind=bee(v)
    if uid then
      local e=stock[uid] or {uid=uid,princess=0,drone=0,queen=0}; stock[uid]=e
      e[kind]=math.max(0,e[kind]+count)
      if count>0 then e[kind..'Item']=v end
    elseif count>0 then
      local g=gene(v)
      if g and g.chromosome==0 then samples[g.allele]='G' end
    end
  end
  local function item(m,slot) return call(m.module.t.getStackInSlot,m.side,slot) end
  local function outputSlots(kind)
    if kind=='apiary' then return 7,15 elseif kind=='analyzer' then return 9,12
    elseif kind=='mutatron' then return 3,3 else return 4,4 end
  end
  local waiting={}
  local function warn(message)
    local key=currentID or 'global'
    if waiting[key]~=message then
      waiting[key]=message; st.wait=message; if flow then flow.wait=message end
      print("WAIT "..message); save()
    end
  end
  local function tick()
    assert(event.pull(1)~="interrupted","Paused by Ctrl+C; bees auto resumes")
  end
  local function db(ref) return component.proxy(ref.database) end
  local function allocate()
    local owned={}
    for _,r in pairs(st.refs) do owned[r.database..":"..r.slot]=true end
    for _,e in ipairs(tools.databases) do
      for slot=1,81 do
        local value,err=read(e.proxy.get,slot)
        if err then break end
        if value==nil and not owned[e.address..":"..slot] then
          st.seq=st.seq+1; local id=tostring(st.seq)
          st.refs[id]={database=e.address,slot=slot}; save(); return id
        end
      end
    end
    error("No free OC database entry")
  end
  local function release(id)
    if not id or not st.refs[id] then return end
    local r=st.refs[id]; call(db(r).clear,r.slot)
    assert(call(db(r).get,r.slot)==nil,"Could not clear owned database entry")
    st.refs[id]=nil; save()
  end
  st.leases=st.leases or {}
  st.resources=st.resources or {}
  local function cleanLease(interface)
    if st.lease then
      st.leases[st.lease.interface]=st.lease; st.lease=nil; save()
    end
    local keys={}
    for key in pairs(st.leases) do if not interface or key==interface then keys[#keys+1]=key end end
    for _,key in ipairs(keys) do
      local p=component.proxy(key)
      call(p.setInterfaceConfiguration,9)
      assert(call(p.getInterfaceConfiguration,9)==nil,"Could not clear automation request 9")
      st.leases[key]=nil; save()
    end
  end
  local function emptyBuffer(module)
    for slot=1,9 do if alive(call(module.t.getStackInSlot,module.source,slot)) then return false end end
    return true
  end
  local function matches(v,ref)
    if not alive(v) then return false end
    if ref.uid then local uid,kind=bee(v); return uid==ref.uid and kind==ref.kind end
    return v.name==ref.name and v.label==ref.label
  end
  -- Per-interface requests are polled, never slept on. Database entries retain
  -- exact item identity; one owner serializes every use of a shared interface.
  local function deliver(m,id,destination,count,intention)
    local r=assert(st.refs[id],"Missing owned bee reference")
    local interface=m.module.interface
    local owner=id..':'..m.key..':'..destination
    local lease=st.leases[interface]
    if lease and lease.owner~=owner then return nil end
    if not lease then
      if not emptyBuffer(m.module) then return nil end
      st.leases[interface]={interface=interface,owner=owner,since=computer.uptime()}; save()
      assert(call(m.module.m.setInterfaceConfiguration,9,r.database,r.slot,count),"Interface request failed")
      lease=st.leases[interface]
    end
    local source
    for slot=1,9 do
      local v=call(m.module.t.getStackInSlot,m.module.source,slot)
      if alive(v) then
        assert(not source and matches(v,r) and v.size<=count,"Unexpected item in staging interface")
        assert(call(m.module.t.compareStackToDatabase,m.module.source,slot,r.database,r.slot,true),"Staged item NBT differs from the owned descriptor")
        source=slot
      end
    end
    if not source then
      if computer.uptime()-lease.since<15 then return nil end
      cleanLease(interface)
      return false,"Exact item not delivered within 15 seconds: "..tostring(r.uid or r.name).." / "..tostring(r.kind or r.label).."; check ME stock, exact NBT and interface supply. Request cancelled; other jobs continue."
    end
    if m.kind=='analyzer' and count>1 and not intention.batchPeers then
      intention.batchPeers={}
      for other,ref in pairs(st.refs) do
        if other~=id and ref.ready and not ref.analyzed and ref.uid==r.uid and ref.kind==r.kind
            and call(m.module.t.compareStackToDatabase,m.module.source,source,ref.database,ref.slot,true) then
          intention.batchPeers[#intention.batchPeers+1]=other
        end
      end
    end
    intention.armed=true; save()
    local v=call(m.module.t.getStackInSlot,m.module.source,source)
    local moved=call(m.module.t.transferItem,m.module.source,m.side,v.size,source,destination)
    assert(type(moved)=="number" and moved>=0 and moved<=v.size,"Invalid loading result")
    if moved==0 then intention.armed=false; save()
    else
      adjust(v,-moved); r.inME=false
      for _,other in ipairs(intention.batchPeers or {}) do if st.refs[other] then st.refs[other].inME=false end end
      save()
    end
    cleanLease(interface)
    return moved>0
  end
  local function reference(v)
    local id=allocate(); local r=st.refs[id]
    r.filter={name=v.name,label=v.label}; r.uid,r.kind=bee(v); r.name=v.name; r.label=v.label; r.available=v.size
    save(); return id
  end
  local function materialize(id)
    local r=st.refs[id]
    if r.ready then return true end
    call(db(r).clear,r.slot)
    call(me.proxy.store,r.filter,r.database,r.slot,1)
    local v=call(db(r).get,r.slot)
    if not matches(v,r) then warn('ME needs '..tostring(r.uid)..' / '..tostring(r.kind)); return false end
    r.analyzed=type(v.individual)=='table' and v.individual.isAnalyzed==true
    r.ready=true; r.inME=true; save(); return true
  end
  local resourceRetry={}
  local function resource(m,slot,label)
    local key=m.key..':'..slot
    local job=st.resources[key]
    if alive(item(m,slot)) and not job then return true end
    if not job then
      if resourceRetry[key] and computer.uptime()<resourceRetry[key] then return false end
      local id=allocate(); local r=st.refs[id]
      st.resources[key]={ref=id,intention={}}; save(); job=st.resources[key]
      call(me.proxy.store,{label=label},r.database,r.slot,1)
      local v=call(db(r).get,r.slot)
      if not alive(v) or v.label~=label then
        st.resources[key]=nil; save(); release(id)
        resourceRetry[key]=computer.uptime()+ME_INTERVAL; warn('ME needs '..label); return false
      end
      r.name=v.name; r.label=v.label; r.uid=nil; r.kind=nil; r.ready=true; save()
    end
    local r=st.refs[job.ref]
    local moved,reason
    if alive(item(m,slot)) or job.intention.armed then moved=true
    else moved,reason=deliver(m,job.ref,slot,16,job.intention) end
    if moved==nil then return false end
    if reason then warn(reason); resourceRetry[key]=computer.uptime()+ME_INTERVAL end
    local lease=st.leases[m.module.interface]
    if lease and lease.owner==job.ref..':'..m.key..':'..slot then cleanLease(m.module.interface) end
    st.resources[key]=nil; save(); release(job.ref)
    return alive(item(m,slot))
  end
  local function fluidReady(m)
    if m.module.t.getFluidInTank then
      local tanks=read(m.module.t.getFluidInTank,m.side)
      if type(tanks)=="table" then
        local amount=tonumber(tanks.amount)
        for _,tank in pairs(tanks) do if type(tank)=="table" and tonumber(tank.amount) then amount=(amount or 0)+tank.amount end end
        if amount and amount<(m.kind=='analyzer' and 100 or 1) then
          warn(m.kind=='analyzer' and "Analyzer needs liquid honey (100 mB per unanalyzed bee)" or "Mutatron needs mutagen")
          return false
        end
      end
    end
    return true
  end
  local function supplies(m)
    if m.kind=='analyzer' then return fluidReady(m) end
    if m.kind=='imprinter' then
      local template=item(m,1)
      if not alive(template) or template.name~='gendustry:gene_template' then warn("Imprinter needs the user template without species/effect"); return false end
      return resource(m,2,'Genetics Labware')
    elseif m.kind=='sampler' then return resource(m,1,'Blank Gene Sample') and resource(m,2,'Genetics Labware')
    elseif m.kind=='mutatron' then return fluidReady(m) and resource(m,4,'Genetics Labware') end
    return true
  end
  local availability,zoneCache={},{}
  local function free(m)
    if st.apiaries[m.key] then return false end
    for id,f in pairs(st.flows) do if id~=currentID and f.op and f.op.key==m.key then return false end end
    if m.kind=='apiary' and availability[m.key]~=nil then return availability[m.key] end
    local lo,hi=outputSlots(m.kind)
    for slot=lo,hi do if alive(item(m,slot)) then return false end end
    if m.kind=='apiary' or m.kind=='mutatron' then
      local result=not alive(item(m,1)) and not alive(item(m,2))
      if m.kind=='apiary' then availability[m.key]=result end
      return result
    end
    if m.kind=='analyzer' then
      if alive(item(m,1)) then return false end
      for slot=3,8 do if alive(item(m,slot)) then return false end end
      return true
    end
    return not alive(item(m,3))
  end
  local function find(kind,wanted,purpose)
    local best,score
    local configuration=kind=='apiary' and climateConfiguration()
    local requiredT,requiredH
    if purpose=='incubator' then requiredT,requiredH=preferredClimate(wanted and wanted.uid,configuration) end
    if purpose=='incubator' and not requiredT then return nil,nil,'Unknown preferred climate for '..tostring(wanted and wanted.uid)..'; use bees zones species <UID> <TEMP> <HUMIDITY>' end
    for _,m in ipairs(groups[kind]) do
      local roleMatches=true
      if kind=='apiary' then
        local cache=zoneCache[m.key]
        local epoch=math.floor(computer.uptime()/5)
        if not cache or cache.epoch~=epoch then cache={epoch=epoch,value=climateOfApiary(m.module.t,m.side)}; zoneCache[m.key]=cache end
        local zone=climateZone(m,configuration,cache.value)
        roleMatches=zone.role==purpose and (purpose=='breeding' or (zone.temperature==requiredT and zone.humidity==requiredH))
      end
      if kind=='analyzer' and emptyBuffer(m.module) then
        local owned,duplicate,reserved=false,false,{}
        for id,f in pairs(st.flows) do
          if id~=currentID and f.op and f.op.key==m.key then
            owned=true
            for _,feed in ipairs(f.op.feeds) do
              local ref=st.refs[feed.ref]
              if ref and wanted and ref.uid==wanted.uid and ref.kind==wanted.kind then duplicate=true end
              if not feed.loaded then reserved[feed.slot]=true end
            end
          end
        end
        if not duplicate and (owned or free(m)) then
          for slot=3,8 do if not reserved[slot] and not alive(item(m,slot)) then return m,slot end end
        end
      elseif kind~='analyzer' and roleMatches and free(m) and emptyBuffer(m.module) then
        local climate=kind=='apiary' and zoneCache[m.key].value.score or 0
        if not best or climate>score then best=m; score=climate end
      end
    end
    return best,nil,kind=='apiary' and ('No free '..tostring(purpose)..' zone'..(requiredT and ' '..requiredT..'/'..requiredH or '')..'; inspect bees zones') or nil
  end
  local function returnSlot(m,slot)
    if st.leases[m.module.interface] then return false end
    local v=item(m,slot); if not alive(v) then return true end
    local moved=call(m.module.t.transferItem,m.side,m.module.source,v.size,slot)
    assert(type(moved)=="number" and moved>=0 and moved<=v.size,"Invalid bulk return")
    if moved>0 then adjust(v,moved); print("RETURN",m.kind,moved,v.label or v.name) end
    return not alive(item(m,slot))
  end
  local function flowOwns(key)
    for _,f in pairs(st.flows) do if f.op and f.op.key==key then return true end end
    return false
  end
  -- Output slots and leftover drones do not imply an active machine job.
  -- Never touch the drone while a flow is still loading its princess.
  local function serviceUnowned()
    for _,m in pairs(machines) do
      if not flowOwns(m.key) and not st.apiaries[m.key] then
        local lo,hi=outputSlots(m.kind)
        for slot=lo,hi do returnSlot(m,slot) end
        if m.kind=='apiary' then
          local parent=item(m,1)
          if not alive(parent) then
            local _,kind=bee(item(m,2) or {})
            if kind=='drone' then returnSlot(m,2) end
          else
            local uid,kind=bee(parent)
            if kind=='queen' then st.apiaries[m.key]={uid=uid,puid=uid}; save() end
          end
        end
      end
    end
  end
  local function serviceApiaries()
    for key,job in pairs(st.apiaries) do
      local m=assert(machines[key],"Saved apiary is missing")
      local empty=true
      for slot=7,15 do if not returnSlot(m,slot) then empty=false end end
      if not alive(item(m,1)) and not flowOwns(key) then
        local _,kind=bee(item(m,2) or {})
        if kind=='drone' and not returnSlot(m,2) then empty=false end
      end
      if not alive(item(m,1)) and not alive(item(m,2)) and empty then
        st.apiaries[key]=nil; st.cycles=st.cycles+1; save()
        print("APIARY COMPLETE",key,job.uid)
      end
    end
  end
  local function finishFlow()
    local f=assert(flow)
    waiting[currentID]=nil
    st.flows[currentID]=nil; flow=nil; save()
    release(f.p); release(f.d)
  end
  local function copyOutput(m,slot,id)
    local r=assert(st.refs[id])
    assert(call(m.module.t.store,m.side,slot,r.database,r.slot),"Cannot copy exact output descriptor")
  end
  local deliveryRetry={}
  local function serviceFlow()
    local f=flow; if not f then return end
    if f.reselect then
      if st.needFresh then return end
      f.reselect=nil; save()
    end
    if deliveryRetry[currentID] and computer.uptime()<deliveryRetry[currentID] then return end
    if f.pendingP then f.p=reference(f.pendingP); f.pendingP=nil; save() end
    if f.pendingD then f.d=reference(f.pendingD); f.pendingD=nil; save() end
    local step=f.steps[f.step]
    if not step then finishFlow(); return end
    local selected=(step=='queen' or step:sub(-1)=='P') and f.p or f.d
    if step~='mate' and not materialize(selected) then
      if not f.op then
        print('REPLAN',f.target,'bee no longer present in live ME lookup')
        st.needFresh=true; finishFlow()
      end
      return
    end
    if step:match('^analyze') and st.refs[selected].analyzed and not f.op then
      f.step=f.step+1; save(); return
    end
    local kind=step:match('^analyze') and 'analyzer' or step:match('^imprint') and 'imprinter'
      or step=='sample' and 'sampler' or step=='mate' and (f.mode=='mutate' and 'mutatron' or 'apiary') or 'apiary'
    if not f.op then
      local wanted=st.refs[(step=='queen' or step:sub(-1)=='P') and f.p or f.d]
      local purpose=kind=='apiary' and (step=='queen' and 'incubator' or 'breeding') or nil
      if purpose=='breeding' then
        assert(st.refs[f.p].analyzed and st.refs[f.p].imprinted and st.refs[f.d].analyzed and st.refs[f.d].imprinted,'Both breeding parents must be analyzed and imprinted')
      elseif purpose=='incubator' then assert(wanted and wanted.analyzed,'Queen must pass analyzer before climate routing') end
      local m,analysisSlot,reason=find(kind,wanted,purpose)
      if not m then warn(reason or "No empty "..kind); return end
      if not supplies(m) then return end
      local feeds={}
      if step=='mate' then
        feeds={{ref=f.d,slot=2},{ref=f.p,slot=1}}
      elseif step=='queen' then feeds={{ref=f.p,slot=1}}
      else
        local id=step:sub(-1)=='P' and f.p or f.d
        local r=st.refs[id]
        feeds={{ref=id,slot=analysisSlot or 3,count=kind=='analyzer' and r.kind=='drone' and math.min(options.batch,r.available or 1) or 1}}
      end
      f.op={key=m.key,feeds=feeds,phase='feeding',ticks=0}; f.wait=nil; waiting[currentID]=nil; st.wait=nil; save()
      if kind=='mutatron' and f.conditions and #f.conditions>0 then
        print('CONDITIONAL ATTEMPT',f.target,table.concat(f.conditions,'; '),'requirements are not verified by OC; server decides availability')
      end
    end
    local op=f.op; local m=assert(machines[op.key],"Saved processor is missing")
    if op.phase=='feeding' then
      if not supplies(m) then
        local started=false
        for _,feed in ipairs(op.feeds) do if feed.armed or feed.loaded then started=true end end
        if not started then f.op=nil; save() end
        return
      end
      -- A mating pair cannot have started if its princess was never sent.
      -- Recheck the staged drone instead of trusting a stale loaded flag.
      if step=='mate' and not op.feeds[2].armed and not op.feeds[2].loaded then
        local drone=op.feeds[1]
        if drone.loaded and not alive(item(m,2)) then drone.loaded=nil; drone.armed=nil; save() end
      end
      for _,feed in ipairs(op.feeds) do
        if not feed.loaded then
          local r=st.refs[feed.ref]; local v=item(m,feed.slot)
          if alive(v) then
            local _,physicalKind=bee(v)
            local mated=step=='mate' and feed.slot==1 and feed.armed and physicalKind=='queen'
            assert(mated or matches(v,r),"Unexpected bee in owned input")
            assert(feed.armed,"Input occupied before this flow loaded it; inspect bees auto check")
            feed.loaded=true; save()
          elseif feed.armed and not (step=='mate' and feed.slot==2 and not op.feeds[2].armed) then
            -- The triggering item may be internal/already output. Never replay it.
            feed.loaded=true; save()
          else
            local delivered,reason=deliver(m,feed.ref,feed.slot,feed.count or 1,feed)
            if delivered==nil then return end
            if not delivered then
              op.blockedSince=op.blockedSince or computer.uptime(); save()
              if not reason and computer.uptime()-op.blockedSince>=ME_INTERVAL then
                reason='Input transfer remains blocked at '..m.key..' slot '..feed.slot..'; releasing unstarted work'
              end
              if reason then
                deliveryRetry[currentID]=computer.uptime()+ME_INTERVAL
                local started=false
                for _,input in ipairs(op.feeds) do if input.armed or input.loaded then started=true end end
                if started and step=='mate' and feed.slot==1 and not feed.armed and not feed.loaded
                    and not alive(item(m,1)) then
                  local drone=op.feeds[1]
                  if returnSlot(m,2) then
                    drone.loaded=nil; drone.armed=nil
                    local ref=st.refs[drone.ref]; ref.inME=true
                    started=false; save()
                  end
                end
                if not started then
                  -- Captivity generations are not bee identity. Reselect the
                  -- current live variant, then repeat its preparation; never
                  -- carry analyzed/imprinted claims across an NBT substitution.
                  local previous=call(db(r).get,r.slot)
                  r.filter={name=previous and previous.name or r.name,label=previous and previous.label or r.label}
                  r.ready=nil; r.analyzed=nil; r.imprinted=nil; r.inME=true
                  local suffix=feed.ref==f.p and 'P' or 'D'
                  for index,value in ipairs(f.steps) do
                    if value=='analyze'..suffix then f.step=index; break end
                  end
                  f.op=nil; f.reselect=true; st.needFresh=true
                  print('REPLAN',f.target,'refresh live bee variant after failed exact request',reason)
                  save(); return
                end
              end
              warn(reason or ("Input transfer blocked at "..m.key)); return
            end
            deliveryRetry[currentID]=nil; op.blockedSince=nil
            feed.loaded=true; save()
          end
        end
      end
      op.phase='working'; save()
      print("PROCESS",step,m.key,f.target)
    end
    if kind=='apiary' then
      if not op.handed then
        st.apiaries[m.key]={uid=st.refs[f.p].uid,target=f.target,puid=st.refs[f.p].uid,duid=f.d and st.refs[f.d].uid,fertility=st.refs[f.p].fertility}
        op.handed=true; save()
      end
      finishFlow(); return
    end
    local lo,hi=outputSlots(kind)
    if not op.capture then
      for slot=lo,hi do
        local v=item(m,slot)
        if alive(v) then
          local uid,k=bee(v)
          local failed=v.name=='gendustry:waste' and (kind=='imprinter' or kind=='mutatron')
          local id=step:sub(-1)=='P' and f.p or f.d
          local expected=id and st.refs[id]
          if kind~='analyzer' or (expected and uid==expected.uid and k==expected.kind) then
          if failed then id=nil
          elseif kind=='mutatron' then
            assert(k=='queen' and type(uid)=='string',"Mutatron output is not an identifiable queen")
            id=f.p
          elseif kind=='sampler' then assert(v.name=='gendustry:gene_sample',"Unexpected sampler output")
          else
            local r=assert(st.refs[id]); assert(uid==r.uid and k==r.kind,"Processor changed bee species/type; template may include species")
            if kind=='analyzer' then assert(type(v.individual)=='table' and v.individual.isAnalyzed==true,"Analyzer output is not marked analyzed") end
          end
          op.capture={slot=slot,ref=not failed and kind~='sampler' and id or nil,uid=uid,kind=k,label=v.label,name=v.name,tagGene=gene(v),failed=failed}; save()
          break
          end
        end
      end
    end
    if op.capture then
      local capture=op.capture
      local physical=item(m,capture.slot)
      if alive(physical) then
        local uid,k=bee(physical)
        local same=capture.ref and uid==capture.uid and k==capture.kind
          or not capture.ref and physical.name==capture.name and physical.label==capture.label
        if same then
          if st.leases[m.module.interface] then return end
          if capture.ref then
            copyOutput(m,capture.slot,capture.ref)
            if kind=='analyzer' then
              for _,other in ipairs(op.feeds[1].batchPeers or {}) do
                if st.refs[other] then
                  copyOutput(m,capture.slot,other)
                  st.refs[other].ready=true; st.refs[other].analyzed=true; st.refs[other].inME=true; st.refs[other].filter=nil
                end
              end
            end
            capture.copied=true; save()
          end
          if not returnSlot(m,capture.slot) then return end
        else
          assert(capture.copied,'Owned output changed before capture completed')
        end
      end
      if capture.ref then
        local r=st.refs[capture.ref]; local v=call(db(r).get,r.slot)
        local uid,k=bee(v or {})
        assert(uid==capture.uid and k==capture.kind,"Captured output descriptor missing")
        r.uid=uid; r.kind=k; r.filter=nil; r.ready=true; r.inME=true; save()
        local active=type(v.individual)=='table' and v.individual.active
        local fertility=type(active)=='table' and tonumber(active.fertility)
        if fertility and fertility>=1 and fertility<=64 then r.fertility=fertility; save() end
        if kind=='mutatron' then r.analyzed=nil; r.imprinted=nil; save()
        elseif kind=='analyzer' then r.analyzed=true; save()
        elseif kind=='imprinter' then r.analyzed=true; r.imprinted=true; save() end
      end
      if capture.failed then
        if not capture.applied then st.losses=(st.losses or 0)+1; capture.applied=true; save() end
        print('GENETIC LOSS',kind,f.target,'waste returned; replanning from actual stock')
        finishFlow()
      elseif kind=='mutatron' then
        st.mutations=st.mutations+1
        print("MUTATION RESULT",capture.uid,"wanted",f.target,capture.uid==f.target and 'MATCH' or 'SIDE SPECIES SAVED')
        local oldDrone=f.d; f.d=nil; f.target=capture.uid; f.mode='queen'; f.steps={'analyzeP','queen'}; f.step=1; f.op=nil; save(); release(oldDrone)
      elseif kind=='sampler' then
        if not capture.applied then
          st.samples=st.samples+1; capture.applied=true; save()
          print("SAMPLE RESULT",capture.label or capture.name,"donor",f.target)
        end
        finishFlow()
      else f.step=f.step+1; f.op=nil; save() end
    else
      op.ticks=op.ticks+1
      if op.ticks%120==0 then warn("Waiting for "..kind.." output at "..m.key.."; check power, fluid and machine error. Input is not replayed.") end
    end
  end
  local function collectStock(items)
    local stock,samples={},{}
    for _,v in pairs(items) do
      if alive(v) then
        local uid,k=bee(v)
        if uid then
          names[uid]=names[uid] or (v.individual or {}).displayName or uid
          local e=stock[uid] or {uid=uid,princess=0,drone=0,queen=0}; stock[uid]=e
          e[k]=e[k]+v.size; e[k..'Item']=v
        end
        local g=gene(v); if g and g.chromosome==0 then samples[g.allele]='G' end
      end
    end
    aliases={}
    for uid,name in pairs(names) do
      if aliases[name]==nil then aliases[name]=uid elseif aliases[name]~=uid then aliases[name]=false end
    end
    for _,v in pairs(items) do
      if alive(v) and v.name=='gendustry:gene_sample' and not gene(v) then
        local name=tostring(v.label or ''):match('^Bee Sample %- Species: (.+)$')
        local uid=name and aliases[name]
        if uid and not samples[uid] then samples[uid]='L' end
      end
    end
    return stock,samples
  end
  local function start(mode,target,p,d,conditions)
    local f={mode=mode,target=target,step=1,steps=mode=='sample' and {'analyzeD','imprintD','sample'}
      or mode=='queen' and {'analyzeP','queen'} or {'analyzeP','imprintP','analyzeD','imprintD','mate'}}
    f.pendingP=p; f.pendingD=d; f.conditions=conditions; st.seq=st.seq+1; st.flows[tostring(st.seq)]=f; st.wait=nil; save(); print("FLOW",mode,target)
  end
  local function choose(stock,samples,category)
    local observed=stock
    local incoming,predicted,load={},{},{}
    for _,j in pairs(st.apiaries) do
      if not j.orphan then
        incoming[j.uid]=true; if j.target then incoming[j.target]=true end
        predicted[j.uid]=(predicted[j.uid] or 0)+(j.fertility or 4)
        load[j.uid]=(load[j.uid] or 0)+1
      end
    end
    local available={}
    for uid,e in pairs(stock) do local c={}; for k,v in pairs(e) do c[k]=v end; c.stockDrone=e.drone; available[uid]=c end
    for _,f in pairs(st.flows) do
      incoming[f.target]=true; load[f.target]=(load[f.target] or 0)+1
      for _,role in ipairs({'p','d'}) do
        local r=f[role] and st.refs[f[role]]
        local pending=f[role=='p' and 'pendingP' or 'pendingD']
        local uid,k
        if r then uid,k=r.uid,r.kind elseif pending then uid,k=bee(pending) end
        if uid and available[uid] and (not r or r.inME~=false) then available[uid][k]=math.max(0,available[uid][k]-1) end
      end
      if f.mode=='multiply' or f.mode=='queen' then
        local r=f.p and st.refs[f.p]
        local fertility=r and r.fertility or 4
        local drone=f.d and st.refs[f.d]
        local cost=(f.mode=='queen' or (drone and drone.inME==false)) and 0 or 1
        predicted[f.target]=(predicted[f.target] or 0)+math.max(0,fertility-cost)
      end
    end
    stock=available
    local list={}; for _,e in pairs(stock) do list[#list+1]=e end
    table.sort(list,function(a,b)
      if (load[a.uid] or 0)~=(load[b.uid] or 0) then return (load[a.uid] or 0)<(load[b.uid] or 0) end
      return a.uid<b.uid
    end)
    local function idle(e) return e~=nil end
    local function target(e) return (samples[e.uid] or not capabilities.sample) and DRONE_TARGET or DRONE_TARGET+38 end
    for _,e in ipairs(list) do
      if category=='queen' and capabilities.queen and e.queen>0 and (e.stockDrone+(predicted[e.uid] or 0)<target(e) or e.princess==0) then start('queen',e.uid,e.queenItem); return true end
    end
    for _,e in ipairs(list) do
      if category=='breed' and capabilities.multiply and e.princess>0 and e.drone>0 and e.stockDrone+(predicted[e.uid] or 0)<target(e) then start('multiply',e.uid,e.princessItem,e.droneItem); return true end
    end
    for _,e in ipairs(list) do
      if category=='sample' and capabilities.sample and idle(e) and not samples[e.uid] and e.drone>DRONE_TARGET then start('sample',e.uid,nil,e.droneItem); return true end
    end
    for _,e in ipairs(list) do
      if category=='breed' and capabilities.restore and not incoming[e.uid] and (e.drone<DRONE_TARGET or not samples[e.uid]) then
        if e.princess==0 and e.queen==0 and e.drone>=1 then
          for _,base in ipairs(list) do
            if idle(base) and base.uid~=e.uid and base.princess>0 and (base.princess>1 or base.drone>=DRONE_TARGET) then
              if e.drone==1 then print('RESTORE USING LAST DRONE',e.uid,'loss risk accepted; actual offspring will be inspected') end
              start('restore',e.uid,base.princessItem,e.droneItem); return true
            end
          end
        elseif e.princess>0 and e.drone==0 then
          for _,donor in ipairs(list) do
            if idle(donor) and donor.uid~=e.uid and donor.drone>=2 then start('restore',e.uid,e.princessItem,donor.droneItem); return true end
          end
        end
      end
    end
    if category~='mutate' or not capabilities.mutate then return false end
    local candidates={}
    local function resolve(value) return names[value] and value or aliases[value] end
    for _,recipe in pairs(recipes) do
      if type(recipe)=='table' then
        local a,b,result=resolve(recipe.allele1),resolve(recipe.allele2),resolve(recipe.result)
        local existing=result and stock[result]
        -- A collected gene does not replace the living stock target. Recreate
        -- extinct lines, but let existing bees and in-flight jobs restore them.
        local living=result and observed[result]
        local extinct=not living or living.princess+living.drone+living.queen==0
        if a and b and result and not incoming[result] and (not samples[result] or extinct) and (not existing or existing.princess==0) then
          local function pair(p,d)
            if idle(p) and idle(d) and p.princess>0 and d.drone>=2 and (p.princess>1 or p.drone>=DRONE_TARGET) then
              local conditions={}
              if type(recipe.specialConditions)=='table' then for _,v in pairs(recipe.specialConditions) do conditions[#conditions+1]=tostring(v) end
              elseif hasConditions(recipe) then conditions[1]=tostring(recipe.specialConditions) end
              table.sort(conditions)
              candidates[#candidates+1]={p=p,d=d,result=result,conditions=conditions}
            end
          end
          pair(stock[a],stock[b]); if a~=b then pair(stock[b],stock[a]) end
        end
      end
    end
    table.sort(candidates,function(a,b) local x=a.result..a.p.uid..a.d.uid; local y=b.result..b.p.uid..b.d.uid; return x<y end)
    -- Round robin prevents an unlucky common side result starving other branches.
    if #candidates>0 then
      st.recipeCursor=(st.recipeCursor or 0)%#candidates+1
      local c=candidates[st.recipeCursor]; start('mutate',c.result,c.p.princessItem,c.d.droneItem,c.conditions); return true
    end
    return false
  end
  local function migrate()
    if st.migrated then return end
    local text=readText(dir..'apiary-run.new') or readText(dir..'apiary-run')
    if text then
      local old=parse(text,'APIARY1')
      if not old.finished then
        if old.lease then
          local p=component.proxy(old.lease.interface)
          for slot=1,2 do call(p.setInterfaceConfiguration,slot); assert(call(p.getInterfaceConfiguration,slot)==nil,'Legacy request cleanup failed') end
          local pDB=component.proxy(old.lease.database)
          for _,slot in ipairs(old.lease.slots) do call(pDB.clear,slot) end
        end
        for key,j in pairs(old.jobs) do
          assert(machines[key] and machines[key].kind=='apiary','Legacy apiary missing')
          local orphan=j.phase=='loading' and not alive(item(machines[key],1)) and alive(item(machines[key],2))
          st.apiaries[key]={uid=j.uid,puid=j.uid,duid=j.uid,orphan=orphan}
          if orphan then print('LEGACY PARTIAL INPUT',key,'preserved; no unprepared princess will be added') end
        end
        save()
        old.finished=true; old.migratedTo=path
        writeText(dir..'apiary-run',ser.serialize(old))
        if fs.exists(dir..'apiary-run.new') then assert(fs.remove(dir..'apiary-run.new')) end
        print('Existing apiary jobs adopted; partial inputs are preserved, never blindly completed.')
      end
    end
    st.migrated=true; save()
  end
  local function perform()
    cleanLease(); migrate()
    for key,job in pairs(st.resources) do st.resources[key]=nil; save(); release(job.ref) end
    if not st.climateRouting then
      for _,f in pairs(st.flows) do
        for index,step in ipairs(f.steps) do
          if index<f.step then
            local id=step:sub(-1)=='P' and f.p or f.d; local r=id and st.refs[id]
            if r and step:match('^analyze') then r.analyzed=true end
            if r and step:match('^imprint') then r.analyzed=true; r.imprinted=true end
          end
        end
        if f.mode=='queen' and f.steps[f.step]=='queen' then
          local loaded=false
          if f.op then for _,feed in ipairs(f.op.feeds) do if feed.loaded or feed.armed then loaded=true end end end
          if not loaded then f.steps={'analyzeP','queen'}; f.step=1; f.op=nil end
        end
      end
      st.climateRouting=true; save()
    end
    if st.resource then release(st.resource); st.resource=nil; save() end
    local used={}
    for _,f in pairs(st.flows) do if f.p then used[f.p]=true end; if f.d then used[f.d]=true end end
    local garbage={}; for id in pairs(st.refs) do if not used[id] then garbage[#garbage+1]=id end end
    for _,id in ipairs(garbage) do release(id) end
    for _,module in pairs(modules) do
      for slot=1,9 do assert(call(module.m.getInterfaceConfiguration,slot)==nil,'Existing interface request at '..module.interface) end
      -- A just-cleared request can take a tick to return its surplus to ME.
      for attempt=0,15 do if emptyBuffer(module) then break end; assert(attempt<15,'Interface buffer not empty'); tick() end
    end
    for key in pairs(st.apiaries) do assert(machines[key],'Owned apiary is missing') end
    save()
    print('AUTO: analyzer -> imprinter -> apiary/mutatron; reserve 32; species gene chance 7.7%; all recipes allowed; server requirements remain enforced.')
    print('Ctrl+C pauses. bees auto resumes. Fluids/power must be supplied to the machines.')
    local capacity=0
    for _,e in ipairs(tools.databases) do
      for slot=1,81 do
        local v,err=read(e.proxy.get,slot); if err then break end
        if v==nil then capacity=capacity+1 end
      end
    end
    for _ in pairs(st.refs) do capacity=capacity+1 end
    local supplySlots=#groups.imprinter+2*#groups.sampler+#groups.mutatron
    local flowLimit=math.max(0,math.min(options.queue>0 and options.queue or (#groups.apiary+#groups.mutatron+#groups.sampler),math.floor((capacity-supplySlots)/2)))
    print('Preparation capacity:',flowLimit,'flows; analyzer input slots: 6 per machine')
    local nextRead=0; local lastSummary=-60
    local schedule={'queen','mutate','breed','breed','sample'}
    local cursor=0
    assert(flowLimit>0,'No usable job capacity; check modules and free OC database entries')
    for _,f in pairs(st.flows) do if f.op then assert(machines[f.op.key],'Saved processor is missing; resolve existing work before changing modules') end end
    while true do
      availability={}
      serviceUnowned()
      serviceApiaries()
      if computer.uptime()>=nextRead then
        local items,err=readME(me,true); assert(type(items)=='table',err or 'ME read failed')
        stock,samples=collectStock(items); st.needFresh=false; nextRead=computer.uptime()+ME_INTERVAL
      end
      local ids={}; for id in pairs(st.flows) do ids[#ids+1]=id end
      table.sort(ids,function(a,b) return tonumber(a)<tonumber(b) end)
      for _,id in ipairs(ids) do currentID=id; flow=st.flows[id]; serviceFlow() end
      currentID=nil; flow=nil
      do
        local count=0; for _ in pairs(st.flows) do count=count+1 end
        while count<flowLimit and not st.needFresh do
          local started=false
          for _=1,#schedule do
            cursor=cursor%#schedule+1
            if choose(stock,samples,schedule[cursor]) then started=true; break end
          end
          if not started then
            if count==0 then warn('No currently available task; monitoring ME. Some species need parents or a wild source.') end
            break
          end
          count=count+1
        end
      end
      if computer.uptime()-lastSummary>=60 then
        local beesCount,sampleCount,active=0,0,0
        for _ in pairs(stock) do beesCount=beesCount+1 end
        for _ in pairs(samples) do sampleCount=sampleCount+1 end
        for _ in pairs(st.apiaries) do active=active+1 end
        print('AUTO STATUS','bee species='..beesCount,'sample evidence='..sampleCount,'apiaries='..active,'cycles='..st.cycles,'donors='..st.samples)
        lastSummary=computer.uptime()
      end
      tick()
    end
  end
  local ok,err=pcall(perform)
  if not ok then
    local cleaned,cleanupError=pcall(cleanLease)
    print('AUTO PAUSED: '..tostring(err))
    if not cleaned then print('Request cleanup pending: '..tostring(cleanupError)) end
    print('Loaded inputs and exact references preserved. Fix the error, then bees auto.')
    return false
  end
  return true
end
-- END EMBEDDED AUTOMATION

if command=="zones" then
  local ok,err=pcall(climateCommand)
  if not ok then print('Climate configuration failed: '..tostring(err)); return false end
  return true
elseif command=="auto" or command=="run" then
  local ok,result=pcall(automate)
  if not ok then print("AUTO NOT STARTED: "..tostring(result)); return false end
  return result
elseif command=="plan" then
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
  print("OpenBeekeeper 0.11.2 - read-only discovery")
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
  print("L is display-label evidence, not NBT verification. Auto uses it only to avoid extra work.")
  if unresolved>0 then print("Unknown/ambiguous sample labels: "..unresolved) end
  print("Preview is not the full species list. Use bees owned for collected entries only.")
  for _,w in ipairs(warnings) do print("WARNING "..w) end
else
  print("Commands: scan | me | setup <ME number> | roles | catalog | probe <number/role> | map | owned | plan | auto [resume/status/check/config/reset] | run [resume/status/check/config/reset] | bind | bind-reset | modules | interface-test | interface-reset")
end
print("Read-only. No items moved.")
