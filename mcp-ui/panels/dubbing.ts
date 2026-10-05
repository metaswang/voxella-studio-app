import { $, t, esc, shell, icon, action, call, start, value, field, backButton, openPanel, notice, poll, progress, mountPlayer, languageLabel, time, resolveJob, clearPlayer, context, isDisposed, type Obj } from '../shared/ui';
let voices:Obj[]=[],sessionID:string|undefined,stopJob:(()=>void)|undefined,attached=false,submitting=false;
const edited=new Set<string>();
let selectedVoice:string|undefined;
shell(t('配音','Voiceover'),`<div class="back-row">${backButton()}</div><div class="heading"><p class="eyebrow">VOICEOVER</p><h1 id="voiceover-heading">${t('让文字，有声有色。','Words with a voice.')}</h1><p id="voiceover-intro" class="muted">${t('写下文稿，选择你的声音，生成自然流畅的配音。','Write your script, choose a voice, and bring it to life.')}</p></div><section id="job" hidden class="job-card" aria-live="polite"></section><div id="player" hidden class="player-box"></div><form id="dub-form"><div class="split-layout"><div><section class="card"><div class="card-header"><span class="step-number">01</span><h2>${t('你的文稿','Your script')}</h2></div>${field(`<label for="title">${t('作品名称','Title')} <span class="muted">${t('（选填）','(optional)')}</span></label>`,`<input id="title" maxlength="200" placeholder="${t('例如：新产品介绍','e.g. Introducing our next chapter')}">`)}<label class="eyebrow" for="script">${t('配音文稿','SCRIPT')}</label><textarea id="script" class="script-input" required maxlength="12000" placeholder="${t('在这里写下你希望说的话……','What would you like to say?')}"></textarea><p id="voiceover-settings" class="field-hint" hidden></p><p id="script-source" class="field-hint" hidden>Script from your request.</p><p id="character-count" class="character-count">0 / 12,000</p></section><section id="voice-settings" class="card"><div class="card-header"><span class="step-number">02</span><h2>${t('选择声音','Choose a voice')}</h2><button type="button" id="refresh-voices" class="icon-button right" aria-label="${t('刷新声音','Refresh voices')}">${icon('refresh')}</button></div><div id="voices" class="voice-list"><div class="skeleton wide"></div></div><div class="field" style="margin-top:18px"><label for="language">${t('文稿语言','Script language')}</label><select id="language"><option value="">${t('跟随所选声音','Use the voice’s language')}</option><option value="zh">${t('中文','Chinese')}</option><option value="en">${t('英语','English')}</option><option value="ja">${t('日语','Japanese')}</option><option value="ko">${t('韩语','Korean')}</option><option value="fr">${t('法语','French')}</option><option value="de">${t('德语','German')}</option><option value="es">${t('西班牙语','Spanish')}</option></select></div><div class="form-footer"><p>${t('使用本地声音库与已配置的语音模型。','Uses your voice library and configured speech model.')}</p><button type="submit" id="generate" class="button primary" disabled>${icon('mic')}${t('生成配音','Generate voiceover')}</button></div></section></div><aside id="voiceover-tips" class="aside-card">${icon('mic')}<h3>${t('好的配音，从好文稿开始。','Make every sentence count.')}</h3><p>${t('用短句和自然的标点控制节奏。选用声音库里的参考声音，让你的内容保持熟悉的声音风格。','Use short sentences and natural punctuation to shape the rhythm. Your saved reference voices keep the sound familiar.')}</p><ul class="aside-list"><li>${icon('check')}${t('使用已有参考声音','Use your saved voices')}</li><li>${icon('check')}${t('生成后试听与下载','Preview and save the audio')}</li><li>${icon('check')}${t('每次生成保留独立会话','Every creation gets its own session')}</li></ul></aside></div></form>`);
function updateButton(){
 $<HTMLButtonElement>('generate').disabled=attached||submitting||!value('script').trim()||!document.querySelector('input[name=voice]:checked');
 $('generate').hidden=attached;
 $('voice-settings').hidden=attached;$('voiceover-tips').hidden=attached;
 $('dub-form').querySelector<HTMLElement>('.split-layout')!.style.gridTemplateColumns=attached?'1fr':'';
 const voice=voices.find(v=>v.voice_id===selectedVoice);
 $('voiceover-settings').hidden=!attached;
 $('voiceover-settings').textContent=[voice?.name,languageLabel(value('language')||voice?.language)].filter(Boolean).join(' · ');
 $('character-count').textContent=`${value('script').length.toLocaleString()} / 12,000`;
 for(const id of ['script','title'])$<HTMLInputElement|HTMLTextAreaElement>(id).readOnly=attached;
 $<HTMLSelectElement>('language').disabled=attached;
 document.querySelectorAll<HTMLInputElement>('input[name=voice]').forEach(input=>input.disabled=attached);
}
function renderVoices(){
 const selected=selectedVoice??document.querySelector<HTMLInputElement>('input[name=voice]:checked')?.value;
 $('voices').innerHTML=voices.length?voices.map((v,i)=>`<label class="voice-option"><input type="radio" name="voice" value="${esc(v.voice_id)}" ${selected===v.voice_id||!selected&&i===0?'checked':''}><span class="voice-avatar">${esc(v.name?.slice(0,1)||'V')}</span><span><strong>${esc(v.name)}</strong><small>${esc(languageLabel(v.language))} · ${time(v.duration)}</small></span></label>`).join(''):`<div class="empty-state"><span class="empty-icon">${icon('mic')}</span><h3>${t('先添加一个声音','Add your first voice')}</h3><p>${t('在 VoxStudio 的声音库添加 3–30 秒参考音频及准确文稿，然后点击刷新。','In VoxStudio’s Voice Library, add a 3–30 second reference recording and its exact script, then refresh here.')}</p></div>`;
 $('voices').onchange=()=>{edited.add('voice_id');selectedVoice=document.querySelector<HTMLInputElement>('input[name=voice]:checked')?.value;updateButton()};updateButton();
}
function showJob(job:Obj){
 const id=job.session_id;sessionID=id;attached=true;stopJob?.();$('job').hidden=false;updateButton();
 const render=(v:Obj)=>{
  if(isDisposed())return;
  const done=v.status==='completed',ended=['completed','failed','cancelled'].includes(v.status);
  $('voiceover-heading').textContent=done?'Your voiceover is ready.':ended?'Your voiceover': 'Creating your voiceover…';
  $('voiceover-intro').textContent=done?'Your script and generated audio are saved in VoxStudio.':ended?'Your script is retained below.':'Your script is retained below. Follow the progress here.';
  $('job').innerHTML=`<h3>${esc(v.title||value('title')||'Your voiceover')}</h3>${progress(v)}<div class="actions">${done?`<button type="button" id="listen" class="button primary">${icon('play')}Load preview</button><button type="button" id="download" class="button">${icon('download')}Save audio</button>`:''}${id?'<button type="button" id="open-result" class="text-button">View session'+icon('arrow')+'</button>':''}${ended?'<button type="button" id="edit-draft" class="text-button">Edit and generate again</button>':''}</div>`;
  if(id)action('open-result',()=>openPanel('app_session',{session_id:id}));
  if(done&&id){action('listen',async()=>mountPlayer($('player'),await call('media.preview',{session_id:id})));action('download',async()=>{const receipt=await call('media.save_result',{session_id:id});if(receipt.outcome==='saved')notice('Audio saved')})}
  if(ended)action('edit-draft',async()=>{stopJob?.();attached=false;sessionID=undefined;$('job').hidden=true;clearPlayer($('player'));$('voiceover-heading').textContent='Words with a voice.';$('voiceover-intro').textContent='Edit your script, choose a voice, and generate a new voiceover.';updateButton();$('script').focus()});
  void context({type:'voxstudio_voiceover',session_id:id,job_id:job.job_id,status:v.status,title:v.title});
 };
 render(job);if(id&&!['completed','failed','cancelled'].includes(job.status))stopJob=poll(()=>call('media.status',{session_id:id}),render);
}
action('back',()=>openPanel('app_workbench'));action('refresh-voices',async()=>{voices=(await call('voice.list')).voices??[];renderVoices()});
for(const id of ['script','title','language'])$(id).oninput=()=>{edited.add(id==='script'?'text':id);updateButton()};
$('dub-form').onsubmit=async e=>{
 e.preventDefault();const b=$<HTMLButtonElement>('generate');if(b.disabled||submitting||attached)return;submitting=true;updateButton();b.setAttribute('aria-busy','true');
 try{const voice=document.querySelector<HTMLInputElement>('input[name=voice]:checked')?.value;if(!voice)throw new Error('Choose a voice');const language=value('language');const result=await call('dubbing.create',{text:value('script').trim(),voice_id:voice,...(language?{language}:{}),...(value('title').trim()?{title:value('title').trim()}:{})});if(!result.session_id)throw new Error(result.error||result.message||'No session returned');showJob(result);notice('Voiceover started. Your script is retained.')}
 catch(e){if(!isDisposed())notice(e instanceof Error?e.message:String(e),true)}finally{submitting=false;b.removeAttribute('aria-busy');updateButton()}
};
function applyOptions(options:Obj,submitted=false){
 for(const [key,id]of [['text','script'],['title','title'],['language','language']]){
  if(typeof options[key]==='string'&&(!edited.has(key)||submitted)){
   const field=$<HTMLInputElement|HTMLTextAreaElement|HTMLSelectElement>(id);
   if(field instanceof HTMLSelectElement&&options[key]&&!Array.from(field.options).some(option=>option.value===options[key]))field.add(new Option(options[key],options[key]));
   field.value=options[key];
  }
 }
 if(options.voice_id&&(!edited.has('voice_id')||submitted))selectedVoice=options.voice_id;
 if(typeof options.text==='string')$('script-source').hidden=false;
 updateButton();
}
start('app_dubbing',async data=>{
 applyOptions(data.options??{},Boolean(data.session_id||data.job_id));
 if(Array.isArray(data.voices))voices=data.voices;
 renderVoices();
 if(data.job_id||data.session_id){
  showJob(data);
  if(!data.session_id)try{const result=await resolveJob(data);if(result.session_id)showJob(result);else throw new Error(result.error||result.message||'Could not create a voiceover job')}
  catch(error){if(!isDisposed()){showJob({...data,status:'failed',error:error instanceof Error?error.message:String(error)});throw error}}
 }
 // Never replay a start request if the host delays the original result.
},args=>args.start===true?undefined:args,args=>applyOptions(args));
