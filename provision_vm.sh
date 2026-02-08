#!/bin/bash
set -euo pipefail
# Constants
RESOURCE_GROUP="MyOneClickGroup"
VM_NAME="MyOneClickVM"
LOCATION="northeurope"
ZONE="3"
VM_SIZE="Standard_F1als_v7"
CUSTOM_DATA_FILE="custom_data_nginx.sh"
function log_error() {
    echo "ERROR: $1" >&2
    exit 1
}
function create_resource_group() {
    echo "Creating resource group: $RESOURCE_GROUP..."
    if ! az group create --name "$RESOURCE_GROUP" --location "$LOCATION"; then
        log_error "Failed to create resource group"
    fi
}
function create_vm() {
    echo "Creating virtual machine: $VM_NAME..."
    if ! az vm create \
        --resource-group "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --name "$VM_NAME" \
        --image Ubuntu2404 \
        --size "$VM_SIZE" \
        --zone "$ZONE" \
        --admin-username azureuser \
        --generate-ssh-keys \
        --custom-data "@$CUSTOM_DATA_FILE"; then
        log_error "Failed to create VM"
    fi
}
function open_port() {
    echo "Opening port 80 for HTTP traffic..."
    if ! az vm open-port --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --port 80; then
        log_error "Failed to open port 80"
    fi
}
function get_vm_ip() {
    az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --show-details --query publicIps -o tsv
}
function main() {
    create_resource_group
    create_vm
    open_port
    vm_ip=$(get_vm_ip)
    echo "Deployment complete! Access your server at http://$vm_ip"
}
main