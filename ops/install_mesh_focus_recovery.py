#!/usr/bin/env python3
"""Install the opt-in, per-user Mesh focus recovery LaunchAgent.

No root service. It runs only while focus-recovery.json exists. The app's explicit
Quit removes that record. --remove unloads the service and removes its plist.
This installer does not create recovery intent or start camera/microphone capture.
"""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess

LABEL = 'com.devansh.mesh-monitor.focus-recovery'

def configuration(home):
    executable = home / 'Applications/Mesh Monitor.app/Contents/MacOS/MeshMonitor'
    state = home / 'Library/Application Support/MeshMonitor/focus-recovery.json'
    return {'Label': LABEL, 'ProgramArguments': [str(executable), '--recover-focus-session'],
            'KeepAlive': {'PathState': {str(state): True}}, 'RunAtLoad': False,
            'ThrottleInterval': 10, 'ProcessType': 'Interactive',
            'LimitLoadToSessionType': 'Aqua',
            'EnvironmentVariables': {'PATH': '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'}}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--remove', action='store_true')
    args = parser.parse_args()
    home = Path.home()
    path = home / 'Library/LaunchAgents' / (LABEL + '.plist')
    domain = f'gui/{os.getuid()}'
    if args.remove:
        subprocess.run(['launchctl', 'bootout', domain + '/' + LABEL], check=False, capture_output=True)
        path.unlink(missing_ok=True)
        print('Focus recovery service removed; no running app was instructed to resume.')
        return
    config = configuration(home)
    executable = Path(config['ProgramArguments'][0])
    if not executable.is_file(): raise SystemExit('Install Mesh Monitor first.')
    info = plistlib.loads((executable.parents[1] / 'Info.plist').read_bytes())
    if int(info.get('CFBundleVersion', '0')) < 35: raise SystemExit('Build 35 or newer is required.')
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(config)); path.chmod(0o600)
    existing = subprocess.run(['launchctl', 'print', domain + '/' + LABEL], capture_output=True)
    if existing.returncode == 0:
        raise SystemExit('Recovery service already loaded. Plist updated; unload only during a planned maintenance stop.')
    subprocess.run(['launchctl', 'bootstrap', domain, str(path)], check=True)
    print(path)

if __name__ == '__main__': main()
