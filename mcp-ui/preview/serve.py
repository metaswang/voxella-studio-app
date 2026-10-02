"""Loopback development host for real MCP reads and explicit fixture tests."""
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import argparse
import http.client
import json
ROOT = Path(__file__).resolve().parents[2]
READ_TOOLS = {
    'app_workbench', 'voxstudio.library', 'voxstudio.sessions',
    'app_session', 'voxstudio.session_panel', 'app_transcription', 'app_dubbing',
    'voice.list', 'media.status', 'session.editor.read', 'documents.read',
    'search_mentions', 'media.preview', 'media.session_preview',
}
class Handler(SimpleHTTPRequestHandler):
    def accepts_origin(self):
        host = self.headers.get('Host')
        allowed = {f'127.0.0.1:{self.server.server_port}', f'localhost:{self.server.server_port}'}
        origin = self.headers.get('Origin')
        return host in allowed and (not origin or origin == f'http://{host}')
    def do_DELETE(self):
        if self.path != '/mcp' or not self.headers.get('Mcp-Session-Id'):
            self.send_error(400)
            return
        if not self.accepts_origin():
            self.send_error(403)
            return
        upstream = http.client.HTTPConnection('127.0.0.1', 19789, timeout=5)
        try:
            upstream.request('DELETE', '/mcp', headers={'Mcp-Session-Id': self.headers['Mcp-Session-Id']})
            response = upstream.getresponse()
            response.read()
            self.send_response(response.status)
            self.end_headers()
        except OSError:
            self.send_response(502)
            self.end_headers()
        finally:
            upstream.close()
    def do_POST(self):
        if self.path != '/mcp':
            self.send_error(404)
            return
        if not self.accepts_origin():
            self.send_error(403)
            return
        upstream = None
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 < length <= 1024 * 1024:
                raise ValueError('Invalid request size')
            body = self.rfile.read(length)
            request = json.loads(body)
            if not isinstance(request, dict) or not isinstance(request.get('params', {}), dict):
                raise ValueError('Invalid JSON-RPC request')
            method = request.get('method')
            if method not in {'initialize', 'notifications/initialized', 'tools/list', 'tools/call', 'resources/list', 'resources/read'}:
                raise ValueError('This local preview supports read-only MCP requests.')
            if method == 'tools/call' and request.get('params', {}).get('name') not in READ_TOOLS:
                raise ValueError('This local preview is read-only. Create and edit in the ChatGPT/Codex plugin.')
            headers = {'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream'}
            for key in ('Mcp-Session-Id', 'MCP-Protocol-Version'):
                if self.headers.get(key):
                    headers[key] = self.headers[key]
            upstream = http.client.HTTPConnection('127.0.0.1', 19789, timeout=15)
            upstream.request('POST', '/mcp', body, headers)
            response = upstream.getresponse()
            content = response.read()
            self.send_response(response.status)
            self.send_header('Content-Type', response.getheader('Content-Type', 'application/json'))
            if response.getheader('Mcp-Session-Id'):
                self.send_header('Mcp-Session-Id', response.getheader('Mcp-Session-Id'))
            self.end_headers()
            self.wfile.write(content)
        except (ValueError, OSError, http.client.HTTPException) as error:
            data = json.dumps({'error': str(error)}).encode()
            self.send_response(400 if isinstance(error, ValueError) else 502)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(data)
        finally:
            if upstream:
                upstream.close()
    def translate_path(self, path):
        relative = path.split('?', 1)[0].lstrip('/')
        if relative.startswith('panels/'):
            return str(ROOT / 'Sources/VoxstudioPro/Resources/MCPApps' / Path(relative).name)
        return str(ROOT / 'mcp-ui/preview' / (Path(relative).name or 'index.html'))
    def end_headers(self):
        self.send_header('Cache-Control','no-store')
        super().end_headers()
if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('--port',type=int,default=19790)
    ThreadingHTTPServer(('127.0.0.1',parser.parse_args().port),Handler).serve_forever()
