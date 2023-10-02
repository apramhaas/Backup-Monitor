# Backup Monitor PowerShell Script

## Purpose
The Backup Monitor PowerShell script is designed to monitor backup sets and ensure that they meet certain criteria, such as backup frequency and backup size. It can be used to keep track of the status of backup operations for critical data.

## Copyright & License
This script is distributed under the terms of the GNU General Public License (GPL) version 3. You can find a copy of the license in the [LICENSE](LICENSE) file.

## Checks Performed
The script performs the following checks on each backup set:

1. **Minimum Backup Sets:** Ensures that there are a minimum number of backup sets available for monitoring.

2. **Backup Frequency:** Detects the backup frequency pattern based on timestamps and checks if the latest backup aligns with the determined pattern.

3. **Backup Size:** Checks if the size of the latest backup is within an acceptable range based on the sizes of previous backups.

## Configuration and Parameters
The script can be configured using a configuration file. The following parameters can be specified in the configuration file:

- `minBackupSets`: Minimum number of backup sets required for monitoring.
- `emailSender`: Email address of the sender for notification emails.
- `notificationEmail`: Email address to which notification emails will be sent.
- `notifyType`: Notification type, with valid values: `off`, `alarm`, `always`, `alarmonlastbackup`.
- `smtpServer`: SMTP server address for sending notification emails.
- `backupPaths`: An array of backup paths to monitor.

## Example Configuration File
```plaintext
minBackupSets = 5
emailSender = backup-monitor@yourdomain.com
notificationEmail = your@email.com
notifyType = alarmonlastbackup
smtpServer = smtp.yourmailserver.com

[Paths]
C:\Backups\BackupSet1
\\Server\Backup\BackupSet2
