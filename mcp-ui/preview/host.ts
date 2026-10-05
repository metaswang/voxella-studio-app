// Development host: real, read-only MCP data by default. ?mode=fixture is explicit.
import { AppBridge, PostMessageTransport } from '@modelcontextprotocol/ext-apps/app-bridge';
const unified = new URLSearchParams(location.search).get('panel')==='workspace';
const endpoint=unified?'/app/mcp':'/mcp';
const live = new URLSearchParams(location.search).get('mode') !== 'fixture';
let sessionId = '', requestId = 0, initializing: Promise<void>|undefined;
async function rpc(method:string, params:any={}, retry=true):Promise<any> {
 if(method!=='initialize'&&!sessionId){
  initializing??=rpc('initialize',{protocolVersion:'2025-11-25',capabilities:{},clientInfo:{name:'voxstudio-local-read-preview',version:'1'}},false).then(async()=>{await rpc('notifications/initialized',{},false)}).finally(()=>{initializing=undefined});
  await initializing;
 }
 const id=++requestId;
 const response=await fetch(endpoint,{method:'POST',headers:{'Content-Type':'application/json',...(sessionId?{'Mcp-Session-Id':sessionId}:{}),'MCP-Protocol-Version':'2025-11-25'},body:JSON.stringify({jsonrpc:'2.0',...(method.startsWith('notifications/')?{}:{id}),method,params})});
 if(response.status===404&&sessionId&&retry){sessionId='';return rpc(method,params,false)}
 sessionId=response.headers.get('Mcp-Session-Id')||sessionId;
 const raw=await response.text();
 const reply=raw.startsWith('{')?JSON.parse(raw):raw.split('\n').filter(line=>line.startsWith('data: {')).map(line=>JSON.parse(line.slice(6))).find(value=>value.id===id);
 if(!response.ok||reply?.error)throw Error(typeof reply?.error==='string'?reply.error:reply?.error?.message||'Could not connect to the local VoxStudio MCP. Open the latest Mac app build.');
 return reply?.result??{};
}
const result=(data:any)=>({content:[{type:'text' as const,text:JSON.stringify(data)}],structuredContent:data,...(unified?{_meta:{'voxstudio/receiptTools':['media.choose_local_file','transcription.create_from_input','session.open']}}:{})});
const sessions=[
 {session_id:'11111111-1111-4111-8111-111111111111',title:'Designing a more human workspace',kind:'transcription',status:'completed',duration:148,language:'en',updated_at:'2026-10-03T08:00:00Z',translation_languages:['zh']},
 {session_id:'22222222-2222-4222-8222-222222222222',title:'Introducing the next chapter',kind:'dubbing',status:'completed',duration:32,language:'en',updated_at:'2026-10-02T12:00:00Z'},
 {session_id:'33333333-3333-4333-8333-333333333333',title:'产品访谈 · 让创作更简单',kind:'transcription',status:'completed',duration:624,language:'zh',updated_at:'2026-10-02T10:00:00Z'},
 {session_id:'44444444-4444-4444-8444-444444444444',title:'Studio notes · Morning thoughts',kind:'transcription',status:'failed',duration:85,language:'en',updated_at:'2026-10-01T08:00:00Z'}
];
const voices=[{voice_id:'voice-a',name:'Alex',language:'en',duration:18},{voice_id:'voice-b',name:'Jamie',language:'en',duration:12},{voice_id:'voice-c',name:'林',language:'zh',duration:24}];
let cues=[{id:1,start_ms:0,end_ms:8000,text:'The best tools give you room to think. They make the complicated feel effortless.',speaker:'Alex'},{id:2,start_ms:8000,end_ms:16000,text:'We started with a simple question: what would a quieter, more intentional workspace look like?',speaker:'Jamie'},{id:3,start_ms:16000,end_ms:24000,text:'Fewer distractions. Clearer choices. And a little more space for the work that matters.',speaker:'Alex'}];
let transcriptCues=[{id:1,start_ms:0,end_ms:8000,text:'The best tools give you room to think.',speaker:'Alex'},{id:2,start_ms:8000,end_ms:16000,text:'They make the complicated feel effortless.',speaker:'Alex'},{id:3,start_ms:16000,end_ms:24000,text:'A quieter workspace leaves room for the work that matters.',speaker:'Jamie'}];
const noSubtitles=new URLSearchParams(location.search).get('subtitles')==='none';
let revision='fixture-1';
const frame=document.querySelector<HTMLIFrameElement>('#panel')!;
const status=document.querySelector('#status')!;
const log=document.querySelector('#calls')!;
let bridge:AppBridge|undefined,page='library',dark=false,failSave=false,emptyList=false,callCount=0,selectedSession='';
const counts:Record<string,number>={};
const fixturePreviews=new Map<string,{mimeType:string,file:string}>();
const fixtureMedia=new Map<string,Promise<string>>();
async function readResource(uri:string){
 if(live)return rpc('resources/read',{uri});
 const preview=fixturePreviews.get(uri);
 if(uri.startsWith('ui://')){const name=uri.includes('workspace')?'workspace':uri.includes('transcription')?'transcription':'dubbing';const text=await (await fetch('/panels/'+name+'.html')).text();return {contents:[{uri,mimeType:'text/html;profile=mcp-app',text}]};}
 if(!preview)throw Error('Sample preview is no longer available. Load it again.');
 let bytes=fixtureMedia.get(preview.file);
 if(!bytes){bytes=(async()=>{const response=await fetch('/'+preview.file);if(!response.ok)throw Error('Sample media is missing. Rebuild the local preview fixtures.');const data=new Uint8Array(await response.arrayBuffer());let binary='';for(let i=0;i<data.length;i+=8192)binary+=String.fromCharCode(...data.subarray(i,i+8192));return btoa(binary)})();fixtureMedia.set(preview.file,bytes);bytes.catch(()=>fixtureMedia.delete(preview.file));}
 return {contents:[{uri,mimeType:preview.mimeType,blob:await bytes}]};
}
const panelFor:Record<string,string>={'voxstudio.workspace':'workspace',app_workbench:'library',app_transcription:'transcription',app_session:'session',app_dubbing:'dubbing'};
let workspaceState:any={workspace_id:'fixture-workspace',active_turn_id:'fixture-turn-1',turn_id:'fixture-turn-1',query:'What makes a quieter workspace?',revision:1,view_revision:0,status:'answered',complete:true,scope:{},next_scope:{},view:{source_id:sessions[0].session_id,evidence_id:'fixture-evidence'},
 candidates:[],read_evidence:[{source_id:sessions[0].session_id,title:sessions[0].title,evidence_id:'fixture-evidence',text:transcriptCues[0].text,start:0,end:8,character_start:0,character_end:transcriptCues[0].text.length,material_kind:'transcript'}],cited_evidence_ids:['fixture-evidence'],observations:{}};
const scenario=new URLSearchParams(location.search).get('scenario');
if(scenario==='scoped')workspaceState.scope={source_ids:[sessions[0].session_id,sessions[2].session_id]};
if(scenario==='search'||scenario==='empty')workspaceState.observations={s:{tool:'search',sequence:0,arguments:{query:'Design',target:'sources'},result:{retrieval:{target:'sources'},results:scenario==='empty'?[]:[{source_id:sessions[0].session_id,title:sessions[0].title}]}}};
if(scenario==='cloud')workspaceState.view={source_id:sessions[2].session_id};
if(scenario==='catalog-paged'){workspaceState.scope={source_ids:[sessions[0].session_id,sessions[2].session_id]};workspaceState.observations={s:{sequence:0,tool:'list_sources',arguments:{limit:1},result:{sources:[{source_id:sessions[0].session_id,title:sessions[0].title}],next_cursor:'fixture-list-next'}}};}
const fixtureHistory=new Map<string,any>();
async function respond(name:string,args:any={}){
 counts[name]=(counts[name]||0)+1;log.textContent=`${++callCount} calls · ${name} (${counts[name]})`;
 if(live)return rpc('tools/call',{name,arguments:args});
 if(unified&&['app_workbench','app_session'].includes(name))return result({...workspaceState,view:name==='app_session'?{source_id:args.session_id}:workspaceState.view});
 if(name==='voxstudio.workspace'||name==='app_knowledge')return result(workspaceState);
 if(name==='knowledge.workspace_state'&&args.page)return result({page:{sources:[{...sessions[2],source_id:sessions[2].session_id}],complete:true}});
 if(name==='knowledge.workspace_state'){const old=args.turn_id?fixtureHistory.get(args.turn_id):undefined;const current=old?{...old,active_turn_id:workspaceState.active_turn_id,revision:workspaceState.revision,view_revision:workspaceState.view_revision}:workspaceState;return result(args.after_revision===current.revision?{workspace_id:workspaceState.workspace_id,revision:current.revision,unchanged:true}:current);}
 if(name==='knowledge.update_view'){
  workspaceState={...workspaceState,revision:workspaceState.revision+1,view_revision:workspaceState.view_revision+1,view:{...workspaceState.view,...args.view},next_scope:args.view.next_scope??workspaceState.next_scope};
  if(scenario==='view-race'){
   // A new question can finish between a view write and its returned snapshot.
   workspaceState={...workspaceState,turn_id:'fixture-turn-2',active_turn_id:'fixture-turn-2',revision:workspaceState.revision+1,view:{pinned:false},observations:{s:{tool:'search',sequence:0,arguments:{query:'Design',target:'sources'},result:{retrieval:{target:'sources'},results:[{source_id:sessions[0].session_id,title:sessions[0].title}]}}}};
  }
  return result(workspaceState);
 }
 if(name==='list_sources')return result({sources:sessions.filter(row=>!args.source_ids||args.source_ids.includes(row.session_id)).map(row=>({...row,source_id:row.session_id,body_readable:true})),complete:true});
 if(name==='fetch'&&args.view==='metadata')return result(sessions.find(row=>row.session_id===args.source_id)??sessions[0]);
 if(name==='fetch'){
  if(args.view==='summary')return result({summary_markdown:'# Saved source summary\n\nA quieter workspace gives people room to think.',complete:true});
  const subtitle=args.material==='subtitles'||args.material==='translation';
  const selected=subtitle?(noSubtitles?[]:cues):transcriptCues;
  let offset=0;
  const segments=selected.map((row,i)=>{const start=offset;offset+=row.text.length+1;return {text:row.text,speaker:[row.speaker],start:scenario==='cloud'?null:row.start_ms/1000,end:scenario==='cloud'?null:row.end_ms/1000,character_start:start,character_end:start+row.text.length,...(args.view==='cues'?{cue_id:row.id,display_text:row.text.replace(/\.$/,'')}:{}),role:'original',source_id:args.source_id??sessions[0].session_id,evidence_id:i===0?'fixture-evidence':'fixture-'+i};}).filter((_,i)=>scenario!=='paged'||(args.cursor?i>0:i===0));
  return result({segments,provenance:subtitle?'subtitle_track':'transcript',total_count:selected.length,complete:scenario!=='paged'||Boolean(args.cursor),next_cursor:scenario==='paged'&&!args.cursor?'fixture-next':null});
 }
 if(name==='voxstudio.sessions'||name==='voxstudio.library'||name==='app_workbench')return result({view:'library',sessions:emptyList?[]:sessions,native_forms:false});
 if(name==='app_transcription')return result({view:'transcription',native_forms:false});
 if(name==='voice.list')return result({voices:emptyList?[]:voices});
 if(name==='app_dubbing'&&scenario==='voiceover-delayed')await new Promise(resolve=>setTimeout(resolve,2000));
 if(name==='app_dubbing')return result({view:'dubbing',voices:emptyList?[]:voices,options:args.session_id?{text:'A saved voiceover script.',title:sessions[1].title,voice_id:voices[0].voice_id,language:'en'}:args,...(args.start||args.session_id?{...sessions[1],title:args.title||sessions[1].title,progress:1}:{})});
 if(name==='app_session'||name==='voxstudio.session_panel')return result({view:'session',...sessions.find(s=>s.session_id===args.session_id)??sessions[0]});
 if(name==='media.status')return result({...sessions.find(s=>s.session_id===args.session_id)??sessions[0],progress:1});
 if(name==='media.session_preview'||name==='media.preview'){
  const session=sessions.find(s=>s.session_id===args.session_id);
  if(!session)throw Error('Sample session not found.');
  const start=Number(args.start??0);
  if(!Number.isFinite(start)||start<0||start>=session.duration)throw Error('Preview start exceeds the sample session duration.');
  // The included synthetic clips are 15 seconds, not recordings of these mock sessions.
  if(args.duration!==undefined&&Number(args.duration)!==15)throw Error('Sample media supports 15-second previews. Use real app data for other durations.');
  const video=name==='media.session_preview',mimeType=video?'video/mp4':'audio/mp4';
  const uri='voxstudio://previews/fixture/'+crypto.randomUUID();
  fixturePreviews.set(uri,{mimeType,file:video?'fixture-video.mp4':'fixture-audio.m4a'});
  return result({preview_resource_uri:uri,mime_type:mimeType,start,end:start+15,captions_ready:!noSubtitles,cues:noSubtitles?[]:cues.filter(c=>c.end_ms/1000>start&&c.start_ms/1000<start+15).map(c=>({id:c.id,start:c.start_ms/1000,end:c.end_ms/1000,text:c.text}))});
 }
 if(name==='session.get_summary'){
  const mode=new URLSearchParams(location.search).get('summary');
  if(mode==='error')throw Error('Sample summary could not be read. Refresh to retry.');
  if(mode==='none')return result({session_id:args.session_id,status:'unavailable',summary_markdown:null,complete:false});
  const markdown='# A more intentional workspace\n\n## Key points\n\n- Fewer distractions give people room to think.\n- Clear choices make creative work feel effortless.\n\n## Next steps\n\nDiscuss a quieter workspace with the team.\n\n> 让创作更简单。'+(mode==='unsafe'?'\n\n<script>throw Error("unsafe")</script><img src="https://example.com/track.png" onerror="alert(1)"><p onclick="alert(1)">Safe text</p>':'');
  const cursor=Number(args.cursor??0),page=mode==='paged'?markdown.slice(cursor,cursor+100):markdown;
  return result({session_id:args.session_id,summary_markdown:page,complete:cursor+page.length>=markdown.length,next_cursor:cursor+page.length<markdown.length?cursor+page.length:null});
 }
 if(name==='session.editor.read'){
  const selected=args.scope==='transcript'?transcriptCues:noSubtitles?[]:cues;
  const paragraphs:typeof selected=[];
  for(const cue of selected){const last=paragraphs[paragraphs.length-1];if(last&&last.speaker&&last.speaker===cue.speaker){last.text+=' '+cue.text;last.end_ms=cue.end_ms}else paragraphs.push({...cue})}
  return result({session_id:args.session_id,scope:args.scope,language:args.language??'en',revision,cues:selected,paragraphs,available:selected.length>0,editable:selected.length>0&&args.session_id!==sessions[1].session_id});
 }
 if(name==='session.editor.commit'){
  if(failSave)return {content:[{type:'text' as const,text:'This transcript changed in another window. Your draft has been kept.'}],isError:true};
  if(args.expected_revision!==revision)return {content:[{type:'text' as const,text:'Revision conflict'}],isError:true};
  const selected=args.scope==='transcript'?transcriptCues:cues;
  for(const op of args.operations){const cue=selected.find(c=>c.id===op.cue_id)!;if(op.type==='text')cue.text=op.text;if(op.type==='timing'){cue.start_ms=op.start_ms;cue.end_ms=op.end_ms}}
  revision='fixture-'+Date.now();return result({revision,cues,outcome:'local_committed'});
 }
 if(name==='media.choose_local_file')return result({asset_id:'fixture-asset',status:'ready',name:'Design conversation.m4a'});
 if(name==='transcription.create_from_input')return result(sessions[0]);
 if(name==='dubbing.create')return result(sessions[1]);
 if(name==='media.save_result'||name==='documents.save_as')return result({outcome:'cancelled'});
 if(name==='documents.export')return result({document_id:'export-document'});
 throw Error('Fixture does not implement '+name);
}
async function mount(name:string,args:any={}){
 if(args.session_id)selectedSession=args.session_id;
 if(live&&name==='session'&&!args.session_id&&selectedSession)args={session_id:selectedSession};
 const label=live?'Local MCP preview · real app data · read-only':'Fixture host · sample data';
 if(bridge)await bridge.close();page=name;frame.src='about:blank';status.textContent=`${label} · connecting`;
 bridge=new AppBridge(null,{name:live?'VoxStudio local preview':'VoxStudio fixture preview',version:'1'}, {serverTools:{},serverResources:{},updateModelContext:{},message:{text:{}}} as any,{hostContext:{theme:dark?'dark':'light',locale:'zh-CN',displayMode:new URLSearchParams(location.search).get('display')==='inline'?'inline':'fullscreen',availableDisplayModes:['inline','fullscreen']}});
 bridge.onrequestdisplaymode=async p=>{await bridge!.setHostContext({displayMode:p.mode});return {mode:p.mode};};
 bridge.oncalltool=p=>respond(p.name,p.arguments);
 bridge.onreadresource=p=>readResource(p.uri);
 bridge.onupdatemodelcontext=async()=>({});
 bridge.onmessage=async p=>{const text=p.content.find(c=>c.type==='text');const name=Object.keys(panelFor).find(n=>text?.type==='text'&&text.text.includes(n));const json=text?.type==='text'?text.text.match(/\{[\s\S]*\}/)?.[0]:undefined;let args={};try{if(json)args=JSON.parse(json)}catch{}if(name)setTimeout(()=>void mount(panelFor[name],args),0);return {}};
 bridge.oninitialized=async()=>{let tool=Object.keys(panelFor).find(k=>panelFor[k]===name)!;const workspace=new URLSearchParams(location.search).get('workspace_id');if(live&&name==='workspace'&&workspace){tool='app_knowledge';args={action:'show',workspace_id:workspace};}await bridge!.sendToolInput({arguments:args});try{await bridge!.sendToolResult(await respond(tool,args));status.textContent=`${label} · connected`}catch(error){status.textContent=`${label} · unavailable`;await bridge!.sendToolResult({content:[{type:'text',text:String(error)}],isError:true})}};
 await bridge.connect(new PostMessageTransport(frame.contentWindow!,frame.contentWindow!));
 frame.src=`/panels/${name}.html`;
 document.querySelectorAll<HTMLButtonElement>('[data-panel]').forEach(b=>{b.setAttribute('aria-pressed',String(b.dataset.panel===name));b.disabled=live&&b.dataset.panel==='session'&&!selectedSession});
}
for(const button of document.querySelectorAll<HTMLButtonElement>('[data-panel]'))button.onclick=()=>void mount(button.dataset.panel!);
document.querySelector('#theme')!.addEventListener('click',()=>{dark=!dark;void bridge?.setHostContext({theme:dark?'dark':'light'})});
document.querySelector('#width')!.addEventListener('click',()=>{frame.classList.toggle('narrow')});
document.querySelector('#conflict')!.addEventListener('change',e=>{failSave=(e.target as HTMLInputElement).checked});
document.querySelector('#empty')!.addEventListener('change',e=>{emptyList=(e.target as HTMLInputElement).checked;void mount(page)});
const follow=document.createElement('button');follow.textContent='Simulate follow-up';follow.id='follow-up';follow.hidden=live;document.querySelector('nav')!.append(follow);
follow.onclick=()=>{fixtureHistory.set(workspaceState.turn_id,structuredClone(workspaceState));workspaceState={...workspaceState,turn_id:'fixture-turn-2',active_turn_id:'fixture-turn-2',revision:workspaceState.revision+1,view_revision:workspaceState.view_revision+1,scope:{},observations:{},view:workspaceState.view.pinned?workspaceState.view:{source_id:sessions[2].session_id}};void bridge?.sendToolResult(result(workspaceState));};
if(live){document.querySelector('#conflict')!.parentElement!.hidden=true;document.querySelector('#empty')!.parentElement!.hidden=true;log.textContent='Real app sessions · read-only browser preview · create/edit in the ChatGPT/Codex plugin'}
window.addEventListener('pagehide',()=>{if(sessionId)void fetch(endpoint,{method:'DELETE',headers:{'Mcp-Session-Id':sessionId},keepalive:true})});
const requestedPanel=new URLSearchParams(location.search).get('panel');
const voiceoverScript='Make Your Own Lemonade” is about turning life’s setbacks into chances for practical action and growth. It encourages acknowledging what’s hard, then choosing a next step—such as addressing worry, protecting your health or finances, and finding small things to be grateful for.';
const requestedSession=new URLSearchParams(location.search).get('session_id');
void mount(requestedPanel&&['workspace','session','dubbing','transcription'].includes(requestedPanel)?requestedPanel:'library',requestedSession?{session_id:requestedSession}:scenario==='voiceover-prompt'?{text:voiceoverScript,title:'Make Your Own Lemonade',voice_id:voices[0].voice_id,language:'en',start:false}:['voiceover-start','voiceover-delayed'].includes(scenario??'')?{text:voiceoverScript,title:'Make Your Own Lemonade',voice_id:voices[0].voice_id,language:'en',start:true}:{});
