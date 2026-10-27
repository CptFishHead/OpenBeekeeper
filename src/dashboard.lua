-- OpenOS dashboard; event callbacks only record intent. Machine work stays serial.
local function newDashboard()
  local term=require('term')
  local unicode=require('unicode')
  local event=require('event')
  local computer=require('computer')
  local gpu=assert(component.gpu,'GPU unavailable')
  assert(term.isAvailable(),'Terminal unavailable')
  local w,h=gpu.getResolution()
  local originalW,originalH=w,h
  -- A 5x5 screen is square; character cells are approximately 1:2.
  if gpu.maxResolution and gpu.setResolution then
    local maxW,maxH=gpu.maxResolution()
    local squareW=math.min(maxW,maxH*2)
    if squareW>=60 and maxH>=30 then w,h=squareW,maxH; gpu.setResolution(w,h) end
  end
  assert(w>=60 and h>=18,'Dashboard needs at least 60x18 characters')
  local ui={started=computer.uptime(),logs={},input='',offset=0,taskOffset=0,
    updateText='Updates: press Check update',listeners={},version=(readText('/home/.openbeekeeper/VERSION') or '0.15.3'):gsub('%s+$','')}
  local honey={'   ────         ────    ','  ╱    ╲       ╱    ╲   ',' ╱      ╲─────╱      ╲  ',
    ' ╲      ╱     ╲      ╱  ','  ╲    ╱       ╲    ╱   ','   ────         ────    '}
  local oldFG,oldBG=gpu.getForeground(),gpu.getBackground()
  local blink=term.getCursorBlink and term.getCursorBlink()
  term.setCursorBlink(false)
  local painted={}
  local function short(s,n) return unicode.sub(tostring(s or ''),1,math.max(0,n)) end
  local function line(y,s,fg,bg)
    s=short(s,w); fg=fg or 0xF4E9B6; bg=bg or 0x18160F
    local old=painted[y]
    if old and old[1]==s and old[2]==fg and old[3]==bg then return end
    gpu.setBackground(bg); gpu.setForeground(fg)
    gpu.fill(1,y,w,1,' ')
    if bg==0x18160F then
      local tile=honey[(y-1)%#honey+1]
      gpu.setForeground(0x342C16)
      gpu.set(1,y,short(string.rep(tile,math.ceil(w/unicode.len(tile))),w))
      gpu.setForeground(fg)
    end
    gpu.set(1,y,s)
    painted[y]={s,fg,bg}
  end
  local function machine(key)
    local address,side=tostring(key):match('^(.-):(%d+)$')
    return (address or tostring(key)):sub(1,8)..(side and ':'..side or '')
  end
  local function label(uid) return tostring(uid or '?'):gsub('^forestry%.species','') end
  function ui.log(...)
    local parts={}; for i=1,select('#',...) do parts[i]=tostring(select(i,...)) end
    local text=table.concat(parts,' ')
    for row in (text..'\n'):gmatch('(.-)\n') do
      local length=unicode.len(row)
      for pos=1,math.max(1,length),w do
        ui.logs[#ui.logs+1]=unicode.sub(row,pos,pos+w-1)
        if #ui.logs>250 then table.remove(ui.logs,1) end
      end
    end
    ui.dirty=true
    if ui.render and computer.uptime()-(ui.lastDraw or -1)>=0.2 then ui.render() end
  end
  function ui.stop(action,commandLine)
    if ui.stopRequested then return end
    ui.dirty=true
    ui.action=action or 'stop'; ui.commandLine=commandLine; ui.stopRequested=true
  end
  local function submit()
    local text=ui.input:match('^%s*(.-)%s*$'); ui.input=''
    if text=='' then return end
    ui.log('> '..text)
    if text=='settings' then ui.page='conditions'; ui.taskOffset=0
    elseif text=='help' then ui.log('settings | status | check-update | update | exit | any OpenOS command (stops auto first)')
    elseif text=='status' then ui.log(ui.summary or 'Starting automation')
    elseif text=='check-update' then ui.checkPending=true
    elseif text=='exit' or text=='stop' then ui.stop()
    elseif text=='update' or text=='bees update' then ui.stop('update','bees update')
    else ui.stop('command',text) end
  end
  local function listen(name,handler)
    assert(event.listen(name,handler),'Cannot register '..name)
    ui.listeners[#ui.listeners+1]={name,handler}
  end
  local function closeRequest()
    if ui.request then pcall(ui.request.close); ui.request=nil end
  end
  function ui.pollUpdate()
    if ui.checkPending and not ui.request then
      ui.checkPending=false
      local ok,request=pcall(function()
        assert(component.isAvailable('internet'),'Internet card unavailable')
        return assert(component.internet.request('https://raw.githubusercontent.com/CptFishHead/OpenBeekeeper/main/VERSION?fresh='..math.floor(computer.uptime())))
      end)
      if ok then
        ui.request=request; ui.requestSince=computer.uptime(); ui.response=''; ui.updateText='Updates: checking...'
      else ui.updateText='Updates: '..tostring(request) end
    end
    if not ui.request then return end
    local ok,err=pcall(function()
      assert(computer.uptime()-ui.requestSince<15,'check timed out')
      if ui.request.finishConnect and not ui.request.finishConnect() then return end
      if ui.request.response then
        local status=ui.request.response(); assert(status==200,'HTTP '..tostring(status))
      end
      local chunk,reason=ui.request.read(128)
      assert(not reason,reason)
      if chunk then
        ui.response=ui.response..chunk; assert(#ui.response<=128,'oversized VERSION')
      else
        local remote=ui.response:match('^%s*(%d+%.%d+%.%d+)%s*$')
        assert(remote,'invalid VERSION')
        ui.updateText=remote==ui.version and ('Updates: up to date ('..remote..')') or ('Repository version: '..remote..' | installed: '..ui.version)
        closeRequest()
      end
    end)
    if not ok then closeRequest(); ui.updateText='Updates: '..tostring(err) end
  end
  function ui.render(st)
    if st then ui.state=st end
    st=ui.state or {flows={},apiaries={}}
    local width,height=gpu.getResolution()
    if width~=w or height~=h then painted={} end
    w,h=width,height
    assert(w>=60 and h>=18,'Dashboard resized below 60x18')
    ui.taskEnd=math.min(h-9,math.max(9,math.floor(h*0.45)))
    ui.logStart=ui.taskEnd+2
    local rows,actions={},{}; local ids={}
    for id in pairs(st.flows or {}) do ids[#ids+1]=id end
    table.sort(ids,function(a,b) return (tonumber(a) or 0)<(tonumber(b) or 0) end)
    for _,id in ipairs(ids) do
      local f=st.flows[id]
      rows[#rows+1]='#'..id..' '..f.mode..' '..label(f.target)..' | '..tostring(f.steps[f.step] or 'complete')
        ..' | '..(f.op and (machine(f.op.key)..' '..f.op.phase) or 'queued')..(f.cancelRequested and ' | CANCELLING' or '')..(f.wait and (' | '..f.wait) or '')
      actions[#rows]={kind='cancel',key=id,target=f.target}
    end
    local active=0; local keys={}
    for key in pairs(st.apiaries or {}) do keys[#keys+1]=key end; table.sort(keys)
    for _,key in ipairs(keys) do
      active=active+1; rows[#rows+1]='Apiary '..machine(key)..' | '..label(st.apiaries[key].uid)..' | '..(st.apiaries[key].cancelRequested and 'CANCELLING' or 'running')
      actions[#rows]={kind='cancelApiary',key=key,target=st.apiaries[key].uid}
    end
    local seconds=math.max(0,math.floor(computer.uptime()-ui.started))
    local time=string.format('%02d:%02d:%02d',math.floor(seconds/3600),math.floor(seconds/60)%60,seconds%60)
    ui.summary='Tasks: '..#ids..' | Apiaries: '..active..' | Cycles: '..(st.cycles or 0)..' | Mutations: '..(st.mutations or 0)..' | Samples: '..(st.samples or 0)
    line(1,' OpenBeekeeper '..ui.version..' | Uptime '..time,0x1B160A,0xE0A52B)
    line(2,ui.summary)
    line(3,ui.stopRequested and ' [ Stopping... ]' or ' [ Stop ]  [ Check update ]  [ Update ]  [ Settings ]',0xFFE28A,0x5C4516)
    line(4,ui.stopRequested and 'Finishing the current transfer and clearing ME requests...' or (ui.notice or ui.updateText),0xD1BA74)
    if ui.page then
      line(5,' [ Conditions ] [ Tasks ] [ Effects ] [ Back ] | '..ui.page:upper(),0xFFE28A,0x3D3115)
      local settings=ui.settings or {options={},conditions={}}
      if ui.confirm then
        local selected=ui.confirm
        rows={'DELETE '..(selected.kind=='cancel' and ('#'..selected.key) or ('Apiary '..machine(selected.key))),
          label(selected.target),'Finishes current operation; planner keeps running.',
          '[ Confirm delete ]   [ Back ]'}
        actions={}; actions[4]={kind='confirm'}
      elseif ui.page=='effects' then
        rows={'Negative effects: allowed [x] / blocked [ ]:'}; actions={}
        for _,rule in ipairs(settings.effects or {}) do
          rows[#rows+1]=((settings.options.effects or {})[rule.key]~=false and '[x] ' or '[ ] ')..rule.label..' ('..rule.count..' species)'
          actions[#rows]={kind='effect',key=rule.key}
        end
        rows[#rows+1]='Known species + visible genes; hidden hybrids may differ.'
      elseif ui.page=='conditions' then
        rows={}; actions={}
        local function checkbox(text,enabled,action)
          local prefix=enabled and '[x] ' or '[ ] '
          local width=math.max(1,w-5); local length=unicode.len(text)
          for pos=1,math.max(1,length),width do
            rows[#rows+1]=(pos==1 and prefix or '    ')..unicode.sub(text,pos,pos+width-1)
            actions[#rows]=action
          end
        end
        checkbox('Mutations',settings.options.mutations~=false,{kind='option',key='mutations'})
        checkbox('Gene sampling',settings.options.sampling~=false,{kind='option',key='sampling'})
        rows[#rows+1]='Recipe conditions (all must be allowed):'
        for _,text in ipairs(settings.conditions) do
          checkbox(text,(settings.options.conditions or {})[text]~=false,{kind='condition',key=text})
        end
        if #settings.conditions==0 then rows[#rows+1]='No special conditions reported by the catalogue.' end
      else
        for index,text in ipairs(rows) do rows[index]='[ Delete ] '..text end
        if #rows==0 then rows[1]='No current tasks.' end
      end
    else
      line(5,' CURRENT TASKS ('..#rows..') - click a task to delete; scroll to browse',0xFFE28A)
    end
    ui.rowActions=actions
    local taskHeight=ui.taskEnd-5
    ui.taskOffset=math.max(0,math.min(ui.taskOffset,math.max(0,#rows-taskHeight)))
    for y=6,ui.taskEnd do line(y,rows[ui.taskOffset+y-5] or '') end
    line(ui.taskEnd+1,' LOG '..(ui.offset>0 and '(scroll paused)' or '(live)'),0xFFE28A)
    local logHeight=h-2-ui.logStart
    ui.offset=math.max(0,math.min(ui.offset,math.max(0,#ui.logs-logHeight)))
    local first=math.max(1,#ui.logs-ui.offset-logHeight+1)
    for y=ui.logStart,h-3 do line(y,ui.logs[first+y-ui.logStart] or '',0xE4D9AA) end
    line(h-2,'Command | settings | help | Ctrl+C: stop | Other commands stop auto',0xD1BA74)
    line(h-1,'> '..unicode.sub(ui.input,math.max(1,unicode.len(ui.input)-w+4)),0xFFF3C4,0x3D3115)
    line(h,ui.page=='effects' and ' Species restrictions persist. No additional bee analysis.'
      or ui.page=='conditions' and ' Checkboxes allow attempts; the server validates recipe conditions.'
      or ui.page and ' Deleting a task keeps planner rules; jobs may be recreated.'
      or ' Stop/update preserve the queue; bees auto resumes.',0xD1BA74)
    ui.dirty=false; ui.lastDraw=computer.uptime()
  end
  function ui.pump()
    if ui.pumping then return end
    ui.pumping=true
    -- OpenOS dispatches listeners through computer.pullSignal. Drain queued
    -- input without sleeping, even while the executor is visiting many devices.
    if computer.pullSignal and computer.uptime()>=(ui.nextInputPoll or 0) then
      ui.nextInputPoll=computer.uptime()+0.1
      for _=1,32 do
        if not computer.pullSignal(0) then break end
        ui.dirty=true
      end
    end
    ui.pumping=nil
    if (ui.stopRequested and not ui.stopPainted)
        or (ui.dirty and computer.uptime()-(ui.lastDraw or -1)>=0.1) then
      ui.render(); ui.stopPainted=ui.stopRequested
    end
  end
  local ok,err=pcall(function()
    listen('interrupted',function() ui.stop(); return true end)
    listen('touch',function(_,screen,x,y)
      if screen~=gpu.getScreen() then return true end
      if y==3 then
        if x<=9 then ui.stop()
        elseif x<=27 then ui.checkPending=true
        elseif x<=39 then ui.stop('update','bees update')
        elseif x<=54 then
          if ui.page then ui.page=nil else ui.page='conditions' end
          ui.confirm=nil; ui.taskOffset=0
        end
      elseif y==5 and ui.page then
        ui.confirm=nil; ui.taskOffset=0
        if x<=16 then ui.page='conditions'
        elseif x<=26 then ui.page='tasks'
        elseif x<=38 then ui.page='effects'
        else ui.page=nil end
      elseif y>=6 and y<=(ui.taskEnd or 9) then
        local action=(ui.rowActions or {})[ui.taskOffset+y-5]
        if action then
          if action.kind=='cancel' or action.kind=='cancelApiary' then
            ui.confirm=action; ui.page='tasks'; ui.taskOffset=0
          elseif action.kind=='confirm' then
            if x<=20 then
              ui.actions=ui.actions or {}; ui.actions[#ui.actions+1]=ui.confirm
              ui.notice='Delete requested. Planner continues normally.'
            end
            ui.confirm=nil; ui.taskOffset=0
          else
            ui.actions=ui.actions or {}; ui.actions[#ui.actions+1]=action
            ui.notice='Policy change queued for the next safe checkpoint.'
          end
        end
      end
      return true
    end)
    listen('scroll',function(_,screen,x,y,direction)
      if screen~=gpu.getScreen() then return true end
      if y>=6 and y<= (ui.taskEnd or 9) then ui.taskOffset=math.max(0,ui.taskOffset-direction*3)
      elseif y>= (ui.logStart or 11) then ui.offset=math.max(0,ui.offset+direction*3) end
      return true
    end)
    listen('key_down',function(_,address,char,code)
      if char==3 then ui.stop()
      elseif code==28 then submit()
      elseif code==14 then ui.input=unicode.sub(ui.input,1,-2)
      elseif code==201 then ui.offset=ui.offset+5
      elseif code==209 then ui.offset=math.max(0,ui.offset-5)
      elseif char and char>=32 and unicode.len(ui.input)<512 then ui.input=ui.input..unicode.char(char) end
      return true
    end)
    listen('clipboard',function(_,address,value)
      ui.input=short(ui.input..tostring(value):gsub('[%c]',' '),512); return true
    end)
  end)
  function ui.close()
    closeRequest()
    for _,entry in ipairs(ui.listeners) do pcall(event.ignore,entry[1],entry[2]) end
    if gpu.setResolution then gpu.setResolution(originalW,originalH) end
    gpu.setBackground(oldBG); gpu.setForeground(oldFG)
    term.clear(); term.setCursor(1,1)
    if blink~=nil then term.setCursorBlink(blink) end
  end
  if not ok then ui.close(); error(err) end
  return ui
end
