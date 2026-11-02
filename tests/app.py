import json, os, socket, subprocess, sys, tempfile, time
from gi.repository import Gio, GLib

BIN, EXE, APP = sys.argv[1:4]
home = tempfile.mkdtemp()
env = dict(os.environ, XDG_DATA_HOME=home, XDG_CONFIG_HOME=home, XDG_CACHE_HOME=home, XDG_STATE_HOME=home,
           HOME=home, GDK_BACKEND="wayland", WAYLAND_DISPLAY="wayland-7", GSK_RENDERER="cairo", GIO_USE_VFS="local")
b = subprocess.Popen(["labwc"], env=dict(os.environ, HOME=home, XDG_CONFIG_HOME=home, WLR_BACKENDS="headless", WLR_RENDERER="pixman", WLR_LIBINPUT_NO_DEVICES="1", WAYLAND_DISPLAY="", LIBSEAT_BACKEND="noop"), stdout=subprocess.DEVNULL, stderr=open(home + "/wm.log", "w"))
time.sleep(2)
for x in os.listdir(os.environ["XDG_RUNTIME_DIR"]):
    if x.startswith("wayland-") and not x.endswith(".lock"):
        env["WAYLAND_DISPLAY"] = x
d = subprocess.Popen([BIN + "/sinty-agentd"], env=env)
time.sleep(1)
a = subprocess.Popen([EXE, "--gapplication-service"], env=env, stdout=subprocess.DEVNULL, stderr=open(home + "/app.log", "w"))
time.sleep(6)
s = socket.socket(socket.AF_UNIX)
s.connect(os.environ["XDG_RUNTIME_DIR"] + "/sinty-agent/mcp.sock")
fh = s.makefile("rw")
n = 0
def req(method, params=None):
    global n
    n += 1
    fh.write(json.dumps({"jsonrpc": "2.0", "id": n, "method": method, "params": params or {}}) + "\n")
    fh.flush()
    return json.loads(fh.readline())
def tool(name, **k):
    r = req("tools/call", {"name": name, "arguments": k})["result"]
    return r["isError"], r["content"][0]["text"]
fails = []
def check(label, ok, extra=""):
    print(("ok   " if ok else "FAIL ") + label + (" " + str(extra)[:160] if not ok else ""), flush=True)
    if not ok:
        fails.append(label)
def invoke(intent, **k):
    return tool("app_invoke", app=APP, intent=intent, args=k)
req("initialize", {"protocolVersion": "2025-06-18"})
e, t = tool("app_intents", app=APP)
check("intents listed", not e and "note_create" in t, t + open(home + "/app.log").read()[-400:] + open(home + "/wm.log").read()[-300:])
if fails:
    sys.exit(1)
e, t = invoke("note_create", title="Prova", markdown="uno")
check("create", not e and '"Prova"' in t, t)
nid = json.loads(t)["id"] if not e else ""
e, t = invoke("note_append", id=nid, markdown="due")
check("append", not e, t)
e, t = invoke("note_read", id=nid)
check("read back", not e and "uno" in t and "due" in t, t)
e, t = invoke("note_search", query="Prova")
check("search", not e and nid in t, t)
e, t = tool("app_context", app=APP)
check("context", not e, t)
check("file on disk", any("due" in open(os.path.join(r, f), errors="ignore").read() for r, _, fs in os.walk(home) for f in fs if f.endswith(".md")))
e, t = invoke("nope")
check("unknown intent fails", e, t)
try:
    bus = Gio.bus_get_sync(Gio.BusType.SESSION)
    path = "/" + APP.replace(".", "/").replace("-", "_")
    bus.call_sync(APP, path, "dev.sinty.AppAgent1", "ListIntents", None, GLib.VariantType("(s)"), 0, 5000, None)
    check("stranger refused", False)
except GLib.Error as x:
    check("stranger refused", "AccessDenied" in x.message or "only the system agent" in x.message, x.message)
for p in (a, d, b):
    p.terminate()
print("app=%d" % len(fails))
sys.exit(1 if fails else 0)
