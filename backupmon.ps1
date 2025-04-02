<#
    Backup Monitor PowerShell Script
    Copyright (C) 2023-2025 Andreas Pramhaas
    https://github.com/apramhaas/Backup-Monitor

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.

    # Version: 1.1.0
    # History:
    # - 1.0.0: Initial release
    # - 1.1.0: Added support for multiple email addresses in the notificationEmail parameter (2025-03-19)
    # - 1.2.0: Enforce minimum backup sets to 2 and improve backup time pattern calculations (2025-04-02)
#>

param
(
    [Parameter(Mandatory = $True)]
    [ValidateNotNullOrEmpty()]
    [string]$config
)

# Set to true to log extended data of internal variable states. You can also add a 'debug=true' line in the config file
$debug = $False

# Function to send an email report
function Send-EmailReport {
    param (
        [string]$subject,
        [string]$body,
        [string]$email
    )

    $smtp = New-Object Net.Mail.SmtpClient($smtpServer)
    $message = New-Object Net.Mail.MailMessage
    $message.From = $emailSender
    $message.To.Add($email)
    $message.Subject = $subject
    $message.Body = $body
    $smtp.Send($message)
}

# Function to validate email addresses
function Test-EmailAddress {
    param (
        [string]$email
    )
    return $email -match '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'
}

# Function to get the size of a backup (file or directory)
function Get-BackupSize {
    param (
        [string]$path
    )

    if (Test-Path $path -PathType Leaf) {
        return (Get-Item $path).Length
    }
    elseif (Test-Path $path -PathType Container) {
        return (Get-ChildItem $path -Recurse | Measure-Object -Property Length -Sum).Sum
    }
    else {
        return 0
    }
}

# Function to calculate the median of an array of numbers
function Get-Median {
    param (
        [long[]]$numbers
    )

    $count = $numbers.Count
    $sortedNumbers = $numbers | Sort-Object

    if ($count % 2 -eq 0) {
        # If the count is even, take the average of the middle two numbers
        $middle1 = $sortedNumbers[($count / 2) - 1]
        $middle2 = $sortedNumbers[$count / 2]
        $median = ($middle1 + $middle2) / 2
    }
    else {
        # If the count is odd, simply take the middle number
        $median = $sortedNumbers[$count / 2]
    }

    return $median
}

# Read config file
if (Test-Path $config) {
    $configFileContents = Get-Content $config | ForEach-Object {
        $_.Trim()
    }

    # Define default values
    $minBackupSets = 5
    $emailSender = ""
    $notificationEmail = ""
    # Control if a mail is sent. Valid values for notifyType: off, alarm, always, alarmonlastbackup
    $notifyType = "off"
    $smtpServer = ""
    $backupPaths = @()
    $alarmOnLastBackup = $False

    foreach ($line in $configFileContents) {
        if ($line -eq "") {
            continue
        }
        if ($line -match "^\s*(\w+)\s*=\s*(.+)") {
            $variableName = $matches[1]
            $variableValue = $matches[2]
            
            # Set the variable based on the name
            if ($variableName -eq "debug" -and $variableValue -eq "true") {
                $debug = $True
            }
            else {
                Set-Variable -Name $variableName -Value $variableValue
            }            
        }
        # If the line is a valid path, add it to the paths array
        elseif (Test-Path $line -PathType Container) {
            $backupPaths += $line                     
        }
    }

    # Display the read or default values
    Write-Host "Backup monitor started. These values where read from the config file. If not specified a default value was used."    
    Write-Host "minBackupSets = $minBackupSets"
    Write-Host "emailSender = $emailSender"
    Write-Host "notificationEmail = $notificationEmail"
    Write-Host "smtpServer = $smtpServer"
    Write-Host "notifyType = $notifyType"
    Write-Host "Paths:"
    $backupPaths | ForEach-Object {
        Write-Host $_
    }

    if ($minBackupSets -lt 2) {
        $minBackupSets = 2;
        Write-Host "minBackupSets value must be minimum 2 for this script to work correctly. Forcing to 2!"
    }
}
else {
    Write-Host "Specified config file \"$config\" does not exist."
    exit 1
}

# Initialize variables for tracking backups
$failedBackups = @()
$currentDate = Get-Date

Write-Host "`nStart backup check at $currentDate"
# Loop through each backup path
foreach ($path in $backupPaths) {
    if (Test-Path $path) {
        Write-Host "Checking path: ${path}"

        # Get a list of backup files and directories sorted by create time
        $backupItems = Get-ChildItem -Path $path | Sort-Object LastWriteTime

        # Ensure a minimum of $minBackupSets (forced to at least 2) backup sets, otherwise continue in the next path instead of further tests
        if ($backupItems.Count -lt $minBackupSets) {
            # If there is a backup that is not older than 25 hours it's probably a fresh start and ignore
            if ($backupItems.Count -gt 0) {
                if (([datetime]$currentDate - [datetime]$backupItems[-1].LastWriteTime).TotalSeconds -ge 90000) {
                    $failedBackups += "${path}: Less than $minBackupSets backup sets found."
                    $alarmOnLastBackup = $True
                    continue
                }
                else {
                    Write-Host "${path}: less than $minBackupSets found, but ignoring as last backup is from within 25 hours"
                    continue
                }
            }
            else {
                $failedBackups += "${path}: Less than $minBackupSets backup sets found."
                $alarmOnLastBackup = $True
                continue
            }
        }

        # Determine the pattern frequency based on timestamps. Code above
        # ensures that at least 2 backups samples are available here. If more
        # than two samples are available, calculate the median of all
        # differences. Average doesn't make sense, as an outlier would skew the value.

        if ($backupItems.Count -gt 2) {        
            # Calculate the differences between timestamps
            $differences = @()
            for ($i = 0; $i -lt ($backupItems.Count - 1); $i++) {
                $diff = ($backupItems[$i + 1].LastWriteTime - $backupItems[$i].LastWriteTime).TotalSeconds
                $differences += $diff
                if ($debug) {
                    $diff1 = $backupItems[$i + 1].LastWriteTime
                    $diff2 = $backupItems[$i].LastWriteTime
                    Write-Host "diff1 = $diff1, diff2 = $diff2, diff = $diff"
                }
            }

            # Calculate the median of the differences
            $medianDateDiff = Get-Median -numbers $differences
            $medianDateDiff = [math]::Round($medianDateDiff)
            Write-Host "${path}: Calculated median of time span between the backups sets is ${medianDateDiff} seconds"    
        }
        else {
            # only calculate the difference as median calculation needs at least 3 samples
            $medianDateDiff = ($backupItems[1].LastWriteTime - $backupItems[0].LastWriteTime).TotalSeconds
            $medianDateDiff = [math]::Round($medianDateDiff)
            Write-Host "${path}: Calculated time span between the backups sets is ${medianDateDiff} seconds"
        }

        # Check if the difference between the last backup timestamp and now is below the calculated median with a 5 % discrepancy allowed        
        $differenceToCheck = ([datetime]$currentDate - [datetime]$backupItems[-1].LastWriteTime).TotalSeconds

        # Define the allowable discrepancy (5 %)
        $allowableDiscrepancy = $medianDateDiff * 1.05
        if ($differenceToCheck -gt $allowableDiscrepancy) {
            $failedBackups += "${path}: More time than usual has passed since the last backup (calculated based on modification time)."
            $alarmOnLastBackup = $True
        }

        # Check if there are irregularities between the backup creation times
        # loop through the differences array and detect if there is a discrepancy > 5 %
        $exitloop = $False;
        if ($differences.Length -ge 2) {
            for ($i = 0; $i -lt ($differences.Length - 1); $i++) {                
                if ($differences[$i] -ne 0) {                    
                    $discrepancy = ([Math]::Round((([Math]::Abs($differences[$i] - $differences[$i + 1])) / $differences[$i]) * 100))
                    # Extended logging when debug flag is enabled
                    if ($debug) {
                        $leaf1 = Split-Path -Path $backupItems[$i] -Leaf
                        $leaf2 = Split-Path -Path $backupItems[$i + 1] -Leaf
                        $leaf3 = Split-Path -Path $backupItems[$i + 2] -Leaf
                        Write-Host "leaf1 = $leaf1, leaf2 = $leaf2, leaf3 = $leaf3, discrepancy = $discrepancy (of differences between leaf1/leaf2 and leaf2/leaf3)"
                    }

                    if ($discrepancy -gt 5) {
                        $leaf1 = Split-Path -Path $backupItems[$i] -Leaf
                        $leaf2 = Split-Path -Path $backupItems[$i + 1] -Leaf
                        $leaf3 = Split-Path -Path $backupItems[$i + 2] -Leaf
                        $failedBackups += "${path}: Detected a discrepancy greater than 5 % ($discrepancy % - $leaf1 / $leaf2 / $leaf3) between the backup set modification times."
                        # check if the alarm occured on the last backup an enable the flag for mail delivery
                        if ($i -eq ($differences.Length - 2)) {
                            $alarmOnLastBackup = $True
                        }
                        $exitloop = $True;
                    }
                }
                if ($exitloop) { break }
            }
        }

        # Check if the latest backup size is reasonable based on previous backups
        $backupSizes = @()
        for ($i = 0; $i -lt ($backupItems.Count - 1); $i++) {
            $backupSizes += Get-BackupSize $backupItems[$i].FullName
        }

        # Calculate the median of all previous backup sizes
        $medianSize = Get-Median -numbers $backupSizes
        $lastBackupSize = Get-BackupSize $backupItems[-1].FullName
        # Define the allowable discrepancy (5%)
        $allowableDiscrepancy = $medianSize * 0.05
        if ($lastBackupSize -lt $allowableDiscrepancy) {
            $failedBackups += "${path}: Last backup is more than 5% smaller than usual based on the previous backups."
        }       
    }
    else {
        $failedBackups += "${path}: Path not found."
    } 
}

# Generate a summary report
$reportBody = "Backup monitor summary report - ${currentDate}`n"
$reportBody += "===============================================`n"

$reportBody += "Checked backup paths:`n"
foreach ($path in $backupPaths) {
    $reportBody += "$path`n"
}

$reportBody += "`nALARMS:`n"
if ($failedBackups.Count -eq 0) {
    $reportBody += "No failed backups`n"
}
else {
    foreach ($failedBackup in $failedBackups) {
        $reportBody += "$failedBackup`n"
    }
}

# Send the summary report via email
if ($notificationEmail -ne "" -And $smtpServer -ne "" -And $notifyType -ne "off") {
    Write-Host "`nPreparing to send e-mail with summary to $notificationEmail"

    # Split the email addresses and validate each one
    $emailAddresses = $notificationEmail -split ','
    $validEmailAddresses = @()
    foreach ($email in $emailAddresses) {
        $trimmedEmail = $email.Trim()
        if (Test-EmailAddress -email $trimmedEmail) {
            $validEmailAddresses += $trimmedEmail
        }
        else {
            Write-Host "Invalid email address detected: $trimmedEmail"
        }
    }

    if ($validEmailAddresses.Count -eq 0) {
        Write-Host "No valid email addresses found. Skipping email notification."
    }
    else {
        # Always send an email report
        if ($failedBackups.Count -eq 0 -And $notifyType -eq "always") {
            foreach ($email in $validEmailAddresses) {
                Write-Host "Sending email to $email"
                Send-EmailReport -subject "Backup monitor summary" -body $reportBody -email $email
            }
        }
        # Send email report only when an alarm is raised
        elseif ($failedBackups.Count -gt 0 -And $notifyType -eq "alarm") {
            foreach ($email in $validEmailAddresses) {
                Write-Host "Sending email to $email"
                Send-EmailReport -subject "Backup monitor summary with ALARMs" -body $reportBody -email $email
            }
        }
        # Send email report only when an alarm is raised regarding the newest backup
        elseif ($failedBackups.Count -gt 0 -And $notifyType -eq "alarmonlastbackup" -and $alarmOnLastBackup -eq $True) {
            foreach ($email in $validEmailAddresses) {
                Write-Host "Sending email to $email"
                Send-EmailReport -subject "Backup monitor summary with ALARMs" -body $reportBody -email $email
            }
        } 
    }
}

Write-Host "`n$reportBody"
