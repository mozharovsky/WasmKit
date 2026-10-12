#!/usr/bin/env python3
"""Summarizes a series.py output directory into series-summary.md and series-summary.json.

Within one process, a ratio is formed per round. Across the base and head binaries, a ratio is
formed per pair of neighbouring processes from the medians of their rounds.
"""

import argparse
import csv
import glob
import json
import os
import statistics
from collections import defaultdict

sys_path = os.path.dirname(os.path.abspath(__file__))
import sys  # noqa: E402

sys.path.insert(0, sys_path)
from analyze import describe, verdict, fmt_ns, ratio_cell, quantile, read_wasmi, summarize_wasmi  # noqa: E402

WITHIN = {
    "head": [
        ("direct", "token", "dispatch"),
        ("token-control", "token", "token control"),
        ("direct-control", "direct", "direct control"),
        ("direct-control", "token-control", "candidate"),
    ],
    "base": [
        ("direct", "token", "dispatch"),
        ("token-control", "token", "token control"),
    ],
}
ACROSS = [
    ("head", "direct-control", "base", "token-control", "head direct-control / base token-control"),
    ("head", "direct", "base", "direct", "head direct / base direct"),
    ("head", "direct-control", "base", "direct", "head direct-control / base direct"),
    ("head", "token-control", "base", "token-control", "head token-control / base token-control"),
    ("head", "token", "base", "token", "head token / base token"),
]


def read_series(directory):
    """Returns {(pair, side): {(round, variant, case): median per-unit ns}} and rejected samples."""
    result = {}
    bad = 0
    for path in sorted(glob.glob(os.path.join(directory, "*.csv"))):
        pair, side = os.path.basename(path)[:-4].split("-")
        groups = defaultdict(list)
        with open(path) as file:
            rows = [line for line in file if not line.startswith("#")]
        for row in csv.DictReader(rows):
            if row["kind"] != "sample" or row["variant"] == "harness":
                continue
            if row["ok"] != "1":
                bad += 1
                continue
            groups[(int(row["round"]), row["variant"], row["case"])].append(int(row["nanoseconds"]) / int(row["units"]))
        result[(int(pair), side)] = {key: statistics.median(values) for key, values in groups.items()}
    return result, bad


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out")
    args = parser.parse_args()
    out = args.out
    report = {}
    lines = ["# Devbox series summary", ""]

    series, bad = read_series(os.path.join(out, "series"))
    cases = sorted({case for values in series.values() for (_, _, case) in values})
    lines += [f"Rejected samples: {bad}. Per call, or per import for chatter.", ""]

    # Absolute medians per side and variant.
    lines += ["## Medians of round medians", "", "| Case | base token | base token-control | base direct | head token | head token-control | head direct | head direct-control |",
              "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    absolute = {}
    for case in cases:
        cells = []
        for side, variant in [("base", "token"), ("base", "token-control"), ("base", "direct"), ("head", "token"),
                              ("head", "token-control"), ("head", "direct"), ("head", "direct-control")]:
            values = [v for (pair, s), rounds in series.items() if s == side
                      for (r, var, c), v in rounds.items() if var == variant and c == case]
            if values:
                absolute[f"{side}/{variant}/{case}"] = describe(values)
                cells.append(fmt_ns(statistics.median(values)))
            else:
                cells.append("")
        lines.append(f"| {case} | " + " | ".join(cells) + " |")
    lines.append("")
    report["absolute"] = absolute

    # Within-process ratios.
    report["within"] = {}
    for side, comparisons in WITHIN.items():
        lines += [f"## Within {side} processes, per round", "",
                  "| Case | " + " | ".join(f"{a} / {b}" for a, b, _ in comparisons) + " |",
                  "| --- | " + " | ".join("---" for _ in comparisons) + " |"]
        for case in cases:
            cells = []
            for numerator, denominator, label in comparisons:
                ratios = []
                for (pair, s), rounds in series.items():
                    if s != side:
                        continue
                    for round_index in {r for (r, _, _) in rounds}:
                        a = rounds.get((round_index, numerator, case))
                        b = rounds.get((round_index, denominator, case))
                        if a and b:
                            ratios.append(a / b)
                if ratios:
                    stats = describe(ratios)
                    stats["verdict"] = verdict(stats)
                    report["within"][f"{side}/{label}/{case}"] = stats
                    cells.append(ratio_cell(stats))
                else:
                    cells.append("")
            lines.append(f"| {case} | " + " | ".join(cells) + " |")
        lines.append("")

    # Across binaries, per pair of neighbouring processes.
    report["across"] = {}
    pairs = sorted({pair for (pair, _) in series})
    lines += ["## Across binaries, per pair of neighbouring processes", "",
              "| Case | " + " | ".join(label for *_, label in ACROSS) + " |",
              "| --- | " + " | ".join("---" for _ in ACROSS) + " |"]
    for case in cases:
        cells = []
        for side_a, var_a, side_b, var_b, label in ACROSS:
            ratios = []
            for pair in pairs:
                a = [v for (r, var, c), v in series.get((pair, side_a), {}).items() if var == var_a and c == case]
                b = [v for (r, var, c), v in series.get((pair, side_b), {}).items() if var == var_b and c == case]
                if a and b:
                    ratios.append(statistics.median(a) / statistics.median(b))
            if ratios:
                stats = describe(ratios)
                stats["verdict"] = verdict(stats)
                report["across"][f"{label}/{case}"] = stats
                cells.append(ratio_cell(stats))
            else:
                cells.append("")
        lines.append(f"| {case} | " + " | ".join(cells) + " |")
    lines.append("")

    # Stop latency.
    latency = defaultdict(list)
    failed = 0
    for path in sorted(glob.glob(os.path.join(out, "latency", "*.csv"))):
        side = os.path.basename(path).split("-")[1]
        with open(path) as file:
            for row in csv.DictReader(line for line in file if not line.startswith("#")):
                if row["ok"] != "1":
                    failed += 1
                    continue
                latency[(side, row["variant"], int(row["interval"]), row["mode"])].append(int(row["nanoseconds"]))
    if latency:
        report["latency"] = {f"{s}/{v}/{i}/{m}": describe(values) for (s, v, i, m), values in latency.items()}
        lines += ["## Stop latency", "", f"Failed samples: {failed}. Time from the request to the throw.", "",
                  "| Binary | Variant | Interval | Mode | n | median | p90 | max |",
                  "| --- | --- | ---: | --- | ---: | ---: | ---: | ---: |"]
        for (side, variant, interval, mode), values in sorted(latency.items(), key=lambda x: (x[0][3], x[0][2], x[0][0], x[0][1])):
            lines.append(f"| {side} | {variant} | {interval} | {mode} | {len(values)} | {fmt_ns(statistics.median(values))} | "
                         f"{fmt_ns(quantile(values, 0.9))} | {fmt_ns(max(values))} |")
        lines.append("")

    # Cold steps.
    cold = defaultdict(list)
    for path in sorted(glob.glob(os.path.join(out, "cold", "*.csv"))):
        side = os.path.basename(path).split("-")[1]
        with open(path) as file:
            for row in csv.DictReader(line for line in file if not line.startswith("#")):
                if row["kind"] == "cold" and row["ok"] == "1":
                    cold[(row["step"], side, row["variant"])].append(int(row["nanoseconds"]))
    if cold:
        columns = [("base", "token-control"), ("base", "direct"), ("head", "token-control"), ("head", "direct"),
                   ("head", "direct-control")]
        lines += ["## Cold process steps (median)", "", "| Step | " + " | ".join(f"{s} {v}" for s, v in columns) + " |",
                  "| --- | " + " | ".join("---:" for _ in columns) + " |"]
        for step in sorted({s for (s, _, _) in cold}):
            cells = [fmt_ns(statistics.median(cold[(step, s, v)])) if cold.get((step, s, v)) else "" for s, v in columns]
            lines.append(f"| {step} | " + " | ".join(cells) + " |")
        lines.append("")
        report["cold"] = {f"{s}/{side}/{v}": describe(values) for (s, side, v), values in cold.items()}

    if os.path.isdir(os.path.join(out, "wasmi")):
        wasmi, geomeans = summarize_wasmi(read_wasmi(os.path.join(out, "wasmi")))
        report["wasmi"] = wasmi
        report["wasmi_geomean"] = geomeans
        lines += ["## WasmiBenchmarks on the head binary", "", "Geometric mean of the per-round ratios over all cases:", ""]
        for label, stats in geomeans.items():
            lines.append(f"- {label}: {ratio_cell(stats)}")
        lines.append("")

    with open(os.path.join(out, "series-summary.json"), "w") as file:
        json.dump(report, file, indent=2)
    with open(os.path.join(out, "series-summary.md"), "w") as file:
        file.write("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
