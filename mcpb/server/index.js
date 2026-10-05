// Standard stdio ↔ Streamable HTTP transport. No host-specific UI transformation.
const http = require('node:http');
const {randomUUID} = require('node:crypto');
const URL_BASE = 'http://127.0.0.1:19789/app/mcp';
const READ_TOOLS = new Set(['search','fetch','list_sources','aggregate','find_text','methods','knowledge.workspace_state','session.get_summary','get_project','get_timeline','inspect_timeline','get_media','inspect_media','search_media','get_multicam','get_transcript','inspect_color','list_models','read_skill','get_clip','list_media','voice.list','media.status','media.search','media.preview','media.session_preview','media.asset_preview','media.input_status','voxstudio.job_status','session.editor.read','documents.read','voxstudio.sessions','search_mentions']);
function replayPolicy(msg) {
  if (['tools/list','resources/list','resources/read','resources/templates/list','prompts/list','prompts/get','ping'].includes(msg.method)) return 'read';
  if (msg.method !== 'tools/call') return 'never';
  if (READ_TOOLS.has(msg.params?.name)) return 'read';
  const args=msg.params?.arguments??{};
  if (msg.params?.name==='knowledge.complete_turn') return 'receipt';
  if (msg.params?.name==='app_knowledge' && args.action==='begin' && args.request_id) return 'receipt';
  // Presence of request_id is checked against the server's typed tool schema.
  return args.request_id?'receipt':'never';
}
function parseEvents(buffer, deliver) {
  // Normalize after joining chunks: CR and LF can arrive separately.
  buffer=buffer.replace(/\r\n/g,'\n');
  let sep;
  while ((sep=buffer.indexOf('\n\n'))>=0) {
    const event=buffer.slice(0,sep);buffer=buffer.slice(sep+2);
    const data=event.split('\n').filter(l=>l.startsWith('data:')).map(l=>l.slice(5).trimStart()).join('\n');
    if(data) {try{deliver(JSON.parse(data));}catch{}}
  }
  return buffer;
}
function createProxy({url=URL_BASE,emit,log=()=>{},deadlineMs=25000,retryMin=500,retryMax=5000}={}) {
  let session=null,protocol='2025-06-18',initializeParams=null,connecting=null,getRequest=null,epoch=null,closed=false;
  const pending=new Map(),sleep=ms=>new Promise(r=>setTimeout(r,ms));
  const headers=sid=>({'Content-Type':'application/json',Accept:'application/json, text/event-stream','MCP-Protocol-Version':protocol,...(sid?{'Mcp-Session-Id':sid}:{})});
  async function post(msg,sid,deliver,signal) {
    let delivered=false;
    try {
      const response=await fetch(url,{method:'POST',headers:headers(sid),body:JSON.stringify(msg),signal});
      if(!response.ok)throw new Error(`HTTP ${response.status}`);
      const assigned=response.headers.get('mcp-session-id');
      const forward=out=>{if(out.id===msg.id && msg.id!==undefined)delivered=true;deliver(out);};
      if(response.headers.get('content-type')?.startsWith('text/event-stream')) {
        const reader=response.body.getReader(),decoder=new TextDecoder();let buf='';
        for(;;){const {done,value}=await reader.read();if(done)break;buf=parseEvents(buf+decoder.decode(value,{stream:true}).replace(/\r\n/g,'\n'),forward);}
      } else if(response.headers.get('content-type')?.startsWith('application/json'))forward(await response.json());
      if(msg.method && msg.id!==undefined && !delivered)throw new Error('response lost; execution status unknown');
      return assigned;
    }catch(error){error.delivered=delivered;throw error;}
  }
  function notifications(sid) {
    getRequest?.destroy();
    const req=http.get(url,{headers:{...headers(sid),Accept:'text/event-stream'}},res=>{
      if(res.statusCode!==200){res.resume();return;}
      let buf='';res.setEncoding('utf8');
      res.on('data',chunk=>{buf=parseEvents(buf+chunk.replace(/\r\n/g,'\n'),msg=>{if(session===sid && !closed)emit(msg);});});
      res.on('end',()=>{if(session===sid && !closed){session=null;connect().catch(()=>{});}});
      res.on('error',()=>{if(session===sid && !closed){session=null;connect().catch(()=>{});}});
    });
    req.on('error',()=>{if(session===sid && !closed){session=null;connect().catch(()=>{});}});getRequest=req;
  }
  function connect() {
    if(connecting)return connecting;
    connecting=(async()=>{
      let delay=retryMin;
      while(!closed){
        const control=new AbortController(),timeout=setTimeout(()=>control.abort(),deadlineMs);
        try{
          let result;
          const id=`shim-${randomUUID()}`;
          const sid=await post({jsonrpc:'2.0',id,method:'initialize',params:initializeParams},null,out=>{if(out.id===id){if(out.error)throw new Error(out.error.message);result=out.result;}},control.signal);
          if(!result)throw new Error('Missing initialization result');
          if(result.protocolVersion)protocol=result.protocolVersion;
          await post({jsonrpc:'2.0',method:'notifications/initialized'},sid,()=>{},control.signal);
          session=sid;epoch=result.serverInfo?.version??null;notifications(sid);return result;
        }catch(error){log('Connection pending:',error.message);}
        finally{clearTimeout(timeout);}
        await sleep(delay);delay=Math.min(delay*2,retryMax);
      }
      throw new Error('Transport closed');
    })().finally(()=>{connecting=null;});return connecting;
  }
  async function bounded(promise,control) {
    if(control.signal.aborted)throw new Error('Request cancelled or recovery deadline exceeded');
    return Promise.race([promise,new Promise((_,reject)=>control.signal.addEventListener('abort',()=>reject(new Error('Request cancelled or recovery deadline exceeded')),{once:true}))]);
  }
  async function handle(msg) {
    const control=new AbortController();let timer=setTimeout(()=>control.abort(),session?60000:deadlineMs),recovering=false;
    if(msg.id!==undefined)pending.set(msg.id,control);
    try{
      if(msg.method==='notifications/cancelled')pending.get(msg.params?.requestId)?.abort();
      if(msg.method==='initialize'){
        initializeParams=msg.params;
        const result=await bounded(connect(),control);emit({jsonrpc:'2.0',id:msg.id,result});return;
      }
      if(msg.method==='notifications/initialized')return;
      if(!initializeParams)throw new Error('Initialize the connector first');
      if(connecting||!session)await bounded(connect(),control);
      clearTimeout(timer);timer=setTimeout(()=>control.abort(),60000);
      const originalEpoch=epoch,policy=replayPolicy(msg);
      for(let attempts=0;;attempts++){
        const sid=session;
        try{
          await post(msg,sid,out=>{if(session===sid && !control.signal.aborted)emit(out);},control.signal);
          if(session!==sid){const error=new Error('Connection replaced; response belongs to the previous session');error.delivered=true;throw error;}return;
        }catch(error){
          if(error.delivered || control.signal.aborted)throw error;
          if(!recovering){recovering=true;clearTimeout(timer);timer=setTimeout(()=>control.abort(),deadlineMs);}
          if(session===sid){session=null;connect().catch(()=>{});}
          if(policy==='never'||msg.id===undefined||attempts>=2)throw new Error(`Execution status unknown; request was not replayed (${error.message})`);
          await bounded(connect(),control);
          if(policy==='receipt' && epoch!==originalEpoch)throw new Error('VoxStudio restarted; execution status unknown and the request was not replayed');
        }
      }
    }finally{clearTimeout(timer);if(pending.get(msg.id)===control)pending.delete(msg.id);}
  }
  return {handle,close(){closed=true;getRequest?.destroy();for(const c of pending.values())c.abort();},get session(){return session;}};
}
function startStdio(){
  const proxy=createProxy({emit:msg=>process.stdout.write(JSON.stringify(msg)+'\n'),log:(...args)=>console.error('[voxstudio-shim]',...args)});
  let buf='';process.stdin.setEncoding('utf8');
  process.stdin.on('data',chunk=>{buf+=chunk;let nl;while((nl=buf.indexOf('\n'))>=0){const line=buf.slice(0,nl).trim();buf=buf.slice(nl+1);if(!line)continue;let msg;try{msg=JSON.parse(line);}catch{continue;}
    proxy.handle(msg).catch(error=>{if(msg.id!==undefined)process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:msg.id,error:{code:-32603,message:`VoxStudio: ${error.message}`}})+'\n');});}});
  process.stdin.on('end',()=>{proxy.close();process.exit(0);});
}
if(require.main===module)startStdio();
module.exports={createProxy,replayPolicy,parseEvents,URL_BASE,startStdio};
