import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile
from unittest.mock import patch
from unittest.mock import Mock
from email.message import Message
ROOT=Path(__file__).resolve().parents[2]
def module(name,file):
    spec=importlib.util.spec_from_file_location(name,ROOT/'scripts'/file);value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
packager=module('plugin_package','package-openai-plugin.py')
installer=module('plugin_install','openai-plugin-install.py')
mcpb=module('mcpb_package','package-mcpb.py')
PLUGIN_VERSION=json.loads((ROOT/'Plugins/voxstudio/plugin.json').read_text())['version']

class PluginPackageTests(unittest.TestCase):
    def test_download_is_reproducible_and_self_contained(self):
        with tempfile.TemporaryDirectory() as tmp:
            base=Path(tmp);first=packager.package(ROOT,base/'one');second=packager.package(ROOT,base/'two')
            self.assertEqual(first,second)
            with zipfile.ZipFile(base/'one'/packager.FILENAME) as archive:
                self.assertIsNone(archive.testzip());archive.extractall(base/'extracted')
                self.assertFalse(any(name.endswith(('.env','.swift','.dmg')) or 'node_modules' in name for name in archive.namelist()))
            folder=base/'extracted'/packager.FOLDER
            marketplace=json.loads((folder/'.agents/plugins/marketplace.json').read_text())
            self.assertEqual([row['name'] for row in marketplace['plugins']],['voxstudio'])
            config=json.loads((folder/'plugins/voxstudio/mcp.json').read_text())
            self.assertEqual(config['mcpServers']['voxstudio']['url'],'http://127.0.0.1:19789/chatgpt/mcp')
            self.assertEqual(set(config['mcpServers']),{'voxstudio'})
            self.assertEqual({p.parent.name for p in (folder/'plugins/voxstudio/skills').glob('*/SKILL.md')},{'onboarding','media-workflow','session-retrieval','knowledge-qa'})
            self.assertTrue((folder/'plugins/voxstudio/skills/knowledge-qa/SKILL.md').is_file())
            self.assertTrue((folder/'install.py').is_file())
            app_icon=(ROOT/'Sources/VoxstudioPro/Resources/AppIcon.png').read_bytes()
            self.assertEqual((folder/'plugins/voxstudio/assets/icon.png').read_bytes(),app_icon)
            manifest=json.loads((folder/'plugins/voxstudio/plugin.json').read_text())
            self.assertEqual(manifest['extensions']['com.openai']['interface']['logo'],'./assets/icon.png')
    def test_readiness_probe_accepts_sse_priming_frames(self):
        class Response:
            def __init__(self, result):
                self.headers=Message();self.headers['Content-Type']='text/event-stream'
                self.data=('id: priming\nevent: message\ndata:\n\ndata: '+json.dumps({'id':1,'result':result})+'\n\n').encode()
            def __enter__(self):return self
            def __exit__(self,*args):pass
            def read(self):return self.data
        def reply(request,timeout):
            method=json.loads(request.data)['method']
            if method=='tools/list':return Response({'tools':[{'name':name} for name in ['voxstudio.workspace','app_knowledge','knowledge.complete_turn','search','fetch','app_transcription','app_dubbing','media.export']]})
            if method=='resources/read':return Response({'contents':[{'mimeType':'text/html;profile=mcp-app','text':'<!--voxstudio-session-companion-v1-->'}]})
            return Response({'serverInfo':{'version':'2.0.0'}})
        with patch.object(installer.urllib.request,'urlopen',side_effect=reply):installer.probe()

    def test_claude_extension_matches_current_sources(self):
        with tempfile.TemporaryDirectory() as tmp:
            a=mcpb.package(ROOT,Path(tmp)/'a.mcpb');b=mcpb.package(ROOT,Path(tmp)/'b.mcpb')
            self.assertEqual(a.read_bytes(),b.read_bytes())
            with zipfile.ZipFile(a) as archive:
                self.assertEqual(json.loads(archive.read('manifest.json'))['version'],'0.3.1')
                self.assertEqual(json.loads(archive.read('manifest.json'))['server']['entry_point'],'server/stdio.js')
                self.assertIn(b'/app/mcp',archive.read('server/index.js'))
                self.assertEqual(archive.read('icon.png'),(ROOT/'Sources/VoxstudioPro/Resources/AppIcon.png').read_bytes())
                for name in mcpb.FILES:self.assertEqual(archive.read(name),(ROOT/'mcpb'/name).read_bytes())
    def fixture(self,base,old):
        packager.package(ROOT,base/'package')
        with zipfile.ZipFile(base/'package'/packager.FILENAME) as archive:archive.extractall(base)
        folder=base/packager.FOLDER;home=base/'codex';home.mkdir()
        state={}
        config='[unrelated]\nvalue = "preserved"\n'
        for name,enabled in old:
            version='0.1.2' if name=='voxstudio' else '0.1.0';identity=name+'@voxstudio-local'
            state[identity]={'name':name,'pluginId':identity,'version':version,'enabled':enabled,'authPolicy':'ON_INSTALL','source':{'source':'local','path':'/old/'+name}}
            cache=home/'plugins/cache/voxstudio-local'/name/version;cache.mkdir(parents=True)
            (cache/'plugin.json').write_text(json.dumps({'name':name,'version':version}))
            config+=f'\n[plugins."{identity}"]\nenabled = {str(enabled).lower()}\npermission = "preserve"\n'
        (home/'config.toml').write_text(config);(home/'state.json').write_text(json.dumps(state))
        cli=base/'fake-codex';cli.write_text('''#!/usr/bin/env python3
import json,os,pathlib,sys,re,shutil
home=pathlib.Path(os.environ['TEST_PLUGIN_HOME']);file=home/'state.json';state=json.loads(file.read_text());args=sys.argv[2:-1]
root=home/'marketplace.txt'
output=None
if args[:2]==['marketplace','list']:output={'marketplaces':[{'name':'voxstudio-local','root':root.read_text()}] if root.exists() else []}
elif args[:2]==['marketplace','remove']:root.unlink(missing_ok=True)
elif args[:2]==['marketplace','add']:
 if root.exists() and root.read_text()!=args[2]:raise RuntimeError('already added from a different source')
 root.write_text(args[2])
elif args[0]=='add':
 identity=args[1];name=identity.split('@')[0];folder=pathlib.Path(root.read_text());plugins=folder/('plugins' if (folder/'plugins').exists() else 'Plugins');manifest=json.loads((plugins/name/'plugin.json').read_text());state[identity]={'name':name,'pluginId':identity,'version':manifest['version'],'enabled':True}
elif args[0]=='remove':state.pop(args[1],None)
elif args[0]=='list':
 text=(home/'config.toml').read_text()
 for identity,row in state.items():
  match=re.search(r'\\[plugins\\."'+re.escape(identity)+r'"\\]\\s*\\nenabled = (true|false)',text)
  if match:row['enabled']=match[1]=='true'
file.write_text(json.dumps(state));print(json.dumps(output if output is not None else {'installed':list(state.values())}))
''');cli.chmod(0o755)
        return folder,home,str(cli)
    def test_all_previous_install_states_and_preferences(self):
        variants=[[],[('voxstudio',False)],[('voxstudio-knowledge',False)],[('voxstudio',False),('voxstudio-knowledge',True)]]
        for variant in variants:
            with self.subTest(variant=variant),tempfile.TemporaryDirectory() as tmp:
                folder,home,cli=self.fixture(Path(tmp),variant);os.environ['TEST_PLUGIN_HOME']=str(home)
                installer.migrate(folder,cli,home,verify=lambda:None)
                state=json.loads((home/'state.json').read_text())
                self.assertEqual(set(state),{installer.MAIN});self.assertEqual(state[installer.MAIN]['version'],PLUGIN_VERSION)
                if variant:self.assertFalse(state[installer.MAIN]['enabled'])
                else:self.assertIn('enabled = true',installer.section((home/'config.toml').read_text(),installer.MAIN))
                self.assertIn('value = "preserved"',(home/'config.toml').read_text())
                # An upgrade can be run again without losing the immutable rollback package.
                cache=home/'plugins/cache/voxstudio-local/voxstudio'/PLUGIN_VERSION;cache.mkdir(parents=True);(cache/'plugin.json').write_text(json.dumps({'name':'voxstudio','version':PLUGIN_VERSION}))
                backup=installer.migrate(folder,cli,home,verify=lambda:None)
                self.assertNotIn(installer.OLD,json.loads((backup/'state.json').read_text()))
                calls=0
                def verify():
                    nonlocal calls
                    calls+=1
                    if calls==2:raise RuntimeError('UI unavailable')
                with self.assertRaisesRegex(RuntimeError,'UI unavailable'):installer.migrate(folder,cli,home,verify)
                self.assertEqual(set(json.loads((home/'state.json').read_text())),{installer.MAIN})
    def test_failed_post_install_verification_restores_both(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder,home,cli=self.fixture(Path(tmp),[('voxstudio',False),('voxstudio-knowledge',True)]);os.environ['TEST_PLUGIN_HOME']=str(home)
            calls=0
            def verify():
                nonlocal calls
                calls+=1
                if calls==2:raise RuntimeError('UI unavailable')
            with self.assertRaisesRegex(RuntimeError,'UI unavailable'):installer.migrate(folder,cli,home,verify)
            state=json.loads((home/'state.json').read_text())
            self.assertEqual(state[installer.MAIN]['version'],'0.1.2');self.assertIn(installer.OLD,state)
            self.assertIn('permission = "preserve"',(home/'config.toml').read_text())
    def test_replaces_marketplace_and_recovers_omitted_legacy_install(self):
        with tempfile.TemporaryDirectory() as tmp:
            base=Path(tmp)
            folder,home,cli=self.fixture(base,[('voxstudio',True),('voxstudio-knowledge',False)])
            os.environ['TEST_PLUGIN_HOME']=str(home)
            # A mutable marketplace may omit Knowledge while its installed cache
            # and permission block still exist. Both must reach the rollback copy.
            state=json.loads((home/'state.json').read_text());state.pop(installer.OLD)
            (home/'state.json').write_text(json.dumps(state))
            (home/'marketplace.txt').write_text(str(base/'old-marketplace'))
            backup=installer.migrate(folder,cli,home,verify=lambda:None)
            self.assertEqual((home/'marketplace.txt').read_text(),str(folder))
            self.assertEqual(json.loads((home/'state.json').read_text())[installer.MAIN]['version'],PLUGIN_VERSION)
            snapshot=json.loads((backup/'state.json').read_text())
            self.assertFalse(snapshot[installer.OLD]['enabled'])
            self.assertTrue((backup/'plugins/voxstudio-knowledge/plugin.json').exists())
    def test_app_readiness_failure_has_no_mutations(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder,home,cli=self.fixture(Path(tmp),[]);os.environ['TEST_PLUGIN_HOME']=str(home)
            def fail():raise RuntimeError('not ready')
            with self.assertRaises(RuntimeError):installer.migrate(folder,cli,home,fail)
            self.assertFalse((home/'marketplace.txt').exists())
    def test_native_connection_is_independent_and_preserves_existing_policy(self):
        endpoint='http://127.0.0.1:19789/native/mcp'
        with tempfile.TemporaryDirectory() as tmp:
            home=Path(tmp);(home/'config.toml').write_text('[unrelated]\nvalue="kept"\n')
            existing=Mock(returncode=0,stdout=json.dumps({'enabled':False,'transport':{'type':'streamable_http','url':endpoint}}))
            with patch.object(installer.subprocess,'run',return_value=existing) as run:
                installer.configure_native('codex',home,verify=lambda:None)
                self.assertEqual(run.call_count,1)
            conflict=Mock(returncode=0,stdout=json.dumps({'transport':{'type':'streamable_http','url':'https://other.invalid/mcp'}}))
            with patch.object(installer.subprocess,'run',return_value=conflict) as run:
                with self.assertRaisesRegex(RuntimeError,'different endpoint'):installer.configure_native('codex',home,verify=lambda:None)
                self.assertEqual(run.call_count,1)
            missing=Mock(returncode=1,stderr="No MCP server named 'voxstudio_native' found.")
            with patch.object(installer.subprocess,'run',side_effect=[missing,Mock(returncode=0)]) as run:
                installer.configure_native('codex',home,verify=lambda:None)
                self.assertEqual(run.call_args_list[-1].args[0],['codex','mcp','add','voxstudio_native','--url',endpoint])
            self.assertEqual((home/'config.toml').read_text(),'[unrelated]\nvalue="kept"\n')
            self.assertEqual(len(list((home/'voxstudio-native-backups').glob('*/config.toml'))),1)
if __name__=='__main__':unittest.main()
