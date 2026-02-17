# Find Deformed .uasset Files

PowerShell + WPF tool that scans a folder for **.uasset** files corrupted by Git merge conflicts (or invalid headers), so you can find and fix them before they break your Unreal Engine project.

## What it detects

- **Git merge conflict markers** inside .uasset files: `<<<<<<<`, `=======`, `>>>>>>>` (binary files should never contain these).
- **Invalid UAsset header**: files that don’t start with the Unreal package magic bytes (`0x9E2A83C1`).

## Size filter

- Only **.uasset files ≤ 3KB** are scanned. This keeps scans fast on very large (e.g. 90GB) projects by using filesystem metadata only for the filter and opening only small files. You can change the limit by editing `$script:MaxUAssetSizeBytes` at the top of `find-deformed-uassets.ps1` (default: 3072 bytes).

## Style and integration

- Matches the style of **GitFileVerPicker.ps1** (WPF, XAML, DataGrid, MessageBox, same patterns).
- Optional integration: **Open in Version Picker** launches `GitFileVerPicker.ps1` for the selected file so you can restore a good version from Git history.

## How to run

```powershell
# Scan current directory
.\find-deformed-uassets.ps1

# Scan a specific folder
.\find-deformed-uassets.ps1 "C:\Path\To\Your\UnrealProject"
```

1. Use **Browse** to pick the root folder (e.g. project or Content folder).
2. Click **Scan for .uasset files**.
3. Review the grid: **Status** (OK / Deformed / Error), **Reason**, **Size**, **In Git**.
4. For a deformed file, select it and click **Open in Version Picker** to fix it with Git history (if you use GitFileVerPicker.ps1).

## Version Picker path

The script looks for `GitFileVerPicker.ps1` in a sibling folder:

- `..\Git-Version-Picker\GitFileVerPicker.ps1` relative to this script.

To use a different location (e.g. `P:\Resources\Scripts\Git-Version-Picker\GitFileVerPicker.ps1`), edit the variable at the top of `find-deformed-uassets.ps1`:

```powershell
$script:GitFileVerPickerPath = "P:\Resources\Scripts\Git-Version-Picker\GitFileVerPicker.ps1"
```

## Skipped paths

- `Intermediate\` and `Saved\` are skipped to avoid scanning build artifacts.

## Scan progress and log

- While scanning, the status bar shows **progress**: e.g. `Scanning... (150 / 500)`.
- Each run writes a **log file** (one line per file: status and relative path). Default path: `%TEMP%\find-deformed-uassets-ScanLog.txt`. When the scan finishes, the status line includes `Log: <path>` so you can open or copy it. To disable logging, set `$script:ScanLogPath = ""` at the top of the script.

## Limitations

- Only files ≤ 3KB are scanned; corruptions in larger .uasset files are not reported.
- Long paths (e.g. over 260 characters) or permission-denied folders may cause errors or skipped content.
- There is no cancel button during a scan (future improvement).

## Tests

Core logic is in `Find-DeformedUAssetsCore.ps1` (dot-sourced by the main script). Pester tests live in `find-deformed-uassets.Tests.ps1`.

```powershell
# Run all tests (requires Pester, e.g. Install-Module Pester -Scope CurrentUser)
Invoke-Pester -Script .\find-deformed-uassets.Tests.ps1
```

Tests cover: `Find-BytesInBuffer`, `Test-UAssetMagicHeader`, `Test-FileHasConflictMarkers`, `Get-UAssetHealth`, and `Invoke-ScanUAssets` (including size filter and excluded paths).

## Requirements

- PowerShell (Windows).
- WPF (built-in); no extra modules.
