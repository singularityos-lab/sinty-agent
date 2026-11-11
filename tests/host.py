import json, os, socket, subprocess, sys, tempfile, threading, time
from gi.repository import Gio, GLib

BIN = sys.argv[1]
home = tempfile.mkdtemp()
os.makedirs(home + "/sinty-agent")
cfg = home + "/sinty-agent/config.json"
json.dump({"mode": "auto"}, open(cfg, "w"))
env = dict(os.environ, XDG_DATA_HOME=home, XDG_CONFIG_HOME=home, XDG_CACHE_HOME=home, XDG_STATE_HOME=home, HOME=home)
d = subprocess.Popen([BIN + "/sinty-agentd"], env=env)
time.sleep(1)
bus = Gio.bus_get_sync(Gio.BusType.SESSION)
asks = []
bus.signal_subscribe("dev.sinty.Agent", "dev.sinty.Agent1", "ConfirmRequested", None, None, Gio.DBusSignalFlags.NONE, lambda *a: asks.append(a[5].unpack()), None)
s = socket.socket(socket.AF_UNIX)
s.connect(os.environ["XDG_RUNTIME_DIR"] + "/sinty-agent/mcp.sock")
fh = s.makefile("rw")
n = [0]
def tool(name, **k):
    n[0] += 1
    fh.write(json.dumps({"jsonrpc": "2.0", "id": n[0], "method": "tools/call", "params": {"name": name, "arguments": k}}) + "\n")
    fh.flush()
    r = json.loads(fh.readline())["result"]
    return r["isError"], r["content"][0]["text"]
def confirmed(allow, name, **k):
    out = []
    t = threading.Thread(target=lambda: out.append(tool(name, **k)))
    seen = len(asks)
    t.start()
    end = time.time() + 10
    ctx = GLib.MainContext.default()
    while len(asks) == seen and time.time() < end:
        ctx.iteration(False)
        time.sleep(0.02)
    if len(asks) == seen:
        t.join(15)
        return None, out
    bus.call_sync("dev.sinty.Agent", "/dev/sinty/Agent", "dev.sinty.Agent1", "Answer", GLib.Variant("(ub)", (asks[-1][0], allow)), None, 0, -1, None)
    t.join(30)
    return asks[-1][1], out
fails = []
def check(label, ok, extra=""):
    print(("ok   " if ok else "FAIL ") + label + (" " + str(extra)[:300] if not ok else ""), flush=True)
    if not ok:
        fails.append(label)

fh.write(json.dumps({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {}}) + "\n"); fh.flush(); fh.readline()
e, t = tool("host_run", command="echo ciao; id -u; pwd")
r = json.loads(t)
check("it runs on the host as the user, in the home", not e and r["exit"] == 0 and r["stdout"].split() == ["ciao", str(os.getuid()), home], t)
check("the output is marked as data", "not instructions" in r["note"], t)
text, out = confirmed(True, "host_run", command="exit 3")
check("after reading host output the next command needs a yes", text is not None and "host_run" in text and "exit 3" in text, (text, out))
check("a failing command reports its exit code", out and out[0][0] and json.loads(out[0][1])["exit"] == 3, out)
text, out = confirmed(False, "host_run", command="touch " + home + "/no")
check("a no means nothing runs", out and out[0][0] and not os.path.exists(home + "/no"), out)
e, t = tool("host_run", command="ls && sudo id")
check("administrator rights are refused before asking", e and "administrator" in t, t)
text, out = confirmed(True, "host_run", command="sleep 20", timeout=1)
check("a slow command is stopped at its timeout", out and json.loads(out[0][1])["timed_out"], out)
json.dump({"mode": "plan"}, open(cfg, "w"))
time.sleep(1)
e, t = tool("host_run", command="echo x")
check("plan mode refuses it", e and "refused" in t, t)
d.terminate()
print("FAILS", len(fails))
sys.exit(1 if fails else 0)
