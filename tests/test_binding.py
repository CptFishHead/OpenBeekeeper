"""Run real Lua binding logic against independent, scrambled ME/module routes."""
import unittest
import test_runtime as runtime

FIXTURE = r'''
buffers={}; configs={}; databaseSlots={}; stores=0; requests=0; machineMoves=0
routes={8,3,6,1,7,2,5,4}; delayed=false
local marker={name='minecraft:cobblestone',size=1}
devices.db={kind='database',get=function(slot) return databaseSlots[slot] end,
  clear=function(slot) databaseSlots[slot]=nil end}
for i=1,8 do
  local n=i; buffers[n]={}; configs[n]={}
  devices['t'..n]={kind='transposer',
    getInventoryName=function(side)
      if side==1 then return 'appliedenergistics2:interface' end
      if side==0 then return n<=4 and 'gendustry:industrial_apiary' or 'gendustry:imprinter' end
      return nil,'no inventory'
    end,
    getStackInSlot=function(side,slot)
      assert(side==1, 'MACHINE INVENTORY READ FORBIDDEN'); return buffers[n][slot]
    end,
    transferItem=function() machineMoves=machineMoves+1; error('MACHINE TRANSFER FORBIDDEN') end}
  devices['if'..n]={kind='me_interface',getItemsInNetwork=function() error('ME LIST FORBIDDEN') end,
    store=function(filter,address,slot,count)
      assert(filter.name=='minecraft:cobblestone' and address=='db' and count==1)
      stores=stores+1
      if noStone then return false end
      databaseSlots[slot]=marker; return true
    end,
    getInterfaceConfiguration=function(slot) return configs[n][slot] end,
    setInterfaceConfiguration=function(slot,address,dbSlot,count)
      assert(slot==9)
      if not address then
        if cleanupFails then error('cleanup offline') end
        configs[n][slot]=nil
        if not returnBlocked then buffers[routes[n]]={} end
        return true
      end
      requests=requests+1
      assert(address=='db' and count==1 and databaseSlots[dbSlot]==marker)
      configs[n][slot]=marker
      if not noSupply then buffers[routes[n]][1]=marker end
      if foreignItem then buffers[routes[n]][2]={name='minecraft:diamond',size=1} end
      return true
    end}
end
'''


class BindingTests(unittest.TestCase):
    def run_binding(self, setup="", command="bind"):
        return runtime.RuntimeTests().run_script(FIXTURE+setup, command)

    def test_eight_scrambled_routes_one_store_and_no_machine_transfers(self):
        text, _, lua = self.run_binding('callableMode=true')
        self.assertIn('Saved 8 module bindings', text)
        data=lua.globals().stateFiles['/home/.openbeekeeper-data/modules']
        for n, route in enumerate([8,3,6,1,7,2,5,4], 1):
            self.assertIn(f'interface t{route} 1 if{n}\n', data)
        self.assertEqual(lua.globals().stores, 1)
        self.assertEqual(lua.globals().requests, 8)
        self.assertEqual(lua.globals().machineMoves, 0)
        self.assertEqual(len(list(lua.globals().databaseSlots.items())), 0)
        self.assertIsNone(lua.globals().stateFiles['/home/.openbeekeeper-data/bind-pending'])

    def test_existing_database_descriptors_are_preserved(self):
        text, _, lua=self.run_binding("databaseSlots[1]=drone('keep.original')")
        self.assertIn('Saved 8', text)
        self.assertEqual(lua.globals().databaseSlots[1].individual.ident, 'keep.original')
        self.assertIsNone(lua.globals().databaseSlots[2])

    def test_existing_data_directory_does_not_get_created_again(self):
        text, _, lua=self.run_binding('''
          stateFiles['/home/.openbeekeeper-data']='DIRECTORY'
          require('filesystem').makeDirectory=function(path)
            error('file or directory with that name already exists')
          end
        ''')
        self.assertIn('Saved 8 module bindings', text)
        self.assertEqual(lua.globals().stores, 1)

    def test_existing_request_blocks_without_mutation(self):
        text, _, lua=self.run_binding('configs[5][2]={size=1}')
        self.assertIn('existing requests', text)
        self.assertEqual(lua.globals().stores, 0)
        self.assertIsNotNone(lua.globals().configs[5][2])

    def test_existing_buffer_blocks_without_mutation(self):
        text, _, lua=self.run_binding('buffers[3][1]=drone("keep")')
        self.assertIn('inventory must be empty', text)
        self.assertEqual(lua.globals().stores, 0)

    def test_missing_interface_blocks_before_store(self):
        text, _, lua=self.run_binding('devices.if8=nil')
        self.assertIn('modules=8, interfaces=7', text)
        self.assertEqual(lua.globals().stores, 0)

    def test_no_cobblestone_cleans_reserved_entry(self):
        text, _, lua=self.run_binding('noStone=true')
        self.assertIn('operation rejected', text)
        self.assertEqual(lua.globals().requests, 0)
        self.assertIsNone(lua.globals().stateFiles['/home/.openbeekeeper-data/bind-pending'])

    def test_delivery_timeout_cleans_request_and_does_not_publish(self):
        text, _, lua=self.run_binding('noSupply=true')
        self.assertIn('No marker delivered within 15 seconds', text)
        self.assertIsNone(lua.globals().configs[1][9])
        self.assertIsNone(lua.globals().stateFiles['/home/.openbeekeeper-data/modules'])

    def test_return_timeout_keeps_old_bindings_and_clears_request(self):
        text, _, lua=self.run_binding("returnBlocked=true; stateFiles['/home/.openbeekeeper-data/modules']='OLD'")
        self.assertIn('Interface did not empty', text)
        self.assertEqual(lua.globals().stateFiles['/home/.openbeekeeper-data/modules'], 'OLD')
        self.assertIsNone(lua.globals().configs[1][9])

    def test_foreign_item_never_enters_a_machine(self):
        text, _, lua=self.run_binding('foreignItem=true')
        self.assertIn('Unexpected item', text)
        self.assertEqual(lua.globals().machineMoves, 0)

    def test_cleanup_failure_keeps_journal_for_next_invocation(self):
        text, _, lua=self.run_binding('cleanupFails=true')
        self.assertIn('Cleanup pending', text)
        self.assertIsNotNone(lua.globals().stateFiles['/home/.openbeekeeper-data/bind-pending'])
        lua.execute('cleanupFails=false')
        run=lua.eval("function(source, ...) return assert(load(source))(... ) end")
        run(runtime.SOURCE, 'bind-reset')
        self.assertIsNone(lua.globals().configs[1][9])
        self.assertIsNone(lua.globals().databaseSlots[1])
        self.assertIsNone(lua.globals().stateFiles['/home/.openbeekeeper-data/bind-pending'])

    def test_partial_run_never_replaces_previous_complete_map(self):
        text, _, lua=self.run_binding("routes[2]=routes[1]; stateFiles['/home/.openbeekeeper-data/modules']='OLD'")
        self.assertIn('Several interface components map to one module', text)
        self.assertEqual(lua.globals().stateFiles['/home/.openbeekeeper-data/modules'], 'OLD')


if __name__ == '__main__':
    unittest.main()
