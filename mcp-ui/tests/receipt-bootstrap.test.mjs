import assert from 'node:assert/strict';
import {test} from 'node:test';
import {build} from 'esbuild';
import vm from 'node:vm';
import {webcrypto} from 'node:crypto';

const bundle=await build({entryPoints:['shared/ui.ts'],bundle:true,format:'iife',globalName:'ui',write:false,
 plugins:[{name:'mock-host',setup(b){b.onResolve({filter:/^@modelcontextprotocol\/ext-apps$/},()=>({path:'host',namespace:'mock'}));
 b.onLoad({filter:/.*/,namespace:'mock'},()=>({contents:`export class App {async connect(){this.ontoolinput?.({arguments:globalThis.modelInput})} async callServerTool(p){globalThis.calls.push(structuredClone(p));return {structuredContent:{session_id:'saved-session',status:'completed'}}} getHostContext(){return {}}} export function applyDocumentTheme(){} export function applyHostStyleVariables(){}`,loader:'js'}));}}]});
function host(receiptTools,modelInput={session_id:'saved-session'}){
 const elements=new Map();
 const context=vm.createContext({window:{__voxstudioReceiptTools:receiptTools},modelInput,crypto:webcrypto,calls:[],structuredClone,setTimeout,clearTimeout,
  document:{getElementById(id){if(!elements.has(id))elements.set(id,{classList:{add(){},remove(){},toggle(){}}});return elements.get(id)}}});
 vm.runInContext(bundle.outputFiles[0].text,context);return context;
}
test('delayed or absent initial tool result cannot omit a write ID in fallback',async()=>{
 const c=host(['app_dubbing','session.open']);
 c.ui.start('app_dubbing',()=>{});
 await new Promise(resolve=>setTimeout(resolve,450));
 assert.equal(c.calls.length,1);
 assert.equal(c.calls[0].name,'app_dubbing');
 assert.match(c.calls[0].arguments.request_id,/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
 const args={session_id:'saved-session'};
 await c.ui.rawCall('session.open',args);await c.ui.rawCall('session.open',args);
 assert.equal(c.calls[1].arguments.request_id,c.calls[2].arguments.request_id);
 await c.ui.rawCall('media.status',{session_id:'saved-session'});
 assert.equal(c.calls[3].arguments.request_id,undefined);
});
test('existing IDs survive retry and catalog is scoped to the connection',async()=>{
 const c=host(['app_dubbing']);c.ui.start('media.status',()=>{});
 await new Promise(resolve=>setTimeout(resolve,0));
 const args={session_id:'saved-session',request_id:'5b0e8a52-3c1d-4f7a-9d26-8e41c7a0b1d3'};
 await c.ui.rawCall('app_dubbing',args);assert.equal(c.calls[0].arguments.request_id,args.request_id);
 await c.ui.rawCall('session.open',{session_id:'saved-session'});
 assert.equal(c.calls[1].arguments.request_id,undefined);
 c.ui.app.onteardown();
});

test('a delayed generation result never replays the submitted start request',async()=>{
 const c=host(['app_dubbing'],{start:true,text:'Synthetic test',request_id:'5b0e8a52-3c1d-4f7a-9d26-8e41c7a0b1d3'});
 c.ui.start('app_dubbing',()=>{},args=>args.start===true?undefined:args);
 await new Promise(resolve=>setTimeout(resolve,450));
 assert.equal(c.calls.length,0);c.ui.app.onteardown();
});
