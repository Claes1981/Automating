#!/usr/bin/env bash
set -euo pipefail

################################################################################
# Azure VM Pricing Script
# Displays available VM sizes with pricing for a given Azure region
################################################################################

readonly SCRIPT_NAME="$(basename "$0")"
readonly AZURE_CLI_TIMEOUT=600
readonly API_TIMEOUT=60
readonly MAX_API_PAGES=250
readonly HOURS_PER_MONTH=730

declare -a TEMP_FILES=()

usage() {
  cat >&2 <<EOF
Usage: $SCRIPT_NAME <location>

Displays available Azure VM sizes with pricing for the specified region.

Arguments:
  location    Azure region (e.g., northeurope, eastus, westeurope)

Examples:
  $SCRIPT_NAME northeurope
  $SCRIPT_NAME eastus
EOF
}

log_info() {
  echo "$*" >&2
}

log_error() {
  echo "ERROR: $*" >&2
}

log_debug() {
  if [[ "${DEBUG:-}" == "true" ]]; then
    echo "DEBUG: $*" >&2
  fi
}

cleanup() {
  log_debug "Cleaning up temporary files..."
  for file in "${TEMP_FILES[@]}"; do
    rm -f "$file" 2>/dev/null || true
  done
}

trap cleanup EXIT

check_dependencies() {
  local deps=("jq" "curl" "az")
  for dep in "${deps[@]}"; do
    if ! command -v "$dep" &> /dev/null; then
      log_error "$dep is not installed or not in PATH"
      exit 1
    fi
  done
}

create_temp_file() {
  local prefix="${1:-tmp}"
  local temp_file
  temp_file=$(mktemp "/tmp/${prefix}_XXXXXX")
  TEMP_FILES+=("$temp_file")
  echo "$temp_file"
}

fetch_vm_skus() {
  local location="$1"
  local output_file="$2"
  
  log_info "Fetching VM SKUs for $location..."
  
  local sku_json_file
  sku_json_file=$(create_temp_file "skus_json")
  
  if ! timeout "$AZURE_CLI_TIMEOUT" az vm list-skus \
      --location "$location" \
      --resource-type virtualMachines \
      --all \
      -o json > "$sku_json_file" 2>&1; then
    log_error "Failed to fetch VM SKUs from Azure CLI"
    cat "$sku_json_file" >&2
    return 1
  fi
  
  jq -r --arg loc "$location" '
    .[]
    | select(.locations[]? == $loc)
    | select(.name | startswith("Standard_") or startswith("Basic_"))
    | {
        name: .name,
        vcpus: (.capabilities[]? | select(.name == "vCPUs") | .value),
        memoryGb: (.capabilities[]? | select(.name == "MemoryGB") | .value)
      }
    | select(.vcpus != null and .memoryGb != null)
    | [.name, .vcpus, .memoryGb] | @tsv
  ' "$sku_json_file" > "$output_file"
  
  local sku_count
  sku_count=$(wc -l < "$output_file")
  log_info "Found $sku_count VM SKUs for $location"
}

fetch_pricing_data() {
  local location="$1"
  local output_file="$2"
  
  log_info "Fetching pricing data from Azure Pricing API..."
  
  local filter="serviceFamily eq 'Compute'"
  local encoded_filter
  encoded_filter=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.stdin.read().strip()))" <<< "$filter")
  
  local base_url="https://prices.azure.com/api/retail/prices?filter=$encoded_filter"
  local next_page="$base_url"
  local page_count=0
  local total_items=0
  
  > "$output_file"
  
  while [[ -n "$next_page" && "$next_page" != "null" && page_count -lt MAX_API_PAGES ]]; do
    page_count=$((page_count + 1))
    log_debug "Fetching page $page_count..."
    
    local page_response
    page_response=$(create_temp_file "page_response")
    
    if ! timeout "$API_TIMEOUT" curl -s --max-time "$API_TIMEOUT" \
        "$next_page" > "$page_response" 2>&1; then
      log_error "Failed to fetch pricing page $page_count"
      return 1
    fi
    
    if ! jq -e '.Items' > /dev/null < "$page_response" 2>&1; then
      log_error "Invalid response from Pricing API on page $page_count"
      return 1
    fi
    
    jq -r --arg loc "$location" '
      .Items[]
      | select(.armRegionName? == $loc)
      | select(.serviceName? == "Virtual Machines")
      | select(.armSkuName? != null and .armSkuName != "")
      | select(.type == "Consumption")
      | [.armSkuName, (.unitPrice | tonumber)] | @tsv
    ' "$page_response" >> "$output_file"
    
    local page_items
    page_items=$(jq '.Items | length' < "$page_response")
    total_items=$((total_items + page_items))
    
    local matched_count
    matched_count=$(wc -l < "$output_file")
    log_debug "Page $page_count: $page_items items, cumulative matches: $matched_count"
    
    next_page=$(jq -r '.NextPageLink // empty' < "$page_response")
  done
  
  log_info "Fetched pricing for $total_items items across $page_count pages"
  
  sort -u "$output_file" -o "$output_file"
}

display_vm_table() {
  local vm_data_file="$1"
  local pricing_data_file="$2"
  
  printf "%-30s %6s %8s %12s %15s\n" "Name" "vCPUs" "RAM_GB" "Hourly_USD" "Monthly_USD"
  printf "%-30s %6s %8s %12s %15s\n" "----" "------" "------" "----------" "------------"
  
  awk -F '\t' -v price_file="$pricing_data_file" -v hours="$HOURS_PER_MONTH" '
    BEGIN {
      while ((getline < price_file) > 0) {
        split($0, parts, "\t")
        price[parts[1]] = parts[2]
      }
    }
    {
      name = $1
      vcpus = $2
      ram = $3
      hourly = (name in price) ? price[name] : "N/A"
      monthly = (hourly != "N/A") ? sprintf("%.2f", hourly * hours) : "N/A"
      sort_key = (hourly != "N/A") ? hourly : 999999
      printf "%010.6f\t%-30s\t%6s\t%8s\t%12s\t%15s\n", sort_key, name, vcpus, ram, hourly, monthly
    }
  ' "$vm_data_file" | sort -t $'\t' -k1,1n | cut -f2-
}

main() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 1
  fi
  
  local location="$1"
  
  if [[ -z "$location" ]]; then
    log_error "Location is required"
    usage
    exit 1
  fi
  
  check_dependencies
  
  log_info "Starting VM pricing lookup for region: $location"
  
  local vm_table_file
  vm_table_file=$(create_temp_file "vm_table")
  
  local pricing_file
  pricing_file=$(create_temp_file "pricing")
  
  fetch_vm_skus "$location" "$vm_table_file" || exit 1
  fetch_pricing_data "$location" "$pricing_file" || exit 1
  
  local price_count
  price_count=$(wc -l < "$pricing_file")
  log_info "Found pricing data for $price_count VM SKUs"
  
  display_vm_table "$vm_table_file" "$pricing_file"
}

main "$@"