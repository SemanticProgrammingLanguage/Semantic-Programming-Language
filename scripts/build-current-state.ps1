[CmdletBinding()]
param(
    [string]$CompilerPath = (Join-Path $PSScriptRoot '../crosscompiler/bin/swc.exe'),
    [string]$SourcePath = (Join-Path $PSScriptRoot '../crosscompiler/manifests/swc.smod'),
    [string]$ProbePath = (Join-Path $PSScriptRoot '../crosscompiler/source/windows/se/return42.se'),
    [string]$OutputDirectory = (Join-Path (Get-Location) 'tmp\current-state-build'),
    [ValidateSet('--embed-all','--embed-needed','--no-modules')]
    [string]$EmbedMode = '--embed-all',
    [switch]$KeepArtifacts
)

$ErrorActionPreference = 'Stop'

function Resolve-ExistingFile([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label not found: $Path"
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Invoke-Swc([string]$Executable, [string[]]$Arguments) {
    $started = Get-Date
    $output = (& $Executable @Arguments 2>&1 | Out-String).Trim()
    $exitCode = $LASTEXITCODE
    [pscustomobject]@{
        arguments = ($Arguments -join ' ')
        exit_code = $exitCode
        seconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 3)
        output = $output
    }
}

function Get-Artifact([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ exists = $false; bytes = 0; sha256 = $null }
    }
    $item = Get-Item -LiteralPath $Path
    return [pscustomobject]@{
        exists = $true
        bytes = $item.Length
        sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
}

function Get-PeEvidence([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ valid = $false; x64 = $false; entry_in_text = $false; trivial_entry_stub = $true }
    }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 256 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
        return [pscustomobject]@{ valid = $false; x64 = $false; entry_in_text = $false; trivial_entry_stub = $true }
    }
    $peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
    $signature = 'PE' + [char]0 + [char]0
    if ($peOffset -lt 0 -or $peOffset + 24 -gt $bytes.Length -or [Text.Encoding]::ASCII.GetString($bytes, $peOffset, 4) -ne $signature) {
        return [pscustomobject]@{ valid = $false; x64 = $false; entry_in_text = $false; trivial_entry_stub = $true }
    }
    $coff = $peOffset + 4
    $machine = [BitConverter]::ToUInt16($bytes, $coff)
    $sectionCount = [BitConverter]::ToUInt16($bytes, $coff + 2)
    $optionalSize = [BitConverter]::ToUInt16($bytes, $coff + 16)
    $optional = $coff + 20
    $entryRva = [BitConverter]::ToUInt32($bytes, $optional + 16)
    $sectionBase = $optional + $optionalSize
    $entryOffset = $null
    foreach ($i in 0..($sectionCount - 1)) {
        $section = $sectionBase + (40 * $i)
        $name = [Text.Encoding]::ASCII.GetString($bytes, $section, 8).Trim([char]0)
        $virtualSize = [BitConverter]::ToUInt32($bytes, $section + 8)
        $virtualAddress = [BitConverter]::ToUInt32($bytes, $section + 12)
        $rawSize = [BitConverter]::ToUInt32($bytes, $section + 16)
        $rawPointer = [BitConverter]::ToUInt32($bytes, $section + 20)
        if ($name -eq '.text' -and $entryRva -ge $virtualAddress -and $entryRva -lt ($virtualAddress + [Math]::Max($virtualSize, $rawSize))) {
            $entryOffset = $rawPointer + ($entryRva - $virtualAddress)
        }
    }
    $trivial = $true
    if ($null -ne $entryOffset -and $entryOffset -ge 0 -and $entryOffset -lt $bytes.Length) {
        $entry = @($bytes[$entryOffset..([Math]::Min($entryOffset + 5, $bytes.Length - 1))])
        $trivial = ($entry[0] -eq 0xC3) -or ($entry.Count -ge 6 -and $entry[0] -eq 0xB8 -and $entry[5] -eq 0xC3)
    }
    [pscustomobject]@{
        valid = $true
        x64 = ($machine -eq 0x8664)
        entry_in_text = ($null -ne $entryOffset)
        trivial_entry_stub = $trivial
    }
}

function Invoke-Runtime([string]$Executable) {
    $process = Start-Process -FilePath $Executable -PassThru -WindowStyle Hidden
    if (-not $process.WaitForExit(5000)) {
        Stop-Process -Id $process.Id -Force
        return [pscustomobject]@{ started = $true; timed_out = $true; exit_code = $null }
    }
    return [pscustomobject]@{ started = $true; timed_out = $false; exit_code = $process.ExitCode }
}

$compiler = Resolve-ExistingFile $CompilerPath 'Compiler'
$source = Resolve-ExistingFile $SourcePath 'Compiler source'
$probe = Resolve-ExistingFile $ProbePath 'Runtime probe'
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$outputRoot = (Resolve-Path -LiteralPath $OutputDirectory).Path

$stage2Path = Join-Path $outputRoot 'stage2.exe'
$stage3Path = Join-Path $outputRoot 'stage3.exe'
$probeExePath = Join-Path $outputRoot 'return42.exe'
$reportPath = Join-Path $outputRoot 'current-state-report.json'

$version = Invoke-Swc $compiler @('version')
$help = Invoke-Swc $compiler @('help')
$stage2 = Invoke-Swc $compiler @('compile', $source, '-o', $stage2Path, $EmbedMode)
$stage2Artifact = Get-Artifact $stage2Path
$stage2Pe = Get-PeEvidence $stage2Path
$stage3 = [pscustomobject]@{ exit_code = $null; output = ''; seconds = 0; arguments = '' }
$stage3Artifact = Get-Artifact $stage3Path
$stage3Pe = Get-PeEvidence $stage3Path
$stage2Runtime = [pscustomobject]@{ started = $false; timed_out = $false; exit_code = $null }
$stage3Runtime = [pscustomobject]@{ started = $false; timed_out = $false; exit_code = $null }

if ($stage2.exit_code -eq 0 -and $stage2Artifact.exists) {
    $stage2Runtime = Invoke-Runtime $stage2Path
    $stage3 = Invoke-Swc $stage2Path @('compile', $source, '-o', $stage3Path, $EmbedMode)
    $stage3Artifact = Get-Artifact $stage3Path
    $stage3Pe = Get-PeEvidence $stage3Path
    if ($stage3.exit_code -eq 0 -and $stage3Artifact.exists) {
        $stage3Runtime = Invoke-Runtime $stage3Path
    }
}

$probeBuild = Invoke-Swc $compiler @('compile', $probe, '-o', $probeExePath, '--no-modules')
$probeArtifact = Get-Artifact $probeExePath
$probeRuntime = [pscustomobject]@{ started = $false; timed_out = $false; exit_code = $null }
if ($probeBuild.exit_code -eq 0 -and $probeArtifact.exists) {
    $probeRuntime = Invoke-Runtime $probeExePath
}

$byteStable = $stage2Artifact.exists -and $stage3Artifact.exists -and ($stage2Artifact.sha256 -eq $stage3Artifact.sha256)
$stage2Passed = $stage2.exit_code -eq 0 -and $stage2Artifact.exists -and $stage2Runtime.exit_code -eq 0 -and -not $stage2Runtime.timed_out -and $stage2Pe.valid -and $stage2Pe.x64 -and $stage2Pe.entry_in_text -and -not $stage2Pe.trivial_entry_stub
$stage3Passed = $stage3.exit_code -eq 0 -and $stage3Artifact.exists -and $stage3Runtime.exit_code -eq 0 -and -not $stage3Runtime.timed_out -and $stage3Pe.valid -and $stage3Pe.x64 -and $stage3Pe.entry_in_text -and -not $stage3Pe.trivial_entry_stub
$probePassed = $probeBuild.exit_code -eq 0 -and $probeArtifact.exists -and $probeRuntime.exit_code -eq 42

$report = [ordered]@{
    schema = 'swc.current-state-build.v1'
    compiler = $compiler
    source = $source
    probe = $probe
    version = $version
    help = $help
    stage2 = [ordered]@{ command = $stage2; artifact = $stage2Artifact; pe = $stage2Pe; runtime = $stage2Runtime; passed = $stage2Passed }
    stage3 = [ordered]@{ command = $stage3; artifact = $stage3Artifact; pe = $stage3Pe; runtime = $stage3Runtime; passed = $stage3Passed }
    byte_stable = $byteStable
    runtime_probe = [ordered]@{ command = $probeBuild; artifact = $probeArtifact; runtime = $probeRuntime; passed = $probePassed }
    overall = ($stage2Passed -and $stage3Passed -and $byteStable -and $probePassed)
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding UTF8

Write-Output "SWC_CURRENT_STATE_REPORT=$reportPath"
Write-Output "STAGE2_PASS=$stage2Passed BYTES=$($stage2Artifact.bytes)"
Write-Output "STAGE3_PASS=$stage3Passed BYTES=$($stage3Artifact.bytes)"
Write-Output "STAGE2_PE_VALID=$($stage2Pe.valid) X64=$($stage2Pe.x64) ENTRY_IN_TEXT=$($stage2Pe.entry_in_text) TRIVIAL_STUB=$($stage2Pe.trivial_entry_stub)"
Write-Output "STAGE3_PE_VALID=$($stage3Pe.valid) X64=$($stage3Pe.x64) ENTRY_IN_TEXT=$($stage3Pe.entry_in_text) TRIVIAL_STUB=$($stage3Pe.trivial_entry_stub)"
Write-Output "BYTE_STABLE=$byteStable"
Write-Output "RUNTIME_PROBE_PASS=$probePassed EXIT=$($probeRuntime.exit_code)"
Write-Output "OVERALL_PASS=$($report.overall)"

if (-not $KeepArtifacts -and $report.overall) {
    Remove-Item -LiteralPath $stage2Path, $stage3Path, $probeExePath -Force -ErrorAction SilentlyContinue
    Write-Output 'GENERATED_EXE_CLEANUP=TRUE'
}

if (-not $report.overall) { exit 1 }
