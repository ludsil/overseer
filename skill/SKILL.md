---
name: overseer
description: Use when anything about the Overseer menu bar app comes up (missing icon, expired account, reconnecting a profile), when checking how much subscription capacity is left ("how much usage do I have left", "am I near my limit", "which sub has headroom", /usage, quota, rate limit, weekly limit, Overseer) or before sizing any agent fleet, and when work should be spread across the user's multiple AI subscriptions ("use my second sub", "don't burn this session's quota", "run it on the other account", "juggle subscriptions") or launched on a specific Claude or Codex account.
---

# Overseer: subscription capacity and worker routing

## Overview

One account = one config directory. The orchestrator (this session) stays on its own subscription and launches CLI workers via Bash with an env var pointing at a different credential namespace: `CLAUDE_CONFIG_DIR` for Claude Code, `CODEX_HOME` for Codex, `GROK_HOME` for Grok Build. Workers on other profiles consume ZERO quota from the main session's sub.

**The only subscription switch is the env var + profile dir.** There is no `ant auth --profile`, no `ANTHROPIC_PROFILE`, no API-key routing — subscription OAuth lives inside each profile dir (macOS: a per-profile Keychain entry). Never copy or store credentials anywhere else, including this skill.

**REQUIRED BACKGROUND:** orchestrating-subagents — engine choice, fleet sizing, and the full Codex CLI recipe. This skill only adds the multi-subscription layer.

## Profile registry (discovered at runtime)

Slots are DIRECTORIES; accounts MOVE between them at runtime — the Overseer app's "Make active" swaps the default profile's login with a slot's, by design, so whichever sub has headroom can be rotated onto the default profile. **Never trust a remembered dir→email mapping (including anything this file said in the past). Read identity live, and enumerate dirs instead of assuming you know them all** — the user adds subs without editing this skill:

```bash
~/.claude/skills/overseer/scripts/usage.sh   # discovers ~/.claude + every ~/.claude-*; each section header = dir · CURRENT account · limits
ls -d ~/.codex ~/.codex-* 2>/dev/null        # Codex homes
```

A `local.md` beside the live copy of this file, if present, holds machine-local notes (e.g. a dated dir→account snapshot). It is a starting hint only — the live reading above always wins.

| Dir pattern | Engine | Role |
|---|---|---|
| `~/.claude` (default) | Claude | Whatever account is mounted here is what plain `claude` and Conductor bill. Don't launch worker fleets on it. |
| `~/.claude-*` | Claude | Worker-pool slots: heavy fan-out, design (fable), planning (fable/opus5) |
| `~/.codex*` | Codex gpt-5.6-sol (xhigh) | Web research, verification, second opinions, self-contained coding |
| `~/.grok*` | Grok Build grok-4.6 (500k ctx) | Overflow pool for research/verification/second opinions when Claude+Codex are constrained. Weekly pool SHARED with any Grok chat use on X by the same account — spend gently. |

**Switching accounts is only durable once the old sessions are gone.** Every live Claude Code process keeps the account it started with AND writes that account's rotated tokens back into its profile's single Keychain item when it refreshes — so a switch can silently revert minutes later, and two processes writing one item invalidate each other's refresh token (`invalid_grant`, "token disconnected", "Please run /login" — a repeatedly-observed failure mode). Rules: switch, then start a NEW session and let the old ones finish; never mount the same account on two slots (duplicate refresh tokens rotate each other dead — Overseer marks these "same account as X").

**A running session bills the account its profile held at process start.** A swap changes only what NEW processes see, so mounts can move mid-session: re-read identity (not just limits) at every usage check, and don't infer "which sub am I on" from stale memory — the answer is what the default dir held when your session started.

Two dirs can hold the SAME account, in which case there is no quota to spread and CLI workers just eat the orchestrator's own limits. Overseer marks such rows "same account as X"; `accountUuid` in each dir's `.claude.json` is the ground truth.

**NEVER set `CLAUDE_CONFIG_DIR=~/.claude` explicitly.** For the default profile leave the variable UNSET: setting it — even to the default path — moves the CLI onto a hash-suffixed Keychain item (`Claude Code-credentials-<8 hex>`) and an in-directory `.claude.json`, forking the profile's identity from what plain `claude`/Conductor uses. This can silently fork and lose a login. Worker recipes here only ever set it to NON-default dirs, which is safe.

Adding a profile: Overseer → Manage Claude accounts → Add account (or `mkdir ~/.claude-N` + one interactive login). No skill edit needed — discovery is dynamic.

**Worker profiles share the default profile's user config by symlink** (`skills`, `CLAUDE.md`, `settings.json`, `settings.local.json`, `plugins`, `agents`, `commands` → `~/.claude/…`; Overseer creates these for new slots). A profile dir bundles the login WITH the config that shapes behavior, and `CLAUDE_CONFIG_DIR` moves both, so an unlinked slot runs blind — no skills, none of the user's global rules (verified: a worker on an unlinked slot could not see this skill). Only `.claude.json` + the Keychain item stay per-account. If a worker ever behaves as if it has no skills/instructions, check `ls -l ~/.claude-N/skills` for a missing or broken link — an atomic rewrite through the symlink path can replace it with a real file.

## Launch recipes

**Claude worker on a specific ACCOUNT — the default dispatch path** (background Bash, one
output file each). Never pick a directory from a remembered or minutes-old reading: mounts
rotate, and a stale dir→account mapping can route an entire fleet onto a drained pool
while a fresh sub sits idle. `scripts/run-on.sh` resolves the account's
CURRENT dir from each profile's own `.claude.json` and execs in the same breath (once
started, a worker keeps the credentials it started with — a later swap can't move it):

```bash
~/.claude/skills/overseer/scripts/run-on.sh you@example.com \
  -p "PROMPT" --model claude-opus-5 > /path/out.md 2>/path/err.log
~/.claude/skills/overseer/scripts/run-on.sh @freshest \
  -p "PROMPT" --model fable > /path/out.md 2>/path/err.log   # lowest session %, ties by weekly_all
```

- **Exit 42 = the worker was REFUSED** (limit / not logged in). The bare CLI exits 0 in
  that case with the refusal as its only stdout — never trust a worker's exit code or a
  non-empty output file without this wrapper (or an equivalent content check); a
  one-line output file that reads "You've hit your session limit…" is a failed run.
  Exit 64 = account not found on any dir / no usable profile for `@freshest`.
- Routing is reported on stderr; worker stdout passes through untouched. It handles the
  default-dir rule itself (runs with the env var UNSET when the account is mounted there).

**Raw per-directory launch** (the underlying mechanism — use only when you have read the
dir's identity in the same breath):

```bash
CLAUDE_CONFIG_DIR=$HOME/.claude-2 claude -p "PROMPT" \
  --model claude-opus-5 > /path/out.md 2>/path/err.log
```

- `--model` verified working in CLI v2.1.231: `claude-opus-5`, `fable`, `haiku`, `sonnet`. Use `fable` for design/large-planning workers (vision + judgment), `claude-opus-5` for judgment-tier fan-out, `haiku` for mechanical.
- Workers that edit files: `cd` into a dedicated git worktree first and add `--permission-mode acceptEdits` (or `--dangerously-skip-permissions` for trusted throwaway work).
- The clean answer is stdout (the `-p` result); keep stderr separate.

**Preflight a profile before any fleet** (~10s, near-zero cost):

```bash
CLAUDE_CONFIG_DIR=$HOME/.claude-2 claude -p "Reply with exactly: OK" --model haiku
```

`Not logged in · Please run /login` means the profile needs a one-time interactive login: run `CLAUDE_CONFIG_DIR=$HOME/.claude-2 claude` in a terminal, then `/login` with that sub's account. Tokens auto-refresh afterward. A reply like `You've hit your weekly limit · resets <date>` means auth is FINE but that sub has no headroom — route its work to codex or another profile until the stated reset.

**Codex worker:** use the recipe in orchestrating-subagents verbatim (`codex exec --skip-git-repo-check -c tools.web_search=true -o out.md "PROMPT" < /dev/null`). **Always close stdin with `< /dev/null` when launching from an agent's background shell**: with a non-TTY stdin that stays open (a harness pipe), `codex exec` prints `Reading additional input from stdin...` and blocks forever before doing any work — the run looks alive but never starts (a repeatedly-reproduced failure mode). A terminal launch has a TTY and doesn't need it, but the suffix is harmless there — keep it unconditionally. If a run seems stuck, `tail` its log for that exact line: kill and relaunch with stdin closed. For a second Codex account, prefix with `CODEX_HOME=$HOME/.codex-2` AND set `cli_auth_credentials_store = "file"` in that home's `config.toml` before logging in — Codex's Keychain mode is shared across homes, so only file mode (`auth.json` inside the home) isolates accounts.

**Grok worker** (Grok Build CLI, verified on v1.0.5 with an X Premium+ sub):

```bash
grok -p "PROMPT" > /path/out.md 2>/path/err.log            # single-turn headless, answer on stdout
grok -p "PROMPT" --output-format json                       # adds usage/cost/sessionId metadata
grok -p "PROMPT" --json-schema '{...}'                      # structured output
```

- Default model grok-4.6 (500k context); `-m` selects, `--reasoning-effort` tunes. Editing workers: `--permission-mode` / `--always-approve` exist, and it has native `--worktree=NAME`.
- Preflight: `grok -p "Reply with exactly: OK"` (~$0.002 of pool). `grok models` checks login WITHOUT spending ("You are logged in with grok.com").
- Auth lives in `~/.grok/auth.json` (file-based, auto-refreshing). Second account: `GROK_HOME=$HOME/.grok-2`.
- NO usage endpoint exists (probed api.x.ai, cli-chat-proxy.grok.com, and the ACP stdio agent's full capability set — the TUI's /usage rides a private websocket). Capacity check = preflight outcome; refusal markers in session events are `usage_pool_exhausted` / `usage_limit_reached` (Overseer's Grok row flags these red). Per-run token usage is recorded in each session's `updates.jsonl` (largest `totalTokens` = session total) if an agent ever needs to account for Build-side spend; Grok chat on X draws the same pool invisibly, so local sums are never a pool percentage. The weekly pool is shared and X Premium+ gets ~1/3 of SuperGrok's rate — treat it as a light overflow pool, not a fan-out engine. If a future CLI version ships `grok usage` or exposes `x.ai/session/usage` over stdio, upgrade to it.

## From Conductor (or any harness)

Works unchanged: the harness's model picker only governs the orchestrator session (sub 1); workers are plain Bash children, so `CLAUDE_CONFIG_DIR`/`CODEX_HOME` routing works from Conductor, terminal, or Zed alike. Optional: pin env for a repo's Conductor agents via `.conductor/settings.local.toml` → `[environment_variables.local]`.

## Maintaining this skill

**Source of truth is the `skill/` directory of this repo** — edit there, PR, then sync the live copy by running `skill/install.sh` from your clone (copies to `~/.claude/skills/overseer/`, which worker slots see through their symlinks). A hand-edit to the live copy alone will be silently overwritten by the next sync — with one exception: `local.md` next to the live SKILL.md is machine-local (account snapshots, personal notes), never comes from the repo, and survives every sync. If it exists, read it.

If anything here stops working (usage.sh errors, login/keychain behavior changes, new CLI versions), read `internals.md` in this dir first — it records HOW each fact was established and how to re-verify or adapt it. After fixing, update the registry/recipes here and re-date the verification notes.

## Usage awareness — check before provisioning

Agents CAN query real subscription utilization (same data as `/usage`):

```bash
~/.claude/skills/overseer/scripts/usage.sh              # ALL Claude profiles, auto-discovered
~/.claude/skills/overseer/scripts/usage.sh ~/.claude-2  # one profile
```

Each section is headed by `dir · current account email` (read live — mounts move). Prints session (5h), weekly, and per-model-scoped utilization with severity, reset times, and `<- binding` on the limit that is CURRENTLY constraining the account (`is_active`). Per-model weekly limits are separate from the all-model weekly: Fable can sit at 100% binding while `weekly_all` is at 54% — meaning fable-tier work is out but sonnet/haiku work on that sub is not. Read the binding line before concluding a sub is spent.

Human-facing view across all engines incl. Codex: **Overseer**, this repo's native macOS menu bar app installed to `~/Applications`; the same collector runs as a CLI via `overseer.5m.py --text|--json`. Reopen the app from Finder to get a window if its icon is missing; `scripts/doctor.sh` in the repo repairs placement/autostart. Both it and usage.sh read the profile's OAuth token from its Keychain entry (service `Claude Code-credentials[-sha256(dir)[:8]]`) and calls `api.anthropic.com/api/oauth/usage`; the token never leaves the machine.

**Expired tokens on worker profiles self-heal** (2026-08-31): Overseer performs the CLI's own OAuth refresh grant (`POST https://platform.claude.com/v1/oauth/token`, JSON `{grant_type: refresh_token, refresh_token, client_id: "9d1c250a-e61b-44d9-88ed-5944d1962f5e"}`, with a CLI-shaped User-Agent such as `claude-cli/2.1.247 (external, cli)`) and writes the rotated pair back to the profile's Keychain item in the CLI's exact shape. SAFETY GATE: only for tokens already expired on NON-default profiles - an expired worker token provably has no live session refreshing it, while the default profile may have an idle session holding the refresh token in memory, and two writers rotating one refresh token invalidate each other. For the default profile, a tiny `claude -p` run (the CLI's own path) is the safe renewal. usage.sh sections showing HTTP 401 self-resolve on the app's next refresh cycle, or run any command on that profile.

Fleet discipline built on it:

1. Run it with no args BEFORE sizing a fleet, and again between waves — it discovers every profile and shows who is mounted where, so a new sub or a swapped mount is caught instead of assumed away.
2. `warning`/`critical` severity (or session ≥70%) on a sub → no new large fleets there this window. Reroute to the other profile or codex, or schedule after the printed reset time.
3. **Constrained ≠ cheaper.** Never downgrade models to fit a budget. Cut agent COUNT instead: merge related work into fewer, bigger-scoped, more intentful delegations with explicit deliverables.
3b. **Size to marginal value, not to design symmetry.** Default is ONE worker
   per independent deliverable. A second worker on the same deliverable is
   justified only when outputs compete for a judged slot and single-draw
   variance is the real risk; a third needs a written reason. "N verticals x
   M stances" multiplying itself is not a reason - state what each worker
   beyond the first adds before launching. (Observed: a six-worker wave on one
   deliverable was barely better than one or two.)
3c. **Vision work is not text work — price it separately.** Screenshots and
   full-page image reads cost multiples of text per agent, and the session (5h)
   window is what binds first, not weekly. The 10–15 wave cap below is a TEXT
   cap: for image-reading agents the cap is **3**, and the check is the live
   session percentage taken IMMEDIATELY before launch (not one from earlier in
   the turn — your own main-loop image reads have moved it since). Session ≥40%
   → do not fan out vision work on this sub at all; do it inline yourself, or
   route it to a worker profile / Codex. Reading N large screenshots in the main
   loop AND launching agents that each read more is the specific combination to
   avoid. (Observed: a session went 41% → 93% in one turn from ~8 full-page
   screenshot reads plus a 6-agent vision fan-out that was killed before
   returning anything; the same analysis was then completed inline from
   JSON/pixel measurement at negligible cost — see rule 3d.)
3d. **Measure before you look.** When the question is quantitative (how many
   sections have a background, what are the gaps, which colors repeat), extract
   it mechanically — DOM measurement via Playwright, or PIL over a saved
   screenshot — and spend image reads only on the few frames where judgment is
   actually required. A vision fleet asked to "classify these pages" is usually
   a script that was never written.
3e. **Drain the window that expires first.** Among profiles with headroom, route
   Fable/judgment worker fleets to the one whose BINDING limit resets SOONEST
   (usage.sh prints reset times) — unspent capacity in that window is about to
   evaporate, while later-resetting windows keep their value as reserve. Note
   this is a different criterion from `@freshest` (lowest session %): when
   draining is the goal, pick the account by reset time explicitly with
   `run-on.sh <account>`.
3f. **Poke idle subs right after a window resets, so the next countdown starts.**
   Windows appear to start on FIRST USE, not on a fixed clock: usage.sh shows
   `session … resets -` on an untouched profile — no session window exists
   until a request opens one. A sub left idle after its reset is banking
   nothing; a one-line poke (`run-on.sh <account> -p "Reply with exactly: OK"`)
   starts the 5h clock so capacity is live when a fleet needs it. Poke with
   the MODEL whose scoped window you care about (a fable one-liner to start
   the fable weekly). Session start-on-first-use is observed; the weekly
   working the same way is plausible but UNVERIFIED —
   verify by poking right after a weekly reset and reading whether the new
   weekly reset lands at poke+7d (rolling) or on the old cadence (fixed);
   update this rule with the answer either way.
4. Checkpoint intent: every worker writes to its own output file from the start, waves capped at 10–15 (text) / 3 (vision, see 3c), so a mid-wave limit loses only that wave's tail — then re-check usage before the next wave.
5. Codex DOES have a live usage endpoint (discovered 2026-08-18, supersedes the old "no endpoint" claim): the `account/rateLimits/read` RPC on `codex app-server`. Zero token cost, works for any home via `CODEX_HOME=` prefix:

   ```bash
   { printf '%s\n' \
     '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"usage-check","title":"usage-check","version":"1.0"}}}' \
     '{"jsonrpc":"2.0","method":"initialized"}' \
     '{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}'; sleep 5; } \
     | codex app-server 2>/dev/null | grep '"id":2'
   ```

   Read `result.rateLimits`: `primary.usedPercent` + `resetsAt` (epoch s) per window, and decisively `rateLimitReachedType` — non-null (`"rate_limit_reached"`) means new runs are REFUSED. Two traps proven live on 2026-08-18: (a) session rollout files freeze at the last successful run and refused runs write NO session file, so file-scraped numbers can't see a block — never trust them for "can I launch"; (b) `usedPercent: 100` alone ≠ blocked — enforcement lags the meter by minutes and in-flight sessions keep streaming after the door closes, so a running worker is not proof of headroom. `credits.balance > "0"` keeps a full window usable. The Overseer app now reads this same RPC live.

## Routing

| Work | Where |
|---|---|
| Orchestration, synthesis, conclusions | Main loop (sub 1) — never delegated |
| In-session subagents (Agent/Workflow tools) | Bill sub 1 — same sub as the main loop, and draw on the same 5h session window the main loop needs to keep working. Small/structured fan-out only; for vision fan-out see rule 3c. |
| Heavy Claude fan-out, design workers, planning workers | Whichever `~/.claude-*` slot has headroom (check usage.sh, route per-slot) |
| Web research, claim verification, second opinions | `~/.codex` (free w.r.t. Claude quota) |
| Overflow when Claude subs and Codex are all constrained | `~/.grok` (grok-4.6, free w.r.t. Claude/Codex quota; small shared weekly pool) |

## Common mistakes

| Mistake | Reality |
|---|---|
| `ant auth login --profile`, `ANTHROPIC_PROFILE`, `ANTHROPIC_API_KEY` for switching subs | Do not exist / wrong layer. Subscription auth = profile dir + `CLAUDE_CONFIG_DIR` env var. Nothing else. |
| Expecting Agent/Workflow subagents to use another sub | In-session subagents always bill the session's own sub. Only Bash-launched CLI workers with the env var spread load. |
| Launching a fleet on an unverified profile | Preflight first; "Not logged in" replies waste the whole wave. |
| Parallel editing workers sharing one cwd | They collide. One git worktree per editing worker. |
| Storing tokens/credentials in this skill or scripts | OAuth stays in profile dirs/Keychain. The orchestrator only ever knows the profile path. |
