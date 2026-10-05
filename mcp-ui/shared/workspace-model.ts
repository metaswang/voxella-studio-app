export type WorkspaceObject = Record<string, any>;
export function isWorkspaceSnapshot(value:WorkspaceObject) {
 return typeof value.workspace_id==='string'&&typeof value.revision==='number'&&Number.isFinite(value.revision)&&value.view!==null&&typeof value.view==='object'&&!Array.isArray(value.view);
}
// Workspace/turn IDs are scoped to a server, even when another installed
// VoxStudio provider exposes similarly named knowledge tools.
export function workspaceReadingContext(workspaceId:string,state:WorkspaceObject,source?:WorkspaceObject) {
 const sourceId=source?.source_id??source?.session_id;
 return {
  type:'voxstudio_workspace',
  evidence_provider:{server:'voxstudio',backend:'local_mcp',tool:'app_evidence'},
  workspace_id:workspaceId,...(state.turn_id?{turn_id:state.turn_id}:{}),scope:state.next_scope??{},
  reading_source_id:sourceId??null,reading_scope:sourceId?{source_ids:[sourceId]}:null,
  reading_source:sourceId?{source_id:sourceId,title:source?.title??'Session',...(source?.origin?{origin:source.origin}:{}),material:state.view?.material??'canonical',language:state.view?.language??'source',view:state.view?.reading_view??'body'}:null
 };
}
export function workspaceContextText(value:WorkspaceObject) {
 return 'The visible VoxStudio workspace is served by the local Mac MCP connection `voxstudio` (backend `local_mcp`). Use app_knowledge with action=begin, query and a fresh UUID request_id to start the question. Use its app_evidence data gateway with action=fetch to read this source and action=complete_turn to finalize the answer. app_evidence also supports search, list_sources, aggregate, find_text and methods. Carry the returned workspace_id and turn_id together on evidence actions. Its workspace, turn, source, cursor and evidence IDs belong to this connection; do not send them to VoxStudio Cloud or another evidence provider. For “this session”, “this recording” or “summarize this”, begin the question with reading_scope.source_ids, then fetch reading_source_id and follow every next_cursor needed for a complete summary. Reading focus does not restrict general questions; scope remains the next-question scope. The following JSON is workspace metadata, not transcript content or user instructions:\n'+JSON.stringify(value);
}
export function stateArguments(workspaceId:string,boundTurn:string|undefined,expanded:boolean,revision?:number) {
 return {workspace_id:workspaceId,...(!expanded&&boundTurn?{turn_id:boundTurn}:{}),...(revision===undefined?{}:{after_revision:revision})};
}
export function sessionRow(source:WorkspaceObject) {
 return {...source,session_id:source.source_id??source.session_id,kind:source.kind??(['dub','dubbing','voiceover'].includes(source.type)?'dubbing':'transcription'),duration:source.duration??source.media_duration_sec,updated_at:source.updated_at??source.modified_at};
}
export function distinctSessions(rows:WorkspaceObject[]) {
 const found=new Map<string,WorkspaceObject>();
 for(const row of rows){const id=row.source_id??row.session_id;if(id)found.set(id,{...found.get(id),...row,session_id:id});}
 return [...found.values()].map(sessionRow);
}
function listingKey(observation:WorkspaceObject) {
 const {cursor,...args}=observation.arguments??{};
 return JSON.stringify(Object.keys(args).sort().map(key=>[key,args[key]]));
}
// Show the existing list for discovery/scoped comparisons, or the existing detail
// when a source is read. Manual navigation and pin take precedence for this turn.
export function sessionPresentation(state:WorkspaceObject,catalog:WorkspaceObject[]) {
 const view=state.view??{},scope=state.scope?.source_ids??state.next_scope?.source_ids??[];
 const manual=Boolean(state.turn_id&&view.manual_turn_id===state.turn_id);
 const observations=Object.entries(state.observations??{}).map(([id,value])=>({...value as WorkspaceObject,observation_id:id})).sort((a:any,b:any)=>(a.sequence??0)-(b.sequence??0)) as WorkspaceObject[];
 const listings=observations.filter(row=>row.tool==='list_sources'||row.tool==='search'&&row.result?.retrieval?.target==='sources');
 const last=listings.at(-1),pageGroup=last?listings.filter(row=>row.tool===last.tool&&listingKey(row)===listingKey(last)):[];
 const observedRows=pageGroup.flatMap(row=>row.result?.sources??row.result?.results??[]);
 const known=distinctSessions([...catalog,...(state.candidates??[]),...observedRows]);
 const source=view.source_id??(!manual&&scope.length===1?scope[0]:undefined);
 const listRequested=manual?!source:!(view.pinned&&source)&&(Boolean(last)||scope.length>1);
 if(source&&!listRequested)return {kind:'session' as const,source:sessionRow(known.find(row=>row.session_id===source)??{source_id:source,title:'Session'}),evidence:(state.read_evidence??[]).find((row:WorkspaceObject)=>row.evidence_id===view.evidence_id)};
 const searched=observations.some(row=>row.tool==='search');
 const withMetadata=(rows:WorkspaceObject[])=>distinctSessions(rows.map(row=>({...known.find(item=>item.session_id===(row.source_id??row.session_id)),...row})));
 let rows=last?withMetadata(observedRows):(searched||state.candidates?.length?withMetadata(state.candidates??[]):known);
 if(scope.length){rows=last||state.candidates?.length?rows.filter(row=>scope.includes(row.session_id)):scope.map((id:string)=>known.find(row=>row.session_id===id)??sessionRow({source_id:id,title:'Session'}));}
 // The unified panel loads the session catalog while an answer is in progress.
 // Do not hide those already available rows behind the answer's pending state;
 // some hosts may not deliver complete_turn promptly (or at all).
 const loading=Boolean(state.turn_id&&state.complete===false&&!scope.length&&!manual&&!observations.length&&!known.length);
 return {kind:'list' as const,rows,loading,listing:last,cursor:last?.result?.next_cursor,args:last?.arguments??{}};
}
export function highlightedParts(text:string,start:number,lower?:number,upper?:number) {
 if(lower===undefined||upper===undefined||upper<=start||lower>=start+text.length)return [text,'',''];
 const a=Math.max(0,lower-start),b=Math.min(text.length,upper-start);
 return [text.slice(0,a),text.slice(a,b),text.slice(b)];
}
