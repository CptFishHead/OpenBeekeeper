"""Execute real loading, queen cycles, bulk harvest and disk resume in Lua 5.2."""
import unittest
import test_runtime as runtime

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


class ExecutorTests(unittest.TestCase):
    def execute(self, setup='', *args):
        return runtime.RuntimeTests().run_script(FIXTURE+setup, 'run', *args)

    def test_four_species_distributed_across_four_modules_to_target(self):
        text, _, lua=self.execute("for _,uid in ipairs({'a','b','c','d'}) do add(uid,'princess',1); add(uid,'drone',31) end; callableMode=true")
        self.assertIn('REPRODUCTION: 16 apiaries', text)
        self.assertIn('Reproduction finished: cycles=4', text)
        self.assertEqual(lua.globals().cycles, 4)
        for uid in ('a','b','c','d'):
            self.assertEqual(lua.globals().stock[uid+':drone'].size, 34)
            self.assertEqual(lua.globals().stock[uid+':princess'].size, 1)
        self.assertEqual({r.module for r in lua.globals().loaded.values()}, {1,2,3,4})
        calls=list(lua.globals().networkCalls.values())
        self.assertTrue(all(b-a>=20 for a,b in zip(calls,calls[1:])), calls)
        self.assertTrue(any(r.requested==64 for r in lua.globals().harvested.values()))
        self.assertFalse(list(lua.globals().dbSlots.items()))

    def test_repeats_cycles_until_stock_reaches_32(self):
        text, _, lua=self.execute("add('a','princess',1); add('a','drone',1)")
        self.assertIn('cycles=11;', text)
        self.assertEqual(lua.globals().stock['a:drone'].size, 34)
        self.assertEqual(len(list(lua.globals().loaded.values())), 22)

    def test_exact_target_is_not_loaded_and_missing_parent_is_reported(self):
        text, _, lua=self.execute("add('a','princess',1); add('a','drone',32); add('b','drone',7)")
        self.assertIn('NEEDS PARENT b', text)
        self.assertIn('cycles=0;', text)
        self.assertEqual(len(list(lua.globals().loaded.values())), 0)

    def test_queen_in_me_can_finish_without_drone(self):
        text, _, lua=self.execute("add('a','queen',1); add('a','drone',30)")
        self.assertIn('cycles=1;', text)
        self.assertEqual(lua.globals().stock['a:drone'].size, 34)
        self.assertEqual(len(list(lua.globals().loaded.values())), 1)

    def test_partial_harvest_retries_remainder_without_losing_counts(self):
        text, _, lua=self.execute("add('a','princess',1); add('a','drone',31); partialHarvest=true")
        self.assertIn('Reproduction finished: cycles=1', text)
        self.assertEqual(lua.globals().stock['a:drone'].size, 34)
        self.assertTrue(any(r.requested>r.moved for r in lua.globals().harvested.values()))

    def test_failure_after_drone_load_resumes_without_loading_second_drone(self):
        text, _, lua=self.execute("add('a','princess',1); add('a','drone',31); failPrincess=true")
        self.assertIn('Parent transfer failed', text)
        self.assertEqual(len(list(lua.globals().loaded.values())), 1)
        lua.execute('failPrincess=false')
        lua.eval('function(src) return assert(load(src))("run","resume") end')(runtime.SOURCE)
        self.assertEqual(lua.globals().stock['a:drone'].size, 34)
        self.assertEqual(len([v for v in lua.globals().loaded.values() if v.slot==2]), 1)

    def test_interrupt_running_queen_requires_explicit_resume(self):
        text, _, lua=self.execute("add('a','princess',1); add('a','drone',31); interruptAt=1")
        self.assertIn('Paused by Ctrl+C', text)
        run=lua.eval('function(src, ...) return assert(load(src))(...) end')
        run(runtime.SOURCE,'run')
        self.assertEqual(len(list(lua.globals().loaded.values())), 2)
        self.assertIn('Unfinished run exists', '\n'.join(r.text for r in lua.globals().lines.values()))
        lua.execute('interruptAt=nil')
        run(runtime.SOURCE,'run','resume')
        self.assertEqual(lua.globals().stock['a:drone'].size, 34)
        self.assertEqual(len(list(lua.globals().loaded.values())), 2)

    def test_unowned_bees_and_outputs_are_never_collected(self):
        text, _, lua=self.execute("apiaries[1][2][1]=beeStack('keep','queen',1); apiaries[1][2][7]=beeStack('keep','princess',1); add('a','princess',1); add('a','drone',31); stall=true; interruptAt=2")
        self.assertIn('Paused', text)
        self.assertIsNotNone(lua.globals().apiaries[1][2][7])
        self.assertFalse(any(r.module==1 and r.side==2 for r in lua.globals().loaded.values()))

    def test_wrong_descriptor_never_requests_or_loads_bees(self):
        text, _, lua=self.execute("add('a','princess',1); add('a','drone',31); wrongDescriptor=true")
        self.assertIn('descriptor does not match', text)
        self.assertEqual(lua.globals().configurationsMade, 0)
        self.assertEqual(len(list(lua.globals().loaded.values())), 0)

    def test_existing_configuration_is_preserved_and_blocks_run(self):
        text, _, lua=self.execute("configurations[1][3]=beeStack('keep','drone',1); add('a','princess',1); add('a','drone',31)")
        self.assertIn('existing requests', text)
        self.assertIsNotNone(lua.globals().configurations[1][3])
        self.assertEqual(lua.globals().stores, 0)

    def test_supply_timeout_cleans_owned_requests(self):
        text, _, lua=self.execute("add('a','princess',1); add('a','drone',31); noSupply=true")
        self.assertIn('not delivered within 15 seconds', text)
        self.assertEqual(len(list(lua.globals().loaded.values())), 0)
        self.assertFalse(list(lua.globals().configurations[1].items()))
        self.assertFalse(list(lua.globals().dbSlots.items()))

    def test_occupied_database_entries_are_preserved(self):
        text, _, lua=self.execute("dbSlots[1]={name='keep',size=1}; add('a','princess',1); add('a','drone',31)")
        self.assertIn('Reproduction finished', text)
        self.assertEqual(lua.globals().dbSlots[1].name, 'keep')

    def test_failed_request_cleanup_is_recovered_before_resuming_loading(self):
        text, _, lua=self.execute("add('a','princess',1); add('a','drone',31); cleanupFails=true")
        self.assertIn('Request cleanup pending', text)
        lua.execute('cleanupFails=false')
        lua.eval('function(src) return assert(load(src))("run","resume") end')(runtime.SOURCE)
        self.assertEqual(lua.globals().stock['a:drone'].size, 34)
        self.assertEqual(len([v for v in lua.globals().loaded.values() if v.slot==2]), 1)
        self.assertFalse(list(lua.globals().dbSlots.items()))

    def test_status_does_not_change_requests_or_read_me(self):
        text, _, lua=self.execute("add('a','princess',1); add('a','drone',31); interruptAt=1")
        before=lua.globals().stores
        reads=len(list(lua.globals().networkCalls.values()))
        lua.eval('function(src) return assert(load(src))("run","status") end')(runtime.SOURCE)
        self.assertEqual(lua.globals().stores, before)
        self.assertEqual(len(list(lua.globals().networkCalls.values())), reads)

    def test_replaced_bound_interface_blocks_without_me_reads(self):
        text, _, lua=self.execute("devices.if1=nil; add('a','princess',1); add('a','drone',31)")
        self.assertIn('Missing bound interface', text)
        self.assertEqual(lua.globals().stores, 0)
        self.assertEqual(len(list(lua.globals().networkCalls.values())), 0)

    def test_corrupt_primary_journal_never_replays_stale_backup(self):
        text, _, lua=self.execute("stateFiles['/home/.openbeekeeper-data/apiary-run']='CORRUPT'; add('a','princess',1); add('a','drone',31)")
        self.assertIn('Invalid run journal', text)
        self.assertEqual(lua.globals().stores, 0)

    def test_stalled_cycle_can_resume_after_power_or_environment_repair(self):
        text, _, lua=self.execute("add('a','princess',1); add('a','drone',31); stall=true")
        self.assertIn('stalled for 900 polling cycles', text)
        lua.execute('stall=false')
        lua.eval('function(src) return assert(load(src))("run","resume") end')(runtime.SOURCE)
        self.assertEqual(lua.globals().stock['a:drone'].size, 34)


if __name__ == '__main__':
    unittest.main()
