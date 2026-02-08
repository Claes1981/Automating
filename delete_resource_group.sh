#!/bin/bash

set -euo pipefail

# Constants
RESOURCE_GROUP="MyOneClickGroup"

function log_error() {
    echo "ERROR: $1" >&2
    exit 1
}

function delete_resource_group() {
    echo "Deleting resource group: $RESOURCE_GROUP..."
    if ! az group delete --name "$RESOURCE_GROUP" --yes --no-wait; then
        log_error "Failed to delete resource group"
    fi
    echo "Resource group deletion initiated. This may take a few minutes to complete."
}

function main() {
    delete_resource_group
}

main