const {test}=require('node:test');const assert=require('node:assert/strict');const http=require('node:http');
const {createProxy,replayPolicy,parseEvents,URL_BASE}=require('../server/index');
test('standard forwarding includes metadata, blobs and bidirectional notifications',async()=>{
 let session=0;const received=[],outputs=[];let stream;
 const server=http.createServer((req,res)=>{
  if(req.method==='GET'){stream=res;res.writeHead(200,{'Content-Type':'text/event-stream'});res.write('data: {"jsonrpc":"2.0","id":"host","method":"sampling/createMessage","params":{}}\n\n');return;}
  let data='';req.on('data',v=>data+=v);req.on('end',()=>{const msg=JSON.parse(data);received.push(msg);
   if(msg.method==='initialize'){res.writeHead(200,{'Content-Type':'application/json','Mcp-Session-Id':`s${++session}`});res.end(JSON.stringify({jsonrpc:'2.0',id:msg.id,result:{protocolVersion:'2025-06-18',serverInfo:{version:'epoch1'},capabilities:{tools:{},resources:{}}}}));return;}
   if(msg.id===undefined||!msg.method){res.writeHead(202);res.end();return;}
   res.writeHead(200,{'Content-Type':'application/json'});res.end(JSON.stringify({jsonrpc:'2.0',id:msg.id,result:{structuredContent:{evidence:'text'},_meta:{ui:{resourceUri:'ui://voxstudio/workspace/v1'}},contents:[{blob:'YWJj',mimeType:'audio/wav'}]}}));
  });
 });await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const proxy=createProxy({url:`http://127.0.0.1:${server.address().port}/app/mcp`,emit:msg=>outputs.push(msg)});
 try{
  await proxy.handle({jsonrpc:'2.0',id:1,method:'initialize',params:{capabilities:{extensions:{'io.modelcontextprotocol/ui':{mimeTypes:['text/html;profile=mcp-app']}}}}});
  await proxy.handle({jsonrpc:'2.0',id:2,method:'resources/read',params:{uri:'voxstudio://previews/a'}});
  await proxy.handle({jsonrpc:'2.0',id:'host',result:{role:'assistant',content:{type:'text',text:'sample'}}});
  assert.deepEqual(outputs.find(v=>v.id===2).result,{structuredContent:{evidence:'text'},_meta:{ui:{resourceUri:'ui://voxstudio/workspace/v1'}},contents:[{blob:'YWJj',mimeType:'audio/wav'}]});
  assert.equal(received.find(v=>v.method==='initialize').params.capabilities.extensions['io.modelcontextprotocol/ui'].mimeTypes[0],'text/html;profile=mcp-app');
  assert.equal(received.find(v=>v.id==='host').result.role,'assistant');
 }finally{proxy.close();stream?.destroy();server.closeAllConnections();await new Promise(r=>server.close(r));}
});
test('lost write is never blindly replayed and recovery respects its deadline',async()=>{
 let writes=0;const server=http.createServer((req,res)=>{if(req.method==='GET'){res.writeHead(405);res.end();return;}let data='';req.on('data',v=>data+=v);req.on('end',()=>{const msg=JSON.parse(data);
  if(msg.method==='initialize'){res.writeHead(200,{'Content-Type':'application/json','Mcp-Session-Id':'s'});res.end(JSON.stringify({id:msg.id,result:{serverInfo:{version:'1'}}}));}
  else if(msg.id===undefined){res.writeHead(202);res.end();}
  else{writes++;req.socket.destroy();}
 });});await new Promise(r=>server.listen(0,'127.0.0.1',r));const proxy=createProxy({url:`http://127.0.0.1:${server.address().port}`,emit:()=>{},deadlineMs:150,retryMin:5,retryMax:10});
 try{await proxy.handle({id:1,method:'initialize',params:{}});await assert.rejects(proxy.handle({id:2,method:'tools/call',params:{name:'delete_clip',arguments:{clip_id:'a'}}}),/not replayed/);assert.equal(writes,1);}
 finally{proxy.close();server.closeAllConnections();await new Promise(r=>server.close(r));}
 const offline=createProxy({url:'http://127.0.0.1:1',emit:()=>{},deadlineMs:60,retryMin:5,retryMax:10});let started=Date.now();await assert.rejects(offline.handle({id:1,method:'initialize',params:{}}),/deadline/);assert.ok(Date.now()-started<300);offline.close();
});
test('retry policies and multiline CRLF SSE parsing',()=>{
 assert.ok(URL_BASE.endsWith('/app/mcp'));assert.equal(replayPolicy({method:'tools/call',params:{name:'fetch'}}),'read');
 for(const name of ['media.input_status','media.asset_preview','voxstudio.job_status','session.editor.read','documents.read'])assert.equal(replayPolicy({method:'tools/call',params:{name}}),'read');
 assert.equal(replayPolicy({method:'tools/call',params:{name:'app_knowledge',arguments:{action:'begin',request_id:'stable'}}}),'receipt');
 assert.equal(replayPolicy({method:'tools/call',params:{name:'delete_clip'}}),'never');
 const rows=[];assert.equal(parseEvents('data: {"x":1}\n\ndata: {"x":',v=>rows.push(v)),'data: {"x":');assert.deepEqual(rows,[{x:1}]);
});

test('receipt retries share a process epoch and stop after App restart',async()=>{
 for(const restarted of [false,true]){
  let sessions=0,calls=0,effects=0;const outputs=[],receipts=new Map();
  const server=http.createServer((req,res)=>{
   if(req.method==='GET'){res.writeHead(405);res.end();return;}
   let data='';req.on('data',v=>data+=v);req.on('end',()=>{
    const msg=JSON.parse(data);
    if(msg.method==='initialize'){
     sessions++;res.writeHead(200,{'Content-Type':'application/json','Mcp-Session-Id':`s${sessions}`});
     res.end(JSON.stringify({id:msg.id,result:{serverInfo:{version:restarted?`epoch${sessions}`:'epoch1'}}}));return;
    }
    if(msg.id===undefined){res.writeHead(202);res.end();return;}
    calls++;const id=msg.params.arguments.request_id;
    if(!receipts.has(id)){effects++;receipts.set(id,{content:[{type:'text',text:'saved'}]});}
    if(calls===1){req.socket.destroy();return;}
    res.writeHead(200,{'Content-Type':'application/json'});res.end(JSON.stringify({id:msg.id,result:receipts.get(id)}));
   });
  });await new Promise(r=>server.listen(0,'127.0.0.1',r));
  const proxy=createProxy({url:`http://127.0.0.1:${server.address().port}`,emit:msg=>outputs.push(msg),deadlineMs:300,retryMin:5,retryMax:10});
  try{
   await proxy.handle({id:1,method:'initialize',params:{}});
   const action=proxy.handle({id:2,method:'tools/call',params:{name:'session.editor.commit',arguments:{request_id:'stable-request'}}});
   if(restarted){await assert.rejects(action,/restarted.*not replayed/);assert.equal(calls,1);}
   else{await action;assert.equal(calls,2);assert.equal(outputs.find(row=>row.id===2).result.content[0].text,'saved');}
   assert.equal(effects,1);
  }finally{proxy.close();server.closeAllConnections();await new Promise(r=>server.close(r));}
 }
});
test('cancellation stops an outstanding request and forwards the notification',async()=>{
 let started;const begun=new Promise(r=>started=r),received=[];
 const server=http.createServer((req,res)=>{
  if(req.method==='GET'){res.writeHead(405);res.end();return;}
  let data='';req.on('data',v=>data+=v);req.on('end',()=>{
   const msg=JSON.parse(data);received.push(msg);
   if(msg.method==='initialize'){res.writeHead(200,{'Content-Type':'application/json','Mcp-Session-Id':'s'});res.end(JSON.stringify({id:msg.id,result:{serverInfo:{version:'epoch1'}}}));}
   else if(msg.id===undefined){res.writeHead(202);res.end();}
   else started();
  });
 });await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const proxy=createProxy({url:`http://127.0.0.1:${server.address().port}`,emit:()=>{},deadlineMs:300});
 try{
  await proxy.handle({id:1,method:'initialize',params:{}});
  const request=proxy.handle({id:2,method:'tools/call',params:{name:'fetch',arguments:{id:'a'}}});
  const rejected=assert.rejects(request,/abort|cancel/i);await begun;
  await proxy.handle({method:'notifications/cancelled',params:{requestId:2}});await rejected;
  assert.equal(received.filter(row=>row.method==='tools/call').length,1);
  assert.equal(received.find(row=>row.method==='notifications/cancelled').params.requestId,2);
 }finally{proxy.close();server.closeAllConnections();await new Promise(r=>server.close(r));}
});
test('SSE parser handles CRLF split between transport chunks',()=>{
 const rows=[];let buffer=parseEvents('data: {"x":1}\r',row=>rows.push(row));
 buffer=parseEvents(buffer+'\n\r',row=>rows.push(row));
 buffer=parseEvents(buffer+'\n',row=>rows.push(row));
 assert.equal(buffer,'');assert.deepEqual(rows,[{x:1}]);
});
