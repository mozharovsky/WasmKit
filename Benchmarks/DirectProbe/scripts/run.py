#!/usr/bin/env python3
"""Runs phase A of the direct-execution probe sequentially on one machine.

Every child process runs under an external time limit. A child that exceeds it is sampled for a
stack report and then killed, and the run records the failure instead of a timing.
"""

import argparse
import json
import os
import platform
import re
import shutil
import signal
import subprocess
import sys
import time

MAIN_VARIANTS = ["token", "token-control", "direct"]
WASMI_VARIANTS = {
    "token": ["--token", "--software-bounds"],
    "token-control": ["--token", "--software-bounds", "--control"],
    "direct": ["--software-bounds"],
}


def log(message):
    print(f"[run] {message}", flush=True)


class Runner:
    def __init__(self, out):
        self.out = out
        self.steps = []
        self.failed = False

    def sample_stack(self, pid, name):
        if platform.system() != "Darwin" or shutil.which("sample") is None:
            return None
        path = os.path.join(self.out, "diagnostics", f"{name}-{pid}.sample.txt")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        command = ["sample", str(pid), "1", "-file", path]
        if os.geteuid() != 0 and shutil.which("sudo"):
            command = ["sudo", "-n"] + command
        subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
        return path

    def run(self, name, command, timeout, stdout_path=None, required=True):
        """Runs one child with a limit and records its outcome."""
        os.makedirs(os.path.dirname(stdout_path or os.path.join(self.out, "x")), exist_ok=True)
        stderr_path = os.path.join(self.out, "logs", f"{name}.stderr.txt")
        os.makedirs(os.path.dirname(stderr_path), exist_ok=True)
        started = time.monotonic()
        stdout = open(stdout_path, "w") if stdout_path else subprocess.DEVNULL
        with open(stderr_path, "w") as stderr:
            process = subprocess.Popen(command, stdout=stdout, stderr=stderr, start_new_session=True)
            try:
                status = process.wait(timeout=timeout)
                timed_out = False
            except subprocess.TimeoutExpired:
                timed_out = True
                diagnostics = self.sample_stack(process.pid, name)
                os.killpg(process.pid, signal.SIGKILL)
                status = process.wait()
                log(f"{name} exceeded {timeout} s and was killed; stack in {diagnostics}")
        if stdout_path:
            stdout.close()
        elapsed = time.monotonic() - started
        step = {
            "name": name,
            "command": command,
            "status": status,
            "timed_out": timed_out,
            "seconds": round(elapsed, 3),
            "stdout": os.path.relpath(stdout_path, self.out) if stdout_path else None,
            "stderr": os.path.relpath(stderr_path, self.out),
        }
        self.steps.append(step)
        ok = status == 0 and not timed_out
        if not ok and required:
            self.failed = True
        log(f"{name}: status {status}{' (timeout)' if timed_out else ''} in {elapsed:.1f} s")
        return ok


def spin_proof(runner, bench, wasm, variant, out):
    """Samples a spinning process and counts the dispatch symbols it is executing."""
    name = f"spin-{variant}"
    stdout_path = os.path.join(out, "spin", f"{variant}.txt")
    os.makedirs(os.path.dirname(stdout_path), exist_ok=True)
    stderr_path = os.path.join(out, "logs", f"{name}.stderr.txt")
    command = [bench, "spin", "--wasm", wasm, "--variant", variant, "--seconds", "6", "--scale", "2"]
    with open(stdout_path, "w") as stdout, open(stderr_path, "w") as stderr:
        process = subprocess.Popen(command, stdout=stdout, stderr=stderr)
        time.sleep(2)
        sample_path = os.path.join(out, "spin", f"{variant}.sample.txt")
        sample = ["sample", str(process.pid), "2", "-file", sample_path]
        if os.geteuid() != 0:
            sample = ["sudo", "-n"] + sample
        sampled = subprocess.run(sample, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
        try:
            status = process.wait(timeout=60)
        except subprocess.TimeoutExpired:
            os.kill(process.pid, signal.SIGKILL)
            status = process.wait()
    counts = {}
    if os.path.exists(sample_path):
        text = open(sample_path, errors="replace").read()
        for symbol in ["wasmkit_tc_", "runDirectThreaded", "runTokenThreaded", "startTokenThreaded",
                       "runDispatchGroups", "doExecute", "wasmkit_trap_guard_run"]:
            counts[symbol] = len(re.findall(re.escape(symbol), text))
    runner.steps.append({
        "name": name, "command": command, "status": status, "sample_status": sampled.returncode,
        "symbol_lines": counts,
    })
    log(f"{name}: status {status}, sample {sampled.returncode}, symbols {counts}")
    return status == 0, counts


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bench", required=True)
    parser.add_argument("--wasm", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--wasmi")
    parser.add_argument("--wasmi-root")
    parser.add_argument("--processes", type=int, default=3)
    parser.add_argument("--rounds", type=int, default=8)
    parser.add_argument("--samples", type=int, default=5)
    parser.add_argument("--warmup", type=int, default=2)
    parser.add_argument("--cold", type=int, default=10)
    parser.add_argument("--wasmi-rounds", type=int, default=4)
    parser.add_argument("--wasmi-warmup-ms", type=int, default=500)
    parser.add_argument("--wasmi-measure-ms", type=int, default=1000)
    parser.add_argument("--size", action="append", default=[], help="extra size flags for the bench")
    parser.add_argument("--only", default="verify,spin,warm,bounds,cold,wasmi")
    args = parser.parse_args()

    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    runner = Runner(out)
    only = set(args.only.split(","))
    sizes = [token for flag in args.size for token in flag.split()]
    started = time.time()

    if "verify" in only:
        runner.run("verify", [args.bench, "verify", "--wasm", args.wasm, "--variants",
                              "token,token-control,direct,direct-mprotect"],
                   timeout=1200, stdout_path=os.path.join(out, "verify.txt"))
        if runner.failed:
            log("verification failed; timings are not taken")
            finish(runner, out, started)
            return 1

    if "spin" in only and platform.system() == "Darwin":
        for variant in ["token", "token-control", "direct", "direct-mprotect"]:
            spin_proof(runner, args.bench, args.wasm, variant, out)

    if "warm" in only:
        for process in range(args.processes):
            shift = process % len(MAIN_VARIANTS)
            variants = MAIN_VARIANTS[shift:] + MAIN_VARIANTS[:shift]
            runner.run(f"warm-{process}", [args.bench, "warm", "--wasm", args.wasm, "--variants",
                                           ",".join(variants), "--rounds", str(args.rounds),
                                           "--samples", str(args.samples), "--warmup", str(args.warmup)]
                       + sizes,
                       timeout=3600, stdout_path=os.path.join(out, "warm", f"process-{process}.csv"))

    if "bounds" in only:
        runner.run("bounds-0", [args.bench, "warm", "--wasm", args.wasm, "--variants",
                                "direct,direct-mprotect", "--rounds", str(args.rounds),
                                "--samples", str(args.samples), "--warmup", str(args.warmup)] + sizes,
                   timeout=3600, stdout_path=os.path.join(out, "bounds", "process-0.csv"))

    if "fuel" in only:
        runner.run("fuel-0", [args.bench, "warm", "--wasm", args.wasm, "--variants",
                              "token-control,direct-fuel,direct,token-fuel", "--rounds", str(args.rounds),
                              "--samples", str(args.samples), "--warmup", str(args.warmup)] + sizes,
                   timeout=3600, stdout_path=os.path.join(out, "fuel", "process-0.csv"))

    if "cold" in only:
        for iteration in range(args.cold):
            shift = iteration % len(MAIN_VARIANTS)
            order = MAIN_VARIANTS[shift:] + MAIN_VARIANTS[:shift]
            if iteration % 2 == 1:
                order = list(reversed(order))
            for variant in order:
                runner.run(f"cold-{iteration}-{variant}",
                           [args.bench, "cold", "--wasm", args.wasm, "--variant", variant],
                           timeout=600, stdout_path=os.path.join(out, "cold", f"{iteration}-{variant}.csv"))

    if "wasmi" in only and args.wasmi:
        for round_index in range(args.wasmi_rounds):
            shift = round_index % len(MAIN_VARIANTS)
            order = MAIN_VARIANTS[shift:] + MAIN_VARIANTS[:shift]
            if round_index % 2 == 1:
                order = list(reversed(order))
            for variant in order:
                command = [args.wasmi] + WASMI_VARIANTS[variant] + [
                    "--warmup-ms", str(args.wasmi_warmup_ms), "--measure-ms", str(args.wasmi_measure_ms)]
                if args.wasmi_root:
                    command += ["--root", args.wasmi_root]
                runner.run(f"wasmi-{round_index}-{variant}", command, timeout=1800,
                           stdout_path=os.path.join(out, "wasmi", f"{round_index}-{variant}.csv"))

    return finish(runner, out, started)


def finish(runner, out, started):
    meta = {
        "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(started)),
        "seconds": round(time.time() - started, 1),
        "failed": runner.failed,
        "steps": runner.steps,
    }
    with open(os.path.join(out, "steps.json"), "w") as file:
        json.dump(meta, file, indent=2)
    log(f"done in {meta['seconds']} s, failed={runner.failed}")
    return 1 if runner.failed else 0


if __name__ == "__main__":
    sys.exit(main())
