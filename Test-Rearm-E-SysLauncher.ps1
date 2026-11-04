#requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'Rearm-E-SysLauncher.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref] $tokens, [ref] $errors)
if ($errors.Count) { throw ($errors.Message -join '; ') }
$functions = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst]
}, $false))
foreach ($definition in $functions) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
$script:checks = 0
function Assert {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:checks++
}
function Assert-Throws {
    param([scriptblock] $Action, [string] $Message)
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    Assert $failed $Message
}
function Assert-Bytes {
    param([byte[]] $Actual, [byte[]] $Expected, [string] $Message)
    Assert ([Convert]::ToBase64String($Actual) -eq [Convert]::ToBase64String($Expected)) $Message
}
$fixture = Join-Path $PSScriptRoot ('Rearm-Test-' + [guid]::NewGuid().ToString('N'))
$environmentNames = @('USERPROFILE', 'LOCALAPPDATA', 'APPDATA', 'ProgramData', 'TEMP',
    'CommonProgramFiles', 'CommonProgramFiles(x86)', 'ProgramFiles', 'ProgramFiles(x86)',
    'REARM_TEST_ESYS', 'REARM_TEST_LAUNCHER', 'REARM_TEST_WINDOWS', 'REARM_TEST_RUNNING')
$savedEnvironment = @{}
foreach ($name in $environmentNames) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }
try {
    [void] [IO.Directory]::CreateDirectory($fixture)
    Assert-Throws { Get-SafePath 'C:\' } 'drive root rejected'
    Assert-Throws { Get-SafePath '\\server\share\' } 'share root rejected'
    Assert-Throws { Get-SafePath 'relative\path' } 'relative path rejected'
    Assert-Throws { Get-SafePath '%REARM_NONEXISTENT_VARIABLE%\path' } 'unexpanded variable rejected'
    Assert (Test-PathWithin 'C:\example\child' 'C:\example') 'child recognized'
    Assert (-not (Test-PathWithin 'C:\example-other' 'C:\example')) 'prefix collision rejected'

    $latin = [Text.Encoding]::GetEncoding(28591)
    $accent = [char] 0xe9
    $text = "# keep caf$accent`r`nPath.EST=C:\token.est`r`nOther=one`npath.est : two\`n  continuation`nKeep=three"
    $expected = "# keep caf$accent`r`nOther=one`nKeep=three"
    Assert-Bytes (Get-PropertiesWithoutToken $latin.GetBytes($text)) $latin.GetBytes($expected) 'Latin-1 and mixed newlines preserved'
    $text = "Other=value\`nPath.EST=part-of-value`nPath.EST=remove`n"
    Assert-Bytes (Get-PropertiesWithoutToken $latin.GetBytes($text)) $latin.GetBytes("Other=value\`nPath.EST=part-of-value`n") 'retained property continuation preserved'
    foreach ($encoding in @([Text.UTF8Encoding]::new($true),
                            [Text.UnicodeEncoding]::new($false, $true),
                            [Text.UnicodeEncoding]::new($true, $true))) {
        [byte[]] $inputBytes = @($encoding.GetPreamble()) + @($encoding.GetBytes("Keep=one`r`nPath.EST=remove`r`n"))
        [byte[]] $expectedBytes = @($encoding.GetPreamble()) + @($encoding.GetBytes("Keep=one`r`n"))
        Assert-Bytes (Get-PropertiesWithoutToken $inputBytes) $expectedBytes 'Unicode encoding/BOM preserved'
    }
    Assert-Bytes (Get-PropertiesWithoutToken ([byte[]]@())) ([byte[]]@()) 'empty properties unchanged'
    Assert-Throws { Get-PropertiesWithoutToken ([byte[]]@(255,254,0,0)) } 'UTF-32 rejected explicitly'
    Assert-Throws {
        Select-Installation @(
            [pscustomobject]@{Name='E-Sys 1';Version='1.0';Path='C:\one'},
            [pscustomobject]@{Name='E-Sys 2';Version='2.0';Path='C:\two'}
        ) '^E-Sys' '' 'E-Sys'
    } 'ambiguous installations rejected'
    Assert ([version]'2.8.1.155' -gt [version]'2.8.0') 'four-component comparison'

    $file = Join-Path $fixture 'timestamps.txt'
    [IO.File]::WriteAllText($file, 'unchanged')
    $created = [datetime]::new(2011,1,1,3,0,0,[DateTimeKind]::Utc)
    Set-ItemTimes $file $created $created.AddSeconds(1) $created.AddSeconds(2)
    $item = Get-Item -LiteralPath $file
    Assert ($item.CreationTimeUtc -eq $created) 'creation timestamp set'
    Assert ($item.LastWriteTimeUtc -eq $created.AddSeconds(1)) 'modified timestamp set'
    Assert ($item.LastAccessTimeUtc -eq $created.AddSeconds(2)) 'accessed timestamp set'
    Assert ([IO.File]::ReadAllText($file) -eq 'unchanged') 'timestamp operation preserves contents'

    $junction = Join-Path $fixture 'junction'
    $junctionTarget = Join-Path $fixture 'junction-target'
    [void] [IO.Directory]::CreateDirectory($junctionTarget)
    [void] (New-Item -ItemType Junction -Path $junction -Target $junctionTarget)
    Assert-Throws { Get-SafePath (Join-Path $junction 'child') } 'junction ancestor rejected'
    Assert-Throws { @(Get-Tree $fixture) } 'junction inside tree rejected'
    [IO.Directory]::Delete($junction)

    # Run the actual orchestration against a sandbox fixture. Only registry/shell/
    # process discovery and the elevation predicate are replaced; never live targets.
    $source = [IO.File]::ReadAllText($scriptPath)
    $discovery = $functions | Where-Object Name -eq 'Get-InstalledApps'
    $stub = @'
function Get-InstalledApps {
    [pscustomobject]@{Name='E-Sys 3.30.0';Version='3.30.0';Path=$env:REARM_TEST_ESYS}
    [pscustomobject]@{Name='E-Sys Launcher Premium';Version='2.8.2';Path=$env:REARM_TEST_LAUNCHER}
}
function Get-ItemProperty {
    param([string] $Path)
    [pscustomobject]@{
        Cache=(Join-Path $env:USERPROFILE 'Cache')
        Cookies=(Join-Path $env:USERPROFILE 'Cookies')
        History=(Join-Path $env:USERPROFILE 'History')
        Personal=(Join-Path $env:USERPROFILE 'Documents')
    }
}
function Get-CimInstance {
    param([string] $ClassName)
    if ($env:REARM_TEST_RUNNING -eq '1') {
        [pscustomobject]@{Name='E-Sys.exe';ExecutablePath=$null;CommandLine=$null;ProcessId=12345}
    }
    elseif ($env:REARM_TEST_RUNNING -eq 'launcher') {
        [pscustomobject]@{Name='ESysLauncherPRO.exe';ExecutablePath=$null;CommandLine=$null;ProcessId=12346}
    }
}
'@
    $source = $source.Remove($discovery.Extent.StartOffset,
        $discovery.Extent.EndOffset - $discovery.Extent.StartOffset).Insert($discovery.Extent.StartOffset, $stub)
    $predicate = '$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)'
    Assert ($source.Contains($predicate)) 'fixture elevation seam found'
    $source = $source.Replace($predicate, '$true')
    # The legacy fixed token path must also be redirected into the fixture.
    Assert ($source.Contains("'C:\Data\FreeToken.est'")) 'fixture token path seam found'
    $source = $source.Replace("'C:\Data\FreeToken.est'", "(Join-Path `$env:USERPROFILE 'FreeToken.est')")
    $source = $source.Replace('$env:SystemRoot', '$env:REARM_TEST_WINDOWS')
    $subject = Join-Path $fixture 'TestSubject.ps1'
    [IO.File]::WriteAllText($subject, $source)
    $roots = @{
        USERPROFILE='User'; LOCALAPPDATA='User\Local'; APPDATA='User\Roaming'
        ProgramData='ProgramData'; TEMP='Temp'; REARM_TEST_WINDOWS='Windows'
        CommonProgramFiles='Common'; 'CommonProgramFiles(x86)'='Common32'
        ProgramFiles='ProgramFiles'; 'ProgramFiles(x86)'='ProgramFiles32'
    }
    foreach ($name in $roots.Keys) {
        $path = Join-Path $fixture $roots[$name]
        [void] [IO.Directory]::CreateDirectory($path)
        [Environment]::SetEnvironmentVariable($name, $path)
    }
    $env:REARM_TEST_ESYS = Join-Path $fixture 'E-Sys'
    $env:REARM_TEST_LAUNCHER = Join-Path $fixture 'Launcher'
    foreach ($path in @(
        (Join-Path $env:REARM_TEST_ESYS 'config'),
        (Join-Path $env:REARM_TEST_LAUNCHER 'nested'),
        (Join-Path $env:USERPROFILE 'Esys'),
        (Join-Path $env:USERPROFILE 'Cache'),
        (Join-Path $env:USERPROFILE 'Cookies'),
        (Join-Path $env:USERPROFILE 'History'),
        (Join-Path $env:USERPROFILE 'Documents'),
        (Join-Path $env:LOCALAPPDATA 'Tokenmaster'),
        (Join-Path $env:ProgramData 'IsolatedStorage'),
        (Join-Path $env:ProgramData 'Microsoft\Crypto\RSA\MachineKeys'),
        (Join-Path $env:REARM_TEST_WINDOWS 'System32'),
        (Join-Path $env:REARM_TEST_WINDOWS 'SysWOW64')
    )) { [void] [IO.Directory]::CreateDirectory($path) }
    $config = Join-Path $env:REARM_TEST_ESYS 'config\Esys.properties'
    $configText = "# Keep`r`nPath.EST=C:\test.est`r`nSetting=value`r`n"
    [IO.File]::WriteAllBytes($config, $latin.GetBytes($configText))
    $deleteFile = Join-Path $env:USERPROFILE 'Esys\settings.txt'
    [IO.File]::WriteAllText($deleteFile, 'valuable user data')
    [IO.File]::WriteAllText((Join-Path $env:REARM_TEST_LAUNCHER 'nested\launcher.txt'), 'launcher')
    [IO.File]::WriteAllText((Join-Path $env:TEMP 'remove.dat'), 'temporary data')
    [IO.File]::WriteAllText((Join-Path $env:TEMP 'keep.txt'), 'unrelated')
    $keyRoot = Join-Path $env:ProgramData 'Microsoft\Crypto\RSA\MachineKeys'
    [IO.File]::WriteAllText((Join-Path $keyRoot '4eccd106f69e31c1b12304e5463bb71d_test'), 'target key')
    [IO.File]::WriteAllText((Join-Path $keyRoot 'unrelated_key'), 'keep key')
    $backupRoot = Join-Path $fixture 'Backups'
    $before = (Get-FileHash -LiteralPath $config).Hash
    $beforeTime = (Get-Item -LiteralPath $config).LastWriteTimeUtc
    Assert (-not (Get-Command $subject).Parameters.ContainsKey('Apply')) 'Apply parameter removed'
    $plan = @(& $subject -WhatIf -BackupRoot $backupRoot -WarningAction SilentlyContinue)
    Assert ($plan.Count -gt 0) 'read-only plan returned'
    Assert (-not (Test-Path -LiteralPath $backupRoot)) 'inspection creates no backups'
    Assert ((Get-FileHash -LiteralPath $config).Hash -eq $before) 'inspection preserves config'
    $whatIf = @(& $subject -WhatIf -BackupRoot $backupRoot -WarningAction SilentlyContinue)
    Assert ($whatIf.Count -eq $plan.Count) 'WhatIf returns same plan'
    Assert (-not (Test-Path -LiteralPath $backupRoot)) 'WhatIf creates no backups'
    Assert ((Get-Item -LiteralPath $config).LastWriteTimeUtc -eq $beforeTime) 'WhatIf preserves timestamps'
    Assert (@($plan | Where-Object Path -eq (Join-Path $env:TEMP 'remove.dat')).Count -eq 1) 'batch temp cleanup enabled by default'
    Assert (@($plan | Where-Object Path -eq $env:REARM_TEST_WINDOWS).Count -eq 1) 'batch Windows timestamps enabled by default'
    $legacy = @(& $subject -WhatIf -LauncherVersion '2.5.3' -BackupRoot $backupRoot -WarningAction SilentlyContinue)
    Assert (@($legacy | Where-Object Path -eq (Join-Path $env:TEMP 'keep.txt')).Count -eq 1) 'old Launcher temp timestamp branch'
    Assert (@($legacy | Where-Object Path -eq (Join-Path $env:USERPROFILE 'Documents')).Count -eq 0) 'old Launcher excludes Documents'
    $env:REARM_TEST_RUNNING = '1'
    try {
        Assert-Throws { & $subject -Confirm:$false -BackupRoot $backupRoot } 'running E-Sys blocks implicit execution'
    }
    finally { [Environment]::SetEnvironmentVariable('REARM_TEST_RUNNING', $null) }
    Assert (-not (Test-Path -LiteralPath $backupRoot)) 'process refusal creates no backup'
    $proSubject = Join-Path $fixture 'TestProSubject.ps1'
    [IO.File]::WriteAllText($proSubject, $source.Replace("Name='E-Sys Launcher Premium';Version='2.8.2'",
        "Name='E-Sys Launcher PRO';Version='2.8.1.155'"))
    $result = & $subject
    Assert ($result.Status -eq 'Completed') 'Premium works with no arguments or confirmation prompt'
    Assert (Test-Path -LiteralPath (Join-Path $result.Backup 'completed.txt')) 'completion marker exists'
    Assert (-not (Test-Path -LiteralPath $deleteFile)) 'user configuration removed'
    Assert (-not (Test-Path -LiteralPath (Join-Path $env:TEMP 'remove.dat'))) 'default batch temp cleanup'
    Assert (Test-Path -LiteralPath (Join-Path $env:TEMP 'keep.txt')) 'unrelated temp file preserved'
    Assert (-not (Test-Path -LiteralPath (Join-Path $keyRoot '4eccd106f69e31c1b12304e5463bb71d_test'))) 'target RSA prefix removed'
    Assert (Test-Path -LiteralPath (Join-Path $keyRoot 'unrelated_key')) 'unrelated RSA key preserved'
    Assert-Bytes ([IO.File]::ReadAllBytes($config)) $latin.GetBytes("# Keep`r`nSetting=value`r`n") 'configuration edited end-to-end'
    $manifest = Get-Content -LiteralPath (Join-Path $result.Backup 'manifest.json') -Raw | ConvertFrom-Json
    $userBackup = $manifest.Data | Where-Object Original -eq (Join-Path $env:USERPROFILE 'Esys')
    Assert ([IO.File]::ReadAllText((Join-Path $userBackup.Backup 'settings.txt')) -eq 'valuable user data') 'deleted data backed up'
    $configBackup = $manifest.Data | Where-Object Original -eq $config
    Assert-Bytes ([IO.File]::ReadAllBytes($configBackup.Backup)) $latin.GetBytes($configText) 'original config backed up'
    Assert (@($manifest.Metadata | Where-Object Path -eq $config).Count -eq 1) 'config metadata deduplicated'
    Assert ([datetime]$manifest.ReferenceLocal -eq [datetime]::new(2011,1,1,3,0,0)) 'Premium automatically uses 2.0.4 date'
    $proResult = & $proSubject
    Assert ($proResult.Status -eq 'Completed') 'Pro works with no arguments or confirmation prompt'
    $proManifest = Get-Content -LiteralPath (Join-Path $proResult.Backup 'manifest.json') -Raw | ConvertFrom-Json
    Assert ([datetime]$proManifest.ReferenceLocal -eq [datetime]::new(2020,6,1,3,0,0)) 'Pro automatically uses 2.0.5 date'
    $second = & $subject -BackupRoot $backupRoot -WarningAction SilentlyContinue
    Assert ($second.Status -eq 'Completed') 'repeated execution succeeds'
    Assert ($second.Backup -ne $result.Backup) 'unique backup per run'
    Assert-Throws {
        & $subject -WhatIf -BackupRoot $env:REARM_TEST_ESYS -WarningAction SilentlyContinue
    } 'backup installation overlap rejected'

    Assert-Throws {
        & $subject -Clean -Confirm:$false -BackupRoot $backupRoot
    } 'cleanup requires Launcher to be uninstalled first'
    Assert-Throws {
        & $subject -Clean -WhatIf -IncludeSystemTimestamps -BackupRoot $backupRoot
    } 'cleanup rejects rearm-only switches'
    $cleanSource = $source.Replace(
        "[pscustomobject]@{Name='E-Sys 3.30.0';Version='3.30.0';Path=`$env:REARM_TEST_ESYS}", '').Replace(
        "[pscustomobject]@{Name='E-Sys Launcher Premium';Version='2.8.2';Path=`$env:REARM_TEST_LAUNCHER}", '')
    $cleanSubject = Join-Path $fixture 'TestCleanSubject.ps1'
    [IO.File]::WriteAllText($cleanSubject, $cleanSource)
    $roamingPro = Join-Path $env:APPDATA 'TokenMaster\E-Sys Launcher PRO'
    $programPro = Join-Path $env:ProgramData 'TokenMaster\E-Sys Launcher PRO'
    $otherProduct = Join-Path $env:ProgramData 'TokenMaster\OtherProduct'
    $dotNetConfig = Join-Path $env:LOCALAPPDATA 'TokenMaster\ESysLauncherPRO.exe_StrongName_abc123'
    $otherDotNetConfig = Join-Path $env:LOCALAPPDATA 'TokenMaster\OtherProduct.exe_StrongName_abc123'
    $urlConfig = Join-Path $env:LOCALAPPDATA 'ESysLauncherPremium.exe_Url_xyz789'
    $directPro = Join-Path $env:LOCALAPPDATA 'E-Sys_Launcher_PRO'
    $premium = Join-Path $env:LOCALAPPDATA 'E-Sys Launcher Premium'
    $programFilesPro = Join-Path $env:ProgramFiles 'TokenMaster\E-Sys Launcher PRO'
    $programFilesPro32 = Join-Path ${env:ProgramFiles(x86)} 'TokenMaster\E-Sys Launcher PRO'
    $otherProgram = Join-Path $env:ProgramFiles 'TokenMaster\OtherProduct'
    $startMenuPro = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\E-Sys Launcher PRO'
    $userEsys = Join-Path $env:USERPROFILE 'Esys'
    $isolated = Join-Path $env:ProgramData 'IsolatedStorage'
    foreach ($path in @($roamingPro, $programPro, $otherProduct, $dotNetConfig, $otherDotNetConfig,
        $urlConfig, $directPro, $premium, $programFilesPro, $programFilesPro32,
        $otherProgram, $startMenuPro, $userEsys, $isolated)) {
        [void] [IO.Directory]::CreateDirectory($path)
        [IO.File]::WriteAllText((Join-Path $path 'keep-or-back-up.txt'), $path)
    }
    [IO.File]::WriteAllText((Join-Path $env:USERPROFILE 'FreeToken.est'), 'launcher token')
    [IO.File]::WriteAllText((Join-Path $env:TEMP 'unrelated.dat'), 'unrelated temporary file')
    $targetKey = Join-Path $keyRoot '83aa4cc77f591dfc2374580bbd95f6ba_test'
    [IO.File]::WriteAllText($targetKey, 'launcher key')
    $configBeforeClean = [IO.File]::ReadAllBytes($config)
    $configTimeBeforeClean = (Get-Item -LiteralPath $config).LastWriteTimeUtc
    $windowsTimeBeforeClean = (Get-Item -LiteralPath $env:REARM_TEST_WINDOWS).LastWriteTimeUtc
    $backupCountBeforeClean = @(Get-ChildItem -LiteralPath $backupRoot -Directory).Count
    $cleanPlan = @(& $cleanSubject -Clean -WhatIf -LauncherPath $roamingPro -BackupRoot $backupRoot)
    Assert ($cleanPlan.Count -gt 0) 'cleanup works without installed application registrations'
    Assert (@($cleanPlan | Where-Object Action -ne 'Delete (after backup)').Count -eq 0) 'cleanup plan contains only deletions'
    Assert (@($cleanPlan | Where-Object { Test-PathWithin $roamingPro $_.Path }).Count -eq 1) 'roaming PRO data included exactly once'
    Assert (@($cleanPlan | Where-Object Path -eq $programPro).Count -eq 1) 'ProgramData PRO data included'
    Assert (@($cleanPlan | Where-Object { Test-PathWithin $dotNetConfig $_.Path }).Count -eq 1) '.NET StrongName configuration included'
    Assert (@(Get-ChildItem -LiteralPath $backupRoot -Directory).Count -eq $backupCountBeforeClean) 'cleanup WhatIf creates no backups'
    Assert (Test-Path -LiteralPath $programPro) 'cleanup WhatIf preserves leftovers'
    $proPlan = @(& $cleanSubject -Clean -WhatIf -LauncherEdition Pro -BackupRoot $backupRoot)
    Assert (@($proPlan | Where-Object Path -eq $premium).Count -eq 0) 'edition-specific cleanup preserves Premium folder'
    Assert-Throws {
        & $cleanSubject -Clean -WhatIf -LauncherPath (Join-Path $env:ProgramData 'TokenMaster') -BackupRoot $backupRoot
    } 'custom cleanup path cannot target shared manufacturer container'
    $env:REARM_TEST_RUNNING = 'launcher'
    try {
        Assert-Throws {
            & $cleanSubject -Clean -Confirm:$false -BackupRoot $backupRoot
        } 'running Launcher blocks post-uninstall cleanup'
    }
    finally { [Environment]::SetEnvironmentVariable('REARM_TEST_RUNNING', $null) }
    Assert (@(Get-ChildItem -LiteralPath $backupRoot -Directory).Count -eq $backupCountBeforeClean) 'cleanup process refusal creates no backup'
    $env:REARM_TEST_RUNNING = '1'
    try {
        $cleanResult = & $cleanSubject -Clean -Confirm:$false -LauncherPath $roamingPro -BackupRoot $backupRoot
    }
    finally { [Environment]::SetEnvironmentVariable('REARM_TEST_RUNNING', $null) }
    Assert ($cleanResult.Status -eq 'Completed') 'cleanup succeeds without dates/Pro override while E-Sys runs'
    foreach ($path in @($roamingPro, $programPro, $dotNetConfig, $urlConfig, $directPro,
        $premium, $programFilesPro, $programFilesPro32, $startMenuPro)) {
        Assert (-not (Test-Path -LiteralPath $path)) "Launcher leftover removed: $path"
    }
    Assert (-not (Test-Path -LiteralPath (Join-Path $env:APPDATA 'TokenMaster'))) 'empty manufacturer container removed'
    Assert (Test-Path -LiteralPath (Join-Path $otherProduct 'keep-or-back-up.txt')) 'unrelated TokenMaster data preserved'
    Assert (Test-Path -LiteralPath (Join-Path $otherProgram 'keep-or-back-up.txt')) 'unrelated TokenMaster installation preserved'
    Assert (Test-Path -LiteralPath (Join-Path $otherDotNetConfig 'keep-or-back-up.txt')) 'unrelated .NET configuration preserved'
    Assert (Test-Path -LiteralPath (Join-Path $userEsys 'keep-or-back-up.txt')) 'E-Sys user data preserved'
    Assert (Test-Path -LiteralPath (Join-Path $isolated 'keep-or-back-up.txt')) 'shared isolated storage preserved'
    Assert (Test-Path -LiteralPath (Join-Path $env:TEMP 'unrelated.dat')) 'unrelated temporary data preserved'
    Assert (-not (Test-Path -LiteralPath $targetKey)) 'known Launcher RSA prefix cleaned'
    Assert (Test-Path -LiteralPath (Join-Path $keyRoot 'unrelated_key')) 'unrelated RSA key preserved during cleanup'
    Assert (-not (Test-Path -LiteralPath (Join-Path $env:USERPROFILE 'FreeToken.est'))) 'legacy Launcher token cleaned'
    Assert-Bytes ([IO.File]::ReadAllBytes($config)) $configBeforeClean 'cleanup does not edit E-Sys properties'
    Assert ((Get-Item -LiteralPath $config).LastWriteTimeUtc -eq $configTimeBeforeClean) 'cleanup does not predate E-Sys config'
    Assert ((Get-Item -LiteralPath $env:REARM_TEST_WINDOWS).LastWriteTimeUtc -eq $windowsTimeBeforeClean) 'cleanup does not predate Windows'
    $cleanManifest = Get-Content -LiteralPath (Join-Path $cleanResult.Backup 'manifest.json') -Raw | ConvertFrom-Json
    Assert ($cleanManifest.Mode -eq 'Clean') 'cleanup mode recorded in manifest'
    Assert ($null -eq $cleanManifest.ReferenceLocal) 'cleanup manifest has no reference date'
    Assert (@($cleanManifest.Data | Where-Object Original -eq $config).Count -eq 0) 'cleanup does not back up unrelated E-Sys config'
    $programBackup = $cleanManifest.Data | Where-Object Original -eq $programPro
    Assert ([IO.File]::ReadAllText((Join-Path $programBackup.Backup 'keep-or-back-up.txt')) -eq $programPro) 'removed PRO data backed up'
    $savedEsys = $env:REARM_TEST_ESYS + '-saved'
    Move-Item -LiteralPath $env:REARM_TEST_ESYS -Destination $savedEsys
    try {
        $repeatClean = & $cleanSubject -Clean -Confirm:$false -BackupRoot $backupRoot
        Assert ($repeatClean.Status -eq 'NothingToClean') 'repeated cleanup succeeds even when E-Sys is absent'
        Assert ($null -eq $repeatClean.Backup) 'empty cleanup creates no backup'
    }
    finally { Move-Item -LiteralPath $savedEsys -Destination $env:REARM_TEST_ESYS }
    Write-Host "Passed $script:checks assertions."
}
finally {
    foreach ($name in $environmentNames) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name])
    }
    if (Test-Path -LiteralPath $fixture) {
        $remainingJunction = Join-Path $fixture 'junction'
        if ([IO.Directory]::Exists($remainingJunction)) { [IO.Directory]::Delete($remainingJunction) }
        Remove-Item -LiteralPath $fixture -Recurse -Force
    }
}
