import {$,t,esc,icon,action,value,badge,time,date,empty,languageLabel,type Obj} from './ui';
export function sessionListMarkup(title='Sessions') {return `<div class="section-heading"><h2>${esc(title)}<span id="count" class="count"></span></h2><button id="refresh" class="icon-button" aria-label="${t('刷新会话','Refresh sessions')}">${icon('refresh')}</button></div><div class="library-controls"><div class="segmented" role="group" aria-label="${t('会话类型','Session type')}"><button data-filter="all" aria-pressed="true">${t('全部','All')}</button><button data-filter="transcription" aria-pressed="false">${t('转录','Transcripts')}</button><button data-filter="dubbing" aria-pressed="false">${t('配音','Voiceovers')}</button></div><label class="search-box">${icon('search')}<input id="search" type="search" placeholder="${t('搜索会话…','Search sessions…')}" aria-label="${t('搜索会话','Search sessions')}"></label></div><div id="sessions" class="session-list"><div class="loading-card"><div class="skeleton"></div><div class="skeleton wide"></div></div></div><button id="sessions-more" class="button small" hidden>Load more</button>`;}
export function createSessionList(options:{open:(session:Obj)=>Promise<unknown>;refresh:()=>Promise<unknown>;more?:()=>Promise<unknown>}) {
let sessions:Obj[]=[],filter='all',loading=false;
function render(){
 const query=value('search').trim().toLocaleLowerCase();
 if(loading){$('count').textContent='';$('sessions').innerHTML='<div class="loading-card"><div class="skeleton"></div><div class="skeleton wide"></div></div>';return;}
 const rows=sessions.filter(s=>(filter==='all'||s.kind===filter)&&String(s.title).toLocaleLowerCase().includes(query));
 $('count').textContent=String(rows.length);
 $('sessions').innerHTML=rows.length?rows.map(s=>`<button class="session-row" data-session="${esc(s.session_id)}"><span class="session-icon ${s.kind==='dubbing'?'voice':''}">${icon(s.kind==='dubbing'?'mic':'text')}</span><span><span class="session-name">${esc(s.title||t('未命名会话','Untitled session'))}</span><span class="session-meta"><span>${t(s.kind==='dubbing'?'配音':'转录',s.kind==='dubbing'?'Voiceover':'Transcript')}</span>${s.duration?`<span>${time(s.duration)}</span>`:''}${s.language?`<span>${esc(languageLabel(s.language))}</span>`:''}${s.updated_at?`<span>${date(s.updated_at)}</span>`:''}</span></span>${s.status?badge(s.status):''}${icon('arrow')}</button>`).join(''):empty(t('没有匹配的会话','No matching sessions'),query?'Try another name or clear the search.':'No sessions to show.');
 $('sessions').querySelectorAll<HTMLButtonElement>('[data-session]').forEach((button,i)=>{button.id=`session-${i}`;action(button.id,()=>options.open(sessions.find(s=>s.session_id===button.dataset.session)!))});
}

action('refresh',options.refresh);action('sessions-more',async()=>options.more?.());
$('search').oninput=render;
for(const b of document.querySelectorAll<HTMLButtonElement>('[data-filter]'))b.onclick=()=>{filter=b.dataset.filter!;document.querySelectorAll('[data-filter]').forEach(el=>el.setAttribute('aria-pressed',String(el===b)));render()};
return {setRows(rows:Obj[],hasMore=false,isLoading=false){sessions=rows;loading=isLoading;$('sessions-more').hidden=loading||!hasMore;render();}};
}
