#!/usr/bin/env bash
# Usage: ./vm-prices-final.sh northeurope
# Shows Linux VM prices (pay-as-you-go) for Ubuntu Server 24.04 LTS

LOCATION="$1"
if [ -z "$LOCATION" ]; then
  echo "Usage: $0 northeurope" >&2
  exit 1
fi

echo "Fetching VM SKUs for $LOCATION..." >&2
VM_SKUS_JSON=$(az vm list-skus \
  --location "$LOCATION" \
  --resource-type virtualMachines \
  --all \
  -o json)

# Extract VM table
VM_TABLE=$(echo "$VM_SKUS_JSON" | jq -r "
  .[]
  | select(.locations[]? == \"$LOCATION\")
  | {
      name: .name,
      vcpus: (.capabilities[]? | select(.name==\"vCPUs\") | .value),
      memoryGb: (.capabilities[]? | select(.name==\"MemoryGB\") | .value),
      tier: .tier
    }
  | select(.vcpus != null and .memoryGb != null)
  | \"\(.name)\t\(.vcpus)\t\(.memoryGb)\t\(.tier)\"
")

# URL-encoded filter for northeurope VMs
FILTER="serviceFamily eq 'Compute' and armRegionName eq '$LOCATION' and serviceName eq 'Virtual Machines'"
ENCODED_FILTER=$(echo "$FILTER" | sed "s/'/%27/g")

CURL_URL="https://prices.azure.com/api/retail/prices?\$filter=${ENCODED_FILTER}&\$top=1000"
echo "Fetching prices from: $CURL_URL" >&2

PRICE_JSON=$(curl -s "$CURL_URL")
PRICE_ITEMS=$(echo "$PRICE_JSON" | jq '.Items // []')

# CRITICAL: Fixed price map logic - prefer REGULAR Linux VMs (not Spot/Low Priority/Windows)
PRICE_MAP=$(echo "$PRICE_ITEMS" | jq -r '
  .[]
  | select(.armSkuName? != null and .armSkuName != "")
  | select(.type == "Consumption")                    # Pay-as-you-go only
  | select(.skuName? | contains("Spot") | not)         # Skip Spot VMs
  | select(.skuName? | contains("Low Priority") | not) # Skip Low Priority  
  | select(.productName? | contains("Windows") | not)  # Skip Windows VMs
  | select(.meterName? | test("^[A-Za-z0-9_-]+$"))     # Linux compute meter (like "D2s_v5", "B2s")
  | "\(.armSkuName)\t\(.unitPrice)"
' | sort -u)

echo -e "Name\tvCPUs\tRAM_GB\tTier\tHourly_USD\tMonthly_USD\n"

echo "$VM_TABLE" | while IFS=$'\t' read -r NAME VCPUS RAM_GB TIER; do
  HOURLY=$(echo "$PRICE_MAP" | awk -v sku="$NAME" 'BEGIN{FS="\t"} $1==sku {print $2; exit}')
  if [ -z "$HOURLY" ] || [ "$HOURLY" = "null" ] || [ "$HOURLY" = "0" ]; then
    HOURLY="N/A"
    MONTHLY="N/A"
  else
    MONTHLY=$(awk "BEGIN { printf \"%.2f\", $HOURLY*730 }")
  fi
  echo -e "$NAME\t$VCPUS\t$RAM_GB\t$TIER\t$HOURLY\t$MONTHLY"
done | head -30  # First 30 results
