# Envelope Menu Gum Conversion Specification

## Purpose

PR #23 (8a942b4) converted `_machine_menu`, `_fleet_menu`, and `_main_menu` to the shared `_menu`/`_confirm` gum helpers, leaving the envelope section of `.devlead/scripts/config.sh` as the last raw island: `_envelope_menu` hand-rolls its own numbered list and read loop, and `_edit_field` has zero gum usage across all five field types. This spec fixes that gap so the envelope screen obeys the same presentation contract (gum when available, identical `read -r -p` fallback under `DEVLEAD_NO_GUM=1`) as the rest of `config.sh`. What a choice DOES — validation, commit logic, schema shape — is unchanged.

## Scope

### In Scope
- New `_input <header> <current>` helper mirroring `_menu`'s has-gum/fallback shape.
- `_envelope_menu` dispatch rendered through `_menu`.
- `_edit_field` per-type widgets: `bool` → two-option `gum choose`; `int` / `string` / `string (nullable HH:MM)` → `_input` prefilled with the current value; `list`, `list-of-objects`, `map` unchanged.
- stderr discipline for all human-visible text in the envelope section.
- Gum-branch test coverage using the T7/T9 call-counting, self-terminating stub idiom, extended with a `gum input` stub.

### Out of Scope
- `_commit_change`, `_load_schema`, validation rules, or what a choice DOES.
- Widgets for `list` / `list-of-objects` / `map`.
- `envelope.sh`, its schema text, or the TTY/§A3 gate mechanics themselves (only their preservation is in scope).

## Hard Constraints

These MUST hold regardless of implementation approach; any scenario violating one of these fails review.

- **C1 — T2 field-literal invariant**: no envelope field name (e.g. `enabled`, `budget.max_issues`, `budget.stop_at`) MUST appear as a string literal anywhere in `config.sh`. Dispatch and per-type widget selection MUST be driven exclusively by `SCHEMA_FIELD`/`SCHEMA_TYPE` array contents, never by a hardcoded field-name branch. `test/unit-config-menu.sh` T2 MUST stay green.
- **C2 — §A3 TTY gate intact**: the envelope screen MUST remain behind the existing TTY gate and MUST stay unreachable from `sweep-execute`/`sweep-loop`/`sweep-discover`. No code path introduced by this change may expose `_envelope_menu`, `_edit_field`, or `_input` to an autonomous/non-interactive caller.
- **C3 — stderr discipline**: every line of human-visible text inside `_envelope_menu` and `_edit_field` (headers, help text, consequence text, prompts, error/cancel messages) MUST go to stderr (`>&2`). `_input` MUST emit only the resolved value on stdout, matching `_menu`'s existing return-channel contract.
- **C4 — dotted-name entry is fallback-only**: the ability to type a field's exact dotted name instead of a number MUST survive only in the no-gum path, resolved via `_menu`'s existing `__invalid__<raw>` return value (no change to `_menu` itself). Under gum, `gum choose`'s built-in filter is the only name-matching mechanism — no new typed-name affordance is added to the gum branch.
- **C5 — `DEVLEAD_NO_GUM=1` preserved**: no-gum scenarios MUST continue to run through a real pty (`script -qec`) with `DEVLEAD_NO_GUM=1` exported, per the suite's existing convention. New gum-branch scenarios MUST use self-terminating, call-counting stubs (first call answers/picks, subsequent calls answer "Back" or a fixed value) so the suite never hangs waiting on a real `gum`.
- **C6** — `list`, `list-of-objects`, and `map` field types MUST remain on their current `read -r -p`-based flow; no gum widget is introduced for these three types.
- **C7** — `"string (nullable HH:MM)"` blank-clears semantics MUST be preserved unchanged: leaving the (possibly prefilled) input blank still clears the field via the existing confirm-then-null path. No new "Clear" affordance is added.

## Requirements

### REQ-1: Envelope dispatch renders through `_menu`
`_envelope_menu` MUST build its numbered/gum list via `_menu` instead of its own `printf`/`read` loop, passing each field's name + current value as the label and its schema index as the value.

#### Scenario: no-gum dispatch matches today's numbered list shape
- GIVEN `DEVLEAD_NO_GUM=1` and an envelope with N eligible fields
- WHEN `_envelope_menu` is opened
- THEN the field list is rendered via `_menu`'s stderr numbered format, not a hand-rolled `printf` loop
- AND selecting a number resolves the same field as before the conversion

#### Scenario: dotted-name fallback still resolves under no-gum
- GIVEN `DEVLEAD_NO_GUM=1` and the envelope menu open
- WHEN the user types a field's exact dotted name instead of a number
- THEN `_menu` returns `__invalid__<name>`, `_envelope_menu` matches the `__invalid__` prefix, and the named field is resolved and opened for editing (per C4)

#### Scenario: gum dispatch has no hand-rolled numbered list
- GIVEN gum is available (`_has_gum` true)
- WHEN `_envelope_menu` is opened
- THEN the field picker is rendered via `gum choose` through `_menu`, with no `printf '%2d)'`-style output anywhere in the dispatch path

#### Scenario: blank Enter or q/Q at the field picker backs out
- GIVEN the envelope field picker is open (gum or no-gum)
- WHEN the user submits a blank Enter, or types `q`/`Q`, instead of picking a field
- THEN `_menu` returns its "b" sentinel and `_envelope_menu` exits back to the caller (`_main_menu`) immediately, per the same contract `_machine_menu`/`_fleet_menu`/`_main_menu` have followed since PR #23 — no redisplay loop, no hang

### REQ-2: Per-type field editors match plan, fallback identical to today
`_edit_field` MUST present `bool` as a two-option `gum choose` (`true`/`false` literal labels, per C1), and `int` / `string` / `"string (nullable HH:MM)"` via `_input` prefilled with the field's current value. `list`, `list-of-objects`, and `map` MUST be unchanged (C6). Under `DEVLEAD_NO_GUM=1`, every type MUST fall back to behavior identical to today's `read -r -p` flow.

#### Scenario: bool renders as a two-option select under gum
- GIVEN gum is available and a `bool` field is opened
- WHEN `_edit_field` runs
- THEN the user is offered a `gum choose` with literal `true`/`false` options (no free-text retyping)

#### Scenario: int/string/time prefilled with current value under gum
- GIVEN gum is available and an `int`, `string`, or `"string (nullable HH:MM)"` field with current value `cur` is opened
- WHEN `_edit_field` runs
- THEN `_input` is invoked with `cur` as the prefilled value, so the user edits rather than retypes from scratch

#### Scenario: nullable HH:MM blank still clears under gum
- GIVEN gum is available and `budget.stop_at` (type `"string (nullable HH:MM)"`) is prefilled with an existing time
- WHEN the user deletes the prefilled text in `_input` and confirms
- THEN the field is cleared to `null` via the existing confirm-then-null path, per C7 — no new Clear affordance exists

#### Scenario: every type falls back identically under `DEVLEAD_NO_GUM=1`
- GIVEN `DEVLEAD_NO_GUM=1`
- WHEN each of `bool`, `int`, `string`, `"string (nullable HH:MM)"`, `list`, `list-of-objects` is edited
- THEN the observable prompt/read/validate/commit behavior for that type is unchanged from pre-conversion `config.sh`

### REQ-3: T2 field-literal invariant holds through the conversion
No envelope field name MUST appear as a string literal anywhere in `config.sh` after the conversion; type dispatch (bool vs int vs string vs list) stays driven by `SCHEMA_TYPE`, never by field name.

#### Scenario: T2 stays green
- GIVEN the full diff of this change to `config.sh`
- WHEN `test/unit-config-menu.sh` T2 runs
- THEN it asserts zero envelope field-name literals and passes

### REQ-4: Consequence shown before confirm for all 7 UI entries
For every one of the 7 UI-facing envelope entries (6 top-level scalar fields plus the single grouped `discover.modules` list-of-objects entry, which itself surfaces 2 of the 8 raw schema CONSEQUENCE records via its two child prompts), any non-empty `CONSEQUENCE` text MUST be displayed before the corresponding gum or no-gum confirm/input step.

#### Scenario: scalar field consequence precedes the prompt
- GIVEN a top-level scalar field (e.g. `enabled`, `merge.mode`) with a non-empty schema `CONSEQUENCE`
- WHEN the field is opened for editing, under gum or no-gum
- THEN the consequence text is shown before the input/select widget and before the confirm step

#### Scenario: grouped list-of-objects entry shows both child consequences
- GIVEN the `discover.modules` entry (one UI-facing entry, backed by the `path` and `spec` raw schema records)
- WHEN the entry is opened
- THEN both children's consequence text is shown before their respective prompts, preserving today's ordering

### REQ-5: All visible text moves to stderr
Every echo/printf inside `_envelope_menu` and `_edit_field` that produces human-visible output MUST target stderr, so a captured `$( )` value is never contaminated (per C3).

#### Scenario: captured gum value is never contaminated by envelope text
- GIVEN a gum widget's return value is captured via `v="$(gum input ...)"` inside `_edit_field`
- WHEN any header, help, consequence, or error text is printed around that call
- THEN none of that text appears on stdout, and `v` equals exactly the widget's chosen value

#### Scenario: no-gum prompts stay on stderr too
- GIVEN `DEVLEAD_NO_GUM=1`
- WHEN `_envelope_menu` or `_edit_field` prints any prompt, help, consequence, or cancel/error message
- THEN it is written to stderr, matching `_menu`'s existing stderr convention

### REQ-6: Gum-branch test stubs terminate, never type to a real gum
New gum-branch scenarios in `test/unit-config-menu.sh` MUST use self-terminating, call-counting stubs for `gum choose` and the new `gum input`, following the T7/T9 idiom, and MUST NOT invoke a real `gum` binary.

#### Scenario: gum choose stub terminates
- GIVEN a stubbed `gum choose` that logs calls and answers "Back" after the first pick
- WHEN a new envelope gum-branch test runs
- THEN the menu loop exits without hanging and the test suite completes

#### Scenario: gum input stub returns a fixed value once
- GIVEN a stubbed `gum input` returning a fixed value on its first call
- WHEN a new int/string/time gum-branch test runs
- THEN `_input` receives that fixed value exactly once per widget invocation and the scenario completes without waiting on real input

### REQ-7: §A3 TTY gate and autonomous unreachability hold
The TTY gate protecting `config.sh` MUST still run first, and the envelope screen MUST remain unreachable from `sweep-execute`, `sweep-loop`, and `sweep-discover` after this change (restates C2 as a directly testable requirement).

#### Scenario: TTY gate still blocks non-interactive invocation
- GIVEN `config.sh` is invoked without a TTY
- WHEN the envelope screen would otherwise be reached
- THEN the existing TTY gate blocks it, matching `test/unit-config-menu.sh`'s existing gate assertions

#### Scenario: sweep paths never reference the envelope menu
- GIVEN the full diff of this change
- WHEN `sweep-execute.sh`, `sweep-loop.sh`, and `sweep-discover.sh` are searched for any reference to `_envelope_menu`, `_edit_field`, or `_input`
- THEN zero matches are found

### REQ-8: shellcheck clean, `make test` green
All touched or added `.sh` files MUST be `shellcheck -S warning` clean, and `make test` MUST pass with the new envelope gum coverage included.

#### Scenario: shellcheck clean
- GIVEN the diff of this change
- WHEN `shellcheck -S warning` runs over every touched or added `.sh` file
- THEN it reports zero findings

#### Scenario: make test green with new coverage included
- GIVEN the full test suite including the new `_input`/dispatch/per-type gum scenarios
- WHEN `make test` runs
- THEN all tests pass and the new envelope gum scenarios are part of the run

## Out of Scope
- Any change to `_commit_change`, `_load_schema`, validation rules, or what a choice DOES.
- Widgets for `list` / `list-of-objects` / `map`.
- `envelope.sh`, its schema text, or the TTY/§A3 gate mechanics.
- Widening `_menu`'s or `_input`'s general contract beyond what the envelope conversion needs.

## Review Workload Forecast

- **Estimated changed lines**: ~300 (per proposal Size Estimate): ~120 script (`_input` + dispatch + per-type rewiring) + ~180 test (new gum-branch scenarios + `gum input` stub).
- **400-line budget risk**: Low — comfortably under budget as a single PR.
- **Chained PRs recommended**: No — proposal already identifies a natural split boundary ((1) `_input` + dispatch, (2) per-type editors + gum tests) only if the estimate grows; not needed at current size.
- **Decision needed before apply**: No — proposal's question round already resolved the open decisions with assumptions (dotted-name fallback-only, blank-clears semantics kept, bool literal `true`/`false` labels, `_input` header-only) and none block `sdd-tasks`.
