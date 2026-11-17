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
| T0 | design + votes | inline | done | c3bfe02, votes commit on `docs/proactive-design` |
| T1 | S5 | pending mapping | todo | |
| T2 | S6 | pending mapping | todo | |
| T3 | S7–S10, S12, S15, S20 | — | todo | |
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
