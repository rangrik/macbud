#!/bin/bash
set -euo pipefail

app="${1:?Usage: install-release.sh /path/to/MacBud.app}"
destination=/Applications/MacBud.app
codesign --verify --deep --strict "$app"
staging=$(mktemp -d /Applications/.macbud-install.XXXXXX)
replaced=0
had_previous=0

cleanup() {
    result=$?
    if (( result != 0 && replaced == 1 )); then
        pkill -x MacBud 2>/dev/null || true
        rm -rf "$destination"
        if (( had_previous == 1 )); then
            mv "$staging/previous.app" "$destination"
            env -u MACBUD_AUTOMATION open -n "$destination" || true
        fi
    fi
    rm -rf "$staging"
    exit "$result"
}
trap cleanup EXIT

ditto "$app" "$staging/MacBud.app"
codesign --verify --deep --strict "$staging/MacBud.app"
pkill -x MacBud 2>/dev/null || true
for attempt in {1..20}; do
    if ! pgrep -x MacBud >/dev/null; then break; fi
    sleep 0.1
done
if pgrep -x MacBud >/dev/null; then
    printf 'MacBud is still running; installation stopped.\n' >&2
    exit 1
fi
if [[ -e "$destination" ]]; then
    mv "$destination" "$staging/previous.app"
    had_previous=1
fi
replaced=1
mv "$staging/MacBud.app" "$destination"
codesign --verify --deep --strict "$destination"
env -u MACBUD_AUTOMATION open -n "$destination"
sleep 2
pgrep -f '^/Applications/MacBud.app/Contents/MacOS/MacBud($| )' >/dev/null
printf 'Installed and launched %s (Release).\n' "$destination"
