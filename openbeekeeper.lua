-- OpenBeekeeper 0.5.1: ME discovery includes export buses and databases.
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
local snapshots={}
local function readME(entry)
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
    if type(cached)=="table" and cached.schema=="ME1" and cached.machine==machine
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
if command=="scan" then
  print("OpenBeekeeper 0.5.1 - read-only discovery")
  print("Transposers: "..#transposers)
  local n=inspect(transposers,nil,true)
  print("Apiary adjacencies: "..n.." (duplicates possible; not a worker count)")
  listNetworks(networks)
  listTools(tools)
  print("Forestry catalogue endpoints: "..#catalogues)
elseif command=="me" then
  listNetworks(networks)
  listTools(tools)
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
  print("Commands: scan | me | setup <ME number> | roles | catalog | probe <number/role> | map | owned")
end
print("Read-only. No items moved.")
