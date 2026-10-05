"""Verify completion continuations and audition an existing local TTS result in Docker."""
import argparse
import json
from pathlib import Path

from check_mcp_profiles import call, rpc


def check(base):
    core = '/chatgpt/mcp'
    status, _, session = rpc(base, core, 'initialize', {
        'protocolVersion': '2025-06-18', 'capabilities': {},
        'clientInfo': {'name': 'voxstudio-completed-media-verification', 'version': '1'},
    })
    assert status == 200 and session
    listed = call(base, core, 'voxstudio.sessions', {}, session)['result']
    assert not listed.get('isError'), listed
    rows = listed['structuredContent']['sessions']
    report = {'transcription': 'no-existing-completed-local-result',
              'dubbing': 'no-existing-completed-local-result'}
    for kind in report:
        for row in rows:
            if row['kind'] != kind or row['status'] != 'completed' or row.get('remote_only'):
                continue
            result = call(base, core, 'media.status', {'session_id': row['session_id']}, session)['result']
            if result.get('isError'):
                continue
            value = result['structuredContent']
            if value['status'] != 'completed':
                continue
            next_call = value['next_call']
            assert next_call['tool'] == ('fetch' if kind == 'transcription' else 'media.session_preview')
            if kind == 'dubbing':
                preview = call(base, core, next_call['tool'], {
                    **next_call['arguments'], 'duration': 1,
                }, session)['result']
                assert not preview.get('isError'), preview
                uri = preview['structuredContent']['preview_resource_uri']
                status, resource, _ = rpc(base, core, 'resources/read', {'uri': uri}, session)
                assert status == 200 and resource['result']['contents'][0]['blob']
                _, denied, _ = rpc(base, '/native/mcp', 'resources/read', {'uri': uri})
                assert 'error' in denied, 'TTS preview grant leaked to native'
                report[kind] = 'verified-next-call-audio-resource-and-grant-isolation'
            else:
                report[kind] = 'verified-completed-transcription-next-call'
            break
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--base', default='http://host.docker.internal:19789')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    report = check(args.base)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
