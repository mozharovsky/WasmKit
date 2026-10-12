#!/usr/bin/env python3
"""Summarizes a phase A output directory into summary.md and summary.json.

Each warm process runs paired rounds. A round's value of a case is the median of its samples, and
every ratio is formed inside one round of one process before it is summarized, so drift between
rounds or processes does not enter a comparison.
"""

import argparse
import csv
import glob
import json
import math
import os
import statistics
from collections import defaultdict

COMPARISONS = [
    ("direct", "token", "dispatch: direct / token"),
    ("token-control", "token", "control: token-control / token"),
    ("direct", "token-control", "potential: direct / token-control"),
]
BOUNDS = [("direct-mprotect", "direct", "bounds: direct-mprotect / direct")]
FUEL = [
    ("token-fuel", "token-control", "token-fuel / token-control"),
    ("direct-fuel", "direct", "direct-fuel / direct"),
    ("direct-fuel", "token-control", "proxy: direct-fuel / token-control"),
]


def quantile(values, q):
    values = sorted(values)
    if not values:
        return float("nan")
    position = (len(values) - 1) * q
    low = math.floor(position)
    high = math.ceil(position)
    return values[low] + (values[high] - values[low]) * (position - low)


def describe(values):
    return {
        "n": len(values),
        "median": statistics.median(values),
        "min": min(values),
        "max": max(values),
        "p25": quantile(values, 0.25),
        "p75": quantile(values, 0.75),
        "cv": statistics.pstdev(values) / statistics.mean(values) if len(values) > 1 else 0.0,
    }


def verdict(ratio):
    if ratio["max"] < 1:
        return "faster in every round"
    if ratio["min"] > 1:
        return "slower in every round"
    if ratio["p75"] < 1:
        return "faster in most rounds"
    if ratio["p25"] > 1:
        return "slower in most rounds"
    return "within spread"


def read_warm(directory):
    """Returns {(process, round, variant, case): (per-unit ns median, units)} and bad samples."""
    groups = defaultdict(list)
    bad = 0
    for path in sorted(glob.glob(os.path.join(directory, "process-*.csv"))):
        process = os.path.basename(path).split("-")[1].split(".")[0]
        with open(path) as file:
            rows = [line for line in file if not line.startswith("#")]
        for row in csv.DictReader(rows):
            if row["kind"] != "sample":
                continue
            if row["ok"] != "1":
                bad += 1
                continue
            units = int(row["units"])
            groups[(process, int(row["round"]), row["variant"], row["case"])].append(
                (int(row["nanoseconds"]) / units, units))
    medians = {key: (statistics.median(v for v, _ in values), values[0][1]) for key, values in groups.items()}
    return medians, bad


def summarize_warm(medians, comparisons):
    by_case = defaultdict(lambda: defaultdict(list))
    rounds = defaultdict(dict)
    units = {}
    for (process, round_index, variant, case), (value, unit_count) in medians.items():
        by_case[case][variant].append(value)
        rounds[(case, process, round_index)][variant] = value
        units[case] = unit_count
    summary = {}
    for case, variants in by_case.items():
        entry = {"units": units[case], "variants": {v: describe(values) for v, values in variants.items()},
                 "ratios": {}}
        for numerator, denominator, label in comparisons:
            ratios = [r[numerator] / r[denominator] for (c, _, _), r in rounds.items()
                      if c == case and numerator in r and denominator in r]
            if ratios:
                stats = describe(ratios)
                stats["verdict"] = verdict(stats)
                entry["ratios"][label] = stats
        summary[case] = entry
    return summary


def read_cold(directory):
    steps = defaultdict(lambda: defaultdict(list))
    bad = 0
    for path in sorted(glob.glob(os.path.join(directory, "*.csv"))):
        with open(path) as file:
            rows = [line for line in file if not line.startswith("#")]
        for row in csv.DictReader(rows):
            if row["kind"] != "cold":
                continue
            if row["ok"] != "1":
                bad += 1
                continue
            steps[row["step"]][row["variant"]].append(int(row["nanoseconds"]))
    return {step: {variant: describe(values) for variant, values in variants.items()}
            for step, variants in steps.items()}, bad


def read_wasmi(directory):
    """Returns {(round, variant): {case: time}} where CoreMark is turned into 1/score."""
    results = {}
    for path in sorted(glob.glob(os.path.join(directory, "*.csv"))):
        name = os.path.basename(path)[:-4]
        round_index, variant = name.split("-", 1)
        values = {}
        with open(path) as file:
            for line in file:
                parts = line.strip().split(",")
                if parts[0].startswith("execute/") and len(parts) == 4:
                    values[parts[0][len("execute/"):]] = float(parts[1])
                elif parts[0] == "coremark" and len(parts) == 2:
                    values["coremark (1/score)"] = 1.0 / float(parts[1])
        results[(int(round_index), variant)] = values
    return results


def summarize_wasmi(results):
    cases = sorted({case for values in results.values() for case in values})
    rounds = sorted({round_index for round_index, _ in results})
    summary = {}
    for case in cases:
        entry = {"variants": {}, "ratios": {}}
        variants = sorted({variant for _, variant in results})
        for variant in variants:
            values = [results[(r, variant)][case] for r in rounds if case in results.get((r, variant), {})]
            if values:
                entry["variants"][variant] = describe(values)
        for numerator, denominator, label in COMPARISONS:
            ratios = []
            for r in rounds:
                a = results.get((r, numerator), {}).get(case)
                b = results.get((r, denominator), {}).get(case)
                if a and b:
                    ratios.append(a / b)
            if ratios:
                stats = describe(ratios)
                stats["verdict"] = verdict(stats)
                entry["ratios"][label] = stats
        summary[case] = entry
    geomeans = {}
    for numerator, denominator, label in COMPARISONS:
        per_round = []
        for r in rounds:
            logs = []
            for case in cases:
                a = results.get((r, numerator), {}).get(case)
                b = results.get((r, denominator), {}).get(case)
                if a and b:
                    logs.append(math.log(a / b))
            if logs:
                per_round.append(math.exp(sum(logs) / len(logs)))
        if per_round:
            stats = describe(per_round)
            stats["verdict"] = verdict(stats)
            geomeans[label] = stats
    return summary, geomeans


def fmt_ns(value):
    if value >= 1e6:
        return f"{value / 1e6:.2f} ms"
    if value >= 1e3:
        return f"{value / 1e3:.2f} µs"
    return f"{value:.1f} ns"


def ratio_cell(stats):
    return f"{stats['median']:.3f} ({stats['min']:.3f}–{stats['max']:.3f}, n={stats['n']}) {stats['verdict']}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out")
    args = parser.parse_args()
    out = args.out
    report = {}
    lines = ["# Phase A summary", ""]

    if os.path.isdir(os.path.join(out, "warm")):
        medians, bad = read_warm(os.path.join(out, "warm"))
        warm = summarize_warm(medians, COMPARISONS)
        report["warm"] = warm
        report["warm_bad_samples"] = bad
        lines += ["## Warm Swift-WASM cases", "",
                  f"Rejected samples: {bad}. Values are per call, or per import for chatter.", "",
                  "| Case | token | token-control | direct | dispatch | control | potential |",
                  "| --- | ---: | ---: | ---: | --- | --- | --- |"]
        for case, entry in sorted(warm.items()):
            v = entry["variants"]
            cells = [fmt_ns(v[name]["median"]) if name in v else "" for name in ["token", "token-control", "direct"]]
            ratios = [ratio_cell(entry["ratios"][label]) if label in entry["ratios"] else ""
                      for _, _, label in COMPARISONS]
            lines.append(f"| {case} | " + " | ".join(cells + ratios) + " |")
        lines.append("")

    if os.path.isdir(os.path.join(out, "bounds")):
        medians, bad = read_warm(os.path.join(out, "bounds"))
        bounds = summarize_warm(medians, BOUNDS)
        report["bounds"] = bounds
        lines += ["## Bounds strategy under direct dispatch", "", f"Rejected samples: {bad}.", "",
                  "| Case | direct | direct-mprotect | ratio |", "| --- | ---: | ---: | --- |"]
        for case, entry in sorted(bounds.items()):
            v = entry["variants"]
            label = BOUNDS[0][2]
            lines.append(
                f"| {case} | {fmt_ns(v['direct']['median'])} | {fmt_ns(v['direct-mprotect']['median'])} | "
                f"{ratio_cell(entry['ratios'][label]) if label in entry['ratios'] else ''} |")
        lines.append("")

    if os.path.isdir(os.path.join(out, "fuel")):
        medians, bad = read_warm(os.path.join(out, "fuel"))
        fuel = summarize_warm(medians, FUEL)
        report["fuel"] = fuel
        lines += ["## Fuel charges as a checkpoint proxy", "", f"Rejected samples: {bad}.", "",
                  "| Case | token-control | direct | direct-fuel | " + " | ".join(l for _, _, l in FUEL) + " |",
                  "| --- | ---: | ---: | ---: | --- | --- | --- |"]
        for case, entry in sorted(fuel.items()):
            v = entry["variants"]
            cells = [fmt_ns(v[name]["median"]) if name in v else "" for name in ["token-control", "direct", "direct-fuel"]]
            ratios = [ratio_cell(entry["ratios"][label]) if label in entry["ratios"] else "" for _, _, label in FUEL]
            lines.append(f"| {case} | " + " | ".join(cells + ratios) + " |")
        lines.append("")

    if os.path.isdir(os.path.join(out, "cold")):
        cold, bad = read_cold(os.path.join(out, "cold"))
        report["cold"] = cold
        lines += ["## Cold process steps", "", f"Rejected steps: {bad}. Median (min–max) over processes.", "",
                  "| Step | token | token-control | direct |", "| --- | ---: | ---: | ---: |"]
        for step, variants in sorted(cold.items()):
            cells = []
            for name in ["token", "token-control", "direct"]:
                if name in variants:
                    s = variants[name]
                    cells.append(f"{fmt_ns(s['median'])} ({fmt_ns(s['min'])}–{fmt_ns(s['max'])})")
                else:
                    cells.append("")
            lines.append(f"| {step} | " + " | ".join(cells) + " |")
        lines.append("")

    if os.path.isdir(os.path.join(out, "wasmi")):
        results = read_wasmi(os.path.join(out, "wasmi"))
        wasmi, geomeans = summarize_wasmi(results)
        report["wasmi"] = wasmi
        report["wasmi_geomean"] = geomeans
        lines += ["## WasmiBenchmarks replay", "", "Mean time per run in ms. CoreMark is 1/score.", "",
                  "| Case | token | token-control | direct | dispatch | control | potential |",
                  "| --- | ---: | ---: | ---: | --- | --- | --- |"]
        for case, entry in wasmi.items():
            v = entry["variants"]
            cells = [f"{v[name]['median']:.4g}" if name in v else "" for name in ["token", "token-control", "direct"]]
            ratios = [ratio_cell(entry["ratios"][label]) if label in entry["ratios"] else ""
                      for _, _, label in COMPARISONS]
            lines.append(f"| {case} | " + " | ".join(cells + ratios) + " |")
        lines += ["", "Geometric mean of the per-round ratios over all cases:", ""]
        for label, stats in geomeans.items():
            lines.append(f"- {label}: {ratio_cell(stats)}")
        lines.append("")

    with open(os.path.join(out, "summary.json"), "w") as file:
        json.dump(report, file, indent=2)
    with open(os.path.join(out, "summary.md"), "w") as file:
        file.write("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
