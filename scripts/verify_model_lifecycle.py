#!/usr/bin/env python3
"""Explicit real-model lifecycle check using a DEBUG app and synthetic empty libraries.

Requires --execute. Controls only the launched test app. The app's supervisor may
migrate verified AskBase LaunchAgents and manage the already installed models.
Do not run alongside another AskBase instance.
"""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import socket
import subprocess
import tempfile
import time
import urllib.request


def fetch(port, path):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(f"http://127.0.0.1:{port}{path}", timeout=3) as response:
        return json.load(response)


def busy(port):
    with socket.socket() as sock:
        sock.settimeout(0.5)
        return sock.connect_ex(("127.0.0.1", port)) == 0


def process_rows():
    text = subprocess.check_output(["ps", "-axo", "pid=,ppid=,pgid=,command="], text=True)
    rows = {}
    for line in text.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) == 4:
            rows[int(parts[0])] = (int(parts[1]), int(parts[2]), parts[3])
    return rows


def await_condition(predicate, seconds, description):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = predicate()
        if value:
            return value
        time.sleep(0.1)
    raise RuntimeError("Timed out: " + description)


def app_pid(bundle, library):
    prefix = str(bundle / "Contents/MacOS/AskBaseMac") + " --library-path " + str(library)
    return next((pid for pid, row in process_rows().items() if row[2].startswith(prefix)), None)


def owned_snapshot(pid):
    rows = process_rows()
    supervisors = {
        p for p, row in rows.items()
        if "ModelRuntime/supervisor.py" in row[2] and f"--parent-pid {pid} " in row[2]
    }
    groups = {row[1] for row in rows.values() if row[0] in supervisors}
    return supervisors, groups


def run_case(bundle, mode, output):
    directory = Path(tempfile.mkdtemp(prefix="AskBase-UIVerify-lifecycle-"))
    library = directory / "ui-smoke-library"
    reports = directory / "reports"
    args = [
        "open", "-n", "-W", str(bundle), "--args", "--library-path", str(library),
        "--manage-models", "--ui-lifecycle-only", "--ui-smoke-output", str(reports),
    ]
    if mode == "window":
        args += ["--ui-close-window"]
    elif mode in ("crash", "startup_quit"):
        args += ["--ui-hold-open"]
    log = (directory / "launch.log").open("wb")
    launcher = subprocess.Popen(args, stdout=log, stderr=log)
    started = time.monotonic()
    pid = await_condition(lambda: app_pid(bundle, library), 15, "test app launch")
    result = {"mode": mode, "app_pid": pid, "isolated_library": str(library)}
    try:
        if mode == "startup_quit":
            # Wait until a model child has actually started, but before readiness.
            children = await_condition(
                lambda: {
                    p: row for p, row in process_rows().items()
                    if row[0] in {
                        sp for sp, sr in process_rows().items()
                        if sr[0] == pid and "ModelRuntime/supervisor.py" in sr[2]
                    }
                }, 30, "model child during startup",
            )
            supervisors, owned_groups = owned_snapshot(pid)
            # SIGTERM is intentionally an abrupt app termination, like a killed/crashed app.
            os.kill(pid, signal.SIGTERM)
            result["model_pids_before_stop"] = sorted(children)
        else:
            ready = reports / "lifecycle-ready.json"
            await_condition(ready.exists, 300, "app and model readiness")
            report = json.loads(ready.read_text())
            if not all(report["checks"].values()):
                raise RuntimeError("App readiness checks failed: " + json.dumps(report))
            embedding = fetch(8871, "/health")
            models = fetch(11434, "/api/ps")["models"]
            if not any(m.get("name") == report["model"] or m.get("model") == report["model"] for m in models):
                raise RuntimeError("Selected answer model was not resident after app startup")
            result.update(
                startup_seconds=round(time.monotonic() - started, 3),
                embedding_mlx_active_bytes=embedding.get("metrics", {}).get("mlx_active_bytes"),
                resident_models=[{k: m.get(k) for k in ("name", "size", "size_vram")} for m in models],
                app_ready=report,
            )
            supervisors, owned_groups = owned_snapshot(pid)
            if mode == "crash":
                os.kill(pid, signal.SIGKILL)
        result["supervisor_pids"] = sorted(supervisors)
        result["model_process_groups"] = sorted(owned_groups)
        stop_started = time.monotonic()
        await_condition(
            lambda: pid not in process_rows()
            and not any(busy(port) for port in (8871, 11434))
            and not supervisors.intersection(process_rows())
            and not any(row[1] in owned_groups for row in process_rows().values()),
            45, "app, supervisor and all model processes to exit",
        )
        result["release_seconds_including_ui_delay"] = round(time.monotonic() - stop_started, 3)
        result["ports_released"] = True
        result["owned_processes_exited"] = True
        result["passed"] = True
        launcher.wait(timeout=5)
    finally:
        # If a test fails, request normal quit of this exact test PID only.
        # Never kill a supervisor: it must survive long enough to release its children.
        if app_pid(bundle, library) == pid:
            os.kill(pid, signal.SIGTERM)
        log.close()
        output.mkdir(parents=True, exist_ok=True)
        (output / f"lifecycle-{mode}.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--case", choices=["quit", "window", "crash", "startup_quit", "all"], default="all")
    args = parser.parse_args()
    if not args.execute:
        parser.error("Real model/service control requires explicit --execute")
    info = plistlib.loads((args.bundle / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "cloud.doublewen.AskBaseMac" or not info.get("AskBaseDebugBuild"):
        raise SystemExit("A bundled AskBase DEBUG build is required.")
    if any(re.search(r"/AskBaseMac(?: |$)", row[2]) for row in process_rows().values()):
        raise SystemExit("Close other AskBase apps first. No process was stopped.")
    cases = ["quit", "window", "crash", "startup_quit"] if args.case == "all" else [args.case]
    results = []
    for case in cases:
        print(f"Checking {case}...", flush=True)
        results.append(run_case(args.bundle.resolve(), case, args.output.resolve()))
        print(f"Passed {case}", flush=True)
    summary = {
        "checked_utc": datetime.now(timezone.utc).isoformat(), "cases": results,
        "scope": "native DEBUG AppKit lifecycle, installed models, empty isolated libraries",
        "limits": "No real-document accuracy or physical mouse/keyboard testing; no model downloads.",
    }
    (args.output / "model-lifecycle-0.5.0.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
