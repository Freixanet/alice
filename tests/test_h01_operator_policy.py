"""Regression tests for the test operator's inspection of real Docker policy.

The container inspections are synthetic here. Actual kernel denial is proved
separately by the hosted H01 Docker workflow, not by these mock fixtures.
"""

import json
import os
import unittest
from types import SimpleNamespace
from unittest import mock

with mock.patch.dict(os.environ, {"H01_FIXTURE_DIR": "/tmp/h01-unit-test-fixture"}):
    from scripts import h01_operator


PROJECT = "alice-h01-unit-fixture"


def container_config(service):
    suffixes = (["asr_backplane"] if service == "asr" else
                ["asr_backplane", "hermes_front", "operator_front"])
    return {
        "HostConfig": {
            "ReadonlyRootfs": True, "Privileged": False,
            "PidMode": "", "NetworkMode": "default", "CapDrop": ["ALL"],
        },
        "Config": {"User": "12001:12001" if service == "asr" else "12002:12002"},
        "Mounts": [],
        "NetworkSettings": {
            "Networks": {PROJECT + "_" + suffix: {} for suffix in suffixes},
            "Ports": ({"8443/tcp": None} if service == "asr" else
                      {"8443/tcp": [{"HostIp": "127.0.0.1", "HostPort": "38443"}]}),
        },
    }


class H01OperatorDockerPolicyTests(unittest.TestCase):
    def setUp(self):
        self.configs = {service: container_config(service) for service in ("asr", "gateway")}
        self.internal_overrides = {}

    def inspect(self, command, text=True):
        self.assertTrue(text)
        if command[:2] == ["docker", "inspect"]:
            service = command[2].removeprefix("test-")
            return json.dumps([self.configs[service]])
        if command[:3] == ["docker", "network", "inspect"]:
            name = command[3]
            suffix = name.removeprefix(PROJECT + "_")
            return json.dumps([{"Internal": self.internal_overrides.get(
                name, suffix != "operator_front")}])
        raise AssertionError("unexpected Docker inspect command: " + repr(command))

    def verify(self):
        def docker(*args):
            self.assertEqual(args[:2], ("ps", "-q"))
            return SimpleNamespace(stdout="test-" + args[2])

        with mock.patch.dict(os.environ, {"H01_COMPOSE_PROJECT": PROJECT}), \
             mock.patch.object(h01_operator, "docker", side_effect=docker), \
             mock.patch.object(h01_operator.subprocess, "check_output", side_effect=self.inspect):
            return h01_operator.verify_live_container_policy()

    def test_exact_isolated_networks_and_loopback_gateway_pass(self):
        self.assertEqual([entry["service"] for entry in self.verify()], ["asr", "gateway"])

    def test_additional_asr_network_must_fail(self):
        self.configs["asr"]["NetworkSettings"]["Networks"][PROJECT + "_zzz_public"] = {}
        with self.assertRaises(AssertionError):
            self.verify()

    def test_asr_backplane_not_internal_must_fail(self):
        self.internal_overrides[PROJECT + "_asr_backplane"] = False
        with self.assertRaises(AssertionError):
            self.verify()

    def test_gateway_public_host_binding_must_fail(self):
        self.configs["gateway"]["NetworkSettings"]["Ports"]["8443/tcp"][0]["HostIp"] = "0.0.0.0"
        with self.assertRaises(AssertionError):
            self.verify()

    def test_gateway_second_published_port_must_fail(self):
        self.configs["gateway"]["NetworkSettings"]["Ports"]["9999/tcp"] = [
            {"HostIp": "127.0.0.1", "HostPort": "39999"}]
        with self.assertRaises(AssertionError):
            self.verify()

    def test_asr_published_port_must_fail(self):
        self.configs["asr"]["NetworkSettings"]["Ports"]["8443/tcp"] = [
            {"HostIp": "127.0.0.1", "HostPort": "38444"}]
        with self.assertRaises(AssertionError):
            self.verify()


if __name__ == "__main__":
    unittest.main()
