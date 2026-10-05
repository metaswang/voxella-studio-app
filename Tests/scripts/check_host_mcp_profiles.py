"""Read the desktop host's actual MCP registry without starting a model turn."""
import argparse
import json
from pathlib import Path
import select
import subprocess
import time


def check(cli):
    process=subprocess.Popen([cli,'app-server','--stdio'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,bufsize=1)
    def send(method,params,identifier):
        process.stdin.write(json.dumps({'id':identifier,'method':method,'params':params})+'\n');process.stdin.flush()
        deadline=time.monotonic()+45
        while time.monotonic()<deadline:
            ready,_,_=select.select([process.stdout],[],[],max(0,deadline-time.monotonic()))
            if not ready:break
            line=process.stdout.readline()
            if not line:raise RuntimeError('Desktop host closed its protocol stream')
            message=json.loads(line)
            if message.get('id')!=identifier:continue
            if 'error' in message:raise RuntimeError(message['error'])
            return message['result']
        raise RuntimeError('Desktop host inventory timed out')
    try:
        send('initialize',{'clientInfo':{'name':'voxstudio-profile-verification','version':'1'},'capabilities':{'experimentalApi':True,'requestAttestation':False}},1)
        process.stdin.write('{"method":"initialized"}\n');process.stdin.flush()
        result={}
        for index,name in enumerate(['voxstudio','voxstudio_native','voxstudio_cloud'],2):
            data=send('mcpServerStatus/list',{'serverName':name,'detail':'toolsAndAuthOnly','limit':100},index)
            row=next(value for value in data['data'] if value['name']==name)
            assert not row.get('toolsError'),(name,row.get('toolsError'))
            tools=list(row['tools'].values()) if isinstance(row['tools'],dict) else row['tools']
            model=[tool for tool in tools if tool.get('_meta',{}).get('ui',{}).get('visibility')!=['app']]
            names={tool['name'] for tool in model}
            assert names,(name,'No model tools')
            if name in {'voxstudio','voxstudio_cloud'}:
                assert 15<=len(names)<=18,(name,len(names))
                assert not any(token in tool for tool in names for token in ['set_clip_properties','documents.commit','video_editor','clip_project','timeline.edit'])
            result[name]={'plugin_id':row.get('pluginId'),'http_origin':row.get('httpOrigin'),'auth_status':row.get('authStatus'),'runtime_status':row.get('runtimeStatus'),'server_info':row.get('serverInfo'),'catalog_tools':len(tools),'model_tools':len(model),'model_bytes':len(json.dumps(model,ensure_ascii=False,separators=(',',':')).encode()),'model_names':sorted(names),'tools_error':row.get('toolsError')}
        assert result['voxstudio']['plugin_id']=='voxstudio@voxstudio-local'
        assert result['voxstudio_native']['plugin_id'] is None
        assert result['voxstudio_cloud']['plugin_id']=='voxstudio-cloud@voxstudio-cloud-marketplace'
        return result
    finally:
        process.stdin.close();process.terminate()
        try:process.wait(timeout=5)
        except subprocess.TimeoutExpired:process.kill()


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--cli',required=True);parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();report=check(args.cli)
    args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({key:{field:value for field,value in row.items() if field!='model_names'} for key,row in report.items()},ensure_ascii=False,indent=2))
