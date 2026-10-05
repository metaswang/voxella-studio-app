import {$,app,esc,shell,icon,action,call,start,context,notice,clearPlayer,onDispose,isDisposed,backButton,type Obj} from '../shared/ui';
import {createSessionView} from '../shared/session-view';
import {createSessionList,sessionListMarkup} from '../shared/session-list';
import {stateArguments,sessionPresentation,sessionRow,distinctSessions} from '../shared/workspace-model';
let state:Obj={},workspaceId='',boundTurn:string|undefined,revision:number|undefined,expanded=true;
let catalog:Obj[]=[],catalogCursor:string|undefined,mode='',detailSignature='',shownSource='',generation=0;
let catalogScope='';
let reader:ReturnType<typeof createSessionView>|undefined,list:ReturnType<typeof createSessionList>|undefined;
let listExtras:Obj[]=[],listKey='',extraCursor:string|undefined,hasExtraPage=false;
let timer:ReturnType<typeof setTimeout>|undefined,polling=false,backoff=2000,stopped=false,viewQueue=Promise.resolve();
let historicalView:Obj={};
shell('Sessions',`<div class="panel-display"><button id="expand" class="text-button" hidden>Expand ${icon('external')}</button></div><div id="content"><div class="loading-card"><div class="skeleton wide"></div></div></div>`);
function hostMode(){const host=app.getHostContext();expanded=host?.displayMode!=='inline'||!boundTurn;$('expand').hidden=!host?.availableDisplayModes?.includes('fullscreen')||host?.displayMode==='fullscreen';}
function isHistorical(){return Boolean(!expanded&&boundTurn&&state.active_turn_id!==boundTurn);}
function updateControls(){const pin=$('pin-session');if(pin){pin.hidden=isHistorical();pin.textContent=state.view?.pinned?'Unpin session':'Pin session';pin.setAttribute('aria-pressed',String(Boolean(state.view?.pinned)));}}
async function readingContext(){await context({workspace_id:workspaceId,turn_id:state.turn_id,scope:state.next_scope??{},reading_source_id:mode==='session'?shownSource:undefined});}
function saveView(values:Obj,render=false){
 const id=workspaceId,turn=state.turn_id,origin=generation;
 viewQueue=viewQueue.catch(()=>{}).then(async()=>{
  if(stopped||id!==workspaceId||origin!==generation||turn!==state.turn_id)return;
  if(isHistorical()){
   historicalView={...historicalView,...values};state.view={...state.view,...values};
   for(const key of Object.keys(state.view))if(state.view[key]===null)delete state.view[key];
   if(render)await renderPresentation();else {detailSignature=signature();updateControls();}
   await readingContext();return;
  }
  const fresh=await call('knowledge.workspace_state',{workspace_id:id});
  if(stopped||id!==workspaceId||origin!==generation||turn!==fresh.turn_id)return;
  const result=await call('knowledge.update_view',{workspace_id:id,expected_view_revision:fresh.view_revision,view:values});
  if(stopped||id!==workspaceId)return;
  // A view write can return newer retrieval results or even a new active turn.
  // Consume that state through the same renderer as polling so its revision
  // cannot suppress the detail-to-list transition on the next poll. Preserve
  // the existing reader for this session's own tab/language/anchor changes.
  if(!render&&result.turn_id===turn&&sessionPresentation(result,catalog).source?.session_id===shownSource)detailSignature=signature(result);
  await applyState(result);
 });return viewQueue;
}
function signature(value:Obj=state){return [workspaceId,value.turn_id,value.view?.source_id,value.view?.evidence_id].join(':');}
async function openSession(row:Obj){await saveView({source_id:row.session_id,evidence_id:null,material:'canonical',reading_view:'body',language:'source',anchor:0,manual_turn_id:state.turn_id??null},true);}
async function backToList(){await saveView({source_id:null,evidence_id:null,pinned:false,manual_turn_id:state.turn_id??null},true);}
async function loadCatalog(append=false){
 const id=workspaceId,scope=state.scope??state.next_scope??{},key=JSON.stringify(scope);
 const result=await call('list_sources',{...scope,limit:100,...(append&&catalogCursor?{cursor:catalogCursor}:{})});
 if(stopped||id!==workspaceId||key!==JSON.stringify(state.scope??state.next_scope??{}))return;
 catalogScope=key;
 catalog=distinctSessions(append?[...catalog,...(result.sources??[])]:result.sources??[]);catalogCursor=result.next_cursor||undefined;
}
function currentListKey(presentation:Obj){return JSON.stringify([state.turn_id,presentation.listing?.sequence,presentation.args]);}
async function moreSessions(){
 const presentation=sessionPresentation(state,catalog);if(presentation.kind!=='list')return;
 if(!presentation.listing){await loadCatalog(true);await renderPresentation();return;}
 const cursor=hasExtraPage?extraCursor:presentation.cursor;if(!cursor)return;
 const key=currentListKey(presentation),id=workspaceId;
 const result=(await call('knowledge.workspace_state',{workspace_id:id,turn_id:state.turn_id,page:{observation_id:presentation.listing.observation_id,cursor}})).page;
 if(stopped||id!==workspaceId||key!==currentListKey(sessionPresentation(state,catalog)))return;
 listExtras=distinctSessions([...listExtras,...(result.sources??[])]);extraCursor=result.next_cursor||undefined;hasExtraPage=true;
 await renderPresentation();
}
async function renderPresentation(){
 if(stopped)return;
 const presentation=sessionPresentation(state,catalog);
 if(presentation.kind==='list'){
  if(mode!=='list'){
   generation++;reader?.dispose();reader=undefined;mode='list';detailSignature='';shownSource='';
   $('content').innerHTML=sessionListMarkup();
   list=createSessionList({open:openSession,refresh:async()=>{await loadCatalog();await renderPresentation();},more:moreSessions});
  }
  const key=currentListKey(presentation);
  if(key!==listKey){listKey=key;listExtras=[];extraCursor=undefined;hasExtraPage=false;}
  list!.setRows(distinctSessions([...presentation.rows,...listExtras]),Boolean(presentation.listing?(hasExtraPage?extraCursor:presentation.cursor):catalogCursor),presentation.loading);
  return;
 }
 const nextSignature=signature();if(mode==='session'&&nextSignature===detailSignature){updateControls();return;}
 const current=++generation;reader?.dispose();mode='session';detailSignature=nextSignature;list=undefined;
 $('content').innerHTML=`<div class="back-row session-navigation">${backButton()}<button id="pin-session" class="text-button" aria-pressed="false">Pin session</button></div><div id="detail"><div class="loading-card"><div class="skeleton wide"></div></div></div>`;
 shownSource=presentation.source.session_id;
 action('back',backToList);action('pin-session',()=>saveView({source_id:shownSource,pinned:!state.view?.pinned}));updateControls();
 const readingTurn=state.turn_id;
 reader=createSessionView({readOnly:true,onChange:values=>current===generation&&readingTurn===state.turn_id?saveView({...values,evidence_id:null,manual_turn_id:state.turn_id??null}):Promise.resolve()});
 let source=presentation.source;
 // Catalog paging may omit a specifically requested session. Read its metadata
 // rather than substituting another session or blocking cloud text on media status.
 if(!catalog.some(row=>row.session_id===source.session_id)){
  const metadata=await call('fetch',{source_id:source.session_id,view:'metadata'});
  if(current!==generation||stopped)return;
  source=sessionRow({...source,...metadata});
 }
 const evidence=presentation.evidence??{};
 if(state.view?.evidence_id){await call('fetch',{evidence_id:state.view.evidence_id,limit:1});if(current!==generation||stopped)return;}
 await reader.show(source,{...state.view,character_start:evidence.character_start,character_end:evidence.character_end,anchor:state.view?.anchor??evidence.character_start});
}
async function applyState(next:Obj){
 if(stopped||next.unchanged||typeof next.revision!=='number'||(revision!==undefined&&next.revision<revision))return;
 state=next;revision=next.revision;
 if(isHistorical())state={...state,view:{...state.view,...historicalView}};
 if(catalogScope!==JSON.stringify(state.scope??state.next_scope??{}))await loadCatalog();
 await renderPresentation();await readingContext();
}
function clearContent(message:string){
 generation++;reader?.dispose();reader=undefined;list=undefined;catalog=[];catalogCursor=undefined;mode='';detailSignature='';shownSource='';state={};clearPlayer();
 $('content').innerHTML=`<div class="empty-state"><h3>Sessions unavailable</h3><p>${esc(message)}</p><button id="reopen" class="button small">Reopen sessions</button></div>`;
 action('reopen',async()=>{const result=await call('voxstudio.workspace');workspaceId=result.workspace_id;boundTurn=undefined;revision=undefined;hostMode();await loadCatalog();await applyState(result);void pollState();});
}
async function pollState(){
 if(polling||stopped||isDisposed()||document.hidden||!workspaceId)return;
 polling=true;
 try{await applyState(await call('knowledge.workspace_state',stateArguments(workspaceId,boundTurn,expanded,revision)));backoff=state.complete===false?1000:2000;}
 catch(error){
  backoff=Math.min(backoff*2,30000);
  const message=error instanceof Error?error.message:String(error);
  if(/changed|stale|unauthoriz|expired|unavailable|cancelled/i.test(message)){clearContent(message);workspaceId='';clearTimeout(timer);}
  else notice(message,true);
 }
 finally{polling=false;clearTimeout(timer);if(!stopped&&!document.hidden&&workspaceId)timer=setTimeout(()=>void pollState(),backoff);}
}
action('expand',async()=>{await app.requestDisplayMode({mode:'fullscreen'});hostMode();revision=undefined;await pollState();});
const visibility=()=>{clearTimeout(timer);if(!document.hidden)void pollState();};document.addEventListener('visibilitychange',visibility);
onDispose(()=>{stopped=true;generation++;reader?.dispose();clearTimeout(timer);document.removeEventListener('visibilitychange',visibility);});
start('voxstudio.workspace',async data=>{
 if(data.workspace_id!==workspaceId){generation++;reader?.dispose();workspaceId=data.workspace_id;boundTurn=data.turn_id;revision=undefined;mode='';detailSignature='';state=data;catalogScope='';historicalView={};}
 hostMode();if(!expanded&&boundTurn&&data.turn_id!==boundTurn)return;await applyState(data);void pollState();
},()=>({}));
const originalHostContext=app.onhostcontextchanged;
app.onhostcontextchanged=parameters=>{originalHostContext?.(parameters);hostMode();revision=undefined;void pollState();};
