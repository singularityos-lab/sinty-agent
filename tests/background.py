import json, os, socket, stat, subprocess, sys, tempfile, time

BIN = sys.argv[1]
home = tempfile.mkdtemp()
fake = os.path.join(home, "bin")
os.makedirs(fake)
log = os.path.join(home, "runs.jsonl")
with open(os.path.join(fake, "sinty"), "w") as f:
    f.write(f"""#!{sys.executable}
import json, os, socket, sys
token = os.environ.get("SINTY_AGENT_TOKEN", "")
s = socket.socket(socket.AF_UNIX)
s.connect(os.environ["XDG_RUNTIME_DIR"] + "/sinty-agent/mcp.sock")
fh = s.makefile("rw")
fh.write("token " + token + "\\n")
fh.write(json.dumps({{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {{"name": "settings_set", "arguments": {{"schema": "org.gnome.desktop.interface", "key": "color-scheme", "value": "'prefer-dark'"}}}}}}) + "\\n")
fh.flush()
r = json.loads(fh.readline())["result"]
open({log!r}, "a").write(json.dumps({{"argv": sys.argv[1:], "token": len(token), "error": r["isError"], "text": r["content"][0]["text"]}}) + "\\n")
print("did the work for " + sys.argv[3])
""")
os.chmod(os.path.join(fake, "sinty"), 0o755)
cfg = os.path.join(home, "sinty-agent")
os.makedirs(cfg)
watched = os.path.join(home, "Inbox")
os.makedirs(watched)
json.dump({"mode": "ask", "background": True}, open(os.path.join(cfg, "config.json"), "w"))
json.dump([
    {"id": "hello", "title": "Hello", "prompt": "Greet me", "event": "login"},
    {"id": "inbox", "title": "Inbox", "prompt": "File what arrives", "event": "files:" + watched},
    {"id": "later", "title": "Later", "prompt": "Not yet", "every_minutes": 60},
    {"id": "off", "title": "Off", "prompt": "Never", "event": "login", "enabled": False},
], open(os.path.join(cfg, "tasks.json"), "w"))
json.dump([{"id": "move", "title": "Move photos", "steps": [{"text": "list", "done": True, "result": "40"}, {"text": "copy"}]}],
          open(os.path.join(cfg, "plans.json"), "w"))
env = dict(os.environ, XDG_DATA_HOME=home, XDG_CONFIG_HOME=home, XDG_CACHE_HOME=home, XDG_STATE_HOME=home,
           HOME=home, GSETTINGS_BACKEND="keyfile", SINTY_AGENT_TICK="1", PATH=fake + ":" + os.environ["PATH"])
fails = []
def check(label, ok, extra=""):
    print(("ok   " if ok else "FAIL ") + label + (" " + str(extra)[:300] if not ok else ""), flush=True)
    if not ok:
        fails.append(label)

d = subprocess.Popen([BIN + "/sinty-agentd"], env=env)
time.sleep(1)
time.sleep(5)
open(os.path.join(watched, "bill.pdf"), "w").write("x")
time.sleep(4)
runs = [json.loads(l) for l in open(log)] if os.path.exists(log) else []
convs = sorted(r["argv"][2] for r in runs)
check("login, files and the plan ran, the others did not", convs == ["task-hello", "task-inbox", "task-plan-move"], convs)
check("each run carried a token", all(r["token"] == 32 for r in runs), runs)
check("the token made the run trusted, so an undoable change ran without asking", all(not r["error"] and "change " in r["text"] for r in runs), runs)
plan = [r for r in runs if r["argv"][2] == "task-plan-move"]
check("the plan resumes from its open step", plan and "from step 1: copy" in plan[0]["argv"][3], plan)
check("the background note reaches the model", runs and "cannot be undone still waits" in runs[0]["argv"][3], runs[:1])
state = json.load(open(os.path.join(home, "sinty-agent", "tasks-state.json")))
check("last runs are kept with what was said", state.get("hello", {}).get("ok") and "did the work" in state["hello"]["said"], state)
receipts = [json.loads(l) for l in open(os.path.join(home, "sinty-agent", "receipts.jsonl"))]
check("receipts record each run", sum(1 for x in receipts if x["tool"] == "settings_set") == 3, receipts)
d.terminate()
d.wait()

d = subprocess.Popen([BIN + "/sinty-agentd"], env=env)
time.sleep(5)
runs2 = [json.loads(l) for l in open(log)]
check("after a restart login tasks run again", sum(1 for r in runs2 if r["argv"][2] == "task-hello") == 2, [r["argv"][2] for r in runs2])
d.terminate()
d.wait()

json.dump({"mode": "ask", "background": False}, open(os.path.join(cfg, "config.json"), "w"))
d = subprocess.Popen([BIN + "/sinty-agentd"], env=env)
time.sleep(5)
runs3 = [json.loads(l) for l in open(log)]
check("nothing runs while background work is off", len(runs3) == len(runs2), len(runs3))
s = socket.socket(socket.AF_UNIX)
s.connect(os.environ["XDG_RUNTIME_DIR"] + "/sinty-agent/mcp.sock")
fh = s.makefile("rw")
def tool(name, **k):
    fh.write(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": name, "arguments": k}}) + "\n")
    fh.flush()
    r = json.loads(fh.readline())["result"]
    return r["isError"], r["content"][0]["text"]
e, t = tool("tasks_list")
check("tasks_list shows background off and last runs", not e and json.loads(t)["background"] is False and any("last_run" in x for x in json.loads(t)["tasks"]), t)
e, t = tool("task_save", task={"id": "news", "prompt": "Read the news", "at": "07:30"})
check("task_save reads the task back", not e and "read back" in t and "off in Settings" in t, t)
e, t = tool("task_save", task={"id": "bad", "prompt": "x", "every_minutes": 1})
check("task_save refuses a trigger too fast", e, t)
e, t = tool("task_delete", id="news")
check("task_delete", not e, t)
e, t = tool("plan_step", id="move", step=1, result="copied 40")
check("plan_step closes the last step and the plan", not e and "done" in t, t)
e, t = tool("plans_list")
check("plans_list shows it done", '"status": "done"' in t, t)
d.terminate()
print("FAILS", len(fails))
sys.exit(1 if fails else 0)
