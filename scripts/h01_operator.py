"""H01 disposable Linux Docker lab coordinator and synthetic Alice user.

Reproducible real network/PID/mount boundary tests. NO production services.
Controls Docker only as trusted TEST OPERATOR, never from Hermes container.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import ssl
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

BASE = Path(__file__).resolve().parents[1]
COMPOSE = ['docker', 'compose', '-f', str(BASE / 'deploy/h01/compose.yaml')]
FIXTURE = Path(os.environ['H01_FIXTURE_DIR'])
URL = 'https://127.0.0.1:38443'


def token(name):
    return (FIXTURE / name).read_text().strip()


def docker(*args, check=True, capture=True):
    return subprocess.run([*COMPOSE, *args], check=check, text=True,
                          capture_output=capture, timeout=180)


def query(path, obj=None, role='owner', actor='a', timeout=15):
    ctx = ssl.create_default_context(cafile=str(FIXTURE / 'gateway.pem'))
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
                                         urllib.request.HTTPSHandler(context=ctx))
    headers = {'Authorization': 'Bearer ' + token(role + '_' + actor)}
    method = 'POST' if obj is not None else 'GET'
    data = json.dumps(obj, separators=(',', ':')).encode() if obj is not None else None
    req = urllib.request.Request(URL + path, data=data, method=method, headers=headers)
    try:
        with opener.open(req, timeout=timeout) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read())


def require(name, status, result, wanted):
    if status != wanted:
        raise AssertionError(f'{name}: expected HTTP {wanted}, got {status}: {result}')
    return result


def ready():
    last = 'no response'
    for _ in range(90):
        try:
            status, payload = query('/health')
            last = 'HTTP ' + str(status) + ' ' + str(payload.get('status', ''))[:50]
            if status == 200:
                return
        except OSError as exc:
            last = type(exc).__name__ + ': ' + str(exc)[:100]
        time.sleep(1)
    try:
        check_private_connectivity('readiness-timeout-after-90s')
    except Exception as exc:
        print('H01_DIAG_FAILED', type(exc).__name__, flush=True)
    raise RuntimeError('H01 synthetic Alice gateway did not become ready: ' + last)


def job(actor='a'):
    for _ in range(60):
        try:
            s, out = query('/v1/jobs', {'recipient': 'Fictional delivery'}, actor=actor)
            if s == 200:
                return out['job_id']
        except OSError:
            pass
        time.sleep(.5)
    raise AssertionError('Alice gateway could not create a job on private ASR')


def step(job_id, actor, epoch, action, **kwargs):
    s, out = query('/v1/proposals', {'job_id': job_id,
                                    'proposal': {'action': action, 'epoch': epoch, **kwargs}},
                   role='proposal', actor=actor)
    return require('typed-proposal:' + action, s, out, 200)


def plan_from_empty(job_id, actor='a'):
    step(job_id, actor, 0, 'search', query='keyboard')
    return plan_from_search(job_id, actor)


def plan_from_search(job_id, actor='a'):
    step(job_id, actor, 1, 'read_product', sku='FAKE-ALICE-1')
    step(job_id, actor, 2, 'select_product', sku='FAKE-ALICE-1')
    step(job_id, actor, 3, 'add_to_cart', quantity=2)
    return step(job_id, actor, 4, 'prepare_checkout')


def approve(job_id, actor='a'):
    s, challenge = query('/v1/challenge', {'job_id': job_id}, actor=actor)
    require('challenge', s, challenge, 200)
    digest = hmac.new(bytes.fromhex(token('device_hmac_hex')),
                      json.dumps(challenge, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode(),
                      hashlib.sha256).hexdigest()
    # Negative controls: a forged signature is not a privileged authorization.
    s, out = query('/v1/approve', {'job_id': job_id, 'signature': '0' * 64}, actor=actor)
    require('forged-approval-denied', s, out, 403)
    s, out = query('/v1/approve', {'job_id': job_id, 'signature': digest}, actor=actor)
    require('exact-user-approval', s, out, 200)
    s, out = query('/v1/approve', {'job_id': job_id, 'signature': digest}, actor=actor)
    require('replayed-approval-denied', s, out, 403)


def inspect_dispatch(job_id):
    code = ("import sqlite3; db=sqlite3.connect('/var/lib/h01/state.sqlite3'); "
            "row=db.execute('SELECT state_json FROM jobs WHERE job_id=?',(__import__('sys').argv[1],)).fetchone(); "
            "print(__import__('json').loads(row[0])['state'] if row else 'MISSING')")
    r = docker('exec', '-T', 'asr', '/opt/asr-python/bin/python', '-c', code, job_id, check=False)
    return r.stdout.strip() if r.returncode == 0 else 'UNAVAILABLE'


def check_private_connectivity(label):
    # Disposable operator reads only IPs and exit-code; never reads private
    # tokens or browser data and never grants Hermes Docker access.
    for service, host in (('gateway', 'asr'), ('asr', '127.0.0.1')):
        code = ("import socket,json; h=__import__('sys').argv[1]; "
                "ips=[a[4][0] for a in socket.getaddrinfo(h,8443,type=socket.SOCK_STREAM)]; "
                "results=[]; "
                "\nfor ip in ips:\n"
                " s=socket.socket();s.settimeout(2);results.append([ip,s.connect_ex((ip,8443))]);s.close()\n"
                "print(json.dumps(results))")
        interpreter = '/opt/asr-python/bin/python' if service == 'asr' else 'python'
        report = docker('exec', '-T', service, interpreter, '-c', code, host, check=False)
        print('H01_DIAG_CONNECTIVITY', label, service, host,
              'returncode=' + str(report.returncode),
              (report.stdout or report.stderr)[-320:].strip(), flush=True)


def verify_live_container_policy():
    checks = []
    for service in ('asr', 'gateway'):
        container_id = docker('ps', '-q', service).stdout.strip()
        if not container_id:
            raise AssertionError('required isolated container not running: ' + service)
        raw = subprocess.check_output(['docker', 'inspect', container_id], text=True)
        item = json.loads(raw)[0]
        hc, config = item['HostConfig'], item['Config']
        assert hc['ReadonlyRootfs'] is True, service + ': filesystem writable'
        assert not hc['Privileged'], service + ': privileged container'
        assert not hc.get('PidMode') or hc['PidMode'] != 'host', service + ': shared PID namespace'
        assert hc.get('NetworkMode') != 'host', service + ': host network'
        assert 'ALL' in (hc.get('CapDrop') or []), service + ': capabilities not dropped'
        assert str(config.get('User')) in ('12001:12001', '12002:12002'), service + ': root user'
        mounts = [mount['Destination'] for mount in item.get('Mounts', [])]
        assert '/var/run/docker.sock' not in mounts, service + ': Docker socket mounted'
        nets = tuple(sorted(item['NetworkSettings']['Networks']))
        expected = (('asr_backplane',) if service == 'asr' else
                    ('asr_backplane', 'hermes_front', 'operator_front'))
        # zip() alone silently ignores ADDITIONAL networks, allowing a public
        # network to be attached without failing the isolation verifier.
        assert len(nets) == len(expected), (service, 'unexpected extra network', nets)
        assert nets == tuple(os.environ['H01_COMPOSE_PROJECT'] + '_' + suffix for suffix in expected), (service, nets)
        for name, suffix in zip(nets, expected):
            metadata = json.loads(subprocess.check_output(['docker', 'network', 'inspect', name], text=True))[0]
            wanted_internal = suffix != 'operator_front'
            assert metadata['Internal'] is wanted_internal, (service, name, 'unexpected network egress')
        if service == 'asr':
            published = item['NetworkSettings'].get('Ports') or {}
            assert not any(bindings for bindings in published.values()), 'ASR published on host port'
        else:
            # Network isolation fails if the Alice-facing gateway is accidentally
            # exposed on 0.0.0.0 or a second host address, even though Hermes
            # remains disconnected from the ASR bridge in this Docker fixture.
            published = item['NetworkSettings'].get('Ports') or {}
            assert set(published) == {'8443/tcp'}, (service, 'unexpected published ports', published)
            bindings = published['8443/tcp'] or []
            assert len(bindings) == 1 and bindings[0]['HostIp'] == '127.0.0.1' and bindings[0]['HostPort'] == '38443', (
                service, 'gateway listener not bound exclusively to loopback', bindings)
        checks.append({'service': service, 'user': config.get('User'),
                       'readonly': True, 'cap_drop_all': True, 'separate_pid': True,
                       'networks': list(expected), 'docker_socket': False})
    return checks


def verify_private_runner_external_egress():
    # Actual outbound kernel connect attempts FROM the ASR network namespace.
    # The private bridge intentionally permits gateway + localhost merchant;
    # this checks only forbidden Internet/metadata, not a full egress allowlist.
    code = ("import socket,json; result={}; "
            "targets=[('public_internet','1.1.1.1',443),('metadata_ip','169.254.169.254',80)]; "
            "\nfor name,host,port in targets:\n"
            "  try:\n"
            "    c=socket.create_connection((host,port),timeout=2);c.close();result[name]=False\n"
            "  except OSError:\n"
            "    result[name]=True\n"
            "print(json.dumps(result))")
    out = docker('exec', '-T', 'asr', '/opt/asr-python/bin/python', '-c', code)
    result = json.loads(out.stdout.strip())
    if not result or not all(result.values()):
        raise AssertionError('ASR private Linux network unexpectedly reached external target')
    return {'phase': 'asr-kernel-outbound-policy', 'blocked': result,
            'limitation': 'gateway and other backplane services remain reachable'}


def verify_private_browser_profile_exists():
    # The hostile probe must target an ACTUAL, currently existing private
    # Chromium profile directory, not a guessed nonexistent browser path.
    # Only paths/booleans cross to the disposable operator, never file contents.
    code = ("import glob,json,os,pathlib; "
            "targets=['/run/h01-secrets/backend_coordinator_a',"
            "'/run/h01-secrets/device_hmac_hex','/var/lib/h01/state.sqlite3']; "
            "profiles=[p for p in glob.glob('/tmp/playwright_chromiumdev_profile-*') "
            "if pathlib.Path(p).is_dir()]; "
            "print(json.dumps({'files_present':all(pathlib.Path(p).is_file() for p in targets), "
            "'profiles':profiles}))")
    report = docker('exec', '-T', 'asr', '/opt/asr-python/bin/python', '-c', code)
    observed = json.loads(report.stdout.strip())
    if not observed['files_present'] or len(observed['profiles']) != 1:
        raise AssertionError('trusted ASR cannot attest private secrets/ledger and one live Chromium profile')
    return observed['profiles'][0]


def full_test():
    ready()
    evidence = []
    evidence.append({'phase': 'actual-docker-inspect', 'config': verify_live_container_policy()})
    evidence.append(verify_private_runner_external_egress())
    a = job('a')
    b = job('b')
    # Separate read-only browser job so the attacker still owns the untouched
    # epoch-zero positive-control proposal on job a.
    profile_probe = job('a')
    step(profile_probe, 'a', 0, 'search', query='keyboard')
    private_profile = verify_private_browser_profile_exists()
    # The operator knows the ASR private IP and deliberately hands only the IP
    # to hostile Hermes for a real failed direct-TCP attempt.
    asr_container = docker('ps', '-q', 'asr').stdout.strip()
    ip = subprocess.check_output(['docker', 'inspect', '-f',
        '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}', asr_container], text=True).strip()
    pid = subprocess.check_output(['docker', 'inspect', '-f', '{{.State.Pid}}',
                                   asr_container], text=True).strip()
    if not ip:
        raise RuntimeError('missing real ASR backplane IP: cannot claim isolation')
    attacker = docker('--profile', 'attack', 'run', '--rm', '--no-deps',
                      '-e', 'H01_ASR_BACKPLANE_IP=' + ip,
                      '-e', 'H01_ASR_HOST_PID=' + pid,
                      '-e', 'H01_BROWSER_PROFILE_PATH=' + private_profile,
                      '-e', 'H01_BROWSER_JOB_ID=' + a, 'hostile-hermes')
    output = json.loads(attacker.stdout.strip().splitlines()[-1])
    if not output['passed']:
        raise AssertionError('hostile Hermes attack succeeded: ' + json.dumps(output['failed']))
    evidence.append({'phase': 'hostile-hermes-real-container', 'checks': output['checks'],
                     'failed': output['failed']})
    # Each probe reports its concrete method: real TCP, /proc, mount, UID/caps
    # or HTTP role guard. Distinguish an absent endpoint from a kernel denial.
    print('H01_ATTACK_MATRIX ' + json.dumps(output['checks'], sort_keys=True), flush=True)
    print('H01_PHASE_PASS ' + json.dumps({'phase': 'hostile-hermes-real-container',
                                          'checks': len(output['checks'])}), flush=True)

    # Alice B's valid owner token cannot read/commit Alice A's known job.
    for path in ('/v1/resume', '/v1/challenge', '/v1/commit', '/v1/human-handoff'):
        s, out = query(path, {'job_id': a}, actor='b')
        require('cross-tenant:' + path, s, out, 403)
    result = plan_from_search(a)
    if result['checkout']['amount_minor'] != 4998:
        raise AssertionError('fictional checkout price drift')
    approve(a)
    s, out = query('/v1/commit', {'job_id': a}, actor='a')
    require('approved fictitious commit', s, out, 200)
    if out['status'] != 'confirmed_simulated':
        raise AssertionError('unverified fake order')
    s, out = query('/v1/commit', {'job_id': a}, actor='a')
    require('no repeat commit', s, out, 403)
    evidence.append({'phase': 'alice-trusted-approval-and-once-only',
                     'amount_minor': 4998, 'fictional_receipts_observed': 1,
                     'second_submit_http_status': 403,
                     'independent_durable_merchant_receipt_verified': False})
    print('H01_PHASE_PASS ' + json.dumps(evidence[-1]), flush=True)

    # A real Browser-owned job survives in SQLite but its *prior owner*
    # generation is never implicitly adopted by a replacement container.
    orphan = job('a')
    step(orphan, 'a', 0, 'search', query='keyboard')
    check_private_connectivity('before-ASR-replacement')
    old_container = docker('ps', '-q', 'asr').stdout.strip()
    if not old_container:
        raise AssertionError('no original ASR container to replace')
    # A real hosted ASR rollout replaces its entire per-job container,
    # destroying the browser PID namespace; this is strictly controlled by
    # Alice's trusted operator, not by Hermes. Prevent a false close ACK from
    # the NEW process for the old job even if Docker attests old termination.
    docker('up', '-d', '--force-recreate', '--no-deps', 'asr')
    new_container = docker('ps', '-q', 'asr').stdout.strip()
    if new_container == old_container:
        raise AssertionError('ASR container not replaced; cannot test previous-owner fencing')
    stale = subprocess.run(['docker', 'inspect', old_container],
                           capture_output=True, text=True)
    if stale.returncode == 0 and json.loads(stale.stdout)[0]['State']['Running']:
        raise AssertionError('prior ASR container still running after replacement')
    check_private_connectivity('after-ASR-replacement')
    ready()  # authentic private ASR readiness, not merely container Up.
    for _ in range(30):
        s, out = query('/v1/resume', {'job_id': orphan}, actor='a')
        if s == 200:
            break
        time.sleep(1)
    require('resumed-orphan', s, out, 200)
    s, out = query('/v1/proposals', {'job_id': orphan,
                                     'proposal': {'action': 'search', 'epoch': 1, 'query': 'keyboard'}},
                   role='proposal', actor='a')
    require('orphan-action-denied', s, out, 403)
    s, out = query('/v1/human-handoff', {'job_id': orphan}, actor='a')
    require('unfenced-orphan-handoff-denied', s, out, 403)
    evidence.append({'phase': 'browser-generation-crash-fence', 'prior_browser_reuse': 'denied'})
    print('H01_PHASE_PASS ' + json.dumps(evidence[-1]), flush=True)

    # To test the irreversible dispatch race we use ONLY the fake merchant's
    # deliberate delay. The operator can kill a container; Hermes never can.
    os.environ['H01_FAULT_COMMIT_DELAY'] = '15'
    docker('up', '-d', '--force-recreate', '--no-deps', 'asr')
    ready()
    crash = job('a')
    plan_from_empty(crash)
    approve(crash)
    result = {}

    def submit():
        try:
            result['http'] = query('/v1/commit', {'job_id': crash}, actor='a', timeout=25)
        except Exception as exc:
            result['transport'] = type(exc).__name__

    # A socket stuck beyond its per-operation timeout must not pin the CI
    # operator process indefinitely if this bounded failure assertion fires.
    thread = threading.Thread(target=submit, daemon=True)
    thread.start()
    for _ in range(80):
        if inspect_dispatch(crash) == 'dispatching':
            break
        time.sleep(.15)
    else:
        raise AssertionError('durable dispatching not observed; cannot test crash')
    docker('kill', '-s', 'SIGKILL', 'asr')
    thread.join(timeout=25)
    if thread.is_alive():
        raise AssertionError('fake checkout client still executing after ASR SIGKILL')
    if not result or ('http' in result and result['http'][0] == 200):
        raise AssertionError('fake checkout client did not observe an interrupted dispatch')
    os.environ['H01_FAULT_COMMIT_DELAY'] = '0'
    docker('up', '-d', '--force-recreate', '--no-deps', 'asr')
    ready()
    s, out = query('/v1/resume', {'job_id': crash}, actor='a')
    require('resume-after-kill', s, out, 200)
    if out['status'] != 'unknown':
        raise AssertionError('dispatching not reconciled to UNKNOWN: ' + str(out))
    s, out = query('/v1/commit', {'job_id': crash}, actor='a')
    require('no-uncertain-payment-retry', s, out, 403)
    evidence.append({'phase': 'sigkill-during-fake-dispatch',
                     'recovered_state': 'unknown', 'automatic_retries': 0})
    print(json.dumps({'H01': 'DOCKER_BOUNDARY_FIXTURE_ONLY', 'passed': True,
                      'tests': evidence, 'os_isolation_from_docker_host_admin': 'UNVERIFIED',
                      'hermes_real_plugin_host': 'UNVERIFIED',
                      'real_money': False}, sort_keys=True))


if __name__ == '__main__':
    if len(sys.argv) != 2 or sys.argv[1] != 'e2e':
        raise SystemExit('usage: h01_operator.py e2e')
    full_test()
