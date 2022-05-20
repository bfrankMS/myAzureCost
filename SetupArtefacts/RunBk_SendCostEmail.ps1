param (
    [parameter(Mandatory = $false,
        HelpMessage = "Enter a en-us formatted date e.g. '12/30/2019'")]
    [String]$myDate
)

[void][Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms") 
[void][Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms.DataVisualization")

#Loginto Azure subscription - Get Execution Context.
$connectionName = "AzureRunAsConnection"
$AzureSubscriptionId = "myAzureCostAzureSubscriptionId"
$storageAccount = Get-AutomationVariable -Name "myAzureCostStorageAccountName"
$containerName = Get-AutomationVariable -Name "myAzureCostSAContainer"
$UserCredential = Get-AutomationPSCredential -Name 'myAzureCostSmtpSender'
$smtpUser = $UserCredential.UserName
$smtpPassword = $UserCredential.Password
$smtpRecipient = Get-AutomationVariable -Name 'myAzureCostSmtpRecipient' 
$smtpServer = Get-AutomationVariable -Name 'myAzureCostSmtpServer'
$smtpServerSSLPort = Get-AutomationVariable -Name 'myAzureCostSmtpServerSSLPort'
$myAzureCostPriceSheetURI = Get-AutomationVariable -Name 'myAzureCostPriceSheetURI'
$myCultureInfo = Get-AutomationVariable -Name 'myAzureCostCultureInfo'
$tableName = Get-AutomationVariable -Name "myAzureCostSATable"

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
try {
    $startDate = [dateTime]::Parse($myDate)
}
catch {
    $startDate = [dateTime]::Today.AddDays(-1)      #default to yesterday
}
Write-Output "Processing Cost for date: $StartDate"

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

#region loading pricesheet data from blob storage
$priceListPath = "$Env:temp\$($(Split-Path $myAzureCostPriceSheetURI -Leaf) -replace "[\?]{1}.*",'')" 
"downloading pricelist..."
Invoke-WebRequest -Uri $myAzureCostPriceSheetURI -OutFile $priceListPath
"found in $($priceListPath): $(Test-Path $priceListPath)" 
if (!(Test-Path $priceListPath)) {
    "...no pricelist file found - exit!"
    $ErrorActionPreference = 'Stop'
    Get-Content $priceListPath
}
#endregion 

#selectively fill pricelist object
$uniqueMeterIDs = Import-Csv -Path $usagePath -Delimiter ';' -Encoding UTF8 | % { $_.MeterID } | Select-Object -Unique
$priceList = Import-Csv $priceListPath -Delimiter ';'  -Encoding UTF8 | where { $uniqueMeterIDs -contains $_.MeterId }

$usageEntries = Import-Csv -Path $usagePath -Delimiter ';' -Encoding UTF8
Write-Output 'Calculating costs...i.e.: Matching MeterIDs of usage to pricelist.'

#calculate usage
$costEntries = @()
foreach ($usageEntry in $usageEntries) {
    Write-Host "." -NoNewline
    $costEntries += $usageEntry | select-object UsageStartTime, UsageEndTime, MeterCategory, MeterSubCategory, MeterName, InstanceName, RG, Location, @{N = 'Quantity'; E = { [decimal]$_.Quantity } }, Unit, @{N = 'UnitPrice'; E = { $MeterID = $_.MeterId ; $price = [decimal]0;$price =[decimal]($priceList | where { $_.MeterId -eq $MeterID }).MeterRates ; $price } }, @{N = 'Estimated Costs'; E = { $MeterID = $_.MeterID ;  $price = [decimal]0;$price =[decimal]($priceList | where { $_.MeterId -eq $MeterID }).MeterRates; $price = ($price * [decimal]$_.Quantity) ; $price } } , MeterID, Tags
}

# reporting section
"========================"
"You have {0} items on your daily consumption list." -f $($costEntries.Count) 
"========================"
$totalCost = $($costEntries | Measure-Object 'Estimated Costs' -Sum).Sum
"They sum up to {0} in total for the day" -f $totalCost
"========================"

#region total costs per category
$costPerCat = $costEntries | Group-Object -Property MeterCategory | % { $Sum = ($_.Group | Measure-Object 'Estimated Costs' -Sum).Sum; $myobj = [PSCustomObject]@{Name = "$($_.Name)"; Count = $($_.Group.Count); Sum = $Sum; Percentage = [Math]::Round([decimal]((100 * $Sum) / $totalCost), 2) }; $myobj }
$costPerCatResult = @()
$costPerCatResult += ($costPerCat | Where-Object Percentage -GT 3 | Sort-Object Percentage -Descending)#.GetEnumerator()

$Sum = (($costPerCat | Where-Object Percentage -le 3) | Measure-Object Sum -Sum).Sum
$costPerCatResult += [PSCustomObject]@{Name = "other"; Count = (($costPerCat | Where-Object Percentage -le 3) | Measure-Object Count -Sum).Sum; Sum = $Sum; Percentage = [Math]::Round([decimal]((100 * $Sum) / $totalCost), 2) }
"========================"
"Total costs per category"
$costPerCatResult | Select-Object Name, Count, @{N = 'Sum'; E = { "{0:N2}" -f $_.Sum } }, @{N = 'Percentage'; E = { "{0:N2}%" -f $_.Percentage } } | ft -AutoSize
#endregion 

#region Top 10 consumers 
"========================"
"Top 10 consumers"
$costEntries | Sort-Object 'Estimated Costs' -Descending | Select-Object -First 10 | ft InstanceName, 'Estimated Costs', MeterName, MeterCategory | ft -AutoSize
#endregion 

#region Costs per RG
$costsPerRG = $costEntries | Group-Object -Property RG | % { $Sum = ($_.Group | Measure-Object 'Estimated Costs' -Sum).Sum; $myobj = [PSCustomObject]@{Name = "$($_.Name)"; Count = "$($_.Count)"; Sum = $Sum; Percentage = [Math]::Round([decimal]((100 * $Sum) / $totalCost), 2) }; $myobj }
$costsPerRGResult = @()
$costsPerRGResult += $costsPerRG | Where-Object Percentage -GT 3 | Sort-Object Percentage -Descending

$Sum = (($costsPerRG | Where-Object Percentage -le 3) | Measure-Object Sum -Sum).Sum
$costsPerRGResult += [PSCustomObject]@{Name = "other"; Count = (($costsPerRG | Where-Object Percentage -le 3) | Measure-Object Count -Sum).Sum; Sum = $Sum; Percentage = [Math]::Round([decimal]((100 * $Sum) / $totalCost), 2) }
"========================"
"Costs per RG"
$costsPerRGResult | ft -AutoSize
#endregion  

#region Costs per Region
$costsPerRegion = $costEntries | Group-Object -Property Location | % { $Sum = ($_.Group | Measure-Object 'Estimated Costs' -Sum).Sum; $myobj = [PSCustomObject]@{Name = "$($_.Name)"; Count = "$($_.Count)"; Sum = $Sum; Percentage = [Math]::Round([decimal]((100 * $Sum) / $totalCost), 2) }; $myobj }
$costsPerRegionResult = @()
$costsPerRegionResult += $costsPerRegion | Where-Object Percentage -GT 3 | Sort-Object Percentage -Descending

$Sum = (($costsPerRegion | Where-Object Percentage -le 3) | Measure-Object Sum -Sum).Sum
$costsPerRegionResult += [PSCustomObject]@{Name = "other"; Count = (($costsPerRegion | Where-Object Percentage -le 3) | Measure-Object Count -Sum).Sum; Sum = $Sum; Percentage = [Math]::Round([decimal]((100 * $Sum) / $totalCost), 2) }
"========================"
"Costs per Region"
$costsPerRegionResult | ft -AutoSize
#endregion

#region Top 3 consumers per category
$top3ConsumersPerCat = $costEntries | Group-Object -Property MeterCategory | % { $_.Group | sort-object 'Estimated Costs' -Descending | Select-Object -First 3 }
"========================"
"Top 3 consumers per category"
$top3ConsumersPerCat | ft InstanceName, 'Estimated Costs', MeterCategory -AutoSize
#endregion 

#region get history data from table
$cloudTable = (Get-AzStorageTable –Name $tableName –Context $ctx).CloudTable

#update or new
try {
    $entry = Get-AzTableRow -Table $cloudTable -PartitionKey $startDate.ToString('MMMM') -rowKey "$($startDate.ToString('dd'))"
    $entry.TotalCost = "{0:N2}" -f $totalCost
    $entry.Year = $startDate.Year
    $entry | Update-AzTableRow -table $cloudTable
}
catch {
    Add-AzTableRow -table $cloudTable -partitionKey $startDate.ToString('MMMM') `
        -rowKey "$($startDate.ToString('dd'))" -property @{"TotalCost" = $("{0:N2}" -f $totalCost); "Year" = $startDate.Year }
}

Get-AzTableRow -Table $cloudTable -PartitionKey $startDate.ToString('MMMM') -rowKey "$($startDate.ToString('dd'))"
#Get last 7 days
$last7Days = @()
for ($date = $startDate.AddDays(-6); $date -le $startDate; $date += [System.timespan]::new(1, 0, 0, 0)) { 
    $last7Days += Get-AzTableRow -Table $cloudTable -PartitionKey $date.ToString('MMMM') -rowKey "$($date.ToString('dd'))"
}

$last7Days | ft RowKey, PartitionKey, Year, TotalCost

#endregion

function MyChart ($titleText, $results, $chartType) {
    #region create series
    #Create a series of data points
    $costPerCatSeries = [System.Windows.Forms.DataVisualization.Charting.Series]::new("costPerCatSeries")

    foreach ($entry in $results.GetEnumerator()) {
        $dp = [System.Windows.Forms.DataVisualization.Charting.DataPoint]::new()
        $dp.AxisLabel = $($entry.Name)
        $dp.LegendText = "$($entry.Name) = $($entry.Sum)"
        $dp.YValues = @($entry.Sum)
        #$dp.SetValueY(
        $costPerCatSeries.Points.Add($dp)
    }
    #endregion 

    #region create chart
    #Create a chart and add the data series to it
    $myChart = [System.Windows.Forms.DataVisualization.Charting.Chart]::new()
    $myChart.Size = [System.Drawing.Size]::new(400, 400)
    $title = [System.Windows.Forms.DataVisualization.Charting.Title]::new()
    $title.Font = [System.Drawing.Font]::new("Calibri", 13)
    $title.Text = "$titleText"
    $myChart.Titles.Add($title)
    # Create Chart Area
    $chartArea1 = [System.Windows.Forms.DataVisualization.Charting.ChartArea]::new()
    # Add Chart Area to the Chart
    $myChart.ChartAreas.Add($chartArea1);
    $myChart.ChartAreas[0].AxisX.MajorGrid.Enabled = $false
    $myChart.ChartAreas[0].AxisY.MajorGrid.Enabled = $false
    $myChart.Series.Add($costPerCatSeries)

    $myChart.Series["costPerCatSeries"].ChartType = $chartType
    #AXISLABEL #LABEL #INDEX #PERCENT #LEGENDTEXT #SERIESNAME #LAST
    $myChart.Series["costPerCatSeries"].Label = "#AXISLABEL #PERCENT{P1}"# (#VALY{F2}) (#PERCENT)";
    $myChart.Series["costPerCatSeries"].Font = [System.Drawing.Font]::new("Calibri", 11)
    # Set labels style
    $myChart.Series["costPerCatSeries"]["PieLabelStyle"] = "Outside";
    # Set drawing style
    $myChart.Series["costPerCatSeries"]["PieDrawingStyle"] = "Concave";
    $myChart.Series["costPerCatSeries"]["PieLineColor"] = "Black";
        
    return $myChart
        
}

#region Mail object
"========================"
"creating mail object"
#mailing variables
$smtpSenderAddress = $smtpUser
if ((Get-AzContext).name -match "^(.*) - .*$") {
    $subscriptionName = $Matches[1]
}
else {
    $subscriptionName = (Get-AzContext).name
}

$smtpSubject = "Cost report of $($StartDate.ToString("yyyyMMdd")) for $subscriptionName"


#Create the .net email object
$mail = [System.Net.Mail.MailMessage]::new()
$mail.From = [System.Net.Mail.MailAddress]::new($smtpSenderAddress, "myAzureCost");
$smtpRecipients = $smtpRecipient -split "[,;]"
foreach ($smtpRecipient in $smtpRecipients)
{
    $mail.To.Add([System.Net.Mail.MailAddress]::new($smtpRecipient));
}
$mail.Subject = $smtpSubject;

#The content of the email is HTML
$htmlBody = @"
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN"  "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
<title>Your Azure Daily Consumption Report</title>
</head>
<body>
<p><h2>Hello,</h2></p>
<p>This is your daily report for subscription: <b>$subscriptionName</b>.</p>
<p>Date: <b>$($StartDate.ToString("d",$destculture))</b>.</p>
<p>You have <b>$("{0}" -f $($costEntries.Count)) items</b> on your daily consumption list.<br>
They sum up to <b>$("{0:N2}" -f $totalCost)</b> in total for the day.</p>
"@
$htmlBody += "<p><h3>Costs History:</h3>"
$htmlBody += "<table style=""width:auto; height: auto;""><tr><td><img src='cid:costHistoryChart'></td><td>"
$htmlBody += $($last7Days | Select-Object @{N = 'Day'; E = { "{0}" -f $_.RowKey } }, @{N = 'Month'; E = { "{0}" -f $_.PartitionKey } }, Year, TotalCost | ConvertTo-Html -Property Day, Month, Year, TotalCost -Fragment)
$htmlBody += "</td></tr></table></p>"
$htmlBody += "<p><h3>Costs Per Category:</h3>"
$htmlBody += "<table style=""width:auto; height: auto;""><tr><td><img src='cid:costsPerCatChart'></td><td>"
$htmlBody += $($costPerCatResult | Select-Object Name, Count, @{N = 'Sum'; E = { "{0:N2}" -f $_.Sum } }, @{N = 'Percentage'; E = { "{0:N2}%" -f $_.Percentage } } | ConvertTo-Html -Property Name, Count, Sum, Percentage -Fragment)
$htmlBody += "</td></tr></table></p>"
$htmlBody += "<p><h3>Top 10 Consumers:</h3>"
$htmlBody += $($costEntries | Sort-Object 'Estimated Costs' -Descending | Select-Object -First 10 | ConvertTo-Html -Property @{L = 'InstanceName'; E = { $($_.InstanceName -replace "(.{20})(.*)", '$1...') } }, @{L = 'Estimated Costs'; E = { $("{0:N2}" -f $($_.'Estimated Costs')) } }, MeterName, MeterCategory -Fragment)
$htmlBody += "</p>"
$htmlBody += "<p><h3>Costs per RG:</h3>"
$htmlBody += "<table style=""width:auto; height: auto;""><tr><td><img src='cid:costsPerRGChart'></td><td>"
$htmlBody += $($costsPerRGResult | Select-Object Name, Count, @{N = 'Sum'; E = { "{0:N2}" -f $_.Sum } }, @{N = 'Percentage'; E = { "{0:N2}%" -f $_.Percentage } } | ConvertTo-Html -Property Name, Count, Sum, Percentage -Fragment)
$htmlBody += "</td></tr></table></p>"
$htmlBody += "<p><h3>Costs Per Region:</h3>"
$htmlBody += "<table style=""width:auto; height: auto;""><tr><td><img src='cid:costsPerRegionChart'></td><td>"
$htmlBody += $($costsPerRegionResult | Select-Object Name, Count, @{N = 'Sum'; E = { "{0:N2}" -f $_.Sum } }, @{N = 'Percentage'; E = { "{0:N2}%" -f $_.Percentage } } | ConvertTo-Html -Property Name, Count, Sum, Percentage -Fragment)
$htmlBody += "</td></tr></table></p>"
$htmlBody += "</body></html>"

"Attaching chart to email content"
$aViewHTMLText = [System.Net.Mail.AlternateView]::CreateAlternateViewFromString($htmlBody, [System.Text.Encoding]::UTF8, "text/html")

$costsPerRGChart = MyChart "Cost Per Resource Group" $costsPerRGResult $([System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Bar)
$costsPerRGChart.ChartAreas[0].AxisX.Enabled = [System.Windows.Forms.DataVisualization.Charting.AxisEnabled]::True 
$costsPerRGChart.ChartAreas[0].AxisX.IsReversed = $true;
$costsPerRGChart.ChartAreas[0].AxisY.Enabled = [System.Windows.Forms.DataVisualization.Charting.AxisEnabled]::False
$costsPerRGChart.Series["costPerCatSeries"].Palette = [System.Windows.Forms.DataVisualization.Charting.ChartColorPalette]::BrightPastel
$costsPerRGChart.Series["costPerCatSeries"]["BarLabelStyle"] = "Outside";
$costsPerRGChart.Series["costPerCatSeries"].Label = "#PERCENT{P1}"
$costsPerRGChart.Series["costPerCatSeries"]["DrawSideBySide"] = $true
$costsPerRGChart.Series["costPerCatSeries"]["MaxPixelPointWidth"] = "30";
$costsPerRGChart.ChartAreas[0].InnerPlotPosition.Auto = $true;
$costsPerRGChart.ChartAreas[0].Position.Auto = $true;
$costsPerRGChart.Size = [System.Drawing.Size]::new(500, 350)
$costsPerRGChart.ChartAreas[0].AxisX.Interval = 1
$costsPerRGChart.ChartAreas[0].AxisX.IsLabelAutoFit = $True
$costsPerRGChart.Series["costPerCatSeries"].Font = [System.Drawing.Font]::new("Calibri", 11)

#embed the costsPerRGChart as image into the html body as linked resource 
$msImage1 = [System.IO.MemoryStream]::new()
$costsPerRGChart.SaveImage([System.IO.Stream]$msImage1, [System.Windows.Forms.DataVisualization.Charting.ChartImageFormat]::Png);
#reset stream position otherwhise picture will be 0 bytes.
$msImage1.Position = 0;
$lr = [System.Net.Mail.LinkedResource]::new([System.IO.Stream]$msImage1, "image/png");
$lr.ContentId = 'costsPerRGChart';
$aViewHTMLText.LinkedResources.Add($lr);

$costsPerCatChart = MyChart "Costs Per Category" $costPerCatResult $([System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Doughnut)

#embed the costsPerCatChart as image into the html body as linked resource 
$msImage2 = [System.IO.MemoryStream]::new()
$costsPerCatChart.SaveImage([System.IO.Stream]$msImage2, [System.Windows.Forms.DataVisualization.Charting.ChartImageFormat]::Png);
#reset stream position otherwhise picture will be 0 bytes.
$msImage2.Position = 0;
$lr2 = [System.Net.Mail.LinkedResource]::new([System.IO.Stream]$msImage2, "image/png");
$lr2.ContentId = 'costsPerCatChart';
$aViewHTMLText.LinkedResources.Add($lr2);


$costsPerRegionChart = MyChart "Costs Per Region" $costsPerRegionResult $([System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Pie)

#embed the costsPerRegionResult as image into the html body as linked resource 
$msImage3 = [System.IO.MemoryStream]::new()
$costsPerRegionChart.SaveImage([System.IO.Stream]$msImage3, [System.Windows.Forms.DataVisualization.Charting.ChartImageFormat]::Png);
#reset stream position otherwhise picture will be 0 bytes.
$msImage3.Position = 0;
$lr3 = [System.Net.Mail.LinkedResource]::new([System.IO.Stream]$msImage3, "image/png");
$lr3.ContentId = 'costsPerRegionChart';
$aViewHTMLText.LinkedResources.Add($lr3);


#region Last 7 days cost history chart
$last7DaysNormalized =  $last7Days | Select-Object @{N = 'Name'; E = { [System.DateTime]::ParseExact("$($_.Year)-$($_.PartitionKey)-$($_.RowKey)", "yyyy-MMMM-dd", [System.Globalization.CultureInfo]::CurrentCulture).ToString("d",$destculture)}},@{N = 'Sum'; E = { $_.TotalCost}}

$costHistoryChart = MyChart "Last 7 Days Cost History" $last7DaysNormalized $([System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Column)
$costHistoryChart.ChartAreas[0].AxisX.Enabled = [System.Windows.Forms.DataVisualization.Charting.AxisEnabled]::True 
$costHistoryChart.ChartAreas[0].AxisY.Enabled = [System.Windows.Forms.DataVisualization.Charting.AxisEnabled]::False
$costHistoryChart.ChartAreas[0].AxisX.ArrowStyle = [System.Windows.Forms.DataVisualization.Charting.AxisArrowStyle]::Triangle
$costHistoryChart.Series["costPerCatSeries"]["BarLabelStyle"] = "Outside";
$costHistoryChart.Series["costPerCatSeries"].Label = "#VALY"
$costHistoryChart.Series["costPerCatSeries"]["DrawSideBySide"] = $true
$costHistoryChart.Series["costPerCatSeries"]["MaxPixelPointWidth"] = "30";
$costHistoryChart.ChartAreas[0].InnerPlotPosition.Auto = $true;
$costHistoryChart.ChartAreas[0].Position.Auto = $true;
$costHistoryChart.Size = [System.Drawing.Size]::new(400, 270)
$costHistoryChart.ChartAreas[0].AxisX.Interval = 1
$costHistoryChart.ChartAreas[0].AxisX.IsLabelAutoFit = $True
$costHistoryChart.Series["costPerCatSeries"].Font = [System.Drawing.Font]::new("Calibri", 11)

$msImage4 = [System.IO.MemoryStream]::new()
$costHistoryChart.SaveImage([System.IO.Stream]$msImage4, [System.Windows.Forms.DataVisualization.Charting.ChartImageFormat]::Png);
#reset stream position otherwhise picture will be 0 bytes.
$msImage4.Position = 0;
$lr4 = [System.Net.Mail.LinkedResource]::new([System.IO.Stream]$msImage4, "image/png");
$lr4.ContentId = 'costHistoryChart';
$aViewHTMLText.LinkedResources.Add($lr4);
#endregion


#add the content to the mail object.
$mail.AlternateViews.Add($aViewHTMLText ); 

#adding attachments
$costEntriesName = "$Env:temp\$($StartDate.ToString("yyyyMMdd"))Costs.csv"
 
#>
$costEntries | Select-object @{N = 'UsageStartTime'; E = { "{0}" -f [System.DateTime]::Parse($_.UsageStartTime,[CultureInfo]::new("en-us")).ToString("d",$destculture) } }, @{N = 'UsageEndTime'; E = { "{0}" -f [System.DateTime]::Parse($_.UsageEndTime,[CultureInfo]::new("en-us")).ToString("d",$destculture) } } , MeterCategory, MeterSubCategory, MeterName, InstanceName, RG, Location, @{N = 'Quantity'; E = { $([decimal]$_.Quantity).ToString($destculture) } }, Unit, @{N = 'UnitPrice'; E = { $([decimal]$_.UnitPrice).ToString($destculture) } }, @{L = 'Estimated Costs'; E = { $([decimal]$_.'Estimated Costs').ToString($destculture) } }, MeterId, Tags | Export-Csv "$costEntriesName" -Encoding UTF8 -Delimiter ';' -NoTypeInformation -Force 
if ((Test-Path $costEntriesName )) {
    "...add cost as attachment"
    $contentType = [System.Net.Mime.ContentType]::new()
    $contentType.MediaType = [System.Net.Mime.MediaTypeNames+Application]::Octet
    $contentType.Name = "$(Split-Path $costEntriesName -leaf)";
    $attachment = [System.Net.Mail.Attachment]::new("$costEntriesName", $contentType)
    $mail.Attachments.Add($attachment)
}

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
$mailClient = [System.Net.Mail.SmtpClient]::new($smtpServer, $smtpServerSSLPort)
$mailClient.EnableSsl = $true
$mailClient.UseDefaultCredentials = $false; # Important: This line of code must be executed before setting the NetworkCredentials object, otherwise the setting will be reset (a bug in .NET)
$mailClient.Credentials = [System.Net.NetworkCredential]::new($smtpUser, $smtpPassword);
try
{
    $mailClient.Send($mail);
}
catch [Exception]
{
    Write-Host "Exception caught in Send - Exception info below:"
    $($_.Exception)
}
finally
{
    $mailClient.Dispose()
}
