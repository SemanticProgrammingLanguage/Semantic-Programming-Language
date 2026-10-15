[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$InputPath,[Parameter(Mandatory=$true)][string]$OutputPath)
$ErrorActionPreference='Stop'
Remove-Item Alias:r -Force -ErrorAction SilentlyContinue
$lines=[IO.File]::ReadAllLines((Resolve-Path -LiteralPath $InputPath).Path)
$nodes=@{};$rels=[Collections.Generic.List[object]]::new();$section='';$start=-1;$end=-1
for($i=0;$i -lt $lines.Count;$i++){$s=$lines[$i].Trim().TrimEnd(',');if($s -eq 'nodes=['){$section='n';$start=$i;continue};if($s -eq 'relations=['){$section='r';continue};if($s -eq ']'){if($section -eq 'r'){$end=$i};$section='';continue};if(!$s.StartsWith('{')){continue};$o=$s|ConvertFrom-Json;if($section -eq 'n'){$nodes[[int]$o.id]=$o}elseif($section -eq 'r'){$rels.Add($o)}}
$next=1+[int]($nodes.Keys|Measure-Object -Maximum).Maximum
function N($k,$f){$id=$script:next;$script:next++;$fields=[ordered]@{kind=$f.kind};foreach($key in $f.Keys|Where-Object {$_ -ne 'kind'}|Sort-Object){$fields[$key]=$f[$key]};$script:nodes[$id]=[pscustomobject]@{id=$id;structural_kind=$k;fields=[pscustomobject]$fields};$id}
function E($a,$b,$role,$ordinal){$script:rels.Add([pscustomobject]@{kind='syntax.child';from=$a;to=[ordered]@{domain='node';id=[string]$b};attributes=[ordered]@{role=$role;ordinal=$ordinal}})}
function R($id,$role){@($script:rels|Where-Object {$_.kind -eq 'syntax.child' -and [int]$_.from -eq $id -and $_.attributes.role -eq $role}|Sort-Object {$_.attributes.ordinal})}
function Ref($name){N 'SymbolRef' @{kind='identifier';name=$name}}
function Int($v){N 'LiteralExpr' @{kind='literal';operation=@{literal_kind='integer';text=[string]$v}}}
function Call($name,[int[]]$operands){$id=N 'CallExpr' @{kind='call'};E $id (Ref $name) 'callee' 0;for($j=0;$j -lt $operands.Count;$j++){E $id $operands[$j] 'argument' $j};$id}
function Assign($name,$value){$id=N 'AssignStmt' @{kind='assign';name=$name};E $id $value 'expression' 0;$id}
function Expr($v){$id=N 'ExprStmt' @{kind='expression'};E $id $v 'expression' 0;$id}
function Ret($v){$id=N 'ReturnStmt' @{kind='return'};E $id $v 'expression' 0;$id}
function Op($op,$a,$b){$id=N 'OperationExpr' @{kind='binary';operation=@{semantic_id=$op;semantics=@{operation=$op}}};E $id $a 'left' 0;E $id $b 'right' 1;$id}
function Insert($scope,$stmt,$at){foreach($r in @(R $scope 'statement')){if([int]$r.attributes.ordinal -ge $at){$r.attributes.ordinal++}};E $scope $stmt 'statement' $at}
function FindClosure($name){$f=@($script:nodes.Values|Where-Object {$_.structural_kind -eq 'ClosureExpr' -and $_.fields.name -eq $name});if($f.Count -ne 1){throw "Expected unique $name"};[int]$f[0].id}
function Tree($id){$adj=@{};foreach($r in $script:rels){if($r.kind -ne 'syntax.child'){continue};$f=[int]$r.from;if(!$adj.ContainsKey($f)){$adj[$f]=[Collections.Generic.List[int]]::new()};$adj[$f].Add([int]$r.to.id)};$seen=[Collections.Generic.HashSet[int]]::new();$q=[Collections.Generic.Queue[int]]::new();$q.Enqueue($id);while($q.Count){$cur=$q.Dequeue();if(!$seen.Add($cur)){continue};foreach($to in $adj[$cur]){$q.Enqueue($to)}};,$seen}
$stmt=FindClosure 'compile_stmt';$scope=[int](R $stmt 'body')[0].to.id
$sub=Tree $stmt
# Move only loop-context accesses. Offset96 is the graph's maximum node ID;
# offset121 was unaligned and overlapped metadata. New slots216/224 are free.
foreach($id in $sub){$n=$nodes[$id];if($n.structural_kind -ne 'CallExpr'){continue};$c=R $id 'callee';if($c.Count -ne 1 -or $nodes[[int]$c[0].to.id].fields.name -notin @('ctx_get','ctx_set')){continue};$a=R $id 'argument';if($a.Count -lt 2){continue};$old=$nodes[[int]$a[1].to.id];if($old.structural_kind -ne 'LiteralExpr'){continue};if($old.fields.operation.text -eq '96'){$old.fields.operation.text='216'}elseif($old.fields.operation.text -eq '121'){$old.fields.operation.text='224'}}
$branches=@{};foreach($r in @(R $scope 'statement')){$n=$nodes[[int]$r.to.id];if($n.structural_kind -ne 'IfStmt'){continue};$c=R $n.id 'condition';if($c.Count -ne 1){continue};$lhs=R ([int]$c[0].to.id) 'left';$rhs=R ([int]$c[0].to.id) 'right';if($lhs.Count -ne 1 -or $rhs.Count -ne 1 -or $nodes[[int]$lhs[0].to.id].fields.name -ne 'k'){continue};$tag=$nodes[[int]$rhs[0].to.id].fields.operation.text;if($tag -in @('11','14','15')){$branches[$tag]=[int](R $n.id 'then')[0].to.id}}
foreach($pair in @(@('14',216),@('15',224))){$b=$branches[$pair[0]];if(!$b){throw 'Missing control branch'};$test=N 'IfStmt' @{kind='if'};$body=N 'Scope' @{kind='block'};E $test (Op 'less_or_equal' (Call 'ctx_get' @((Ref 'c'),(Int $pair[1]))) (Int 0)) 'condition' 0;E $test $body 'then' 0;E $body (Expr (Call 'ctx_set' @((Ref 'c'),(Int 208),(Int 1)))) 'statement' 0;E $body (Ret (Int -1)) 'statement' 1;Insert $b $test 0}
$loop=$branches['11'];if(!$loop){throw 'Missing loop body'}
$callstmt=@(R $loop 'statement'|Where-Object {$n=$nodes[[int]$_.to.id];if($n.structural_kind -ne 'ExprStmt'){return $false};$x=R $n.id 'expression';if($x.Count -ne 1){return $false};$c=R ([int]$x[0].to.id) 'callee';$c.Count -eq 1 -and $nodes[[int]$c[0].to.id].fields.name -eq 'compile_stmt'})
if($callstmt.Count -ne 1){throw 'Expected one loop body compilation'}
$setrow=@(R $loop 'statement'|Where-Object {[int]$_.to.id -eq 20539});if($setrow.Count -ne 1){throw 'Expected existing loop break-context setter'}
$at=[int]$setrow[0].attributes.ordinal
Insert $loop (Assign 'outer_break_target' (Call 'ctx_get' @((Ref 'c'),(Int 216)))) $at
Insert $loop (Assign 'outer_continue_target' (Call 'ctx_get' @((Ref 'c'),(Int 224)))) ($at+1)
$at=[int]$callstmt[0].attributes.ordinal+1
Insert $loop (Expr (Call 'ctx_set' @((Ref 'c'),(Int 216),(Ref 'outer_break_target')))) $at
Insert $loop (Expr (Call 'ctx_set' @((Ref 'c'),(Int 224),(Ref 'outer_continue_target')))) ($at+1)
$f=FindClosure 'compile_func';$b=[int](R $f 'body')[0].to.id
Insert $b (Expr (Call 'ctx_set' @((Ref 'c'),(Int 216),(Int 0)))) 0
Insert $b (Expr (Call 'ctx_set' @((Ref 'c'),(Int 224),(Int 0)))) 1
# These native tags currently lack a complete reader/layout contract. Reject
# them before family projection can erase their identity or invoke a missing
# legacy helper. Index operands are validated at the same real entry point.
$ex=FindClosure 'compile_expr';$xb=[int](R $ex 'body')[0].to.id
$at=1
foreach($tag in @(19,20)){
 $test=N 'IfStmt' @{kind='if'};$tb=N 'Scope' @{kind='block'};E $test (Op 'equal' (Ref 'k') (Int $tag)) 'condition' 0;E $test $tb 'then' 0
 E $tb (Expr (Call 'ctx_set' @((Ref 'c'),(Int 208),(Int 1)))) 'statement' 0;E $tb (Ret (Int -1)) 'statement' 1;Insert $xb $test $at;$at++
}
$test=N 'IfStmt' @{kind='if'};$tb=N 'Scope' @{kind='block'};E $test (Op 'equal' (Ref 'k') (Int 18)) 'condition' 0;E $test $tb 'then' 0
$bad=N 'IfStmt' @{kind='if'};$bb=N 'Scope' @{kind='block'}
$base=Op 'less_than' (Call 'child' @((Ref 'c'),(Ref 'id'),(Int 12),(Int 0))) (Int 0)
$index=Op 'less_than' (Call 'child' @((Ref 'c'),(Ref 'id'),(Int 6),(Int 0))) (Int 0)
E $bad (Op 'bit_or' $base $index) 'condition' 0;E $bad $bb 'then' 0;E $tb $bad 'statement' 0
E $bb (Expr (Call 'ctx_set' @((Ref 'c'),(Int 208),(Int 1)))) 'statement' 0;E $bb (Ret (Int -1)) 'statement' 1;Insert $xb $test $at
$out=[Collections.Generic.List[string]]::new();foreach($line in $lines[0..($start-1)]){$out.Add($line)};$out.Add('nodes=[');$all=@($nodes.Values|Sort-Object {[int]$_.id});for($i=0;$i -lt $all.Count;$i++){$suffix=if($i -lt $all.Count-1){','}else{''};$out.Add(($all[$i]|ConvertTo-Json -Compress -Depth 100)+$suffix)};$out.Add(']');$out.Add('relations=[');for($i=0;$i -lt $rels.Count;$i++){$suffix=if($i -lt $rels.Count-1){','}else{''};$out.Add(($rels[$i]|ConvertTo-Json -Compress -Depth 100)+$suffix)};for($i=$end;$i -lt $lines.Count;$i++){$out.Add($lines[$i])};$dest=[IO.Path]::GetFullPath($OutputPath);[IO.Directory]::CreateDirectory((Split-Path -Parent $dest))|Out-Null;[IO.File]::WriteAllLines($dest,$out,[Text.UTF8Encoding]::new($false));"LOOP_CONTEXT_PATCH=$dest"
