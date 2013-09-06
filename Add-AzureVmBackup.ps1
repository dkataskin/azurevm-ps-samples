<#
.Synopsis
   Backup an existing VM with only an OS disk to a new blob.
.DESCRIPTION
   Backup an existing VM. The VM has to have an OS disk and no data disks.

   The backups are made as copies of the backing disk blob, with the name convention:
   <Name of the backing blob of the OS disk, without the .vhd extension>_v_<serviceName>-<vmName>_b_<date in yyyy-mm-dd format>-<backup number of the day>.vhd"
.EXAMPLE
   .\Add-AzureVmBackup.ps1 -ServiceName aService -Name aVm
.INPUTS
   None
.OUTPUTS
   None
#>
Param
(
    # Service the VM is running on
    [Parameter(Mandatory=$true)]
    [String]
    $ServiceName, 

    # Name of the VM
    [Parameter(Mandatory=$true)]
    [String]
    $Name
)

# The script has been tested on Powershell 3.0
Set-StrictMode -Version 3

# Following modifies the Write-Verbose behavior to turn the messages on globally for this session
$VerbosePreference = "Continue"

# Check if Windows Azure Powershell is avaiable
if ((Get-Module -ListAvailable Azure) -eq $null)
{
    throw "Windows Azure Powershell not found! Please install from http://www.windowsazure.com/en-us/downloads/#cmd-line-tools"
}

$vm = Get-AzureVM -ServiceName $ServiceName -Name $Name -ErrorAction SilentlyContinue

if ($vm -eq $null)
{
    throw "A virtual machine with name $Name on $ServiceName does not exist."
}

$vmStopped = $false
if ($vm.InstanceStatus -eq "ReadyRole" -and $vm.PowerState -eq "Started")
{
    Stop-AzureVM -ServiceName $ServiceName -Name $Name -StayProvisioned
    $vmStopped = $true
}

$osDiskMediaLinkUri = [System.Uri]$vm.VM.OSVirtualHardDisk.MediaLink

if ($osDiskMediaLinkUri.Segments.Count -gt 3)
{
    throw "Disk containers only one level deep supported"
}

# If it is a 3 part segment, first part willbe / second will be the container name, and third part will be the blob name
$containerName = $osDiskMediaLinkUri.Segments[1].Replace("/","")
$osDiskBlobName = $osDiskMediaLinkUri.Segments[2]

$storageAccountName = $osDiskMediaLinkUri.Host.Split(".")[0]

$currentAzureSubscription = Get-AzureSubscription -Current
$currentStorageAccountName = $currentAzureSubscription.CurrentStorageAccount

# Change the current storage account
if ($storageAccountName -ne $currentStorageAccountName)
{
    Set-AzureSubscription -SubscriptionName $currentAzureSubscription.SubscriptionName -CurrentStorageAccount $storageAccountName
}

$backupNameDelimeter = "_b_"
$diskDelimeter = "_d_"

$machineRef = $ServiceName + "-" + $Name
$dateRef = Get-Date -Format "yyyy-MM-dd"
$diskNumberPattern = "[0-9][0-9]"
$backNameRegex = $machineRef + $backupNameDelimeter + $diskNumberPattern + $diskDelimeter + $dateRef + "-" + "[0-9]{4}\.vhd$"
$backupNamePrefix = $machineRef + $backupNameDelimeter + "00" + $diskDelimeter + $dateRef + "-"

$existingBackups = Get-AzureStorageBlob -Container $containerName | Where-Object {$_.Name -match "$backNameRegex"} | Select-Object Name

$backupNumber = 0
if($existingBackups -ne $null)
{
    $latestBackup = $existingBackups | ForEach-Object {[int]$_.Name.Substring($backupNamePrefix.Length, ($_.Name.Length - $backupNamePrefix.Length - 4))} | Get-Unique | Measure-Object -Maximum
    $backupNumber = $latestBackup.Maximum + 1 
}

$backupNameSuffix = "{0:0000}" -f $backupNumber + ".vhd"

$copiedBlobs = @()
# Backup the OS disk first
$diskNumber = 0
$backupNamePrefix = $machineRef + $backupNameDelimeter + "{0:00}" -f $diskNumber + $diskDelimeter
$backupName = $backupNamePrefix + $dateRef + "-" + $backupNameSuffix
$copiedBlobs += Start-AzureStorageBlobCopy -SrcContainer $containerName -SrcBlob $osDiskBlobName -DestContainer $containerName -DestBlob $backupName

foreach ($disk in $vm.VM.DataVirtualHardDisks)
{
    $diskNumber += 1
    $backupNamePrefix = $machineRef + $backupNameDelimeter + "{0:00}" -f $diskNumber + $diskDelimeter
    $backupName = $backupNamePrefix + $dateRef + "-" + $backupNameSuffix
    $copiedBlobs += Start-AzureStorageBlobCopy -SrcContainer $containerName -SrcBlob $osDiskBlobName -DestContainer $containerName -DestBlob $backupName
}

do
{
    Start-Sleep -Seconds 10
    $statusCollection = $copiedBlobs | ForEach-Object {Get-AzureStorageBlobCopyState -ICloudBlob $_.ICloudBlob}
    $copyDone = $true
    foreach ($status in $statusCollection)
    {
        $copyDone = $copyDone -and ($status.Status -eq "Success")    
    }
}
until ($copyDone)

# Restore the original CurrentStorageAccount setting
Set-AzureSubscription -SubscriptionName $currentAzureSubscription.SubscriptionName -CurrentStorageAccount $currentStorageAccountName

if ($vmStopped)
{
    Start-AzureVM -ServiceName $ServiceName -Name $Name
}