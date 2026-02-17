# Core logic for Find Deformed .uasset Files (no GUI).
# Dot-source this file to get variables and functions; used by the main script and by tests.

# UAsset magic signature (little-endian): 0x9E2A83C1
$script:UAssetMagicBytes = [byte[]]@(0xC1, 0x83, 0x2A, 0x9E)

# Git conflict marker byte sequences (ASCII)
$script:ConflictMarkerHead = [System.Text.Encoding]::ASCII.GetBytes("<<<<<<<")
$script:ConflictMarkerSep = [System.Text.Encoding]::ASCII.GetBytes("=======")
$script:ConflictMarkerEnd = [System.Text.Encoding]::ASCII.GetBytes(">>>>>>>")

# Prefer grep (e.g. Git for Windows) or ripgrep for conflict-marker search; fallback = byte scan
$script:GrepPath = $null
foreach ($cmd in @('grep', 'rg')) {
    $exe = Get-Command $cmd -ErrorAction SilentlyContinue
    if ($exe) { $script:GrepPath = $exe.Source; break }
}

# Only scan .uasset files at or below this size (bytes).
$script:MaxUAssetSizeBytes = 3072   # 3KB

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

# Returns true if file contains any Git conflict marker (<<<<<<<, =======, >>>>>>>). Uses grep/rg when available.
function Test-FileHasConflictMarkers {
    param ([string]$FilePath)

    if (-not $FilePath -or -not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        return $false
    }

    if ($script:GrepPath) {
        try {
            $proc = Start-Process -FilePath $script:GrepPath -ArgumentList @('-a', '-q', '-F', '-e', '<<<<<<<', '-e', '=======', '-e', '>>>>>>>', '--', $FilePath) -PassThru -NoNewWindow -Wait
            return ($proc.ExitCode -eq 0)
        } catch {
            return $false
        }
    }

    # Fallback: byte scan
    try {
        $stream = [System.IO.File]::OpenRead($FilePath)
        try {
            $headerSize = [Math]::Min(8192, $stream.Length)
            $buffer = New-Object byte[] $headerSize
            $read = $stream.Read($buffer, 0, $headerSize)
            $fullBuffer = $buffer[0..($read - 1)]
            if ($stream.Length -gt $headerSize -and $stream.Length -lt 1024 * 1024) {
                $rest = New-Object byte[] ($stream.Length - $read)
                $stream.Read($rest, 0, $rest.Length) | Out-Null
                $fullBuffer = $fullBuffer + $rest
            }
            $hasHead = Find-BytesInBuffer -Buffer $fullBuffer -Search $script:ConflictMarkerHead
            $hasSep  = Find-BytesInBuffer -Buffer $fullBuffer -Search $script:ConflictMarkerSep
            $hasEnd  = Find-BytesInBuffer -Buffer $fullBuffer -Search $script:ConflictMarkerEnd
            return ($hasHead -or $hasSep -or $hasEnd)
        } finally {
            $stream.Close()
        }
    } catch {
        return $false
    }
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

# Analyze a single .uasset file: returns [PSCustomObject] with Status, Reason, FileSize, InGit, FullPath, RelativePath, Deformed
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
        Deformed     = $false
    }

    if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) {
        $result.Status = "Error"
        $result.Reason = "File not found"
        $result.Deformed = $true
        return $result
    }

    $fileInfo = Get-Item -LiteralPath $FullPath
    $result.FileSize = "{0:N0} bytes" -f $fileInfo.Length

    if ($GitRoot) {
        $relForGit = $FullPath.Substring($GitRoot.Length).TrimStart('\', '/').Replace('\', '/')
        try {
            $null = git ls-files --error-unmatch -- $relForGit 2>$null
            $result.InGit = "Yes"
        } catch {
            $result.InGit = "No"
        }
    }

    if (Test-FileHasConflictMarkers -FilePath $FullPath) {
        $result.Status = "Deformed"
        $result.Reason = "Git merge conflict markers (<<<<<<< / ======= / >>>>>>>)"
        $result.Deformed = $true
        return $result
    }

    try {
        $stream = [System.IO.File]::OpenRead($FullPath)
        try {
            $headerSize = [Math]::Min(8192, $stream.Length)
            $buffer = New-Object byte[] $headerSize
            [void]$stream.Read($buffer, 0, $headerSize)

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

# Scan folder for .uasset files and return list of health results. Returns @(,$results), $gitRoot
function Invoke-ScanUAssets {
    param ([string]$RootPath)

    $rootAbs = [System.IO.Path]::GetFullPath($RootPath)
    $gitRoot = $null
    try {
        Push-Location -LiteralPath $rootAbs
        $gitRoot = (git rev-parse --show-toplevel 2>$null)
        if (-not $gitRoot) { $gitRoot = $null }
        Pop-Location
    } catch {
        Pop-Location -ErrorAction SilentlyContinue
    }

    $uassetFiles = Get-ChildItem -LiteralPath $rootAbs -Filter "*.uasset" -Recurse -File -ErrorAction SilentlyContinue |
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

    return @(,$results), $gitRoot
}
