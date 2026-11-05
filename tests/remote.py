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
def dbus(method, args=None, reply=None):
    try:
        r = bus.call_sync("dev.sinty.Agent", "/dev/sinty/Agent", "dev.sinty.Agent1", method, args, reply, Gio.DBusCallFlags.NONE, 15000)
        return r.unpack() if r is not None else ()
    except GLib.Error as e:
        return e
def status():
    return json.loads(dbus("GetStatus")[0])
remotes = []
asks = []
bus.signal_subscribe("dev.sinty.Agent", "dev.sinty.Agent1", "RemoteChanged", None, None, Gio.DBusSignalFlags.NONE, lambda *a: remotes.append(a[5].unpack()[0]), None)
closed = []
bus.signal_subscribe("dev.sinty.Agent", "dev.sinty.Agent1", "ConfirmClosed", None, None, Gio.DBusSignalFlags.NONE, lambda *a: closed.append(a[5].unpack()[0]), None)
bus.signal_subscribe("dev.sinty.Agent", "dev.sinty.Agent1", "ConfirmRequested", None, None, Gio.DBusSignalFlags.NONE, lambda *a: asks.append(a[5].unpack()), None)
ctx = GLib.MainContext.default()
def pump(cond):
    end = time.time() + 8
    while not cond() and time.time() < end:
        ctx.iteration(False); time.sleep(0.02)
check("the status names no phone at rest", status().get("remote") == "", status())
empty = dbus("RemoteGrant", GLib.Variant("(s)", ("  ",)), GLib.VariantType("(s)"))
check("a phone needs a name", isinstance(empty, GLib.Error), empty)
g = dbus("RemoteGrant", GLib.Variant("(s)", ("Pixel di Mirko",)), GLib.VariantType("(s)"))
token = g[0] if isinstance(g, tuple) else ""
check("the device service gets a phone token", len(token) == 32, g)
s = socket.socket(socket.AF_UNIX); s.settimeout(30); s.connect(os.environ["XDG_RUNTIME_DIR"] + "/sinty-agent/mcp.sock")
fh = s.makefile("rw"); n = 0
fh.write("token " + token + "\n"); fh.flush()
def tool(name, /, **k):
    global n
    n += 1
    fh.write(json.dumps({"jsonrpc": "2.0", "id": n, "method": "tools/call", "params": {"name": name, "arguments": k}}) + "\n"); fh.flush()
    r = json.loads(fh.readline())["result"]
    return r["isError"], r["content"][0]["text"]
check("harmless runs", not tool("agent_status")[0])
pump(lambda: remotes)
check("the desktop learns a phone took over", remotes[:1] == ["Pixel di Mirko"], remotes)
check("the status names the phone", status().get("remote") == "Pixel di Mirko", status())
r = {}
t = threading.Thread(target=lambda: r.update(x=tool("shell_run", command="true")))
t.start(); pump(lambda: asks)
check("the prompt names the phone", asks and asks[0][1].startswith("Pixel di Mirko:"), asks)
check("the status tells the risk of the open question", status().get("risk") == "irreversible", status())
if asks:
    check("the device service can answer", dbus("Answer", GLib.Variant("(ub)", (asks[0][0], False))) == ())
t.join(timeout=20)
pump(lambda: closed)
check("the desktop learns the question is closed", asks and closed == [asks[0][0]], closed)
check("the phone denial reaches the tool", "x" in r and r["x"][0] and "did not allow" in r["x"][1], r)
check("the device service can stop", dbus("Stop") == ())
check("the device service can resume", dbus("Resume") == ())
check("the device service can choose autopilot", dbus("SetMode", GLib.Variant("(s)", ("autopilot",))) == () and status()["mode"] == "autopilot", status())
check("the device service cannot get a desktop token", isinstance(dbus("GrantSession", None, GLib.VariantType("(s)")), GLib.Error))
fh.close(); s.close()
pump(lambda: len(remotes) > 1)
check("the desktop learns the phone left", remotes[-1:] == [""], remotes)
check("the status forgets the phone", status().get("remote") == "", status())
d.terminate()
print("remote=%d" % len(fails))
sys.exit(1 if fails else 0)
