# === Get all storages that support template content ===
echo "🔍 Searching for storage with $TEMPLATE_NAME_PREFIX template..."
VALID_STORES=($(pvesm status --enabled 1 | awk '/vztmpl/ {print $1}'))

TEMPLATE_STORE=""
TEMPLATE_FILE=""

for store in "${VALID_STORES[@]}"; do
  CACHE_PATH="/mnt/pve/${store}/template/cache"
  FILE=$(find "$CACHE_PATH" -type f -name "$TEMPLATE_GLOB" 2>/dev/null | sort -rV | head -n 1)
  if [ -n "$FILE" ]; then
    TEMPLATE_STORE="$store"
    TEMPLATE_FILE="$FILE"
    break
  fi
done

# === If not found, download to the first available store ===
if [ -z "$TEMPLATE_FILE" ]; then
  echo "📦 No template found. Downloading into ${VALID_STORES[0]}..."
  pveam update
  pveam available | grep "$TEMPLATE_NAME_PREFIX" | sort -rV | head -n 1 | awk '{print $1}' | xargs -I {} pveam download "${VALID_STORES[0]}" {}
  TEMPLATE_STORE="${VALID_STORES[0]}"
  CACHE_PATH="/mnt/pve/${TEMPLATE_STORE}/template/cache"
  TEMPLATE_FILE=$(find "$CACHE_PATH" -type f -name "$TEMPLATE_GLOB" | sort -rV | head -n 1)
fi

# === Confirm result ===
if [ -z "$TEMPLATE_FILE" ]; then
  echo "❌ Failed to locate or download template."
  exit 1
fi

TEMPLATE_BASENAME=$(basename "$TEMPLATE_FILE")
echo "💾 Using template: $TEMPLATE_BASENAME from $TEMPLATE_STORE"
