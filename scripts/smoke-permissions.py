#!/usr/bin/env python3
"""Exercise the real MCP permission boundary against temporary files only."""
import json
import os
import pathlib
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

binary = str(pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '.build/macos-mcp-unsigned').resolve())
with tempfile.TemporaryDirectory(prefix='macos-mcp-permissions-') as tmp:
    root = pathlib.Path(tmp)
    policy = root / 'permissions.json'
    (root / 'approved').mkdir()
    target = root / 'approved/note.md'
    target.write_text('Original\n')
    (root / 'outside').mkdir()
    (root / 'approved/link').symlink_to(root / 'outside', target_is_directory=True)
    def set_policy(tools):
        pending = root / 'pending.json'
        pending.write_text(json.dumps({'version': 1, 'tools': tools}))
        pending.replace(policy)
    set_policy({'scoped_read': {'allow': True}})
    env = dict(os.environ, MACOS_MCP_PERMISSIONS_FILE=str(policy),
               ALLOWED_PATHS_JSON=json.dumps({'notes': str(root), 'other': str(root)}),
               ALLOWED_PATHS_AUDIT_LOG_PATH=str(root / 'audit.log'), OBSIDIAN_VAULT_PATH=str(root))
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    base = f'http://127.0.0.1:{port}'
    def rpc(method, params):
        request = urllib.request.Request(base + '/mcp', json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}).encode(),
                                         headers={'Content-Type': 'application/json', 'Authorization': 'Bearer permissions-smoke', 'Accept': 'text/event-stream'})
        with urllib.request.urlopen(request, timeout=8) as response:
            lines = response.read().decode().splitlines()
        return json.loads([line[6:] for line in lines if line.startswith('data: ')][-1])['result']
    def call(name, arguments, denied=False):
        result = rpc('tools/call', {'name': name, 'arguments': arguments})
        assert bool(result.get('isError')) == denied, result
        return json.loads(result['content'][0]['text'])
    with (root / 'server.log').open('w') as log:
        process = subprocess.Popen([binary, 'serve', '--host', '127.0.0.1', '--port', str(port), '--mcp-secret', 'permissions-smoke'], env=env, stdout=log, stderr=log)
        try:
            for _ in range(60):
                try:
                    urllib.request.urlopen(base + '/health', timeout=1).close()
                    break
                except OSError:
                    time.sleep(.1)
            example = pathlib.Path(__file__).resolve().parent.parent / 'examples/permissions.json'
            policy.write_bytes(example.read_bytes())
            visible = {t['name'] for t in rpc('tools/list', {})['tools']}
            assert 'mail_read' in visible and 'scoped_read' in visible
            assert not visible.intersection({'mail_send', 'scoped_write', 'vault_write', 'download_file'})
            set_policy({'scoped_read': {'allow': True}})
            assert {t['name'] for t in rpc('tools/list', {})['tools']} == {'scoped_read'}
            write = {'path_name': 'notes', 'path': 'approved/note.md', 'mode': 'upsert', 'content': 'Changed'}
            call('scoped_write', write, denied=True)
            call('notes_search', {'query': 'never invoke Automation'}, denied=True)
            call('mail_send', {}, denied=True)
            call('download_file', {'url': 'http://127.0.0.1:1/never-contact'}, denied=True)
            assert target.read_text() == 'Original\n'
            # Grant only append operations under one named root and subtree.
            set_policy({'scoped_write': {'allow': True, 'path_names': ['notes'], 'modes': ['append-section'], 'paths': ['approved']}})
            call('scoped_write', write, denied=True)
            append = dict(write, mode='append-section', section_anchor='note-1', section_heading='Note')
            call('scoped_write', dict(append, path_name='other'), denied=True)
            call('scoped_write', dict(append, path='approved/link/escape.md'), denied=True)
            call('scoped_write', append)
            assert 'Changed' in target.read_text()
            assert not (root / 'outside/escape.md').exists()
            # Broad grants still cannot rewrite the policy or aliases to it.
            set_policy({'scoped_write': {'allow': True}, 'vault_write': {'allow': True}})
            (root / 'alias').symlink_to(policy)
            os.link(policy, root / 'hardlink')
            before = policy.read_bytes()
            for path in ['permissions.json', ' permissions.json ', 'alias', 'hardlink']:
                call('scoped_write', dict(write, path_name=' notes ', path=path), denied=True)
            call('vault_write', {'path': 'alias', 'content': '{}'}, denied=True)
            assert policy.read_bytes() == before
            original_content = target.read_text()
            audit = root / 'audit.log'
            audit.unlink()
            audit.symlink_to(policy)
            call('scoped_write', write, denied=True)
            audit.unlink()
            (root / 'audit.log.1').symlink_to(policy)
            call('scoped_write', write, denied=True)
            assert policy.read_bytes() == before and target.read_text() == original_content
            # Revocation is immediate and malformed/deleted policy never permits a call.
            set_policy({})
            assert rpc('tools/list', {})['tools'] == []
            call('scoped_write', write, denied=True)
            policy.write_text('{broken')
            assert rpc('tools/list', {})['tools'] == []
            call('scoped_read', {'path_name': 'notes', 'path': 'approved/note.md'}, denied=True)
            policy.unlink()
            call('scoped_read', {'path_name': 'notes', 'path': 'approved/note.md'}, denied=True)
            print('PASS: tool discovery/call enforcement, in-process denials, write scopes/modes, symlink escape, policy self-protection, live revocation, invalid/missing policy')
        finally:
            process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
