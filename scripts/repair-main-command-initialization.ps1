param([Parameter(Mandatory)][string]$InputPath,[Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference='Stop'
if([IO.Path]::GetFullPath($InputPath) -eq [IO.Path]::GetFullPath($OutputPath)){throw 'Use separate candidate output'}
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'import-semantic-function-closure.ps1'),[ref]$null,[ref]$null)
$reader=$ast.Find({param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Read-SemanticGraph'},$false)
. ([scriptblock]::Create($reader.Extent.Text))
$g=Read-SemanticGraph $InputPath;$nodes=@{};$children=@{}
foreach($n in $g.Nodes){$nodes[[int]$n.id]=$n}
foreach($r in $g.Relations){if($r.kind -eq 'syntax.child'){$key=[int]$r.from;if(!$children.ContainsKey($key)){$children[$key]=[Collections.Generic.List[object]]::new()};$children[$key].Add($r)}}
$main=@($g.Nodes|Where-Object{$_.structural_kind -eq 'ClosureExpr' -and $_.fields.operation.function_binding -eq 'main'})
if($main.Count -ne 1){throw 'Expected unique main'}
$body=@($children[[int]$main[0].id]|Where-Object{$_.attributes.role -eq 'body'})
if($body.Count -ne 1){throw 'Expected main body'}
$statements=@($children[[int]$body[0].to.id]|Where-Object{$_.attributes.role -eq 'statement'}|Sort-Object{$_.attributes.ordinal})
$command=@($statements|Where-Object{$nodes[[int]$_.to.id].structural_kind -eq 'AssignStmt' -and $nodes[[int]$_.to.id].fields.name -eq 'cmd'}|Select-Object -First 1)
if($command.Count -ne 1){throw 'Expected command initialization'}
$move=[Collections.Generic.List[object]]::new()
foreach($statement in $statements){
 if([int]$statement.attributes.ordinal -ge [int]$command[0].attributes.ordinal){continue}
 $seen=[Collections.Generic.HashSet[int]]::new();$queue=[Collections.Generic.Queue[int]]::new();$queue.Enqueue([int]$statement.to.id);$reads=$false
 while($queue.Count){$id=$queue.Dequeue();if(!$seen.Add($id)){continue};if($nodes[$id].structural_kind -eq 'SymbolRef' -and $nodes[$id].fields.name -eq 'cmd'){$reads=$true};if($children.ContainsKey($id)){foreach($r in $children[$id]){$queue.Enqueue([int]$r.to.id)}}}
 if($reads){$move.Add($statement)}
}
$ordered=[Collections.Generic.List[object]]::new()
foreach($statement in $statements){
 if($move.Contains($statement)){continue}
 $ordered.Add($statement)
 if($statement -eq $command[0]){foreach($item in $move){$ordered.Add($item)}}
}
for($i=0;$i -lt $ordered.Count;$i++){$ordered[$i].attributes.ordinal=$i}
$text=[IO.File]::ReadAllText((Resolve-Path $InputPath))
# The bootstrap reader requires fields.kind first. Normalize only the moved
# guard subtrees, preserving the representation of unrelated compiler nodes.
$guardIds=[Collections.Generic.HashSet[int]]::new()
$pending=[Collections.Generic.Queue[int]]::new()
foreach($item in $move){$pending.Enqueue([int]$item.to.id)}
while($pending.Count){$id=$pending.Dequeue();if(!$guardIds.Add($id)){continue};if($children.ContainsKey($id)){foreach($edge in $children[$id]){$pending.Enqueue([int]$edge.to.id)}}}
$text=[regex]::Replace($text,'(?m)^\{"id":\d+,"structural_kind":.*$', [Text.RegularExpressions.MatchEvaluator]{param($m)
 $node=$m.Value.TrimEnd(',')|ConvertFrom-Json
 if(!$guardIds.Contains([int]$node.id)){return $m.Value}
 $fields=[ordered]@{kind=$node.fields.kind}
 foreach($property in $node.fields.PSObject.Properties){if($property.Name -ne 'kind'){$fields[$property.Name]=$property.Value}}
 $node.fields=$fields
 ($node|ConvertTo-Json -Compress -Depth 100)+$(if($m.Value.EndsWith(',')){','}else{''})
})
$json=(@($g.Relations)|ForEach-Object{$_|ConvertTo-Json -Depth 100 -Compress}) -join ",`n"
$text=[regex]::Replace($text,'(?ms)^relations\s*=\[.*?^\]',[Text.RegularExpressions.MatchEvaluator]{param($m)"relations=[`n$json`n]"},1)
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),$text,[Text.UTF8Encoding]::new($false))
"OUTPUT=$OutputPath MOVED_UNINITIALIZED_CMD_READS=$($move.Count)"
