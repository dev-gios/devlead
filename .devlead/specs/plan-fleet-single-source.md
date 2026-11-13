# Fleet Single-Source Enrollment Reporting Specification

## Purpose

Enrollment is decided by two independent stores: the fleet list (`~/.devlead/autonomous-repos`, WHERE to look) and the repo envelope (`.devlead/envelope.yml`, WHETHER it may work). This spec fixes REPORTING and DISCOVERABILITY only — a repo listed without an envelope (broken, can never run) must read distinctly from a repo deliberately turned off (`enabled: false`), and both halves must be visible and actionable from one config screen. Authority stays split by design; nothing here merges the two stores.

## Scope

### In Scope
- `sweep.sh` `_sweep_repo` Gate 1 (no envelope) and Gate 2 (`enabled: false`) digest `STATUS:` line wording.
- New unified fleet-enrollment screen in `config.sh` showing both halves (fleet-list membership + envelope check/enabled state) with a one-line explanation of what each grants, and actions on both. `_machine_enrollment` folds into this screen — a single entry point, not a third book.
- Test coverage for all three shapes (listed+enabled, listed+disabled, listed+no-envelope), wired into `Makefile`; `shellcheck -S warning` clean.
- Doc sync: `.claude/commands/sweep-execute.md` STATUS strings kept consistent with actual `sweep.sh` output.

### Out of Scope
- Renaming `envelope.sh check`'s `ENROLLED:`/`ENABLED:` KEY:value contract.
- Merging the fleet list and envelope stores, or any pruning/auto-editing of the fleet list.
- Changing sweep gate LOGIC or which repos get skipped. Text and UI only.

## Hard Constraints

These MUST hold regardless of implementation approach; any scenario violating one of these fails review.

- **C1 — §A1, no auto-editing the fleet list**: `sweep.sh` MUST NOT write to `~/.devlead/autonomous-repos` under any code path introduced or touched by this change.
- **C2 — §A3, TTY gate intact**: any new or modified `config.sh` screen MUST stay behind the existing TTY gate and MUST remain unreachable from autonomous/non-interactive paths.
- **C3 — fd-4 tokens frozen**: the outcomes lines on file descriptor 4 (`no medible — not-enrolled.` and `no medible — not-enabled.`) MUST NOT change. `test/smoke-outcomes.sh` asserts these verbatim and is Makefile-wired; it MUST keep passing unmodified. New framing goes into the digest `STATUS:` line only, never into the fd-4 tokens.
- **C4 — no hardcoded envelope field names in config.sh**: any new screen MUST read envelope state exclusively via `envelope.sh check`/`envelope.sh schema`, never by re-parsing `envelope.yml` or hardcoding its field list, per `config.sh`'s existing header convention.
- **C5 — `DEVLEAD_NO_GUM=1` preserved in pty tests**: new or modified `test/unit-config-menu.sh` scenarios exercising the new screen MUST continue to drive it through a real pty (`script -qec`) with `DEVLEAD_NO_GUM=1`, matching the suite's existing convention.

## Requirements

### REQ-1: Broken case names the exact fix command
When a repo is in the fleet list but has no `envelope.yml` (Gate 1), the `sweep.sh` digest `STATUS:` line MUST name the exact remedy command. The fd-4 outcomes token stays frozen per C3.

#### Scenario: no-envelope digest line is actionable
- GIVEN a repo listed in `~/.devlead/autonomous-repos` with no `.devlead/envelope.yml`
- WHEN `sweep.sh` runs the digest for that repo
- THEN the digest `STATUS:` line names the exact command to fix it (e.g. `envelope.sh init`)
- AND the fd-4 outcomes line for that repo is unchanged: `- $repo_path: no medible — not-enrolled.`

### REQ-2: Deliberate-off case reads sober, no action requested
When a repo has an envelope with `enabled: false` (Gate 2), the `sweep.sh` digest `STATUS:` line MUST read as a deliberate, no-action-needed state — distinguishable in tone from REQ-1's broken case. The fd-4 outcomes token stays frozen per C3.

#### Scenario: disabled digest line requests no action
- GIVEN a repo with `.devlead/envelope.yml` present and `enabled: false`
- WHEN `sweep.sh` runs the digest for that repo
- THEN the digest `STATUS:` line reads as a deliberate off-switch, naming no fix command
- AND the fd-4 outcomes line for that repo is unchanged: `- $repo_path: no medible — not-enabled.`

### REQ-3: Unified fleet-enrollment screen in config.sh
`config.sh` MUST expose one screen showing both enrollment halves together: fleet-list membership and envelope check/enabled state, each with a one-line explanation of what it grants, with actions available on both halves from that single screen. This screen MUST replace `_machine_enrollment` as the entry point (not add a third book) and MUST comply with C2 and C4.

#### Scenario: both halves visible together
- GIVEN a repo in any of the three enrollment shapes
- WHEN the user opens the fleet-enrollment screen in `devlead config`
- THEN both fleet-list membership and envelope check/enabled state are shown on the same screen, each with its one-line grant explanation

#### Scenario: actionable from one screen
- GIVEN the fleet-enrollment screen is open
- WHEN the user chooses to act on either half (fleet-list toggle or envelope init/enable/disable)
- THEN the action is available without leaving the screen or navigating to a separate legacy menu

### REQ-4: Three-shape test coverage, Makefile-wired, shellcheck clean
Test coverage MUST exist for all three enrollment shapes (listed+enabled, listed+disabled, listed+no-envelope), covering both the `sweep.sh` digest wording and the `config.sh` unified screen. The suite(s) MUST be wired into `Makefile`'s test target, and `shellcheck -S warning` MUST be clean on all touched or added `.sh` files.

#### Scenario: three shapes covered and wired
- GIVEN `make test` runs
- WHEN the fleet-enrollment suite(s) execute
- THEN all three shapes (listed+enabled, listed+disabled, listed+no-envelope) are asserted
- AND their result is included in the `make test` exit status

#### Scenario: shellcheck clean
- GIVEN the diff of this change
- WHEN `shellcheck -S warning` runs over every touched or added `.sh` file
- THEN it reports zero findings

### REQ-5: Read-only sweep, TTY gate preserved
`sweep.sh` MUST remain strictly read-only with respect to the fleet list, and the TTY gate protecting `config.sh` from autonomous reachability MUST remain intact after this change. (Restates C1/C2 as a directly testable requirement.)

#### Scenario: sweep.sh never writes the fleet list
- GIVEN the full diff of `sweep.sh` for this change
- WHEN searched for any write to `autonomous-repos`
- THEN zero matches are found

#### Scenario: TTY gate still blocks non-interactive invocation
- GIVEN `config.sh` is invoked without a TTY (or from an autonomous path)
- WHEN the fleet-enrollment screen would otherwise be reached
- THEN the existing TTY gate blocks it, matching `test/unit-config-menu.sh` T1/T6 assertions

### REQ-6: Doc sync — sweep-execute.md matches actual output
`.claude/commands/sweep-execute.md`'s documented `STATUS:` strings MUST match the actual wording `sweep.sh` produces after REQ-1/REQ-2 land.

#### Scenario: doc strings match implementation
- GIVEN the updated `sweep.sh` STATUS wording for Gate 1 and Gate 2
- WHEN `.claude/commands/sweep-execute.md` is compared against actual `sweep.sh` output for both gates
- THEN the documented STATUS strings match verbatim

## Out of Scope
- Renaming the `ENROLLED:`/`ENABLED:` KEY:value contract in `envelope.sh check`.
- Merging the fleet list and envelope stores into one file/abstraction.
- Any pruning or auto-editing of the fleet list by `sweep.sh` or any other automated path.
- Changing which repos get skipped or the underlying gate logic — this spec covers text and UI only.

## Review Workload Forecast

- **Estimated changed lines**: ~280-350 (per proposal Size Estimate), spanning `sweep.sh` wording (~small), the new `config.sh` unified screen (bulk of the change), test additions/updates, `Makefile` wiring, and doc sync.
- **400-line budget risk**: Medium.
- **Chained PRs recommended**: No — proposal assesses single PR as feasible; the config.sh screen and its tests are the bulk but stay within budget if kept digest/screen-only with no cosmetics deferred elsewhere.
- **Decision needed before apply**: No — proposal already resolved scope and approach; no open decision blocks `sdd-tasks`.
