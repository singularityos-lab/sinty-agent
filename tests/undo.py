import json, os, socket, subprocess, sys, tempfile, time
from gi.repository import Gio, GLib

BIN = sys.argv[1]
home = tempfile.mkdtemp()
env = dict(os.environ, XDG_DATA_HOME=home, XDG_CONFIG_HOME=home, XDG_CACHE_HOME=home, XDG_STATE_HOME=home,
           HOME=home, GSETTINGS_BACKEND="keyfile")
os.environ.update(GSETTINGS_BACKEND="keyfile", XDG_CONFIG_HOME=home)
d = subprocess.Popen([BIN + "/sinty-agentd"], env=env)
time.sleep(1)
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
def tool(name, /, **k):
    r = req("tools/call", {"name": name, "arguments": k})["result"]
    return r["isError"], r["content"][0]["text"]
fails = []
def check(label, ok, extra=""):
    print(("ok   " if ok else "FAIL ") + label + (" " + str(extra)[:200] if not ok else ""), flush=True)
    if not ok:
        fails.append(label)

SCHEMA, KEY = sys.argv[2], sys.argv[3]
FIRST, SECOND = sys.argv[4], sys.argv[5]
req("initialize", {"protocolVersion": "2025-06-18"})
e, t = tool("settings_set", schema=SCHEMA, key=KEY, value=FIRST)
check("first change", not e and "change " in t, t)
e, t = tool("settings_set", schema=SCHEMA, key=KEY, value=SECOND)
check("second change", not e and "change " in t, t)
second = int(t.rsplit("change ", 1)[1].split(":")[0])
e, t = tool("settings_get", schema=SCHEMA, key=KEY)
check("second is live", t == SECOND, t)
e, t = tool("changes_list")
items = json.loads(t)
check("journal lists both, newest first", len(items) == 2 and items[0]["id"] == second and items[0]["undo"] == FIRST, t)
e, t = tool("change_undo")
check("undo the newest", not e and "read back" in t, t)
e, t = tool("settings_get", schema=SCHEMA, key=KEY)
check("value is back", t == FIRST, t)
e, t = tool("change_undo", id=second)
check("the same change cannot be undone twice", e, t)

bus = Gio.bus_get_sync(Gio.BusType.SESSION)
def agent(method, args=None, reply=None):
    return bus.call_sync("dev.sinty.Agent", "/dev/sinty/Agent", "dev.sinty.Agent1", method, args,
                         GLib.VariantType(reply) if reply else None, Gio.DBusCallFlags.NONE, 10000, None)
listed = json.loads(agent("ListChanges", None, "(s)").unpack()[0])
check("the shell sees the journal", len(listed) == 2 and listed[0]["undone"], listed)
r = json.loads(agent("Undo", GLib.Variant("(u)", (0,)), "(s)").unpack()[0])
check("the shell undoes the oldest left", r["done"] and r["id"] == listed[1]["id"], r)
e, t = tool("settings_get", schema=SCHEMA, key=KEY)
check("original value is back", t != FIRST and t != SECOND, t)
receipts = [json.loads(l) for l in open(home + "/sinty-agent/receipts.jsonl")]
check("receipts carry the change id", sum(1 for x in receipts if x.get("change")) == 3, receipts)
d.terminate()
print("FAILS", len(fails))
sys.exit(1 if fails else 0)
