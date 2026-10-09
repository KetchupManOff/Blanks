# Assembles the open-files Windows x64 release of Tetris Yank Edition.
#
# Output (Exports/<Name>/):
#   <Name>.exe + <Name>.pck   engine and game code (pck kept beside the exe)
#   music/  sfx/  themes/      plain, player-editable files
#   MODDING.md                 how to edit the above
# Plus Exports/<Name>.zip containing the same folder.
#
# Usage:
#   .\package_release.ps1
#   .\package_release.ps1 -Godot "C:\path\to\Godot_v4.7.2-stable_win64.exe" -Name "TetrisYankEdition-1.0.0"

param(
    # Use the _console.exe build: it is a console-subsystem binary, so
    # PowerShell waits for it and $LASTEXITCODE reports the real exit
    # code. The plain win64.exe is a GUI-subsystem binary that detaches
    # immediately, breaking import/export sequencing.
    [string]$Godot = "$env:LOCALAPPDATA\Programs\Godot\Godot_v4.7.2-stable_win64_console.exe",
    [string]$Preset = "Windows Desktop",
    [string]$Name = "TetrisYankEdition",
    [string]$OutDir = "Exports"
)

$ErrorActionPreference = "Stop"
$project = $PSScriptRoot

if (-not (Test-Path -LiteralPath $Godot)) {
    throw "Godot executable not found: '$Godot'. Pass -Godot with the path to your Godot editor executable."
}

# Keep Godot's import scan away from the release output: a .gdignore marker
# makes the editor skip the Exports/ tree entirely, so packaged copies of
# the music/sfx/theme files are never re-imported as project resources (no
# UID-duplicate warnings, no stray .import files in releases, fast imports).
$exportsDir = Join-Path $project $OutDir
if (-not (Test-Path -LiteralPath $exportsDir)) {
    New-Item -ItemType Directory -Path $exportsDir | Out-Null
}
$gdignore = Join-Path $exportsDir ".gdignore"
if (-not (Test-Path -LiteralPath $gdignore)) {
    New-Item -ItemType File -Path $gdignore | Out-Null
}

Write-Host "1/4 Importing project..."
& $Godot --headless --path $project --import

Write-Host "2/4 Exporting preset '$Preset'..."
$package = Join-Path $project (Join-Path $OutDir $Name)
if (Test-Path -LiteralPath $package) {
    Remove-Item -Recurse -Force -LiteralPath $package
}
New-Item -ItemType Directory -Path $package | Out-Null
# Export straight into the package folder: the PCK (and, when enabled in
# the preset, the console wrapper) land beside the executable there, so
# no duplicate executables are left in the output root.
$exePath = Join-Path $package "$Name.exe"
& $Godot --headless --path $project --export-release $Preset $exePath
if ($LASTEXITCODE -ne 0) {
    throw "Godot export failed with exit code $LASTEXITCODE."
}

$pckPath = [System.IO.Path]::ChangeExtension($exePath, ".pck")
if (-not (Test-Path -LiteralPath $pckPath)) {
    throw "Expected PCK beside the executable: '$pckPath' (binary_format/embed_pck is disabled in the preset)."
}

Write-Host "3/4 Assembling open-files package..."

function Copy-GameContent {
    param([string]$SourceDir, [string]$TargetDir)
    # Copy the raw content files only: .import/.uid are Godot project
    # metadata living beside the sources and must not ship in the release.
    # The copy is recursive and mirrors subfolder structure, so theme
    # asset folders (themes/assets/...) ship next to their .theme files.
    New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    Get-ChildItem -LiteralPath $SourceDir -Recurse -File |
        Where-Object { $_.Extension -ne ".import" -and $_.Extension -ne ".uid" } |
        ForEach-Object {
            $relative = $_.FullName.Substring($SourceDir.Length).TrimStart('\', '/')
            $destination = Join-Path $TargetDir $relative
            $destinationDir = Split-Path -Parent $destination
            if (-not (Test-Path -LiteralPath $destinationDir)) {
                New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
            }
            Copy-Item -LiteralPath $_.FullName -Destination $destination
        }
}

Copy-GameContent (Join-Path $project "audio\music") (Join-Path $package "music")
Copy-GameContent (Join-Path $project "audio\sfx") (Join-Path $package "sfx")
Copy-GameContent (Join-Path $project "themes") (Join-Path $package "themes")
Copy-Item -LiteralPath (Join-Path $project "docs\MODDING.md") -Destination $package

Write-Host "4/4 Zipping..."
$zipPath = Join-Path $project (Join-Path $OutDir "$Name.zip")
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -Force -LiteralPath $zipPath
}

# Windows briefly locks a freshly exported .exe (antivirus, search indexer,
# Explorer preview, ...) and Compress-Archive then fails on a complete package
# folder. Retry that specific failure class for a bounded time; any other
# archive error is a real problem and still fails immediately.
function Test-ArchiveLockError {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)
    # ERROR_SHARING_VIOLATION (0x80070020) / ERROR_LOCK_VIOLATION
    # (0x80070021), possibly wrapped in outer exceptions; also match the
    # canonical "in use" message for locks that surface differently.
    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        if ($exception.HResult -eq 0x80070020 -or $exception.HResult -eq 0x80070021) {
            return $true
        }
        if ($exception.Message -match "being used by another process") {
            return $true
        }
        $exception = $exception.InnerException
    }
    return $false
}

# Retry for up to 30 seconds: a short-lived lock resolves on its own, and a
# persistent one must cost only the zip artifact, never the exported folder.
$zipRetryDeadline = [DateTime]::UtcNow.AddSeconds(30)
$zipAttempt = 0
while ($true) {
    $zipAttempt++
    try {
        Compress-Archive -Path $package -DestinationPath $zipPath
        break
    }
    catch {
        if (-not (Test-ArchiveLockError $_)) {
            throw
        }
        # A failed pass can leave a truncated zip: drop it so no partial
        # archive is mistaken for a release and the next attempt starts clean.
        if (Test-Path -LiteralPath $zipPath) {
            Remove-Item -Force -LiteralPath $zipPath
        }
        if ([DateTime]::UtcNow -ge $zipRetryDeadline) {
            throw ("Could not create '$zipPath' within 30 seconds: the exported files were still " +
                   "in use by another process. The unzipped package remains available at '$package' " +
                   "for manual distribution or zipping. Last error: $($_.Exception.Message)")
        }
        Write-Host "  Zip attempt ${zipAttempt}: exported files still in use by another process; retrying..."
        Start-Sleep -Seconds 2
    }
}

Write-Host ""
Write-Host "Package folder: $package"
Write-Host "Release zip:    $zipPath"
