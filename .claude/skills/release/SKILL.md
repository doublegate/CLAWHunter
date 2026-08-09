---
name: release
description: Cut a CLAWHunter release — bump every pinned version literal, run the host gate, record the hardware gate, build reproducibly, and tag. Usage: /release 3.4.0
disable-model-invocation: true
---

Release CLAWHunter version `$ARGUMENTS`.

If `$ARGUMENTS` is empty, ask for the target semantic version and stop until answered.
Throughout, `NEW` is that version (e.g. `3.4.0`) and `OLD` is the current one — read `OLD`
from `VERSION=` in `scripts/package-release.sh`, never assume it.

Validate `NEW` against `^[0-9]+\.[0-9]+\.[0-9]+$` before doing anything else, and stop if it
fails. Both downstream contracts are strict about this shape: `release.yml` only triggers on
tags matching `v[0-9]+.[0-9]+.[0-9]+`, and `check.sh`'s unified-version `sed` only recognizes
three-part versions. A `v` prefix, a pre-release suffix, or a two-part version would sail
through the edits and strand the release at the tag.

Publishing is **irreversible**: `.github/workflows/release.yml` refuses to replace an
already-published release, so a wrong tag cannot be fixed by re-tagging. Stop and ask
rather than guess at any step.

## Step 0 — Preconditions

Verify and report each; stop on any failure:

- On `main`, working tree clean, up to date with `origin/main`.
- `shellcheck`, `rg`, `curl`, and `nc` are on PATH. `scripts/check.sh` needs all four; a
  missing `nc` surfaces misleadingly as `FAIL: loopback classifier probe failed`.
- `gh` is on PATH **and authenticated** (`gh auth status`). Several steps below query and
  later publish through it; without this you get `command not found` or an auth prompt
  midway, after edits have already landed.
- **`v$NEW` does not exist anywhere.** Check the remote, not just local refs:
  `git ls-remote --tags origin "refs/tags/v$NEW"` is empty and `gh release view "v$NEW"`
  404s. A tag pushed from another machine will not appear in local `git tag -l`, and you
  would only discover it when the final push is rejected — after the release commit and PR
  already exist.
- **Check whether `v$OLD` was tagged *and* published** — `git ls-remote --tags origin` plus
  `gh release view "v$OLD"`. Three states are possible and they need different answers:
  - *Tagged and released* — normal; proceed.
  - *Untagged* — this repo has shipped a version in code while deliberately deferring its
    tag, so this is a real state, not a mistake. Ask whether to finish that release first
    or supersede it; do not quietly roll it into `NEW`.
  - *Tagged but unreleased* — usually the wreckage of a failed `release.yml` run. Do not
    treat `v$OLD` as shipped: Step 3's `v$OLD..HEAD` range would silently omit everything
    that tag already covers. Report it and ask whether to repair that release or supersede
    it.

  `docs/V<OLD>-RELEASE-CHECKLIST.md` records how far the previous attempt got.
- `scripts/check.sh` passes **before** any edits. A red baseline means the release is
  not the thing to debug.
- **There is something to release.** Summarize the commits since the last release actually
  shipped (see the range rules in Step 3) and say what a user gets from `NEW`. Version
  bumps, CI tweaks, and release paperwork do not count — a version whose only content is
  its own version number burns a number and tells operators to re-flash for nothing. If
  the range is empty or entirely release engineering, report that and ask whether to
  proceed anyway; a deliberate maintenance cut is legitimate, but it should be a decision
  and should say so plainly in the CHANGELOG and release notes.

## Step 1 — Research review

`CONTRIBUTING.md` requires this before every release. Report findings, and stop if any
change is needed that this release does not include:

- Current Hak5 Pager documentation and every firmware changelog since `OLD`.
- The official Hak5 payload repository layout.
- Current OpenClaw protocol and security documentation.

Record anything new in the research doc (see Step 2 for its name).

## Step 2 — Bump every pinned literal

`scripts/check.sh` pins the version in more places than the runtime declarations. Eleven
files are involved and several hold more than one occurrence, so work file by file rather
than counting literals. Miss one and the gate fails. Update all of these, then verify with
`rg -n "$OLD" --glob '!CHANGELOG.md'` returning nothing unexpected.

Runtime declarations — `check.sh` reads these with one regex and permits a single value:

| File | Form |
| --- | --- |
| `lib/common.sh` | `# VERSION: $NEW` and `: "${PAYLOAD_VERSION:=$NEW}"` |
| `payloads/user/reconnaissance/clawhunter/payload.sh` | `readonly PAYLOAD_VERSION="$NEW"` |
| `payloads/recon/access_point/clawhunter/payload.sh` | `readonly PAYLOAD_VERSION="$NEW"` |
| `payloads/alerts/pineapple_client_connected/clawhunter-watchdog/payload.sh` | `readonly PAYLOAD_VERSION="$NEW"` |
| `payloads/user/reconnaissance/clawhunter/harvest.py` | `VERSION = "$NEW"` |
| `scripts/package-release.sh` | `VERSION=$NEW` |

User-facing surfaces — asserted as exact strings, so match them character for character:

| File | Exact string |
| --- | --- |
| `README.md` | `version-$NEW-green` (badge) |
| `CHANGELOG.md` | `## [v$NEW] - <ISO date>` at line start |
| `scripts/install-pager.sh` | `CLAWHunter v$NEW installed` |
| `docs/architecture.dot` | `CLAWHunter v$NEW Architecture` |

`scripts/check.sh` itself — it hard-codes the expected value so an accidental *unified*
downgrade still fails. Update in the same commit:

- The `[ "$versions" = "$NEW" ]` assertion.
- The `grep -q` lines for the badge, CHANGELOG heading (**including the date**), installer,
  and `architecture.dot`.
- Every `clawhunter-v$NEW-pager.tar.gz` and `unpacked/clawhunter-v$NEW` path.

Also regenerate `docs/architecture.svg` and `images/architecture.png` from the edited
`docs/architecture.dot` if the rendered version string is visible in them.

### Versioned document filenames

`docs/V<major>.<minor>-RESEARCH.md`, `-RELEASE-NOTES.md`, and `-RELEASE-CHECKLIST.md` carry
the version in their **names**, and `check.sh` asserts the research and notes files are
present in the release archive.

**These accumulate — never rename or delete an existing set.** `docs/` already holds both
`V3-RESEARCH.md` and `V3.3-RESEARCH.md`, which is the precedent: each line keeps its own
record. A release checklist in particular is evidence of what was verified for a version
that operators may still be running, and `git mv`-ing it away rewrites that history.

The three kinds are not on the same clock:

- **Release notes and the release checklist are per release.** Every minor or major bump
  adds a new `V<new major>.<new minor>-RELEASE-NOTES.md` and `-RELEASE-CHECKLIST.md`
  alongside the existing ones. Then repoint `.github/workflows/release.yml`'s
  `--notes-file` — miss this and the new tag publishes the previous version's notes — and
  the archive-content `grep -q` in `scripts/check.sh` that names the notes file.
- **The research record is per research, not per release.** `CONTRIBUTING.md` requires
  updating it "when a change depends on new Hak5/OpenClaw behavior", so Step 1 decides
  this, not the version number. If Step 1 turned up nothing new, the existing
  `V<major>.<minor>-RESEARCH.md` remains the authoritative record: leave it in place, leave
  `check.sh`'s research `grep -q` pointing at it, and say in your report that no new
  research doc was warranted. Only genuinely new findings justify a new file — and then
  repoint that grep too. A research doc created just to match a version number is a stub
  that makes the record look richer than it is.
- **Patch bumps** reuse whatever already exists — the docs track the minor line, not the
  patch. Update contents; invent no `V3.3.1-` files.

So after a minor bump with no new research, `check.sh`'s two archive assertions legitimately
name different versions: the notes at `NEW`, the research still at `OLD`. That asymmetry is
correct, not drift. Leave `CHANGELOG.md`'s older entries pointing at the docs they shipped
with.

`scripts/package-release.sh` copies all of `docs/`, so the whole accumulated set ships in
every archive. That is intended: an operator who extracts the tarball can read the history
without a checkout.

## Step 3 — CHANGELOG

Add a `## [v$NEW] - <today, ISO>` entry with user-visible Added / Changed / Fixed sections.
The date must match the `grep -q` line you wrote into `check.sh`.

Derive the entry from `git log v$OLD..HEAD` when `v$OLD` exists. When it does not — see
Step 0 — fall back to the newest tag that does (`git describe --tags --abbrev=0`) and say
in your report which range you actually summarized, so nobody assumes the diff is against
`OLD`. Never invent the range silently.

## Step 4 — Host gate

Run `scripts/check.sh` and paste the real output. It must end with
`All CLAWHunter checks passed.` Do not proceed on a failure, and do not weaken an assertion
to make it pass — a failing invariant is the finding.

The only gate edits this step permits are the `NEW`-value updates from Step 2. Everything
else is off limits *here specifically*, even where it would be reasonable work on an
ordinary day. `AGENTS.md` notes that some assertions are textual proxies — the
`checkpoint_mark` call-site count, for one — so a legitimate refactor can trip the gate
without breaking the contract underneath, and re-pointing the assertion is a fair fix in
normal development. Mid-release it is not, because you cannot tell a harmless refactor from
a harmful one by looking at the assertion that just failed, and the cost of being wrong is
a published, unreplaceable tag. Report it, name the likely cause, and let the operator
decide. A gate that goes red while cutting a version is information, not an obstacle.

Note that several assertions are bare `[ ]` tests under `set -e`: they abort with **no
message at all**, so the gate simply stops mid-run and the tail looks like a truncated
pass. Always check the exit code rather than reading the last line.

## Step 5 — Hardware gate

Ask the user to run the physical Pager checks listed in `README.md` and report the firmware
version used, **or** to state explicitly that hardware testing was not performed. Record the
answer verbatim in the release notes and the PR body. Never infer or fabricate this.

## Step 6 — Build and verify

```bash
rm -rf dist && scripts/package-release.sh dist
```

Then verify as an operator would, and report each result. Both manifests store **bare
basenames**, so every `-c` must run from the directory holding the files it names —
`sha256sum -c dist/...sha256` from the repo root reports `No such file or directory` and a
`FAILED open or read`, which looks like corruption rather than a wrong working directory.
Use a subshell so the `cd` does not leak, exactly as `check.sh` does:

```bash
( cd dist && sha256sum -c "clawhunter-v$NEW-pager.tar.gz.sha256" )
( cd dist && mkdir -p unpacked && tar -xzf "clawhunter-v$NEW-pager.tar.gz" -C unpacked \
  && cd "unpacked/clawhunter-v$NEW" && sha256sum -c SHA256SUMS )
```

- Confirm the embedded `common.sh` beside each of the three payloads is byte-identical to
  `lib/common.sh` (`cmp`, one per payload directory).

`dist/` is gitignored; CI rebuilds from the tag, so this local build is verification only
and is never uploaded.

## Step 7 — Pre-tag review

Report, and stop if anything is off:

- `git diff --check` clean.
- `git status` shows no archive, checksum, loot, log, or `__pycache__` staged.
- The `CONTRIBUTING.md` PR checklist is satisfied, including the firmware statement.

## Step 8 — Commit, PR, tag

Every numbered action below is a separate stop. Ask, wait for an answer, do that one thing,
report the result — then ask about the next. Do not batch two of them into one question, and
do not treat approval of one as approval of the next: each step widens who can see the
release, and the last one cannot be undone.

Local work (reversible) needs no gate:

1. Branch `release/v$NEW` and commit as `feat: release v$NEW`.

Each of these is outward-facing. Confirm separately before each:

2. **Push** the branch to `origin`.
3. **Open the PR**, with a body carrying the gate result and the Step 5 firmware statement.
4. After review and merge, update local `main` and re-run `scripts/check.sh` on the merge
   commit — the merge may not be what either parent was.
5. **Create** the annotated tag on the merge commit: `git tag -a "v$NEW" -m "CLAWHunter v$NEW"`.
   Local only, still recoverable with `git tag -d`.
6. **Push the tag** — `git push origin "v$NEW"`. This is the irreversible one. State plainly
   that it will publish, and get an unambiguous yes.

Pushing the tag triggers `release.yml`, which rebuilds from the tag, re-runs the gate,
asserts the tag equals `package-release.sh`'s `VERSION`, and publishes the archive and
checksum. Watch the run and report its result. If it fails after publishing, the version
is burned — cut the next patch version rather than trying to replace the release.
