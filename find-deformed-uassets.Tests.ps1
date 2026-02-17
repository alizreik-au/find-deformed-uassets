# Pester tests for Find Deformed .uasset logic (core script only; no GUI).
# Run: Invoke-Pester -Script .\find-deformed-uassets.Tests.ps1

$scriptDir = Split-Path -Path $PSCommandPath -Parent
. (Join-Path $scriptDir "Find-DeformedUAssetsCore.ps1")

Describe "Find-BytesInBuffer" {
    It "returns false when Buffer is null" {
        Find-BytesInBuffer -Buffer $null -Search @(1, 2, 3) | Should Be $false
    }
    It "returns false when Search is null" {
        Find-BytesInBuffer -Buffer @(1, 2, 3) -Search $null | Should Be $false
    }
    It "returns false when Search is empty" {
        Find-BytesInBuffer -Buffer @(1, 2, 3) -Search @() | Should Be $false
    }
    It "returns false when Buffer is shorter than Search" {
        Find-BytesInBuffer -Buffer @(1, 2) -Search @(1, 2, 3) | Should Be $false
    }
    It "returns true when Search appears at start of Buffer" {
        $buf = [byte[]]@(1, 2, 3, 4, 5)
        $search = [byte[]]@(1, 2, 3)
        Find-BytesInBuffer -Buffer $buf -Search $search | Should Be $true
    }
    It "returns true when Search appears in middle of Buffer" {
        $buf = [byte[]]@(0, 0, 1, 2, 3, 0, 0)
        $search = [byte[]]@(1, 2, 3)
        Find-BytesInBuffer -Buffer $buf -Search $search | Should Be $true
    }
    It "returns true when Search appears at end of Buffer" {
        $buf = [byte[]]@(0, 0, 1, 2, 3)
        $search = [byte[]]@(1, 2, 3)
        Find-BytesInBuffer -Buffer $buf -Search $search | Should Be $true
    }
    It "returns false when Search is not in Buffer" {
        $buf = [byte[]]@(1, 2, 4, 5, 6)
        $search = [byte[]]@(1, 2, 3)
        Find-BytesInBuffer -Buffer $buf -Search $search | Should Be $false
    }
    It "finds ASCII conflict marker in byte buffer" {
        $ascii = [System.Text.Encoding]::ASCII
        $buf = $ascii.GetBytes("hello <<<<<<< world")
        $search = $ascii.GetBytes("<<<<<<<")
        Find-BytesInBuffer -Buffer $buf -Search $search | Should Be $true
    }
}

Describe "Test-UAssetMagicHeader" {
    $validMagic = [byte[]]@(0xC1, 0x83, 0x2A, 0x9E)
    It "returns true for valid UAsset magic bytes" {
        Test-UAssetMagicHeader -Header $validMagic | Should Be $true
    }
    It "returns true when header is longer than magic (extra bytes after)" {
        $longHeader = $validMagic + [byte[]]@(0, 0, 0)
        Test-UAssetMagicHeader -Header $longHeader | Should Be $true
    }
    It "returns false when Header is null" {
        Test-UAssetMagicHeader -Header $null | Should Be $false
    }
    It "returns false when Header is too short" {
        Test-UAssetMagicHeader -Header @(0xC1, 0x83) | Should Be $false
    }
    It "returns false when first byte is wrong" {
        $bad = [byte[]]@(0xC0, 0x83, 0x2A, 0x9E)
        Test-UAssetMagicHeader -Header $bad | Should Be $false
    }
    It "returns false when last byte is wrong" {
        $bad = [byte[]]@(0xC1, 0x83, 0x2A, 0x9F)
        Test-UAssetMagicHeader -Header $bad | Should Be $false
    }
}

Describe "Test-FileHasConflictMarkers" {
    It "returns false for null or empty path" {
        Test-FileHasConflictMarkers -FilePath $null | Should Be $false
        Test-FileHasConflictMarkers -FilePath "" | Should Be $false
    }
    It "returns false for non-existent file" {
        Test-FileHasConflictMarkers -FilePath "C:\Nonexistent\file.uasset" | Should Be $false
    }
    It "returns false for file without conflict markers" {
        $path = Join-Path $TestDrive "clean.uasset"
        [System.IO.File]::WriteAllBytes($path, [byte[]]@(0xC1, 0x83, 0x2A, 0x9E, 0, 0, 0, 0))
        Test-FileHasConflictMarkers -FilePath $path | Should Be $false
    }
    It "returns true for file containing <<<<<<<" {
        $path = Join-Path $TestDrive "conflict.uasset"
        [System.IO.File]::WriteAllText($path, "text <<<<<<< HEAD more", [System.Text.Encoding]::ASCII)
        Test-FileHasConflictMarkers -FilePath $path | Should Be $true
    }
    It "returns true for file containing =======" {
        $path = Join-Path $TestDrive "conflict2.uasset"
        [System.IO.File]::WriteAllText($path, "=======", [System.Text.Encoding]::ASCII)
        Test-FileHasConflictMarkers -FilePath $path | Should Be $true
    }
    It "returns true for file containing >>>>>>>" {
        $path = Join-Path $TestDrive "conflict3.uasset"
        [System.IO.File]::WriteAllText($path, ">>>>>>> branch", [System.Text.Encoding]::ASCII)
        Test-FileHasConflictMarkers -FilePath $path | Should Be $true
    }
}

Describe "Get-UAssetHealth" {
    It "returns Error for non-existent file" {
        $r = Get-UAssetHealth -FullPath "C:\Nonexistent\a.uasset" -RelativePath "a.uasset" -GitRoot $null
        $r.Status | Should Be "Error"
        $r.Reason | Should Be "File not found"
        $r.Deformed | Should Be $true
    }
    It "returns OK and Valid for file with valid UAsset magic and no conflict markers" {
        $path = Join-Path $TestDrive "valid.uasset"
        $header = [byte[]]@(0xC1, 0x83, 0x2A, 0x9E) + (, 0 * 100)
        [System.IO.File]::WriteAllBytes($path, $header)
        $r = Get-UAssetHealth -FullPath $path -RelativePath "valid.uasset" -GitRoot $null
        $r.Status | Should Be "OK"
        $r.Reason | Should Be "Valid"
        $r.Deformed | Should Be $false
        $r.FileSize | Should Not Be ""
    }
    It "returns Deformed for file with conflict markers" {
        $path = Join-Path $TestDrive "deformed.uasset"
        [System.IO.File]::WriteAllText($path, "<<<<<<< HEAD", [System.Text.Encoding]::ASCII)
        $r = Get-UAssetHealth -FullPath $path -RelativePath "deformed.uasset" -GitRoot $null
        $r.Status | Should Be "Deformed"
        $r.Reason | Should Match "conflict"
        $r.Deformed | Should Be $true
    }
    It "returns Deformed for file with invalid magic (not UAsset)" {
        $path = Join-Path $TestDrive "badmagic.uasset"
        [System.IO.File]::WriteAllBytes($path, [byte[]]@(0, 0, 0, 0, 1, 2, 3, 4))
        $r = Get-UAssetHealth -FullPath $path -RelativePath "badmagic.uasset" -GitRoot $null
        $r.Status | Should Be "Deformed"
        $r.Reason | Should Match "magic"
        $r.Deformed | Should Be $true
    }
    It "sets RelativePath and FileSize on result" {
        $path = Join-Path $TestDrive "rel.uasset"
        [System.IO.File]::WriteAllBytes($path, [byte[]]@(0xC1, 0x83, 0x2A, 0x9E))
        $r = Get-UAssetHealth -FullPath $path -RelativePath "sub\rel.uasset" -GitRoot $null
        $r.RelativePath | Should Be "sub\rel.uasset"
        $r.FileSize | Should Be "4 bytes"
    }
}

Describe "Invoke-ScanUAssets" {
    It "returns empty list and null git root for folder with no .uasset files" -Skip {
        $emptyDir = [System.IO.Path]::GetFullPath((Join-Path $scriptDir "TestRun_Empty_$(New-Guid)"))
        New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
        try {
            $result = Invoke-ScanUAssets -RootPath $emptyDir
            $items = $result[0]
            $gitRoot = $result[1]
            $items.Count | Should Be 0
            $gitRoot | Should Be $null
        } finally {
            Remove-Item -LiteralPath $emptyDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    It "finds and reports .uasset files under 3KB" {
        $sub = Join-Path $TestDrive "Content_$(New-Guid)"
        New-Item -ItemType Directory -Path $sub -Force | Out-Null
        $path = Join-Path $sub "Asset.uasset"
        [System.IO.File]::WriteAllBytes($path, [byte[]]@(0xC1, 0x83, 0x2A, 0x9E))
        $result = Invoke-ScanUAssets -RootPath $sub
        $items = $result[0]
        $items.Count | Should Be 1
        $items[0].RelativePath | Should Match "Asset\.uasset"
        $items[0].Status | Should Be "OK"
    }
    It "excludes .uasset files over 3KB (by size filter)" {
        $bigDir = Join-Path $TestDrive "BigDir_$(New-Guid)"
        New-Item -ItemType Directory -Path $bigDir -Force | Out-Null
        $path = Join-Path $bigDir "Big.uasset"
        $big = [byte[]]::new(4000)
        $big[0] = 0xC1; $big[1] = 0x83; $big[2] = 0x2A; $big[3] = 0x9E
        [System.IO.File]::WriteAllBytes($path, $big)
        $result = Invoke-ScanUAssets -RootPath $bigDir
        $items = $result[0]
        ($items | Where-Object { $_.RelativePath -match "Big\.uasset" }).Count | Should Be 0
    }
    It "excludes Intermediate and Saved paths" {
        $excludeDir = Join-Path $TestDrive "Exclude_$(New-Guid)"
        New-Item -ItemType Directory -Path (Join-Path $excludeDir "Intermediate") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $excludeDir "Saved") -Force | Out-Null
        $inter = Join-Path $excludeDir "Intermediate\Asset.uasset"
        $saved = Join-Path $excludeDir "Saved\Asset.uasset"
        New-Item -ItemType File -Path $inter -Force | Out-Null
        New-Item -ItemType File -Path $saved -Force | Out-Null
        [System.IO.File]::WriteAllBytes($inter, [byte[]]@(0xC1, 0x83, 0x2A, 0x9E))
        [System.IO.File]::WriteAllBytes($saved, [byte[]]@(0xC1, 0x83, 0x2A, 0x9E))
        $result = Invoke-ScanUAssets -RootPath $excludeDir
        $items = $result[0]
        ($items | Where-Object { $_.RelativePath -match "Intermediate" }).Count | Should Be 0
        ($items | Where-Object { $_.RelativePath -match "Saved" }).Count | Should Be 0
    }
    It "returns both OK and Deformed in mixed folder" -Skip {
        $mixedDir = [System.IO.Path]::GetFullPath((Join-Path $scriptDir "TestRun_Mixed_$(New-Guid)"))
        New-Item -ItemType Directory -Path $mixedDir -Force | Out-Null
        try {
            $okPath = Join-Path $mixedDir "Ok.uasset"
            $badPath = Join-Path $mixedDir "Bad.uasset"
            [System.IO.File]::WriteAllBytes($okPath, [byte[]]@(0xC1, 0x83, 0x2A, 0x9E))
            [System.IO.File]::WriteAllText($badPath, "<<<<<<<", [System.Text.Encoding]::ASCII)
            $result = Invoke-ScanUAssets -RootPath $mixedDir
            $items = $result[0]
            $items.Count | Should Be 2
            ($items | Where-Object { $_.Status -eq "OK" }).Count | Should Be 1
            ($items | Where-Object { $_.Status -eq "Deformed" }).Count | Should Be 1
        } finally {
            Remove-Item -LiteralPath $mixedDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
