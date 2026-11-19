#!/usr/bin/env bash
set -euo pipefail

ENV_FILE=".env"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/1pimp"
CONFIG_FILE="$CONFIG_DIR/config.json"

# 1. Basic validation
if [[ $# -eq 0 ]]; then
  echo "Usage: 1pimp KEY_ONE KEY_TWO ..."
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: No $ENV_FILE file found in $(pwd)"
  exit 1
fi

for cmd in op jq python3; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: '$cmd' is required but not installed."
    exit 1
  fi
done

# 2. Extract matching keys and values from .env safely
KEYS=()
VALUES=()

echo "Found in $ENV_FILE:"
echo "----------------------------------------"
for key in "$@"; do
  line=$(grep -E "^${key}=" "$ENV_FILE" | tail -n 1 || true)

  if [[ -z "$line" ]]; then
    echo "Error: Key '$key' not found in $ENV_FILE"
    exit 1
  fi

  raw_val="${line#*=}"
  raw_val="${raw_val%$'\r'}"
  if [[ "$raw_val" =~ ^\"(.*)\"$ ]]; then
    val="${BASH_REMATCH[1]}"
  elif [[ "$raw_val" =~ ^\'(.*)\'$ ]]; then
    val="${BASH_REMATCH[1]}"
  else
    val="$raw_val"
  fi

  if [[ "$val" == op://* ]]; then
    echo "Error: '$key' is already a 1Password reference ($val)"
    exit 1
  fi

  KEYS+=("$key")
  VALUES+=("$val")
  echo "  $key = $val"
done
echo "----------------------------------------"

# 3. Load last selected vault from config (if available)
LAST_VAULT_ID=""
if [[ -f "$CONFIG_FILE" ]]; then
  LAST_VAULT_ID=$(jq -r '.last_vault_id // empty' "$CONFIG_FILE" 2>/dev/null || true)
fi

# 4. Fetch vaults and prompt user to select one
echo "Fetching 1Password vaults..."
VAULTS_JSON=$(op vault list --format=json)
VAULT_COUNT=$(echo "$VAULTS_JSON" | jq 'length')

if [[ "$VAULT_COUNT" -eq 0 ]]; then
  echo "Error: No vaults found."
  exit 1
fi

DEFAULT_CHOICE=""
echo ""
echo "Select a vault:"
for ((i=0; i<VAULT_COUNT; i++)); do
  v_id=$(echo "$VAULTS_JSON" | jq -r ".[$i].id")
  v_name=$(echo "$VAULTS_JSON" | jq -r ".[$i].name")
  num=$((i+1))

  if [[ -n "$LAST_VAULT_ID" && "$v_id" == "$LAST_VAULT_ID" ]]; then
    DEFAULT_CHOICE="$num"
    printf "  [%d] %s (default)\n" "$num" "$v_name"
  else
    printf "  [%d] %s\n" "$num" "$v_name"
  fi
done

echo ""
if [[ -n "$DEFAULT_CHOICE" ]]; then
  read -rp "Vault number (1-$VAULT_COUNT) [$DEFAULT_CHOICE]: " choice
  choice="${choice:-$DEFAULT_CHOICE}"
else
  read -rp "Vault number (1-$VAULT_COUNT): " choice
fi

if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > VAULT_COUNT )); then
  echo "Invalid selection. Aborted."
  exit 1
fi

VAULT_NAME=$(echo "$VAULTS_JSON" | jq -r ".[$((choice-1))].name")
VAULT_ID=$(echo "$VAULTS_JSON" | jq -r ".[$((choice-1))].id")

# Save selected vault to ~/.config/1pimp/config.json (preserving any future settings)
mkdir -p "$CONFIG_DIR"
if [[ -f "$CONFIG_FILE" ]] && jq empty "$CONFIG_FILE" 2>/dev/null; then
  TMP_CFG=$(mktemp)
  jq --arg id "$VAULT_ID" --arg name "$VAULT_NAME" \
    '. + {last_vault_id: $id, last_vault_name: $name}' "$CONFIG_FILE" > "$TMP_CFG"
  mv "$TMP_CFG" "$CONFIG_FILE"
else
  jq -n --arg id "$VAULT_ID" --arg name "$VAULT_NAME" \
    '{last_vault_id: $id, last_vault_name: $name}' > "$CONFIG_FILE"
fi

# Default item title to the current folder name
DEFAULT_TITLE=$(basename "$(pwd)")
read -rp "1Password item title [$DEFAULT_TITLE]: " ITEM_TITLE
ITEM_TITLE="${ITEM_TITLE:-$DEFAULT_TITLE}"

# 5. Build field assignments (KEY[password]=VALUE) and create the item
ASSIGNMENTS=()
for ((i=0; i<${#KEYS[@]}; i++)); do
  ASSIGNMENTS+=("${KEYS[$i]}[password]=${VALUES[$i]}")
done

echo "Creating item '$ITEM_TITLE' in vault '$VAULT_NAME'..."
op item create \
  --category="API Credential" \
  --vault="$VAULT_ID" \
  --title="$ITEM_TITLE" \
  "${ASSIGNMENTS[@]}" >/dev/null

# 6. Replace values in .env with op:// references safely via Python
export KEYS_JOINED=$(IFS=,; echo "${KEYS[*]}")
export VAULT_NAME
export ITEM_TITLE
export ENV_FILE

python3 - <<'PY'
import os, re

env_file = os.environ["ENV_FILE"]
vault = os.environ["VAULT_NAME"]
item = os.environ["ITEM_TITLE"]
keys = set(os.environ["KEYS_JOINED"].split(","))

with open(env_file, "r", encoding="utf-8") as f:
    lines = f.readlines()

out = []
for line in lines:
    m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=", line)
    if m and m.group(1) in keys:
        k = m.group(1)
        out.append(f'{k}="op://{vault}/{item}/{k}"\n')
    else:
        out.append(line)

with open(env_file, "w", encoding="utf-8") as f:
    f.writelines(out)
PY

echo "Done! Updated $ENV_FILE with op:// references."