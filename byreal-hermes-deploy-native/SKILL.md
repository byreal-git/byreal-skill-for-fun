---
name: byreal-hermes-deploy-native
version: 0.1.0
description: "Deploy or sync the Hermes Telegram agent on top of RealClaw's built-in LLM API. Trigger on 'install hermes', 'deploy hermes', 'setup hermes', 'sync hermes', 'update hermes'."
---

# Skill: Hermes Deploy (Native API)

> Deploy Hermes on RealClaw's built-in LLM API. Only input is a new Telegram Bot Token.
>
> **Depends on**: AGENTS.md §Skill Supply Chain Security (review gate for this skill; `HERMES_AGENT_REF` should be a reviewed commit SHA before production use), §Security Red Lines.

## References

- `references/DEPLOY.md` — user-facing install guide and file layout.
- `references/soul-inject.sh` — appends the Hermes identity block to SOUL.md; shared by Install and Sync.

## Trigger

- Install: "install hermes", "deploy hermes", "setup hermes"
- Sync: "sync hermes", "update hermes"

## Inputs

One thing: a **new** Telegram Bot Token from @BotFather (`/newbot`). It must be a **different bot than the one RealClaw polls** — two pollers on the same bot break both. Tell the user this before asking.

The LLM API config is read from `~/.openclaw/openclaw.json`. No other input needed.

---

## Install Flow

### Step 1: Verify openclaw.json is readable

Do NOT re-type API keys. The agent masks/redacts sensitive values; config.yaml is written by Python in Step 4 so the key never passes through the agent or shell.

Must fail the flow on any missing field — silently continuing here leads to confusing errors in Step 4+.

```bash
python3 - << 'PYEOF' || { echo "ERROR: openclaw.json unreadable or missing fields — aborting."; exit 1; }
import json, os
with open(os.path.expanduser('~/.openclaw/openclaw.json')) as f:
    cfg = json.load(f)
p = cfg['models']['providers']['anthropic']
required = ['baseUrl', 'apiKey']
missing = [k for k in required if not p.get(k)]
if missing: raise SystemExit(f"missing fields in openclaw.json: {missing}")
if not p.get('models') or not p['models'][0].get('id'): raise SystemExit("no model id")
print('base_url:', p['baseUrl'])
print('api_mode:', p.get('api', 'anthropic-messages'))
print('model:', p['models'][0]['id'])
print('api_key:', p['apiKey'][:8] + '...')
PYEOF
```

### Step 2: System deps & paths

```bash
export HERMES_HOME="$HOME/.openclaw/hermes"
export PATH="$HERMES_HOME/bin:$PATH"

grep -q 'HERMES_HOME=' "$HOME/.bashrc" 2>/dev/null || \
  echo 'export HERMES_HOME="$HOME/.openclaw/hermes"' >> "$HOME/.bashrc"
grep -q '.openclaw/hermes/bin' "$HOME/.bashrc" 2>/dev/null || \
  echo 'export PATH="$HOME/.openclaw/hermes/bin:$PATH"' >> "$HOME/.bashrc"

# python3-venv — fail loudly if we can't install it.
if ! python3 -m venv --help >/dev/null 2>&1; then
  if [ "$(id -u)" = "0" ]; then apt-get install -y -qq python3-venv
  elif command -v sudo >/dev/null 2>&1; then sudo apt-get install -y -qq python3-venv
  else echo "ERROR: python3-venv missing and no root/sudo."; exit 1
  fi
fi

# uv — pinned version, verified against the release's .sha256 (no curl|sh).
# Keep the GitHub asset filename intact so `sha256sum -c` can match what's inside the .sha256 file.
UV_VERSION="0.5.11"
UV_TARGET="x86_64-unknown-linux-gnu"
UV_ASSET="uv-${UV_TARGET}.tar.gz"
if [ ! -x "$HERMES_HOME/bin/uv" ]; then
  mkdir -p "$HERMES_HOME/bin"
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  BASE="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}"
  curl -fsSL "${BASE}/${UV_ASSET}"        -o "$T/${UV_ASSET}"
  curl -fsSL "${BASE}/${UV_ASSET}.sha256" -o "$T/${UV_ASSET}.sha256"
  (cd "$T" && sha256sum -c "${UV_ASSET}.sha256") || { echo "ERROR: uv ${UV_VERSION} checksum failed — aborting."; exit 1; }
  tar -xzf "$T/${UV_ASSET}" -C "$T"
  install -m 0755 "$T/uv-${UV_TARGET}/uv"  "$HERMES_HOME/bin/uv"
  install -m 0755 "$T/uv-${UV_TARGET}/uvx" "$HERMES_HOME/bin/uvx" 2>/dev/null || true
  rm -rf "$T"; trap - EXIT
fi

mkdir -p "$HERMES_HOME"/{logs,skills,sessions,memory}

# Hermes writes PIDs to ~/.hermes/ regardless of HERMES_HOME → symlink.
[ -d "$HOME/.hermes" ] && [ ! -L "$HOME/.hermes" ] && rm -rf "$HOME/.hermes"
ln -sfn "$HERMES_HOME" "$HOME/.hermes"
```

### Step 3: Clone hermes-agent at a pinned ref

Bump `HERMES_AGENT_REF` to a reviewed commit SHA before shipping — a moving `main` is a supply-chain hole.

```bash
export HERMES_HOME="$HOME/.openclaw/hermes"
export PATH="$HERMES_HOME/bin:$PATH"

HERMES_AGENT_REF="main"  # TODO: pin to a reviewed commit SHA before production use
HERMES_AGENT_REPO="https://github.com/NousResearch/hermes-agent.git"

# Pin python-telegram-bot — supply-chain parity with uv and hermes-agent pins.
# Bump after reviewing the release notes. v21 is the current LTS.
PTB_VERSION="21.6"

if [ ! -d "$HERMES_HOME/hermes-agent/.git" ]; then
  git clone "$HERMES_AGENT_REPO" "$HERMES_HOME/hermes-agent"
fi
# Always refresh to the configured ref so bumping HERMES_AGENT_REF takes effect on re-run.
git -C "$HERMES_HOME/hermes-agent" fetch --quiet origin
git -C "$HERMES_HOME/hermes-agent" checkout --detach --quiet "$HERMES_AGENT_REF"
echo "hermes-agent at $(git -C "$HERMES_HOME/hermes-agent" rev-parse --short HEAD)"

cd "$HERMES_HOME/hermes-agent"
if ! "$HERMES_HOME/hermes-agent/venv/bin/python" -c "import sys" 2>/dev/null; then
  uv venv venv --python python3 2>&1 | tail -2
fi
uv pip install -e . --python venv/bin/python 2>&1 | tail -3
uv pip install "python-telegram-bot==${PTB_VERSION}" --python venv/bin/python 2>&1 | tail -2
```

### Step 4: Write .env and config.yaml

`.env` holds only the TG token. `config.yaml` is written by Python directly from `openclaw.json` so the API key never passes through the agent.

The agent must export `TG_TOKEN` from the user's input before running this block. An unquoted heredoc then expands it, and the script aborts if the token is empty so we can't silently ship a broken `.env`.

```bash
export HERMES_HOME="$HOME/.openclaw/hermes"

: "${TG_TOKEN:?TG_TOKEN is unset — set it from the user input before running this block}"
# Trim trailing whitespace / CR (pasted tokens often carry \r or spaces).
TG_TOKEN="${TG_TOKEN%"${TG_TOKEN##*[![:space:]]}"}"
TG_TOKEN="${TG_TOKEN#"${TG_TOKEN%%[![:space:]]*}"}"

# Unlink first: POSIX `cat >` truncates but keeps the old mode. A prior run that
# created .env at 0644 would stay 0644 even inside an `umask 077` subshell.
rm -f "$HERMES_HOME/.env"
( umask 077
  cat > "$HERMES_HOME/.env" << ENVEOF
TELEGRAM_BOT_TOKEN=${TG_TOKEN}
GATEWAY_ALLOW_ALL_USERS=true
ENVEOF
)
ln -sf "$HERMES_HOME/.env" "$HERMES_HOME/hermes-agent/.env"

python3 << 'PYEOF'
import json, os
home = os.path.expanduser("~/.openclaw/hermes")
with open(os.path.expanduser("~/.openclaw/openclaw.json")) as f:
    cfg = json.load(f)
p = cfg["models"]["providers"]["anthropic"]
base_url = p["baseUrl"].rstrip("/").removesuffix("/v1")
api_mode = p.get("api", "anthropic-messages").replace("-", "_")
model_id = p["models"][0]["id"]

# json.dumps yields a valid double-quoted YAML scalar for any string (handles :, #,
# leading/trailing whitespace, etc). Don't interpolate raw values into YAML.
def yq(s): return json.dumps(str(s))

cfg_path = os.path.join(home, "config.yaml")
# O_CREAT's mode arg is ignored if the file already exists → unlink first so a
# pre-existing 0644 from an older install doesn't carry over.
try: os.unlink(cfg_path)
except FileNotFoundError: pass
# Open with 0o600 from the start — no permission race window for the API key.
body = f"""home_dir: ~/.openclaw/hermes

model:
  default: {yq(model_id)}
  provider: realclaw

agent:
  reasoning_effort: ''

custom_providers:
  - name: realclaw
    base_url: {yq(base_url)}
    api_key: {yq(p["apiKey"])}
    api_mode: {yq(api_mode)}

gateway:
  host: 0.0.0.0
  port: 8765
"""
fd = os.open(cfg_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    f.write(body)
print(f"config.yaml: model={model_id} base_url={base_url}")
PYEOF
```

Config gotchas: strip trailing `/v1` from `base_url` (Hermes appends `/v1/messages`); `reasoning_effort: ''` (RealClaw proxy rejects thinking params); `api_mode` uses underscores (`anthropic_messages`). The proxy IP changes between nodes — always re-read from `openclaw.json`, never hardcode.

### Step 5: Share RealClaw's knowledge

```bash
export HERMES_HOME="$HOME/.openclaw/hermes"
REALCLAW_WS="$HOME/.openclaw/workspace"

for f in USER.md AGENTS.md TOOLS.md IDENTITY.md SOUL.md; do
  cp "$REALCLAW_WS/$f" "$HERMES_HOME/$f" 2>/dev/null || true
done

# Last 7 days of memory.
if [ -d "$REALCLAW_WS/memory" ]; then
  mkdir -p "$HERMES_HOME/memory"
  find "$REALCLAW_WS/memory" -name "*.md" -type f -mtime -7 -exec cp {} "$HERMES_HOME/memory/" \;
fi

# All skills except self-deploy and review gate. Reset first so re-runs don't
# accumulate stale skills that were removed upstream. nullglob prevents the loop
# from iterating over a literal "*/" when the skills dir is empty.
EXCLUDED="byreal-hermes-deploy-native byreal-skill-review"
rm -rf "$HERMES_HOME/skills"
mkdir -p "$HERMES_HOME/skills"
if [ -d "$REALCLAW_WS/skills" ]; then
  shopt -s nullglob
  for d in "$REALCLAW_WS/skills"/*/; do
    name=$(basename "$d"); skip=false
    for ex in $EXCLUDED; do [ "$name" = "$ex" ] && skip=true; done
    [ "$skip" = false ] && cp -r "$d" "$HERMES_HOME/skills/"
  done
  shopt -u nullglob
fi

# Populate USER.md with real wallet addresses if missing/template.
# Parses agent-token's JSON output — never regex-scrape base58 strings.
if [ ! -s "$HERMES_HOME/USER.md" ] || grep -qE '\{[a-z_]+\}' "$HERMES_HOME/USER.md" 2>/dev/null; then
  python3 << 'WALLETEOF'
import subprocess, json, os
home = os.path.expanduser("~/.openclaw/hermes")
wallets = {}
LABELS = {"solana": "Solana", "mantle": "EVM (Mantle)",
          "ethereum": "EVM (Ethereum)", "base": "EVM (Base)"}

def add(chain, addr):
    l = LABELS.get(str(chain).lower())
    if l and addr and l not in wallets: wallets[l] = addr

for p in ["~/.openclaw/skills/agent-token/scripts/agent-token.ts",
          "~/.openclaw/hermes/skills/agent-token/scripts/agent-token.ts",
          "~/.openclaw/workspace/skills/agent-token/scripts/agent-token.ts"]:
    script = os.path.expanduser(p)
    if not os.path.exists(script): continue
    try:
        r = subprocess.run(["bun", script, "wallet-info", "--json"],
                           capture_output=True, text=True, timeout=15,
                           env={**os.environ, "CLAUDE_SKILL_DIR": os.path.dirname(os.path.dirname(script))})
        data = json.loads(r.stdout)
    except Exception:
        continue
    if isinstance(data, dict) and isinstance(data.get("wallets"), list):
        for w in data["wallets"]:
            if isinstance(w, dict): add(w.get("chain"), w.get("address"))
    elif isinstance(data, dict):
        for k, v in data.items():
            if isinstance(v, str): add(k, v)
    if wallets: break

if "Solana" not in wallets:
    try:
        r = subprocess.run(["byreal-cli", "wallet", "address"], capture_output=True, text=True, timeout=10)
        a = (r.stdout or "").strip()
        if r.returncode == 0 and 32 <= len(a) <= 44 and not a.startswith("0x"):
            wallets["Solana"] = a
    except Exception: pass

if wallets:
    md = "# User Profile\n\n## Wallets (RealClaw Privy)\n\n| Network | Address |\n|---------|---------|\n"
    md += "".join(f"| {n} | {a} |\n" for n, a in wallets.items())
    md += "\n*RealClaw Privy server-side wallets — Hermes uses these for on-chain ops.*\n"
    open(os.path.join(home, "USER.md"), "w").write(md)
    print(f"USER.md: {len(wallets)} wallet(s) — {', '.join(wallets)}")
else:
    open(os.path.join(home, "USER.md"), "w").write(
        "# User Profile\n\nWallet addresses not configured. Ask the user.\n")
    print("WARNING: no wallets detected — Hermes will ask on first message")
WALLETEOF
fi

# Warn on empty/placeholder core files (not auto-fixed).
# TOOLS.md matters for Hermes to know chain addresses; without it, skills that
# reference token mints or program IDs will fail.
for f in SOUL.md AGENTS.md TOOLS.md; do
  if [ ! -s "$HERMES_HOME/$f" ] || grep -q "^placeholder$" "$HERMES_HOME/$f" 2>/dev/null; then
    echo "WARNING: $f empty/placeholder — run byreal-onboarding on RealClaw, then 'sync hermes'"
  fi
done
```

### Step 6: Inject Hermes identity into SOUL.md

Hermes reads only SOUL.md (not SYSTEM_PROMPT_INJECT.md), so the identity block is appended to SOUL.md by the shared script. Idempotent — skipped if the marker is already present.

```bash
export HERMES_HOME="$HOME/.openclaw/hermes"
bash "${CLAUDE_SKILL_DIR:-$HOME/.openclaw/workspace/skills/byreal-hermes-deploy-native}/references/soul-inject.sh"
```

### Step 7: Start the gateway

```bash
export HERMES_HOME="$HOME/.openclaw/hermes"
export PATH="$HERMES_HOME/bin:$PATH"

# Signal the old gateway and wait for it to actually exit so the new one can bind
# on :8765 without "address already in use". After 10s, SIGKILL and continue.
pkill -f "hermes_cli.main" 2>/dev/null || true
for i in $(seq 1 10); do
  pgrep -f "hermes_cli.main" >/dev/null 2>&1 || break
  sleep 1
done
pkill -9 -f "hermes_cli.main" 2>/dev/null || true
rm -f "$HERMES_HOME/gateway.pid" "$HOME/.hermes/gateway.pid" "$HERMES_HOME/gateway_state.json"

cat > "$HERMES_HOME/start.sh" << 'SCRIPTEOF'
#!/bin/bash
export HERMES_HOME="$HOME/.openclaw/hermes"
export PATH="$HERMES_HOME/bin:$PATH"
cd "$HERMES_HOME/hermes-agent"
exec "$HERMES_HOME/hermes-agent/venv/bin/python3" -m hermes_cli.main gateway >> "$HERMES_HOME/logs/gateway.log" 2>&1
SCRIPTEOF
chmod +x "$HERMES_HOME/start.sh"

# nohup + disown so the gateway survives the parent shell (container restart, SSH disconnect).
nohup bash "$HERMES_HOME/start.sh" >/dev/null 2>&1 & disown
sleep 6
tail -15 "$HERMES_HOME/logs/gateway.log"
```

### Log diagnostics

| Log says | Fix |
|---|---|
| `Connected to Telegram` + `Gateway running` | success |
| HTTP 404 | `base_url` still ends in `/v1` — strip and restart |
| HTTP 401 | API key rotated — re-read `openclaw.json` and update `config.yaml` |
| Connection refused | proxy IP changed — re-read `openclaw.json` |
| PID/lock error | `rm -f $HERMES_HOME/gateway.pid $HERMES_HOME/gateway_state.json` and retry |

### Post-deploy message to user

- Running on RealClaw's built-in API — no external API costs.
- Model: `<from config.yaml>`. Full knowledge shared: profile, wallets, safety rules, memory, all skills.
- Test: message the new bot on Telegram.
- After RealClaw restart: `nohup bash ~/.openclaw/hermes/start.sh >/dev/null 2>&1 & disown`
- To update knowledge: say "sync hermes".
- Logs: `tail -f ~/.openclaw/hermes/logs/gateway.log`

---

## Sync Flow

Re-copies core files + memory + skills, re-injects the SOUL identity block, and restarts Hermes.

```bash
export HERMES_HOME="$HOME/.openclaw/hermes"
REALCLAW_WS="$HOME/.openclaw/workspace"

# Gate on install presence — sync without a prior install leaves half-created state.
if [ ! -x "$HERMES_HOME/start.sh" ] || [ ! -f "$HERMES_HOME/config.yaml" ]; then
  echo "ERROR: Hermes is not installed at $HERMES_HOME — run 'install hermes' first."
  exit 1
fi

is_placeholder() {
  [ ! -s "$1" ] || grep -q "^placeholder$" "$1" 2>/dev/null
}

for f in USER.md AGENTS.md TOOLS.md IDENTITY.md; do
  if [ -f "$REALCLAW_WS/$f" ] && ! is_placeholder "$REALCLAW_WS/$f"; then
    cp "$REALCLAW_WS/$f" "$HERMES_HOME/$f"
  fi
done

if [ -f "$REALCLAW_WS/SOUL.md" ] && ! is_placeholder "$REALCLAW_WS/SOUL.md"; then
  cp "$REALCLAW_WS/SOUL.md" "$HERMES_HOME/SOUL.md"
  bash "${CLAUDE_SKILL_DIR:-$HOME/.openclaw/workspace/skills/byreal-hermes-deploy-native}/references/soul-inject.sh"
fi

if [ -d "$REALCLAW_WS/memory" ]; then
  mkdir -p "$HERMES_HOME/memory"
  find "$REALCLAW_WS/memory" -name "*.md" -type f -mtime -7 -exec cp {} "$HERMES_HOME/memory/" \;
fi

# Reset skills/ before copying so upstream removals propagate (sync is authoritative).
EXCLUDED="byreal-hermes-deploy-native byreal-skill-review"
rm -rf "$HERMES_HOME/skills"
mkdir -p "$HERMES_HOME/skills"
if [ -d "$REALCLAW_WS/skills" ]; then
  shopt -s nullglob
  for d in "$REALCLAW_WS/skills"/*/; do
    name=$(basename "$d"); skip=false
    for ex in $EXCLUDED; do [ "$name" = "$ex" ] && skip=true; done
    [ "$skip" = false ] && cp -r "$d" "$HERMES_HOME/skills/"
  done
  shopt -u nullglob
fi

# Wait for the old gateway to exit before restarting so port 8765 is free.
pkill -f "hermes_cli.main" 2>/dev/null || true
for i in $(seq 1 10); do
  pgrep -f "hermes_cli.main" >/dev/null 2>&1 || break
  sleep 1
done
pkill -9 -f "hermes_cli.main" 2>/dev/null || true
rm -f "$HERMES_HOME/gateway.pid" "$HERMES_HOME/gateway_state.json"
nohup bash "$HERMES_HOME/start.sh" >/dev/null 2>&1 & disown
sleep 6
tail -5 "$HERMES_HOME/logs/gateway.log"
echo "Hermes synced and restarted."
```
