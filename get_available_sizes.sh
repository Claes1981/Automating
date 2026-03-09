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

# Default values
IMAGE_FILTER=""
ONLY_CURRENT_PRICES=true

usage() {
  cat >&2 <<EOF
Usage: $SCRIPT_NAME <location> [OPTIONS]

Displays available Azure VM sizes with pricing for the specified region.

Arguments:
  location    Azure region (e.g., northeurope, eastus, westeurope)

Options:
  -i, --image IMAGE      Filter VMs by OS image (e.g., Ubuntu2404, WindowsServer)
  --include-future       Include prices with future effectiveStartDate
  -h, --help             Show this help message

Examples:
  $SCRIPT_NAME northeurope
  $SCRIPT_NAME northeurope --image Ubuntu2404
  $SCRIPT_NAME eastus --image Ubuntu2404 --include-future
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
  local image_filter="${3:-}"
  
  local vm_skus_file
  vm_skus_file=$(create_temp_file "vm_skus")
  
  log_info "Fetching VM SKUs from Azure CLI for $location..."
  
  if ! timeout "$AZURE_CLI_TIMEOUT" az vm list-skus \
      --location "$location" \
      --resource-type "virtualMachines" \
      -o json > "$vm_skus_file" 2>&1; then
    log_error "Failed to fetch VM SKUs from Azure CLI"
    cat "$vm_skus_file" >&2
    return 1
  fi
  
  local sku_count
  sku_count=$(jq 'length' < "$vm_skus_file")
  log_info "Found $sku_count VM SKU families in $location"
  
  jq -r --arg loc "$location" '
    .[]
    | select(.locations[]? == $loc)
    | .name as $sku
    | (.capabilities // []) as $caps
    | ($caps | map(select(.name == "vCPUs")) | .[0].value // "0") as $vcpus
    | ($caps | map(select(.name == "MemoryGB")) | .[0].value // "0") as $ram
    | "\($sku)\t\($vcpus)\t\($ram)"
  ' "$vm_skus_file" > "${vm_skus_file}.data"
  
  if [[ -z "$image_filter" ]]; then
    cp "${vm_skus_file}.data" "$output_file"
  else
    local usable_sizes_file
    usable_sizes_file=$(create_temp_file "usable_sizes")
    
    local publisher offer sku
    if [[ "$image_filter" == "Ubuntu2404"* ]]; then
      publisher="Canonical"
      offer="ubuntu-24_04-lts"
      sku="server"
    elif [[ "$image_filter" == "Ubuntu2204"* ]]; then
      publisher="Canonical"
      offer="0001-com-ubuntu-server-jammy"
      sku="22_04-lts-gen2"
    elif [[ "$image_filter" == "Ubuntu"* ]]; then
      publisher="Canonical"
      offer="UbuntuServer"
      sku="${image_filter#Ubuntu}"
    elif [[ "$image_filter" == "WindowsServer"* || "$image_filter" == "Win"* ]]; then
      publisher="MicrosoftWindowsServer"
      offer="WindowsServer"
      sku="2022-datacenter-g2"
    elif [[ "$image_filter" == "RHEL"* || "$image_filter" == "RedHat"* ]]; then
      publisher="RedHat"
      offer="RHEL"
      sku="8-lvm-gen2"
    elif [[ "$image_filter" == "Debian"* ]]; then
      publisher="Debian"
      offer="debian-11"
      sku="11-backports-gen2"
    else
      log_error "Unsupported image type: $image_filter"
      log_error "Supported: Ubuntu2404, Ubuntu2204, WindowsServer, RHEL, Debian"
      return 1
    fi
    
    local version_file
    version_file=$(create_temp_file "version")
    
    log_debug "Fetching latest version for $publisher/$offer:$sku..."
    
    if ! timeout "$AZURE_CLI_TIMEOUT" az vm image list \
        --publisher "$publisher" \
        --offer "$offer" \
        --sku "$sku" \
        --location "$location" \
        --all \
        -o json > "$version_file" 2>&1; then
      log_error "Failed to fetch image versions for $publisher/$offer:$sku"
      return 1
    fi
    
    local versions
    versions=$(jq -r '.[].version' "$version_file" | sort -V -u)
    
    if [[ -z "$versions" ]]; then
      log_error "No image versions found for $publisher/$offer:$sku in $location"
      return 1
    fi
    
    local version found_version=""
    local max_attempts=5
    local attempt=0
    
    log_info "Checking image requirements for $publisher/$offer:$sku in $location..."
    
    while IFS= read -r version; do
      attempt=$((attempt + 1))
      if [[ $attempt -gt $max_attempts ]]; then
        break
      fi
      
      if timeout "$AZURE_CLI_TIMEOUT" az vm image show \
          --publisher "$publisher" \
          --offer "$offer" \
          --sku "$sku" \
          --version "$version" \
          --location "$location" \
          -o json > "$usable_sizes_file" 2>/dev/null; then
        found_version="$version"
        break
      fi
    done <<< "$versions"
    
    if [[ -z "$found_version" ]]; then
      log_error "Could not access any image version for $publisher/$offer:$sku in $location"
      log_error "Skipping image-based filtering, showing all VMs"
      cp "${vm_skus_file}.data" "$output_file"
      return 0
    fi
    
    log_debug "Using accessible image version: $found_version"
    
    local image_arch
    image_arch=$(jq -r '.architecture // "x64"' < "$usable_sizes_file")
    
    log_debug "Image architecture: $image_arch"
    log_info "Note: Hyper-V generation filtering not available via Azure CLI"
    
    if [[ "$image_arch" == "ARM64" || "$image_arch" == "arm64" ]]; then
      awk -F '\t' 'tolower($1) ~ /arm64/' "${vm_skus_file}.data" > "$output_file"
    else
      cp "${vm_skus_file}.data" "$output_file"
    fi
    
    local filtered_count
    filtered_count=$(wc -l < "$output_file")
    log_info "Found $filtered_count VM SKUs (filtered by arch=$image_arch)"
  fi
  
  local total_skus
  total_skus=$(wc -l < "$output_file")
  log_info "Total VM SKUs with hardware info: $total_skus"
}

fetch_pricing_data() {
  local location="$1"
  local output_file="$2"
  local only_current="${3:-true}"
  
  log_info "Fetching pricing data from Azure Pricing API..."
  
  local base_url="https://prices.azure.com/api/retail/prices"
  local next_page="$base_url"
  local page_count=0
  local total_items=0
  
  > "$output_file"
  
  local today
  today=$(date -u +"%Y-%m-%dT00:00:00Z")
  log_debug "Filtering prices with effectiveStartDate <= $today"
  
  while [[ -n "$next_page" && "$next_page" != "null" && page_count -lt MAX_API_PAGES ]]; do
    page_count=$((page_count + 1))
    log_debug "Fetching page $page_count..."
    
    local page_response
    page_response=$(create_temp_file "page_response")
    
    if ! timeout "$API_TIMEOUT" curl -s --max-time "$API_TIMEOUT" \
        "$next_page" > "$page_response" 2>/dev/null; then
      log_error "Failed to fetch pricing page $page_count"
      log_debug "Response: $(head -c 500 "$page_response")"
      return 1
    fi
    
    if ! jq -e '.Items' > /dev/null < "$page_response" 2>&1; then
      log_error "Invalid response from Pricing API on page $page_count"
      log_debug "Response: $(head -c 500 "$page_response")"
      return 1
    fi
    
    if [[ "$only_current" == "true" ]]; then
      jq -r --arg loc "$location" --arg today "$today" '
        .Items[]
        | select(.armRegionName? == $loc)
        | select(.serviceName? == "Virtual Machines")
        | select(.armSkuName? != null and .armSkuName != "")
        | select(.type == "Consumption")
        | select(.effectiveStartDate? == null or .effectiveStartDate <= $today)
        | [.armSkuName, (.unitPrice | tonumber)] | @tsv
      ' "$page_response" >> "$output_file"
    else
      jq -r --arg loc "$location" '
        .Items[]
        | select(.armRegionName? == $loc)
        | select(.serviceName? == "Virtual Machines")
        | select(.armSkuName? != null and .armSkuName != "")
        | select(.type == "Consumption")
        | [.armSkuName, (.unitPrice | tonumber)] | @tsv
      ' "$page_response" >> "$output_file"
    fi
    
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
  local location=""
  local image_filter=""
  local include_future=false
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -i|--image)
        image_filter="$2"
        shift 2
        ;;
      --include-future)
        include_future=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        log_error "Unknown option: $1"
        usage
        exit 1
        ;;
      *)
        location="$1"
        shift
        ;;
    esac
  done
  
  if [[ -z "$location" ]]; then
    log_error "Location is required"
    usage
    exit 1
  fi
  
  check_dependencies
  
  log_info "Starting VM pricing lookup for region: $location"
  
  if [[ -n "$image_filter" ]]; then
    log_info "Filtering by image: $image_filter"
  fi
  
  if [[ "$include_future" == "true" ]]; then
    log_info "Including future-dated prices"
  else
    log_info "Only showing current prices (effectiveStartDate <= today)"
  fi
  
  local vm_table_file
  vm_table_file=$(create_temp_file "vm_table")
  
  local pricing_file
  pricing_file=$(create_temp_file "pricing")
  
  local only_current="true"
  [[ "$include_future" == "true" ]] && only_current="false"
  
  fetch_vm_skus "$location" "$vm_table_file" "$image_filter" || exit 1
  fetch_pricing_data "$location" "$pricing_file" "$only_current" || exit 1
  
  local price_count
  price_count=$(wc -l < "$pricing_file")
  log_info "Found pricing data for $price_count VM SKUs"
  
  display_vm_table "$vm_table_file" "$pricing_file"
}

main "$@"