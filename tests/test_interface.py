"""One-drone interface route: mutation boundaries and cleanup failures."""
import unittest
import test_runtime as runtime
SOURCE = runtime.SOURCE

FIXTURE = r'''
databaseEntry=nil; config={}; bufferItem=nil; delivered=nil; moves=0; stores=0
local function cultivated()
  local v=drone('forestry.speciesCultivated'); v.label='Cultivated Drone'; v.size=1; return v
end
devices.database={kind='database',get=function(slot) assert(slot==1); return databaseEntry end,
  clear=function(slot) assert(slot==1); databaseEntry=nil end}
devices.interface={kind='me_interface',
  getItemsInNetwork=function() return {cultivated()} end,
  store=function(filter,address,slot,count)
    assert(address=='database' and slot==1 and count==1)
    assert(filter.name=='forestry:bee_drone_ge' and filter.label=='Cultivated Drone')
    stores=stores+1; databaseEntry=cultivated()
    if wrongDescriptor then databaseEntry=drone('forestry.speciesForest') end
  end,
  getInterfaceConfiguration=function(slot) return config[slot] end,
  setInterfaceConfiguration=function(slot,address,dbSlot,count)
    assert(slot==1)
    if not address then
      if cleanupFails then error('cleanup unavailable') end
      config[slot]=nil; bufferItem=nil; return true
    end
    assert(address=='database' and dbSlot==1 and count==1)
    config[slot]=cultivated()
    if not noSupply then bufferItem=cultivated() end
    if occupyDuringSupply then queenNow=drone('forestry.speciesForest') end
    return true
  end}
devices.transposer={kind='transposer',
  getInventoryName=function(side)
    if side==1 then return 'appliedenergistics2:interface' end
    if side>=2 and side<=5 then return 'gendustry:industrial_apiary' end
    return nil,'no inventory'
  end,
  getStackInSlot=function(side,slot)
    if side==1 then if slot==4 then return bufferItem end; return nil end
    if side==2 and slot==1 then return queenNow end
    if side==2 and slot==2 then return delivered end
  end,
  transferItem=function(source,dest,count,sourceSlot,destSlot)
    assert(source==1 and dest==2 and count==1 and sourceSlot==4 and destSlot==2)
    moves=moves+1
    if transferFails then return 0 end
    delivered=bufferItem; bufferItem=nil; return 1
  end}
'''


class InterfaceTests(unittest.TestCase):
    def execute(self, setup=""):
        return runtime.RuntimeTests().run_script(FIXTURE + setup, "interface-test")

    def test_one_drone_transferred_then_request_and_database_cleared(self):
        text, _, lua = self.execute("callableMode=true")
        self.assertIn("SUCCESS: one Cultivated Drone", text)
        self.assertEqual(lua.globals().moves, 1)
        self.assertEqual(lua.globals().delivered.size, 1)
        self.assertIsNone(lua.globals().config[1])
        self.assertIsNone(lua.globals().databaseEntry)
        self.assertIsNone(lua.globals().stateFiles['/home/.openbeekeeper-data/interface-test-pending'])

    def test_existing_database_entry_is_preserved(self):
        text, _, lua = self.execute("databaseEntry=drone('keep.original')")
        self.assertIn("Database entry 1 must be empty", text)
        self.assertEqual(lua.globals().databaseEntry.individual.ident, 'keep.original')
        self.assertEqual(lua.globals().stores, 0)
        self.assertEqual(lua.globals().moves, 0)

    def test_existing_interface_request_is_preserved(self):
        text, _, lua = self.execute("config[2]=drone('keep.original')")
        self.assertIn("All interface requests must be empty", text)
        self.assertIsNotNone(lua.globals().config[2])
        self.assertEqual(lua.globals().stores, 0)

    def test_wrong_descriptor_does_not_configure_or_transfer(self):
        text, _, lua = self.execute("wrongDescriptor=true")
        self.assertIn("not the expected drone", text)
        self.assertEqual(lua.globals().moves, 0)
        self.assertIsNone(lua.globals().databaseEntry)

    def test_failed_transfer_still_clears_request(self):
        text, _, lua = self.execute("transferFails=true")
        self.assertIn("Drone transfer failed", text)
        self.assertIsNone(lua.globals().config[1])
        self.assertIsNone(lua.globals().databaseEntry)

    def test_supply_timeout_clears_request_without_transfer(self):
        text, _, lua = self.execute("noSupply=true")
        self.assertIn("within 9 seconds", text)
        self.assertEqual(lua.globals().moves, 0)
        self.assertIsNone(lua.globals().config[1])

    def test_new_queen_in_destination_blocks_transfer(self):
        text, _, lua = self.execute("occupyDuringSupply=true")
        self.assertIn("no longer empty", text)
        self.assertEqual(lua.globals().moves, 0)
        self.assertIsNone(lua.globals().config[1])

    def test_failed_cleanup_leaves_recoverable_journal(self):
        text, _, lua = self.execute("cleanupFails=true")
        self.assertIn("Request cleanup failed", text)
        self.assertIsNotNone(lua.globals().stateFiles['/home/.openbeekeeper-data/interface-test-pending'])
        lua.execute("cleanupFails=false")
        lua.eval("function(source, ...) return assert(load(source))(... ) end")(SOURCE, "interface-reset")
        self.assertIsNone(lua.globals().config[1])
        self.assertIsNone(lua.globals().databaseEntry)
        self.assertIsNone(lua.globals().stateFiles['/home/.openbeekeeper-data/interface-test-pending'])


if __name__ == "__main__":
    unittest.main()
