#!/usr/bin/env bash
set -euo pipefail

################################################################################
# Azure VM Pricing Script
# Displays available VM sizes with pricing for a given Azure region
#
# Principles: Clean Code, Single Responsibility, DRY
################################################################################

readonly SCRIPT_NAME="$(basename "$0")"
readonly AZURE_CLI_TIMEOUT=600
readonly API_TIMEOUT=60
readonly MAX_API_PAGES=500
readonly HOURS_PER_MONTH=730
readonly PRICING_API_BASE="https://prices.azure.com/api/retail/prices"
readonly VM_RESOURCE_TYPE="virtualMachines"
readonly SERVICE_NAME="Virtual Machines"
readonly PRICING_TYPE="Consumption"

declare -a TEMP_FILES=()

################################################################################
# Configuration: Image to Publisher/Offer/SKU mapping
# Format: IMAGE_FILTER:PUBLISHER:OFFER:SKU
################################################################################
declare -A IMAGE_MAPPINGS=(
  ["Ubuntu2404"]="Canonical:ubuntu-24_04-lts:server"
  ["Ubuntu2204"]="Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2"
  ["WindowsServer"]="MicrosoftWindowsServer:WindowsServer:2022-datacenter-g2"
  ["RHEL"]="RedHat:RHEL:8-lvm-gen2"
  ["Debian"]="Debian:debian-11:11-backports-gen2"
)

################################################################################
# Logging functions
################################################################################
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

################################################################################
# Cleanup handler
################################################################################
cleanup() {
  log_debug "Cleaning up ${#TEMP_FILES[@]} temporary files..."
  for file in "${TEMP_FILES[@]}"; do
    rm -f "$file" 2>/dev/null || true
  done
}

trap cleanup EXIT

################################################################################
# Dependency checking
################################################################################
check_dependencies() {
  local -a required_deps=("jq" "curl" "az")
  local missing_dep=""
  
  for dep in "${required_deps[@]}"; do
    if ! command -v "$dep" &> /dev/null; then
      missing_dep="$dep"
      break
    fi
  done
  
  if [[ -n "$missing_dep" ]]; then
    log_error "$missing_dep is not installed or not in PATH"
    return 1
  fi
  
  return 0
}

################################################################################
# Temporary file management
################################################################################
create_temp_file() {
  local prefix="${1:-tmp}"
  local temp_file
  
  temp_file=$(mktemp "/tmp/${prefix}_XXXXXX")
  TEMP_FILES+=("$temp_file")
  echo "$temp_file"
}

################################################################################
# Argument parsing
################################################################################
parse_arguments() {
  local -n _location_ref=$1
  local -n _image_filter_ref=$2
  local -n _include_future_ref=$3
  
  _location_ref=""
  _image_filter_ref=""
  _include_future_ref=false
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -i|--image)
        _image_filter_ref="$2"
        shift 2
        ;;
      --include-future)
        _include_future_ref=true
        shift
        ;;
      -h|--help)
        show_usage
        exit 0
        ;;
      -*)
        log_error "Unknown option: $1"
        show_usage
        exit 1
        ;;
      *)
        _location_ref="$1"
        shift
        ;;
    esac
  done
}

show_usage() {
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

validate_arguments() {
  local location="$1"
  
  if [[ -z "$location" ]]; then
    log_error "Location is required"
    show_usage
    return 1
  fi
  
  return 0
}

################################################################################
# VM SKU fetching and processing
################################################################################
fetch_vm_skus_raw() {
  local location="$1"
  local output_file="$2"
  
  log_info "Fetching VM SKUs from Azure CLI for $location..."
  
  if ! timeout "$AZURE_CLI_TIMEOUT" az vm list-skus \
      --location "$location" \
      --resource-type "$VM_RESOURCE_TYPE" \
      -o json > "$output_file" 2>&1; then
    log_error "Failed to fetch VM SKUs from Azure CLI"
    cat "$output_file" >&2
    return 1
  fi
  
  return 0
}

count_vm_skus() {
  local json_file="$1"
  jq 'length' < "$json_file"
}

parse_vm_skus_to_table() {
  local json_file="$1"
  local location="$2"
  local output_file="$3"
  
  jq -r --arg loc "$location" '
    .[]
    | select(.locations[]? == $loc)
    | .name as $sku
    | (.capabilities // []) as $caps
    | ($caps | map(select(.name == "vCPUs")) | .[0].value // "0") as $vcpus
    | ($caps | map(select(.name == "MemoryGB")) | .[0].value // "0") as $ram
    | "\($sku)\t\($vcpus)\t\($ram)"
  ' "$json_file" > "$output_file"
}

count_lines() {
  local file="$1"
  wc -l < "$file"
}

################################################################################
# Image filtering
################################################################################
resolve_image_mapping() {
  local image_filter="$1"
  local -n _publisher_ref=$2
  local -n _offer_ref=$3
  local -n _sku_ref=$4
  
  # Check exact matches first
  if [[ -v IMAGE_MAPPINGS["$image_filter"] ]]; then
    IFS=':' read -r _publisher_ref _offer_ref _sku_ref <<< "${IMAGE_MAPPINGS[$image_filter]}"
    return 0
  fi
  
  # Check Ubuntu versions dynamically
  if [[ "$image_filter" == Ubuntu* ]]; then
    _publisher_ref="Canonical"
    _offer_ref="UbuntuServer"
    _sku_ref="${image_filter#Ubuntu}"
    return 0
  fi
  
  log_error "Unsupported image type: $image_filter"
  log_error "Supported: Ubuntu2404, Ubuntu2204, WindowsServer, RHEL, Debian"
  return 1
}

fetch_image_versions() {
  local publisher="$1"
  local offer="$2"
  local sku="$3"
  local location="$4"
  local output_file="$5"
  
  log_debug "Fetching image versions for $publisher/$offer:$sku..."
  
  if ! timeout "$AZURE_CLI_TIMEOUT" az vm image list \
      --publisher "$publisher" \
      --offer "$offer" \
      --sku "$sku" \
      --location "$location" \
      --all \
      -o json > "$output_file" 2>&1; then
    log_error "Failed to fetch image versions for $publisher/$offer:$sku"
    return 1
  fi
  
  return 0
}

get_accessible_image_version() {
  local publisher="$1"
  local offer="$2"
  local sku="$3"
  local location="$4"
  local versions_file="$5"
  local output_file="$6"
  
  local versions
  versions=$(jq -r '.[].version' "$versions_file" | sort -V -u)
  
  if [[ -z "$versions" ]]; then
    log_error "No image versions found for $publisher/$offer:$sku in $location"
    return 1
  fi
  
  local max_attempts=5
  local attempt=0
  local version
  
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
        -o json > "$output_file" 2>/dev/null; then
      log_debug "Using accessible image version: $version"
      return 0
    fi
  done <<< "$versions"
  
  return 1
}

get_image_architecture() {
  local image_info_file="$1"
  jq -r '.architecture // "x64"' < "$image_info_file"
}

filter_vms_by_architecture() {
  local vm_data_file="$1"
  local architecture="$2"
  local output_file="$3"
  
  if [[ "$architecture" == "ARM64" || "$architecture" == "arm64" ]]; then
    awk -F '\t' 'tolower($1) ~ /arm64/' "$vm_data_file" > "$output_file"
  else
    cp "$vm_data_file" "$output_file"
  fi
}

apply_image_filter() {
  local location="$1"
  local image_filter="$2"
  local vm_data_file="$3"
  local output_file="$4"
  
  if [[ -z "$image_filter" ]]; then
    cp "$vm_data_file" "$output_file"
    return 0
  fi
  
  local publisher offer sku
  if ! resolve_image_mapping "$image_filter" publisher offer sku; then
    return 1
  fi
  
  local versions_file image_info_file
  versions_file=$(create_temp_file "image_versions")
  image_info_file=$(create_temp_file "image_info")
  
  if ! fetch_image_versions "$publisher" "$offer" "$sku" "$location" "$versions_file"; then
    return 1
  fi
  
  if ! get_accessible_image_version "$publisher" "$offer" "$sku" "$location" \
      "$versions_file" "$image_info_file"; then
    log_error "Could not access any image version for $publisher/$offer:$sku"
    log_info "Skipping image-based filtering, showing all VMs"
    cp "$vm_data_file" "$output_file"
    return 0
  fi
  
  local architecture
  architecture=$(get_image_architecture "$image_info_file")
  
  log_debug "Image architecture: $architecture"
  log_info "Note: Hyper-V generation filtering not available via Azure CLI"
  
  filter_vms_by_architecture "$vm_data_file" "$architecture" "$output_file"
  
  local filtered_count
  filtered_count=$(count_lines "$output_file")
  log_info "Found $filtered_count VM SKUs (filtered by arch=$architecture)"
  
  return 0
}

fetch_vm_data() {
  local location="$1"
  local output_file="$2"
  local image_filter="${3:-}"
  
  local vm_skus_file vm_data_file
  vm_skus_file=$(create_temp_file "vm_skus")
  vm_data_file=$(create_temp_file "vm_data")
  
  if ! fetch_vm_skus_raw "$location" "$vm_skus_file"; then
    return 1
  fi
  
  local sku_count
  sku_count=$(count_vm_skus "$vm_skus_file")
  log_info "Found $sku_count VM SKU families in $location"
  
  parse_vm_skus_to_table "$vm_skus_file" "$location" "$vm_data_file"
  
  if ! apply_image_filter "$location" "$image_filter" "$vm_data_file" "$output_file"; then
    return 1
  fi
  
  local total_skus
  total_skus=$(count_lines "$output_file")
  log_info "Total VM SKUs with hardware info: $total_skus"
  
  return 0
}

################################################################################
# Pricing data fetching
################################################################################
get_current_date_iso() {
  date -u +"%Y-%m-%dT00:00:00Z"
}

fetch_pricing_page() {
  local url="$1"
  local output_file="$2"
  
  if ! timeout "$API_TIMEOUT" curl -s --max-time "$API_TIMEOUT" \
      "$url" > "$output_file" 2>/dev/null; then
    return 1
  fi
  
  return 0
}

validate_pricing_response() {
  local response_file="$1"
  jq -e '.Items' > /dev/null < "$response_file" 2>&1
}

extract_pricing_data() {
  local response_file="$1"
  local location="$2"
  local today="$3"
  local include_future="$4"
  local output_file="$5"
  
  local jq_filter
  if [[ "$include_future" == "true" ]]; then
    jq_filter="
      .Items[]
      | select(.armRegionName? == \"$location\")
      | select(.serviceName? == \"$SERVICE_NAME\")
      | select(.armSkuName? != null and .armSkuName != \"\")
      | select(.type == \"$PRICING_TYPE\")
      | [.armSkuName, (.unitPrice | tonumber)] | @tsv
    "
  else
    jq_filter="
      .Items[]
      | select(.armRegionName? == \"$location\")
      | select(.serviceName? == \"$SERVICE_NAME\")
      | select(.armSkuName? != null and .armSkuName != \"\")
      | select(.type == \"$PRICING_TYPE\")
      | select(.effectiveStartDate? == null or .effectiveStartDate <= \"$today\")
      | [.armSkuName, (.unitPrice | tonumber)] | @tsv
    "
  fi
  
  jq -r "$jq_filter" "$response_file" >> "$output_file"
}

get_next_page_link() {
  local response_file="$1"
  jq -r '.NextPageLink // empty' < "$response_file"
}

count_page_items() {
  local response_file="$1"
  jq '.Items | length' < "$response_file"
}

fetch_pricing_data() {
  local location="$1"
  local output_file="$2"
  local include_future="${3:-false}"
  
  log_info "Fetching pricing data from Azure Pricing API..."
  
  local next_page="$PRICING_API_BASE"
  local page_count=0
  local total_items=0
  
  > "$output_file"
  
  local today
  today=$(get_current_date_iso)
  log_debug "Filtering prices with effectiveStartDate <= $today"
  
  while [[ -n "$next_page" && "$next_page" != "null" && page_count -lt MAX_API_PAGES ]]; do
    page_count=$((page_count + 1))
    log_debug "Fetching page $page_count..."
    
    local page_response
    page_response=$(create_temp_file "page_response")
    
    if ! fetch_pricing_page "$next_page" "$page_response"; then
      log_error "Failed to fetch pricing page $page_count"
      log_debug "Response: $(head -c 500 "$page_response")"
      return 1
    fi
    
    if ! validate_pricing_response "$page_response"; then
      log_error "Invalid response from Pricing API on page $page_count"
      log_debug "Response: $(head -c 500 "$page_response")"
      return 1
    fi
    
    extract_pricing_data "$page_response" "$location" "$today" "$include_future" "$output_file"
    
    local page_items
    page_items=$(count_page_items "$page_response")
    total_items=$((total_items + page_items))
    
    local matched_count
    matched_count=$(count_lines "$output_file")
    log_debug "Page $page_count: $page_items items, cumulative matches: $matched_count"
    
    next_page=$(get_next_page_link "$page_response")
  done
  
  log_info "Fetched pricing for $total_items items across $page_count pages"
  
  sort -u "$output_file" -o "$output_file"
  
  return 0
}

################################################################################
# Display functions
################################################################################
print_table_header() {
  printf "%-30s %6s %8s %12s %15s\n" "Name" "vCPUs" "RAM_GB" "Hourly_USD" "Monthly_USD"
  printf "%-30s %6s %8s %12s %15s\n" "----" "------" "------" "----------" "------------"
}

load_pricing_into_memory() {
  local price_file="$1"
  awk -F '\t' '
    BEGIN {
      while ((getline < ENVIRON["price_file"]) > 0) {
        split($0, parts, "\t")
        price[parts[1]] = parts[2]
      }
    }
  ' price_file="$price_file"
}

format_vm_table_row() {
  local vm_data_file="$1"
  local pricing_data_file="$2"
  
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

display_vm_table() {
  local vm_data_file="$1"
  local pricing_data_file="$2"
  
  print_table_header
  format_vm_table_row "$vm_data_file" "$pricing_data_file"
}

################################################################################
# Main orchestration
################################################################################
main() {
  local location image_filter include_future
  
  parse_arguments location image_filter include_future "$@"
  
  if ! validate_arguments "$location"; then
    exit 1
  fi
  
  if ! check_dependencies; then
    exit 1
  fi
  
  log_info "Starting VM pricing lookup for region: $location"
  
  if [[ -n "$image_filter" ]]; then
    log_info "Filtering by image: $image_filter"
  fi
  
  if [[ "$include_future" == "true" ]]; then
    log_info "Including future-dated prices"
  else
    log_info "Only showing current prices (effectiveStartDate <= today)"
  fi
  
  local vm_table_file pricing_file
  vm_table_file=$(create_temp_file "vm_table")
  pricing_file=$(create_temp_file "pricing")
  
  if ! fetch_vm_data "$location" "$vm_table_file" "$image_filter"; then
    exit 1
  fi
  
  if ! fetch_pricing_data "$location" "$pricing_file" "$include_future"; then
    exit 1
  fi
  
  local price_count
  price_count=$(count_lines "$pricing_file")
  log_info "Found pricing data for $price_count VM SKUs"
  
  display_vm_table "$vm_table_file" "$pricing_file"
}

main "$@"
