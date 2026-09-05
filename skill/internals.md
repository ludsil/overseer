# Sub-fleet internals — how the facts were established (2026-08)

Provenance + re-verification recipes for upgrading this skill when vendors change things. All findings verified empirically against Claude Code CLI v2.1.231 and Codex CLI 0.147.0 on macOS.

## Credential storage (macOS)

- Default profile keychain item: service `Claude Code-credentials`.
- Custom `CLAUDE_CONFIG_DIR` profile: service `Claude Code-credentials-<first 8 hex of sha256 of the absolute dir path>`. Verify with `printf '%s' "$HOME/.claude-2" | shasum -a 256 | cut -c1-8` — the result matches the suffix of the item created by login.
- Item value is JSON: `{"claudeAiOauth": {"accessToken": ..., ...}}`.
- Linux/containers use `<config_dir>/.credentials.json` instead (per Anthropic docs).
- Re-verify after CLI major bumps: `security dump-keychain | grep -F 'Claude Code'` and compare against the sha256 derivation. If usage.sh starts failing at the keychain step, this scheme changed.

## Usage endpoint (what usage.sh depends on)

- `GET https://api.anthropic.com/api/oauth/usage` with headers `Authorization: Bearer <accessToken>` and `anthropic-beta: oauth-2025-04-20`. Same data as interactive `/usage`. Undocumented/internal — expect it can change without notice.
- Response: top-level `five_hour` / `seven_day` objects plus a `limits[]` array of `{kind: session|weekly_all|weekly_scoped, percent, severity: normal|warning|critical, resets_at, scope.model.display_name, is_active}`. usage.sh parses only `limits[]`. `is_active: true` marks the limit currently binding the account — the one that matters when deciding whether to launch.
- Failure modes seen: HTTP 401 = stale access token (any `claude -p` run on that profile refreshes it). If the schema shifts, curl it raw and adapt the parser.
- The beta header value may need bumping if Anthropic rotates the oauth beta version — check what the CLI sends (`strings` on the binary, or a proxy) or community tools (ccusage, claude-monitor ecosystem).

## Account identification per profile

- Claude: `<config_dir>/.claude.json` → `oauthAccount.emailAddress` / `organizationName` (for default profile the file is `~/.claude.json`).
- Codex: `$CODEX_HOME/auth.json` → decode the `tokens.id_token` JWT payload (base64url middle segment) → `email`, and plan under the `https://api.openai.com/auth` claim (`chatgpt_plan_type`).

## Isolation verification method

Fresh `CLAUDE_CONFIG_DIR` dir + `claude -p "Reply with exactly: OK" --model haiku` → `Not logged in · Please run /login` proves no credential leak from other profiles. A limit message (`You've hit your weekly limit`) proves routing reached the RIGHT account (quota state is per-account).

## Codex usage data (no endpoint, but local telemetry exists)

- Codex CLI writes a `rate_limits` block into session logs: `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl`, inside `event_msg` payloads of `"type":"token_count"`. Shape: `{limit_id, primary:{used_percent, window_minutes, resets_at(epoch)}, secondary, credits, plan_type}`. Tail-scan the newest files for the last occurrence.
- It is a SNAPSHOT from the last codex run, not live — always label it with its age.
- No usage endpoint equivalent as of 2026-08. If OpenAI ships subscription usage APIs, mirror usage.sh and update SKILL.md rule 5. Docs to watch: learn.chatgpt.com (auth, config reference, environment variables pages).
- Second Codex account requires `cli_auth_credentials_store = "file"` in that home's `config.toml` BEFORE login (OS keychain mode is shared across CODEX_HOME dirs).
- `codex --profile` selects config profiles, NOT accounts.

## Ecosystem context

Official vendor positions worth re-checking when things change: Anthropic documents `CLAUDE_CONFIG_DIR` with side-by-side accounts as an explicit use case ([Claude Code environment variables](https://code.claude.com/docs/en/env-vars)); native profile management is tracked in [claude-code issue #27359](https://github.com/anthropics/claude-code/issues/27359). OpenAI documents `CODEX_HOME` as the root for Codex configuration and auth state ([Codex environment variables](https://learn.chatgpt.com/docs/config-file/environment-variables)).

## run-on.sh

Why: Overseer's "Make active" rewrites each profile dir's `.claude.json` (`oauthAccount.
emailAddress`) and swaps the Keychain item — so dir→account is only valid at the instant
it is read. A dispatch built from a minutes-old reading can land on a session-capped
pool while a fresh sub idles; and because `claude -p` exits
0 on a limit refusal (the refusal is the stdout), the failure was invisible to exit-code
checks. run-on.sh therefore (1) resolves email→dir from the per-dir config at exec time,
re-verifies, and execs in the same process; (2) content-scans the worker output for
refusal signatures (<600 bytes AND limit/login regex, both apostrophe variants) → exit 42;
(3) never sets CLAUDE_CONFIG_DIR for the default dir (identity-fork hazard, 2026-08-16);
(4) @freshest picks lowest session %, ties by weekly_all, via the same OAuth usage
endpoint as usage.sh.

Verified: named-account resolution to the DEFAULT dir (env left unset, "OK");
refusal detection against a 100%-session sub (exit 42); @freshest picked the only fresh
sub and reported its live percentages. Re-verify after CLI upgrades by re-running those
three probes; the refusal regex is the piece most likely to rot if the CLI rewords its
limit messages.

## Codex stdin hang

`codex exec` launched from an agent harness's background Bash (stdin = open
non-TTY pipe) prints `Reading additional input from stdin...` and blocks
indefinitely before starting work. Reproduced live: a background worker sat
idle for minutes; its log's last line was exactly that string. Killing it and
relaunching the identical command with `< /dev/null` completed normally.
Same-session foreground runs and terminal runs (TTY stdin) never hit it —
which is why the recipe worked for weeks and then "randomly" hung: whether the
harness leaves the background-task stdin pipe open is not under our control.
Fix: unconditional `< /dev/null` in the recipe. Re-verify if codex ships a
`--no-stdin`/`--non-interactive` flag worth preferring.
