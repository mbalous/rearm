# Rearm

A Windows PowerShell utility for inspecting and maintaining application data.
It consolidates older E-Sys Launcher maintenance workflows into a single
script and includes a separate post-uninstall cleanup mode.

> **Use with care.** Normal execution makes changes immediately and requires
> administrator privileges. It can remove application data and cryptographic
> keys and change file and folder timestamps. Preview the plan first, close
> the affected applications, and keep an independent system backup.

## Requirements

- Windows with Windows PowerShell 5.1 or PowerShell 7.
- Administrator privileges for execution; preview does not require elevation.
- For the normal workflow, discoverable E-Sys and Launcher installations.

No bundled executables or external utilities are required.

## Usage

In PowerShell, from the project directory, preview the normal workflow:

```powershell
.\Rearm-E-SysLauncher.ps1 -WhatIf
```

Review the listed operations. To execute, open an elevated PowerShell session:

```powershell
.\Rearm-E-SysLauncher.ps1
```

Execution is the default and does not prompt under standard PowerShell
preferences. Use `-Confirm` to request confirmation. Use `-Verbose` to see
optional paths that were absent.

After uninstalling Launcher through Windows or its installer, preview or
perform cleanup of recognized Launcher leftovers:

```powershell
.\Rearm-E-SysLauncher.ps1 -Clean -WhatIf
.\Rearm-E-SysLauncher.ps1 -Clean
```

Cleanup does not uninstall software, modify E-Sys configuration, or predate
files. It refuses to run while the selected Launcher is still registered as
installed. It targets known Launcher folders and the legacy token and RSA
filename patterns; it does not attempt to find every possible leftover.

## Scope and safeguards

- The normal workflow removes selected application data and `Path.EST` from
  `Esys.properties`, and changes timestamps. By default it also targets
  shared TokenMaster and IsolatedStorage data, temporary `.dat` files and
  certain RSA keys. These may affect other applications. It also changes
  timestamps on Windows and common-program container folders.
- To exclude shared cleanup or system-folder timestamps, respectively, use
  `-IncludeSharedCleanup:$false` or `-IncludeSystemTimestamps:$false`.
  Excluding them may prevent the intended workflow from working.
- Discovery can be overridden with `-EsysPath`, `-LauncherPath`,
  `-LauncherEdition Premium|Pro`, and `-LauncherVersion`. In cleanup mode,
  `-LauncherPath` must name a specific Launcher product folder.
- The default reference dates are 2011-01-01 for Premium and 2020-06-01 for
  Pro; `-ReferenceDate` overrides them. The system clock is not changed, and
  these dates are not validated license date ranges. Pro compatibility is
  uncertain; the original Premium documentation excludes Pro, and the
  modified workflow targeted a specific Pro version.
- The script rejects unsafe paths and reparse points, checks for running
  applications, and verifies copied data before making changes.
- Backups default to `Rearm-Backups` beside the script; use `-BackupRoot` for
  a different absolute, nonoverlapping location. Backups and `manifest.json`
  can contain sensitive data and paths: protect them and do not publish them.
  They do not preserve all ACLs or alternate streams.
- There is no automatic rollback. If execution fails, retain the backup and
  restore the affected data and metadata from its manifest as appropriate;
  do not blindly overwrite newer data. A `completed.txt` file is written only
  after operations complete.

Use the software only where you have the necessary rights and permissions.
This project is independent and is not affiliated with the products it
references. Product names and trademarks belong to their respective owners.

## Tests

On Windows, run:

```powershell
.\Test-Rearm-E-SysLauncher.ps1
```

The tests use temporary fixture installations and mocked discovery and
elevation, rather than resetting installed applications.

## Attribution and license

The original scripts were credited to Tony TwoClicks, and the 2.0.5
modification to DreckSoft. This repository does not include the original
packages or executables.

The [license](LICENSE) permits noncommercial use of the portions that the
contributors have rights to license. Commercial use or repurposing requires
separate permission. Third-party rights are not granted by this license.
