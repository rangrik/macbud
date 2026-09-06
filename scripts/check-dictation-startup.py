#!/usr/bin/env python3
"""Regression check for the audio-thread crash at dictation startup.

Requires the installed MacBud app, build/mbctl, Microphone permission, and an
installed speech model. Briefly records and cancels; never delivers text.
"""
import json
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
CONTROL = ROOT / 'build/mbctl'


def command(value):
    subprocess.run([str(CONTROL), value], check=True)


def running():
    return subprocess.run(['pgrep', '-x', 'MacBud'], stdout=subprocess.DEVNULL).returncode == 0


def read_state(snapshot):
    snapshot.unlink(missing_ok=True)
    command(f'dump?path={snapshot}')
    for _ in range(10):
        time.sleep(.05)
        if snapshot.exists():
            try:
                return json.loads(snapshot.read_text())
            except json.JSONDecodeError:
                pass
    return None


def check():
    subprocess.run(['pkill', '-x', 'MacBud'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(['open', '-n', '--env', 'MACBUD_AUTOMATION=1', '/Applications/MacBud.app'], check=True)
    with tempfile.TemporaryDirectory(prefix='macbud-startup-check-') as directory:
        snapshot = Path(directory) / 'state.json'
        try:
            ready_deadline = time.monotonic() + 15
            while read_state(snapshot) is None:
                if time.monotonic() >= ready_deadline:
                    raise RuntimeError('MacBud did not become ready for the startup check')
            command('toast?title=Startup%20check')
            command('dictate')
            recording_since = None
            began = False
            deadline = time.monotonic() + 40
            while time.monotonic() < deadline:
                time.sleep(.5)
                if not running():
                    raise RuntimeError('MacBud exited after starting dictation')
                state = read_state(snapshot)
                if state is None:
                    continue
                phase = state.get('dictation', {}).get('phase', '')
                if phase.startswith('preparing') or phase == 'recording':
                    began = True
                if began and (phase == 'idle' or state.get('phase') != 'dictation'):
                    raise RuntimeError('The dictation notch disappeared and cancelled recording')
                if phase.startswith('failed'):
                    raise RuntimeError(f'Dictation failed: {phase}')
                if phase == 'recording':
                    if state.get('phase') != 'dictation' or state.get('panelVisible') is False:
                        raise RuntimeError('The dictation notch disappeared while recording')
                    if state.get('panelKey') is True:
                        raise RuntimeError('Dictation stole keyboard focus from the target app')
                    recording_since = recording_since or time.monotonic()
                    if time.monotonic() - recording_since >= 3:
                        print('PASS: real microphone recording stayed visible for 3 seconds; cancelling.', flush=True)
                        return
                else:
                    recording_since = None
            raise RuntimeError('Dictation did not begin recording within 40 seconds')
        finally:
            if running():
                command('dictate-cancel')


if __name__ == '__main__':
    try:
        check()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        raise SystemExit(f'FAIL: {error}')
