param([Parameter(Mandatory)][string]$InputPath,[Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference='Stop'
if([IO.Path]::GetFullPath($InputPath) -eq [IO.Path]::GetFullPath($OutputPath)){throw 'Use a candidate output'}
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'import-semantic-function-closure.ps1'),[ref]$null,[ref]$null)
$reader=$ast.Find({param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Read-SemanticGraph'},$false)
. ([scriptblock]::Create($reader.Extent.Text))
$g=Read-SemanticGraph $InputPath;$nodes=@{};$children=@{}
foreach($node in $g.Nodes){$nodes[[int]$node.id]=$node}
foreach($r in $g.Relations){if($r.kind -eq 'syntax.child'){$key=[int]$r.from;if(!$children.ContainsKey($key)){$children[$key]=[Collections.Generic.List[object]]::new()};$children[$key].Add($r)}}
function Walk([int]$root){
 $seen=[Collections.Generic.HashSet[int]]::new();$q=[Collections.Generic.Queue[int]]::new();$q.Enqueue($root)
 while($q.Count){$id=$q.Dequeue();if(!$seen.Add($id)){continue};if($children.ContainsKey($id)){foreach($edge in $children[$id]){$q.Enqueue([int]$edge.to.id)}}}
 return ,$seen
}
$main=@($g.Nodes|Where-Object {$_.structural_kind -eq 'ClosureExpr' -and $_.fields.operation.function_binding -eq 'main'})
if($main.Count -ne 1){throw 'Expected unique main'}
$candidates=@()
foreach($id in (Walk ([int]$main[0].id))){
 if($nodes[$id].structural_kind -ne 'IfStmt'){continue}
 $condition=@($children[$id]|Where-Object {$_.attributes.role -eq 'condition'})
 if($condition.Count -ne 1 -or $nodes[[int]$condition[0].to.id].structural_kind -ne 'CallExpr'){continue}
 $subtree=@((Walk $id)|ForEach-Object {$nodes[$_]})
 if(@($subtree|Where-Object {$_.structural_kind -eq 'LiteralExpr' -and $_.fields.operation.text -eq '--embed-all'}).Count -ne 1){continue}
 if(@($subtree|Where-Object {$_.structural_kind -eq 'AssignStmt' -and $_.fields.name -eq 'rc'}).Count -ne 1){continue}
 if(@($subtree|Where-Object {$_.structural_kind -eq 'SymbolRef' -and $_.fields.name -eq 'compile_smod_all'}).Count -ne 1){continue}
 $candidates+=,$id
}
if($candidates.Count -ne 1){throw "Expected unique redundant SMOD guard, got $($candidates.Count)"}
$remove=[int]$candidates[0]
$parent=@($g.Relations|Where-Object {$_.kind -eq 'syntax.child' -and [int]$_.to.id -eq $remove -and $_.attributes.role -eq 'statement'})
if($parent.Count -ne 1){throw 'Expected unique statement parent'}
$body=[int]$parent[0].from
$statements=@($children[$body]|Where-Object {$_.attributes.role -eq 'statement'}|Sort-Object {$_.attributes.ordinal})
$last=$nodes[[int]$statements[-1].to.id]
if($last.structural_kind -ne 'ReturnStmt'){throw 'Expected unconditional SMOD result after guard'}
$lastSubtree=@((Walk ([int]$last.id))|ForEach-Object {$nodes[$_]})
if(@($lastSubtree|Where-Object {$_.structural_kind -eq 'SymbolRef' -and $_.fields.name -eq 'compile_smod_all'}).Count -ne 1){throw 'Missing final compile_smod_all'}
# The unconditional final return already implements the same compile operation.
# Drop only the redundant statement edge, retaining nodes and other relations.
$relations=@($g.Relations|Where-Object {-not($_.kind -eq 'syntax.child' -and [int]$_.from -eq $body -and $_.attributes.role -eq 'statement' -and [int]$_.to.id -eq $remove)})
$ordered=@($relations|Where-Object {$_.kind -eq 'syntax.child' -and [int]$_.from -eq $body -and $_.attributes.role -eq 'statement'}|Sort-Object {$_.attributes.ordinal})
for($i=0;$i -lt $ordered.Count;$i++){$ordered[$i].attributes.ordinal=$i}
$text=[IO.File]::ReadAllText((Resolve-Path $InputPath))
$json=(@($relations)|ForEach-Object {$_|ConvertTo-Json -Depth 100 -Compress}) -join ",`n"
$text=[regex]::Replace($text,'(?ms)^relations\s*=\[.*?^\]',[Text.RegularExpressions.MatchEvaluator]{param($m)"relations=[`n$json`n]"},1)
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),$text,[Text.UTF8Encoding]::new($false))
"REMOVED_REDUNDANT_SMOD_GUARD=$remove OUTPUT=$OutputPath"
