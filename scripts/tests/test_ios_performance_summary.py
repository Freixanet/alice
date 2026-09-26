import csv
import json
from pathlib import Path
import tempfile
import unittest

from scripts.ios_performance_summary import summarize


class PerformanceSummaryTests(unittest.TestCase):
    def fixture(self, root, manifest, values="[41, 5, 5, 5, 5]"):
        folder = root / "run-metrics"
        folder.mkdir()
        (folder / "manifest.json").write_text(json.dumps([manifest]))
        with (folder / "sample.csv").open("w", newline="") as stream:
            writer = csv.writer(stream)
            writer.writerow(["Destination", "Clock Monotonic Time (Average)", "Clock Monotonic Time (Iterations)"])
            writer.writerow(["iPhone Simulator", "12.2 s", values])

    def test_actual_xcode_manifest_double_suffix_keeps_slow_sample(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root, {"testIdentifier": "Launch", "metricsFileName": "sample.csv.csv"})
            self.assertIn("| 5 | 12.200 | 5.000 | 5.000 | 41.000 | s |", summarize(root))

    def test_documented_plural_manifest_preserves_negative_memory_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root, {"testIdentifier": "Journey", "metricsFiles": ["sample.csv"]}, "[-3, 1, 2]")
            self.assertIn("| 3 | 0.000 | 1.000 | -3.000 | 2.000 | s |", summarize(root))

    def test_missing_measurements_fail_instead_of_producing_empty_success(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "No performance measurements"):
                summarize(Path(directory))

    def test_nonfinite_measurements_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root, {"testIdentifier": "Launch", "metricsFiles": ["sample.csv"]}, "[NaN]")
            with self.assertRaisesRegex(ValueError, "invalid samples"):
                summarize(root)


if __name__ == "__main__":
    unittest.main()
