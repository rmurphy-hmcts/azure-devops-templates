[CmdletBinding()]
Param (
  [Parameter(Mandatory = $true)]
  [string] $appName,
  [Parameter(Mandatory = $true)]
  [string] $appPrefix,
  [Parameter(Mandatory = $true)]
  [string] $resourceGroupName,
  [Parameter(Mandatory = $true)]
  [string] $subscriptionName,
    
  [Parameter(Mandatory = $true)]
  [string] $environment,
  [Parameter(Mandatory = $true)]
  [string] $businessArea,
  [Parameter(Mandatory = $true)]
  [string] $builtFrom,

    
  [Parameter(Mandatory = $true)]
  [string] $logAnalyticsSubscriptionId,
  [Parameter(Mandatory = $true)]
  [string] $logAnalyticsResourceGroup
)

#$subscriptionId = (Get-AzSubscription -SubscriptionName $subscriptionName).Id

$env = ""
if ($environment -ieq "sbox") { 
  $env = "sandbox" 
  $workspaceName = "hmcts-sandbox"
}
elseif ($environment -ieq "dev") { 
  $env = "development" 
  $workspaceName = "hmcts-nonprod"
}
elseif ($environment -ieq "stg") { 
  $env = "staging" 
  $workspaceName = "hmcts-nonprod"
}
elseif ($environment -ieq "prod") { 
  $env = "production" 
  $workspaceName = "hmcts-prod"
}
else { 
  $env = $environment 
  $workspaceName = "hmcts-nonprod"
}

$workspaceId = "/subscriptions/$logAnalyticsSubscriptionId/resourcegroups/$logAnalyticsResourceGroup/providers/microsoft.operationalinsights/workspaces/$workspaceName"
$tags = @{"application" = "$appName"; "businessArea" = $businessArea; "builtFrom" = $builtFrom; "environment" = $env; "criticality " = "low" }
$dnsZones = @('privatelink.oms.opinsights.azure.com', 'privatelink.ods.opinsights.azure.com', 'privatelink.agentsvc.azure-automation.net', 'privatelink.monitor.azure.com')

if (!(Get-Module -Name Az.MonitoringSolutions)) {
  Write-Host "Installing Az.MonitoringSolutions Module..." -ForegroundColor Yellow
  Install-Module -Name Az.MonitoringSolutions -Force -Verbose
  Write-Host "Az.MonitoringSolutions Module successfully installed..."
}
else {
  Write-Host "Az.MonitoringSolutions already installed, skipping" -ForegroundColor Green
}

Write-Host "Starting script"
$vnetName = "$appPrefix-sharedinfra-vnet-$environment"
$appInsightName = "$appPrefix-sharedinfra-appins-$environment"
$privateLinkName = "$appPrefix-privatelink-$environment"
$privateEndpointName = "$appPrefix-privateendpoint-$environment"
$privateLinkScopeName = "$appPrefix-apim-ampls-$environment"
$privateLinkScope = Get-AzInsightsPrivateLinkScope -Name $privateLinkScopeName -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue

if (!($privateLinkScope)) {
  $virtualNetwork = Get-AzVirtualNetwork -ResourceName $vnetName -ResourceGroupName $resourceGroupName
  $subnet = $virtualNetwork | Select-Object -ExpandProperty subnets | Where-Object Name -like 'mgmt-subnet-*'

  Write-Host "Create Azure Monitor Private Link Scope"
  $linkScope = (New-AzInsightsPrivateLinkScope -Location "global" -ResourceGroupName $resourceGroupName -Name $privateLinkScopeName)
  New-AzTag -ResourceId $linkScope.Id -Tag $tags
  $appins = (Get-AzApplicationInsights -ResourceGroupName $resourceGroupName -name $appInsightName)

  Write-Host "Add Azure Monitor Resource"
  New-AzInsightsPrivateLinkScopedResource -LinkedResourceId $workspaceId -Name $workspaceName -ResourceGroupName $resourceGroupName -ScopeName $linkScope.Name
  New-AzInsightsPrivateLinkScopedResource -LinkedResourceId $appins.Id -Name $appins.Name -ResourceGroupName $resourceGroupName -ScopeName $linkScope.Name

  #Write-Host "Set up Private Endpoint Connection"
  #$PrivateLinkResourceId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/microsoft.insights/privateLinkScopes/" + $linkScope.Name
  #$linkedResource = Get-AzPrivateLinkResource -PrivateLinkResourceId $PrivateLinkResourceId
  
  $group = @("azuremonitor")
  $privateEndpointConnection = New-AzPrivateLinkServiceConnection -GroupId $group -Name $privateLinkName -PrivateLinkServiceId $linkScope.Id

  $privateEndpoint = New-AzPrivateEndpoint -ResourceGroupName $resourceGroupName -Name $privateEndpointName -Location "uksouth" -Subnet $subnet -PrivateLinkServiceConnection $privateEndpointConnection
  New-AzTag -ResourceId $privateEndpoint.Id -Tag $tags
  New-AzTag -ResourceId $privateEndpoint.NetworkInterfaces.Id -Tag $tags

  Write-Host "Create Private DNS Zones"
 
  $zoneConfigs = @()

  foreach ($_ in $dnsZones) {
    Write-Host "Creating DNS Zone " $_
    $zone = New-AzPrivateDnsZone -ResourceGroupName $resourceGroupName -Name $_
    New-AzTag -ResourceId $zone.ResourceId -Tag $tags

    New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $resourceGroupName `
      -ZoneName $_ `
      -Name "dnsZoneLink" `
      -VirtualNetworkId $virtualNetwork.Id

    $zoneConfigs += (New-AzPrivateDnsZoneConfig -Name $_ -PrivateDnsZoneId $zone.ResourceId)
  }

  Write-Host "Linking DNS Zones to endpoint..."
  New-AzPrivateDnsZoneGroup -ResourceGroupName $resourceGroupName `
    -PrivateEndpointName $privateEndpointName `
    -name "azure-monitor-dns-zone" `
    -PrivateDnsZoneConfig $zoneConfigs -Force

  Write-Host "Finished."

}
else {
  Write-Host "Azure Private Link Scope already exists. Exiting."
  Write-Host "Updateing Tags"

  $privateLinkScopeId = $privateLinkScope.Id
  Write-Host "Updateing PrivateLinkScope Tags $privateLinkScopeId"
  Update-AzTag -ResourceId $privateLinkScopeId -Tag $tags -Operation Replace

  try {
    Write-Host "Updateing PrivateEndpoint Tags $privateEndpointName"
    $privateEndpoint = Get-AzPrivateEndpoint -ResourceGroupName $resourceGroupName -Name $privateEndpointName
    Update-AzTag -ResourceId $privateEndpoint.Id -Tag $tags -Operation Replace
    Update-AzTag -ResourceId $privateEndpoint.NetworkInterfaces.Id -Tag $tags -Operation Replace
  }
  catch {
    ## Failed
  }

  foreach ($_ in $dnsZones) {
    try {
      Write-Host "Updateing $_ DNS Zone Tags"
      $zone = Get-AzPrivateDnsZone -ResourceGroupName $resourceGroupName -Name $_
      Update-AzTag -ResourceId $zone.ResourceId -Tag $tags -Operation Replace
    }
    catch {
      ## Failed
    }
  }
}