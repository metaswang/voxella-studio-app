const {test}=require('node:test');
const assert=require('node:assert/strict');
const {spawn}=require('node:child_process');
const {createInterface}=require('node:readline');
const path=require('node:path');

test('the Desktop import loader starts stdio and answers initialization and tool discovery',async()=>{
 // Emulate Claude nodeHost.js: another module owns require.main and dynamically
 // imports the manifest entry. Mock HTTP so this checks startup in isolation.
 const loader=`
  const {EventEmitter}=require('node:events');
  require('node:http').get=()=>{const req=new EventEmitter();req.destroy=()=>{};return req;};
  global.fetch=async(_url,options)=>{
   const msg=JSON.parse(options.body);
   if(msg.id===undefined)return new Response(null,{status:202});
   const result=msg.method==='initialize'?{protocolVersion:'2025-06-18',serverInfo:{name:'fixture',version:'epoch1'},capabilities:{tools:{}}}:{tools:[{name:'fetch'}]};
   return new Response(JSON.stringify({jsonrpc:'2.0',id:msg.id,result}),{headers:{'Content-Type':'application/json','Mcp-Session-Id':'fixture'}});
  };
  import(require('node:url').pathToFileURL(process.argv[1]).href).catch(e=>{console.error(e);process.exit(1)});
 `;
 const child=spawn(process.execPath,['-e',loader,path.resolve(__dirname,'../server/stdio.js')],{stdio:['pipe','pipe','pipe']});
 const replies=[],read=createInterface({input:child.stdout});let stderr='';
 child.stderr.on('data',chunk=>stderr+=chunk);
 read.on('line',line=>replies.push(JSON.parse(line)));
 const waitFor=id=>new Promise((resolve,reject)=>{
  const timeout=setTimeout(()=>{cleanup();reject(new Error('No stdio reply: '+stderr));},2000);
  const onLine=()=>{const reply=replies.find(row=>row.id===id);if(reply){cleanup();resolve(reply);}};
  const cleanup=()=>{clearTimeout(timeout);read.off('line',onLine);};
  read.on('line',onLine);onLine();
 });
 try{
  child.stdin.write(JSON.stringify({jsonrpc:'2.0',id:1,method:'initialize',params:{protocolVersion:'2025-06-18',capabilities:{},clientInfo:{name:'import-loader',version:'1'}}})+'\n');
  assert.equal((await waitFor(1)).result.serverInfo.name,'fixture');
  child.stdin.write(JSON.stringify({jsonrpc:'2.0',id:2,method:'tools/list'})+'\n');
  assert.deepEqual((await waitFor(2)).result.tools,[{name:'fetch'}]);
 }finally{read.close();child.stdin.end();child.kill();}
});
