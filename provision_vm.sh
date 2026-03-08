#!/usr/bin/env bash
set -euo pipefail

################################################################################
# Azure VM Provisioning Script
# Creates an Azure VM with nginx pre-installed
################################################################################

readonly SCRIPT_NAME="$(basename "$0")"

readonly DEFAULT_RESOURCE_GROUP="MyOneClickGroup"
readonly DEFAULT_VM_NAME="MyOneClickVM"
readonly DEFAULT_LOCATION="northeurope"
readonly DEFAULT_ZONE="3"
readonly DEFAULT_VM_SIZE="Standard_F1als_v7"
readonly DEFAULT_IMAGE="Ubuntu2404"
readonly DEFAULT_ADMIN_USERNAME="azureuser"
readonly DEFAULT_CUSTOM_DATA_FILE="custom_data_nginx.sh"
readonly DEFAULT_PORT="80"

RESOURCE_GROUP="${DEFAULT_RESOURCE_GROUP}"
VM_NAME="${DEFAULT_VM_NAME}"
LOCATION="${DEFAULT_LOCATION}"
ZONE="${DEFAULT_ZONE}"
VM_SIZE="${DEFAULT_VM_SIZE}"
IMAGE="${DEFAULT_IMAGE}"
ADMIN_USERNAME="${DEFAULT_ADMIN_USERNAME}"
CUSTOM_DATA_FILE="${DEFAULT_CUSTOM_DATA_FILE}"
PORT="${DEFAULT_PORT}"

usage() {
  cat >&2 <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Creates an Azure virtual machine with nginx pre-installed.

Options:
  -g, --resource-group NAME    Resource group name (default: $DEFAULT_RESOURCE_GROUP)
  -n, --name NAME              VM name (default: $DEFAULT_VM_NAME)
  -l, --location LOCATION      Azure location (default: $DEFAULT_LOCATION)
  -z, --zone ZONE              Availability zone (default: $DEFAULT_ZONE)
  -s, --size SIZE              VM size (default: $DEFAULT_VM_SIZE)
  -i, --image IMAGE            OS image (default: $DEFAULT_IMAGE)
  -u, --username USERNAME      Admin username (default: $DEFAULT_ADMIN_USERNAME)
  -c, --custom-data FILE       Custom data script (default: $DEFAULT_CUSTOM_DATA_FILE)
  -p, --port PORT              Port to open (default: $DEFAULT_PORT)
  -h, --help                   Show this help message

Examples:
  $SCRIPT_NAME
  $SCRIPT_NAME -g MyRG -n MyVM -l eastus
  $SCRIPT_NAME --resource-group Production --size Standard_B2s
EOF
}

log_info() {
  echo "$*"
}

log_error() {
  echo "ERROR: $*" >&2
}

check_dependencies() {
  if ! command -v az &> /dev/null; then
    log_error "Azure CLI (az) is not installed or not in PATH"
    exit 1
  fi
  
  if ! az account show &> /dev/null; then
    log_error "Not logged in to Azure. Run 'az login' first."
    exit 1
  fi
}

validate_custom_data() {
  if [[ ! -f "$CUSTOM_DATA_FILE" ]]; then
    log_error "Custom data file not found: $CUSTOM_DATA_FILE"
    exit 1
  fi
}

resource_group_exists() {
  local exists
  exists=$(az group exists --name "$RESOURCE_GROUP" -o tsv)
  [[ "$exists" == "true" ]]
}

create_resource_group() {
  log_info "Creating resource group: $RESOURCE_GROUP in $LOCATION..."
  
  if resource_group_exists; then
    log_info "Resource group '$RESOURCE_GROUP' already exists. Skipping creation."
    return 0
  fi
  
  if ! az group create --name "$RESOURCE_GROUP" --location "$LOCATION"; then
    log_error "Failed to create resource group"
    return 1
  fi
  
  log_info "Resource group created successfully"
}

create_vm() {
  log_info "Creating virtual machine: $VM_NAME (size: $VM_SIZE, zone: $ZONE)..."
  
  if ! az vm create \
      --resource-group "$RESOURCE_GROUP" \
      --location "$LOCATION" \
      --name "$VM_NAME" \
      --image "$IMAGE" \
      --size "$VM_SIZE" \
      --zone "$ZONE" \
      --admin-username "$ADMIN_USERNAME" \
      --generate-ssh-keys \
      --custom-data "@$CUSTOM_DATA_FILE"; then
    log_error "Failed to create VM"
    return 1
  fi
  
  log_info "VM created successfully"
}

open_port() {
  log_info "Opening port $PORT for HTTP traffic..."
  
  if ! az vm open-port \
      --resource-group "$RESOURCE_GROUP" \
      --name "$VM_NAME" \
      --port "$PORT"; then
    log_error "Failed to open port $PORT"
    return 1
  fi
  
  log_info "Port $PORT opened successfully"
}

get_vm_ip() {
  local ip
  ip=$(az vm show \
      --resource-group "$RESOURCE_GROUP" \
      --name "$VM_NAME" \
      --show-details \
      --query publicIps \
      -o tsv)
  
  echo "$ip"
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -g|--resource-group)
        RESOURCE_GROUP="$2"
        shift 2
        ;;
      -n|--name)
        VM_NAME="$2"
        shift 2
        ;;
      -l|--location)
        LOCATION="$2"
        shift 2
        ;;
      -z|--zone)
        ZONE="$2"
        shift 2
        ;;
      -s|--size)
        VM_SIZE="$2"
        shift 2
        ;;
      -i|--image)
        IMAGE="$2"
        shift 2
        ;;
      -u|--username)
        ADMIN_USERNAME="$2"
        shift 2
        ;;
      -c|--custom-data)
        CUSTOM_DATA_FILE="$2"
        shift 2
        ;;
      -p|--port)
        PORT="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        log_error "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
  done
}

main() {
  parse_arguments "$@"
  
  check_dependencies
  validate_custom_data
  
  log_info "Starting VM provisioning..."
  log_info "Resource Group: $RESOURCE_GROUP"
  log_info "VM Name: $VM_NAME"
  log_info "Location: $LOCATION"
  log_info "VM Size: $VM_SIZE"
  echo
  
  create_resource_group || exit 1
  create_vm || exit 1
  open_port || exit 1
  
  local vm_ip
  vm_ip=$(get_vm_ip)
  
  echo
  log_info "=========================================="
  log_info "Deployment complete!"
  log_info "Access your server at: http://$vm_ip"
  log_info "=========================================="
}

main "$@"