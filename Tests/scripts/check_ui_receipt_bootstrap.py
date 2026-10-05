"""Verify resource bootstrap against each live local MCP profile in Docker."""
import json
import re
import sys
from check_mcp_profiles import rpc

base = sys.argv[1]
for path in ('/app/mcp', '/chatgpt/mcp', '/native/mcp'):
    status, _, session = rpc(base, path, 'initialize', {
        'protocolVersion': '2025-06-18', 'capabilities': {},
        'clientInfo': {'name': 'receipt-bootstrap-regression', 'version': '1'},
    })
    assert status == 200 and session
    _, catalog, _ = rpc(base, path, 'tools/list', session=session)
    tools = catalog['result']['tools']
    expected = {tool['name'] for tool in tools if tool.get('annotations', {}).get('readOnlyHint') is not True}
    _, resources, _ = rpc(base, path, 'resources/list', session=session)
    count = 0
    for resource in resources['result']['resources']:
        if not resource['uri'].startswith('ui://'):
            continue
        _, body, _ = rpc(base, path, 'resources/read', {'uri': resource['uri']}, session)
        html = body['result']['contents'][0]['text']
        match = re.search(r'window\.__voxstudioReceiptTools=(\[.*?\]);</script>', html)
        assert match, (path, resource['uri'], 'missing bootstrap')
        assert html.count('window.__voxstudioReceiptTools=') == 1, 'bootstrap must never alter script literals'
        assert set(json.loads(match[1])) == expected, (path, 'catalog mismatch')
        assert html.index(match[0]) < html.index('VoxStudio · Loading'), 'bootstrap must precede bundle'
        count += 1
    assert count > 0
    print(json.dumps({'profile': path, 'panels_verified': count, 'receipt_tools': len(expected)}))
