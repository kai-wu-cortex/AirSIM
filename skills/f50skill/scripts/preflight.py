#!/usr/bin/env python3
"""Read-only F50 inventory and local backup integrity verification; never flashes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
from datetime import datetime, timezone


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def artifacts(path):
    path = Path(path).resolve()
    manifest = json.loads(path.read_text())
    if not manifest.get('device_serial') or not manifest.get('firmware') or not manifest.get('files'):
        raise ValueError('manifest needs device_serial, firmware and nonempty files')
    result = []
    for item in manifest['files']:
        if not item.get('role') or not re.fullmatch(r'[0-9a-f]{64}', item.get('sha256', '')):
            raise ValueError('each file needs role and a real lowercase SHA-256')
        if type(item.get('bytes')) is not int or item['bytes'] <= 0:
            raise ValueError('each file needs positive exact bytes')
        candidate = Path(item['path'])
        if not candidate.is_absolute():
            candidate = path.parent / candidate
        ok = candidate.is_file() and candidate.stat().st_size == item['bytes']
        ok = ok and digest(candidate) == item['sha256']
        result.append({'role': item['role'], 'integrity_passed': ok})
    return {'files': result, 'all_passed': all(x['integrity_passed'] for x in result),
            'compatibility_assessed': False, 'flashing_performed': False}


def device(adb, serial):
    if not re.fullmatch(r'[A-Za-z0-9._:-]+', serial):
        raise ValueError('invalid explicit target serial')
    def call(*args):
        proc = subprocess.run([adb, '-s', serial, *args], capture_output=True,
                              text=True, timeout=15, check=True)
        return proc.stdout.strip()
    if call('get-state') != 'device':
        raise ValueError('selected device is not authorized/online')
    def shell(*args):
        return call('shell', ' '.join(shlex.quote(a) for a in args))
    def optional(*args):
        try:
            return shell(*args)
        except subprocess.SubprocessError:
            return None
    props = {key: shell('getprop', key) for key in (
        'ro.product.model', 'ro.product.device', 'ro.build.display.id',
        'ro.build.version.release', 'ro.build.version.sdk', 'ro.boot.slot_suffix',
        'ro.adb.secure', 'sys.usb.state', 'sys.boot_completed',
        'persist.radio.multisim.config', 'persist.vendor.sys.volte.enable')}
    sums = {}
    for name, remote in {
        'wifi_jar': '/apex/com.android.wifi/javalib/service-wifi.jar',
        'telephony_jar': '/system/framework/vendor-telephony-common.jar',
        'netd': '/system/bin/netd',
        'runtime': '/data/local/f50-wifi/runtime.dex',
    }.items():
        value = optional('sha256sum', remote)
        sums[name] = value.split()[0] if value and re.match(r'^[0-9a-f]{64} ', value) else None
    packages = {}
    for package in ('com.airsim.phonecontrol.standalone', 'com.airsim.f50dsds'):
        package_path = optional('pm', 'path', package)
        entry = {'installed': bool(package_path and package_path.startswith('package:'))}
        if entry['installed']:
            apk = package_path.splitlines()[0].removeprefix('package:')
            value = optional('sha256sum', apk)
            entry['sha256'] = value.split()[0] if value and re.match(r'^[0-9a-f]{64} ', value) else None
        packages[package] = entry
    candidate = (props['ro.product.model'] == 'MU3356'
                 and props['ro.build.display.id'] == 'F50ProV1.0.0B28'
                 and props['ro.build.version.sdk'] == '35')
    return {'observed_at': datetime.now(timezone.utc).isoformat(), 'target_serial': serial,
            'usb_devpath': call('get-devpath'), 'properties': props,
            'boot_id': optional('cat', '/proc/sys/kernel/random/boot_id'),
            'uptime': optional('cat', '/proc/uptime'),
            'adb_enabled': optional('settings', 'get', 'global', 'adb_enabled'),
            'default_dialer': optional('cmd', 'telecom', 'get-default-dialer'),
            'dsds_switch': optional('settings', 'get', 'system', 'car_mode_dual_sim_switch'),
            'sha256': sums, 'packages': packages, 'b28_candidate_only': candidate,
            'flashing_approved': False, 'mutations_performed': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    scan = sub.add_parser('device')
    scan.add_argument('--adb', required=True)
    scan.add_argument('--serial', required=True)
    scan.add_argument('--out', type=Path, required=True)
    verify = sub.add_parser('verify-artifacts')
    verify.add_argument('manifest', type=Path)
    args = parser.parse_args()
    try:
        if args.command == 'verify-artifacts':
            result = artifacts(args.manifest)
            print(json.dumps(result, ensure_ascii=False, indent=2))
            return 0 if result['all_passed'] else 1
        # Refuse overwriting an existing report before contacting the device.
        if args.out.exists():
            raise ValueError('output already exists; choose a new report path')
        result = device(args.adb, args.serial)
        fd = os.open(args.out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as stream:
            json.dump(result, stream, ensure_ascii=False, indent=2)
            stream.write('\n')
        print(json.dumps({'report_saved': str(args.out),
                          'b28_candidate_only': result['b28_candidate_only'],
                          'mutations_performed': False}, ensure_ascii=False))
        return 0
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        reason = str(error) if type(error) is ValueError else type(error).__name__
        print('Preflight failed: ' + reason, file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
