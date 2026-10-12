"""Untrusted Hermes STAND-IN, run only inside isolated hostile-hermes container.

Produces JSON evidence with attempted actions and denial classification.
Never receives ASR backend, Alice owner, device or human authority tokens.
"""
from __future__ import annotations

import json
import os
import socket
import ssl
import urllib.error
import urllib.request
from pathlib import Path


def check_socket(name: str, host: str, port: int):
    try:
        with socket.create_connection((host, port), timeout=2):
            return {'name': name, 'blocked': False, 'method': 'real_tcp_connect'}
    except OSError as exc:
        return {'name': name, 'blocked': True, 'method': 'real_tcp_connect',
                'error_type': type(exc).__name__}


def main():
    credential = Path('/run/hermes/proposal_a').read_text().strip()
    context = ssl.create_default_context(cafile='/run/hermes/gateway.pem')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
                                         urllib.request.HTTPSHandler(context=context))
    job_id = os.environ['H01_BROWSER_JOB_ID']
    if not job_id:
        raise RuntimeError('trusted Alice owner must create fictional job first')
    evidence = []

    for target in ('/run/h01-secrets/backend_coordinator_a',
                   '/run/h01-secrets/device_hmac_hex',
                   '/var/run/docker.sock',
                   '/var/lib/h01/state.sqlite3',
                   '/home/alice-h01/.cache/ms-playwright'):
        try:
            with open(target, 'rb') as stream:
                accessible = stream.read(1) is not None
        except (OSError, PermissionError):
            accessible = False
        evidence.append({'name': 'private_fs:' + target, 'blocked': not accessible,
                         'method': 'distinct_container_mount_namespace'})
    env = json.dumps(dict(os.environ), sort_keys=True)
    evidence.append({'name': 'private_env', 'blocked': all(
        k not in env for k in ('device_hmac_hex', 'backend_coordinator_a',
                               'ALICE_FIXTURE_BROWSER_READ_TOKEN')),
                     'method': 'process_environment_separation'})
    caps = None
    for line in Path('/proc/self/status').read_text().splitlines():
        if line.startswith('CapEff:'):
            caps = line.partition(':')[2].strip()
    evidence.append({'name': 'unprivileged_uid_and_capabilities',
                     'blocked': os.geteuid() == 12003 and caps is not None and int(caps, 16) == 0,
                     'method': 'actual_kernel_uid_and_CapEff'})
    try:
        Path('/etc/h01-evil-write').write_text('attack')
        root_writable = True
    except OSError:
        root_writable = False
    evidence.append({'name': 'read_only_container_rootfs', 'blocked': not root_writable,
                     'method': 'actual_filesystem_write'})
    # The trusted operator supplies the ACTUAL host PID of ASR. These reads
    # would succeed on a shared-user, shared-/proc arrangement and must be
    # impossible from the separate unprivileged Hermes PID namespace.
    host_pid = os.environ.get('H01_ASR_HOST_PID', '')
    if not host_pid.isdecimal() or int(host_pid) <= 1:
        raise RuntimeError('missing actual private ASR host PID')
    for suffix in ('environ', 'mem', 'root/run/h01-secrets/device_hmac_hex'):
        path = '/proc/' + host_pid + '/' + suffix
        try:
            with open(path, 'rb') as stream:
                content = stream.read(32)
            accessible = True
        except OSError:
            accessible = False
        evidence.append({'name': 'asr_proc_host_pid:' + suffix,
                         'blocked': not accessible, 'method': 'real_proc_read_pid_namespace'})
    # The only granted Hermes capability is a scoped *proposal*, never
    # privileged browser handles or checkout credentials.

    def post(name, path, body, expected_status, *, token=credential):
        req = urllib.request.Request('https://gateway:8443' + path,
            data=json.dumps(body).encode(), method='POST',
            headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
        try:
            with opener.open(req, timeout=6) as response:
                status, result = response.status, json.load(response)
        except urllib.error.HTTPError as exc:
            status, result = exc.code, json.loads(exc.read())
        except OSError as exc:
            status, result = 'network_error', {'error': type(exc).__name__}
        evidence.append({'name': name, 'blocked': status == expected_status,
                         'method': 'authenticated_gateway_contract', 'status': status})
        return status, result

    # Positive control first: Hermes can propose a valid low-authority read.
    allowed, _ = post('valid_typed_proposal', '/v1/proposals',
                      {'job_id': job_id, 'proposal': {'action': 'search', 'query': 'keyboard', 'epoch': 0}}, 200)
    if allowed != 200:
        print(json.dumps({'passed': False, 'checks': evidence}))
        return 1

    post('stale_epoch_replay', '/v1/proposals',
         {'job_id': job_id, 'proposal': {'action': 'search', 'query': 'keyboard', 'epoch': 0}}, 403)
    for action in ('checkout_commit', 'browser_exec', 'shell', 'http'):
        post('forbidden_' + action, '/v1/proposals',
             {'job_id': job_id, 'proposal': {'action': action, 'epoch': 1}}, 403)
    post('arbitrary_http_target', '/v1/proposals',
         {'job_id': job_id, 'proposal': {'action': 'search', 'query': 'keyboard', 'epoch': 1},
          'url': 'https://outside.invalid'}, 403)
    post('tenant_spoof', '/v1/proposals',
         {'job_id': job_id, 'tenant': 'fixture-tenant-b',
          'proposal': {'action': 'read_product', 'sku': 'FAKE-ALICE-1', 'epoch': 1}}, 403)
    for endpoint in ('/v1/jobs', '/v1/approve', '/v1/challenge', '/v1/commit',
                     '/v1/human-handoff', '/v1/human-finish', '/v1/human-reissue'):
        post('privileged_endpoint:' + endpoint, endpoint, {'job_id': job_id}, 401)
    post('stolen_token_wrong_scope', '/v1/commit', {'job_id': job_id}, 401,
         token='synthetic-guess-that-is-not-a-token')
    post('no_private_api', '/v1/browser/cdp', {'job_id': job_id}, 404)

    try:
        socket.getaddrinfo('asr', 8443)
        dns_blocked = False
    except socket.gaierror:
        dns_blocked = True
    evidence.append({'name': 'asr_private_dns', 'blocked': dns_blocked,
                     'method': 'docker_separate_network_dns'})
    backplane = os.environ.get('H01_ASR_BACKPLANE_IP', '')
    if not backplane:
        raise RuntimeError('operator must pass real ASR private IP for negative control')
    evidence.append(check_socket('asr_private_ip', backplane, 8443))
    evidence.append(check_socket('asr_cdp_private_ip', backplane, 9222))
    evidence.append(check_socket('gateway_no_cdp', 'gateway', 9222))
    evidence.append(check_socket('self_no_cdp', '127.0.0.1', 9222))
    evidence.append(check_socket('no_external_egress', '1.1.1.1', 443))
    # The identity of the process on PID 1 is the attacker's own executable,
    # not Node/Chromium or an Alice ASR process (separate PID namespace).
    pid1 = Path('/proc/1/cmdline').read_bytes().replace(b'\0', b' ')
    evidence.append({'name': 'separate_pid_namespace',
                     'blocked': b'h01_host' not in pid1 and b'browser_fixture' not in pid1,
                     'method': 'container_pid_namespace'})
    failed = [row['name'] for row in evidence if not row['blocked']]
    print(json.dumps({'passed': not failed, 'failed': failed, 'checks': evidence}, sort_keys=True))
    return 0 if not failed else 1


if __name__ == '__main__':
    raise SystemExit(main())
