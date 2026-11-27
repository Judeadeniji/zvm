# Installer for zvm (Zig Version Manager) on Windows PowerShell.
# Usage:
#   irm https://raw.githubusercontent.com/Judeadeniji/zvm/main/install.ps1 | iex

$ErrorActionPreference = "Stop"

$Repo = "Judeadeniji/zvm"
$InstallDir = if ($env:ZVM_INSTALL_DIR) { $env:ZVM_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA "zvm\bin" }
$Version = if ($env:ZVM_VERSION) { $env:ZVM_VERSION } else { "latest" }

if ($Version -eq "latest") {
    $Release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ "User-Agent" = "zvm-installer" }
    $Tag = $Release.tag_name
} elseif ($Version -eq "nightly") {
    $Releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases?per_page=30" -Headers @{ "User-Agent" = "zvm-installer" }
    $Nightly = $Releases | Where-Object { $_.prerelease -and -not $_.draft -and $_.tag_name -like "*nightly*" } | Select-Object -First 1
    if (-not $Nightly) {
        throw "Failed to find a nightly zvm release"
    }
    $Tag = $Nightly.tag_name
} else {
    $Tag = $Version
}

$Archive = "zvm-$Tag-x86_64-windows.zip"
$BaseUrl = "https://github.com/$Repo/releases/download/$Tag"

$TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("zvm-install-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TmpDir | Out-Null

try {
    $ArchivePath = Join-Path $TmpDir $Archive
    Write-Host "Downloading zvm $Tag (x86_64-windows)..."
    Invoke-WebRequest -Uri "$BaseUrl/$Archive" -OutFile $ArchivePath

    try {
        $SumsPath = Join-Path $TmpDir "SHA256SUMS.txt"
        Invoke-WebRequest -Uri "$BaseUrl/SHA256SUMS.txt" -OutFile $SumsPath
        $Line = Get-Content $SumsPath | Where-Object { $_ -match [regex]::Escape($Archive) + '$' } | Select-Object -First 1
        if ($Line) {
            $Expected = ($Line -split '\s+')[0].ToLowerInvariant()
            $Actual = (Get-FileHash -Path $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($Actual -ne $Expected) {
                throw "SHA-256 mismatch for $Archive"
            }
            Write-Host "SHA-256 verified."
        }
    } catch [System.Net.WebException] {
        # Ignore if SHA256SUMS.txt is absent
    }

    $ExtractDir = Join-Path $TmpDir "extract"
    Expand-Archive -Path $ArchivePath -DestinationPath $ExtractDir -Force
    $Exe = Get-ChildItem -Path $ExtractDir -Recurse -Filter "zvm.exe" | Select-Object -First 1
    if (-not $Exe) {
        throw "zvm.exe not found in archive"
    }

    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Copy-Item -Path $Exe.FullName -Destination (Join-Path $InstallDir "zvm.exe") -Force

    $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($UserPath -notlike "*$InstallDir*") {
        $NewPath = if ($UserPath) { "$InstallDir;$UserPath" } else { $InstallDir }
        [Environment]::SetEnvironmentVariable("Path", $NewPath, "User")
        $env:Path = "$InstallDir;$env:Path"
        Write-Host "Added $InstallDir to your User PATH."
    }

    Write-Host "Installed zvm to $(Join-Path $InstallDir 'zvm.exe')"
    Write-Host "Next: run 'zvm setup' to create the zig/zls shims."
} finally {
    Remove-Item -Path $TmpDir -Recurse -Force -ErrorAction SilentlyContinue
}
