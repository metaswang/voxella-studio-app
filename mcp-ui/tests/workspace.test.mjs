import assert from 'node:assert/strict';import {test} from 'node:test';import {build} from 'esbuild';
const bundle=await build({entryPoints:['shared/workspace-model.ts'],bundle:true,format:'esm',platform:'node',write:false});
const {stateArguments,sessionPresentation,highlightedParts}=await import('data:text/javascript;base64,'+Buffer.from(bundle.outputFiles[0].contents).toString('base64'));
const catalog=[{source_id:'one',title:'One',type:'upload'},{source_id:'two',title:'Two',type:'dub'},{source_id:'three',title:'Three'}];
test('inline cards stay on their turn while expanded panels follow the active turn',()=>{
 assert.deepEqual(stateArguments('workspace','old-turn',false,4),{workspace_id:'workspace',turn_id:'old-turn',after_revision:4});
 assert.deepEqual(stateArguments('workspace','old-turn',true),{workspace_id:'workspace'});
});
test('a checked source opens the existing detail; a multi-session scope shows only selected sessions',()=>{
 assert.equal(sessionPresentation({view:{source_id:'one'}},catalog).kind,'session');
 const comparison=sessionPresentation({scope:{source_ids:['one','two']},view:{source_id:'one'}},catalog);
 assert.equal(comparison.kind,'list');assert.deepEqual(comparison.rows.map(row=>row.session_id),['one','two']);
 assert.equal(sessionPresentation({scope:{source_ids:['one']},view:{}},catalog).source.session_id,'one');
});
test('session discovery shows matching rows even if metadata or original text has been fetched',()=>{
 const listing={tool:'search',arguments:{query:'Two',target:'sources'},result:{retrieval:{target:'sources'},results:[{source_id:'two',title:'Two'}]}};
 const result=sessionPresentation({view:{source_id:'two'},observations:{s:listing}},catalog);
 assert.equal(result.kind,'list');assert.deepEqual(result.rows.map(row=>row.session_id),['two']);
 assert.equal(sessionPresentation({view:{},observations:{s:{...listing,result:{retrieval:{target:'sources'},results:[]}}}},catalog).rows.length,0);
});
test('manual detail, back and pin survive later automatic source selection without changing scope',()=>{
 const state={turn_id:'turn',scope:{source_ids:['one','two']},view:{source_id:'two',manual_turn_id:'turn'}};
 assert.equal(sessionPresentation(state,catalog).source.session_id,'two');
 assert.equal(sessionPresentation({...state,scope:{source_ids:['one']},view:{manual_turn_id:'turn'}},catalog).kind,'list');
 assert.equal(sessionPresentation({...state,view:{source_id:'three',pinned:true}},catalog).source.session_id,'three');
});
test('filtered catalog pages retain only the latest filter and its exact cursor arguments',()=>{
 const make=(sequence,origin,sources,next_cursor)=>({sequence,tool:'list_sources',arguments:{origin,limit:1,...(sequence===2?{cursor:'first'}:{})},result:{sources,next_cursor}});
 const result=sessionPresentation({observations:{z:make(0,'cloud',[catalog[2]]),a:make(2,'local',[catalog[1]],'next'),x:make(1,'local',[catalog[0]],'first')}},catalog);
 assert.deepEqual(result.rows.map(row=>row.session_id),['one','two']);assert.equal(result.cursor,'next');assert.equal(result.args.origin,'local');
});
test('empty passage searches do not fall back to unrelated catalog sessions',()=>{
 assert.deepEqual(sessionPresentation({observations:{s:{tool:'search',result:{results:[]}}},candidates:[]},catalog).rows,[]);
});
test('UTF16 highlights work without timecodes and across segment boundaries',()=>{
 assert.deepEqual(highlightedParts('甲😀乙',10,11,13),['甲','😀','乙']);
 assert.deepEqual(highlightedParts('abcdef',20,18,23),['','abc','def']);
 assert.deepEqual(highlightedParts('abcdef',20,30,31),['abcdef','','']);
});
