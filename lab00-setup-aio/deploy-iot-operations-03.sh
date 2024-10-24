#!/bin/bash

# load environment variables
set -a && source .env && set +a

required_vars=(
    "resource_group"
    "subscription_id"
    "location"
    "k8s_cluster_name"
    "keyvault_name"
)


# Set the current directory to where the script lives.
cd "$(dirname "$0")"


# Function to check if all required arguments have been set
check_required_arguments() {
    # Array to store the names of the missing arguments
    local missing_arguments=()

    # Loop through the array of required argument names
    for arg_name in "${required_vars[@]}"; do
        # Check if the argument value is empty
        if [[ -z "${!arg_name}" ]]; then
            # Add the name of the missing argument to the array
            missing_arguments+=("${arg_name}")
        fi
    done

    # Check if any required argument is missing
    if [[ ${#missing_arguments[@]} -gt 0 ]]; then
        echo -e "\nError: Missing required arguments:"
        printf '  %s\n' "${missing_arguments[@]}"
        [ ! \( \( $# == 1 \) -a \( "$1" == "-c" \) \) ] && echo "  Either provide a config file path or all the arguments, but not both at the same time."
        [ ! \( $# == 22 \) ] && echo "  All arguments must be provided."
        echo ""
        exit 1
    fi
}

####################################################################################

# Check if all required arguments have been set
check_required_arguments

# Get Key Vault ID
KEYVAULT_ID=$(az keyvault show --resource-group "$resource_group" --name ${keyvault_name} --query id -o tsv)

# Get Schema resgistry ID
SCHEMA_REGISTRY_ID=$(az iot ops schema registry show --name ${k8s_cluster_name}sreg --resource-group ${resource_group} -o tsv --query id)

#
# Prepare cluster
#
az iot ops init  \
  --subscription $subscription_id \
  -g $resource_group \
  --cluster $k8s_cluster_name \
  --sr-resource-id $SCHEMA_REGISTRY_ID

# Install IoT Operations
az iot ops create \
  --subscription $subscription_id \
  -g $resource_group \
  --cluster $k8s_cluster_name \
  --custom-location ${k8s_cluster_name}-cl \
  --name ${k8s_cluster_name}-ops-instance \
  --enable-rsync \
  --broker-mem-profile Low

exit 0
