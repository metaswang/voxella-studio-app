import { App, applyDocumentTheme, applyHostStyleVariables } from '@modelcontextprotocol/ext-apps';
import {openLegacyPanel} from './legacy-panel';
import { voxStudioLogo } from './logo';
export type Obj = Record<string, any>;
export const app = new App({name: 'VoxStudio', version: '0.2.0'}, {availableDisplayModes: ['inline', 'fullscreen']});
export const $ = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id) as T;
// Product requirement: always English, independent of the host/system locale.
export const chinese = false;
export const t = (zh: string, en: string) => chinese ? zh : en;
export const esc = (value: unknown) => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]!));
export const icons: Record<string, string> = {
 wave:'<path d="M3 10v4m4-8v12m5-16v20m5-16v12m4-8v4"/>',
 text:'<path d="M4 5h16M4 10h12M4 15h16M4 20h8"/>',
 mic:'<rect x="9" y="2" width="6" height="13" rx="3"/><path d="M5 10v2a7 7 0 0 0 14 0v-2M12 19v3m-4 0h8"/>',
 video:'<rect x="3" y="5" width="18" height="14" rx="3"/><path d="m10 9 5 3-5 3Z"/>',
 arrow:'<path d="M5 12h14m-5-5 5 5-5 5"/>',
 back:'<path d="M19 12H5m5-5-5 5 5 5"/>',
 plus:'<path d="M12 5v14M5 12h14"/>',
 search:'<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 5 5"/>',
 refresh:'<path d="M20 7v5h-5M4 17v-5h5M5 7a8 8 0 0 1 13-2l2 2M4 17l2 2a8 8 0 0 0 13-2"/>',
 upload:'<path d="M12 16V3m-5 5 5-5 5 5M4 15v5a1 1 0 0 0 1 1h14a1 1 0 0 0 1-1v-5"/>',
 check:'<path d="m5 12 4 4L19 6"/>',
 clock:'<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
 folder:'<path d="M3 7V5a2 2 0 0 1 2-2h5l2 3h7a2 2 0 0 1 2 2v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z"/>',
 play:'<path d="m8 4 12 8-12 8Z"/>',
 download:'<path d="M12 3v13m-5-5 5 5 5-5M4 17v4h16v-4"/>',
 edit:'<path d="m14 5 5 5M4 20l5-1L21 7a2 2 0 0 0-5-5L4 14Z"/>',
 cut:'<circle cx="6" cy="6" r="3"/><circle cx="6" cy="18" r="3"/><path d="m8 8 13 13M8 16 21 3"/>',
 sound:'<path d="m11 4-6 5H2v6h3l6 5Zm4 4a6 6 0 0 1 0 8m3-11a10 10 0 0 1 0 14"/>',
 close:'<path d="m6 6 12 12M6 18 18 6"/>',
 external:'<path d="M14 3h7v7m0-7L10 14M10 3H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-5"/>',
 error:'<circle cx="12" cy="12" r="9"/><path d="M12 7v6m0 3v1"/>',
};
export function icon(name: string, cls = '') { return `<svg class="icon ${cls}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${icons[name] ?? icons.wave}</svg>`; }
export function shell(section: string, body: string) {
 document.documentElement.lang = chinese ? 'zh-CN' : 'en';
 document.body.innerHTML = `<div class="app-shell"><header class="topbar"><div class="brand"><span class="brand-mark"><img src="${voxStudioLogo}" width="30" height="30" alt="" aria-hidden="true"></span><span>VoxStudio</span></div><span class="top-section">${esc(section)}</span><span id="connection" class="connection"><i></i>${t('正在连接','Connecting')}</span></header><main id="main">${body}</main><footer class="app-footer"><span>${t('由 Mac 上的 VoxStudio 处理','Processed by VoxStudio on your Mac')}</span><span>VoxStudio</span></footer></div><div id="notice" class="notice" hidden role="status" aria-live="polite"><span id="notice-message"></span><button id="dismiss-notice" class="icon-button" aria-label="${t('关闭提示','Dismiss notification')}">${icon('close')}</button></div>`;
 $('dismiss-notice').onclick = () => $('notice').hidden = true;
}
export function notice(message: string, error = false) { $('notice-message').textContent=message; $('notice').hidden=false; $('notice').classList.toggle('error',error); }
export function clearNotice() { $('notice').hidden=true; }
let receiptTools = new Set<string>();
export function decode(result: Obj): Obj {
 if(Array.isArray(result._meta?.["voxstudio/receiptTools"]))receiptTools=new Set(result._meta["voxstudio/receiptTools"]);
 const text=result.content?.find((c: Obj)=>c.type==='text')?.text;
 if (result.isError) throw new Error(result.structuredContent?.error || text || t('操作失败，请重试','Operation failed. Please try again.'));
 if (result.structuredContent) return result.structuredContent;
 if (text) { try { return JSON.parse(text); } catch { return {message:text}; } }
 return {};
}
let connected = false, disposed = false;
const cleanups: Array<()=>void> = [];
export const onDispose = (fn:()=>void) => cleanups.push(fn);
export const isDisposed = () => disposed;
class VoxStudioUnavailableError extends Error {}
export async function rawCall(name: string, args: Obj = {}) {
 if (!connected) throw new Error(t('尚未连接到 VoxStudio，请稍候','Waiting for VoxStudio to connect.'));
 try {
  const result = await app.callServerTool({name, arguments:receiptTools.has(name)&&!args.request_id?{...args,request_id:crypto.randomUUID()}:args});
  if(Array.isArray(result._meta?.['voxstudio/receiptTools']))receiptTools=new Set(result._meta['voxstudio/receiptTools']);
  if (result.isError) decode(result);
  $('connection').innerHTML='<i></i>Connected';$('connection').classList.add('online');
  return result;
 } catch(error) {
  const message=error instanceof Error?error.message:String(error);
  if(/Transport.*error|HTTP request failed|error sending request|connection (?:closed|refused)|fetch failed/i.test(message)) {
   $('connection').textContent='Disconnected';$('connection').classList.remove('online');
   throw new VoxStudioUnavailableError('VoxStudio is not reachable. Open the Mac app, then retry. If it was restarted, reopen this panel.');
  }
  throw error;
 }
}
export async function call(name: string, args: Obj = {}) { return decode(await rawCall(name,args)); }
export async function openNativeSession(sessionId:string) {
 try { return await call('session.open',{session_id:sessionId}); }
 catch(error) {
  if(!(error instanceof VoxStudioUnavailableError))throw error;
  // The host can launch a registered Mac URL scheme even while MCP is offline.
  try {
   const result=await app.openLink({url:`voxstudio://sessions/${encodeURIComponent(sessionId)}`});
   if(!result.isError){notice('VoxStudio launch requested. If it stays closed, open the Mac app. Then reopen this panel to reconnect.');return result;}
  } catch {}
  throw new Error('VoxStudio is closed. This host could not launch it. Open the Mac app, then reopen this panel and retry.');
 }
}
export function action(id: string, handler:()=>Promise<unknown>) {
 const button=$(id) as HTMLButtonElement;
 button.onclick=async()=>{if(button.disabled)return; button.disabled=true;button.setAttribute('aria-busy','true');clearNotice();try{await handler()}catch(e){if(!disposed&&button.isConnected)notice(e instanceof Error?e.message:String(e),true)}finally{if(button.isConnected){button.disabled=false;button.removeAttribute('aria-busy')}}};
}
export function value(id: string) { return ($<HTMLInputElement>(id)).value; }
export function time(seconds: number) { if(!Number.isFinite(seconds)||seconds<0)return '—';const s=Math.floor(seconds);return `${Math.floor(s/60).toString().padStart(2,'0')}:${(s%60).toString().padStart(2,'0')}`; }
export function date(raw?:string) { if(!raw)return '';const value=new Date(raw);return Number.isNaN(+value)?'':new Intl.DateTimeFormat(chinese?'zh-CN':'en',{month:'short',day:'numeric'}).format(value); }
export function stateLabel(state:string) { return ({completed:t('已完成','Completed'),failed:t('处理失败','Failed'),cancelled:t('已取消','Cancelled'),running:t('处理中','Processing'),queued:t('等待中','Queued'),pending:t('等待中','Queued'),processing:t('处理中','Processing'),idle:t('草稿','Draft'),not_started:t('草稿','Draft')})[state] ?? t('准备中','Preparing'); }
export function badge(state:string) { return `<span class="badge ${['completed','failed','cancelled'].includes(state)?state:'running'}"><i></i>${esc(stateLabel(state))}</span>`; }
export function empty(title:string,description:string,glyph='folder') { return `<div class="empty-state"><span class="empty-icon">${icon(glyph)}</span><h3>${esc(title)}</h3><p>${esc(description)}</p></div>`; }
export function languages(auto=false) { return (auto?[["",t('自动识别','Detect automatically')]]:[]).concat([['zh',t('中文','Chinese')],['en',t('英语','English')],['ja',t('日语','Japanese')],['ko',t('韩语','Korean')],['es',t('西班牙语','Spanish')],['fr',t('法语','French')],['de',t('德语','German')]]).map(([v,label])=>`<option value="${v}">${label}</option>`).join(''); }
export function languageLabel(code:string) { return ({zh:t('中文','Chinese'),en:t('英语','English'),ja:t('日语','Japanese'),ko:t('韩语','Korean'),es:t('西班牙语','Spanish'),fr:t('法语','French'),de:t('德语','German'),source:t('原文','Original')})[code]??code; }
export function field(label:string,control:string,hint='') { return `<div class="field">${label}${control}${hint?`<p class="field-hint">${hint}</p>`:''}</div>`; }
export function backButton() { return `<button id="back" class="text-button">${icon('back')}${t('会话列表','Sessions')}</button>`; }
const panelNames: Record<string,[string,string]> = {app_workbench:['会话列表','Sessions'],app_transcription:['转录','Transcription'],app_dubbing:['配音','Voiceover'],app_session:['会话详情','Session details']};
// Navigate unified panels through standard resources without adding model instructions to chat.
export async function openPanel(tool: string, args: Obj = {}) {
 if(!connected)throw new Error('Please wait for the connection.');
 if(!panelNames[tool])throw new Error('Unknown panel');
 if(!receiptTools.size){await openLegacyPanel(app,panelNames[tool][1],tool,args);return;}
 const name=tool==='app_workbench'?'voxstudio.workspace':tool;
 const result=await rawCall(name,args);
 const uri=['app_session','app_workbench'].includes(tool)?'ui://voxstudio/workspace/v3':tool==='app_transcription'?'ui://voxstudio/transcription/v4':'ui://voxstudio/dubbing/v4';
 const resource=await app.readServerResource({uri});
 const html=resource.contents.find(row=>'text' in row);
 if(!html||!('text' in html))throw new Error('Panel resource is unavailable.');
 (window as any).__voxstudioPanelResult=result;
 disposed=true;for(const cleanup of cleanups)cleanup();await app.close();
 document.open();document.write(html.text);document.close();
}
export async function context(value: Obj) { try { await app.updateModelContext({structuredContent:value}); } catch { /* Content still works when optional model context is unsupported. */ } }
export function progress(state:Obj) {const amount=Math.max(0,Math.min(100,Math.round((state.progress||0)*100)));return `<div class="progress-heading">${badge(state.status)}<span>${amount}%</span></div><progress max="100" value="${amount}">${amount}%</progress><p class="muted">${esc(state.error||state.message||(state.status==='completed'?'Your result is ready.':state.status==='failed'?'The job could not be completed. Open the session for details.':state.status==='cancelled'?'This job was cancelled.':'Processing on your Mac. You can return to this session later.'))}</p>`;}
export function poll(read:()=>Promise<Obj>,render:(v:Obj)=>void) {let timer:ReturnType<typeof setTimeout>|undefined;let stopped=false;const run=async()=>{if(stopped||disposed)return;try{const v=await read();if(stopped||disposed)return;render(v);if(!['completed','failed','cancelled','idle'].includes(v.status))timer=setTimeout(run,2000)}catch(e){notice(String(e),true)}};void run();const stop=()=>{stopped=true;clearTimeout(timer)};onDispose(stop);return stop;}
export async function waitInput(result: Obj,onState?:(state:Obj)=>void):Promise<Obj|undefined> {
 while(!disposed){
  if(result.outcome==='cancelled'||result.status==='cancelled')return;
  onState?.(result);
  if(result.status==='ready')return result;
  if(result.status==='selecting'&&result.job_id){
   await new Promise(r=>setTimeout(r,600));
   if(disposed)return;
   result=await call('voxstudio.job_status',{job_id:result.job_id});
  }else if(result.status==='importing'&&result.asset_id){
   await new Promise(r=>setTimeout(r,600));
   if(disposed)return;
   result=await call('media.input_status',{asset_id:result.asset_id});
  }else throw new Error(result.error||t('媒体导入失败','Media import failed'));
 }
}
export async function resolveJob(result:Obj):Promise<Obj> {let attempts=0;while(result.job_id&&!result.session_id&&!result.document_id&&['queued','running','pending','importing',undefined].includes(result.status)&&!disposed){if(++attempts>300)throw new Error(t('任务已提交，稍后可在会话列表查看','Job submitted. Check the sessions list in a moment.'));await new Promise(r=>setTimeout(r,600));result=await call('voxstudio.job_status',{job_id:result.job_id})}if(result.error||result.status==='failed')throw new Error(result.error||'Job failed');return result;}
export function start(fallbackTool:string,consume:(data:Obj)=>Promise<void>|void,fallbackArgs:(args:Obj)=>Obj|undefined= args=>args,consumeInput?:(args:Obj)=>void) {
 let initial:Obj|undefined, input:Obj|undefined, chain=Promise.resolve(), delivered='';
 const handoff=(window as any).__voxstudioPanelResult;
 if(handoff){initial=decode(handoff);delete (window as any).__voxstudioPanelResult;}
 const deliver=(data:Obj)=>{const signature=JSON.stringify(data);if(signature===delivered)return;delivered=signature;chain=chain.then(()=>consume(data)).then(()=>undefined).catch(e=>notice(e instanceof Error?e.message:String(e),true));};
 app.ontoolinput=p=>{input=p.arguments as Obj;consumeInput?.(input)};
 app.ontoolresult=p=>{try{const data=decode(p);if(fallbackTool==='voxstudio.workspace'&&!data.workspace_id)return;initial=data;if(connected)deliver(initial)}catch(e){notice(String(e),true)}};
 const host=(ctx:Obj)=>{if(ctx.theme)applyDocumentTheme(ctx.theme);if(ctx.styles?.variables)applyHostStyleVariables(ctx.styles.variables)};
 app.onhostcontextchanged=host;
 app.onteardown=async()=>{disposed=true;for(const fn of cleanups)fn();return {}};
 const timeout=setTimeout(()=>{if(!connected)notice(t('连接尚未完成。请确认 VoxStudio 正在运行，然后重新打开此面板。','Still connecting. Check that VoxStudio is running, then reopen this panel.'),true)},12000);
 void (async()=>{try{await app.connect();connected=true;clearTimeout(timeout);host(app.getHostContext()??{});$('connection').innerHTML=`<i></i>${t('已连接','Connected')}`;$('connection').classList.add('online');if(initial)deliver(initial);else {const fallback=setTimeout(()=>{if(!initial&&!disposed){const args=fallbackArgs(input??{});if(args)void call(fallbackTool,args).then(deliver).catch(e=>notice(String(e),true));}},350);onDispose(()=>clearTimeout(fallback));}}catch(e){clearTimeout(timeout);$('connection').textContent=t('连接失败','Disconnected');notice(String(e),true)}})();
}
type MountedPlayer={media:HTMLMediaElement,start:number,end:number,dispose:()=>void,container:HTMLElement};
let mountedPlayer:MountedPlayer|undefined;
export function clearPlayer(container?:HTMLElement) {
 if(mountedPlayer&&(!container||mountedPlayer.container===container)){mountedPlayer.dispose();mountedPlayer=undefined}
 if(container){container.replaceChildren();container.hidden=true}
}
onDispose(()=>clearPlayer());
function playbackError(media:HTMLMediaElement) {
 const detail=media.error?.code===4?'This media format is not supported by the browser.':media.error?.code===3?'The browser could not decode this clip.':'The preview could not be loaded.';
 return new Error(`${detail} Open the result in VoxStudio.`);
}
function waitForMetadata(media:HTMLMediaElement) {
 return new Promise<void>((resolve,reject)=>{
  const finish=(error?:Error)=>{clearTimeout(timer);media.removeEventListener('loadedmetadata',ready);media.removeEventListener('error',failed);error?reject(error):resolve()};
  const ready=()=>finish(),failed=()=>finish(playbackError(media));
  const timer=setTimeout(()=>finish(new Error('Preview loading timed out. Try again or open it in VoxStudio.')),10000);
  media.addEventListener('loadedmetadata',ready,{once:true});media.addEventListener('error',failed,{once:true});media.load();
 });
}
export async function mountPlayer(container:HTMLElement,preview:Obj,onTime?:(time:number)=>void,isCurrent=()=>true) {
 const start=Number(preview.start??0),end=Number(preview.end??start+15);
 if(typeof preview.preview_resource_uri!=='string'||!Number.isFinite(start)||start<0||!Number.isFinite(end)||end<=start)throw new Error('Preview information is incomplete. Try loading it again.');
 const resource=await app.readServerResource({uri:preview.preview_resource_uri});
 if(isDisposed()||!container.isConnected||!isCurrent())return;
 const content=resource.contents.find(c=>c.uri===preview.preview_resource_uri&&'blob'in c);
 if(!content||!('blob'in content)||!content.blob)throw new Error('The preview resource contains no media. Try again or open it in VoxStudio.');
 const mime=content.mimeType||preview.mime_type||'audio/mp4';
 if(!['audio/mp4','audio/mpeg','audio/wav','video/mp4'].includes(mime))throw new Error('This preview format is not supported. Open the result in VoxStudio.');
 const media=document.createElement(mime.startsWith('video/')?'video':'audio');media.controls=true;media.preload='metadata';media.setAttribute('aria-label',mime.startsWith('video/')?'Session video preview':'Session audio preview');
 if(media instanceof HTMLVideoElement)media.playsInline=true;
 // Keep the MCP-delivered bytes local. Blob URLs support normal media loading
 // in sandboxed host webviews without navigating to a base64 data URL.
 const binary=atob(content.blob),bytes=new Uint8Array(binary.length);
 for(let i=0;i<binary.length;i++)bytes[i]=binary.charCodeAt(i);
 const source=URL.createObjectURL(new Blob([bytes],{type:mime}));
 const dispose=()=>{media.onerror=null;media.ontimeupdate=null;media.onplay=null;media.onpause=null;media.onended=null;media.pause();media.removeAttribute('src');media.load();URL.revokeObjectURL(source)};
 media.src=source;
 try{await waitForMetadata(media)}catch(error){dispose();if(isCurrent()&&!isDisposed())throw error;return;}
 if(isDisposed()||!container.isConnected||!isCurrent()){dispose();return;}
 clearPlayer();
 const cues:Obj[]=preview.captions_ready===true&&Array.isArray(preview.cues)?preview.cues:[];
 const caption=cues.length?document.createElement('p'):undefined;
 if(caption){caption.className='player-caption';caption.setAttribute('aria-live','off')}
 const heading=document.createElement('div');heading.className='player-heading';
 const label=document.createElement('p');label.className='eyebrow';label.textContent=`PREVIEW · ${time(start)}–${time(end)}`;
 const play=document.createElement('button');play.className='button small';play.type='button';
 const reflectPlayback=()=>{play.textContent=media.paused?'Play preview':'Pause preview';play.setAttribute('aria-pressed',String(!media.paused))};
 play.onclick=async()=>{try{if(media.paused){if(media.ended)media.currentTime=0;await media.play()}else media.pause()}catch(error){notice(error instanceof Error?error.message:'Playback failed. Open the result in VoxStudio.',true)}};
 heading.append(label,play);reflectPlayback();
 const updateTime=()=>{const at=start+media.currentTime;if(caption){caption.textContent=cues.find(c=>c.start<=at&&c.end>at)?.text??'';caption.hidden=!caption.textContent}onTime?.(at)};
 media.ontimeupdate=updateTime;media.onplay=reflectPlayback;media.onpause=reflectPlayback;media.onended=reflectPlayback;
 media.onerror=()=>notice(playbackError(media).message,true);
 container.replaceChildren(heading,media,...(caption?[caption]:[]));container.hidden=false;updateTime();
 mountedPlayer={media,start,end,dispose,container};
 return mountedPlayer;
}
