#!/usr/bin/env bash
set -euo pipefail

################################################################################
# Azure Resource Group Deletion Script
# Safely deletes an Azure resource group and all its contents
################################################################################

readonly SCRIPT_NAME="$(basename "$0")"
readonly DEFAULT_RESOURCE_GROUP="MyOneClickGroup"

RESOURCE_GROUP="${DEFAULT_RESOURCE_GROUP}"
FORCE=false

usage() {
  cat >&2 <<EOF
Usage: $SCRIPT_NAME [OPTIONS] [-g RESOURCE_GROUP]

Deletes an Azure resource group and all its resources.

Options:
  -g, --resource-group NAME    Resource group name (default: $DEFAULT_RESOURCE_GROUP)
  -f, --force                  Skip confirmation prompt
  -h, --help                   Show this help message

Examples:
  $SCRIPT_NAME
  $SCRIPT_NAME -g MyResourceGroup
  $SCRIPT_NAME --resource-group Production --force

WARNING: This action is irreversible!
EOF
}

log_info() {
  echo "$*"
}

log_error() {
  echo "ERROR: $*" >&2
}

log_warning() {
  echo "WARNING: $*" >&2
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

confirm_deletion() {
  if [[ "$FORCE" == "true" ]]; then
    return 0
  fi
  
  log_warning "You are about to delete resource group: $RESOURCE_GROUP"
  log_warning "This action is irreversible!"
  
  read -r -p "Are you sure? (yes/no): " confirmation
  
  if [[ "${confirmation,,}" != "yes" ]]; then
    log_info "Deletion cancelled by user"
    exit 0
  fi
}

resource_group_exists() {
  az group exists --name "$RESOURCE_GROUP"
}

delete_resource_group() {
  log_info "Deleting resource group: $RESOURCE_GROUP..."
  
  if ! az group delete \
      --name "$RESOURCE_GROUP" \
      --yes \
      --no-wait; then
    log_error "Failed to initiate resource group deletion"
    return 1
  fi
  
  log_info "Resource group deletion initiated"
  log_info "This may take several minutes to complete"
  log_info "Check status with: az group show -g $RESOURCE_GROUP"
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -g|--resource-group)
        RESOURCE_GROUP="$2"
        shift 2
        ;;
      -f|--force)
        FORCE=true
        shift
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
  confirm_deletion
  
  if ! resource_group_exists; then
    log_warning "Resource group '$RESOURCE_GROUP' does not exist"
    exit 0
  fi
  
  delete_resource_group || exit 1
  
  log_info "=========================================="
  log_info "Deletion initiated successfully"
  log_info "=========================================="
}

main "$@"