subId=$(az account show --query "id" -o tsv)
echo "Subscription ID: ${subId}"

restUrl="https://management.azure.com/subscriptions/${subId//[$'\t\r\n']/}/providers/Microsoft.ApiManagement/locations/${resourceLocation//[$'\t\r\n']/}/deletedservices/${resourceName//[$'\t\r\n']/}?api-version=2020-06-01-preview"
echo "Calling: ${restUrl}"

available=true
if response=$(az rest --method GET --uri ${restUrl} --query "properties.scheduledPurgeDate" -o tsv); then

  echo "Resource Expiry: $response"
  if [[ $response != "" ]]; then
    expectedPurgeDate=$(date --date='-2 day' --utc +%FT%T.%3NZ)
    responsePurgeDate=$(date -d $response --utc +%FT%T.%3NZ)
    echo "Expected expiry ${expectedPurgeDate}"

    if [[ $responsePurgeDate < $expectedPurgeDate ]]; then
      echo "Resource exists in error in the Deleted Service"
      echo "Purge date is longer then 48 hours. Value: ${responsePurgeDate}"
      available=true
    else
      echo "Resource exists in the Deleted Service"
      available=false
    fi

  else
    echo "Resource doesn't exist in the Deleted Service"
    available=true
  fi

else

  echo "Resource doesn't exist in the Deleted Service"
  available=true
fi
