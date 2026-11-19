#!/usr/bin/env bash
set -euo pipefail

ENV_FILE=".env"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/1pimp"
CONFIG_FILE="$CONFIG_DIR/config.json"

# 1. Basic validation
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

if [[ $# -eq 0 ]]; then
  AVAILABLE_KEYS=()
  available_count=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]]; then
      key="${BASH_REMATCH[1]}"
      if (( available_count == 0 )) || [[ " ${AVAILABLE_KEYS[*]} " != *" $key "* ]]; then
        AVAILABLE_KEYS+=("$key")
        ((available_count+=1))
      fi
    fi
  done < "$ENV_FILE"

  if (( available_count == 0 )); then
    echo "Error: No keys found in $ENV_FILE"
    exit 1
  fi

  if ! exec 3</dev/tty 4>/dev/tty; then
    echo "Error: Interactive key selection requires a terminal."
    exit 1
  fi

  cursor=0
  selected_count=0
  SELECTED=()
  render_keys() {
    for ((i=0; i<available_count; i++)); do
      if (( i == cursor )); then pointer=">"; else pointer=" "; fi
      if [[ "${SELECTED[$i]:-0}" == 1 ]]; then mark="x"; else mark=" "; fi
      printf '\r\033[2K %s [%s] %s\n' "$pointer" "$mark" "${AVAILABLE_KEYS[$i]}" >&4
    done
  }

  printf 'Select keys from %s (Up/Down: move, Space: toggle, Enter: continue):\n' "$ENV_FILE" >&4
  render_keys
  while true; do
    if ! IFS= read -rsn1 key <&3; then
      echo "Selection aborted." >&4
      exit 1
    fi
    case "$key" in
      $'\033')
        escape=""
        IFS= read -rsn2 -t 1 escape <&3 || true
        case "$escape" in
          '[A'|'OA') cursor=$(( (cursor + available_count - 1) % available_count )) ;;
          '[B'|'OB') cursor=$(( (cursor + 1) % available_count )) ;;
          *) continue ;;
        esac
        ;;
      ' ')
        if [[ "${SELECTED[$cursor]:-0}" == 1 ]]; then
          SELECTED[$cursor]=0
          selected_count=$((selected_count - 1))
        else
          SELECTED[$cursor]=1
          selected_count=$((selected_count + 1))
        fi
        ;;
      ''|$'\r')
        if (( selected_count > 0 )); then break; fi
        printf '\a' >&4
        continue
        ;;
      *) continue ;;
    esac
    printf '\033[%dA' "$available_count" >&4
    render_keys
  done
  exec 3<&- 4>&-

  SELECTED_KEYS=()
  for ((i=0; i<available_count; i++)); do
    if [[ "${SELECTED[$i]:-0}" == 1 ]]; then
      SELECTED_KEYS+=("${AVAILABLE_KEYS[$i]}")
    fi
  done
  set -- "${SELECTED_KEYS[@]}"
fi

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

# 3. Load last selected account and vault from config (if available)
LAST_ACCOUNT_ID=""
LAST_VAULT_ID=""
if [[ -f "$CONFIG_FILE" ]]; then
  LAST_ACCOUNT_ID=$(jq -r '.last_account_id // empty' "$CONFIG_FILE" 2>/dev/null || true)
  LAST_VAULT_ID=$(jq -r '.last_vault_id // empty' "$CONFIG_FILE" 2>/dev/null || true)
fi

# 4. Select an account before listing its vaults
ACCOUNTS_JSON=$(op account list --format=json)
ACCOUNT_COUNT=$(echo "$ACCOUNTS_JSON" | jq 'length')

if [[ "$ACCOUNT_COUNT" -eq 0 ]]; then
  echo "Error: No signed-in 1Password accounts found."
  exit 1
fi

if [[ "$ACCOUNT_COUNT" -gt 1 ]]; then
  DEFAULT_ACCOUNT_CHOICE=""
  echo ""
  echo "Select a 1Password account:"
  for ((i=0; i<ACCOUNT_COUNT; i++)); do
    a_id=$(echo "$ACCOUNTS_JSON" | jq -r ".[$i].account_uuid")
    a_email=$(echo "$ACCOUNTS_JSON" | jq -r ".[$i].email")
    a_url=$(echo "$ACCOUNTS_JSON" | jq -r ".[$i].url")
    num=$((i+1))

    if [[ "$a_id" == "$LAST_ACCOUNT_ID" ]]; then
      DEFAULT_ACCOUNT_CHOICE="$num"
      printf "  [%d] %s (%s) (default)\n" "$num" "$a_email" "$a_url"
    else
      printf "  [%d] %s (%s)\n" "$num" "$a_email" "$a_url"
    fi
  done

  echo ""
  if [[ -n "$DEFAULT_ACCOUNT_CHOICE" ]]; then
    read -rp "Account number (1-$ACCOUNT_COUNT) [$DEFAULT_ACCOUNT_CHOICE]: " account_choice
    account_choice="${account_choice:-$DEFAULT_ACCOUNT_CHOICE}"
  else
    read -rp "Account number (1-$ACCOUNT_COUNT): " account_choice
  fi

  if ! [[ "$account_choice" =~ ^[0-9]+$ ]] || (( account_choice < 1 || account_choice > ACCOUNT_COUNT )); then
    echo "Invalid selection. Aborted."
    exit 1
  fi
else
  account_choice=1
fi

ACCOUNT_ID=$(echo "$ACCOUNTS_JSON" | jq -r ".[$((account_choice-1))].account_uuid")

# 5. Fetch vaults for the selected account and prompt user to select one
echo "Fetching 1Password vaults..."
VAULTS_JSON=$(op vault list --account="$ACCOUNT_ID" --format=json)
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

# Save selected account and vault to ~/.config/1pimp/config.json
mkdir -p "$CONFIG_DIR"
if [[ -f "$CONFIG_FILE" ]] && jq empty "$CONFIG_FILE" 2>/dev/null; then
  TMP_CFG=$(mktemp)
  jq --arg account "$ACCOUNT_ID" --arg id "$VAULT_ID" --arg name "$VAULT_NAME" \
    '. + {last_account_id: $account, last_vault_id: $id, last_vault_name: $name}' "$CONFIG_FILE" > "$TMP_CFG"
  mv "$TMP_CFG" "$CONFIG_FILE"
else
  jq -n --arg account "$ACCOUNT_ID" --arg id "$VAULT_ID" --arg name "$VAULT_NAME" \
    '{last_account_id: $account, last_vault_id: $id, last_vault_name: $name}' > "$CONFIG_FILE"
fi

# Default item title to the current folder name
DEFAULT_TITLE=$(basename "$(pwd)")
read -rp "1Password item title [$DEFAULT_TITLE]: " ITEM_TITLE
ITEM_TITLE="${ITEM_TITLE:-$DEFAULT_TITLE}"

# 6. Build field assignments (KEY[password]=VALUE) and create the item
ASSIGNMENTS=()
for ((i=0; i<${#KEYS[@]}; i++)); do
  ASSIGNMENTS+=("${KEYS[$i]}[password]=${VALUES[$i]}")
done

echo "Creating item '$ITEM_TITLE' in vault '$VAULT_NAME'..."
op item create \
  --account="$ACCOUNT_ID" \
  --category="API Credential" \
  --vault="$VAULT_ID" \
  --title="$ITEM_TITLE" \
  "${ASSIGNMENTS[@]}" >/dev/null

# 7. Replace values in .env with op:// references safely via Python
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