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
a = subprocess.Popen([EXE] + ([] if APP == "dev.sinty.files" else ["--gapplication-service"]), env=env, stdout=subprocess.DEVNULL, stderr=open(home + "/app.log", "w"))
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
check("intents listed", not e and json.loads(t)["intents"], t + open(home + "/app.log").read()[-400:] + open(home + "/wm.log").read()[-300:])
if fails:
    sys.exit(1)

def notes():
    e, t = invoke("note_create", title="Prova", markdown="uno")
    check("create", not e and '"Prova"' in t, t)
    nid = json.loads(t)["id"]
    check("append", not invoke("note_append", id=nid, markdown="due")[0])
    e, t = invoke("note_read", id=nid)
    check("read back", not e and "uno" in t and "due" in t, t)
    e, t = invoke("note_search", query="Prova")
    check("search", not e and nid in t, t)
    check("file on disk", any("due" in open(os.path.join(r, f), errors="ignore").read() for r, _, fs in os.walk(home) for f in fs if f.endswith(".md")))

def tasks():
    e, t = invoke("task_add", text="Comprare il pane")
    check("add", not e and "pane" in t, t)
    uid = json.loads(t)["uid"]
    e, t = invoke("task_search", query="pane")
    check("search", not e and uid in t, t)
    check("complete", not invoke("task_complete", uid=uid)[0])
    time.sleep(1)
    e, t = invoke("task_list", completed=True)
    check("listed done", not e and uid in t, t)

def camera():
    e, t = invoke("camera_last")
    check("last without shots", not e and json.loads(t)["path"] == "", t)
    tool_mode("autopilot")
    e, t = invoke("camera_photo")
    check("no camera reported", e and "camera" in t, t)

def files():
    root = home + "/t"
    os.makedirs(root)
    open(root + "/a.txt", "w").write("x")
    e, t = invoke("files_list", path=root)
    check("list", not e and "a.txt" in t, t)
    check("relative refused", invoke("files_list", path="t")[0])
    check("copy", not invoke("files_copy", to=root + "/b.txt", **{"from": root + "/a.txt"})[0] and os.path.exists(root + "/b.txt"))
    check("copy never overwrites", invoke("files_copy", to=root + "/b.txt", **{"from": root + "/a.txt"})[0])
    check("move", not invoke("files_move", to=root + "/c.txt", **{"from": root + "/b.txt"})[0] and os.path.exists(root + "/c.txt"))
    check("mkdir", not invoke("files_mkdir", path=root + "/d/e")[0] and os.path.isdir(root + "/d/e"))
    check("show", not invoke("files_show", path=root)[0])

def edit():
    p = home + "/doc.txt"
    open(p, "w").write("ciao\n")
    e, t = invoke("edit_open", path=p)
    check("open", not e and "doc.txt" in t, t)
    time.sleep(2)
    e, t = invoke("edit_read")
    check("read", not e and "ciao" in t, t)
    check("insert", not invoke("edit_insert", text="scritto dal vivo ")[0])
    e, t = invoke("edit_read")
    check("insert visible", not e and "scritto dal vivo" in t, t)
    tool_mode("autopilot")
    check("save", not invoke("edit_save")[0])
    time.sleep(1)
    check("saved on disk", "scritto dal vivo" in open(p).read(), open(p).read())

def tool_mode(m):
    subprocess.run([BIN + "/sinty-agent", "mode", m], capture_output=True, timeout=10)

{"dev.sinty.notes": notes, "dev.sinty.tasks": tasks, "dev.sinty.camera": camera, "dev.sinty.files": files, "dev.sinty.edit": edit}[APP]()
check("context", not tool("app_context", app=APP)[0])
check("unknown intent fails", invoke("nope")[0])
tool_mode("plan")
w = {"dev.sinty.notes": "note_create", "dev.sinty.tasks": "task_add", "dev.sinty.files": "files_mkdir", "dev.sinty.edit": "edit_insert"}.get(APP)
check("plan refuses writes", w is None or invoke(w, title="x", text="x", path="/nonexistent/x")[0])
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
