#requires -Version 5.1
<#
.SYNOPSIS
Inspects or resets E-Sys Launcher state without external utilities.
.DESCRIPTION
Consolidates the 2.0.4 Premium and 2.0.5 Pro-modified batch workflows.
Defaults to execution: requires elevation, backs up affected data and
timestamps, then performs approved operations. -WhatIf provides a read-only plan.
Use -Clean after uninstalling Launcher to remove its remaining data/files,
without modifying E-Sys configuration or predating anything.
Pro compatibility is not established by the original Premium documentation.
.EXAMPLE
.\Rearm-E-SysLauncher.ps1
.EXAMPLE
.\Rearm-E-SysLauncher.ps1 -WhatIf
.EXAMPLE
.\Rearm-E-SysLauncher.ps1 -ReferenceDate '2020-06-01T03:00:00'
.EXAMPLE
.\Rearm-E-SysLauncher.ps1 -Clean -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [switch] $Clean,
    [ValidateSet('Auto', 'Premium', 'Pro')]
    [string] $LauncherEdition = 'Auto',
    [string] $EsysPath,
    [string] $LauncherPath,
    [version] $LauncherVersion,
    [datetime] $ReferenceDate = [datetime]::new(2011, 1, 1, 3, 0, 0),
    [switch] $IncludeSharedCleanup = $true,
    [switch] $IncludeSystemTimestamps = $true,
    [string] $BackupRoot = (Join-Path $PSScriptRoot 'Rearm-Backups')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-SafePath {
    param([Parameter(Mandatory)][string] $Path)
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ($expanded -match '%[^%]+%' -or -not [IO.Path]::IsPathRooted($expanded)) {
        throw "Path must be absolute with no unresolved environment variables: $Path"
    }
    $full = [IO.Path]::GetFullPath($expanded).TrimEnd('\')
    if ($full -eq [IO.Path]::GetPathRoot($expanded).TrimEnd('\')) {
        throw "Drive/share roots are not permitted: $Path"
    }
    # Check ancestors too: a literal child can otherwise escape through a junction.
    $current = $full
    while ($current -and $current -ne [IO.Path]::GetPathRoot($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Reparse points are not permitted: $current"
            }
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
    return $full
}

function Test-PathWithin {
    param([string] $Path, [string] $Parent)
    return $Path.Equals($Parent, [StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith($Parent.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-InstalledApps {
    $views = @([Microsoft.Win32.RegistryView]::Registry32)
    if ([Environment]::Is64BitOperatingSystem) {
        $views += [Microsoft.Win32.RegistryView]::Registry64
    }
    foreach ($hive in @([Microsoft.Win32.RegistryHive]::LocalMachine,
                        [Microsoft.Win32.RegistryHive]::CurrentUser)) {
        foreach ($view in $views) {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view)
            try {
                $uninstall = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
                if ($null -eq $uninstall) { continue }
                try {
                    foreach ($name in $uninstall.GetSubKeyNames()) {
                        $key = $uninstall.OpenSubKey($name)
                        if ($null -eq $key) { throw "Uninstall registration disappeared: $name" }
                        try {
                            $display = [string] $key.GetValue('DisplayName')
                            if ($display -match '^E-?Sys(?:\s|$)') {
                                [pscustomobject]@{
                                    Name = $display
                                    Version = [string] $key.GetValue('DisplayVersion')
                                    Path = [string] $key.GetValue('InstallLocation')
                                }
                            }
                        }
                        finally { $key.Dispose() }
                    }
                }
                finally { $uninstall.Dispose() }
            }
            finally { $base.Dispose() }
        }
    }
}

function Select-Installation {
    param([object[]] $Apps, [string] $Pattern, [string] $Override, [string] $Label)
    $matches = @($Apps | Where-Object { $_.Name -match $Pattern } |
        Sort-Object Name, Version, Path -Unique)
    if ($Override) {
        $path = Get-SafePath $Override
        $matches = @($matches | Where-Object {
            $_.Path -and (Get-SafePath $_.Path) -eq $path
        })
        if ($matches.Count -gt 1) { throw "Ambiguous $Label registrations at $path." }
        if ($matches.Count -eq 1) { return $matches[0] }
        return [pscustomobject]@{ Name = $Label; Version = ''; Path = $path }
    }
    if ($matches.Count -ne 1) {
        throw "Expected one $Label registration; found $($matches.Count). Specify its path/edition explicitly."
    }
    if (-not $matches[0].Path) {
        throw "$Label has an empty InstallLocation. Specify its installation path explicitly."
    }
    return $matches[0]
}

function Get-Tree {
    param([string] $Path)
    $item = Get-Item -LiteralPath (Get-SafePath $Path) -Force
    $item
    if ($item.PSIsContainer) {
        $queue = [Collections.Generic.Queue[string]]::new()
        $queue.Enqueue($item.FullName)
        while ($queue.Count -gt 0) {
            foreach ($child in Get-ChildItem -LiteralPath $queue.Dequeue() -Force) {
                if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    throw "Reparse point inside target: $($child.FullName)"
                }
                $child
                if ($child.PSIsContainer) { $queue.Enqueue($child.FullName) }
            }
        }
    }
}

function Get-PropertiesWithoutToken {
    param([byte[]] $Bytes)
    # Java .properties is byte-oriented unless an explicit Unicode BOM is present.
    $offset = 0
    $encoding = [Text.Encoding]::GetEncoding(28591)
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 239 -and
        $Bytes[1] -eq 187 -and $Bytes[2] -eq 191) {
        $encoding = [Text.UTF8Encoding]::new($true, $true); $offset = 3
    }
    elseif ($Bytes.Length -ge 4 -and
        (($Bytes[0] -eq 255 -and $Bytes[1] -eq 254 -and $Bytes[2] -eq 0 -and $Bytes[3] -eq 0) -or
         ($Bytes[0] -eq 0 -and $Bytes[1] -eq 0 -and $Bytes[2] -eq 254 -and $Bytes[3] -eq 255))) {
        throw 'UTF-32 properties files are not supported; refusing to corrupt the configuration.'
    }
    elseif ($Bytes.Length -ge 2 -and $Bytes[0] -eq 255 -and $Bytes[1] -eq 254) {
        $encoding = [Text.UnicodeEncoding]::new($false, $true, $true); $offset = 2
    }
    elseif ($Bytes.Length -ge 2 -and $Bytes[0] -eq 254 -and $Bytes[1] -eq 255) {
        $encoding = [Text.UnicodeEncoding]::new($true, $true, $true); $offset = 2
    }
    $text = $encoding.GetString($Bytes, $offset, $Bytes.Length - $offset)
    $lines = [regex]::Matches($text, '[^\r\n]*(?:\r\n|\r|\n|$)')
    $builder = [Text.StringBuilder]::new()
    $skipContinuation = $false
    $keepContinuation = $false
    foreach ($line in $lines) {
        $content = $line.Value.TrimEnd("`r", "`n")
        $slashes = [regex]::Match($content, '\\+$').Length
        $continues = ($slashes % 2) -eq 1
        $remove = $skipContinuation -or (-not $keepContinuation -and
            $content -match '^\s*(?i:Path\.EST)(?:\s*[:=]|\s+|$)')
        if ($remove) {
            $skipContinuation = $continues
            $keepContinuation = $false
        }
        else {
            [void] $builder.Append($line.Value)
            $keepContinuation = $continues
        }
    }
    [byte[]] $result = @($encoding.GetPreamble()) + @($encoding.GetBytes($builder.ToString()))
    return ,$result
}

function Set-ItemTimes {
    param([string] $Path, [datetime] $Created, [datetime] $Modified, [datetime] $Accessed)
    $item = Get-Item -LiteralPath (Get-SafePath $Path) -Force
    $item.CreationTimeUtc = $Created
    $item.LastWriteTimeUtc = $Modified
    $item.LastAccessTimeUtc = $Accessed
    $item.Refresh()
    if ($item.CreationTimeUtc.Ticks -ne $Created.Ticks -or
        $item.LastWriteTimeUtc.Ticks -ne $Modified.Ticks -or
        $item.LastAccessTimeUtc.Ticks -ne $Accessed.Ticks) {
        throw "Timestamp verification failed: $Path"
    }
}

function Get-LauncherCleanupTargets {
    param([string[]] $DataRoots, [string[]] $ProgramRoots, [string] $Edition)
    $editions = if ($Edition -eq 'Auto') { @('PRO', 'Premium') } else { @($Edition) }
    $names = @(
        foreach ($value in $editions) {
            "E-Sys Launcher $value"
            "E-Sys_Launcher_$value"
            "ESysLauncher$value"
        }
    )
    $editionPattern = ($editions | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $configPattern = "^(?:E-?Sys[_ -]?Launcher(?:[_ -]?(?:$editionPattern)))\.exe_(?:StrongName|Url)_[a-z0-9]+$"
    foreach ($root in $DataRoots) {
        $root = Get-SafePath $root
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($child in Get-ChildItem -LiteralPath $root -Force) {
            if ($names -contains $child.Name -or $child.Name -match $configPattern) {
                $child.FullName
            }
        }
    }
    foreach ($root in @($DataRoots) + @($ProgramRoots)) {
        $namespace = Get-SafePath (Join-Path $root 'TokenMaster')
        if (-not (Test-Path -LiteralPath $namespace -PathType Container)) { continue }
        $children = @(Get-ChildItem -LiteralPath $namespace -Force)
        $matched = @($children | Where-Object {
            $names -contains $_.Name -or $_.Name -match $configPattern
        })
        if ($matched.Count -eq $children.Count) {
            # Remove an empty manufacturer container too, but never other products.
            $namespace
        }
        else { foreach ($child in $matched) { $child.FullName } }
    }
    foreach ($root in $ProgramRoots) {
        foreach ($name in $names) {
            $path = Get-SafePath (Join-Path $root $name)
            if (Test-Path -LiteralPath $path) { $path }
        }
    }
}

function Assert-ExecutionReady {
    param([string[]] $InstallationRoots, [switch] $CleanupOnly)
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run execution in an elevated PowerShell session. -WhatIf does not require elevation.'
    }
    $namePattern = if ($CleanupOnly) {
        '^(?:E-?Sys[_ -]?Launcher|Launcher(?:Premium|Pro)?)(?:.*)\.exe$'
    } else {
        '^(?:E-?Sys|E-?Sys.*Launcher|Launcher(?:Premium|Pro)?)(?:[ ._-].*)?\.exe$'
    }
    $running = @(Get-CimInstance Win32_Process | Where-Object {
        $process = $_
        $fromInstallation = @($InstallationRoots | Where-Object {
            ($process.ExecutablePath -and (Test-PathWithin $process.ExecutablePath $_)) -or
            (-not $CleanupOnly -and $process.CommandLine -and $process.Name -match '^javaw?\.exe$' -and
                $process.CommandLine.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0)
        }).Count -gt 0
        $process.Name -match $namePattern -or $fromInstallation
    })
    if ($running.Count) {
        throw "Close affected Launcher/E-Sys processes first. Running process IDs: $($running.ProcessId -join ', ')."
    }
}

function Add-Target {
    param([string] $Path, [Collections.Generic.List[string]] $List)
    $safe = Get-SafePath $Path
    if (Test-Path -LiteralPath $safe) {
        if (-not $List.Contains($safe)) { $List.Add($safe) }
    }
    else { $skipped.Add($safe) }
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This script requires Windows.'
}
$apps = @(Get-InstalledApps)
$perform = -not $WhatIfPreference
$deleteTargets = [Collections.Generic.List[string]]::new()
$timestampTargets = [Collections.Generic.List[string]]::new()
$installationRoots = [Collections.Generic.List[string]]::new()
$skipped = [Collections.Generic.List[string]]::new()
$profileRoot = Get-SafePath $env:USERPROFILE
$localRoot = Get-SafePath $env:LOCALAPPDATA
$roamingRoot = Get-SafePath $env:APPDATA
$programRoot = Get-SafePath $env:ProgramData
$tempRoot = Get-SafePath $env:TEMP
$configPath = $null
$configChanged = $false
$edition = $LauncherEdition
if ($Clean) {
    if (-not $PSBoundParameters.ContainsKey('Confirm')) { $ConfirmPreference = 'Low' }
    foreach ($name in @('EsysPath', 'LauncherVersion', 'ReferenceDate',
        'IncludeSharedCleanup', 'IncludeSystemTimestamps')) {
        if ($PSBoundParameters.ContainsKey($name)) {
            throw "-$name is a rearm-only parameter and cannot be combined with -Clean."
        }
    }
    $registered = @($apps | Where-Object {
        $_.Name -match '^E-?Sys Launcher (?:Premium|Pro)(?:\s|$)' -and
        ($LauncherEdition -eq 'Auto' -or $_.Name -match "\b$LauncherEdition\b")
    })
    if ($registered.Count -gt 0) {
        if ($perform) { throw 'Launcher is still registered as installed. Uninstall it before using -Clean.' }
        Write-Warning 'Launcher is still registered as installed; this is only a cleanup preview. Uninstall it before executing -Clean.'
    }
    $programFilesRoots = @(
        $env:ProgramFiles
        if ([Environment]::Is64BitOperatingSystem) {
            [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
        }
    ) | Where-Object { $_ } | Sort-Object -Unique
    foreach ($path in Get-LauncherCleanupTargets @($programRoot, $localRoot, $roamingRoot) $programFilesRoots $LauncherEdition) {
        Add-Target $path $deleteTargets
    }
    # Launcher-specific Start Menu folders; leave loose/unidentified shortcuts alone.
    foreach ($root in @($programRoot, $roamingRoot)) {
        $startMenu = Join-Path $root 'Microsoft\Windows\Start Menu\Programs'
        if (Test-Path -LiteralPath $startMenu -PathType Container) {
            foreach ($path in Get-LauncherCleanupTargets @($startMenu) @() $LauncherEdition) {
                Add-Target $path $deleteTargets
            }
        }
    }
    if ($LauncherPath) {
        $customPath = Get-SafePath $LauncherPath
        $expected = '^E-?Sys[_ -]?Launcher[_ -]?(?:Pro|Premium)$'
        if ([IO.Path]::GetFileName($customPath) -notmatch $expected -or
            ($LauncherEdition -ne 'Auto' -and [IO.Path]::GetFileName($customPath) -notmatch "$LauncherEdition$")) {
            throw '-Clean -LauncherPath must name a Launcher PRO/Premium product folder, not a shared container.'
        }
        Add-Target $customPath $deleteTargets
    }
}
else {
    $esys = Select-Installation $apps '^E-?Sys\s+\d' $EsysPath 'E-Sys'
    $pattern = switch ($LauncherEdition) {
        'Premium' { '^E-?Sys Launcher Premium(?:\s|$)' }
        'Pro' { '^E-?Sys Launcher Pro(?:\s|$)' }
        default { '^E-?Sys Launcher (?:Premium|Pro)(?:\s|$)' }
    }
    $launcher = Select-Installation $apps $pattern $LauncherPath 'E-Sys Launcher'
    $esysRoot = Get-SafePath $esys.Path
    $launcherRoot = Get-SafePath $launcher.Path
    $installationRoots.Add($esysRoot)
    $installationRoots.Add($launcherRoot)
    $edition = $LauncherEdition
    if ($edition -eq 'Auto') {
        if ($launcher.Name -match 'Premium') { $edition = 'Premium' }
        elseif ($launcher.Name -match '\bPro\b') { $edition = 'Pro' }
        else { throw 'Specify -LauncherEdition when using an unregistered LauncherPath.' }
    }
    foreach ($root in @($esysRoot, $launcherRoot)) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            throw "Installation folder does not exist: $root"
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $esysRoot 'config\Esys.properties') -PathType Leaf)) {
        throw 'E-Sys installation does not contain config\Esys.properties.'
    }
    if ($null -eq $LauncherVersion) {
        $parsed = $null
        if (-not [version]::TryParse($launcher.Version.Trim(), [ref] $parsed)) {
            throw "Invalid Launcher version '$($launcher.Version)'. Specify -LauncherVersion."
        }
        $LauncherVersion = $parsed
    }
    if ($edition -eq 'Pro') {
        Write-Warning "Detected Launcher PRO $LauncherVersion. Original documentation excludes Pro; the 2.0.5 mod targets Pro 3.4, not all Pro versions."
        if (-not $PSBoundParameters.ContainsKey('ReferenceDate')) {
            $ReferenceDate = [datetime]::new(2020, 6, 1, 3, 0, 0)
        }
    }
    if ($perform) {
        Assert-ExecutionReady $installationRoots.ToArray()
    }

    Add-Target (Join-Path $profileRoot 'Esys') $deleteTargets
    foreach ($parent in @($programRoot, $localRoot, $roamingRoot)) {
        foreach ($name in @('E-Sys Launcher Premium', 'E-Sys_Launcher_Premium')) {
            Add-Target (Join-Path $parent $name) $deleteTargets
        }
        if ($IncludeSharedCleanup) { Add-Target (Join-Path $parent 'Tokenmaster') $deleteTargets }
    }
    if ($IncludeSharedCleanup) {
        Add-Target (Join-Path $programRoot 'IsolatedStorage') $deleteTargets
        if (Test-Path -LiteralPath $tempRoot -PathType Container) {
            foreach ($file in Get-ChildItem -LiteralPath $tempRoot -Filter '*.dat' -File -Force) {
                Add-Target $file.FullName $deleteTargets
            }
        }
    }

    # Enumerate before making changes, without following junctions or symlinks.
    foreach ($root in @($esysRoot, $launcherRoot)) {
        foreach ($item in Get-Tree $root) { Add-Target $item.FullName $timestampTargets }
    }
    foreach ($root in @($localRoot, $profileRoot, $programRoot)) { Add-Target $root $timestampTargets }
    $shell = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    $shellNames = @('Cache', 'Cookies')
    if ($LauncherVersion -ge [version]'2.6.2') { $shellNames += 'History', 'Personal' }
    foreach ($name in $shellNames) {
        $property = $shell.PSObject.Properties[$name]
        if ($null -eq $property -or -not $property.Value) {
            throw "Cannot resolve required User Shell Folder '$name'."
        }
        Add-Target ([string] $property.Value) $timestampTargets
    }
    if ($LauncherVersion -lt [version]'2.6.2' -and (Test-Path -LiteralPath $tempRoot)) {
        foreach ($file in Get-ChildItem -LiteralPath $tempRoot -File -Force) {
            if (-not $deleteTargets.Contains($file.FullName)) { Add-Target $file.FullName $timestampTargets }
        }
    }
    if ($IncludeSystemTimestamps) {
        foreach ($path in @($env:SystemRoot, (Join-Path $env:SystemRoot 'System32'))) {
            Add-Target $path $timestampTargets
        }
        if ([Environment]::Is64BitOperatingSystem) {
            Add-Target (Join-Path $env:SystemRoot 'SysWOW64') $timestampTargets
        }
        if ($LauncherVersion -ge [version]'2.8.0') {
            $common = if ([Environment]::Is64BitOperatingSystem) {
                [Environment]::GetEnvironmentVariable('CommonProgramFiles(x86)')
            } else { $env:CommonProgramFiles }
            Add-Target $common $timestampTargets
        }
    }
    $configPath = Join-Path $esysRoot 'config\Esys.properties'
    $originalBytes = [IO.File]::ReadAllBytes($configPath)
    $newBytes = Get-PropertiesWithoutToken $originalBytes
    $configChanged = [Convert]::ToBase64String($originalBytes) -ne [Convert]::ToBase64String($newBytes)
}
Add-Target 'C:\Data\FreeToken.est' $deleteTargets
if ($Clean -or $IncludeSharedCleanup) {
    $rsaRoot = Join-Path $programRoot 'Microsoft\Crypto\RSA'
    if (Test-Path -LiteralPath $rsaRoot -PathType Container) {
        foreach ($file in @(Get-Tree $rsaRoot | Where-Object {
            -not $_.PSIsContainer -and $_.Name -match '^(?:4eccd106f69e31c1b12304e5463bb71d|83aa4cc77f591dfc2374580bbd95f6ba)'
        })) { Add-Target $file.FullName $deleteTargets }
    }
}
# A custom path may duplicate a known path or sit beneath a matched namespace.
$minimalTargets = @($deleteTargets | Where-Object {
    $candidate = $_
    @($deleteTargets | Where-Object {
        $_ -ne $candidate -and (Test-PathWithin $candidate $_)
    }).Count -eq 0
})
$deleteTargets.Clear()
foreach ($target in $minimalTargets) { $deleteTargets.Add($target) }
if ($Clean -and $perform) {
    Assert-ExecutionReady $deleteTargets.ToArray() -CleanupOnly
}
$protected = @($profileRoot, $localRoot, $roamingRoot, $programRoot, $tempRoot,
    (Get-SafePath $env:SystemRoot), (Get-SafePath $PSScriptRoot)) + @($installationRoots.ToArray())
if ($Clean) {
    foreach ($app in $apps | Where-Object { $_.Name -match '^E-?Sys\s+\d' -and $_.Path }) {
        $protected += Get-SafePath $app.Path
    }
    $protected += @($programFilesRoots | ForEach-Object { Get-SafePath $_ })
}
foreach ($target in $deleteTargets) {
    foreach ($path in $protected) {
        if (Test-PathWithin $path $target) { throw "Deletion would contain protected path: $path" }
    }
    [void] @(Get-Tree $target)
}
$backupBase = Get-SafePath $BackupRoot
foreach ($target in @($deleteTargets.ToArray()) + @($installationRoots.ToArray())) {
    if ((Test-PathWithin $backupBase $target) -or (Test-PathWithin $target $backupBase)) {
        throw "BackupRoot must not overlap deletion/installation targets: $target"
    }
}
$created = [datetime]::SpecifyKind($ReferenceDate, [DateTimeKind]::Unspecified).ToUniversalTime()
$modified = $created.AddSeconds(1)
$accessed = $created.AddSeconds(2)
$plan = [Collections.Generic.List[object]]::new()
foreach ($path in $deleteTargets) { $plan.Add([pscustomobject]@{ Action = 'Delete (after backup)'; Path = $path }) }
if ($configChanged) { $plan.Add([pscustomobject]@{ Action = 'Remove Path.EST'; Path = $configPath }) }
foreach ($path in $timestampTargets) { $plan.Add([pscustomobject]@{ Action = 'Set three timestamps'; Path = $path }) }
if ($Clean) {
    Write-Host "Post-uninstall Launcher cleanup ($edition); E-Sys is not modified."
} else {
    Write-Host "E-Sys $($esys.Version): $esysRoot"
    Write-Host "Launcher $edition $LauncherVersion`: $launcherRoot"
    Write-Host "Reference local time: $($ReferenceDate.ToString('yyyy-MM-dd HH:mm:ss')); system clock will not be changed."
}
Write-Host "Plan: $($deleteTargets.Count) deletions, $($timestampTargets.Count) timestamp targets; config edit: $configChanged."
if (-not $Clean -and -not $IncludeSharedCleanup) { Write-Warning 'Shared Tokenmaster/IsolatedStorage, temporary .dat and RSA cleanup excluded. Use -IncludeSharedCleanup to opt into the original broader cleanup.' }
if (-not $Clean -and -not $IncludeSystemTimestamps) { Write-Warning 'Windows/CommonProgramFiles timestamps excluded. Use -IncludeSystemTimestamps to opt into those original steps.' }
foreach ($path in $skipped) { Write-Verbose "Optional target absent: $path" }
if ($Clean -and $plan.Count -eq 0) {
    [pscustomobject]@{ Status = 'NothingToClean'; Backup = $null; Operations = 0 }
    return
}
$operation = if ($Clean) { 'Back up and remove post-uninstall Launcher leftovers' }
             else { 'Back up affected data and timestamps, remove configuration, and predate files/folders' }
# One approval covers the complete plan, avoiding partially approved operations.
if (-not $PSCmdlet.ShouldProcess("$edition $LauncherVersion; $($plan.Count) operations",
    $operation)) {
    $plan.ToArray()
    return
}

$backup = Join-Path $backupBase ([datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N'))
[void] [IO.Directory]::CreateDirectory($backup)
Write-Host "Backup: $backup"
$records = [Collections.Generic.List[object]]::new()
$data = [Collections.Generic.List[object]]::new()
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($target in @($deleteTargets.ToArray()) + @($timestampTargets.ToArray())) {
    $items = if ($deleteTargets.Contains($target)) { @(Get-Tree $target) }
             else { @(Get-Item -LiteralPath $target -Force) }
    foreach ($item in $items) {
        if ($seen.Add($item.FullName)) {
            $records.Add([pscustomobject]@{
                Path = $item.FullName
                Directory = [bool] $item.PSIsContainer
                CreatedUtc = $item.CreationTimeUtc.ToString('o')
                ModifiedUtc = $item.LastWriteTimeUtc.ToString('o')
                AccessedUtc = $item.LastAccessTimeUtc.ToString('o')
                Attributes = [int] $item.Attributes
            })
        }
    }
}
$index = 0
$dataTargets = @($deleteTargets.ToArray())
if ($configPath) { $dataTargets += $configPath }
foreach ($target in $dataTargets) {
    Write-Progress -Id 1 -Activity 'Backing up and verifying affected data' -Status $target `
        -PercentComplete ([int](100 * $index / $dataTargets.Count))
    $destination = Join-Path $backup ("data\{0:D4}" -f $index++)
    [void] [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
    Copy-Item -LiteralPath $target -Destination $destination -Recurse -Force
    $sourceItems = @(Get-Tree $target)
    foreach ($item in $sourceItems) {
        $copyPath = if ($item.FullName -eq $target) { $destination }
                    else { $destination + $item.FullName.Substring($target.Length) }
        $copy = Get-Item -LiteralPath $copyPath -Force
        if ($item.PSIsContainer -ne $copy.PSIsContainer) { throw "Backup type mismatch: $target" }
        if (-not $item.PSIsContainer -and
            (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash -ne
            (Get-FileHash -LiteralPath $copyPath -Algorithm SHA256).Hash) {
            throw "Backup hash verification failed: $($item.FullName)"
        }
    }
    $data.Add([pscustomobject]@{ Original = $target; Backup = $destination })
}
Write-Progress -Id 1 -Activity 'Backing up and verifying affected data' -Completed
$manifestPath = Join-Path $backup 'manifest.json'
[pscustomobject]@{
    Status = 'BackedUp'
    Mode = if ($Clean) { 'Clean' } else { 'Rearm' }
    Edition = $edition
    Version = if ($null -ne $LauncherVersion) { $LauncherVersion.ToString() } else { $null }
    ReferenceLocal = if (-not $Clean) { $ReferenceDate.ToString('o') } else { $null }
    Data = $data.ToArray()
    Metadata = $records.ToArray()
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
try {
    $operationIndex = 0
    foreach ($target in $deleteTargets) {
        Write-Progress -Id 2 -Activity 'Removing configuration and leftovers' -Status $target `
            -PercentComplete ([int](100 * $operationIndex++ / $deleteTargets.Count))
        # Revalidate immediately before deletion in case the filesystem changed.
        [void] @(Get-Tree $target)
        Remove-Item -LiteralPath $target -Recurse -Force
        if (Test-Path -LiteralPath $target) { throw "Deletion verification failed: $target" }
    }
    Write-Progress -Id 2 -Activity 'Removing configuration and leftovers' -Completed
    if ($configChanged) {
        if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath)) -ne
            [Convert]::ToBase64String($originalBytes)) {
            throw 'Esys.properties changed after planning; refusing to overwrite concurrent changes.'
        }
        $temporary = $configPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        try {
            [IO.File]::WriteAllBytes($temporary, $newBytes)
            [IO.File]::Replace($temporary, $configPath, [System.Management.Automation.Language.NullString]::Value)
        }
        finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
        if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath)) -ne
            [Convert]::ToBase64String($newBytes)) { throw 'Configuration write verification failed.' }
    }
    # Children first: deleting/editing children otherwise changes parent timestamps.
    $operationIndex = 0
    foreach ($target in ($timestampTargets | Sort-Object { $_.Length } -Descending)) {
        Write-Progress -Id 3 -Activity 'Predating and verifying files and folders' -Status $target `
            -PercentComplete ([int](100 * $operationIndex++ / $timestampTargets.Count))
        if (-not (Test-Path -LiteralPath $target)) { throw "Timestamp target disappeared: $target" }
        Set-ItemTimes $target $created $modified $accessed
    }
    [IO.File]::WriteAllText((Join-Path $backup 'completed.txt'), [datetime]::UtcNow.ToString('o'))
}
catch {
    Write-Warning "Execution stopped; partial changes may remain. Backup and metadata: $manifestPath"
    throw
}
finally {
    Write-Progress -Id 2 -Activity 'Removing configuration and leftovers' -Completed
    Write-Progress -Id 3 -Activity 'Predating and verifying files and folders' -Completed
}
Write-Host "Completed successfully. Backup: $backup" -ForegroundColor Green
if (-not $Clean) {
    Write-Host "Current system date: $([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Host 'The system clock was not changed; use the valid clock range for your Launcher version.'
}
[pscustomobject]@{ Status = 'Completed'; Backup = $backup; Operations = $plan.Count }
