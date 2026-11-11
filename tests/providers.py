import http.server, json, os, stat, subprocess, sys, tempfile, threading, time

BIN = sys.argv[1]
home = tempfile.mkdtemp()
fake = home + "/bin"
os.makedirs(fake)
os.makedirs(home + "/artifacts")
seen = []

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        seen.append((self.path, dict(self.headers), body))
        if self.path == "/v1/messages":
            done = any(isinstance(m["content"], list) and m["role"] == "user" for m in body["messages"])
            r = {"content": [{"type": "text", "text": "fatto api"}]} if done else {"content": [{"type": "tool_use", "id": "t1", "name": "agent_status", "input": {}}]}
        else:
            done = any(m["role"] == "tool" for m in body["messages"])
            r = {"message": {"role": "assistant", "content": "fatto ollama"}} if done else {"message": {"role": "assistant", "content": "", "tool_calls": [{"function": {"name": "agent_status", "arguments": {}}}]}}
        data = json.dumps(r).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
url = "http://127.0.0.1:%d" % srv.server_port
env = dict(os.environ, HOME=home, SINTY_AGENT_API_KEY="k-test", SINTY_AGENT_BRIDGE=BIN + "/sinty-agent-bridge", PATH=BIN + ":" + fake + ":" + os.environ["PATH"], XDG_CONFIG_HOME=home)
d = subprocess.Popen([BIN + "/sinty-agentd"], env=env)
time.sleep(1)
fails = []
def check(label, ok, extra=""):
    print(("ok   " if ok else "FAIL ") + label + (" " + str(extra)[:400] if not ok else ""), flush=True)
    if not ok:
        fails.append(label)
def ask(*a, e=env):
    return subprocess.run([BIN + "/sinty", "ask", *a], capture_output=True, text=True, timeout=30, env=e)

r = ask("--provider", "claude-api", "--endpoint", url, "come stai")
check("claude api answers", r.stdout.strip() == "fatto api", r.stdout + r.stderr)
p, h, b = seen[0]
check("claude api key", h.get("x-api-key") == "k-test")
check("claude api sends tools", any(t["name"] == "app_invoke" for t in b["tools"]))
check("tool result returned", any("mode" in json.dumps(m) for m in seen[-1][2]["messages"]))
seen.clear()
r = ask("--provider", "ollama", "--model", "m", "--endpoint", url, "ciao")
check("ollama answers", r.stdout.strip() == "fatto ollama", r.stdout + r.stderr)
check("ollama bearer", seen[0][1].get("Authorization") == "Bearer k-test")
r = ask("--provider", "ollama", "--endpoint", url, "ciao")
check("ollama needs a model", r.returncode != 0 and "model" in r.stderr, r.stderr)
r = ask("--provider", "claude-api", "--endpoint", "http://127.0.0.1:1", "ciao")
check("dead endpoint fails", r.returncode != 0)
e2 = dict(env)
del e2["SINTY_AGENT_API_KEY"]

def script(name, body):
    p = fake + "/" + name
    open(p, "w").write("#!/bin/sh\n" + body)
    os.chmod(p, 0o755)

script("claude", 'printf "%s\\n" "$@" > "$HOME/claude.argv"\necho claude-ok\n')
r = ask("--provider", "claude-code", "ciao")
argv = open(home + "/claude.argv").read()
check("claude code runs", "claude-ok" in r.stdout, r.stdout + r.stderr)
check("claude code gets the server", '"sinty-agent"' in argv and "mcp__sinty" in argv, argv)
open(fake + "/codex", "w").write("""#!/usr/bin/env python3
import json, os, sys
open(os.environ["HOME"] + "/codex.argv", "w").write("\\n".join(sys.argv[1:]))
log = open(os.environ["HOME"] + "/codex.log", "w")
def send(v):
    sys.stdout.write(json.dumps(v) + "\\n")
    sys.stdout.flush()
for line in sys.stdin:
    m = json.loads(line)
    log.write(line)
    log.flush()
    if m.get("method") == "initialize":
        send({"id": m["id"], "result": {}})
    elif m.get("method") == "thread/start":
        send({"id": m["id"], "result": {"thread": {"id": "th1"}}})
    elif m.get("method") == "turn/start":
        send({"id": 90, "method": "item/tool/call", "params": {"tool": "agent_status", "arguments": {}}})
    elif m.get("id") == 90:
        text = m["result"]["contentItems"][0]["text"]
        send({"method": "item/completed", "params": {"item": {"type": "agentMessage", "text": "codex-ok " + json.loads(text)["mode"]}}})
        send({"method": "turn/completed", "params": {"turn": {"status": "completed"}}})
""")
os.chmod(fake + "/codex", 0o755)
r = ask("--provider", "codex", "ciao")
argv = open(home + "/codex.argv").read()
sent = [json.loads(x) for x in open(home + "/codex.log")]
start = next(x for x in sent if x.get("method") == "thread/start")["params"]
check("codex runs app-server", r.stdout.strip() == "codex-ok ask" and argv.startswith("app-server"), r.stdout + r.stderr + argv)
check("codex gets only Sinty tools, read-only, no approvals", start["sandbox"] == "read-only" and start["approvalPolicy"] == "never" and any(t["name"] == "app_invoke" for t in start["dynamicTools"]), start.keys())

os.remove(fake + "/claude")
script("dsh", 'shift\nexport PATH="$HOME/guest:$PATH"\nexec sh -c "$1"\n')
os.makedirs(home + "/guest")
open(home + "/guest/claude", "w").write('#!/bin/sh\nprintf "%s\\n" "$@" > "$HOME/guest.argv"\necho guest-ok\n')
os.chmod(home + "/guest/claude", 0o755)
r = ask("--provider", "claude-code", "ciao")
argv = open(home + "/guest.argv").read()
check("claude code in dsh", "guest-ok" in r.stdout and "artifacts/.sinty-agent/bridge" in argv, r.stdout + r.stderr + argv)
b = home + "/artifacts/.sinty-agent"
check("bridge private", stat.S_IMODE(os.stat(b).st_mode) == 0o700 and stat.S_IMODE(os.stat(b + "/mcp.sock").st_mode) == 0o600)
line = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}}) + "\n"
pr = subprocess.Popen([b + "/bridge", b + "/mcp.sock"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
pr.stdin.write(line)
pr.stdin.flush()
check("bridge reaches the daemon", "sinty-agent" in pr.stdout.readline())
pr.kill()
d.terminate()
print("providers=%d" % len(fails))
sys.exit(1 if fails else 0)
