<
.SYNOPSIS
    Ralph for GitHub Copilot CLI
    Autonomous AI agent loop that runs Copilot CLI until all PRD items are complete.
    Implements stricter state handling, deterministic story selection, and progress persistence.
#>

param(
    [int]$MaxIterations = 10
)

$ErrorActionPreference = 'Stop'

$ScriptDir       = $PSScriptRoot
$PrdFile         = 'prd.json'
$ProgressFile    = 'progress.txt'
$ArchiveDir      = 'archive'
$LastBranchFile  = '.ralph-last-branch'
$PromptFile      = Join-Path $ScriptDir 'prompt.md'

# --- Preconditions ---
if (-not (Get-Command copilot -ErrorAction SilentlyContinue)) {
    throw 'GitHub Copilot CLI not installed. npm install -g @github/copilot'
}

if (-not (Test-Path $PrdFile)) {
    throw 'prd.json not found. Aborting.'
}

if (-not (Test-Path $PromptFile)) {
    throw 'prompt.md not found. Aborting.'
}

# --- Helpers ---
function Read-Prd {
    Get-Content $PrdFile -Raw | ConvertFrom-Json
}

function Write-Progress([string]$Line) {
    $timestamp = (Get-Date).ToString('u')
    "$timestamp $Line" | Out-File $ProgressFile -Append -Encoding UTF8
}

function Get-IncompleteStories {
    $prd = Read-Prd
    $prd.userStories |
        Where-Object { $_.passes -ne $true } |
        Sort-Object @{ Expression = { if ($_.priority) { $_.priority } else { 999 } } }, id
}

function Count-Remaining {
    (Get-IncompleteStories).Count
}

function Get-CurrentStory {
    $stories = Get-IncompleteStories
    if ($stories.Count -gt 0) {
        "$($stories[0].id): $($stories[0].title)"
    } else {
        'none'
    }
}

# --- Archive on branch change ---
if (Test-Path $LastBranchFile) {
    try {
        $prd         = Read-Prd
        $current     = $prd.branchName
        $previous    = Get-Content $LastBranchFile -Raw

        if ($current -and $previous -and ($current -ne $previous.Trim())) {
            $date    = Get-Date -Format 'yyyy-MM-dd'
            $name    = $previous.Trim() -replace '^ralph/', ''
            $target  = Join-Path $ArchiveDir "$date-$name"

            New-Item -ItemType Directory -Path $target -Force | Out-Null
            Copy-Item $PrdFile $target -Force -ErrorAction SilentlyContinue
            Copy-Item $ProgressFile $target -Force -ErrorAction SilentlyContinue

            @"# Ralph Progress Log
Started: $(Get-Date)
---
"@ | Out-File $ProgressFile -Encoding UTF8
        }
    } catch {}
}

# Track current branch
try {
    $prd = Read-Prd
    if ($prd.branchName) {
        $prd.branchName | Out-File $LastBranchFile -NoNewline -Encoding UTF8
    }
} catch {}

# Initialize progress file
if (-not (Test-Path $ProgressFile)) {
@"# Ralph Progress Log
Started: $(Get-Date)
---
"@ | Out-File $ProgressFile -Encoding UTF8
}

Write-Host "Ralph for GitHub Copilot CLI" -ForegroundColor Cyan
Write-Host "Max iterations: $MaxIterations" -ForegroundColor Yellow
Write-Host "Remaining stories: $(Count-Remaining)" -ForegroundColor Yellow

# --- Main Loop ---
for ($i = 1; $i -le $MaxIterations; $i++) {

    $remaining = Count-Remaining
    if ($remaining -eq 0) {
        Write-Progress 'All stories completed.'
        exit 0
    }

    $currentStory = Get-CurrentStory
    Write-Host "Iteration $i / $MaxIterations" -ForegroundColor Blue
    Write-Host "Current: $currentStory" -ForegroundColor Cyan

    Write-Progress "Iteration $i START | Remaining=$remaining | Story=$currentStory"

    $prompt = Get-Content $PromptFile -Raw

    try {
        $output = & copilot -p $prompt --allow-all-tools 2>&1
        $outStr = $output -join "`n"
    } catch {
        $outStr = $_.Exception.Message
    }

    Write-Progress "Iteration $i OUTPUT"
    Write-Progress $outStr

    if ($outStr -match '<promise>COMPLETE</promise>') {
        Write-Progress 'Completion signal received.'
        exit 0
    }

    Write-Progress "Iteration $i END"
    Start-Sleep -Seconds 2
}

Write-Progress "Max iterations reached ($MaxIterations)."
exit 1
