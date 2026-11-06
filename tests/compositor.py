import base64, json, os, socket, subprocess, sys, tempfile, time
import struct

BIN = sys.argv[1]
home = tempfile.mkdtemp()
rt = os.environ["XDG_RUNTIME_DIR"]
base = dict(os.environ, HOME=home, XDG_CONFIG_HOME=home, XDG_DATA_HOME=home, XDG_CACHE_HOME=home, XDG_STATE_HOME=home)
base.pop("DISPLAY", None)
log = open(home + "/labwc.log", "w")
lab = subprocess.Popen(os.environ.get("LABWC", "labwc").split(), env=dict(base, WLR_BACKENDS="headless", WLR_RENDERER="pixman", WLR_LIBINPUT_NO_DEVICES="1", LIBSEAT_BACKEND="noop", WLR_HEADLESS_OUTPUTS="2"), stdout=log, stderr=log)
time.sleep(2)
if lab.poll() is not None:
    log.flush(); print("labwc gone", open(home + "/labwc.log", errors="replace").read()[-1500:]); sys.exit(1)
env = dict(base, GDK_BACKEND="wayland", GSK_RENDERER="cairo")
for x in os.listdir(rt):
    if x.startswith("wayland-") and not x.endswith(".lock"):
        env["WAYLAND_DISPLAY"] = x
TARGET = """
import gi, sys
gi.require_version("Gtk", "4.0")
from gi.repository import Gtk
out = sys.argv[1]
def note(s):
    with open(out, "a") as f:
        f.write(s + "\\n")
def act(app):
    w = Gtk.ApplicationWindow(application=app, title="Estranea", default_width=500, default_height=300)
    b = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
    btn = Gtk.Button(label="Premi", hexpand=True, vexpand=True)
    btn.connect("clicked", lambda *_: note("clicked"))
    e = Gtk.Entry()
    e.connect("changed", lambda x: note("text=" + x.get_text()))
    b.append(btn); b.append(e); w.set_child(b); w.present(); e.grab_focus()
a = Gtk.Application(application_id="org.example.Estranea")
a.connect("activate", act)
a.run([])
"""
open(home + "/t.py", "w").write(TARGET)
out = home + "/out"
open(out, "w").close()
tp = subprocess.Popen(["python3", home + "/t.py", out], env=env, stdout=log, stderr=log)
dl = open(home + "/agentd.log", "w")
d = subprocess.Popen([BIN + "/sinty-agentd"], env=dict(env, WAYLAND_DEBUG=os.environ.get("AGENT_WL_DEBUG", "")), stdout=dl, stderr=dl)
time.sleep(4)
s = socket.socket(socket.AF_UNIX)
s.settimeout(20)
s.connect(rt + "/sinty-agent/mcp.sock")
fh = s.makefile("rw")
n = 0
def req(method, params=None):
    global n
    n += 1
    fh.write(json.dumps({"jsonrpc": "2.0", "id": n, "method": method, "params": params or {}}) + "\n")
    fh.flush()
    return json.loads(fh.readline())
def tool(name, /, **k):
    r = req("tools/call", {"name": name, "arguments": k})["result"]
    return r["isError"], r["content"][0]["text"], r["content"]
fails = []
def check(label, ok, extra=""):
    print(("ok   " if ok else "FAIL ") + label + (" " + str(extra)[:200] if not ok else ""), flush=True)
    if not ok:
        fails.append(label)
def lines():
    return open(out).read().split("\n")
subprocess.run(["busctl", "--version"], capture_output=True) if False else None
req("initialize", {"protocolVersion": "2025-06-18"})
try:
    tool("agent_status")
except Exception as x:
    print("status hang", x)
mode = subprocess.run([BIN + "/sinty-agent", "mode", "autopilot"], env=env, capture_output=True, text=True)
check("autopilot", mode.returncode == 0, mode.stderr)
try:
    e, t, _ = tool("windows_list")
except Exception as x:
    print("list hang", x); log.flush(); print(open(home + "/agentd.log", errors="replace").read()[-2500:]); os._exit(1)
ws = json.loads(t) if not e else []
w = next((x for x in ws if x["app_id"] == "org.example.Estranea"), None)
check("foreign window listed", w is not None, t)
if not w:
    print(open(home + "/labwc.log").read()[-600:])
    sys.exit(1)
check("geometry known", w["width"] > 100 and w["height"] > 100 and w["pid"] == tp.pid, w)
check("title known", w["title"] == "Estranea", w)
wid = w["id"]

e, t, _ = tool("window_set", id=wid, action="move_resize", x=40, y=50, width=600, height=400)
time.sleep(0.8)
w = next(x for x in json.loads(tool("windows_list")[1]) if x["id"] == wid)
check("move resize", not e and w["x"] == 40 and w["y"] == 50 and w["width"] == 600, w)
check("id stable", w["id"] == wid)

e, t, _ = tool("outputs_list")
outs = json.loads(t) if not e else []
check("two screens listed", len(outs) == 2 and outs[0]["x"] < outs[1]["x"], t)
if len(outs) == 2:
    check("screens ordered", outs[0]["position"] == "leftmost" and outs[1]["position"] == "rightmost", outs)
    e, t, _ = tool("window_set", id=wid, action="output", output="right")
    reply = json.loads(t)["window"] if not e else {}
    check("move to the right screen", not e and reply.get("output") == outs[1]["name"], t)
    w = next(x for x in json.loads(tool("windows_list")[1]) if x["id"] == wid)
    check("window really on the right screen", w["output"] == outs[1]["name"] and w["x"] >= outs[1]["x"], w)
    e, t, _ = tool("window_set", id=wid, action="output", output=outs[0]["name"])
    w = next(x for x in json.loads(tool("windows_list")[1]) if x["id"] == wid)
    check("move back by name", not e and w["output"] == outs[0]["name"] and w["x"] < outs[1]["x"], (t, w))
    check("unknown screen refused", tool("window_set", id=wid, action="output", output="HDMI-9")[0])
    e, t, _ = tool("window_set", id=wid, action="move_resize", x=40, y=50, width=600, height=400)
    time.sleep(0.5)

e, t, c = tool("screen_capture", window=wid)
check("window capture", not e and len(c) == 2 and c[1]["type"] == "image", t)
if len(c) == 2:
    png = base64.b64decode(c[1]["data"])
    width = struct.unpack(">I", png[16:20])[0]
    check("window image size", png[:4] == b"\x89PNG" and width >= 590, width)
    check("window image not blank", len(set(png[40:4000])) > 20)
e, t, c = tool("screen_capture")
check("screen capture", not e and len(c) == 2, t)
if len(c) == 2:
    open(home + "/screen.png", "wb").write(base64.b64decode(c[1]["data"]))
    if len(sys.argv) > 2:
        open(sys.argv[2], "wb").write(base64.b64decode(c[1]["data"]))

e, t, _ = tool("pointer", action="click", window=wid, x=300, y=150)
time.sleep(0.6)
check("click on a foreign window", not e and "clicked" in lines(), (t, lines()))

e, t, _ = tool("keyboard", window=wid, text="ciao")
time.sleep(0.6)
check("typing reaches it", not e and "text=ciao" in lines(), (t, lines()[-3:]))
e, t, _ = tool("keyboard", keys="ctrl+a")
check("combination", not e, t)
e, t, _ = tool("keyboard", text="è perché €")
time.sleep(0.6)
check("combination then unicode", not e and lines()[-2] == "text=è perché €", lines()[-4:])

for action in ("minimize", "unminimize", "maximize", "unmaximize"):
    check(action, not tool("window_set", id=wid, action=action)[0])
    time.sleep(0.4)
    w = next(x for x in json.loads(tool("windows_list")[1]) if x["id"] == wid)
    if action == "minimize":
        check("minimized", w["minimized"], w)
    if action == "maximize":
        check("maximized", w["maximized"], w)
check("snap", not tool("window_set", id=wid, action="snap", direction="left")[0])
check("bad action refused", tool("window_set", id=wid, action="nope")[0])
check("outside screen refused", tool("pointer", action="click", x=99999, y=5)[0])
check("unknown window refused", tool("window_close", id=9999)[0])
subprocess.run([BIN + "/sinty-agent", "mode", "plan"], env=env, capture_output=True)
check("plan refuses a click", tool("pointer", action="click", x=5, y=5)[0])
check("plan allows the list", not tool("windows_list")[0])
subprocess.run([BIN + "/sinty-agent", "mode", "autopilot"], env=env, capture_output=True)
e, _, _ = tool("window_close", id=wid)
time.sleep(1.5)
check("close", not e and tp.poll() is not None or not any(x["id"] == wid for x in json.loads(tool("windows_list")[1])))
d.terminate(); tp.terminate(); lab.terminate()
print("compositor=%d" % len(fails))
sys.exit(1 if fails else 0)
