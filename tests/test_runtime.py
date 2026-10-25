"""Execute the real standalone script in Lua 5.2 with read-only OC doubles."""
from pathlib import Path
import unittest

from lupa.lua52 import LuaRuntime

SOURCE = (Path(__file__).resolve().parents[1] / "openbeekeeper.lua").read_text(encoding="utf-8")

HARNESS = r'''
devices={}; lines={}; colour=0xFFFFFF
print=function(...)
  local parts={}; for i=1,select('#',...) do parts[i]=tostring(select(i,...)) end
  lines[#lines+1]={text=table.concat(parts,' '),colour=colour}
end
local gpu={getForeground=function() return colour end,setForeground=function(c) colour=c end}
package.preload.component=function() return {
  list=function() local keys={}; for k in pairs(devices) do keys[#keys+1]=k end
    local i=0; return function() i=i+1; local k=keys[i]; if k then return k,devices[k].kind end end end,
  methods=function(a) local m={}; for k,v in pairs(devices[a]) do if type(v)=='function' then m[k]=true end end; return m end,
  proxy=function(a) return devices[a] end,
  isAvailable=function(k) return k=='gpu' end, gpu=gpu
} end
package.preload.serialization=function() return {serialize=function(v) return 'SERIALIZED:'..v.name end} end
function worker(address,side,items)
  devices[address]={kind='transposer',
    getInventorySize=function(s) if s==side then return #items end return nil,'no inventory' end,
    getInventoryName=function() return 'gendustry:industrial_apiary' end,
    getStackInSlot=function(s,i) return items[i] end,
    transferItem=function() error('MUTATION FORBIDDEN') end}
end
function network(address,items,offline)
  devices[address]={kind='custom_server_me',
    getItemsInNetwork=function() if offline then return nil,'offline' end return items end,
    setInterfaceConfiguration=function() error('MUTATION FORBIDDEN') end}
end
function drone(id)
  return {name='forestry:bee_drone_ge',label='A drone',size=2,individual={ident=id}}
end
function sample(allele,chr)
  return {name='gendustry:gene_sample',label='Not trusted',size=1,
    tag={species='rootBees',chromosome=chr or 0,allele=allele}}
end
'''


class RuntimeTests(unittest.TestCase):
    def run_script(self, setup="", *args):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(HARNESS)
        lua.execute(setup)
        lua.eval("function(source, ...) return assert(load(source,'openbeekeeper'))(...) end")(SOURCE, *args)
        rows = [(row.text, row.colour) for row in lua.globals().lines.values()]
        return "\n".join(text for text, _ in rows), rows, lua

    def test_all_transposers_and_world_sides(self):
        text, _, _ = self.run_script("""
          worker('new-device-z',5,{drone('test.speciesZ')})
          worker('new-device-a',0,{drone('test.speciesA')})
        """)
        self.assertIn("Transposers: 2", text)
        self.assertIn("test.speciesZ", text)
        self.assertIn("test.speciesA", text)
        self.assertIn("Apiary adjacencies: 2", text)

    def test_no_devices_is_a_valid_diagnostic(self):
        text, _, _ = self.run_script()
        self.assertIn("Transposers: 0", text)
        self.assertIn("No items moved", text)

    def test_empty_slots_and_read_errors(self):
        text, _, _ = self.run_script("""
          worker('x',2,{{name='minecraft:air',size=1},{size=0}})
          devices.x.getStackInSlot=function(s,i) if i==2 then error('broken slot') end
            return {name='minecraft:air',size=1} end
        """)
        self.assertNotIn("minecraft:air", text)
        self.assertIn("broken slot", text)

    def test_me_discovery_uses_capabilities(self):
        text, _, _ = self.run_script("network('new-random-address',{})", "me")
        self.assertIn("custom_server_me", text)
        self.assertIn("Numbers are temporary", text)

    def test_probe_includes_bees_without_species_provider(self):
        text, _, _ = self.run_script("""
          network('a',{{name='forestry:bee_drone_ge',size=1}, sample('x'),sample('y'),sample('z')})
        """, "probe", "1")
        self.assertEqual(text.count("SERIALIZED:"), 3)
        self.assertIn("forestry:bee_drone_ge", text)

    def test_only_archive_species_sample_is_green(self):
        text, rows, lua = self.run_script("""
          network('a-stock',{drone('forestry.speciesDiligent'),sample('forestry.speciesNoble')})
          network('b-archive',{sample('forestry.speciesDiligent')})
        """, "map", "1", "2")
        diligent = [(t, c) for t, c in rows if t.startswith('[B]') and 'forestry.speciesDiligent' in t]
        self.assertEqual(len(diligent), 1)
        self.assertEqual(diligent[0][1], 0x55FF55)
        self.assertIn("[B] [G]", diligent[0][0])
        noble = [(t, c) for t, c in rows if t.startswith('[-]') and 'forestry.speciesNoble' in t]
        self.assertEqual(noble[0][1], 0xAAAAAA)
        self.assertEqual(lua.globals().colour, 0xFFFFFF)

    def test_missing_nbt_and_non_species_gene_cannot_turn_green(self):
        _, rows, _ = self.run_script("""
          network('a-stock',{drone('forestry.speciesDiligent')})
          network('b-archive',{{name='gendustry:gene_sample',label='Diligent',size=1,hasTag=true},
            sample('forestry.speciesDiligent',1)})
        """, "map", "1", "2")
        diligent = [(t, c) for t, c in rows if t.startswith('[B]') and 'forestry.speciesDiligent' in t]
        self.assertEqual(diligent[0][1], 0x55DDFF)
        self.assertIn("[?]", diligent[0][0])

    def test_archive_read_failure_is_unknown(self):
        text, rows, _ = self.run_script("network('a',{},true)", "map", "1", "1")
        self.assertIn("offline", text)
        self.assertIn("Archive not read", text)
        self.assertFalse(any(c == 0x55FF55 for _, c in rows))

    def test_invalid_network_selection_does_not_read_another(self):
        text, _, _ = self.run_script("network('a',{})", "map", "20", "30")
        self.assertIn("Use:", text)
        self.assertNotIn("BEE MAP", text)


if __name__ == "__main__":
    unittest.main()
