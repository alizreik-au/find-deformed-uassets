Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms

# Default scan root: current directory or first argument
$script:ScanRoot = if ($args[0]) { $args[0] } else { Get-Location | Select-Object -ExpandProperty Path }

# UAsset magic signature (little-endian): 0x9E2A83C1
$script:UAssetMagicBytes = [byte[]]@(0xC1, 0x83, 0x2A, 0x9E)

# Git conflict marker byte sequences (ASCII)
$script:ConflictMarkerHead = [System.Text.Encoding]::ASCII.GetBytes("<<<<<<<")
$script:ConflictMarkerSep = [System.Text.Encoding]::ASCII.GetBytes("=======")
$script:ConflictMarkerEnd = [System.Text.Encoding]::ASCII.GetBytes(">>>>>>>")

# Only scan .uasset files at or below this size (bytes). Use filesystem metadata so large trees stay fast.
$script:MaxUAssetSizeBytes = 3072   # 3KB

# Scan log path (written during each scan; overwritten per run). Empty = no log file.
$script:ScanLogPath = Join-Path $env:TEMP "find-deformed-uassets-ScanLog.txt"

# Path to Git Version Picker script. Set to your GitFileVerPicker.ps1 location if not sibling folder.
$script:GitFileVerPickerPath = Join-Path (Split-Path -Path $PSCommandPath -Parent) "..\Git-Version-Picker\GitFileVerPicker.ps1"
# Alternative: $script:GitFileVerPickerPath = "P:\Resources\Scripts\Git-Version-Picker\GitFileVerPicker.ps1"

# XAML for the WPF GUI
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" 
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" 
        Title="Find Deformed .uasset Files (Git Merge Conflicts)" Height="500" Width="1200">
    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="*" />
            <RowDefinition Height="Auto" />
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="10,10,10,5">
            <TextBlock Text="Folder:" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <TextBox Name="FolderPathBox" Width="700" VerticalAlignment="Center" IsReadOnly="True"/>
            <Button Name="BrowseButton" Content="Browse..." Width="80" Margin="8,0,0,0"/>
        </StackPanel>

        <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="10,0,10,10">
            <Button Name="ScanButton" Content="Scan for .uasset files" Width="180" Margin="0,0,8,0"/>
            <TextBlock Name="StatusText" Text="Set folder and click Scan." VerticalAlignment="Center" Foreground="Gray"/>
        </StackPanel>

        <DataGrid Name="ResultsGrid" AutoGenerateColumns="False" Grid.Row="2" Margin="10" SelectionMode="Single">
            <DataGrid.Columns>
                <DataGridTextColumn Header="Path" Binding="{Binding RelativePath}" Width="400"/>
                <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="100"/>
                <DataGridTextColumn Header="Reason" Binding="{Binding Reason}" Width="280"/>
                <DataGridTextColumn Header="Size" Binding="{Binding FileSize}" Width="90"/>
                <DataGridTextColumn Header="In Git" Binding="{Binding InGit}" Width="60"/>
            </DataGrid.Columns>
        </DataGrid>

        <StackPanel Grid.Row="3" Orientation="Horizontal" Margin="10" HorizontalAlignment="Right">
            <Button Name="OpenVersionPickerButton" Content="Open in Version Picker" Width="180" Margin="0,0,8,0"/>
            <Button Name="RefreshButton" Content="Refresh" Width="80"/>
        </StackPanel>
    </Grid>
</Window>
"@

# Load the XAML and parse the GUI
$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

$folderPathBox = $window.FindName("FolderPathBox")
$browseButton = $window.FindName("BrowseButton")
$scanButton = $window.FindName("ScanButton")
$statusText = $window.FindName("StatusText")
$resultsGrid = $window.FindName("ResultsGrid")
$openVersionPickerButton = $window.FindName("OpenVersionPickerButton")
$refreshButton = $window.FindName("RefreshButton")

# Initialize folder path
$folderPathBox.Text = $script:ScanRoot

# Returns true if the byte array contains the search sequence at any position
function Find-BytesInBuffer {
    param (
        [byte[]]$Buffer,
        [byte[]]$Search
    )
    if ($null -eq $Buffer -or $null -eq $Search -or $Search.Length -eq 0 -or $Buffer.Length -lt $Search.Length) {
        return $false
    }
    for ($i = 0; $i -le ($Buffer.Length - $Search.Length); $i++) {
        $match = $true
        for ($j = 0; $j -lt $Search.Length; $j++) {
            if ($Buffer[$i + $j] -ne $Search[$j]) {
                $match = $false
                break
            }
        }
        if ($match) { return $true }
    }
    return $false
}

# Returns true if file starts with UAsset magic bytes
function Test-UAssetMagicHeader {
    param ([byte[]]$Header)
    if ($null -eq $Header -or $Header.Length -lt $script:UAssetMagicBytes.Length) {
        return $false
    }
    for ($i = 0; $i -lt $script:UAssetMagicBytes.Length; $i++) {
        if ($Header[$i] -ne $script:UAssetMagicBytes[$i]) {
            return $false
        }
    }
    return $true
}

# Analyze a single .uasset file: returns [PSCustomObject] with Status, Reason, FileSize, InGit, FullPath, RelativePath
function Get-UAssetHealth {
    param (
        [string]$FullPath,
        [string]$RelativePath,
        [string]$GitRoot
    )

    $result = [PSCustomObject]@{
        FullPath     = $FullPath
        RelativePath = $RelativePath
        Status       = "OK"
        Reason       = ""
        FileSize     = ""
        InGit        = "No"
        Deformed    = $false
    }

    if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) {
        $result.Status = "Error"
        $result.Reason = "File not found"
        $result.Deformed = $true
        return $result
    }

    $fileInfo = Get-Item -LiteralPath $FullPath
    $result.FileSize = "{0:N0} bytes" -f $fileInfo.Length

    # Check if in git (optional)
    if ($GitRoot) {
        $relForGit = $FullPath.Substring($GitRoot.Length).TrimStart('\', '/').Replace('\', '/')
        try {
            $null = git ls-files --error-unmatch -- $relForGit 2>$null
            $result.InGit = "Yes"
        } catch {
            $result.InGit = "No"
        }
    }

    try {
        $stream = [System.IO.File]::OpenRead($FullPath)
        try {
            $headerSize = [Math]::Min(8192, $stream.Length)  # Read first 8KB for conflict markers and magic
            $buffer = New-Object byte[] $headerSize
            $read = $stream.Read($buffer, 0, $headerSize)

            # If file is small, read rest for conflict markers (merge text can be at end)
            if ($stream.Length -gt $headerSize -and $stream.Length -lt 1024 * 1024) {
                $rest = New-Object byte[] ($stream.Length - $read)
                $stream.Read($rest, 0, $rest.Length) | Out-Null
                $fullBuffer = $buffer[0..($read - 1)] + $rest
            } else {
                $fullBuffer = $buffer[0..($read - 1)]
            }

            $hasConflictHead = Find-BytesInBuffer -Buffer $fullBuffer -Search $script:ConflictMarkerHead
            $hasConflictSep  = Find-BytesInBuffer -Buffer $fullBuffer -Search $script:ConflictMarkerSep
            $hasConflictEnd  = Find-BytesInBuffer -Buffer $fullBuffer -Search $script:ConflictMarkerEnd

            if ($hasConflictHead -or $hasConflictSep -or $hasConflictEnd) {
                $result.Status = "Deformed"
                $reasons = @()
                if ($hasConflictHead) { $reasons += "contains <<<<<<<" }
                if ($hasConflictSep)  { $reasons += "contains ======= " }
                if ($hasConflictEnd)  { $reasons += "contains >>>>>>>" }
                $result.Reason = "Git merge conflict markers: " + ($reasons -join "; ")
                $result.Deformed = $true
                return $result
            }

            $hasValidMagic = Test-UAssetMagicHeader -Header $buffer
            if (-not $hasValidMagic) {
                $result.Status = "Deformed"
                $result.Reason = "Invalid UAsset header (bad magic bytes)."
                $result.Deformed = $true
                return $result
            }

            $result.Reason = "Valid"
        } finally {
            $stream.Close()
        }
    } catch {
        $result.Status = "Error"
        $result.Reason = "Read error: $($_.Exception.Message)"
        $result.Deformed = $true
    }

    return $result
}

# Scan folder for .uasset files and return list of health results
function Invoke-ScanUAssets {
    param ([string]$RootPath)

    $gitRoot = $null
    try {
        Push-Location -Path $RootPath
        $gitRoot = (git rev-parse --show-toplevel 2>$null)
        if (-not $gitRoot) { $gitRoot = $null }
        Pop-Location
    } catch {
        Pop-Location -ErrorAction SilentlyContinue
    }

    $rootAbs = [System.IO.Path]::GetFullPath($RootPath)
    $uassetFiles = Get-ChildItem -Path $RootPath -Filter "*.uasset" -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\Intermediate\\' -and $_.FullName -notmatch '\\Saved\\' -and $_.Length -le $script:MaxUAssetSizeBytes }

    $results = [System.Collections.ArrayList]::new()

    foreach ($file in $uassetFiles) {
        try {
            $rel = $file.FullName.Substring($rootAbs.Length).TrimStart('\', '/')
            $health = Get-UAssetHealth -FullPath $file.FullName -RelativePath $rel -GitRoot $gitRoot
            $null = $results.Add($health)
        } catch {
            $rel = try { $file.FullName.Substring($rootAbs.Length).TrimStart('\', '/') } catch { $file.FullName }
            $null = $results.Add([PSCustomObject]@{ FullPath = $file.FullName; RelativePath = $rel; Status = "Error"; Reason = $_.Exception.Message; FileSize = ""; InGit = "No"; Deformed = $true })
        }
    }

    return @($results), $gitRoot
}

# Run scan on current folder and update grid (call from UI thread or Dispatcher)
function Update-ScanResults {
    param (
        [string]$Folder,
        [System.Windows.Controls.TextBlock]$StatusControl,
        [System.Windows.Controls.DataGrid]$Grid
    )

    $StatusControl.Text = "Scanning..."
    $StatusControl.Foreground = [System.Windows.Media.Brushes]::Orange

    $Folder = $Folder.Trim()
    if (-not [System.IO.Directory]::Exists($Folder)) {
        [System.Windows.MessageBox]::Show("Folder does not exist: $Folder", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        $StatusControl.Text = "Invalid folder."
        $StatusControl.Foreground = [System.Windows.Media.Brushes]::Gray
        return
    }

    $scanResult = Invoke-ScanUAssets -RootPath $Folder
    $items = $scanResult[0]
    $deformedCount = ($items | Where-Object { $_.Deformed }).Count
    $totalCount = $items.Count

    $Grid.ItemsSource = $items
    $StatusControl.Text = "Found $totalCount .uasset file(s) under 3KB. Deformed: $deformedCount"
    $StatusControl.Foreground = if ($deformedCount -gt 0) {
        [System.Windows.Media.Brushes]::Red
    } else {
        [System.Windows.Media.Brushes]::Green
    }
}

# Browse for folder
$browseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Select folder to scan for .uasset files"
    $dialog.SelectedPath = $folderPathBox.Text
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $folderPathBox.Text = $dialog.SelectedPath
        $script:ScanRoot = $dialog.SelectedPath
    }
})

# Scan button (runs scan and updates grid)
$scanButton.Add_Click({
    $folder = $folderPathBox.Text.Trim()
    if (-not [System.IO.Directory]::Exists($folder)) {
        [System.Windows.MessageBox]::Show("Folder does not exist: $folder", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        return
    }
    $statusText.Text = "Scanning..."
    $statusText.Foreground = [System.Windows.Media.Brushes]::Orange

    $progressSync = [hashtable]::Synchronized(@{ Count = 0; Total = 0 })
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.Open()
    $runspace.SessionStateProxy.Path.SetLocation($folder) | Out-Null
    $runspace.SessionStateProxy.SetVariable("RootPath", $folder)
    $runspace.SessionStateProxy.SetVariable("UAssetMagicBytes", $script:UAssetMagicBytes)
    $runspace.SessionStateProxy.SetVariable("ConflictMarkerHead", $script:ConflictMarkerHead)
    $runspace.SessionStateProxy.SetVariable("ConflictMarkerSep", $script:ConflictMarkerSep)
    $runspace.SessionStateProxy.SetVariable("ConflictMarkerEnd", $script:ConflictMarkerEnd)
    $runspace.SessionStateProxy.SetVariable("MaxUAssetSizeBytes", $script:MaxUAssetSizeBytes)
    $runspace.SessionStateProxy.SetVariable("ProgressSync", $progressSync)
    $runspace.SessionStateProxy.SetVariable("LogPath", $script:ScanLogPath)

    $scriptBlock = {
        function Find-BytesInBuffer { param([byte[]]$Buffer,[byte[]]$Search)
            if ($null -eq $Buffer -or $null -eq $Search -or $Search.Length -eq 0 -or $Buffer.Length -lt $Search.Length) { return $false }
            for ($i = 0; $i -le ($Buffer.Length - $Search.Length); $i++) {
                $match = $true
                for ($j = 0; $j -lt $Search.Length; $j++) { if ($Buffer[$i + $j] -ne $Search[$j]) { $match = $false; break } }
                if ($match) { return $true }
            }
            return $false
        }
        function Test-UAssetMagicHeader { param([byte[]]$Header)
            if ($null -eq $Header -or $Header.Length -lt $UAssetMagicBytes.Length) { return $false }
            for ($i = 0; $i -lt $UAssetMagicBytes.Length; $i++) { if ($Header[$i] -ne $UAssetMagicBytes[$i]) { return $false } }
            return $true
        }
        $gitRoot = $null
        try { Push-Location $RootPath; $gitRoot = (git rev-parse --show-toplevel 2>$null); Pop-Location } catch { Pop-Location -ErrorAction SilentlyContinue }
        $rootAbs = [System.IO.Path]::GetFullPath($RootPath)
        $files = @(Get-ChildItem -Path $RootPath -Filter "*.uasset" -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\Intermediate\\' -and $_.FullName -notmatch '\\Saved\\' -and $_.Length -le $MaxUAssetSizeBytes })
        $ProgressSync.Total = $files.Count
        $ProgressSync.Count = 0
        $logWriter = $null
        if ($LogPath) { try { $logWriter = [System.IO.StreamWriter]::new($LogPath, $false, [System.Text.Encoding]::UTF8); $logWriter.WriteLine("Scan started at $(Get-Date -Format 'o') | Root: $RootPath | Files: $($files.Count)") } catch { } }
        $results = [System.Collections.ArrayList]::new()
        foreach ($file in $files) {
            try {
                $rel = $file.FullName.Substring($rootAbs.Length).TrimStart('\', '/')
                $status = "OK"; $reason = "Valid"; $size = "{0:N0} bytes" -f $file.Length; $inGit = "No"; $deformed = $false
                if ($gitRoot) {
                    try {
                        $relForGit = $file.FullName.Substring($gitRoot.Length).TrimStart('\', '/').Replace('\', '/')
                        $null = git ls-files --error-unmatch -- $relForGit 2>$null; $inGit = "Yes"
                    } catch { }
                }
                try {
                    $stream = [System.IO.File]::OpenRead($file.FullName)
                    $headerSize = [Math]::Min(8192, $stream.Length)
                    $buffer = New-Object byte[] $headerSize
                    [void]$stream.Read($buffer, 0, $headerSize)
                    $fullBuffer = $buffer
                    if ($stream.Length -gt $headerSize -and $stream.Length -lt 1048576) {
                        $rest = New-Object byte[] ($stream.Length - $headerSize)
                        [void]$stream.Read($rest, 0, $rest.Length)
                        $fullBuffer = $buffer + $rest
                    }
                    $stream.Close()
                    if (Find-BytesInBuffer $fullBuffer $ConflictMarkerHead) { $status = "Deformed"; $reason = "Git conflict: <<<<<<<"; $deformed = $true }
                    elseif (Find-BytesInBuffer $fullBuffer $ConflictMarkerSep) { $status = "Deformed"; $reason = "Git conflict: ======= "; $deformed = $true }
                    elseif (Find-BytesInBuffer $fullBuffer $ConflictMarkerEnd) { $status = "Deformed"; $reason = "Git conflict: >>>>>>>"; $deformed = $true }
                    elseif (-not (Test-UAssetMagicHeader $buffer)) { $status = "Deformed"; $reason = "Invalid UAsset header"; $deformed = $true }
                } catch { $status = "Error"; $reason = $_.Exception.Message; $deformed = $true }
                $null = $results.Add([PSCustomObject]@{ FullPath = $file.FullName; RelativePath = $rel; Status = $status; Reason = $reason; FileSize = $size; InGit = $inGit; Deformed = $deformed })
                if ($logWriter) { try { $logWriter.WriteLine("$status`t$rel") } catch { } }
            } catch {
                $rel = try { $file.FullName.Substring($rootAbs.Length).TrimStart('\', '/') } catch { $file.FullName }
                $null = $results.Add([PSCustomObject]@{ FullPath = $file.FullName; RelativePath = $rel; Status = "Error"; Reason = $_.Exception.Message; FileSize = ""; InGit = "No"; Deformed = $true })
                if ($logWriter) { try { $logWriter.WriteLine("Error`t$rel") } catch { } }
            }
            $ProgressSync.Count = $results.Count
        }
        if ($logWriter) { try { $logWriter.WriteLine("Scan finished at $(Get-Date -Format 'o')"); $logWriter.Close(); $logWriter.Dispose() } catch { } }
        return @(,$results), ($results | Where-Object Deformed).Count, (@($files).Count)
    }

    $ps = [powershell]::Create().AddScript($scriptBlock)
    $ps.Runspace = $runspace
    $async = $ps.BeginInvoke()

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({
        if ($async.IsCompleted) {
            $timer.Stop()
            try {
                $output = $ps.EndInvoke($async)
                $items = $output[0]
                $deformedCount = $output[1]
                $totalCount = $output[2]
                $resultsGrid.ItemsSource = $items
                $logNote = if ($script:ScanLogPath -and (Test-Path -LiteralPath $script:ScanLogPath)) { " Log: $script:ScanLogPath" } else { "" }
                $statusText.Text = "Found $totalCount .uasset file(s) under 3KB. Deformed: $deformedCount$logNote"
                $statusText.Foreground = if ($deformedCount -gt 0) { [System.Windows.Media.Brushes]::Red } else { [System.Windows.Media.Brushes]::Green }
            } catch {
                $statusText.Text = "Scan failed."
                $statusText.Foreground = [System.Windows.Media.Brushes]::Red
                [System.Windows.MessageBox]::Show($_.Exception.Message, "Scan Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
            } finally {
                $ps.Dispose(); $runspace.Close()
            }
            return
        }
        $c = $progressSync.Count; $t = $progressSync.Total
        $statusText.Text = "Scanning... ($c / $t)"
    })
    $timer.Start()
})

# Open selected file in Git Version Picker
$openVersionPickerButton.Add_Click({
    $selected = $resultsGrid.SelectedItem
    if ($null -eq $selected) {
        [System.Windows.MessageBox]::Show("Please select a file in the grid.", "No Selection", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }
    $fullPath = $selected.FullPath
    if (-not (Test-Path -LiteralPath $fullPath)) {
        [System.Windows.MessageBox]::Show("File no longer exists: $fullPath", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        return
    }
    if (-not (Test-Path -LiteralPath $script:GitFileVerPickerPath)) {
        [System.Windows.MessageBox]::Show("Git Version Picker script not found at: $script:GitFileVerPickerPath", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        return
    }
    try {
        Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$script:GitFileVerPickerPath`" `"$fullPath`""
    } catch {
        [System.Windows.MessageBox]::Show("Failed to start Version Picker: $_", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    }
})

# Refresh: re-scan current folder (reuses same async scan as Scan button)
$refreshButton.Add_Click({
    $folder = $folderPathBox.Text.Trim()
    if (-not [System.IO.Directory]::Exists($folder)) {
        [System.Windows.MessageBox]::Show("Folder does not exist: $folder", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        return
    }
    $statusText.Text = "Scanning..."
    $statusText.Foreground = [System.Windows.Media.Brushes]::Orange
    $progressSync = [hashtable]::Synchronized(@{ Count = 0; Total = 0 })
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.Open()
    $runspace.SessionStateProxy.Path.SetLocation($folder) | Out-Null
    $runspace.SessionStateProxy.SetVariable("RootPath", $folder)
    $runspace.SessionStateProxy.SetVariable("UAssetMagicBytes", $script:UAssetMagicBytes)
    $runspace.SessionStateProxy.SetVariable("ConflictMarkerHead", $script:ConflictMarkerHead)
    $runspace.SessionStateProxy.SetVariable("ConflictMarkerSep", $script:ConflictMarkerSep)
    $runspace.SessionStateProxy.SetVariable("ConflictMarkerEnd", $script:ConflictMarkerEnd)
    $runspace.SessionStateProxy.SetVariable("MaxUAssetSizeBytes", $script:MaxUAssetSizeBytes)
    $runspace.SessionStateProxy.SetVariable("ProgressSync", $progressSync)
    $runspace.SessionStateProxy.SetVariable("LogPath", $script:ScanLogPath)
    $scriptBlock = {
        function Find-BytesInBuffer { param([byte[]]$Buffer,[byte[]]$Search)
            if ($null -eq $Buffer -or $null -eq $Search -or $Search.Length -eq 0 -or $Buffer.Length -lt $Search.Length) { return $false }
            for ($i = 0; $i -le ($Buffer.Length - $Search.Length); $i++) {
                $match = $true
                for ($j = 0; $j -lt $Search.Length; $j++) { if ($Buffer[$i + $j] -ne $Search[$j]) { $match = $false; break } }
                if ($match) { return $true }
            }
            return $false
        }
        function Test-UAssetMagicHeader { param([byte[]]$Header)
            if ($null -eq $Header -or $Header.Length -lt $UAssetMagicBytes.Length) { return $false }
            for ($i = 0; $i -lt $UAssetMagicBytes.Length; $i++) { if ($Header[$i] -ne $UAssetMagicBytes[$i]) { return $false } }
            return $true
        }
        $gitRoot = $null
        try { Push-Location $RootPath; $gitRoot = (git rev-parse --show-toplevel 2>$null); Pop-Location } catch { Pop-Location -ErrorAction SilentlyContinue }
        $rootAbs = [System.IO.Path]::GetFullPath($RootPath)
        $files = @(Get-ChildItem -Path $RootPath -Filter "*.uasset" -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\Intermediate\\' -and $_.FullName -notmatch '\\Saved\\' -and $_.Length -le $MaxUAssetSizeBytes })
        $ProgressSync.Total = $files.Count
        $ProgressSync.Count = 0
        $logWriter = $null
        if ($LogPath) { try { $logWriter = [System.IO.StreamWriter]::new($LogPath, $false, [System.Text.Encoding]::UTF8); $logWriter.WriteLine("Scan started at $(Get-Date -Format 'o') | Root: $RootPath | Files: $($files.Count)") } catch { } }
        $results = [System.Collections.ArrayList]::new()
        foreach ($file in $files) {
            try {
                $rel = $file.FullName.Substring($rootAbs.Length).TrimStart('\', '/')
                $status = "OK"; $reason = "Valid"; $size = "{0:N0} bytes" -f $file.Length; $inGit = "No"; $deformed = $false
                if ($gitRoot) {
                    try {
                        $relForGit = $file.FullName.Substring($gitRoot.Length).TrimStart('\', '/').Replace('\', '/')
                        $null = git ls-files --error-unmatch -- $relForGit 2>$null; $inGit = "Yes"
                    } catch { }
                }
                try {
                    $stream = [System.IO.File]::OpenRead($file.FullName)
                    $headerSize = [Math]::Min(8192, $stream.Length)
                    $buffer = New-Object byte[] $headerSize
                    [void]$stream.Read($buffer, 0, $headerSize)
                    $fullBuffer = $buffer
                    if ($stream.Length -gt $headerSize -and $stream.Length -lt 1048576) {
                        $rest = New-Object byte[] ($stream.Length - $headerSize)
                        [void]$stream.Read($rest, 0, $rest.Length)
                        $fullBuffer = $buffer + $rest
                    }
                    $stream.Close()
                    if (Find-BytesInBuffer $fullBuffer $ConflictMarkerHead) { $status = "Deformed"; $reason = "Git conflict: <<<<<<<"; $deformed = $true }
                    elseif (Find-BytesInBuffer $fullBuffer $ConflictMarkerSep) { $status = "Deformed"; $reason = "Git conflict: ======= "; $deformed = $true }
                    elseif (Find-BytesInBuffer $fullBuffer $ConflictMarkerEnd) { $status = "Deformed"; $reason = "Git conflict: >>>>>>>"; $deformed = $true }
                    elseif (-not (Test-UAssetMagicHeader $buffer)) { $status = "Deformed"; $reason = "Invalid UAsset header"; $deformed = $true }
                } catch { $status = "Error"; $reason = $_.Exception.Message; $deformed = $true }
                $null = $results.Add([PSCustomObject]@{ FullPath = $file.FullName; RelativePath = $rel; Status = $status; Reason = $reason; FileSize = $size; InGit = $inGit; Deformed = $deformed })
                if ($logWriter) { try { $logWriter.WriteLine("$status`t$rel") } catch { } }
            } catch {
                $rel = try { $file.FullName.Substring($rootAbs.Length).TrimStart('\', '/') } catch { $file.FullName }
                $null = $results.Add([PSCustomObject]@{ FullPath = $file.FullName; RelativePath = $rel; Status = "Error"; Reason = $_.Exception.Message; FileSize = ""; InGit = "No"; Deformed = $true })
                if ($logWriter) { try { $logWriter.WriteLine("Error`t$rel") } catch { } }
            }
            $ProgressSync.Count = $results.Count
        }
        if ($logWriter) { try { $logWriter.WriteLine("Scan finished at $(Get-Date -Format 'o')"); $logWriter.Close(); $logWriter.Dispose() } catch { } }
        return @(,$results), ($results | Where-Object Deformed).Count, (@($files).Count)
    }
    $ps = [powershell]::Create().AddScript($scriptBlock)
    $ps.Runspace = $runspace
    $async = $ps.BeginInvoke()
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({
        if ($async.IsCompleted) {
            $timer.Stop()
            try {
                $output = $ps.EndInvoke($async)
                $resultsGrid.ItemsSource = $output[0]
                $logNote = if ($script:ScanLogPath -and (Test-Path -LiteralPath $script:ScanLogPath)) { " Log: $script:ScanLogPath" } else { "" }
                $statusText.Text = "Found $($output[2]) .uasset file(s) under 3KB. Deformed: $($output[1])$logNote"
                $statusText.Foreground = if ($output[1] -gt 0) { [System.Windows.Media.Brushes]::Red } else { [System.Windows.Media.Brushes]::Green }
            } catch {
                $statusText.Text = "Scan failed."
                $statusText.Foreground = [System.Windows.Media.Brushes]::Red
                [System.Windows.MessageBox]::Show($_.Exception.Message, "Scan Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
            } finally {
                $ps.Dispose(); $runspace.Close()
            }
            return
        }
        $c = $progressSync.Count; $t = $progressSync.Total
        $statusText.Text = "Scanning... ($c / $t)"
    })
    $timer.Start()
})

# Start the application (reuse existing Application if script is run again in same process)
if (-not [System.Windows.Application]::Current) {
    $app = New-Object System.Windows.Application
} else {
    $app = [System.Windows.Application]::Current
}
$window.Show()
$app.Run($window)
