"""Live profile acceptance client; run in Docker against the Mac's loopback service."""
import argparse
import json
from pathlib import Path
import urllib.error
import urllib.request
from uuid import uuid4


def rpc(base, path, method, arguments=None, session=None):
    headers={'Content-Type':'application/json','Accept':'application/json, text/event-stream','MCP-Protocol-Version':'2025-06-18','Host':'127.0.0.1:19789'}
    if session:headers['Mcp-Session-Id']=session
    body=json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':arguments or {}}).encode()
    request=urllib.request.Request(base+path,body,headers)
    try:
        with urllib.request.urlopen(request,timeout=30) as response:
            text=response.read().decode();status=response.status;session=response.headers.get('Mcp-Session-Id')
    except urllib.error.HTTPError as error:
        return error.code,{},None
    if not text.lstrip().startswith('{'):
        text=next(line[5:].strip() for line in text.splitlines() if line.startswith('data:') and line[5:].lstrip().startswith('{'))
    return status,json.loads(text),session


def call(base,path,name,arguments,session=None):
    status,body,_=rpc(base,path,'tools/call',{'name':name,'arguments':arguments},session)
    assert status==200,(path,name,status)
    return body


def check(base):
    rows={};sessions={};catalogs={}
    for path in ['/chatgpt/mcp','/native/mcp','/app/mcp','/mcp','/knowledge/mcp']:
        status,body,session=rpc(base,path,'initialize',{'protocolVersion':'2025-06-18','capabilities':{},'clientInfo':{'name':'voxstudio-profile-acceptance','version':'1'}})
        assert status==200 and session,(path,status)
        sessions[path]=session
        status,body,_=rpc(base,path,'tools/list',session=session)
        assert status==200 and 'result' in body,(path,body)
        tools=body['result']['tools'];names={tool['name'] for tool in tools};catalogs[path]=names
        assert len(names)==len(tools),'Duplicate names'
        model=[tool for tool in tools if tool.get('_meta',{}).get('ui',{}).get('visibility')!=['app']]
        size=lambda value:len(json.dumps(value,ensure_ascii=False,separators=(',',':')).encode())
        rows[path]={'tools':len(tools),'model_tools':len(model),'model_bytes':size(model),'catalog_bytes':size(tools),'names':sorted(names)}
    core='/chatgpt/mcp';native='/native/mcp';names=catalogs[core]
    assert 15<=rows[core]['model_tools']<=18
    assert rows[core]['model_bytes']<=24*1024
    assert {'app_knowledge','app_transcription','app_dubbing','media.export','search','fetch','knowledge.complete_turn'}<=names
    assert not {'get_timeline','set_clip_properties','documents.commit','session.editor.commit'}&names
    assert {'get_timeline','set_clip_properties','documents.commit','session.editor.commit'}<=catalogs[native]
    assert 'app_knowledge' not in catalogs[native]
    assert 'set_clip_properties' in catalogs['/app/mcp'] and 'set_clip_properties' in catalogs['/mcp']
    for source in sessions:
        for target in sessions:
            if source!=target:
                status,_,_=rpc(base,target,'tools/list',session=sessions[source]);assert status==404,(source,target,status)
    for name in ['set_clip_properties','documents.commit','session.editor.commit','get_timeline']:
        body=call(base,core,name,{},sessions[core]);assert body.get('error') or body.get('result',{}).get('isError')
    draft=call(base,core,'app_dubbing',{'text':'MCP profile acceptance draft.','start':False,'request_id':str(uuid4())},sessions[core])
    draft=draft.get('result',{})
    assert not draft.get('isError'),draft
    assert draft.get('structuredContent',{}).get('options',{}).get('text')=='MCP profile acceptance draft.'
    invalid=call(base,core,'app_transcription',{'path':'/nonexistent-voxstudio-mcp-profile-test.wav','start':True,'request_id':str(uuid4())},sessions[core])
    assert invalid.get('result',{}).get('isError')
    begun=call(base,core,'app_knowledge',{'action':'begin','query':'List local sessions for MCP verification.','scope':{'origin':'local'},'request_id':str(uuid4())},sessions[core])['result']
    assert not begun.get('isError'),begun
    fields=begun['structuredContent'];next_call=fields.get('next_call',{});assert next_call.get('tool') in names and next_call.get('tool')!='app_evidence'
    pair={'workspace_id':fields['workspace_id'],'turn_id':fields['turn_id']}
    listed=call(base,core,'list_sources',{**pair,'limit':2},sessions[core])['result']
    assert not listed.get('isError'),listed
    listing=listed['structuredContent'];sources=listing.get('sources',[])
    rows['workflow']={'draft_preserved':True,'invalid_asr_rejected':True,'knowledge_begin':True,'source_count_on_page':len(sources),'session_isolation_pairs':20,'export':'no-readable-source'}
    observation=listing.get('observation_id')
    source=next((source for source in sources if source.get('body_readable')),None)
    if source:
        fetched=call(base,core,'fetch',{**pair,'source_id':source['source_id'],'view':'body','limit':1},sessions[core])['result']
        assert not fetched.get('isError'),fetched
        read=fetched['structuredContent'];observation=read.get('observation_id')
        rows['workflow']['original_read']=True
        exported=call(base,core,'media.export',{'session_id':source['source_id'],'format':'txt','request_id':str(uuid4())},sessions[core])['result']
        if not exported.get('isError'):
            doc=exported['structuredContent'];assert 'text' in doc and 'resource_uri' in doc
            status,resource,_=rpc(base,core,'resources/read',{'uri':doc['resource_uri']},sessions[core]);assert status==200 and 'result' in resource
            _,denied,_=rpc(base,native,'resources/read',{'uri':doc['resource_uri']},sessions[native]);assert 'error' in denied,'Export grant leaked to native'
            rows['workflow']['export']='verified-with-isolated-document-grant'
        else:rows['workflow']['export']='source-has-no-exportable-subtitle-track'
    final=call(base,core,'knowledge.complete_turn',{**pair,'outcome':'answered','cited_observation_ids':[observation] if observation else []},sessions[core])['result']
    assert not final.get('isError'),final
    rows['workflow']['knowledge_completed']=True
    for path,session in sessions.items():
        req=urllib.request.Request(base+path,method='DELETE',headers={'Mcp-Session-Id':session,'MCP-Protocol-Version':'2025-06-18','Host':'127.0.0.1:19789'})
        with urllib.request.urlopen(req,timeout=10) as response:assert response.status==200 or response.status==204
    return rows


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--base',default='http://host.docker.internal:19789');parser.add_argument('--output',type=Path)
    args=parser.parse_args();report=check(args.base)
    if args.output:args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({path:{key:value for key,value in row.items() if key!='names'} for path,row in report.items()},ensure_ascii=False,indent=2))
