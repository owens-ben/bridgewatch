#!/usr/bin/env python3
"""JSON helpers for scripts/ui-test.sh (standard library only).

The shell script does the running; this reads what xcrun hands back (simctl and xcresulttool JSON) and writes the
summary files. Every subcommand takes files, so scripts/ui-test.sh selftest can feed it canned input.

  sim-spec     --type-name T --runtime-version V < `simctl list -j runtimes devicetypes`   -> "<type id> <runtime id>"
  sim-find     --name N --runtime-version V < `simctl list -j devices`                      -> UDID (or nothing)
  get          --file F --key K                                                             -> one top-level field
  parse-result --sim NAME --summary F --tests F [--manifest F --attach-dir D --failures-dir D] --out F
  perf-line    --metrics F --test NAME --date D --commit C                                  -> one TSV line
  sim-booted   < `simctl list -j devices`                                                    -> UDIDs booted now
  find-crashes --since EPOCH --dest D --bundle-id ID --process NAME --dir D...               -> count of copied reports
  summarize    --out-dir D --commit C --branch B --tier T --started S --finished F --verdict V
               [--crashes-dir D] [--note TEXT]... [--sim NAME|UDID|RUNTIME]... [--result F]... [--perf-line TSV]...
"""
import argparse
import datetime
import json
import math
import os
import re
import shutil
import subprocess
import sys


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


# ---- simctl ----------------------------------------------------------------------------------------------------


def runtime_version_ok(runtime, version):
    return runtime.get("version") == version or runtime.get("identifier", "").endswith("iOS-" + version.replace(".", "-"))


def cmd_sim_spec(a):
    data = json.load(sys.stdin)
    types = [t for t in data.get("devicetypes", []) if t.get("name") == a.type_name]
    if not types:
        sys.exit("no device type named %r" % a.type_name)
    type_id = types[0]["identifier"]
    for rt in data.get("runtimes", []):
        if not rt.get("isAvailable", True) or not runtime_version_ok(rt, a.runtime_version):
            continue
        supported = [t.get("identifier") for t in rt.get("supportedDeviceTypes", [])]
        if not supported or type_id in supported:
            print(type_id, rt["identifier"])
            return
    sys.exit("no available iOS %s runtime supports %s" % (a.runtime_version, a.type_name))


def devices_for(data, version):
    for runtime_id, devices in data.get("devices", {}).items():
        if runtime_id.endswith("iOS-" + version.replace(".", "-")):
            for d in devices:
                yield d


def cmd_sim_booted(a):
    for devices in json.load(sys.stdin).get("devices", {}).values():
        for d in devices:
            if d.get("state") == "Booted":
                print(d["udid"])


def cmd_sim_find(a):
    for d in devices_for(json.load(sys.stdin), a.runtime_version):
        if d.get("name") == a.name and d.get("isAvailable", True):
            print(d["udid"])
            return


# ---- xcresult --------------------------------------------------------------------------------------------------


def walk(node, ancestors=()):
    yield node, ancestors
    for child in node.get("children", []) or []:
        yield from walk(child, ancestors + (node,))


LOCATION = re.compile(r"([\w+.\-/ ]+\.swift):(\d+)")


def failure_from_node(case_name, message_node):
    text = (message_node.get("details") or message_node.get("name") or "").strip()
    name = (message_node.get("name") or "").strip()
    loc = message_node.get("sourceLocation") or {}
    path, line = loc.get("filePath"), loc.get("lineNumber")
    if not path:
        m = LOCATION.search(name) or LOCATION.search(text)
        if m:
            path, line = m.group(1).strip(), int(m.group(2))
    # Xcode puts "File.swift:123: message" in the name; keep just the message when the location is separate.
    message = text if text and text != name else name
    message = re.sub(r"^[\w+.\-/ ]+\.swift:\d+:\s*", "", message)
    return {"test": case_name, "message": message,
            "file": os.path.basename(path) if path else None, "line": line}


def parse_failures(tests, summary):
    failures = []
    for node, _ in walk({"children": tests.get("testNodes", [])}):
        if node.get("nodeType") != "Test Case" or node.get("result") != "Failed":
            continue
        # BoatARUITests/testName: the identifier Xcode and -only-testing use.
        name = node.get("nodeIdentifier") or node.get("name") or "?"
        found = False
        for sub, _ in walk(node):
            if sub.get("nodeType") == "Failure Message":
                failures.append(failure_from_node(name, sub))
                found = True
        if not found:
            failures.append({"test": name, "message": "failed (no failure message in the result)", "file": None, "line": None})
    if not failures:
        # No tree, or no Test Case nodes: the summary still lists what failed.
        for f in summary.get("testFailures", []) or []:
            failures.append({"test": f.get("testIdentifierString") or f.get("testName") or "?",
                             "message": f.get("failureText") or "failed", "file": None, "line": None})
            m = LOCATION.search(f.get("failureText") or "")
            if m:
                failures[-1]["file"], failures[-1]["line"] = os.path.basename(m.group(1).strip()), int(m.group(2))
    return failures


def slug(text):
    return re.sub(r"[^A-Za-z0-9._-]+", "_", text).strip("_")[:90]


IMAGES = (".png", ".jpg", ".jpeg", ".heic")
VIDEOS = (".mp4", ".mov")


def last_frame(video, dest):
    """Writes the video's last frame to dest (a PNG) with ffmpeg, when it is installed; True when it worked."""
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        return False
    # The recording only has frames when the screen changes, so a static last second has none: look back further
    # until a frame turns up (each pass keeps overwriting dest, so the last frame stays).
    for seconds in ("-1", "-5", "-30"):
        try:
            subprocess.run([ffmpeg, "-v", "error", "-y", "-sseof", seconds, "-i", video, "-frames:v", "100000", "-update", "1",
                            dest], check=True, timeout=120)
        except (subprocess.SubprocessError, OSError):
            continue
        if os.path.isfile(dest):
            break
    return os.path.isfile(dest)


def copy_screenshots(a, sim, failures):
    """Copies what shows each failed test's final state out of the exported attachments; returns the number copied.

    Xcode 27 does not flag any attachment as belonging to a failure (isAssociatedWithFailure is false everywhere) and
    its "UI Snapshot" is an archived element tree, not an image. What does show the screen is the screen recording
    (its last frame is the failure) and the "App UI hierarchy" text. So the attachments of each failed test are
    exported (one folder per test, each with its own manifest.json) and: image attachments are copied as they are,
    the recording becomes a PNG of its last frame (needs ffmpeg), and the UI hierarchy text is kept next to it.
    """
    if not (a.attach_dir and a.failures_dir and os.path.isdir(a.attach_dir)):
        return 0
    os.makedirs(a.failures_dir, exist_ok=True)
    folders = [a.attach_dir] + [os.path.join(a.attach_dir, d) for d in sorted(os.listdir(a.attach_dir))
                                if os.path.isdir(os.path.join(a.attach_dir, d))]
    copied = 0
    for folder in folders:
        manifest = a.manifest if folder == a.attach_dir and a.manifest else os.path.join(folder, "manifest.json")
        if not os.path.exists(manifest):
            continue
        for entry in load(manifest):
            test_id = entry.get("testIdentifier", "")
            base = "%s__%s" % (slug(sim), slug(test_id or "test"))
            images = []
            for att in entry.get("attachments", []):
                name = att.get("exportedFileName", "")
                src = os.path.join(folder, name)
                human = (att.get("suggestedHumanReadableName") or "").lower()
                ext = os.path.splitext(name)[1].lower()
                if not os.path.isfile(src):
                    continue
                if ext in IMAGES:
                    dest = "%s__%d%s" % (base, len(images) + 1, ext)
                    shutil.copyfile(src, os.path.join(a.failures_dir, dest))
                    images.append(dest)
                elif ext in VIDEOS:
                    dest = "%s__last-frame.png" % base
                    if last_frame(src, os.path.join(a.failures_dir, dest)):
                        images.append(dest)
                elif ext == ".txt" and human.startswith("app ui hierarchy"):
                    shutil.copyfile(src, os.path.join(a.failures_dir, base + "__ui-hierarchy.txt"))
            copied += len(images)
            for f in failures:
                if images and test_id and f["test"].endswith(test_id.split("/", 1)[-1]) and not f.get("screenshot"):
                    f["screenshot"] = "failures/" + images[0]
    return copied


def cmd_failed_tests(a):
    for f in load(a.file).get("failures", []):
        print(f["test"])


def cmd_parse_result(a):
    summary = load(a.summary) if a.summary and os.path.exists(a.summary) else {}
    tests = load(a.tests) if a.tests and os.path.exists(a.tests) else {}
    failures = parse_failures(tests, summary)
    for f in failures:
        f["simulator"] = a.sim
    passed, failed = summary.get("passedTests", 0), summary.get("failedTests", 0)
    skipped = summary.get("skippedTests", 0)
    total = summary.get("totalTestCount", passed + failed + skipped)
    # A failed test with no parsed failure message still counts as failed.
    failed = max(failed, len(failures))
    out = {"simulator": a.sim, "total": total, "passed": passed, "failed": failed, "skipped": skipped,
           "result": summary.get("result"), "failures": failures}
    out["screenshots"] = copy_screenshots(a, a.sim, failures) if failures else 0
    with open(a.out, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2)


# ---- perf ------------------------------------------------------------------------------------------------------

TO_MB = {"B": 1 / 1e6, "kB": 1 / 1e3, "KB": 1 / 1e3, "MB": 1.0, "GB": 1e3}


def pick(metrics, *needles):
    for needle in needles:
        for m in metrics:
            if needle in (m.get("displayName") or "").lower() and m.get("measurements"):
                return m
    return None


def cmd_perf_line(a):
    data = load(a.metrics)
    metrics = []
    for test in data if isinstance(data, list) else [data]:
        for run in test.get("testRuns", []):
            metrics += run.get("metrics", [])
    cpu = pick(metrics, "cpu time")
    mem = pick(metrics, "peak", "physical")
    if not cpu:
        sys.exit("no CPU Time metric in %s" % a.metrics)
    values = cpu["measurements"]
    mean = sum(values) / len(values)
    sd = math.sqrt(sum((v - mean) ** 2 for v in values) / (len(values) - 1)) if len(values) > 1 else 0.0
    rsd = sd / mean * 100 if mean else 0.0
    peak = ""
    if mem:
        factor = TO_MB.get(mem.get("unitOfMeasurement", "kB"), 1 / 1e3)
        peak = "%.1f" % (max(mem["measurements"]) * factor)
    print("\t".join([a.date, a.commit, a.test, "%.3f" % mean, "%.1f" % rsd, peak]))


# ---- crash reports --------------------------------------------------------------------------------------------


def read_ips(path):
    """(header, body) of an .ips file: the first line is a JSON header, the rest a JSON report. Either may be None."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        return None, None, ""
    head, _, rest = text.partition("\n")
    try:
        header = json.loads(head)
    except ValueError:
        header = None
    try:
        body = json.loads(rest) if rest.strip() else None
    except ValueError:
        body = None
    if body is None and header is not None and "threads" in header:
        body = header  # a single-document file
    return header, body, text


def ips_is_for(path, bundle_id, process):
    header, body, text = read_ips(path)
    for doc in (header, body):
        if isinstance(doc, dict) and (doc.get("bundleID") == bundle_id or doc.get("app_name") == process
                                      or doc.get("name") == process or doc.get("procName") == process):
            return True
    # Not JSON, or a shape we don't know: the identifiers in the first KB of text.
    first = text[:4096]
    return re.search(r'"(bundleID|bundleIdentifier|CFBundleIdentifier)"\s*:\s*"%s"' % re.escape(bundle_id), first) is not None \
        or re.search(r'"(app_name|name|procName)"\s*:\s*"%s"' % re.escape(process), first) is not None


def crash_info(path):
    """One report as {file, time, exception, thread_top_frame}; every field but file may be empty."""
    info = {"file": os.path.basename(path), "time": "", "exception": "", "top_frame": ""}
    try:
        info["time"] = datetime.datetime.fromtimestamp(os.path.getmtime(path)).strftime("%Y-%m-%d %H:%M:%S")
    except (OSError, ValueError):
        pass
    try:
        header, body, _ = read_ips(path)
        if isinstance(header, dict) and header.get("timestamp"):
            info["time"] = str(header["timestamp"])
        body = body if isinstance(body, dict) else {}
        exc = body.get("exception") or {}
        parts = [exc.get("type"), exc.get("signal")]
        info["exception"] = "/".join(str(x) for x in parts if x)
        threads = body.get("threads") or []
        idx = body.get("faultingThread")
        thread = threads[idx] if isinstance(idx, int) and 0 <= idx < len(threads) else next(
            (t for t in threads if t.get("triggered")), None)
        frames = (thread or {}).get("frames") or []
        if frames:
            images = body.get("usedImages") or []
            # The first frame in the app's own code says more than the runtime's trap handler above it.
            def image_name(fr):
                i = fr.get("imageIndex")
                return images[i].get("name", "") if isinstance(i, int) and i < len(images) else ""
            f = next((fr for fr in frames if "BoatAR" in image_name(fr)), frames[0])
            image = images[f["imageIndex"]].get("name", "") if isinstance(f.get("imageIndex"), int) \
                and f["imageIndex"] < len(images) else ""
            info["top_frame"] = " ".join(x for x in (f.get("symbol") or "", "(%s)" % image if image else "") if x)
    except (AttributeError, KeyError, TypeError, IndexError, ValueError):
        pass
    return info


def cmd_find_crashes(a):
    """Copies the app's .ips reports made at or after --since (epoch seconds) into --dest; prints how many."""
    since = float(a.since or 0)
    seen, count = set(), 0
    for d in a.dir or []:
        for folder in (d, os.path.join(d, "Retired")):
            if not os.path.isdir(folder):
                continue
            for name in sorted(os.listdir(folder)):
                path = os.path.join(folder, name)
                if not name.endswith(".ips") or not os.path.isfile(path):
                    continue
                try:
                    if os.path.getmtime(path) < since:
                        continue
                except OSError:
                    continue
                real = os.path.realpath(path)
                if real in seen or not ips_is_for(path, a.bundle_id, a.process):
                    continue
                seen.add(real)
                os.makedirs(a.dest, exist_ok=True)
                dest = os.path.join(a.dest, name)
                n = 1
                while os.path.exists(dest):
                    n += 1
                    dest = os.path.join(a.dest, "%d-%s" % (n, name))
                shutil.copy2(path, dest)
                count += 1
    print(count)


# ---- summary ---------------------------------------------------------------------------------------------------


def cmd_summarize(a):
    results = [load(p) for p in a.result or [] if os.path.exists(p)]
    sims = []
    for s in a.sim or []:
        name, udid, runtime = (s.split("|") + ["", ""])[:3]
        sims.append({"name": name, "udid": udid, "runtime": runtime})
    failures = [f for r in results for f in r.get("failures", [])]
    counts = {r["simulator"]: {k: r.get(k, 0) for k in ("total", "passed", "failed", "skipped")} for r in results}
    perf = []
    for line in a.perf_line or []:
        d, c, t, cpu, rsd, mem = (line.split("\t") + [""] * 6)[:6]
        perf.append({"date": d, "commit": c, "test": t, "avg_cpu_s": cpu, "rsd_pct": rsd, "peak_mem_mb": mem})
    summary = {"commit": a.commit, "branch": a.branch, "tier": a.tier, "simulators": sims,
               "started": a.started, "finished": a.finished, "verdict": a.verdict,
               "counts": counts, "failures": failures, "perf": perf, "notes": a.note or []}
    crashes = []
    if a.crashes_dir and os.path.isdir(a.crashes_dir):
        crashes = [crash_info(os.path.join(a.crashes_dir, n)) for n in sorted(os.listdir(a.crashes_dir)) if n.endswith(".ips")]
    summary["crashes"] = crashes
    if a.idle_start or a.top_start or a.top_end:
        summary["machine"] = {"cpu_idle_at_start_pct": a.idle_start, "top_cpu_at_start": a.top_start or [],
                              "top_cpu_at_end": a.top_end or []}
    os.makedirs(a.out_dir, exist_ok=True)
    with open(os.path.join(a.out_dir, "summary.json"), "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)
    with open(os.path.join(a.out_dir, "summary.md"), "w", encoding="utf-8") as f:
        f.write(render_md(summary))


HEADLINE = {
    "pass": "PASS",
    "fail": "FAIL: tests failed",
    "build-failed": "BUILD FAILED",
    "invalid": "INVALID: the machine was too busy for a trustworthy run (this is not a test failure)",
}


def render_md(s):
    headline = HEADLINE.get(s["verdict"], s["verdict"])
    if s["verdict"] == "fail" and s.get("crashes") and not s["failures"]:
        headline = "FAIL: every test passed but the app crashed"
    lines = ["# UI tests: %s (%s)" % (headline, s["tier"]), "",
             "- commit `%s` on `%s`" % (s["commit"], s["branch"]),
             "- started %s, finished %s" % (s["started"], s["finished"])]
    for sim in s["simulators"]:
        lines.append("- simulator: %s %s %s" % (sim["name"], sim["udid"], sim["runtime"]))
    for note in s["notes"]:
        lines.append("- note: %s" % note)
    if s["counts"]:
        lines += ["", "| Simulator | Total | Passed | Failed | Skipped |", "| --- | ---: | ---: | ---: | ---: |"]
        for name, c in s["counts"].items():
            lines.append("| %s | %d | %d | %d | %d |" % (name, c["total"], c["passed"], c["failed"], c["skipped"]))
    if s["failures"]:
        lines += ["", "## Failures", ""]
        for f in s["failures"]:
            where = " (%s:%s)" % (f["file"], f["line"]) if f.get("file") else ""
            lines.append("- `%s` on %s%s: %s" % (f["test"], f["simulator"], where, f["message"]))
            if f.get("screenshot"):
                lines.append("  - screenshot: %s" % f["screenshot"])
    if s.get("crashes"):
        lines += ["", "## Crashes", "", "The app crashed %d time(s) during the run (copies in crashes/):" % len(s["crashes"]), ""]
        for c in s["crashes"]:
            detail = ", ".join(x for x in (c["time"], c["exception"], c["top_frame"]) if x)
            lines.append("- `%s`%s" % (c["file"], ": " + detail if detail else ""))
    m = s.get("machine")
    if m:
        lines += ["", "## Machine", "", "- CPU idle at start: %s%%" % (m["cpu_idle_at_start_pct"] or "?"),
                  "- busiest processes at start: %s" % ("; ".join(m["top_cpu_at_start"]) or "?"),
                  "- busiest processes at end: %s" % ("; ".join(m["top_cpu_at_end"]) or "?")]
    if s["perf"]:
        lines += ["", "## Performance", "", "| Test | Avg CPU s | RSD % | Peak memory MB |", "| --- | ---: | ---: | ---: |"]
        for p in s["perf"]:
            lines.append("| %s | %s | %s | %s |" % (p["test"], p["avg_cpu_s"], p["rsd_pct"], p["peak_mem_mb"]))
    return "\n".join(lines) + "\n"


def cmd_get(a):
    value = load(a.file).get(a.key, "")
    print(value if value is not None else "")


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)

    def add(name, fn, *args, **multi):
        sp = sub.add_parser(name)
        for arg in args:
            sp.add_argument("--" + arg, default=None)
        for arg in multi.get("many", []):
            sp.add_argument("--" + arg, action="append")
        sp.set_defaults(fn=fn)

    add("sim-spec", cmd_sim_spec, "type-name", "runtime-version")
    add("sim-booted", cmd_sim_booted)
    add("get", cmd_get, "file", "key")
    add("sim-find", cmd_sim_find, "name", "runtime-version")
    add("parse-result", cmd_parse_result, "sim", "summary", "tests", "manifest", "attach-dir", "failures-dir", "out")
    add("failed-tests", cmd_failed_tests, "file")
    add("perf-line", cmd_perf_line, "metrics", "test", "date", "commit")
    add("find-crashes", cmd_find_crashes, "since", "dest", "bundle-id", "process", many=["dir"])
    add("summarize", cmd_summarize, "out-dir", "commit", "branch", "tier", "started", "finished", "verdict", "idle-start",
        "crashes-dir",
        many=["note", "sim", "result", "perf-line", "top-start", "top-end"])
    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
