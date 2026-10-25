-- OpenBeekeeper 0.3.2: discovery, ME diagnostics, collection preview. Read-only.
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
  for address,kind in component.list() do entries[#entries+1]={address=address,kind=kind} end
  table.sort(entries,function(a,b) return a.address<b.address end)
  for _,entry in ipairs(entries) do
    local methods=read(component.methods,entry.address)
    local proxy=read(component.proxy,entry.address)
    if type(methods)=="table" and proxy then
      entry.proxy=proxy
      if entry.kind=="transposer" then transposers[#transposers+1]=entry end
      -- Values are the direct-call flag, NOT an availability flag.
      -- false means a synchronized callback exists; only nil means absent.
      if methods.getItemsInNetwork~=nil then networks[#networks+1]=entry end
      if methods.listAllSpecies~=nil and methods.getBeeBreedingData~=nil then catalogues[#catalogues+1]=entry end
    end
  end
  return transposers,networks,catalogues
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
  for i,e in ipairs(networks) do print(i,e.kind,e.address) end
  if #networks==0 then print("None. Connect an OC adapter to an ME interface.") end
  print("Numbers are temporary. Never use them as saved role bindings.")
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

local transposers,networks,catalogues=discover()
if command=="scan" then
  print("OpenBeekeeper 0.3.2 - read-only discovery")
  print("Transposers: "..#transposers)
  local n=inspect(transposers,nil,true)
  print("Apiary adjacencies: "..n.." (duplicates possible; not a worker count)")
  listNetworks(networks)
  print("Forestry catalogue endpoints: "..#catalogues)
elseif command=="me" then
  listNetworks(networks)
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
  local entry=index and networks[index]
  if not entry then listNetworks(networks); print("Use: lua openbeekeeper.lua probe <ME number>"); return end
  local items,err=read(entry.proxy.getItemsInNetwork)
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
elseif command=="map" then
  local stockIndex,geneIndex=tonumber(args[2]),tonumber(args[3])
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
  local function collect(v,source)
    local id=bee(v)
    if type(id)=="string" and id~="" then
      known[id]=known[id] or {label=(v.individual or {}).displayName or id}
      known[id].bee=true
    end
    if source=="archive" then
      local g=gene(v)
      if g and g.chromosome==0 then
        known[g.allele]=known[g.allele] or {label=g.allele}
        known[g.allele].gene=true
      end
    end
  end
  inspect(transposers,collect,false)
  local warnings={}
  local function readNetwork(index,source)
    if not index then return end
    local items,err=read(networks[index].proxy.getItemsInNetwork)
    if type(items)~="table" then warnings[#warnings+1]=source..": "..tostring(err); return end
    if source=="archive" then archiveReadable=true end
    for _,v in pairs(items) do if alive(v) then collect(v,source) end end
  end
  readNetwork(stockIndex,"stock"); readNetwork(geneIndex,"archive")
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
  print("B=bee available; G=verified species sample in selected archive")
  print("Green=archived gene; cyan=bee only; grey=unconfirmed")
  for _,v in ipairs(rows) do
    if gpu then gpu.setForeground(v.gene and 0x55FF55 or v.bee and 0x55DDFF or 0xAAAAAA) end
    print(string.format("[%s] [%s] %-16s %s",v.bee and "B" or "-",v.gene and "G" or "?",v.label,v.id))
  end
  if gpu then gpu.setForeground(previous) end
  if not archiveReadable then print("Archive not read. No collection completeness claim.") end
  print("Unreadable sample NBT is UNKNOWN, never green. Preview is not the full species list.")
  for _,w in ipairs(warnings) do print("WARNING "..w) end
else
  print("Commands: scan | me | catalog | probe <ME number> | map [stock ME number] [archive ME number]")
end
print("Read-only. No items moved.")
