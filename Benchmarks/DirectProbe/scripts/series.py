#!/usr/bin/env python3
"""Runs the final comparison of the base revision and the prototype on one machine.

Two harness binaries run the same guest. The base binary is built against the control base and
measures token, token-control and direct. The head binary is built against the prototype and adds
direct-control. Each warm process runs paired rounds of its own variants, and base and head
processes alternate, so every cross-binary ratio compares neighbouring processes.
"""

import argparse
import os
import platform
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from run import Runner, spin_proof, finish, WASMI_VARIANTS  # noqa: E402

BASE_VARIANTS = ["token", "token-control", "direct"]
HEAD_VARIANTS = ["token", "token-control", "direct", "direct-control"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-bench", required=True)
    parser.add_argument("--head-bench", required=True)
    parser.add_argument("--wasm", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--rounds", type=int, default=6)
    parser.add_argument("--samples", type=int, default=5)
    parser.add_argument("--warmup", type=int, default=2)
    parser.add_argument("--size", action="append", default=[])
    parser.add_argument("--latency-intervals", default="64,1024,16384")
    parser.add_argument("--latency-samples", type=int, default=20)
    parser.add_argument("--cold", type=int, default=8)
    parser.add_argument("--wasmi")
    parser.add_argument("--wasmi-root")
    parser.add_argument("--wasmi-rounds", type=int, default=3)
    parser.add_argument("--wasmi-warmup-ms", type=int, default=500)
    parser.add_argument("--wasmi-measure-ms", type=int, default=1000)
    parser.add_argument("--only", default="verify,spin,series,latency,cold,wasmi")
    args = parser.parse_args()

    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    runner = Runner(out)
    only = set(args.only.split(","))
    sizes = [token for flag in args.size for token in flag.split()]
    started = time.time()
    binaries = {"base": (args.base_bench, BASE_VARIANTS), "head": (args.head_bench, HEAD_VARIANTS)}

    if "verify" in only:
        for side, (bench, variants) in binaries.items():
            extra = ["direct-mprotect"] if side == "head" else []
            runner.run(f"verify-{side}", [bench, "verify", "--wasm", args.wasm, "--variants", ",".join(variants + extra)],
                       timeout=1200, stdout_path=os.path.join(out, "verify", f"{side}.txt"))
        if runner.failed:
            return finish(runner, out, started)

    if "spin" in only and platform.system() == "Darwin":
        for side, variant in [("base", "token-control"), ("base", "direct"), ("head", "direct"), ("head", "direct-control")]:
            ok, counts = spin_proof(runner, binaries[side][0], args.wasm, variant, os.path.join(out, side))
            runner.steps[-1]["name"] = f"spin-{side}-{variant}"

    if "series" in only:
        for pair in range(args.pairs):
            order = ["base", "head"] if pair % 2 == 0 else ["head", "base"]
            for side in order:
                bench, variants = binaries[side]
                shift = pair % len(variants)
                rotated = variants[shift:] + variants[:shift]
                runner.run(f"series-{pair}-{side}",
                           [bench, "warm", "--wasm", args.wasm, "--variants", ",".join(rotated),
                            "--rounds", str(args.rounds), "--samples", str(args.samples),
                            "--warmup", str(args.warmup)] + sizes,
                           timeout=3600, stdout_path=os.path.join(out, "series", f"{pair}-{side}.csv"))

    if "latency" in only:
        cases = [("base", "token-control"), ("head", "token-control"), ("head", "direct-control")]
        for interval in args.latency_intervals.split(","):
            for index, (side, variant) in enumerate(cases if int(interval) % 2 == 0 else list(reversed(cases))):
                runner.run(f"latency-{interval}-{side}-{variant}",
                           [binaries[side][0], "latency", "--wasm", args.wasm, "--variant", variant,
                            "--polling-interval", interval, "--samples", str(args.latency_samples)],
                           timeout=900,
                           stdout_path=os.path.join(out, "latency", f"{interval}-{side}-{variant}.csv"))

    if "cold" in only:
        for iteration in range(args.cold):
            cases = [("base", v) for v in ["token-control", "direct"]] + [("head", v) for v in HEAD_VARIANTS]
            if iteration % 2 == 1:
                cases.reverse()
            for side, variant in cases:
                runner.run(f"cold-{iteration}-{side}-{variant}",
                           [binaries[side][0], "cold", "--wasm", args.wasm, "--variant", variant],
                           timeout=600,
                           stdout_path=os.path.join(out, "cold", f"{iteration}-{side}-{variant}.csv"))

    if "wasmi" in only and args.wasmi:
        for round_index in range(args.wasmi_rounds):
            shift = round_index % len(HEAD_VARIANTS)
            order = HEAD_VARIANTS[shift:] + HEAD_VARIANTS[:shift]
            if round_index % 2 == 1:
                order.reverse()
            for variant in order:
                command = [args.wasmi] + WASMI_VARIANTS[variant] + [
                    "--warmup-ms", str(args.wasmi_warmup_ms), "--measure-ms", str(args.wasmi_measure_ms)]
                if args.wasmi_root:
                    command += ["--root", args.wasmi_root]
                runner.run(f"wasmi-{round_index}-{variant}", command, timeout=1800,
                           stdout_path=os.path.join(out, "wasmi", f"{round_index}-{variant}.csv"))

    return finish(runner, out, started)


if __name__ == "__main__":
    sys.exit(main())
