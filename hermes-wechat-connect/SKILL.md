---
name: hermes-wechat-connect
description: Connect Hermes to a WeChat (微信) account so the same brain reachable on Telegram is also reachable on WeChat. Reads the openclaw-weixin account JSON, writes WEIXIN_TOKEN / WEIXIN_ACCOUNT_ID / WEIXIN_BASE_URL into the Hermes .env, and restarts the gateway. Idempotent. Use when the user says "连接微信", "我想用微信跟你聊", "connect WeChat", or asks to add a WeChat channel to Hermes.
version: 0.1.0
---

# Hermes WeChat Connect

## When to use

The user wants Hermes accessible via WeChat in addition to Telegram. Trigger phrases:

- "帮我连接微信" / "把微信也接上"
- "我想用微信跟你聊"
- "connect WeChat" / "add WeChat channel"

## When NOT to use

- **RealClaw main session** has its own WeChat path (channels in `openclaw.json`). Running this skill there does nothing useful — it would only configure Hermes's `.env`, and Hermes is the Telegram-side child. If the user is talking to RealClaw, redirect: ask them to chat with Hermes (or the install agent) and request WeChat there.
- If `~/.openclaw/hermes/` does not exist, Hermes isn't installed yet. Run `byreal-hermes-deploy-native` first.

## Background — why this skill exists

The hermes-agent gateway (`gateway/config.py` ~L1630) **hardcodes** the WeChat channel to read from environment variables, not from `openclaw.json`:

```
WEIXIN_TOKEN
WEIXIN_ACCOUNT_ID
WEIXIN_BASE_URL
```

Writing WeChat config into `openclaw.json` is a dead end — the gateway's runtime snapshot mechanism overwrites that file on restart, so any `channels.openclaw-weixin` entries get clobbered. The byreal-onboarding / openclaw-channel-management skills lead users down that path, which is why earlier attempts produced "暂无法连接 OpenClaw".

The fix is two lines: write three vars into `~/.openclaw/hermes/.env`, restart the gateway. This skill automates that, plus locates the existing account JSON and verifies the gateway came back up.

## Prereqs

- `~/.openclaw/hermes/` exists (Hermes installed via `byreal-hermes-deploy-native`).
- A WeChat account already registered via `npx weixin-installer`. **The QR-code scan is interactive and cannot run from inside Hermes** — if no account exists, this skill stops and tells the user to SSH in once and register.

## Flow

### Step 1 — Run the helper script

The work is in `references/configure-wechat.sh`. It is idempotent — safe to re-run after `npx weixin-installer`, after a token rotation, or after re-installing Hermes.

```bash
bash "$(dirname "$0")/references/configure-wechat.sh"
```

The script does everything in steps 2–5 below.

### Step 2 — Locate the account JSON (script does this)

Search order, first hit wins (most recently modified file picked when multiple):

1. `$HOME/.openclaw/openclaw-weixin/accounts/` — canonical, written by `npx weixin-installer`.
2. `$HOME/.openclaw/hermes/weixin/accounts/` — fallback. Usually only holds runtime state (`*.context-tokens.json`, `*.sync.json`); a synced account file may also live here.

The script filters out `*.context-tokens.json` and `*.sync.json` — those are gateway-managed runtime state, not account definitions, and would fail parsing.

If none found → exit code 2, print SSH-and-register instructions, stop. Tell the user verbatim:

> 微信的二维码扫描必须在主机上交互完成,Hermes 内部跑不了。你 SSH 上 Hermes 的服务器,跑 `npx weixin-installer`,扫码完成注册。然后再跟我说"连接微信"。

### Step 3 — Extract & write `.env` (script does this)

Account JSON schema (confirmed): `{ "token": "...", "savedAt": "...", "baseUrl": "...", "userId": "..." }`

Parse:
- `WEIXIN_TOKEN` ← `token` (fallback `access_token`)
- `WEIXIN_ACCOUNT_ID` ← **filename** stem (e.g. `519aede3165a-im-bot.json` → `519aede3165a-im-bot`). NOT a JSON field. The JSON's `userId` is a WeChat user identifier — different concept, do not substitute.
- `WEIXIN_BASE_URL` ← `baseUrl` (fallback `base_url`), default `https://ilinkai.weixin.qq.com`

Upsert each into `~/.openclaw/hermes/.env` (replace if line exists, append if not). File mode held at `0600`. **TG bot token in the same file is left untouched.**

### Step 4 — Restart gateway (script does this)

Prefer `systemctl restart hermes-gateway` if the unit file exists; else fall back to:

```
kill $(cat ~/.openclaw/hermes/gateway.pid)
nohup bash ~/.openclaw/hermes/start.sh >/dev/null 2>&1 & disown
```

### Step 5 — Verify (script does this)

- `pgrep -f hermes_cli.main` returns a PID within 15s.
- `tail -100 ~/.openclaw/hermes/logs/gateway.log` mentions `weixin` or `wechat` (best-effort — if absent, surface the last 10 log lines as a warning, but exit 0 since the gateway came up).

### Step 6 — Tell the user

Report (always truncate the token — first 6 + last 4):

> 微信已连上。账号 `<WEIXIN_ACCOUNT_ID>`,token `<519aed...3002>`。给微信 bot 发条消息试试,我会从同一个 SOUL 回。

If the script exited non-zero, surface the script's error message and the last 20 lines of `gateway.log` verbatim. Do NOT retry — the failure modes (no account JSON, malformed JSON, gateway didn't come up) are not transient.

## Safety

- `WEIXIN_TOKEN` is a secret. Display only the truncated form. **Never** write the full token to chat, MEMORY.md, `memory/`, daily logs, or commit messages.
- Don't touch `openclaw.json`. RealClaw owns it; the runtime snapshot will overwrite anything you put there.
- Don't touch the `TELEGRAM_BOT_TOKEN` line in `.env`. Upsert is keyed on the variable name — it only rewrites `WEIXIN_*`.
- `.env` mode stays `0600`. Re-chmod after every edit (the script does this).

## Co-existence with Telegram

Both channels share the same gateway process and the same SOUL.md / USER.md / wallets / memory. The user can talk to Hermes on either side; replies go back through whichever channel the inbound message came on. No additional config — once `.env` has both `TELEGRAM_BOT_TOKEN` and `WEIXIN_*`, the gateway brings up both pollers on startup.

## What this skill does NOT do

- **Register a new WeChat account.** That requires `npx weixin-installer` and a QR scan — must be done by a human SSH'd into the host. This skill only configures an already-registered account.
- **Pick between multiple accounts.** If `accounts/` has more than one JSON, the script picks the most recently modified and warns. Disambiguation: user deletes stale JSONs, or the user (not Hermes) manually edits `.env`.
- **Configure RealClaw main session WeChat.** Different mechanism, not in scope.
- **Disconnect WeChat.** Removing the channel = delete the three `WEIXIN_*` lines from `.env` and restart. Out of scope for v0.1.

## Update path

If the WeChat token rotates: re-run this skill. The upsert overwrites the existing line.

If `npx weixin-installer` produces a new account JSON next to an old one: re-run this skill — it picks the most recently modified.

If the gateway is moved (e.g. `HERMES_HOME` changes): export `HERMES_HOME=...` before invoking the script.
