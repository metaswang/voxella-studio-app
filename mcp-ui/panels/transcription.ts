import { $, t, esc, shell, icon, action, call, start, value, languages, field, backButton, openPanel, waitInput, resolveJob, notice, poll, progress, context, type Obj } from '../shared/ui';
let asset:Obj|undefined, stopJob:(()=>void)|undefined, sessionID:string|undefined;
let submissionID:string|undefined, publishedIdentity='';
shell(t('转录','Transcribe'),`<div class="back-row">${backButton()}</div><div class="heading"><p class="eyebrow">TRANSCRIBE</p><h1>${t('听见每一句，留下每一字。','Every word, captured.')}</h1><p class="muted">${t('导入音频或视频，让 VoxStudio 为你整理文字和字幕。','Bring your audio or video. VoxStudio will take it from here.')}</p></div><div class="split-layout"><div><section class="card"><div class="card-header"><span class="step-number">01</span><h2>${t('选择媒体','Choose your media')}</h2></div><button id="choose" class="upload-zone">${icon('upload')}<strong>${t('选择音频或视频文件','Choose an audio or video file')}</strong><span>M4A · MP3 · WAV · MP4 · MOV</span></button><div id="selected" hidden class="selected-file"></div></section><section class="card"><div class="card-header"><span class="step-number">02</span><h2>${t('转录选项','Make it yours')}</h2><button hidden id="native-form" class="text-button right">${t('使用宿主表单','Use host form')}${icon('external')}</button></div><form id="transcription-form">${field(`<label for="title">${t('会话名称','Session name')} <span class="muted">${t('（选填）','(optional)')}</span></label>`,`<input id="title" maxlength="200" placeholder="${t('例如：产品访谈 · 第一期','e.g. Product interview · Episode 01')}">`)}<div class="field-grid">${field(`<label for="language">${t('源语言','Spoken language')}</label>`,`<select id="language">${languages(true)}</select>`)}${field(`<label for="speakers">${t('说话人','Speakers')}</label>`,`<select id="speakers"><option value="auto">${t('自动识别','Detect automatically')}</option><option value="one">${t('1 人','1 speaker')}</option><option value="two">${t('2 人','2 speakers')}</option><option value="three">${t('3 人','3 speakers')}</option><option value="off">${t('不区分','Do not identify')}</option></select>`)}</div><details><summary>${t('字幕与翻译','Captions & translation')}</summary><div><label class="checkbox-row"><input type="checkbox" id="segment"><span>${t('智能字幕分段','Smart caption segmentation')}<small>${t('使用 VoxStudio 中配置的字幕模型','Uses the caption model configured in VoxStudio')}</small></span></label><div class="field" style="margin-top:18px"><label for="target">${t('同时翻译为','Also translate into')}</label><select id="target"><option value="">${t('暂不翻译','No translation')}</option>${languages()}</select><p class="field-hint">${t('更多语言可在完成后添加。','You can add more languages after transcription.')}</p></div></div></details><div class="form-footer"><p>${t('选择文件不会自动创建任务。','Choosing a file does not start a job.')}</p><button type="submit" id="submit" class="button primary" disabled>${icon('wave')}${t('开始转录','Start transcription')}</button></div></form></section><div id="job" hidden class="job-card"></div></div><aside class="aside-card">${icon('text')}<h3>${t('专注内容，整理交给我们。','Stay with the conversation.')}</h3><p>${t('保留原始录音，用清晰的文字回顾内容。转录完成后，可逐句试听、修订并导出字幕。','Keep your original recording and revisit it as a clear transcript. Listen, refine the wording, and export captions when you’re ready.')}</p><ul class="aside-list"><li>${icon('check')}${t('自动识别语言与说话人','Language & speaker detection')}</li><li>${icon('check')}${t('文字与音频同步预览','Text with synchronized playback')}</li><li>${icon('check')}${t('导出 SRT、VTT 或文本','Export SRT, VTT, or text')}</li></ul></aside></div>`);
function updateAsset(){if(!asset)return;$('selected').hidden=false;$('selected').innerHTML=`${icon('video')}<div><strong>${esc(asset.name||t('已选择媒体','Selected media'))}</strong><p>${t('文件就绪，可以开始转录','Ready to transcribe')}</p></div>${icon('check')}`;$<HTMLButtonElement>('submit').disabled=false;$('submit').innerHTML=icon('wave')+t('开始转录','Start transcription');}
function showJob(result:Obj){
 sessionID=result.session_id;submissionID=result.job_id||submissionID;stopJob?.();$('job').hidden=false;
 const render=(state:Obj)=>{
  const identity={type:'voxstudio_transcription',job_id:submissionID,session_id:sessionID,status:state.status,title:state.title,...(sessionID?{result_call:{tool:'app_session',arguments:{session_id:sessionID}}}:{})};
  const signature=JSON.stringify(identity);
  if(signature!==publishedIdentity){publishedIdentity=signature;void context(identity)}
  $('job').innerHTML=`<h3>${esc(state.title||t('转录任务','Transcription'))}</h3>${progress(state)}${sessionID?`<div class="actions"><button id="result" class="button ${state.status==='completed'?'primary':'soft'}">${t(state.status==='completed'?'查看转录':'打开会话',state.status==='completed'?'View transcript':'Open session')}${icon('arrow')}</button></div>`:''}`;
  if(sessionID)action('result',()=>openPanel('app_session',{session_id:sessionID}));
 };
 render(result);if(sessionID)stopJob=poll(()=>call('media.status',{session_id:sessionID}),render);$('job').scrollIntoView({behavior:'smooth',block:'nearest'});
}
action('back',()=>openPanel('app_workbench'));
action('choose',async()=>{
 const button=$('choose'),original=button.innerHTML;
 try{
  button.innerHTML=`${icon('folder')}<strong>Opening file picker…</strong><span>Choose a file in VoxStudio on your Mac.</span>`;
  const next=await waitInput(await call('media.choose_local_file'),state=>{
   button.innerHTML=state.status==='importing'
    ? `${icon('upload')}<strong>Importing ${esc(state.name||'media')}…</strong><span>Your file is being prepared.</span>`
    : `${icon('folder')}<strong>Choose a file in VoxStudio</strong><span>The file picker is open on your Mac. Select a file or cancel to return.</span>`;
  });
  if(next){asset=next;updateAsset()}
 }finally{button.innerHTML=original}
});
action('native-form',async()=>{const job=await resolveJob(await call('transcription.start_form',asset?{asset_id:asset.asset_id}:{}));if(job.session_id)showJob(job);else notice(job.message||t('已取消，未创建任务','Cancelled. No job was created.'))});
$('transcription-form').onsubmit=async e=>{e.preventDefault();if(!asset)return;const submit=$<HTMLButtonElement>('submit');if(submit.disabled)return;submit.disabled=true;submit.setAttribute('aria-busy','true');try{const language=value('language'),target=value('target');const job=await resolveJob(await call('transcription.create_from_input',{asset_id:asset.asset_id,...(value('title').trim()?{title:value('title').trim()}:{}),...(language?{language}:{}),speakers:value('speakers'),segment_subtitles:$<HTMLInputElement>('segment').checked,target_languages:target?[target]:[]}));if(job.session_id){showJob(job);asset=undefined;submit.textContent=t('任务已创建','Job created')}else throw new Error(job.message||'Could not create a job')}catch(e){notice(e instanceof Error?e.message:String(e),true);submit.disabled=false}finally{submit.removeAttribute('aria-busy')}};
start('app_transcription',async data=>{
 $('native-form').hidden=!data.native_forms;
 const options=data.options||{};
 if(options.title)$<HTMLInputElement>('title').value=options.title;
 if(options.language&&options.language!=='auto'){
  const select=$<HTMLSelectElement>('language');
  if(!Array.from(select.options).some(option=>option.value===options.language))select.add(new Option(options.language,options.language));
  select.value=options.language;
 }
 if(options.speakers)$<HTMLSelectElement>('speakers').value=options.speakers;
 $<HTMLInputElement>('segment').checked=options.segment_subtitles===true;
 if(options.target_languages?.length)$<HTMLSelectElement>('target').value=options.target_languages[0];
 if(data.job_id||data.session_id){
  asset=undefined;$('choose').hidden=true;$('transcription-form').closest<HTMLElement>('.card')!.hidden=true;
  const mediaCard=$('selected').closest<HTMLElement>('.card')!;
  mediaCard.querySelector<HTMLElement>('.step-number')!.hidden=true;
  mediaCard.querySelector('h2')!.textContent='Your media';
  $('selected').hidden=false;$('selected').innerHTML=`${icon('video')}<div><strong>${esc(data.name||'Attached media')}</strong><p>${esc(options.language&&options.language.toLowerCase()!=='auto'?'Spoken language: '+options.language:'Language detection: Automatic')}</p></div>${icon('check')}`;
  showJob(data);
  try{
   const job=await resolveJob(data);
   if(job.session_id)showJob(job);
   else throw new Error(job.error||job.message||'Could not create a transcription job');
  }catch(error){
   const message=error instanceof Error?error.message:String(error);
   showJob({status:message.startsWith('Job submitted.')?'queued':'failed',message,error:message});
   throw error;
  }
 }else if(data.input){const next=await waitInput(data.input);if(next){asset=next;updateAsset()}}
 else if(data.file){const next=await waitInput(await call('media.bind_attachment',{file:data.file}));if(next){asset=next;updateAsset()}}
 // A delayed initial result must never replay a submission and create a second job.
},args=>args.start===true?undefined:args);
