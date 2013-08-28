<#
.Synopsis
   Restores a VM backup created by Backup-AzureVm.
.DESCRIPTION
   Restores a VM from its backup, saved in a blob. The blob name uses the convention:
   <base VM disk blobName without vhd extension>byyyy-mm-dd-<backupnumber>.vhd. 
   The provided Day parameter should be a string of format "yyyy-mm-dd", with days and months 0 padded.
   Service is created if not existis, VM already exists throws an exception.
.EXAMPLE
   .\Add-AzureVmFromBackup -ServiceName aService -Location "West US" -Name aVm -Size "Small" -Day "2013-08-28" -BackupNumber 1
#>
Param
(
    # Service the backed up VM is running on
    [Parameter(Mandatory=$true)]
    [String]
    $BackupServiceName, 
    
    # Name of the backed up VM
    [Parameter(Mandatory=$true)]
    [String]
    $BackupName,

    # Storage account where the backups are kept
    [Parameter(Mandatory=$true)]
    [String]
    $StorageAccounteName, 

    # Container name where the backups reside
    [Parameter(Mandatory=$false)]
    [String]
    $ContainerName = "vhds", 

    # Service the VM is running on
    [Parameter(Mandatory=$true)]
    [String]
    $ServiceName, 

    # Location of the service if not exists
    [Parameter(Mandatory=$false)]
    [String]
    $Location, 

    # Name of the VM
    [Parameter(Mandatory=$true)]
    [String]
    $Name,

    # Size of the VM. 
    [Parameter(Mandatory=$true)]
    [String]
    $Size,

    # The day of the backup
    [Parameter(Mandatory=$true)]
    [String]
    $Day,

    # The number of the backup at that day
    [Parameter(Mandatory=$true)]
    [String]
    $BackupNumber
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
    if ($Location -eq "")
    {
        throw "Service $ServiceName does not exist, please provide a location for the service using Location parameter."
    }
    New-AzureService -ServiceName $ServiceName -Location $Location
}

$currentAzureSubscription = Get-AzureSubscription  -Current
$currentStorageAccountName = $currentAzureSubscription.CurrentStorageAccount

$storageAccount = Get-AzureStorageAccount -StorageAccountName $StorageAccounteName -ErrorAction SilentlyContinue
if ($storageAccount -eq $null)
{
    throw "Storage account $StorageAccounteName does not exist on the current subscription. Current subscription is:"
    Get-AzureSubscription -Current
}

# Change the current storage account
if ($StorageAccountName -ne $currentStorageAccountName)
{
    Set-AzureSubscription -SubscriptionName $currentAzureSubscription.SubscriptionName -CurrentStorageAccount $storageAccountName
}

    
$BackupVmPrevix = "_v_"
$backupNamePrefix = "_b_"

$vhdBlobName = Get-AzureStorageBlob -Container $ContainerName | Where-Object {$_.Name -ilike $("*" + $BackupVmPrevix + $ServiceName + "-" + $Name + $backupNamePrefix + $Day + "-" + $BackupNumber)} 

if ($vhdBlobName -eq $null)
{
    throw "No blob for that backup speficication is found."
}


$vm = New-AzureVMConfig -Name $Name -InstanceSize $Size -ImageName $imageName | 
                        Add-AzureProvisioningConfig -Windows -AdminUsername $credential.GetNetworkCredential().username `
                        -Password $credential.GetNetworkCredential().password | 
                        Set-AzureSubnet -SubnetNames $subnetName |
                        Add-AzureDataDisk -CreateNew -DiskSizeInGB 20 -DiskLabel 'DITDrive' -LUN 0 |
                        New-AzureVM -ServiceName $ServiceName -AffinityGroup $affinityGroupName -VNetName $VNetName -WaitForBoot