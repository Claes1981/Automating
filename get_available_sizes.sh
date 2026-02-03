#!/usr/bin/env bash
# Usage: ./vm-ubuntu-prices.sh northeurope
# Requires: az, jq, curl

LOCATION="$1"
if [ -z "$LOCATION" ]; then
  echo "Usage: $0 <azure-region>  (e.g. northeurope, westeurope)" >&2
  exit 1
fi

echo "Fetching VM SKUs for region: $LOCATION ..." >&2
VM_SKUS_JSON=$(az vm list-skus \
  --location "$LOCATION" \
  --resource-type virtualMachines \
  --all \
  -o json)

# Name, armSkuName, vCPUs, MemoryGB, Tier
VM_TABLE=$(echo "$VM_SKUS_JSON" | jq -r '
  .[]
  | select(.locations[]? == "'"$LOCATION"'")
  | {
      name: .name,
      armSkuName: .name,   # for VMs this usually matches armSkuName in pricing API
      tier: .tier,
      vcpus: (.capabilities[]? | select(.name=="vCPUs") | .value),
      memoryGb: (.capabilities[]? | select(.name=="MemoryGB") | .value)
    }
  | select(.vcpus != null and .memoryGb != null)
  | "\(.name)\t\(.armSkuName)\t\(.vcpus)\t\(.memoryGb)\t\(.tier)"
')

echo "Fetching retail prices for region: $LOCATION (all VM meters) ..." >&2

BASE_URL="https://prices.azure.com/api/retail/prices"
# NOTE: we do NOT filter on osType here; we just take compute meters and ignore Windows-specific ones by name.
FILTER="\$filter=serviceFamily eq 'Compute' and armRegionName eq '$LOCATION' and serviceName eq 'Virtual Machines'"

PAGE_URL="${BASE_URL}?${FILTER}"
PRICE_ITEMS="[]"

# Simple pagination loop (Retail API is paged)
while [ -n "$PAGE_URL" ] && [ "$PAGE_URL" != "null" ]; do
  PAGE_JSON=$(curl -s "$PAGE_URL")
  PRICE_ITEMS=$(jq -s '.[0] + .[1].Items' <(echo "$PRICE_ITEMS") <(echo "$PAGE_JSON"))
  PAGE_URL=$(echo "$PAGE_JSON" | jq -r '.NextPageLink')
done

# Build a map: armSkuName -> hourly price
# Prefer: type == "Consumption", no "Spot" / "Low Priority", and productName not containing "Windows".
PRICE_MAP=$(echo "$PRICE_ITEMS" | jq -r '
  .[]
  | select(.unitPrice != null and .unitPrice > 0)
  | select(.type == "Consumption")
  | select((.skuName | contains("Spot") | not) and (.skuName | contains("Low Priority") | not))
  | select(.productName | contains("Windows") | not)
  | "\(.armSkuName)\t\(.unitPrice)"
')

echo -e "Name\tvCPUs\tRAM_GB\tTier\tHourly_USD\tMonthly_USD"

echo "$VM_TABLE" | while IFS=$'\t' read -r NAME ARMSKU VCPUS MEM_GB TIER; do
  HOURLY=$(echo "$PRICE_MAP" | awk -v sku="$ARMSKU" 'BEGIN{FS="\t"} $1==sku {print $2; exit}')
  if [ -z "$HOURLY" ]; then
    HOURLY="N/A"
    MONTHLY="N/A"
  else
    MONTHLY=$(awk -v h="$HOURLY" 'BEGIN { printf "%.2f", h*730 }')
  fi
  echo -e "$NAME\t$VCPUS\t$MEM_GB\t$TIER\t$HOURLY\t$MONTHLY"
done
