#!/bin/bash

# load environment variables
set -a && source .env && set +a

# Required variables
required_vars=(
    "resource_group"
    "location"
    "aio_instance"
    "asset_endpoint_profile"
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
   #RG_ID=$(az group show --name $RESOURCE_GROUP --query id -o tsv)
fi

#
# Create Asset endpoint profile
#

ae_query=$(az iot ops asset endpoint query --instance ${aio_instance} --query "[?name=='$asset_endpoint_profile']")
if [ "$ae_query" == "[]" ]; then
   echo -e "\nCreating Asset endpoint '$asset_endpoint_profile'"
   az iot ops asset endpoint create opcua --name ${asset_endpoint_profile} --resource-group ${resource_group} --instance ${aio_instance} --target-address "opc.tcp://opcdummy:55555"
else
   echo "Asset endpoint $asset_endpoint_profile already exists."
fi

#
# Create Assets
#
jsonData=$( cat assets.json )

for row in $(echo $jsonData | jq -r '.[] | @base64'); do
   _jq() {
      echo "${row}" | base64 -di | jq -r "${1}"
   }

   # Set each property of the row to a variable
   ASSET_NAME=$(_jq '.asset')
   DESCRIPTION=$(_jq '.description')
   LOCATION=$(_jq '.location')
   echo "asset=$ASSET_NAME ; description=$DESCRIPTION ; location=$LOCATION"

   # Create asset
   asset_query=$(az iot ops asset query --instance ${aio_instance} --query "[?name=='$ASSET_NAME']")
   if [ "$asset_query" == "[]" ]; then
      echo -e "\nCreating Asset '$ASSET_NAME'"
      az iot ops asset create \
      --name "${ASSET_NAME}" \
      -g ${resource_group} \
      --instance ${aio_instance} \
      --endpoint-profile ${asset_endpoint_profile} \
      --description "${DESCRIPTION} ${ASSET_NAME}" \
      --custom-attribute "location=${LOCATION}" \
      --topic-path "devices/${ASSET_NAME}/telemetry"
   else
      echo "Asset $ASSET_NAME already exists."
   fi

done





