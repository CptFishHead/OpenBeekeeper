"""End-to-end machine chain with exact, opaque NBT database references."""
from pathlib import Path
import unittest
import test_runtime as runtime
import automation_fixture as legacy

FULL = legacy.FIXTURE + r'''
local function clone(v)
 if type(v)~='table' then return v end
 local x={}; for k,y in pairs(v) do x[k]=clone(y) end; return x
end
local function descriptor(v)
 local x=clone(v); if x then x._nbt=nil end; return x
end
local serial=require('serialization'); local oldSerialize=serial.serialize
local oldUnserialize=serial.unserialize
serial.unserialize=function(text) return clone(oldUnserialize(text)) end
serial.serialize=function(v)
 if v.schema=='AUTO1' or v.schema=='CLIMATE1' or v.schema=='AUTOOPTIONS1' or v.schema=='AUTOINTERFACES1' then serialNumber=serialNumber+1; local key='AUTO:'..serialNumber; serialValues[key]=clone(v); return key end
 return oldSerialize(v)
end
local originalBee=beeStack
beeStack=function(uid,kind,count)
 local v=originalBee(uid,kind,count); v.individual.isAnalyzed=false; v._nbt='raw'; return v
end
devices.db.get=function(slot) return descriptor(dbSlots[slot]) end
local function store(filter,address,slot,count)
 assert(address=='db' and count==1); stores=stores+1
 for _,v in pairs(stock) do
  if v.size>=0 and (not filter.name or v.name==filter.name) and (not filter.label or v.label==filter.label) and (not filter.size or v.size==filter.size) then
   dbSlots[slot]=clone(v); dbSlots[slot].size=1; return true
  end
 end
 return true
end
devices.me.store=store
local binding=stateFiles['/home/.openbeekeeper-data/modules']
processors={}; visits={}; sampled={}; observedMutations={}; comparisons=0
local types={[5]='analyzer',[6]='imprinter',[7]='sampler',[8]='mutatron'}
local ids={analyzer='forestry:analyzer',imprinter='gendustry:imprinter',sampler='gendustry:sampler',mutatron='gendustry:mutatron'}
for n=5,8 do
 local module=n; local kind=types[n]; bins[n]={}; configurations[n]={}; processors[n]={}
 if kind=='imprinter' then processors[n][1]={name='gendustry:gene_template',label='Genetic Template',size=1} end
 local lab=kind=='mutatron' and 4 or 2
 if kind~='analyzer' then processors[n][lab]={name='gendustry:labware',label='Genetics Labware',size=64} end
 if kind=='sampler' then processors[n][1]={name='gendustry:gene_sample_blank',label='Blank Gene Sample',size=64} end
 binding=binding..'interface t'..n..' 1 if'..n..'\nmachine t'..n..' 0 '..ids[kind]..'\n'
 devices['if'..n]={kind='me_interface',store=store,getItemsInNetwork=function() error('WRONG ENDPOINT') end}
 devices['t'..n]={kind='transposer',
  getInventoryName=function(side) if side==1 then return 'appliedenergistics2:interface' elseif side==0 then return ids[kind] end return nil,'no inventory' end,
  getStackInSlot=function(side,slot) if side==1 then return descriptor(bins[module][slot]) end return descriptor(processors[module][slot]) end,
  getFluidInTank=function(side) return {{amount=(kind=='analyzer' and noHoney) and 0 or 10000}} end,
  transferItem=function(from,to,count,slot,destination)
   if from==1 then
    if failProcessorLoad and kind==failProcessorLoad then return 0 end
    assert(not processors[module][destination]); assert(count==bins[module][slot].size)
    processors[module][destination]=clone(bins[module][slot]); bins[module][slot]=nil
    visits[#visits+1]={uid=processors[module][destination].individual and processors[module][destination].individual.ident,kind=kind,nbt=processors[module][destination]._nbt,count=count}
    return count
   end
   assert(from==0 and to==1)
   local v=assert(processors[module][slot]); assert(count==v.size)
   local moved=partialFull and math.min(1,count) or count
   if v.individual then
    local k=v.name:find('princess') and 'princess' or v.name:find('queen') and 'queen' or 'drone'
    add(v.individual.ident,k,moved)
   elseif v.name=='gendustry:gene_sample' then
    local key='sample:'..v.label
    if not stock[key] then stock[key]=clone(v); stock[key].size=0 end
    stock[key].size=stock[key].size+moved
   end
   v.size=v.size-moved; if v.size==0 then processors[module][slot]=nil end
   return moved
  end}
end
stateFiles['/home/.openbeekeeper-data/modules']=binding
for n=1,8 do
 local module=n
 local oldMove=devices['t'..n].transferItem
 if n<=4 then
  devices['t'..n].transferItem=function(from,to,count,slot,destination)
   if from==1 then
    local v=bins[module][slot]
    if not v.name:find('queen') then assert(v.individual.isAnalyzed and v._nbt:find('imprinted',1,true),'UNPREPARED MATING PARENT') end
   end
   return oldMove(from,to,count,slot,destination)
  end
 end
 devices['t'..n].store=function(side,slot,address,index)
  assert(address=='db')
  local v=module<=4 and (side==1 and bins[module][slot] or apiaries[module][side][slot])
    or (side==1 and bins[module][slot] or processors[module][slot])
  assert(v); dbSlots[index]=clone(v); return true
 end
 devices['t'..n].compareStackToDatabase=function(side,slot,address,index,nbt)
  comparisons=comparisons+1; assert(nbt==true and address=='db')
  local v=bins[module][slot]; local r=dbSlots[index]
  return not badNBT and v and r and v.name==r.name and v._nbt==r._nbt
 end
 devices['if'..n].store=store
 devices['if'..n].getInterfaceConfiguration=function(slot) return descriptor(configurations[module][slot]) end
 devices['if'..n].setInterfaceConfiguration=function(slot,address,index,count)
  if not address then
   if cleanupFails then error('cleanup failed') end
   configurations[module][slot]=nil
   local v=bins[module][slot]
   if v then
    if v.individual then
     local k=v.name:find('princess') and 'princess' or v.name:find('queen') and 'queen' or 'drone'
     add(v.individual.ident,k,v.size)
    else
     for _,x in pairs(stock) do if x.name==v.name and x.label==v.label then x.size=x.size+v.size; break end end
    end
    bins[module][slot]=nil
   end
   return true
  end
  assert(slot==9)
  local v=clone(dbSlots[index]); v.size=count
  local source
  if v.individual then
   local k=v.name:find('princess') and 'princess' or v.name:find('queen') and 'queen' or 'drone'
   source=stock[v.individual.ident..':'..k]
  else for _,x in pairs(stock) do if x.name==v.name and x.label==v.label then source=x; break end end end
  configurations[module][slot]=clone(v)
  if source and source.size>0 and not noSupply then
   v.size=math.min(count,source.size); source.size=source.size-v.size; bins[module][slot]=v
  end
  return true
 end
end
-- A separate incubator module, never used for prepared-parent reproduction.
apiaries[9]={}; bins[9]={}; configurations[9]={}
for side=2,5 do apiaries[9][side]={[3]={name='gendustry:apiary_upgrade',label='Plains Emulation Upgrade',size=1,damage=17}} end
devices.t9={kind='transposer',
 getInventoryName=function(side) if side==1 then return 'appliedenergistics2:interface' elseif side>=2 and side<=5 then return 'gendustry:industrial_apiary' end return nil,'no inventory' end,
 getStackInSlot=function(side,slot) if side==1 then return descriptor(bins[9][slot]) end return descriptor(apiaries[9][side] and apiaries[9][side][slot]) end,
 store=function(side,slot,address,index) dbSlots[index]=clone(apiaries[9][side][slot]); return true end,
 compareStackToDatabase=function(side,slot,address,index,nbt) return bins[9][slot] and bins[9][slot]._nbt==dbSlots[index]._nbt end,
 transferItem=function(from,to,count,slot,destination)
  if from==1 then
   local v=assert(bins[9][slot]); assert(v.name:find('queen'),'INCUBATOR RECEIVED A MATING PARENT')
   apiaries[9][to][destination]=clone(v); bins[9][slot]=nil
   loaded[#loaded+1]={module=9,side=to,slot=destination,uid=v.individual.ident}; return count
  end
  local v=assert(apiaries[9][from][slot]); assert(slot>=7 and count==v.size)
  if v.individual then add(v.individual.ident,v.name:find('princess') and 'princess' or 'drone',count) end
  apiaries[9][from][slot]=nil; return count
 end}
devices.if9={kind='me_interface',store=store,getItemsInNetwork=function() error('WRONG ENDPOINT') end,
 getInterfaceConfiguration=function(slot) return configurations[9][slot] end,
 setInterfaceConfiguration=function(slot,address,index,count)
  if not address then
   local v=bins[9][slot]
   if v then add(v.individual.ident,'queen',v.size); bins[9][slot]=nil end
   configurations[9][slot]=nil; return true
  end
  local v=clone(dbSlots[index]); v.size=count
  local source=assert(stock[v.individual.ident..':queen']); assert(source.size>=count)
  source.size=source.size-count; bins[9][slot]=v; configurations[9][slot]=clone(v); return true
 end}
binding=binding..'interface t9 1 if9\n'
for side=2,5 do binding=binding..'machine t9 '..side..' gendustry:industrial_apiary\n' end
stateFiles['/home/.openbeekeeper-data/modules']=binding
local climate={schema='CLIMATE1',roles={},manual={},species={}}
for module=1,4 do for side=2,5 do climate.roles['t'..module..':'..side]='breeding' end end
for _,uid in ipairs({'a','b','c','d','goal','side','conditional'}) do climate.species[uid]={'NORMAL','NORMAL'} end
stateFiles['/home/.openbeekeeper-data/climate']=serial.serialize(climate)
devices.catalogue={kind='bee_housing',
 listAllSpecies=function() return {{uid='a',name='a'},{uid='b',name='b'},{uid='goal',name='goal'},{uid='side',name='side'},{uid='conditional',name='conditional'}} end,
 getBeeBreedingData=function() return {
  {allele1='a',allele2='b',result='goal',chance=10,specialConditions=onlyConditional and {'Night'} or {}},
  includeConditional and {allele1='a',allele2='b',result='conditional',chance=99,specialConditions={'Nether'}} or {}} end}
local basePull=require('event').pull
require('event').pull=function(seconds)
 local ret=basePull(seconds); if ret=='interrupted' then return ret end
 for n,p in pairs(processors) do
  local kind=types[n]
  local inSlot,outSlot
  if kind=='analyzer' then
   for slot=3,8 do if p[slot] then inSlot=slot; break end end
   for slot=9,12 do if not p[slot] then outSlot=slot; break end end
  end
  if not stallProcessor or stallProcessor~=kind then
   if kind=='analyzer' and inSlot and outSlot and not noHoney then
    p[outSlot]=clone(p[inSlot]); p[outSlot].individual.isAnalyzed=true; p[outSlot]._nbt='analyzed|'..p[outSlot]._nbt; p[inSlot]=nil
   elseif kind=='imprinter' and p[3] and not p[4] and p[2] and p[2].size>0 then
    assert(p[3].individual.isAnalyzed,'IMPRINT BEFORE ANALYSIS')
    p[4]=clone(p[3]); p[4]._nbt='imprinted|'..p[4]._nbt
    if changeSpecies then p[4].individual.ident='WRONG' end
    if geneticDeath and p[3].name:find('princess') then p[4]={name='gendustry:waste',label='Genetic Waste',size=1}; geneticDeath=false end
    p[3]=nil; p[2].size=p[2].size-1; if p[2].size==0 then p[2]=nil end
   elseif kind=='sampler' and p[3] and not p[4] and p[1] and p[2] then
    assert(p[3]._nbt:find('imprinted',1,true),'UNPREPARED SAMPLE')
    local uid=p[3].individual.ident; sampled[#sampled+1]=uid
    local success=not sampleFailures or #sampled>sampleFailures
    p[4]={name='gendustry:gene_sample',size=1,label=success and ('Bee Sample - Species: '..uid) or 'Bee Sample - Speed: Fast'}
    if not hideSampleNBT then p[4].tag={species='rootBees',chromosome=success and 0 or 1,allele=success and uid or 'speed.fast'} end
    p[3]=nil; p[1].size=p[1].size-1; p[2].size=p[2].size-1
   elseif kind=='mutatron' and p[1] and p[2] and not p[3] then
    -- Gendustry mutatron accepts parents without analysis or imprinting.
    local uid=mutationResult or (#observedMutations==0 and 'side' or 'goal')
    observedMutations[#observedMutations+1]=uid
    p[3]=beeStack(uid,'queen',1); p[1]=nil; p[2]=nil
   end
  end
 end
 return ret
end
'''


class AutomationTests(unittest.TestCase):
    def execute(self, setup='', *args):
        return runtime.RuntimeTests().run_script(FULL+setup, 'auto', *args)

    def test_radiation_species_and_visible_inherited_gene_are_blocked_without_analysis(self):
        cases=[("forestry.speciesVindictive",None),("forestry.speciesVengeful",None),
               ("forestry.speciesAvenging",None),
               ("a","active"),("a","inactive")]
        for uid,side in cases:
            with self.subTest(uid=uid,side=side):
                setup="add('"+uid+"','queen',1); interruptAt=12;"
                if side:
                    setup+="stock['a:queen'].individual.isAnalyzed=true; stock['a:queen'].individual."+side+"={effect='Radiation'};"
                text, _, lua=self.execute(setup)
                self.assertNotIn('FLOW queen',text)
                self.assertEqual(len(list(lua.globals().loaded.values())),0)
                self.assertEqual(len(list(lua.globals().visits.values())),0)
                self.assertEqual(lua.globals().stock[uid+':queen'].size,1)

    def test_extra_bees_entity_radiation_is_allowed_with_destructive_radiation_blocked(self):
        for species in ['unstable','nuclear','radioactive','yellorium','cyanite','blutonium']:
            with self.subTest(species=species):
                setup=r'''
                  add(UID,'queen',1); stock[UID..':queen'].individual.active={effect='Unstable'}
                  stock[UID..':queen'].individual.inactive={effect='extrabees.effect.radioactive'}
                  stall=true; interruptAt=8
                  local p='/home/.openbeekeeper-data/climate'; local c=require('serialization').unserialize(stateFiles[p])
                  c.species[UID]={'NORMAL','NORMAL'}; stateFiles[p]=require('serialization').serialize(c)
                  stateFiles['/home/.openbeekeeper-data/automation-options']=require('serialization').serialize({
                    schema='AUTOOPTIONS1',batch=64,queue=0,mutations=true,sampling=true,effects={radiation=false}})
                '''
                _, _, lua=self.execute("UID='extrabees.species."+species+"';"+setup)
                self.assertEqual(len([v for v in lua.globals().loaded.values() if v.slot==1]),1)
                self.assertEqual(len(list(lua.globals().visits.values())),0)

    def test_radiation_mutation_target_is_not_planned(self):
        text, _, lua=self.execute(r'''
          add('a','princess',1); add('a','drone',16); add('b','drone',17)
          stock.ga=sample('a'); stock.gb=sample('b'); interruptAt=12
          devices.catalogue.listAllSpecies=function() return {
            {uid='a',name='a'},{uid='b',name='b'},
            {uid='forestry.speciesVindictive',name='Vindictive'}} end
          devices.catalogue.getBeeBreedingData=function() return {{
            allele1='a',allele2='b',result='forestry.speciesVindictive',chance=10}} end
        ''')
        self.assertNotIn('FLOW mutate',text)
        self.assertEqual(len(list(lua.globals().observedMutations.values())),0)

    def test_unexpected_radioactive_mutation_result_stays_in_me(self):
        text, _, lua=self.execute(r'''
          add('a','princess',1); add('a','drone',16); add('b','drone',17)
          stock.ga=sample('a'); stock.gb=sample('b'); interruptAt=16
          mutationResult='forestry.speciesVindictive'
        ''')
        self.assertEqual(lua.globals().stock['forestry.speciesVindictive:queen'].size,1)
        self.assertEqual(len(list(lua.globals().loaded.values())),0)
        self.assertFalse(any(v.kind=='analyzer' for v in lua.globals().visits.values()))

    def test_existing_radioactive_apiary_is_evacuated_to_me(self):
        text, _, lua=self.execute(r'''
          apiaries[9][2][1]=beeStack('forestry.speciesVindictive','queen',1)
          stall=true; interruptAt=8
          local move=devices.t9.transferItem
          devices.t9.transferItem=function(from,to,count,slot,destination)
            if from~=1 and slot==1 then
              local v=apiaries[9][from][slot]; assert(v and count==v.size)
              add(v.individual.ident,'queen',count); apiaries[9][from][slot]=nil; return count
            end
            return move(from,to,count,slot,destination)
          end
        ''')
        self.assertIn('EFFECT BLOCKED radiation',text)
        self.assertIsNone(lua.globals().apiaries[9][2][1])
        self.assertEqual(lua.globals().stock['forestry.speciesVindictive:queen'].size,1)
        self.assertEqual(len(list(lua.globals().loaded.values())),0)

    def test_disconnected_interface_keeps_lease_but_other_requests_are_cleaned_and_resume_works(self):
        for raises in [False,True]:
            with self.subTest(proxy_raises=raises):
                setup=r'''
                  add('a','drone',17); noSupply=true; interruptAt=10
                  local serial=require('serialization'); local serialize=serial.serialize
                  serial.serialize=function(v)
                    if v.schema=='AUTO1' then liveState=v end
                    return serialize(v)
                  end
                  local component=require('component'); local proxy=component.proxy
                  component.proxy=function(address)
                    if address=='if6' and disconnected and missingProxyRaises then error('no such component') end
                    return proxy(address)
                  end
                  local get=devices.t5.getStackInSlot
                  devices.t5.getStackInSlot=function(...)
                    if disconnected then error('no such component') end
                    return get(...)
                  end
                  interface6=devices.if6
                  clear8=devices.if8.setInterfaceConfiguration
                  devices.if8.setInterfaceConfiguration=function(slot,address,...)
                    if disconnected and not address then error('no such component') end
                    return clear8(slot,address,...)
                  end
                  local pull=require('event').pull
                  require('event').pull=function(seconds)
                    local result=pull(seconds)
                    if clock>=3 and not detached then
                      detached=true; disconnected=true; devices.if6=nil
                      for _,key in ipairs({'if6','if7','if8'}) do liveState.leases[key]={owner='test'} end
                      configurations[7][9]={name='test',size=1}
                    end
                    return result
                  end
                '''
                text, _, lua=self.execute('missingProxyRaises='+str(raises).lower()+';'+setup)
                self.assertIn('t5.getStackInSlot',text)
                self.assertIn('OFFLINE ME interface if6',text)
                self.assertNotIn('attempt to index a nil',text)
                state=lua.eval("require('serialization').unserialize(stateFiles['/home/.openbeekeeper-data/automation'])")
                self.assertIsNotNone(state.leases['if6'])
                self.assertIsNotNone(state.leases['if8'])
                self.assertIsNone(state.leases['if7'])
                self.assertIsNone(lua.globals().configurations[7][9])
                self.assertGreater(len(list(state.refs.values())),0)
                lua.execute("disconnected=false; devices.if6=interface6; noSupply=false; interruptAt=clock+60")
                text=self.invoke_auto(lua,action='resume')
                state=lua.eval("require('serialization').unserialize(stateFiles['/home/.openbeekeeper-data/automation'])")
                self.assertEqual(len(list(state.leases.values())),0)
                self.assertEqual(list(lua.globals().sampled.values()),['a'])

    def test_every_recipe_condition_must_be_enabled(self):
        for blocked in ['date','biome',None]:
            with self.subTest(blocked=blocked):
                setup=r'''
                  add('a','princess',1); add('a','drone',16); add('b','drone',17)
                  stock.ga=sample('a'); stock.gb=sample('b'); stallProcessor='mutatron'; interruptAt=12
                  devices.catalogue.getBeeBreedingData=function() return {{
                    allele1='a',allele2='b',result='goal',chance=10,
                    specialConditions={'date','biome'}}} end
                  local conditions={}
                '''
                if blocked:
                    setup+="conditions['"+blocked+"']=false;"
                setup+="stateFiles['/home/.openbeekeeper-data/automation-options']=require('serialization').serialize({schema='AUTOOPTIONS1',batch=64,queue=0,mutations=true,sampling=true,conditions=conditions})"
                text, _, lua=self.execute(setup)
                self.assertEqual('PROCESS mate' in text,blocked is None)

    def test_resume_counts_empty_owned_database_slots_only_once(self):
        _, _, lua=self.execute(r'''
          for slot=8,81 do dbSlots[slot]={name='unrelated',size=1} end
          add('a','princess',1); add('a','drone',15); stock.ga=sample('a')
          stallProcessor='analyzer'; interruptAt=3
        ''')
        lua.execute('interruptAt=clock+3')
        text=self.invoke_auto(lua,action='resume')
        self.assertIn('Preparation capacity: 1 flows',text)
        self.assertNotIn('Preparation capacity: 2 flows',text)

    def test_database_exhaustion_waits_without_losing_pending_bee(self):
        text, _, lua=self.execute(r'''
          add('a','drone',17); interruptAt=40
          local get=devices.db.get
          devices.db.get=function(slot)
            local v=get(slot)
            if blockFree and clock<5 and not v then return {name='external',size=1} end
            return v
          end
          local query=devices.me.getItemsInNetwork
          devices.me.getItemsInNetwork=function(...)
            blockFree=true; return query(...)
          end
        ''')
        self.assertIn('Waiting for a free OC database entry',text)
        self.assertNotIn('No free OC database entry',text)
        self.assertEqual(list(lua.globals().sampled.values()),['a'])

    def test_prepares_both_parents_in_order_before_mating_and_bulk_returns(self):
        text, _, lua=self.execute("add('a','princess',1); add('a','drone',15); stock.gene=sample('a'); interruptAt=45; callableMode=true")
        self.assertNotIn('UNPREPARED', text)
        self.assertNotIn('AUTO NOT STARTED', text)
        self.assertEqual(lua.globals().stock['a:drone'].size, 18)
        self.assertEqual([v.kind for v in lua.globals().visits.values() if v.uid], ['analyzer','imprinter','analyzer','imprinter'])
        self.assertGreaterEqual(lua.globals().comparisons, 6)
        self.assertIn('APIARY COMPLETE', text)

    def test_samples_only_surplus_and_recognizes_actual_gene(self):
        text, _, lua=self.execute("add('a','drone',17); hideSampleNBT=true; interruptAt=65")
        self.assertEqual(lua.globals().stock['a:drone'].size, 16)
        self.assertEqual(list(lua.globals().sampled.values()), ['a'])
        self.assertIsNotNone(lua.globals().stock['sample:Bee Sample - Species: a'])
        self.assertIn('SAMPLE RESULT', text)

    def test_wrong_chromosome_does_not_mark_species_collected(self):
        text, _, lua=self.execute("add('a','drone',18); sampleFailures=1; interruptAt=80")
        self.assertEqual(list(lua.globals().sampled.values()), ['a','a'])
        self.assertEqual(lua.globals().stock['a:drone'].size, 16)
        self.assertIsNotNone(lua.globals().stock['sample:Bee Sample - Speed: Fast'])
        self.assertIsNotNone(lua.globals().stock['sample:Bee Sample - Species: a'])

    def test_mutatron_selects_live_princess_at_request_time_or_cancels_without_request(self):
        for missing in (False,True):
            with self.subTest(missing=missing):
                setup=r'''
                  add('a','princess',1); add('a','drone',16); add('b','drone',17)
                  stock.ga=sample('a'); stock.gb=sample('b'); stallProcessor='mutatron'; interruptAt=50
                  princessRequests=0; changedPrincess=false
                  local store=devices.me.store
                  devices.me.store=function(filter,address,slot,count)
                    local raw=stateFiles['/home/.openbeekeeper-data/automation']
                    local s=raw and require('serialization').unserialize(raw)
                    if filter.name=='forestry:bee_princess_ge' and s then
                      for _,f in pairs(s.flows) do
                        if f.mode=='mutate' and f.steps[f.step]=='mate' and not changedPrincess then
                          changedPrincess=true
                          if missingPrincess then stock['a:princess'].size=0
                          else stock['a:princess']._nbt='analyzed|captivity2'; stock['a:princess'].individual.isAnalyzed=true end
                        end
                      end
                    end
                    return store(filter,address,slot,count)
                  end
                  local request=devices.if8.setInterfaceConfiguration
                  devices.if8.setInterfaceConfiguration=function(slot,address,index,count)
                    if address and dbSlots[index].name=='forestry:bee_princess_ge' then
                      princessRequests=princessRequests+1
                      assert(stock['a:princess'].size>0,'REQUESTED ABSENT PRINCESS')
                      assert(dbSlots[index]._nbt==stock['a:princess']._nbt,'REQUESTED STALE PRINCESS NBT')
                    end
                    return request(slot,address,index,count)
                  end
                '''
                text, _, lua=self.execute('missingPrincess='+str(missing).lower()+';'+setup)
                self.assertTrue(lua.globals().changedPrincess)
                self.assertNotIn('REQUESTED ABSENT',text)
                self.assertNotIn('REQUESTED STALE',text)
                if missing:
                    self.assertEqual(lua.globals().princessRequests,0)
                    self.assertIsNone(lua.globals().processors[8][2])
                    self.assertIn('mutatron request not configured',text)
                else:
                    self.assertEqual(lua.globals().princessRequests,1)
                    self.assertEqual(lua.globals().processors[8][1]._nbt,'analyzed|captivity2')

    def test_imprinter_preloads_free_input_and_keeps_output_ownership_in_order(self):
        setup=r'''
          add('a','drone',17); add('b','drone',17); blockImprintOutput=true; interruptAt=20
          local move=devices.t6.transferItem
          devices.t6.transferItem=function(from,to,count,slot,destination)
            if from==0 and slot==4 and blockImprintOutput then return 0 end
            return move(from,to,count,slot,destination)
          end
        '''
        _, _, lua=self.execute(setup)
        self.assertIsNotNone(lua.globals().processors[6][3])
        self.assertIsNotNone(lua.globals().processors[6][4])
        self.assertNotEqual(lua.globals().processors[6][3].individual.ident,lua.globals().processors[6][4].individual.ident)
        lua.execute('blockImprintOutput=false; interruptAt=clock+60')
        text=self.invoke_auto(lua,action='resume')
        self.assertNotIn('Processor changed bee species',text)
        self.assertEqual(set(lua.globals().sampled.values()),{'a','b'})

    def test_mutatron_preloads_next_pair_while_previous_output_is_held(self):
        setup=r'''
          add('a','princess',4); add('a','drone',16); add('b','drone',40)
          stock.ga=sample('a'); stock.gb=sample('b'); includeConditional=true; blockMutationOutput=true; interruptAt=15
          local move=devices.t8.transferItem
          devices.t8.transferItem=function(from,to,count,slot,destination)
            if from==0 and slot==3 and blockMutationOutput then return 0 end
            return move(from,to,count,slot,destination)
          end
        '''
        text, _, lua=self.execute(setup)
        self.assertIsNotNone(lua.globals().processors[8][1])
        self.assertIsNotNone(lua.globals().processors[8][2])
        self.assertIsNotNone(lua.globals().processors[8][3])
        self.assertFalse(any(v.kind=='analyzer' for v in lua.globals().visits.values()))
        lua.execute('blockMutationOutput=false; interruptAt=clock+40')
        self.invoke_auto(lua,action='resume')
        state=lua.eval("require('serialization').unserialize(stateFiles['/home/.openbeekeeper-data/automation'])")
        self.assertGreaterEqual(state.mutations,2)

    def test_mutatron_accounts_return_even_when_next_output_replaces_it_immediately(self):
        setup=r'''
          add('a','princess',4); add('a','drone',16); add('b','drone',40)
          stock.ga=sample('a'); stock.gb=sample('b'); includeConditional=true; blockMutationOutput=true; interruptAt=15
          local move=devices.t8.transferItem
          devices.t8.transferItem=function(from,to,count,slot,destination)
            if from==0 and slot==3 and blockMutationOutput then return 0 end
            local moved=move(from,to,count,slot,destination)
            local p=processors[8]
            if from==0 and slot==3 and moved>0 and p[1] and p[2] then
              p[3]=beeStack('goal','queen',1); p[1]=nil; p[2]=nil
              immediateReplacement=true
            end
            return moved
          end
        '''
        _, _, lua=self.execute(setup)
        lua.execute('blockMutationOutput=false; interruptAt=clock+40')
        text=self.invoke_auto(lua,action='resume')
        self.assertTrue(lua.globals().immediateReplacement)
        self.assertNotIn('Owned output changed',text)
        state=lua.eval("require('serialization').unserialize(stateFiles['/home/.openbeekeeper-data/automation'])")
        self.assertGreaterEqual(state.mutations,2)

    def test_apiary_preloads_next_drone_without_replacing_running_queen(self):
        setup=r'''
          local p='/home/.openbeekeeper-data/modules'; local rows={}
          for line in stateFiles[p]:gmatch('[^\n]+') do
            if not line:find('gendustry:industrial_apiary',1,true) or line=='machine t1 2 gendustry:industrial_apiary' then rows[#rows+1]=line end
          end
          stateFiles[p]=table.concat(rows,'\n')..'\n'
          add('a','princess',2); add('a','drone',2); stock.ga=sample('a'); stall=true; interruptAt=80
        '''
        _, _, lua=self.execute(setup)
        self.assertIn('queen',lua.globals().apiaries[1][2][1].name)
        self.assertIsNotNone(lua.globals().apiaries[1][2][2])
        self.assertEqual(len([v for v in lua.globals().loaded.values() if v.slot==1]),1)
        self.assertEqual(len([v for v in lua.globals().loaded.values() if v.slot==2]),2)
        lua.execute('stall=false; interruptAt=clock+40')
        self.invoke_auto(lua,action='resume')
        self.assertGreaterEqual(len([v for v in lua.globals().loaded.values() if v.slot==1]),2)

    def test_missing_mutatron_parent_returns_remaining_parent_and_replans(self):
        setup=r'''
          add('a','princess',1); add('a','drone',16); add('b','drone',17)
          stock.ga=sample('a'); stock.gb=sample('b'); stallProcessor='mutatron'; interruptAt=45
          local pull=require('event').pull
          require('event').pull=function(seconds)
            local result=pull(seconds)
            if processors[8][1] and processors[8][2] and not removedParent then
              processors[8][1]=nil; removedParent=true
            end
            return result
          end
        '''
        text, _, lua=self.execute(setup)
        self.assertTrue(lua.globals().removedParent)
        self.assertIn('incomplete pair returned; replanning',text)
        self.assertIsNone(lua.globals().processors[8][2])

    def test_targeted_recovery_frees_empty_mutatron_without_discarding_other_jobs(self):
        _, _, lua=self.execute("add('a','princess',1); add('a','drone',16); add('b','drone',17); stock.ga=sample('a'); stock.gb=sample('b'); stallProcessor='mutatron'; interruptAt=15")
        old=lua.globals().stateFiles['/home/.openbeekeeper-data/automation']
        before=len(list(lua.globals().lines.values()))
        lua.eval('function(src) return assert(load(src))("auto","recover","mutatron","empty") end')(runtime.SOURCE)
        refused='\n'.join(row.text for i,row in lua.globals().lines.items() if i>before)
        self.assertIn('No empty mutatron jobs',refused)
        self.assertEqual(lua.globals().stateFiles['/home/.openbeekeeper-data/automation'],old)
        lua.execute(r'''
          processors[8][1]=nil; processors[8][2]=nil
          local p='/home/.openbeekeeper-data/automation'; local ser=require('serialization')
          local s=ser.unserialize(stateFiles[p]); s.flows['999']={mode='queen',target='a',steps={'queen'},step=1}
          stateFiles[p]=ser.serialize(s)
        ''')
        before=len(list(lua.globals().lines.values()))
        lua.eval('function(src) return assert(load(src))("auto","recover","mutatron","empty") end')(runtime.SOURCE)
        text='\n'.join(row.text for i,row in lua.globals().lines.items() if i>before)
        self.assertIn('RECOVERED EMPTY MUTATRON',text)
        state=lua.eval("require('serialization').unserialize(stateFiles['/home/.openbeekeeper-data/automation'])")
        self.assertIsNotNone(state.flows['999'])
        self.assertEqual(len(list(state.flows.values())),1)
        self.assertIsNotNone(lua.globals().stateFiles['/home/.openbeekeeper-data/automation-recover-1'])

    def test_mutation_runs_without_imprinter_and_without_imprinting_parents(self):
        setup=r'''
          local p='/home/.openbeekeeper-data/modules'; local rows={}
          for line in stateFiles[p]:gmatch('[^\n]+') do
            if not line:match('^interface t[56] ') and not line:match('^machine t[56] ') then rows[#rows+1]=line end
          end
          stateFiles[p]=table.concat(rows,'\n')..'\n'
          add('a','princess',1); add('a','drone',16); add('b','drone',17)
          stock.ga=sample('a'); stock.gb=sample('b'); add('c','queen',1); stock.gc=sample('c'); interruptAt=25; stallProcessor='mutatron'
        '''
        text, _, lua=self.execute(setup)
        self.assertIn('breeding=false mutations=true',text)
        parents=[v for v in lua.globals().visits.values() if v.kind=='mutatron']
        self.assertEqual(len(parents),2)
        self.assertTrue(all('imprinted' not in v.nbt for v in parents))
        self.assertFalse(any(v.kind in {'analyzer','imprinter'} for v in lua.globals().visits.values()))
        self.assertTrue(any(v.uid=='c' and v.module==9 for v in lua.globals().loaded.values()))

    def test_mutatron_side_result_is_saved_and_not_reported_as_target(self):
        text, _, lua=self.execute("add('a','princess',6); add('a','drone',16); add('b','drone',17); stock.ga=sample('a'); stock.gb=sample('b'); mutationResult='side'; interruptAt=30")
        self.assertIn('MUTATION RESULT side wanted goal SIDE SPECIES SAVED', text)
        self.assertGreaterEqual(lua.globals().stock['side:drone'].size, 3)
        self.assertIsNone(lua.globals().stock['goal:drone'])

    def test_sampled_extinct_species_is_recreated_without_resampling(self):
        for gene_sample in ("sample('goal')", "{name='gendustry:gene_sample',label='Bee Sample - Species: goal',size=1}"):
            with self.subTest(sample=gene_sample):
                setup = ("add('a','princess',4); add('a','drone',16); add('b','drone',17); "
                         "stock.ga=sample('a'); stock.gb=sample('b'); stock.goalGene="+gene_sample+"; "
                         "mutationResult='goal'; interruptAt=300")
                text, _, lua = self.execute(setup)
                self.assertIn('MUTATION RESULT goal wanted goal MATCH', text)
                self.assertGreaterEqual(lua.globals().stock['goal:drone'].size, 16)
                self.assertNotIn('goal', list(lua.globals().sampled.values()))
                self.assertEqual(list(lua.globals().observedMutations.values()), ['goal'])

    def test_sampled_extinct_species_has_only_one_inflight_mutation(self):
        setup = ("add('a','princess',8); add('a','drone',16); add('b','drone',40); "
                 "stock.ga=sample('a'); stock.gb=sample('b'); stock.goalGene=sample('goal'); "
                 "stallProcessor='mutatron'; interruptAt=70")
        text, _, lua = self.execute(setup)
        self.assertEqual(text.count('FLOW mutate goal'), 1)
        self.assertEqual(len([v for v in lua.globals().visits.values() if v.kind=='mutatron']), 2)

    def test_sampled_species_with_living_queen_or_target_stock_is_not_remutated(self):
        for living in ("add('goal','queen',1); stall=true", "add('goal','drone',16)"):
            with self.subTest(living=living):
                setup = ("add('a','princess',4); add('a','drone',16); add('b','drone',17); "
                         "stock.ga=sample('a'); stock.gb=sample('b'); stock.goalGene=sample('goal'); "+living+"; interruptAt=70")
                text, _, lua = self.execute(setup)
                self.assertNotIn('FLOW mutate goal', text)
                self.assertEqual(list(lua.globals().observedMutations.values()), [])

    def test_conditional_recipes_are_dispatched_as_unverified_attempts(self):
        text, _, lua=self.execute("onlyConditional=true; add('a','princess',2); add('a','drone',16); add('b','drone',17); stock.ga=sample('a'); stock.gb=sample('b'); interruptAt=30")
        self.assertTrue(list(lua.globals().observedMutations.values()))
        self.assertIn('CONDITIONAL ATTEMPT goal Night requirements are not verified by OC',text)

    def test_roulette_is_retried_after_side_species_is_preserved(self):
        text, _, lua=self.execute("add('a','princess',6); add('a','drone',16); add('b','drone',17); stock.ga=sample('a'); stock.gb=sample('b'); stock.lab={name='gendustry:labware',label='Genetics Labware',size=1000}; interruptAt=900")
        self.assertEqual(list(lua.globals().observedMutations.values())[:2], ['side','goal'])
        self.assertIn('MUTATION RESULT goal wanted goal MATCH', text)

    def test_labware_refills_from_me_without_touching_template(self):
        text, _, lua=self.execute("add('a','princess',1); add('a','drone',15); stock.ga=sample('a'); processors[6][2]=nil; stock.lab={name='gendustry:labware',label='Genetics Labware',size=64}; interruptAt=50")
        self.assertEqual(lua.globals().stock['a:drone'].size, 18)
        self.assertEqual(lua.globals().processors[6][1].name, 'gendustry:gene_template')
        self.assertLess(lua.globals().stock.lab.size, 64)

    def test_opaque_nbt_mismatch_blocks_input(self):
        text, _, lua=self.execute("add('a','princess',1); add('a','drone',15); stock.ga=sample('a'); badNBT=true; interruptAt=30")
        self.assertIn('NBT differs', text)
        self.assertEqual(list(lua.globals().visits.values()), [])
        self.assertFalse(list(lua.globals().configurations[5].items()))

    def test_imprinter_routes_output_to_matching_job_after_reservation_order_changes(self):
        _, _, lua=self.execute(r'''
          add('a','drone',17); add('b','drone',17); holdOutput=true; interruptAt=18
          local move=devices.t6.transferItem
          devices.t6.transferItem=function(from,to,count,slot,destination)
            if from==0 and slot==4 and holdOutput then return 0 end
            return move(from,to,count,slot,destination)
          end
        ''')
        lua.execute(r'''
          local path='/home/.openbeekeeper-data/automation'
          local s=require('serialization').unserialize(stateFiles[path]); local current,nextJob
          local output=processors[6][4].individual.ident
          for _,f in pairs(s.flows) do
            if f.op and f.op.key=='t6:0' then
              if s.refs[f.d].uid==output then current=f else nextJob=f end
            end
          end
          assert(current and nextJob)
          current.op.order=100; current.op.capture=nil; nextJob.op.order=1; s.operationSeq=100
          stateFiles[path]=require('serialization').serialize(s)
          holdOutput=false; interruptAt=clock+60
        ''')
        text=self.invoke_auto(lua,action='resume')
        self.assertNotIn('Processor changed bee species/type',text)
        self.assertEqual(set(lua.globals().sampled.values()),{'a','b'})

    def test_changed_species_from_imprinter_is_quarantined(self):
        text, _, lua=self.execute("add('a','princess',1); add('a','drone',15); stock.ga=sample('a'); changeSpecies=true; interruptAt=40")
        self.assertIn('UNMATCHED IMPRINTER OUTPUT', text)
        self.assertEqual(len(list(lua.globals().loaded.values())), 0)
        self.assertIsNotNone(lua.globals().processors[6][4])

    def test_genetic_waste_does_not_block_all_automation(self):
        text, _, lua=self.execute("add('a','princess',2); add('a','drone',15); stock.ga=sample('a'); geneticDeath=true; interruptAt=70")
        self.assertIn('GENETIC LOSS imprinter a', text)
        self.assertGreaterEqual(lua.globals().stock['a:drone'].size, 16)

    def test_missing_honey_waits_before_feeding_and_does_not_fake_progress(self):
        text, _, lua=self.execute("add('a','princess',1); add('a','drone',15); stock.ga=sample('a'); noHoney=true; interruptAt=30")
        self.assertIn('Analyzer needs liquid honey', text)
        self.assertEqual(list(lua.globals().visits.values()), [])

    def test_resume_mid_processing_does_not_feed_duplicate_parent(self):
        text, _, lua=self.execute("add('a','princess',1); add('a','drone',15); stock.ga=sample('a'); interruptAt=3; stallProcessor='analyzer'")
        before=len(list(lua.globals().visits.values()))
        lua.execute("interruptAt=clock+45; stallProcessor=nil")
        lua.eval('function(src) return assert(load(src))("auto","resume") end')(runtime.SOURCE)
        self.assertEqual(lua.globals().stock['a:drone'].size, 18)
        self.assertEqual(before, 1)
        self.assertEqual(len([v for v in lua.globals().visits.values() if v.kind=='analyzer']), 2)

    def test_no_extra_me_inventory_query_for_samples_or_processors(self):
        _, _, lua=self.execute("add('a','drone',18); sampleFailures=1; interruptAt=80")
        calls=list(lua.globals().networkCalls.values())
        self.assertTrue(all(b-a>=20 for a,b in zip(calls,calls[1:])), calls)

    def test_partial_apiary_returns_retry_remainder(self):
        text, _, lua=self.execute("add('a','princess',1); add('a','drone',15); stock.ga=sample('a'); partialHarvest=true; interruptAt=90")
        self.assertEqual(lua.globals().stock['a:drone'].size, 18)
        self.assertTrue(any(r.requested>r.moved for r in lua.globals().harvested.values()))

    def test_resume_after_drone_loading_does_not_load_a_second_drone(self):
        text, _, lua=self.execute("add('a','princess',1); add('a','drone',15); stock.ga=sample('a'); failPrincess=true; interruptAt=30")
        self.assertEqual(len([r for r in lua.globals().loaded.values() if r.slot==2]), 1)
        lua.execute('failPrincess=false; interruptAt=clock+50')
        lua.eval('function(src) return assert(load(src))("auto") end')(runtime.SOURCE)
        self.assertEqual(lua.globals().stock['a:drone'].size, 18)
        self.assertEqual(len([r for r in lua.globals().loaded.values() if r.slot==2]), 1)

    def test_unowned_outputs_and_orphan_drone_are_returned_without_reloading(self):
        setup=r'''
          apiaries[1][2][2]=beeStack('a','drone',1)
          processors[6][4]=beeStack('b','drone',1)
          local move=devices.t1.transferItem
          devices.t1.transferItem=function(from,to,count,slot,destination)
            if from==2 and slot==2 then
              assert(not apiaries[1][2][1]); add('a','drone',count); apiaries[1][2][2]=nil; return count
            end
            return move(from,to,count,slot,destination)
          end
          stock.ga=sample('a'); stock.gb=sample('b'); interruptAt=3
        '''
        text, _, lua=self.execute(setup)
        self.assertIsNone(lua.globals().apiaries[1][2][2])
        self.assertIsNone(lua.globals().processors[6][4])
        self.assertEqual(lua.globals().stock['a:drone'].size,1)
        self.assertEqual(lua.globals().stock['b:drone'].size,1)
        self.assertEqual(len(list(lua.globals().loaded.values())),0)
        self.assertIn('Paused by Ctrl+C',text)

    def test_blocked_princess_releases_drone_and_apiary_for_retry(self):
        setup=r'''
          add('a','princess',1); add('a','drone',15); stock.ga=sample('a')
          failPrincess=true; interruptAt=40
          for n=1,4 do
            local module=n; local move=devices['t'..n].transferItem
            devices['t'..n].transferItem=function(from,to,count,slot,destination)
              if from~=1 and slot==2 then
                assert(not apiaries[module][from][1]); add('a','drone',count)
                apiaries[module][from][2]=nil; return count
              end
              return move(from,to,count,slot,destination)
            end
          end
        '''
        text, _, lua=self.execute(setup)
        self.assertIn('releasing unstarted work',text)
        for group in lua.globals().apiaries.values():
            for apiary in group.values():
                self.assertIsNone(apiary[2])
        lua.execute('failPrincess=false; interruptAt=clock+50')
        self.invoke_auto(lua,action='resume')
        self.assertEqual(lua.globals().stock['a:drone'].size,18)

    def test_status_is_read_only(self):
        _, _, lua=self.execute("add('a','drone',17); interruptAt=3; stallProcessor='analyzer'")
        calls=len(list(lua.globals().networkCalls.values())); visits=len(list(lua.globals().visits.values()))
        lua.eval('function(src) return assert(load(src))("auto","status") end')(runtime.SOURCE)
        self.assertEqual(len(list(lua.globals().networkCalls.values())), calls)
        self.assertEqual(len(list(lua.globals().visits.values())), visits)

    def test_previous_working_queen_is_adopted_without_reloading(self):
        code="""
          apiaries[1][2][1]=beeStack('a','queen',1)
          local s={schema='APIARY1',finished=false,jobs={['t1:2']={uid='a',phase='running'}}}
          stateFiles['/home/.openbeekeeper-data/apiary-run']=require('serialization').serialize(s)
          stock.ga=sample('a'); interruptAt=3
        """
        text, _, lua=self.execute(code)
        self.assertIn('Existing apiary jobs adopted', text)
        self.assertEqual(len(list(lua.globals().loaded.values())), 0)
        self.assertGreaterEqual(lua.globals().stock['a:drone'].size, 4)

    def test_last_drone_can_be_used_for_restoration_as_authorized(self):
        text, _, lua=self.execute("add('a','princess',3); add('a','drone',16); add('b','drone',1); stock.ga=sample('a'); interruptAt=25")
        self.assertIn('RESTORE USING LAST DRONE b', text)
        self.assertTrue(any(r.uid=='b' and r.kind=='analyzer' for r in lua.globals().visits.values()))

    def test_run_alias_uses_analysis_and_imprinting(self):
        lua=runtime.LuaRuntime(unpack_returned_tuples=True)
        lua.execute(runtime.HARNESS); lua.execute(FULL+"add('a','princess',1); add('a','drone',15); stock.ga=sample('a'); interruptAt=45")
        lua.eval('function(src) return assert(load(src))("run") end')(runtime.SOURCE)
        self.assertEqual(lua.globals().stock['a:drone'].size,18)
        self.assertEqual([v.kind for v in lua.globals().visits.values() if v.uid], ['analyzer','imprinter','analyzer','imprinter'])

    def test_long_queen_cycles_fill_four_modules_in_parallel(self):
        code="""
          for _,uid in ipairs({'a','b','c','d'}) do add(uid,'princess',1); add(uid,'drone',15); stock['gene:'..uid]=sample(uid) end
          stall=true; interruptAt=110
        """
        text, _, lua=self.execute(code)
        self.assertEqual({v.module for v in lua.globals().loaded.values()}, {1,2,3,4})
        self.assertEqual(len(list(lua.globals().loaded.values())),8)

    def test_blank_samples_refill_from_me(self):
        text, _, lua=self.execute("add('a','drone',17); processors[7][1]=nil; stock.blank={name='gendustry:gene_sample_blank',label='Blank Gene Sample',size=64}; interruptAt=60")
        self.assertEqual(lua.globals().stock['a:drone'].size,16)
        self.assertLess(lua.globals().stock.blank.size,64)

    def test_missing_resources_wait_instead_of_consuming_donor(self):
        text, _, lua=self.execute("add('a','drone',17); processors[7][1]=nil; interruptAt=60")
        self.assertIn('ME needs Blank Gene Sample',text)
        self.assertEqual(list(lua.globals().sampled.values()),[])

    def test_occupied_database_entry_survives_full_pipeline(self):
        text, _, lua=self.execute("dbSlots[1]={name='keep',size=1}; add('a','drone',17); interruptAt=60")
        self.assertEqual(lua.globals().dbSlots[1].name,'keep')

    def test_corrupt_automation_state_blocks_all_new_inputs(self):
        text, _, lua=self.execute("stateFiles['/home/.openbeekeeper-data/automation']='BROKEN'; add('a','drone',17); interruptAt=60")
        self.assertIn('Invalid AUTO1 journal',text)
        self.assertEqual(list(lua.globals().visits.values()),[])

    def test_crash_after_physical_input_transfer_is_not_replayed(self):
        code="""
          add('a','drone',17); interruptAt=60
          local original=devices.t5.transferItem
          devices.t5.transferItem=function(...)
            local moved=original(...)
            if not crashedOnce then crashedOnce=true; error('crash after physical transfer') end
            return moved
          end
        """
        text, _, lua=self.execute(code)
        self.assertIn('crash after physical transfer', text)
        lua.execute('interruptAt=clock+60')
        lua.eval('function(src) return assert(load(src))("auto") end')(runtime.SOURCE)
        self.assertEqual(len([v for v in lua.globals().visits.values() if v.kind=='analyzer']),1)
        self.assertEqual(lua.globals().stock['a:drone'].size,16)

    def test_processors_preserve_owned_database_refs_after_pause(self):
        text, _, lua=self.execute("add('a','drone',17); interruptAt=3; stallProcessor='analyzer'; dbSlots[1]={name='keep',size=1}")
        refs=[v for k,v in lua.globals().dbSlots.items() if k!=1]
        self.assertTrue(refs)
        self.assertEqual(lua.globals().dbSlots[1].name,'keep')

    def test_all_six_analyzer_inputs_are_used(self):
        _, _, lua=self.execute("for _,uid in ipairs({'a','b','c','d','e','f'}) do add(uid,'princess',1); add(uid,'drone',15); stock['gene:'..uid]=sample(uid) end; stallProcessor='analyzer'; interruptAt=3")
        self.assertEqual(sum(lua.globals().processors[5][slot] is not None for slot in range(3,9)),6)

    def test_several_princesses_of_same_species_can_fill_multiple_apiaries(self):
        text, _, lua=self.execute("add('a','princess',16); add('a','drone',20); stall=true; interruptAt=180")
        jobs=[v for v in lua.globals().loaded.values() if v.slot==1]
        self.assertNotIn('AUTO PAUSED: openbeekeeper',text)
        self.assertGreaterEqual(len(jobs),4)
        self.assertLessEqual(len(jobs),12)  # Sampling may reduce the target while preparation is in flight.
        self.assertEqual({v.module for v in jobs},{1,2,3,4})
        self.assertTrue(any(v.kind=='analyzer' and v.count>1 for v in lua.globals().visits.values()))

    def test_native_breeding_apiaries_also_incubate_matching_queens(self):
        setup=r'''
          local p='/home/.openbeekeeper-data/modules'; local rows={}
          for line in stateFiles[p]:gmatch('[^\n]+') do
            if not line:match('^interface t9 ') and not line:match('^machine t9 ') then rows[#rows+1]=line end
          end
          stateFiles[p]=table.concat(rows,'\n')..'\n'
          local c=require('serialization').unserialize(stateFiles['/home/.openbeekeeper-data/climate'])
          c.species.b={'HOT','ARID'}
          stateFiles['/home/.openbeekeeper-data/climate']=require('serialization').serialize(c)
          add('a','queen',1); add('b','queen',1); stock.ga=sample('a'); stock.gb=sample('b')
          stall=true; interruptAt=20
        '''
        _, _, lua=self.execute(setup,'check')
        lua.eval('function(src) return assert(load(src))("zones","breeding","native","NORMAL","NORMAL") end')(runtime.SOURCE)
        # Updating climate must not silently turn a breeding apiary into an incubator.
        lua.eval('function(src) return assert(load(src))("zones","climate","1","NORMAL","NORMAL") end')(runtime.SOURCE)
        c=lua.eval("require('serialization').unserialize(stateFiles['/home/.openbeekeeper-data/climate'])")
        self.assertTrue(all(role=='breeding' for role in c.roles.values()))
        text=self.invoke_auto(lua,action='resume')
        self.assertIn('mutations=true',text)
        loads=[v for v in lua.globals().loaded.values() if v.slot==1]
        self.assertEqual(len(loads),1)
        self.assertEqual(loads[0].uid,'a')
        self.assertIn(loads[0].module,{1,2,3,4})
        self.assertIn('HOT/ARID',text)

    def test_optional_modules_and_preflight_configuration(self):
        setup=r'''
          local p='/home/.openbeekeeper-data/modules'
          local rows={}
          for line in stateFiles[p]:gmatch('[^\n]+') do
            if not line:match('^interface t[78] ') and not line:match('^machine t[78] ') then rows[#rows+1]=line end
          end
          stateFiles[p]=table.concat(rows,'\n')..'\n'
          devices.me.getItemsInNetwork=function() error('CHECK MUST NOT READ ME') end
        '''
        text, _, lua=self.execute(setup,'check')
        self.assertIn('breeding=16 incubator=4',text)
        self.assertIn('mutatrons=0 samplers=0',text)
        self.assertIn('breeding=true mutations=false sampling=false',text)
        self.assertEqual(lua.globals().configurationsMade,0)
        lua.eval('function(src) return assert(load(src))("auto","config","batch","16") end')(runtime.SOURCE)
        self.assertIn('AUTO CONFIG batch=16',self.invoke_auto(lua,action='config'))
        lua.execute("devices.me.getItemsInNetwork=stockItems; add('a','princess',1); add('a','drone',15); stock.ga=sample('a'); interruptAt=45")
        self.invoke_auto(lua,action='resume')
        self.assertGreaterEqual(lua.globals().stock['a:drone'].size,16)

    def test_mutations_run_while_breeding_remains_queued(self):
        text, _, lua=self.execute("add('a','princess',4); add('a','drone',16); add('b','drone',17); add('c','princess',80); add('c','drone',20); stock.ga=sample('a'); stock.gb=sample('b'); stall=true; interruptAt=100")
        self.assertTrue(list(lua.globals().observedMutations.values()))
        self.assertIn('FLOW multiply c',text)
        self.assertIn('MUTATION RESULT',text)

    def test_reservations_do_not_duplicate_a_single_princess(self):
        _, _, lua=self.execute("add('a','princess',1); add('a','drone',15); stock.ga=sample('a'); stall=true; interruptAt=90")
        self.assertEqual(len([v for v in lua.globals().loaded.values() if v.slot==1]),1)

    def test_genome_unknown_to_climate_catalog_waits_without_queen_analysis(self):
        code="""
          add('unmapped','queen',1); interruptAt=35
        """
        text, _, lua=self.execute(code)
        self.assertIn('Unknown preferred climate for unmapped',text)
        self.assertFalse(any(v.kind=='analyzer' and v.uid=='unmapped' for v in lua.globals().visits.values()))
        self.assertEqual(len(list(lua.globals().loaded.values())),0)

    def test_incompatible_incubator_is_not_used(self):
        code="""
          add('a','queen',1); interruptAt=35
          local c=require('serialization').unserialize(stateFiles['/home/.openbeekeeper-data/climate'])
          c.species.a={'HOT','ARID'}
          stateFiles['/home/.openbeekeeper-data/climate']=require('serialization').serialize(c)
        """
        text, _, lua=self.execute(code)
        self.assertIn('No free incubator zone HOT/ARID',text)
        self.assertEqual(len(list(lua.globals().loaded.values())),0)

    def test_heater_dryer_are_included_in_zone_climate(self):
        code="""
          add('a','queen',1); interruptAt=30
          local c=require('serialization').unserialize(stateFiles['/home/.openbeekeeper-data/climate']); c.species.a={'HOT','ARID'}
          stateFiles['/home/.openbeekeeper-data/climate']=require('serialization').serialize(c)
          for side=2,5 do
            apiaries[9][side][4]={name='gendustry:apiary_upgrade',label='Heater Upgrade',size=1}
            apiaries[9][side][5]={name='gendustry:apiary_upgrade',label='Dryer Upgrade',size=1}
          end
        """
        text, _, lua=self.execute(code)
        self.assertTrue(any(v.module==9 for v in lua.globals().loaded.values()))

    def test_zone_command_explicitly_assigns_native_breeding_pool(self):
        lua=runtime.LuaRuntime(unpack_returned_tuples=True); lua.execute(runtime.HARNESS); lua.execute(FULL)
        lua.eval('function(src) return assert(load(src))("zones","breeding","native") end')(runtime.SOURCE)
        c=lua.eval('require("serialization").unserialize')(lua.globals().stateFiles['/home/.openbeekeeper-data/climate'])
        self.assertEqual(len(list(c.roles.items())),16)
        self.assertIsNone(c.roles['t9:2'])

    def test_sixteen_breeding_apiaries_can_be_used_without_two_bee_cap(self):
        code="""
          for i=1,16 do local uid='species'..i; add(uid,'princess',1); add(uid,'drone',15); stock['gene:'..uid]=sample(uid) end
          stall=true; interruptAt=350
        """
        _, _, lua=self.execute(code)
        parents=[v for v in lua.globals().loaded.values() if v.slot==1]
        self.assertEqual(len(parents),16)
        self.assertEqual({v.module for v in parents},{1,2,3,4})

    def test_emulators_are_automatically_classified_as_incubators(self):
        lua=runtime.LuaRuntime(unpack_returned_tuples=True); lua.execute(runtime.HARNESS); lua.execute(FULL)
        lua.eval('function(src) return assert(load(src))("zones") end')(runtime.SOURCE)
        text='\n'.join(v.text for v in lua.globals().lines.values())
        self.assertIn('incubator plains NORMAL NORMAL t9:2',text)

    def test_old_single_flow_queen_is_migrated_without_analyzer(self):
        code="""
          add('a','queen',1); stall=true; interruptAt=40
          local old={schema='AUTO1',refs={},apiaries={},seq=0,cycles=0,samples=0,mutations=0,migrated=true,
            flow={mode='queen',target='a',step=1,steps={'queen'},pendingP=beeStack('a','queen',1)}}
          stateFiles['/home/.openbeekeeper-data/automation']=require('serialization').serialize(old)
        """
        text, _, lua=self.execute(code)
        self.assertFalse(any(v.kind=='analyzer' and v.uid=='a' for v in lua.globals().visits.values()))
        self.assertTrue(any(v.module==9 for v in lua.globals().loaded.values()))

    def test_six_input_queue_resumes_without_duplicate_parents(self):
        code="""
          for _,uid in ipairs({'a','b','c','d','e','f'}) do add(uid,'princess',1); add(uid,'drone',15); stock['gene:'..uid]=sample(uid) end
          stall=true; stallProcessor='analyzer'; interruptAt=3
        """
        _, _, lua=self.execute(code)
        lua.execute("stallProcessor=nil; interruptAt=clock+180")
        lua.eval('function(src) return assert(load(src))("auto") end')(runtime.SOURCE)
        self.assertEqual(len([v for v in lua.globals().loaded.values() if v.slot==1]),6)
        self.assertEqual(len([v for v in lua.globals().visits.values() if v.kind=='analyzer']),12)

    def invoke_auto(self, lua, action='reset', command='auto'):
        before = len(list(lua.globals().lines.values()))
        lua.eval('function(src,cmd,action) return assert(load(src))(cmd,action) end')(runtime.SOURCE, command, action)
        return '\n'.join(row.text for i,row in lua.globals().lines.items() if i>before)

    def test_reset_stale_exact_request_archives_journals_and_preserves_configuration(self):
        text, _, lua = self.execute("add('a','drone',17); noSupply=true; dbSlots[1]={name='unrelated',size=1}; interruptAt=50")
        self.assertIn('Exact item not delivered within 15 seconds: a / drone', text)
        self.assertIn('Request cancelled; other jobs continue', text)
        lua.execute("""
          local p='/home/.openbeekeeper-data/automation'
          stateFiles[p..'.new']=stateFiles[p]
          stateFiles[p..'.bak']='distinct old backup'
          for _,v in pairs(devices) do
            if v.kind=='transposer' then v.transferItem=function() error('RESET MUST NOT MOVE ITEMS') end end
          end
          devices.me.getItemsInNetwork=function() error('RESET MUST NOT QUERY ME STOCK') end
        """)
        paths = ['/home/.openbeekeeper-data/'+name for name in ('modules','climate','roles')]
        config = {p:lua.globals().stateFiles[p] for p in paths}
        base = '/home/.openbeekeeper-data/automation'
        old = {ext:lua.globals().stateFiles[base+ext] for ext in ('','.new','.bak')}
        text = self.invoke_auto(lua)
        self.assertIn('AUTO RESET complete', text)
        for ext, archived in (('', '.main'), ('.new','.new'), ('.bak','.bak')):
            self.assertEqual(lua.globals().stateFiles[base+'-reset-1'+archived],old[ext])
        self.assertEqual({p:lua.globals().stateFiles[p] for p in paths}, config)
        self.assertEqual(lua.globals().dbSlots[1].name, 'unrelated')
        self.assertEqual(len(list(lua.globals().dbSlots.items())),1)
        self.assertIsNone(lua.globals().stateFiles[base+'.new'])
        self.assertEqual(lua.globals().stateFiles[base],lua.globals().stateFiles[base+'.bak'])
        lua.execute("dbSlots[2]={name='reused-after-reset',size=1}")
        self.assertIn('already complete',self.invoke_auto(lua,command='run'))
        self.assertEqual(lua.globals().dbSlots[2].name,'reused-after-reset')
        lua.execute("devices.me.getItemsInNetwork=function() return {} end; interruptAt=clock+3")
        self.assertNotIn('Exact item not delivered',self.invoke_auto(lua,action='resume'))

    def test_zero_stock_craftable_princess_template_is_never_requested(self):
        setup=r'''
          add('a','princess',1); add('a','drone',15); stock.ga=sample('a'); interruptAt=60
          phantom=beeStack('a','princess',0); phantom._nbt='old-captivity-template'
          local original=devices.me.store
          devices.me.store=function(filter,address,slot,count)
            if filter.name==phantom.name and filter.label==phantom.label and not filter.size then
              dbSlots[slot]=beeStack('a','princess',1); dbSlots[slot]._nbt=phantom._nbt; return true
            end
            return original(filter,address,slot,count)
          end
          local request=devices.if5.setInterfaceConfiguration
          devices.if5.setInterfaceConfiguration=function(slot,address,index,count)
            if address then assert(dbSlots[index]._nbt~=phantom._nbt,'PHANTOM PRINCESS REQUESTED') end
            return request(slot,address,index,count)
          end
        '''
        text, _, lua=self.execute(setup)
        self.assertNotIn('PHANTOM PRINCESS REQUESTED',text)
        self.assertIn('APIARY COMPLETE',text)
        self.assertEqual(lua.globals().stock['a:drone'].size,18)

    def test_changed_captivity_nbt_reselects_live_drone_and_repeats_imprinting(self):
        setup=r'''
          add('a','drone',17); interruptAt=90
          generationChanged=false; imprintRequests=0
          local original=devices.if6.setInterfaceConfiguration
          devices.if6.setInterfaceConfiguration=function(slot,address,index,count)
            if not address then return original(slot) end
            imprintRequests=imprintRequests+1
            local v=stock['a:drone']
            if not generationChanged then
              generationChanged=true; v._nbt='analyzed|raw|generations2'; v.individual.isAnalyzed=true
            end
            local previous=noSupply
            noSupply=dbSlots[index]._nbt~=v._nbt
            local result=original(slot,address,index,count); noSupply=previous
            return result
          end
        '''
        text, _, lua=self.execute(setup)
        self.assertIn('refresh live bee variant',text)
        self.assertGreaterEqual(lua.globals().imprintRequests,2)
        self.assertEqual(list(lua.globals().sampled.values()).count('a'),1)
        imprints=[v for v in lua.globals().visits.values() if v.kind=='imprinter']
        self.assertEqual(len(imprints),1)
        self.assertIn('generations2',imprints[0].nbt)

    def test_disappeared_bee_is_not_requested_again_after_next_me_snapshot(self):
        setup=r'''
          add('a','drone',17); noSupply=true; interruptAt=70
          requestsA=0
          local original=devices.if5.setInterfaceConfiguration
          devices.if5.setInterfaceConfiguration=function(slot,address,index,count)
            if address and dbSlots[index].individual.ident=='a' then
              requestsA=requestsA+1
              stock['a:drone'].size=0
            end
            return original(slot,address,index,count)
          end
        '''
        text, _, lua=self.execute(setup)
        self.assertEqual(lua.globals().requestsA,1)
        self.assertIn('REPLAN a',text)
        self.assertIsNone(lua.globals().configurations[5][9])
        state=lua.eval("require('serialization').unserialize(stateFiles['/home/.openbeekeeper-data/automation'])")
        self.assertEqual(len(list(state.flows.values())),0)
        self.assertEqual(len(list(state.refs.values())),0)
        calls=list(lua.globals().networkCalls.values())
        self.assertTrue(all(b-a>=20 for a,b in zip(calls,calls[1:])))

    def test_missing_exact_bee_waits_without_stopping_other_jobs_and_resumes(self):
        setup = r'''
          add('a','drone',17); add('b','princess',1); add('b','drone',15)
          stock.gb=sample('b'); interruptAt=100
          -- One shared imprinter must remain available to b while a is missing.
          local original=devices.if6.setInterfaceConfiguration
          devices.if6.setInterfaceConfiguration=function(slot,address,index,count)
            local previous=noSupply
            if address and dbSlots[index].individual.ident=='a' and not supplyA then noSupply=true end
            local result=original(slot,address,index,count); noSupply=previous; return result
          end
        '''
        text, _, lua = self.execute(setup)
        self.assertIn('Request cancelled; other jobs continue',text)
        self.assertGreater(lua.globals().cycles,0)
        self.assertGreaterEqual(lua.globals().stock['b:drone'].size,16)
        self.assertNotIn('a',list(lua.globals().sampled.values()))
        self.assertIsNone(lua.globals().configurations[6][9])
        lua.execute('supplyA=true; interruptAt=clock+80')
        self.invoke_auto(lua,action='resume')
        self.assertEqual(list(lua.globals().sampled.values()).count('a'),1)

    def test_explicit_empty_reset_discards_stale_work_but_checks_physical_slots(self):
        _, _, lua = self.execute("add('a','drone',17); stallProcessor='analyzer'; interruptAt=3; dbSlots[81]={name='unrelated',size=1}")
        def reset_empty():
            before = len(list(lua.globals().lines.values()))
            lua.eval('function(src) return assert(load(src))("auto","reset","empty") end')(runtime.SOURCE)
            return '\n'.join(row.text for i,row in lua.globals().lines.items() if i>before)
        self.assertIn('occupied analyzer', reset_empty())
        lua.execute("processors[5]={}; local p='/home/.openbeekeeper-data/automation'; local ser=require('serialization'); local s=ser.unserialize(stateFiles[p]); s.apiaries['t1:2']={uid='a'}; stateFiles[p]=ser.serialize(s)")
        self.assertIn('RESET REFUSED', self.invoke_auto(lua))
        self.assertIn('AUTO RESET complete', reset_empty())
        self.assertEqual(lua.globals().dbSlots[81].name, 'unrelated')
        self.assertIsNotNone(lua.globals().stateFiles['/home/.openbeekeeper-data/automation-reset-1.main'])
        self.assertIn('already complete', self.invoke_auto(lua))

    def test_reset_replans_from_current_base_bees_instead_of_old_me_snapshot(self):
        _, _, lua = self.execute("add('a','drone',17); noSupply=true; interruptAt=50")
        self.assertIn('AUTO RESET complete',self.invoke_auto(lua))
        lua.execute("stock['a:drone'].size=0; add('b','princess',1); add('b','drone',15); stock.gb=sample('b'); noSupply=false; interruptAt=clock+45")
        text = self.invoke_auto(lua,action='resume')
        self.assertIn('FLOW multiply b',text)
        self.assertNotIn('FLOW sample a',text)
        self.assertEqual(lua.globals().stock['b:drone'].size,18)

    def test_completed_reset_repairs_interrupted_final_backup_without_clearing_reused_slots(self):
        _, _, lua = self.execute("add('a','drone',17); noSupply=true; interruptAt=50")
        lua.execute("""
          local original=io.open
          io.open=function(path,mode)
            local file=original(path,mode)
            if path=='/home/.openbeekeeper-data/automation.bak' and mode=='w' then
              local write=file.write
              file.write=function(self,text)
                local s=serialValues[text]
                if s and s.lastResetArchive and not s.reset and not failedBackup then
                  failedBackup=true; error('crash final reset backup')
                end
                return write(self,text)
              end
            end
            return file
          end
        """)
        self.assertIn('crash final reset backup',self.invoke_auto(lua))
        lua.execute("dbSlots[1]={name='reused-after-reset',size=1}")
        self.assertIn('already complete',self.invoke_auto(lua))
        base='/home/.openbeekeeper-data/automation'
        self.assertEqual(lua.globals().stateFiles[base],lua.globals().stateFiles[base+'.bak'])
        self.assertEqual(lua.globals().dbSlots[1].name,'reused-after-reset')

    def test_reset_refuses_loaded_or_internal_processing_even_after_physical_input_disappears(self):
        for hide_input in (False,True):
            with self.subTest(internal=hide_input):
                _, _, lua = self.execute("add('a','drone',17); stallProcessor='analyzer'; interruptAt=3")
                if hide_input:
                    lua.execute('processors[5]={}')
                old = lua.globals().stateFiles['/home/.openbeekeeper-data/automation']
                text = self.invoke_auto(lua)
                self.assertIn('RESET REFUSED',text)
                self.assertEqual(lua.globals().stateFiles['/home/.openbeekeeper-data/automation'],old)
                self.assertIsNone(lua.globals().stateFiles['/home/.openbeekeeper-data/automation-reset-1.index'])

    def test_reset_refuses_inputs_and_unresolved_machine_ownership(self):
        blockers = (
            "apiaries[1][2][1]=beeStack('b','queen',1)",
            "s.apiaries['t1:2']={uid='b'}",
            "for _,f in pairs(s.flows) do f.op.feeds[1].armed=true end",
            "for _,f in pairs(s.flows) do f.op.feeds[1].loaded=true end",
        )
        for blocker in blockers:
            with self.subTest(blocker=blocker):
                _, _, lua = self.execute("add('a','drone',17); noSupply=true; interruptAt=50")
                lua.execute("interruptAt=nil; local p='/home/.openbeekeeper-data/automation'; local ser=require('serialization'); local s=ser.unserialize(stateFiles[p]); "+blocker+"; stateFiles[p]=ser.serialize(s)")
                before = lua.globals().stateFiles['/home/.openbeekeeper-data/automation']
                self.assertIn('RESET REFUSED',self.invoke_auto(lua))
                self.assertEqual(lua.globals().stateFiles['/home/.openbeekeeper-data/automation'],before)

    def test_reset_clears_bound_interface_requests_and_stale_resource_jobs(self):
        _, _, lua=self.execute("add('a','drone',17); noSupply=true; interruptAt=50")
        lua.execute(r'''
          local p='/home/.openbeekeeper-data/automation'; local ser=require('serialization')
          local s=ser.unserialize(stateFiles[p]); local id=next(s.refs)
          s.lease={interface='if5'}; s.leases={if6={interface='if6',owner=id}}
          s.resource=id; s.resources={old={ref=id,intention={}}}
          stateFiles[p]=ser.serialize(s)
          for n=1,9 do configurations[n][3]={name='minecraft:diamond',size=1} end
          configurations[5][9]=beeStack('a','drone',1)
          bins[5][9]=beeStack('a','drone',1); stock['a:drone'].size=stock['a:drone'].size-1
          devices.foreign={kind='me_interface',getInterfaceConfiguration=function() return {name='keep-me',size=1} end,
            setInterfaceConfiguration=function() error('UNBOUND INTERFACE MUST NOT BE CLEARED') end}
        ''')
        self.assertIn('AUTO RESET complete',self.invoke_auto(lua))
        for module in range(1,10):
            self.assertEqual(len(list(lua.globals().configurations[module].items())),0)
        self.assertIsNone(lua.globals().bins[5][9])
        base='/home/.openbeekeeper-data/automation'
        self.assertIsNotNone(lua.globals().stateFiles[base+'-reset-1.interfaces'])
        lua.execute("resetState=require('serialization').unserialize(stateFiles['/home/.openbeekeeper-data/automation'])")
        self.assertIsNone(lua.globals().resetState.resource)
        self.assertIsNone(lua.globals().resetState.lease)
        self.assertIn('already complete',self.invoke_auto(lua))

    def test_reset_returns_only_outputs_and_retries_blocked_partial_transfers(self):
        _, _, lua=self.execute("add('a','drone',17); stallProcessor='analyzer'; interruptAt=3")
        lua.execute(r'''
          processors[5]={}; partialFull=true; partialHarvest=true
          processors[5][9]=beeStack('a','drone',5)
          processors[6][4]=beeStack('b','princess',1)
          processors[7][4]={name='gendustry:gene_sample',label='Bee Sample - Species: b',size=1}
          processors[8][3]=beeStack('c','queen',1)
          apiaries[1][2][7]=beeStack('d','drone',4)
          local original=devices.t5.transferItem
          devices.t5.transferItem=function(...) if blockReset then return 0 end return original(...) end
          blockReset=true
          local originalClear=devices.db.clear
          devices.db.clear=function(slot) assert(not processors[5][9],'OUTPUTS MUST RETURN BEFORE DB CLEANUP'); return originalClear(slot) end
        ''')
        def reset_empty():
            before=len(list(lua.globals().lines.values()))
            lua.eval('function(src) return assert(load(src))("auto","reset","empty") end')(runtime.SOURCE)
            return '\n'.join(row.text for i,row in lua.globals().lines.items() if i>before)
        self.assertIn('Reset output transfer blocked',reset_empty())
        self.assertIsNotNone(lua.globals().stateFiles['/home/.openbeekeeper-data/automation-reset-1.main'])
        lua.execute('blockReset=false')
        self.assertIn('AUTO RESET complete',self.invoke_auto(lua))
        for module,slot in ((5,9),(6,4),(7,4),(8,3)):
            self.assertIsNone(lua.globals().processors[module][slot])
        self.assertIsNone(lua.globals().apiaries[1][2][7])
        self.assertEqual(lua.globals().processors[6][1].name,'gendustry:gene_template')
        self.assertEqual(lua.globals().processors[6][2].size,64)

    def test_reset_archive_failure_leaves_journal_and_owned_database_untouched(self):
        _, _, lua = self.execute("add('a','drone',17); noSupply=true; interruptAt=50")
        base='/home/.openbeekeeper-data/automation'
        before=lua.globals().stateFiles[base]
        lua.execute("""
          local original=io.open
          io.open=function(path,mode)
            if path:find('automation-reset-',1,true) and mode=='w' then return nil,'archive write failed' end
            return original(path,mode)
          end
          devices.db.clear=function() error('DATABASE MUST NOT BE CLEARED BEFORE ARCHIVE') end
        """)
        self.assertNotIn('DATABASE MUST NOT',self.invoke_auto(lua))
        self.assertEqual(lua.globals().stateFiles[base],before)
        self.assertIsNotNone(lua.globals().dbSlots[1])

    def test_reset_refuses_database_descriptor_replaced_externally(self):
        _, _, lua = self.execute("add('a','drone',17); noSupply=true; interruptAt=50")
        lua.execute("dbSlots[1]={name='unrelated-replacement',size=1}")
        self.assertIn('slot changed externally',self.invoke_auto(lua))
        self.assertEqual(lua.globals().dbSlots[1].name,'unrelated-replacement')

    def test_interrupted_reset_blocks_resume_and_never_clears_a_reused_slot(self):
        _, _, lua = self.execute("add('a','drone',17); noSupply=true; interruptAt=50")
        lua.execute("""
          local original=devices.db.clear
          devices.db.clear=function(slot) original(slot); error('crash after clear') end
        """)
        self.assertIn('crash after clear',self.invoke_auto(lua))
        self.assertIn('Reset cleanup is pending',self.invoke_auto(lua,action='resume'))
        lua.execute("dbSlots[1]=beeStack('a','drone',1); devices.db.clear=function(slot) dbSlots[slot]=nil end")
        self.assertIn('interrupted database clear is ambiguous',self.invoke_auto(lua))
        self.assertIsNotNone(lua.globals().dbSlots[1])
        lua.execute('dbSlots[1]=nil')
        self.assertIn('AUTO RESET complete',self.invoke_auto(lua))
        self.assertIsNone(lua.globals().stateFiles['/home/.openbeekeeper-data/automation-reset-2.index'])

    def test_embedded_runtime_matches_maintained_source(self):
        from tools.embed_automation import build_body
        maintained=build_body()
        body=runtime.SOURCE.split('-- BEGIN EMBEDDED AUTOMATION\n',1)[1].split('-- END EMBEDDED AUTOMATION\n',1)[0]
        self.assertEqual(body, maintained)


if __name__ == '__main__':
    unittest.main()
