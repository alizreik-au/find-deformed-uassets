Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms

# Default scan root: current directory or first argument
$script:ScanRoot = if ($args[0]) { $args[0] } else { Get-Location | Select-Object -ExpandProperty Path }

# Load core logic (variables and functions used by GUI and by tests)
. (Join-Path (Split-Path -Path $PSCommandPath -Parent) "Find-DeformedUAssetsCore.ps1")

# Scan log path (written during each scan; overwritten per run). Empty = no log file.
$script:ScanLogPath = Join-Path $env:TEMP "find-deformed-uassets-ScanLog.txt"

# Debug log (append; always written when scan runs). Set to "" to disable.
$script:DebugLogPath = Join-Path $env:TEMP "find-deformed-uassets-debug.log"
function Write-DebugLog {
    param([string]$Message)
    if (-not $script:DebugLogPath) { return }
    try {
        $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')] $Message"
        Add-Content -LiteralPath $script:DebugLogPath -Value $line -ErrorAction Stop
    } catch { }
}

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
    if ($totalCount -eq 0) {
        $StatusControl.Text = "No .uasset files (under 3KB) found - folder was searched recursively."
        $StatusControl.Foreground = [System.Windows.Media.Brushes]::Gray
    } else {
        $StatusControl.Text = "Found $totalCount .uasset file(s) under 3KB (searched recursively). Deformed: $deformedCount"
        $StatusControl.Foreground = if ($deformedCount -gt 0) {
            [System.Windows.Media.Brushes]::Red
        } else {
            [System.Windows.Media.Brushes]::Green
        }
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
    Write-DebugLog "Scan clicked. Folder: [$folder]"
    if (-not [System.IO.Directory]::Exists($folder)) {
        Write-DebugLog "Scan aborted: folder does not exist"
        [System.Windows.MessageBox]::Show("Folder does not exist: $folder", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        return
    }
    $statusText.Text = "Step 1: Preparing scan..."
    $statusText.Foreground = [System.Windows.Media.Brushes]::Orange
    Write-DebugLog "Step 1: Preparing scan..."

    $progressSync = [hashtable]::Synchronized(@{ Count = 0; Total = 0; Phase = "Preparing" })
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.Open()
    Write-DebugLog "Runspace opened"
    $runspace.SessionStateProxy.Path.SetLocation($folder) | Out-Null
    $runspace.SessionStateProxy.SetVariable("RootPath", $folder)
    $runspace.SessionStateProxy.SetVariable("DebugLogPath", $script:DebugLogPath)
    $runspace.SessionStateProxy.SetVariable("UAssetMagicBytes", $script:UAssetMagicBytes)
    $runspace.SessionStateProxy.SetVariable("ConflictMarkerHead", $script:ConflictMarkerHead)
    $runspace.SessionStateProxy.SetVariable("ConflictMarkerSep", $script:ConflictMarkerSep)
    $runspace.SessionStateProxy.SetVariable("ConflictMarkerEnd", $script:ConflictMarkerEnd)
    $runspace.SessionStateProxy.SetVariable("MaxUAssetSizeBytes", $script:MaxUAssetSizeBytes)
    $runspace.SessionStateProxy.SetVariable("ProgressSync", $progressSync)
    $runspace.SessionStateProxy.SetVariable("LogPath", $script:ScanLogPath)
    $runspace.SessionStateProxy.SetVariable("GrepPath", $script:GrepPath)

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
        function Test-FileHasConflictMarkersRunspace { param([string]$Path)
            if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
            if ($GrepPath) {
                try {
                    $proc = Start-Process -FilePath $GrepPath -ArgumentList @('-a', '-q', '-F', '-e', '<<<<<<<', '-e', '=======', '-e', '>>>>>>>', '--', $Path) -PassThru -NoNewWindow -Wait
                    return ($proc.ExitCode -eq 0)
                } catch { return $false }
                }
            try {
                $stream = [System.IO.File]::OpenRead($Path)
                try {
                    $headerSize = [Math]::Min(8192, $stream.Length)
                    $buffer = New-Object byte[] $headerSize
                    $read = $stream.Read($buffer, 0, $headerSize)
                    $fullBuffer = $buffer
                    if ($stream.Length -gt $headerSize -and $stream.Length -lt 1048576) {
                        $rest = New-Object byte[] ($stream.Length - $headerSize)
                        [void]$stream.Read($rest, 0, $rest.Length)
                        $fullBuffer = $buffer + $rest
                    }
                    $stream.Close()
                    return (Find-BytesInBuffer $fullBuffer $ConflictMarkerHead -or Find-BytesInBuffer $fullBuffer $ConflictMarkerSep -or Find-BytesInBuffer $fullBuffer $ConflictMarkerEnd)
                } finally { $stream.Close() }
            } catch { return $false }
        }
        function Test-UAssetMagicHeader { param([byte[]]$Header)
            if ($null -eq $Header -or $Header.Length -lt $UAssetMagicBytes.Length) { return $false }
            for ($i = 0; $i -lt $UAssetMagicBytes.Length; $i++) { if ($Header[$i] -ne $UAssetMagicBytes[$i]) { return $false } }
            return $true
        }
        $ProgressSync.Phase = "Step 2: Resolving path and finding git root..."
        $rootAbs = [System.IO.Path]::GetFullPath($RootPath)
        $gitRoot = $null
        try { Push-Location -LiteralPath $rootAbs; $gitRoot = (git rev-parse --show-toplevel 2>$null); Pop-Location } catch { Pop-Location -ErrorAction SilentlyContinue }
        $ProgressSync.Phase = "Step 3: Enumerating .uasset files recursively (under 3KB)..."
        $files = @(Get-ChildItem -LiteralPath $rootAbs -Filter "*.uasset" -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\Intermediate\\' -and $_.FullName -notmatch '\\Saved\\' -and $_.Length -le $MaxUAssetSizeBytes })
        $ProgressSync.Phase = "Step 4: Scanning files..."
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
                    if (Test-FileHasConflictMarkersRunspace $file.FullName) { $status = "Deformed"; $reason = "Git conflict markers (grep)"; $deformed = $true }
                    else {
                        $stream = [System.IO.File]::OpenRead($file.FullName)
                        $headerSize = [Math]::Min(8192, $stream.Length)
                        $buffer = New-Object byte[] $headerSize
                        [void]$stream.Read($buffer, 0, $headerSize)
                        $stream.Close()
                        if (-not (Test-UAssetMagicHeader $buffer)) { $status = "Deformed"; $reason = "Invalid UAsset header"; $deformed = $true }
                    }
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
        DLog "Runspace done. results.Count=$($results.Count)"
        return @(,$results), ($results | Where-Object Deformed).Count, (@($files).Count)
    }

    $ps = [powershell]::Create().AddScript($scriptBlock)
    $ps.Runspace = $runspace
    Write-DebugLog "Calling BeginInvoke..."
    $async = $ps.BeginInvoke()
    Write-DebugLog "BeginInvoke returned, starting timer"

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({
        $phase = $progressSync.Phase
        $c = $progressSync.Count; $t = $progressSync.Total
        Write-DebugLog "Tick: IsCompleted=$($async.IsCompleted) Phase=$phase Count=$c Total=$t"
        if ($async.IsCompleted) {
            $timer.Stop()
            Write-DebugLog "Async completed, calling EndInvoke..."
            try {
                $output = $ps.EndInvoke($async)
                $items = $output[0]
                $deformedCount = $output[1]
                $totalCount = $output[2]
                Write-DebugLog "EndInvoke OK. totalCount=$totalCount deformedCount=$deformedCount"
                $resultsGrid.ItemsSource = $items
                $logNote = if ($script:ScanLogPath -and (Test-Path -LiteralPath $script:ScanLogPath)) { " Log: $script:ScanLogPath" } else { "" }
                if ($totalCount -eq 0) {
                    $statusText.Text = "Done. No .uasset files (under 3KB) found - folder was searched recursively.$logNote"
                    $statusText.Foreground = [System.Windows.Media.Brushes]::Gray
                    Write-DebugLog "Status set (0 files). Showing MessageBox."
                    [System.Windows.MessageBox]::Show("Scan complete. No .uasset files (under 3KB) were found in the selected folder or its subfolders. Only files under 3KB are scanned.", "Nothing found", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
                } else {
                    $statusText.Text = "Step 5: Done. Found $totalCount .uasset file(s) under 3KB (searched recursively). Deformed: $deformedCount$logNote"
                    $statusText.Foreground = if ($deformedCount -gt 0) { [System.Windows.Media.Brushes]::Red } else { [System.Windows.Media.Brushes]::Green }
                    Write-DebugLog "Status set ($totalCount files, $deformedCount deformed)."
                }
            } catch {
                Write-DebugLog "EndInvoke threw: $($_.Exception.Message)"
                $statusText.Text = "Scan failed."
                $statusText.Foreground = [System.Windows.Media.Brushes]::Red
                [System.Windows.MessageBox]::Show($_.Exception.Message, "Scan Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
            } finally {
                $ps.Dispose(); $runspace.Close()
                Write-DebugLog "Disposed runspace and PS."
            }
            return
        }
        if ($phase -match "Step 4" -and $t -gt 0) {
            $statusText.Text = "$phase ($c / $t)"
        } else {
            $statusText.Text = $phase
        }
    })
    $timer.Start()
    Write-DebugLog "Timer started. Debug log: $script:DebugLogPath"
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
    Write-DebugLog "Refresh clicked. Folder: [$folder]"
    if (-not [System.IO.Directory]::Exists($folder)) {
        [System.Windows.MessageBox]::Show("Folder does not exist: $folder", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        return
    }
    $statusText.Text = "Step 1: Preparing scan..."
    $statusText.Foreground = [System.Windows.Media.Brushes]::Orange
    $progressSync = [hashtable]::Synchronized(@{ Count = 0; Total = 0; Phase = "Preparing" })
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.Open()
    $runspace.SessionStateProxy.Path.SetLocation($folder) | Out-Null
    $runspace.SessionStateProxy.SetVariable("RootPath", $folder)
    $runspace.SessionStateProxy.SetVariable("DebugLogPath", $script:DebugLogPath)
    $runspace.SessionStateProxy.SetVariable("UAssetMagicBytes", $script:UAssetMagicBytes)
    $runspace.SessionStateProxy.SetVariable("ConflictMarkerHead", $script:ConflictMarkerHead)
    $runspace.SessionStateProxy.SetVariable("ConflictMarkerSep", $script:ConflictMarkerSep)
    $runspace.SessionStateProxy.SetVariable("ConflictMarkerEnd", $script:ConflictMarkerEnd)
    $runspace.SessionStateProxy.SetVariable("MaxUAssetSizeBytes", $script:MaxUAssetSizeBytes)
    $runspace.SessionStateProxy.SetVariable("ProgressSync", $progressSync)
    $runspace.SessionStateProxy.SetVariable("LogPath", $script:ScanLogPath)
    $runspace.SessionStateProxy.SetVariable("GrepPath", $script:GrepPath)
    $scriptBlock = {
        function DLog { param([string]$Msg) if ($DebugLogPath) { try { Add-Content -LiteralPath $DebugLogPath -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')] [RS] $Msg" -ErrorAction Stop } catch { } } }
        DLog "Runspace script started (Refresh). RootPath=$RootPath"
        function Find-BytesInBuffer { param([byte[]]$Buffer,[byte[]]$Search)
            if ($null -eq $Buffer -or $null -eq $Search -or $Search.Length -eq 0 -or $Buffer.Length -lt $Search.Length) { return $false }
            for ($i = 0; $i -le ($Buffer.Length - $Search.Length); $i++) {
                $match = $true
                for ($j = 0; $j -lt $Search.Length; $j++) { if ($Buffer[$i + $j] -ne $Search[$j]) { $match = $false; break } }
                if ($match) { return $true }
            }
            return $false
        }
        function Test-FileHasConflictMarkersRunspace { param([string]$Path)
            if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
            if ($GrepPath) {
                try {
                    $proc = Start-Process -FilePath $GrepPath -ArgumentList @('-a', '-q', '-F', '-e', '<<<<<<<', '-e', '=======', '-e', '>>>>>>>', '--', $Path) -PassThru -NoNewWindow -Wait
                    return ($proc.ExitCode -eq 0)
                } catch { return $false }
                }
            try {
                $stream = [System.IO.File]::OpenRead($Path)
                try {
                    $headerSize = [Math]::Min(8192, $stream.Length)
                    $buffer = New-Object byte[] $headerSize
                    $read = $stream.Read($buffer, 0, $headerSize)
                    $fullBuffer = $buffer
                    if ($stream.Length -gt $headerSize -and $stream.Length -lt 1048576) {
                        $rest = New-Object byte[] ($stream.Length - $headerSize)
                        [void]$stream.Read($rest, 0, $rest.Length)
                        $fullBuffer = $buffer + $rest
                    }
                    $stream.Close()
                    return (Find-BytesInBuffer $fullBuffer $ConflictMarkerHead -or Find-BytesInBuffer $fullBuffer $ConflictMarkerSep -or Find-BytesInBuffer $fullBuffer $ConflictMarkerEnd)
                } finally { $stream.Close() }
            } catch { return $false }
        }
        function Test-UAssetMagicHeader { param([byte[]]$Header)
            if ($null -eq $Header -or $Header.Length -lt $UAssetMagicBytes.Length) { return $false }
            for ($i = 0; $i -lt $UAssetMagicBytes.Length; $i++) { if ($Header[$i] -ne $UAssetMagicBytes[$i]) { return $false } }
            return $true
        }
        $ProgressSync.Phase = "Step 2: Resolving path and finding git root..."
        $rootAbs = [System.IO.Path]::GetFullPath($RootPath)
        DLog "rootAbs=$rootAbs"
        $gitRoot = $null
        try { Push-Location -LiteralPath $rootAbs; $gitRoot = (git rev-parse --show-toplevel 2>$null); Pop-Location } catch { Pop-Location -ErrorAction SilentlyContinue }
        $ProgressSync.Phase = "Step 3: Enumerating .uasset files recursively (under 3KB)..."
        $files = @(Get-ChildItem -LiteralPath $rootAbs -Filter "*.uasset" -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\Intermediate\\' -and $_.FullName -notmatch '\\Saved\\' -and $_.Length -le $MaxUAssetSizeBytes })
        DLog "files.Count=$($files.Count)"
        $ProgressSync.Phase = "Step 4: Scanning files..."
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
                    if (Test-FileHasConflictMarkersRunspace $file.FullName) { $status = "Deformed"; $reason = "Git conflict markers (grep)"; $deformed = $true }
                    else {
                        $stream = [System.IO.File]::OpenRead($file.FullName)
                        $headerSize = [Math]::Min(8192, $stream.Length)
                        $buffer = New-Object byte[] $headerSize
                        [void]$stream.Read($buffer, 0, $headerSize)
                        $stream.Close()
                        if (-not (Test-UAssetMagicHeader $buffer)) { $status = "Deformed"; $reason = "Invalid UAsset header"; $deformed = $true }
                    }
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
        DLog "Runspace done (Refresh). results.Count=$($results.Count)"
        return @(,$results), ($results | Where-Object Deformed).Count, (@($files).Count)
    }
    $ps = [powershell]::Create().AddScript($scriptBlock)
    $ps.Runspace = $runspace
    $async = $ps.BeginInvoke()
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({
        $phase = $progressSync.Phase
        $c = $progressSync.Count; $t = $progressSync.Total
        Write-DebugLog "Tick(Refresh): IsCompleted=$($async.IsCompleted) Phase=$phase Count=$c Total=$t"
        if ($async.IsCompleted) {
            $timer.Stop()
            Write-DebugLog "Refresh async completed, calling EndInvoke..."
            try {
                $output = $ps.EndInvoke($async)
                $resultsGrid.ItemsSource = $output[0]
                $totalCount = $output[2]
                $deformedCount = $output[1]
                Write-DebugLog "Refresh EndInvoke OK. totalCount=$totalCount deformedCount=$deformedCount"
                $logNote = if ($script:ScanLogPath -and (Test-Path -LiteralPath $script:ScanLogPath)) { " Log: $script:ScanLogPath" } else { "" }
                if ($totalCount -eq 0) {
                    $statusText.Text = "Done. No .uasset files (under 3KB) found. Folder was searched recursively.$logNote"
                    $statusText.Foreground = [System.Windows.Media.Brushes]::Gray
                    [System.Windows.MessageBox]::Show("Scan complete. No .uasset files (under 3KB) were found in the selected folder or its subfolders. Only files under 3KB are scanned.", "Nothing found", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
                } else {
                    $statusText.Text = "Step 5: Done. Found $totalCount .uasset file(s) under 3KB (searched recursively). Deformed: $deformedCount$logNote"
                    $statusText.Foreground = if ($deformedCount -gt 0) { [System.Windows.Media.Brushes]::Red } else { [System.Windows.Media.Brushes]::Green }
                }
            } catch {
                Write-DebugLog "Refresh EndInvoke threw: $($_.Exception.Message)"
                $statusText.Text = "Scan failed."
                $statusText.Foreground = [System.Windows.Media.Brushes]::Red
                [System.Windows.MessageBox]::Show($_.Exception.Message, "Scan Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
            } finally {
                $ps.Dispose(); $runspace.Close()
            }
            return
        }
        if ($phase -match "Step 4" -and $t -gt 0) {
            $statusText.Text = "$phase ($c / $t)"
        } else {
            $statusText.Text = $phase
        }
    })
    $timer.Start()
    Write-DebugLog "Refresh timer started."
})

# Start the application (reuse existing Application if script is run again in same process)
if (-not [System.Windows.Application]::Current) {
    $app = New-Object System.Windows.Application
} else {
    $app = [System.Windows.Application]::Current
}
$window.Show()
$app.Run($window)
