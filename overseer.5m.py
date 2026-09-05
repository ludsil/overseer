#!/usr/bin/env python3
# <swiftbar.alwaysVisible>true</swiftbar.alwaysVisible>
"""Overseer - menu bar + CLI view of usage limits across every local Claude and Codex subscription.

Runs as a SwiftBar/xbar plugin (default) or a terminal report (--text / --json).
Profiles are discovered from ~/.claude*, ~/.codex* - no configuration needed.
"""

from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
OAUTH_BETA = "oauth-2025-04-20"
HOME = os.path.expanduser("~")

GREEN, YELLOW, RED, GRAY = "#16b06a", "#e0a03a", "#e0503a", "#8a8a8a"
DOTS = {"normal": "🟢", "warning": "🟡", "critical": "🔴", "unknown": "⚪️"}


def severity(percent: float | None) -> str:
    if percent is None:
        return "unknown"
    if percent >= 80:
        return "critical"
    if percent >= 50:
        return "warning"
    return "normal"


def color(sev: str) -> str:
    return {"normal": GREEN, "warning": YELLOW, "critical": RED}.get(sev, GRAY)


def when(ts: float | None) -> str:
    """Human reset time: HH:MM today, else weekday/date."""
    if not ts:
        return ""
    dt = datetime.fromtimestamp(ts)
    delta = ts - time.time()
    if delta < 0:
        return "now"
    if delta < 12 * 3600 and dt.day == datetime.now().day:
        return dt.strftime("%H:%M")
    if delta < 6 * 86400:
        return dt.strftime("%a %H:%M")
    return dt.strftime("%b %-d %H:%M")


def ago(ts: float | None) -> str:
    """Human age of a past observation."""
    if not ts:
        return ""
    delta = max(0, time.time() - ts)
    if delta < 90:
        return "just now"
    if delta < 3600:
        return f"{int(delta // 60)}m ago"
    if delta < 86400:
        return f"{int(delta // 3600)}h ago"
    return f"{int(delta // 86400)}d ago"


def keychain_service(config_dir: str) -> str:
    if os.path.realpath(config_dir) == os.path.realpath(os.path.join(HOME, ".claude")):
        return "Claude Code-credentials"
    digest = hashlib.sha256(config_dir.encode()).hexdigest()[:8]
    return f"Claude Code-credentials-{digest}"


def claude_credentials(config_dir: str) -> dict | None:
    """OAuth blob from the profile's Keychain item, or its file fallback."""
    try:
        raw = subprocess.run(
            ["security", "find-generic-password", "-s", keychain_service(config_dir), "-w"],
            capture_output=True, text=True, timeout=10,
        )
        if raw.returncode == 0:
            return json.loads(raw.stdout).get("claudeAiOauth")
    except Exception:
        pass
    path = os.path.join(config_dir, ".credentials.json")
    if os.path.exists(path):
        try:
            with open(path) as fh:
                return json.load(fh).get("claudeAiOauth")
        except Exception:
            return None
    return None


def claude_account(config_dir: str) -> dict:
    path = os.path.join(HOME, ".claude.json") if os.path.realpath(config_dir) == os.path.realpath(
        os.path.join(HOME, ".claude")) else os.path.join(config_dir, ".claude.json")
    try:
        with open(path) as fh:
            return json.load(fh).get("oauthAccount") or {}
    except Exception:
        return {}


def claude_profile(config_dir: str) -> dict:
    account = claude_account(config_dir)
    out = {
        "engine": "claude",
        "dir": config_dir,
        "name": os.path.basename(config_dir),
        "email": account.get("emailAddress"),
        "org": account.get("organizationName"),
        "limits": [],
        "error": None,
    }
    creds = claude_credentials(config_dir)
    if not creds:
        out["error"] = "not logged in"
        return out
    out["plan"] = creds.get("subscriptionType")
    expires = creds.get("expiresAt")
    if expires and expires / 1000 < time.time():
        out["error"] = "token expired"
        cache_load(out)
        return out

    req = urllib.request.Request(USAGE_URL, headers={
        "Authorization": f"Bearer {creds['accessToken']}",
        "anthropic-beta": OAUTH_BETA,
    })
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.load(resp)
    except urllib.error.HTTPError as err:
        out["error"] = "token stale" if err.code == 401 else f"HTTP {err.code}"
        cache_load(out)
        return out
    except Exception as err:
        out["error"] = f"{type(err).__name__}"
        cache_load(out)
        return out

    for entry in data.get("limits", []):
        model = ((entry.get("scope") or {}).get("model") or {}).get("display_name")
        label = {"session": "Session (5h)", "weekly_all": "Weekly"}.get(entry["kind"], entry["kind"])
        if model:
            label = f"Weekly · {model}"
        resets = entry.get("resets_at")
        out["limits"].append({
            "label": label,
            "percent": entry.get("percent"),
            "severity": entry.get("severity") or severity(entry.get("percent")),
            "resets": datetime.fromisoformat(resets).timestamp() if resets else None,
            "binding": bool(entry.get("is_active")),
        })
    cache_save(out)
    return out


def codex_account(home: str) -> dict:
    try:
        with open(os.path.join(home, "auth.json")) as fh:
            token = (json.load(fh).get("tokens") or {}).get("id_token")
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        import base64
        claims = json.loads(base64.urlsafe_b64decode(payload))
        return {
            "email": claims.get("email"),
            "plan": (claims.get("https://api.openai.com/auth") or {}).get("chatgpt_plan_type"),
        }
    except Exception:
        return {}


def codex_profile(home: str) -> dict:
    account = codex_account(home)
    out = {
        "engine": "codex",
        "dir": home,
        "name": os.path.basename(home),
        "email": account.get("email"),
        "plan": account.get("plan"),
        "limits": [],
        "error": None,
        "stale": True,
    }
    if not account:
        out["error"] = "not logged in"
        return out

    sessions = sorted(
        glob.glob(os.path.join(home, "sessions", "*", "*", "*", "*.jsonl")),
        key=os.path.getmtime, reverse=True,
    )
    for path in sessions[:8]:
        limits, observed = read_codex_limits(path)
        if limits:
            for key, label in (("primary", "Primary"), ("secondary", "Secondary")):
                window = limits.get(key)
                if not window:
                    continue
                minutes = window.get("window_minutes") or 0
                name = f"{label} ({minutes // 1440}d)" if minutes >= 1440 else f"{label} ({minutes // 60}h)"
                percent = window.get("used_percent")
                out["limits"].append({
                    "label": name,
                    "percent": round(percent) if percent is not None else None,
                    "severity": severity(percent),
                    "resets": window.get("resets_at"),
                })
            out["observed"] = observed
            return out
    out["error"] = "no usage seen yet - run codex once"
    return out


def read_codex_limits(path: str) -> tuple[dict | None, float | None]:
    """Last rate_limits block in a session log (tail-scanned)."""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            if size > 512_000:
                fh.seek(size - 512_000)
                fh.readline()
            lines = fh.read().decode("utf-8", "ignore").splitlines()
    except Exception:
        return None, None
    for line in reversed(lines):
        if '"rate_limits"' not in line:
            continue
        try:
            event = json.loads(line)
        except Exception:
            continue
        limits = (event.get("payload") or {}).get("rate_limits")
        if limits:
            stamp = event.get("timestamp")
            observed = None
            if stamp:
                try:
                    observed = datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()
                except Exception:
                    pass
            return limits, observed
    return None, None


def discover() -> list[dict]:
    profiles = []
    claude_dirs = [os.path.join(HOME, ".claude")] + sorted(glob.glob(os.path.join(HOME, ".claude-*")))
    for path in claude_dirs:
        if os.path.isdir(path) and not path.endswith((".json", ".backup")):
            profiles.append(claude_profile(path))
    for path in [os.path.join(HOME, ".codex")] + sorted(glob.glob(os.path.join(HOME, ".codex-*"))):
        if os.path.isdir(path):
            profiles.append(codex_profile(path))
    return profiles


CACHE_DIR = os.path.join(HOME, ".cache", "overseer")


def cache_path(profile_dir: str) -> str:
    return os.path.join(CACHE_DIR, hashlib.sha256(profile_dir.encode()).hexdigest()[:12] + ".json")


def cache_save(profile: dict) -> None:
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        with open(cache_path(profile["dir"]), "w") as fh:
            json.dump({"at": time.time(), "limits": profile["limits"]}, fh)
    except Exception:
        pass


def cache_load(profile: dict) -> None:
    """Fall back to the last good reading so an expired token still shows numbers."""
    try:
        with open(cache_path(profile["dir"])) as fh:
            blob = json.load(fh)
    except Exception:
        return
    if blob.get("limits"):
        profile["limits"] = blob["limits"]
        profile["observed"] = blob.get("at")


def menu_icon() -> str | None:
    """Base64 PNG for the menu bar, shipped next to this script."""
    root = os.path.dirname(os.path.realpath(__file__))
    paths = [
        os.path.join(root, "assets", "overseer-menu@2x.png"),
        os.path.join(root, ".overseer-menu@2x.png"),
    ]
    path = next((candidate for candidate in paths if os.path.exists(candidate)), None)
    if not path:
        return None
    import base64
    with open(path, "rb") as fh:
        return base64.b64encode(fh.read()).decode()


def worst(profile: dict) -> float | None:
    percents = [lim["percent"] for lim in profile["limits"] if lim["percent"] is not None]
    return max(percents) if percents else None


def label_of(profile: dict) -> str:
    email = profile.get("email") or ""
    local = email.split("@")[0] if email else profile["name"]
    return local[:9]


def render_swiftbar(profiles: list[dict]) -> None:
    tops, sev_rank = [], "normal"
    for profile in profiles:
        top = worst(profile)
        tops.append("--" if top is None else str(int(top)))
        sev = severity(top) if top is not None else "unknown"
        if ["normal", "unknown", "warning", "critical"].index(sev) > \
           ["normal", "unknown", "warning", "critical"].index(sev_rank):
            sev_rank = sev
    icon = menu_icon()
    if icon:
        summary = "·".join(tops)
        print(f'| templateImage={icon} tooltip="Overseer · {summary}"')
    else:
        print(f"{DOTS[sev_rank]} {'·'.join(tops)}")
    print("---")

    for profile in profiles:
        engine = "Claude" if profile["engine"] == "claude" else "Codex"
        who = profile.get("email") or profile["name"]
        plan = f" · {profile['plan']}" if profile.get("plan") else ""
        print(f"{engine} · {who}{plan} | font=Menlo size=12 color={GRAY}")
        if profile["error"]:
            print(f"  {profile['error']} | font=Menlo size=12 color={RED}")
        for lim in profile["limits"]:
            pct = "--" if lim["percent"] is None else f"{int(lim['percent']):3d}%"
            reset = when(lim["resets"])
            tail = f"  resets {reset}" if reset else ""
            if lim.get("binding"):
                tail += "  ← binding"
            print(f"  {lim['label']:<18} {pct}{tail} | font=Menlo size=12 color={color(lim['severity'])}")
        if profile.get("observed"):
            note = "last codex run" if profile["engine"] == "codex" else "cached"
            print(f"  {note} · {ago(profile['observed'])} | font=Menlo size=11 color={GRAY}")
        if profile["engine"] == "claude" and profile["error"]:
            cmd = (f"CLAUDE_CONFIG_DIR={profile['dir']} claude -p 'Reply with exactly: OK' --model haiku")
            print(f"  Refresh this profile | bash=/bin/bash param1=-lc param2=\"{cmd}\" "
                  f"terminal=false refresh=true font=Menlo size=11")
        print("---")

    print(f"Updated {datetime.now().strftime('%H:%M')} | font=Menlo size=11 color={GRAY}")
    print("Refresh | refresh=true")


def render_text(profiles: list[dict]) -> None:
    for profile in profiles:
        engine = "Claude" if profile["engine"] == "claude" else "Codex"
        who = profile.get("email") or profile["name"]
        plan = f" ({profile['plan']})" if profile.get("plan") else ""
        print(f"\n{engine} · {who}{plan}  [{profile['dir']}]")
        if profile["error"]:
            print(f"  ! {profile['error']}")
        for lim in profile["limits"]:
            pct = "--" if lim["percent"] is None else f"{int(lim['percent']):3d}%"
            reset = when(lim["resets"])
            mark = "  <- binding" if lim.get("binding") else ""
            print(f"  {lim['label']:<18} {pct}  {lim['severity']:<8} "
                  f"{'resets ' + reset if reset else ''}{mark}")
        if profile.get("observed"):
            note = "from last codex run" if profile["engine"] == "codex" else "cached values"
            print(f"  ({note}, {ago(profile['observed'])})")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--text", action="store_true", help="plain terminal report")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    args = parser.parse_args()

    profiles = discover()
    if args.json:
        json.dump(profiles, sys.stdout, indent=2)
        print()
    elif args.text:
        render_text(profiles)
    else:
        render_swiftbar(profiles)
    return 0


if __name__ == "__main__":
    sys.exit(main())
