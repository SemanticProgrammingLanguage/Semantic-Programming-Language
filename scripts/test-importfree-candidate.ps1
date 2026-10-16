param(
 [Parameter(Mandatory)][string]$Compiler,
 [Parameter(Mandatory)][string]$OutputDirectory,
 [string]$FixtureDirectory='tests'
)
$ErrorActionPreference='Stop'
$compilerPath=(Resolve-Path -LiteralPath $Compiler).Path
$fixtures=(Resolve-Path -LiteralPath $FixtureDirectory).Path
$out=[IO.Path]::GetFullPath($OutputDirectory)
$null=New-Item -ItemType Directory -Path $out -Force
$null=New-Item -ItemType Directory -Path 'tmp/compile-probes' -Force
$results=[Collections.Generic.List[object]]::new()
function Invoke-Checked([string]$File,[string[]]$Arguments,[int]$Expected,[int]$Timeout=600000,[string]$ExpectedStdout){
 $start=[Diagnostics.ProcessStartInfo]::new()
 $start.FileName=$File
 $start.UseShellExecute=$false
 $start.CreateNoWindow=$true
 $capture=$PSBoundParameters.ContainsKey('ExpectedStdout')
 $start.RedirectStandardOutput=$capture
 foreach($argument in $Arguments){$start.ArgumentList.Add($argument)}
 $process=[Diagnostics.Process]::Start($start)
 if($capture){$outputTask=$process.StandardOutput.ReadToEndAsync()}
 if(!$process.WaitForExit($Timeout)){$process.Kill();throw "Timed out: $File"}
 $actual=$process.ExitCode
 $results.Add([ordered]@{file=$File;arguments=$Arguments;expected=$Expected;actual=$actual;passed=($actual -eq $Expected)})
 if($actual -ne $Expected){throw "Exit mismatch: $File expected=$Expected actual=$actual"}
 if($capture){
  $captured=$outputTask.GetAwaiter().GetResult()
  if($captured -cne $ExpectedStdout){throw "Redirected stdout mismatch: $File"}
 }
}
Invoke-Checked $compilerPath @('version') 0 30000 -ExpectedStdout "swc 2.3.2 windows-x64`n"
Invoke-Checked $compilerPath @('help') 0 30000
$cases=@(
 @{name='return42';source='tests/return42.se';exit=42;arguments=@()},
 @{name='argc';source='tests/importfree-argc.se';exit=3;arguments=@('one','two')},
 @{name='argv';source='tests/importfree-argv-first-byte.se';exit=118;arguments=@('version')},
 @{name='native-io';source='tests/importfree-native-io.se';exit=39;arguments=@()}
)
# Expected results were independently reproduced with the active CRT baseline.
foreach($pair in @(
 @('matrix-binding-pattern-swap',37),@('matrix-binding-pattern-effects-once',13),
 @('matrix-foreach-sum',33),@('matrix-foreach-break',42),@('matrix-foreach-continue',42),
 @('matrix-slice-identity-index',42),@('matrix-tuple-effects-once',24),
 @('matrix-nested-tuple-index-value',35)
)){$cases+=@{name=$pair[0];source=('tests/'+$pair[0]+'.se');exit=[int]$pair[1];arguments=@()}}
try{
 foreach($case in $cases){
  $target=Join-Path $out ($case.name+'.exe')
  Invoke-Checked $compilerPath @('compile',(Join-Path $fixtures (Split-Path $case.source -Leaf)),'-o',$target) 0
  Invoke-Checked $target $case.arguments $case.exit 30000
  if($case.name -eq 'native-io'){
   $actual=[IO.File]::ReadAllBytes((Join-Path (Get-Location) 'tmp/compile-probes/importfree-adapter-output.txt'))
   $expected=[Text.Encoding]::ASCII.GetBytes("Semantic import-free Win64 file test.`r`n")
   if([Convert]::ToBase64String($actual) -ne [Convert]::ToBase64String($expected)){throw 'Native I/O content mismatch'}
  }
 }
 foreach($name in @('importfree-peb-arity-rejected','matrix-intrinsic-arity-rejected','matrix-binding-pattern-arity-invalid','matrix-slice-missing-contract-rejected')){
  $target=Join-Path $out ($name+'-rejected.exe')
  if(Test-Path -LiteralPath $target){throw "Refusing stale rejection output: $target"}
  Invoke-Checked $compilerPath @('compile',(Join-Path $fixtures ($name+'.se')),'-o',$target) 3
  if(Test-Path -LiteralPath $target){throw "Rejected input produced an executable: $name"}
 }
 foreach($mode in @('default','explicit')){
  $target=Join-Path $out ('smod-'+$mode+'.exe')
  $arguments=@('compile',(Join-Path $fixtures 'importfree-return42.smod'),'-o',$target)
  if($mode -eq 'explicit'){$arguments+='--embed-all'}
  Invoke-Checked $compilerPath $arguments 0
  Invoke-Checked $target @() 42 30000
 }
 $spaced=Join-Path $out 'paths with spaces'
 $null=New-Item -ItemType Directory -Path $spaced -Force
 $inputFile=Join-Path $spaced 'input with spaces.se'
 $target=Join-Path $spaced 'output with spaces.exe'
 Copy-Item -LiteralPath (Join-Path $fixtures 'return42.se') -Destination $inputFile
 Invoke-Checked $compilerPath @('compile',$inputFile,'-o',$target) 0
 Invoke-Checked $target @() 42 30000
 $absoluteManifest=Join-Path $spaced 'absolute unit.smod'
 $absoluteSource=(Join-Path $fixtures 'return42.se').Replace('\','/')
 $manifest=[ordered]@{schema='slc.semantic-module.v1';name='absolute-unit-regression';version='1.0.0';language='semantic';entry_point='main';dependencies=@();files=@([ordered]@{kind='semantic';language='semantic';path=$absoluteSource;semantic_path=$absoluteSource;status='SEMANTIC_READY'})}
 [IO.File]::WriteAllText($absoluteManifest,($manifest|ConvertTo-Json -Depth 8 -Compress),[Text.UTF8Encoding]::new($false))
 $target=Join-Path $spaced 'absolute unit.exe'
 Invoke-Checked $compilerPath @('compile',$absoluteManifest,'-o',$target,'--embed-all') 0
 Invoke-Checked $target @() 42 30000
}finally{
 $json=ConvertTo-Json -InputObject @($results.ToArray()) -Depth 8
 [IO.File]::WriteAllText((Join-Path $out 'native-results.json'),$json,[Text.UTF8Encoding]::new($false))
}
Write-Output "NATIVE_REGRESSIONS_PASSED=$($results.Count)"
