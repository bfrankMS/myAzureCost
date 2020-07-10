#Loginto Azure subscription - Get Execution Context.
$connectionName = "AzureRunAsConnection"
$AzureSubscriptionId = "myAzureCostAzureSubscriptionId"
$storageAccount = Get-AutomationVariable -Name "myAzureCostStorageAccountName"
$tableName = Get-AutomationVariable -Name "myAzureCostSATable"

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

    $RGName = (Get-AzResource -Name $storageAccount -ResourceType 'Microsoft.Storage/storageAccounts').ResourceGroupName
    $sa = Get-AzStorageAccount -Name $storageAccount -ResourceGroupName $RGName
    $ctx = $sa.Context
    
    New-AzStorageTable –Name $tableName –Context $ctx -Verbose 
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