#!/usr/bin/env python3
"""Build and install Alice directly, reusing Xcode's existing incremental cache."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time

DEFAULT_REPO = Path(__file__).resolve().parents[1]
BUNDLE = 'com.freixanet.alice'


def run(args, *, cwd=None, log=None):
    if log:
        with log.open('w') as out:
            result = subprocess.run(args, cwd=cwd, stdout=out, stderr=subprocess.STDOUT)
        if result.returncode:
            print('\n'.join(log.read_text(errors='replace').splitlines()[-35:]), file=sys.stderr)
            raise RuntimeError(f'Falló {args[0]}. Registro: {log}')
        return ''
    try:
        return subprocess.check_output(args, cwd=cwd, text=True, stderr=subprocess.STDOUT).strip()
    except subprocess.CalledProcessError as error:
        detail = (error.output or '').strip()
        raise RuntimeError(detail or f'Falló {args[0]} con código {error.returncode}') from error


def device_json(args, target):
    # Apple's supported machine-readable interface, not terminal table parsing.
    run(['xcrun', 'devicectl', *args, '--json-output', str(target)])
    data = json.loads(target.read_text())
    if data.get('info', {}).get('outcome') != 'success':
        raise RuntimeError(f'El dispositivo no completó la operación. Consulta {target}')
    return data['result']


def installed_build(device, folder, label):
    result = device_json(['device', 'info', 'apps', '--device', device,
                          '--bundle-id', BUNDLE], folder / f'{label}.json')
    apps = [a for a in result.get('apps', []) if a.get('bundleIdentifier') == BUNDLE]
    if len(apps) != 1:
        raise RuntimeError('No se pudo confirmar la instalación actual de Alice; no se sustituirá.')
    return int(apps[0]['bundleVersion'])


def source_identity(repo):
    sha = run(['git', 'rev-parse', 'HEAD'], cwd=repo)
    branch = run(['git', 'branch', '--show-current'], cwd=repo)
    dirty = run(['git', 'status', '--porcelain', '--untracked-files=no'], cwd=repo)
    untracked_ios = run(['git', 'ls-files', '--others', '--exclude-standard', 'ios'], cwd=repo)
    # Xcode's generated project and build files are intentionally local artifacts.
    untracked_sources = [p for p in untracked_ios.splitlines()
                         if not p.startswith(('ios/.build/', 'ios/build/', 'ios/Alice.xcodeproj/'))]
    if dirty or untracked_sources:
        raise RuntimeError('Guarda los cambios del proyecto en un commit antes de compilar para instalar.')
    published = run(['git', 'for-each-ref', '--contains', sha, '--format=%(refname)',
                     'refs/remotes'], cwd=repo)
    if not published:
        raise RuntimeError('El commit de origen no figura en una rama remota. Publícalo antes de instalar.')
    return sha, branch


def sanitize_products(cache):
    # Apple QA1940: only generated products, never source, signing settings,
    # quarantine flags, File Provider metadata or the incremental database.
    products = cache / 'Build/Products/Debug-iphoneos'
    if products.exists():
        for attribute in ('com.apple.FinderInfo', 'com.apple.ResourceFork'):
            result = subprocess.run(['/usr/bin/xattr', '-rd', attribute, str(products)],
                                    capture_output=True, text=True)
            if result.returncode and 'No such xattr' not in result.stderr:
                raise RuntimeError(f'No se pudo limpiar {attribute}: {result.stderr.strip()}')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=DEFAULT_REPO,
                        help='Checkout de Alice que contiene los cambios que quieres instalar.')
    parser.add_argument('--device', help='ID o nombre del iPhone; se detecta si solo hay uno.')
    parser.add_argument('--derived-data', type=Path, help='Caché existente; por defecto ios/.build/DeviceData.')
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--check', action='store_true', help='Comprueba origen, iPhone y caché; no compila ni instala.')
    modes.add_argument('--build-only', action='store_true', help='Compila sin contactar el teléfono ni sustituir su app.')
    parser.add_argument('--no-launch', action='store_true', help='Instala sin abrir Alice.')
    opts = parser.parse_args(argv)
    repo = opts.repo.expanduser().resolve()
    if not (repo / 'ios/project.yml').is_file():
        raise RuntimeError(f'No es un proyecto de Alice: {repo}')
    cache = (opts.derived_data or repo / 'ios/.build/DeviceData').expanduser().resolve()
    # Across all checkouts using this runner; OS releases the lock even on a crash.
    lock_path = Path(tempfile.gettempdir()) / f'alice-iphone-{os.getuid()}.lock'
    with lock_path.open('a') as lock:
        os.chmod(lock_path, 0o600)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Ya hay otra compilación o instalación de este flujo en curso.')
        sha, branch = source_identity(repo)
        run(['xcrun', '--find', 'devicectl'])
        runs = repo / 'ios/.build/iphone-installs'
        runs.mkdir(parents=True, exist_ok=True)
        folder = Path(tempfile.mkdtemp(prefix=time.strftime('%Y%m%d-%H%M%S-'), dir=runs))
        device = opts.device
        before = 0
        if opts.build_only:
            # A compilation needs no phone connection. Reuse the last confirmed
            # number, then also account for the local product below. Never use
            # this cached value to authorize an installation.
            for previous in runs.glob('*/result.json'):
                try:
                    saved = json.loads(previous.read_text())
                    before = max(before, int(saved.get('installed_before') or 0),
                                 int(saved.get('installed_after') or 0))
                except (OSError, ValueError, TypeError):
                    continue
        else:
            if not device:
                listing = device_json(['list', 'devices'], folder / 'devices.json')
                devices = [d for d in listing.get('devices', [])
                           if d.get('hardwareProperties', {}).get('deviceType') == 'iPhone'
                           and d.get('connectionProperties', {}).get('pairingState') == 'paired']
                if len(devices) != 1:
                    raise RuntimeError('No hay un único iPhone emparejado. Indícalo con --device.')
                device = devices[0]['identifier']
            before = installed_build(device, folder, 'before')
        evidence = {'repo': str(repo), 'commit': sha, 'branch': branch,
                    'derived_data': str(cache), 'installed_before': before, 'installed_before_is_cached': opts.build_only,
                    'mode': 'check' if opts.check else 'build-only' if opts.build_only else 'install'}
        def save():
            (folder / 'result.json').write_text(json.dumps(evidence, indent=2) + '\n')
        save()
        label = 'Última versión consultada' if opts.build_only else 'Alice instalada'
        print(f'Origen: {branch} · {sha[:12]}\n{label}: {before}\nCaché: {cache}', flush=True)
        if opts.check:
            print(f'Comprobación correcta. Registro: {folder}')
            return
        next_build = before + 1
        app = cache / 'Build/Products/Debug-iphoneos/Alice.app'
        if (app / 'Info.plist').exists():
            local = plistlib.loads((app / 'Info.plist').read_bytes())
            next_build = max(next_build, int(local['CFBundleVersion']) + 1)
        print('Compilando sin abrir Xcode…', flush=True)
        started = time.monotonic()
        # --use-cache avoids unnecessary project regeneration; no clean, archive,
        # simulator, polling watcher, CPU limit or change to compiler optimizations.
        run(['xcodegen', 'generate', '--use-cache', '--cache-path',
             str(repo / 'ios/.build/xcodegen-install-cache.json'), '--spec', 'project.yml'],
            cwd=repo / 'ios', log=folder / 'project.log')
        sanitize_products(cache)
        build_args = ['xcodebuild', '-project', str(repo / 'ios/Alice.xcodeproj'),
             '-scheme', 'Alice', '-configuration', 'Debug',
             '-destination', 'generic/platform=iOS', '-derivedDataPath', str(cache),
             '-allowProvisioningUpdates', '-skipPackageUpdates', f'CURRENT_PROJECT_VERSION={next_build}', 'build']
        try:
            run(build_args, cwd=repo, log=folder / 'build.log')
        except RuntimeError:
            log = folder / 'build.log'
            if not log.exists() or 'resource fork, Finder information, or similar detritus' not in log.read_text(errors='replace'):
                raise
            print('Retirando metadatos de Finder de los productos compilados y repitiendo la firma…', flush=True)
            sanitize_products(cache)
            run(build_args, cwd=repo, log=folder / 'build-after-metadata-repair.log')
        evidence['build_seconds'] = round(time.monotonic() - started, 2)
        evidence['built_version'] = next_build
        if source_identity(repo)[0] != sha:
            raise RuntimeError('El origen cambió durante la compilación. No se instalará.')
        built = plistlib.loads((app / 'Info.plist').read_bytes())
        if built.get('CFBundleIdentifier') != BUNDLE or str(built.get('CFBundleVersion')) != str(next_build):
            raise RuntimeError('El producto compilado no coincide con Alice y su versión esperada.')
        save()
        print(f'Compilación: {evidence["build_seconds"]} s · versión {next_build}', flush=True)
        if opts.build_only:
            print(f'No se instaló. Registro: {folder}')
            return
        # Detect another agent's installation while we were building.
        if installed_build(device, folder, 'preinstall') != before:
            raise RuntimeError('Otro proceso cambió la versión del iPhone. No se sustituirá.')
        print('Instalando directamente en el iPhone…', flush=True)
        started = time.monotonic()
        device_json(['device', 'install', 'app', '--device', device, str(app)], folder / 'install.json')
        evidence['install_seconds'] = round(time.monotonic() - started, 2)
        actual = installed_build(device, folder, 'after')
        evidence['installed_after'] = actual
        save()
        if actual != next_build:
            raise RuntimeError(f'Versión instalada inesperada: {actual}. Se esperaba {next_build}.')
        print(f'Instalación comprobada: {actual} · {evidence["install_seconds"]} s', flush=True)
        if not opts.no_launch:
            try:
                device_json(['device', 'process', 'launch', '--device', device, BUNDLE], folder / 'launch.json')
            except (RuntimeError, subprocess.CalledProcessError) as error:
                print(f'Alice está instalada, pero no se pudo abrir automáticamente: {error}\n'
                      'Desbloquea el iPhone y abre Alice.', file=sys.stderr)
        print(f'Registro: {folder}')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError, OSError, ValueError) as error:
        print(f'Error: {error}', file=sys.stderr)
        sys.exit(1)
