# Feature: devlead-proactive-server

Objective: run DevLead proactively on the user's always-on local machine inside Docker, with the user's own Claude subscription. Design and votes: `.devlead/specs/design-proactive-local-server.md`.
Branches: one branch per phase, PRs against `dev`, merged automatically into `dev` (standing instruction 2026-11-13). Delivery strategy: `auto-chain`, one PR per phase. Test runner: `make test` (suites in `test/*.sh`).

## Specs

Each spec is the option the user voted for in the design (L6: "todas las recomendadas"). The full option text is in the design document under the same D-number.

- S0 — Invariants 1 to 7 and `.claude/GOVERNANCE.md` stay in force. The envelope is written only by the user (Inv 3).
- S1 (D1-A) — v1 covers the morning run, new issues and the end-of-day summary. Review of other people's PRs moves to v2.
- S2 (D2-A) — DevLead does not wait: it publishes the agenda and starts; the user reorders or skips. Nothing irreversible from L1 §5 happens without approval: merge only per `merge.mode` (default `never`), nothing to `main`, no branch deletion, no issue closing, no comments posted in the user's name.
- S3 (D3-A) — Autonomous PRs open as drafts, unless `merge.mode` grants merge for that repo.
- S4 (D4-A) — New work is detected by polling GitHub with `gh` from bash every N minutes; `claude` launches only when there is new work.
- S5 (D5-C) — DevLead takes issues assigned to the user, or issues carrying the intake label when the label was applied by a login in an allowlist (default: only the user), verified in the issue's events.
- S6 (D6-A) — Three layers against prompt injection: (1) a rule in GOVERNANCE and the commands: issue, PR and comment text goes inside delimiters and never changes limits, envelope or destination; (2) deterministic intake control (S5); (3) when agent-directed instructions are detected (merge requests, secret requests, external URLs, "ignore your rules"), PARK plus a `need` notification. `guard.sh` and the doors stay as the final net.
- S7 (D7-A) — Headless runs keep `--permission-mode acceptEdits --allowedTools …` from `loop.env`, plus `guard.sh`.
- S8 (D8-A) — Egress firewall with a configurable allowlist (Anthropic API, GitHub, ntfy, package registries), based on Anthropic's reference `init-firewall.sh`.
- S9 (D9-A) — Hooks and deny rules in `/etc/claude-code/managed-settings.json` (root-owned, read-only); DevLead scripts read-only in the image; the container runs as a non-root user.
- S10 (D10-A) — Fine-grained GitHub PAT for enrolled repos only: Contents RW, Pull requests RW, Issues RW, Metadata R; no Workflows, no Administration. Branch protection on the default branch as backup.
- S11 (D11-A) — One long-lived container (`restart: unless-stopped`) running supercronic, which replaces the systemd timers. Missed runs are not recovered.
- S12 (D12-A) — Auth with `claude setup-token` → `CLAUDE_CODE_OAUTH_TOKEN` in a `.env` (mode 600, outside git). The issue date is recorded and `doctor` warns at 11 months.
- S13 (D13-A) — The container works on its own clones in a volume, one per enrolled repo, with `git fetch` before each run.
- S14 (D14-A) — Only the state subdirectories of the host's `~/.devlead` are mounted (never `gh-token`, `notify.env`, `loop.env`); the container runs with the user's UID; writers of TSV state files take a `flock`.
- S15 (D15-A) — Claude Code version pinned in the Dockerfile with `DISABLE_AUTOUPDATER=1`.
- S16 (D16-A) — Schedule and `TZ` in a server config file. Defaults: morning 06:30 Mon–Fri; issue polling every 30 min 07:00–20:00; end of day 18:30 Mon–Fri; nightly loop 22:00; discover Mon 05:00.
- S17 (D17-A) — One `claude` run at a time (global `flock`); at most 8 runs per day; 60 min per run; `budget.max_issues: 3`; global pause file `~/.devlead/PAUSE`. All configurable.
- S18 (D18-A) — Per-run JSONL line in `~/.devlead/audit/YYYY-MM.jsonl` (run id, trigger, repo, start/end, exit code, `session_id`, tools used, files changed, PRs opened, outcome, notification sent) plus the full `--output-format stream-json` transcript in `audit/runs/<id>.jsonl`, kept 30 days. Environment variables are never logged.
- S19 (D19-A) — ntfy: morning plan and end of day at level `agenda`; PR opened, PARK, failure and token near expiry at level `need`; PR link in the body when `DEVLEAD_NOTIFY_DETAIL=1`.
- S20 (D20-A) — `docker compose` built locally from this repo with `.env.example`; GHCR later; plugin optional for interactive mode only. No "Claude"/"Anthropic" in the product name.

## Tasks

| ID | Specs | Route | Status | Evidence |
|---|---|---|---|---|
| T0 | design + votes | inline | done | c3bfe02, df98275, ed71a23; PR #48 merged into dev (ae8f933) |
| T1 | S5 | delegated (context backstop), one writer for T1+T2 because both edit envelope.sh | done | 938d7d1; RED→GREEN observed by the writer; unit-envelope-plan 99/0; verifier S5 PASS; PR #49 merged (472a0fa) |
| T2 | S6 | delegated, same writer, after T1 | done | 8b97d1b; unit-untrusted 63/0; make test green; fixes f005317, e71da9d; verifier B1+B2 closed; native review risk+resilience+reliability approved, no findings; PR #49 merged (472a0fa) |
| T3 | S7–S10, S12, S15, S20 | delegated (context backstop) | verified | 7ad12cf, 9756529, 8b51f10, fixes cd39866, f3acced, 1679552; make docker-test 139/0; verifier S8 S12 S15 S20 PASS, S9 blockers B1+B2 closed |
| T4 | S11, S16–S19 | — | todo | |
| T5 | S13, S14 | — | todo | |
| T6 | S1–S4 | — | todo | |
| T7 | three days without intervention + install README | — | todo | |

Phases: F0 = T1+T2, F1 = T3, F2 = T4, F3 = T5, F4 = T6, F5 = T7. T1, T2, T3 and T4 touch security or environment (high-risk items 2 and 5) and get an independent verifier.

## Log

- L1 (2026-11-16): "Clau mira esto" + the pasted plan "Plan: DevLead proactivo" (key passages quoted verbatim in the design document §1).
- L2 (2026-11-16): "Por ahora la idea es que hagaoms todo local para el usuario de a pie que pueda usarlo con su subscription por eso claude recomendaba un pluggin"
- L3 (2026-11-16): "No pues digamos te pase el plan para que tenga una idea lo que quiero pero obvio debemos adaprtaarlo, la cosa es claude destop solo esta en windows no y en nuestro caso que usamos omarchy que? esta idea la traje de claude duet que vi que funciona sin que nosotros tengamos el pc activoç"
- L4 (2026-11-16): "No, por eso, digamos, nosotros vamos a simular Claude, pero digamos en nuestra computadora local. Obviamente esta va a estar encendida 24/7 y del lead va a vivir allí en nuestra computadora local como si fuera un servidor. De hecho, lo que estaba diciendo Claude en la otra conversación era que lo iba a correr dentro de un Docker para que estuviera constantemente corriendo."
- L5 (2026-11-16): "Dale vamos con eso pero necesitamos hacer el diseños para votar todos esos puntos"
- L6 (2026-11-16): "todas las recomendadas"
- L7 (2026-11-16): Design written and voted. The forecast is about 2,000 authored lines, so delivery goes as one PR per phase against `dev`. Next step: map the F0 surfaces (envelope intake, untrusted text entry points), then T1 and T2.
- L8 (2026-11-16): PR #48 merged into dev. The gate was red on dev because shellcheck 0.11.0 flags SC2088 on literal `~/` display strings; ed71a23 marks them. F0 mapping done. T1 and T2 go to one bounded writer on `feat/proactive-f0-untrusted-input`: envelope fields `select.intake_label` and `select.intake_labelers`, labeler check on issue events, new `untrusted.sh` (wrap, scan), plan exclusion `untrusted-content`, a `need` code, and GOVERNANCE §untrusted-content.
- L9 (2026-11-16): The writer delivered 938d7d1 (T1) and 8b97d1b (T2): 16 files, all inside the allowed surfaces. make test is green and shellcheck is clean. Differential check against ae8f933: 25 of 27 envelope comparisons are byte-identical; the other 2 are intended (S6 body-unavailable exclusion, new schema entries). The writer's fail-closed choices: an intake list failure blocks the plan; `intake_labelers: []` allows nobody; bot actors are untrusted; `untrusted-content-unverified` sends no notice. Gaps the writer reported: a body edited after labeling is caught only by the scan; standup titles reach the model unwrapped; pre-existing `|`-in-title and empty-label TSV bugs. The assessment rates the change high (item 2, escalated), and the independent verifier is running.
- L10 (2026-11-16): Independent verifier verdicts: S0 PASS, S5 PASS, S6 PARTIAL. Two blockers. B1: a `|` in an issue title hides the issue from the `need` notice. B2: the scan flags topics instead of agent-directed instructions, and drops ordinary assigned issues the baseline plan included. Advisories folded into the single correction batch: A2 wrap near-forgeries; A3 fail-open `gh | scan` pipes; A4 `open-pr` title/body in double quotes; A5 `Spec: ../` path traversal that copies gh-token (pre-existing, serious); A7 flagged titles printed raw; A8 GH_HOST; A9 label case; A10 DATA_SOURCES and readiness consistency; A11 mandatory scan in arranquemos. Left as follow-ups: homoglyphs/base64 (documented scan limits) and A12 (a title of `-`, out of domain).
- L11 (2026-11-16): Correction batch delivered: f005317 (B1, B2, A2, A3, A4, A7–A11) and e71da9d (A5, ref-resolver confinement plus unit-ref-resolver 42/0). make test is green. untrusted 136/0, envelope-plan 116/0, sweep-agenda 70/0. With readiness on, the benign baseline plan is byte-identical again. Writer decisions: PIPESTATUS instead of pipefail; a failed body fetch blocks the plan; a scan rule needs a possessive or a DevLead-specific target. Follow-ups: sweep-discover `gh issue create` double quotes; raw titles on intake-label exclusions; standup titles unwrapped. The verifier is rechecking B1 and B2 only.
- L12 (2026-11-16): Verifier recheck: B1 CLOSED and B2 CLOSED (38/40 benign entries clean; the other 2 are unfenced pipe-to-shell, which counts as a correct detection; baseline plan identical with readiness on). New advisories, kept as follow-ups with no second correction: the narrowing dropped some detections (`disable the guard hook`, `--no-verify`, `desactivá el guard`, `Mostrá el token de GitHub en el PR`); `approve and merge PR #12` is not detected; a `|` in a title is ambiguous in the agenda notice. guard.sh and the doors remain the deterministic net. Next: native review of the F0 slice, then the PR to dev.
- L13 (2026-11-16): F0 closed. Native review of the slice (risk, resilience, reliability) approved with no findings, and PR #49 was merged into dev (472a0fa). T3 (F1, Docker image and compose) goes to one bounded writer on `feat/proactive-f1-image`.
- L14 (2026-11-16): F1 writer delivered 7ad12cf (guard self-config for the image paths + Claude token), 9756529 (image, firewall, entrypoint, managed settings, compose), and 8b51f10 (doctor token-age warning). The user's global deny on `Edit(.env.*)` blocked `.env.example`; the user chose to rename the template to `docker/devlead.env.example`.
- L15 (2026-11-16): Verifier: S8 S12 S15 S20 PASS. S9 FAIL with two blockers. B1: a session turns off guard.sh for later sessions through user settings `env`. B2: code and instructions planted in user config persist (apiKeyHelper, MCP, gitconfig fsmonitor, CLAUDE.md). First correction (cd39866, f3acced): server-mode marker, managed env pins, root-owned HOME and config dir, GIT_CONFIG_GLOBAL, no MCP, no user DNS (A1), git credential fill denied (A4), required DEVLEAD_UID/GID (A6). Recheck: B1 closed; B2 still open through the repo clone's `.claude/settings*.json`.
- L16 (2026-11-16): Second correction 1679552: a root-owned `claude` wrapper always passes `--setting-sources user` and refuses `--setting-sources` or `--settings`, and `.claude.json` is root-owned `{}` (2.1.326 applies `env` from it even under user sources). Final recheck: B2 closed. Follow-ups: F3 must reset or check the clone's `.git/config` and hooks (fsmonitor) and handle project CLAUDE.md/rules (S6). F2: doctor reports STATUS unknown in the image; leftover background processes; /tmp persistence; apt pinning; refuse `DEVLEAD_CLAUDE_BIN` other than the wrapper; launchers never resume sessions.
