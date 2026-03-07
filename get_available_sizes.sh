#!/usr/bin/env bash
# Usage: ./get_available_sizes.sh northeurope

# Constants
TIMEOUT_SECONDS=600
CURL_TIMEOUT_SECONDS=60
JQ_MIN_VERSION="0.7"
SKIP_PRICING=false

# Validate input
LOCATION="$1"
if [ -z "$LOCATION" ]; then
  echo "Usage: $0 <location>" >&2
  echo "Example: $0 northeurope" >&2
  exit 1
fi

check_jq_version() {
  if ! command -v jq &> /dev/null; then
    echo "ERROR: jq is not installed. Please install jq first." >&2
    exit 1
  fi
}

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

# Fetch VM SKUs to a temp file for later use
VM_SKUS_FILE=""

# Fetch VM SKUs
fetch_vm_skus() {
  local location="$1"
  echo "Fetching VM SKUs for $location..." >&2
  
  VM_SKUS_FILE="/tmp/vm_skus_${location}_$$"
  
  timeout "$TIMEOUT_SECONDS" az vm list-skus \
    --location "$location" \
    --resource-type virtualMachines \
    --all \
    -o json 2>&1 | tee "$VM_SKUS_FILE.full" > /dev/null
  
  if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo "ERROR: Failed to fetch VM SKUs" >&2
    exit 1
  fi
  
  # Extract VM SKUs to a simple list
  jq -r '
    .[]
    | select(.locations[]? == "'"$location"'")
    | .name
    | select((. | startswith("Standard_")) or (. | startswith("Basic_")))
  ' "$VM_SKUS_FILE.full" | sort -u > "$VM_SKUS_FILE"
  
  local sku_count=$(wc -l < "$VM_SKUS_FILE")
  echo "DEBUG: Found $sku_count VM SKUs for $location" >&2
  
  # Also create the full table for display
  jq -r "
    .[]
    | select(.locations[]? == \"$location\")
    | {
        name: .name,
        vcpus: (.capabilities[]? | select(.name==\"vCPUs\") | .value),
        memoryGb: (.capabilities[]? | select(.name==\"MemoryGB\") | .value)
      }
    | select(.vcpus != null and .memoryGb != null)
    | [.name, .vcpus, .memoryGb] | @tsv
  " "$VM_SKUS_FILE.full"
  
  rm -f "$VM_SKUS_FILE.full"
}

# Fetch pricing data for specific SKUs
fetch_pricing_data() {
  local location="$1"
  local skus_file="$2"
  echo "Fetching prices..." >&2
  
  # Build filter - just get Compute service family
  local filter="serviceFamily eq 'Compute'"
  
  # URL encode
  local encoded_filter=$(printf '%s' "$filter" | python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.stdin.read().strip()))" 2>/dev/null || printf '%s' "$filter" | sed 's/ /+/g')
  
  local curl_url="https://prices.azure.com/api/retail/prices?filter=$encoded_filter"
  local next_page="$curl_url"
  local page_count=0
  local total_items=0
  local max_pages=250
  
  # Use temp file to collect results
  local temp_file="/tmp/pricing_${location}_$$"
  > "$temp_file"
  
  echo "DEBUG: Starting pagination for location: $location" >&2
  
  # Fetch pages and filter on the fly
  while [ -n "$next_page" ] && [ "$next_page" != "null" ] && [ "$page_count" -lt "$max_pages" ]; do
    page_count=$((page_count + 1))
    echo "DEBUG: Fetching page $page_count..." >&2
    
    local page_json=$(timeout "$CURL_TIMEOUT_SECONDS" curl -s --max-time "$CURL_TIMEOUT_SECONDS" "$next_page" 2>&1)
    
    if [ $? -ne 0 ] || [ -z "$page_json" ]; then
      echo "WARNING: Failed to fetch page $page_count" >&2
      break
    fi
    
    # Validate JSON response
    if ! echo "$page_json" | jq -e '.Items' >/dev/null 2>&1; then
      echo "WARNING: Invalid price data response on page $page_count" >&2
      break
    fi
    
    # Process items - filter by region, Virtual Machines service, and Consumption type
    echo "$page_json" | jq -r --arg loc "$location" '
      .Items[]
      | select(.armRegionName? == $loc)
      | select(.serviceName? == "Virtual Machines")
      | select(.armSkuName? != null and .armSkuName != "")
      | select(.type == "Consumption")
      | [.armSkuName, (.unitPrice | tonumber)] | @tsv
    ' >> "$temp_file"
    
    # Count items from this page
    local page_items=$(echo "$page_json" | jq '.Items | length')
    total_items=$((total_items + page_items))
    local page_found=$(wc -l < "$temp_file")
    
    echo "DEBUG: Page $page_count: $page_items items, cumulative matches: $page_found" >&2
    
    # Get next page link
    next_page=$(echo "$page_json" | jq -r '.NextPageLink // empty')
  done
  
  echo "DEBUG: Fetched $total_items total items across $page_count pages" >&2
  
  # Sort unique and output
  sort -u "$temp_file"
  
  # Clean up
  rm -f "$temp_file"
}

# Display results
display_results() {
  local vm_file="$1"
  local price_file="$2"
  
  echo -e "Name\tvCPUs\tRAM_GB\tHourly_USD\tMonthly_USD (730h)\n"
  
  # Process VMs and match with prices, sort by price (cheapest first, N/A last)
  awk -F '\t' -v price_file="$price_file" '
    BEGIN { while ((getline < price_file) > 0) { split($0, parts, "\t"); price[parts[1]] = parts[2]; } }
    {
      name = $1;
      vcpus = $2;
      ram = $3;
      hourly = (name in price) ? price[name] : "N/A";
      monthly = (hourly != "N/A") ? sprintf("%.2f", hourly * 730) : "N/A";
      sort_key = (hourly != "N/A") ? hourly : 999999;
      print sort_key "\t" name "\t" vcpus "\t" ram "\t" hourly "\t" monthly;
    }' "$vm_file" | sort -t $'\t' -k1,1n | cut -f2-
}

# Main execution
main() {
  check_jq_version
  echo "DEBUG: Starting main execution with location=$LOCATION" >&2
  
  # Create temp files for data
  local vm_table_file="/tmp/vm_table_${LOCATION}_$$"
  local price_map_file="/tmp/price_map_${LOCATION}_$$"
  
  # Fetch VM SKUs to file
  fetch_vm_skus "$LOCATION" > "$vm_table_file"
  echo "DEBUG: About to call fetch_pricing_data" >&2
  
  # Fetch pricing data to file
  fetch_pricing_data "$LOCATION" "$VM_SKUS_FILE" > "$price_map_file"
  echo "DEBUG: PRICE_MAP line count: $(wc -l < "$price_map_file")" >&2
  
  # Display results using files
  display_results "$vm_table_file" "$price_map_file"
  
  # Cleanup
  rm -f "$VM_SKUS_FILE" "$vm_table_file" "$price_map_file"
}

main