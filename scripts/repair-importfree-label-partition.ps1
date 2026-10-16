param([Parameter(Mandatory)][string]$InputPath,[Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference='Stop'
if([IO.Path]::GetFullPath($InputPath) -eq [IO.Path]::GetFullPath($OutputPath)){throw 'Separate output required'}
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'import-semantic-function-closure.ps1'),[ref]$null,[ref]$null)
$reader=$ast.Find({param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Read-SemanticGraph'},$false)
. ([scriptblock]::Create($reader.Extent.Text))
$g=Read-SemanticGraph $InputPath;$nodes=@{};$children=@{}
foreach($node in $g.Nodes){$nodes[[int]$node.id]=$node}
foreach($r in $g.Relations){if($r.kind -eq 'syntax.child'){$key=[int]$r.from;if(!$children.ContainsKey($key)){$children[$key]=[Collections.Generic.List[object]]::new()};$children[$key].Add($r)}}
function Subtree([int]$Root){
 $seen=[Collections.Generic.HashSet[int]]::new();$q=[Collections.Generic.Queue[int]]::new();$q.Enqueue($Root)
 while($q.Count){$id=$q.Dequeue();if(!$seen.Add($id)){continue};if($children.ContainsKey($id)){foreach($r in $children[$id]){$q.Enqueue([int]$r.to.id)}}}
 return ,$seen
}
$changed=@{}
foreach($name in @('compile_ifree_runtime_call','emit_ifree_entry','emit_ifree_runtime_template')){
 $root=@($g.Nodes|Where-Object {$_.structural_kind -eq 'ClosureExpr' -and $_.fields.operation.function_binding -eq $name})
 if($root.Count -ne 1){throw "Nonunique closure $name"}
 foreach($id in (Subtree ([int]$root[0].id))){
  $node=$nodes[$id]
  if($node.structural_kind -ne 'OperationExpr' -or $node.fields.operation.semantic_id -ne 'multiply'){continue}
  $left=@($children[$id]|Where-Object {$_.attributes.role -eq 'left'})
  if($left.Count -eq 1){$value=$nodes[[int]$left[0].to.id];if($value.structural_kind -eq 'LiteralExpr' -and $value.fields.operation.text -eq '10'){$value.fields.operation.text='11';$changed[[int]$value.id]=$value}}
 }
}
# [0,4096+11*stride) is owned by the existing compiler, including
# foreach continue labels in group 10. Reserve seven new labels after it.
$allocation=@($g.Nodes|Where-Object {$_.structural_kind -eq 'AssignStmt' -and $_.fields.name -eq 'native_label_count'})
if($allocation.Count -ne 1){throw 'Expected unique native label allocation'}
foreach($id in (Subtree ([int]$allocation[0].id))){$node=$nodes[$id];if($node.structural_kind -eq 'LiteralExpr' -and $node.fields.operation.text -eq '4096'){$node.fields.operation.text='4103';$changed[$id]=$node}}
if($changed.Count -ne 5){throw "Expected four runtime bases and one capacity change; got $($changed.Count)"}
$text=[IO.File]::ReadAllText((Resolve-Path $InputPath))
$text=[regex]::Replace($text,'(?m)^\{"id":\d+,"structural_kind":.*$', [Text.RegularExpressions.MatchEvaluator]{param($m)
 $match=[regex]::Match($m.Value,'^\{"id":(\d+),')
 $id=[int]$match.Groups[1].Value
 if(!$changed.ContainsKey($id)){return $m.Value}
 ($changed[$id]|ConvertTo-Json -Depth 100 -Compress)+$(if($m.Value.EndsWith(',')){','}else{''})
})
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),$text,[Text.UTF8Encoding]::new($false))
"LABEL_PARTITION_FIXES=$($changed.Count) OUTPUT=$OutputPath"
