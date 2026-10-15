[CmdletBinding()]
param(
    [string]$CompilerPath = (Join-Path (Get-Location) 'swc.exe'),
    [string]$CompilerSource = (Join-Path (Get-Location) 'src\swc-selfhost-windows.se'),
    [string]$FixtureDirectory = (Join-Path (Get-Location) 'tests'),
    [string]$OutputDirectory = (Join-Path (Get-Location) 'tmp\current-fixture-audit')
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $CompilerPath -PathType Leaf)) { throw "Compiler not found: $CompilerPath" }
if (-not (Test-Path -LiteralPath $FixtureDirectory -PathType Container)) { throw "Fixture directory not found: $FixtureDirectory" }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

function Inspect-Pe([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 256 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
        return [pscustomobject]@{ valid = $false; x64 = $false; entry_in_text = $false; trivial_entry_stub = $true; entry_bytes = $null }
    }
    $peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
    $peSignature = 'PE' + [char]0 + [char]0
    if ($peOffset -lt 0 -or $peOffset + 24 -gt $bytes.Length -or [Text.Encoding]::ASCII.GetString($bytes, $peOffset, 4) -ne $peSignature) {
        return [pscustomobject]@{ valid = $false; x64 = $false; entry_in_text = $false; trivial_entry_stub = $true; entry_bytes = $null }
    }
    $coff = $peOffset + 4
    $machine = [BitConverter]::ToUInt16($bytes, $coff)
    $sectionCount = [BitConverter]::ToUInt16($bytes, $coff + 2)
    $optionalSize = [BitConverter]::ToUInt16($bytes, $coff + 16)
    $optional = $coff + 20
    $entryRva = [BitConverter]::ToUInt32($bytes, $optional + 16)
    $sectionBase = $optional + $optionalSize
    $inText = $false
    $entryOffset = $null
    for ($i = 0; $i -lt $sectionCount; $i++) {
        $section = $sectionBase + (40 * $i)
        $name = [Text.Encoding]::ASCII.GetString($bytes, $section, 8).Trim([char]0)
        $virtualSize = [BitConverter]::ToUInt32($bytes, $section + 8)
        $virtualAddress = [BitConverter]::ToUInt32($bytes, $section + 12)
        $rawSize = [BitConverter]::ToUInt32($bytes, $section + 16)
        $rawPointer = [BitConverter]::ToUInt32($bytes, $section + 20)
        if ($name -eq '.text' -and $entryRva -ge $virtualAddress -and $entryRva -lt ($virtualAddress + [Math]::Max($virtualSize, $rawSize))) {
            $inText = $true
            $entryOffset = $rawPointer + ($entryRva - $virtualAddress)
        }
    }
    $entryHex = $null
    $trivial = $false
    if ($null -ne $entryOffset -and $entryOffset -ge 0 -and $entryOffset -lt $bytes.Length) {
        $end = [Math]::Min($entryOffset + 31, $bytes.Length - 1)
        $entry = @($bytes[$entryOffset..$end])
        $entryHex = (($entry | ForEach-Object { $_.ToString('X2') }) -join ' ')
        $trivial = ($entry[0] -eq 0xC3) -or ($entry.Count -ge 6 -and $entry[0] -eq 0xB8 -and $entry[5] -eq 0xC3)
    } else { $trivial = $true }
    [pscustomobject]@{
        valid = $true
        x64 = ($machine -eq 0x8664)
        entry_in_text = $inText
        trivial_entry_stub = $trivial
        entry_bytes = $entryHex
    }
}

$rows = foreach ($fixture in Get-ChildItem -LiteralPath $FixtureDirectory -Filter '*.se' -File | Sort-Object Name) {
    $output = Join-Path $OutputDirectory ($fixture.BaseName + '.exe')
    if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Force -ErrorAction SilentlyContinue }
    $fixtureText = Get-Content -LiteralPath $fixture.FullName -Raw
    $inputPath = $fixture.FullName
    $linkBindings = @()
    $metadataMatch = [regex]::Match($fixtureText, '(?m)^metadata=(\{.*\})\s*$')
    if ($metadataMatch.Success) {
        $fixtureMetadata = $metadataMatch.Groups[1].Value | ConvertFrom-Json
        $linkBindings = @($fixtureMetadata.link_bindings | Where-Object { $_ })
    }
    if ($linkBindings.Count -gt 0) {
        $inputPath = Join-Path $OutputDirectory ($fixture.BaseName + '.linked.se')
        & (Join-Path $PSScriptRoot 'import-semantic-function-closure.ps1') `
            -CorePath $fixture.FullName -UnitPath $CompilerSource -RootBinding $linkBindings `
            -OutputPath $inputPath -ReportPath (Join-Path $OutputDirectory ($fixture.BaseName + '.import.json')) | Out-Null
    }
    & $CompilerPath compile $inputPath -o $output --no-modules 2>&1 | Out-Null
    $compileExit = $LASTEXITCODE
    $bytes = 0
    $hash = $null
    $runtimeExit = $null
    $runtimeTimeout = $false
    $pe = [pscustomobject]@{ valid = $false; x64 = $false; entry_in_text = $false; trivial_entry_stub = $true; entry_bytes = $null }
    $expectedExit = $null
    $expectedCompileExit = $null
    if ($metadataMatch.Success -and $null -ne $fixtureMetadata.expected_compile_exit) {
        $expectedCompileExit = [int]$fixtureMetadata.expected_compile_exit
    }
    $expectedMatch = [regex]::Match($fixtureText, 'expected_exit"\s*:\s*"?(-?\d+)"?|expected_exit\s*=\s*"?(-?\d+)"?')
    if ($expectedMatch.Success) { $expectedExit = [int]($expectedMatch.Groups[1].Value + $expectedMatch.Groups[2].Value) }
    if (Test-Path -LiteralPath $output) {
        $item = Get-Item -LiteralPath $output
        $bytes = $item.Length
        $hash = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash
        $pe = Inspect-Pe $output
        $process = Start-Process -FilePath $output -PassThru -WindowStyle Hidden
        if ($process.WaitForExit(3000)) { $runtimeExit = $process.ExitCode }
        else { Stop-Process -Id $process.Id -Force; $runtimeTimeout = $true }
    }
    [pscustomobject]@{
        fixture = $fixture.Name
        linked_compiler_bindings = $linkBindings
        compile_exit = $compileExit
        output_bytes = $bytes
        output_sha256 = $hash
        runtime_exit = $runtimeExit
        runtime_timeout = $runtimeTimeout
        executable_emitted = ($bytes -gt 0)
        pe_valid = $pe.valid
        pe_x64 = $pe.x64
        entry_in_text = $pe.entry_in_text
        trivial_entry_stub = $pe.trivial_entry_stub
        entry_bytes = $pe.entry_bytes
        expected_exit = $expectedExit
        expected_compile_exit = $expectedCompileExit
        rejection_verified = ($null -ne $expectedCompileExit -and $compileExit -eq $expectedCompileExit -and $bytes -eq 0)
        behavior_verified = ($compileExit -eq 0 -and $null -ne $expectedExit -and $runtimeExit -eq $expectedExit -and -not $runtimeTimeout)
    }
}

$reportPath = Join-Path $OutputDirectory 'fixture-audit.json'
$emittedRows = @($rows | Where-Object { $_.executable_emitted -eq $true })
$summary = [ordered]@{
    schema = 'swc.current-fixture-audit.v1'
    compiler = (Resolve-Path -LiteralPath $CompilerPath).Path
    compiler_sha256 = (Get-FileHash -LiteralPath $CompilerPath -Algorithm SHA256).Hash
    compiler_source = (Resolve-Path -LiteralPath $CompilerSource).Path
    fixture_directory = (Resolve-Path -LiteralPath $FixtureDirectory).Path
    total = $rows.Count
    compile_success = ($rows | Where-Object compile_exit -eq 0).Count
    rejected = ($rows | Where-Object compile_exit -ne 0).Count
    emitted = ($rows | Where-Object executable_emitted).Count
    runtime_timeouts = ($rows | Where-Object runtime_timeout).Count
    structurally_valid_pe = ($emittedRows | Where-Object { $_.pe_valid -eq $true -and $_.pe_x64 -eq $true -and $_.entry_in_text -eq $true }).Count
    trivial_entry_stubs = ($emittedRows | Where-Object { $_.trivial_entry_stub -eq $true }).Count
    behavior_verified = ($emittedRows | Where-Object { $_.behavior_verified -eq $true }).Count
    rejection_verified = @($rows | Where-Object { $_.rejection_verified -eq $true }).Count
    expectation_failures = @($rows | Where-Object {
        ($null -ne $_.expected_exit -and -not $_.behavior_verified) -or
        ($null -ne $_.expected_compile_exit -and -not $_.rejection_verified)
    }).Count
    distinct_emitted_hashes = @($emittedRows | Select-Object -ExpandProperty output_sha256 -Unique).Count
    fixtures = @($rows)
}
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding UTF8
$rows | Format-Table fixture,compile_exit,output_bytes,runtime_exit -AutoSize
Write-Output "SWC_FIXTURE_AUDIT=$reportPath"
Write-Output "TOTAL=$($summary.total) COMPILE_SUCCESS=$($summary.compile_success) REJECTED=$($summary.rejected) EMITTED=$($summary.emitted) DISTINCT_HASHES=$($summary.distinct_emitted_hashes)"
Write-Output "STRUCTURALLY_VALID_PE=$($summary.structurally_valid_pe) TRIVIAL_ENTRY_STUBS=$($summary.trivial_entry_stubs) BEHAVIOR_VERIFIED=$($summary.behavior_verified)"
Write-Output "REJECTION_VERIFIED=$($summary.rejection_verified) EXPECTATION_FAILURES=$($summary.expectation_failures)"

Remove-Item -LiteralPath ($rows | Where-Object executable_emitted | ForEach-Object { Join-Path $OutputDirectory ($_.fixture -replace '\.se$','.exe') }) -Force -ErrorAction SilentlyContinue
if ($summary.expectation_failures -gt 0) { exit 1 }
