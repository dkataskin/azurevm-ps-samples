<#
.Synopsis
   Given a VM OS disk backed up by the Backup-AzureVM.ps1 script, purge the old backups before the last N given. This scripts
   assumes the backups are stored on the storage account pointed by the current subscription's CurrentStorageAccount property
.DESCRIPTION
   Purge the old backups of a given VM, with one single disk. Any previous backups, before the last N, being used by a VM are skipped. 

   OlderThanDays and KeepLast are mutually exclusive parameters.
.EXAMPLE
   For removing the last 5 backups of a given VM on a service:
   .\Remove-AzureVMBackup -ServiceName aService -Name aVm -KeepLast 5

   Removing all of the backups:
   .\Remove-AzureVMBackup -ServiceName aService -Name aVm -KeepLast 0

   Removing older than 3 days worth of backups
   .\Remove-AzureVMBackup -ServiceName aService -Name aVm -OlderThanDays 0


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
    [Parameter(Mandatory=$true, ParameterSetName='KeepLast')]
    [String]
    $KeepLast,

    # Last N days of backup to keep, and remove older ones
    [Parameter(Mandatory=$true, ParameterSetName='OlderThanDays')]
    [String]
    $OlderThanDays
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

$backupNamePrefix = "_b_"
$diskDelimeter = "_d_"

$existingBackups = Get-AzureStorageBlob -Container $ContainerName | 
    Where-Object {$_.Name -match $(".*" + $ServiceName + "-" + $Name + $backupNamePrefix + "[0-9][0-9]" + $diskDelimeter + "[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}\.vhd$")} | 
    Select-Object Name

$foundBackups = @{}

if($existingBackups -ne $null)
{
    foreach ($existingBackup in $existingBackups)
    {
        $parts = $existingBackup.Name -split $backupNamePrefix
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
            
        $backupParts = $backupPart -split $diskDelimeter
        if ($backupParts.Count -ne 2)
        {
            throw "The backup name does not conform to the naming convention."
        }
        $diskNumber = $backupParts[0]
            
        $backupParts = $backupParts[1] -split "-"
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
        $objBackup | Add-Member -type NoteProperty -name BackupId -value ([Int64]$($backupParts[0] + $backupParts[1] + $backupParts[2] + $backupParts[3]))

        if (!$foundBackups.ContainsKey($objBackup.BackupId))
        {
            # Initialize the disk array for the found backup
            $foundBackups.Add($objBackup.BackupId, @())
        }
        $foundBackups[$objBackup.BackupId] += $objBackup
    }
}

$existingVmDisks = Get-AzureDisk

if ($PSCmdlet.ParameterSetName -eq "KeepLast")
{
    $index = 1
    $foundBackupIds = $foundBackups.Keys | Sort-Object -Descending

    if ($foundBackupIds -eq $null)
    {
        Write-Warning "No backups found to remove."
    }
    else
    {
        foreach ($foundBackupId in $foundBackupIds)
        {
            if ($index++ -gt $KeepLast)
            {
                $backupVhds = $foundBackups[$foundBackupId]

                foreach ($backupVhd in $backupVhds)
                {
                    $existingDisk = $existingVmDisks | Where-Object {$_.MediaLink -match $(".*" + $backupVhd.BlobName + "$")}

                    if ($existingDisk -ne $null -and $existingDisk.AttachedTo -eq $null)
                    {
                        Remove-AzureDisk -DiskName $existingDisk.DiskName 
                        Write-Verbose "Removed a disk using the backup blob."
                    }

                    if ($existingDisk -eq $null)
                    {
                        Remove-AzureStorageBlob -Container $containerName -Blob $backupVhd.BlobName
                        Write-Verbose "Removed $backupVhd.BlobName"
                    }   
                    else
                    {
                        Write-Warning "Found disk attached to a VM. DiskName: $existingDisk.DiskName, not removing the blob $backupVhd.BlobName"
                    }
                }            
            }    
        }
    }
}
else
{
    # Remove the backups older than N days
    $lastDayToKeep = ([Int64](Get-Date $((Get-Date).AddDays(-1 * ($OlderThanDays - 1))) -Format "yyyyMMdd")) * 10000
    $foundBackupIds = $foundBackups.Keys | Where-Object {$_ -lt $lastDayToKeep}

    if ($foundBackupIds -eq $null)
    {
        Write-Warning "No backups found to remove."
    }
    else
    {
        foreach ($foundBackupId in $foundBackupIds)
        {
            $backupVhds = $foundBackups[$foundBackupId]
            foreach ($backupVhd in $backupVhds)
            {
                $existingDisk = $existingVmDisks | Where-Object {$_.MediaLink -match $(".*" + $backupVhd.BlobName + "$")}

                if ($existingDisk -ne $null -and $existingDisk.AttachedTo -eq $null)
                {
                    Remove-AzureDisk -DiskName $existingDisk.DiskName 
                    Write-Verbose "Removed a disk using the backup blob."
                    $existingDisk = $null
                }

                if ($existingDisk -eq $null)
                {
                    Remove-AzureStorageBlob -Container $containerName -Blob $backupVhd.BlobName
                } 
                else
                {
                    Write-Warning "Found disk attached to a VM. DiskName: $existingDisk.DiskName, not removing the blob $backupVhd.BlobName"
                }
            }
        }
    }
}