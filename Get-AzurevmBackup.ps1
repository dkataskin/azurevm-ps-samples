<#
.Synopsis
   Given a VM OS disk backed up by the Backup-AzureVM.ps1 script, list all of the backups.
.DESCRIPTION
  List all of the backups on the blob store of the given VM, using the naming convention.
  Please note the results are not sorted, and to discover the order of the backups.

  The backups are as copies of the backing disk blob, with the name convention:
   <Name of the backing blob of the OS disk, without the .vhd extension>_v_<serviceName>-<vmName>_b_<date in yyyy-mm-dd format>-<backup number of the day>.vhd"
.EXAMPLE
   .\Get-AzurevmBackup.ps1 -ServiceName AService -Name vmName
.INPUTS
   None
.OUTPUTS
   Hashtable of compressed backup number in the form of yyyymmdd<dailybackupnumber>
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

        # Name of the storage account for the backup blobs
        [Parameter(Mandatory=$false)]
        [String]
        $StorageAccountName,

        # Name of the storage account container for the backup blobs
        [Parameter(Mandatory=$false)]
        [String]
        $StorageAccountContainer
    )

    $vm = Get-AzureVM -ServiceName $ServiceName -Name $Name -ErrorAction SilentlyContinue

    $containerName = ""
    $diskBlobName = ""
    if ($vm -eq $null)
    {
        if ($StorageAccountName -eq "" -or $StorageAccountContainer -eq "")
        {
            throw "A virtual machine with name $Name on $ServiceName does not exist, and the StorageAccountName an StorageAccountContainer `
                parameter values has not been provided. Please provide where the backups reside."
        }
    }
    else
    {
        $osDiskMediaLinkUri = [System.Uri]$vm.VM.OSVirtualHardDisk.MediaLink

        if ($osDiskMediaLinkUri.Segments.Count -gt 3)
        {
            throw "Disk containers only one level deep supported"
        }

        # If it is a 3 part segment, first part willbe / second will be the container name, and third part will be the blob name
        $containerName = $osDiskMediaLinkUri.Segments[1].Replace("/","")
        $diskBlobName = $osDiskMediaLinkUri.Segments[2]

        $StorageAccountName = $osDiskMediaLinkUri.Host.Split(".")[0]
    }

    $currentAzureSubscription = Get-AzureSubscription -Current
    $currentStorageAccountName = $currentAzureSubscription.CurrentStorageAccount

    # Change the current storage account
    if ($StorageAccountName -ne $currentStorageAccountName)
    {
        Set-AzureSubscription -SubscriptionName $currentAzureSubscription.SubscriptionName -CurrentStorageAccount $StorageAccountName
    }

    
    $BackupVmPrevix = "_v_"
    $backupNamePrefix = "_b_"

    $existingBackups = Get-AzureStorageBlob -Container $containerName | Where-Object {$_.Name -ilike $("*" + $BackupVmPrevix + $ServiceName + "-" + $Name + $backupNamePrefix +"*")} | Select-Object Name

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

            $foundBackups += $objBackup
        }
    }

    # Restore the original CurrentStorageAccount setting
    Set-AzureSubscription -SubscriptionName $currentAzureSubscription.SubscriptionName -CurrentStorageAccount $currentStorageAccountName

    $foundBackups 