#!/usr/bin/env bash
# Usage: ./vm-ubuntu-prices.sh westeurope
# Requires: az CLI, jq, curl

LOCATION="$1"
if [ -z "$LOCATION" ]; then
  echo "Usage: $0 <azure-region>  (e.g. westeurope, northeurope, francecentral)" >&2
  exit 1
fi

# 1. Get *virtualMachines* SKUs for the region, with capabilities
#    list-skus is global; we filter by location & resourceType.
echo "Fetching VM SKUs for region: $LOCATION ..." >&2
VM_SKUS_JSON=$(az vm list-skus \
  --location "$LOCATION" \
  --resource-type virtualMachines \
  --all \
  -o json)

# 2. Build a table of: Name, vCPUs, RAM_MB, Tier
VM_TABLE=$(echo "$VM_SKUS_JSON" | jq -r '
  .[]
  | select(.locations[]? == "'"$LOCATION"'")
  | {
      name: .name,
      tier: .tier,
      vcpus: (.capabilities[]? | select(.name=="vCPUs") | .value),
      memoryMb: (.capabilities[]? | select(.name=="MemoryGB") | (.value | (tonumber*1024)))
    }
  | select(.vcpus != null and .memoryMb != null)
  | "\(.name)\t\(.vcpus)\t\(.memoryMb)\t\(.tier)"
')

# 3. Query Retail Prices API for Linux/Ubuntu VMs in that region
#    Adjust filters if you want strictly Ubuntu, or include all Linux.
echo "Fetching retail prices for region: $LOCATION (Linux/Ubuntu) ..." >&2
BASE_URL="https://prices.azure.com/api/retail/prices"
FILTER="\$filter=serviceFamily eq 'Compute' and armRegionName eq '$LOCATION' and serviceName eq 'Virtual Machines' and osType eq 'Linux'"
PRICE_JSON=$(curl -s "${BASE_URL}?${FILTER}")

# 4. Map skuName -> hourly price (pay-as-you-go)
PRICE_MAP=$(echo "$PRICE_JSON" | jq -r '
  .Items[]
  | select(.unitPrice != null and .unitPrice > 0)
  | "\(.skuName)\t\(.unitPrice)"
')

# 5. Join SKUs with prices and compute ~monthly cost (730 hours)
echo -e "Name\tvCPUs\tRAM_GB\tTier\tHourly_USD\tMonthly_USD"

echo "$VM_TABLE" | while IFS=$'\t' read -r NAME VCPUS MEM_MB TIER; do
  HOURLY=$(echo "$PRICE_MAP" | awk -v sku="$NAME" 'BEGIN{FS="\t"} $1==sku {print $2; exit}')
  if [ -z "$HOURLY" ]; then
    HOURLY="N/A"
    MONTHLY="N/A"
  else
    MONTHLY=$(awk -v h="$HOURLY" 'BEGIN { printf "%.2f", h*730 }')
  fi
  RAM_GB=$(awk -v m="$MEM_MB" 'BEGIN { printf "%.1f", m/1024 }')
  echo -e "$NAME\t$VCPUS\t$RAM_GB\t$TIER\t$HOURLY\t$MONTHLY"
done
