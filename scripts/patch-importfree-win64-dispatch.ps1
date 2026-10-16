[CmdletBinding()]
param([Parameter(Mandatory)][string]$InputPath,[Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference='Stop'
$inputFull=(Resolve-Path -LiteralPath $InputPath).Path
$out=[IO.Path]::GetFullPath($OutputPath)
if($inputFull -eq $out){throw 'Use separate candidate output'}
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'import-semantic-function-closure.ps1'),[ref]$null,[ref]$null)
$reader=$ast.Find({param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Read-SemanticGraph'},$false)
. ([scriptblock]::Create($reader.Extent.Text))
$g=Read-SemanticGraph $inputFull
$n=@{};foreach($v in $g.Nodes){$n[[int]$v.id]=$v}
$r=[Collections.Generic.List[object]]::new();foreach($v in $g.Relations){$r.Add($v)}
$added=[Collections.Generic.List[object]]::new();$next=1+[int](($n.Keys|Measure-Object -Maximum).Maximum)
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'patch-slice-native-execution.ps1'),[ref]$null,[ref]$null)
foreach($f in $ast.FindAll({param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
function Str($s){Node LiteralExpr ([ordered]@{kind='literal';operation=[ordered]@{literal_kind='string';text=$s}})}
$null=Fn compile_ifree_win64_call
$callBody=20181
if(!$n.ContainsKey($callBody) -or $n[$callBody].structural_kind -ne 'Scope'){throw 'Expected canonical compile_expr direct-call scope'}
foreach($count in 0..7){
 $name='ifree_win64_call'+$count
 $test=Node IfStmt ([ordered]@{kind='if'})
 $body=Node Scope ([ordered]@{kind='block'})
 Edge $test (Call slice_eq_cstr @((Ref np),(Ref nn),(Str $name))) condition 0
 Edge $test $body then 0
 Edge $body (Expr (Call compile_ifree_win64_call @((Ref c),(Ref id),(Lit $count)))) statement 0
 Edge $body (Ret (Lit 0)) statement 1
 Insert $callBody $test (3+$count)
}
$source=[IO.File]::ReadAllText($inputFull)
$json=(@($added)|ForEach-Object{$_|ConvertTo-Json -Compress -Depth 100}) -join ",`n"
$source=[regex]::Replace($source,'(?ms)^nodes\s*=\[.*?^\]',[Text.RegularExpressions.MatchEvaluator]{param($m)$m.Value.Substring(0,$m.Value.Length-1).TrimEnd()+",`n"+$json+"`n]"},1)
$json=(@($r)|ForEach-Object{$_|ConvertTo-Json -Compress -Depth 100}) -join ",`n"
$source=[regex]::Replace($source,'(?ms)^relations\s*=\[.*?^\]',[Text.RegularExpressions.MatchEvaluator]{param($m)"relations=[`n$json`n]"},1)
[IO.File]::WriteAllText($out,$source,[Text.UTF8Encoding]::new($false))
"OUTPUT=$out WIN64_CALL_ARITIES=0..7"
