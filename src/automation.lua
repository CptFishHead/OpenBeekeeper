-- Embedded in openbeekeeper.lua by tools/embed_automation.py; no runtime module dependency.
local function automate()
  local fs=require("filesystem")
  local ser=require("serialization")
  local computer=require("computer")
  local event=require("event")
  local dir="/home/.openbeekeeper-data/"
  local path=dir.."automation"
  local optionsPath=dir..'automation-options'
  local methodOwners={}
  for _,entries in ipairs({transposers,networks,catalogues,tools.databases}) do
    for _,entry in ipairs(entries) do
      for name in pairs(entry.methods or {}) do
        local method=entry.proxy[name]
        if method~=nil then methodOwners[method]=entry.address..'.'..name end
      end
    end
  end
  local function call(method,...)
    if dashboard then
      dashboard.pump()
      if dashboard.stopRequested and not dashboard.critical and not dashboard.cleaning then error('Stopped from dashboard') end
    end
    local value,err=read(method,...)
    assert(not err,(methodOwners[method] or 'Component call')..': '..tostring(err))
    return value
  end
  local function parse(text,schema)
    local ok,value=pcall(ser.unserialize,text)
    assert(ok and type(value)=="table" and value.schema==schema,"Invalid "..schema.." journal; preserve it")
    return value
  end
  local options=readText(optionsPath..'.new') or readText(optionsPath)
  options=options and parse(options,'AUTOOPTIONS1') or {schema='AUTOOPTIONS1',batch=64,queue=0,mutations=true,sampling=true}
  assert(type(options.batch)=='number' and options.batch%1==0 and options.batch>=1 and options.batch<=64
    and type(options.queue)=='number' and options.queue%1==0 and options.queue>=0 and options.queue<=128
    and type(options.mutations)=='boolean' and type(options.sampling)=='boolean','Invalid automation options; preserve configuration')
  options.conditions=options.conditions or {}
  assert(type(options.conditions)=='table','Invalid condition policy')
  for key,value in pairs(options.conditions) do
    assert(type(key)=='string' and type(value)=='boolean','Invalid condition policy entry')
  end
  local function saveOptions()
    if not fs.exists(dir) then assert(fs.makeDirectory(dir)) end
    local text=ser.serialize(options)
    writeText(optionsPath..'.new',text)
    assert(readText(optionsPath..'.new')==text,'Options verification failed')
    if fs.exists(optionsPath) then assert(fs.remove(optionsPath)) end
    assert(fs.rename(optionsPath..'.new',optionsPath))
  end
  if args[2]=='config' then
    local key,value=args[3],args[4]
    if key then
      assert(key=='batch' or key=='queue' or key=='mutations' or key=='sampling','Options: batch, queue, mutations, sampling')
      if key=='batch' or key=='queue' then
        value=value=='auto' and key=='queue' and 0 or tonumber(value)
        assert(value and value%1==0 and value>=(key=='batch' and 1 or 0) and value<=(key=='batch' and 64 or 128),'Invalid option value')
      else assert(value=='on' or value=='off','Use on/off'); value=value=='on' end
      options[key]=value
      saveOptions()
    end
    print('AUTO CONFIG batch='..options.batch..'; queue='..(options.queue==0 and 'auto' or options.queue)..'; mutations='..tostring(options.mutations)..'; sampling='..tostring(options.sampling))
    return true
  end
  local raw=readText(path..".new") or readText(path)
  local st=raw and parse(raw,"AUTO1") or {schema="AUTO1",refs={},apiaries={},seq=0,cycles=0,samples=0,mutations=0}
  st.flows=st.flows or {}
  if st.flow then st.seq=st.seq+1; st.flows[tostring(st.seq)]=st.flow; st.flow=nil end
  local flow,currentID
  if args[2]=="status" then
    print("AUTOMATION: apiary cycles="..st.cycles.."; sampled drones="..st.samples.."; mutations="..st.mutations)
    for id,f in pairs(st.flows) do print("FLOW",id,f.mode,f.target,"step="..f.step,f.op and (f.op.key..' '..f.op.phase) or 'queued',f.wait or '') end
    for key,job in pairs(st.apiaries) do print("APIARY",key,job.uid) end
    if st.reset then print('RESET CLEANUP PENDING; use bees auto reset; archive: '..tostring(st.reset.archive)) end
    print(st.wait or "No resource wait recorded."); return true
  end
  assert(args[2]==nil or args[2]=="resume" or args[2]=="reset" or args[2]=='check' or args[2]=='recover',"Use bees auto [resume/status/check/config/reset/recover]")
  assert(args[3]==nil or (args[2]=='reset' and args[3]=='empty')
    or (args[2]=='recover' and args[3]=='mutatron' and args[4]=='empty' and args[5]==nil),'Use bees auto reset [empty] or bees auto recover mutatron empty')
  if args[2]=='recover' then
    assert(args[3]=='mutatron' and args[4]=='empty','After cancelling internal work: bees auto recover mutatron empty')
  end
  assert(not st.reset or args[2]=="reset","Reset cleanup is pending; use bees auto reset before resuming")
  assert(not fs.exists(BIND_PENDING) and not fs.exists(pendingPath),"Finish bind/interface recovery first")
  local function save()
    if not fs.exists(dir) then assert(fs.makeDirectory(dir)) end
    local text=ser.serialize(st)
    writeText(path..".new",text); assert(readText(path..".new")==text,"Automation journal verification failed")
    if fs.exists(path) then writeText(path..".bak",assert(readText(path))); assert(fs.remove(path)) end
    assert(fs.rename(path..".new",path))
  end
  local networkIndex,networkError=roleIndex("network",networks)
  assert(networkIndex,networkError)
  local me=networks[networkIndex]
  if st.network then assert(st.network==me.address,"Saved automation ME endpoint changed") end
  st.network=me.address
  local byT,byME,modules,machines,groups={},{},{},{},{apiary={},analyzer={},imprinter={},sampler={},mutatron={}}
  for _,v in ipairs(transposers) do byT[v.address]=v end
  for _,v in ipairs(networks) do byME[v.address]=v end
  local binding=assert(readText(BIND_PATH),"Run bees bind first")
  assert(binding:match("^OpenBeekeeper%-modules%-1\n"),"Invalid module bindings")
  for line in binding:gmatch("[^\n]+") do
    local address,side,iface=line:match("^interface (%S+) (%d+) (%S+)$")
    if address then
      local t=assert(byT[address],"Missing bound transposer "..address)
      local m=assert(byME[iface],"Missing bound interface "..iface)
      side=tonumber(side)
      assert(not modules[address] and side<=5,"Duplicate/invalid module")
      assert(call(t.proxy.getInventoryName,side)=="appliedenergistics2:interface","Changed interface adjacency")
      assert(t.methods.store~=nil and t.methods.compareStackToDatabase~=nil,"Transposer needs store and compareStackToDatabase for exact bee identity")
      modules[address]={address=address,t=t.proxy,m=m.proxy,source=side,interface=iface}
    end
  end
  local kinds={['gendustry:industrial_apiary']='apiary',['forestry:analyzer']='analyzer',
    ['gendustry:imprinter']='imprinter',['gendustry:sampler']='sampler',['gendustry:mutatron']='mutatron'}
  for line in binding:gmatch("[^\n]+") do
    local address,side,name=line:match("^machine (%S+) (%d+) (%S+)$")
    local kind=name and kinds[name]
    if kind then
      local module=assert(modules[address],"Machine has no module")
      side=tonumber(side); local key=address..":"..side
      assert(not machines[key] and side<=5 and call(module.t.getInventoryName,side)==name,"Changed/duplicate machine adjacency")
      local machine={key=key,module=module,side=side,kind=kind}
      machines[key]=machine; groups[kind][#groups[kind]+1]=machine
    end
  end
  if args[2]=='reset' then
    local manuallyEmpty=args[3]=='empty' or (st.reset and st.reset.empty)
    local function refuse(reason)
      error('RESET REFUSED: '..reason..'; use bees auto status and resume existing work with bees auto. Empty machines alone do not prove internal work finished.')
    end
    if not manuallyEmpty and next(st.apiaries) then refuse('active apiary ownership remains in the journal') end
    for id,f in pairs(manuallyEmpty and {} or st.flows) do
      local op=f.op
      if op then
        if op.phase~='feeding' or op.capture or op.handed then refuse('flow '..id..' may be processing internally') end
        for _,feed in ipairs(op.feeds or {}) do
          if feed.armed or feed.loaded then refuse('flow '..id..' has armed/loaded input') end
        end
      end
    end
    local legacy=readText(dir..'apiary-run.new') or readText(dir..'apiary-run')
    if legacy and not parse(legacy,'APIARY1').finished then refuse('unfinished legacy apiary journal; resume/adopt it first') end
    local function waitBuffer(module)
      for attempt=0,15 do
        local occupied=false
        for slot=1,9 do if alive(call(module.t.getStackInSlot,module.source,slot)) then occupied=true end end
        if not occupied then return end
        if attempt==15 then refuse('occupied staging buffer '..module.interface..'; ME is not accepting items') end
        assert(event.pull(1)~='interrupted','Reset paused; repeat bees auto reset to continue')
      end
    end
    local hasInterfaceWork=st.lease or st.resource or next(st.leases or {}) or next(st.resources or {})
    for _,module in pairs(modules) do
      for slot=1,9 do
        if call(module.m.getInterfaceConfiguration,slot)~=nil or alive(call(module.t.getStackInSlot,module.source,slot)) then hasInterfaceWork=true end
      end
    end
    local hasOutputs=false
    local function resetOutputs(kind)
      if kind=='apiary' then return 7,15 elseif kind=='analyzer' then return 9,12
      elseif kind=='mutatron' then return 3,3 else return 4,4 end
    end
    for _,m in pairs(machines) do
      local slots=m.kind=='apiary' and {1,2}
        or m.kind=='analyzer' and {1,3,4,5,6,7,8}
        or m.kind=='mutatron' and {1,2} or {3}
      for _,slot in ipairs(slots) do
        if alive(call(m.module.t.getStackInSlot,m.side,slot)) then refuse('occupied '..m.kind..' '..m.key..' slot '..slot) end
      end
      local lo,hi=resetOutputs(m.kind)
      for slot=lo,hi do if alive(call(m.module.t.getStackInSlot,m.side,slot)) then hasOutputs=true end end
    end
    local databases={}
    for _,entry in ipairs(tools.databases) do databases[entry.address]=entry.proxy end
    local occupied={}
    for id,r in pairs(st.refs) do
      if type(r)~='table' or not databases[r.database] or type(r.slot)~='number' or r.slot<1 or r.slot>81 or r.slot%1~=0 then refuse('invalid/missing owned database reference '..id) end
      local key=r.database..':'..r.slot
      if occupied[key] then refuse('duplicate owned database reference '..key) end
      occupied[key]=true
      local value=call(databases[r.database].get,r.slot)
      if value~=nil then
        local uid,kind=bee(value)
        local matches=r.uid and uid==r.uid and kind==r.kind
          or not r.uid and r.name and value.name==r.name and value.label==r.label
        if not matches then refuse('owned database slot changed externally: '..key..'; preserve its descriptor') end
      end
    end
    if st.lastResetArchive and not st.reset and not hasOutputs and not hasInterfaceWork and not next(st.refs) and not next(st.flows) then
      -- Repair an interrupted final backup write without revisiting old refs.
      save()
      local text=assert(readText(path))
      writeText(path..'.bak',text); assert(readText(path..'.bak')==text,'Reset backup verification failed')
      print('AUTO RESET already complete; archive: '..st.lastResetArchive); return true
    end
    if not st.reset then
      local n=1
      while fs.exists(path..'-reset-'..n..'.index') or fs.exists(path..'-reset-'..n..'.main') or fs.exists(path..'-reset-'..n..'.new') or fs.exists(path..'-reset-'..n..'.bak') do n=n+1 end
      local archive=path..'-reset-'..n
      if not fs.exists(dir) then assert(fs.makeDirectory(dir)) end
      local rows={'OpenBeekeeper-automation-reset-1'}
      for _,variant in ipairs({{path,'.main'},{path..'.new','.new'},{path..'.bak','.bak'}}) do
        local text=readText(variant[1])
        if text then
          writeText(archive..variant[2],text)
          assert(readText(archive..variant[2])==text,'Reset archive verification failed')
          rows[#rows+1]=variant[2]
        end
      end
      local index=table.concat(rows,'\n')..'\n'
      writeText(archive..'.index',index); assert(readText(archive..'.index')==index,'Reset archive index verification failed')
      st.reset={archive=archive,empty=manuallyEmpty or nil}; save()
    end
    local reset=st.reset
    assert(type(reset.archive)=='string' and fs.exists(reset.archive..'.index'),'Reset archive missing; preserve journal')
    local interfaceArchive=reset.archive..'.interfaces'
    if not fs.exists(interfaceArchive) then
      local saved={schema='AUTOINTERFACES1',interfaces={}}
      for _,module in pairs(modules) do
        local slots={}; saved.interfaces[module.interface]=slots
        for slot=1,9 do slots[slot]=call(module.m.getInterfaceConfiguration,slot) end
      end
      local text=ser.serialize(saved)
      writeText(interfaceArchive..'.new',text)
      assert(readText(interfaceArchive..'.new')==text,'Interface archive verification failed')
      assert(fs.rename(interfaceArchive..'.new',interfaceArchive))
    end
    parse(assert(readText(interfaceArchive)),'AUTOINTERFACES1')
    for _,module in pairs(modules) do
      for slot=1,9 do
        if call(module.m.getInterfaceConfiguration,slot)~=nil then call(module.m.setInterfaceConfiguration,slot) end
        assert(call(module.m.getInterfaceConfiguration,slot)==nil,'Cannot clear reset interface '..module.interface..' slot '..slot)
      end
    end
    st.lease=nil; st.leases={}; st.resource=nil; st.resources={}; save()
    for _,module in pairs(modules) do waitBuffer(module) end
    -- Output extraction is idempotent: archive the queue first, move only the
    -- actual remaining stacks, and clear descriptors only after ME accepts them.
    for _,m in pairs(machines) do
      local lo,hi=resetOutputs(m.kind)
      for slot=lo,hi do
        local v=call(m.module.t.getStackInSlot,m.side,slot)
        while alive(v) do
          local moved=call(m.module.t.transferItem,m.side,m.module.source,math.min(v.size,limit or v.size),slot)
          assert(type(moved)=='number' and moved>=0 and moved<=v.size,'Invalid reset output transfer')
          if moved==0 then
            waitBuffer(m.module)
            moved=call(m.module.t.transferItem,m.side,m.module.source,math.min(v.size,limit or v.size),slot)
            assert(type(moved)=='number' and moved>0 and moved<=v.size,'Reset output transfer blocked at '..m.key..' slot '..slot..'; fix ME supply and repeat bees auto reset')
          end
          print('RESET RETURN',m.kind,moved,v.label or v.name)
          v=call(m.module.t.getStackInSlot,m.side,slot)
        end
      end
    end
    for _,module in pairs(modules) do waitBuffer(module) end
    if reset.clearing then
      local r=assert(st.refs[reset.clearing],'Reset reference missing')
      if call(databases[r.database].get,r.slot)~=nil then refuse('interrupted database clear is ambiguous at '..r.database..':'..r.slot..'; inspect/archive the descriptor before manually clearing this slot') end
      st.refs[reset.clearing]=nil; reset.clearing=nil; save()
    end
    local ids={}; for id in pairs(st.refs) do ids[#ids+1]=id end; table.sort(ids)
    for _,id in ipairs(ids) do
      local r=st.refs[id]
      reset.clearing=id; save()
      call(databases[r.database].clear,r.slot)
      assert(call(databases[r.database].get,r.slot)==nil,'Could not clear owned database entry; reset remains pending')
      st.refs[id]=nil; reset.clearing=nil; save()
    end
    st={schema='AUTO1',refs={},apiaries={},flows={},seq=0,cycles=0,samples=0,mutations=0,
      network=me.address,migrated=true,climateRouting=true,lastResetArchive=reset.archive}
    save()
    local text=assert(readText(path))
    writeText(path..'.bak',text); assert(readText(path..'.bak')==text,'Reset backup verification failed')
    print('AUTO RESET complete; old journal archived at '..reset.archive..'.*')
    print('Bindings, climate zones and ME roles preserved. Run bees auto to plan from current stock.')
    return true
  end
  for _,kind in ipairs({'apiary','analyzer','imprinter','sampler','mutatron'}) do
    table.sort(groups[kind],function(a,b) if a.side~=b.side then return a.side<b.side end return a.key<b.key end)
  end
  local zones={breeding=0,incubator=0,unassigned=0,off=0}
  local configuration=climateConfiguration()
  for _,m in ipairs(groups.apiary) do
    local zone=climateZone(m,configuration)
    zones[zone.role]=(zones[zone.role] or 0)+1
  end
  local hasIncubation=zones.incubator+zones.breeding>0
  local capabilities={queen=hasIncubation}
  local prepare=#groups.analyzer>0 and #groups.imprinter>0
  capabilities.multiply=prepare and zones.breeding>0
  capabilities.restore=capabilities.multiply
  capabilities.mutate=options.mutations and #groups.mutatron>0 and hasIncubation
  capabilities.sample=prepare and options.sampling and #groups.sampler>0
  print('MODULES apiaries='..#groups.apiary..' breeding='..zones.breeding..' incubator='..zones.incubator..' unassigned='..zones.unassigned..'; analyzers='..#groups.analyzer..' imprinters='..#groups.imprinter..' mutatrons='..#groups.mutatron..' samplers='..#groups.sampler..' databases='..#tools.databases)
  print('ENABLED breeding='..tostring(capabilities.multiply)..' mutations='..tostring(capabilities.mutate)..' sampling='..tostring(capabilities.sample)..'; analyzer batch='..options.batch)
  if zones.unassigned>0 then print('Unassigned apiaries do not run; configure bees zones before starting.') end
  if args[2]=='check' then
    for _,m in pairs(machines) do
      local slots={}
      local last=m.kind=='apiary' and 15 or m.kind=='analyzer' and 12 or 4
      for slot=1,last do
        local v=call(m.module.t.getStackInSlot,m.side,slot)
        if alive(v) then slots[#slots+1]=slot..'='..tostring(v.label or v.name)..' x'..v.size end
      end
      local owner=st.apiaries[m.key] and 'apiary cycle' or 'none'
      for id,f in pairs(st.flows) do
        if f.op and f.op.key==m.key then owner='flow '..id..' '..f.op.phase end
      end
      print('INVENTORY',m.kind,m.key,#slots>0 and table.concat(slots,'; ') or 'empty','owner='..owner)
      if m.kind=='imprinter' then
        local template=call(m.module.t.getStackInSlot,m.side,1)
        if not alive(template) or template.name~='gendustry:gene_template' then print('MISSING template at '..m.key) end
      end
    end
    print('Read-only check. Change topology with bees bind; assign roles with bees zones; policy with bees auto config.')
    return true
  end
  local names,aliases,recipes={},{},{}
  for _,v in ipairs(catalogues) do
    local list=read(v.proxy.listAllSpecies)
    if type(list)=="table" then
      for _,x in pairs(list) do if type(x)=="table" and x.uid then names[x.uid]=x.name or x.uid end end
      recipes=call(v.proxy.getBeeBreedingData) or {}; break
    end
  end
  if not next(names) then print('Forestry catalogue unavailable: existing species can breed; new mutation recipes are unavailable.') end
  local recipeConditionCache={}
  local function recipeConditions(recipe)
    if recipeConditionCache[recipe] then return recipeConditionCache[recipe] end
    local list={}
    if type(recipe.specialConditions)=='table' then
      for _,value in pairs(recipe.specialConditions) do list[#list+1]=tostring(value) end
    elseif hasConditions(recipe) then list[1]=tostring(recipe.specialConditions) end
    table.sort(list); recipeConditionCache[recipe]=list; return list
  end
  local function conditionsAllowed(list)
    for _,text in ipairs(list or {}) do if options.conditions[text]==false then return false end end
    return true
  end
  local conditionSet={}
  for _,recipe in pairs(recipes) do
    if type(recipe)=='table' then for _,text in ipairs(recipeConditions(recipe)) do conditionSet[text]=true end end
  end
  for text in pairs(options.conditions) do conditionSet[text]=true end
  for _,f in pairs(st.flows) do for _,text in ipairs(f.conditions or {}) do conditionSet[text]=true end end
  local conditionList={}; for text in pairs(conditionSet) do conditionList[#conditionList+1]=text end
  table.sort(conditionList)
  if dashboard then
    dashboard.settings={options=options,conditions=conditionList}
    dashboard.actions=dashboard.actions or {}
  end
  local stock,samples={},{}
  local function adjust(v,count)
    local uid,kind=bee(v)
    if uid then
      local e=stock[uid] or {uid=uid,princess=0,drone=0,queen=0}; stock[uid]=e
      e[kind]=math.max(0,e[kind]+count)
      if count>0 then e[kind..'Item']=v end
    elseif count>0 then
      local g=gene(v)
      if g and g.chromosome==0 then samples[g.allele]='G' end
    end
  end
  local function item(m,slot) return call(m.module.t.getStackInSlot,m.side,slot) end
  local function outputSlots(kind)
    if kind=='apiary' then return 7,15 elseif kind=='analyzer' then return 9,12
    elseif kind=='mutatron' then return 3,3 else return 4,4 end
  end
  local waiting={}
  local function warn(message)
    local key=currentID or 'global'
    if waiting[key]~=message then
      waiting[key]=message; st.wait=message; if flow then flow.wait=message end
      print("WAIT "..message); save()
    end
  end
  local function tick()
    if dashboard then
      dashboard.pollUpdate(); dashboard.render(st)
      assert(not dashboard.stopRequested,'Stopped from dashboard')
    end
    assert(event.pull(1)~="interrupted","Paused by Ctrl+C; bees auto resumes")
    assert(not dashboard or not dashboard.stopRequested,'Stopped from dashboard')
  end
  local function db(ref)
    local proxy,err=read(component.proxy,ref.database)
    assert(proxy,'OC database unavailable: '..ref.database..'; '..tostring(err or 'no such component'))
    return proxy
  end
  local function allocate()
    local owned={}
    for _,r in pairs(st.refs) do owned[r.database..":"..r.slot]=true end
    for _,e in ipairs(tools.databases) do
      for slot=1,81 do
        local value,err=read(e.proxy.get,slot)
        if err then break end
        if value==nil and not owned[e.address..":"..slot] then
          st.seq=st.seq+1; local id=tostring(st.seq)
          st.refs[id]={database=e.address,slot=slot}; save(); return id
        end
      end
    end
    warn("Waiting for a free OC database entry; existing jobs continue")
    return nil
  end
  local function release(id)
    if not id or not st.refs[id] then return end
    local r=st.refs[id]; call(db(r).clear,r.slot)
    assert(call(db(r).get,r.slot)==nil,"Could not clear owned database entry")
    st.refs[id]=nil; save()
  end
  st.leases=st.leases or {}
  st.resources=st.resources or {}
  local function cleanLease(interface)
    if st.lease then
      st.leases[st.lease.interface]=st.lease; st.lease=nil; save()
    end
    local keys={}
    for key in pairs(st.leases) do if not interface or key==interface then keys[#keys+1]=key end end
    table.sort(keys)
    local failures={}
    for _,key in ipairs(keys) do
      -- A missing interface must not prevent cleanup on all other modules.
      -- Keep its lease and descriptor until its request is actually cleared.
      local ok,err=pcall(function()
        local proxy,reason=read(component.proxy,key)
        assert(proxy,'interface unavailable: '..tostring(reason or 'no such component'))
        call(proxy.setInterfaceConfiguration,9)
        assert(call(proxy.getInterfaceConfiguration,9)==nil,'request 9 remains configured')
        st.leases[key]=nil; save()
      end)
      if not ok then failures[#failures+1]=key..': '..tostring(err) end
    end
    assert(#failures==0,'ME request cleanup pending: '..table.concat(failures,'; '))
  end
  local function emptyBuffer(module)
    for slot=1,9 do if alive(call(module.t.getStackInSlot,module.source,slot)) then return false end end
    return true
  end
  local function matches(v,ref)
    if not alive(v) then return false end
    if ref.uid then local uid,kind=bee(v); return uid==ref.uid and kind==ref.kind end
    return v.name==ref.name and v.label==ref.label
  end
  local materialize
  -- Per-interface requests are polled, never slept on. Database entries retain
  -- exact item identity; one owner serializes every use of a shared interface.
  local function deliver(m,id,destination,count,intention)
    local r=assert(st.refs[id],"Missing owned bee reference")
    local interface=m.module.interface
    local owner=id..':'..m.key..':'..destination
    local lease=st.leases[interface]
    if lease and lease.owner~=owner then return nil end
    if not lease then
      if not emptyBuffer(m.module) then return nil end
      -- Mutation needs the species, not the previous captivity counter/genome.
      -- A database entry copied after analysis can outlive that exact variant.
      -- Resolve a positive live ME variant immediately before issuing a request.
      if m.kind=='mutatron' and r.kind=='princess' then
        if not materialize(id,true) then return false,'No live princess '..tostring(r.uid)..' in ME; mutatron request not configured' end
      elseif not r.ready and not materialize(id) then
        return false,'No live '..tostring(r.kind)..' '..tostring(r.uid)..' in ME; request not configured'
      end
      st.leases[interface]={interface=interface,owner=owner,since=computer.uptime()}; save()
      assert(call(m.module.m.setInterfaceConfiguration,9,r.database,r.slot,count),"Interface request failed")
      lease=st.leases[interface]
    end
    local source
    for slot=1,9 do
      local v=call(m.module.t.getStackInSlot,m.module.source,slot)
      if alive(v) then
        assert(not source and matches(v,r) and v.size<=count,"Unexpected item in staging interface")
        assert(call(m.module.t.compareStackToDatabase,m.module.source,slot,r.database,r.slot,true),"Staged item NBT differs from the owned descriptor")
        source=slot
      end
    end
    if not source then
      if computer.uptime()-lease.since<15 then return nil end
      cleanLease(interface)
      return false,"Exact item not delivered within 15 seconds: "..tostring(r.uid or r.name).." / "..tostring(r.kind or r.label).."; check ME stock, exact NBT and interface supply. Request cancelled; other jobs continue."
    end
    if m.kind=='analyzer' and count>1 and not intention.batchPeers then
      intention.batchPeers={}
      for other,ref in pairs(st.refs) do
        if other~=id and ref.ready and not ref.analyzed and ref.uid==r.uid and ref.kind==r.kind
            and call(m.module.t.compareStackToDatabase,m.module.source,source,ref.database,ref.slot,true) then
          intention.batchPeers[#intention.batchPeers+1]=other
        end
      end
    end
    if dashboard then
      dashboard.pump()
      assert(not dashboard.stopRequested,'Stopped from dashboard')
      dashboard.critical=true
    end
    intention.armed=true; save()
    local v=call(m.module.t.getStackInSlot,m.module.source,source)
    local moved=call(m.module.t.transferItem,m.module.source,m.side,v.size,source,destination)
    assert(type(moved)=="number" and moved>=0 and moved<=v.size,"Invalid loading result")
    if moved==0 then intention.armed=false; save()
    else
      adjust(v,-moved); r.inME=false
      for _,other in ipairs(intention.batchPeers or {}) do if st.refs[other] then st.refs[other].inME=false end end
      save()
    end
    cleanLease(interface)
    if dashboard then dashboard.critical=nil end
    return moved>0
  end
  local function reference(v)
    local id=allocate(); if not id then return nil end; local r=st.refs[id]
    r.filter={name=v.name,label=v.label}; r.uid,r.kind=bee(v); r.name=v.name; r.label=v.label; r.available=v.size
    save(); return id
  end
  materialize=function(id,refresh)
    local r=st.refs[id]
    if refresh then
      local previous=call(db(r).get,r.slot)
      r.filter={name=previous and previous.name or r.name,label=previous and previous.label or r.label}
      r.ready=nil; r.analyzed=nil; r.imprinted=nil; save()
    end
    if r.ready then return true end
    -- AE store() also enumerates zero-stock/craftable variants. A label-only
    -- lookup can therefore copy a phantom NBT template forever. Match a known
    -- positive quantity from our ledger/snapshot; never request size-zero ghosts.
    local e=stock[r.uid]
    local current=e and e[r.kind..'Item']
    local counts,seen={},{}
    local function candidate(count)
      if type(count)=='number' and count>0 and count%1==0 and not seen[count] then
        counts[#counts+1]=count; seen[count]=true
      end
    end
    if current and matches(current,r) then candidate(current.size) end
    candidate(e and e[r.kind]); candidate(r.available); candidate(1)
    local v
    for _,count in ipairs(counts) do
      call(db(r).clear,r.slot)
      call(me.proxy.store,{name=r.filter.name,label=r.filter.label,size=count},r.database,r.slot,1)
      v=call(db(r).get,r.slot)
      if matches(v,r) then break end
    end
    if not matches(v,r) then warn('ME needs '..tostring(r.uid)..' / '..tostring(r.kind)); return false end
    r.analyzed=type(v.individual)=='table' and v.individual.isAnalyzed==true
    r.ready=true; r.inME=true; save(); return true
  end
  local resourceRetry={}
  local function resource(m,slot,label)
    local key=m.key..':'..slot
    local job=st.resources[key]
    if alive(item(m,slot)) and not job then return true end
    if not job then
      if resourceRetry[key] and computer.uptime()<resourceRetry[key] then return false end
      local id=allocate(); if not id then return false end; local r=st.refs[id]
      st.resources[key]={ref=id,intention={}}; save(); job=st.resources[key]
      call(me.proxy.store,{label=label},r.database,r.slot,1)
      local v=call(db(r).get,r.slot)
      if not alive(v) or v.label~=label then
        st.resources[key]=nil; save(); release(id)
        resourceRetry[key]=computer.uptime()+ME_INTERVAL; warn('ME needs '..label); return false
      end
      r.name=v.name; r.label=v.label; r.uid=nil; r.kind=nil; r.ready=true; save()
    end
    local r=st.refs[job.ref]
    local moved,reason
    if alive(item(m,slot)) or job.intention.armed then moved=true
    else moved,reason=deliver(m,job.ref,slot,16,job.intention) end
    if moved==nil then return false end
    if reason then warn(reason); resourceRetry[key]=computer.uptime()+ME_INTERVAL end
    local lease=st.leases[m.module.interface]
    if lease and lease.owner==job.ref..':'..m.key..':'..slot then cleanLease(m.module.interface) end
    st.resources[key]=nil; save(); release(job.ref)
    return alive(item(m,slot))
  end
  local function fluidReady(m)
    if m.module.t.getFluidInTank then
      local tanks=read(m.module.t.getFluidInTank,m.side)
      if type(tanks)=="table" then
        local amount=tonumber(tanks.amount)
        for _,tank in pairs(tanks) do if type(tank)=="table" and tonumber(tank.amount) then amount=(amount or 0)+tank.amount end end
        if amount and amount<(m.kind=='analyzer' and 100 or 1) then
          warn(m.kind=='analyzer' and "Analyzer needs liquid honey (100 mB per unanalyzed bee)" or "Mutatron needs mutagen")
          return false
        end
      end
    end
    return true
  end
  local function supplies(m)
    if m.kind=='analyzer' then return fluidReady(m) end
    if m.kind=='imprinter' then
      local template=item(m,1)
      if not alive(template) or template.name~='gendustry:gene_template' then warn("Imprinter needs the user gene template (effect genes allowed; keep species unchanged)"); return false end
      return resource(m,2,'Genetics Labware')
    elseif m.kind=='sampler' then return resource(m,1,'Blank Gene Sample') and resource(m,2,'Genetics Labware')
    elseif m.kind=='mutatron' then return fluidReady(m) and resource(m,4,'Genetics Labware') end
    return true
  end
  local availability,zoneCache={},{}
  local function free(m,purpose)
    local owned=false
    for id,f in pairs(st.flows) do
      if id~=currentID and f.op and f.op.key==m.key then
        owned=true
        if m.kind=='apiary' then return false end
        for _,feed in ipairs(f.op.feeds) do if not feed.loaded then return false end end
      end
    end
    if m.kind=='apiary' then
      local cacheKey=m.key..':'..tostring(purpose)
      if availability[cacheKey]~=nil then return availability[cacheKey] end
      local result
      if st.apiaries[m.key] then
        local parent=item(m,1); local _,kind=bee(parent or {})
        result=purpose=='breeding' and not alive(item(m,2)) and (not alive(parent) or kind=='queen')
      else
        result=not alive(item(m,1)) and not alive(item(m,2))
        if result then for slot=7,15 do if alive(item(m,slot)) then result=false end end end
      end
      availability[cacheKey]=result; return result
    end
    -- An older job owns its output, but empty inputs can hold the next job.
    if not owned then
      local lo,hi=outputSlots(m.kind)
      for slot=lo,hi do if alive(item(m,slot)) then return false end end
    end
    if m.kind=='mutatron' then return not alive(item(m,1)) and not alive(item(m,2)) end
    if m.kind=='analyzer' then
      if alive(item(m,1)) then return false end
      for slot=3,8 do if alive(item(m,slot)) then return false end end
      return true
    end
    return not alive(item(m,3))
  end
  local function find(kind,wanted,purpose)
    local best,score
    local configuration=kind=='apiary' and climateConfiguration()
    local requiredT,requiredH
    if purpose=='incubator' then requiredT,requiredH=preferredClimate(wanted and wanted.uid,configuration) end
    if purpose=='incubator' and not requiredT then return nil,nil,'Unknown preferred climate for '..tostring(wanted and wanted.uid)..'; use bees zones species <UID> <TEMP> <HUMIDITY>' end
    for _,m in ipairs(groups[kind]) do
      local roleMatches=true
      if kind=='apiary' then
        local cache=zoneCache[m.key]
        local epoch=math.floor(computer.uptime()/5)
        if not cache or cache.epoch~=epoch then cache={epoch=epoch,value=climateOfApiary(m.module.t,m.side)}; zoneCache[m.key]=cache end
        local zone=climateZone(m,configuration,cache.value)
        roleMatches=purpose=='breeding' and zone.role=='breeding'
          or purpose=='incubator' and (zone.role=='incubator' or zone.role=='breeding')
            and zone.temperature==requiredT and zone.humidity==requiredH
      end
      if kind=='analyzer' and emptyBuffer(m.module) then
        local owned,duplicate,reserved=false,false,{}
        for id,f in pairs(st.flows) do
          if id~=currentID and f.op and f.op.key==m.key then
            owned=true
            for _,feed in ipairs(f.op.feeds) do
              local ref=st.refs[feed.ref]
              if ref and wanted and ref.uid==wanted.uid and ref.kind==wanted.kind then duplicate=true end
              if not feed.loaded then reserved[feed.slot]=true end
            end
          end
        end
        if not duplicate and (owned or free(m)) then
          for slot=3,8 do if not reserved[slot] and not alive(item(m,slot)) then return m,slot end end
        end
      elseif kind~='analyzer' and roleMatches and free(m,purpose) and emptyBuffer(m.module) then
        local climate=kind=='apiary' and zoneCache[m.key].value.score or 0
        local queued=st.apiaries[m.key] and 1 or 0
        for id,other in pairs(st.flows) do
          if id~=currentID and other.op and other.op.key==m.key then queued=queued+1 end
        end
        local rank=climate-queued*1000 -- Use idle hardware before preloading busy hardware.
        if not best or rank>score then best=m; score=rank end
      end
    end
    return best,nil,kind=='apiary' and ('No free '..tostring(purpose)..' zone'..(requiredT and ' '..requiredT..'/'..requiredH or '')..'; inspect bees zones') or nil
  end
  local function returnSlot(m,slot,limit)
    if st.leases[m.module.interface] then return false end
    local v=item(m,slot); if not alive(v) then return true,0 end
    local moved=call(m.module.t.transferItem,m.side,m.module.source,math.min(v.size,limit or v.size),slot)
    assert(type(moved)=="number" and moved>=0 and moved<=v.size,"Invalid bulk return")
    if moved>0 then adjust(v,moved); print("RETURN",m.kind,moved,v.label or v.name) end
    return not alive(item(m,slot)),moved
  end
  local function flowOwns(key)
    for _,f in pairs(st.flows) do if f.op and f.op.key==key then return true end end
    return false
  end
  -- Output slots and leftover drones do not imply an active machine job.
  -- Never touch the drone while a flow is still loading its princess.
  local function serviceUnowned()
    for _,m in pairs(machines) do
      if not flowOwns(m.key) and not st.apiaries[m.key] then
        local lo,hi=outputSlots(m.kind)
        for slot=lo,hi do returnSlot(m,slot) end
        if m.kind=='apiary' then
          local parent=item(m,1)
          if not alive(parent) then
            local _,kind=bee(item(m,2) or {})
            if kind=='drone' then returnSlot(m,2) end
          else
            local uid,kind=bee(parent)
            if kind=='queen' then st.apiaries[m.key]={uid=uid,puid=uid}; save() end
          end
        end
      end
    end
  end
  local function serviceApiaries()
    for key,job in pairs(st.apiaries) do
      local m=assert(machines[key],"Saved apiary is missing")
      local empty=true
      if job.cancelRequested then
        -- The queued next drone belongs to its flow, not to this apiary cycle.
        if not returnSlot(m,1) then empty=false end
        if not flowOwns(key) and not returnSlot(m,2) then empty=false end
      end
      for slot=7,15 do if not returnSlot(m,slot) then empty=false end end
      if not alive(item(m,1)) and not flowOwns(key) then
        local _,kind=bee(item(m,2) or {})
        if kind=='drone' and not returnSlot(m,2) then empty=false end
      end
      if not alive(item(m,1)) and (not alive(item(m,2)) or flowOwns(key)) and empty then
        st.apiaries[key]=nil; if not job.cancelRequested then st.cycles=st.cycles+1 end; save()
        print("APIARY COMPLETE",key,job.uid)
      end
    end
  end
  local function finishFlow()
    local f=assert(flow)
    waiting[currentID]=nil
    st.flows[currentID]=nil; flow=nil; save()
    release(f.p); release(f.d)
  end
  local function operationStarted(f)
    if not f.op then return false end
    if f.op.phase~='feeding' or f.op.capture or f.op.handed then return true end
    for _,feed in ipairs(f.op.feeds) do if feed.armed or feed.loaded then return true end end
    return false
  end
  local function processControls()
    local actions=dashboard and dashboard.actions or {}
    if dashboard then dashboard.actions={} end
    local changed=false
    for _,action in ipairs(actions) do
      if action.kind=='condition' and conditionSet[action.key] then
        options.conditions[action.key]=options.conditions[action.key]==false
        saveOptions(); print('CONDITION',options.conditions[action.key] and 'ALLOW' or 'BLOCK',action.key)
      elseif action.kind=='option' and (action.key=='mutations' or action.key=='sampling') then
        options[action.key]=not options[action.key]; saveOptions()
        capabilities.mutate=options.mutations and #groups.mutatron>0 and hasIncubation
        capabilities.sample=prepare and options.sampling and #groups.sampler>0
      elseif action.kind=='cancel' then
        local f=st.flows[action.key]
        if f then
          f.cancelRequested=true; save()
          print('CANCEL REQUESTED',action.key,f.target,'current operation finishes safely; planner unchanged')
        else print('Task already finished',action.key) end
      elseif action.kind=='cancelApiary' then
        local job=st.apiaries[action.key]
        if job then
          job.cancelRequested=true
          save(); print('CANCEL APIARY',action.key,'returning bees to ME; planner unchanged')
        end
      end
    end
    -- Policy edits also apply to already queued mutations; an internal result
    -- must still be collected before ownership can be released.
    for _,f in pairs(st.flows) do
      if f.mode=='mutate' and (not options.mutations or not conditionsAllowed(f.conditions))
          or f.mode=='sample' and not options.sampling then
        if not f.cancelRequested then f.cancelRequested=true; changed=true end
      end
    end
    if changed then save() end
  end
  local function copyOutput(m,slot,id)
    local r=assert(st.refs[id])
    assert(call(m.module.t.store,m.side,slot,r.database,r.slot),"Cannot copy exact output descriptor")
  end
  local deliveryRetry={}
  local function serviceFlow()
    if dashboard then dashboard.pump(); assert(not dashboard.stopRequested,'Stopped from dashboard') end
    local f=flow; if not f then return end
    if f.cancelRequested and not operationStarted(f) then
      if f.op then
        for interface,lease in pairs(st.leases) do
          for _,feed in ipairs(f.op.feeds) do
            if lease.owner==feed.ref..':'..f.op.key..':'..feed.slot then cleanLease(interface); break end
          end
        end
      end
      print('CANCELLED',currentID,f.target); finishFlow(); return
    end
    if f.reselect then
      if st.needFresh then return end
      f.reselect=nil; save()
    end
    if deliveryRetry[currentID] and computer.uptime()<deliveryRetry[currentID] then return end
    if f.pendingP then
      local id=reference(f.pendingP); if not id then return end
      f.p=id; f.pendingP=nil; save()
    end
    if f.pendingD then
      local id=reference(f.pendingD); if not id then return end
      f.d=id; f.pendingD=nil; save()
    end
    local step=f.steps[f.step]
    if not step then finishFlow(); return end
    -- Existing mutation queues may still contain imprint steps. Skip only work
    -- that has not been sent; finish an already armed/internal imprint safely.
    if (f.mode=='mutate' and (step:match('^imprint') or step:match('^analyze')))
        or (f.mode=='queen' and step:match('^analyze')) then
      local started=f.op and (f.op.phase~='feeding' or f.op.capture or f.op.handed)
      if f.op then
        for _,feed in ipairs(f.op.feeds) do if feed.armed or feed.loaded then started=true end end
      end
      if not started then f.op=nil; f.step=f.step+1; save(); return end
    end
    local selected=(step=='queen' or step:sub(-1)=='P') and f.p or f.d
    if step~='mate' and not materialize(selected) then
      if not f.op then
        print('REPLAN',f.target,'bee no longer present in live ME lookup')
        st.needFresh=true; finishFlow()
      end
      return
    end
    if step:match('^analyze') and st.refs[selected].analyzed and not f.op then
      f.step=f.step+1; save(); return
    end
    local kind=step:match('^analyze') and 'analyzer' or step:match('^imprint') and 'imprinter'
      or step=='sample' and 'sampler' or step=='mate' and (f.mode=='mutate' and 'mutatron' or 'apiary') or 'apiary'
    if not f.op then
      local wanted=st.refs[(step=='queen' or step:sub(-1)=='P') and f.p or f.d]
      local purpose=kind=='apiary' and (step=='queen' and 'incubator' or 'breeding') or nil
      if purpose=='breeding' then
        assert(st.refs[f.p].analyzed and st.refs[f.p].imprinted and st.refs[f.d].analyzed and st.refs[f.d].imprinted,'Both breeding parents must be analyzed and imprinted')
      end
      local m,analysisSlot,reason=find(kind,wanted,purpose)
      if not m then warn(reason or "No empty "..kind); return end
      if not supplies(m) then return end
      local feeds={}
      if step=='mate' then
        feeds={{ref=f.d,slot=2},{ref=f.p,slot=1}}
      elseif step=='queen' then feeds={{ref=f.p,slot=1}}
      else
        local id=step:sub(-1)=='P' and f.p or f.d
        local r=st.refs[id]
        feeds={{ref=id,slot=analysisSlot or 3,count=kind=='analyzer' and r.kind=='drone' and math.min(options.batch,r.available or 1) or 1}}
      end
      st.operationSeq=(st.operationSeq or 0)+1
      f.op={key=m.key,feeds=feeds,phase='feeding',ticks=0,order=st.operationSeq}; f.wait=nil; waiting[currentID]=nil; st.wait=nil; save()
      if kind=='mutatron' and f.conditions and #f.conditions>0 then
        print('CONDITIONAL ATTEMPT',f.target,table.concat(f.conditions,'; '),'requirements are not verified by OC; server decides availability')
      end
    end
    local op=f.op; local m=assert(machines[op.key],"Saved processor is missing")
    if op.phase=='feeding' then
      if not supplies(m) then
        local started=false
        for _,feed in ipairs(op.feeds) do if feed.armed or feed.loaded then started=true end end
        if not started then f.op=nil; save() end
        return
      end
      -- A mating pair cannot have started if its princess was never sent.
      -- Recheck the staged drone instead of trusting a stale loaded flag.
      if step=='mate' and not op.feeds[2].armed and not op.feeds[2].loaded then
        local drone=op.feeds[1]
        if drone.loaded and not alive(item(m,2)) then drone.loaded=nil; drone.armed=nil; save() end
      end
      for _,feed in ipairs(op.feeds) do
        if not feed.loaded then
          if kind=='apiary' and st.apiaries[m.key] and feed.slot==1 and not feed.armed then
            return -- The next drone may wait beside the current queen; its princess cannot.
          end
          local r=st.refs[feed.ref]; local v=item(m,feed.slot)
          if alive(v) then
            local _,physicalKind=bee(v)
            local mated=step=='mate' and feed.slot==1 and feed.armed and physicalKind=='queen'
            assert(mated or matches(v,r),"Unexpected bee in owned input")
            assert(feed.armed,"Input occupied before this flow loaded it; inspect bees auto check")
            feed.loaded=true; save()
          elseif feed.armed and not (step=='mate' and feed.slot==2 and not op.feeds[2].armed) then
            -- The triggering item may be internal/already output. Never replay it.
            feed.loaded=true; save()
          else
            local delivered,reason=deliver(m,feed.ref,feed.slot,feed.count or 1,feed)
            if delivered==nil then return end
            if not delivered then
              op.blockedSince=op.blockedSince or computer.uptime(); save()
              if not reason and computer.uptime()-op.blockedSince>=ME_INTERVAL then
                reason='Input transfer remains blocked at '..m.key..' slot '..feed.slot..'; releasing unstarted work'
              end
              if reason then
                deliveryRetry[currentID]=computer.uptime()+ME_INTERVAL
                local started=false
                for _,input in ipairs(op.feeds) do if input.armed or input.loaded then started=true end end
                if started and step=='mate' and feed.slot==1 and not feed.armed and not feed.loaded
                    and not alive(item(m,1)) then
                  local drone=op.feeds[1]
                  if returnSlot(m,2) then
                    drone.loaded=nil; drone.armed=nil
                    local ref=st.refs[drone.ref]; ref.inME=true
                    started=false; save()
                  end
                end
                if not started then
                  -- Captivity generations are not bee identity. Reselect the
                  -- current live variant, then repeat its preparation; never
                  -- carry analyzed/imprinted claims across an NBT substitution.
                  local previous=call(db(r).get,r.slot)
                  r.filter={name=previous and previous.name or r.name,label=previous and previous.label or r.label}
                  r.ready=nil; r.analyzed=nil; r.imprinted=nil; r.inME=true
                  local suffix=feed.ref==f.p and 'P' or 'D'
                  for index,value in ipairs(f.steps) do
                    if value=='analyze'..suffix then f.step=index; break end
                  end
                  f.op=nil; f.reselect=true; st.needFresh=true
                  print('REPLAN',f.target,'refresh live bee variant after failed exact request',reason)
                  save(); return
                end
              end
              warn(reason or ("Input transfer blocked at "..m.key)); return
            end
            deliveryRetry[currentID]=nil; op.blockedSince=nil
            feed.loaded=true; save()
          end
        end
      end
      op.phase='working'; save()
      print("PROCESS",step,m.key,f.target)
    end
    if kind=='apiary' then
      if not op.handed then
        st.apiaries[m.key]={uid=st.refs[f.p].uid,target=f.target,puid=st.refs[f.p].uid,duid=f.d and st.refs[f.d].uid,fertility=st.refs[f.p].fertility}
        if f.cancelRequested then st.apiaries[m.key].cancelRequested=true end
        op.handed=true; save()
      end
      finishFlow(); return
    end
    local older,newer=false,false
    if kind~='analyzer' then
      for id,other in pairs(st.flows) do
        if id~=currentID and other.op and other.op.key==m.key then
          if other.op.order<op.order then older=true else newer=true end
        end
      end
    end
    if kind=='mutatron' and not newer and not op.capture and not alive(item(m,3)) then
      local princess,drone=item(m,1),item(m,2)
      if alive(princess)~=alive(drone) then
        local now=computer.uptime()
        if not op.partialSince or now<op.partialSince then op.partialSince=now; save() end
        if now-op.partialSince>=2 then
          local slot=alive(princess) and 1 or 2
          local ref=st.refs[slot==1 and f.p or f.d]
          assert(matches(slot==1 and princess or drone,ref),'Unexpected remaining mutatron parent')
          local cleared,moved=returnSlot(m,slot)
          -- A successful extraction proves this pair was not consumed internally.
          -- If the slot disappeared by itself, await the possible internal result.
          if cleared and moved>0 then
            print('RECOVER MUTATRON',m.key,'incomplete pair returned; replanning')
            st.needFresh=true; finishFlow(); return
          end
        end
      elseif op.partialSince then op.partialSince=nil; save() end
    end
    if older then return end -- Common outputs belong to the earliest loaded operation.
    local lo,hi=outputSlots(kind)
    if not op.capture then
      for slot=lo,hi do
        local v=item(m,slot)
        if alive(v) then
          local uid,k=bee(v)
          local failed=v.name=='gendustry:waste' and (kind=='imprinter' or kind=='mutatron')
          local id=step:sub(-1)=='P' and f.p or f.d
          local expected=id and st.refs[id]
          if kind~='analyzer' or (expected and uid==expected.uid and k==expected.kind) then
          if failed then id=nil
          elseif kind=='mutatron' then
            assert(k=='queen' and type(uid)=='string',"Mutatron output is not an identifiable queen")
            id=f.p
          elseif kind=='sampler' then assert(v.name=='gendustry:gene_sample',"Unexpected sampler output")
          else
            local r=assert(st.refs[id]); assert(uid==r.uid and k==r.kind,"Processor changed bee species/type; template may include species")
            if kind=='analyzer' then assert(type(v.individual)=='table' and v.individual.isAnalyzed==true,"Analyzer output is not marked analyzed") end
          end
          op.capture={slot=slot,ref=not failed and kind~='sampler' and id or nil,uid=uid,kind=k,label=v.label,name=v.name,tagGene=gene(v),failed=failed}; save()
          break
          end
        end
      end
    end
    if op.capture then
      local capture=op.capture
      local physical=item(m,capture.slot)
      if alive(physical) and not capture.returned then
        local uid,k=bee(physical)
        local same=capture.ref and uid==capture.uid and k==capture.kind
          or not capture.ref and physical.name==capture.name and physical.label==capture.label
        if same then
          if st.leases[m.module.interface] then return end
          if capture.ref then
            copyOutput(m,capture.slot,capture.ref)
            if kind=='analyzer' then
              for _,other in ipairs(op.feeds[1].batchPeers or {}) do
                if st.refs[other] then
                  copyOutput(m,capture.slot,other)
                  st.refs[other].ready=true; st.refs[other].analyzed=true; st.refs[other].inME=true; st.refs[other].filter=nil
                end
              end
            end
          end
          -- Record non-bee results too. A transfer can expose the next queued
          -- result immediately; slot emptiness is not an extraction receipt.
          capture.remaining=capture.remaining or physical.size
          capture.copied=true; save()
          local _,moved=returnSlot(m,capture.slot,capture.remaining)
          capture.remaining=capture.remaining-(moved or 0)
          if capture.remaining>0 then save(); return end
          capture.returned=true; save()
        else
          assert((capture.copied or not capture.ref) and not capture.remaining,'Owned output changed before capture completed')
        end
      end
      if capture.ref then
        local r=st.refs[capture.ref]; local v=call(db(r).get,r.slot)
        local uid,k=bee(v or {})
        assert(uid==capture.uid and k==capture.kind,"Captured output descriptor missing")
        r.uid=uid; r.kind=k; r.filter=nil; r.ready=true; r.inME=true; save()
        local active=type(v.individual)=='table' and v.individual.active
        local fertility=type(active)=='table' and tonumber(active.fertility)
        if fertility and fertility>=1 and fertility<=64 then r.fertility=fertility; save() end
        if kind=='mutatron' then r.analyzed=nil; r.imprinted=nil; save()
        elseif kind=='analyzer' then r.analyzed=true; save()
        elseif kind=='imprinter' then r.analyzed=true; r.imprinted=true; save() end
      end
      if f.cancelRequested then
        if kind=='mutatron' and not capture.failed then st.mutations=st.mutations+1 end
        if kind=='sampler' then st.samples=st.samples+1 end
        print('CANCELLED',currentID,f.target,'result returned to ME')
        finishFlow(); return
      end
      if capture.failed then
        if not capture.applied then st.losses=(st.losses or 0)+1; capture.applied=true; save() end
        print('GENETIC LOSS',kind,f.target,'waste returned; replanning from actual stock')
        finishFlow()
      elseif kind=='mutatron' then
        st.mutations=st.mutations+1
        print("MUTATION RESULT",capture.uid,"wanted",f.target,capture.uid==f.target and 'MATCH' or 'SIDE SPECIES SAVED')
        local oldDrone=f.d; f.d=nil; f.target=capture.uid; f.mode='queen'; f.steps={'queen'}; f.step=1; f.op=nil; save(); release(oldDrone)
      elseif kind=='sampler' then
        if not capture.applied then
          st.samples=st.samples+1; capture.applied=true; save()
          print("SAMPLE RESULT",capture.label or capture.name,"donor",f.target)
        end
        finishFlow()
      else f.step=f.step+1; f.op=nil; save() end
    else
      op.ticks=op.ticks+1
      if op.ticks%120==0 then warn("Waiting for "..kind.." output at "..m.key.."; check power, fluid and machine error. Input is not replayed.") end
    end
  end
  local function collectStock(items)
    local recipeConditionCache={}
  local function recipeConditions(recipe)
    if recipeConditionCache[recipe] then return recipeConditionCache[recipe] end
    local list={}
    if type(recipe.specialConditions)=='table' then
      for _,value in pairs(recipe.specialConditions) do list[#list+1]=tostring(value) end
    elseif hasConditions(recipe) then list[1]=tostring(recipe.specialConditions) end
    table.sort(list); recipeConditionCache[recipe]=list; return list
  end
  local function conditionsAllowed(list)
    for _,text in ipairs(list or {}) do if options.conditions[text]==false then return false end end
    return true
  end
  local conditionSet={}
  for _,recipe in pairs(recipes) do
    if type(recipe)=='table' then for _,text in ipairs(recipeConditions(recipe)) do conditionSet[text]=true end end
  end
  for text in pairs(options.conditions) do conditionSet[text]=true end
  for _,f in pairs(st.flows) do for _,text in ipairs(f.conditions or {}) do conditionSet[text]=true end end
  local conditionList={}; for text in pairs(conditionSet) do conditionList[#conditionList+1]=text end
  table.sort(conditionList)
  if dashboard then
    dashboard.settings={options=options,conditions=conditionList}
    dashboard.actions=dashboard.actions or {}
  end
  local stock,samples={},{}
    for _,v in pairs(items) do
      if alive(v) then
        local uid,k=bee(v)
        if uid then
          names[uid]=names[uid] or (v.individual or {}).displayName or uid
          local e=stock[uid] or {uid=uid,princess=0,drone=0,queen=0}; stock[uid]=e
          e[k]=e[k]+v.size; e[k..'Item']=v
        end
        local g=gene(v); if g and g.chromosome==0 then samples[g.allele]='G' end
      end
    end
    aliases={}
    for uid,name in pairs(names) do
      if aliases[name]==nil then aliases[name]=uid elseif aliases[name]~=uid then aliases[name]=false end
    end
    for _,v in pairs(items) do
      if alive(v) and v.name=='gendustry:gene_sample' and not gene(v) then
        local name=tostring(v.label or ''):match('^Bee Sample %- Species: (.+)$')
        local uid=name and aliases[name]
        if uid and not samples[uid] then samples[uid]='L' end
      end
    end
    return stock,samples
  end
  local function start(mode,target,p,d,conditions)
    local f={mode=mode,target=target,step=1,steps=mode=='sample' and {'analyzeD','imprintD','sample'}
      or mode=='queen' and {'queen'}
      or mode=='mutate' and {'mate'} or {'analyzeP','imprintP','analyzeD','imprintD','mate'}}
    f.pendingP=p; f.pendingD=d; f.conditions=conditions; st.seq=st.seq+1; st.flows[tostring(st.seq)]=f; st.wait=nil; save(); print("FLOW",mode,target)
  end
  local function choose(stock,samples,category)
    local observed=stock
    local incoming,predicted,load={},{},{}
    for _,j in pairs(st.apiaries) do
      if not j.orphan then
        incoming[j.uid]=true; if j.target then incoming[j.target]=true end
        predicted[j.uid]=(predicted[j.uid] or 0)+(j.fertility or 4)
        load[j.uid]=(load[j.uid] or 0)+1
      end
    end
    local available={}
    for uid,e in pairs(stock) do local c={}; for k,v in pairs(e) do c[k]=v end; c.stockDrone=e.drone; available[uid]=c end
    for _,f in pairs(st.flows) do
      incoming[f.target]=true; load[f.target]=(load[f.target] or 0)+1
      for _,role in ipairs({'p','d'}) do
        local r=f[role] and st.refs[f[role]]
        local pending=f[role=='p' and 'pendingP' or 'pendingD']
        local uid,k
        if r then uid,k=r.uid,r.kind elseif pending then uid,k=bee(pending) end
        if uid and available[uid] and (not r or r.inME~=false) then available[uid][k]=math.max(0,available[uid][k]-1) end
      end
      if f.mode=='multiply' or f.mode=='queen' then
        local r=f.p and st.refs[f.p]
        local fertility=r and r.fertility or 4
        local drone=f.d and st.refs[f.d]
        local cost=(f.mode=='queen' or (drone and drone.inME==false)) and 0 or 1
        predicted[f.target]=(predicted[f.target] or 0)+math.max(0,fertility-cost)
      end
    end
    stock=available
    local list={}; for _,e in pairs(stock) do list[#list+1]=e end
    table.sort(list,function(a,b)
      if (load[a.uid] or 0)~=(load[b.uid] or 0) then return (load[a.uid] or 0)<(load[b.uid] or 0) end
      return a.uid<b.uid
    end)
    local function idle(e) return e~=nil end
    local function target(e) return (samples[e.uid] or not capabilities.sample) and DRONE_TARGET or DRONE_TARGET+38 end
    for _,e in ipairs(list) do
      if category=='queen' and capabilities.queen and e.queen>0 and (e.stockDrone+(predicted[e.uid] or 0)<target(e) or e.princess==0) then start('queen',e.uid,e.queenItem); return true end
    end
    for _,e in ipairs(list) do
      if category=='breed' and capabilities.multiply and e.princess>0 and e.drone>0 and e.stockDrone+(predicted[e.uid] or 0)<target(e) then start('multiply',e.uid,e.princessItem,e.droneItem); return true end
    end
    for _,e in ipairs(list) do
      if category=='sample' and capabilities.sample and idle(e) and not samples[e.uid] and e.drone>DRONE_TARGET then start('sample',e.uid,nil,e.droneItem); return true end
    end
    for _,e in ipairs(list) do
      if category=='breed' and capabilities.restore and not incoming[e.uid] and (e.drone<DRONE_TARGET or not samples[e.uid]) then
        if e.princess==0 and e.queen==0 and e.drone>=1 then
          for _,base in ipairs(list) do
            if idle(base) and base.uid~=e.uid and base.princess>0 and (base.princess>1 or base.drone>=DRONE_TARGET) then
              if e.drone==1 then print('RESTORE USING LAST DRONE',e.uid,'loss risk accepted; actual offspring will be inspected') end
              start('restore',e.uid,base.princessItem,e.droneItem); return true
            end
          end
        elseif e.princess>0 and e.drone==0 then
          for _,donor in ipairs(list) do
            if idle(donor) and donor.uid~=e.uid and donor.drone>=2 then start('restore',e.uid,e.princessItem,donor.droneItem); return true end
          end
        end
      end
    end
    if category~='mutate' or not capabilities.mutate then return false end
    local candidates={}
    local function resolve(value) return names[value] and value or aliases[value] end
    for _,recipe in pairs(recipes) do
      if type(recipe)=='table' then
        local a,b,result=resolve(recipe.allele1),resolve(recipe.allele2),resolve(recipe.result)
        local existing=result and stock[result]
        -- A collected gene does not replace the living stock target. Recreate
        -- extinct lines, but let existing bees and in-flight jobs restore them.
        local living=result and observed[result]
        local extinct=not living or living.princess+living.drone+living.queen==0
        if a and b and result and conditionsAllowed(recipeConditions(recipe)) and not incoming[result] and (not samples[result] or extinct) and (not existing or existing.princess==0) then
          local function pair(p,d)
            if idle(p) and idle(d) and p.princess>0 and d.drone>=2 and (p.princess>1 or p.drone>=DRONE_TARGET) then
              local conditions=recipeConditions(recipe)
              candidates[#candidates+1]={p=p,d=d,result=result,conditions=conditions}
            end
          end
          pair(stock[a],stock[b]); if a~=b then pair(stock[b],stock[a]) end
        end
      end
    end
    table.sort(candidates,function(a,b) local x=a.result..a.p.uid..a.d.uid; local y=b.result..b.p.uid..b.d.uid; return x<y end)
    -- Round robin prevents an unlucky common side result starving other branches.
    if #candidates>0 then
      st.recipeCursor=(st.recipeCursor or 0)%#candidates+1
      local c=candidates[st.recipeCursor]; start('mutate',c.result,c.p.princessItem,c.d.droneItem,c.conditions); return true
    end
    return false
  end
  local function migrate()
    if st.migrated then return end
    local text=readText(dir..'apiary-run.new') or readText(dir..'apiary-run')
    if text then
      local old=parse(text,'APIARY1')
      if not old.finished then
        if old.lease then
          local p=component.proxy(old.lease.interface)
          for slot=1,2 do call(p.setInterfaceConfiguration,slot); assert(call(p.getInterfaceConfiguration,slot)==nil,'Legacy request cleanup failed') end
          local pDB=component.proxy(old.lease.database)
          for _,slot in ipairs(old.lease.slots) do call(pDB.clear,slot) end
        end
        for key,j in pairs(old.jobs) do
          assert(machines[key] and machines[key].kind=='apiary','Legacy apiary missing')
          local orphan=j.phase=='loading' and not alive(item(machines[key],1)) and alive(item(machines[key],2))
          st.apiaries[key]={uid=j.uid,puid=j.uid,duid=j.uid,orphan=orphan}
          if orphan then print('LEGACY PARTIAL INPUT',key,'preserved; no unprepared princess will be added') end
        end
        save()
        old.finished=true; old.migratedTo=path
        writeText(dir..'apiary-run',ser.serialize(old))
        if fs.exists(dir..'apiary-run.new') then assert(fs.remove(dir..'apiary-run.new')) end
        print('Existing apiary jobs adopted; partial inputs are preserved, never blindly completed.')
      end
    end
    st.migrated=true; save()
  end
  local function perform()
    cleanLease(); migrate()
    st.operationSeq=st.operationSeq or 0
    local ordered={}
    for id,f in pairs(st.flows) do
      if f.op then
        if f.op.order then st.operationSeq=math.max(st.operationSeq,f.op.order)
        else ordered[#ordered+1]=id end
      end
    end
    table.sort(ordered,function(a,b) return tonumber(a)<tonumber(b) end)
    for _,id in ipairs(ordered) do
      st.operationSeq=st.operationSeq+1; st.flows[id].op.order=st.operationSeq
    end
    save()
    for key,job in pairs(st.resources) do st.resources[key]=nil; save(); release(job.ref) end
    if not st.climateRouting then
      for _,f in pairs(st.flows) do
        for index,step in ipairs(f.steps) do
          if index<f.step then
            local id=step:sub(-1)=='P' and f.p or f.d; local r=id and st.refs[id]
            if r and step:match('^analyze') then r.analyzed=true end
            if r and step:match('^imprint') then r.analyzed=true; r.imprinted=true end
          end
        end
        if f.mode=='queen' and f.steps[f.step]=='queen' then
          local loaded=false
          if f.op then for _,feed in ipairs(f.op.feeds) do if feed.loaded or feed.armed then loaded=true end end end
          if not loaded then f.steps={'queen'}; f.step=1; f.op=nil end
        end
      end
      st.climateRouting=true; save()
    end
    if st.resource then release(st.resource); st.resource=nil; save() end
    local used={}
    for _,f in pairs(st.flows) do if f.p then used[f.p]=true end; if f.d then used[f.d]=true end end
    local garbage={}; for id in pairs(st.refs) do if not used[id] then garbage[#garbage+1]=id end end
    for _,id in ipairs(garbage) do release(id) end
    for _,module in pairs(modules) do
      for slot=1,9 do assert(call(module.m.getInterfaceConfiguration,slot)==nil,'Existing interface request at '..module.interface) end
      -- A just-cleared request can take a tick to return its surplus to ME.
      for attempt=0,15 do if emptyBuffer(module) then break end; assert(attempt<15,'Interface buffer not empty'); tick() end
    end
    for key in pairs(st.apiaries) do assert(machines[key],'Owned apiary is missing') end
    save()
    print('AUTO: breeding analyzer -> imprinter -> apiary; mutation parents -> mutatron; queens -> climate apiary; reserve 16; species gene chance 7.7%; recipe conditions follow Settings; server requirements remain enforced.')
    print('Ctrl+C pauses. bees auto resumes. Fluids/power must be supplied to the machines.')
    local capacity=0
    local owned={}
    for _,r in pairs(st.refs) do owned[r.database..':'..r.slot]=true end
    for _,e in ipairs(tools.databases) do
      for slot=1,81 do
        local v,err=read(e.proxy.get,slot); if err then break end
        if v==nil or owned[e.address..':'..slot] then capacity=capacity+1 end
      end
    end
    local supplySlots=#groups.imprinter+2*#groups.sampler+#groups.mutatron
    local flowLimit=math.max(0,math.min(options.queue>0 and options.queue or (#groups.apiary+#groups.mutatron+#groups.sampler),math.floor((capacity-supplySlots)/2)))
    print('Preparation capacity:',flowLimit,'flows; analyzer input slots: 6 per machine')
    local nextRead=0; local lastSummary=-60
    local schedule={'queen','mutate','breed','breed','sample'}
    local cursor=0
    assert(flowLimit>0 or next(st.flows),'No usable job capacity; check modules and free OC database entries')
    for _,f in pairs(st.flows) do if f.op then assert(machines[f.op.key],'Saved processor is missing; resolve existing work before changing modules') end end
    while true do
      if dashboard then
        dashboard.pollUpdate(); dashboard.render(st)
        assert(not dashboard.stopRequested,'Stopped from dashboard')
      end
      processControls()
      availability={}
      serviceUnowned()
      serviceApiaries()
      if computer.uptime()>=nextRead then
        local items,err=readME(me,true); assert(type(items)=='table',err or 'ME read failed')
        stock,samples=collectStock(items); st.needFresh=false; nextRead=computer.uptime()+ME_INTERVAL
      end
      local ids={}; for id in pairs(st.flows) do ids[#ids+1]=id end
      table.sort(ids,function(a,b) return tonumber(a)<tonumber(b) end)
      for _,id in ipairs(ids) do currentID=id; flow=st.flows[id]; serviceFlow() end
      currentID=nil; flow=nil
      do
        local count=0; for _ in pairs(st.flows) do count=count+1 end
        while count<flowLimit and not st.needFresh do
          local started=false
          for _=1,#schedule do
            cursor=cursor%#schedule+1
            if choose(stock,samples,schedule[cursor]) then started=true; break end
          end
          if not started then
            if count==0 then warn('No currently available task; monitoring ME. Some species need parents or a wild source.') end
            break
          end
          count=count+1
        end
      end
      if computer.uptime()-lastSummary>=60 then
        local beesCount,sampleCount,active=0,0,0
        for _ in pairs(stock) do beesCount=beesCount+1 end
        for _ in pairs(samples) do sampleCount=sampleCount+1 end
        for _ in pairs(st.apiaries) do active=active+1 end
        print('AUTO STATUS','bee species='..beesCount,'sample evidence='..sampleCount,'apiaries='..active,'cycles='..st.cycles,'donors='..st.samples)
        lastSummary=computer.uptime()
      end
      tick()
    end
  end
  if args[2]=='recover' then
    local candidates={}
    local function emptyMutatron(m)
      for slot=1,3 do if alive(item(m,slot)) then return false end end
      return true
    end
    for id,f in pairs(st.flows) do
      local m=f.op and machines[f.op.key]
      if m and m.kind=='mutatron' and emptyMutatron(m) then candidates[#candidates+1]=id end
    end
    assert(#candidates>0,'No empty mutatron jobs to recover; occupied machines are preserved')
    local number=1
    while fs.exists(dir..'automation-recover-'..number) do number=number+1 end
    local archive=dir..'automation-recover-'..number
    local text=ser.serialize(st)
    writeText(archive..'.new',text); assert(readText(archive..'.new')==text,'Recovery archive verification failed')
    assert(fs.rename(archive..'.new',archive))
    cleanLease()
    for _,id in ipairs(candidates) do
      currentID=id; flow=st.flows[id]
      local m=machines[flow.op.key]
      if emptyMutatron(m) then
        print('RECOVERED EMPTY MUTATRON',m.key,'cancelled job '..id)
        finishFlow()
      else print('KEEP MUTATRON',m.key,'inventory changed; existing job retained') end
    end
    currentID=nil; flow=nil; st.needFresh=true; save()
    print('Recovery archived at '..archive..'; other jobs preserved. Run bees auto.')
    return true
  end
  local function reportDisconnected()
    local ok,seen=pcall(function()
      local found={}; for address in component.list() do found[address]=true end; return found
    end)
    if not ok then print('Component diagnostics unavailable: '..tostring(seen)); return end
    local required={[me.address]='ME network'}
    for _,module in pairs(modules) do
      required[module.address]='transposer'; required[module.interface]='ME interface'
    end
    for _,r in pairs(st.refs) do required[r.database]='OC database' end
    local missing={}
    for address,kind in pairs(required) do
      if not seen[address] then missing[#missing+1]=kind..' '..address end
    end
    table.sort(missing)
    for _,text in ipairs(missing) do print('OFFLINE',text) end
    if #missing>0 then
      print('Restore component connections/power and loaded chunks, then bees auto. Keep the queue and bindings.')
    end
  end
  local ok,err=pcall(perform)
  if not ok then
    if dashboard then dashboard.cleaning=true; dashboard.critical=nil end
    local cleaned,cleanupError=pcall(cleanLease)
    if dashboard then dashboard.safeToRun=cleaned end
    print('AUTO PAUSED: '..tostring(err))
    if not cleaned then print('Request cleanup pending: '..tostring(cleanupError)) end
    reportDisconnected()
    print('Loaded inputs and exact references preserved. Fix the error, then bees auto.')
    return false
  end
  return true
end
