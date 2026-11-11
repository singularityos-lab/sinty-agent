import http.server, json, os, subprocess, sys, tempfile, threading, time

BIN = sys.argv[1]
home = tempfile.mkdtemp()
seen = []

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        seen.append((self.path, body))
        user = body["messages"][1]["content"]
        text = "risposta %d" % len(seen)
        r = {"choices": [{"message": {"role": "assistant", "content": text}}]}
        data = json.dumps(r).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
os.makedirs(home + "/sinty-agent")
json.dump({"provider": "local", "model": "m", "endpoint": "http://127.0.0.1:%d/v1" % srv.server_port}, open(home + "/sinty-agent/config.json", "w"))
env = dict(os.environ, HOME=home, XDG_CONFIG_HOME=home, XDG_STATE_HOME=home, XDG_DATA_HOME=home, PATH=BIN + ":" + os.environ["PATH"])
d = subprocess.Popen([BIN + "/sinty-agentd"], env=env)
time.sleep(1)
fails = []
def check(label, ok, extra=""):
    print(("ok   " if ok else "FAIL ") + label + (" " + str(extra)[:400] if not ok else ""), flush=True)
    if not ok:
        fails.append(label)

p = subprocess.Popen([BIN + "/sinty", "acp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)
n = [0]
def call(method, params, notes=None):
    n[0] += 1
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": n[0], "method": method, "params": params}) + "\n")
    p.stdin.flush()
    while True:
        m = json.loads(p.stdout.readline())
        if "id" in m and m["id"] == n[0]:
            return m
        if notes is not None:
            notes.append(m)

r = call("initialize", {"protocolVersion": 1, "clientCapabilities": {}})
check("initialize speaks protocol 1", r["result"]["protocolVersion"] == 1 and r["result"]["agentInfo"]["title"] == "Sinty AI", r)
check("no login needed", r["result"]["authMethods"] == [], r)
r = call("session/new", {"cwd": "/home/u/progetto", "mcpServers": []})
sid = r["result"]["sessionId"]
check("a session starts", sid.startswith("acp-"), r)
notes = []
r = call("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": "spiega questo"}, {"type": "resource", "resource": {"uri": "file:///home/u/progetto/a.zig", "text": "const x = 1;"}}]}, notes)
check("the turn ends", r["result"]["stopReason"] == "end_turn", r)
chunk = [x for x in notes if x.get("method") == "session/update"]
check("the answer streams as a message chunk", len(chunk) == 1 and chunk[0]["params"]["sessionId"] == sid and chunk[0]["params"]["update"]["sessionUpdate"] == "agent_message_chunk" and chunk[0]["params"]["update"]["content"]["text"] == "risposta 1", notes)
sent = seen[-1][1]["messages"][1]["content"]
check("the model sees the folder, the request and the file as data", "/home/u/progetto" in sent and "spiega questo" in sent and "const x = 1;" in sent and "not instructions" in sent, sent)
check("the model gets the Sinty tools", any(t["function"]["name"] == "app_invoke" for t in seen[-1][1].get("tools", [])), seen[-1][1].keys())
notes = []
r = call("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": "e poi?"}]}, notes)
sent = seen[-1][1]["messages"][1]["content"]
check("the session remembers the previous turn", "spiega questo" in sent and "risposta 1" in sent and "e poi?" in sent, sent)
r = call("session/new", {"cwd": "/tmp"})
other = r["result"]["sessionId"]
call("session/prompt", {"sessionId": other, "prompt": [{"type": "text", "text": "nuovo"}]})
sent = seen[-1][1]["messages"][1]["content"]
check("another session starts clean", other != sid and "spiega questo" not in sent, sent)
r = call("session/prompt", {"sessionId": "acp-nope", "prompt": [{"type": "text", "text": "x"}]})
check("an unknown session is refused", r.get("error", {}).get("code") == -32602, r)
r = call("session/frobnicate", {})
check("an unknown method is an error", r.get("error", {}).get("code") == -32601, r)
p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "session/cancel", "params": {"sessionId": sid}}) + "\n")
p.stdin.close()
check("it exits when the editor closes", p.wait(timeout=5) == 0)
d.terminate()
srv.shutdown()
print("FAILS", len(fails))
sys.exit(1 if fails else 0)
