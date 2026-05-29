#!/bin/bash
# Configure Hermes WeChat (微信) channel by writing WEIXIN_* env vars into
# ~/.openclaw/hermes/.env and restarting the gateway. Idempotent.
#
# Why this exists: hermes-agent's gateway/config.py hardcodes WeChat config to
# read from environment variables, NOT from openclaw.json. Writing channels into
# openclaw.json gets clobbered by the runtime snapshot on restart.
#
# Required env (optional override): HERMES_HOME (defaults to ~/.openclaw/hermes)
#
# Exit codes:
#   0 — success
#   1 — Hermes not installed
#   2 — no WeChat account registered yet (user must run `npx weixin-installer`)
#   3 — account JSON exists but is malformed
#   4 — gateway failed to start within 15s

set -u

: "${HERMES_HOME:=$HOME/.openclaw/hermes}"
ENV_FILE="$HERMES_HOME/.env"
LOG_FILE="$HERMES_HOME/logs/gateway.log"
PID_FILE="$HERMES_HOME/gateway.pid"
START_SH="$HERMES_HOME/start.sh"

if [ ! -d "$HERMES_HOME" ]; then
  echo "ERROR: $HERMES_HOME not found. Install Hermes first via byreal-hermes-deploy-native." >&2
  exit 1
fi

# Step 1 — locate the WeChat account JSON.
#
# Search order (confirmed against production pod):
#   1. ~/.openclaw/openclaw-weixin/accounts/  — canonical, written by `npx weixin-installer`
#   2. ~/.openclaw/hermes/weixin/accounts/    — fallback; usually only holds runtime
#                                                state (*.context-tokens.json, *.sync.json),
#                                                but a synced account file may live here.
#
# Runtime state files MUST be filtered out — they share the directory but lack
# the account schema, so picking one would fail parsing.
ACCOUNT_JSON=""
SEARCH_DIRS=(
  "$HOME/.openclaw/openclaw-weixin/accounts"
  "$HOME/.openclaw/hermes/weixin/accounts"
)

list_account_jsons() {
  # Lists *.json in $1, newest first, excluding *.context-tokens.json and *.sync.json.
  ls -1t "$1"/*.json 2>/dev/null \
    | grep -v '\.context-tokens\.json$' \
    | grep -v '\.sync\.json$' \
    || true
}

ACCOUNT_COUNT=0
for dir in "${SEARCH_DIRS[@]}"; do
  [ -d "$dir" ] || continue
  matches=$(list_account_jsons "$dir")
  [ -z "$matches" ] && continue
  ACCOUNT_JSON=$(echo "$matches" | head -1)
  ACCOUNT_COUNT=$(echo "$matches" | wc -l | tr -d ' ')
  echo "Found WeChat account JSON: $ACCOUNT_JSON"
  break
done

if [ -z "$ACCOUNT_JSON" ]; then
  cat >&2 <<EOF
ERROR: no WeChat account JSON found. Searched:
$(printf '  %s\n' "${SEARCH_DIRS[@]}")

The QR-code scan can't run from inside Hermes. SSH into the host once:

    ssh <hermes-host>
    npx weixin-installer

Scan with WeChat, finish registration, then re-run "连接微信".
EOF
  exit 2
fi

if [ "$ACCOUNT_COUNT" -gt 1 ]; then
  echo "WARNING: $ACCOUNT_COUNT account JSONs exist; using most recently modified ($ACCOUNT_JSON). Delete stale ones to silence this warning." >&2
fi

# Step 2 — extract token / account_id / base_url.
#
# Schema (confirmed): { "token": "...", "savedAt": "...", "baseUrl": "...", "userId": "..." }
#
# Important: account_id is NOT a field in the JSON. It comes from the *filename*
# (e.g. "519aede3165a-im-bot.json" → "519aede3165a-im-bot"). The JSON's `userId`
# is a WeChat user identifier (different concept) and must NOT be used here.
PARSED=$(python3 - "$ACCOUNT_JSON" <<'PYEOF'
import json, os, sys
path = sys.argv[1]
try:
    d = json.load(open(path))
except Exception as e:
    print(f"PARSE_ERROR: {e}", file=sys.stderr)
    sys.exit(3)
basename = os.path.basename(path)
acct = basename[:-5] if basename.endswith('.json') else basename
token = d.get('token') or d.get('access_token') or ''
base = d.get('baseUrl') or d.get('base_url') or 'https://ilinkai.weixin.qq.com'
if not token:
    print("MISSING_FIELDS: token missing in account JSON", file=sys.stderr)
    sys.exit(3)
if not acct:
    print("MISSING_FIELDS: cannot derive account_id from filename", file=sys.stderr)
    sys.exit(3)
# Tab-separated to survive any spaces / special chars.
print(f"{token}\t{acct}\t{base}")
PYEOF
) || {
  echo "ERROR: failed to parse $ACCOUNT_JSON" >&2
  exit 3
}

WEIXIN_TOKEN=$(echo "$PARSED" | cut -f1)
WEIXIN_ACCOUNT_ID=$(echo "$PARSED" | cut -f2)
WEIXIN_BASE_URL=$(echo "$PARSED" | cut -f3)

if [ -z "$WEIXIN_TOKEN" ] || [ -z "$WEIXIN_ACCOUNT_ID" ]; then
  echo "ERROR: empty token or account_id after parsing" >&2
  exit 3
fi

# Truncate token for display (first 6 + last 4).
TLEN=${#WEIXIN_TOKEN}
if [ "$TLEN" -gt 12 ]; then
  TOKEN_TRUNC="${WEIXIN_TOKEN:0:6}...${WEIXIN_TOKEN: -4}"
else
  TOKEN_TRUNC="<$TLEN-char-token>"
fi

# Step 3 — upsert WEIXIN_* into .env. Other lines (TELEGRAM_BOT_TOKEN etc.) are
# left intact. We use python so the value can contain shell metacharacters
# without sed/awk escape headaches.
[ -f "$ENV_FILE" ] || { touch "$ENV_FILE"; chmod 600 "$ENV_FILE"; }

ENV_FILE="$ENV_FILE" \
WEIXIN_TOKEN="$WEIXIN_TOKEN" \
WEIXIN_ACCOUNT_ID="$WEIXIN_ACCOUNT_ID" \
WEIXIN_BASE_URL="$WEIXIN_BASE_URL" \
python3 - <<'PYEOF'
import os
path = os.environ['ENV_FILE']
updates = {
    'WEIXIN_TOKEN': os.environ['WEIXIN_TOKEN'],
    'WEIXIN_ACCOUNT_ID': os.environ['WEIXIN_ACCOUNT_ID'],
    'WEIXIN_BASE_URL': os.environ['WEIXIN_BASE_URL'],
}
try:
    lines = open(path).read().splitlines()
except FileNotFoundError:
    lines = []
seen = set()
out = []
for line in lines:
    replaced = False
    for k, v in updates.items():
        if line.startswith(k + '='):
            out.append(f"{k}={v}")
            seen.add(k)
            replaced = True
            break
    if not replaced:
        out.append(line)
for k, v in updates.items():
    if k not in seen:
        out.append(f"{k}={v}")
open(path, 'w').write('\n'.join(out) + '\n')
PYEOF

chmod 600 "$ENV_FILE"
echo "WeChat config written to $ENV_FILE (token: $TOKEN_TRUNC, account: $WEIXIN_ACCOUNT_ID, base: $WEIXIN_BASE_URL)"

# Step 4 — restart gateway. Prefer systemd if there's a unit file; else PID-file
# kill + nohup start.sh.
RESTART_METHOD=""
if command -v systemctl >/dev/null 2>&1 && \
   systemctl list-unit-files 2>/dev/null | grep -q '^hermes-gateway\.service'; then
  RESTART_METHOD="systemctl"
  echo "Restarting gateway via systemctl..."
  systemctl restart hermes-gateway
else
  RESTART_METHOD="pidfile"
  if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
      kill "$PID"
      for _ in 1 2 3 4 5; do
        kill -0 "$PID" 2>/dev/null || break
        sleep 1
      done
      kill -0 "$PID" 2>/dev/null && kill -9 "$PID" 2>/dev/null
    fi
  fi
  if [ ! -x "$START_SH" ] && [ ! -f "$START_SH" ]; then
    echo "ERROR: $START_SH not found — cannot restart gateway" >&2
    exit 4
  fi
  nohup bash "$START_SH" >/dev/null 2>&1 & disown
  echo "Gateway restart launched (start.sh)"
fi

# Step 5 — verify gateway came up within 15s.
echo "Waiting for gateway to come up..."
ATTEMPT=0
while [ "$ATTEMPT" -lt 15 ]; do
  if pgrep -f 'hermes_cli.main' >/dev/null 2>&1; then
    break
  fi
  sleep 1
  ATTEMPT=$((ATTEMPT + 1))
done

if ! pgrep -f 'hermes_cli.main' >/dev/null 2>&1; then
  echo "ERROR: gateway did not start within 15s (method: $RESTART_METHOD). Last 30 log lines:" >&2
  [ -f "$LOG_FILE" ] && tail -30 "$LOG_FILE" >&2 || echo "(no log file at $LOG_FILE)" >&2
  exit 4
fi

# Best-effort: look for a WeChat-channel sign of life in the log. The gateway
# may take a few extra seconds to initialise channels after process start.
sleep 3
if [ -f "$LOG_FILE" ]; then
  if tail -200 "$LOG_FILE" | grep -qiE 'weixin|wechat'; then
    echo "WeChat channel mention found in gateway.log — looks connected"
  else
    echo "WARNING: gateway is up but no WeChat-channel log line yet. Last 10 log lines:" >&2
    tail -10 "$LOG_FILE" >&2
    echo "(if a WeChat message round-trip works in the next minute, ignore this warning)"
  fi
fi

echo "Done. Send a test message to the WeChat bot to verify end-to-end."
