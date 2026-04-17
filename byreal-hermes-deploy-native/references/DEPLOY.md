# Hermes on RealClaw (Native API)

Uses RealClaw's built-in LLM API. No external API key needed.

## You only need ONE thing

**A new Telegram Bot Token** (not the one RealClaw uses):

1. Open Telegram, search for `@BotFather`
2. Send `/newbot`
3. Name it something like "MyHermes"
4. Copy the token

## Install

In your RealClaw chat, say:

> Install Hermes

The agent will:
1. Ask for your new TG Bot Token
2. Auto-read RealClaw's API config
3. Install and start Hermes
4. **Share RealClaw's knowledge with Hermes** (profile, safety rules, memory, skills)
5. Your RealClaw bot is unaffected

## What Hermes Gets

| From RealClaw | What's shared |
|---|---|
| USER.md | User identity, wallets, risk profile, preferences |
| SOUL.md | Communication style + Hermes identity block appended |
| AGENTS.md | Safety rules, red lines |
| TOOLS.md | Tool capabilities, chain reference |
| memory/ | Last 7 days of context |
| skills/ | All skills (swap, LP, DCA, yield farming, etc.) |

**Hermes uses RealClaw's Privy wallet** for on-chain operations — same capabilities as RealClaw.

## After RealClaw Restart

```bash
nohup bash ~/.openclaw/hermes/start.sh >/dev/null 2>&1 & disown
```

## Sync Knowledge

When RealClaw learns something new, tell it:

> sync hermes

This pushes the latest files to Hermes and restarts it.

## Verify

```bash
# Check Hermes is running
pgrep -f hermes_cli.main

# Check Telegram connected
tail -5 ~/.openclaw/hermes/logs/gateway.log

# Check knowledge files
ls ~/.openclaw/hermes/*.md
```

## File Layout

```
~/.openclaw/hermes/
  .env                    # TG Bot Token only
  config.yaml             # Points to RealClaw's internal API proxy
  start.sh                # Startup script
  SOUL.md                 # From RealClaw (style) + Hermes identity block appended
  USER.md                 # From RealClaw (profile + wallets)
  AGENTS.md               # From RealClaw (safety rules)
  TOOLS.md                # From RealClaw (tool reference)
  gateway.pid
  logs/gateway.log
  memory/                 # Last 7 days of RealClaw memory
  skills/                 # All RealClaw skills (except self-deploy & skill-review)
  hermes-agent/
    .env -> ../.env
    venv/
~/.hermes -> ~/.openclaw/hermes/
```
