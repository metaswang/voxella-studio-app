// Development host: real, read-only MCP data by default. ?mode=fixture is explicit.
import { AppBridge, PostMessageTransport } from '@modelcontextprotocol/ext-apps/app-bridge';
const live = new URLSearchParams(location.search).get('mode') !== 'fixture';
let sessionId = '', requestId = 0, initializing: Promise<void>|undefined;
async function rpc(method:string, params:any={}, retry=true):Promise<any> {
 if(method!=='initialize'&&!sessionId){
  initializing??=rpc('initialize',{protocolVersion:'2025-11-25',capabilities:{},clientInfo:{name:'voxstudio-local-read-preview',version:'1'}},false).then(async()=>{await rpc('notifications/initialized',{},false)}).finally(()=>{initializing=undefined});
  await initializing;
 }
 const id=++requestId;
 const response=await fetch('/mcp',{method:'POST',headers:{'Content-Type':'application/json',...(sessionId?{'Mcp-Session-Id':sessionId}:{}),'MCP-Protocol-Version':'2025-11-25'},body:JSON.stringify({jsonrpc:'2.0',...(method.startsWith('notifications/')?{}:{id}),method,params})});
 if(response.status===404&&sessionId&&retry){sessionId='';return rpc(method,params,false)}
 sessionId=response.headers.get('Mcp-Session-Id')||sessionId;
 const raw=await response.text();
 const reply=raw.startsWith('{')?JSON.parse(raw):raw.split('\n').filter(line=>line.startsWith('data: {')).map(line=>JSON.parse(line.slice(6))).find(value=>value.id===id);
 if(!response.ok||reply?.error)throw Error(typeof reply?.error==='string'?reply.error:reply?.error?.message||'Could not connect to the local VoxStudio MCP. Open the latest Mac app build.');
 return reply?.result??{};
}
const result=(data:any)=>({content:[{type:'text' as const,text:JSON.stringify(data)}],structuredContent:data});
const sessions=[
 {session_id:'11111111-1111-4111-8111-111111111111',title:'Designing a more human workspace',kind:'transcription',status:'completed',duration:148,language:'en',updated_at:'2026-10-03T08:00:00Z',translation_languages:['zh']},
 {session_id:'22222222-2222-4222-8222-222222222222',title:'Introducing the next chapter',kind:'dubbing',status:'completed',duration:32,language:'en',updated_at:'2026-10-02T12:00:00Z'},
 {session_id:'33333333-3333-4333-8333-333333333333',title:'产品访谈 · 让创作更简单',kind:'transcription',status:'completed',duration:624,language:'zh',updated_at:'2026-10-02T10:00:00Z'},
 {session_id:'44444444-4444-4444-8444-444444444444',title:'Studio notes · Morning thoughts',kind:'transcription',status:'failed',duration:85,language:'en',updated_at:'2026-10-01T08:00:00Z'}
];
const voices=[{voice_id:'voice-a',name:'Alex',language:'en',duration:18},{voice_id:'voice-b',name:'Jamie',language:'en',duration:12},{voice_id:'voice-c',name:'林',language:'zh',duration:24}];
let cues=[{id:1,start_ms:0,end_ms:8000,text:'The best tools give you room to think. They make the complicated feel effortless.',speaker:'Alex'},{id:2,start_ms:8000,end_ms:16000,text:'We started with a simple question: what would a quieter, more intentional workspace look like?',speaker:'Jamie'},{id:3,start_ms:16000,end_ms:24000,text:'Fewer distractions. Clearer choices. And a little more space for the work that matters.',speaker:'Alex'}];
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
 if(!preview)throw Error('Sample preview is no longer available. Load it again.');
 let bytes=fixtureMedia.get(preview.file);
 if(!bytes){bytes=(async()=>{const response=await fetch('/'+preview.file);if(!response.ok)throw Error('Sample media is missing. Rebuild the local preview fixtures.');const data=new Uint8Array(await response.arrayBuffer());let binary='';for(let i=0;i<data.length;i+=8192)binary+=String.fromCharCode(...data.subarray(i,i+8192));return btoa(binary)})();fixtureMedia.set(preview.file,bytes);bytes.catch(()=>fixtureMedia.delete(preview.file));}
 return {contents:[{uri,mimeType:preview.mimeType,blob:await bytes}]};
}
const panelFor:Record<string,string>={app_workbench:'library',app_transcription:'transcription',app_session:'session',app_dubbing:'dubbing'};
async function respond(name:string,args:any={}){
 counts[name]=(counts[name]||0)+1;log.textContent=`${++callCount} calls · ${name} (${counts[name]})`;
 if(live)return rpc('tools/call',{name,arguments:args});
 if(name==='voxstudio.sessions'||name==='voxstudio.library'||name==='app_workbench')return result({view:'library',sessions:emptyList?[]:sessions,native_forms:false});
 if(name==='app_transcription')return result({view:'transcription',native_forms:false});
 if(name==='app_dubbing'||name==='voice.list')return result({view:'dubbing',voices:emptyList?[]:voices});
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
  return result({preview_resource_uri:uri,mime_type:mimeType,start,end:start+15,cues:cues.filter(c=>c.end_ms/1000>start&&c.start_ms/1000<start+15).map(c=>({id:c.id,start:c.start_ms/1000,end:c.end_ms/1000,text:c.text}))});
 }
 if(name==='session.editor.read')return result({session_id:args.session_id,scope:args.scope,language:args.language??'en',revision,cues});
 if(name==='session.editor.commit'){
  if(failSave)return {content:[{type:'text' as const,text:'This transcript changed in another window. Your draft has been kept.'}],isError:true};
  if(args.expected_revision!==revision)return {content:[{type:'text' as const,text:'Revision conflict'}],isError:true};
  for(const op of args.operations){const cue=cues.find(c=>c.id===op.cue_id)!;if(op.type==='text')cue.text=op.text;if(op.type==='timing'){cue.start_ms=op.start_ms;cue.end_ms=op.end_ms}}
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
 bridge=new AppBridge(null,{name:live?'VoxStudio local preview':'VoxStudio fixture preview',version:'1'}, {serverTools:{},serverResources:{},updateModelContext:{},message:{text:{}}} as any,{hostContext:{theme:dark?'dark':'light',locale:'zh-CN',displayMode:'fullscreen'}});
 bridge.oncalltool=p=>respond(p.name,p.arguments);
 bridge.onreadresource=p=>readResource(p.uri);
 bridge.onupdatemodelcontext=async()=>({});
 bridge.onmessage=async p=>{const text=p.content.find(c=>c.type==='text');const name=Object.keys(panelFor).find(n=>text?.type==='text'&&text.text.includes(n));const json=text?.type==='text'?text.text.match(/\{[\s\S]*\}/)?.[0]:undefined;let args={};try{if(json)args=JSON.parse(json)}catch{}if(name)setTimeout(()=>void mount(panelFor[name],args),0);return {}};
 bridge.oninitialized=async()=>{const tool=Object.keys(panelFor).find(k=>panelFor[k]===name)!;await bridge!.sendToolInput({arguments:args});try{await bridge!.sendToolResult(await respond(tool,args));status.textContent=`${label} · connected`}catch(error){status.textContent=`${label} · unavailable`;await bridge!.sendToolResult({content:[{type:'text',text:String(error)}],isError:true})}};
 await bridge.connect(new PostMessageTransport(frame.contentWindow!,frame.contentWindow!));
 frame.src=`/panels/${name}.html`;
 document.querySelectorAll<HTMLButtonElement>('[data-panel]').forEach(b=>{b.setAttribute('aria-pressed',String(b.dataset.panel===name));b.disabled=live&&b.dataset.panel==='session'&&!selectedSession});
}
for(const button of document.querySelectorAll<HTMLButtonElement>('[data-panel]'))button.onclick=()=>void mount(button.dataset.panel!);
document.querySelector('#theme')!.addEventListener('click',()=>{dark=!dark;void bridge?.setHostContext({theme:dark?'dark':'light'})});
document.querySelector('#width')!.addEventListener('click',()=>{frame.classList.toggle('narrow')});
document.querySelector('#conflict')!.addEventListener('change',e=>{failSave=(e.target as HTMLInputElement).checked});
document.querySelector('#empty')!.addEventListener('change',e=>{emptyList=(e.target as HTMLInputElement).checked;void mount(page)});
if(live){document.querySelector('#conflict')!.parentElement!.hidden=true;document.querySelector('#empty')!.parentElement!.hidden=true;log.textContent='Real app sessions · read-only browser preview · create/edit in the ChatGPT/Codex plugin'}
window.addEventListener('pagehide',()=>{if(sessionId)void fetch('/mcp',{method:'DELETE',headers:{'Mcp-Session-Id':sessionId},keepalive:true})});
void mount('library');
