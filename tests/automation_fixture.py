"""Base OC/ME simulation shared by full automation integration tests."""
FIXTURE = r'''
local function clone(v)
 if type(v)~='table' then return v end
 local c={}; for k,x in pairs(v) do c[k]=clone(x) end; return c
end
local serial=require('serialization'); local originalSerialize=serial.serialize
serial.serialize=function(v)
 if v.schema=='APIARY1' then
  serialNumber=serialNumber+1; local token='RUN:'..serialNumber
  serialValues[token]=clone(v); return token
 end
 return originalSerialize(v)
end
stateFiles['/home/.openbeekeeper-data/roles']='OpenBeekeeper-roles-2\nnetwork me\n'
local binding={'OpenBeekeeper-modules-1'}
stock={}; bins={}; configurations={}; apiaries={}; dbSlots={}
loaded={}; harvested={}; stores=0; cycles=0; configurationsMade=0
function beeStack(uid,kind,count)
 return {name='forestry:bee_'..kind..'_ge',label=uid..' '..kind,size=count,
   individual={ident=uid,displayName=uid}}
end
function add(uid,kind,count)
 local key=uid..':'..kind
 if not stock[key] then stock[key]=beeStack(uid,kind,0) end
 stock[key].size=stock[key].size+count
end
function stockItems()
 local t={}; for _,v in pairs(stock) do if v.size>0 then t[#t+1]=clone(v) end end; return t
end
devices.me={kind='me_controller',getItemsInNetwork=function()
 networkCalls[#networkCalls+1]=clock; return stockItems() end}
devices.db={kind='database',get=function(i) return dbSlots[i] end,
 clear=function(i) dbSlots[i]=nil end}
for n=1,4 do
 local module=n; bins[module]={}; configurations[module]={}; apiaries[module]={}
 binding[#binding+1]='interface t'..module..' 1 if'..module
 for side=2,5 do
  binding[#binding+1]='machine t'..module..' '..side..' gendustry:industrial_apiary'
  apiaries[module][side]={}
 end
 local function returnToME(v,count)
  if v and v.individual then
   local uid=v.individual.ident
   local kind=v.name:find('princess') and 'princess' or v.name:find('queen') and 'queen' or 'drone'
   add(uid,kind,count)
  end
 end
 devices['if'..module]={kind='me_interface',
  getItemsInNetwork=function() error('WRONG ENDPOINT') end,
  store=function(filter,address,slot,count)
   assert(address=='db' and count==1); stores=stores+1
   for _,v in pairs(stock) do
    if v.size>0 and v.name==filter.name and v.label==filter.label then
     dbSlots[slot]=clone(v); dbSlots[slot].size=1
     if wrongDescriptor then dbSlots[slot].individual.ident='wrong' end
     return true
    end
   end
   return false
  end,
  getInterfaceConfiguration=function(slot) return configurations[module][slot] end,
  setInterfaceConfiguration=function(slot,address,dbSlot,count)
   if not address then
    if cleanupFails then error('cleanup failed') end
    configurations[module][slot]=nil
    local v=bins[module][slot]; if v then returnToME(v,v.size); bins[module][slot]=nil end
    return true
   end
   configurationsMade=configurationsMade+1
   assert(address=='db' and count==1)
   local v=clone(dbSlots[dbSlot]); configurations[module][slot]=clone(v)
   if not noSupply then
    local kind=v.name:find('princess') and 'princess' or v.name:find('queen') and 'queen' or 'drone'
    local key=v.individual.ident..':'..kind
    assert(stock[key] and stock[key].size>0)
    stock[key].size=stock[key].size-1; bins[module][slot]=v
   end
   return true
  end}
 devices['t'..module]={kind='transposer',
  getInventoryName=function(side)
   if side==1 then return 'appliedenergistics2:interface' end
   if side>=2 and side<=5 then return 'gendustry:industrial_apiary' end
   return nil,'no inventory'
  end,
  getStackInSlot=function(side,slot)
   return clone(side==1 and bins[module][slot] or apiaries[module][side] and apiaries[module][side][slot])
  end,
  transferItem=function(from,to,count,slot,destination)
   if from==1 then
    if failPrincess and destination==1 then return 0 end
    assert(not apiaries[module][to][destination])
    local v=assert(bins[module][slot]); assert(count==1)
    apiaries[module][to][destination]=clone(v); bins[module][slot]=nil
    loaded[#loaded+1]={module=module,side=to,slot=destination,uid=v.individual.ident}
    local a=apiaries[module][to]
    if a[1] and a[1].name:find('princess') and a[2] then
     a[1]=beeStack(a[1].individual.ident,'queen',1); a[2]=nil
    end
    return 1
   end
   assert(to==1 and slot>=7 and slot<=15, 'UPGRADE/INPUT EXTRACTION FORBIDDEN')
   local v=assert(apiaries[module][from][slot]); assert(count==v.size,'MUST REQUEST WHOLE SLOT')
   local moved=partialHarvest and math.min(2,count) or count
   harvested[#harvested+1]={requested=count,moved=moved}
   returnToME(v,moved); v.size=v.size-moved
   if v.size==0 then apiaries[module][from][slot]=nil end
   return moved
  end}
end
stateFiles['/home/.openbeekeeper-data/modules']=table.concat(binding,'\n')..'\n'
package.preload.event=function() return {pull=function(seconds)
 clock=clock+seconds
 if interruptAt and clock>=interruptAt then return 'interrupted' end
 if not stall then
  for _,group in pairs(apiaries) do for _,a in pairs(group) do
   if a[1] and a[1].name:find('queen') then
    local uid=a[1].individual.ident; a[1]=nil
    a[7]=beeStack(uid,'princess',1); a[8]=beeStack(uid,'drone',4)
    a[9]={name='forestry:bee_combs',label='Honey Comb',size=64}; cycles=cycles+1
   end
  end end
 end
 return nil
end} end
'''
