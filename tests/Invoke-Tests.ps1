#Requires -Version 5.1
<#! Dependency-free tests. Files and provider fakes use only a new temporary fixture.
Run in Windows PowerShell 5.1 for the deployment-engine check, or PowerShell 7
for portable logic/filesystem checks. No employee profile or Windows setting is changed.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$Source = Join-Path (Split-Path $PSScriptRoot -Parent) 'Invoke-EndpointMaintenance.ps1'
$Tokens = $null; $ParseErrors = $null
$Ast = [management.automation.language.parser]::ParseFile($Source, [ref]$Tokens, [ref]$ParseErrors)
if ($ParseErrors.Count -gt 0) { throw ($ParseErrors.Message -join [environment]::NewLine) }
. $Source
$script:Passed = 0
$script:Failed = 0
$script:FixtureRoot = Join-Path ([io.path]::GetTempPath()) ('PSWinVitals-tests-' + [guid]::NewGuid().ToString('N'))
$null = [io.directory]::CreateDirectory($script:FixtureRoot)
$script:FakeProvider = @{}
$script:ProviderDeletes = 0

function Assert-True { param([bool]$Condition, [string]$Message = 'Assertion failed'); if (!$Condition) { throw $Message } }
function Assert-Equal { param($Actual, $Expected); if ($Actual -cne $Expected) { throw ('Expected [{0}], got [{1}]' -f $Expected, $Actual) } }
function Assert-Throws { param([scriptblock]$Action); $Thrown = $false; try { & $Action } catch { $Thrown = $true }; Assert-True $Thrown 'Expected an exception' }
function Test-Case {
    param([string]$Name, [scriptblock]$Action)
    try { & $Action; $script:Passed++; Write-Host ('PASS {0}' -f $Name) }
    catch { $script:Failed++; Write-Host ('FAIL {0}: {1}' -f $Name, $_.Exception.Message) }
}
function Invoke-WithStub {
    param([hashtable]$Stubs, [scriptblock]$Action)
    $Saved = @{}
    foreach ($Name in $Stubs.Keys) {
        $Existing = Get-Item -LiteralPath ('Function:' + $Name) -ErrorAction SilentlyContinue
        $Saved[$Name] = if ($Existing) { $Existing.ScriptBlock } else { $null }
        Set-Item -LiteralPath ('Function:script:' + $Name) -Value $Stubs[$Name]
    }
    try { & $Action }
    finally {
        foreach ($Name in $Stubs.Keys) {
            if ($null -ne $Saved[$Name]) { Set-Item -LiteralPath ('Function:script:' + $Name) -Value $Saved[$Name] }
            else { Remove-Item -LiteralPath ('Function:script:' + $Name) }
        }
    }
}
function New-FixtureDirectory {
    $Path = Join-Path $script:FixtureRoot ([guid]::NewGuid().ToString('N'))
    $null = [io.directory]::CreateDirectory($Path)
    return $Path
}
function New-OldFile {
    param([string]$Path, [string]$Text = 'synthetic test data')
    $null = [io.directory]::CreateDirectory([io.path]::GetDirectoryName($Path))
    [io.file]::WriteAllText($Path, $Text)
    [io.file]::SetCreationTimeUtc($Path, [datetime]::UtcNow.AddDays(-30))
    [io.file]::SetLastWriteTimeUtc($Path, [datetime]::UtcNow.AddDays(-30))
}
function New-TimeEvidence {
    param([datetime]$Load, [datetime]$Unload)
    $LoadTime = $Load.ToUniversalTime().ToFileTimeUtc()
    $UnloadTime = $Unload.ToUniversalTime().ToFileTimeUtc()
    return [pscustomobject]@{
        LocalProfileLoadTimeHigh = [int64]($LoadTime -shr 32); LocalProfileLoadTimeLow = $LoadTime -band 4294967295L
        LocalProfileUnLoadTimeHigh = [int64]($UnloadTime -shr 32); LocalProfileUnLoadTimeLow = $UnloadTime -band 4294967295L
    }
}
function New-FakeProfile {
    param([int]$Rid)
    $Path = Join-Path $script:FixtureRoot ('profile-' + $Rid)
    $null = [io.directory]::CreateDirectory($Path)
    $Age = Get-ProfileAge (New-TimeEvidence ([datetime]::UtcNow.AddDays(-250)) ([datetime]::UtcNow.AddDays(-240))) $null
    $Record = [pscustomobject]@{
        SID = 'S-1-5-21-111-222-333-' + $Rid; Account = $null; Path = $Path; RegistryPath = $Path
        RegistryError = $null; Loaded = $false; Special = $false; RefCount = 0; Status = 0
        RoamingConfigured = $false; RedirectedFolders = @(); Age = $Age
        Size = [pscustomobject]@{ LogicalBytes = 0L; Files = 0L; SkippedLinks = 0L; UnsafeLinks = 0L; SkippedCloud = 0L; EncryptedFiles = 0L; Errors = 0L; Complete = $true }
        Eligible = $true; SkipReasons = @(); Action = 'Retained'; Verification = $null
    }
    $Fresh = $Record.PSObject.Copy()
    $script:FakeProvider[$Record.SID] = @{ Record = $Fresh; Deleted = $false; LeavePath = $false }
    return $Record
}
$ProviderStubs = @{
    'Get-UserActivityBlock' = { return $null }
    'Get-CimInstance' = {
        param($ClassName, $Filter, $OperationTimeoutSec)
        if ($Filter -match "SID='([^']+)'") {
            $Sid = $Matches[1]
            if ($script:FakeProvider.ContainsKey($Sid) -and !$script:FakeProvider[$Sid].Deleted) { [pscustomobject]@{ SID = $Sid } }
        }
    }
    'Get-ProfileRecord' = { param($CimProfile); return $script:FakeProvider[$CimProfile.SID].Record }
    'Test-Path' = {
        param($LiteralPath, $ErrorAction)
        if ($LiteralPath -like 'Registry::HKEY_USERS*') { return $false }
        if ($LiteralPath -like 'HKLM:*ProfileList*') {
            $Sid = ($LiteralPath -split '\\')[-1]
            return ($script:FakeProvider.ContainsKey($Sid) -and !$script:FakeProvider[$Sid].Deleted)
        }
        return Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath -ErrorAction Stop
    }
    'Remove-CimInstance' = {
        [CmdletBinding(SupportsShouldProcess = $true)]
        param($InputObject)
        $Entry = $script:FakeProvider[$InputObject.SID]
        Assert-True (Test-PathUnderRoot $Entry.Record.Path $script:FixtureRoot)
        $script:ProviderDeletes++
        if (!$Entry.LeavePath) { [io.directory]::Delete($Entry.Record.Path, $true) }
        $Entry.Deleted = $true
    }
}

try {
    Test-Case 'Parser and PowerShell 5.1-compatible syntax' {
        Assert-Equal $ParseErrors.Count 0
        $Text = [io.file]::ReadAllText($Source)
        Assert-True ($Text -notmatch '\?\?|\?\.|ForEach-Object\s+-Parallel|\[Experimental')
        Assert-True ($Text -match '#Requires -Version 5\.1')
    }
    Test-Case 'Default invocation selects no mutations' { Assert-Equal @(Get-Operation $false $false $false $false $false $false).Count 0 }
    Test-Case 'Clean alone selects only temp cleanup' { Assert-Equal (@(Get-Operation $true $false $false $false $false $false) -join ',') 'TempFiles' }
    Test-Case 'Explicit profile operation replaces standard default' { Assert-Equal (@(Get-Operation $true $false $true $false $false $false) -join ',') 'StaleProfiles' }
    Test-Case 'All selects all four operations without a hidden profile cap' {
        Assert-Equal (@(Get-Operation $true $false $false $false $false $true) -join ',') 'TempFiles,StaleProfiles,RepairWindows,ComponentStore'
        Assert-True ([io.file]::ReadAllText($Source) -notmatch 'MaxProfilesPerRun|DeepClean')
    }
    Test-Case 'Mutation flags without Clean are rejected' { Assert-Throws { Get-Operation $false $true $false $false $false $false } }
    Test-Case 'Exclusions support a single native command-line argument and interactive arrays' {
        Assert-Equal (@(Get-ProfileExclusion @('kiosk, shareduser', 'backup', '', 'kiosk')) -join ',') 'backup,kiosk,shareduser'
    }
    Test-Case 'Wrapped sharing violations retain their native error code' {
        $Inner = [io.ioexception]::new('Synthetic sharing violation', -2147024864)
        Assert-Equal (Get-IoErrorCode ([exception]::new('Wrapper', $Inner))) 32
    }
    Test-Case 'Zero and missing FILETIME values do not become ancient dates' {
        Assert-True ($null -eq (Convert-ProfileFileTime 0 0)); Assert-True ($null -eq (Convert-ProfileFileTime $null 1))
    }
    Test-Case 'Unsigned FILETIME DWORD conversion handles a signed low DWORD' {
        $Expected = ([datetime]'2025-01-02T03:04:05Z').ToUniversalTime(); $Time = $Expected.ToFileTimeUtc()
        $Lo = $Time -band 4294967295L; if ($Lo -ge 2147483648L) { $Lo -= 4294967296L }
        Assert-Equal (Convert-ProfileFileTime ($Time -shr 32) $Lo) $Expected
    }
    Test-Case 'Newest registry timestamp determines age' {
        $Now = [datetime]'2026-10-20T12:00:00Z'
        $Age = Get-ProfileAge (New-TimeEvidence $Now.AddDays(-200) $Now.AddDays(-190)) $null $Now
        Assert-Equal $Age.AgeDays 190
    }
    Test-Case 'Newer CIM activity prevents stale-profile deletion' {
        $Now = [datetime]'2026-10-20T12:00:00Z'
        $Age = Get-ProfileAge (New-TimeEvidence $Now.AddDays(-250) $Now.AddDays(-240)) $Now.AddDays(-2) $Now
        Assert-True (!(Test-ProfileAge ([pscustomobject]@{ Age = $Age }) 180 $Now))
    }
    Test-Case 'Old CIM evidence alone cannot authorize removal' {
        $Age = Get-ProfileAge ([pscustomobject]@{}) ([datetime]::UtcNow.AddYears(-2))
        Assert-True (!(Test-ProfileAge ([pscustomobject]@{ Age = $Age }) 180))
    }
    Test-Case 'An invalid unload time cannot fall back to an old valid load time' {
        $Evidence = New-TimeEvidence ([datetime]::UtcNow.AddDays(-250)) ([datetime]::UtcNow.AddDays(-240))
        $Evidence.LocalProfileUnLoadTimeHigh = 4294967295L
        $Age = Get-ProfileAge $Evidence $null
        Assert-True (!(Test-ProfileAge ([pscustomobject]@{ Age = $Age }) 180))
    }
    Test-Case 'Future activity prevents removal' {
        $Now = [datetime]'2026-10-20T12:00:00Z'
        $Age = Get-ProfileAge (New-TimeEvidence $Now.AddDays(-250) $Now.AddDays(2)) $null $Now
        Assert-True (!(Test-ProfileAge ([pscustomobject]@{ Age = $Age }) 180 $Now))
    }
    Test-Case 'Age boundary uses exact UTC time rather than rounded days' {
        $Now = ([datetime]'2026-10-20T12:00:00Z').ToUniversalTime()
        $Profile = [pscustomobject]@{ Age = [pscustomobject]@{ LastActivityUtc = $Now.AddDays(-180); AgeUnknownReason = $null } }
        Assert-True (!(Test-ProfileAge $Profile 180 $Now))
        $Profile.Age.LastActivityUtc = $Profile.Age.LastActivityUtc.AddSeconds(-1)
        Assert-True (Test-ProfileAge $Profile 180 $Now)
    }
    Test-Case 'Containment rejects adjacent directories with a shared prefix' {
        $Root = Join-Path $script:FixtureRoot 'allowed'
        Assert-True (Test-PathUnderRoot (Join-Path $Root 'file') $Root)
        Assert-True (!(Test-PathUnderRoot ($Root + '-other/file') $Root))
    }
    Test-Case 'WhatIf preserves eligible temp files and content' {
        $Root = New-FixtureDirectory; $Path = Join-Path $Root 'old.tmp'; New-OldFile $Path
        $Before = (Get-FileHash -LiteralPath $Path).Hash
        $Result = Remove-OldTempFile $Root 7 -WhatIf
        Assert-Equal $Result.State 'Planned'; Assert-Equal $Result.Data.Eligible 1
        Assert-True ([io.file]::Exists($Path)); Assert-Equal (Get-FileHash -LiteralPath $Path).Hash $Before
    }
    Test-Case 'Old nested temp files are removed; recent children and root remain' {
        $Root = New-FixtureDirectory; $Old = Join-Path $Root 'nested/old.tmp'; New-OldFile $Old
        $New = Join-Path $Root 'nested/new.tmp'; [io.file]::WriteAllText($New, 'new synthetic data')
        [io.directory]::SetLastWriteTimeUtc((Split-Path $Old), [datetime]::UtcNow.AddDays(-30))
        $Result = Remove-OldTempFile $Root 7
        Assert-Equal $Result.State 'Completed'; Assert-True (![io.file]::Exists($Old)); Assert-True ([io.file]::Exists($New))
        Assert-True ([io.directory]::Exists($Root))
    }
    Test-Case 'A second cleanup is a valid no-op' {
        $Root = New-FixtureDirectory; New-OldFile (Join-Path $Root 'old.tmp')
        $null = Remove-OldTempFile $Root 7
        $Result = Remove-OldTempFile $Root 7
        Assert-Equal $Result.State 'Completed'; Assert-Equal $Result.Data.Removed 0
    }
    Test-Case 'Links to an external tree are not traversed or cleaned' {
        $Root = New-FixtureDirectory; $Outside = New-FixtureDirectory; $OutsideFile = Join-Path $Outside 'retain.tmp'; New-OldFile $OutsideFile
        $Link = Join-Path $Root 'external'
        if ($env:OS -eq 'Windows_NT') { $null = New-Item -ItemType Junction -Path $Link -Target $Outside }
        else { $null = New-Item -ItemType SymbolicLink -Path $Link -Target $Outside }
        Assert-Throws { Assert-PlainPath $Link }
        $Result = Remove-OldTempFile $Root 7
        Assert-True ([io.file]::Exists($OutsideFile)); Assert-Equal $Result.Data.Removed 0; Assert-Equal $Result.Data.SkippedLinks 1
        Assert-Equal (Measure-ProfileDirectory $Root).UnsafeLinks 1
    }
    Test-Case 'Unknown SFC output never becomes a passing result' { Assert-Equal (Get-SfcFinding 'Unrecognized localized output') 'Unknown' }
    Test-Case 'SFC uncorrected corruption is a finding, not a clean bill of health' { Assert-Equal (Get-SfcFinding 'Windows Resource Protection found corrupt files but was unable to fix some of them.') 'Fail' }
    Test-Case 'SFC successful repair is recorded as a warning/finding' { Assert-Equal (Get-SfcFinding 'Windows Resource Protection found corrupt files and successfully repaired them.') 'Warn' }
    Test-Case 'Native argument quoting preserves spaces, quotes, and a trailing backslash' {
        Assert-Equal (ConvertTo-NativeArgument 'C:\source path\') '"C:\source path\\"'
        Assert-Equal (ConvertTo-NativeArgument 'say "x"') '"say \"x\""'
    }
    Test-Case 'UTF16 SFC output is decoded without changing console state' {
        $Path = Join-Path (New-FixtureDirectory) 'sfc.log'; $Text = 'Windows Resource Protection did not find any integrity violations.'
        [io.file]::WriteAllText($Path, $Text, [text.encoding]::Unicode)
        Assert-Equal (Read-NativeText $Path 65001) $Text
    }
    Test-Case 'Exit status distinguishes health findings from execution failures and deferral' {
        Assert-Equal (Get-RunExitCode @([pscustomobject]@{ State = 'Completed'; Finding = 'Fail' })) 0
        Assert-Equal (Get-RunExitCode @([pscustomobject]@{ State = 'Deferred' })) 10
        Assert-Equal (Get-RunExitCode @([pscustomobject]@{ State = 'Deferred' }, [pscustomobject]@{ State = 'Failed' })) 1
    }
    Test-Case 'All eligible profiles are processed, including more than five' {
        $script:FakeProvider = @{}; $script:ProviderDeletes = 0
        $Profiles = @(1001..1008 | ForEach-Object { New-FakeProfile $_ })
        $Inventory = [pscustomobject]@{ Root = $script:FixtureRoot; CurrentSid = 'S-1-5-18'; LocalSids = @(); Profiles = $Profiles }
        Invoke-WithStub $ProviderStubs {
            $Result = Remove-OldProfile $Inventory 180 @()
            Assert-Equal $Result.State 'Completed'; Assert-Equal $script:ProviderDeletes 8
            Assert-Equal @($Profiles | Where-Object Action -eq 'Removed').Count 8
        }
    }
    Test-Case 'Profile WhatIf never invokes deletion' {
        $script:FakeProvider = @{}; $script:ProviderDeletes = 0; $Profile = New-FakeProfile 1101
        $Inventory = [pscustomobject]@{ Root = $script:FixtureRoot; CurrentSid = 'S-1-5-18'; LocalSids = @(); Profiles = @($Profile) }
        Invoke-WithStub $ProviderStubs {
            $Result = Remove-OldProfile $Inventory 180 @() -WhatIf
            Assert-Equal $script:ProviderDeletes 0; Assert-Equal $Profile.Action 'Planned'; Assert-True ([io.directory]::Exists($Profile.Path))
        }
    }
    Test-Case 'A newly loaded profile is retained after the audit' {
        $script:FakeProvider = @{}; $script:ProviderDeletes = 0; $Profile = New-FakeProfile 1201
        $script:FakeProvider[$Profile.SID].Record.Loaded = $true
        $Inventory = [pscustomobject]@{ Root = $script:FixtureRoot; CurrentSid = 'S-1-5-18'; LocalSids = @(); Profiles = @($Profile) }
        Invoke-WithStub $ProviderStubs {
            $Result = Remove-OldProfile $Inventory 180 @()
            Assert-Equal $script:ProviderDeletes 0; Assert-Equal $Profile.Action 'Skipped'
        }
    }
    Test-Case 'New profile activity after the audit prevents removal' {
        $script:FakeProvider = @{}; $script:ProviderDeletes = 0; $Profile = New-FakeProfile 1301
        $Fresh = $script:FakeProvider[$Profile.SID].Record
        $Fresh.Age = Get-ProfileAge (New-TimeEvidence ([datetime]::UtcNow.AddHours(-2)) ([datetime]::UtcNow.AddHours(-1))) $null
        $Inventory = [pscustomobject]@{ Root = $script:FixtureRoot; CurrentSid = 'S-1-5-18'; LocalSids = @(); Profiles = @($Profile) }
        Invoke-WithStub $ProviderStubs { $null = Remove-OldProfile $Inventory 180 @(); Assert-Equal $script:ProviderDeletes 0 }
    }
    Test-Case 'Explicit shared-account exclusions are rechecked before removal' {
        $script:FakeProvider = @{}; $script:ProviderDeletes = 0; $Profile = New-FakeProfile 1401
        $Inventory = [pscustomobject]@{ Root = $script:FixtureRoot; CurrentSid = 'S-1-5-18'; LocalSids = @(); Profiles = @($Profile) }
        Invoke-WithStub $ProviderStubs { $null = Remove-OldProfile $Inventory 180 @($Profile.SID); Assert-Equal $script:ProviderDeletes 0 }
    }
    Test-Case 'Provider leftovers cause failure without a recursive fallback purge' {
        $script:FakeProvider = @{}; $script:ProviderDeletes = 0; $Profile = New-FakeProfile 1501
        $script:FakeProvider[$Profile.SID].LeavePath = $true
        $Inventory = [pscustomobject]@{ Root = $script:FixtureRoot; CurrentSid = 'S-1-5-18'; LocalSids = @(); Profiles = @($Profile) }
        Invoke-WithStub $ProviderStubs {
            $Result = Remove-OldProfile $Inventory 180 @()
            Assert-Equal $Result.State 'Failed'; Assert-Equal $script:ProviderDeletes 1
            Assert-True ([io.directory]::Exists($Profile.Path)); Assert-Equal $Profile.Action 'Failed'
        }
    }
    Test-Case 'Logged-on sessions defer profile deletion rather than force logoff' {
        $script:FakeProvider = @{}; $script:ProviderDeletes = 0; $Profile = New-FakeProfile 1601
        $Inventory = [pscustomobject]@{ Root = $script:FixtureRoot; CurrentSid = 'S-1-5-18'; LocalSids = @(); Profiles = @($Profile) }
        $BusyStubs = $ProviderStubs.Clone(); $BusyStubs['Get-UserActivityBlock'] = { 'A user session exists' }
        Invoke-WithStub $BusyStubs { $Result = Remove-OldProfile $Inventory 180 @(); Assert-Equal $Result.State 'Deferred'; Assert-Equal $script:ProviderDeletes 0 }
    }
    Test-Case 'Servicing WhatIf never invokes DISM or SFC' {
        Invoke-WithStub @{
            'Get-UserActivityBlock' = { return $null }; 'Get-ServicingBlock' = { return $null }
            'Invoke-WindowsTool' = { throw 'Native mutation was reached under WhatIf' }
        } {
            $BeforeName = $env:COMPUTERNAME; $env:COMPUTERNAME = 'TEST-FIXTURE'
            try {
                Assert-Equal (Invoke-WindowsRepair -WhatIf).State 'Planned'
                Assert-Equal (Invoke-ComponentCleanup -WhatIf).State 'Planned'
            } finally { $env:COMPUTERNAME = $BeforeName }
        }
    }
    Test-Case 'Default profile age is 180 days and no unsafe utility is reachable' {
        Assert-Equal $Ast.ParamBlock.Parameters.Where({ $_.Name.VariablePath.UserPath -eq 'ProfileAgeDays' }).DefaultValue.Value 180
        $CommandNames = @($Ast.FindAll({ param($Node) $Node -is [management.automation.language.commandast] }, $true) | ForEach-Object { $_.GetCommandName() })
        foreach ($Name in @('Install-WindowsUpdate', 'Get-WindowsUpdate', 'Update-Help', 'Clear-RecycleBin', 'Invoke-Expression', 'Stop-Process', 'Restart-Computer')) {
            Assert-True ($CommandNames -notcontains $Name) ('Disallowed operation found: ' + $Name)
        }
    }
    Test-Case 'Empty-profile reports serialize and produce all three report files' {
        $script:RunDirectory = New-FixtureDirectory
        $Report = [pscustomobject]@{ Computer = 'TEST'; RunId = 'fixture'; Mode = 'Audit'; Operations = @(); ExitCode = 0; Tasks = @()
            Profiles = @(); ProfileAgeDays = 180; DiskBefore = @(); DiskAfter = @(); RebootRequired = $false }
        $null = Save-RunReport $Report
        foreach ($Name in @('result.json', 'profiles.csv', 'summary.txt')) { Assert-True ([io.file]::Exists((Join-Path $script:RunDirectory $Name))) }
        Assert-Equal (([io.file]::ReadAllText((Join-Path $script:RunDirectory 'result.json')) | ConvertFrom-Json).ExitCode) 0
    }
    Test-Case 'A nonempty profile report preserves eligibility, action, and age evidence' {
        $script:RunDirectory = New-FixtureDirectory; $Profile = New-FakeProfile 1701
        $Profile.Action = 'Removed'; $Profile.Verification = 'Synthetic provider verified'
        $Report = [pscustomobject]@{ Computer = 'TEST'; RunId = 'fixture'; Mode = 'Clean'; Operations = @('StaleProfiles'); ExitCode = 0
            Tasks = @([pscustomobject]@{ Name = 'StaleProfiles'; State = 'Completed'; Finding = 'NotApplicable'; Summary = 'Synthetic deletion verified' })
            Profiles = @($Profile); ProfileAgeDays = 180; DiskBefore = @(); DiskAfter = @(); RebootRequired = $false }
        $null = Save-RunReport $Report
        $Rows = @(Import-Csv -LiteralPath (Join-Path $script:RunDirectory 'profiles.csv'))
        Assert-Equal $Rows.Count 1; Assert-Equal $Rows[0].Action 'Removed'; Assert-Equal $Rows[0].Eligible 'True'
        Assert-True (![string]::IsNullOrEmpty($Rows[0].RegistryUnloadUtc))
    }
    Test-Case 'Pure profile protections reject local, built-in, redirected, and special accounts' {
        $Profile = New-FakeProfile 1801
        Invoke-WithStub @{ 'Test-Path' = $ProviderStubs['Test-Path'] } {
            Assert-True (@(Get-ProfileProtection $Profile $script:FixtureRoot @($Profile.SID) @() 'S-1-5-18') -contains 'Local account retained')
            $Profile.RedirectedFolders = @('Documents')
            Assert-True (@(Get-ProfileProtection $Profile $script:FixtureRoot @() @() 'S-1-5-18') -contains 'Folder-redirection profile requires separate review')
            $Profile.RedirectedFolders = @(); $Profile.Special = $true
            Assert-True (@(Get-ProfileProtection $Profile $script:FixtureRoot @() @() 'S-1-5-18') -contains 'Special/system profile')
        }
    }
    Test-Case 'OneDrive and encrypted-file evidence block full-profile removal' {
        $Profile = New-FakeProfile 1901
        $null = [io.directory]::CreateDirectory((Join-Path $Profile.Path 'OneDrive - Synthetic'))
        Assert-True (@(Get-ProfileInspectionReason $Profile) -contains 'OneDrive directory requires separate review')
        $Profile.Size.EncryptedFiles = 1
        Assert-True (@(Get-ProfileInspectionReason $Profile) -contains 'EFS-encrypted files found')
    }
    if ($env:OS -eq 'Windows_NT') {
        Test-Case 'Windows WTS session enumeration compiles and executes' { $Users = @(Get-InteractiveSession); Assert-True ($Users.Count -ge 0) }
        Test-Case 'Windows file locks prevent deletion without forcing an application closed' {
            $Root = New-FixtureDirectory; $File = Join-Path $Root 'locked.tmp'; New-OldFile $File
            $Handle = [io.file]::Open($File, 'Open', 'ReadWrite', 'None')
            try {
                $Result = Remove-OldTempFile $Root 7
                Assert-True ([io.file]::Exists($File)); Assert-Equal $Result.Data.Removed 0
                Assert-True (($Result.Data.Locked + $Result.Data.Failed) -gt 0)
            } finally { $Handle.Dispose() }
        }
        Test-Case 'Native Windows argument parsing preserves each original value' {
            $Executable = Join-Path (New-FixtureDirectory) 'ArgumentFixture.exe'
            Add-Type -TypeDefinition @'
using System;
using System.Text;
public static class ArgumentFixture {
    public static void Main(string[] args) {
        foreach (string arg in args) Console.WriteLine(Convert.ToBase64String(Encoding.UTF8.GetBytes(arg)));
    }
}
'@ -OutputAssembly $Executable -OutputType ConsoleApplication
            $Values = @('a b', 'C:\source path\', 'say "hello"', '')
            $Info = [diagnostics.processstartinfo]::new()
            $Info.FileName = $Executable; $Info.Arguments = ($Values | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' '
            $Info.UseShellExecute = $false; $Info.RedirectStandardOutput = $true
            $Child = [diagnostics.process]::Start($Info)
            try {
                $Text = $Child.StandardOutput.ReadToEnd(); $Child.WaitForExit()
                $EncodedLines = $Text.Replace("`r", '').Split([char]10)
                for ($Index = 0; $Index -lt $Values.Count; $Index++) {
                    Assert-Equal ([text.encoding]::UTF8.GetString([convert]::FromBase64String($EncodedLines[$Index]))) $Values[$Index]
                }
            } finally { $Child.Dispose() }
        }
    }
    if ($env:OS -eq 'Windows_NT' -and $PSVersionTable.PSEdition -eq 'Desktop') {
        Test-Case 'Windows PowerShell 5.1 audit orchestration writes secured reports and releases its lock' {
            $OriginalProgramData = $env:ProgramData
            $OriginalArchitecture = $env:PROCESSOR_ARCHITECTURE
            $env:ProgramData = New-FixtureDirectory; $env:PROCESSOR_ARCHITECTURE = 'AMD64'
            $FakeInventory = [pscustomobject]@{ Root = $script:FixtureRoot; CurrentSid = 'S-1-5-18'; LocalSids = @(); Profiles = @(); OrphanDirectories = @() }
            $RunStubs = @{
                'Get-CimInstance' = { param($ClassName, $OperationTimeoutSec); [pscustomobject]@{ ProductType = 1; Version = '10.0.26100' } }
                'Get-DiskSpace' = { return @() }
                'Get-SystemHealth' = { New-Result 'Completed' 'Pass' 'Synthetic system health' }
                'Get-StorageHealth' = { New-Result 'Completed' 'Pass' 'Synthetic storage health' }
                'Get-DeviceHealth' = { New-Result 'Completed' 'Pass' 'Synthetic device health' }
                'Get-EventHealth' = { New-Result 'Completed' 'Pass' 'Synthetic event health' }
                'Get-SecurityHealth' = { New-Result 'Completed' 'Unknown' 'Synthetic security health' }
                'Get-NetworkHealth' = { New-Result 'Completed' 'Pass' 'Synthetic network health' }
                'Get-InstalledProgram' = { New-Result 'Completed' 'NotApplicable' 'Synthetic program inventory' }
                'Get-LocalUpdateHistory' = { New-Result 'Completed' 'NotApplicable' 'Synthetic history' }
                'Get-CrashDumpInventory' = { New-Result 'Completed' 'NotApplicable' 'Synthetic dump inventory' }
                'Get-PendingReboot' = { [pscustomobject]@{ Pending = $false; ServicingReboot = $false; Reasons = @() } }
                'Get-ProfileInventory' = { return $FakeInventory }.GetNewClosure()
            }
            try {
                Invoke-WithStub $RunStubs {
                    $Options = @{ Clean = $false; TempFiles = $false; RemoveStaleProfiles = $false; ComponentStore = $false
                        RepairWindows = $false; All = $false; CheckIntegrity = $false; RepairSource = ''; ProfileAgeDays = 180
                        TempAgeDays = 7; ExcludeProfiles = @(); SkipProfileSizes = $true }
                    Assert-Equal (Invoke-EndpointRun $Options $Source) 0
                    Assert-True ([io.file]::Exists((Join-Path $script:RunDirectory 'result.json')))
                    Assert-True (![io.file]::Exists((Join-Path $env:ProgramData 'PSWinVitals\active.json')))
                    $Handle = [io.file]::Open((Join-Path $env:ProgramData 'PSWinVitals\maintenance.lock'), 'Open', 'ReadWrite', 'None')
                    $Handle.Dispose()
                    $Acl = Get-Acl -LiteralPath (Join-Path $env:ProgramData 'PSWinVitals')
                    Assert-True $Acl.AreAccessRulesProtected
                }
            } finally { $env:ProgramData = $OriginalProgramData; $env:PROCESSOR_ARCHITECTURE = $OriginalArchitecture }
        }
    }
} finally {
    # Remove only this test's newly created fixture. Never traverse a fixture link.
    Get-ChildItem -LiteralPath $script:FixtureRoot -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue |
        ForEach-Object { if ($_.PSIsContainer) { [io.directory]::Delete($_.FullName) } else { [io.file]::Delete($_.FullName) } }
    [io.directory]::Delete($script:FixtureRoot, $true)
}
Write-Host ('Tests: {0} passed; {1} failed. Engine: {2} {3}' -f $script:Passed, $script:Failed, $PSVersionTable.PSEdition, $PSVersionTable.PSVersion)
if ($script:Failed -gt 0) { exit 1 }
