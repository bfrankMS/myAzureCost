param (
    [parameter(Mandatory = $true,
        HelpMessage = "Enter a tag label e.g. 'ms-resource-usage'")]
    [String]$tagLabel,
    [parameter(Mandatory = $true,
        HelpMessage = "Enter a tag value e.g. 'azure-cloud-shell'")]
    [String]$tagValue
)

$date = [dateTime]::Today.AddMonths(-1)
$year = $date.Year
$month = $date.Month

$startOfMonth = Get-Date -Year $year -Month $month -Day 1 -Hour 0 -Minute 0 -Second 0 -Millisecond 0
$endOfMonth = $startOfMonth.AddMonths(1).AddDays(-1).AddHours(23)

$ConsumptionDate = $startOfMonth
$EndDate = $endOfMonth

Write-Output "Get consumption between $($ConsumptionDate.ToString("dd'/'MM'/'yyyy")) and $($EndDate.ToString("dd'/'MM'/'yyyy"))"

#Loginto Azure subscription - Get Execution Context.
$connectionName = "AzureRunAsConnection"
$AzureSubscriptionId = "myAzureCostAzureSubscriptionId"
$storageAccount = Get-AutomationVariable -Name "myAzureCostStorageAccountName"
$containerName = Get-AutomationVariable -Name "myAzureCostSAContainer"

try {
    # Get the connection "AzureRunAsConnection "
    $servicePrincipalConnection = Get-AutomationConnection -Name $connectionName  
    $subscriptionID = Get-AutomationVariable -Name $AzureSubscriptionId  

    "Logging in to Azure..."
    $account = Login-AzAccount `
        -ServicePrincipal `
        -TenantId $servicePrincipalConnection.TenantId `
        -ApplicationId $servicePrincipalConnection.ApplicationId `
        -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint `
        -Environment AzureCloud

    Set-AzContext -SubscriptionId $subscriptionID

    $UsageAggregations = @()
    $ErrorActionPreference = "SilentlyContinue"
    $UsageAggregates = $null
    do {
        if ($UsageAggregates.ContinuationToken) {
            "continue"
            $UsageAggregates = Get-UsageAggregates -ContinuationToken $($UsageAggregates.ContinuationToken) -ShowDetails $true -Verbose -ReportedStartTime $ConsumptionDate -ReportedEndTime $EndDate -AggregationGranularity Hourly
        }
        else {
            "first data"
            $UsageAggregates = Get-UsageAggregates -ShowDetails $true -Verbose -ReportedStartTime $ConsumptionDate -ReportedEndTime $EndDate -AggregationGranularity Hourly
        }

        foreach ($item in $UsageAggregates.UsageAggregations) {
            $UsageAggregations += $item
        }
    }
    while ($UsageAggregates.ContinuationToken)

    $UsageToExport = $UsageAggregations | % { $_.Properties | select-object UsageStartTime, UsageEndTime, MeterCategory, MeterSubCategory, MeterName, @{N = 'InstanceName'; E = { ($_.InstanceData | ConvertFrom-Json).'Microsoft.Resources'.resourceUri.Split('/') | select -Last 1 } }, @{N = 'RG'; E = { ($_.InstanceData | ConvertFrom-Json).'Microsoft.Resources'.resourceUri.Split('/')[4] } }, @{N = 'Location'; E = { ($_.InstanceData | ConvertFrom-Json).'Microsoft.Resources'.location } }, @{N = 'Quantity'; E = { $_.Quantity } }, Unit, MeterId, @{N = 'Tags'; E = { ($_.InstanceData | ConvertFrom-Json).'Microsoft.Resources'.tags } } } | where { ($(get-Date $_.UsageStartTime) -ge $(Get-date $ConsumptionDate.ToShortDateString()) -and ($(get-Date $_.UsageStartTime) -lt $(Get-date $EndDate.ToShortDateString())) -and (($_.Tags -like "*$tagLabel=$tagValue*"))) } 
    
    # sum up quantities of instances with same MeterID, date and rg 
    $data = $UsageToExport | Group-Object InstanceName, RG, MeterID
    $result = @()
    $result += foreach ($item in $data) {
        $item.Group | Select-Object -Unique @{N = 'UsageStartTime'; E = { $($ConsumptionDate.ToString("d")) } }, @{N = 'UsageEndTime'; E = { $($EndDate.ToString("d")) } }, MeterCategory, MeterSubCategory, MeterName, InstanceName, RG, Location, @{Name = 'Quantity'; Expression = { (($item.Group) | Measure-Object -Property Quantity -sum).Sum } }, Unit, MeterId, Tags
    }

    $result | Export-Csv "$Env:temp/Usage.csv" -Encoding UTF8 -Delimiter ';' -NoTypeInformation

    $RGName = (Get-AzResource -Name $storageAccount -ResourceType 'Microsoft.Storage/storageAccounts').ResourceGroupName
    $sa = Get-AzStorageAccount -Name $storageAccount -ResourceGroupName $RGName
    $ctx = $sa.Context
    Set-AzStorageBlobContent -Container $containerName -Context $ctx -File "$Env:temp/Usage.csv" -Blob "$($ConsumptionDate.ToString("yyyyMMdd"))-$($EndDate.ToString("yyyyMMdd"))-Consumption.csv" -Force
}
catch {
    if (!$servicePrincipalConnection) {
        $ErrorMessage = "Connection $connectionName not found."
        throw $ErrorMessage
    }
    else {
        Write-Error -Message $_.Exception
        throw $_.Exception
    }
} 
Write-Output $account