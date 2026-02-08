#!/usr/bin/env bash
# Usage: ./get_available_sizes.sh northeurope

LOCATION="$1"
if [ -z "$LOCATION" ]; then
  echo "Usage: $0 northeurope" >&2
  exit 1
fi

echo "Fetching VM SKUs for $LOCATION..." >&2
VM_SKUS_JSON=$(timeout 300 az vm list-skus \
  --location "$LOCATION" \
  --resource-type virtualMachines \
  --all \
  -o json)

VM_TABLE=$(echo "$VM_SKUS_JSON" | jq -r "
  .[]
  | select(.locations[]? == \"$LOCATION\")
  | {
      name: .name,
      vcpus: (.capabilities[]? | select(.name==\"vCPUs\") | .value),
      memoryGb: (.capabilities[]? | select(.name==\"MemoryGB\") | .value)
    }
  | select(.vcpus != null and .memoryGb != null)
  | \"\(.name)\t\(.vcpus)\t\(.memoryGb)\"
")

# Fixed URL encoding + fetch
FILTER="serviceFamily eq 'Compute' and armRegionName eq '$LOCATION' and serviceName eq 'Virtual Machines'"
ENCODED_FILTER=$(echo "$FILTER" | sed "s/'/%27/g")
CURL_URL="https://prices.azure.com/api/retail/prices?$filter=${ENCODED_FILTER}&$top=1000"

echo "Fetching prices..." >&2
PRICE_JSON=$(timeout 300 curl -s --max-time 60 "$CURL_URL")

# DEBUG: Show what we're working with
echo "$PRICE_JSON" | jq -r '.Items[] | select(.armRegionName == "'$LOCATION'") | "\(.armSkuName)\t\(.unitPrice)\t\(.productName)"' | head -5 >&2

# Check if we got valid JSON
if ! echo "$PRICE_JSON" | jq -e '.Items' >/dev/null 2>&1; then
  echo "ERROR: Failed to fetch price data or invalid response" >&2
  exit 1
fi

# SIMPLIFIED filter: ANY Consumption VM in region (we'll clean up later)
PRICE_MAP=$(echo "$PRICE_JSON" | jq -r '
  .Items[]
  | select(.armRegionName == "'$LOCATION'")
  | select(.type == "Consumption")
  | select(.armSkuName? != null and .armSkuName != "")
  | select(.armSkuName | startswith("Standard_"))
  | "\(.armSkuName)\t\(.unitPrice)"
' | sort -u)

echo -e "Name\tvCPUs\tRAM_GB\tHourly_USD\tMonthly_USD (730h)\n"

echo "$VM_TABLE" | while IFS=$'\t' read -r NAME VCPUS RAM_GB; do
  # Match VM name to armSkuName (strip "Standard_" prefix if needed)
  MATCH_SKU=$(echo "$NAME" | sed 's/^Standard_//')
  HOURLY=$(echo "$PRICE_MAP" | awk -v sku="$NAME" -v msku="$MATCH_SKU" 'BEGIN{FS="\t"} 
    ($1==sku || $1==("Standard_" msku)) {print $2; exit}')
  
  if [ -z "$HOURLY" ] || [ "$HOURLY" = "null" ]; then
    HOURLY="N/A"
    MONTHLY="N/A"
  else
    MONTHLY=$(awk "BEGIN { printf \"%.2f\", $HOURLY*730 }")
  fi
  echo -e "$NAME\t$VCPUS\t$RAM_GB\t$HOURLY\t$MONTHLY"
done | head -30
