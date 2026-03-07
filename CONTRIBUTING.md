# Contributing to CLAWHunter

Contributions are welcome — new payload variants, fingerprinting improvements, compatibility fixes, and documentation.

---

## Environment requirements

- **Hak5 WiFi Pineapple Pager** (or access to one for testing)
- **Bash 5.x** — test syntax with `bash -n <file>`
- **Python 3.6+** — no third-party packages; stdlib only
- **OpenWRT/busybox constraints** — see [Compatibility rules](#compatibility-rules)

---

## Compatibility rules

The Pager runs OpenWRT with a busybox userland. All shell code must work within these constraints:

| ❌ Don't use | ✅ Use instead |
|-------------|--------------|
| `grep -oP` (PCRE) | `awk` for field extraction |
| `shuf` | `awk -v seed=$RANDOM 'BEGIN{srand(seed)}…'` |
| `/dev/tcp` alone | `/dev/tcp` with `nc -w 3` fallback |
| `TEXT_PICKER` | Display instructions; use Recon context vars |
| `pip` / third-party Python | Python3 stdlib only |
| `python3 -c "import X"` where X is not stdlib | Not supported |

---

## Before submitting a pull request

1. **Syntax check all bash:**
   ```bash
   bash -n lib/common.sh
   bash -n payloads/user/clawhunter/payload.sh
   bash -n payloads/recon/clawhunter/payload.sh
   bash -n payloads/alert/clawhunter-watchdog/payload.sh
   ```

2. **Syntax check Python:**
   ```bash
   python3 -m py_compile payloads/user/clawhunter/harvest.py
   ```

3. **Test on actual hardware** if possible. If not, note in the PR that hardware testing hasn't been done — that's fine, but it should be called out.

4. **Update `CHANGELOG.md`** — add an entry under an `[Unreleased]` heading describing what you changed.

5. **Update `README.md`** if you add, remove, or change user-visible behavior (prompts, controls, LED states, output format, etc.).

---

## Payload structure

New user-facing payloads belong in `payloads/user/<name>/payload.sh`. Include the standard Hak5 metadata header:

```bash
# Title: Your Payload Name
# Description: What it does in one sentence.
# Author: Your Name
```

Any shared functions that multiple payloads need should go in `lib/common.sh`, not duplicated across payloads.

---

## Code style

- Every function: comment block with purpose, params, and side effects
- Inline comments: explain *why*, not *what*
- Constants: `UPPER_SNAKE_CASE`; local variables: `lower_snake_case`
- No magic numbers — named constants with a comment explaining the value
- Prefer `local` for all variables inside functions
- All `curl` calls: explicit `--max-time` or `-m` timeout
- All `nc` calls: explicit `-w` timeout

---

## What makes a good PR

- **Focused** — one feature or fix per PR
- **Tested** — at minimum, syntax-checked; hardware-tested if possible
- **Documented** — CHANGELOG entry + README update if user-visible
- **Compatible** — passes the busybox constraints above

---

## Reporting bugs

Open a GitHub issue. Include:
- Pager firmware version
- Which payload variant (`user` / `recon` / `alert`)
- Relevant log snippet from `/root/loot/clawhunter/`
- What you expected vs. what happened
