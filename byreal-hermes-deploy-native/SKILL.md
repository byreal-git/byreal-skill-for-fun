---
name: byreal-hermes-deploy-native
version: 0.2.3
description: "Deploy or sync the Hermes Telegram agent on top of RealClaw's built-in LLM API. Trigger on 'install hermes', 'deploy hermes', 'setup hermes', 'sync hermes', 'update hermes'."
---

# Skill: Hermes Deploy (Native API)

> Spawn a Hermes Telegram agent **on the same host as RealClaw**. Only input is a new Telegram Bot Token.
>
> RealClaw is the parent runtime; Hermes is its Telegram-side child. This skill clones RealClaw's brain — every skill, the full memory store, AGENTS.md, TOOLS.md, USER.md, SOUL.md, wallet access — into a hermes-agent runtime under `~/.openclaw/hermes/`, then attaches it to a new TG bot. Boot it and it's RealClaw with a Telegram surface; the SOUL.md identity block tells Hermes who it is and that RealClaw spawned it.
>
> **Depends on**: AGENTS.md §Skill Updates & Config Safety (this skill is review-gated; `HERMES_AGENT_REF` is pinned to a reviewed commit SHA — see Step 3, never use a moving ref), §Security Red Lines, §Wallet (address authority), §Secrets.

## References

- `references/DEPLOY.md` — user-facing install guide and file layout.
- `references/soul-inject.sh` — appends the Hermes identity block to SOUL.md; shared by Install and Sync.

## Trigger

- Install: "install hermes", "deploy hermes", "setup hermes"
- Sync: "sync hermes", "update hermes"

## Inputs

One thing: a **new** Telegram Bot Token from @BotFather (`/newbot`). It must be a **different bot than the one RealClaw polls** — two pollers on the same bot break both. Step 1 will hard-fail if the user accidentally pastes the same token.

The LLM API config is read from `~/.openclaw/openclaw.json`. No other input needed.

## What Hermes Inherits

Default: **everything that makes RealClaw RealClaw.** Same host, same wallet, same brain.

| File / dir | Copied? | Notes |
|---|---|---|
| `AGENTS.md`, `TOOLS.md`, `USER.md` | Yes | Same safety contract, tool routing, profile |
| `SOUL.md` | Yes (with appended identity block) | Style reference + Hermes name; idempotent |
| `MEMORY.md` | Yes | Long-term curated facts |
| `memory/*.md` | Yes (full history) | Per-day daily logs — no time window |
| `skills/*` | Yes (all but one) | Union of `~/.openclaw/workspace/skills/` (curated) and `~/.openclaw/skills/` (global pre-install — `agent-token` etc.). Workspace wins on name collision. |
| `BOOTSTRAP.md` | Yes if present | Almost always absent (auto-deletes after RealClaw onboards). If present, Hermes will see USER/SOUL already filled and skip onboarding. |
| `skills/byreal-hermes-deploy-native` | **No** | Recursion guard — Hermes shouldn't deploy itself |
| `BOOT.md` | **No** | CLI deps are global npm installs; Hermes doesn't run RealClaw's BOOT hook |
| `hooks/` | **No** | OpenClaw runtime hooks (skill-updater) belong to the RealClaw runtime, not Hermes |
| `configs/<strategy>/state.json` | **No** | Strategy state authority stays with RealClaw main session — see §Coexistence below |

### Coexistence with RealClaw main session

Both agents share the same wallet, AGENTS.md, and skills. The **only** state Hermes does NOT write is `configs/<strategy>/state.json` and the strategy crons that update it. Reason: two cron loops writing the same atomic state file race; whoever flushes second clobbers the other's snapshot. So:

- Read-only access to `configs/` is fine — Hermes can answer "how is my LP doing" by reading state.
- Hermes does not register strategy crons via `openclaw cron add`; main session owns the schedule.
- This rule is enforced by the appended SOUL.md identity block, not by withholding files.

---

## Install Flow

### Step 1: Verify openclaw.json + reject TG-token collision

Do NOT re-type API keys. The agent masks/redacts sensitive values; `config.yaml` is written by Python in Step 4 so the key never passes through the agent or shell.

This block also fails if the user's TG token equals RealClaw's TG token (double polling = both bots break).

```bash
: "${TG_TOKEN:?TG_TOKEN is unset — set it from the user input before running this block}"

python3 - << 'PYEOF' || { echo "ERROR: openclaw.json unreadable / fields missing / TG-token collision — aborting."; exit 1; }
import json, os
with open(os.path.expanduser('~/.openclaw/openclaw.json')) as f:
    cfg = json.load(f)

models = cfg.get('models', {})
providers = models.get('providers', {})
active = models.get('activeProvider') or models.get('default') or 'anthropic'
p = providers.get(active) or providers.get('anthropic')
if not p:
    raise SystemExit(f"no usable provider in openclaw.json (active={active}, available={list(providers)})")

required = ['baseUrl', 'apiKey']
missing = [k for k in required if not p.get(k)]
if missing: raise SystemExit(f"missing fields in openclaw.json: {missing}")
if not p.get('models') or not p['models'][0].get('id'):
    raise SystemExit("no model id")

rc_tg = (cfg.get('telegram') or {}).get('botToken') or os.environ.get('TELEGRAM_BOT_TOKEN', '')
user_tg = os.environ.get('TG_TOKEN', '').strip()
if rc_tg and user_tg and rc_tg.strip() == user_tg:
    raise SystemExit("TG_TOKEN collides with RealClaw's bot token — create a NEW bot via @BotFather")

print('provider :', active)
print('base_url :', p['baseUrl'])
print('api_mode :', p.get('api', 'anthropic-messages'))
print('model    :', p['models'][0]['id'])
print('api_key  :', p['apiKey'][:8] + '...')
PYEOF
```

### Step 2: System deps & paths

```bash
export HERMES_HOME="$HOME/.openclaw/hermes"
export PATH="$HERMES_HOME/bin:$PATH"

# python3-venv — fail loudly if we can't install it.
if ! python3 -m venv --help >/dev/null 2>&1; then
  if [ "$(id -u)" = "0" ]; then apt-get install -y -qq python3-venv
  elif command -v sudo >/dev/null 2>&1; then sudo apt-get install -y -qq python3-venv
  else echo "ERROR: python3-venv missing and no root/sudo."; exit 1
  fi
fi

# uv — pinned + checksum-verified.
UV_VERSION="0.5.11"
case "$(uname -m)" in
  x86_64|amd64) UV_TARGET="x86_64-unknown-linux-gnu" ;;
  aarch64|arm64) UV_TARGET="aarch64-unknown-linux-gnu" ;;
  *) echo "ERROR: unsupported arch $(uname -m) for uv ${UV_VERSION}"; exit 1 ;;
esac
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

`HERMES_AGENT_REF` is pinned to an immutable commit SHA. **Never replace it with a moving ref** (`main`, branch name, or even a tag — tags can be re-pointed by the upstream owner). To upgrade hermes-agent: review the upstream diff against the current SHA, get security sign-off, then update the constant to the new SHA.

The script `git fetch`-es origin so the pinned SHA can be checked out even if it's not on `main` anymore (e.g. force-push reorganises history). The post-checkout `rev-parse` echoes the resolved SHA; verify it matches the pinned constant.

```bash
export HERMES_HOME="$HOME/.openclaw/hermes"
export PATH="$HERMES_HOME/bin:$PATH"

# Pinned to NousResearch/hermes-agent tag v2026.5.29 (release commit "chore: release v0.15.1").
# Bump only after upstream diff review + security sign-off. Do NOT use a branch ref.
HERMES_AGENT_REF="e71a2bd11b733f3be7cf99deafde0066c343d462"
HERMES_AGENT_REPO="https://github.com/NousResearch/hermes-agent.git"

# Pin python-telegram-bot — supply-chain parity with uv and hermes-agent pins.
PTB_VERSION="21.6"

# Reject anything other than a 40-char hex SHA — defends against a future maintainer
# silently downgrading the pin to a branch/tag/short-SHA.
if ! [[ "$HERMES_AGENT_REF" =~ ^[0-9a-f]{40}$ ]]; then
  echo "ERROR: HERMES_AGENT_REF must be a full 40-char commit SHA, got: $HERMES_AGENT_REF" >&2
  exit 1
fi

if [ ! -d "$HERMES_HOME/hermes-agent/.git" ]; then
  git clone "$HERMES_AGENT_REPO" "$HERMES_HOME/hermes-agent"
fi
git -C "$HERMES_HOME/hermes-agent" fetch --quiet origin
git -C "$HERMES_HOME/hermes-agent" checkout --detach --quiet "$HERMES_AGENT_REF"

# Hard-assert checkout actually landed at the pinned SHA. Without this, a silent
# checkout failure would leave the previous (possibly stale or attacker-controlled)
# tree in place and only the echo would run.
ACTUAL_SHA=$(git -C "$HERMES_HOME/hermes-agent" rev-parse HEAD)
if [ "$ACTUAL_SHA" != "$HERMES_AGENT_REF" ]; then
  echo "ERROR: hermes-agent HEAD is $ACTUAL_SHA, expected $HERMES_AGENT_REF — refusing to continue" >&2
  exit 1
fi
echo "hermes-agent pinned at $ACTUAL_SHA"

cd "$HERMES_HOME/hermes-agent"
if ! "$HERMES_HOME/hermes-agent/venv/bin/python" -c "import sys" 2>/dev/null; then
  uv venv venv --python python3 2>&1 | tail -2
fi
uv pip install -e . --python venv/bin/python 2>&1 | tail -3
uv pip install "python-telegram-bot==${PTB_VERSION}" --python venv/bin/python 2>&1 | tail -2
```

### Step 4: Write .env and config.yaml

`.env` holds only the TG token. `config.yaml` is written by Python directly from `openclaw.json` so the API key never passes through the agent or shell.

```bash
export HERMES_HOME="$HOME/.openclaw/hermes"

: "${TG_TOKEN:?TG_TOKEN is unset — set it from the user input before running this block}"
TG_TOKEN="${TG_TOKEN%"${TG_TOKEN##*[![:space:]]}"}"
TG_TOKEN="${TG_TOKEN#"${TG_TOKEN%%[![:space:]]*}"}"

# Unlink first: `cat >` truncates but keeps the old mode. A prior run that
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

models = cfg.get("models", {})
providers = models.get("providers", {})
active = models.get("activeProvider") or models.get("default") or "anthropic"
p = providers.get(active) or providers.get("anthropic")
base_url = p["baseUrl"].rstrip("/").removesuffix("/v1")
api_mode = p.get("api", "anthropic-messages").replace("-", "_")
model_id = p["models"][0]["id"]

# json.dumps yields a valid double-quoted YAML scalar for any string.
def yq(s): return json.dumps(str(s))

cfg_path = os.path.join(home, "config.yaml")
try: os.unlink(cfg_path)
except FileNotFoundError: pass
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
print(f"config.yaml: provider={active} model={model_id} base_url={base_url}")
PYEOF
```

Config gotchas: strip trailing `/v1` from `base_url` (Hermes appends `/v1/messages`); `reasoning_effort: ''` (RealClaw proxy rejects thinking params); `api_mode` uses underscores (`anthropic_messages`). The proxy IP changes between nodes — always re-read from `openclaw.json`, never hardcode.

### Step 5: Share RealClaw's knowledge

```bash
export HERMES_HOME="$HOME/.openclaw/hermes"
REALCLAW_WS="$HOME/.openclaw/workspace"

# Copy core docs. IDENTITY.md was removed in 0.2.x. BOOT.md / hooks/ stay in the
# RealClaw workspace — Hermes is the agent runtime, not the OpenClaw runtime.
# BOOTSTRAP.md is copied if it still exists (almost always already deleted).
for f in USER.md AGENTS.md TOOLS.md SOUL.md MEMORY.md BOOTSTRAP.md; do
  cp "$REALCLAW_WS/$f" "$HERMES_HOME/$f" 2>/dev/null || true
done

# Full memory history — Hermes shares context with RealClaw on the same host.
if [ -d "$REALCLAW_WS/memory" ]; then
  mkdir -p "$HERMES_HOME/memory"
  cp -r "$REALCLAW_WS/memory/." "$HERMES_HOME/memory/"
fi

# Skills: full inheritance. Only exclude self-deploy to avoid recursion (Hermes
# deploying itself again). Onboarding / tier-switch / watchdog / skill-review all
# travel with Hermes — co-execution rules live in the SOUL.md identity block.
#
# Two source dirs to walk: the workspace skills repo and the global pre-install
# dir (~/.openclaw/skills/). RealClaw ships some skills (notably agent-token) at
# the global path, others under workspace; Hermes needs the union. Workspace
# wins on collisions because that's what skill-updater curates.
EXCLUDED="byreal-hermes-deploy-native"
GLOBAL_SKILLS_DIR="$HOME/.openclaw/skills"
rm -rf "$HERMES_HOME/skills"
mkdir -p "$HERMES_HOME/skills"

copy_skills_from() {
  local src="$1"
  [ -d "$src" ] || return 0
  shopt -s nullglob
  for d in "$src"/*/; do
    name=$(basename "$d")
    skip=false
    for ex in $EXCLUDED; do [ "$name" = "$ex" ] && skip=true; done
    [ "$skip" = false ] && [ ! -d "$HERMES_HOME/skills/$name" ] && cp -r "$d" "$HERMES_HOME/skills/"
  done
  shopt -u nullglob
}

# Workspace first (curated, skill-updater authoritative), then global (filling
# in agent-token and friends that ship pre-installed).
copy_skills_from "$REALCLAW_WS/skills"
copy_skills_from "$GLOBAL_SKILLS_DIR"

# Populate USER.md with real wallet addresses if missing/template.
# AGENTS.md §Wallet: agent-token wallet-info is the SOLE authoritative source.
# Do NOT fall back to byreal-cli or any other tool.
if [ ! -s "$HERMES_HOME/USER.md" ] || grep -qE '\{[a-z_]+\}' "$HERMES_HOME/USER.md" 2>/dev/null; then
  python3 << 'WALLETEOF'
import subprocess, json, os
home = os.path.expanduser("~/.openclaw/hermes")
wallets = {}
LABELS = {"solana": "Solana", "ethereum": "EVM (Mantle)"}  # TOOLS.md Chain Reference

def add(chain, addr):
    l = LABELS.get(str(chain).lower())
    if l and addr and l not in wallets: wallets[l] = addr

# RealClaw ships agent-token in two possible locations depending on pod build:
#   1. ~/.openclaw/skills/        — global pre-install (production default)
#   2. ~/.openclaw/workspace/skills/ — workspace-managed (BOOT.md §4 fallback)
#   3. ~/.openclaw/hermes/skills/  — already-mirrored copy from this skill
candidates = [
    "~/.openclaw/skills/agent-token/scripts/agent-token.ts",
    "~/.openclaw/workspace/skills/agent-token/scripts/agent-token.ts",
    "~/.openclaw/hermes/skills/agent-token/scripts/agent-token.ts",
]

for p in candidates:
    script = os.path.expanduser(p)
    if not os.path.exists(script): continue
    try:
        r = subprocess.run(
            ["bun", script, "wallet-info", "--json"],
            capture_output=True, text=True, timeout=15,
            env={**os.environ, "CLAUDE_SKILL_DIR": os.path.dirname(os.path.dirname(script))},
        )
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

if wallets:
    md = "# User Profile\n\n## Wallets (RealClaw Privy)\n\n| Network | Address |\n|---------|---------|\n"
    md += "".join(f"| {n} | {a} |\n" for n, a in wallets.items())
    md += "\n*RealClaw Privy server-side wallets — Hermes uses these for on-chain ops.*\n"
    md += "*Display rule (AGENTS.md §Wallet): always truncate addresses in chat; full copy via Console.*\n"
    open(os.path.join(home, "USER.md"), "w").write(md)
    print(f"USER.md: {len(wallets)} wallet(s) — {', '.join(wallets)}")
else:
    open(os.path.join(home, "USER.md"), "w").write(
        "# User Profile\n\nWallet addresses unavailable (agent-token wallet-info failed). "
        "Hermes will refuse on-chain ops until this is fixed; do NOT infer addresses by reasoning.\n")
    print("WARNING: agent-token wallet-info failed — Hermes will refuse on-chain ops")
WALLETEOF
fi

# Warn on empty/placeholder core files (not auto-fixed).
for f in SOUL.md AGENTS.md TOOLS.md; do
  if [ ! -s "$HERMES_HOME/$f" ] || grep -q "^placeholder$" "$HERMES_HOME/$f" 2>/dev/null; then
    echo "WARNING: $f empty/placeholder — run byreal-onboarding on RealClaw, then 'sync hermes'"
  fi
done
```

### Step 6: Inject Hermes identity into SOUL.md

Hermes reads only SOUL.md (not BOOTSTRAP.md), so the identity block is appended to SOUL.md by the shared script. Idempotent — skipped if the marker is already present.

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

nohup bash "$HERMES_HOME/start.sh" >/dev/null 2>&1 & disown
sleep 6
tail -15 "$HERMES_HOME/logs/gateway.log"
```

### Log diagnostics

| Log says | Fix |
|---|---|
| `Connected to Telegram` + `Gateway running` | success |
| HTTP 404 | `base_url` still ends in `/v1` — strip and restart |
| HTTP 401 (LLM) | API key rotated — run `sync hermes` to refresh `config.yaml` |
| HTTP 401 (aux service) | Expected — Hermes has no RealClaw session cookie. Use public APIs instead (CoinGecko / Jupiter / DexScreener) |
| Connection refused | proxy IP changed — run `sync hermes` |
| TG `Conflict: terminated by other getUpdates` | Two pollers on the same bot — confirm Hermes uses a different bot than RealClaw |
| PID/lock error | `rm -f $HERMES_HOME/gateway.pid $HERMES_HOME/gateway_state.json` and retry |

### Post-deploy message to user

- Running on RealClaw's built-in API — no external API costs.
- Model: `<from config.yaml>`. Knowledge shared: profile, wallets, safety rules, recent memory, operational skills.
- Test: message the new bot on Telegram.
- After RealClaw restart: `nohup bash ~/.openclaw/hermes/start.sh >/dev/null 2>&1 & disown`
- To refresh after RealClaw learns something / proxy rotates: say "sync hermes".
- Logs: `tail -f ~/.openclaw/hermes/logs/gateway.log`

---

## Sync Flow

Re-copies core files + memory + skills, **rewrites `config.yaml` from `openclaw.json`** (proxy IP / model / key may have rotated), re-injects the SOUL identity block, and restarts Hermes.

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

# 1. Refresh core docs (BOOT.md / hooks/ excluded by design — see install Step 5).
for f in USER.md AGENTS.md TOOLS.md MEMORY.md; do
  if [ -f "$REALCLAW_WS/$f" ] && ! is_placeholder "$REALCLAW_WS/$f"; then
    cp "$REALCLAW_WS/$f" "$HERMES_HOME/$f"
  fi
done

if [ -f "$REALCLAW_WS/SOUL.md" ] && ! is_placeholder "$REALCLAW_WS/SOUL.md"; then
  cp "$REALCLAW_WS/SOUL.md" "$HERMES_HOME/SOUL.md"
  bash "${CLAUDE_SKILL_DIR:-$HOME/.openclaw/workspace/skills/byreal-hermes-deploy-native}/references/soul-inject.sh"
fi

# 2. Full memory history (sync is authoritative — old per-day files removed upstream
#    are not auto-deleted in Hermes; rsync --delete would do it but we keep cp for
#    portability and let stale daily logs decay naturally).
if [ -d "$REALCLAW_WS/memory" ]; then
  mkdir -p "$HERMES_HOME/memory"
  cp -r "$REALCLAW_WS/memory/." "$HERMES_HOME/memory/"
fi

# 3. Skills: workspace + global pre-install dirs unioned (same as install).
EXCLUDED="byreal-hermes-deploy-native"
GLOBAL_SKILLS_DIR="$HOME/.openclaw/skills"
rm -rf "$HERMES_HOME/skills"
mkdir -p "$HERMES_HOME/skills"

copy_skills_from() {
  local src="$1"
  [ -d "$src" ] || return 0
  shopt -s nullglob
  for d in "$src"/*/; do
    name=$(basename "$d")
    skip=false
    for ex in $EXCLUDED; do [ "$name" = "$ex" ] && skip=true; done
    [ "$skip" = false ] && [ ! -d "$HERMES_HOME/skills/$name" ] && cp -r "$d" "$HERMES_HOME/skills/"
  done
  shopt -u nullglob
}

copy_skills_from "$REALCLAW_WS/skills"
copy_skills_from "$GLOBAL_SKILLS_DIR"

# 4. Rewrite config.yaml — proxy IP / model / key may have rotated since install.
python3 << 'PYEOF'
import json, os
home = os.path.expanduser("~/.openclaw/hermes")
with open(os.path.expanduser("~/.openclaw/openclaw.json")) as f:
    cfg = json.load(f)
models = cfg.get("models", {})
providers = models.get("providers", {})
active = models.get("activeProvider") or models.get("default") or "anthropic"
p = providers.get(active) or providers.get("anthropic")
base_url = p["baseUrl"].rstrip("/").removesuffix("/v1")
api_mode = p.get("api", "anthropic-messages").replace("-", "_")
model_id = p["models"][0]["id"]
def yq(s): return json.dumps(str(s))

cfg_path = os.path.join(home, "config.yaml")
try: os.unlink(cfg_path)
except FileNotFoundError: pass
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
print(f"config.yaml refreshed: provider={active} model={model_id} base_url={base_url}")
PYEOF

# 5. Restart gateway.
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
