"""Exercise the real dashboard with the machine executor and OpenOS event doubles."""
import unittest
import test_automation as automation
import test_runtime as runtime

DISPLAY = r'''
uiHandlers={}; uiRows={}; uiCells={}; uiHistory={}; shellCommands={}; uiWidth=80; uiHeight=25
local gpu=require('component').gpu
local background=0
function gpu.getBackground() return background end
function gpu.setBackground(value) background=value end
function gpu.getResolution() return uiWidth,uiHeight end
function gpu.maxResolution() return 160,50 end
function gpu.setResolution(w,h) uiWidth=w; uiHeight=h; return true end
function gpu.getScreen() return 'screen' end
function gpu.fill(x,y,w,h,char)
 assert(x>=1 and y>=1 and x+w-1<=uiWidth and y+h-1<=uiHeight)
 uiRows[y]=''; uiCells[y]={}; for x=1,uiWidth do uiCells[y][x]={char=' ',fg=colour,bg=background} end
end
function gpu.set(x,y,text)
 assert(x>=1 and y>=1 and y<=uiHeight)
 for i=1,require('unicode').len(text) do
  assert(x+i-1<=uiWidth); uiCells[y][x+i-1]={char=require('unicode').sub(text,i,i),fg=colour,bg=background}
 end
 uiRows[y]=text; uiHistory[#uiHistory+1]={text=text,fg=colour,bg=background}; return true
end
package.preload.unicode=function() return {
 sub=function(s,a,b)
  local chars={}; for c in s:gmatch('[%z\1-\127\194-\244][\128-\191]*') do chars[#chars+1]=c end
  a=a or 1; b=b or #chars
  if a<0 then a=#chars+a+1 end; if b<0 then b=#chars+b+1 end
  local out={}; for i=math.max(1,a),math.min(#chars,b) do out[#out+1]=chars[i] end
  return table.concat(out)
 end,
 len=function(s) local n=0; for _ in s:gmatch('[%z\1-\127\194-\244][\128-\191]*') do n=n+1 end; return n end,
 char=string.char
} end
package.preload.term=function() return {
 isAvailable=function() return true end,getCursorBlink=function() return false end,
 setCursorBlink=function() end,setCursor=function() end,
 clear=function() uiFinalRows={}; for y,row in pairs(uiRows) do uiFinalRows[y]=row end end
} end
local event=require('event')
event.listen=function(name,handler) uiHandlers[name]=handler; return true end
event.ignore=function(name,handler) assert(uiHandlers[name]==handler); uiHandlers[name]=nil; return true end
package.preload.shell=function() return {execute=function(command)
 for _,config in pairs(configurations) do assert(config[9]==nil,'COMMAND RAN BEFORE CLEANUP') end
 shellCommands[#shellCommands+1]=command; return true
end} end
local pull=event.pull
event.pull=function(seconds)
 local result=pull(seconds)
 if uiAction and clock>=uiAt and not uiSent then
  uiSent=true
  if uiAction=='stop' then uiHandlers.touch('touch','screen',3,3)
  elseif uiAction=='command' then
   uiHandlers.clipboard('clipboard','keyboard','bees auto status')
   uiHandlers.key_down('key_down','keyboard',13,28)
  elseif uiAction=='update' then uiHandlers.touch('touch','screen',32,3)
  end
 end
 return result
end
'''

class DashboardTests(unittest.TestCase):
    def launch(self, setup):
        return runtime.RuntimeTests().run_script(automation.FULL+DISPLAY+setup,'ui')

    def test_dashboard_theme_tasks_logs_and_stop_preserve_executor_state(self):
        text, _, lua=self.launch("add('a','princess',1); add('a','drone',15); stock.ga=sample('a'); stall=true; uiAction='stop'; uiAt=25")
        frames=[row.text for row in lua.globals().uiHistory.values()]
        self.assertTrue(any('Uptime' in row for row in frames))
        self.assertTrue(any('CURRENT TASKS' in row for row in frames))
        self.assertTrue(any('PROCESS' in row for row in frames))
        self.assertTrue(any('running' in row for row in frames))
        self.assertTrue(any(row.fg==0x342C16 for row in lua.globals().uiHistory.values()))
        self.assertIn('Automation paused; queue preserved',text)
        self.assertEqual((lua.globals().uiWidth,lua.globals().uiHeight),(80,25))
        self.assertEqual(len(list(lua.globals().uiHandlers.values())),0)
        self.assertEqual(len([v for v in lua.globals().loaded.values() if v.slot==1]),1)
        for config in lua.globals().configurations.values():
            self.assertIsNone(config[9])

    def test_exit_during_armed_transfer_finishes_transfer_before_stopping(self):
        setup=r'''
          add('a','drone',17); stallProcessor='analyzer'
          local get=devices.t5.getStackInSlot
          devices.t5.getStackInSlot=function(side,slot)
            if side==1 and slot==9 and not stoppedDuringArm then
              local raw=stateFiles['/home/.openbeekeeper-data/automation']
              local s=raw and require('serialization').unserialize(raw)
              for _,f in pairs(s and s.flows or {}) do
                if f.op and f.op.feeds[1].armed then
                  stoppedDuringArm=true; uiHandlers.touch('touch','screen',3,3)
                end
              end
            end
            return get(side,slot)
          end
        '''
        _, _, lua=self.launch(setup)
        self.assertTrue(lua.globals().stoppedDuringArm)
        self.assertEqual(len([v for v in lua.globals().visits.values() if v.kind=='analyzer']),1)
        state=lua.eval("require('serialization').unserialize(stateFiles['/home/.openbeekeeper-data/automation'])")
        flow=next(iter(state.flows.values()))
        self.assertTrue(flow.op.feeds[1].loaded)
        self.assertIsNotNone(lua.globals().processors[5][3])

    def test_exit_interrupts_me_cooldown_without_waiting_twenty_seconds(self):
        setup=r"clock=5; stateFiles['/home/.openbeekeeper-data/me-last-read']='test-computer 5\n'; uiAction='stop'; uiAt=6"
        text, _, lua=self.launch(setup)
        self.assertIn('Automation paused; queue preserved',text)
        self.assertLess(lua.globals().clock,7)
        self.assertEqual(len(list(lua.globals().networkCalls.values())),0)
        self.assertEqual(len(list(lua.globals().uiHandlers.values())),0)

    def test_command_and_update_run_only_after_interface_cleanup(self):
        for action,command in [('command','bees auto status'),('update','bees update')]:
            with self.subTest(action=action):
                _, _, lua=self.launch("add('a','drone',17); noSupply=true; uiAction='"+action+"'; uiAt=3")
                self.assertEqual(list(lua.globals().shellCommands.values()),[command])
                self.assertEqual(len(list(lua.globals().uiHandlers.values())),0)
                state=lua.eval("require('serialization').unserialize(stateFiles['/home/.openbeekeeper-data/automation'])")
                self.assertEqual(len(list(state.leases.values())),0)

    def test_update_check_is_nonblocking_and_does_not_install(self):
        setup=r'''
          local component=require('component'); local available=component.isAvailable
          component.isAvailable=function(kind) return kind=='internet' or available(kind) end
          local chunks={'0.12.1\n'}; local reads=0
          component.internet={request=function(url)
            assert(url:find('/VERSION?',1,true))
            return {finishConnect=function() return true end,response=function() return 200 end,
              read=function() reads=reads+1; return chunks[reads] end,close=function() end}
          end}
          local pull=require('event').pull
          require('event').pull=function(seconds)
            local result=pull(seconds)
            if not checked then checked=true; uiHandlers.touch('touch','screen',15,3) end
            return result
          end
          uiAction='stop'; uiAt=8
        '''
        _, _, lua=self.launch(setup)
        self.assertTrue(any('Repository version: 0.12.1' in row.text for row in lua.globals().uiHistory.values()))
        self.assertEqual(len(list(lua.globals().shellCommands.values())),0)
