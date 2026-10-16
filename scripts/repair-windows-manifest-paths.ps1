param([Parameter(Mandatory)][string]$InputPath,[Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference='Stop'
if([IO.Path]::GetFullPath($InputPath) -eq [IO.Path]::GetFullPath($OutputPath)){throw 'Use a separate candidate'}
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'import-semantic-function-closure.ps1'),[ref]$null,[ref]$null)
$reader=$ast.Find({param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Read-SemanticGraph'},$false)
. ([scriptblock]::Create($reader.Extent.Text))
$g=Read-SemanticGraph $InputPath;$n=@{};foreach($v in $g.Nodes){$n[[int]$v.id]=$v}
$r=[Collections.Generic.List[object]]::new();foreach($v in $g.Relations){$r.Add($v)}
$added=[Collections.Generic.List[object]]::new();$next=1+[int](($n.Keys|Measure-Object -Maximum).Maximum)
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'patch-slice-native-execution.ps1'),[ref]$null,[ref]$null)
foreach($f in $ast.FindAll({param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
$root=Fn resolve_manifest_path;$body=Child $root body
$queue=[Collections.Generic.Queue[int]]::new();$seen=[Collections.Generic.HashSet[int]]::new();$queue.Enqueue($root)
while($queue.Count){$id=$queue.Dequeue();if(!$seen.Add($id)){continue};foreach($edge in @($r|Where-Object {$_.kind -eq 'syntax.child' -and [int]$_.from -eq $id})){$queue.Enqueue([int]$edge.to.id)}}
$matches=@()
foreach($id in $seen){
 if($n[$id].structural_kind -ne 'OperationExpr' -or $n[$id].fields.operation.semantic_id -ne 'equal'){continue}
 $right=Child $id right
 if($n[$right].structural_kind -eq 'LiteralExpr' -and $n[$right].fields.operation.text -eq '47'){$matches+=,$id}
}
if($matches.Count -ne 2){throw 'Expected two existing slash checks'}
foreach($id in $matches){
 $incoming=@($r|Where-Object {$_.kind -eq 'syntax.child' -and [int]$_.to.id -eq $id})
 $left=Child $id left
 $replacement=Op bit_or $id (Op equal $left (Lit 92))
 foreach($edge in $incoming){$edge.to.id=[string]$replacement}
}
# Drive-absolute paths require both colon and separator; C:relative is not
# silently treated as an absolute path. Length check precedes byte reads.
$outer=Node IfStmt ([ordered]@{kind='if'});$outerBody=Node Scope ([ordered]@{kind='block'})
Edge $outer (Op greater_or_equal (Call cstrlen @((Ref rel))) (Lit 3)) condition 0
Edge $outer $outerBody then 0
$drive=Node IfStmt ([ordered]@{kind='if'});$driveBody=Node Scope ([ordered]@{kind='block'})
$colon=Op equal (Call load8 @((Op add (Ref rel) (Lit 1)))) (Lit 58)
$separator=Op bit_or (Op equal (Call load8 @((Op add (Ref rel) (Lit 2)))) (Lit 47)) (Op equal (Call load8 @((Op add (Ref rel) (Lit 2)))) (Lit 92))
Edge $drive (Op bit_and $colon $separator) condition 0;Edge $drive $driveBody then 0
Edge $outerBody $drive statement 0
Edge $driveBody (Expr (Call copy_slice_z @((Ref rel),(Call cstrlen @((Ref rel))),(Ref out)))) statement 0
Edge $driveBody (Ret (Ref out)) statement 1
Insert $body $outer 0
$text=[IO.File]::ReadAllText((Resolve-Path $InputPath))
$json=(@($added)|ForEach-Object {$_|ConvertTo-Json -Depth 100 -Compress}) -join ",`n"
$text=[regex]::Replace($text,'(?ms)^nodes\s*=\[.*?^\]',[Text.RegularExpressions.MatchEvaluator]{param($m)$m.Value.Substring(0,$m.Value.Length-1).TrimEnd()+",`n"+$json+"`n]"},1)
$json=(@($r)|ForEach-Object {$_|ConvertTo-Json -Depth 100 -Compress}) -join ",`n"
$text=[regex]::Replace($text,'(?ms)^relations\s*=\[.*?^\]',[Text.RegularExpressions.MatchEvaluator]{param($m)"relations=[`n$json`n]"},1)
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),$text,[Text.UTF8Encoding]::new($false))
"WINDOWS_SEPARATOR_CHECKS=2 DRIVE_ABSOLUTE_GUARD=1 OUTPUT=$OutputPath"
