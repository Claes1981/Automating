#!/usr/bin/env bash
# Usage: ./get_available_sizes.sh northeurope

# Constants
TIMEOUT_SECONDS=600
CURL_TIMEOUT_SECONDS=60
MAX_RESULTS=30

# Validate input
LOCATION="$1"
if [ -z "$LOCATION" ]; then
  echo "Usage: $0 <location>" >&2
  echo "Example: $0 northeurope" >&2
  exit 1
fi

# Fetch VM SKUs
fetch_vm_skus() {
  local location="$1"
  echo "Fetching VM SKUs for $location..." >&2
  
  VM_SKUS_JSON=$(timeout "$TIMEOUT_SECONDS" az vm list-skus \
    --location "$location" \
    --resource-type virtualMachines \
    --all \
    -o json 2>&1)
  
  if [ $? -ne 0 ]; then
    echo "ERROR: Failed to fetch VM SKUs" >&2
    echo "$VM_SKUS_JSON" >&2
    exit 1
  fi
  
  echo "$VM_SKUS_JSON" | jq -r "
    .[]
    | select(.locations[]? == \"$location\")
    | {
        name: .name,
        vcpus: (.capabilities[]? | select(.name==\"vCPUs\") | .value),
        memoryGb: (.capabilities[]? | select(.name==\"MemoryGB\") | .value)
      }
    | select(.vcpus != null and .memoryGb != null)
    | [.name, .vcpus, .memoryGb] | @tsv
  "
}

# Fetch pricing data
fetch_pricing_data() {
  local location="$1"
  echo "Fetching prices..." >&2
  
  # Build filter and URL
  local filter="serviceFamily eq 'Compute' and armRegionName eq '$location' and serviceName eq 'Virtual Machines'"
  local encoded_filter=$(echo "$filter" | sed "s/'/%27/g")
  local curl_url="https://prices.azure.com/api/retail/prices?filter=${encoded_filter}&top=1000"
  
  PRICE_JSON=$(timeout "$TIMEOUT_SECONDS" curl -s --max-time "$CURL_TIMEOUT_SECONDS" "$curl_url" 2>&1)
  
  if [ $? -ne 0 ]; then
    echo "WARNING: Failed to fetch price data" >&2
    return 1
  fi
  
  # Validate JSON response
  if ! echo "$PRICE_JSON" | jq -e '.Items' >/dev/null 2>&1; then
    echo "WARNING: Invalid price data response" >&2
    return 1
  fi
  
  # Extract price map
  echo "$PRICE_JSON" | jq -r '
    .Items[]
    | select(.armRegionName == "'$location'")
    | select(.type == "Consumption")
    | select(.armSkuName? != null and .armSkuName != "")
    | select(.armSkuName | startswith("Standard_"))
    | "\(.armSkuName)\t\(.unitPrice)"
  ' | sort -u
}

# Display results
display_results() {
  local vm_table="$1"
  local price_map="$2"
  
  echo -e "Name\tvCPUs\tRAM_GB\tHourly_USD\tMonthly_USD (730h)\n"
  
  echo "$vm_table" | while IFS=$'\t' read -r NAME VCPUS RAM_GB; do
    # Match VM name to armSkuName
    local match_sku=$(echo "$NAME" | sed 's/^Standard_//')
    local hourly
    
    if [ -n "$price_map" ]; then
      hourly=$(echo "$price_map" | awk -v sku="$NAME" -v msku="$match_sku" 'BEGIN{FS="\t"} 
        ($1==sku || $1==("Standard_" msku)) {print $2; exit}')
    fi
    
    if [ -z "$hourly" ] || [ "$hourly" = "null" ]; then
      hourly="N/A"
      monthly="N/A"
    else
      monthly=$(awk "BEGIN { printf \"%.2f\", $hourly*730 }")
    fi
    
    echo -e "$NAME\t$VCPUS\t$RAM_GB\t$hourly\t$monthly"
  done | head -"$MAX_RESULTS"
}

# Main execution
main() {
  VM_TABLE=$(fetch_vm_skus "$LOCATION")
  PRICE_MAP=$(fetch_pricing_data "$LOCATION" 2>&1)
  display_results "$VM_TABLE" "$PRICE_MAP"
}

main