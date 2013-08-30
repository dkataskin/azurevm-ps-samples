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

if ($vm.VM.DataVirtualHardDisks.Count > 0)
{
    throw "VM has $($vm.VM.DataVirtualHardDisks.Count) data disks, cannot continue. Script is supported only for VMs `
        with having an OS disk only"
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
$diskBlobName = $osDiskMediaLinkUri.Segments[2]

$storageAccountName = $osDiskMediaLinkUri.Host.Split(".")[0]

$currentAzureSubscription = Get-AzureSubscription -Current
$currentStorageAccountName = $currentAzureSubscription.CurrentStorageAccount

# Change the current storage account
if ($storageAccountName -ne $currentStorageAccountName)
{
    Set-AzureSubscription -SubscriptionName $currentAzureSubscription.SubscriptionName -CurrentStorageAccount $storageAccountName
}

$baseName = ""
if ($diskBlobName.EndsWith(".vhd"))
{
    # Remove the trailing .vhd
    $baseName = $diskBlobName.Substring(0, ($diskBlobName.Length - 4))
}
else
{
    $baseName = $diskBlobName
}

if ($baseName -eq "")
{
    throw "Could not extract the base disk name."
}

$backupNamePrefix = "_v_" + $ServiceName + "-" + $Name + "_b_" + (Get-Date -Format "yyyy-MM-dd") + "-"

$existingBackups = Get-AzureStorageBlob -Container $containerName | Where-Object {$_.Name -ilike "$($baseName + $backupNamePrefix)*"} | Select-Object Name

$backupNumber = 0
if($existingBackups -ne $null)
{
    $baseAndBackupNameLength = $($baseName + $backupNamePrefix).Length
    $latestBackup = $existingBackups | ForEach-Object {[int]$_.Name.Substring($($baseName + $backupNamePrefix).Length, ($_.Name.Length - $baseAndBackupNameLength - 4))} | Measure-Object -Maximum
    $backupNumber = $latestBackup.Maximum + 1 
}

$backupName = $baseName + $backupNamePrefix + "{0:0000}" -f $backupNumber + ".vhd"


$copiedBlob = Start-AzureStorageBlobCopy -SrcContainer $containerName -SrcBlob $diskBlobName -DestContainer $containerName -DestBlob $backupName

$status = $null
do
{
    Start-Sleep -Seconds 10
    $status = Get-AzureStorageBlobCopyState -ICloudBlob $copiedBlob.ICloudBlob
}
until ($status.Status -eq "Success")

# Restore the original CurrentStorageAccount setting
Set-AzureSubscription -SubscriptionName $currentAzureSubscription.SubscriptionName -CurrentStorageAccount $currentStorageAccountName

if ($vmStopped)
{
    Start-AzureVM -ServiceName $ServiceName -Name $Name
}