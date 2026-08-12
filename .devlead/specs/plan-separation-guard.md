# Registry Separation Guard — Specification

<!-- Delta spec for SDD change: plan-separation-guard -->
<!-- New capability: registry-separation-guard (no prior spec exists) -->

## Purpose

DevLead has two enablement registries with different authority: `~/.devlead/active-repos`
(session-scoped, ephemeral, grants nothing) and `~/.devlead/autonomous-repos` (durable,
grants unsupervised branches/commits/PRs — Inv 3 authority). This spec defines a static
test suite, `test/unit-registry-separation.sh`, that proves the two registries are never
read across their intended boundary, and locks that invariant before two sibling tasks
(session expiry, `active-repos` → `session-repos` rename) touch the surrounding code.

## New Capabilities

### Requirement: REQ-1 — Forward Violation Detection

The system MUST fail the test suite if any file on the autonomous path — `sweep.sh`,
`sweep-loop.sh`, or any script/prompt file transitively invoked or sourced by them —
contains a real read of the session registry (`active-repos` literal, its future
`session-repos` literal, or the `ACTIVE_FILE` canonical variable name).

#### Scenario: Clean autonomous path passes

- GIVEN the current repo tree (sweep.sh, sweep-loop.sh, and their transitive closure)
- WHEN the guard scans the autonomous path-set
- THEN no session-registry reference is found and this check reports PASS

#### Scenario: Planted forward violation fails

- GIVEN a `/tmp` fixture tree where a file on the autonomous path-set reads `active-repos`
- WHEN the guard scans that fixture tree
- THEN the check reports FAIL for that fixture file

### Requirement: REQ-2 — Reverse Violation Detection

The system MUST fail the test suite if `post-edit.sh`, `gate-check.sh`, or
`devlead-active.sh` uses `autonomous-repos` (literal, or the `REPOS_FILE` canonical
variable name) as an authority source.

#### Scenario: Clean session path passes

- GIVEN the current repo tree (post-edit.sh, gate-check.sh, devlead-active.sh)
- WHEN the guard scans the session path-set
- THEN no autonomous-registry reference is found and this check reports PASS

#### Scenario: Planted reverse violation fails

- GIVEN a `/tmp` fixture tree where a session-path file reads `autonomous-repos` as authority
- WHEN the guard scans that fixture tree
- THEN the check reports FAIL for that fixture file

### Requirement: REQ-3 — File:Line Failure Reporting

On any detected violation, the system MUST report the exact source `FILE:LINE` plus the
trimmed offending source line, in the form `FAIL <file>:<line>: <trimmed source>`.

#### Scenario: Violation output identifies exact location

- GIVEN a fixture file with a planted violation on a known line number
- WHEN the guard detects the violation
- THEN the failure message contains that file's path and that exact line number

### Requirement: REQ-4 — Prose-Mention Exemption

The system MUST NOT fail on comment-only lines (first non-blank character is `#`) that
merely mention the opposing registry or script name in prose, including the real case at
`envelope.sh:221` (a comment referencing "devlead-active.sh" as a design-pattern example).

#### Scenario: envelope.sh:221 does not fail the suite

- GIVEN the current `envelope.sh` file containing its line-221 prose comment
- WHEN the guard scans the autonomous path-set including envelope.sh
- THEN line 221 is excluded from violation detection and the suite does not fail because of it

#### Scenario: Fixture proves the exemption explicitly

- GIVEN a `/tmp` fixture file containing only a comment-only mention of the opposing registry
- WHEN the guard scans that fixture
- THEN no violation is reported for that line

### Requirement: REQ-5 — Manifest-String Exemption

The system MUST NOT fail on real (non-comment) code lines that name a registry-adjacent
script (e.g., `devlead-active.sh`) inside unrelated data such as a symlink/publish manifest
entry, when the line contains no registry-file literal or canonical variable name. This
covers `bootstrap-lib.sh:226`.

#### Scenario: bootstrap-lib.sh:226 does not fail the suite

- GIVEN the current `bootstrap-lib.sh` file containing its line-226 manifest array entry
- WHEN the guard scans the autonomous path-set including bootstrap-lib.sh
- THEN line 226 is excluded because it contains no registry-file literal or canonical variable, and the suite does not fail because of it

#### Scenario: Fixture proves the manifest-string exemption explicitly

- GIVEN a `/tmp` fixture file with a real-code manifest entry naming a registry-adjacent script but no registry literal or variable
- WHEN the guard scans that fixture
- THEN no violation is reported for that line

### Requirement: REQ-6 — Self-Test Fixtures Prove Scanner Correctness

The system MUST include a self-test using synthetic fixtures under a sandboxed `/tmp`
tree covering at minimum four cases: forward violation (fires), reverse violation (fires),
prose mention (silent), and manifest-string mention (silent) — proving the scanner both
detects real violations and stays quiet on the two documented exemptions.

#### Scenario: All four fixture cases produce correct PASS/FAIL

- GIVEN the four synthetic fixtures are written to a sandboxed `/tmp` directory
- WHEN the scanner function runs against that fixture tree
- THEN the forward and reverse fixtures report FAIL and the prose and manifest-string fixtures report PASS (no violation)

### Requirement: REQ-7 — Rename-Resilient Data-First Structure

The system MUST declare registry filenames (`active-repos`, `autonomous-repos`) and their
canonical variable names (`ACTIVE_FILE`, `REPOS_FILE`) as named constants, and declare the
autonomous and session path-sets as arrays, at the top of the test file — so structural
assertions never hardcode these values inline.

#### Scenario: Constants centralize registry identity

- GIVEN the test file's top-of-file declarations
- WHEN the sibling rename task changes `active-repos` to `session-repos`
- THEN only the constant definitions require edits — no assertion logic changes

### Requirement: REQ-8 — Transitive-Closure Derivation With Declared Expected Set

The system MUST derive the autonomous path-set as the transitive closure of scripts
invoked or sourced from `sweep.sh` and `sweep-loop.sh` (including `.claude/commands/sweep-execute.md`
in the string-search net), and MUST assert that derived set equals an explicitly declared
expected set — failing loudly if the call graph has grown or shrunk without the declaration
being updated.

#### Scenario: Derived closure matches declared expectation

- GIVEN the current call graph from sweep.sh and sweep-loop.sh
- WHEN the guard computes the transitive closure
- THEN the computed set equals the declared expected set and this check reports PASS

#### Scenario: Undeclared call-graph growth fails

- GIVEN a fixture where a new script is invoked from the autonomous path but not added to the declared expected set
- WHEN the guard computes the transitive closure
- THEN the mismatch between derived and declared sets is reported as FAIL

### Requirement: REQ-9 — Makefile Integration

The system MUST be invocable via `make test`, wired as one additional line under the
existing `test:` target, following the repo's flat `bash test/<name>.sh` convention.

#### Scenario: make test runs the new suite

- GIVEN the Makefile `test:` target includes `bash test/unit-registry-separation.sh`
- WHEN `make test` is run
- THEN the registry-separation suite executes as part of the full test run

### Requirement: REQ-10 — Shellcheck Cleanliness

The new test script MUST be shellcheck-clean, consistent with enforcement by
`post-edit.sh` (per-edit) and `gate-check.sh` Gate 3 (per-branch).

#### Scenario: Shellcheck passes with no warnings

- GIVEN `test/unit-registry-separation.sh` as committed
- WHEN shellcheck runs against it
- THEN no warnings or errors are reported

### Requirement: REQ-11 — Baseline Pass on Current Clean Tree

The suite MUST pass (exit 0, `FAIL_COUNT` = 0) when run against the current repository
state, since both registry directions are confirmed clean today.

#### Scenario: Suite passes on current main

- GIVEN the current repository tree with no planted violations
- WHEN `bash test/unit-registry-separation.sh` runs
- THEN all real-tree checks (REQ-1, REQ-2 non-fixture scenarios) report PASS and the script exits 0

## Out of Scope

- `autonomous-repos` format, lifecycle, or writers.
- The `active-repos` → `session-repos` rename itself.
- Session expiry logic.
- Runtime/hook enforcement — this is a static test, not a gate.
- Migrating existing tests' hardcoded registry literals (test/unit-gate-check.sh,
  test/smoke-outcomes.sh, test/smoke-pinned-release.sh).
