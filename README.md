# Overseer

Run several Claude Code, Codex, or Grok subscriptions? Overseer is a macOS menu-bar app
(plus a CLI and an agent skill) that shows how much capacity each account has left and
lets you switch which Claude account is active — so you, or your agents, know where the
headroom is before starting more work.

> **Authorship:** not a single line here was written by hand — code, docs, and commit
> messages are all AI-generated, with a human steering. It runs daily on the machines it
> was built for, but agents are agents: review before you trust, and PRs for fixes are
> very welcome.

```text
Claude · claude.one@example.com · team
  Session (5h)         51%  resets 05:50
  Weekly               54%  resets Sun 17:00
  Weekly · Fable      100%  resets Sun 17:00  ← binding
─────────────────────────────────────────────
Codex · you@example.com · plus
  Weekly (7d)          66%  resets Thu 09:34
```

## Quick start

> [!TIP]
> **The installer is an agent.** Clone the repo, open Claude Code in it, say the word —
> it builds the app, installs it, and adds the agent skill:
>
> ```sh
> git clone https://github.com/ludsil/overseer.git && cd overseer
> claude "set up overseer"
> ```

## Install

Doing it by hand instead of asking Claude:

```sh
brew install librsvg     # icon rendering; Apple Command Line Tools and macOS 13+ required
./install.sh             # build the app and install it to ~/Applications
./skill/install.sh       # optional: the agent skill, into ~/.claude/skills
```

Only want the app? The DMG on the Releases page needs no repo and no build: drag
Overseer into Applications and open it. Releases are not notarized, so macOS blocks the
first launch — approve it under **System Settings → Privacy & Security → Open Anyway**
(on macOS 14 and earlier, right-click → Open also works).

Either way, Overseer lives in the menu bar with **Launch at Login** in its menu, and you
add subscriptions inside the app: **Manage Claude accounts → Add account** creates the
profile directory and opens the login for it (logins run through the `claude` CLI you
already have). No configuration files.

**Updating:** Overseer does not update itself. Download the newest DMG and replace the
app, or for source installs run `git pull && ./install.sh`.

The dependency-free CLI collector needs no install: `./overseer.5m.py --text|--json`.

## Accounts and switching

One account = one config directory (`~/.claude`, `~/.claude-2`, …, and likewise
`~/.codex*`, `~/.grok*`). Overseer discovers them all automatically and shows one row per
account. The row on the default `~/.claude` profile is badged **ACTIVE** — that account
is what plain `claude` and every tool without `CLAUDE_CONFIG_DIR` bills.

**Make active** on any other row swaps that account's stored login with the default
profile's — a local Keychain exchange, instant and lossless; the outgoing login is parked
on the other slot. A browser login is only needed for a slot with no stored credential.
An expired row shows **Reconnect**, which renews the token silently. **Manage Claude
accounts** adds, replaces, or removes account directories; a row holding an account
already shown elsewhere is tagged `duplicate`, since it adds no quota of its own.

## Sharing usage keys

**Manage Claude accounts → Copy usage keys** bundles each account's *short-lived access
token* — never the rotating refresh token — into a blob you can hand to another machine or
person. **Import usage keys** installs it from the clipboard. Imported accounts work until
the token expires (about 8–12h), then re-import; because they carry no refresh token, an
imported copy can never renew or invalidate the sender's login.

Two forms, chosen by who receives them:

- **For another Overseer (encrypted)** — passphrase-protected; only Overseer's Import can
  open it, and you share the passphrase over a separate channel. The default choice.
- **As plain text (unsafe)** — readable by anything, for a recipient who doesn't run
  Overseer. Anyone who gets the blob can use those accounts until the tokens expire, so
  send it carefully.

Sharing your own subscriptions across your own machines is one thing; handing paid seats
to other people is generally against the provider's subscription terms. Today this covers
Claude; Codex and Grok are planned.

## The agent skill

`skill/` is the other half of the project: a Claude Code skill that teaches agents to
*use* the capacity Overseer shows — check live limits per account (`scripts/usage.sh`),
dispatch CLI workers onto a specific account (`scripts/run-on.sh`, with detection of
silently-refused runs), and follow fleet-sizing rules so one orchestrator can spread work
across every subscription without burning its own session. Install it with
`./skill/install.sh`; the spec is [skill/SKILL.md](skill/SKILL.md).

## Privacy

Overseer reads each Claude profile's OAuth token from that profile's macOS Keychain item
and talks only to the vendor that issued it: Anthropic's usage and profile endpoints, and
its token-refresh endpoint when a non-active account's token has expired. Codex usage
comes from a local `codex app-server` call (session-log snapshots as fallback) and Grok
state is read from local files. Credentials are never displayed, logged, or sent anywhere
else; there is no telemetry. Readings are cached in
`~/Library/Application Support/Overseer/Cache` (CLI: `~/.cache/overseer`). Note that the
usage endpoint is undocumented and may change without notice.

## Troubleshooting

A missing menu-bar icon is usually macOS parking the item behind the notch: reopen
Overseer from Finder to get a window instead, and run `./scripts/doctor.sh` to check and
repair install, placement, and autostart. Details in
[docs/menu-bar-visibility.md](docs/menu-bar-visibility.md).

## Layout

- `Sources/Overseer/` — the AppKit menu-bar app
- `overseer.5m.py` — standalone CLI collector (SwiftBar-compatible)
- `skill/` — the agent skill: usage checks, per-account dispatch, fleet rules
- `scripts/` — build, DMG, install, and doctor scripts
