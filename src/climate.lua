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
