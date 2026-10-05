// Optional live acceptance: node mcpb/tests/live-smoke.cjs <authorized-session-UUID>
const assert=require('node:assert/strict');
const {createProxy}=require('../server/index.js');
const sessionId=process.argv[2];
assert.match(sessionId??'',/^[0-9a-f-]{36}$/i,'Supply the UUID of an authorized sample session');
const responses=new Map(),proxy=createProxy({emit:message=>{if(message.id!==undefined)responses.set(message.id,message);}});
let request=0;
async function call(method,params={}){
 const id=++request;await proxy.handle({jsonrpc:'2.0',id,method,params});
 const row=responses.get(id);assert.ok(row,'No response');if(row.error)throw Error(row.error.message);return row.result;
}
(async()=>{
 try{
  const initialized=await call('initialize',{protocolVersion:'2025-06-18',capabilities:{extensions:{'io.modelcontextprotocol/ui':{mimeTypes:['text/html;profile=mcp-app']}}},clientInfo:{name:'voxstudio-stdio-acceptance',version:'1'}});
  const inventory=await call('tools/list');const entry=inventory.tools.find(row=>row.name==='app_knowledge');
  assert.equal(entry._meta.ui.resourceUri,'ui://voxstudio/workspace/v1');assert.ok(inventory.tools.find(row=>row.name==='session.editor.commit'));
  const html=await call('resources/read',{uri:entry._meta.ui.resourceUri});assert.equal(html.contents[0].mimeType,'text/html;profile=mcp-app');assert.ok(html.contents[0].text.includes('voxstudio-session-companion-v1'));
  const read=await call('tools/call',{name:'fetch',arguments:{source_id:sessionId,limit:1}});assert.equal(read.isError,undefined);assert.ok(read.structuredContent.segments[0].text.length>0);
  const preview=await call('tools/call',{name:'media.session_preview',arguments:{session_id:sessionId,start:0,duration:15}});assert.ok(!preview.isError,JSON.stringify(preview));
  const bytes=await call('resources/read',{uri:preview.structuredContent.preview_resource_uri});assert.ok(bytes.contents[0].blob.length>100);assert.ok(bytes.contents[0].mimeType.startsWith('video/')||bytes.contents[0].mimeType.startsWith('audio/'));
  console.log(JSON.stringify({serverVersion:initialized.serverInfo.version,toolCount:inventory.tools.length,standardUI:true,structuredContent:true,mediaBlob:true,bytes:Buffer.from(bytes.contents[0].blob,'base64').length}));
 }finally{proxy.close();}
})().catch(error=>{console.error(error.message);process.exitCode=1;});
