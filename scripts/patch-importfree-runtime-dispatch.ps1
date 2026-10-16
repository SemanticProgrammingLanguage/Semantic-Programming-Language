[CmdletBinding()]
param([Parameter(Mandatory)][string]$InputPath,[Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference='Stop'
$inputFull=(Resolve-Path -LiteralPath $InputPath).Path;$out=[IO.Path]::GetFullPath($OutputPath)
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
foreach($name in @('compile_ifree_runtime_call','emit_ifree_entry','clear_ifree_imports','emit_ifree_runtime_template')){$null=Fn $name}
$callBody=20181
$names=@('sys_mmap','sys_open','sys_read','sys_write','sys_close')
for($i=0;$i -lt $names.Count;$i++){
 $test=Node IfStmt ([ordered]@{kind='if'});$body=Node Scope ([ordered]@{kind='block'})
 Edge $test (Call slice_eq_cstr @((Ref np),(Ref nn),(Str $names[$i]))) condition 0;Edge $test $body then 0
 Edge $body (Expr (Call compile_ifree_runtime_call @((Ref c),(Ref id),(Lit $i)))) statement 0
 Edge $body (Ret (Lit 0)) statement 1
 Insert $callBody $test (3+$i)
}
$programBody=Child (Fn compile_program) body
$statements=@(Edges $programBody statement)
# Runtime entries follow the complete existing label namespace, including
# foreach-continue labels in group 10. Keep seven additional table cells.
$allocation=@($statements|Where-Object{$n[[int]$_.to.id].fields.name -eq 'native_label_count'})
if($allocation.Count -ne 1){throw 'Expected native label allocation'}
$allocationExpr=@(Edges ([int]$allocation[0].to.id) expression)
if($allocationExpr.Count -ne 1){throw 'Expected label capacity expression'}
$oldCapacity=[int]$allocationExpr[0].to.id
$newCapacity=Op add $oldCapacity (Lit 7)
$allocationExpr[0].to.id=[string]$newCapacity
$peInit=@($statements|Where-Object{$v=$n[[int]$_.to.id];if($v.structural_kind -ne 'ExprStmt'){return $false};$x=Child $v.id expression;$c=@(Edges $x callee);$c.Count -eq 1 -and $n[[int]$c[0].to.id].fields.name -eq 'pe_init'})
$main=@($statements|Where-Object{$n[[int]$_.to.id].fields.name -eq 'mainid'})
$loopStart=@($statements|Where-Object{$n[[int]$_.to.id].fields.name -eq 'i'}|Select-Object -First 1)
if($peInit.Count -ne 1 -or $main.Count -ne 1 -or $loopStart.Count -ne 1){throw 'Unexpected canonical startup structure'}
$from=[int]$peInit[0].attributes.ordinal;$until=[int]$loopStart[0].attributes.ordinal
$r=[Collections.Generic.List[object]]@($r|Where-Object{-not($_.kind -eq 'syntax.child' -and [int]$_.from -eq $programBody -and $_.attributes.role -eq 'statement' -and [int]$_.attributes.ordinal -gt $from -and [int]$_.attributes.ordinal -lt $until)})
# Preserve original non-startup ordering and insert new native startup after pe_init.
$ordered=@(Edges $programBody statement);for($i=0;$i -lt $ordered.Count;$i++){$ordered[$i].attributes.ordinal=$i}
$initOrdinal=[int]$peInit[0].attributes.ordinal
Insert $programBody (Expr (Call clear_ifree_imports @((Ref c)))) ($initOrdinal+1)
Insert $programBody ([int]$main[0].to.id) ($initOrdinal+2)
Insert $programBody (Expr (Call emit_ifree_entry @((Ref c),(Ref mainid)))) ($initOrdinal+3)
$resolve=@(Edges $programBody statement|Where-Object{$v=$n[[int]$_.to.id];if($v.structural_kind -ne 'ExprStmt'){return $false};$x=Child $v.id expression;$c=@(Edges $x callee);$c.Count -eq 1 -and $n[[int]$c[0].to.id].fields.name -eq 'resolve_fix'})
if($resolve.Count -ne 1){throw 'Expected one relocation resolution pass'}
Insert $programBody (Expr (Call emit_ifree_runtime_template @((Ref c)))) ([int]$resolve[0].attributes.ordinal)
$source=[IO.File]::ReadAllText($inputFull)
$json=(@($added)|ForEach-Object{$_|ConvertTo-Json -Compress -Depth 100}) -join ",`n"
$source=[regex]::Replace($source,'(?ms)^nodes\s*=\[.*?^\]',[Text.RegularExpressions.MatchEvaluator]{param($m)$m.Value.Substring(0,$m.Value.Length-1).TrimEnd()+",`n"+$json+"`n]"},1)
$json=(@($r)|ForEach-Object{$_|ConvertTo-Json -Compress -Depth 100}) -join ",`n"
$source=[regex]::Replace($source,'(?ms)^relations\s*=\[.*?^\]',[Text.RegularExpressions.MatchEvaluator]{param($m)"relations=[`n$json`n]"},1)
[IO.File]::WriteAllText($out,$source,[Text.UTF8Encoding]::new($false))
"OUTPUT=$out CRT_STARTUP_REPLACED=TRUE SYS_DISPATCHES=5"
