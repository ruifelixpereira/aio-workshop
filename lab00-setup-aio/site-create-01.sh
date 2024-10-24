#!/bin/bash

# load environment variables
set -a && source .env && set +a

# Required variables
required_vars=(
    "resource_group"
    "location"
    "k8s_cluster_name"
    "acr_name"
    "vm_size"
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
        [ ! \( \( $# == 1 \) -a \( "$1" == "-c" \) \) ] && echo "  Either provide a .env file or all the arguments, but not both at the same time."
        [ ! \( $# == 22 \) ] && echo "  All arguments must be provided."
        echo ""
        exit 1
    fi
}

####################################################################################

# Check if all required arguments have been set
check_required_arguments

#
# Create/Get a resource group.
#
rg_query=$(az group list --query "[?name=='$resource_group']")
if [ "$rg_query" == "[]" ]; then
   echo -e "\nCreating Resource group '$resource_group'"
   az group create --name ${resource_group} --location ${location}
else
   echo "Resource group $resource_group already exists."
   #RG_ID=$(az group show --name $resource_group --query id -o tsv)
fi

#
# Create AKS cluster
#
aks_query=$(az aks list --query "[?name=='$k8s_cluster_name']")
if [ "$aks_query" == "[]" ]; then
   echo -e "\nCreating AKS cluster '$k8s_cluster_name'"
   az aks create -g ${resource_group} -n ${k8s_cluster_name} --enable-managed-identity --node-count 3 --node-vm-size ${vm_size} --enable-addons monitoring --generate-ssh-keys --attach-acr ${acr_name} --enable-oidc-issuer --enable-workload-identity
else
   echo "AKS cluster $k8s_cluster_name already exists."

   # Attach using acr-name
   #az aks update -g ${resource_group} -n ${k8s_cluster_name} --attach-acr ${acr_name}
fi


# Get cluster credentials to local .kube/config
az aks get-credentials -g ${resource_group} -n ${k8s_cluster_name}

#
# Arc enable the cluster
#
kubectl config use-context ${k8s_cluster_name}
#az connectedk8s connect --name ${k8s_cluster_name} --resource-group ${resource_group}

echo "Created site ${k8s_cluster_name}"

