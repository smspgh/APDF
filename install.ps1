<#
.SYNOPSIS
    APDF Framework Installer for Windows
.DESCRIPTION
    Installs the Agent Principal Development Framework to a target project directory
    with conflict detection, backup, and smart merge capabilities.
.PARAMETER TargetPath
    The target project directory to install APDF into
.PARAMETER Force
    Skip confirmation prompts and use default merge strategies
.EXAMPLE
    .\install.ps1 -TargetPath "C:\Projects\MyApp"
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$TargetPath,

    [switch]$Force
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Colors for output
function Write-Success { param($msg) Write-Host $msg -ForegroundColor Green }
function Write-Warning { param($msg) Write-Host $msg -ForegroundColor Yellow }
function Write-Error { param($msg) Write-Host $msg -ForegroundColor Red }
function Write-Info { param($msg) Write-Host $msg -ForegroundColor Cyan }

# Files/directories to install
$FilesToCopy = @(
    "agents",
    "phases",
    "methodologies",
    "meta.json",
    "roles.json",
    "state.json",
    "state.example.json"
)

$ClaudeCommandsDir = ".claude\commands"
$ClaudeSettingsFile = ".claude\settings.json"
$ClaudeMdFile = ".claude\CLAUDE.md"
$GitignoreFile = ".gitignore.apdf"

# Conflict tracking
$Conflicts = @()
$BackupDir = Join-Path $TargetPath ".apdf-backup"
$BackupTimestamp = Get-Date -Format "yyyyMMdd-HHmmss"

function Test-Conflict {
    param([string]$RelativePath)
    $FullPath = Join-Path $TargetPath $RelativePath
    return Test-Path $FullPath
}

function Backup-File {
    param([string]$RelativePath)

    $SourcePath = Join-Path $TargetPath $RelativePath
    if (-not (Test-Path $SourcePath)) { return }

    $BackupPath = Join-Path $BackupDir "$BackupTimestamp\$RelativePath"
    $BackupFolder = Split-Path -Parent $BackupPath

    if (-not (Test-Path $BackupFolder)) {
        New-Item -ItemType Directory -Path $BackupFolder -Force | Out-Null
    }

    Copy-Item -Path $SourcePath -Destination $BackupPath -Force
    Write-Info "  Backed up: $RelativePath"
}

function Merge-GitIgnore {
    $SourcePath = Join-Path $ScriptDir $GitignoreFile
    $TargetFile = Join-Path $TargetPath ".gitignore"

    $ApdfContent = Get-Content $SourcePath -Raw
    $Marker = "`n`n# === APDF Framework ===`n"
    $EndMarker = "# === End APDF Framework ===`n"

    if (Test-Path $TargetFile) {
        $ExistingContent = Get-Content $TargetFile -Raw

        # Check if APDF section already exists
        if ($ExistingContent -match "# === APDF Framework ===") {
            Write-Warning "  .gitignore already contains APDF section, skipping"
            return
        }

        # Append APDF entries
        $NewContent = $ExistingContent.TrimEnd() + $Marker + $ApdfContent.Trim() + "`n" + $EndMarker
        Set-Content -Path $TargetFile -Value $NewContent -NoNewline
        Write-Success "  Merged .gitignore (appended APDF entries)"
    } else {
        # No existing .gitignore, create new one
        $NewContent = $Marker.TrimStart() + $ApdfContent.Trim() + "`n" + $EndMarker
        Set-Content -Path $TargetFile -Value $NewContent -NoNewline
        Write-Success "  Created .gitignore with APDF entries"
    }
}

function Merge-ClaudeMd {
    $SourcePath = Join-Path $ScriptDir $ClaudeMdFile
    $TargetFile = Join-Path $TargetPath $ClaudeMdFile

    $ApdfContent = Get-Content $SourcePath -Raw
    $Marker = "`n`n# === APDF Framework Configuration ===`n`n"
    $EndMarker = "`n# === End APDF Framework Configuration ===`n"

    if (Test-Path $TargetFile) {
        Backup-File $ClaudeMdFile
        $ExistingContent = Get-Content $TargetFile -Raw

        # Check if APDF section already exists
        if ($ExistingContent -match "# === APDF Framework Configuration ===") {
            Write-Warning "  CLAUDE.md already contains APDF section, skipping"
            return
        }

        # Append APDF section
        $NewContent = $ExistingContent.TrimEnd() + $Marker + $ApdfContent.Trim() + $EndMarker
        Set-Content -Path $TargetFile -Value $NewContent -NoNewline
        Write-Success "  Merged CLAUDE.md (appended APDF configuration)"
    } else {
        # No existing CLAUDE.md, copy as-is
        $TargetDir = Split-Path -Parent $TargetFile
        if (-not (Test-Path $TargetDir)) {
            New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
        }
        Copy-Item -Path $SourcePath -Destination $TargetFile -Force
        Write-Success "  Created CLAUDE.md"
    }
}

function Merge-ClaudeSettings {
    $SourcePath = Join-Path $ScriptDir $ClaudeSettingsFile
    $TargetFile = Join-Path $TargetPath $ClaudeSettingsFile

    if (Test-Path $TargetFile) {
        Backup-File $ClaudeSettingsFile

        try {
            $ExistingSettings = Get-Content $TargetFile -Raw | ConvertFrom-Json -AsHashtable
            $ApdfSettings = Get-Content $SourcePath -Raw | ConvertFrom-Json -AsHashtable

            # Deep merge hooks
            if ($ApdfSettings.ContainsKey("hooks")) {
                if (-not $ExistingSettings.ContainsKey("hooks")) {
                    $ExistingSettings["hooks"] = @{}
                }
                foreach ($hookType in $ApdfSettings["hooks"].Keys) {
                    if (-not $ExistingSettings["hooks"].ContainsKey($hookType)) {
                        $ExistingSettings["hooks"][$hookType] = @()
                    }
                    # Append APDF hooks
                    $ExistingSettings["hooks"][$hookType] += $ApdfSettings["hooks"][$hookType]
                }
            }

            # Add agentPrincipal config if not exists
            if ($ApdfSettings.ContainsKey("agentPrincipal") -and -not $ExistingSettings.ContainsKey("agentPrincipal")) {
                $ExistingSettings["agentPrincipal"] = $ApdfSettings["agentPrincipal"]
            }

            # Merge permissions (union of allow, intersection of deny)
            if ($ApdfSettings.ContainsKey("permissions")) {
                if (-not $ExistingSettings.ContainsKey("permissions")) {
                    $ExistingSettings["permissions"] = @{}
                }
                if ($ApdfSettings["permissions"].ContainsKey("allow")) {
                    if (-not $ExistingSettings["permissions"].ContainsKey("allow")) {
                        $ExistingSettings["permissions"]["allow"] = @()
                    }
                    $ExistingSettings["permissions"]["allow"] = @($ExistingSettings["permissions"]["allow"]) + @($ApdfSettings["permissions"]["allow"]) | Select-Object -Unique
                }
                if ($ApdfSettings["permissions"].ContainsKey("deny")) {
                    if (-not $ExistingSettings["permissions"].ContainsKey("deny")) {
                        $ExistingSettings["permissions"]["deny"] = @()
                    }
                    $ExistingSettings["permissions"]["deny"] = @($ExistingSettings["permissions"]["deny"]) + @($ApdfSettings["permissions"]["deny"]) | Select-Object -Unique
                }
            }

            $MergedJson = $ExistingSettings | ConvertTo-Json -Depth 10
            Set-Content -Path $TargetFile -Value $MergedJson
            Write-Success "  Merged settings.json (combined hooks and permissions)"
        } catch {
            Write-Warning "  Could not merge settings.json (invalid JSON?), backing up and replacing"
            Copy-Item -Path $SourcePath -Destination $TargetFile -Force
        }
    } else {
        # No existing settings.json, copy as-is
        $TargetDir = Split-Path -Parent $TargetFile
        if (-not (Test-Path $TargetDir)) {
            New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
        }
        Copy-Item -Path $SourcePath -Destination $TargetFile -Force
        Write-Success "  Created settings.json"
    }
}

function Copy-ClaudeCommands {
    $SourceDir = Join-Path $ScriptDir $ClaudeCommandsDir
    $TargetDir = Join-Path $TargetPath $ClaudeCommandsDir

    if (-not (Test-Path $TargetDir)) {
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    }

    $CommandFiles = Get-ChildItem -Path $SourceDir -Filter "APDF_*.md"
    $Copied = 0
    $Skipped = 0

    foreach ($file in $CommandFiles) {
        $TargetFile = Join-Path $TargetDir $file.Name
        if (Test-Path $TargetFile) {
            if (-not $Force) {
                Write-Warning "  Command exists: $($file.Name) (skipped)"
                $Skipped++
                continue
            }
            Backup-File (Join-Path $ClaudeCommandsDir $file.Name)
        }
        Copy-Item -Path $file.FullName -Destination $TargetFile -Force
        $Copied++
    }

    Write-Success "  Copied $Copied command files" + $(if ($Skipped -gt 0) { ", skipped $Skipped existing" } else { "" })
}

function Copy-FrameworkFiles {
    foreach ($item in $FilesToCopy) {
        $SourcePath = Join-Path $ScriptDir $item
        $TargetItemPath = Join-Path $TargetPath $item

        if (Test-Path $SourcePath -PathType Container) {
            # Directory
            if (Test-Path $TargetItemPath) {
                if (-not $Force) {
                    Write-Warning "  Directory exists: $item (merging contents)"
                }
            }

            if (-not (Test-Path $TargetItemPath)) {
                New-Item -ItemType Directory -Path $TargetItemPath -Force | Out-Null
            }

            Copy-Item -Path "$SourcePath\*" -Destination $TargetItemPath -Recurse -Force
            Write-Success "  Copied directory: $item"
        } else {
            # File
            if (Test-Path $TargetItemPath) {
                Backup-File $item
            }
            Copy-Item -Path $SourcePath -Destination $TargetItemPath -Force
            Write-Success "  Copied file: $item"
        }
    }
}

# Main installation flow
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  APDF Framework Installer" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Validate target path
if (-not (Test-Path $TargetPath)) {
    Write-Error "Target path does not exist: $TargetPath"
    exit 1
}

Write-Info "Target: $TargetPath"
Write-Host ""

# Scan for conflicts
Write-Host "Scanning for conflicts..." -ForegroundColor Yellow
Write-Host ""

$ConflictReport = @()

# Check framework files
foreach ($item in $FilesToCopy) {
    if (Test-Conflict $item) {
        $ConflictReport += [PSCustomObject]@{
            Path = $item
            Type = if (Test-Path (Join-Path $TargetPath $item) -PathType Container) { "Directory" } else { "File" }
            Action = "Backup & Replace"
        }
    }
}

# Check .claude files
if (Test-Conflict $ClaudeMdFile) {
    $ConflictReport += [PSCustomObject]@{ Path = $ClaudeMdFile; Type = "File"; Action = "Smart Merge" }
}
if (Test-Conflict $ClaudeSettingsFile) {
    $ConflictReport += [PSCustomObject]@{ Path = $ClaudeSettingsFile; Type = "File"; Action = "Smart Merge" }
}
if (Test-Conflict ".gitignore") {
    $ConflictReport += [PSCustomObject]@{ Path = ".gitignore"; Type = "File"; Action = "Append" }
}

# Check commands
$ExistingCommands = @()
if (Test-Path (Join-Path $TargetPath $ClaudeCommandsDir)) {
    $ApdfCommands = Get-ChildItem -Path (Join-Path $ScriptDir $ClaudeCommandsDir) -Filter "APDF_*.md" -Name
    foreach ($cmd in $ApdfCommands) {
        if (Test-Path (Join-Path $TargetPath $ClaudeCommandsDir $cmd)) {
            $ExistingCommands += $cmd
        }
    }
    if ($ExistingCommands.Count -gt 0) {
        $ConflictReport += [PSCustomObject]@{
            Path = ".claude/commands/APDF_*.md ($($ExistingCommands.Count) files)"
            Type = "Files"
            Action = "Backup & Replace"
        }
    }
}

# Display conflict report
if ($ConflictReport.Count -gt 0) {
    Write-Warning "Found $($ConflictReport.Count) potential conflicts:"
    Write-Host ""
    $ConflictReport | Format-Table -AutoSize
    Write-Host ""

    if (-not $Force) {
        $response = Read-Host "Continue with installation? Existing files will be backed up to .apdf-backup/ (Y/n)"
        if ($response -eq "n" -or $response -eq "N") {
            Write-Host "Installation cancelled."
            exit 0
        }
    }
} else {
    Write-Success "No conflicts detected!"
}

Write-Host ""
Write-Host "Installing APDF Framework..." -ForegroundColor Cyan
Write-Host ""

# Perform installation
Copy-FrameworkFiles
Merge-GitIgnore
Merge-ClaudeMd
Merge-ClaudeSettings
Copy-ClaudeCommands

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Installation Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""

if (Test-Path $BackupDir) {
    Write-Info "Backups saved to: .apdf-backup/$BackupTimestamp/"
}

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Open Claude Code in your project directory"
Write-Host "  2. Run /APDF_init for new projects"
Write-Host "  3. Run /APDF_onboard for existing projects"
Write-Host ""
