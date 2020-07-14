[void][Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms") 
[void][Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms.DataVisualization")

#Loginto Azure subscription - Get Execution Context.
$connectionName = "AzureRunAsConnection"
$AzureSubscriptionId = "myAzureCostAzureSubscriptionId"
$storageAccount = Get-AutomationVariable -Name "myAzureCostStorageAccountName"
$containerName = Get-AutomationVariable -Name "myAzureCostSAContainer"
$UserCredential = Get-AutomationPSCredential -Name 'myAzureCostSendgrid'
$smtpUser = $UserCredential.UserName
$smtpPassword = $UserCredential.Password
$smtpRecipient = Get-AutomationVariable -Name 'myAzureCostSmtpRecipient' 
$myCultureInfo = Get-AutomationVariable -Name 'myAzureCostCultureInfo'

try
{
    "...attachments destination culture: $myCultureInfo"
    $destculture = [CultureInfo]::new("$myCultureInfo")
}
catch [System.Globalization.CultureNotFoundException]
{
    "$myCultureInfo did not work ... using en-US instead."
    $destculture = [CultureInfo]::new("en-US")
}

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

    "Setting subscription context to $subscriptionID..."
    Set-AzContext -SubscriptionId $subscriptionID
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
"Login result:" 
Write-Output $account

#region loading usage data from blob storage
$StartDate = [datetime]::Today.AddDays(-1)
$fileName = "$($StartDate.ToString("yyyyMMdd"))Consumption.csv"

"Get latest consumption file from blob...$fileName"
$RGName = (Get-AzResource -Name $storageAccount -ResourceType 'Microsoft.Storage/storageAccounts').ResourceGroupName
"$RGName"
$sa = Get-AzStorageAccount -Name $storageAccount -ResourceGroupName $RGName
$ctx = $sa.Context
$blob = Get-AzStorageBlob -Container $containerName -Context $ctx -Blob "$fileName"
"found: $($blob.Name)"
$token = New-AzStorageBlobSASToken -Context $ctx  -CloudBlob $($blob.ICloudBlob) -StartTime ([datetime]::Now).AddHours(-1) -ExpiryTime ([datetime]::Now).AddHours(1) -Permission 'r'
$uri = "https://$storageAccount.blob.core.windows.net/$containerName/$fileName$token"
$usagePath = "$Env:temp\$($(Split-Path $uri -Leaf) -replace "[\?]{1}.*",'')" 
"downloading usage..."
Invoke-WebRequest -Uri $uri -OutFile $usagePath
"found in $($usagePath): $(Test-Path $usagePath)" 
if (!(Test-Path $usagePath)) {
    "...no usage file found - exit!"
    $ErrorActionPreference = 'Stop'
    Get-Content $usagePath
}
#endregion

$usageEntries = Import-Csv -Path $usagePath -Delimiter ';' -Encoding UTF8
Write-Output 'importing usage file'

#region Mail object
"========================"
"creating mail object"
#mailing variables
$smtpServer = "smtp.sendgrid.net"
$smtpSenderAddress = $smtpUser
if ((Get-AzContext).name -match "^(.*) - .*$")
{
    $subscriptionName = $Matches[1]
}else {
    $subscriptionName = (Get-AzContext).name
}

$smtpSubject = "Usage report of $($StartDate.ToString("yyyyMMdd")) for $subscriptionName"

#Create the .net email object
$mail = [System.Net.Mail.MailMessage]::new()
$mail.From = [System.Net.Mail.MailAddress]::new($smtpSenderAddress, "myAzureCost");
$mail.To.Add([System.Net.Mail.MailAddress]::new($smtpRecipient));
$mail.Subject = $smtpSubject;

#The content of the email is HTML
$htmlBody = @"
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN"  "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
<title>Your Azure Daily Usage Email</title>
</head>
<body>
<p><h2>Hello,</h2></p>
<p>This is your daily usage report of <b>$($StartDate.ToString("d",$destculture))</b> for subscription: <b>$subscriptionName</b>.</p>
<p>(cultureinfo: <b>$myCultureInfo.</b>)</p>
<p>hope you'll find it useful.</p>
"@
$htmlBody += "</body></html>"

"Attaching chart to email content"
$aViewHTMLText = [System.Net.Mail.AlternateView]::CreateAlternateViewFromString($htmlBody, [System.Text.Encoding]::UTF8, "text/html")

#add the content to the mail object.
$mail.AlternateViews.Add($aViewHTMLText ); 

$transformedUsagePath = "$Env:temp\$($StartDate.ToString("yyyyMMdd"))ConsumptionCulture.csv"
$usageEntries | Select-object @{N = 'UsageStartTime'; E = { "{0}" -f [System.DateTime]::Parse($_.UsageStartTime,[CultureInfo]::new("en-us")).ToString("d",$destculture) } }, @{N = 'UsageEndTime'; E = { "{0}" -f [System.DateTime]::Parse($_.UsageEndTime,[CultureInfo]::new("en-us")).ToString("d",$destculture) } }, MeterCategory, MeterSubCategory, MeterName, InstanceName, RG, Location, @{N = 'Quantity'; E = { $([decimal]$_.Quantity).ToString($destculture) } }, Unit, MeterId, Tags | Export-Csv "$transformedUsagePath" -Encoding UTF8 -Delimiter ';' -NoTypeInformation

if ((Test-Path $transformedUsagePath )) {
    "...add usage as attachment"
    $contentType = [System.Net.Mime.ContentType]::new()
    $contentType.MediaType = [System.Net.Mime.MediaTypeNames+Application]::Octet
    $contentType.Name = "$(Split-Path $transformedUsagePath -leaf)";
    $attachment = [System.Net.Mail.Attachment]::new("$transformedUsagePath", $contentType)
    $mail.Attachments.Add($attachment)
}

"Sending mail"
#send the mail.
$mailClient = [System.Net.Mail.SmtpClient]::new($smtpServer, 25)
$mailClient.Credentials = [System.Net.NetworkCredential]::new($smtpUser, $smtpPassword);
$mailClient.Send($mail);