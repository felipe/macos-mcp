#!/usr/bin/env python3
"""Exercise `macos-mcp channel` against a temporary serve instance and temporary files only."""
import hashlib
import hmac
import http.server
import json
import os
import pathlib
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

binary = str(pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '.build/macos-mcp-unsigned').resolve())
SECRET = 'channel-smoke-secret'


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def wait_for(url):
    for _ in range(60):
        try:
            urllib.request.urlopen(url, timeout=1).close()
            return
        except OSError:
            time.sleep(.1)
    raise AssertionError(f'{url} never came up')


with tempfile.TemporaryDirectory(prefix='macos-mcp-channel-') as tmp:
    root = pathlib.Path(tmp)
    (root / 'note.md').write_text('Through the channel\n')
    policy = root / 'permissions.json'
    policy.write_text(json.dumps({'version': 1, 'tools': {'scoped_read': {'allow': True}}}))
    secret_file = root / 'secret'
    secret_file.write_text(SECRET + '\n')
    env = dict(os.environ, MACOS_MCP_PERMISSIONS_FILE=str(policy),
               ALLOWED_PATHS_JSON=json.dumps({'notes': str(root)}),
               ALLOWED_PATHS_AUDIT_LOG_PATH=str(root / 'audit.log'), OBSIDIAN_VAULT_PATH=str(root))
    serve_port, hook_port = free_port(), free_port()
    hook = f'http://127.0.0.1:{hook_port}'

    with (root / 'serve.log').open('w') as log:
        serve = subprocess.Popen([binary, 'serve', '--host', '127.0.0.1', '--port', str(serve_port)],
                                 env=env, stdout=log, stderr=log)
        channel = subprocess.Popen(
            [binary, 'channel', '--port', str(hook_port), '--mcp-url', f'http://127.0.0.1:{serve_port}/mcp',
             '--webhook-secret-file', str(secret_file), '--owner-name', 'Smoke', '--owner-phone', '+1 (555) 000-1111',
             '--log-file', str(root / 'channel.log')],
            env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True)
        try:
            wait_for(f'http://127.0.0.1:{serve_port}/health')
            wait_for(hook + '/health')

            def rpc(method, params=None, request_id=1):
                channel.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': request_id, 'method': method, 'params': params or {}}) + '\n')
                channel.stdin.flush()
                reply = json.loads(channel.stdout.readline())
                assert reply['id'] == request_id, reply
                return reply

            def post(body, signature):
                request = urllib.request.Request(hook + '/incoming', body,
                                                 headers={'Content-Type': 'application/json', 'X-Hub-Signature-256': signature})
                try:
                    with urllib.request.urlopen(request, timeout=5) as response:
                        return response.status
                except urllib.error.HTTPError as error:
                    return error.code

            # A text that lands before the session finishes its handshake is held, not lost:
            # the poller will not send it again.
            early = json.dumps({'event': 'imessage', 'from': '+15550001111', 'text': 'early'}).encode()
            assert post(early, 'sha256=' + hmac.new(SECRET.encode(), early, hashlib.sha256).hexdigest()) == 200

            # The session is told this server is a channel, and how to answer a text.
            init = rpc('initialize', {'protocolVersion': '2024-11-05', 'capabilities': {}})['result']
            assert init['capabilities']['experimental'] == {'claude/channel': {}}, init
            assert 'send_imessage' in init['instructions']
            channel.stdin.write(json.dumps({'jsonrpc': '2.0', 'method': 'notifications/initialized'}) + '\n')
            channel.stdin.flush()
            held = json.loads(channel.stdout.readline())
            assert held['method'] == 'notifications/claude/channel' and held['params']['content'] == 'early', held

            # Tools are the serve instance's tools, unchanged, and calls reach it.
            assert [t['name'] for t in rpc('tools/list')['result']['tools']] == ['scoped_read']
            read = rpc('tools/call', {'name': 'scoped_read', 'arguments': {'path_name': 'notes', 'path': 'note.md'}})['result']
            assert not read.get('isError') and 'Through the channel' in read['content'][0]['text'], read
            denied = rpc('tools/call', {'name': 'send_imessage', 'arguments': {'contact': '+15550000000', 'text': 'never sent'}})['result']
            assert denied.get('isError'), denied
            assert rpc('resources/list').get('error', {}).get('code') == -32601

            # Only a correctly signed webhook becomes a channel event; the text arrives as written.
            text = 'héllo\nsecond line'
            body = json.dumps({'event': 'imessage', 'from': '+15550001111', 'text': text,
                               'message_count': 2, 'rowids': [10, 11]}).encode()
            good = 'sha256=' + hmac.new(SECRET.encode(), body, hashlib.sha256).hexdigest()
            assert post(body, 'sha256=' + '0' * 64) == 401
            assert post(body, 'sha256=' + hmac.new(b'wrong', body, hashlib.sha256).hexdigest()) == 401
            assert post(b'{"event":"imessage"}', 'sha256=' + hmac.new(SECRET.encode(), b'{"event":"imessage"}', hashlib.sha256).hexdigest()) == 400
            assert post(body, good) == 200
            event = json.loads(channel.stdout.readline())
            assert event['method'] == 'notifications/claude/channel', event
            assert event['params']['content'] == text
            assert event['params']['meta'] == {'chat_id': '+15550001111', 'chat_type': 'direct', 'user': 'Smoke',
                                               'event': 'imessage', 'message_count': '2', 'rowid': '11'}, event

            # Only the owner's own number is called the owner; a group is marked as one.
            def deliver(sender):
                payload = json.dumps({'event': 'imessage', 'from': sender, 'text': 'hi'}).encode()
                assert post(payload, 'sha256=' + hmac.new(SECRET.encode(), payload, hashlib.sha256).hexdigest()) == 200
                return json.loads(channel.stdout.readline())['params']['meta']
            stranger = deliver('+15559998888')
            assert stranger['user'] == '+15559998888' and stranger['chat_type'] == 'direct', stranger
            group = deliver('chat123456789')
            assert group['user'] == 'chat123456789' and group['chat_type'] == 'group', group
            # An email handle is a direct chat and never the owner, whatever it looks like.
            for address in ('chat@example.com', '15550001111@example.com'):
                email = deliver(address)
                assert email['user'] == address and email['chat_type'] == 'direct', email

            # Bad framing is refused before the signature check and does not take the channel down.
            for length in ('-1', 'abc', str(64 * 1024 * 1024)):
                with socket.create_connection(('127.0.0.1', hook_port), timeout=5) as raw:
                    raw.sendall(f'POST /incoming HTTP/1.1\r\nContent-Length: {length}\r\n\r\n'.encode())
                    assert raw.recv(64).startswith(b'HTTP/1.1 400'), length
            urllib.request.urlopen(hook + '/health', timeout=2).close()

            # A dead serve instance is reported to the model as a tool error, not swallowed.
            serve.terminate()
            serve.wait(timeout=5)
            down = rpc('tools/call', {'name': 'scoped_read', 'arguments': {'path_name': 'notes', 'path': 'note.md'}})['result']
            assert down.get('isError') and 'unreachable' in down['content'][0]['text'], down

            # When the session goes away the channel exits and frees the webhook port.
            channel.stdin.close()
            assert channel.wait(timeout=5) == 0
            try:
                urllib.request.urlopen(hook + '/health', timeout=1)
                raise AssertionError('webhook port still answering after the session closed')
            except OSError:
                pass
        finally:
            for process in (channel, serve):
                if process.poll() is None:
                    process.kill()
    # A serve instance behind a bearer token gets the token on every forwarded request.
    token = 'smoke-token-' + '0123456789abcdef' * 2
    token_file = root / 'token'
    token_file.write_text(token + '\n')
    token_file.chmod(0o600)
    seen = []

    class Upstream(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            seen.append(self.headers.get('Authorization'))
            self.rfile.read(int(self.headers.get('Content-Length', 0)))
            reply = json.dumps({'jsonrpc': '2.0', 'id': 1, 'result': {'tools': []}}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(reply)))
            self.end_headers()
            self.wfile.write(reply)

        def log_message(self, *args):
            pass

    upstream = http.server.HTTPServer(('127.0.0.1', 0), Upstream)
    threading.Thread(target=upstream.serve_forever, daemon=True).start()
    with (root / 'token.log').open('w') as log:
        channel = subprocess.Popen(
            [binary, 'channel', '--port', str(free_port()), '--mcp-url', f'http://127.0.0.1:{upstream.server_port}/mcp',
             '--webhook-secret-file', str(secret_file), '--mcp-token-file', str(token_file)],
            env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True)
        try:
            channel.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'}) + '\n')
            channel.stdin.flush()
            assert json.loads(channel.stdout.readline())['result'] == {'tools': []}
            assert seen == [f'Bearer {token}'], seen
            channel.stdin.close()
            assert channel.wait(timeout=5) == 0
        finally:
            if channel.poll() is None:
                channel.kill()
            upstream.shutdown()
print('channel smoke passed')
