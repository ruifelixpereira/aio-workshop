#!/bin/bash

# load environment variables
set -a && source .env && set +a

required_vars=(
    "resource_group"
    "subscription_id"
    "location"
    "k8s_cluster_name"
    "keyvault_name"
    "storage_account_name"
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

register_provider() {
    provider_name=$1
    pr_query=$(az provider list --query "[?namespace=='$provider_name' && registrationState=='Registered']")
    if [ "$pr_query" == "[]" ]; then
        echo -e "\nRegistering provider '$provider_name'"
        az provider register -n $provider_name
    else
        echo "Provider $provider_name is registered."
    fi
}

wait_provider() {
    provider_name=$1
    STATUS=$(az provider show --namespace $provider_name --query registrationState -o tsv)
    while [ ${STATUS} == "Registering" ]; do
        echo "Waiting for provider $provider_name to register"
        sleep 5
        STATUS=$(az provider show --namespace $provider_name --query registrationState -o tsv)
    done

    if [ ! ${STATUS} == "Registered" ]; then
        echo "Operation did not succeed"
        echo "Operation status is ${STATUS}"
        exit 1
    else
        echo "Provider $provider_name is registered."
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
    echo -e "\nCreating the Resource Group '$resource_group'"
    az group create --location $location --resource-group $resource_group --subscription $subscription_id
else
    echo "Resource group $resource_group already exists."
    location=$(az group show --name $resource_group --query location -o tsv)
fi

# Set K8s context
kubectl config use-context $k8s_cluster_name

#
# Setup providers (in paralell)
#
register_provider "Microsoft.ExtendedLocation"
register_provider "Microsoft.Kubernetes"
register_provider "Microsoft.KubernetesConfiguration"
register_provider "Microsoft.IoTOperations"
register_provider "Microsoft.DeviceRegistry"

wait_provider "Microsoft.ExtendedLocation"
wait_provider "Microsoft.Kubernetes"
wait_provider "Microsoft.KubernetesConfiguration"
wait_provider "Microsoft.IoTOperations"
wait_provider "Microsoft.DeviceRegistry"

#
# Install connectedk8s extension - version required by AIO 0.7.31
#
az extension remove --name connectedk8s
curl -L -o connectedk8s-1.10.0-py2.py3-none-any.whl https://github.com/AzureArcForKubernetes/azure-cli-extensions/raw/refs/heads/connectedk8s/public/cli-extensions/connectedk8s-1.10.0-py2.py3-none-any.whl   
az extension add --upgrade --source connectedk8s-1.10.0-py2.py3-none-any.whl --yes

#
# Arc enable the cluster
#
arc_query=$(az connectedk8s list --resource-group "$resource_group" --query "[?name=='$k8s_cluster_name']")
if [ "$arc_query" == "[]" ]; then
    echo -e "\nArc enabling the K8S cluster '$k8s_cluster_name'"
    #az connectedk8s connect --name ${k8s_cluster_name} --resource-group ${resource_group}
    #az connectedk8s connect --name ${k8s_cluster_name} -l ${location} --resource-group ${resource_group} --subscription ${subscription_id} --enable-oidc-issuer --enable-workload-identity
    az connectedk8s connect --name ${k8s_cluster_name} -l ${location} --resource-group ${resource_group} --subscription ${subscription_id} --enable-workload-identity
else
    echo "K8S cluster $k8s_cluster_name is already ARC enabled."
fi

# Get the cluster issuer URL.
issuer_url=$(az connectedk8s show --resource-group ${resource_group} --name ${k8s_cluster_name} --query oidcIssuerProfile.issuerUrl --output tsv)

# Prep config.yaml (/etc/rancher/k3s/config.yaml) -- only relevant if using K3S
tee config.yaml << EOF
kube-apiserver-arg:
 - service-account-issuer=${issuer_url}
 - service-account-max-token-expiration=24h
EOF

# Enable custom location support on your cluster.
# This command uses the objectId of the Microsoft Entra ID application that the Azure Arc service uses:
export OBJECT_ID=$(az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv)
az connectedk8s enable-features -n $k8s_cluster_name -g $resource_group --custom-locations-oid $OBJECT_ID --features cluster-connect custom-locations

# Install az extension
az extension add --upgrade --name azure-iot-ops

# Verify cluster
az iot ops verify-host

#
# To create a new key vault, with Permission model set to Vault access policy.
#
kv_query=$(az keyvault list --resource-group "$resource_group" --query "[?name=='$keyvault_name']")
if [ "$kv_query" == "[]" ]; then
    echo -e "\nCreating Key vault '$keyvault_name'"
    az keyvault create --enable-rbac-authorization false --name ${keyvault_name} --resource-group ${resource_group}
else
    echo "Key vault $keyvault_name already exists."
fi

#
# Create a storage account for schema registry
#
sa_query=$(az storage account list --resource-group "$resource_group" --query "[?name=='$storage_account_name']")
if [ "$sa_query" == "[]" ]; then
    echo -e "\nCreating Storage account '$storage_account_name'"
    az storage account create --name ${storage_account_name} --resource-group ${resource_group} --enable-hierarchical-namespace
else
    echo "Storage account $storage_account_name already exists."
fi

#
# Create a schema registry that connects to your storage account.
#
schema_registry_name=${k8s_cluster_name}sreg

sr_query=$(az iot ops schema registry list --resource-group "$resource_group" --query "[?name=='$schema_registry_name']")
if [ "$sr_query" == "[]" ]; then
    echo -e "\nCreating Schema registry '$schema_registry_name'"

    az iot ops schema registry create \
    --name ${schema_registry_name} \
    --resource-group ${resource_group} \
    --registry-namespace ${schema_registry_name}ns \
    --sa-resource-id $(az storage account show --name ${storage_account_name} --resource-group ${resource_group} -o tsv --query id)

else
    echo "Schema registry $schema_registry_name already exists."
fi

exit 0
