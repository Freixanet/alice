"""CPU here is the change between two readings, not a process's lifetime average."""
import importlib.util
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True
HOST_LOAD = Path(__file__).resolve().parents[1] / "dashboard" / "host_load.py"
PLUGIN_API = Path(__file__).resolve().parents[1] / "dashboard" / "plugin_api.py"


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


class HostLoadTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load(HOST_LOAD, "alice_host_load_test")

    def test_cputime_includes_days_hours_and_fractions(self):
        self.assertEqual(self.mod.parse_cputime("1:02.50"), 62.5)
        self.assertEqual(self.mod.parse_cputime("1:02:03"), 3723)
        self.assertEqual(self.mod.parse_cputime("2-01:00:00"), 2 * 86400 + 3600)

    def test_cpu_is_the_delta_over_the_wall_clock(self):
        previous = {7: (10.0, 1000, "Safari")}
        current = {7: (11.0, 1000, "Safari")}
        report = self.mod.build_report(
            previous, current, elapsed=2.0,
            memory={"used": 8, "total": 16, "compressor": 0},
            cores=2, load=(1.0, 1.0, 1.0), host="studio", sampled_at=10,
            name_of=lambda pid, comm: comm,
        )
        self.assertFalse(report["warming"])
        # One second of CPU over two seconds is 50% of one core.
        self.assertEqual(report["processes"][0]["cpu"], 50.0)
        # And 25% of a two-core Mac.
        self.assertEqual(report["cpu"]["percent"], 25.0)
        self.assertEqual(report["processes"][0]["name"], "Safari")

    def test_the_first_reading_does_not_pretend_the_mac_is_idle(self):
        current = {1: (1000.0, 1000, "kernel_task")}
        report = self.mod.build_report(
            None, current, elapsed=0,
            memory={"used": 1, "total": 2, "compressor": 0},
            cores=8, load=(0, 0, 0), host="studio", sampled_at=1,
            name_of=lambda pid, comm: comm,
        )
        self.assertTrue(report["warming"])
        self.assertIsNone(report["processes"][0]["cpu"])
        self.assertEqual(report["cpu"]["percent"], 0.0)

    def test_a_new_process_waits_for_its_own_second_reading(self):
        previous = {1: (1.0, 1000, "kernel_task")}
        current = {1: (1.0, 1000, "kernel_task"), 9: (3.0, 1000, "new")}
        report = self.mod.build_report(
            previous, current, elapsed=1.0,
            memory={"used": 1, "total": 4, "compressor": 0},
            cores=1, load=(0, 0, 0), host="studio", sampled_at=2,
            name_of=lambda pid, comm: comm,
        )
        by_pid = {row["pid"]: row for row in report["processes"]}
        self.assertIsNone(by_pid[9]["cpu"])
        self.assertEqual(by_pid[1]["cpu"], 0.0)

    def test_memory_pressure_follows_how_much_the_kernel_still_calls_free(self):
        self.assertEqual(self.mod.pressure({"used": 1, "total": 16, "free_percent": 66}), "ok")
        self.assertEqual(self.mod.pressure({"used": 1, "total": 16, "free_percent": 15}), "tight")
        self.assertEqual(self.mod.pressure({"used": 1, "total": 16, "free_percent": 5}), "critical")

    def test_ps_rows_keep_the_command_name_and_drop_pid_zero(self):
        text = "    0  0:00.00      0  kernel\n   42  1:02.50   2048  Safari\n"
        rows = self.mod.parse_ps(text)
        self.assertEqual(list(rows), [42])
        self.assertEqual(rows[42][0], 62.5)
        self.assertEqual(rows[42][1], 2048 * 1024)
        self.assertEqual(rows[42][2], "Safari")

    def test_a_one_second_blip_does_not_swing_the_published_number(self):
        report = {
            "warming": False,
            "cpu": {"percent": 40.0, "cores": 8, "load": [1, 1, 1]},
            "memory": {"used": 100, "total": 1000, "pressure": "ok"},
            "processes": [{"pid": 7, "name": "Safari", "cpu": 40.0, "memory": 200 * 1024 * 1024}],
        }
        first, cpu_state, machine = self.mod.settle(report, {}, None)
        self.assertEqual(first["cpu"]["percent"], 40.0)
        report["cpu"]["percent"] = 0
        report["processes"][0]["cpu"] = 0
        second, _, _ = self.mod.settle(report, cpu_state, machine)
        # Three quarters of the previous reading remains, so 40 does not become 0.
        self.assertEqual(second["cpu"]["percent"], 30.0)
        self.assertEqual(second["processes"][0]["cpu"], 30.0)

    def test_an_open_app_says_what_closing_it_loses(self):
        found = self.mod.consequence(
            "Safari", "/Applications/Safari.app/Contents/MacOS/Safari", False
        )
        self.assertEqual(found["effect"], "app")
        self.assertEqual(found["affects"], "Safari")
        self.assertIn("Unsaved work", found["effectDetail"])

    def test_a_helper_names_the_app_it_belongs_to(self):
        found = self.mod.consequence(
            "Google Chrome Helper",
            "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Google Chrome Helper",
            False,
        )
        self.assertEqual(found["effect"], "helper")
        self.assertEqual(found["affects"], "Google Chrome")
        self.assertIn("glitch or quit", found["effectDetail"])

    def test_a_system_service_names_the_part_of_the_mac_it_runs(self):
        found = self.mod.consequence("mds", "/System/Library/Frameworks/CoreServices.framework/mds", False)
        self.assertEqual(found["effect"], "service")
        self.assertIn("Spotlight", found["effectTitle"])

    def test_a_background_task_does_not_claim_other_apps(self):
        found = self.mod.consequence("job", "/Users/me/bin/job", False)
        self.assertEqual(found["effect"], "task")
        self.assertIn("Other apps keep running", found["effectDetail"])

    def test_alices_own_process_says_it_would_disconnect_the_phone(self):
        found = self.mod.consequence("Python", "/usr/local/bin/python", True)
        self.assertEqual(found["effect"], "connection")
        self.assertIn("disconnects this phone", found["effectDetail"])

    def test_stopping_refuses_what_keeps_the_mac_up(self):
        self.assertEqual(
            self.mod.refusal(1, "launchd", "launchd", set()),
            "launchd keeps this Mac running.",
        )
        self.assertEqual(
            self.mod.refusal(90, "WindowServer", "WindowServer", set()),
            "WindowServer keeps this Mac running.",
        )
        self.assertEqual(
            self.mod.refusal(90, "Safari", "Safari", {90}),
            "Safari keeps this Mac running.",
        )

    def test_stopping_refuses_a_pid_that_now_belongs_to_someone_else(self):
        self.assertEqual(
            self.mod.refusal(42, "Safari", "Notes", set()),
            "That process already ended.",
        )
        self.assertIsNone(self.mod.refusal(42, "Safari", "Safari", set()))

    def test_vm_stat_counts_free_and_speculative_as_available(self):
        text = "Mach Virtual Memory Statistics: (page size of 100 bytes)\nPages free: 2.\nPages speculative: 3.\n"
        memory = self.mod.parse_vm_stat(text, total=1000)
        self.assertEqual(memory["used"], 500)


class HostLoadRouteTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from fastapi import FastAPI
        from fastapi.testclient import TestClient

        cls.api = load(PLUGIN_API, "alice_plugin_api_host_load_test")
        app = FastAPI()
        app.include_router(cls.api.router, prefix=cls.api.PLUGIN_PREFIX)
        cls.client = TestClient(app)

    def test_the_route_returns_the_reading_and_forbids_caching(self):
        reading = {"host": "studio", "warming": True, "processes": []}
        with mock.patch.object(self.api, "_host_load_reading", return_value=reading):
            response = self.client.get("/api/plugins/alice/host/load")
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["host"], "studio")
        self.assertIn("no-store", response.headers["cache-control"])

    def test_stop_reports_a_refusal_without_ending_a_process(self):
        with mock.patch.object(self.api, "_stop_host_process", return_value={"ok": False, "error": "That process already ended."}):
            response = self.client.post(
                "/api/plugins/alice/host/process/stop",
                json={"pid": 42, "name": "Safari"},
            )
        self.assertEqual(response.status_code, 409, response.text)
        self.assertEqual(response.json()["error"], "That process already ended.")
