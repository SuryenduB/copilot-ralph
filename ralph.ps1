<#
.SYNOPSIS
    Orchestrates an autonomous AI agent loop to complete Product Requirements Document (PRD) items using various coding CLI tools.

.DESCRIPTION
    Ralph is an autonomous agent script that iteratively executes coding tasks defined in a PRD until all items are marked as complete.
    It supports multiple backends, including GitHub Copilot CLI, OpenCode, Gemini, and Qwen. The script implements deterministic
    story selection based on priority, manages state persistence via progress logs, and automatically archives progress when
    switching Git branches. It requires 'prd.json' and 'prompt.md' in the script's root directory.

.PARAMETER Coding
    Specifies the CLI tool to use for code generation. Valid values are 'Copilot', 'OpenCode', 'Gemini', or 'Qwen'.
    The default value is 'Copilot'.

.PARAMETER Model
    Specifies the model identifier to be passed to the CLI tool.

.PARAMETER MaxIterations
    Specifies the maximum number of iterations the agent loop will run before stopping.
    The default value is 10.

.EXAMPLE
    .\Ralph.ps1
    Runs the agent using default settings (Copilot tool, Copilot model, 10 iterations).

.EXAMPLE
    .\Ralph.ps1 -Coding Gemini -Model Qwen -MaxIterations 20
    Runs the agent using the Gemini CLI tool with the Qwen model, allowing up to 20 iterations.

.INPUTS
    None. You cannot pipe objects to this script.

.OUTPUTS
    None. The script generates a progress log (progress.txt) and updates the PRD file, but does not output objects to the pipeline.

.NOTES
    Prerequisites:
    - Selected Coding CLI must be installed and available in the system PATH.
    - 'prd.json' and 'prompt.md' must exist in the same directory as the script.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [ValidateSet('Copilot','OpenCode','Gemini','Qwen')]
    [string]$Coding = 'Copilot',

    [Parameter(Mandatory=$false)]
    [string]$Model,

    [int]$MaxIterations = 10
)

 $ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Set Yolo default according to selected model (enabled for Gemini, Qwen, Copilot)
 $Yolo = if ($Coding -in @('Gemini','Qwen','Copilot')) { $true } else { $false }

 $ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { (Get-Location).Path }
 $PrdFile = Join-Path $ScriptDir 'prd.json'
 $ProgressFile = Join-Path $ScriptDir 'progress.txt'
 $ArchiveDir = Join-Path $ScriptDir 'archive'
 $LastBranchFile = Join-Path $ScriptDir '.ralph-last-branch'
 $PromptFile = Join-Path $ScriptDir 'prompt.md' 

# --- Preconditions ---
switch ($Coding) {
    'OpenCode' {
        if (-not (Get-Command opencode -ErrorAction SilentlyContinue)) {
            throw 'OpenCode CLI not installed. Please install opencode and ensure it is on PATH.'
        }
    }
    'Copilot' {
        if (-not (Get-Command copilot -ErrorAction SilentlyContinue)) {
            throw 'GitHub Copilot CLI not installed. npm install -g @github/copilot'
        }
    }
    'Gemini' {
        if (-not (Get-Command gemini -ErrorAction SilentlyContinue)) {
            throw 'Gemini CLI not installed. Please install gemini and ensure it is on PATH.'
        }
    }
    'Qwen' {
        if (-not (Get-Command qwen -ErrorAction SilentlyContinue)) {
            throw 'Qwen CLI not installed. Please install qwen and ensure it is on PATH.'
        }
    }
    Default {
        throw "Unsupported coding tool: $Coding"
    }
}

if (-not (Test-Path $PrdFile)) {
    throw 'prd.json not found. Aborting.'
}

if (-not (Test-Path $PromptFile)) {
    throw 'prompt.md not found. Aborting.'
}

# --- Helpers ---
function Read-Prd {
    try {
        Get-Content $PrdFile -Raw | ConvertFrom-Json
    } catch {
        throw ('Failed to parse ' + $PrdFile + ': ' + $_.Exception.Message)
    }
} 

function Write-Log([string]$Line) {
    $timestamp = (Get-Date).ToString('u')
    "$timestamp $Line" | Out-File $ProgressFile -Append -Encoding UTF8
} 

function Get-IncompleteStories {
    $prd = Read-Prd
    if (-not $prd -or -not $prd.userStories) { return @() }
    @($prd.userStories) |
        Where-Object { $_.passes -ne $true } |
        Sort-Object @{ Expression = { if ($null -ne $_.priority) { $_.priority } else { 999 } } }, id
} 

function Get-RemainingCount {
    @(Get-IncompleteStories).Count
}

function Get-CurrentStory {
    $stories = @((Get-IncompleteStories))
    if ($stories.Count -gt 0) {
        $s = $stories[0]
        if ($null -ne $s.id -or $null -ne $s.title) {
            "$($s.id): $($s.title)"
        } else {
            'unknown'
        }
    } else {
        'none'
    }
}

# Build CLI args for Copilot/Gemini/Qwen style CLIs. Accepts optional Tool to add tool-specific flags (e.g., Copilot).
function Build-CliArgs {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [Parameter(Mandatory = $false)][string]$Tool
    )

    $cliArgs = @()

    if ($Model) {
        $cliArgs += "--model=$Model"
    }

    if ($Yolo -and ($Tool -in @('Gemini', 'Qwen', 'Copilot'))) {
        $cliArgs += '--yolo'
    }

    if ($Tool -eq 'Copilot') {
        $cliArgs += '--allow-all-tools'
    }

    # Prompt must always be the last argument
    $cliArgs += @('-p', $Prompt)

    return $cliArgs
}

# Invoke a native CLI tool using the call operator (&). Handles OpenCode specially.
function Invoke-CodingTool {
    param(
        [Parameter(Mandatory=$true)][string]$Tool,
        [Parameter(Mandatory=$true)][string]$Prompt
    )

    # Map tool logical names to executable names (case-insensitive)
    $exe = switch ($Tool) {
        'Copilot' { 'copilot' }
        'OpenCode' { 'opencode' }
        'Gemini' { 'gemini' }
        'Qwen' { 'qwen' }
        Default { $Tool }
    }

    if ($Tool -eq 'OpenCode') {
        # Log invocation details (prompt length to avoid printing huge content)
        $promptLength = if ($null -ne $Prompt) { $Prompt.Length } else { 0 }
        Write-Host "[Invoke] $exe run (prompt length: $promptLength chars)" -ForegroundColor Magenta
        Write-Log "[Invoke] $exe run (prompt length: $promptLength chars)"

        $output = & $exe run $Prompt 2>&1
        $exitCode = $LASTEXITCODE
        # Write each output line to host and progress log for traceability
        foreach ($line in $output) {
            if ($line -ne '') { Write-Host "[$Tool] $line" -ForegroundColor Cyan }
            Write-Log "[$Tool] $line"
        }
        if ($exitCode -ne 0) {
            Write-Log "OpenCode exit code: $exitCode"
            throw "OpenCode failed with exit code $exitCode"
        }
        return ,$output
    } else {
        $cliArgs = Build-CliArgs -Prompt $Prompt -Tool $Tool
        

        # Verify -p exists and log the parameter set we're about to send
        if (-not ($cliArgs -contains '-p')) {
            Write-Warning "Parameter '-p' not found in args for $Tool; this may cause the prompt to be ignored. Args: $($cliArgs -join ' ')"
            Write-Log "WARNING: Parameter '-p' not found in args for $Tool; Args: $($cliArgs -join ' ')"
        }

        $argDisplay = ($cliArgs -join ' ')
        Write-Host "[Invoke] $exe $argDisplay" -ForegroundColor Magenta
        Write-Log "[Invoke] $exe $argDisplay"

        # Use the call operator to invoke the native CLI with the assembled args
        $output = & $exe @cliArgs 2>&1
        foreach ($line in $output) {
            if ($line -ne '') { Write-Host "[$Tool] $line" -ForegroundColor Cyan }
            Write-Log "[$Tool] $line"
        }
        return ,$output
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

            @(
                '# Ralph Progress Log'
                "Started: $(Get-Date)"
                '---'
            ) | Out-File $ProgressFile -Encoding UTF8
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
    @(
        '# Ralph Progress Log'
        "Started: $(Get-Date)"
        '---'
    ) | Out-File $ProgressFile -Encoding UTF8
} 

Write-Host "Ralph for GitHub Copilot CLI" -ForegroundColor Cyan
Write-Host "Max iterations: $MaxIterations" -ForegroundColor Yellow
Write-Host "Remaining stories: $(Get-RemainingCount)" -ForegroundColor Yellow
Write-Host "Coding tool: $Coding, Model: $Model (Yolo: $Yolo)" -ForegroundColor Green

# --- Main Loop ---
for ($i = 1; $i -le $MaxIterations; $i++) {

    $remaining = Get-RemainingCount
    if ($remaining -eq 0) {
        Write-Log 'All stories completed.'
        exit 0
    }

    $currentStory = Get-CurrentStory
    Write-Host "Iteration $i / $MaxIterations" -ForegroundColor Blue
    Write-Host "Current: $currentStory" -ForegroundColor Cyan

    Write-Log "Iteration $i START | Remaining=$remaining | Story=$currentStory"

    $prompt = Get-Content $PromptFile -Raw

    try {
        $output = Invoke-CodingTool -Tool $Coding -Prompt $prompt
        $outStr = $output -join "`n"
    } catch {
        $outStr = $_.Exception.Message
    }

    Write-Log "Iteration $i OUTPUT"
    Write-Log $outStr

    if ($outStr -match '<promise>COMPLETE</promise>') {
        Write-Log 'Completion signal received.'
        exit 0
    }

    Write-Log "Iteration $i END"
    Start-Sleep -Seconds 2
}

Write-Log "Max iterations reached ($MaxIterations)."
exit 1