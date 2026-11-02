import json, os, socket, subprocess, sys, threading, time
from gi.repository import Gio, GLib

BIN = sys.argv[1]
d = subprocess.Popen([BIN + "/sinty-agentd"], stderr=subprocess.DEVNULL)
time.sleep(1)
fails = []
def check(label, ok, extra=""):
    print(("ok   " if ok else "FAIL ") + label + (" " + str(extra)[:160] if not ok else ""), flush=True)
    if not ok:
        fails.append(label)
bus = Gio.bus_get_sync(Gio.BusType.SESSION)
def dbus(method, args=None):
    try:
        bus.call_sync("dev.sinty.Agent", "/dev/sinty/Agent", "dev.sinty.Agent1", method, args, None, Gio.DBusCallFlags.NONE, 15000)
        return True
    except GLib.Error:
        return False
def cli(*a):
    return subprocess.run([BIN + "/sinty-agent", *a], capture_output=True, text=True, timeout=20)
check("a script cannot raise the mode", not dbus("SetMode", GLib.Variant("(s)", ("autopilot",))))
check("a script cannot answer", not dbus("Answer", GLib.Variant("(ub)", (1, True))))
check("a script cannot allow a session", not dbus("AllowSession", GLib.Variant("(u)", (1,))))
check("a script can always stop", dbus("Stop"))
check("a script cannot resume", not dbus("Resume"))
check("the shell can resume", cli("resume").returncode == 0)
check("a script can lower the mode", dbus("SetMode", GLib.Variant("(s)", ("plan",))))
cli("mode", "autopilot")
s = socket.socket(socket.AF_UNIX); s.settimeout(30); s.connect(os.environ["XDG_RUNTIME_DIR"] + "/sinty-agent/mcp.sock")
fh = s.makefile("rw"); n = 0
def tool(name, /, **k):
    global n
    n += 1
    fh.write(json.dumps({"jsonrpc": "2.0", "id": n, "method": "tools/call", "params": {"name": name, "arguments": k}}) + "\n"); fh.flush()
    r = json.loads(fh.readline())["result"]
    return r["isError"], r["content"][0]["text"]
asks = []
def signal(_c, _s, _p, _i, _n, params, _u):
    asks.append(params.unpack())
bus.signal_subscribe("dev.sinty.Agent", "dev.sinty.Agent1", "ConfirmRequested", None, None, Gio.DBusSignalFlags.NONE, signal, None)
ctx = GLib.MainContext.default()
def pump(want):
    end = time.time() + 8
    while len(asks) < want and time.time() < end:
        ctx.iteration(False); time.sleep(0.02)
check("harmless runs", not tool("agent_status")[0])
def answer(fn, want):
    def run():
        pump(want)
        if len(asks) >= want:
            fn(asks[want - 1][0])
    return run
r = {}
t = threading.Thread(target=lambda: r.update(x=tool("settings_get", schema="nope.schema")))
t.start(); pump(1); t2 = None
check("autopilot does not free a script", len(asks) == 1, asks)
check("the prompt names the program", asks and sys.executable.split("/")[-1][:6] in asks[0][1], asks)
cli("deny", str(asks[0][0])) if asks else None
t.join(); check("denied", r["x"][0] and "did not allow" in r["x"][1], r)
t = threading.Thread(target=lambda: r.update(x=tool("settings_get", schema="nope.schema")))
t.start(); pump(2)
if len(asks) >= 2:
    cli("allow-session", str(asks[1][0]))
t.join(); check("allowed reached the tool", "no such schema" in r["x"][1], r)
before = len(asks)
e, tx = tool("settings_get", schema="nope.schema")
check("the session stays allowed", len(asks) == before and "no such schema" in tx, tx)
d.terminate()
print("trust=%d" % len(fails))
sys.exit(1 if fails else 0)
