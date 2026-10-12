"""Negative tests for H02's live Docker verifier (not a VM boundary test)."""
import json
import os
import unittest
from types import SimpleNamespace
from unittest import mock

with mock.patch.dict(os.environ, {"H02_FIXTURE_DIR": "/tmp/h02-operator-test"}):
    from scripts import h02_operator

PROJECT = "alice-h02-policy-test"
PRIVATE = PROJECT + "_asr_backplane"
PUBLIC = PROJECT + "_public_front"


def config(service):
    return {
        "HostConfig": {"ReadonlyRootfs": True, "Privileged": False,
                       "NetworkMode": "default", "PidMode": "", "CapDrop": ["ALL"]},
        "Config": {"User": ("12001:12001" if service == "asr" else "12002:12002")},
        "Mounts": [],
        "NetworkSettings": {
            "Networks": ({PRIVATE: {"IPAddress": "172.19.0.2"}} if service == "asr"
                         else {PRIVATE: {}, PUBLIC: {}}),
            "Ports": ({"8443/tcp": None} if service == "asr"
                      else {"8443/tcp": [{"HostIp": "127.0.0.1", "HostPort": "38444"}]}),
        },
    }


class H02PolicyTests(unittest.TestCase):
    def setUp(self):
        self.configs = {"asr": config("asr"), "gateway": config("gateway")}
        self.nets = {PRIVATE: True, PUBLIC: False}

    def check_output(self, command, text):
        self.assertTrue(text)
        if command[:2] == ["docker", "inspect"]:
            return json.dumps([self.configs[command[-1].removeprefix("test-")]])
        if command[:3] == ["docker", "network", "inspect"]:
            return json.dumps([{"Internal": self.nets[command[-1]]}])
        raise AssertionError("unexpected command")

    def verify(self):
        def fake_docker(*args):
            self.assertEqual(args[:2], ("ps", "-q"))
            return SimpleNamespace(stdout="test-" + args[2])
        with mock.patch.dict(os.environ, {"H02_COMPOSE_PROJECT": PROJECT,
                                          "H02_PUBLIC_BIND": "127.0.0.1"}), \
                mock.patch.object(h02_operator, "docker", side_effect=fake_docker), \
                mock.patch.object(h02_operator.subprocess, "check_output", side_effect=self.check_output):
            return h02_operator.verify_policy()

    def test_expected_policy(self):
        self.assertEqual(self.verify(), "172.19.0.2")

    def test_extra_asr_network_is_rejected(self):
        self.configs["asr"]["NetworkSettings"]["Networks"][PROJECT + "_extra"] = {}
        with self.assertRaises(AssertionError):
            self.verify()

    def test_gateway_unintended_public_binding_is_rejected(self):
        self.configs["gateway"]["NetworkSettings"]["Ports"]["8443/tcp"][0]["HostIp"] = "0.0.0.0"
        with self.assertRaises(AssertionError):
            self.verify()

    def test_gateway_additional_network_is_rejected(self):
        self.configs["gateway"]["NetworkSettings"]["Networks"][PROJECT + "_extra"] = {}
        with self.assertRaises(AssertionError):
            self.verify()

    def test_backplane_noninternal_is_rejected(self):
        self.nets[PRIVATE] = False
        with self.assertRaises(AssertionError):
            self.verify()

    def test_private_runner_published_port_is_rejected(self):
        self.configs["asr"]["NetworkSettings"]["Ports"]["8443/tcp"] = [
            {"HostIp": "127.0.0.1", "HostPort": "8443"}]
        with self.assertRaises(AssertionError):
            self.verify()

    def test_root_gateway_is_rejected(self):
        self.configs["gateway"]["Config"]["User"] = "0:0"
        with self.assertRaises(AssertionError):
            self.verify()


if __name__ == "__main__":
    unittest.main()
