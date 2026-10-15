[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$InputPath,[Parameter(Mandatory=$true)][string]$OutputPath)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

# Flat BindingPattern <- TupleExpr candidate. RHS members are evaluated in
# order into temporary frame slots before any target store; nested/rest/
# wildcard patterns are intentionally not activated by this contract.
$lines=[IO.File]::ReadAllLines((Resolve-Path -LiteralPath $InputPath).Path)
$nodes=@{};$rels=[Collections.Generic.List[object]]::new();$section='';$nodeStart=-1;$relationEnd=-1
for($i=0;$i -lt $lines.Count;$i++){
  $t=$lines[$i].Trim().TrimStart(',').TrimEnd(',')
  if($t -eq 'nodes=['){$section='n';$nodeStart=$i;continue}
  if($t -eq 'relations=['){$section='r';continue}
  if($t -eq ']' -and $section -eq 'r'){$relationEnd=$i;$section='';continue}
  if($t -eq ']'){$section='';continue}
  if(!$t.StartsWith('{')){continue};$o=$t|ConvertFrom-Json
  if($section -eq 'n'){$nodes[[int]$o.id]=$o}elseif($section -eq 'r'){$rels.Add($o)}
}
if($nodeStart -lt 0 -or $relationEnd -lt 0){throw 'Expected Semantic document node/relation sections'}
$used=[Collections.Generic.HashSet[int]]::new();foreach($id in $nodes.Keys){[void]$used.Add([int]$id)};$next=1+[int]($nodes.Keys|Measure-Object -Maximum).Maximum
function NewNode([string]$k,[hashtable]$f){while($script:used.Contains($script:next)){$script:next++};$id=$script:next;$script:next++;[void]$script:used.Add($id);$ordered=[ordered]@{kind=$f.kind};foreach($key in $f.Keys|Where-Object {$_ -ne 'kind'}|Sort-Object){$ordered[$key]=$f[$key]};$script:nodes[$id]=[pscustomobject]@{id=$id;structural_kind=$k;fields=[pscustomobject]$ordered};$id}
function AddChild([int]$a,[int]$b,[string]$r,[int]$o){$script:rels.Add([pscustomobject]@{kind='syntax.child';from=$a;to=[pscustomobject]@{domain='node';id=[string]$b};attributes=[pscustomobject]@{missing=$false;name='';ordinal=$o;role=$r}})}
function Rows([int]$id,[string]$role){@($script:rels|Where-Object{$_.kind -eq 'syntax.child' -and [int]$_.from -eq $id -and $_.attributes.role -eq $role}|Sort-Object {[int]$_.attributes.ordinal})}
function Ref([string]$n){NewNode 'SymbolRef' @{kind='identifier';name=$n}}
function Int([long]$n){NewNode 'LiteralExpr' @{kind='literal';operation=[pscustomobject]@{literal_kind='integer';text=[string]$n}}}
function Op([string]$name,[int]$a,[int]$b){$x=NewNode 'OperationExpr' @{kind='binary';operation=[pscustomobject]@{semantic_id=$name;semantics=[pscustomobject]@{operation=$name}}};AddChild $x $a 'left' 0;AddChild $x $b 'right' 1;$x}
function Call([string]$name,[int[]]$operands){$x=NewNode 'CallExpr' @{kind='call'};AddChild $x (Ref $name) 'callee' 0;for($j=0;$j -lt $operands.Count;$j++){AddChild $x $operands[$j] 'argument' $j};$x}
function Assign([string]$name,[int]$expr){$x=NewNode 'AssignStmt' @{kind='assign';name=$name};AddChild $x $expr 'expression' 0;$x}
function ExprStmt([int]$expr){$x=NewNode 'ExprStmt' @{kind='expression'};AddChild $x $expr 'expression' 0;$x}
function Return([int]$expr){$x=NewNode 'ReturnStmt' @{kind='return'};AddChild $x $expr 'expression' 0;$x}
function AddStmt([int]$scope,[int]$stmt,[int]$ord){AddChild $scope $stmt 'statement' $ord}
function NewIf([int]$cond){$i=NewNode 'IfStmt' @{kind='if'};$s=NewNode 'Scope' @{kind='block'};AddChild $i $cond 'condition' 0;AddChild $i $s 'then' 0;$i}
function Closure([string]$name){$a=@($script:nodes.Values|Where-Object{$_.structural_kind -eq 'ClosureExpr' -and $null -ne $_.fields.PSObject.Properties['operation'] -and $null -ne $_.fields.operation -and $_.fields.operation.function_binding -ceq $name});if($a.Count -ne 1){throw "Expected one closure $name; found $($a.Count)"};[int]$a[0].id}

# Add explicit structural role IDs without altering existing role assignments.
$rid=Closure 'role_code';$rb=[int](Rows $rid 'body'|Select-Object -First 1).to.id;$rr=Rows $rb 'statement';$rf=@($rr|Where-Object{$nodes[[int]$_.to.id].structural_kind -eq 'ReturnStmt'}|Select-Object -Last 1)
if($rf.Count -ne 1){throw 'role_code fallback not found'};$insert=[int]$rf[0].attributes.ordinal
foreach($r in $rels){if($r.kind -eq 'syntax.child' -and [int]$r.from -eq $rb -and $r.attributes.role -eq 'statement' -and [int]$r.attributes.ordinal -ge $insert){$r.attributes.ordinal+=2}}
foreach($pair in @(@('target',24),@('child',25))){
  $str=NewNode 'LiteralExpr' @{kind='literal';operation=[pscustomobject]@{literal_kind='string';text=$pair[0]}}
  $cmp=Call 'slice_eq_cstr' @((Ref 'p'),(Ref 'n'),$str);$if=NewIf $cmp;$scope=[int](Rows $if 'then'|Select-Object -First 1).to.id
  AddStmt $scope (Return (Int ([int]$pair[1]))) 0;AddChild $rb $if 'statement' $insert;$insert++
}
# The existing role registry has a hole at statement ordinal 13. The native
# scope emitter stops at the first missing ordinal, so later role rules were
# present in the graph but absent from its emitted body. Preserve their order
# and make the sequence contiguous.
$roleStatements=Rows $rb 'statement';for($j=0;$j -lt $roleStatements.Count;$j++){$roleStatements[$j].attributes.ordinal=$j}

# The compiler reader normalizes names through kind_code before backend
# dispatch. Recognize TupleExpr as the already implemented aggregate kind and
# reserve a distinct non-core tag for BindingPattern (handled only as an
# AssignStmt target by the guarded path below).
$kid=Closure 'kind_code';$kb=[int](Rows $kid 'body'|Select-Object -First 1).to.id;$kr=Rows $kb 'statement'
$normalize=@($kr|Where-Object{$n=$nodes[[int]$_.to.id];$n.structural_kind -eq 'AssignStmt' -and $n.fields.name -ceq 'rich_kind'})
if($normalize.Count -ne 1){throw "Expected one kind_code rich-kind normalization point; found $($normalize.Count)"}
$insert=0
foreach($r in $rels){if($r.kind -eq 'syntax.child' -and [int]$r.from -eq $kb -and $r.attributes.role -eq 'statement' -and [int]$r.attributes.ordinal -ge $insert){$r.attributes.ordinal+=4}}
# Rich catalog codes remain 20=BindingPattern and 21=TupleExpr. These are
# backend parser tags: aggregate=16; 20 already means slice, 23 switch, 24 cmp.
foreach($pair in @(@('TupleExpr',16),@('BindingPattern',25),@('binding_pattern',25),@('binding',25))){
  $str=NewNode 'LiteralExpr' @{kind='literal';operation=[pscustomobject]@{literal_kind='string';text=$pair[0]}}
  $cmp=Call 'slice_eq_cstr' @((Ref 'p'),(Ref 'n'),$str);$if=NewIf $cmp;$scope=[int](Rows $if 'then'|Select-Object -First 1).to.id
  AddStmt $scope (Return (Int ([int]$pair[1]))) 0;AddChild $kb $if 'statement' $insert;$insert++
}

# Reserve anonymous frame cells without retaining names from a previous
# function's slot table. Aggregate lowering uses this allocator as well.
$fa=Closure 'frame_alloc';$fab=[int](Rows $fa 'body'|Select-Object -First 1).to.id
$fr=Rows $fab 'statement';$at=1
foreach($r in $rels){if($r.kind -eq 'syntax.child' -and [int]$r.from -eq $fab -and $r.attributes.role -eq 'statement' -and [int]$r.attributes.ordinal -ge $at){$r.attributes.ordinal+=3}}
AddStmt $fab (Assign 'reserved_i' (Int 0)) $at;$at++
$fl=NewNode 'LoopStmt' @{kind='while'};$fb=NewNode 'Scope' @{kind='block'};AddChild $fl (Op 'less_than' (Ref 'reserved_i') (Ref 'n')) 'condition' 0;AddChild $fl $fb 'body' 0
AddStmt $fb (Assign 'reserved_slot' (Op 'add' (Call 'ctx_get' @((Ref 'c'),(Int 80))) (Op 'multiply' (Op 'add' (Ref 'count') (Ref 'reserved_i')) (Int 24)))) 0
AddStmt $fb (ExprStmt (Call 'store64' @((Ref 'reserved_slot'),(Int 0)))) 1
AddStmt $fb (ExprStmt (Call 'store64' @((Op 'add' (Ref 'reserved_slot') (Int 8)),(Int 0)))) 2
AddStmt $fb (Assign 'reserved_i' (Op 'add' (Ref 'reserved_i') (Int 1))) 3;AddStmt $fab $fl $at;$at++
AddStmt $fab (ExprStmt (Call 'ctx_set' @((Ref 'c'),(Int 88),(Ref 'count')))) $at

# compile_flat_binding_pattern: only direct tuple/aggregate RHS and flat,
# named SymbolRef targets are admitted. All elements are materialized before
# target stores. Unsupported target forms report an error before code emission.
$fn=NewNode 'ClosureExpr' @{kind='function';name='compile_flat_binding_pattern';operation=[pscustomobject]@{function_binding='compile_flat_binding_pattern'}}
foreach($p in @(@('c',0),@('assign_id',1),@('pattern_id',2))){$id=NewNode 'ParameterDecl' @{kind='parameter';name=$p[0]};AddChild $fn $id 'parameter' ([int]$p[1])}
$body=NewNode 'Scope' @{kind='block'};AddChild $fn $body 'body' 0;$ord=0
AddStmt $body (Assign 'value_id' (Call 'child' @((Ref 'c'),(Ref 'assign_id'),(Int 4),(Int 0)))) $ord;$ord++
$reject=NewIf (Op 'not_equal' (Call 'node_get' @((Ref 'c'),(Ref 'value_id'),(Int 0))) (Int 16));$rejectBody=[int](Rows $reject 'then'|Select-Object -First 1).to.id;AddStmt $rejectBody (Return (Int -1)) 0;AddStmt $body $reject $ord;$ord++
$reject=NewIf (Op 'not_equal' (Call 'node_get' @((Ref 'c'),(Ref 'pattern_id'),(Int 0))) (Int 25));$rejectBody=[int](Rows $reject 'then'|Select-Object -First 1).to.id;AddStmt $rejectBody (Return (Int -1)) 0;AddStmt $body $reject $ord;$ord++
AddStmt $body (Assign 'target_count' (Int 0)) $ord;$ord++
$targetNext=Call 'child' @((Ref 'c'),(Ref 'pattern_id'),(Int 25),(Ref 'target_count'))
$tl=NewNode 'LoopStmt' @{kind='while'};$tb=NewNode 'Scope' @{kind='block'};AddChild $tl (Op 'not_equal' $targetNext (Int -1)) 'condition' 0;AddChild $tl $tb 'body' 0;AddStmt $tb (Assign 'target_count' (Op 'add' (Ref 'target_count') (Int 1))) 0;AddStmt $body $tl $ord;$ord++
AddStmt $body (Assign 'value_count' (Int 0)) $ord;$ord++
$valueNext=Call 'child' @((Ref 'c'),(Ref 'value_id'),(Int 6),(Ref 'value_count'))
$vl=NewNode 'LoopStmt' @{kind='while'};$vb=NewNode 'Scope' @{kind='block'};AddChild $vl (Op 'not_equal' $valueNext (Int -1)) 'condition' 0;AddChild $vl $vb 'body' 0;AddStmt $vb (Assign 'value_count' (Op 'add' (Ref 'value_count') (Int 1))) 0;AddStmt $body $vl $ord;$ord++
$bad=NewIf (Op 'not_equal' (Ref 'target_count') (Ref 'value_count'));$badBody=[int](Rows $bad 'then'|Select-Object -First 1).to.id;AddStmt $badBody (Return (Int -1)) 0;AddStmt $body $bad $ord;$ord++
$empty=NewIf (Op 'less_than' (Ref 'target_count') (Int 1));$emptyBody=[int](Rows $empty 'then'|Select-Object -First 1).to.id;AddStmt $emptyBody (Return (Int -1)) 0;AddStmt $body $empty $ord;$ord++
# Validate every target before emitting any instructions or target stores.
AddStmt $body (Assign 'i' (Int 0)) $ord;$ord++
$cl=NewNode 'LoopStmt' @{kind='while'};$cv=NewNode 'Scope' @{kind='block'};AddChild $cl (Op 'less_than' (Ref 'i') (Ref 'target_count')) 'condition' 0;AddChild $cl $cv 'body' 0
AddStmt $cv (Assign 'leaf' (Call 'child' @((Ref 'c'),(Ref 'pattern_id'),(Int 25),(Ref 'i')))) 0
$bad=NewIf (Op 'not_equal' (Call 'node_get' @((Ref 'c'),(Ref 'leaf'),(Int 0))) (Int 6));$bs=[int](Rows $bad 'then'|Select-Object -First 1).to.id;AddStmt $bs (Return (Int -1)) 0;AddStmt $cv $bad 1
$bad=NewIf (Op 'less_than' (Call 'node_get' @((Ref 'c'),(Ref 'leaf'),(Int 16))) (Int 1));$bs=[int](Rows $bad 'then'|Select-Object -First 1).to.id;AddStmt $bs (Return (Int -1)) 0;AddStmt $cv $bad 2
AddStmt $cv (Assign 'i' (Op 'add' (Ref 'i') (Int 1))) 3;AddStmt $body $cl $ord;$ord++
AddStmt $body (Assign 'temp_base' (Call 'frame_alloc' @((Ref 'c'),(Ref 'value_count')))) $ord;$ord++
AddStmt $body (Assign 'i' (Int 0)) $ord;$ord++
$el=NewNode 'LoopStmt' @{kind='while'};$eb=NewNode 'Scope' @{kind='block'};AddChild $el (Op 'less_than' (Ref 'i') (Ref 'value_count')) 'condition' 0;AddChild $el $eb 'body' 0
AddStmt $eb (Assign 'value_item' (Call 'child' @((Ref 'c'),(Ref 'value_id'),(Int 6),(Ref 'i')))) 0
AddStmt $eb (ExprStmt (Call 'compile_expr' @((Ref 'c'),(Ref 'value_item')))) 1
$evalOffset=Op 'subtract' (Ref 'temp_base') (Op 'multiply' (Ref 'i') (Int 8))
AddStmt $eb (ExprStmt (Call 'emit_mov_mem_rax' @((Ref 'c'),$evalOffset))) 2
AddStmt $eb (Assign 'i' (Op 'add' (Ref 'i') (Int 1))) 3;AddStmt $body $el $ord;$ord++
AddStmt $body (Assign 'i' (Int 0)) $ord;$ord++
$sl=NewNode 'LoopStmt' @{kind='while'};$sb=NewNode 'Scope' @{kind='block'};AddChild $sl (Op 'less_than' (Ref 'i') (Ref 'target_count')) 'condition' 0;AddChild $sl $sb 'body' 0
AddStmt $sb (Assign 'leaf' (Call 'child' @((Ref 'c'),(Ref 'pattern_id'),(Int 25),(Ref 'i')))) 0
AddStmt $sb (Assign 'leaf_name' (Call 'node_get' @((Ref 'c'),(Ref 'leaf'),(Int 8)))) 1
AddStmt $sb (Assign 'leaf_len' (Call 'node_get' @((Ref 'c'),(Ref 'leaf'),(Int 16)))) 2
$badName=NewIf (Op 'less_than' (Ref 'leaf_len') (Int 1));$badNameBody=[int](Rows $badName 'then'|Select-Object -First 1).to.id;AddStmt $badNameBody (Return (Int -1)) 0;AddStmt $sb $badName 3
$storeOffset=Op 'subtract' (Ref 'temp_base') (Op 'multiply' (Ref 'i') (Int 8))
AddStmt $sb (ExprStmt (Call 'emit_mov_rax_mem' @((Ref 'c'),$storeOffset))) 4
AddStmt $sb (Assign 'dest' (Call 'slot' @((Ref 'c'),(Ref 'leaf_name'),(Ref 'leaf_len')))) 5
AddStmt $sb (ExprStmt (Call 'emit_mov_mem_rax' @((Ref 'c'),(Ref 'dest')))) 6
AddStmt $sb (Assign 'i' (Op 'add' (Ref 'i') (Int 1))) 7;AddStmt $body $sl $ord;$ord++
AddStmt $body (Return (Int 0)) $ord

# Put a guarded structured-target branch immediately before the ordinary
# AssignStmt branch. It is only taken when role_code found an explicit target.
$cs=Closure 'compile_stmt';$cb=[int](Rows $cs 'body'|Select-Object -First 1).to.id;$sr=Rows $cb 'statement'
$as=@($sr|Where-Object{$n=$nodes[[int]$_.to.id];if($n.structural_kind -ne 'IfStmt'){return $false};$c=Rows ([int]$n.id) 'condition';if(!$c){return $false};$q=$nodes[[int]$c[0].to.id];if($q.structural_kind -ne 'OperationExpr'){return $false};$rhs=Rows ([int]$q.id) 'right';$rhs -and $nodes[[int]$rhs[0].to.id].fields.operation.text -eq '4'})
if($as.Count -ne 1){throw "Expected one ordinary assignment branch; found $($as.Count)"}
$outer=NewIf (Op 'equal' (Ref 'k') (Int 4));$ot=[int](Rows $outer 'then'|Select-Object -First 1).to.id
$lookup=Call 'child' @((Ref 'c'),(Ref 'id'),(Int 24),(Int 0));$inner=NewIf (Op 'greater_than' $lookup (Int -1));$it=[int](Rows $inner 'then'|Select-Object -First 1).to.id
AddStmt $it (Assign 'pattern_status' (Call 'compile_flat_binding_pattern' @((Ref 'c'),(Ref 'id'),$lookup))) 0
$bad=NewIf (Op 'less_than' (Ref 'pattern_status') (Int 0));$bs=[int](Rows $bad 'then'|Select-Object -First 1).to.id;AddStmt $bs (ExprStmt (Call 'ctx_set' @((Ref 'c'),(Int 208),(Int 1)))) 0;AddStmt $it $bad 1
AddStmt $it (Return (Ref 'pattern_status')) 2;AddStmt $ot $inner 0
$at=[int]$as[0].attributes.ordinal;foreach($r in $rels){if($r.kind -eq 'syntax.child' -and [int]$r.from -eq $cb -and $r.attributes.role -eq 'statement' -and [int]$r.attributes.ordinal -ge $at){$r.attributes.ordinal++}};AddChild $cb $outer 'statement' $at

# Remove the old return/unary shortcut. It emitted MOV EAX,1 but skipped
# the common jump to the epilogue, so compile_func's default zero won.
# The existing compile_expr unary emitter already performs the operation.
$shortcuts=@($rels|Where-Object {$_.kind -eq 'syntax.child' -and [int]$_.to.id -eq 3017 -and $_.attributes.role -eq 'statement'})
foreach($r in $shortcuts){$parent=[int]$r.from;[void]$rels.Remove($r);$items=Rows $parent 'statement';for($j=0;$j -lt $items.Count;$j++){$items[$j].attributes.ordinal=$j}}
# The dispatcher had two statement-0 edges: the probe bridge shadowed the
# family assignment. The following guard read an uninitialized local. Retain
# the real family lookup and remove only the redundant probe edge.
$dispatch=Closure 'rich_core_lowering_dispatch';$db=[int](Rows $dispatch 'body'|Select-Object -First 1).to.id
$probeRows=@(Rows $db 'statement'|Where-Object {[int]$_.to.id -eq 22678});foreach($r in $probeRows){[void]$rels.Remove($r)}

# Propagate an invalid destructuring contract to compile_file's existing
# negative-size guard, before write_file can create an executable.
$cp=Closure 'compile_program';$cpb=[int](Rows $cp 'body'|Select-Object -First 1).to.id
foreach($r in $rels){if($r.kind -eq 'syntax.child' -and [int]$r.from -eq $cpb -and $r.attributes.role -eq 'statement'){$r.attributes.ordinal++}}
AddStmt $cpb (ExprStmt (Call 'ctx_set' @((Ref 'c'),(Int 208),(Int 0)))) 0
$last=@(Rows $cpb 'statement'|Where-Object{$nodes[[int]$_.to.id].structural_kind -eq 'ReturnStmt'}|Select-Object -Last 1);$at=[int]$last[0].attributes.ordinal
foreach($r in $rels){if($r.kind -eq 'syntax.child' -and [int]$r.from -eq $cpb -and $r.attributes.role -eq 'statement' -and [int]$r.attributes.ordinal -ge $at){$r.attributes.ordinal++}}
$bad=NewIf (Op 'not_equal' (Call 'ctx_get' @((Ref 'c'),(Int 208))) (Int 0));$bs=[int](Rows $bad 'then'|Select-Object -First 1).to.id;AddStmt $bs (Return (Int -1)) 0;AddStmt $cpb $bad $at

$out=[Collections.Generic.List[string]]::new();foreach($line in $lines[0..($nodeStart-1)]){$out.Add($line)};$out.Add('nodes=[');$all=@($nodes.Values|Sort-Object {[int]$_.id})
for($i=0;$i -lt $all.Count;$i++){$j=$all[$i]|ConvertTo-Json -Compress -Depth 100;if($i -lt $all.Count-1){$j+=','};$out.Add($j)}
$out.Add(']');$out.Add('relations=[');for($i=0;$i -lt $rels.Count;$i++){$j=$rels[$i]|ConvertTo-Json -Compress -Depth 60;if($i -lt $rels.Count-1){$j+=','};$out.Add($j)};$out.Add(']');foreach($line in $lines[($relationEnd+1)..($lines.Count-1)]){$out.Add($line)}
$dest=[IO.Path]::GetFullPath($OutputPath);[IO.Directory]::CreateDirectory((Split-Path -Parent $dest))|Out-Null;[IO.File]::WriteAllLines($dest,$out,[Text.UTF8Encoding]::new($false));"FLAT_BINDING_PATTERN=$dest"
