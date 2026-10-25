"""Exercise the installer in Lua 5.2 with a disk and network simulation."""
from pathlib import Path
import unittest
import zlib

from lupa.lua52 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "install.lua").read_text(encoding="utf-8")
BASE = "https://raw.githubusercontent.com/CptFishHead/OpenBeekeeper/"
APP = "/home/.openbeekeeper/"
FILES = ("openbeekeeper.lua", "install.lua", "bees.lua", "VERSION", "README.md")

HARNESS = r'''
files={}; dirs={['/']=true,['/home']=true,['/usr']=true,['/usr/bin']=true}
messages={}; requests={}; failCount=0; tick=0; online=true
print=function(...) local p={}; for i=1,select('#',...) do p[i]=tostring(select(i,...)) end
  messages[#messages+1]=table.concat(p,' ') end
io.stderr={write=function(_,s) messages[#messages+1]=s end}
local function parent(path) return path:match('^(.*)/[^/]+$') or '/' end
local fs={}
fs.path=parent
fs.exists=function(path) return files[path]~=nil or dirs[path]==true end
fs.isDirectory=function(path) return dirs[path]==true end
fs.size=function(path) return files[path] and #files[path] or 0 end
fs.makeDirectory=function(path)
  if path=='' or path=='/' then return true end
  fs.makeDirectory(parent(path)); dirs[path]=true; return true
end
fs.remove=function(path)
  for k in pairs(files) do if k:sub(1,#path+1)==path..'/' then return nil,'not empty' end end
  for k in pairs(dirs) do if k:sub(1,#path+1)==path..'/' then return nil,'not empty' end end
  files[path]=nil; dirs[path]=nil; return true
end
fs.rename=function(source,destination)
  if files[source]==nil or files[destination]~=nil then return nil,'rename failed' end
  files[destination]=files[source]; files[source]=nil; return true
end
io.open=function(path,mode)
  if mode=='rb' and files[path]==nil then return nil,'missing' end
  if mode=='wb' then
    if not dirs[parent(path)] then return nil,'parent missing' end
    files[path]=''
  end
  local h={}
  h.read=function() return files[path] end
  h.write=function(_,content)
    if path==failPath and failCount>0 then failCount=failCount-1; files[path]=content:sub(1,2); return nil,'injected write failure' end
    files[path]=content; return true
  end
  h.flush=function() return true end
  h.close=function() return true end
  return h
end
loadfile=function(path) if not files[path] then return nil,'missing' end; return load(files[path],'@'..path) end
package.preload.filesystem=function() return fs end
package.preload.component=function() return {isAvailable=function(k) return k=='internet' and online end} end
package.preload.computer=function() return {uptime=function() tick=tick+1; return tick end} end
package.preload.shell=function() return {execute=function(command)
  local url,path=command:match('^wget %-fq (%S+) (%S+)$')
  assert(url and path,'unexpected shell command')
  requests[#requests+1]=url
  if url==failURL then return false end
  local content=remote[url]; if not content then return false end
  files[path]=content; return true
end} end
'''


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(HARNESS)
        self.run_chunk = self.lua.eval("function(src, ...) return assert(load(src,'installer'))(...) end")
        self.release()

    def release(self, revision="a" * 40, version="0.3.0", extra=""):
        payload = {name: (ROOT / name).read_bytes().decode("utf-8") for name in FILES}
        payload["VERSION"] = version + "\n"
        payload["openbeekeeper.lua"] += extra
        lines = ["OpenBeekeeper-package-1", "revision " + revision, "version " + version]
        for name, text in payload.items():
            blob = text.encode("utf-8")
            lines.append(f"file {name} {len(blob)} {zlib.adler32(blob):08x}")
        remote = {BASE + revision + "/" + k: v for k, v in payload.items()}
        remote[BASE + "main/package.manifest"] = "\n".join(lines) + "\n"
        self.lua.globals().remote = self.lua.table_from(remote)
        return payload

    @property
    def disk(self):
        return self.lua.globals().files

    @property
    def output(self):
        return "\n".join(self.lua.globals().messages.values())

    def run_manager(self, action="install"):
        return self.run_chunk(MANAGER, action)

    def test_install_and_offline_check(self):
        self.assertTrue(self.run_manager())
        self.assertIsNotNone(self.disk["/usr/bin/bees.lua"])
        self.assertIsNotNone(self.disk[APP + "install.lua"])
        self.lua.globals().online = False
        self.assertTrue(self.run_manager("check"))
        self.assertTrue(self.run_chunk(self.disk["/usr/bin/bees.lua"], "check"))

    def test_all_payload_downloads_are_pinned_to_one_commit(self):
        self.assertTrue(self.run_manager())
        urls = list(self.lua.globals().requests.values())
        self.assertEqual(len(urls), 6)
        self.assertTrue(all("/" + "a" * 40 + "/" in url for url in urls[1:]))

    def test_update_skips_unchanged_healthy_release(self):
        self.assertTrue(self.run_manager())
        before = len(self.lua.globals().requests)
        self.assertTrue(self.run_manager("update"))
        self.assertEqual(len(self.lua.globals().requests) - before, 1)
        self.assertIn("Already up to date", self.output)

    def test_reinstall_repairs_file_and_preserves_user_data(self):
        self.assertTrue(self.run_manager())
        expected = self.disk[APP + "openbeekeeper.lua"]
        self.disk[APP + "openbeekeeper.lua"] = "broken"
        self.disk["/home/.openbeekeeper-data/config.lua"] = "my configuration"
        self.assertFalse(self.run_manager("check"))
        self.assertTrue(self.run_manager("reinstall"))
        self.assertEqual(self.disk[APP + "openbeekeeper.lua"], expected)
        self.assertEqual(self.disk["/home/.openbeekeeper-data/config.lua"], "my configuration")

    def test_failed_download_does_not_replace_installed_files(self):
        self.assertTrue(self.run_manager())
        original = self.disk[APP + "VERSION"]
        self.release("b" * 40, "0.3.1")
        self.lua.globals().failURL = BASE + "b" * 40 + "/install.lua"
        self.assertFalse(self.run_manager("update"))
        self.assertEqual(self.disk[APP + "VERSION"], original)
        self.assertTrue(self.run_manager("check"))

    def test_corrupted_download_is_rejected_before_replacement(self):
        self.assertTrue(self.run_manager())
        original = self.disk[APP + "openbeekeeper.lua"]
        self.release("b" * 40, "0.3.1")
        self.lua.globals().remote[BASE + "b" * 40 + "/openbeekeeper.lua"] = "truncated"
        self.assertFalse(self.run_manager("update"))
        self.assertEqual(self.disk[APP + "openbeekeeper.lua"], original)

    def test_partial_target_write_rolls_back_every_file(self):
        self.assertTrue(self.run_manager())
        original = self.disk[APP + "openbeekeeper.lua"]
        self.release("b" * 40, "0.3.1", "\n-- new release\n")
        self.lua.globals().failPath = APP + "install.lua"
        self.lua.globals().failCount = 1
        self.assertFalse(self.run_manager("update"))
        self.assertEqual(self.disk[APP + "openbeekeeper.lua"], original)
        self.assertIsNone(self.disk["/home/.openbeekeeper-install/pending"])
        self.assertTrue(self.run_manager("check"))

    def test_explicit_rollback_restores_previous_release(self):
        self.assertTrue(self.run_manager())
        original = self.disk[APP + "package.manifest"]
        self.release("b" * 40, "0.3.1")
        self.assertTrue(self.run_manager("update"))
        self.assertTrue(self.run_manager("rollback"))
        self.assertEqual(self.disk[APP + "package.manifest"], original)
        self.assertTrue(self.run_manager("check"))

    def test_interrupted_install_can_recover_before_network_access(self):
        self.assertTrue(self.run_manager())
        self.release("b" * 40, "0.3.1")
        self.lua.globals().failPath = APP + "install.lua"
        self.lua.globals().failCount = 2  # fail replacement and immediate recovery
        self.assertFalse(self.run_manager("update"))
        self.assertIsNotNone(self.disk["/home/.openbeekeeper-install/pending"])
        self.lua.globals().online = False
        self.assertFalse(self.run_manager("reinstall"))  # recovery succeeds, network unavailable
        self.assertIsNone(self.disk["/home/.openbeekeeper-install/pending"])
        self.assertTrue(self.run_manager("check"))

    def test_manifest_path_traversal_is_rejected(self):
        self.lua.globals().remote[BASE + "main/package.manifest"] += "file ../outside 1 00000001\n"
        self.assertFalse(self.run_manager())
        self.assertIsNone(self.disk[APP + "openbeekeeper.lua"])

    def test_failed_recovery_pointer_write_does_not_poison_installation(self):
        self.assertTrue(self.run_manager())
        original = self.disk[APP + "package.manifest"]
        self.release("b" * 40, "0.3.1")
        self.lua.globals().failPath = "/home/.openbeekeeper-install/pending.new"
        self.lua.globals().failCount = 1
        self.assertFalse(self.run_manager("update"))
        self.assertIsNone(self.disk["/home/.openbeekeeper-install/pending"])
        self.assertEqual(self.disk[APP + "package.manifest"], original)
        self.assertTrue(self.run_manager("check"))


if __name__ == "__main__":
    unittest.main()
