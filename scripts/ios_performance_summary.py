#!/usr/bin/env python3
"""Summarize xcresulttool CSV measurements without discarding slow samples."""

import csv
import json
import math
from pathlib import Path
import statistics
import sys


def summarize(root: Path) -> str:
    output = ["## Measurements", "", "All iterations retained; units are those exported by Xcode.", ""]
    metrics_count = 0
    for manifest in sorted(root.glob("*-metrics/manifest.json")):
        for test in json.loads(manifest.read_text()):
            names = test.get("metricsFiles") or [test.get("metricsFileName")]
            for name in names:
                if not isinstance(name, str) or Path(name).name != name:
                    raise ValueError("Invalid metric filename")
                file = manifest.parent / name
                # Xcode 26.6 exports foo.csv but records foo.csv.csv in its
                # manifest. Use the single suffix only when the exact file is absent.
                if not file.is_file() and name.endswith(".csv.csv"):
                    file = file.with_suffix("")
                with file.open(newline="") as stream:
                    for row in csv.DictReader(stream):
                        title = str(test["testIdentifier"]).replace("|", "\\|")
                        output += [f"### {title}", "", row["Destination"], "",
                                   "| Metric | Samples | Mean | Median | Min | Max | Unit |",
                                   "| --- | ---: | ---: | ---: | ---: | ---: | --- |"]
                        for key, raw in row.items():
                            if not key.endswith(" (Iterations)"):
                                continue
                            metric = key.removesuffix(" (Iterations)")
                            # Retain every metric in the raw artifact. Cycle and
                            # instruction counters return zero on this simulator;
                            # zero is not evidence that the app did no work.
                            if metric.startswith(("CPU Cycles", "CPU Instructions")):
                                continue
                            values = json.loads(raw)
                            if not values or not all(type(x) in (int, float) and math.isfinite(x) for x in values):
                                raise ValueError(f"Missing or invalid samples: {metric}")
                            unit = row[f"{metric} (Average)"].rsplit(" ", 1)[-1]
                            stats = [statistics.mean(values), statistics.median(values), min(values), max(values)]
                            numbers = " | ".join(f"{x:.3f}" for x in stats)
                            output.append(f"| {metric} | {len(values)} | {numbers} | {unit} |")
                            metrics_count += 1
                        output += [""]
    if not metrics_count:
        raise ValueError("No performance measurements found")
    output += ["Cycle/instruction counters are retained in raw CSV only; zero counters are not interpreted as zero work.",
               "Memory Physical is a change during the interval; Absolute/Peak Memory Physical are footprints. Negative changes mean memory was released.",
               "A slow first launch is retained. Report median and range alongside mean; five samples do not establish a reliable tail-latency budget."]
    return "\n".join(output) + "\n"


if __name__ == "__main__":
    print(summarize(Path(sys.argv[1])), end="")
