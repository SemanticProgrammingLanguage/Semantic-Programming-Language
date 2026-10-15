param([Parameter(Mandatory=$true)][string]$InputPath,[Parameter(Mandatory=$true)][string]$OutputPath)
$ErrorActionPreference='Stop'
$lines=[IO.File]::ReadAllLines((Resolve-Path -LiteralPath $InputPath).Path)
$nodes=@{};$rels=[Collections.Generic.List[object]]::new();$section='';$nodeEnd=-1;$relEnd=-1
for($i=0;$i -lt $lines.Count;$i++){
 $s=$lines[$i].Trim().TrimEnd(',')
 if($s -eq 'nodes=['){$section='n';continue};if($s -eq 'relations=['){$section='r';continue}
 if($s -eq ']'){if($section -eq 'n'){$nodeEnd=$i};if($section -eq 'r'){$relEnd=$i};$section='';continue}
 if(!$s.StartsWith('{')){continue};$o=$s|ConvertFrom-Json
 if($section -eq 'n'){$nodes[[int]$o.id]=$o}elseif($section -eq 'r'){$rels.Add($o)}
}
function Rows([int]$id,[string]$role){@($script:rels|Where-Object {$_.kind -eq 'syntax.child' -and [int]$_.from -eq $id -and $_.attributes.role -eq $role})}
$fn=@($nodes.Values|Where-Object {$_.structural_kind -eq 'ClosureExpr' -and $_.fields.name -eq 'compile_stmt'})
if($fn.Count -ne 1){throw 'Expected unique compile_stmt'}
$body=[int](Rows $fn[0].id 'body')[0].to.id
$branch=@(Rows $body 'statement'|Where-Object {
 $n=$nodes[[int]$_.to.id];if($n.structural_kind -ne 'IfStmt'){return $false}
 $cond=Rows $n.id 'condition';if($cond.Count -ne 1){return $false};$right=Rows ([int]$cond[0].to.id) 'right'
 $right.Count -eq 1 -and $nodes[[int]$right[0].to.id].fields.operation.text -eq '9'
})
if($branch.Count -ne 1){throw 'Expected ReturnStmt backend branch'}
$scope=[int](Rows ([int]$branch[0].to.id) 'then')[0].to.id
$stmts=@(Rows $scope 'statement'|Sort-Object {$_.attributes.ordinal})
if($nodes[[int]$stmts[0].to.id].fields.name -ne 'x'){throw 'Expected return operand lookup first'}
foreach($r in $stmts){if([int]$r.attributes.ordinal -ge 1){$r.attributes.ordinal++}}
$new=[Collections.Generic.List[object]]::new();$next=1+[int]($nodes.Keys|Measure-Object -Maximum).Maximum
function Node($kind,$fields){$id=$script:next;$script:next++;$script:new.Add([ordered]@{id=$id;structural_kind=$kind;fields=$fields});$id}
function Edge($a,$b,$role,$ord){$script:rels.Add([ordered]@{kind='syntax.child';from=$a;to=@{domain='node';id=[string]$b};attributes=@{role=$role;ordinal=$ord}})}
$cond=Node 'OperationExpr' ([ordered]@{kind='binary';operation=@{semantic_id='equal';semantics=@{operation='equal'}}})
$x=Node 'SymbolRef' ([ordered]@{kind='identifier';name='x'});$minus=Node 'LiteralExpr' ([ordered]@{kind='literal';operation=@{literal_kind='integer';text='-1'}})
Edge $cond $x 'left' 0;Edge $cond $minus 'right' 1
$test=Node 'IfStmt' ([ordered]@{kind='if'});$then=Node 'Scope' ([ordered]@{kind='block'});Edge $test $cond 'condition' 0;Edge $test $then 'then' 0;Edge $scope $test 'statement' 1
$call=Node 'CallExpr' ([ordered]@{kind='call'});$callee=Node 'SymbolRef' ([ordered]@{kind='identifier';name='child'});Edge $call $callee 'callee' 0
$ops=@((Node 'SymbolRef' ([ordered]@{kind='identifier';name='c'})),(Node 'SymbolRef' ([ordered]@{kind='identifier';name='id'})),(Node 'LiteralExpr' ([ordered]@{kind='literal';operation=@{literal_kind='integer';text='12'}})),(Node 'LiteralExpr' ([ordered]@{kind='literal';operation=@{literal_kind='integer';text='0'}})))
for($j=0;$j -lt $ops.Count;$j++){Edge $call $ops[$j] 'argument' $j}
$set=Node 'AssignStmt' ([ordered]@{kind='assign';name='x'});Edge $set $call 'expression' 0;Edge $then $set 'statement' 0
$out=[Collections.Generic.List[string]]::new()
for($i=0;$i -lt $nodeEnd;$i++){$out.Add($lines[$i])};$out[$out.Count-1]=$out[$out.Count-1].TrimEnd(',')+','
for($i=0;$i -lt $new.Count;$i++){$suffix=if($i -lt $new.Count-1){','}else{''};$out.Add(($new[$i]|ConvertTo-Json -Compress -Depth 50)+$suffix)}
$out.Add(']');$out.Add('relations=[')
for($i=0;$i -lt $rels.Count;$i++){$suffix=if($i -lt $rels.Count-1){','}else{''};$out.Add(($rels[$i]|ConvertTo-Json -Compress -Depth 80)+$suffix)}
for($i=$relEnd;$i -lt $lines.Count;$i++){$out.Add($lines[$i])}
$dest=[IO.Path]::GetFullPath($OutputPath);[IO.Directory]::CreateDirectory((Split-Path -Parent $dest))|Out-Null;[IO.File]::WriteAllLines($dest,$out,[Text.UTF8Encoding]::new($false))
"RETURN_VALUE_NATIVE_FALLBACK=$dest"
