#Requires -Version 5.1
<#+.SYNOPSIS
Audits a Windows workstation and optionally performs selected maintenance.
.DESCRIPTION
Run without switches for an audit. -Clean alone cleans old temporary files.
Operation switches replace that default. -Clean -All selects all four operations:
TempFiles, RemoveStaleProfiles, ComponentStore, and RepairWindows.
Windows Update installation, browser clearing, and software downloads are absent.
Run as SYSTEM or an elevated administrator in 64-bit Windows PowerShell 5.1.
Results are saved under ProgramData\PSWinVitals. No reboot is initiated.
.PARAMETER Clean
Enable the selected maintenance operations. Without operation switches, clean Temp.
.PARAMETER TempFiles
Remove old files from Windows Temp and normal unloaded profiles' Local Temp.
.PARAMETER RemoveStaleProfiles
Remove ALL eligible profiles older than ProfileAgeDays using the Windows provider.
This permanently removes their local files, certificates, caches, and settings.
.PARAMETER ComponentStore
Run DISM StartComponentCleanup without ResetBase.
.PARAMETER RepairWindows
Run DISM RestoreHealth with LimitAccess, then SFC scannow. No Windows Update fallback.
.PARAMETER All
Select all four maintenance operations. Requires Clean. Safety exclusions still apply.
.PARAMETER CheckIntegrity
Run DISM ScanHealth, SFC verifyonly, and read-only CHKDSK on the Windows volume.
.PARAMETER ProfileAgeDays
Profile inactivity threshold in days. Default 180. There is no profile-count limit.
.PARAMETER TempAgeDays
Temporary-file age threshold in days. Default 7; creation and last-write must qualify.
.PARAMETER ExcludeProfiles
Additional exact profile directory names or SIDs to retain, including shared accounts.
.PARAMETER RepairSource
Optional locally staged Windows repair-source directory. It must match the installed OS.
.PARAMETER SkipProfileSizes
Skip profile file enumeration in an audit or temp-only pass. Full profile removal
always inspects candidates for unreadable paths, encrypted files, and cloud folders.
.EXAMPLE
.\Invoke-EndpointMaintenance.ps1
.EXAMPLE
.\Invoke-EndpointMaintenance.ps1 -Clean
.EXAMPLE
.\Invoke-EndpointMaintenance.ps1 -Clean -RemoveStaleProfiles -ProfileAgeDays 180 -WhatIf
.EXAMPLE
.\Invoke-EndpointMaintenance.ps1 -Clean -TempFiles -RemoveStaleProfiles
.EXAMPLE
.\Invoke-EndpointMaintenance.ps1 -Clean -All -ExcludeProfiles 'kiosk', 'shareduser'
.NOTES
Version 1.0.0-rc1. Derived from ralish/PSWinVitals, Copyright (c) Samuel Leslie.
Upstream baseline: ff133b76a1b8b444c46f5bdb3e9118d9b0ad83b5.
MIT license reproduced at the end of this file.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [switch]$Clean,
    [switch]$TempFiles,
    [switch]$RemoveStaleProfiles,
    [switch]$ComponentStore,
    [switch]$RepairWindows,
    [switch]$All,
    [switch]$CheckIntegrity,
    [ValidateRange(1, 3650)][int]$ProfileAgeDays = 180,
    [ValidateRange(1, 3650)][int]$TempAgeDays = 7,
    [string[]]$ExcludeProfiles = @(),
    [string]$RepairSource,
    [switch]$SkipProfileSizes
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:Version = '1.0.0-rc1'
$script:EventWriter = $null
$script:RunDirectory = $null
$script:RebootRequired = $false

# Small data and logging helpers.
function Get-Value {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $Property = $Object.PSObject.Properties[$Name]
    if ($null -eq $Property) { return $Default }
    return $Property.Value
}

function New-Result {
    param([string]$State = 'Completed', [string]$Finding = 'NotApplicable',
        [string]$Summary, $Data = $null)
    [pscustomobject]@{ State = $State; Finding = $Finding; Summary = $Summary; Data = $Data }
}

function Write-RunEvent {
    param([string]$Task, [string]$Event, $Data = $null)
    if ($null -ne $script:EventWriter) {
        $Record = [ordered]@{
            TimeUtc = [datetime]::UtcNow.ToString('o')
            Task = $Task; Event = $Event; Data = $Data
        }
        $script:EventWriter.WriteLine(($Record | ConvertTo-Json -Depth 8 -Compress))
        $script:EventWriter.Flush()
        $script:EventWriter.BaseStream.Flush($true)
    }
}

function Invoke-LoggedTask {
    param([string]$Name, [scriptblock]$Action)
    $Start = [datetime]::UtcNow
    Write-RunEvent $Name 'Started'
    try {
        $Result = & $Action
        if ($null -eq $Result -or $null -eq $Result.PSObject.Properties['State']) {
            throw 'The task did not return a result.'
        }
    } catch {
        $Result = New-Result 'Failed' 'Unknown' $_.Exception.Message
    }
    $Task = [pscustomobject][ordered]@{
        Name = $Name; State = $Result.State; Finding = $Result.Finding
        Summary = $Result.Summary; StartedUtc = $Start.ToString('o')
        EndedUtc = [datetime]::UtcNow.ToString('o')
        Seconds = [math]::Round(([datetime]::UtcNow - $Start).TotalSeconds, 2)
        Data = $Result.Data
    }
    Write-RunEvent $Name $Task.State $Task
    return $Task
}

function Get-Operation {
    param([bool]$EnableClean, [bool]$Temp, [bool]$Profiles, [bool]$Components,
        [bool]$Repair, [bool]$Everything)
    if (!$EnableClean -and ($Temp -or $Profiles -or $Components -or $Repair -or $Everything)) {
        throw 'Maintenance operation switches require -Clean. Use -Clean -WhatIf to preview.'
    }
    $Selected = [collections.generic.list[string]]::new()
    if (!$EnableClean) { return $Selected.ToArray() }
    if ($Everything -or $Temp) { $Selected.Add('TempFiles') }
    if ($Everything -or $Profiles) { $Selected.Add('StaleProfiles') }
    if ($Everything -or $Repair) { $Selected.Add('RepairWindows') }
    if ($Everything -or $Components) { $Selected.Add('ComponentStore') }
    if ($Selected.Count -eq 0) { $Selected.Add('TempFiles') }
    return $Selected.ToArray()
}

function Get-ProfileExclusion {
    param([string[]]$Names)
    # A single comma-separated argument also works through powershell.exe -File.
    return @($Names | ForEach-Object { $_ -split ',' | ForEach-Object { $_.Trim() } } |
        Where-Object { $_ } | Sort-Object -Unique)
}

function Get-IoErrorCode {
    param([exception]$Exception)
    while ($null -ne $Exception.InnerException) { $Exception = $Exception.InnerException }
    return $Exception.HResult -band 65535
}

# Never resolve a link into a cleanup target. Check every existing ancestor.
function Assert-PlainPath {
    param([Parameter(Mandatory)][string]$Path)
    $Full = [io.path]::GetFullPath($Path)
    if ($Full.StartsWith('\\') -or $Full.StartsWith('//')) { throw 'Network paths are not allowed.' }
    $Current = $Full
    while ($Current) {
        if ([io.file]::Exists($Current) -or [io.directory]::Exists($Current)) {
            $Attributes = [io.file]::GetAttributes($Current)
            if (($Attributes -band [io.fileattributes]::ReparsePoint) -ne 0) {
                throw ('Reparse-point path rejected: {0}' -f $Current)
            }
        }
        $Parent = [io.path]::GetDirectoryName($Current)
        if (!$Parent -or $Parent -eq $Current) { break }
        $Current = $Parent
    }
    return $Full.TrimEnd([io.path]::DirectorySeparatorChar)
}

function Test-PathUnderRoot {
    param([string]$Path, [string]$Root)
    $Full = [io.path]::GetFullPath($Path).TrimEnd([io.path]::DirectorySeparatorChar)
    $Base = [io.path]::GetFullPath($Root).TrimEnd([io.path]::DirectorySeparatorChar)
    return $Full.StartsWith(($Base + [io.path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)
}

function Initialize-LogRoot {
    $Root = Join-Path $env:ProgramData 'PSWinVitals'
    $null = Assert-PlainPath $Root
    $AdminSid = [security.principal.securityidentifier]::new('S-1-5-32-544')
    $SystemSid = [security.principal.securityidentifier]::new('S-1-5-18')
    if (![io.directory]::Exists($Root)) {
        $Acl = [security.accesscontrol.directorysecurity]::new()
        $Acl.SetAccessRuleProtection($true, $false)
        $Acl.SetOwner($AdminSid)
        foreach ($Sid in @($AdminSid, $SystemSid)) {
            $Rule = [security.accesscontrol.filesystemaccessrule]::new($Sid, 'FullControl',
                'ContainerInherit, ObjectInherit', 'None', 'Allow')
            $Acl.AddAccessRule($Rule)
        }
        $null = [io.directory]::CreateDirectory($Root, $Acl)
    }
    $ExistingAcl = Get-Acl -LiteralPath $Root
    $OwnerSid = $ExistingAcl.GetOwner([security.principal.securityidentifier]).Value
    if ($OwnerSid -notin @($AdminSid.Value, $SystemSid.Value)) {
        throw 'The log directory must be owned by SYSTEM or Administrators.'
    }
    $WriteMask = [security.accesscontrol.filesystemrights]'Write, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership'
    foreach ($Rule in $ExistingAcl.GetAccessRules($true, $true, [security.principal.securityidentifier])) {
        if ($Rule.AccessControlType -eq 'Allow' -and ($Rule.FileSystemRights -band $WriteMask) -ne 0 -and
            $Rule.IdentityReference.Value -notin @($AdminSid.Value, $SystemSid.Value)) {
            throw 'The log directory permits writes by an identity other than SYSTEM/Administrators.'
        }
    }
    return $Root
}

function New-TreeStatistics {
    return @{ Files = 0L; Bytes = 0L; Links = 0L; UnsafeLinks = 0L; Cloud = 0L; Encrypted = 0L; Errors = 0L }
}

# Stream metadata only: no file content is opened, no cloud files are hydrated.
function Get-PlainFile {
    param([string]$Root, [hashtable]$Statistics, [switch]$AllowProfileJunctions)
    $null = Assert-PlainPath $Root
    if (![io.directory]::Exists($Root)) { throw ('Directory does not exist: {0}' -f $Root) }
    $Pending = [collections.generic.stack[io.directoryinfo]]::new()
    $Pending.Push([io.directoryinfo]::new($Root))
    while ($Pending.Count -gt 0) {
        $Directory = $Pending.Pop()
        $Iterator = $null
        try {
            $null = Assert-PlainPath $Directory.FullName
            $Iterator = $Directory.EnumerateFileSystemInfos().GetEnumerator()
            while ($Iterator.MoveNext()) {
                $Entry = $Iterator.Current
                $Attributes = $Entry.Attributes
                if (($Attributes -band 1024) -ne 0) {
                    $Statistics.Links++
                    $KnownLegacyLink = $false
                    if ($AllowProfileJunctions) {
                        $Relative = $Entry.FullName.Substring($Root.TrimEnd('\').Length).TrimStart('\')
                        $LegacyNames = @('Application Data', 'Cookies', 'Local Settings', 'My Documents', 'NetHood',
                            'PrintHood', 'Recent', 'SendTo', 'Start Menu', 'Templates', 'Documents\My Music',
                            'Documents\My Pictures', 'Documents\My Videos', 'AppData\Local\Application Data',
                            'AppData\Local\History', 'AppData\Local\Temporary Internet Files')
                        if ($Relative -in $LegacyNames) {
                            $Targets = @((Get-Item -LiteralPath $Entry.FullName -Force).Target)
                            $KnownLegacyLink = ($Targets.Count -eq 1 -and (Test-PathUnderRoot $Targets[0] $Root))
                        }
                    }
                    if (!$KnownLegacyLink) { $Statistics.UnsafeLinks++ }
                    continue
                }
                # Offline, RecallOnOpen, or RecallOnDataAccess.
                if (($Attributes -band (4096 -bor 262144 -bor 4194304)) -ne 0) {
                    $Statistics.Cloud++; continue
                }
                if (($Attributes -band [io.fileattributes]::Directory) -ne 0) {
                    $Pending.Push([io.directoryinfo]$Entry)
                } else {
                    if (($Attributes -band [io.fileattributes]::Encrypted) -ne 0) { $Statistics.Encrypted++ }
                    $Statistics.Files++
                    Write-Output -NoEnumerate $Entry
                }
            }
        } catch {
            $Statistics.Errors++
        } finally {
            if ($null -ne $Iterator -and $Iterator -is [idisposable]) { $Iterator.Dispose() }
        }
    }
}

function Measure-ProfileDirectory {
    param([string]$Path, [switch]$AllowProfileJunctions)
    $Stats = New-TreeStatistics
    try {
        Get-PlainFile $Path $Stats -AllowProfileJunctions:$AllowProfileJunctions | ForEach-Object {
            try { $Stats.Bytes += $_.Length } catch { $Stats.Errors++ }
        }
    } catch { $Stats.Errors++ }
    [pscustomobject]@{
        LogicalBytes = $Stats.Bytes; Files = $Stats.Files; SkippedLinks = $Stats.Links
        SkippedCloud = $Stats.Cloud; EncryptedFiles = $Stats.Encrypted; UnsafeLinks = $Stats.UnsafeLinks
        Errors = $Stats.Errors; Complete = ($Stats.Errors -eq 0 -and $Stats.Cloud -eq 0 -and $Stats.Links -eq 0)
    }
}

# Profile age comes from profile-service FILETIME evidence, never folder dates.
function Convert-ProfileFileTime {
    param($High, $Low)
    if ($null -eq $High -or $null -eq $Low) { return $null }
    try {
        [uint64]$Hi = [int64]$High -band 4294967295L
        [uint64]$Lo = [int64]$Low -band 4294967295L
        [uint64]$FileTime = ($Hi -shl 32) -bor $Lo
        if ($FileTime -eq 0 -or $FileTime -gt [int64]::MaxValue) { return $null }
        return [datetime]::FromFileTimeUtc([int64]$FileTime)
    } catch { return $null }
}

function Get-ProfileAge {
    param($Registry, $CimLastUseTime, [datetime]$NowUtc = [datetime]::UtcNow)
    $NowUtc = $NowUtc.ToUniversalTime()
    $Load = Convert-ProfileFileTime (Get-Value $Registry 'LocalProfileLoadTimeHigh') (Get-Value $Registry 'LocalProfileLoadTimeLow')
    $Unload = Convert-ProfileFileTime (Get-Value $Registry 'LocalProfileUnLoadTimeHigh') (Get-Value $Registry 'LocalProfileUnLoadTimeLow')
    $CimTime = $null
    $InvalidEvidence = $false
    foreach ($Pair in @(@('LocalProfileLoadTimeHigh', 'LocalProfileLoadTimeLow'), @('LocalProfileUnLoadTimeHigh', 'LocalProfileUnLoadTimeLow'))) {
        $High = Get-Value $Registry $Pair[0]; $Low = Get-Value $Registry $Pair[1]
        if (($null -ne $High -or $null -ne $Low) -and !($High -eq 0 -and $Low -eq 0) -and
            $null -eq (Convert-ProfileFileTime $High $Low)) { $InvalidEvidence = $true }
    }
    if ($CimLastUseTime) {
        try { $CimTime = ([datetime]$CimLastUseTime).ToUniversalTime() } catch { $InvalidEvidence = $true }
    }
    $Times = @(@($Load, $Unload) | Where-Object { $null -ne $_ })
    $Reason = $null
    $Last = $null
    if ($InvalidEvidence) {
        $Reason = 'Profile activity evidence is invalid or incomplete'
    } elseif ($Times.Count -eq 0) {
        $Reason = 'No valid registry profile-activity timestamp'
    } elseif (@($Times | Where-Object { $_ -gt $NowUtc }).Count -gt 0 -or ($CimTime -and $CimTime -gt $NowUtc)) {
        $Reason = 'Profile activity timestamp is in the future'
    } else {
        $Last = $Times | Sort-Object -Descending | Select-Object -First 1
        if ($CimTime -and $CimTime -gt $Last) { $Last = $CimTime }
    }
    [pscustomobject]@{
        RegistryLoadUtc = $Load; RegistryUnloadUtc = $Unload; CimLastUseUtc = $CimTime
        LastActivityUtc = $Last; AgeDays = $(if ($Last) { [math]::Floor(($NowUtc - $Last).TotalDays) } else { $null })
        AgeSource = 'Latest valid registry load/unload, with newer CIM activity retained'
        AgeUnknownReason = $Reason
    }
}

function Get-ProfileRecord {
    param($CimProfile)
    $Sid = [string]$CimProfile.SID
    $Key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\' + $Sid
    $Registry = $null
    $ErrorText = $null
    try { $Registry = Get-ItemProperty -LiteralPath $Key } catch { $ErrorText = $_.Exception.Message }
    $Age = Get-ProfileAge $Registry (Get-Value $CimProfile 'LastUseTime')
    $Redirected = @('AppDataRoaming', 'Desktop', 'Documents', 'Pictures', 'Music', 'Videos', 'Favorites',
        'Contacts', 'Downloads', 'Links', 'Searches', 'SavedGames', 'StartMenu' | Where-Object {
        [bool](Get-Value (Get-Value $CimProfile $_) 'Redirected' $false)
    })
    $Name = $null
    try { $Name = [security.principal.securityidentifier]::new($Sid).Translate([security.principal.ntaccount]).Value } catch { }
    [pscustomobject][ordered]@{
        SID = $Sid; Account = $Name; Path = [string]$CimProfile.LocalPath
        RegistryPath = [environment]::ExpandEnvironmentVariables([string](Get-Value $Registry 'ProfileImagePath' ''))
        RegistryError = $ErrorText; Loaded = [bool]$CimProfile.Loaded; Special = [bool]$CimProfile.Special
        RefCount = [int](Get-Value $CimProfile 'RefCount' 0); Status = [int](Get-Value $CimProfile 'Status' 0)
        RoamingConfigured = [bool](Get-Value $CimProfile 'RoamingConfigured' $false); RedirectedFolders = $Redirected
        Age = $Age; Size = $null; Eligible = $false; SkipReasons = @()
        Action = 'Retained'; Verification = $null
    }
}

function Get-ProfileProtection {
    param($Profile, [string]$ProfilesRoot, [string[]]$LocalSids,
        [string[]]$Excluded, [string]$CurrentSid)
    $Reasons = [collections.generic.list[string]]::new()
    $Leaf = [io.path]::GetFileName($Profile.Path.TrimEnd('\'))
    if ($Profile.SID -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$') { $Reasons.Add('Not a normal Windows account SID') }
    if ($Profile.SID -match '-(500|501|502)$') { $Reasons.Add('Built-in account SID') }
    if ($Profile.Special) { $Reasons.Add('Special/system profile') }
    if ($Profile.Loaded -or $Profile.RefCount -gt 0) { $Reasons.Add('Profile is loaded or referenced') }
    if ($Profile.SID -eq $CurrentSid) { $Reasons.Add('Executing identity') }
    if ($LocalSids -contains $Profile.SID) { $Reasons.Add('Local account retained') }
    if ($Leaf -in @('Default', 'Default User', 'All Users', 'Public', 'Administrator', 'defaultuser0',
        'WDAGUtilityAccount', 'systemprofile', 'LocalService', 'NetworkService')) { $Reasons.Add('Built-in profile directory') }
    if ($Excluded -contains $Leaf -or $Excluded -contains $Profile.SID -or $Excluded -contains $Profile.Account) {
        $Reasons.Add('Explicit profile exclusion')
    }
    if ($Profile.RegistryError) { $Reasons.Add('Profile registration could not be read') }
    if (($Profile.Status -band 15) -ne 0 -or $Profile.RoamingConfigured) {
        $Reasons.Add('Temporary, mandatory, corrupt, or roaming profile')
    }
    if (@($Profile.RedirectedFolders).Count -gt 0) { $Reasons.Add('Folder-redirection profile requires separate review') }
    try {
        $Path = Assert-PlainPath $Profile.Path
        $RegistryPath = Assert-PlainPath $Profile.RegistryPath
        if (!$Path.Equals($RegistryPath, [StringComparison]::OrdinalIgnoreCase)) { $Reasons.Add('CIM and registry paths disagree') }
        if (![io.path]::GetDirectoryName($Path).Equals($ProfilesRoot, [StringComparison]::OrdinalIgnoreCase)) {
            $Reasons.Add('Profile is outside the immediate profiles root')
        }
        if (![io.directory]::Exists($Path)) { $Reasons.Add('Profile directory is missing') }
        if (Test-Path -LiteralPath ('Registry::HKEY_USERS\' + $Profile.SID)) { $Reasons.Add('Registry hive is mounted') }
    } catch { $Reasons.Add('Unsafe or unreadable profile path/hive') }
    return $Reasons.ToArray()
}

function Test-ProfileAge {
    param($Profile, [int]$Days, [datetime]$NowUtc = [datetime]::UtcNow)
    $NowUtc = $NowUtc.ToUniversalTime()
    return ($null -ne $Profile.Age.LastActivityUtc -and !$Profile.Age.AgeUnknownReason -and
        $Profile.Age.LastActivityUtc.ToUniversalTime() -lt $NowUtc.AddDays(-$Days))
}

function Get-ProfileInspectionReason {
    param($Profile)
    $Reasons = [collections.generic.list[string]]::new()
    if ($null -eq $Profile.Size) { $Reasons.Add('Profile safety inspection not completed') }
    else {
        if ($Profile.Size.Errors -gt 0) { $Reasons.Add('Profile inspection had access/enumeration errors') }
        if ($Profile.Size.EncryptedFiles -gt 0) { $Reasons.Add('EFS-encrypted files found') }
        if ($Profile.Size.SkippedCloud -gt 0) { $Reasons.Add('Cloud/offline placeholders found') }
        if ($Profile.Size.UnsafeLinks -gt 0) { $Reasons.Add('Nonstandard or external reparse points found') }
    }
    try {
        if (@(Get-ChildItem -LiteralPath $Profile.Path -Force -Directory | Where-Object { $_.Name -like 'OneDrive*' }).Count -gt 0) {
            $Reasons.Add('OneDrive directory requires separate review')
        }
        # Containers and redirected profile locations need separate validation.
        if (Test-Path -LiteralPath (Join-Path $Profile.Path 'AppData\Local\FSLogix')) { $Reasons.Add('Profile-container configuration detected') }
    } catch { $Reasons.Add('Profile configuration could not be inspected') }
    return $Reasons.ToArray()
}

function Get-ProfileInventory {
    param([int]$Days, [string[]]$Excluded, [bool]$SkipSizes, [bool]$Removing)
    $RootValue = Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -Name ProfilesDirectory
    $Root = Assert-PlainPath ([environment]::ExpandEnvironmentVariables($RootValue))
    $CurrentSid = [security.principal.windowsidentity]::GetCurrent().User.Value
    # If local-account discovery fails, fail this task instead of deleting unknown local identities.
    $LocalSids = @(Get-CimInstance Win32_UserAccount -Filter 'LocalAccount = True' -OperationTimeoutSec 30 | Select-Object -ExpandProperty SID)
    if ($LocalSids.Count -eq 0) { throw 'Local-account inventory returned no accounts; profile cleanup cannot be authorized.' }
    $Profiles = @(Get-CimInstance Win32_UserProfile -OperationTimeoutSec 30)
    $Records = [collections.generic.list[object]]::new()
    foreach ($CimProfile in $Profiles) {
        $Profile = Get-ProfileRecord $CimProfile
        Write-RunEvent 'Profiles' 'Inspecting' @{ SID = $Profile.SID; Path = $Profile.Path }
        $Reasons = @(Get-ProfileProtection $Profile $Root $LocalSids $Excluded $CurrentSid)
        $Profile.SkipReasons = $Reasons
        if (!$SkipSizes -or ($Removing -and $Reasons.Count -eq 0 -and (Test-ProfileAge $Profile $Days))) {
            if ([io.directory]::Exists($Profile.Path)) { $Profile.Size = Measure-ProfileDirectory $Profile.Path -AllowProfileJunctions }
        }
        if ($Reasons.Count -eq 0) {
            if (!(Test-ProfileAge $Profile $Days)) {
                $Reasons += $(if ($Profile.Age.AgeUnknownReason) { $Profile.Age.AgeUnknownReason } else { 'Profile is within the retention age' })
            }
            $Reasons += @(Get-ProfileInspectionReason $Profile)
        }
        $Profile.SkipReasons = $Reasons
        $Profile.Eligible = ($Reasons.Count -eq 0)
        $Records.Add($Profile)
    }
    # Duplicate registration is never an automatic deletion candidate.
    foreach ($Group in @($Records | Group-Object Path | Where-Object Count -gt 1)) {
        foreach ($Profile in $Group.Group) { $Profile.Eligible = $false; $Profile.SkipReasons += 'Duplicate registered profile path' }
    }
    $RegisteredPaths = @($Records | ForEach-Object { $_.Path })
    $Orphans = @(Get-ChildItem -LiteralPath $Root -Directory -Force | Where-Object {
        $_.Name -notin @('Default', 'Default User', 'Public', 'All Users') -and $_.FullName -notin $RegisteredPaths
    } | Select-Object -ExpandProperty FullName)
    return [pscustomobject]@{ Root = $Root; CurrentSid = $CurrentSid; LocalSids = $LocalSids; Profiles = $Records.ToArray(); OrphanDirectories = $Orphans }
}

# WTS counts both connected and disconnected interactive sessions, in any locale.
function Get-InteractiveSession {
    if (!('PSWinVitals.Sessions' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace PSWinVitals {
    public static class Sessions {
        [StructLayout(LayoutKind.Sequential)]
        private struct SessionInfo { public int Id; public IntPtr Station; public int State; }
        [DllImport("wtsapi32.dll", SetLastError = true)]
        private static extern bool WTSEnumerateSessions(IntPtr server, int reserved, int version, out IntPtr info, out int count);
        [DllImport("wtsapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool WTSQuerySessionInformation(IntPtr server, int session, int field, out IntPtr data, out int length);
        [DllImport("wtsapi32.dll")] private static extern void WTSFreeMemory(IntPtr data);
        public static string[] GetUsers() {
            var users = new List<string>(); IntPtr info; int count;
            if (!WTSEnumerateSessions(IntPtr.Zero, 0, 1, out info, out count)) throw new Win32Exception();
            try {
                int size = Marshal.SizeOf(typeof(SessionInfo));
                for (int i = 0; i < count; i++) {
                    var session = (SessionInfo)Marshal.PtrToStructure(IntPtr.Add(info, i * size), typeof(SessionInfo));
                    if (session.Id == 0 || session.State == 6) continue;
                    IntPtr data; int length;
                    if (!WTSQuerySessionInformation(IntPtr.Zero, session.Id, 5, out data, out length)) throw new Win32Exception();
                    try {
                        var user = Marshal.PtrToStringUni(data);
                        if (!String.IsNullOrEmpty(user)) users.Add(session.Id.ToString() + ":" + user);
                    } finally { WTSFreeMemory(data); }
                }
            } finally { WTSFreeMemory(info); }
            return users.ToArray();
        }
    }
}
'@
    }
    return [PSWinVitals.Sessions]::GetUsers()
}

function Get-PendingReboot {
    $Reasons = [collections.generic.list[string]]::new()
    $Servicing = $false
    foreach ($Key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')) {
        if (Test-Path -LiteralPath $Key) { $Reasons.Add($Key); $Servicing = $true }
    }
    $SessionManager = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    if (Get-Value $SessionManager 'PendingFileRenameOperations') { $Reasons.Add('Pending file rename operations (not conclusive by itself)') }
    $Active = Get-ItemPropertyValue -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -Name ComputerName
    $Pending = Get-ItemPropertyValue -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -Name ComputerName
    if ($Active -ne $Pending) { $Reasons.Add('Pending computer name change') }
    [pscustomobject]@{ Pending = ($Reasons.Count -gt 0); ServicingReboot = $Servicing; Reasons = $Reasons.ToArray() }
}

function Get-ServicingBlock {
    $Pending = Get-PendingReboot
    if ($Pending.ServicingReboot) { return 'Windows servicing is waiting for a restart' }
    # TrustedInstaller can remain idle after a completed operation; its mere presence is not a block.
    $Busy = @(Get-Process -Name 'dism', 'sfc', 'TiWorker', 'MoUsoCoreWorker' -ErrorAction SilentlyContinue)
    if ($Busy.Count -gt 0) { return ('Existing servicing process: {0}' -f (($Busy.ProcessName | Sort-Object -Unique) -join ', ')) }
    return $null
}

function Get-UserActivityBlock {
    $Sessions = @(Get-InteractiveSession)
    if ($Sessions.Count -gt 0) { return 'An interactive user session is connected or disconnected' }
    foreach ($Battery in @(Get-CimInstance Win32_Battery -OperationTimeoutSec 15)) {
        if ($Battery.BatteryStatus -in @(1, 4, 5) -and $Battery.EstimatedChargeRemaining -lt 30) {
            return 'Battery power is below 30 percent'
        }
    }
    return $null
}

function Remove-OldTempFile {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param([string]$Path, [int]$Days)
    $Root = Assert-PlainPath $Path
    if (![io.directory]::Exists($Root)) { return (New-Result 'Skipped' 'NotApplicable' 'Temp directory is absent') }
    $Apply = $PSCmdlet.ShouldProcess($Root, ('Delete temporary files older than {0} days' -f $Days))
    $Cutoff = [datetime]::UtcNow.AddDays(-$Days)
    $Stats = New-TreeStatistics
    $Counts = @{ Eligible = 0L; Removed = 0L; RemovedLogicalBytes = 0L; Recent = 0L; Locked = 0L; Changed = 0L; Failed = 0L }
    Get-PlainFile $Root $Stats | ForEach-Object {
        $File = $_
        try {
            if ($File.CreationTimeUtc -ge $Cutoff -or $File.LastWriteTimeUtc -ge $Cutoff -or
                ($File.Attributes -band [io.fileattributes]::Encrypted) -ne 0) { $Counts.Recent++; return }
            $Counts.Eligible++
            if (!$Apply) { return }
            $null = Assert-PlainPath $File.FullName
            if (!(Test-PathUnderRoot $File.FullName $Root)) { throw 'Temp file escaped the approved root.' }
            $File.Refresh()
            if (!$File.Exists -or $File.CreationTimeUtc -ge $Cutoff -or $File.LastWriteTimeUtc -ge $Cutoff -or
                ($File.Attributes -band (1024 -bor 4096 -bor 262144 -bor 4194304 -bor 16384)) -ne 0) {
                $Counts.Changed++; return
            }
            $Length = $File.Length
            Remove-Item -LiteralPath $File.FullName -Force -Confirm:$false -ErrorAction Stop
            $Counts.Removed++; $Counts.RemovedLogicalBytes += $Length
        } catch [io.filenotfoundexception] { $Counts.Changed++ }
        catch [io.directorynotfoundexception] { $Counts.Changed++ }
        catch {
            $Code = Get-IoErrorCode $_.Exception
            if ($Code -in @(32, 33)) { $Counts.Locked++ }
            elseif ($Code -in @(2, 3)) { $Counts.Changed++ } else { $Counts.Failed++ }
        }
    }
    $Counts.EnumerationErrors = $Stats.Errors
    $Counts.SkippedLinks = $Stats.Links; $Counts.SkippedCloud = $Stats.Cloud
    $State = if (!$Apply) { if ($WhatIfPreference) { 'Planned' } else { 'Skipped' } } elseif ($Counts.Failed -gt 0 -or $Stats.Errors -gt 0) { 'Failed' } else { 'Completed' }
    $Finding = if ($State -eq 'Failed') { 'Unknown' } else { 'NotApplicable' }
    return (New-Result $State $Finding ('{0}: {1} eligible; {2} removed; {3} locked; {4} errors' -f $Root,
        $Counts.Eligible, $Counts.Removed, $Counts.Locked, ($Counts.Failed + $Stats.Errors)) $Counts)
}

function Invoke-TempCleanup {
    param($Inventory, [int]$Days, [string[]]$Excluded)
    $Results = [collections.generic.list[object]]::new()
    $WindowsTemp = Join-Path $env:SystemRoot 'Temp'
    $Results.Add((Remove-OldTempFile $WindowsTemp $Days))
    if ($null -eq $Inventory) {
        return (New-Result 'Failed' 'Unknown' 'Windows Temp was processed; profile-temp cleanup was blocked by incomplete profile inventory' $Results.ToArray())
    }
    foreach ($Profile in $Inventory.Profiles) {
        $Protection = @(Get-ProfileProtection $Profile $Inventory.Root $Inventory.LocalSids $Excluded $Inventory.CurrentSid)
        if ($Protection.Count -gt 0) { continue }
        $Path = Join-Path $Profile.Path 'AppData\Local\Temp'
        # Refresh loaded state and registry path rather than trust the earlier inventory.
        $FreshCim = @(Get-CimInstance Win32_UserProfile -Filter ("SID='{0}'" -f $Profile.SID) -OperationTimeoutSec 30)
        if ($FreshCim.Count -ne 1) { continue }
        $Fresh = Get-ProfileRecord $FreshCim[0]
        if (@(Get-ProfileProtection $Fresh $Inventory.Root $Inventory.LocalSids $Excluded $Inventory.CurrentSid).Count -gt 0) { continue }
        if (!$Fresh.Path.Equals($Profile.Path, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $Results.Add((Remove-OldTempFile $Path $Days))
    }
    $Failed = @($Results | Where-Object State -eq 'Failed').Count
    $State = if ($Failed) { 'Failed' } elseif ($WhatIfPreference) { 'Planned' } else { 'Completed' }
    return (New-Result $State 'NotApplicable' ('Temp cleanup: {0} targets, {1} incomplete/failed targets' -f $Results.Count, $Failed) $Results.ToArray())
}

function Remove-OldProfile {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param($Inventory, [int]$Days, [string[]]$Excluded)
    $Candidates = @($Inventory.Profiles | Where-Object Eligible | Sort-Object { $_.Age.LastActivityUtc })
    if ($Candidates.Count -eq 0) { return (New-Result 'Completed' 'NotApplicable' 'No eligible stale profiles') }
    $Block = Get-UserActivityBlock
    if ($Block) {
        foreach ($Profile in $Candidates) { $Profile.Action = 'Deferred'; $Profile.Verification = $Block }
        return (New-Result 'Deferred' 'NotApplicable' $Block)
    }
    $Removed = 0; $Skipped = 0; $Failed = 0; $Planned = 0
    foreach ($Profile in $Candidates) {
        try {
            $Block = Get-UserActivityBlock
            if ($Block) {
                $Profile.Action = 'Deferred'; $Profile.Verification = $Block; $Skipped++; continue
            }
            $FreshCim = @(Get-CimInstance Win32_UserProfile -Filter ("SID='{0}'" -f $Profile.SID) -OperationTimeoutSec 30)
            if ($FreshCim.Count -ne 1) { $Profile.Action = 'Skipped'; $Profile.Verification = 'Registration changed'; $Skipped++; continue }
            $Fresh = Get-ProfileRecord $FreshCim[0]
            $Fresh.Size = $Profile.Size
            $Reasons = @(Get-ProfileProtection $Fresh $Inventory.Root $Inventory.LocalSids $Excluded $Inventory.CurrentSid)
            if (!(Test-ProfileAge $Fresh $Days)) { $Reasons += 'Profile activity changed or age is unknown' }
            if (!$Fresh.Path.Equals($Profile.Path, [StringComparison]::OrdinalIgnoreCase)) { $Reasons += 'Registered path changed' }
            $Reasons += @(Get-ProfileInspectionReason $Fresh)
            if ($Reasons.Count -gt 0) {
                $Profile.Action = 'Skipped'; $Profile.Verification = $Reasons -join '; '; $Skipped++; continue
            }
            if (!$PSCmdlet.ShouldProcess(($Fresh.SID + ' ' + $Fresh.Path), 'Permanently remove the complete local profile')) {
                $Profile.Action = $(if ($WhatIfPreference) { 'Planned' } else { 'Skipped' }); $Planned++; continue
            }
            Write-RunEvent 'StaleProfiles' 'Deleting' @{ SID = $Fresh.SID; Path = $Fresh.Path; LastActivityUtc = $Fresh.Age.LastActivityUtc }
            Remove-CimInstance -InputObject $FreshCim[0] -Confirm:$false -ErrorAction Stop
            $StillRegistered = @(Get-CimInstance Win32_UserProfile -Filter ("SID='{0}'" -f $Fresh.SID) -OperationTimeoutSec 30).Count -gt 0
            $Key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\' + $Fresh.SID
            $KeyRemains = Test-Path -LiteralPath $Key -ErrorAction Stop
            $PathRemains = Test-Path -LiteralPath $Fresh.Path -ErrorAction Stop
            if ($StillRegistered -or $KeyRemains -or $PathRemains) { throw 'Windows left a profile registration or directory behind; no fallback purge was attempted.' }
            $Profile.Action = 'Removed'; $Profile.Verification = 'CIM instance, registry key, and directory absent'; $Removed++
            Write-RunEvent 'StaleProfiles' 'Removed' @{ SID = $Fresh.SID; Path = $Fresh.Path }
        } catch {
            $Profile.Action = 'Failed'; $Profile.Verification = $_.Exception.Message; $Failed++
            Write-RunEvent 'StaleProfiles' 'Failed' @{ SID = $Profile.SID; Error = $_.Exception.Message }
        }
    }
    $State = if ($Failed) { 'Failed' } elseif ($Skipped) { 'Deferred' } elseif ($WhatIfPreference) { 'Planned' } else { 'Completed' }
    return (New-Result $State 'NotApplicable' ('Profiles: {0} eligible; {1} removed; {2} skipped/deferred; {3} failed; {4} planned' -f
        $Candidates.Count, $Removed, $Skipped, $Failed, $Planned) @{ Eligible = $Candidates.Count; Removed = $Removed; Skipped = $Skipped; Failed = $Failed; Planned = $Planned })
}

function ConvertTo-NativeArgument {
    param([AllowEmptyString()][string]$Value)
    # Windows CommandLineToArgvW quoting. No cmd.exe or expression evaluation.
    $Escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    return '"' + [regex]::Replace($Escaped, '(\\+)$', '$1$1') + '"'
}

function Read-NativeText {
    param([string]$Path, [int]$CodePage = [globalization.cultureinfo]::CurrentCulture.TextInfo.OEMCodePage)
    $Stream = [io.file]::OpenRead($Path)
    try {
        $Buffer = [byte[]]::new([int][math]::Min($Stream.Length, 524288))
        $Count = $Stream.Read($Buffer, 0, $Buffer.Length)
        if ($Count -ge 2 -and (($Buffer[0] -eq 255 -and $Buffer[1] -eq 254) -or
            @($Buffer | Select-Object -First 200 | Where-Object { $_ -eq 0 }).Count -gt 10)) {
            return [text.encoding]::Unicode.GetString($Buffer, 0, $Count).TrimStart([char]65279)
        }
        return [text.encoding]::GetEncoding($CodePage).GetString($Buffer, 0, $Count)
    } finally { $Stream.Dispose() }
}

function Invoke-WindowsTool {
    param([ValidateSet('dism.exe', 'sfc.exe', 'chkdsk.exe')][string]$Name, [string[]]$Arguments, [string]$Label)
    $Prefix = Join-Path $script:RunDirectory ($Label + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $OutPath = $Prefix + '.stdout.log'; $ErrPath = $Prefix + '.stderr.log'
    $ProcessInfo = [diagnostics.processstartinfo]::new()
    $ProcessInfo.FileName = Join-Path ([environment]::SystemDirectory) $Name
    $ProcessInfo.Arguments = ($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' '
    $ProcessInfo.UseShellExecute = $false; $ProcessInfo.CreateNoWindow = $true
    $ProcessInfo.RedirectStandardOutput = $true; $ProcessInfo.RedirectStandardError = $true; $ProcessInfo.RedirectStandardInput = $true
    $NativeProcess = [diagnostics.process]::new(); $NativeProcess.StartInfo = $ProcessInfo
    $OutStream = $null; $ErrStream = $null
    try {
        $OutStream = [io.filestream]::new($OutPath, [io.filemode]::CreateNew, [io.fileaccess]::Write, [io.fileshare]::Read)
        $ErrStream = [io.filestream]::new($ErrPath, [io.filemode]::CreateNew, [io.fileaccess]::Write, [io.fileshare]::Read)
        if (!$NativeProcess.Start()) { throw ('Unable to start {0}' -f $Name) }
        $NativeProcess.StandardInput.Close()
        Write-RunEvent $Label 'NativeStarted' @{ ProcessId = $NativeProcess.Id; Tool = $Name; Arguments = $Arguments; Stdout = $OutPath; Stderr = $ErrPath }
        $OutCopy = $NativeProcess.StandardOutput.BaseStream.CopyToAsync($OutStream)
        $ErrCopy = $NativeProcess.StandardError.BaseStream.CopyToAsync($ErrStream)
        # Servicing/provider work is not killed just to meet an arbitrary timer.
        $NativeProcess.WaitForExit()
        $OutCopy.GetAwaiter().GetResult(); $ErrCopy.GetAwaiter().GetResult()
        $OutStream.Flush($true); $ErrStream.Flush($true)
        $Code = $NativeProcess.ExitCode
    } finally {
        if ($null -ne $OutStream) { $OutStream.Dispose() }
        if ($null -ne $ErrStream) { $ErrStream.Dispose() }
        $NativeProcess.Dispose()
    }
    $Output = Read-NativeText $OutPath
    $ErrorOutput = Read-NativeText $ErrPath
    Write-RunEvent $Label 'NativeCompleted' @{ Tool = $Name; ExitCode = $Code; Stdout = $OutPath; Stderr = $ErrPath }
    if ($Code -eq 3010) { $script:RebootRequired = $true }
    return [pscustomobject]@{ Tool = $Name; ExitCode = $Code; Output = $Output; ErrorOutput = $ErrorOutput; Stdout = $OutPath; Stderr = $ErrPath }
}

function Get-SfcFinding {
    param([string]$Output)
    if ($Output -match 'did not find any integrity violations') { return 'Pass' }
    if ($Output -match 'found corrupt files and successfully repaired') { return 'Warn' }
    if ($Output -match 'found integrity violations|found corrupt files but was unable') { return 'Fail' }
    return 'Unknown'
}

function Invoke-IntegrityCheck {
    $Block = Get-ServicingBlock
    if ($Block) { return (New-Result 'Deferred' 'Unknown' $Block) }
    $Dism = Invoke-WindowsTool 'dism.exe' @('/Online', '/Cleanup-Image', '/ScanHealth', '/English', '/NoRestart',
        ('/LogPath:' + (Join-Path $script:RunDirectory 'dism-scan.log'))) 'DismScan'
    $Sfc = Invoke-WindowsTool 'sfc.exe' @('/VERIFYONLY') 'SfcVerify'
    $Disk = Invoke-WindowsTool 'chkdsk.exe' @($env:SystemDrive) 'ChkdskVerify'
    $ImageFinding = if ($Dism.Output -match 'No component store corruption detected') { 'Pass' }
        elseif ($Dism.Output -match 'component store is repairable|component store cannot be repaired') { 'Fail' } else { 'Unknown' }
    $SfcFinding = Get-SfcFinding $Sfc.Output
    $DiskFinding = if ($Disk.ExitCode -eq 0) { 'Pass' } else { 'Unknown' }
    $State = if ($Dism.ExitCode -notin @(0, 3010) -or $Sfc.ExitCode -ne 0 -or $Disk.ExitCode -notin @(0, 1, 2, 3)) { 'Failed' } else { 'Completed' }
    $Finding = if ('Fail' -in @($ImageFinding, $SfcFinding)) { 'Fail' }
        elseif ('Unknown' -in @($ImageFinding, $SfcFinding, $DiskFinding)) { 'Unknown' } else { 'Pass' }
    return (New-Result $State $Finding ('Integrity: component store {0}; system files {1}; filesystem {2}. Active-volume CHKDSK findings may be inconclusive.' -f
        $ImageFinding, $SfcFinding, $DiskFinding) @{ DISM = $Dism; SFC = $Sfc; CHKDSK = $Disk })
}

function Invoke-WindowsRepair {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param([string]$Source)
    $Block = Get-UserActivityBlock
    if (!$Block) { $Block = Get-ServicingBlock }
    if ($Block) { return (New-Result 'Deferred' 'Unknown' $Block) }
    if (!$PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'DISM RestoreHealth with LimitAccess, then SFC scannow')) {
        return (New-Result 'Planned' 'NotApplicable' 'Windows repair preview; no repairs performed')
    }
    $Arguments = @('/Online', '/Cleanup-Image', '/RestoreHealth', '/LimitAccess', '/NoRestart', '/English',
        ('/LogPath:' + (Join-Path $script:RunDirectory 'dism-repair.log')))
    if ($Source) { $Arguments += '/Source:' + $Source }
    $Dism = Invoke-WindowsTool 'dism.exe' $Arguments 'DismRepair'
    if ($Dism.ExitCode -notin @(0, 3010)) { return (New-Result 'Failed' 'Unknown' 'DISM repair failed; SFC repair was not started. A matching repair source may be needed.' $Dism) }
    if ($Dism.ExitCode -eq 3010) { return (New-Result 'Deferred' 'Warn' 'DISM requires a restart; SFC repair was deferred' $Dism) }
    $Sfc = Invoke-WindowsTool 'sfc.exe' @('/SCANNOW') 'SfcRepair'
    $Finding = Get-SfcFinding $Sfc.Output
    $State = if ($Sfc.ExitCode -eq 0) { 'Completed' } else { 'Failed' }
    return (New-Result $State $Finding ('Windows repair completed; SFC finding: {0}. See native logs.' -f $Finding) @{ DISM = $Dism; SFC = $Sfc })
}

function Invoke-ComponentCleanup {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param()
    $Block = Get-UserActivityBlock
    if (!$Block) { $Block = Get-ServicingBlock }
    if ($Block) { return (New-Result 'Deferred' 'NotApplicable' $Block) }
    if (!$PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'DISM StartComponentCleanup without ResetBase')) {
        return (New-Result 'Planned' 'NotApplicable' 'Component cleanup preview; no cleanup performed')
    }
    $Dism = Invoke-WindowsTool 'dism.exe' @('/Online', '/Cleanup-Image', '/StartComponentCleanup', '/NoRestart', '/English',
        ('/LogPath:' + (Join-Path $script:RunDirectory 'dism-cleanup.log'))) 'ComponentCleanup'
    $State = if ($Dism.ExitCode -in @(0, 3010)) { 'Completed' } else { 'Failed' }
    return (New-Result $State 'NotApplicable' ('Component cleanup returned {0}' -f $Dism.ExitCode) $Dism)
}

# Selected workstation information, not an unrestricted environment or event dump.
function Get-SystemHealth {
    $Os = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 30
    $Computer = Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 30
    $Bios = Get-CimInstance Win32_BIOS -OperationTimeoutSec 30
    $CpuSamples = [collections.generic.list[double]]::new()
    1..5 | ForEach-Object {
        $Load = @(Get-CimInstance Win32_Processor -OperationTimeoutSec 15 | Select-Object -ExpandProperty LoadPercentage)
        if ($Load.Count -gt 0) { $CpuSamples.Add([double](($Load | Measure-Object -Average).Average)) }
        if ($_ -lt 5) { Start-Sleep -Seconds 1 }
    }
    $MemoryPercent = if ($Os.TotalVisibleMemorySize -gt 0) {
        [math]::Round(100 * (1 - $Os.FreePhysicalMemory / $Os.TotalVisibleMemorySize), 1)
    } else { $null }
    $Cpu = if ($CpuSamples.Count -gt 0) { [math]::Round(($CpuSamples | Measure-Object -Average).Average, 1) } else { $null }
    $Data = [pscustomobject]@{
        ComputerName = $env:COMPUTERNAME; Manufacturer = $Computer.Manufacturer; Model = $Computer.Model
        SerialNumber = $Bios.SerialNumber; Windows = $Os.Caption; Version = $Os.Version; Build = $Os.BuildNumber
        LastBootUtc = $Os.LastBootUpTime.ToUniversalTime(); UptimeDays = [math]::Round(([datetime]::UtcNow - $Os.LastBootUpTime.ToUniversalTime()).TotalDays, 1)
        InstalledRamGiB = [math]::Round($Computer.TotalPhysicalMemory / 1GB, 1)
        MemoryUsedPercent = $MemoryPercent; CpuSamplePercent = $Cpu; Domain = $Computer.Domain; DomainJoined = $Computer.PartOfDomain
    }
    $Finding = if ($null -eq $MemoryPercent -or $null -eq $Cpu) { 'Unknown' }
        elseif ($MemoryPercent -ge 90 -or $Cpu -ge 85) { 'Warn' } else { 'Pass' }
    return (New-Result 'Completed' $Finding ('CPU sample {0}%; RAM used {1}%; uptime {2} days' -f $Cpu, $MemoryPercent, $Data.UptimeDays) $Data)
}

function Get-DiskSpace {
    return @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3' -OperationTimeoutSec 30 | ForEach-Object {
        [pscustomobject]@{
            Drive = $_.DeviceID; FileSystem = $_.FileSystem; SizeBytes = $_.Size; FreeBytes = $_.FreeSpace
            FreeGiB = [math]::Round($_.FreeSpace / 1GB, 2)
            FreePercent = $(if ($_.Size -gt 0) { [math]::Round(100 * $_.FreeSpace / $_.Size, 1) } else { $null })
        }
    })
}

function Get-StorageHealth {
    $Volumes = @(Get-DiskSpace)
    $Physical = @(); $PhysicalError = $null
    try {
        $Physical = @(Get-PhysicalDisk | Select-Object FriendlyName, MediaType, HealthStatus, OperationalStatus)
    } catch { $PhysicalError = $_.Exception.Message }
    $LowSpace = @($Volumes | Where-Object { $_.FreeBytes -lt 20GB -or ($null -ne $_.FreePercent -and $_.FreePercent -lt 15) })
    $Unhealthy = @($Physical | Where-Object { $_.HealthStatus -and $_.HealthStatus -ne 'Healthy' })
    $Finding = if ($LowSpace.Count -gt 0 -or $Unhealthy.Count -gt 0) { 'Warn' }
        elseif ($Physical.Count -eq 0 -or $PhysicalError) { 'Unknown' } else { 'Pass' }
    return (New-Result 'Completed' $Finding ('{0} fixed volumes; {1} low-space volumes; physical disk health is provider-reported, not a full hardware test' -f
        $Volumes.Count, $LowSpace.Count) @{ Volumes = $Volumes; PhysicalDisks = $Physical; PhysicalDiskError = $PhysicalError })
}

function Get-EventHealth {
    $Records = [collections.generic.list[object]]::new()
    foreach ($Log in @('System', 'Application')) {
        try {
            $Events = @(Get-WinEvent -FilterHashtable @{ LogName = $Log; Level = 1, 2; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 50)
            foreach ($Group in @($Events | Group-Object ProviderName, Id)) {
                $Event = $Group.Group[0]
                $Records.Add([pscustomobject]@{ Log = $Log; Provider = $Event.ProviderName; EventId = $Event.Id; CountInSample = $Group.Count; Latest = $Event.TimeCreated.ToUniversalTime() })
            }
        } catch {
            if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { throw }
        }
    }
    $Finding = if ($Records.Count -gt 0) { 'Warn' } else { 'Pass' }
    return (New-Result 'Completed' $Finding 'Recent critical/error events sampled: at most 50 per log over 7 days; messages omitted' $Records.ToArray())
}

function Get-SecurityHealth {
    $Data = [ordered]@{ Defender = $null; Firewall = $null; BitLocker = $null; Unavailable = @() }
    try {
        $Status = Get-MpComputerStatus
        $Data.Defender = $Status | Select-Object AMRunningMode, AntivirusEnabled, RealTimeProtectionEnabled, AntivirusSignatureLastUpdated
    } catch { $Data.Unavailable += 'Defender status unavailable' }
    try { $Data.Firewall = @(Get-NetFirewallProfile | Select-Object Name, Enabled) } catch { $Data.Unavailable += 'Firewall status unavailable' }
    try {
        $Data.BitLocker = @(Get-BitLockerVolume -MountPoint $env:SystemDrive | Select-Object MountPoint, VolumeStatus, ProtectionStatus, EncryptionPercentage)
    } catch { $Data.Unavailable += 'BitLocker status unavailable' }
    $Finding = if (@($Data.Firewall | Where-Object { !$_.Enabled }).Count -gt 0 -or
        @($Data.BitLocker | Where-Object { $_.ProtectionStatus -eq 'Off' }).Count -gt 0) { 'Warn' } else { 'Unknown' }
    return (New-Result 'Completed' $Finding 'Security status snapshot; Defender passive mode and service presence do not establish SentinelOne health' ([pscustomobject]$Data))
}

function Get-NetworkHealth {
    $Computer = Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 30
    $Adapters = @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = True' -OperationTimeoutSec 30 |
        Select-Object Description, IPAddress, DefaultIPGateway, DNSServerSearchOrder, DNSDomain)
    $Trust = $null; $Dns = $null; $Notes = [collections.generic.list[string]]::new()
    if ($Computer.PartOfDomain) {
        try { $Trust = Test-ComputerSecureChannel } catch { $Notes.Add('Secure-channel test unavailable; offline/VPN state may apply') }
        try {
            $Answers = @(Resolve-DnsName -Name ('_ldap._tcp.dc._msdcs.' + $Computer.Domain) -Type SRV -DnsOnly -QuickTimeout)
            $Dns = ($Answers.Count -gt 0)
        } catch { $Notes.Add('Domain DNS lookup unavailable; offline/VPN state may apply') }
    } else { $Notes.Add('Workgroup computer: domain tests not applicable') }
    $Finding = if ($Trust -eq $false -or $Dns -eq $false -or $Adapters.Count -eq 0) { 'Warn' }
        elseif ($Computer.PartOfDomain -and $Trust -eq $true -and $Dns -eq $true) { 'Pass' } else { 'Unknown' }
    return (New-Result 'Completed' $Finding 'Network/domain snapshot; no repair or public Internet test' @{ Adapters = $Adapters; SecureChannel = $Trust; DomainDns = $Dns; Notes = $Notes.ToArray() })
}

function Get-InstalledProgram {
    $Programs = [collections.generic.list[object]]::new()
    foreach ($Path in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (!(Test-Path -LiteralPath $Path)) { continue }
        foreach ($Key in @(Get-ChildItem -LiteralPath $Path)) {
            $Program = Get-ItemProperty -LiteralPath $Key.PSPath
            if (!(Get-Value $Program 'DisplayName') -or (Get-Value $Program 'SystemComponent' 0) -eq 1) { continue }
            $Programs.Add([pscustomobject]@{ Name = $Program.DisplayName; Version = Get-Value $Program 'DisplayVersion'; Publisher = Get-Value $Program 'Publisher' })
        }
    }
    return (New-Result 'Completed' 'NotApplicable' ('{0} system-wide uninstall registry entries; not a complete per-user application inventory' -f $Programs.Count) @($Programs | Sort-Object Name))
}

function Get-DeviceHealth {
    $Devices = @(Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' -OperationTimeoutSec 30 |
        Select-Object Name, PNPClass, ConfigManagerErrorCode, Status)
    $Finding = if ($Devices.Count -gt 0) { 'Warn' } else { 'Pass' }
    return (New-Result 'Completed' $Finding ('{0} device error records; absent-device codes may be informational' -f $Devices.Count) $Devices)
}

function Get-LocalUpdateHistory {
    $Session = $null; $Searcher = $null; $History = $null
    $Items = [collections.generic.list[object]]::new()
    try {
        $Session = New-Object -ComObject 'Microsoft.Update.Session'
        $Searcher = $Session.CreateUpdateSearcher()
        $Count = [math]::Min(20, $Searcher.GetTotalHistoryCount())
        if ($Count -gt 0) {
            # QueryHistory reads existing history. Never call Search, Download, or Install.
            $History = $Searcher.QueryHistory(0, $Count)
            foreach ($Item in $History) {
                try {
                    $Items.Add([pscustomobject]@{ Date = $Item.Date; Title = $Item.Title; ResultCode = [int]$Item.ResultCode; HResult = $Item.HResult })
                } finally { if ([runtime.interopservices.marshal]::IsComObject($Item)) { $null = [runtime.interopservices.marshal]::ReleaseComObject($Item) } }
            }
        }
        $Finding = if (@($Items | Where-Object ResultCode -in @(3, 4, 5)).Count -gt 0) { 'Warn' } else { 'NotApplicable' }
        return (New-Result 'Completed' $Finding 'Last 20 existing Windows Update history entries; no update scan or installation, not patch compliance' $Items.ToArray())
    } catch {
        return (New-Result 'Skipped' 'Unknown' ('Local update history unavailable: {0}' -f $_.Exception.Message))
    } finally {
        foreach ($Com in @($History, $Searcher, $Session)) {
            if ($null -ne $Com -and [runtime.interopservices.marshal]::IsComObject($Com)) { $null = [runtime.interopservices.marshal]::ReleaseComObject($Com) }
        }
    }
}

function Get-CrashDumpInventory {
    param($Inventory)
    $Control = $null
    try { $Control = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' }
    catch [management.automation.itemnotfoundexception] { }
    # Initialize both defaults before independently applying registry overrides.
    $MemoryPath = [environment]::ExpandEnvironmentVariables([string](Get-Value $Control 'DumpFile' (Join-Path $env:SystemRoot 'MEMORY.DMP')))
    $MiniPath = [environment]::ExpandEnvironmentVariables([string](Get-Value $Control 'MinidumpDir' (Join-Path $env:SystemRoot 'Minidump')))
    $Roots = @($MiniPath)
    if ($null -ne $Inventory) {
        $Roots += @($Inventory.Profiles | ForEach-Object { Join-Path $_.Path 'AppData\Local\CrashDumps' })
    }
    $Locations = [collections.generic.list[object]]::new()
    $Errors = [collections.generic.list[string]]::new()
    try {
        $null = Assert-PlainPath $MemoryPath
        if ([io.file]::Exists($MemoryPath)) {
            $File = Get-Item -LiteralPath $MemoryPath
            $Locations.Add([pscustomobject]@{ Location = $MemoryPath; Count = 1; LogicalBytes = $File.Length; LatestUtc = $File.LastWriteTimeUtc })
        }
    } catch { $Errors.Add('Kernel dump metadata unavailable') }
    foreach ($Root in @($Roots | Sort-Object -Unique)) {
        try {
            $null = Assert-PlainPath $Root
            if (![io.directory]::Exists($Root)) { continue }
            $Files = @(Get-ChildItem -LiteralPath $Root -Filter '*.dmp' -File -Force |
                Where-Object { ($_.Attributes -band [io.fileattributes]::ReparsePoint) -eq 0 })
            if ($Files.Count -gt 0) {
                $Locations.Add([pscustomobject]@{ Location = $Root; Count = $Files.Count
                    LogicalBytes = ($Files | Measure-Object Length -Sum).Sum
                    LatestUtc = ($Files | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).LastWriteTimeUtc })
            }
        } catch { $Errors.Add(('Dump metadata unavailable for {0}' -f $Root)) }
    }
    $Finding = if ($Locations.Count -gt 0) { 'Warn' } elseif ($Errors.Count -gt 0) { 'Unknown' } else { 'NotApplicable' }
    $Data = @{ Locations = $Locations.ToArray(); Unavailable = $Errors.ToArray() }
    return (New-Result 'Completed' $Finding ('{0} dump locations found; dump contents and WER reports preserved' -f $Locations.Count) $Data)
}

function Get-RunExitCode {
    param([object[]]$Tasks)
    if (@($Tasks | Where-Object State -eq 'Failed').Count -gt 0) { return 1 }
    if (@($Tasks | Where-Object State -eq 'Deferred').Count -gt 0) { return 10 }
    return 0
}

function Save-RunReport {
    param($Report)
    $Utf8 = [text.utf8encoding]::new($false)
    $Rows = @($Report.Profiles | ForEach-Object {
        [pscustomobject][ordered]@{
            SID = $_.SID; Account = $_.Account; Path = $_.Path; Loaded = $_.Loaded; Special = $_.Special
            LastActivityUtc = $_.Age.LastActivityUtc; AgeDays = $_.Age.AgeDays; AgeSource = $_.Age.AgeSource
            RegistryLoadUtc = $_.Age.RegistryLoadUtc; RegistryUnloadUtc = $_.Age.RegistryUnloadUtc; CimLastUseUtc = $_.Age.CimLastUseUtc
            LogicalSizeBytes = $(if ($_.Size) { $_.Size.LogicalBytes } else { $null })
            SizeComplete = $(if ($_.Size) { $_.Size.Complete } else { $false })
            Eligible = $_.Eligible; SkipReasons = $_.SkipReasons -join '; '; Action = $_.Action; Verification = $_.Verification
        }
    })
    $Csv = if ($Rows.Count -gt 0) { ($Rows | ConvertTo-Csv -NoTypeInformation) -join [environment]::NewLine }
        else { '"SID","Account","Path","Loaded","Special","LastActivityUtc","AgeDays","AgeSource","RegistryLoadUtc","RegistryUnloadUtc","CimLastUseUtc","LogicalSizeBytes","SizeComplete","Eligible","SkipReasons","Action","Verification"' }
    [io.file]::WriteAllText((Join-Path $script:RunDirectory 'profiles.csv'), $Csv, $Utf8)
    $Lines = [collections.generic.list[string]]::new()
    $Lines.Add(('PSWinVitals {0} | {1} | {2}' -f $script:Version, $Report.Computer, $Report.RunId))
    $Lines.Add(('Mode: {0} | Operations: {1} | Exit: {2}' -f $Report.Mode, ($Report.Operations -join ', '), $Report.ExitCode))
    foreach ($Task in $Report.Tasks) { $Lines.Add(('[{0}/{1}] {2}: {3}' -f $Task.State, $Task.Finding, $Task.Name, $Task.Summary)) }
    $Eligible = @($Rows | Where-Object Eligible)
    $Estimated = 0L
    if ($Eligible.Count -gt 0) { $Estimated = ($Eligible | Measure-Object LogicalSizeBytes -Sum).Sum }
    $Lines.Add(('Profiles: {0} inventoried; {1} eligible at >{2} days; eligible logical size estimate {3:N2} GiB' -f
        $Rows.Count, $Eligible.Count, $Report.ProfileAgeDays, ($Estimated / 1GB)))
    if ($Rows.Count -gt 0) {
        $Lines.Add('Largest 10 profiles (all profiles are included in profiles.csv):')
        foreach ($Row in @($Rows | Sort-Object LogicalSizeBytes -Descending | Select-Object -First 10)) {
            $Size = if ($null -ne $Row.LogicalSizeBytes) { '{0:N2} GiB' -f ($Row.LogicalSizeBytes / 1GB) } else { 'size not collected' }
            $Lines.Add(('  {0}: {1}; age {2} days; {3}; {4}' -f $Row.Path, $Size, $Row.AgeDays, $Row.Action, $Row.SkipReasons))
        }
    }
    foreach ($Disk in $Report.DiskAfter) {
        $Before = @($Report.DiskBefore | Where-Object Drive -eq $Disk.Drive)
        $Change = if ($Before.Count -eq 1) { [math]::Round(($Disk.FreeBytes - $Before[0].FreeBytes) / 1GB, 2) } else { $null }
        $Lines.Add(('Disk {0}: {1} GiB free; observed free-space change {2} GiB (includes concurrent activity)' -f $Disk.Drive, $Disk.FreeGiB, $Change))
    }
    $Lines.Add(('Reboot indicator: {0}; no restart initiated' -f $Report.RebootRequired))
    $Lines.Add(('Reports: {0}' -f $script:RunDirectory))
    $Summary = $Lines -join [environment]::NewLine
    [io.file]::WriteAllText((Join-Path $script:RunDirectory 'summary.txt'), $Summary, $Utf8)
    $Temp = Join-Path $script:RunDirectory 'result.json.tmp'
    [io.file]::WriteAllText($Temp, ($Report | ConvertTo-Json -Depth 16), $Utf8)
    [io.file]::Move($Temp, (Join-Path $script:RunDirectory 'result.json'))
    Write-Output $Summary
}

function Remove-ExpiredLog {
    param([string]$RunsRoot)
    $Completed = @(Get-ChildItem -LiteralPath $RunsRoot -Directory | Where-Object {
        $_.FullName -ne $script:RunDirectory -and ($_.Attributes -band [io.fileattributes]::ReparsePoint) -eq 0 -and
        (Test-Path -LiteralPath (Join-Path $_.FullName 'result.json'))
    } | Sort-Object LastWriteTimeUtc -Descending)
    [long]$RetainedBytes = 0
    foreach ($Directory in $Completed) {
        $Size = Measure-ProfileDirectory $Directory.FullName
        if (!$Size.Complete) { continue }
        $RetainedBytes += $Size.LogicalBytes
        if ($Directory.LastWriteTimeUtc -lt [datetime]::UtcNow.AddDays(-30) -or $RetainedBytes -gt 200MB) {
            $null = Assert-PlainPath $Directory.FullName
            if (!(Test-PathUnderRoot $Directory.FullName $RunsRoot)) { throw 'Log retention target escaped the runs root.' }
            # Only protected logs owned by this tool, not cleanup targets. Logs remain writable under WhatIf.
            Remove-Item -LiteralPath $Directory.FullName -Recurse -Force -Confirm:$false -WhatIf:$false
        }
    }
}

function Invoke-EndpointRun {
    param([hashtable]$Options, [string]$ScriptPath)
    $script:RebootRequired = $false
    $Operations = @()
    try {
        $Options.ExcludeProfiles = @(Get-ProfileExclusion $Options.ExcludeProfiles)
        $Operations = @(Get-Operation $Options.Clean $Options.TempFiles $Options.RemoveStaleProfiles $Options.ComponentStore $Options.RepairWindows $Options.All)
        if ($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSEdition -ne 'Desktop' -or
            ![environment]::Is64BitOperatingSystem -or ![environment]::Is64BitProcess) {
            throw 'Use native 64-bit Windows PowerShell 5.1 on a Windows 10/11 x64 client.'
        }
        $Os = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 30
        if ($Os.ProductType -ne 1 -or [version]$Os.Version -lt [version]'10.0' -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
            throw 'Only Windows 10/11 x64 workstations are supported. Servers, DCs, and ARM64 are excluded.'
        }
        $Principal = [security.principal.windowsprincipal]::new([security.principal.windowsidentity]::GetCurrent())
        if (!$Principal.IsInRole([security.principal.windowsbuiltinrole]::Administrator)) { throw 'Run as SYSTEM or an elevated administrator.' }
        if ($Options.RepairSource) {
            if ($Operations -notcontains 'RepairWindows') { throw '-RepairSource requires a selected Windows repair operation.' }
            $Options.RepairSource = Assert-PlainPath $Options.RepairSource
            if (![io.directory]::Exists($Options.RepairSource)) { throw 'The local repair-source directory does not exist.' }
        }
        $LogRoot = Initialize-LogRoot
    } catch { Write-Host ('PRECHECK FAILED: {0}' -f $_.Exception.Message); return 2 }

    $Lock = $null; $MarkerOwned = $false; $Marker = Join-Path $LogRoot 'active.json'
    try {
        try { $Lock = [io.file]::Open((Join-Path $LogRoot 'maintenance.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
        catch [io.ioexception] {
            if ((Get-IoErrorCode $_.Exception) -notin @(32, 33)) { throw }
            Write-Host 'BUSY: another maintenance run holds the machine lock.'; return 1618
        }
        $RunId = [guid]::NewGuid().ToString('N')
        $Runs = Join-Path $LogRoot 'Runs'
        $null = Assert-PlainPath $Runs
        $null = [io.directory]::CreateDirectory($Runs)
        $script:RunDirectory = Join-Path $Runs ([datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + $RunId.Substring(0, 8))
        $null = [io.directory]::CreateDirectory($script:RunDirectory)
        $script:EventWriter = [io.streamwriter]::new((Join-Path $script:RunDirectory 'events.jsonl'), $false, [text.utf8encoding]::new($false))
        $script:EventWriter.AutoFlush = $true
        $Interrupted = [io.file]::Exists($Marker)
        $Tasks = [collections.generic.list[object]]::new()
        $Report = [pscustomobject][ordered]@{
            SchemaVersion = 1; ScriptVersion = $script:Version; ScriptSha256 = (Get-FileHash -LiteralPath $ScriptPath -Algorithm SHA256).Hash
            RunId = $RunId; Computer = $env:COMPUTERNAME; IdentitySid = [security.principal.windowsidentity]::GetCurrent().User.Value
            StartedUtc = [datetime]::UtcNow.ToString('o'); EndedUtc = $null
            Mode = $(if ($Options.Clean) { if ($WhatIfPreference) { 'Clean preview' } else { 'Clean' } } else { 'Audit' })
            Operations = $Operations; ProfileAgeDays = $Options.ProfileAgeDays; TempAgeDays = $Options.TempAgeDays
            ExcludeProfiles = $Options.ExcludeProfiles; Tasks = @(); Profiles = @(); OrphanDirectories = @()
            CheckIntegrity = $Options.CheckIntegrity; SkipProfileSizes = $Options.SkipProfileSizes; RepairSource = $Options.RepairSource
            DiskBefore = @(); DiskAfter = @(); RebootRequired = $false; ExitCode = 1
        }
        Write-RunEvent 'Run' 'Started' @{ RunId = $RunId; Mode = $Report.Mode; Operations = $Operations; PreviousInterruptedRun = $Interrupted }
        if ($Options.Clean -and !$WhatIfPreference -and !$Interrupted) {
            [io.file]::WriteAllText($Marker, (@{ RunId = $RunId; ProcessId = $PID; Directory = $script:RunDirectory } | ConvertTo-Json))
            $MarkerOwned = $true
        }
        $Inventory = $null
        try {
            $Report.DiskBefore = @(Get-DiskSpace)
            $Tasks.Add((Invoke-LoggedTask 'System' { Get-SystemHealth }))
            $Tasks.Add((Invoke-LoggedTask 'Storage' { Get-StorageHealth }))
            $Tasks.Add((Invoke-LoggedTask 'PendingReboot' {
                $Pending = Get-PendingReboot
                New-Result 'Completed' $(if ($Pending.Pending) { 'Warn' } else { 'Pass' }) ($Pending.Reasons -join '; ') $Pending
            }))
            $Tasks.Add((Invoke-LoggedTask 'Devices' { Get-DeviceHealth }))
            $Tasks.Add((Invoke-LoggedTask 'Events' { Get-EventHealth }))
            $Tasks.Add((Invoke-LoggedTask 'Security' { Get-SecurityHealth }))
            $Tasks.Add((Invoke-LoggedTask 'Network' { Get-NetworkHealth }))
            $Tasks.Add((Invoke-LoggedTask 'Programs' { Get-InstalledProgram }))
            $Tasks.Add((Invoke-LoggedTask 'UpdateHistory' { Get-LocalUpdateHistory }))
            $ProfileTask = Invoke-LoggedTask 'Profiles' {
                $Info = Get-ProfileInventory $Options.ProfileAgeDays $Options.ExcludeProfiles $Options.SkipProfileSizes ($Operations -contains 'StaleProfiles')
                $Count = @($Info.Profiles | Where-Object Eligible).Count
                $Unknown = @($Info.Profiles | Where-Object { !$_.Special -and $_.Age.AgeUnknownReason }).Count
                $Finding = if ($Count) { 'Warn' } elseif ($Unknown) { 'Unknown' } else { 'NotApplicable' }
                New-Result 'Completed' $Finding ('{0} profiles; {1} eligible for complete removal at >{2} days; {3} with unknown age' -f
                    @($Info.Profiles).Count, $Count, $Options.ProfileAgeDays, $Unknown) $Info
            }
            $Tasks.Add($ProfileTask)
            if ($ProfileTask.State -eq 'Completed') {
                $Inventory = $ProfileTask.Data; $Report.Profiles = @($Inventory.Profiles); $Report.OrphanDirectories = @($Inventory.OrphanDirectories)
            }
            $Tasks.Add((Invoke-LoggedTask 'CrashDumps' { Get-CrashDumpInventory $Inventory }))
            if ($Options.CheckIntegrity) { $Tasks.Add((Invoke-LoggedTask 'Integrity' { Invoke-IntegrityCheck })) }
            if ($Interrupted -and $Options.Clean) {
                $Tasks.Add([pscustomobject]@{ Name = 'Maintenance'; State = 'Deferred'; Finding = 'Unknown'
                    Summary = ('A previous run was interrupted. Review {0} and its referenced logs before removing that marker and rerunning.' -f $Marker); Data = $null })
            } else {
                if ($Operations -contains 'TempFiles') {
                    $Tasks.Add((Invoke-LoggedTask 'TempFiles' {
                        Invoke-TempCleanup $Inventory $Options.TempAgeDays $Options.ExcludeProfiles
                    }))
                }
                if ($Operations -contains 'StaleProfiles') {
                    $Tasks.Add((Invoke-LoggedTask 'StaleProfiles' {
                        if ($null -eq $Inventory) { throw 'Profile inventory failed; removal was not started.' }
                        Remove-OldProfile $Inventory $Options.ProfileAgeDays $Options.ExcludeProfiles
                    }))
                }
                if ($Operations -contains 'RepairWindows') { $Tasks.Add((Invoke-LoggedTask 'RepairWindows' { Invoke-WindowsRepair $Options.RepairSource })) }
                if ($Operations -contains 'ComponentStore') { $Tasks.Add((Invoke-LoggedTask 'ComponentStore' { Invoke-ComponentCleanup })) }
            }
            $Report.DiskAfter = @(Get-DiskSpace)
            $PendingAfter = Get-PendingReboot
            $Report.RebootRequired = ($script:RebootRequired -or $PendingAfter.Pending)
        } catch {
            $Tasks.Add([pscustomobject]@{ Name = 'Run'; State = 'Failed'; Finding = 'Unknown'; Summary = $_.Exception.Message; Data = $null })
            Write-RunEvent 'Run' 'Failed' $_.Exception.Message
        }
        $Report.Tasks = $Tasks.ToArray()
        $Report.EndedUtc = [datetime]::UtcNow.ToString('o')
        $Report.ExitCode = Get-RunExitCode $Report.Tasks
        Save-RunReport $Report | Write-Host
        Write-RunEvent 'Run' 'Completed' @{ ExitCode = $Report.ExitCode }
        if ($MarkerOwned) { [io.file]::Delete($Marker); $MarkerOwned = $false }
        if (![io.file]::Exists($Marker)) {
            try { Remove-ExpiredLog $Runs } catch { Write-RunEvent 'LogRetention' 'Warning' $_.Exception.Message }
        }
        return $Report.ExitCode
    } catch {
        Write-Host ('RUN FAILED: {0}' -f $_.Exception.Message)
        # Keep active.json if report persistence failed: destructive work must be reconciled.
        return 1
    } finally {
        if ($null -ne $script:EventWriter) { $script:EventWriter.Dispose(); $script:EventWriter = $null }
        if ($null -ne $Lock) { $Lock.Dispose() }
    }
}

# Dot-sourcing defines helpers for tests; it never starts a workstation run.
if ($MyInvocation.InvocationName -ne '.') {
    $Options = @{
        Clean = [bool]$Clean; TempFiles = [bool]$TempFiles; RemoveStaleProfiles = [bool]$RemoveStaleProfiles
        ComponentStore = [bool]$ComponentStore; RepairWindows = [bool]$RepairWindows; All = [bool]$All
        CheckIntegrity = [bool]$CheckIntegrity; ProfileAgeDays = $ProfileAgeDays; TempAgeDays = $TempAgeDays
        ExcludeProfiles = $ExcludeProfiles; RepairSource = $RepairSource; SkipProfileSizes = [bool]$SkipProfileSizes
    }
    $Code = Invoke-EndpointRun $Options $PSCommandPath
    exit $Code
}

<#
The MIT License (MIT)
Copyright (c) Samuel Leslie

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
#>
