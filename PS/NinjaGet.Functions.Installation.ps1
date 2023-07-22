# Uninstall NinjaGet function - uninstalls NinjaGet and resets various changed settings.
function Uninstall-NinjaGet {
    # Confirm NinjaGet is installed.
    if (-not (Test-Path -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\NinjaGet')) {
        Write-NGLog -LogMsg 'NinjaGet is not installed.' -LogColour 'Cyan'
        return
    }
    # Get the NinjaGet installation path.
    $NinjaGetInstallPath = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\NinjaGet\' -Name 'InstallLocation'
    # Get the original setting for StoreAutoDownload.
    $OriginalStoreAutoDownload = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\NinjaGet\' -Name 'StoreUpdatesOriginalValue'

}

# Get latest WinGet function - gets the latest WinGetversion and the download URL for the MSIXBundle from GitHub.
function Get-LatestWinGet {
    $LatestRelease = Invoke-RestMethod -Uri 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' -Method Get 
    $LatestWinGetVersion = $LatestRelease.tag_name
    [version]$LatestWinGetVersion = $LatestWinGetVersion.TrimStart('v')
    $LatestVersion = @{
        Version = $LatestWinGetVersion
        DownloadURI = $LatestRelease.assets.browser_download_url | Where-Object { $_.EndsWith('.msixbundle') }
    }
    return $LatestVersion
}
# Test WinGet version function - tests the version of WinGet against the latest version on GitHub.
function Test-WinGetVersion {
    param(
        [version]$InstalledWinGetVersion
    )
    $LatestWinGet = Get-LatestWinGet
    if ($InstalledWinGetVersion -lt $LatestWinGet.Version) {
        Write-NGLog 'WinGet is out of date.' -LogColour 'Yellow'
        $Script:WinGetURL = $LatestWinGet.DownloadURI
        return $false
    } else {
        Write-NGLog 'WinGet is up to date.' -LogColour 'Green'
        return $true
    }
}
# Update WinGet function - updates WinGet, using the Microsoft Store, if it is out of date.
function Update-WinGetFromStore {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Narrowly defined system state change - updating WinGet.'
    )]
    param(
        # Stop WinGet processes before updating.
        [switch]$StopProcesses,
        # How long to wait for the update to complete. Value is in minutes.
        [int]$WaitTime = 10,
        # The target version of WinGet to wait for. If not specified, the latest version will be used.
        [version]$TargetVersion
    )
    Write-NGLog 'Attempting to update WinGet from the Microsoft Store...' -LogColour 'Yellow'
    # Stop WinGet processes if the switch is specified.
    if ($StopProcesses) {
        Write-NGLog 'Stopping WinGet processes...' -LogColour 'Yellow'
        Get-Process | Where-Object { $_.ProcessName -in @('winget', 'WindowsPackageManagerServer', 'AuthenticationManager', 'AppInstaller') } | Stop-Process -Force
    }
    # Send the update command to the Microsoft Store using the MDM bridge.
    Get-CimInstance -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_EnterpriseModernAppManagement_AppManagement01' | Invoke-CimMethod -MethodName UpdateScanMethod
    # If no target version is specified, get the latest version from GitHub.
    if (!$TargetVersion) {
        $TargetVersion = (Get-LatestWinGet).Version
    }
    # Wait for the update to complete - wait in 30 second intervals until the WaitTime is reached.
    do {
        Write-NGLog 'Waiting for WinGet update to complete...' -LogColour 'Yellow'
        Start-Sleep -Seconds 30
        $WaitTime -= 0.5
    } until ($WaitTime -eq 0 -or (Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller').Version -eq $TargetVersion)
}
# Install WinGet function - installs WinGet if it is not already installed or is out of date.
function Install-WinGetFromMSIX {
    Write-NGLog 'WinGet not installed or out of date. Installing/updating...' -LogColour 'Yellow' # No sense determining this dynamically - we have to update the version check above anyway.
    $WinGetFileName = [Uri]$Script:WinGetURL | Select-Object -ExpandProperty Segments | Select-Object -Last 1
    $WebClient = New-Object System.Net.WebClient
    $PrerequisitesPath = Join-Path -Path $Script:InstallPath -ChildPath 'Prerequisites'
    $WinGetDownloadPath = Join-Path -Path $PrerequisitesPath -ChildPath $WinGetFileName
    $WebClient.DownloadFile($Script:WinGetURL, $WinGetDownloadPath)
    try {
        Write-NGLog 'Installing WinGet...' -LogColour 'Yellow'
        Add-AppxProvisionedPackage -Online -PackagePath $WinGetDownloadPath -SkipLicense -ErrorAction Stop | Out-Null
        Write-NGLog 'WinGet installed.' -LogColour 'Green'
    } catch {
        Write-NGLog -LogMsg 'Failed to install WinGet!' -LogColour 'Red'
    } finally {
        Remove-Item -Path $WinGetDownloadPath -Force -ErrorAction SilentlyContinue
    }
}
# Prerequisite test function - checks if the script can run.
function Test-NinjaGetPrerequisites {
    # Check if the script is running in a supported OS.
    if ([System.Environment]::OSVersion.Version.Build -lt 17763) {
        Write-NGLog -LogMsg 'This script requires Windows 10 1809 or later!' -LogColour 'Red'
        exit 1
    }
    # Check for the required Microsoft Visual C++ redistributables.
    $Visual2019 = 'Microsoft Visual C++ 2015-2019 Redistributable*'
    $Visual2022 = 'Microsoft Visual C++ 2015-2022 Redistributable*'
    $VCPPInstalled = Get-Item @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*') | Where-Object {
        $_.GetValue('DisplayName') -like $Visual2019 -or $_.GetValue('DisplayName') -like $Visual2022
    }
    if (!($VCPPInstalled)) {
        Write-NGLog 'Installing the required Microsoft Visual C++ redistributables...' -LogColour 'Yellow'
        if ([System.Environment]::Is64BitOperatingSystem) {
            $OSArch = 'x64'
        } else {
            $OSArch = 'x86'
        }
        $VCPPRedistURL = ('https://aka.ms/vs/17/release/vc_redist.{0}.exe' -f $OSArch)
        $VCPPRedistFileName = [Uri]$VCPPRedistURL | Select-Object -ExpandProperty Segments | Select-Object -Last 1
        $WebClient = New-Object System.Net.WebClient
        $VCPPRedistDownloadPath = "$InstallPath\Prerequisites"
        if (!(Test-Path -Path $VCPPRedistDownloadPath)) {
            $null = New-Item -Path $VCPPRedistDownloadPath -ItemType Directory -Force
        }
        $VCPPRedistDownloadFile = "$VCPPRedistDownloadPath\$VCPPRedistFileName"
        $WebClient.DownloadFile($VCPPRedistURL, $VCPPRedistDownloadFile)
        try {
            Start-Process -FilePath $VCPPRedistDownloadFile -ArgumentList '/quiet', '/norestart' -Wait -ErrorAction Stop | Out-Null
            Write-NGLog 'Microsoft Visual C++ redistributables installed.' -LogColour 'Green'
        } catch {
            Write-NGLog -LogMsg 'Failed to install the required Microsoft Visual C++ redistributables!' -LogColour 'Red'
            exit 1
        }
    }
    $WinGet = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq 'Microsoft.DesktopAppInstaller' } -ErrorAction SilentlyContinue
    if ($WinGet) {
        # WinGet is installed - let's test the version.
        if ([Version]$WinGet.Version -ge (Get-LatestWinGet).Version) {
            Write-NGLog 'WinGet is installed and up to date.' -LogColour 'Cyan'
        } else {
            Update-WinGetFromStore
        }
    } else {
        Install-WinGet
    }
    # Test that store app updates are enabled.
    $StoreAppUpdatesEnabled = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' -Name 'AutoDownload' -ErrorAction SilentlyContinue
    if ($StoreAppUpdatesEnabled -eq '2') {
        Write-NGLog 'Store app updates are not enabled!' -LogColour 'Red'
        Enable-StoreUpdates
    } else {
        Write-NGLog 'Store app updates are enabled!' -LogColour 'Cyan'
    }
}
# Enable store app updates function - enables store app updates.
function Enable-StoreUpdates {
    param(
        # The original value of the AutoDownload registry value.
        [int]$OriginalValue = $null
    )
    $WSPRegistryPath = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'
    $WSPropertyName = 'AutoDownload'
    if ($OriginalValue) {
        Write-NgLog -LogMsg ('Storing original value of AutoDownload registry value [{0}]...' -f $OriginalValue) -LogColour 'Yellow'
        Register-NinjaGetSettings -StoreUpdatesOriginalValue $OriginalValue
    }
    Write-NgLog 'Enabling store app updates...' -LogColour 'Yellow'
    New-ItemProperty -Path $WSPRegistryPath -Name $WSPropertyName -Value 4 -Force
}
# Register NinjaGet in the registry.
function Register-NinjaGetProgramEntry {
    param(
        # The display name of the program.
        [string]$DisplayName,
        # The publisher of the program.
        [string]$Publisher
    )
    $RegistryPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\NinjaGet'
    $null = New-Item -Path $RegistryPath -Force
    $null = New-ItemProperty -Path $RegistryPath -Name 'DisplayName' -Value 'NinjaGet' -Force
    $null = New-ItemProperty $RegistryPath -Name DisplayIcon -Value '' -Force
    $null = New-ItemProperty $RegistryPath -Name DisplayVersion -Value $Script:Version -Force
    $null = New-ItemProperty $RegistryPath -Name InstallLocation -Value $Script:InstallPath -Force
    $null = New-ItemProperty $RegistryPath -Name UninstallString -Value "powershell.exe -NoProfile -File `"$Script:InstallPath\PS\Uninstall-NinjaGet.ps1`"" -Force
    $null = New-ItemProperty $RegistryPath -Name QuietUninstallString -Value "powershell.exe -NoProfile -File `"$Script:InstallPath\PS\Uninstall-NinjaGet.ps1`"" -Force
    $null = New-ItemProperty $RegistryPath -Name NoModify -Value 1 -Force
    $null = New-ItemProperty $RegistryPath -Name NoRepair -Value 1 -Force
    $null = New-ItemProperty $RegistryPath -Name Publisher -Value 'homotechsual' -Force
    $null = New-ItemProperty $RegistryPath -Name URLInfoAbout -Value 'https://docs.homotechsual.dev/tools/ninjaget' -Force
}
# Notification App Function - Creates an app user model ID and registers the app with Windows.
function Register-NotificationApp {
    param(
        [string]$DisplayName = 'Software Updater',
        [uri]$LogoUri
    )
    $HKCR = Get-PSDrive -Name HKCR -ErrorAction SilentlyContinue
    If (!($HKCR)) {
        $null = New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT -Scope Script
    }
    $BaseRegPath = 'HKCR:\AppUserModelId'
    $AppId = 'NinjaGet.Notifications'
    $AppRegPath = "$BaseRegPath\$AppId"
    If (!(Test-Path $AppRegPath)) {
        $null = New-Item -Path $BaseRegPath -Name $AppId -Force
    }
    if ($IconURI) {
        $IconFileName = $IconURI.Segments[-1]
        $IconPath = "$InstallPath\resources\$IconFileName"
        $IconFile = New-Object System.IO.FileInfo $IconFilePath
        If ($IconFile.Exists) {
            $IconFile.Delete()
        }
        $WebClient = New-Object System.Net.WebClient
        $WebClient.DownloadFile($IconURI, $IconPath)
    } else {
        $IconPath = "$InstallPath\resources\applications.png"
    }
    $null = New-ItemProperty -Path $AppRegPath -Name DisplayName -Value $DisplayName -PropertyType String -Force
    $null = New-ItemProperty -Path $AppRegPath -Name IconUri -Value $IconPath -PropertyType String -Force
    $null = New-ItemProperty -Path $AppRegPath -Name ShowInSettings -Value 0 -PropertyType DWORD -Force
    $null = Remove-PSDrive -Name HKCR -Force
}
# Scheduled task function - creates a scheduled task to run NinjaGet updater.
function Register-NinjaGetUpdaterScheduledTask {
    param(
        # The time to update at.
        [string]$TimeToUpdate = '16:00',
        # The update interval.
        [string]$UpdateInterval = 'Daily',
        # Whether to update at logon.
        [int]$UpdateAtLogon
    )
    $TaskAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -File `"$InstallPath\PS\Invoke-NinjaGetUpdates.ps1`""
    $TaskTriggers = [System.Collections.Generic.List[Object]]@()
    if ($UpdateAtLogon) {
        $LogonTrigger = New-ScheduledTaskTrigger -AtLogOn
        $TaskTriggers.Add($LogonTrigger)
    }
    if ($UpdateInterval -eq 'Daily') {
        $DailyTrigger = New-ScheduledTaskTrigger -Daily -At $TimeToUpdate
        $TaskTriggers.Add($DailyTrigger)
    }
    if ($UpdateInterval -eq 'Every2Days') {
        $DailyTrigger = New-ScheduledTaskTrigger -Daily -At $TimeToUpdate -DaysInterval 2
        $TaskTriggers.Add($DailyTrigger)
    }
    if ($UpdateInterval -eq 'Weekly') {
        $WeeklyTrigger = New-ScheduledTaskTrigger -Weekly -At $TimeToUpdate -DaysOfWeek 2
        $TaskTriggers.Add($WeeklyTrigger)
    }
    if ($UpdateInterval -eq 'Every2Weeks') {
        $WeeklyTrigger = New-ScheduledTaskTrigger -Weekly -At $TimeToUpdate -DaysOfWeek 2 -WeeksInterval 2
        $TaskTriggers.Add($WeeklyTrigger)
    }
    if ($UpdateInterval -eq 'Monthly') {
        $MonthlyTrigger = New-ScheduledTaskTrigger -Monthly -At $TimeToUpdate -DaysOfMonth 1
        $TaskTriggers.Add($MonthlyTrigger)
    }
    $TaskServicePrincipal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -RunLevel Highest
    $TaskSettings = New-ScheduledTaskSettingsSet -Compatibility Win8 -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit '03:00:00'
    if ($TaskTriggers) {
        $ScheduledTask = New-ScheduledTask -Action $TaskAction -Principal $TaskServicePrincipal -Settings $TaskSettings -Trigger $TaskTriggers
    } else {
        $ScheduledTask = New-ScheduledTask -Action $TaskAction -Principal $TaskServicePrincipal -Settings $TaskSettings
    }
    $null = Register-ScheduledTask -TaskName 'NinjaGet Updater' -InputObject $ScheduledTask -Force
}
# Scheduled task function - creates a scheduled task for NinjaGet notifications.
function Register-NinjaGetNotificationsScheduledTask {
    $taskAction = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$InstallPath\VBS\hideui.vbs`" `"powershell.exe -NoProfile -File `"$InstallPath\PS\Send-NinjaGetNotification.ps1`""
    $TaskServicePrincipal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-11'
    $TaskSettings = New-ScheduledTaskSettingsSet -Compatibility Win8 -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit '00:05:00'
    $ScheduledTask = New-ScheduledTask -Action $TaskAction -Principal $TaskServicePrincipal -Settings $TaskSettings
    $null = Register-ScheduledTask -TaskName 'NinjaGet Notifier' -InputObject $ScheduledTask -Force
    # Set the task to be runnable for all users.
    $Scheduler = New-Object -ComObject 'Schedule.Service'
    $Scheduler.Connect()
    $Task = $Scheduler.GetFolder('').GetTask('NinjaGet Notifier')
    $SecurityDescriptor = $Task.GetSecurityDescriptor(0xF)
    $SecurityDescriptor = $SecurityDescriptor + '(A;;GRGX;;;AU)'
    $Task.SetSecurityDescriptor($SecurityDescriptor, 0)
}
# Get NinjaGet settings function - gets the NinjaGet setting(s) from the registry.
function Get-NinjaGetSetting {
    [CmdletBinding()]
    param(
        # The setting to get.
        [ValidateSet(
            'LogPath',
            'TrackingPath',
            'NotificationLevel',
            'AutoUpdate',
            'AutoUpdateBlocklist',
            'DisableOnMetered',
            'MachineScopeOnly',
            'UpdateOnLogin',
            'StoreUpdatesOriginalValue'
        )]
        [string]$Setting
    )
    begin {
        $RegistryPath = 'HKLM:\SOFTWARE\NinjaGet'
    }
    process {
        # Get the setting
        $SettingValue = Get-ItemPropertyValue -Path $RegistryPath -Name $Setting -ErrorAction SilentlyContinue
    }
    end {
        # If we have a value, return it.
        if ($SettingValue) {
            return $SettingValue
        } else {
            # If we don't have a value, log an error and return $null.
            Write-NGLog -LogMsg ('The setting [{0}] does not have a value set in the registry.' -f $Setting) -LogColour 'Amber'
            return $null
        }
    }
}
# Register NinjaGet settings function - registers the NinjaGet settings in the registry.
function Register-NinjaGetSettings {
    [CmdletBinding()]
    param(
        # The log file path setting.
        [string]$LogPath,
        # The tracking file path setting.
        [string]$TrackingPath,
        # Notification level setting.
        [ValidateSet('Full', 'SuccessOnly', 'None')]
        [string]$NotificationLevel,
        # Auto update setting.
        [int]$AutoUpdate,
        # Auto update blocklist setting.
        [string[]]$AutoUpdateBlocklist,
        # RMM platform setting.
        [ValidateSet('NinjaRMM')]
        [string]$RMMPlatform,
        # RMM platform last run field setting.
        [string]$LastRunField,
        # RMM platform last run status field setting.
        [string]$LastRunStatusField,
        # RMM platform install field setting.
        [string]$InstallField,
        # RMM platform uninstall field setting.
        [string]$UninstallField,
        # Notification image URL setting.
        [uri]$NotificationImageURL,
        # Notification title setting.
        [string]$NotificationTitle,
        # Update interval setting.
        [ValidateSet('Daily', 'Every2Days', 'Weekly', 'Every2Weeks', 'Monthly')]
        [string]$UpdateInterval,
        # Update time setting.
        [string]$UpdateTime,
        # Update on login setting.
        [int]$UpdateOnLogin,
        # Disable on metered setting.
        [int]$DisableOnMetered,
        # Machine scope only setting.
        [int]$MachineScopeOnly,
        # Use task scheduler setting.
        [int]$UseTaskScheduler,
        # Store Updates original setting.
        [int]$StoreUpdatesOriginalValue
    )
    $RegistryPath = 'HKLM:\SOFTWARE\NinjaGet'
    $null = New-Item -Path $RegistryPath -Force
    if ($NotificationLevel) {
        $null = New-ItemProperty -Path $RegistryPath -Name 'NotificationLevel' -Value $NotificationLevel -Force
    }
    if ($AutoUpdate) {
        $null = New-ItemProperty -Path $RegistryPath -Name 'AutoUpdate' -Value $AutoUpdate -PropertyType DWORD -Force
    }
    if ($AutoUpdateBlocklist) {
        $null = New-ItemProperty -Path $RegistryPath -Name 'AutoUpdateBlocklist' -Value $AutoUpdateBlocklist -PropertyType 'MultiString' -Force
    }
    if ($RMMPlatform) {
        $null = New-ItemProperty -Path $RegistryPath -Name 'RMMPlatform' -Value $RMMPlatform -Force
    }
    if ($RMMPlatformLastRunField) {
        $null = New-ItemProperty -Path $RegistryPath -Name 'RMMPlatformLastRunField' -Value $RMMPlatformLastRunField -Force
    }
    if ($DisableOnMetered) {
        $null = New-ItemProperty -Path $RegistryPath -Name 'DisableOnMetered' -Value $DisableOnMetered -PropertyType DWORD -Force
    }
    if ($MachineScopeOnly) {
        $null = New-ItemProperty -Path $RegistryPath -Name 'MachineScopeOnly' -Value $MachineScopeOnly -PropertyType DWORD -Force
    }
    if ($UpdateOnLogin) {
        $null = New-ItemProperty -Path $RegistryPath -Name 'UpdateOnLogin' -Value $UpdateOnLogin -PropertyType DWORD -Force
    }
    if ($StoreUpdatesOriginalValue) {
        $null = New-ItemProperty -Path $RegistryPath -Name 'StoreUpdatesOriginalValue' -Value $StoreUpdatesOriginalValue -PropertyType DWORD -Force
    }
}
# Set Scope Machine function - sets WinGet's default installation scope to machine.
function Set-ScopeMachine {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Narrowly defined system state change - altering WinGet configuration.'
    )]
    [CmdletBinding()]
    param (
        # Require only machine scoped packages.
        [bool]$MachineScopeOnly
    )
    # Get the WinGet settings path.
    if ([System.Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) {
        # Running in SYSTEM context.
        $SettingsPath = "$ENV:WinDir\system32\config\systemprofile\AppData\Local\Microsoft\WinGet\Settings\defaultState\"
        $SettingsFile = Join-Path -Path $SettingsPath -ChildPath 'settings.json'
        Write-NGLog -LogMsg ('Configuring WinGet to use machine scope for SYSTEM context.') -LogColour 'Yellow'
        Write-Verbose ('Configuring WinGet to use machine scope for SYSTEM context using config path: {0}' -f $SettingsFile)
    } else {
        # Running in user context.
        $SettingsPath = "$ENV:LocalAppData\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\"
        $SettingsFile = Join-Path -Path $SettingsPath -ChildPath 'settings.json'
        Write-NGLog -LogMsg ('Configuring WinGet to use machine scope for user context.') -LogColour 'Yellow'
        Write-Verbose ('Configuring WinGet to use machine scope for user context using config path: {0}' -f $SettingsFile)
    }
    # Create the settings directory if it doesn't exist.
    if (!(Test-Path $SettingsPath)) {
        New-Item -Path $SettingsPath -ItemType Directory -Force
    }
    # Check if the settings file already exists.
    if (Test-Path $SettingsFile) {
        # Check if the settings file already has the correct scope.
        $WinGetConfig = Get-Content $SettingsFile -Raw | Where-Object { $_ -notmatch '//' } | ConvertFrom-Json
    }
    if (!$WinGetConfig) {
        # Initialise a blank WinGet config object.
        $WinGetConfig = @{
            '$schema' = 'https://aka.ms/winget-settings.schema.json'
        }
    }
    if (!$WinGetConfig.'$schema') {
        Add-Member -InputObject $WinGetConfig -MemberType NoteProperty -Name '$schema' -Value 'https://aka.ms/winget-settings.schema.json' -Force
    }
    if ($WinGetConfig.installBehavior.preferences) {
        Add-Member -InputObject $WinGetConfig.installBehavior.preferences -MemberType NoteProperty -Name 'scope' -Value 'machine' -Force
    } elseif ($WinGetConfig.InstallBehaviour) {
        $Scope = New-Object -TypeName PSObject -Property $(@{ scope = 'machine' })
        Add-Member -InputObject $WinGetConfig.installBehavior -Name 'preferences' -MemberType NoteProperty -Value $Scope
    } else {
        $Scope = New-Object -TypeName PSObject -Property $(@{ scope = 'machine' })
        $Preference = New-Object -TypeName PSObject -Property $(@{ preferences = $Scope })
        Add-Member -InputObject $WinGetConfig -MemberType NoteProperty -Name 'installBehavior' -Value $Preference -Force
    }
    if ($MachineScopeOnly) {
        if ($WinGetConfig.installBehavior.requirements) {
            Add-Member -InputObject $WinGetConfig.installBehavior.requirements -MemberType NoteProperty -Name 'scope' -Value 'machine' -Force
        } elseif ($WinGetConfig.installBehavior) {
            $Scope = New-Object -TypeName PSObject -Property $(@{ scope = 'machine' })
            Add-Member -InputObject $WinGetConfig.installBehavior -MemberType NoteProperty -Name 'requirements' -Value $Scope
        } else {
            $Scope = New-Object -TypeName PSObject -Property $(@{ scope = 'machine' })
            $Requirement = Add-Member -InputObject $WinGetConfig -MemberType PSObject -Property $(@{ requirements = $Scope })
            Add-Member -InputObject $WinGetConfig -MemberType NoteProperty -Name 'installBehavior' -Value $Requirement -Force
        }
    }
    Write-Debug ('WinGet config: {0}' -f ($WinGetConfig | ConvertTo-Json -Depth 10))
    $WinGetConfigJSON = $WinGetConfig | ConvertTo-Json -Depth 10
    Set-Content -Path $SettingsFile -Value $WinGetConfigJSON -Force
}
# Notification priority function - sets the notification priority for NinjaGet.
function Set-NotificationPriority {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Narrowly defined system state change - altering priority for notifications.'
    )]
    [CmdletBinding()]
    param(
        # Set for all users.
        [switch]$AllUsers
    )
    if (!$AllUsers) {
        # Set for current user only.
        $RegistryPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings\NinjaGet.Notifications'
        
    }
}