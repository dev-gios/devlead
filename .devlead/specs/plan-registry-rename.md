# Session Registry Rename Specification

<!-- Delta spec for SDD change: plan-registry-rename -->
<!-- Modified capability: session-registry (rename + migration; registry-separation-guard
     and session-expiry specs are unaffected — see plan-separation-guard.md, plan-session-expiry.md) -->

## Purpose

`~/.devlead/active-repos` + `.devlead/scripts/devlead-active.sh` sit opposite
`~/.devlead/autonomous-repos`. "active vs autonomous" reads as two grades of the same
authority; in truth the first grants nothing (it only makes hooks non-inert for a
session) and the second is the autonomous-sweep universe. This spec renames the ephemeral
registry to `session-repos` / `devlead-session.sh` so the distinction is self-evident, and
defines the one-shot migration that gets existing machines there without ever fusing or
silently choosing between two present registries.

## Requirements

### REQ-1: Rename surface

The system MUST rename, consistently and without leaving a stale name behind outside
deliberate legacy-handling code:
- `~/.devlead/active-repos` → `~/.devlead/session-repos`
- `ACTIVE_FILE` (canonical variable) → `SESSION_FILE`
- `.devlead/scripts/devlead-active.sh` → `.devlead/scripts/devlead-session.sh`, including
  usage/messages/header prose
- `${SESSION_FILE}.lock` (the derived lockfile path follows the rename)
- All 4 call sites: `.claude/hooks/post-edit.sh:14`, `.claude/hooks/gate-check.sh:38`,
  `.claude/commands/arranquemos.md:91`, `.claude/commands/cerremos.md:114`

#### Scenario: Hooks invoke the renamed script
- GIVEN `post-edit.sh` and `gate-check.sh` as committed
- WHEN either hook fires
- THEN it invokes `~/.devlead/scripts/devlead-session.sh check` (not the old name)

#### Scenario: Slash commands invoke the renamed script
- GIVEN `/arranquemos` and `/cerremos` as committed
- WHEN either command runs its activation step
- THEN it invokes `devlead-session.sh on` / `devlead-session.sh off` respectively

#### Scenario: No stray old-name reference outside legacy-handling code
- GIVEN the full post-change diff
- WHEN searched for `active-repos`, `ACTIVE_FILE`, or `devlead-active.sh`
- THEN every remaining match is inside the uninstall removal loop (REQ-6), the bootstrap
  prune (REQ-5), or the migration/fallback logic (REQ-2, REQ-3) — each carrying a comment
  explaining why it references the old name

### REQ-2: One-shot migration in `on`/`off`, under the existing lock

`on` and `off` MUST perform migration inside their existing locked read-rewrite-replace
critical section (the same `flock` used for session-expiry rewrites), never inside `check`.
- Old file only exists → migration MUST rename it to the new path exactly once (a `mv`),
  emitting a one-line stderr notice; a second invocation MUST be a no-op (new file already
  present, no notice repeated).
- Both old and new files exist → `on`/`off` MUST abort with a nonzero exit and a stderr
  message naming BOTH paths and the required manual resolution. Migration MUST NOT merge
  the two files' contents and MUST NOT silently pick one. Neither file may be modified when
  this abort fires.
- Neither file exists → no migration action; `on`/`off` proceed to create the new file as
  today.

#### Scenario: First on/off after upgrade migrates old-only
- GIVEN only `~/.devlead/active-repos` exists
- WHEN `on` (or `off`) runs
- THEN `~/.devlead/session-repos` exists with the old file's exact prior contents,
  `~/.devlead/active-repos` no longer exists, and a stderr notice was printed

#### Scenario: Second on/off is a no-op migration
- GIVEN migration already completed (only `session-repos` exists)
- WHEN `on` (or `off`) runs again
- THEN no migration notice is printed and behavior is identical to a machine that never
  had the old file

#### Scenario: Both files present aborts loudly, never merges
- GIVEN both `~/.devlead/active-repos` and `~/.devlead/session-repos` exist
- WHEN `on` (or `off`) runs
- THEN it exits nonzero, prints a stderr message naming both paths and the manual
  resolution, and neither file's contents change

### REQ-3: `check` purity preserved, with read-only legacy fallback

`check` MUST remain pure (zero stdout, byte-identical files on both exit paths, no
mutation — the existing `unit-devlead-active.sh` REQ-3/4/8 contract) across all three
registry layouts:
- New file only exists → `check` reads the new file; the old file is ignored entirely.
- Old file only exists → `check` reads the OLD file read-only (no write, no rename, no
  stdout, same exit-code semantics as reading the new file). This exists so an upgraded
  machine that has not yet run `/arranquemos` does not fail open (hooks silently going
  inert would stop gate enforcement).
- Both files exist → `check` reads the NEW file only, silently, and does not merge, delete,
  or write either file. The both-exist condition is resolved loudly only in `on`/`off`
  (REQ-2), never inside `check`.

#### Scenario: check reads new file when only new exists
- GIVEN only `session-repos` exists with an entry for the current repo
- WHEN `check` runs
- THEN it returns the same exit code as before the rename, prints nothing to stdout, and
  neither file is modified

#### Scenario: check falls back to old file when only old exists
- GIVEN only `active-repos` exists with an entry for the current repo
- WHEN `check` runs
- THEN it evaluates that entry via the read-only legacy path, prints nothing to stdout,
  and `active-repos` is byte-identical before and after

#### Scenario: check prefers new file silently when both exist
- GIVEN both `active-repos` and `session-repos` exist with different contents
- WHEN `check` runs
- THEN it evaluates only the entry from `session-repos`, prints nothing to stdout, and
  neither file is modified

### REQ-4: Three-manifest consistency

The system MUST update all three manifest entries for the renamed script atomically in the
same change:
- `.devlead/scripts/bootstrap-lib.sh:226` `_pairs` array entry
- `test/smoke-pinned-release.sh:82` (`all_publish_targets()` heredoc)
- `test/smoke-pinned-release.sh:111` (`all_source_paths()` heredoc)

The existing `test/unit-publish-manifest.sh` cross-check MUST continue to fail loudly,
naming the exact missing entry, if only some of the three are updated.

#### Scenario: All three manifests updated together passes
- GIVEN `bootstrap-lib.sh` `_pairs` and both `smoke-pinned-release.sh` heredocs reference
  `devlead-session.sh`
- WHEN `unit-publish-manifest.sh` runs
- THEN it reports PASS (all three entries agree)

#### Scenario: Desynced manifest fails loudly
- GIVEN only 2 of the 3 manifest entries were updated to the new name (fixture or
  regression state)
- WHEN `unit-publish-manifest.sh` runs
- THEN it fails, naming the specific entry that still references the old name

### REQ-5: Bootstrap prunes the orphaned legacy script

Bootstrap publish MUST remove the single hardcoded legacy installed path
(`~/.devlead/scripts/devlead-active.sh`) when present, idempotently and silently when
absent, with a stderr note when it acts. This MUST NOT be a glob or general garbage
collection — a single named path only. Rationale: an orphaned legacy executable would still
write `active-repos` if invoked, recreating the old file and pushing the machine into the
permanent both-exist abort state (REQ-2).

#### Scenario: Legacy script present is pruned
- GIVEN `~/.devlead/scripts/devlead-active.sh` exists as an orphan after publish
- WHEN bootstrap publish runs
- THEN the orphan is removed and a stderr note is printed

#### Scenario: Legacy script absent is a silent no-op
- GIVEN `~/.devlead/scripts/devlead-active.sh` does not exist
- WHEN bootstrap publish runs
- THEN no error occurs and no note is printed

### REQ-6: Uninstall lists both names

`uninstall.sh`'s removal loop MUST list both `devlead-active.sh` and `devlead-session.sh`
so a machine at any migration stage is fully cleaned. This is a copy-and-name addition to
the existing symlink-only removal loop; it does not change the loop's symlink-only removal
mechanism (a pre-existing gap relative to bootstrap's copy-based publish, out of scope for
this change and mitigated by REQ-5's independent prune path).

#### Scenario: Uninstall removes symlinks for both names
- GIVEN a symlink named `devlead-active.sh` and/or `devlead-session.sh` under the install
  target
- WHEN `uninstall.sh` runs
- THEN both are removed if present, and absence of either is a silent no-op

### REQ-7: Docs state what each registry grants

`.claude/CLAUDE.md` §Modo opt-in, `arranquemos.md`, and `cerremos.md` MUST each use the new
names AND explicitly state what the session registry grants (nothing — it only makes hooks
non-inert for a session) versus what the autonomous registry grants (unsupervised
branches/commits/PRs, Inv 3 authority).

#### Scenario: CLAUDE.md documents session registry scope
- GIVEN `.claude/CLAUDE.md` §Modo opt-in as committed
- WHEN read
- THEN it names `devlead-session.sh` / `session-repos` and states the session registry
  grants no merge or execution authority by itself

### REQ-8: `unit-registry-separation.sh` stays green with new names

`test/unit-registry-separation.sh`'s `SESSION_SCRIPT` (line 69) and `SESSION_PATH_SET`
(line 92) constants MUST be updated to `devlead-session.sh` so real-invocation detection
keeps working post-rename. `SESSION_NAMES`/`SESSION_VARS` already carry both the old and
new literals by design and require no edit.

#### Scenario: Separation guard passes post-rename
- GIVEN the renamed script and registry as committed
- WHEN `test/unit-registry-separation.sh` runs
- THEN it reports PASS with zero forward or reverse violations

### REQ-9: TTL and expiry behavior unchanged

The rename and migration MUST NOT alter TTL semantics, entry format
(`path<TAB>epoch`), or lock semantics established in the session-expiry spec
(`.devlead/specs/plan-session-expiry.md`). Migration MUST carry the file's exact prior
contents (including timestamped entries) across the rename.

#### Scenario: Migrated file preserves timestamps and TTL evaluation
- GIVEN `active-repos` contains a fresh timestamped entry before migration
- WHEN migration renames it to `session-repos`
- THEN `check` against the migrated entry produces the same exit code it would have
  produced against the pre-migration file

### REQ-10: Hooks stay inert on unmarked repos

The rename MUST NOT change the existing opt-in mechanism: `post-edit.sh` and
`gate-check.sh` MUST remain no-ops (exit 0, no gate output) for repos not present in either
the migrated or legacy registry.

#### Scenario: Unmarked repo hook is a no-op
- GIVEN a repo with no entry in `session-repos` or `active-repos`
- WHEN `post-edit.sh` or `gate-check.sh` fires
- THEN the hook exits 0 without blocking and without gate output

### REQ-11: Lint and full suite green

`shellcheck` MUST be clean on `devlead-session.sh` and every modified file. `make test`
MUST pass, including `unit-devlead-session.sh` (renamed from `unit-devlead-active.sh`,
including its `Makefile:19` wiring), `unit-gate-check.sh`, `unit-registry-separation.sh`,
and `unit-publish-manifest.sh`.

#### Scenario: Full suite passes post-change
- GIVEN the change as committed
- WHEN `make test` runs
- THEN all listed suites report PASS and shellcheck reports zero warnings

## Out of Scope

- `autonomous-repos`, `REPOS_FILE`, `sweep*.sh`, systemd units, envelope/merge authority
  (Inv 3 untouched).
- `GOVERNANCE.md` / `DEVLEAD.md` — no literal references to rename.
- Fixing `uninstall.sh`'s symlink-only removal vs. bootstrap's copy-based publish
  (pre-existing gap, independently mitigated by REQ-5, not solved here).
- Any change to TTL value, entry format, or lock semantics beyond carrying them intact
  through migration (REQ-9).

## Review Workload Forecast

- Estimated changed lines: ~280-360 (per proposal risk table), driven by the rename
  surface (1 script + 1 test file), the three-manifest interlock (REQ-4), the migration
  and fallback logic in `on`/`off`/`check` (REQ-2, REQ-3), and doc updates (REQ-7).
- Atomicity: the three-manifest interlock plus migration coupling make this unsplittable
  without landing broken intermediate states — renaming the source without the manifest
  breaks publish (caught loudly by `unit-publish-manifest.sh`, REQ-4), and shipping the
  rename without migration silently deactivates every installed machine (REQ-2/REQ-3).
- Recommendation: single PR with `size:exception`, decided at `sdd-tasks`.
- `Decision needed before apply: Yes` (confirm `size:exception` acceptance)
- `Chained PRs recommended: No` (atomicity forbids a safe split)
- `400-line budget risk: Medium` (forecast is under 400 but close enough to warrant the
  exception up front)
