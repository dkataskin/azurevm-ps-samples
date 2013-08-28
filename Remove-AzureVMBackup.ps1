﻿<#
.Synopsis
   Given a VM OS disk backed up by the Backup-AzureVM.ps1 script, purge the old backups before the last N given. This scripts
   assumes the backups are stored on the storage account pointed by the current subscription's CurrentStorageAccount property
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

    # Name of the container where the backups are kept
    [Parameter(Mandatory=$false)]
    [String]
    $ContainerName = "vhds",


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

$BackupVmPrevix = "_v_"
$backupNamePrefix = "_b_"

$existingBackups = Get-AzureStorageBlob -Container $ContainerName | Where-Object {$_.Name -ilike $("*" + $BackupVmPrevix + $ServiceName + "-" + $Name + $backupNamePrefix +"*")} | Select-Object Name

$foundBackups = @()

if($existingBackups -ne $null)
{
    foreach ($existingBackup in $existingBackups)
    {
        # parse the name
        $parts = $existingBackup.Name -Split $BackupVmPrevix
        if ($parts.Count -ne 2)
        {
            throw "Unexpected backup format for blob name $existingBackup"
        }

        $baseName = $parts[0]

        $parts = $parts[1] -split $backupNamePrefix
        if ($parts.Count -ne 2)
        {
            throw "Unexpected backup format for blob name $existingBackup"
        }

        $backupPart = ""
        $vmParts = $parts[0] -split "-"
        if ($parts[1].Endswith(".vhd"))
        {
            $backupPart = $parts[1].Substring(0, $parts[1].Length - 4)
        }
        else
        {
            $backupPart = $parts[1]
        }
            
        $backupParts = $backupPart -split "-"
        if ($vmParts.Count -ne 2 -and $backupParts.Count -ne 4)
        {
            throw "The backup name does not conform to the naming convention."
        }

        $objBackup = New-Object System.Object
        $objBackup | Add-Member -type NoteProperty -name ServiceName -value $vmParts[0]
        $objBackup | Add-Member -type NoteProperty -name VmName -value $vmParts[1]
        $objBackup | Add-Member -type NoteProperty -name BackupDate -value $($backupParts[0] + "-" + $backupParts[1] + "-" + $backupParts[2])
        $objBackup | Add-Member -type NoteProperty -name BackupNumber -value $backupParts[3]
        $objBackup | Add-Member -type NoteProperty -name BlobName -value $existingBackup.Name
        $objBackup | Add-Member -type NoteProperty -name BackupId -value ([int]$($backupParts[0] + $backupParts[1] + $backupParts[2] + $backupParts[3]))

        $foundBackups += $objBackup
    }
}

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
$foundBackups = $foundBackups | Sort-Object -Property BackupId -Descending

foreach ($foundBackup in $foundBackups)
{
    if ($index++ -gt $Keep)
    {
        if (-not($existingVmOsDisks -contains $foundBackup.BlobName))
        {
            Remove-AzureStorageBlob -Container $containerName -Blob $foundBackup.BlobName
        }
    }    
}
