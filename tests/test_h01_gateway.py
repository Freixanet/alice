"""H01 route/identity tests. Docker adversarial tests remain independently required."""
import secrets
import unittest
from unittest import mock

from alice_secure_runner import h01_gateway


class H01GatewayUnitTests(unittest.TestCase):
    def setUp(self):
        self.tokens = {}

        def test_secret(name):
            return self.tokens.setdefault(name, secrets.token_urlsafe(50))

        with mock.patch.object(h01_gateway, 'secret', side_effect=test_secret), \
                mock.patch.object(h01_gateway.ssl, 'create_default_context', return_value=mock.Mock()):
            self.gateway = h01_gateway.Gateway()

    def test_hermes_bearer_can_only_propose(self):
        bearer = 'Bearer ' + self.tokens['proposal_a']
        self.assertEqual(self.gateway.authenticate(bearer, '/v1/proposals'), ('a', 'proposal'))
        for path in ('/v1/jobs', '/v1/approve', '/v1/commit', '/v1/challenge',
                     '/v1/human-finish', '/v1/human-reissue'):
            with self.subTest(path=path), self.assertRaises(PermissionError):
                self.gateway.authenticate(bearer, path)
        with self.assertRaises(LookupError):
            self.gateway.authenticate(bearer, '/v1/browser/cdp')

    def test_actor_principals_are_distinct_and_non_transferable(self):
        for actor in ('a', 'b'):
            self.assertEqual(self.gateway.authenticate('Bearer ' + self.tokens['owner_' + actor],
                                                       '/v1/jobs'), (actor, 'owner'))
            self.assertEqual(self.gateway.authenticate('Bearer ' + self.tokens['human_' + actor],
                                                       '/v1/human-finish'), (actor, 'human'))
        self.assertEqual(len(self.gateway.tokens), 6)
        self.assertEqual(len(set(self.gateway.tokens)), 6)

    def test_gateway_no_arbitrary_proxy_payload(self):
        with self.assertRaises(ValueError):
            self.gateway.forward('a', '/v1/proposals', {'job_id': 'fixture', 'proposal': {},
                                  'url': 'https://attacker.invalid'}, human=False)


if __name__ == '__main__':
    unittest.main()
