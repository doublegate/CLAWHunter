#!/bin/bash
set -euo pipefail

# Build the exact Pager artifact attached to the GitHub release. This is a host
# tool (GNU tar is required), not a runtime dependency installed on the Pager.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# The optional output directory supports CI/temp builds without polluting the
# repository. VERSION and ARCHIVE are intentionally explicit release contracts.
OUTPUT_DIR=${1:-"$ROOT/dist"}
VERSION=3.4.0
ARCHIVE="clawhunter-v${VERSION}-pager.tar.gz"
STAGE=$(mktemp -d /tmp/clawhunter-package-XXXXXX)
# Only the private stage is removed; caller-selected OUTPUT_DIR is preserved.
trap 'rm -rf "$STAGE"' EXIT

# Stage runtime, installer, legal, and operator documentation files. CI,
# development fixtures, and repository metadata do not consume Pager storage,
# while the docs/images directories keep every relative README link usable from
# an extracted release rather than only from a GitHub repository checkout.
PACKAGE_ROOT="$STAGE/clawhunter-v${VERSION}"
mkdir -p "$PACKAGE_ROOT"
cp -R "$ROOT/lib" "$ROOT/payloads" "$ROOT/docs" "$ROOT/images" "$PACKAGE_ROOT/"
# Ship only the device-local installer. Host quality/packaging scripts have no
# runtime value and would unnecessarily increase the payload bundle surface.
mkdir -p "$PACKAGE_ROOT/scripts"
cp "$ROOT/scripts/install-pager.sh" "$PACKAGE_ROOT/scripts/"
cp "$ROOT/README.md" "$ROOT/CHANGELOG.md" "$ROOT/CONTRIBUTING.md" \
    "$ROOT/LICENSE" "$PACKAGE_ROOT/"

# Portal payloads must contain all resources they execute. Embed the canonical
# library rather than maintaining three divergent checked-in copies.
for payload_dir in \
    "$PACKAGE_ROOT/payloads/user/reconnaissance/clawhunter" \
    "$PACKAGE_ROOT/payloads/recon/access_point/clawhunter" \
    "$PACKAGE_ROOT/payloads/alerts/pineapple_client_connected/clawhunter-watchdog"; do
    cp "$PACKAGE_ROOT/lib/common.sh" "$payload_dir/common.sh"
done

# The internal manifest verifies every unpacked file. Paths are relative to the
# package root so the manifest remains valid regardless of transfer location.
(
    cd "$PACKAGE_ROOT"
    # NUL delimiters make manifest generation safe for any legal file name.
    # LC_ALL=C pins byte-value collation. `sort` otherwise honours the builder's
    # LC_COLLATE, so an en_US.UTF-8 host orders ./docs/architecture.dot before
    # ./docs/V3-RESEARCH.md while a C-locale host (every CI runner) does the
    # reverse. That reorders SHA256SUMS, changes the archive bytes, and breaks
    # independent rebuild verification of the published checksum -- while every
    # per-file hash still verifies, so nothing else reports a problem.
    find . -type f ! -name SHA256SUMS -print0 \
        | LC_ALL=C sort -z \
        | xargs -0 sha256sum > SHA256SUMS
)

mkdir -p "$OUTPUT_DIR"
# Normalize order, time, ownership, and gzip metadata for reproducible output.
# File modes remain meaningful so payloads and the installer stay executable.
tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
    -C "$STAGE" -cf - "clawhunter-v${VERSION}" \
    | gzip -n > "$OUTPUT_DIR/$ARCHIVE"
# The adjacent checksum lets operators verify the download before extraction.
(
    cd "$OUTPUT_DIR"
    sha256sum "$ARCHIVE" > "${ARCHIVE}.sha256"
)
printf '%s\n' "$OUTPUT_DIR/$ARCHIVE"
