# Session Registry Expiry Specification

## Purpose

`.devlead/scripts/devlead-active.sh` tracks repos with DevLead active via `~/.devlead/active-repos`. This spec adds TTL-based auto-expiry: stale entries become INERT without being deleted. `off` (`/cerremos`) stays the only explicit-removal path; TTL is a safety net, not a replacement.

## Requirements

### REQ-1: Timestamped entry format
Each entry MUST be `path<TAB>epoch` (`date -u +%s`), tab-delimited, one line per path.

#### Scenario: on writes timestamped entry
- GIVEN active-repos is empty or missing
- WHEN `on` runs for `/repo/a`
- THEN the file contains `/repo/a<TAB>{epoch}` with the current UTC epoch

### REQ-2: In-place refresh, one entry per path
`on` MUST remove any existing line (timestamped or legacy bare) whose path field matches the current root, then append a fresh entry. Exactly one entry per path MUST exist after `on`.

#### Scenario: refresh replaces stale entry
- GIVEN `/repo/a<TAB>{old_epoch}` exists
- WHEN `on` runs again for `/repo/a`
- THEN exactly one `/repo/a` line remains, with a newer epoch

#### Scenario: legacy bare line absorbed
- GIVEN a legacy bare line `/repo/a` (no timestamp) exists
- WHEN `on` runs for `/repo/a`
- THEN the bare line is replaced by `/repo/a<TAB>{epoch}`, no duplicate remains

### REQ-3: check never mutates the file
`check` MUST only read and return an exit status; it MUST NOT delete, rewrite, or reorder any line.

#### Scenario: expired line stays present
- GIVEN `/repo/a<TAB>{epoch}` older than TTL
- WHEN `check` runs for `/repo/a`
- THEN exit code is 1 AND the line is unchanged in the file

### REQ-4: Fail-closed freshness evaluation
`check` MUST exit 0 only when `0 <= age < TTL*3600`. It MUST exit 1 for: missing file, path absent, missing/empty/non-numeric timestamp, timestamp in the future, or `age >= TTL*3600`.

#### Scenario: fresh entry active
- GIVEN age is `0 <= age < TTL*3600`
- WHEN check runs
- THEN exit 0

#### Scenario table — all inert (exit 1)
| Condition | Fixture |
|---|---|
| Missing file | `~/.devlead/active-repos` absent |
| Absent path | file exists, no line for the queried path |
| Legacy bare line | `/repo/a` with no timestamp field |
| Corrupt timestamp | `/repo/a<TAB>notanumber` |
| Future timestamp | `/repo/a<TAB>{epoch}` where epoch > now |
| Expired | `age >= TTL*3600` |

No migration is performed for legacy bare lines — they are inert from the first `check` after this change ships.

### REQ-5: Pure-bash field parsing
`check` MUST parse via a `while IFS=$'\t' read -r p ts` loop (no `awk -v`, no `grep -x`), matching on the path field only, so legacy bare lines remain matchable (`p`=whole line, `ts`=empty).

`on` and `off` MUST rewrite the file via field-based tab-delimited matching that preserves every non-matching (foreign) line byte-for-byte — no `awk -v` (its `-v` argument does backslash processing that can mangle content), no `grep -x` whole-line matching (whole-line comparison cannot distinguish the path field from a trailing timestamp). The `IFS= read -r _line` + `${_line%%$'\t'*}` pattern (read the whole line, compare only its path field against `$_root`, re-emit the original line untouched when it does not match) satisfies this requirement.

#### Scenario: legacy line matches by field
- GIVEN a bare line `/repo/a`
- WHEN `off` runs for `/repo/a`
- THEN the path-field comparison treats the whole bare line as the path field, matches it against `$_root`, and the line is dropped from the rewrite

#### Scenario: foreign line preserved byte-for-byte
- GIVEN a foreign line with content the shell could otherwise reinterpret (e.g. an extra tab-delimited field, or a value with a backslash sequence)
- WHEN `on` or `off` rewrites the file for a different path
- THEN the foreign line reappears in the output with identical bytes, unchanged

### REQ-6: Configurable TTL with pinned default
`DEVLEAD_SESSION_TTL_HOURS` MUST override the TTL. An internal `_TTL_DEFAULT_HOURS=16` constant MUST exist, extractable by a test that fails if the literal changes.

#### Scenario: default and override
- GIVEN `DEVLEAD_SESSION_TTL_HOURS` unset → TTL is 16h
- GIVEN `DEVLEAD_SESSION_TTL_HOURS=4` and entry aged 5h → check exits 1

### REQ-7: TTL validation, fail-safe (never fail-open)
TTL MUST be validated against `^[1-9][0-9]*$` (mirrors `envelope.sh`'s `DEVLEAD_GH_TIMEOUT_SECS`). On invalid value, `check` MUST print one stderr line naming the offered and fallback (default) values, then use `_TTL_DEFAULT_HOURS`. Invalid TTL MUST NOT disable or bypass the gate.

#### Scenario: invalid TTL falls back
- GIVEN `DEVLEAD_SESSION_TTL_HOURS=abc` (or `0`, or negative)
- WHEN check runs
- THEN stderr names "abc" as offered and 16 as used, AND evaluation proceeds with TTL=16

### REQ-8: Silent, exit-code-only check contract
`check` MUST NOT write to stdout. The only external contract is the exit code, preserving compatibility with `post-edit.sh` and `gate-check.sh` (both discard stderr, branch on exit status only).

#### Scenario: no stdout under any state
- GIVEN any valid or invalid entry state
- WHEN check runs
- THEN stdout is empty

### REQ-9: off removes explicitly, field-based
`off` MUST remove every line (timestamped or legacy bare) whose path field matches the current root, using field matching instead of whole-line matching. Semantics for callers are unchanged: `off` always removes regardless of TTL state.

#### Scenario: off removes both formats
- GIVEN `/repo/a<TAB>{epoch}` OR a bare `/repo/a` line
- WHEN `off` runs for `/repo/a`
- THEN no entry for `/repo/a` remains in the file

### REQ-10: No autonomous-repos coupling
The implementation MUST NOT read or write any `autonomous-repos` file, and MUST NOT introduce a shared registry abstraction linking the two files.

#### Scenario: zero cross-references
- GIVEN the full diff of `devlead-active.sh` and its tests
- WHEN searched for "autonomous-repos"
- THEN zero matches are found

### REQ-11: Test coverage and lint
`test/unit-devlead-active.sh` MUST cover: fresh (active), expired (inert, line retained), missing timestamp (inert), future timestamp (inert), invalid TTL (fallback + warning), and the pinned default. `test/unit-gate-check.sh:activate_devlead()` MUST write the new `path<TAB>epoch` format. The new suite MUST be wired into the Makefile test target. `shellcheck` MUST be clean on `devlead-active.sh` and the new test file.

#### Scenario: default-pin test fails on drift
- GIVEN `_TTL_DEFAULT_HOURS=16` in the script
- WHEN the test extracts the literal and asserts `== 16`
- THEN changing the literal to any other value fails the test

#### Scenario: Makefile wiring
- GIVEN `make test` (or equivalent target)
- WHEN the full suite runs
- THEN `test/unit-devlead-active.sh` executes and its result is included

## Out of Scope
- `autonomous-repos` file — zero references, stays that way.
- Migration of the 5 existing legacy bare-path lines — inert on first `check`, no transform.
- Renaming `devlead-active.sh` or its registry file.
