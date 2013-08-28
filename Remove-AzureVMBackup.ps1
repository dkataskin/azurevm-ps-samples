<#
.Synopsis
   Given a VM OS disk backed up by the Backup-AzureVM.ps1 script, purge the old backups before the last N given.
.DESCRIPTION
   Purge the old backups of a given VM, with one single disk. Any previous backups, before the last N, being used by a VM are skipped. 
.EXAMPLE
   .\Add-DomainControllerAndMemberServer.ps1 -ServiceName AService -Location "West US" -DomainControllerName dc `
        -VNetName dcvnet -MemberServerName mem
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
    $Name,

    # Last N backups to keep
    [Parameter(Mandatory=$true)]
    [String]
    $Keep
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

$osDiskMediaLinkUri = [System.Uri]$vm.VM.OSVirtualHardDisk.MediaLink

if ($osDiskMediaLinkUri.Segments.Count -gt 3)
{
    throw "Disk containers only one level deep supported"
}

# If it is a 3 part segment, first part willbe / second will be the container name, and third part will be the blob name
$containerName = $osDiskMediaLinkUri.Segments[1].Replace("/","")
$diskBlobName = $osDiskMediaLinkUri.Segments[2]

$storageAccountName = $osDiskMediaLinkUri.Host.Split(".")[0]

$currentAzureSubscription = Get-AzureSubscription  | Where-Object {$_.IsDefault}
$currentStorageAccountName = $currentAzureSubscription.CurrentStorageAccount

# Change the current storage account
if ($storageAccountName -ne $currentStorageAccountName)
{
    Set-AzureSubscription -SubscriptionName $currentAzureSubscription.SubscriptionName -CurrentStorageAccount $storageAccountName
}

function Get-AzurevmBackups
{
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

    $baseName = ""
    $suffixLength = 0
    if ($diskBlobName.EndsWith(".vhd"))
    {
        # Remove the trailing .vhd
        $baseName = $diskBlobName.Substring(0, ($diskBlobName.Length - 4))
        $suffixLength = 4
    }
    else
    {
        $baseName = $diskBlobName
    }

    if ($baseName -eq "")
    {
        throw "Could not extract the base disk name."
    }

    $existingBackups = Get-AzureStorageBlob -Container $containerName | Where-Object {$_.Name -ilike "$($baseName)b*"} | Select-Object Name


    $backupNamePrefix = "b"

    $foundBackups = @{}

    if($existingBackups -ne $null)
    {
        $baseAndBackupNameLength = $($baseName + $backupNamePrefix).Length
        $existingBackups | ForEach-Object {$foundBackups.Add([int]($_.Name.Substring($baseAndBackupNameLength, ($_.Name.Length - $baseAndBackupNameLength - $suffixLength)).Replace("-", "")), $_.Name)} 
    }

    $foundBackups | Sort-Object -Property Name -Descending 
}

$backups = Get-AzureVmBackups -ServiceName $ServiceName -Name $Name

$existingVmOsDisks = @()

$vms = Get-AzureVM 

foreach ($vm in $vms)
{
    $vmDetails = Get-AzureVM -ServiceName $vm.ServiceName -Name $vm.Name
   if (([System.Uri]$vmDetails.VM.OSVirtualHardDisk.MediaLink).Segments.Count -eq 3) 
   {
        $existingVmOsDisks += ([System.Uri]$vmDetails.VM.OSVirtualHardDisk.MediaLink).Segments[2]
   } 
}

$index = 1
$backupIds = $backups.Keys | Sort-Object -Descending

foreach ($key in $backupIds)
{
    if ($index++ -gt $Keep)
    {
        if (-not($existingVmOsDisks -contains $backups[$key]))
        {
            Remove-AzureStorageBlob -Container $containerName -Blob $backups[$key]
        }
    }    
}

# Restore the original CurrentStorageAccount setting
Set-AzureSubscription -SubscriptionName $currentAzureSubscription.SubscriptionName -CurrentStorageAccount $currentStorageAccountName
