#!/usr/bin/env bash
set -euo pipefail
# Synthetic local mail only: this script never launches Mail.app or performs actions.
BINARY="${1:-.build/macos-mcp-unsigned}"
PORT="${PORT:-19327}"
TMP_DIR="$(mktemp -d /tmp/macos-mcp-mail.XXXXXX)"
cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT
export MAIL_DATA_DIR="$TMP_DIR/V10"
export MACOS_MAIL_ACCOUNTS_JSON='{"work":{"id":"test-account","email":"me@example.test"}}'
export MACOS_MCP_PERMISSIONS_FILE="$TMP_DIR/permissions.json"
# Enable schemas for validation checks; no valid action calls are made.
python3 - <<'POLICY'
import json,os
names = ['mail_search','mail_read','mail_list_mailboxes','mail_send','mail_draft','mail_reply','mail_forward','mail_move','mail_flag']
names += ['mail_capabilities','mail_account_list','mail_mailbox_list','mail_envelope_list','mail_envelope_search','mail_message_read','mail_attachment_list','list_emails','search_emails','read_email','read_email_html','list_folders','compose_email']
with open(os.environ['MACOS_MCP_PERMISSIONS_FILE'],'w') as f: json.dump({'version':1,'tools':{name:{'allow':True} for name in names}},f)
POLICY
python3 - <<'PY'
import os,sqlite3,pathlib
root=pathlib.Path(os.environ['MAIL_DATA_DIR']); (root/'MailData').mkdir(parents=True)
c=sqlite3.connect(root/'MailData/Envelope Index')
c.executescript('''
CREATE TABLE messages (ROWID INTEGER PRIMARY KEY,message_id INTEGER,global_message_id INTEGER,document_id TEXT,sender INTEGER,subject INTEGER,date_received INTEGER,date_sent INTEGER,mailbox INTEGER,read INTEGER,flagged INTEGER,deleted INTEGER);
CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY,subject TEXT);
CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY,address TEXT,comment TEXT);
CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY,url TEXT);
CREATE TABLE recipients (message INTEGER,address INTEGER,type INTEGER,position INTEGER);
CREATE TABLE message_global_data (ROWID INTEGER PRIMARY KEY,message_id INTEGER,message_id_header TEXT);
INSERT INTO subjects VALUES(1,'Smoke invoice');
INSERT INTO addresses VALUES(1,'sender@example.test','Sender'),(2,'recipient@example.test','Recipient');
INSERT INTO mailboxes VALUES(1,'imap://test-account/INBOX');
INSERT INTO messages VALUES(42,420,7,'42',1,1,1700000000,1700000000,1,0,1,0);
INSERT INTO recipients VALUES(42,2,0,0);
INSERT INTO message_global_data VALUES(7,420,'<smoke@example.test>');
'''); c.commit();c.close()
p=root/'test-account/INBOX.mbox/Data/0/0/Messages';p.mkdir(parents=True)
raw=b'From: sender@example.test\r\nTo: recipient@example.test\r\nSubject: Smoke invoice\r\nMessage-ID: <smoke@example.test>\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nSynthetic mail body.'
(p/'42.emlx').write_bytes(str(len(raw)).encode()+b'\n'+raw+b'\n<plist/>')
PY
"$BINARY" mail search invoice --recipient recipient@example.test > "$TMP_DIR/search.json"
python3 - "$TMP_DIR/search.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]));assert len(r['messages'])==1,r;assert r['messages'][0]['rowid']==42,r
PY
"$BINARY" mail mailboxes > "$TMP_DIR/mailboxes.json"
python3 - "$TMP_DIR/mailboxes.json" <<'PY'
import json,sys
assert len(json.load(open(sys.argv[1]))['mailboxes'])==1
PY
"$BINARY" mail read 42 > "$TMP_DIR/read.json"
python3 - "$TMP_DIR/read.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]));assert r['body']=='Synthetic mail body.',r
PY
"$BINARY" serve --host 127.0.0.1 --port "$PORT" --mcp-secret mail-smoke > "$TMP_DIR/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null; then break; fi
  sleep 0.25
done
python3 - "$PORT" <<'PY'
import json,sys,urllib.request,os
url='http://127.0.0.1:'+sys.argv[1]+'/mcp'
def rpc(method,params):
 data=json.dumps(dict(jsonrpc='2.0',id=1,method=method,params=params)).encode()
 req=urllib.request.Request(url,data,headers={'Content-Type':'application/json','Accept':'text/event-stream','Authorization':'Bearer mail-smoke'})
 with urllib.request.urlopen(req) as r: lines=r.read().decode().splitlines()
 return json.loads([x[6:] for x in lines if x.startswith('data: ')][-1])['result']
names={x['name'] for x in rpc('tools/list',{})['tools']}
expected={'mail_search','mail_read','mail_list_mailboxes','mail_send','mail_draft','mail_reply','mail_forward','mail_move','mail_flag'}
assert expected<=names,names
for name,args,key in [('mail_search',{'query':'invoice'},'messages'),('mail_read',{'rowid':42},'body'),('mail_list_mailboxes',{},'mailboxes')]:
 r=rpc('tools/call',{'name':name,'arguments':args});assert not r.get('isError'),r
 result=json.loads(r['content'][0]['text']);assert key in result,result
# Invalid action requests stop in validation, before Mail.app can launch.
for name,args in [('mail_send',{'to':'bad'}),('mail_flag',{'rowid':42,'read':'false'}),('mail_read',{'rowid':42,'message_id':'x'})]:
 r=rpc('tools/call',{'name':name,'arguments':args});assert r.get('isError') is True,r
def call(name,args):
 return rpc('tools/call',{'name':name,'arguments':args})
cap=call('mail_capabilities',{})
assert json.loads(cap['content'][0]['text'])['compatibility']['version']=='2.1.2',cap
envelopes=json.loads(call('mail_envelope_list',{'account':'work','page_size':1})['content'][0]['text'])
assert envelopes['has_more'] is False,envelopes
identifier=envelopes['envelopes'][0]['id']
assert identifier.startswith('am1.'),identifier
assert 'rowid' not in envelopes['envelopes'][0],envelopes
r=call('read_email',{'account':'work','id':identifier})
assert not r.get('isError') and r['content'][0]['text']=='Synthetic mail body.',r
r=call('list_emails',{'account':'work'})
assert r['content'][0]['text'].startswith('Found 1 emails:'),r
r=call('list_emails',{'account':'work','page':2})
assert r['content'][0]['text']=='Found 0 emails:\n\n',r
r=call('search_emails',{'account':'work','query':'subject invoice and flag Flagged'})
assert 'Found 1 emails matching' in r['content'][0]['text'],r
r=call('search_emails',{'account':'work','query':'body invoice'})
assert r.get('isError') and json.loads(r['content'][0]['text'])['error']['recoverable'] is False,r
r=call('read_email',{'account':'work','id':'42'})
assert r.get('isError'),r
compose={'account':'work','to':'you@example.test','subject':'Fixture preview','body':'Never sent'}
r=call('compose_email',compose)
assert not r.get('isError') and 'not sent' in r['content'][0]['text'],r
# Neither aliases nor native mutations inherit another tool's grant.
for name,args in [('flag_email',{'account':'work','id':identifier,'flags':['Seen'],'action':'add'}),
                  ('mail_message_send',{'account':'work','to':['you@example.test'],'subject':'No send','body':'No send','confirm':True})]:
 r=call(name,args);assert r.get('isError'),r
# Revoke the preview tool, then prove even a confirmed call cannot bypass policy.
with open(os.environ['MACOS_MCP_PERMISSIONS_FILE']) as f: policy=json.load(f)
policy['tools']['compose_email']['allow']=False
with open(os.environ['MACOS_MCP_PERMISSIONS_FILE'],'w') as f: json.dump(policy,f)
r=call('compose_email',dict(compose,confirm=True));assert r.get('isError'),r
assert 'compose_email' not in {x['name'] for x in rpc('tools/list',{})['tools']}
print('PASS: legacy Mail CLI/MCP; v1 envelopes and opaque IDs; Himalaya text, search, previews; mutation denial and policy reload')
PY
