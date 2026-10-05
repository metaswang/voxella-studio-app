import { parseSummaryMarkdown } from './summary-markdown';
import DOMPurify from 'dompurify';
import {highlightedParts} from './workspace-model';
import { $, t, esc, icon, action, call, value, openNativeSession, notice, poll, progress, mountPlayer, clearPlayer, languageLabel, time, languages, context, type Obj } from './ui';
type Cue = { id:number; start_ms:number; end_ms:number; text:string; display_text?:string; speaker?:string; cue_ids?:number[]; character_start?:number; character_end?:number };
const textTabs = ['transcript','subtitles','summary'] as const;
type TextTab = typeof textTabs[number];
export function createSessionView(options: {readOnly?:boolean; onChange?:(view:Obj)=>Promise<unknown>;onBrowse?:()=>Promise<unknown>} = {}) {
let reading:Obj={},trackCursor:string|undefined,disposed=false;
let scrollTimer:ReturnType<typeof setTimeout>|undefined,suppressScrollUntil=0;
let session:Obj|undefined, track:Obj|undefined, editing=false, dirty=false, stopJob:(()=>void)|undefined;
let activeTab:TextTab='transcript', trackGeneration=0;
let player:Awaited<ReturnType<typeof mountPlayer>>|undefined;
let previewGeneration=0, summaryGeneration=0, summaryMarkdown='', summaryCursor:number|string|undefined;
function resetPreview() { previewGeneration++; player=undefined; const container=$('player'); if(container)clearPlayer(container); }
function args() {
 const selected=value('track')||'source';
 return { session_id:session!.session_id, scope:selected==='source'?(activeTab==='transcript'?'transcript':'source'):'translation', ...(selected==='source'?{}:{language:selected}) };
}
function operations() {
 const out:Obj[]=[];
 for(const row of $('cues').querySelectorAll<HTMLElement>('[data-cue]')) {
  const cue=(track?.cues as Cue[]).find(c=>String(c.id)===row.dataset.cue)!;
  const text=row.querySelector<HTMLTextAreaElement>('textarea')?.value;
  if(text!==undefined&&text!==cue.text)out.push({type:'text',cue_id:cue.id,text});
  const start=row.querySelector<HTMLInputElement>('[data-start]'),end=row.querySelector<HTMLInputElement>('[data-end]');
  if(start&&end) {
   const a=Math.round(Number(start.value)*1000),b=Math.round(Number(end.value)*1000);
   if(!Number.isFinite(a)||!Number.isFinite(b)||a<0||b<=a)throw new Error('End time must be after start time.');
   if(a!==cue.start_ms||b!==cue.end_ms)out.push({type:'timing',cue_id:cue.id,start_ms:a,end_ms:b});
  }
 }
 return out;
}
function cueText(cue:Cue) {
 if(!options.readOnly)return esc(cue.text);
 const text=activeTab==='subtitles'?(cue.display_text??cue.text):cue.text;
 const [before,match,after]=highlightedParts(text,cue.character_start??0,reading.character_start,reading.character_end);
 return esc(before)+(match?'<mark>'+esc(match)+'</mark>':'')+esc(after);
}
function cueMetadata(cue:Cue) {
 const range=activeTab==='subtitles'&&Number.isFinite(cue.start_ms)&&Number.isFinite(cue.end_ms)
  ? `${(cue.start_ms/1000).toFixed(1)}s – ${(cue.end_ms/1000).toFixed(1)}s` : '';
 return range||cue.speaker?`<p class="speaker">${esc([range,cue.speaker].filter(Boolean).join(' · '))}</p>`:'';
}
function renderCues() {
 suppressScrollUntil=Date.now()+500;
 const cues:Cue[]=track?.cues??[];
 const grouped=activeTab==='transcript'&&!editing;
 const rows:Cue[]=grouped?(track?.paragraphs??cues):cues;
 $('cue-count').textContent=`${rows.length} ${grouped?'paragraphs':'segments'}`;
 $('cues').innerHTML=rows.length?rows.map(c=>`<div class="cue-row" ${grouped?'data-paragraph':'data-cue'}="${c.id}" data-range="${c.character_start??0}"><button class="cue-time" data-seek="${c.start_ms/1000}" ${Number.isFinite(c.start_ms)?'':'disabled'} aria-label="${Number.isFinite(c.start_ms)?'Seek to '+time(c.start_ms/1000):'Text without timecode'}">${Number.isFinite(c.start_ms)?time(c.start_ms/1000):'Text'}</button><div>${cueMetadata(c)}${editing?`<textarea aria-label="Text ${c.id}">${esc(c.text)}</textarea><div class="cue-timing"><label>Start (s) <input type="number" data-start min="0" step="0.001" value="${c.start_ms/1000}"></label><span>→</span><label>End (s) <input type="number" data-end min="0" step="0.001" value="${c.end_ms/1000}"></label></div>`:`<p class="cue-copy">${cueText(c)}</p>`}</div></div>`).join(''):`<div class="empty-state"><h3>${activeTab==='subtitles'?'No subtitles generated':'No transcript available'}</h3><p>${activeTab==='subtitles'?'Subtitle segmentation is optional. You can read the original text in Transcript.':'This session has no readable transcript yet.'}</p></div>`;
 $('cues').querySelectorAll<HTMLButtonElement>('[data-seek]').forEach((b,i)=>{
  b.id=`seek-${i}`;
  action(b.id,async()=>{await preview(Number(b.dataset.seek)); const row=rows[i]; if(options.readOnly)await options.onChange?.({anchor:row.character_start??0});else await context({...args(),start_ms:row.start_ms,end_ms:row.end_ms,text:row.text.slice(0,2500)});});
 });
 const edit=$<HTMLButtonElement>('edit');
 if(edit){edit.disabled=track?.editable===false||!cues.length; edit.innerHTML=icon('edit')+(editing?'Done editing':'Edit text');}
 const saveBar=$('save-bar'); if(saveBar)saveBar.hidden=!editing;
 const more=$('text-more');if(more)more.hidden=!trackCursor;
 const material=$('material-note');if(material){material.hidden=!options.readOnly||track?.provenance!=='subtitle_fallback';material.textContent='Transcript unavailable · showing subtitles';}
 $('cues').oninput=editing?()=>{dirty=true; $('save-note').textContent='You have unsaved changes'; $<HTMLButtonElement>('save').disabled=false;}:null;
}
async function loadTrack(append=false) {
 const generation=++trackGeneration, request=args();
 const previous=append?track:undefined;const pageCursor=append?trackCursor:undefined;if(!append){track=undefined;trackCursor=undefined;} $('cues').innerHTML='<div class="skeleton wide"></div>'; $('cue-count').textContent='';
 const edit=$<HTMLButtonElement>('edit'); if(edit)edit.disabled=true;
 try {
  const selected=value('track')||'source';
  const material=selected==='source'?(activeTab==='subtitles'?'subtitles':'canonical'):'translation';
  const next=options.readOnly?await call('fetch',{source_id:session!.session_id,material,...(activeTab==='subtitles'?{view:'cues'}:{}),...(selected==='source'?{}:{language:selected}),limit:64,...(pageCursor?{cursor:pageCursor}:{})}):await call('session.editor.read',request);
  if(generation!==trackGeneration||disposed)return;
  if(options.readOnly){
   const cues=(next.segments??[]).map((row:Obj,index:number)=>({id:row.cue_id??row.character_start??index,text:row.text??'',display_text:row.display_text,speaker:Array.isArray(row.speaker)?row.speaker.join(', '):row.speaker,start_ms:Number.isFinite(row.start)?row.start*1000:NaN,end_ms:Number.isFinite(row.end)?row.end*1000:NaN,character_start:row.character_start,character_end:row.character_end}));
   track={...next,cues:[...(previous?.cues??[]),...cues],editable:false};trackCursor=next.next_cursor||undefined;
  }else track=next;
  renderCues();
  if(options.readOnly){
   if(!append&&Number.isInteger(reading.anchor)&&reading.anchor>0)$('cues').querySelector<HTMLElement>(`[data-range="${(track!.cues as Cue[]).find(c=>c.character_start!<=reading.anchor&&c.character_end!>reading.anchor)?.character_start??reading.anchor}"]`)?.scrollIntoView({block:'nearest'});
   return;
  }
  const text=(track.cues as Cue[]??[]).map(c=>c.text).join(' ');
  await context({...request,title:session?.title,text:text.slice(0,16000),text_complete:text.length<=16000});
 } catch(error) {
  if(generation!==trackGeneration||disposed)return;
  $('cues').innerHTML=`<div class="empty-state"><h3>Text is unavailable</h3><p>${esc(error instanceof Error?error.message:String(error))}</p></div>`;
 }
}
async function preview(at=0) {
 if(player&&at>=player.start&&at<player.end){player.media.currentTime=at-player.start; return;}
 const generation=++previewGeneration, button=$<HTMLButtonElement>('preview');
 button.innerHTML=icon('clock')+'Preparing preview…';
 try {
  const dub=session?.kind==='dubbing';
  const result=await call(dub?'media.preview':'media.session_preview',{session_id:session?.session_id,start:at,duration:15,...(!dub?{language:value('track')||'source'}:{})});
  if(generation!==previewGeneration||disposed)return;
  const next=await mountPlayer($('player'),result,seconds=>{
   const rows:Cue[]=activeTab==='transcript'&&!editing?(track?.paragraphs??track?.cues??[]):track?.cues??[];
   document.querySelectorAll<HTMLElement>('[data-cue], [data-paragraph]').forEach(row=>{
    const cue=rows.find(c=>String(c.id)===(row.dataset.cue??row.dataset.paragraph));
    row.classList.toggle('active',!!cue&&cue.start_ms/1000<=seconds&&cue.end_ms/1000>seconds);
   });
  },()=>generation===previewGeneration&&!disposed);
  if(generation===previewGeneration)player=next;
 } finally {if(generation===previewGeneration&&button.isConnected)button.innerHTML=icon('play')+'Load preview';}
}
function renderSummary() {
 const content=$('summary-body');
 content.innerHTML=DOMPurify.sanitize(parseSummaryMarkdown(summaryMarkdown),{
  ALLOWED_TAGS:['h1','h2','h3','h4','h5','h6','p','br','hr','ul','ol','li','strong','em','del','blockquote','pre','code','table','thead','tbody','tr','th','td'],
  ALLOWED_ATTR:[]
 });
 $('summary-more').hidden=summaryCursor===undefined;
}
async function loadSummary(append=false) {
 const generation=++summaryGeneration, id=session!.session_id;
 const cursor=append?summaryCursor:undefined;
 if(append&&cursor===undefined)return;
 if(!append){summaryMarkdown='';summaryCursor=undefined;$('summary-body').innerHTML='<div class="skeleton wide"></div>';$('summary-more').hidden=true;}
 $<HTMLButtonElement>('summary-refresh').disabled=true;
 $<HTMLButtonElement>('summary-more').disabled=true;
 try {
  const result=options.readOnly?await call('fetch',{source_id:id,view:'summary',...(cursor===undefined?{}:{cursor})}):await call('session.get_summary',{session_id:id,...(cursor===undefined?{}:{cursor})});
  if(disposed||generation!==summaryGeneration||activeTab!=='summary'||session?.session_id!==id)return;
  const markdown=typeof result.summary_markdown==='string'?result.summary_markdown:'';
  if(!markdown.trim()&&!append){
   $('summary-body').innerHTML='<div class="empty-state"><h3>No summary generated</h3><p>Generate a summary in VoxStudio, then refresh to read it here.</p></div>';
   if(!options.readOnly)await context({session_id:id,title:session?.title,view:'summary',summary_available:false});
   return;
  }
  summaryMarkdown+=markdown;
  summaryCursor=options.readOnly?(result.next_cursor||undefined):result.complete===false&&Number.isInteger(result.next_cursor)&&result.next_cursor>Number(cursor??0)?result.next_cursor:undefined;
  renderSummary();
  if(!options.readOnly)await context({session_id:id,title:session?.title,view:'summary',summary_markdown:summaryMarkdown.slice(0,16000),text_complete:summaryCursor===undefined&&summaryMarkdown.length<=16000});
 } catch(error) {
  if(generation!==summaryGeneration||disposed)return;
  if(append){notice(error instanceof Error?error.message:String(error),true);}
  else $('summary-body').innerHTML=`<div class="empty-state"><h3>Summary is unavailable</h3><p>${esc(error instanceof Error?error.message:String(error))}</p></div>`;
 } finally {
  if(generation===summaryGeneration&&!disposed){$<HTMLButtonElement>('summary-refresh').disabled=false;$<HTMLButtonElement>('summary-more').disabled=false;}
 }
}
function updateTabs() {
 for(const tab of textTabs) {
  const button=$(`tab-${tab}`);
  button.setAttribute('aria-selected',String(activeTab===tab));
  button.setAttribute('tabindex',activeTab===tab?'0':'-1');
 }
 const summary=activeTab==='summary';
 $('text-content').hidden=summary;
 $('summary-content').hidden=!summary;
 $('track-actions')?.setAttribute('hidden','');
 if(!summary)$('track-actions')?.removeAttribute('hidden');
 $('text-content').setAttribute('aria-labelledby',`tab-${summary?'transcript':activeTab}`);
 $('track').setAttribute('aria-label',activeTab==='transcript'?'Transcript language':'Subtitle language');
}
async function switchTab(tab:TextTab) {
 if(activeTab===tab)return;
 if(dirty)throw new Error('Save or discard your edits before switching tabs.');
 trackGeneration++; summaryGeneration++;
 if(options.readOnly){reading={...reading,character_start:undefined,character_end:undefined,anchor:0};}
 activeTab=tab; editing=false; updateTabs(); resetPreview(); $('save-bar')?.setAttribute('hidden','');
 if(options.readOnly)await options.onChange?.({reading_view:tab==='summary'?'summary':'body',material:tab==='subtitles'?'subtitles':'canonical',language:value('track')||'source',anchor:0});
 if(tab==='summary')await loadSummary();else await loadTrack();
}
async function showResult() {
 if(!session)return;
 const dub=session.kind==='dubbing'; if(!options.readOnly)activeTab='transcript'; editing=false; dirty=false;
 $('result').innerHTML=`<div class="actions" style="margin-bottom:18px"><button id="preview" class="button primary">${icon('play')}Load preview</button>${dub&&!options.readOnly?`<button id="save-audio" class="button">${icon('download')}Save audio</button>`:''}<button id="native-open" class="text-button">Open in VoxStudio${icon('external')}</button></div><div id="player" class="player-box" hidden></div><section class="card" style="margin-top:22px"><div class="session-text-tabs segmented" role="tablist" aria-label="Session text"><button id="tab-transcript" role="tab" aria-controls="text-content" aria-selected="true">Transcript</button><button id="tab-subtitles" role="tab" aria-controls="text-content" aria-selected="false" tabindex="-1">Subtitles</button><button id="tab-summary" role="tab" aria-controls="summary-content" aria-selected="false" tabindex="-1">Summary</button></div><div id="text-content" role="tabpanel" aria-labelledby="tab-transcript"><div class="toolbar"><div class="actions"><select id="track" aria-label="Transcript language"><option value="source">Original</option>${(session.translation_languages??[]).map((l:string)=>`<option value="${esc(l)}">${esc(languageLabel(l))}</option>`).join('')}</select><span id="cue-count" class="muted"></span></div>${dub||options.readOnly?'':'<button id="edit" class="button small" disabled>'+icon('edit')+'Edit text</button>'}</div><p id="material-note" class="field-hint"></p><div id="cues"><div class="skeleton wide"></div></div><button id="text-more" class="button small" hidden>Load more</button>${dub||options.readOnly?'':`<div id="save-bar" class="save-bar" hidden><span id="save-note">Edit wording and timing</span><div class="actions"><button id="discard" class="button small">Discard</button><button id="save" class="button primary small" disabled>Save changes</button></div></div>`}</div><div id="summary-content" role="tabpanel" aria-labelledby="tab-summary" hidden><div class="toolbar"><span class="muted">Saved in VoxStudio</span><button id="summary-refresh" class="button small">${icon('refresh')}Refresh summary</button></div><div id="summary-body" class="summary-markdown"></div><button id="summary-more" class="button small" style="margin-top:18px" hidden>Load more</button></div></section>${dub||options.readOnly?'':`<details id="track-actions"><summary>Translate & export</summary><div class="field-grid"><div><label for="translate-language" class="eyebrow">ADD TRANSLATION</label><div class="export-row"><select id="translate-language">${languages()}</select><button id="translate" class="button">Translate</button></div></div><div><label for="format" class="eyebrow">EXPORT THIS TRACK</label><div class="export-row"><select id="format"><option value="srt">SRT</option><option value="vtt">VTT</option><option value="txt">TXT</option></select><button id="export" class="button">${icon('download')}Export</button></div></div></div><p class="field-hint">Captions stay in VoxStudio. Choose a destination when exporting.</p></details>`}`;
 action('preview',()=>preview()); action('native-open',()=>openNativeSession(session!.session_id));
 for(const tab of textTabs) {
  action(`tab-${tab}`,()=>switchTab(tab));
  $(`tab-${tab}`).onkeydown=event=>{
   if(!['ArrowLeft','ArrowRight','Home','End'].includes(event.key))return;
   event.preventDefault();
   const index=textTabs.indexOf(tab);
   const next=event.key==='Home'?textTabs[0]:event.key==='End'?textTabs[textTabs.length-1]:textTabs[(index+(event.key==='ArrowRight'?1:-1)+textTabs.length)%textTabs.length];
   void switchTab(next).then(()=>$(`tab-${next}`).focus()).catch(error=>notice(String(error),true));
  };
 }
 action('summary-refresh',()=>loadSummary()); action('summary-more',()=>loadSummary(true));
 const select=$<HTMLSelectElement>('track');select.value=reading.language||'source'; let previous=select.value||'source';
 action('text-more',()=>loadTrack(true));
 select.onchange=async()=>{
  if(dirty){select.value=previous; notice('Save or discard changes before switching languages.',true); return;}
  previous=select.value; editing=false; resetPreview(); if(options.readOnly){reading={...reading,character_start:undefined,character_end:undefined,anchor:0};await options.onChange?.({material:select.value==='source'?(activeTab==='subtitles'?'subtitles':'canonical'):'translation',language:select.value,reading_view:'body',anchor:0});}await loadTrack();
 };
 if(options.readOnly){}else if(dub)action('save-audio',async()=>{const result=await call('media.save_result',{session_id:session!.session_id}); if(result.outcome==='saved')notice('Audio saved');});
 else {
  action('edit',async()=>{if(dirty)throw new Error('Save or discard your changes first.'); editing=!editing; renderCues();});
  action('discard',async()=>{dirty=false; editing=false; renderCues();});
  action('save',async()=>{
   const ops=operations();
   if(ops.length){await call('session.editor.commit',{...args(),expected_revision:track!.revision,operations:ops,request_id:crypto.randomUUID()}); notice('Changes saved in VoxStudio');}
   dirty=false; editing=false; await loadTrack();
  });
  action('export',async()=>{if(dirty)throw new Error('Save your changes before exporting.'); const document=await call('documents.export',{...args(),format:value('format')}); const result=await call('documents.save_as',{document_id:document.document_id}); if(result.outcome==='saved')notice('File exported');});
  action('translate',async()=>{if(dirty)throw new Error('Save your changes before translating.'); await call('transcription.translate',{session_id:session!.session_id,target_languages:[value('translate-language')]}); notice('Translation added'); await loadSession(session!.session_id);});
 }
 updateTabs();if(activeTab==='summary')await loadSummary();else await loadTrack();
}
function renderHeading(){
 $('detail').innerHTML=`<div class="detail-heading"><p class="eyebrow">${session!.kind==='dubbing'?'VOICEOVER':'TRANSCRIPT'}</p><h1>${esc(session!.title||'Session details')}</h1><div class="detail-meta"><span>${session!.kind==='dubbing'?'Voiceover':'Audio & video transcript'}</span><span>Saved in VoxStudio</span></div></div><div id="job" class="job-card" hidden></div><div id="result"></div>`;
}
async function loadSession(id:string) {
 stopJob?.(); resetPreview(); trackGeneration++; summaryGeneration++;
 const generation=trackGeneration;
 if(options.readOnly){renderHeading();await showResult();return;}
 const snapshot=await call('media.status',{session_id:id});
 if(disposed||generation!==trackGeneration||session?.session_id!==id)return;
 session={...session,...snapshot,session_id:id};
 renderHeading();
 if(snapshot.status==='completed'){await showResult(); return;}
 $('job').hidden=false;
 const render=(state:Obj)=>{$('job').innerHTML=progress(state); if(state.status==='completed')void loadSession(id).catch(error=>notice(String(error),true));};
 render(snapshot); if(!['failed','cancelled','idle'].includes(snapshot.status))stopJob=poll(()=>call('media.status',{session_id:id}),render);
}
async function show(data:Obj,view:Obj={}){
 reading={...view,anchor:view.anchor??0};disposed=false;
 if(dirty)return;
 if(!data.session_id){$('detail').innerHTML=`<div class="empty-state"><span class="empty-icon">${icon('text')}</span><h3>Open a session</h3><p>Choose a transcript or voiceover from your sessions.</p><button id="choose-session" class="button primary" style="margin-top:20px">Browse sessions${icon('arrow')}</button></div>`;action('choose-session',async()=>options.onBrowse?.());return;}
 session=data; track=undefined; editing=false; dirty=false; activeTab=view.reading_view==='summary'?'summary':view.material==='subtitles'?'subtitles':'transcript'; trackGeneration++; summaryGeneration++;
 if(data.remote_only&&!options.readOnly){$('detail').innerHTML=`<div class="detail-heading"><p class="eyebrow">CLOUD SESSION</p><h1>${esc(data.title)}</h1></div><div class="card"><h3>Available in VoxStudio</h3><p class="muted" style="margin-top:10px">This session is stored in the cloud. Download it in VoxStudio to preview or edit it here.</p></div>`; return;}
 await loadSession(data.session_id);

}
const rememberScroll=()=>{
 if(!options.readOnly||disposed||Date.now()<suppressScrollUntil||!$('cues'))return;
 clearTimeout(scrollTimer);const generation=trackGeneration;
 scrollTimer=setTimeout(()=>{
  if(disposed||generation!==trackGeneration||activeTab==='summary')return;
  const row=Array.from($('cues').querySelectorAll<HTMLElement>('[data-range]')).find(row=>row.getBoundingClientRect().bottom>80);
  const anchor=row?Number(row.dataset.range):undefined;
  if(Number.isInteger(anchor)&&anchor!==reading.anchor){reading.anchor=anchor;void options.onChange?.({anchor}).catch(error=>notice(String(error),true));}
 },750);
};
if(options.readOnly)document.addEventListener('scroll',rememberScroll,true);
function dispose(){disposed=true;stopJob?.();trackGeneration++;summaryGeneration++;clearTimeout(scrollTimer);document.removeEventListener('scroll',rememberScroll,true);resetPreview();}
return {show,dispose,isDirty:()=>dirty};
}
