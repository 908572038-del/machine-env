"""Cross-checks what the probe reports against the machine it reports on.

    python scripts/check-tool-resolution.py [path\\to\\machine-env-cpp.exe]

Three questions, answered by measurement rather than by trust:

1. Does `get_tools` report the python the bare name runs?
2. Are the entries under `not_on_path` actually unreachable by name from the
   same PATH the server composes (machine value first, then user value, both
   expanded), and do the reported paths exist?
3. When an endpoint fails, is it because of the budget, or because the endpoint
   does not answer even with a larger one?

The point of the PATH comparison is that `not_on_path` is a claim about PATH.
Testing it means resolving the same names with the same PATH, not with whatever
PATH the calling shell happens to hold.
"""
import json
import ntpath
import os
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_EXE = os.path.join(ROOT, "build", "machine-env-cpp.exe")
NAMED = ["python", "pip", "ninja", "cl", "msbuild", "makeappx", "signtool",
         "git", "node", "cmake"]


def registry_path(root, sub):
    import winreg
    try:
        with winreg.OpenKey(root, sub) as key:
            value, _ = winreg.QueryValueEx(key, "Path")
            return value
    except OSError:
        return ""


def composed_path():
    import winreg
    machine = registry_path(
        winreg.HKEY_LOCAL_MACHINE,
        r"SYSTEM\CurrentControlSet\Control\Session Manager\Environment")
    user = registry_path(winreg.HKEY_CURRENT_USER, "Environment")
    return ntpath.expandvars(";".join(part for part in (machine, user) if part))


class Session:
    def __init__(self, exe):
        self.process = subprocess.Popen([exe], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, bufsize=0)
        self.next_id = 0
        self.call("initialize", None)

    def raw(self, method, params=None):
        self.next_id += 1
        payload = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            payload["params"] = params
        self.process.stdin.write((json.dumps(payload) + "\n").encode())
        self.process.stdin.flush()
        return json.loads(self.process.stdout.readline())

    def call(self, name, arguments):
        if name == "initialize":
            return self.raw("initialize", {"protocolVersion": "2025-11-25"})
        return self.raw("tools/call", {"name": name, "arguments": arguments})[
            "result"]["structuredContent"]

    def close(self):
        self.process.stdin.close()
        self.process.wait(15)


def main():
    exe = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_EXE
    if not os.path.isfile(exe):
        raise SystemExit("server not found: %s (build it, or pass a path)" % exe)
    path = composed_path()
    entries = [entry for entry in path.split(";") if entry.strip()]
    print("server        : %s" % exe)
    print("PATH entries  : %d (unexpanded '%%' left: %d)"
          % (len(entries), path.count("%")))
    print()

    session = Session(exe)
    body = session.call("get_tools", {"detail": True})
    cache = body.get("_cache", {})
    print("=== cache ===")
    print("  hit=%s reason=%s age_seconds=%s"
          % (cache.get("hit"), cache.get("reason"), cache.get("age_seconds")))

    print()
    print("=== tools ===")
    tools = body["tools"]
    flagged = set(body.get("not_on_path", []))
    contradictions = []
    for name in NAMED:
        reported = tools.get(name, "")
        truth = shutil.which(name, path=path) or ""
        exists = os.path.exists(reported) if reported else False
        print("  %-9s reported=%-8s off_path=%-5s same-PATH resolve=%s"
              % (name, "found" if reported else "-", name in flagged,
                 truth or "-"))
        if reported and not exists:
            contradictions.append("%s: reported path does not exist" % name)
        # A flag is wrong when the same PATH does reach the name. For python the
        # flagged copy can legitimately differ from the PATH one only when PATH
        # has no python at all, which is the case the old order got backwards.
        if name in flagged and truth and name != "python":
            contradictions.append("%s: flagged off PATH but PATH resolves it" % name)
    if tools.get("python") and shutil.which("python", path=path):
        expected = shutil.which("python", path=path)
        if os.path.normcase(tools["python"]) != os.path.normcase(expected):
            contradictions.append(
                "python: reported %s but the bare name runs %s"
                % (tools["python"], expected))
    print("  python_root=%s pip_root=%s mismatch=%s"
          % (body.get("python_root"), body.get("pip_root"),
             body.get("python_pip_mismatch")))

    print()
    print("=== network: budget or endpoint? ===")
    for budget in (2500, 10000):
        started = time.perf_counter()
        net = session.call("get_network", {"refresh": True, "timeout_ms": budget})
        elapsed = (time.perf_counter() - started) * 1000
        print("  timeout_ms=%-6d %6.0f ms budget_exhausted=%s"
              % (budget, elapsed, net.get("budget_exhausted")))
        for key, entry in sorted(net.get("endpoints", {}).items()):
            print("    %-13s ok=%-5s ms=%-5s reason=%s"
                  % (key, entry.get("ok"), entry.get("ms"),
                     entry.get("reason", "-")))
        if budget != 10000:
            time.sleep(6)  # past the coalescing window

    session.close()

    print()
    print("=== contradictions ===")
    if not contradictions:
        print("  none")
    for line in contradictions:
        print("  " + line)
    return 1 if contradictions else 0


if __name__ == "__main__":
    sys.exit(main())
