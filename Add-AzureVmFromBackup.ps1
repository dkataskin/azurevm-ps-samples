<#
.Synopsis
   Restores a VM backup created by Backup-AzureVm.
.DESCRIPTION
   Restores a VM from its backup, saved in a blob. The blob name uses the convention:
   <base VM disk blobName without vhd extension>byyyy-mm-dd-<backupnumber>.vhd. 
   The provided Day parameter should be a string of format "yyyy-mm-dd", with days and months 0 padded.
   Service is created if not existis, VM already exists throws an exception.
.EXAMPLE
    Restoring from the day and the backup number of the day
   .\Add-AzureVmFromBackup -BackupServiceName existingBackupService -BackupVmName existingVmNameOnService -StorageAccountName backupLocation`
        -ServiceName aService -Location "West US" -Name aVm -Size "Small" -Day "2013-08-28" -BackupNumber 1

    Restoring from a BackupId retrived by Get-AzureVmBackup.ps1 script
    .\Add-AzureVmFromBackup -BackupServiceName existingBackupService -BackupVmName existingVmNameOnService -StorageAccountName backupLocation`
    -ServiceName aService -Location "West US" -Name aVm -Size "Small" -BackupId 201309050001
#>
Param
(
    # Service the backed up VM is running on
    [Parameter(Mandatory=$true, ParameterSetName="BackupId")]
    [Parameter(Mandatory=$true, ParameterSetName="BackupDay")]
    [String]
    $BackupServiceName, 
    
    # Name of the backed up VM
    [Parameter(Mandatory=$true, ParameterSetName="BackupId")]
    [Parameter(Mandatory=$true, ParameterSetName="BackupDay")]
    [String]
    $BackupVmName,

    # Storage account where the backups are kept
    [Parameter(Mandatory=$true, ParameterSetName="BackupId")]
    [Parameter(Mandatory=$true, ParameterSetName="BackupDay")]
    [String]
    $StorageAccountName, 

    # Container name where the backups reside
    [Parameter(Mandatory=$false, ParameterSetName="BackupId")]
    [Parameter(Mandatory=$false, ParameterSetName="BackupDay")]
    [String]
    $ContainerName = "vhds", 

    # Service the VM is running on
    [Parameter(Mandatory=$true, ParameterSetName="BackupId")]
    [Parameter(Mandatory=$true, ParameterSetName="BackupDay")]
    [String]
    $ServiceName, 

    # Location of the service if not exists
    [Parameter(Mandatory=$true, ParameterSetName="BackupId")]
    [Parameter(Mandatory=$true, ParameterSetName="BackupDay")]
    [String]
    $Location, 

    # Name of the VM
    [Parameter(Mandatory=$true, ParameterSetName="BackupId")]
    [Parameter(Mandatory=$true, ParameterSetName="BackupDay")]
    [String]
    $Name,

    # Size of the VM. 
    [Parameter(Mandatory=$true, ParameterSetName="BackupId")]
    [Parameter(Mandatory=$true, ParameterSetName="BackupDay")]
    [ValidateSet("ExtraSmall","Small","Medium","Large","ExtraLarge","A6","A7")]
    [String]
    $Size,

    # The day of the backup
    [Parameter(Mandatory=$true, ParameterSetName="BackupDay")]
    [System.DateTime]
    $Day,

    # The number of the backup at that day
    [Parameter(Mandatory=$true, ParameterSetName="BackupDay")]
    [int]
    $BackupNumber,

    # The backup Id from Get-AzureVmBackup.ps1 script
    [Parameter(Mandatory=$true, ParameterSetName="BackupId")]
    [int64]
    $BackupId
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

$cloudService = Get-AzureService -ServiceName $ServiceName -ErrorAction SilentlyContinue
if ($cloudService -eq $null)
{
    New-AzureService -ServiceName $ServiceName -Location $Location
}

$currentAzureSubscription = Get-AzureSubscription  -Current
$currentStorageAccountName = $currentAzureSubscription.CurrentStorageAccount

$storageAccount = Get-AzureStorageAccount -StorageAccountName $StorageAccountName -ErrorAction SilentlyContinue
if ($storageAccount -eq $null)
{
    throw "Storage account $StorageAccountName does not exist on the current subscription. Current subscription is:"
    Get-AzureSubscription -Current
}

# Change the current storage account
if ($StorageAccountName -ne $currentStorageAccountName)
{
    Set-AzureSubscription -SubscriptionName $currentAzureSubscription.SubscriptionName -CurrentStorageAccount $storageAccountName
}

$dayString = ""
$backupNumberString = ""

if ($PSCmdlet.ParameterSetName -eq "BackupDay")
{
    $dayString = "{0:yyyy-MM-dd}" -f $Day
    $backupNumberString = "{0:0000}" -f $BackupNumber
}
else
{
    $backupIdString = $BackupId.ToString()
    $dayString = $backupIdString.Substring(0, 4) + "-" + $backupIdString.Substring(4, 2) + "-" + $backupIdString.Substring(6, 2) 
    $backupNumberString = $backupIdString.Substring(8, 4)
}
    
$backupNameDelimeter = "_b_"
$diskDelimeter = "_d_"

$vhdBlobs = Get-AzureStorageBlob -Container $ContainerName | `
    Where-Object {$_.Name -match $(".*" + $BackupServiceName + "-" + $BackupVmName + $backupNameDelimeter + "[0-9][0-9]" + `
                                    $diskDelimeter + $dayString + "-" + $backupNumberString + ".vhd")} 

if ($vhdBlobs -eq $null)
{
    throw "No blob for that backup speficication is found."
}

# the disk with ID 00 is allways the OS disk
$osDiskName = $ServiceName + "-" + $Name + $backupNameDelimeter + "00" + $diskDelimeter + $dayString + "-" + $backupNumberString
$osVhdBlob = $vhdBlobs | Where-Object {$_.Name -match $(".*" + $BackupServiceName + "-" + $BackupVmName + $backupNameDelimeter + `
                                        "00" + $diskDelimeter + $dayString + "-" + $backupNumberString + ".vhd")} 
if ($osVhdBlob -eq $null)
{
    throw "No OS disk blob for that backup speficication is found."
}

$azureOsDisk = Add-AzureDisk -DiskName $osDiskName -MediaLocation $osVhdBlob.ICloudBLob.Uri.AbsoluteUri -OS "Windows"

$dataDiskBlobs = $vhdBlobs | Where-Object {$_.Name -notmatch $(".*" + $BackupServiceName + "-" + $BackupVmName + $backupNameDelimeter + `
                                        "00" + $diskDelimeter + $dayString + "-" + $backupNumberString + ".vhd")} 

$vmConfig = New-AzureVMConfig -Name $Name -InstanceSize $Size -DiskName $osDiskName 
foreach ($dataDiskBlob in $dataDiskBlobs)
{
    $diskMediaLinkUri = [System.Uri]$dataDiskBlob.ICloudBLob.Uri.AbsoluteUri
    $diskBlobName = $diskMediaLinkUri.Segments[2]
    $backupNameParts = $diskBlobName -split $backupNameDelimeter
    if ($backupNameParts.Length -ne 2)
    {
        throw "Unrecognized naming convention, $diskBlobName"
    }

    $backupNameParts = $backupNameParts[1] -split $diskDelimeter
    if ($backupNameParts.Length -ne 2)
    {
        throw "Unrecognized naming convention, $diskBlobName. Cannot find disk number."
    }

    $diskNumberString = $backupNameParts[0]
    $diskLabel = $ServiceName + "-" + $Name + $backupNameDelimeter + $diskNumberString  + $diskDelimeter + $dayString + "-" + $backupNumberString
    $diskNumber = [int]$diskNumberString
    $vmConfig = $vmConfig | Add-AzureDataDisk -ImportFrom -DiskLabel $diskLabel -LUN $diskNumber -MediaLocation $diskMediaLinkUri.AbsoluteUri 
}
 
$vmConfig | New-AzureVM -ServiceName $ServiceName

# Restore the storage account
Set-AzureSubscription -SubscriptionName $currentAzureSubscription.SubscriptionName -CurrentStorageAccount $currentStorageAccountName