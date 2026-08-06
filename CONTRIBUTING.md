# Contributing to CLAWHunter

CLAWHunter targets the Hak5 WiFi Pineapple Pager and an OpenWrt/BusyBox userland. Changes must preserve the official Payload Library layout and the shared-library architecture.

Use the project only for authorized security testing.

## Required checks

Run:

```bash
scripts/check.sh
```

The gate covers Bash syntax, ShellCheck warnings, Python byte-compilation and tests, classifier fixtures, JSON output, version unity, and deterministic release packaging. Report the Pager firmware version and whether physical hardware testing was performed in the pull request.

## Layout

```text
payloads/user/reconnaissance/clawhunter/
payloads/recon/access_point/clawhunter/
payloads/alerts/pineapple_client_connected/clawhunter-watchdog/
lib/common.sh
```

Cross-cutting behavior belongs in `lib/common.sh`. Release packages also embed a byte-identical `common.sh` beside each payload so Portal-installed and suite-installed layouts behave the same.

## Architecture Contracts

These behaviors are load-bearing and require regression coverage when changed:

1. All three entry points source one canonical shared library in the repository.
2. Release packaging embeds that exact library beside each Portal payload.
3. mDNS is an unauthenticated hint source and never creates a confirmed finding by itself.
4. `CONFIRMED` requires OpenClaw-specific evidence, not a generic status code or protocol.
5. IPv6 link-local neighbors are logged separately and never enter IPv4 sorting/scanning.
6. Sequential and parallel scans append checkpoints only after every selected port completes.
7. Parallel workers communicate through private result records; only the parent mutates UI, hardware, logs, checkpoints, and result arrays.
8. Harvest execution has one global deadline and returns partial evidence instead of hanging.
9. The client-connected alert targets only the event's exact MAC/IP and stays non-blocking/audio-silent.
10. Recon handles hidden-SSID context, uses the official encryption values, and pins the selected BSSID on the 2.4 GHz client interface.
11. `RINGTONE` and `VIBRATE` receive a filename or valid RTTTL string; numeric millisecond vibration arguments are not a Pager command contract.

## Compatibility

- Keep shell behavior compatible with the Pager's Bash and BusyBox utilities.
- Do not use PCRE-only grep, GNU-only runtime utilities, or Python dependencies outside the standard library.
- Install large optional packages to eMMC with `opkg install -d mmc`.
- Put explicit timeouts on every network operation.
- Treat mDNS TXT data as a hint, not authoritative proof.
- Keep IPv6 addresses out of IPv4 dot-field sorting and scanning.
- Make sequential and parallel checkpoint behavior identical.
- Never interpolate unvalidated network input into a shell command.

## Commenting Standard

Comments are required where code carries a compatibility, security, concurrency, or device-specific contract. A reviewer should not need to reconstruct the reason from firmware changelogs or protocol source.

Document:

- function inputs, published globals, return values, and side effects when they are not obvious from the signature;
- why a timeout or size limit has its chosen scope;
- why a Hak5 event/context variable or category path is authoritative;
- evidence weights and the boundary between a hint, candidate, and confirmation;
- shell parent/subprocess ownership of arrays, logs, hardware, and checkpoints;
- security handling for operator input, gateway secrets, temporary files, and tool allowlists;
- BusyBox, firmware, eMMC, or Portal constraints behind a non-obvious implementation;
- release reproducibility and installer layout assumptions.

Do not narrate trivial assignments or restate a command in prose. Keep comments synchronized with behavior; stale protocol comments are bugs.

## Versioning

The version must match in:

- `lib/common.sh`
- all three `payload.sh` files
- `harvest.py`
- release scripts and user-facing documentation

Update `CHANGELOG.md` for every release. `scripts/check.sh` rejects divergent runtime versions.

## Security

Do not add credential collection, authentication bypasses, destructive actions, arbitrary command execution, staged remote code, or out-of-band exfiltration. Gateway credentials must come from protected local configuration or the environment and must never appear in process arguments or logs.

OpenClaw shared gateway credentials provide operator authority. Tests and documentation must preserve that trust-boundary warning.

## Pull Request Checklist

- Run `scripts/check.sh` and include the result.
- State the Pager firmware used for physical testing, or explicitly state that hardware testing was not performed.
- Add fixtures for classifier, parser, checkpoint, or report behavior changed by the patch.
- Update `README.md` for operator-visible workflow, controls, output, dependencies, or troubleshooting changes.
- Update the current research record when a change depends on new Hak5/OpenClaw behavior.
- Add a `CHANGELOG.md` entry with user-visible additions, changes, and fixes.
- Confirm no token, password, target data, generated loot, archive, or Python cache is staged.
- Confirm all runtime version declarations remain identical.

## Release Process

1. Review current Hak5 Pager documentation, every firmware changelog since the prior release, the official payload repository, and current OpenClaw protocol/security documentation.
2. Run the complete host gate.
3. Perform and record the physical Pager checks listed in `README.md` when hardware is available.
4. Build with `scripts/package-release.sh` in a clean output directory.
5. Verify the adjacent archive checksum and the internal `SHA256SUMS` manifest.
6. Review `git diff --check`, repository status, version strings, and release notes.
7. Merge the reviewed release commit, create the annotated semantic-version tag, and attach both archive and checksum to the GitHub release.
