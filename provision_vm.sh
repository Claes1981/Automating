#!/bin/bash

# Variables
resource_group="MyOneClickGroup"
vm_name="MyOneClickVM"
location="northeurope"
custom_data_file="custom_data_nginx.sh"

# Create a resource group
echo "Creating resource group: $resource_group..."
az group create --name $resource_group --location $location

# Create a virtual machine with custom data
echo "Creating virtual machine: $vm_name..."
az vm create \
   --resource-group $resource_group \
   --location $location \
   --name $vm_name \
   --image Ubuntu2404 \
   --size Standard_B1s \
   --admin-username azureuser \
   --generate-ssh-keys \
   --custom-data @$custom_data_file

# Open port 80 for HTTP traffic
echo "Opening port 80 for HTTP traffic..."
az vm open-port --resource-group $resource_group --name $vm_name --port 80

# Retrieve public IP address of the VM
vm_ip=$(az vm show --resource-group $resource_group --name $vm_name --show-details --query publicIps -o tsv)

echo "Deployment complete! Access your server at http://$vm_ip"
