#!/bin/sh
set -eu

# Device-local installer for an unpacked v3.3.0 release bundle. POSIX sh is
# used intentionally because installation must work before optional Bash/Python
# packages are considered. Pass a destination root to stage/test elsewhere;
# the production default is the Pager's canonical /root/payloads tree.
SOURCE_ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
DEST_ROOT=${1:-/root/payloads}

# Install one entry point plus a local, byte-identical shared library. The local
# copy makes each payload self-contained for Pager Portal while /root/payloads/
# lib/common.sh remains available to suite/development layouts.
install_payload() {
    # Positional arguments are internal, fixed paths from the calls below; they
    # are quoted for whitespace safety even though official categories use none.
    source_dir=$1
    destination=$2
    # mkdir/cp/chmod are BusyBox-compatible and avoid depending on GNU install.
    mkdir -p "$destination"
    cp "$source_dir/payload.sh" "$destination/payload.sh"
    cp "$SOURCE_ROOT/lib/common.sh" "$destination/common.sh"
    chmod 0755 "$destination/payload.sh" "$destination/common.sh"
}

# Keep a canonical suite copy for payloads deployed directly from the repository.
mkdir -p "$DEST_ROOT/lib"
# Overwrite atomically at the file level: a rerun upgrades an existing suite to
# exactly the release bundle's canonical shared implementation.
cp "$SOURCE_ROOT/lib/common.sh" "$DEST_ROOT/lib/common.sh"
chmod 0755 "$DEST_ROOT/lib/common.sh"

# User mode owns harvest.py; Recon and alert modes never require Python.
install_payload \
    "$SOURCE_ROOT/payloads/user/reconnaissance/clawhunter" \
    "$DEST_ROOT/user/reconnaissance/clawhunter"
cp "$SOURCE_ROOT/payloads/user/reconnaissance/clawhunter/harvest.py" \
    "$DEST_ROOT/user/reconnaissance/clawhunter/harvest.py"
# Executable mode supports direct diagnostics while payload.sh still launches
# the engine explicitly with python3.
chmod 0755 "$DEST_ROOT/user/reconnaissance/clawhunter/harvest.py"

install_payload \
    "$SOURCE_ROOT/payloads/recon/access_point/clawhunter" \
    "$DEST_ROOT/recon/access_point/clawhunter"
install_payload \
    "$SOURCE_ROOT/payloads/alerts/pineapple_client_connected/clawhunter-watchdog" \
    "$DEST_ROOT/alerts/pineapple_client_connected/clawhunter-watchdog"

# Print one stable success line for operators and the install-layout gate.
printf 'CLAWHunter v3.3.0 installed under %s\n' "$DEST_ROOT"
