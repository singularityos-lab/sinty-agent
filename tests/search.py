import json, os, socket, subprocess, sys, tempfile, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BIN = sys.argv[1]
home = tempfile.mkdtemp()
CONCEPTS = [
    {"invoice", "bill", "fattura", "bolletta", "electricity", "power", "luce"},
    {"holiday", "trip", "vacanza", "viaggio", "flight", "hotel"},
    {"recipe", "pasta", "cook", "ricetta"},
]
seen = []

def vector(text):
    words = {w.strip(".,:;!?").lower() for w in text.split()}
    v = [float(len(words & c)) for c in CONCEPTS]
    return v + [0.01]

class Fake(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        seen.append((self.path, body["model"], len(body["input"])))
        data = json.dumps({"model": body["model"], "embeddings": [vector(t) for t in body["input"]]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *a):
        pass

docs = os.path.join(home, "Documents")
os.makedirs(os.path.join(docs, "casa"))
open(os.path.join(docs, "casa", "ottobre.txt"), "w").write("Electricity invoice for October, 84 euro to pay by the 30th.")
open(os.path.join(docs, "summer.md"), "w").write("Flight to Lisbon and the hotel near the river.")
open(os.path.join(docs, "carbonara.txt"), "w").write("Pasta, eggs, pecorino, guanciale: cook the pasta al dente.")
open(os.path.join(docs, ".hidden.txt"), "w").write("invoice invoice invoice")
open(os.path.join(home, "user-dirs.dirs"), "w").write('XDG_DOCUMENTS_DIR="$HOME/Documents"\n')
os.makedirs(os.path.join(home, "sinty-agent"), exist_ok=True)
env = dict(os.environ, XDG_DATA_HOME=home, XDG_CONFIG_HOME=home, XDG_CACHE_HOME=home, XDG_STATE_HOME=home, HOME=home)
fails = []
def check(label, ok, extra=""):
    print(("ok   " if ok else "FAIL ") + label + (" " + str(extra)[:300] if not ok else ""), flush=True)
    if not ok:
        fails.append(label)

d = subprocess.Popen([BIN + "/sinty-agentd"], env=env)
time.sleep(1)
s = socket.socket(socket.AF_UNIX)
s.connect(os.environ["XDG_RUNTIME_DIR"] + "/sinty-agent/mcp.sock")
fh = s.makefile("rw")
def tool(name, **k):
    fh.write(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": name, "arguments": k}}) + "\n")
    fh.flush()
    r = json.loads(fh.readline())["result"]
    return r["isError"], r["content"][0]["text"]

e, t = tool("files_search", query="electricity")
r = json.loads(t)
check("without a model it searches by words", not e and r["by"] == "words" and r["results"][0]["name"] == "ottobre.txt", t)
check("hidden files stay out", all(".hidden" not in x["path"] for x in r["results"]), t)
check("a snippet shows where it matched", "Electricity invoice" in r["results"][0]["snippet"], t)
e, t = tool("files_search", query="bolletta della luce")
check("other words find nothing by words alone", not e and not any(x["name"] == "ottobre.txt" for x in json.loads(t)["results"]), t)

server = ThreadingHTTPServer(("127.0.0.1", 11434), Fake)
threading.Thread(target=server.serve_forever, daemon=True).start()
e, t = tool("files_search", query="bolletta della luce")
r = json.loads(t)
check("with a local model it finds the bill by meaning", not e and r["by"] == "meaning" and r["results"][0]["name"] == "ottobre.txt", t)
e, t = tool("files_search", query="vacanza")
r = json.loads(t)
check("and the trip by meaning", r["results"][0]["name"] == "summer.md", t)
calls = len(seen)
e, t = tool("files_search", query="ricetta")
check("files already read are not embedded again", len(seen) == calls + 1 and json.loads(t)["results"][0]["name"] == "carbonara.txt", (seen, t))
check("the default embedding model is used", all(m == "nomic-embed-text" for _, m, _ in seen), seen)
e, t = tool("files_search", query="x", folder="/etc")
check("it refuses folders outside the home", e, t)
e, t = tool("files_search", query="invoice", folder="~/Documents/casa", limit=1)
r = json.loads(t)
check("one folder and a limit", not e and len(r["results"]) == 1 and r["searched"] == 1, t)
server.shutdown()
d.terminate()
print("FAILS", len(fails))
sys.exit(1 if fails else 0)
