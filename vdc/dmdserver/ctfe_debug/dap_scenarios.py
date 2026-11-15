"""DAP scenarios: global constants, pause, errors, hidden locals, conditions,
expressions, template arguments, instantiations, instance definitions, instance
values, static conditions, condition arguments, returns, breakpoint order,
package modules."""
import functools
import json
import os
import subprocess
import threading
import time

print = functools.partial(print, flush=True)

BASE = os.path.dirname(os.path.abspath(__file__))
EXE = r"C:\s\d\visuald\trunk\bin\Debug COFF32\x64\dmdserver.exe"
DMDSRC = r"C:\D\dmd-2.114.0-beta.1\src"
IMPORTS = [DMDSRC + r"\druntime\src", DMDSRC + r"\phobos"]

# The events that say the compilation is over.  A wait does not consume them, so
# every scenario can still check for them at its end.
TERMINAL = ("terminated", "exited")


class Client:
    """Talks to dmdserver -ctfeDebug; a reader thread sorts out responses and events."""

    def __init__(self, src):
        self.p = subprocess.Popen([EXE, "-ctfeDebug", src],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE)
        self.seq = 0
        self.responses = {}
        self.events = []
        self.outputs = []
        self.closed = False
        self.cond = threading.Condition()
        t = threading.Thread(target=self._reader)
        t.daemon = True
        t.start()

    def _reader(self):
        while True:
            msg = self._read_message()
            with self.cond:
                if msg is None:
                    self.closed = True
                    self.cond.notify_all()
                    return
                if msg.get("type") == "response":
                    self.responses[msg.get("request_seq")] = msg
                else:
                    self.events.append(msg)
                    if msg.get("event") == "output":
                        self.outputs.append(msg.get("body") or {})
                self.cond.notify_all()

    def _read_message(self):
        headers = {}
        while True:
            line = self.p.stdout.readline()
            if not line:
                return None
            line = line.strip()
            if not line:
                break
            key, _, value = line.decode("utf-8").partition(":")
            headers[key.strip().lower()] = value.strip()
        n = int(headers.get("content-length", "0"))
        if not n:
            return None
        return json.loads(self.p.stdout.read(n).decode("utf-8"))

    def send(self, command, arguments=None):
        self.seq += 1
        msg = {"seq": self.seq, "type": "request", "command": command}
        if arguments is not None:
            msg["arguments"] = arguments
        data = json.dumps(msg).encode("utf-8")
        self.p.stdin.write(b"Content-Length: %d\r\n\r\n" % len(data) + data)
        self.p.stdin.flush()
        return self.seq

    def request(self, command, arguments=None, timeout=30):
        seq = self.send(command, arguments)
        deadline = time.time() + timeout
        with self.cond:
            while seq not in self.responses:
                if self.closed or time.time() > deadline:
                    return None
                self.cond.wait(0.2)
            return self.responses.pop(seq)

    def wait_event(self, names, timeout=30):
        """Wait for one of `names` (an event name, or a list of them).
        Terminal events are left in the queue, so a later wait still sees them."""
        if isinstance(names, str):
            names = (names,)
        deadline = time.time() + timeout
        with self.cond:
            while True:
                for i, ev in enumerate(self.events):
                    if ev.get("event") in names:
                        if ev.get("event") not in TERMINAL:
                            self.events.pop(i)
                        return ev.get("body") or {}, ev
                if self.closed or time.time() > deadline:
                    return None, None
                self.cond.wait(0.05)

    def got_event(self, name, timeout=30):
        return self.wait_event(name, timeout)[0] is not None

    def scopes(self, frame_id):
        sc = self.request("scopes", {"frameId": frame_id})
        out = []
        for s in (sc or {}).get("body", {}).get("scopes", []):
            vr = self.request("variables", {"variablesReference": s["variablesReference"]})
            out.append((s["name"], [(v["name"], v["value"], v["type"])
                                    for v in (vr or {}).get("body", {}).get("variables", [])]))
        return out

    def frames(self):
        st = self.request("stackTrace", {"threadId": 1})
        return (st or {}).get("body", {}).get("stackFrames", [])

    def close(self):
        try:
            self.send("disconnect", {"restart": False})
            self.p.stdin.close()
        except Exception:
            pass
        try:
            self.p.wait(timeout=20)
        except Exception:
            self.p.kill()
        return self.p.returncode


def finish(c, timeout=60):
    """Resume the session, past any further stops, and report whether it ended.
    The end event arrives as soon as the compilation is done; waiting for a stop
    that never comes would burn the whole timeout of the wait instead."""
    c.send("continue", {"threadId": 1})
    for _ in range(200):
        _, msg = c.wait_event(TERMINAL + ("stopped",), timeout)
        if msg is None:
            return False
        if msg.get("event") != "stopped":
            return True
        c.send("continue", {"threadId": 1})
    return False


def scenario_globals():
    print("=== global constants are no scope of their own ===")
    src = BASE + r"\ctfe_demo.d"
    c = Client(src)
    c.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c.request("launch", {"program": src, "importPaths": IMPORTS})
    c.request("setBreakpoints", {"source": {"path": src}, "breakpoints": [{"line": 19}]})
    c.request("configurationDone")
    ev, _ = c.wait_event("stopped")
    print("stopped:", ev and ev.get("reason"))
    frames = c.frames()
    print("frames:", [(f.get("name"), f.get("line")) for f in frames])
    if frames:
        scopes = c.scopes(frames[0]["id"])
        for name, vs in scopes:
            print("  scope %s: %s" % (name, vs))
        # Visual Studio shows every scope in the Locals window, so the manifest
        # constants of the module must not be one
        assert [name for name, _ in scopes] == ["Locals"], scopes
        shown = [n for _, vs in scopes for n, _, _ in vs]
        assert not [n for n in shown if n in ("f6", "total")], shown
        # but the evaluator still knows them, which is what the watch and the
        # hover window use
        for expr, want in (("f6", "720"), ("total", None)):
            r = c.request("evaluate", {"expression": expr, "frameId": frames[0]["id"],
                                       "context": "hover"})
            body = (r or {}).get("body")
            print("  evaluate %s: %s" % (expr, body and body.get("result")))
            assert body is not None, (expr, r)
            if want is not None:
                assert body.get("result") == want, (expr, body)
    print("terminated:", finish(c))
    print("exit:", c.close())


def scenario_pause():
    print("=== pause while running ===")
    src = BASE + r"\ctfe_pause.d"
    c = Client(src)
    c.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c.request("launch", {"program": src, "importPaths": IMPORTS})
    c.request("configurationDone")
    time.sleep(1.0)
    c.send("pause", {"threadId": 1})
    ev, _ = c.wait_event("stopped", 20)
    print("stopped:", ev and ev.get("reason"))
    frames = c.frames()
    print("frames:", [(f.get("name"), f.get("line")) for f in frames])
    if frames:
        for name, vs in c.scopes(frames[0]["id"]):
            print("  scope %s: %s" % (name, vs))
    print("terminated:", finish(c, 180))
    print("exit:", c.close())


def scenario_errors():
    print("=== compile time error reported to the client ===")
    src = BASE + r"\ctfe_err.d"
    c = Client(src)
    c.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c.request("launch", {"program": src, "importPaths": IMPORTS})
    c.request("configurationDone")
    print("terminated:", c.got_event("terminated", 60))
    for o in c.outputs[:6]:
        print("  output[%s]: %s" % (o.get("category"), (o.get("output") or "").strip()))
    print("exit:", c.close())


def scenario_output():
    print("=== compiler console output reaches the client ===")
    src = BASE + r"\ctfe_out.d"
    c = Client(src)
    c.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c.request("launch", {"program": src, "importPaths": IMPORTS})
    bp = find_line(src, '__ctfeWrite("__ctfeWrite says hello')
    c.request("setBreakpoints", {"source": {"path": src}, "breakpoints": [{"line": bp}]})
    c.request("configurationDone")

    # pragma(msg) and __ctfeWrite write straight to the C streams rather than going
    # through the diagnostics callback, so they only reach the client if the adapter
    # forwards the console of the process doing the interpretation
    def seen():
        return "".join(o.get("output") or "" for o in c.outputs)

    _, ev = c.wait_event(("stopped", "terminated"), 60)
    frames = c.frames() if ev and ev.get("event") == "stopped" else []
    print("stop:", [(f.get("name"), f.get("line")) for f in frames])
    print("  console at the stop: %r" % (seen(),))
    # the text arrives as it is written rather than when the compilation ends, so
    # the __ctfeWrite of the line the breakpoint is on has not been sent yet
    assert frames and frames[0].get("line") == bp, frames
    assert "a pragma(msg) message" in seen(), seen()
    assert "__ctfeWrite" not in seen(), seen()

    print("terminated:", finish(c))
    text = seen()
    for line in text.splitlines():
        print("  output: %s" % line)
    assert "__ctfeWrite says hello" in text, text
    assert text.count("__ctfeWrite says hello") == 2, text
    print("exit:", c.close())


def find_line(src, marker):
    """Line number of the first line containing the marker comment."""
    with open(src, encoding="utf-8") as f:
        for i, line in enumerate(f, 1):
            if marker in line:
                return i
    raise KeyError(marker)


def local_values(c, frame):
    """Locals of a frame as name -> value."""
    return {n: v for n, (v, _) in local_types(c, frame).items()}


def local_types(c, frame):
    """Locals of a frame as name -> (value, type)."""
    out = {}
    for name, vs in c.scopes(frame["id"]):
        if name.lower().startswith("local"):
            for n, v, t in vs:
                out[n] = (v, t)
    return out


def local_tree(c, frame, depth=4):
    """Locals of a frame, and the names their values expand to, keyed by the path
    to them.  The fields of a struct or of an instance of a class are the children
    of the value, and expanding the value is what reaches them.  A name maps to
    its value, its type, and whether it has children at all."""
    def walk(reference, prefix, depth):
        out = {}
        r = c.request("variables", {"variablesReference": reference})
        for v in (r or {}).get("body", {}).get("variables", []):
            child = v.get("variablesReference", 0)
            path = prefix + v["name"]
            out[path] = (v["value"], v.get("type"), bool(child))
            if child and depth:
                out.update(walk(child, path + ".", depth - 1))
        return out

    return walk(frame["id"], "", depth)


def scenario_temps():
    print("=== compiler generated locals are hidden ===")
    src = BASE + r"\ctfe_expr.d"
    line = find_line(src, "BP_FOREACH")
    c = Client(src)
    c.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c.request("launch", {"program": src, "importPaths": IMPORTS})
    c.request("setBreakpoints", {"source": {"path": src}, "breakpoints": [{"line": line}]})
    c.request("configurationDone")
    ev, _ = c.wait_event("stopped")
    print("stopped:", ev and ev.get("reason"))
    frames = c.frames()
    print("frames:", [(f.get("name"), f.get("line")) for f in frames])
    if frames:
        vs = local_values(c, frames[0])
        print("  locals:", sorted(vs.items()))
        hidden = [n for n in vs if n.startswith("__")]
        print("  generated names shown:", hidden or "none")
    # the breakpoint is in a foreach body, so it stops once per element
    print("terminated:", finish(c))
    print("exit:", c.close())


def scenario_condition():
    print("=== conditional breakpoint ===")
    src = BASE + r"\ctfe_expr.d"
    line = find_line(src, "BP_LOOP")
    c = Client(src)
    c.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c.request("launch", {"program": src, "importPaths": IMPORTS})
    r = c.request("setBreakpoints", {"source": {"path": src},
                                     "breakpoints": [{"line": line, "condition": "k == 7"}]})
    print("verified:", [(b.get("line"), b.get("verified"))
                        for b in (r or {}).get("body", {}).get("breakpoints", [])])
    c.request("configurationDone")
    hits = []
    while True:
        ev, msg = c.wait_event(("stopped",) + TERMINAL, 30)
        if msg is None or msg.get("event") != "stopped":
            break
        frames = c.frames()
        k = local_values(c, frames[0]).get("k") if frames else None
        hits.append((frames[0].get("line") if frames else None, k))
        c.send("continue", {"threadId": 1})
    print("hits:", hits)
    assert hits == [(line, "7")], hits
    print("terminated:", c.got_event("terminated", 10))
    print("exit:", c.close())


def scenario_evaluate():
    print("=== expression evaluation ===")
    src = BASE + r"\ctfe_expr.d"
    line = find_line(src, "BP_MIXED")
    c = Client(src)
    c.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c.request("launch", {"program": src, "importPaths": IMPORTS})
    c.request("setBreakpoints", {"source": {"path": src}, "breakpoints": [{"line": line}]})
    c.request("configurationDone")
    ev, _ = c.wait_event("stopped")
    print("stopped:", ev and ev.get("reason"))
    frames = c.frames()
    print("frames:", [(f.get("name"), f.get("line")) for f in frames])
    if frames:
        fid = frames[0]["id"]
        print("  locals:", sorted(local_values(c, frames[0]).items()))
        exprs = ["r", "arr[2]", "p.x", "p.y + 1", "s", "s.length", 's == "abc"',
                 's != "xyz"', "arr[2] == 3", "arr[2] != 3", "flag == true",
                 "p.x == 7 && p.y == 9",
                 "arr[0] + arr[1]", "arr.length", "flag", "flag ? 12 : 34",
                 "p.x > 5 && p.y < 10", "k > 0", "arr[2] + p.x * 2",
                 "c", "nosuch", "p.x +"]
        for e in exprs:
            r = c.request("evaluate", {"expression": e, "frameId": fid, "context": "hover"})
            body = (r or {}).get("body")
            print("  %-22s => %s" % (e, body.get("result") if body else
                                     "error: " + str((r or {}).get("message"))))
        for e in ("p", "arr"):
            r = c.request("evaluate", {"expression": e, "frameId": fid, "context": "watch"})
            body = (r or {}).get("body") or {}
            print("  %-22s => %s : %s" % (e, body.get("result"), body.get("type")))
            vr = c.request("variables", {"variablesReference": body.get("variablesReference", 0)})
            print("      children:", [(v["name"], v["value"])
                                      for v in (vr or {}).get("body", {}).get("variables", [])])
    print("terminated:", finish(c))
    print("exit:", c.close())


def find_lines(src, prefix):
    """Line numbers of the lines starting with prefix."""
    with open(src, encoding="utf-8") as f:
        return [i for i, line in enumerate(f, 1) if line.startswith(prefix)]


def scenario_manifest():
    print("=== breakpoint on a manifest constant declaration ===")
    src = BASE + r"\ctfe_expr.d"
    enum_lines = find_lines(src, "enum")
    loop_line = find_line(src, "BP_LOOP")
    c = Client(src)
    c.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c.request("launch", {"program": src, "importPaths": IMPORTS})
    r = c.request("setBreakpoints", {"source": {"path": src},
                                     "breakpoints": [{"line": l} for l in enum_lines]})
    print("verified:", [(b.get("line"), b.get("verified"))
                        for b in (r or {}).get("body", {}).get("breakpoints", [])])
    c.request("configurationDone")

    hits = []
    while True:
        ev, msg = c.wait_event(("stopped",) + TERMINAL, 30)
        if msg is None or msg.get("event") != "stopped":
            break
        frames = c.frames()
        hits.append((ev.get("reason"), [(f.get("name"), f.get("line")) for f in frames]))
        c.send("continue", {"threadId": 1})
    print("hits:", hits)
    assert [(r_, [f[1] for f in fr]) for r_, fr in hits] == \
        [("breakpoint", [l]) for l in enum_lines], hits
    # the frame of a global initializer is the expression being evaluated
    for (_, fr), want in zip(hits, ("sumArr", "loop", "mixed")):
        assert len(fr) == 1 and want in fr[0][0], fr

    # stepping from the declaration goes into the function call it contains
    c2 = Client(src)
    c2.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c2.request("launch", {"program": src, "importPaths": IMPORTS})
    c2.request("setBreakpoints", {"source": {"path": src},
                                  "breakpoints": [{"line": enum_lines[1]}]})
    c2.request("configurationDone")
    ev, _ = c2.wait_event("stopped")
    frames = c2.frames()
    print("stop:", ev and ev.get("reason"), [(f.get("name"), f.get("line")) for f in frames])
    steps = []
    for _ in range(3):
        c2.send("stepIn", {"threadId": 1})
        ev, _ = c2.wait_event("stopped", 20)
        frames = c2.frames()
        steps.append((ev and ev.get("reason"),
                      frames and (frames[0]["name"], frames[0]["line"]),
                      [(f["name"], f["line"]) for f in frames],
                      sorted(local_values(c2, frames[0]).items()) if frames else None))
    for s in steps:
        print("  stepIn:", s[0], s[1], s[2], s[3])
    assert steps and steps[0][0] == "step" and "loop" in steps[0][1][0], steps
    assert steps[0][1][1] < loop_line, steps
    # the initializer stays at the bottom of the stack while its call is stepped
    bottom = steps[0][2][-1]
    print("  bottom frame:", bottom)
    assert "loop(20)" in bottom[0] and bottom[1] == enum_lines[1], bottom
    print("terminated:", finish(c2))
    print("exit:", c2.close())


def scenario_bottom():
    print("=== the initializer at the bottom of the stack ===")
    src = BASE + r"\ctfe_manifest.d"
    line = find_line(src, "BP_ADDUP")
    c = Client(src)
    c.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c.request("launch", {"program": src, "importPaths": IMPORTS})
    c.request("setBreakpoints", {"source": {"path": src},
                                 "breakpoints": [{"line": line, "condition": "k == 1"}]})
    c.request("configurationDone")

    stacks = []
    while True:
        ev, msg = c.wait_event(("stopped",) + TERMINAL, 30)
        if msg is None or msg.get("event") != "stopped":
            break
        stacks.append([(f["name"], f["line"]) for f in c.frames()])
        c.send("continue", {"threadId": 1})
    for fr in stacks:
        print("  stack:", fr)
    bottoms = [fr[-1] for fr in stacks if fr]
    print("bottoms:", bottoms)
    # every stop inside addup reports the global initializer it was called from
    assert bottoms, stacks
    assert all(name != "static initialization" for name, _ in bottoms), bottoms
    lines = {l for _, l in bottoms}
    want = {find_line(src, m) for m in ("BP_MANIFEST", "BP_CONST", "BP_IMMUTABLE",
                                        "BP_ARRAY", "BP_STATICASSERT", "BP_GFN")}
    assert want == lines, (sorted(want), sorted(lines))

    # a manifest constant folded inside a function that a global initializer calls
    # shows both initializers, innermost first
    lm = find_line(src, "BP_LOCALMANIFEST")
    gfn = find_line(src, "BP_GFN")
    nested = [fr for fr in stacks if any(l == lm for _, l in fr)]
    assert nested, stacks
    assert nested[0][-1] == ("evaluating gfn()", gfn), nested[0]
    assert nested[0][-2] == ("evaluating addup(5)", lm), nested[0]
    print("terminated:", finish(c))
    print("exit:", c.close())


def scenario_template_args():
    print("=== template arguments show as locals ===")
    src = BASE + r"\ctfe_template.d"
    marks = ("BP_TWICE", "BP_VALUE", "BP_MEMBER", "BP_TUPLE")
    lines = {m: find_line(src, m) for m in marks}
    c = Client(src)
    c.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c.request("launch", {"program": src, "importPaths": IMPORTS})
    c.request("setBreakpoints", {"source": {"path": src},
                                 "breakpoints": [{"line": lines[m]} for m in marks]})
    c.request("configurationDone")

    # the arguments an instance was created with are not on the CTFE stack, so they
    # have to be read back from the instances the frame's function is nested in
    want = {lines["BP_TWICE"]: ("twice", {"T": "int", "v": "21"}),
            lines["BP_VALUE"]: ("addup", {"n": "4", "step": "3"}),
            lines["BP_MEMBER"]: ("doubled", {"T": "int"}),
            lines["BP_TUPLE"]: ("tupsum", {"Args": "[int,int,int]"})}

    seen = {}
    while True:
        ev, msg = c.wait_event(("stopped",) + TERMINAL, 30)
        if msg is None or msg.get("event") != "stopped":
            break
        frames = c.frames()
        if frames:
            line = frames[0].get("line")
            vs = local_values(c, frames[0])
            print("  %s %s: %s" % (line, frames[0].get("name"), sorted(vs.items())))
            if line in want and line not in seen:
                seen[line] = vs
                name, expected = want[line]
                assert name in (frames[0].get("name") or ""), frames[0]
                for n, v in expected.items():
                    assert vs.get(n) == v, (line, n, vs)
        c.send("continue", {"threadId": 1})
    assert sorted(seen) == sorted(want), (sorted(seen), sorted(want))
    print("terminated:", finish(c))
    print("exit:", c.close())

    # the arguments can be named in the watch and the hover window, and a variadic
    # one expands to its elements
    c2 = Client(src)
    c2.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c2.request("launch", {"program": src, "importPaths": IMPORTS})
    c2.request("setBreakpoints", {"source": {"path": src},
                                  "breakpoints": [{"line": lines["BP_TUPLE"]}]})
    c2.request("configurationDone")
    ev, _ = c2.wait_event("stopped")
    frames = c2.frames()
    fid = frames[0]["id"]
    for e in ("Args", "sum", "a"):
        r = c2.request("evaluate", {"expression": e, "frameId": fid, "context": "hover"})
        body = (r or {}).get("body")
        print("  %-6s => %s" % (e, body.get("result") if body else
                                "error: " + str((r or {}).get("message"))))
    r = c2.request("evaluate", {"expression": "Args", "frameId": fid, "context": "watch"})
    body = (r or {}).get("body") or {}
    print("  Args : %s : %s" % (body.get("result"), body.get("type")))
    vr = c2.request("variables", {"variablesReference": body.get("variablesReference", 0)})
    kids = [(v["name"], v["value"]) for v in (vr or {}).get("body", {}).get("variables", [])]
    print("      children:", kids)
    assert kids == [("[0]", "int"), ("[1]", "int"), ("[2]", "int")], kids
    print("terminated:", finish(c2))
    print("exit:", c2.close())

    # a template argument can be used in a breakpoint condition
    c3 = Client(src)
    c3.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c3.request("launch", {"program": src, "importPaths": IMPORTS})
    c3.request("setBreakpoints", {"source": {"path": src},
                                  "breakpoints": [{"line": lines["BP_VALUE"],
                                                   "condition": "n == 4"}]})
    c3.request("configurationDone")
    hits = []
    while True:
        ev, msg = c3.wait_event(("stopped",) + TERMINAL, 30)
        if msg is None or msg.get("event") != "stopped":
            break
        frames = c3.frames()
        vs = local_values(c3, frames[0]) if frames else {}
        hits.append((frames[0].get("line") if frames else None, vs.get("n"), vs.get("step")))
        c3.send("continue", {"threadId": 1})
    print("  hits:", hits)
    assert hits and all(h == (lines["BP_VALUE"], "4", "3") for h in hits), hits
    print("terminated:", finish(c3))
    print("exit:", c3.close())


def scenario_instantiation():
    print("=== template instantiations show in the call stack ===")
    src = BASE + r"\ctfe_inst.d"
    marks = ("BP_BOTTOM", "BP_RECURSE", "BP_CHAIN", "BP_SCALE", "BP_SCALE_CALL")
    ln = {m: find_line(src, m) for m in marks}

    # below a call, the instance whose generated code that call runs, located where
    # the instance was created; a recursive instance shows every level of it
    want = {ln["BP_BOTTOM"]: [("ctfe_inst.Chain!0.add", ln["BP_BOTTOM"]),
                              ("instantiating ctfe_inst.Chain!0", ln["BP_RECURSE"]),
                              ("ctfe_inst.Chain!1.add", ln["BP_RECURSE"]),
                              ("instantiating ctfe_inst.Chain!1", ln["BP_RECURSE"]),
                              ("ctfe_inst.Chain!2.add", ln["BP_RECURSE"]),
                              ("instantiating ctfe_inst.Chain!2", ln["BP_RECURSE"]),
                              ("ctfe_inst.Chain!3.add", ln["BP_RECURSE"]),
                              ("instantiating ctfe_inst.Chain!3", ln["BP_CHAIN"]),
                              ("evaluating Chain(1).add(0)", ln["BP_CHAIN"])],
            ln["BP_SCALE"]: [("ctfe_inst.scale!7", ln["BP_SCALE"]),
                             ("instantiating ctfe_inst.scale!7", ln["BP_SCALE_CALL"]),
                             ("evaluating scale(6)", ln["BP_SCALE_CALL"])]}

    c = Client(src)
    c.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c.request("launch", {"program": src, "importPaths": IMPORTS})
    c.request("setBreakpoints", {"source": {"path": src},
                                 "breakpoints": [{"line": ln[m]}
                                                 for m in ("BP_BOTTOM", "BP_SCALE")]})
    c.request("configurationDone")

    seen = {}
    while True:
        ev, msg = c.wait_event(("stopped",) + TERMINAL, 30)
        if msg is None or msg.get("event") != "stopped":
            break
        frames = c.frames()
        stack = [(f.get("name"), f.get("line")) for f in frames]
        print("  stack:", stack)
        if frames and frames[0].get("line") in want:
            line = frames[0].get("line")
            seen[line] = stack
            assert stack == want[line], (line, stack, want[line])
            # clicking an instantiation frame goes to the site the instance came from
            for f, (name, _) in zip(frames, want[line]):
                if name.startswith("instantiating "):
                    assert (f.get("source") or {}).get("path") == src, f
        c.send("continue", {"threadId": 1})
    assert sorted(seen) == sorted(want), (sorted(seen), sorted(want))
    print("terminated:", finish(c))
    print("exit:", c.close())

    # the arguments an instance was created with are the locals of its frame, and
    # they can be named in the watch and the hover window
    c2 = Client(src)
    c2.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c2.request("launch", {"program": src, "importPaths": IMPORTS})
    c2.request("setBreakpoints", {"source": {"path": src},
                                  "breakpoints": [{"line": ln["BP_BOTTOM"]}]})
    c2.request("configurationDone")
    ev, _ = c2.wait_event("stopped")
    inst = [f for f in c2.frames() if (f.get("name") or "").startswith("instantiating ")]
    assert len(inst) == 4, inst
    for k, f in enumerate(inst):
        vs = local_values(c2, f)
        r = c2.request("evaluate", {"expression": "n", "frameId": f["id"], "context": "hover"})
        body = (r or {}).get("body") or {}
        print("  %-32s locals=%-12s n => %s" % (f["name"], sorted(vs.items()), body.get("result")))
        assert vs == {"n": str(k)}, (f["name"], vs)
        assert body.get("result") == str(k), (f["name"], body, r)
    print("terminated:", finish(c2))
    print("exit:", c2.close())


    # instances nested in each other contribute one frame each, at the site that
    # created them, and without repeating an instance an outer call also runs
    src2 = BASE + r"\ctfe_nested.d"
    ln2 = {m: find_line(src2, m) for m in ("BP_ZERO", "BP_SITE", "BP_STEP", "BP_CALL")}
    c3 = Client(src2)
    c3.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c3.request("launch", {"program": src2, "importPaths": IMPORTS})
    c3.request("setBreakpoints", {"source": {"path": src2},
                                  "breakpoints": [{"line": ln2["BP_ZERO"]}]})
    c3.request("configurationDone")
    ev, _ = c3.wait_event("stopped")
    frames = c3.frames()
    stack = [(f.get("name"), f.get("line")) for f in frames]
    print("  nested stack:", stack)
    want = [("ctfe_nested.Link!0.add", ln2["BP_ZERO"]),
            ("instantiating ctfe_nested.Link!0", ln2["BP_SITE"]),
            ("ctfe_nested.Link!1.add", ln2["BP_STEP"]),
            ("instantiating ctfe_nested.Link!1", ln2["BP_SITE"]),
            ("ctfe_nested.Link!2.add", ln2["BP_STEP"]),
            ("instantiating ctfe_nested.Link!2", ln2["BP_CALL"])]
    assert stack[:len(want)] == want, stack
    assert stack[-1][0].startswith("evaluating Link") and stack[-1][1] == ln2["BP_CALL"], stack
    inst = [f for f in frames if (f.get("name") or "").startswith("instantiating ")]
    assert len(inst) == 3, inst
    for k, f in enumerate(inst):
        vs = local_values(c3, f)
        print("  %-34s locals=%s" % (f["name"], sorted(vs.items())))
        assert vs == {"n": str(k)}, (f["name"], vs)
    print("terminated:", finish(c3))
    print("exit:", c3.close())


def scenario_instance_defs():
    print("=== values and types defined by an instance show as locals ===")
    src = BASE + r"\ctfe_defs.d"
    marks = ("BP_TOTAL", "BP_SCALED")
    ln = {m: find_line(src, m) for m in marks}

    # what an instance of `Stats` or `helpers` names is fixed when the instance is
    # created and never reaches the CTFE value stack, so it has to be read back
    # from the members of the instance: the manifest constants, the aliases and the
    # enum type of `Stats!int`, and the value, the type and the symbol alias of
    # `helpers!int`
    want = {ln["BP_TOTAL"]: {"dim": ("3", "int"),
                             "sorted": ("false", "bool"),
                             "Shape": ("Shape", "type"),
                             "first": ("Shape.wide", "Shape"),
                             "Elem": ("int", "type"),
                             "Row": ("int[3]", "type")},
            ln["BP_SCALED"]: {"factor": ("4", "int"),
                              "Elem": ("int", "type"),
                              "twice": ("makeTwice", "alias")}}

    c = Client(src)
    c.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c.request("launch", {"program": src, "importPaths": IMPORTS})
    c.request("setBreakpoints", {"source": {"path": src},
                                 "breakpoints": [{"line": ln[m]} for m in marks]})
    c.request("configurationDone")

    seen = {}
    while True:
        ev, msg = c.wait_event(("stopped",) + TERMINAL, 30)
        if msg is None or msg.get("event") != "stopped":
            break
        frames = c.frames()
        if frames:
            line = frames[0].get("line")
            vs = local_types(c, frames[0])
            print("  %s %s: %s" % (line, frames[0].get("name"), sorted(vs.items())))
            if line in want and line not in seen:
                seen[line] = vs
                for n, vt in want[line].items():
                    assert vs.get(n) == vt, (line, n, vs.get(n), vt)
                # what the instance generates rather than names is no local of it
                for n in ("cells", "total", "scaled", "makeTwice"):
                    assert n not in vs, (line, n, vs)
        c.send("continue", {"threadId": 1})
    assert sorted(seen) == sorted(want), (sorted(seen), sorted(want))
    print("terminated:", finish(c))
    print("exit:", c.close())

    # the frame of the instantiation reports the definitions of that instance as
    # its own locals, and an instance of a template that declares an aggregate
    # shows what the aggregate it becomes names
    c2 = Client(src)
    c2.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c2.request("launch", {"program": src, "importPaths": IMPORTS})
    c2.request("setBreakpoints", {"source": {"path": src},
                                  "breakpoints": [{"line": ln["BP_TOTAL"]}]})
    c2.request("configurationDone")
    ev, _ = c2.wait_event("stopped")
    frames = c2.frames()
    names = [f.get("name") for f in frames]
    print("  stack:", [(f.get("name"), f.get("line")) for f in frames])
    inst = [f for f in frames if (f.get("name") or "").startswith("instantiating ")]
    assert [f["name"] for f in inst] == ["instantiating ctfe_defs.Stats!int.total!2",
                                         "instantiating ctfe_defs.Stats!int"], names
    want_inst = {"instantiating ctfe_defs.Stats!int.total!2": {"k": ("2", "int")},
                 "instantiating ctfe_defs.Stats!int": dict(
                     {"T": ("int", "type")}, **want[ln["BP_TOTAL"]])}
    for f in inst:
        vs = local_types(c2, f)
        print("  %-40s locals=%s" % (f["name"], sorted(vs.items())))
        assert vs == want_inst[f["name"]], (f["name"], vs)

    # the values are read as values, the types as types
    fid = frames[0]["id"]
    for expr, val in (("dim", "3"), ("dim * 2", "6"), ("sorted", "false"),
                      ("first", "Shape.wide"), ("Elem", "int"), ("Row", "int[3]")):
        r = c2.request("evaluate", {"expression": expr, "frameId": fid,
                                    "context": "hover"})
        body = (r or {}).get("body")
        print("  %-8s => %s" % (expr, body.get("result") if body else
                                "error: " + str((r or {}).get("message"))))
        assert body is not None and body.get("result") == val, (expr, r)
    # a type has no value to compute on
    r = c2.request("evaluate", {"expression": "Row.length", "frameId": fid,
                                "context": "hover"})
    print("  Row.length => %s" % (r or {}).get("message"))
    assert not (r or {}).get("success"), r
    assert "is not a value" in (r or {}).get("message"), r
    print("terminated:", finish(c2))
    print("exit:", c2.close())

    # a definition of an instance can be used in a breakpoint condition
    for cond, hits in (("dim == 3", 3), ("dim == 4", 0)):
        c3 = Client(src)
        c3.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
        c3.request("launch", {"program": src, "importPaths": IMPORTS})
        c3.request("setBreakpoints", {"source": {"path": src},
                                      "breakpoints": [{"line": ln["BP_TOTAL"],
                                                       "condition": cond}]})
        c3.request("configurationDone")
        got = []
        while True:
            ev, msg = c3.wait_event(("stopped",) + TERMINAL, 30)
            if msg is None or msg.get("event") != "stopped":
                break
            got.append(local_values(c3, c3.frames()[0]).get("dim"))
            c3.send("continue", {"threadId": 1})
        print("  condition %-10s hits: %s" % (cond, got))
        assert got == ["3"] * hits, (cond, got)
        print("terminated:", finish(c3))
        print("exit:", c3.close())


def scenario_return():
    print("=== the return of a call is a step of its own ===")
    src = BASE + r"\ctfe_ret.d"
    marks = ("BP_CALL", "RET_TOTAL", "RET_SCALED", "BP_ENUM")
    ln = {m: find_line(src, m) for m in marks}
    want_scaled = {"$returnValue": ("20", "int"), "arr": ("[1, 2, 3]", "int[]"),
                   "factor": ("4", "int"), "base": ("6", "int")}
    want_call = {"$returnValue": ("6", "int"), "arr": ("[1, 2, 3]", "int[]"),
                 "factor": ("4", "int"), "base": ("", "int")}
    want_enum = {"$returnValue": ("20", "int")}

    def steps(c, command, n):
        out = []
        for _ in range(n):
            c.send(command, {"threadId": 1})
            ev, _ = c.wait_event("stopped", 20)
            frames = c.frames()
            vs = local_types(c, frames[0]) if frames else {}
            out.append((ev and ev.get("reason"),
                        frames and (frames[0]["name"], frames[0]["line"]), vs))
        return out

    # stepping over the call line runs the call through to the end of the caller's
    # own statement; the step off that line ends where the value goes back to, and
    # reports the value in the frame reported there
    c = Client(src)
    c.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c.request("launch", {"program": src, "importPaths": IMPORTS})
    c.request("setBreakpoints", {"source": {"path": src},
                                 "breakpoints": [{"line": ln["BP_CALL"]}]})
    c.request("configurationDone")
    ev, _ = c.wait_event("stopped")
    frames = c.frames()
    print("  stop:", ev and ev.get("reason"), [(f.get("name"), f.get("line")) for f in frames])
    assert frames and frames[0].get("line") == ln["BP_CALL"], frames

    got = steps(c, "next", 2)
    for r_, at, vs in got:
        print("  stepOver: %s %s %s" % (r_, at, sorted(vs.items())))
    assert got[0] == ("step", ("ctfe_ret.scaled", ln["RET_SCALED"]),
                      {k: v for k, v in want_scaled.items() if k != "$returnValue"}), got[0]
    # the step off the return does not stop again on the line it is already on: it
    # ends at the declaration of the constant the evaluation started from, where the
    # value the call hands back has become the value of the constant
    assert got[1] == ("step", ("evaluating scaled([1, 2, 3])", ln["BP_ENUM"]),
                      want_enum), got[1]

    # the value is a name of the frame the stop reports, so hover, watch and
    # immediate can read it and compute with it; the locals of the frame that
    # returned are no names of that frame
    fid = c.frames()[0]["id"]
    for expr, val in (("$returnValue", "20"), ("$returnValue + 1", "21"),
                      ("$returnValue * 2", "40"), ("factor", "error"),
                      ("$returnValue.length", "error")):
        r = c.request("evaluate", {"expression": expr, "frameId": fid, "context": "hover"})
        body = (r or {}).get("body")
        print("  %-22s => %s" % (expr, body.get("result") if body else
                                 "error: " + str((r or {}).get("message"))))
        if val == "error":
            assert not (r or {}).get("success"), (expr, r)
        else:
            assert body is not None and body.get("result") == val, (expr, r)
    print("  terminated:", finish(c))
    print("  exit:", c.close())

    # stepping into a call ends at the statement of the caller the call is written
    # in: the step off the return of the callee does not report the line it is
    # already on, and the value comes back with the frame it goes back to
    c2 = Client(src)
    c2.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c2.request("launch", {"program": src, "importPaths": IMPORTS})
    c2.request("setBreakpoints", {"source": {"path": src},
                                  "breakpoints": [{"line": ln["BP_CALL"]}]})
    c2.request("configurationDone")
    ev, _ = c2.wait_event("stopped")
    sweep, ret = [], None
    for _ in range(30):
        c2.send("stepIn", {"threadId": 1})
        ev, _ = c2.wait_event("stopped", 20)
        frames = c2.frames()
        if not frames:
            break
        vs = local_types(c2, frames[0])
        sweep.append((frames[0]["name"], frames[0]["line"],
                      vs.get("$returnValue", (None,))[0]))
        if "$returnValue" in vs:
            ret = (frames[0], vs)
            break
    for s in sweep:
        print("  stepIn: %s %s %s" % s)
    assert ret, sweep
    frame, vs = ret
    print("  back at the call site: %s %s %s" % (frame["name"], frame["line"],
                                                 sorted(vs.items())))
    assert frame["line"] == ln["BP_CALL"], frame
    assert frame["name"] == "ctfe_ret.scaled", frame
    assert vs == want_call, vs

    # the value the call handed back is a name of the caller's frame at the call
    # site, while the assignment to the result of the call has not run yet; the
    # step on from there goes on in the caller, and the step off its return ends at
    # the declaration of the constant
    after = steps(c2, "stepIn", 2)
    print("  on from the call site:", after[0][0], after[0][1], sorted(after[0][2].items()))
    assert after[0][1] == ("ctfe_ret.scaled", ln["RET_SCALED"]), after[0]
    assert "$returnValue" not in after[0][2], after[0]
    assert after[0][2].get("base") == ("6", "int"), after[0][2]
    print("  off the return:", after[1][0], after[1][1], sorted(after[1][2].items()))
    assert after[1][1] == ("evaluating scaled([1, 2, 3])", ln["BP_ENUM"]), after[1]
    assert after[1][2] == want_enum, after[1][2]
    print("  terminated:", finish(c2))
    print("  exit:", c2.close())

    # a plain continue is no step: it runs through the returns, which stay on the
    # lines the breakpoints already cover
    c3 = Client(src)
    c3.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c3.request("launch", {"program": src, "importPaths": IMPORTS})
    marked = ("BP_ENUM", "RET_TOTAL", "RET_SCALED")
    c3.request("setBreakpoints", {"source": {"path": src},
                                  "breakpoints": [{"line": ln[m]} for m in marked]})
    c3.request("configurationDone")
    hits = []
    while True:
        ev, msg = c3.wait_event(("stopped",) + TERMINAL, 30)
        if msg is None or msg.get("event") != "stopped":
            break
        frames = c3.frames()
        vs = local_types(c3, frames[0]) if frames else {}
        hits.append((ev.get("reason"), frames and frames[0].get("line"),
                     "$returnValue" in vs))
        c3.send("continue", {"threadId": 1})
    print("  hits:", hits)
    assert [h[0] for h in hits] == ["breakpoint"] * len(hits), hits
    assert [h[1] for h in hits] == [ln[m] for m in marked], hits
    assert not any(h[2] for h in hits), hits
    print("  terminated:", finish(c3))
    print("  exit:", c3.close())


def scenario_stepout():
    print("=== stepping out of a call ends at the call site ===")
    src = BASE + r"\ctfe_stepout.d"
    marks = ("CALL_TOTAL", "RET_SCALED", "CALL_SCALED", "SAY_BODY", "CALL_SAY",
             "RET_TWICE", "BP_ENTRY")
    ln = {m: find_line(src, m) for m in marks}

    def top(frames):
        return (frames[0]["name"], frames[0]["line"]) if frames else None

    def step(c, command=None):
        """Sends command and collects the stop it ends at: the event, the frames of
        the stop and the locals of its innermost frame.  A session that runs to its
        end reports no stop and no frames."""
        if command:
            c.send(command, {"threadId": 1})
        _, msg = c.wait_event(("stopped",) + TERMINAL, 30)
        if msg is None or msg.get("event") != "stopped":
            return msg, [], {}
        frames = c.frames()
        return msg, frames, (local_types(c, frames[0]) if frames else {})

    c = Client(src)
    c.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c.request("launch", {"program": src, "importPaths": IMPORTS})
    c.request("setBreakpoints", {"source": {"path": src},
                                 "breakpoints": [{"line": ln["CALL_TOTAL"]}]})
    c.request("configurationDone")
    msg, frames, vs = step(c)
    print("  stop: %s %s %s" % (msg and msg.get("body", {}).get("reason"), top(frames),
                                [(f.get("name"), f.get("line")) for f in frames]))
    assert top(frames) == ("ctfe_stepout.scaled", ln["CALL_TOTAL"]), frames

    # step into the call first, so that there is a call to step out of
    msg, frames, vs = step(c, "stepIn")
    print("  stepIn: %s %s" % (top(frames), sorted(vs.items())))
    assert top(frames)[0] == "ctfe_stepout.total", frames

    # stepping out ends on the line the call is written on, in the frame the value
    # goes back to: the frame that left has gone off the stack, and its locals with it
    msg, frames, vs = step(c, "stepOut")
    print("  stepOut: %s %s %s" % (msg and msg.get("body", {}).get("reason"),
                                   top(frames), sorted(vs.items())))
    assert msg and msg.get("body", {}).get("reason") == "step", msg
    assert top(frames) == ("ctfe_stepout.scaled", ln["CALL_TOTAL"]), frames
    assert [(f.get("name"), f.get("line")) for f in frames][1:2] == \
        [("ctfe_stepout.twice", ln["CALL_SCALED"])], frames
    assert vs.get("$returnValue") == ("6", "int"), vs
    assert "arr" in vs and "factor" in vs, vs
    assert not any(n in vs for n in ("sum", "e")), vs

    # the value is a name of the frame the stop reports, so hover, watch and
    # immediate can read it and compute with the locals of that frame
    fid = frames[0]["id"]
    for expr, val in (("$returnValue", "6"), ("$returnValue + 1", "7"),
                      ("$returnValue * factor", "24"), ("$returnValue * v", "error")):
        r = c.request("evaluate", {"expression": expr, "frameId": fid, "context": "hover"})
        body = (r or {}).get("body")
        print("  %-22s => %s" % (expr, body.get("result") if body else
                                 "error: " + str((r or {}).get("message"))))
        if val == "error":
            assert not (r or {}).get("success"), (expr, r)
        else:
            assert body is not None and body.get("result") == val, (expr, r)

    # the stop is a step of the caller: the statement below the call runs on from it
    msg, frames, vs = step(c, "next")
    print("  next: %s %s" % (top(frames), sorted(vs.items())))
    assert top(frames) == ("ctfe_stepout.scaled", ln["RET_SCALED"]), frames
    assert "$returnValue" not in vs, vs

    # stepping out of that frame reports the call its own value came back from
    msg, frames, vs = step(c, "stepOut")
    print("  stepOut: %s %s %s" % (msg and msg.get("body", {}).get("reason"),
                                   top(frames), sorted(vs.items())))
    assert top(frames) == ("ctfe_stepout.twice", ln["CALL_SCALED"]), frames
    assert vs.get("$returnValue") == ("20", "int"), vs
    assert "arr" in vs and "v" in vs, vs
    assert not any(n in vs for n in ("factor", "base")), vs

    # the statement below the call runs on, and a call of it that hands nothing
    # back ends at its own call site without a value
    msg, frames, vs = step(c, "next")
    print("  next: %s %s" % (top(frames), sorted(vs.items())))
    assert top(frames) == ("ctfe_stepout.twice", ln["CALL_SAY"]), frames

    msg, frames, vs = step(c, "stepIn")
    print("  stepIn: %s %s" % (top(frames), sorted(vs.items())))
    assert top(frames) == ("ctfe_stepout.say", ln["SAY_BODY"]), frames

    msg, frames, vs = step(c, "stepOut")
    print("  stepOut: %s %s %s" % (msg and msg.get("body", {}).get("reason"),
                                   top(frames), sorted(vs.items())))
    assert top(frames) == ("ctfe_stepout.twice", ln["CALL_SAY"]), frames
    assert "$returnValue" not in vs, vs
    assert "arr" in vs and "v" in vs, vs
    assert "n" not in vs, vs

    msg, frames, vs = step(c, "next")
    print("  next: %s %s" % (top(frames), sorted(vs.items())))
    assert top(frames) == ("ctfe_stepout.twice", ln["RET_TWICE"]), frames

    # out of the call the compile time evaluation started from, the constant whose
    # evaluation it is is the frame the value goes back to: the step ends at the
    # declaration of that constant, and the value the call hands back is reported
    # as the value of the constant
    msg, frames, vs = step(c, "stepOut")
    print("  stepOut to the declaration: %s %s %s" % (
        msg and msg.get("body", {}).get("reason"), top(frames), sorted(vs.items())))
    assert msg and msg.get("body", {}).get("reason") == "step", msg
    assert [(f.get("name"), f.get("line")) for f in frames] == [
        ("evaluating twice([1, 2, 3])", ln["BP_ENTRY"])], frames
    assert vs.get("$returnValue") == ("60", "int"), vs
    assert not any(n in vs for n in ("arr", "v", "factor", "base", "sum", "e", "n")), vs

    # the value is a name of the frame of the declaration, so hover, watch and
    # immediate can read the value the constant was folded to
    fid = frames[0]["id"]
    for expr, val in (("$returnValue", "60"), ("$returnValue + 1", "61")):
        r = c.request("evaluate", {"expression": expr, "frameId": fid, "context": "hover"})
        body = (r or {}).get("body")
        print("  %-22s => %s" % (expr, body.get("result") if body else
                                 "error: " + str((r or {}).get("message"))))
        assert body is not None and body.get("result") == val, (expr, r)

    # the evaluation of the constant is over: going on ends the session
    print("  terminated:", finish(c))
    print("  exit:", c.close())

    # single stepping off the return of the call the evaluation started from ends at
    # the same declaration: the return does not report the line the step is already
    # on, and there is no caller of the program to go on in
    c2 = Client(src)
    c2.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c2.request("launch", {"program": src, "importPaths": IMPORTS})
    c2.request("setBreakpoints", {"source": {"path": src},
                                  "breakpoints": [{"line": ln["RET_TWICE"]}]})
    c2.request("configurationDone")

    msg, frames, vs = step(c2)
    assert top(frames) == ("ctfe_stepout.twice", ln["RET_TWICE"]), frames

    msg, frames, vs = step(c2, "next")
    print("  next over the return: %s %s %s" % (
        msg and msg.get("body", {}).get("reason"), top(frames), sorted(vs.items())))
    assert msg and msg.get("body", {}).get("reason") == "step", msg
    assert [(f.get("name"), f.get("line")) for f in frames] == [
        ("evaluating twice([1, 2, 3])", ln["BP_ENTRY"])], frames
    assert vs.get("$returnValue") == ("60", "int"), vs
    assert not any(n in vs for n in ("arr", "v", "factor", "base", "sum", "e", "n")), vs
    assert [(f.get("name"), f.get("line")) for f in frames] == [
        ("evaluating twice([1, 2, 3])", ln["BP_ENTRY"])], frames
    assert vs.get("$returnValue") == ("60", "int"), vs
    assert not any(n in vs for n in ("arr", "v", "factor", "base", "sum", "e", "n")), vs

    fid = frames[0]["id"]
    r = c2.request("evaluate", {"expression": "$returnValue + 1", "frameId": fid,
                                "context": "hover"})
    body = (r or {}).get("body")
    print("  %-22s => %s" % ("$returnValue + 1", body.get("result") if body else
                             "error: " + str((r or {}).get("message"))))
    assert body is not None and body.get("result") == "61", r

    # the step ends the stepping: what the front end interprets next is code of
    # its own, and the step from the declaration reaches the constant it folds
    msg, frames, vs = step(c2, "next")
    print("  next on: %s" % (top(frames),))
    assert frames, frames
    print("  terminated:", finish(c2))
    print("  exit:", c2.close())

    # a continue from the declaration of a constant runs past it: the value of a
    # constant is no position a running session stops at
    c3 = Client(src)
    c3.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c3.request("launch", {"program": src, "importPaths": IMPORTS})
    c3.request("setBreakpoints", {"source": {"path": src},
                                  "breakpoints": [{"line": ln["RET_TWICE"]}]})
    c3.request("configurationDone")
    msg, frames, vs = step(c3)
    assert top(frames) == ("ctfe_stepout.twice", ln["RET_TWICE"]), frames
    msg, frames, vs = step(c3, "next")
    assert top(frames) == ("evaluating twice([1, 2, 3])", ln["BP_ENTRY"]), frames
    c3.send("continue", {"threadId": 1})
    _, msg = c3.wait_event(("stopped",) + TERMINAL, 30)
    print("  continue from the declaration: %s" % (msg and msg.get("event"),))
    assert msg is not None and msg.get("event") in TERMINAL, msg
    print("  exit:", c3.close())

    # from the declaration of a constant whose initializer has not run, `next` steps
    # over the whole call and lands back on the declaration, where the value the call
    # hands back has become the value of the constant
    c4 = Client(src)
    c4.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c4.request("launch", {"program": src, "importPaths": IMPORTS})
    c4.request("setBreakpoints", {"source": {"path": src},
                                  "breakpoints": [{"line": ln["BP_ENTRY"]}]})
    c4.request("configurationDone")
    msg, frames, vs = step(c4)
    assert top(frames) == ("evaluating twice([1, 2, 3])", ln["BP_ENTRY"]), frames
    assert "$returnValue" not in vs, vs
    msg, frames, vs = step(c4, "next")
    print("  next over the initializer: %s %s" % (top(frames), sorted(vs.items())))
    assert top(frames) == ("evaluating twice([1, 2, 3])", ln["BP_ENTRY"]), frames
    assert vs.get("$returnValue") == ("60", "int"), vs
    print("  terminated:", finish(c4))
    print("  exit:", c4.close())

    # stepping out of the return of the call the evaluation started from ends at the
    # declaration of the constant too: the constant is the frame above that call
    c5 = Client(src)
    c5.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c5.request("launch", {"program": src, "importPaths": IMPORTS})
    c5.request("setBreakpoints", {"source": {"path": src},
                                  "breakpoints": [{"line": ln["RET_TWICE"]}]})
    c5.request("configurationDone")
    msg, frames, vs = step(c5)
    assert top(frames) == ("ctfe_stepout.twice", ln["RET_TWICE"]), frames
    msg, frames, vs = step(c5, "stepOut")
    print("  stepOut from the return: %s %s %s" % (
        msg and msg.get("body", {}).get("reason"), top(frames), sorted(vs.items())))
    assert msg and msg.get("body", {}).get("reason") == "step", msg
    assert [(f.get("name"), f.get("line")) for f in frames] == [
        ("evaluating twice([1, 2, 3])", ln["BP_ENTRY"])], frames
    assert vs.get("$returnValue") == ("60", "int"), vs
    assert not any(n in vs for n in ("arr", "v", "factor", "base", "sum", "e", "n")), vs
    print("  terminated:", finish(c5))
    print("  exit:", c5.close())

    # the step off the return of a call ends at the statement of the caller the call
    # is written in: it does not report the line the step is already on, the value
    # has become a name of the caller's frame, and the step after it is the one that
    # goes into the next call
    c6 = Client(src)
    c6.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c6.request("launch", {"program": src, "importPaths": IMPORTS})
    c6.request("setBreakpoints", {"source": {"path": src},
                                  "breakpoints": [{"line": ln["RET_SCALED"]}]})
    c6.request("configurationDone")
    msg, frames, vs = step(c6)
    assert top(frames) == ("ctfe_stepout.scaled", ln["RET_SCALED"]), frames

    msg, frames, vs = step(c6, "next")
    print("  next from the return: %s %s %s" % (
        msg and msg.get("body", {}).get("reason"), top(frames), sorted(vs.items())))
    assert msg and msg.get("body", {}).get("reason") == "step", msg
    assert top(frames) == ("ctfe_stepout.twice", ln["CALL_SCALED"]), frames
    assert vs.get("$returnValue") == ("20", "int"), vs
    assert vs.get("v") == ("", "int"), vs
    assert [(f.get("name"), f.get("line")) for f in frames][1:2] == \
        [("evaluating twice([1, 2, 3])", ln["BP_ENTRY"])], frames

    msg, frames, vs = step(c6, "next")
    print("  next on from the call site: %s %s %s" % (
        msg and msg.get("body", {}).get("reason"), top(frames), sorted(vs.items())))
    assert top(frames) == ("ctfe_stepout.twice", ln["CALL_SAY"]), frames
    assert "$returnValue" not in vs, vs
    assert vs.get("v") == ("20", "int"), vs
    print("  terminated:", finish(c6))
    print("  exit:", c6.close())


def scenario_instance_values():
    print("=== instance values and types name their arguments ===")
    src = BASE + r"\ctfe_values.d"
    marks = ("BP_PROBE", "BP_CELL", "BP_NODE")
    ln = {m: find_line(src, m) for m in marks}
    c = Client(src)
    c.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c.request("launch", {"program": src, "importPaths": IMPORTS})
    c.request("setBreakpoints", {"source": {"path": src},
                                 "breakpoints": [{"line": ln[m]} for m in marks]})
    c.request("configurationDone")

    # a value of an instance type names the arguments the instance was created with,
    # spelled as the compiler spells it: no parentheses around a basic type or a
    # literal, parentheses around an instance or a list of arguments, and a class
    # named with the module it belongs to
    want = {
        ln["BP_PROBE"]: ("ctfe_values.test", {
            "fp": ("& fn!int", None),
            "b": ("Box!int(3)", "Box!int"),
            "p": ('Pair!(int, string)(7, "hi")', "Pair!(int, string)"),
            "cell": ("Cell!7(3)", "Cell!7"),
            "obj": ("ctfe_values.Obj!(Box!int)(Box!int(9))", "ctfe_values.Obj!(Box!int)")}),
        ln["BP_CELL"]: ("ctfe_values.Cell!7.get", {
            "this": ("Cell!7(3)", "Cell!7")}),
        ln["BP_NODE"]: ("ctfe_values.Node!(Node!(Leaf)).sum", {
            "this": ("Node!(Node!(Leaf))(1, Node!(Leaf)(3, Leaf(4)))", "Node!(Node!(Leaf))"),
            "T": ("Node!(Leaf)", "type")}),
    }

    seen = {}
    while True:
        ev, msg = c.wait_event(("stopped",) + TERMINAL, 30)
        if msg is None or msg.get("event") != "stopped":
            break
        frames = c.frames()
        if frames:
            line = frames[0].get("line")
            vs = local_types(c, frames[0])
            print("  %s %s: %s" % (line, frames[0].get("name"), sorted(vs.items())))
            if line in want and line not in seen:
                seen[line] = vs
                name, expected = want[line]
                assert name in (frames[0].get("name") or ""), frames[0]
                for n, (v, t) in expected.items():
                    assert n in vs, (line, n, sorted(vs))
                    assert vs[n][0] == v, (line, n, vs[n])
                    if t is not None:
                        assert vs[n][1] == t, (line, n, vs[n])
        c.send("continue", {"threadId": 1})
    assert sorted(seen) == sorted(want), (sorted(seen), sorted(want))
    print("terminated:", finish(c))
    print("exit:", c.close())

    # the hover reads the same text, and finds only what the frame it is hovering
    # over knows: the locals of the frames it was called from are not in scope
    c2 = Client(src)
    c2.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c2.request("launch", {"program": src, "importPaths": IMPORTS})
    c2.request("setBreakpoints", {"source": {"path": src},
                                  "breakpoints": [{"line": ln["BP_CELL"]}]})
    c2.request("configurationDone")
    ev, _ = c2.wait_event("stopped")
    frames = c2.frames()
    assert frames and "Cell!7" in (frames[0].get("name") or ""), frames
    fid = frames[0]["id"]
    for expr, val in (("this", "Cell!7(3)"), ("bi", "Box!int(3)"), ("c7", "Cell!7(3)"),
                      ("n", "7"), ("b", "error")):
        r = c2.request("evaluate", {"expression": expr, "frameId": fid, "context": "hover"})
        body = (r or {}).get("body")
        print("  %-10s => %s" % (expr, body.get("result") if body else
                                 "error: " + str((r or {}).get("message"))))
        if val == "error":
            assert not (r or {}).get("success"), (expr, r)
        else:
            assert body is not None and body.get("result") == val, (expr, r)
    print("terminated:", finish(c2))
    print("exit:", c2.close())


def scenario_class_fields():
    print("=== class instances expand the fields of the instance ===")
    src = BASE + r"\ctfe_class.d"
    marks = ("BP_LOCAL", "BP_ARG", "BP_METHOD")
    ln = {m: find_line(src, m) for m in marks}
    c = Client(src)
    c.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c.request("launch", {"program": src, "importPaths": IMPORTS})
    c.request("setBreakpoints", {"source": {"path": src},
                                 "breakpoints": [{"line": ln[m]} for m in marks]})
    c.request("configurationDone")

    # a value of a class is a reference to an instance, and the values of the
    # fields are stored in the instance: they are the children of the value, those
    # of the base classes first.  The references another value holds, the argument
    # of a call and the `this` of a member function read the same way.
    want = {
        ln["BP_LOCAL"]: ("ctfe_class.make", {
            "t": ("ctfe_class.Triangle(3, \"tri\", 7.5)", "ctfe_class.Triangle"),
            "t.sides": ("3", "int"),
            "t.name": ('"tri"', "string"),
            "t.perimeter": ("7.5", "double"),
            "nm.label": ('"holder"', "string"),
            "nm.shape": ("ctfe_class.Shape(3, \"tri\", 7.5)", "ctfe_class.Shape"),
            "nm.shape.sides": ("3", "int"),
            "nm.shape.name": ('"tri"', "string"),
            "nm.shape.perimeter": ("7.5", "double"),
            "h.owner": ('ctfe_class.Named("holder", ctfe_class.Shape(3, "tri", 7.5))',
                        "ctfe_class.Named"),
            "h.owner.shape.perimeter": ("7.5", "double"),
            "h.count": ("2", "int")}),
        ln["BP_ARG"]: ("ctfe_class.sidesOf", {
            "s.sides": ("3", "int"),
            "s.name": ('"tri"', "string"),
            "s.perimeter": ("7.5", "double")}),
        ln["BP_METHOD"]: ("ctfe_class.Shape.twice", {
            "this.sides": ("3", "int"),
            "this.name": ('"tri"', "string"),
            "this.perimeter": ("7.5", "double")}),
    }

    seen = {}
    while True:
        ev, msg = c.wait_event(("stopped",) + TERMINAL, 30)
        if msg is None or msg.get("event") != "stopped":
            break
        frames = c.frames()
        if frames:
            line = frames[0].get("line")
            tree = local_tree(c, frames[0])
            print("  %s %s: %s" % (line, frames[0].get("name"),
                                   sorted(p for p in tree if "." in p)))
            if line in want and line not in seen:
                seen[line] = tree
                name, expected = want[line]
                assert name in (frames[0].get("name") or ""), frames
                for path, (v, t) in expected.items():
                    assert path in tree, (line, path, sorted(tree))
                    assert tree[path][0] == v, (line, path, tree[path])
                    assert tree[path][1] == t, (line, path, tree[path])
                if line == ln["BP_LOCAL"]:
                    # a null reference has no instance to expand
                    assert tree.get("none") == ("null", "ctfe_class.Shape", False), tree.get("none")
        c.send("continue", {"threadId": 1})
    assert sorted(seen) == sorted(want), (sorted(seen), sorted(want))
    print("terminated:", finish(c))
    print("exit:", c.close())

    # the watch reads the same tree: an expression that names an instance is a
    # variable like a local is, and gets the fields of the instance as children
    c2 = Client(src)
    c2.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c2.request("launch", {"program": src, "importPaths": IMPORTS})
    c2.request("setBreakpoints", {"source": {"path": src},
                                  "breakpoints": [{"line": ln["BP_LOCAL"]}]})
    c2.request("configurationDone")
    ev, _ = c2.wait_event("stopped")
    frames = c2.frames()
    assert frames and "make" in (frames[0].get("name") or ""), frames
    fid = frames[0]["id"]
    fields = ["sides", "name", "perimeter"]
    for expr, (value, children) in (
            ("t", ("ctfe_class.Triangle(3, \"tri\", 7.5)", fields)),
            ("nm.shape", ("ctfe_class.Shape(3, \"tri\", 7.5)", fields)),
            ("h.owner.shape", ("ctfe_class.Shape(3, \"tri\", 7.5)", fields)),
            ("none", ("null", []))):
        r = c2.request("evaluate", {"expression": expr, "frameId": fid, "context": "watch"})
        body = (r or {}).get("body")
        assert body and body.get("result") == value, (expr, r)
        ref = body.get("variablesReference", 0)
        got = []
        if ref:
            vr = c2.request("variables", {"variablesReference": ref})
            got = [v["name"] for v in (vr or {}).get("body", {}).get("variables", [])]
        print("  %-14s => %s  %s" % (expr, value, got))
        assert got == children, (expr, got)

    # a member of an instance reads like a member of a struct: the name the locals
    # window shows is the name the watch can write
    for expr, value in (("nm.shape.sides", "3"),
                        ("nm.shape.name", '"tri"'),
                        ("t.perimeter", "7.5"),
                        ("h.owner.label", '"holder"'),
                        ("h.owner.shape.perimeter", "7.5")):
        r = c2.request("evaluate", {"expression": expr, "frameId": fid, "context": "watch"})
        body = (r or {}).get("body")
        print("  %-24s => %s" % (expr, body.get("result") if body else
                                 "error: " + str((r or {}).get("message"))))
        assert body and body.get("result") == value, (expr, r)
    print("terminated:", finish(c2))
    print("exit:", c2.close())


def scenario_conditions():
    print("=== breaking on static conditions ===")
    src = BASE + r"\ctfe_cond.d"
    marks = ("BP_CONSTRAINT", "BP_STATICIF", "BP_ASSERT", "BP_STATICASSERT", "BP_ENUM")
    ln = {m: find_line(src, m) for m in marks}
    c = Client(src)
    c.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c.request("launch", {"program": src, "importPaths": IMPORTS})
    c.request("setBreakpoints", {"source": {"path": src},
                                 "breakpoints": [{"line": ln[m]} for m in marks]})
    c.request("configurationDone")

    # The answer to a template constraint, or to the condition of a `static if` or
    # of a `static assert`, is known while the front end works the program out,
    # where no statement is being interpreted: a breakpoint on the line the
    # condition is written at stops there, with the condition as the frame and the
    # instance it is written in below it.  The clauses are written with the
    # parameters of that instance, so those are the locals of the frame.
    want = {
        ln["BP_CONSTRAINT"]: ("template constraint (is(T == int) || is(T == double))",
                              "instantiating ctfe_cond.combine!int", {"T": "int"}),
        ln["BP_STATICIF"]: ("static if (is(T == int) && big(3))",
                            "instantiating ctfe_cond.combine!int", {"T": "int"}),
        ln["BP_STATICASSERT"]: ("static assert (combine(2, 3) == 5)", None, {}),
    }

    hits = {}
    while True:
        ev, msg = c.wait_event(("stopped",) + TERMINAL, 30)
        if msg is None or msg.get("event") != "stopped":
            break
        frames = c.frames()
        top = frames[0] if frames else {}
        line = top.get("line")
        stack = [(f.get("name") or "", f.get("line")) for f in frames]
        print("  %s %s: %s" % (ev.get("reason"), line, stack))
        if line in want:
            name, below, args = want[line]
            assert name in (top.get("name") or ""), frames
            sites = [f.get("line") for f in frames
                     if (f.get("name") or "").startswith("instantiating")]
            assert bool(sites) == (below is not None), frames
            vals = local_values(c, top)
            for n, v in args.items():
                assert vals.get(n) == v, (line, n, vals)
            hits.setdefault(line, []).append(sites)
        c.send("continue", {"threadId": 1})

    # A condition is answered whenever the front end needs the answer: the
    # constraint of `combine` is asked again for the second instance the program
    # creates, while the body of an instance is generated once, so the `static if`
    # written in it is answered once.  Which instantiation each answer belongs to
    # is on the stack below the condition.
    assert hits.get(ln["BP_CONSTRAINT"]) == [[ln["BP_ENUM"]], [ln["BP_STATICASSERT"]]], hits
    assert hits.get(ln["BP_STATICIF"]) == [[ln["BP_ENUM"]]], hits
    assert hits.get(ln["BP_STATICASSERT"]) == [[]], hits
    print("terminated:", finish(c))
    print("exit:", c.close())

    # Stepping goes on into the calls the clauses of a condition contain, and back
    # to the condition with the value the call handed back.  A step does not stop
    # at a condition of its own: the front end answers the conditions of the
    # runtime library too, and those would be walked through before any line of
    # the program is reached.
    c = Client(src)
    c.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c.request("launch", {"program": src, "importPaths": IMPORTS})
    c.request("setBreakpoints", {"source": {"path": src},
                                 "breakpoints": [{"line": ln["BP_STATICIF"]}]})
    c.request("configurationDone")
    ev, _ = c.wait_event("stopped")
    frames = c.frames()
    assert frames and "static if" in (frames[0].get("name") or ""), frames
    steps = []
    for i in range(3):
        c.send("stepIn", {"threadId": 1})
        ev, _ = c.wait_event("stopped")
        frames = c.frames()
        top = frames[0] if frames else {}
        steps.append((top.get("name") or "", top.get("line")))
        print("  step %d: %s" % (i + 1, steps[-1]))
    assert "big(3)" in steps[0][0], steps
    assert "ctfe_cond.big" in steps[1][0], steps
    assert "big(3)" in steps[2][0], steps
    vals = local_values(c, frames[0])
    print("  locals at the call: %s" % (sorted(vals.items()),))
    assert vals.get("$returnValue") == "true", vals
    print("terminated:", finish(c))
    print("exit:", c.close())


def scenario_condition_instances():
    print("=== the arguments of the instance a static condition is written in ===")
    src = BASE + r"\ctfe_cond2.d"
    marks = ("BP_PICKCONSTRAINT", "BP_STATICIF", "BP_BOXCONSTRAINT", "BP_BOXIF",
             "BP_BOXASSERT", "BP_MIXINIF", "BP_OUTERIF", "BP_IDF")
    ln = {m: find_line(src, m) for m in marks}
    c = Client(src)
    c.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c.request("launch", {"program": src, "importPaths": IMPORTS})
    c.request("setBreakpoints", {"source": {"path": src},
                                 "breakpoints": [{"line": ln[m]} for m in marks]})
    c.request("configurationDone")

    # The clauses of a condition written inside a template instance are named with
    # the parameters of that instance, so those arguments are the locals of the
    # frame: for the constraint of a struct, a function or a mixin template as
    # well, where the arguments of the instance have not all been deduced yet.
    want = {
        ln["BP_PICKCONSTRAINT"]: {"N": "2"},
        ln["BP_STATICIF"]: {"N": "2", "T": "int"},
        ln["BP_BOXCONSTRAINT"]: {"T": "int"},
        ln["BP_BOXIF"]: {"T": "int"},
        ln["BP_BOXASSERT"]: {"T": "int"},
        ln["BP_MIXINIF"]: {"U": "int", "T": "int"},
        ln["BP_OUTERIF"]: {"T": "int"},
        ln["BP_IDF"]: {"n": "1"},
    }

    seen = {}
    while True:
        ev, msg = c.wait_event(("stopped",) + TERMINAL, 30)
        if msg is None or msg.get("event") != "stopped":
            break
        frames = c.frames()
        top = frames[0] if frames else {}
        line = top.get("line")
        print("  %s %s %s: %s" % (ev.get("reason"), line, top.get("name"),
                                  sorted(local_values(c, top).items())))
        if line in want and line not in seen:
            vals = local_values(c, top)
            for n, v in want[line].items():
                assert vals.get(n) == v, (line, n, vals)
            # the instances the condition is written in are on the stack below it,
            # and they report the same names
            names = set()
            for f in frames[1:]:
                if (f.get("name") or "").startswith("instantiating"):
                    names.update(local_values(c, f))
            for n in want[line]:
                assert n in names, (line, n, sorted(names))
            seen[line] = vals
        c.send("continue", {"threadId": 1})
    assert sorted(seen) == sorted(want), (sorted(seen), sorted(want))

    # the watch can read the argument of the instance a condition is written in
    c2 = Client(src)
    c2.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c2.request("launch", {"program": src, "importPaths": IMPORTS})
    c2.request("setBreakpoints", {"source": {"path": src},
                                  "breakpoints": [{"line": ln["BP_BOXIF"]}]})
    c2.request("configurationDone")
    c2.wait_event("stopped", 30)
    fr = (c2.frames() or [{}])[0]
    r = c2.request("evaluate", {"expression": "T", "frameId": fr.get("id"),
                                "context": "watch"})
    body = (r or {}).get("body") or {}
    assert body.get("result") == "int", "watch T: %r" % (r,)
    print("  watch T in the static if of Box!int =>", body.get("result"))
    print("terminated:", finish(c2))
    print("exit:", c2.close())


def scenario_breakpoint_order():
    print("=== setBreakpoints answers in the order the client sent them ===")
    src = BASE + r"\ctfe_cond2.d"
    marks = ("BP_PICKCONSTRAINT", "BP_STATICIF", "BP_BOXCONSTRAINT", "BP_BOXIF",
             "BP_BOXASSERT", "BP_MIXINIF", "BP_OUTERIF", "BP_IDF")
    ln = {m: find_line(src, m) for m in marks}

    # The DAP requires the breakpoints in the response to line up by index with the
    # ones in the request.  A client that hands its breakpoints over in the order
    # they were created, and not sorted by line, pairs every answer with the wrong
    # breakpoint and ends up moving or deleting the wrong marker.
    order = ("BP_BOXIF", "BP_IDF", "BP_PICKCONSTRAINT", "BP_STATICIF",
             "BP_BOXASSERT", "BP_BOXCONSTRAINT", "BP_OUTERIF", "BP_MIXINIF")
    want = [ln[m] for m in order]
    assert want != sorted(want), want

    c = Client(src)
    c.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c.request("launch", {"program": src, "importPaths": IMPORTS})
    r = c.request("setBreakpoints", {"source": {"path": src},
                                     "breakpoints": [{"line": l} for l in want]})
    bps = ((r or {}).get("body") or {}).get("breakpoints") or []
    got = [bp.get("line") for bp in bps]
    assert got == want, (got, want)
    ids = [bp.get("id") for bp in bps]
    assert len(set(ids)) == len(ids), ids
    print("  sent %s => answered %s" % (want, got))

    c.request("configurationDone")
    hit = set()
    while True:
        ev, msg = c.wait_event(("stopped",) + TERMINAL, 30)
        if msg is None or msg.get("event") != "stopped":
            break
        line = ((c.frames() or [{}])[0]).get("line")
        if line not in hit:
            print("  stopped at %s" % line)
        hit.add(line)
        c.send("continue", {"threadId": 1})
    assert hit == set(want), (sorted(hit), sorted(want))
    print("exit:", c.close())

    # A breakpoint the client cannot give a line for is reported as unverified,
    # but still holds its place in the answer.
    c2 = Client(src)
    c2.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c2.request("launch", {"program": src, "importPaths": IMPORTS})
    sent = [{"line": ln["BP_BOXIF"]}, {}, {"line": ln["BP_IDF"]}]
    lines = [ln["BP_BOXIF"], 0, ln["BP_IDF"]]
    r2 = c2.request("setBreakpoints", {"source": {"path": src}, "breakpoints": sent})
    bps2 = ((r2 or {}).get("body") or {}).get("breakpoints") or []
    assert [bp.get("line", 0) for bp in bps2] == lines, bps2
    assert bps2[1].get("verified") is False, bps2
    assert bps2[0].get("verified") is not False, bps2
    print("  sent %s => answered %s"
          % ([bp.get("line", 0) for bp in sent],
             [(bp.get("line", 0), bp.get("verified")) for bp in bps2]))
    # A client that cannot open a file itself asks the adapter for its text.
    r3 = c2.request("source", {"source": {"path": src}})
    text = ((r3 or {}).get("body") or {}).get("content") or ""
    assert "static if" in text, "source request: %r" % (r3,)
    print("  the source of %s reads %d chars" % (os.path.basename(src), len(text)))
    c2.request("configurationDone")
    hit2 = set()
    while True:
        ev, msg = c2.wait_event(("stopped",) + TERMINAL, 30)
        if msg is None or msg.get("event") != "stopped":
            break
        hit2.add(((c2.frames() or [{}])[0]).get("line"))
        c2.send("continue", {"threadId": 1})
    assert hit2 == {ln["BP_BOXIF"], ln["BP_IDF"]}, sorted(hit2)
    print("  stopped at %s" % sorted(hit2))
    print("exit:", c2.close())

    # The traffic of a session can be logged, so that what a client asked for and
    # what it was answered can be inspected after the fact.
    log = os.path.join(os.environ.get("TEMP", BASE), "visuald-ctfe-dap-scenario.log")
    if os.path.exists(log):
        os.remove(log)
    os.environ["CTFE_DAP_LOG"] = log
    try:
        c3 = Client(src)
        c3.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
        c3.request("launch", {"program": src, "importPaths": IMPORTS})
        c3.request("setBreakpoints", {"source": {"path": src},
                                      "breakpoints": [{"line": l} for l in want]})
        c3.request("configurationDone")
        while True:
            ev, msg = c3.wait_event(("stopped",) + TERMINAL, 30)
            if msg is None or msg.get("event") != "stopped":
                break
            c3.frames()
            c3.send("continue", {"threadId": 1})
        print("exit:", c3.close())
    finally:
        del os.environ["CTFE_DAP_LOG"]

    with open(log, encoding="utf-8") as f:
        text = f.read()
    assert '"command": "setBreakpoints"' in text, "the request is missing from the log"
    assert '"command":"setBreakpoints"' in text, "the answer is missing from the log"
    sent = text.count("--> ")
    answered = text.count("<-- ")
    assert sent >= 4 and answered >= sent, (sent, answered)
    print("  logged %d requests and %d answers to %s" % (sent, answered, log))


def scenario_package_module():
    print("=== a module of a package is analysed once ===")
    src = BASE + r"\ctfe_pkg\leaf.d"
    c = Client(src)
    c.request("initialize", {"adapterID": "ctfe", "pathFormat": "path"})
    c.request("launch", {"program": src, "importPaths": IMPORTS + [BASE]})
    line = find_line(src, "BP_TWICE")
    c.request("setBreakpoints", {"source": {"path": src}, "breakpoints": [{"line": line}]})
    c.request("configurationDone")
    hits = []
    while True:
        ev, msg = c.wait_event(("stopped",) + TERMINAL, 30)
        if msg is None or msg.get("event") != "stopped":
            break
        frames = c.frames()
        top = frames[0] if frames else {}
        args = local_values(c, top) if top else {}
        hits.append((top.get("name"), args.get("n")))
        print("  stop %s line %s: %s" % (top.get("name"), top.get("line"), args))
        c.send("continue", {"threadId": 1})
    print("terminated:", finish(c))
    print("exit:", c.close())

    # The debugged file is imported by its own package, so it could be read twice:
    # once as the module the debugger parsed, named after the file, and once as the
    # module the package imported, named after its declaration.  Each call would
    # then be interpreted twice and every breakpoint would stop twice.
    assert sorted(hits) == sorted([("ctfe_pkg.leaf.twice", "3"), ("ctfe_pkg.leaf.twice", "21")]), hits
    for out in c.outputs:
        text = out.get("output") or ""
        assert "conflicts with" not in text and "must be imported" not in text, out


def main():
    scenario_globals()
    scenario_temps()
    scenario_condition()
    scenario_evaluate()
    scenario_manifest()
    scenario_bottom()
    scenario_template_args()
    scenario_instantiation()
    scenario_instance_defs()
    scenario_instance_values()
    scenario_class_fields()
    scenario_conditions()
    scenario_condition_instances()
    scenario_breakpoint_order()
    scenario_package_module()
    scenario_return()
    scenario_stepout()
    scenario_pause()
    scenario_errors()
    scenario_output()


if __name__ == "__main__":
    main()
