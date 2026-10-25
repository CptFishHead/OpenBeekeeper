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
  if args[2]=="status" then
    print("AUTOMATION: apiary cycles="..st.cycles.."; sampled drones="..st.samples.."; mutations="..st.mutations)
    if st.flow then print("FLOW",st.flow.mode,st.flow.target,"step="..st.flow.step) end
    for key,job in pairs(st.apiaries) do print("APIARY",key,job.uid) end
    print(st.wait or "No resource wait recorded."); return true
  end
  assert(args[2]==nil or args[2]=="resume","Use bees auto [resume/status]")
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
  local function warn(message)
    if st.wait~=message then st.wait=message; print("WAIT "..message); save() end
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
      assert(attempt<15,"Exact item not delivered within 15 seconds")
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
    deliver(m,id,slot,math.min(v.maxSize or 16,16),{})
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
  local function free(m)
    if st.apiaries[m.key] then return false end
    local lo,hi=outputSlots(m.kind)
    for slot=lo,hi do if alive(item(m,slot)) then return false end end
    if m.kind=='apiary' or m.kind=='mutatron' then return not alive(item(m,1)) and not alive(item(m,2)) end
    if m.kind=='analyzer' then
      if alive(item(m,1)) then return false end
      for slot=3,8 do if alive(item(m,slot)) then return false end end
      return true
    end
    return not alive(item(m,3))
  end
  local function find(kind)
    local best,score
    for _,m in ipairs(groups[kind]) do
      if free(m) and emptyBuffer(m.module) then
        local climate=0
        if kind=='apiary' then
          for slot=3,6 do
            local v=item(m,slot)
            if alive(v) and (v.label=='Light Upgrade' or v.label=='Seal Upgrade') then climate=climate+1 end
          end
        end
        if not best or climate>score then best=m; score=climate end
      end
    end
    return best
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
    local f=assert(st.flow)
    st.flow=nil; st.needFresh=true; save()
    release(f.p); release(f.d)
  end
  local function copyOutput(m,slot,id)
    local r=assert(st.refs[id])
    assert(call(m.module.t.store,m.side,slot,r.database,r.slot),"Cannot copy exact output descriptor")
  end
  local function serviceFlow()
    local f=st.flow; if not f then return end
    if f.pendingP then f.p=reference(f.pendingP); f.pendingP=nil; save() end
    if f.pendingD then f.d=reference(f.pendingD); f.pendingD=nil; save() end
    for _,id in ipairs({f.p or false,f.d or false}) do if id then materialize(id) end end
    local step=f.steps[f.step]
    if not step then finishFlow(); return end
    local kind=step:match('^analyze') and 'analyzer' or step:match('^imprint') and 'imprinter'
      or step=='sample' and 'sampler' or step=='mate' and (f.mode=='mutate' and 'mutatron' or 'apiary') or 'apiary'
    if not f.op then
      local m=find(kind)
      if not m then warn("No empty "..kind); return end
      if not supplies(m) then return end
      local feeds={}
      if step=='mate' then
        feeds={{ref=f.d,slot=2},{ref=f.p,slot=1}}
      elseif step=='queen' then feeds={{ref=f.p,slot=1}}
      else feeds={{ref=step:sub(-1)=='P' and f.p or f.d,slot=3}} end
      f.op={key=m.key,feeds=feeds,phase='feeding',ticks=0}; st.wait=nil; save()
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
            if not deliver(m,feed.ref,feed.slot,1,feed) then warn("Input transfer blocked at "..m.key); return end
            feed.loaded=true; save()
          end
        end
      end
      op.phase='working'; save()
      print("PROCESS",step,m.key,f.target)
    end
    if kind=='apiary' then
      if not op.handed then
        st.apiaries[m.key]={uid=st.refs[f.p].uid,target=f.target,puid=st.refs[f.p].uid,duid=f.d and st.refs[f.d].uid}
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
    if op.capture then
      local capture=op.capture
      if alive(item(m,capture.slot)) then
        if capture.ref then copyOutput(m,capture.slot,capture.ref) end
        if not returnSlot(m,capture.slot) then return end
      end
      if capture.ref then
        local r=st.refs[capture.ref]; local v=call(db(r).get,r.slot)
        local uid,k=bee(v or {})
        assert(uid==capture.uid and k==capture.kind,"Captured output descriptor missing")
        r.uid=uid; r.kind=k; r.filter=nil; r.ready=true; save()
      end
      if capture.failed then
        if not capture.applied then st.losses=(st.losses or 0)+1; capture.applied=true; save() end
        print('GENETIC LOSS',kind,f.target,'waste returned; replanning from actual stock')
        finishFlow()
      elseif kind=='mutatron' then
        st.mutations=st.mutations+1
        print("MUTATION RESULT",capture.uid,"wanted",f.target,capture.uid==f.target and 'MATCH' or 'SIDE SPECIES SAVED')
        local oldDrone=f.d; f.d=nil; f.mode='queen'; f.steps={'queen'}; f.step=1; f.op=nil; save(); release(oldDrone)
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
  local function start(mode,target,p,d)
    local f={mode=mode,target=target,step=1,steps=mode=='sample' and {'analyzeD','imprintD','sample'}
      or mode=='queen' and {'queen'} or {'analyzeP','imprintP','analyzeD','imprintD','mate'}}
    f.pendingP=p; f.pendingD=d; st.flow=f; st.wait=nil; save()
    st.needFresh=true; save(); print("FLOW",mode,target)
  end
  local function choose(stock,samples)
    local busy={}
    for _,j in pairs(st.apiaries) do
      if not j.orphan then busy[j.uid]=true; if j.puid then busy[j.puid]=true end; if j.duid then busy[j.duid]=true end end
    end
    local list={}; for _,e in pairs(stock) do list[#list+1]=e end
    table.sort(list,function(a,b) return a.uid<b.uid end)
    local function idle(e) return e and not busy[e.uid] end
    local function target(e) return samples[e.uid] and DRONE_TARGET or DRONE_TARGET+38 end
    for _,e in ipairs(list) do
      if idle(e) and e.queenItem and (e.drone<target(e) or e.princess==0) then start('queen',e.uid,e.queenItem); return true end
    end
    for _,e in ipairs(list) do
      if idle(e) and e.princess>0 and e.drone>0 and e.drone<target(e) then start('multiply',e.uid,e.princessItem,e.droneItem); return true end
    end
    for _,e in ipairs(list) do
      if idle(e) and not samples[e.uid] and e.drone>DRONE_TARGET then start('sample',e.uid,nil,e.droneItem); return true end
    end
    for _,e in ipairs(list) do
      if idle(e) and (e.drone<DRONE_TARGET or not samples[e.uid]) then
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
      if type(recipe)=='table' and not hasConditions(recipe) then
        local a,b,result=resolve(recipe.allele1),resolve(recipe.allele2),resolve(recipe.result)
        if a and b and result and not samples[result] and (not stock[result] or stock[result].princess==0) then
          local function pair(p,d)
            if idle(p) and idle(d) and p.princess>0 and d.drone>=2 and (p.drone>0 or p.princess>1) then
              candidates[#candidates+1]={p=p,d=d,result=result}
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
      local c=candidates[st.recipeCursor]; start('mutate',c.result,c.p.princessItem,c.d.droneItem); return true
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
    if st.resource then release(st.resource); st.resource=nil; save() end
    local used={}
    if st.flow then if st.flow.p then used[st.flow.p]=true end; if st.flow.d then used[st.flow.d]=true end end
    local garbage={}; for id in pairs(st.refs) do if not used[id] then garbage[#garbage+1]=id end end
    for _,id in ipairs(garbage) do release(id) end
    for _,module in pairs(modules) do
      for slot=1,9 do assert(call(module.m.getInterfaceConfiguration,slot)==nil,'Existing interface request at '..module.interface) end
      -- A just-cleared request can take a tick to return its surplus to ME.
      for attempt=0,15 do if emptyBuffer(module) then break end; assert(attempt<15,'Interface buffer not empty'); tick() end
    end
    for key in pairs(st.apiaries) do assert(machines[key],'Owned apiary is missing') end
    save()
    print('AUTO: analyzer -> imprinter -> apiary/mutatron; reserve 32; species gene chance 7.7%; conditional recipes excluded.')
    print('Ctrl+C pauses. bees auto resumes. Fluids/power must be supplied to the machines.')
    local nextRead=0; local stock,samples={},{}; local lastSummary=-60
    while true do
      serviceApiaries()
      if computer.uptime()>=nextRead then
        local items,err=readME(me,true); assert(type(items)=='table',err or 'ME read failed')
        stock,samples=collectStock(items); st.needFresh=false; nextRead=computer.uptime()+ME_INTERVAL
      end
      if st.flow then serviceFlow()
      elseif not st.needFresh then
        if not choose(stock,samples) then warn('No currently available unconditional task; monitoring ME. Some species need parents or a wild source.') end
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
