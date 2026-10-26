-- Embedded in openbeekeeper.lua by tools/embed_automation.py; no runtime module dependency.
local function automate()
  local fs=require("filesystem")
  local ser=require("serialization")
  local computer=require("computer")
  local event=require("event")
  local dir="/home/.openbeekeeper-data/"
  local path=dir.."automation"
  local function call(method,...)
    local value,err=read(method,...); assert(not err,err); return value
  end
  local function parse(text,schema)
    local ok,value=pcall(ser.unserialize,text)
    assert(ok and type(value)=="table" and value.schema==schema,"Invalid "..schema.." journal; preserve it")
    return value
  end
  local raw=readText(path..".new") or readText(path)
  local st=raw and parse(raw,"AUTO1") or {schema="AUTO1",refs={},apiaries={},seq=0,cycles=0,samples=0,mutations=0}
  st.flows=st.flows or {}
  if st.flow then st.seq=st.seq+1; st.flows[tostring(st.seq)]=st.flow; st.flow=nil end
  local flow,currentID
  if args[2]=="status" then
    print("AUTOMATION: apiary cycles="..st.cycles.."; sampled drones="..st.samples.."; mutations="..st.mutations)
    for id,f in pairs(st.flows) do print("FLOW",id,f.mode,f.target,"step="..f.step) end
    for key,job in pairs(st.apiaries) do print("APIARY",key,job.uid) end
    if st.reset then print('RESET CLEANUP PENDING; use bees auto reset; archive: '..tostring(st.reset.archive)) end
    print(st.wait or "No resource wait recorded."); return true
  end
  assert(args[2]==nil or args[2]=="resume" or args[2]=="reset","Use bees auto [resume/status/reset]")
  assert(args[3]==nil or (args[2]=='reset' and args[3]=='empty'),'Use bees auto reset [empty]')
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
    if st.lease or st.resource then refuse('unresolved interface lease/resource transfer') end
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
    for _,module in pairs(modules) do
      for slot=1,9 do
        if call(module.m.getInterfaceConfiguration,slot)~=nil then refuse('active interface request '..module.interface..' slot '..slot) end
        if alive(call(module.t.getStackInSlot,module.source,slot)) then refuse('occupied staging buffer '..module.interface..' slot '..slot) end
      end
    end
    for _,m in pairs(machines) do
      local slots=m.kind=='apiary' and {1,2,7,8,9,10,11,12,13,14,15}
        or m.kind=='analyzer' and {1,3,4,5,6,7,8,9,10,11,12}
        or m.kind=='mutatron' and {1,2,3} or {3,4}
      for _,slot in ipairs(slots) do
        if alive(call(m.module.t.getStackInSlot,m.side,slot)) then refuse('occupied '..m.kind..' '..m.key..' slot '..slot) end
      end
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
    if st.lastResetArchive and not next(st.refs) and not next(st.flows) then
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
    assert(#groups[kind]>0,"No bound "..kind.." (advanced mutatron selection is not supported)")
    table.sort(groups[kind],function(a,b) if a.side~=b.side then return a.side<b.side end return a.key<b.key end)
  end
  local names,aliases,recipes={},{},{}
  for _,v in ipairs(catalogues) do
    local list=read(v.proxy.listAllSpecies)
    if type(list)=="table" then
      for _,x in pairs(list) do if type(x)=="table" and x.uid then names[x.uid]=x.name or x.uid end end
      recipes=call(v.proxy.getBeeBreedingData) or {}; break
    end
  end
  assert(next(names),"Forestry catalogue unavailable")
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
    assert(event.pull(1)~="interrupted","Paused by Ctrl+C; bees auto resumes")
  end
  local function db(ref) return component.proxy(ref.database) end
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
    error("No free OC database entry")
  end
  local function release(id)
    if not id or not st.refs[id] then return end
    local r=st.refs[id]; call(db(r).clear,r.slot)
    assert(call(db(r).get,r.slot)==nil,"Could not clear owned database entry")
    st.refs[id]=nil; save()
  end
  local function cleanLease()
    if not st.lease then return end
    local p=component.proxy(st.lease.interface)
    call(p.setInterfaceConfiguration,9)
    assert(call(p.getInterfaceConfiguration,9)==nil,"Could not clear automation request 9")
    st.lease=nil; save()
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
  -- Exact database requests, with a real NBT comparison before each transfer.
  local function deliver(m,id,destination,count,intention)
    local r=assert(st.refs[id],"Missing owned bee reference")
    for attempt=0,15 do
      if emptyBuffer(m.module) then break end
      assert(attempt<15,"Interface buffer is occupied: "..m.module.address); tick()
    end
    st.lease={interface=m.module.interface}; save()
    assert(call(m.module.m.setInterfaceConfiguration,9,r.database,r.slot,count),"Interface request failed")
    local source
    for attempt=0,15 do
      for slot=1,9 do
        local v=call(m.module.t.getStackInSlot,m.module.source,slot)
        if alive(v) then
          assert(not source and matches(v,r) and v.size<=count,"Unexpected item in staging interface")
          assert(call(m.module.t.compareStackToDatabase,m.module.source,slot,r.database,r.slot,true),"Staged item NBT differs from the owned descriptor")
          source=slot
        end
      end
      if source then break end
      if attempt==15 then
        cleanLease()
        return false,"Exact item not delivered within 15 seconds: "..tostring(r.uid or r.name).." / "..tostring(r.kind or r.label).."; check ME stock, exact NBT and interface supply. Retrying this job; other jobs continue."
      end
      tick()
    end
    intention.armed=true; save() -- Recovery must never blindly replay a triggering input.
    local v=call(m.module.t.getStackInSlot,m.module.source,source)
    local moved=call(m.module.t.transferItem,m.module.source,m.side,v.size,source,destination)
    assert(type(moved)=="number" and moved>=0 and moved<=v.size,"Invalid loading result")
    if moved==0 then intention.armed=false; save() end
    cleanLease()
    return moved>0
  end
  local function reference(v)
    local id=allocate(); local r=st.refs[id]
    r.filter={name=v.name,label=v.label}; r.uid,r.kind=bee(v); r.name=v.name; r.label=v.label
    save(); return id
  end
  local function materialize(id)
    local r=st.refs[id]
    if r.ready then return end
    call(me.proxy.store,r.filter,r.database,r.slot,1)
    local v=call(db(r).get,r.slot)
    assert(matches(v,r),"ME item no longer matches requested descriptor")
    r.ready=true; save()
  end
  local resourceRetry={}
  local function resource(m,slot,label)
    if alive(item(m,slot)) then return true end
    if resourceRetry[label] and computer.uptime()<resourceRetry[label] then return false end
    resourceRetry[label]=computer.uptime()+ME_INTERVAL
    local id=st.resource or allocate(); st.resource=id; save()
    local r=st.refs[id]
    call(me.proxy.store,{label=label},r.database,r.slot,1)
    local v=call(db(r).get,r.slot)
    if not alive(v) or v.label~=label then
      release(id); st.resource=nil; save(); warn("ME needs "..label); return false
    end
    r.name=v.name; r.label=v.label; r.uid=nil; r.kind=nil; save()
    local _,reason=deliver(m,id,slot,math.min(v.maxSize or 16,16),{})
    if reason then warn(reason) end
    release(id); st.resource=nil; save()
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
      if not alive(template) or template.name~='gendustry:gene_template' then warn("Imprinter needs the user template without species/effect"); return false end
      return resource(m,2,'Genetics Labware')
    elseif m.kind=='sampler' then return resource(m,1,'Blank Gene Sample') and resource(m,2,'Genetics Labware')
    elseif m.kind=='mutatron' then return fluidReady(m) and resource(m,4,'Genetics Labware') end
    return true
  end
  local availability,zoneCache={},{}
  local function free(m)
    if st.apiaries[m.key] then return false end
    for id,f in pairs(st.flows) do if id~=currentID and f.op and f.op.key==m.key then return false end end
    if m.kind=='apiary' and availability[m.key]~=nil then return availability[m.key] end
    local lo,hi=outputSlots(m.kind)
    for slot=lo,hi do if alive(item(m,slot)) then return false end end
    if m.kind=='apiary' or m.kind=='mutatron' then
      local result=not alive(item(m,1)) and not alive(item(m,2))
      if m.kind=='apiary' then availability[m.key]=result end
      return result
    end
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
        roleMatches=zone.role==purpose and (purpose=='breeding' or (zone.temperature==requiredT and zone.humidity==requiredH))
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
      elseif kind~='analyzer' and roleMatches and free(m) and emptyBuffer(m.module) then
        local climate=kind=='apiary' and zoneCache[m.key].value.score or 0
        if not best or climate>score then best=m; score=climate end
      end
    end
    return best,nil,kind=='apiary' and ('No free '..tostring(purpose)..' zone'..(requiredT and ' '..requiredT..'/'..requiredH or '')..'; inspect bees zones') or nil
  end
  local function returnSlot(m,slot)
    local v=item(m,slot); if not alive(v) then return true end
    local moved=call(m.module.t.transferItem,m.side,m.module.source,v.size,slot)
    assert(type(moved)=="number" and moved>=0 and moved<=v.size,"Invalid bulk return")
    if moved>0 then print("RETURN",m.kind,moved,v.label or v.name) end
    return not alive(item(m,slot))
  end
  local function serviceApiaries()
    for key,job in pairs(st.apiaries) do
      local m=assert(machines[key],"Saved apiary is missing")
      local empty=true
      for slot=7,15 do if not returnSlot(m,slot) then empty=false end end
      if not alive(item(m,1)) and not alive(item(m,2)) and empty then
        st.apiaries[key]=nil; st.cycles=st.cycles+1; st.needFresh=true; save()
        print("APIARY COMPLETE",key,job.uid)
      end
    end
  end
  local function finishFlow()
    local f=assert(flow)
    waiting[currentID]=nil
    st.flows[currentID]=nil; flow=nil; st.needFresh=true; save()
    release(f.p); release(f.d)
  end
  local function copyOutput(m,slot,id)
    local r=assert(st.refs[id])
    assert(call(m.module.t.store,m.side,slot,r.database,r.slot),"Cannot copy exact output descriptor")
  end
  local deliveryRetry={}
  local function serviceFlow()
    local f=flow; if not f then return end
    if deliveryRetry[currentID] and computer.uptime()<deliveryRetry[currentID] then return end
    if f.pendingP then f.p=reference(f.pendingP); f.pendingP=nil; save() end
    if f.pendingD then f.d=reference(f.pendingD); f.pendingD=nil; save() end
    for _,id in ipairs({f.p or false,f.d or false}) do if id then materialize(id) end end
    local step=f.steps[f.step]
    if not step then finishFlow(); return end
    local kind=step:match('^analyze') and 'analyzer' or step:match('^imprint') and 'imprinter'
      or step=='sample' and 'sampler' or step=='mate' and (f.mode=='mutate' and 'mutatron' or 'apiary') or 'apiary'
    if not f.op then
      local wanted=st.refs[(step=='queen' or step:sub(-1)=='P') and f.p or f.d]
      local purpose=kind=='apiary' and (step=='queen' and 'incubator' or 'breeding') or nil
      if purpose=='breeding' then
        assert(st.refs[f.p].analyzed and st.refs[f.p].imprinted and st.refs[f.d].analyzed and st.refs[f.d].imprinted,'Both breeding parents must be analyzed and imprinted')
      elseif purpose=='incubator' then assert(wanted and wanted.analyzed,'Queen must pass analyzer before climate routing') end
      local m,analysisSlot,reason=find(kind,wanted,purpose)
      if not m then warn(reason or "No empty "..kind); return end
      if not supplies(m) then return end
      local feeds={}
      if step=='mate' then
        feeds={{ref=f.d,slot=2},{ref=f.p,slot=1}}
      elseif step=='queen' then feeds={{ref=f.p,slot=1}}
      else feeds={{ref=step:sub(-1)=='P' and f.p or f.d,slot=analysisSlot or 3}} end
      f.op={key=m.key,feeds=feeds,phase='feeding',ticks=0}; f.wait=nil; waiting[currentID]=nil; st.wait=nil; save()
      if kind=='mutatron' and f.conditions and #f.conditions>0 then
        print('CONDITIONAL ATTEMPT',f.target,table.concat(f.conditions,'; '),'requirements are not verified by OC; server decides availability')
      end
    end
    local op=f.op; local m=assert(machines[op.key],"Saved processor is missing")
    if op.phase=='feeding' then
      if not supplies(m) then return end
      for _,feed in ipairs(op.feeds) do
        if not feed.loaded then
          local r=st.refs[feed.ref]; local v=item(m,feed.slot)
          if alive(v) then
            assert(matches(v,r),"Unexpected bee in owned input")
            feed.loaded=true; save()
          elseif feed.armed and not (step=='mate' and feed.slot==2 and not op.feeds[2].armed) then
            -- The triggering item may be internal/already output. Never replay it.
            feed.loaded=true; save()
          else
            local delivered,reason=deliver(m,feed.ref,feed.slot,1,feed)
            if not delivered then
              if reason then deliveryRetry[currentID]=computer.uptime()+ME_INTERVAL end
              warn(reason or ("Input transfer blocked at "..m.key)); return
            end
            deliveryRetry[currentID]=nil
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
        op.handed=true; save()
      end
      finishFlow(); return
    end
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
      if alive(physical) then
        local uid,k=bee(physical)
        local same=capture.ref and uid==capture.uid and k==capture.kind
          or not capture.ref and physical.name==capture.name and physical.label==capture.label
        if same then
          if capture.ref then copyOutput(m,capture.slot,capture.ref); capture.copied=true; save() end
          if not returnSlot(m,capture.slot) then return end
        else
          assert(capture.copied,'Owned output changed before capture completed')
        end
      end
      if capture.ref then
        local r=st.refs[capture.ref]; local v=call(db(r).get,r.slot)
        local uid,k=bee(v or {})
        assert(uid==capture.uid and k==capture.kind,"Captured output descriptor missing")
        r.uid=uid; r.kind=k; r.filter=nil; r.ready=true; save()
        local active=type(v.individual)=='table' and v.individual.active
        local fertility=type(active)=='table' and tonumber(active.fertility)
        if fertility and fertility>=1 and fertility<=64 then r.fertility=fertility; save() end
        if kind=='analyzer' then r.analyzed=true; save()
        elseif kind=='imprinter' then r.analyzed=true; r.imprinted=true; save() end
      end
      if capture.failed then
        if not capture.applied then st.losses=(st.losses or 0)+1; capture.applied=true; save() end
        print('GENETIC LOSS',kind,f.target,'waste returned; replanning from actual stock')
        finishFlow()
      elseif kind=='mutatron' then
        st.mutations=st.mutations+1
        print("MUTATION RESULT",capture.uid,"wanted",f.target,capture.uid==f.target and 'MATCH' or 'SIDE SPECIES SAVED')
        local oldDrone=f.d; f.d=nil; f.mode='queen'; f.steps={'analyzeP','queen'}; f.step=1; f.op=nil; save(); release(oldDrone)
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
      or mode=='queen' and {'analyzeP','queen'} or {'analyzeP','imprintP','analyzeD','imprintD','mate'}}
    f.pendingP=p; f.pendingD=d; f.conditions=conditions; st.seq=st.seq+1; st.flows[tostring(st.seq)]=f; st.wait=nil; save(); print("FLOW",mode,target)
  end
  local function choose(stock,samples)
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
        if uid and available[uid] then available[uid][k]=math.max(0,available[uid][k]-1) end
      end
      if f.mode=='multiply' or f.mode=='queen' then
        local r=f.p and st.refs[f.p]
        local fertility=r and r.fertility or 4
        predicted[f.target]=(predicted[f.target] or 0)+(f.mode=='queen' and fertility or math.max(0,fertility-1))
      end
    end
    stock=available
    local list={}; for _,e in pairs(stock) do list[#list+1]=e end
    table.sort(list,function(a,b)
      if (load[a.uid] or 0)~=(load[b.uid] or 0) then return (load[a.uid] or 0)<(load[b.uid] or 0) end
      return a.uid<b.uid
    end)
    local function idle(e) return e~=nil end
    local function target(e) return samples[e.uid] and DRONE_TARGET or DRONE_TARGET+38 end
    for _,e in ipairs(list) do
      if e.queen>0 and (e.stockDrone+(predicted[e.uid] or 0)<target(e) or e.princess==0) then start('queen',e.uid,e.queenItem); return true end
    end
    for _,e in ipairs(list) do
      if e.princess>0 and e.drone>0 and e.stockDrone+(predicted[e.uid] or 0)<target(e) then start('multiply',e.uid,e.princessItem,e.droneItem); return true end
    end
    for _,e in ipairs(list) do
      if idle(e) and not samples[e.uid] and e.drone>DRONE_TARGET then start('sample',e.uid,nil,e.droneItem); return true end
    end
    for _,e in ipairs(list) do
      if not incoming[e.uid] and (e.drone<DRONE_TARGET or not samples[e.uid]) then
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
        if a and b and result and not incoming[result] and (not samples[result] or extinct) and (not existing or existing.princess==0) then
          local function pair(p,d)
            if idle(p) and idle(d) and p.princess>0 and d.drone>=2 and (p.drone>0 or p.princess>1) then
              local conditions={}
              if type(recipe.specialConditions)=='table' then for _,v in pairs(recipe.specialConditions) do conditions[#conditions+1]=tostring(v) end
              elseif hasConditions(recipe) then conditions[1]=tostring(recipe.specialConditions) end
              table.sort(conditions)
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
          if not loaded then f.steps={'analyzeP','queen'}; f.step=1; f.op=nil end
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
    print('AUTO: analyzer -> imprinter -> apiary/mutatron; reserve 32; species gene chance 7.7%; all recipes allowed; server requirements remain enforced.')
    print('Ctrl+C pauses. bees auto resumes. Fluids/power must be supplied to the machines.')
    local capacity=0
    for _,e in ipairs(tools.databases) do
      for slot=1,81 do
        local v,err=read(e.proxy.get,slot); if err then break end
        if v==nil then capacity=capacity+1 end
      end
    end
    for _ in pairs(st.refs) do capacity=capacity+1 end
    local flowLimit=math.max(1,math.min(#groups.apiary,#groups.analyzer*6,math.floor((capacity-1)/2)))
    print('Preparation capacity:',flowLimit,'flows; analyzer input slots: 6 per machine')
    local nextRead=0; local stock,samples={},{}; local lastSummary=-60
    while true do
      availability={}
      serviceApiaries()
      if computer.uptime()>=nextRead then
        local items,err=readME(me,true); assert(type(items)=='table',err or 'ME read failed')
        stock,samples=collectStock(items); st.needFresh=false; nextRead=computer.uptime()+ME_INTERVAL
      end
      local ids={}; for id in pairs(st.flows) do ids[#ids+1]=id end
      table.sort(ids,function(a,b) return tonumber(a)<tonumber(b) end)
      for _,id in ipairs(ids) do currentID=id; flow=st.flows[id]; serviceFlow() end
      currentID=nil; flow=nil
      if not st.needFresh then
        local count=0; for _ in pairs(st.flows) do count=count+1 end
        while count<flowLimit do
          if not choose(stock,samples) then
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
  local ok,err=pcall(perform)
  if not ok then
    local cleaned,cleanupError=pcall(cleanLease)
    print('AUTO PAUSED: '..tostring(err))
    if not cleaned then print('Request cleanup pending: '..tostring(cleanupError)) end
    print('Loaded inputs and exact references preserved. Fix the error, then bees auto.')
    return false
  end
  return true
end
