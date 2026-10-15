[CmdletBinding()]
param([Parameter(Mandatory)][string]$InputPath,[Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference='Stop'
$inputFull=(Resolve-Path -LiteralPath $InputPath).Path
$out=[IO.Path]::GetFullPath($OutputPath)
if($inputFull -eq $out -or [IO.Path]::GetExtension($out) -ne '.se' -or $out -eq (Join-Path (Split-Path $PSScriptRoot) 'src/swc-selfhost-windows.se')){throw 'Use a separate .se candidate output'}
# Reuse the existing graph reader. No converter, engine, or layout is added.
$importer=Join-Path $PSScriptRoot 'import-semantic-function-closure.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($importer,[ref]$null,[ref]$null)
$reader=$ast.Find({param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Read-SemanticGraph'},$false)
. ([scriptblock]::Create($reader.Extent.Text))
$g=Read-SemanticGraph $inputFull
$n=@{};foreach($v in $g.Nodes){$n[[int]$v.id]=$v}
$r=[Collections.Generic.List[object]]::new();foreach($v in $g.Relations){$r.Add($v)}
$added=[Collections.Generic.List[object]]::new()
$next=1+[int](($n.Keys|Measure-Object -Maximum).Maximum)
function Edges($id,$role){@($script:r|Where-Object{$_.kind -eq 'syntax.child' -and [int]$_.from -eq $id -and $_.attributes.role -eq $role}|Sort-Object{$_.attributes.ordinal})}
function Child($id,$role){$es=@(Edges $id $role);if($es.Count -ne 1){throw "Expected one $role on $id"};[int]$es[0].to.id}
function Fn($name){$vs=@($script:n.Values|Where-Object{$_.structural_kind -eq 'ClosureExpr' -and $_.fields.operation.function_binding -ceq $name});if($vs.Count -ne 1){throw "Expected one $name"};[int]$vs[0].id}
function Node($kind,$fields){$id=$script:next++;$v=[pscustomobject]@{id=$id;structural_kind=$kind;fields=$fields};$script:n[$id]=$v;$script:added.Add($v);$id}
function Edge($a,$b,$role,$ord){$script:r.Add([pscustomobject]@{kind='syntax.child';from=$a;to=[ordered]@{domain='node';id=[string]$b};attributes=[ordered]@{role=$role;ordinal=$ord}})}
function Ref($name){Node 'SymbolRef' ([ordered]@{kind='identifier';name=$name})}
function Lit($value){Node 'LiteralExpr' ([ordered]@{kind='literal';operation=[ordered]@{literal_kind='integer';text=[string]$value}})}
function Call($name,$operands){$id=Node 'CallExpr' ([ordered]@{kind='call'});Edge $id (Ref $name) 'callee' 0;for($i=0;$i -lt $operands.Count;$i++){Edge $id $operands[$i] 'argument' $i};$id}
function Ret($expr){$id=Node 'ReturnStmt' ([ordered]@{kind='return'});Edge $id $expr 'expression' 0;$id}
function Op($name,$a,$b){$id=Node 'OperationExpr' ([ordered]@{kind='binary';operation=@{semantic_id=$name;semantics=@{operation=$name}}});Edge $id $a 'left' 0;Edge $id $b 'right' 1;$id}
function Expr($value){$id=Node 'ExprStmt' ([ordered]@{kind='expression'});Edge $id $value 'expression' 0;$id}
function Assign($name,$value){$id=Node 'AssignStmt' ([ordered]@{kind='assign';name=$name});Edge $id $value 'expression' 0;$id}
function Guard($condition){$id=Node 'IfStmt' ([ordered]@{kind='if'});$b=Node 'Scope' ([ordered]@{kind='block'});Edge $id $condition 'condition' 0;Edge $id $b 'then' 0;Reject $b;$id}
function Insert($b,$stmt,$at){foreach($e in @(Edges $b 'statement')){if([int]$e.attributes.ordinal -ge $at){$e.attributes.ordinal=[int]$e.attributes.ordinal+1}};Edge $b $stmt 'statement' $at}
function Reject($body){
 $expr=Call 'ctx_set' @((Ref 'c'),(Lit 208),(Lit 1))
 $stmt=Node 'ExprStmt' ([ordered]@{kind='expression'});Edge $stmt $expr 'expression' 0;Edge $body $stmt 'statement' 0
 Edge $body (Ret (Lit -1)) 'statement' 1
}
$slice=Fn 'compile_slice_expr';$body=Child $slice 'body'
$compile=Fn 'compile_expr';$cb=Child $compile 'body'
if(@($n.Values|Where-Object{$_.fields.name -ceq '__slice_missing_contract_rejected'}).Count){throw 'Slice rejection patch already applied'}
# Keep original nodes and every non-statement relation as source evidence.
$r=[Collections.Generic.List[object]]@($r|Where-Object{-not ($_.kind -eq 'syntax.child' -and [int]$_.from -eq $body -and $_.attributes.role -eq 'statement')})
$at=0
Edge $body (Guard (Op 'not_equal' (Call 'ctx_get' @((Ref 'c'),(Lit 208))) (Lit 0))) 'statement' $at;$at++
Edge $body (Assign 'slice_base' (Call 'child' @((Ref 'c'),(Ref 'id'),(Lit 16),(Lit 0)))) 'statement' $at;$at++
Edge $body (Guard (Op 'less_or_equal' (Ref 'slice_base') (Lit 0))) 'statement' $at;$at++
# Restrict identity to an immediate aggregate in this frame, not an escaping
# or unknown container. No pointer adjustment, allocation or ownership claim.
Edge $body (Guard (Op 'not_equal' (Call 'node_get' @((Ref 'c'),(Ref 'slice_base'),(Lit 0))) (Lit 16))) 'statement' $at;$at++
foreach($role in @(6,30,31,32,33,34,35)){
 Edge $body (Guard (Op 'greater_or_equal' (Call 'child' @((Ref 'c'),(Ref 'id'),(Lit $role),(Lit 0))) (Lit 0))) 'statement' $at;$at++
}
Edge $body (Expr (Call 'compile_expr' @((Ref 'c'),(Ref 'slice_base')))) 'statement' $at;$at++
Edge $body (Ret (Lit 0)) 'statement' $at
# Exact registered bound roles remain visible to child(); never reinterpret
# a third generic argument as step. Inline evidence is checked in the reader.
$rb=Child (Fn 'role_code') 'body'
$roleAt=0
foreach($pair in @(@('low',30),@('high',31),@('step',32),@('start',33),@('end',34),@('max',35))){
 $str=Node 'LiteralExpr' ([ordered]@{kind='literal';operation=@{literal_kind='string';text=$pair[0]}})
 $test=Node 'IfStmt' ([ordered]@{kind='if'});$tb=Node 'Scope' ([ordered]@{kind='block'})
 Edge $test (Call 'slice_eq_cstr' @((Ref 'p'),(Ref 'n'),$str)) 'condition' 0;Edge $test $tb 'then' 0;Edge $tb (Ret (Lit $pair[1])) 'statement' 0
 Insert $rb $test $roleAt;$roleAt++
}
$pb=Child (Fn 'parse_node_line') 'body'
$ps=@(Edges $pb 'statement');$last=[int]$ps[-1].attributes.ordinal
$sliceCheck=Node 'IfStmt' ([ordered]@{kind='if'});$sb=Node 'Scope' ([ordered]@{kind='block'})
Edge $sliceCheck (Op 'equal' (Call 'node_get' @((Ref 'c'),(Ref 'id'),(Lit 0))) (Lit 20)) 'condition' 0;Edge $sliceCheck $sb 'then' 0
$ord=0
foreach($key in @('low','high','step','start','end','max','bounds','slice_representation')){
 $str=Node 'LiteralExpr' ([ordered]@{kind='literal';operation=@{literal_kind='string';text=('"'+$key+'"')}})
 Edge $sb (Guard (Op 'not_equal' (Call 'find_sub' @((Ref 's'),(Ref 'e'),$str)) (Lit 0))) 'statement' $ord;$ord++
}
Insert $pb $sliceCheck $last
# Inspect the raw native tag before rich_core_lowering_dispatch can replace it.
$branch=Node 'IfStmt' ([ordered]@{kind='if'})
$cond=Node 'OperationExpr' ([ordered]@{kind='binary';operation=@{semantic_id='equal';semantics=@{operation='equal'}}})
Edge $cond (Call 'node_get' @((Ref 'c'),(Ref 'id'),(Lit 0))) 'left' 0
Edge $cond (Lit 20) 'right' 1
$then=Node 'Scope' ([ordered]@{kind='block'})
Edge $branch $cond 'condition' 0;Edge $branch $then 'then' 0
Edge $then (Ret (Call 'compile_slice_expr' @((Ref 'c'),(Ref 'id')))) 'statement' 0
$marker=Node 'AssignStmt' ([ordered]@{kind='assign';name='__slice_missing_contract_rejected'})
Edge $marker (Lit 1) 'expression' 0
$stmts=@(Edges $cb 'statement');if(!$stmts.Count){throw 'compile_expr body missing'}
$first=[int]$stmts[0].attributes.ordinal
foreach($edge in $stmts){$edge.attributes.ordinal=[int]$edge.attributes.ordinal+2}
Edge $cb $marker 'statement' $first;Edge $cb $branch 'statement' ($first+1)
# Validate generated call arities and return operands before writing a candidate.
foreach($v in $added){
 if($v.structural_kind -eq 'CallExpr'){
  $callee=Child $v.id 'callee';$name=$n[$callee].fields.name
  $expected=@{ctx_set=3;ctx_get=2;node_get=3;compile_slice_expr=2;child=4;compile_expr=2;slice_eq_cstr=3;find_sub=3}[$name]
  $operands=@(Edges $v.id 'argument')
  if($null -eq $expected -or $operands.Count -ne $expected){throw "Generated call $name has invalid arguments"}
  for($i=0;$i -lt $operands.Count;$i++){if([int]$operands[$i].attributes.ordinal -ne $i){throw 'Noncontiguous argument ordinals'}}
 }
 if($v.structural_kind -eq 'ReturnStmt'){[void](Child $v.id 'expression')}
 if(@($v.fields.Keys)[0] -ne 'kind'){throw 'Generated fields.kind must serialize first'}
}
# Preserve all original node bytes, including extension/evidence fields and
# their order. Only append ordered kind-first nodes and rewrite relations.
$source=[IO.File]::ReadAllText($inputFull)
$nm=[regex]::Matches($source,'(?ms)^nodes\s*=\[.*?^\]')
$rm=[regex]::Matches($source,'(?ms)^relations\s*=\[.*?^\]')
if($nm.Count -ne 1 -or $rm.Count -ne 1){throw 'Expected one readable node/relation array; refusing lossy conversion'}
$newNodes=(@($added)|ForEach-Object{$_|ConvertTo-Json -Compress -Depth 100}) -join ",`n"
$source=[regex]::Replace($source,'(?ms)^nodes\s*=\[.*?^\]',[Text.RegularExpressions.MatchEvaluator]{param($m) $m.Value.Substring(0,$m.Value.Length-1).TrimEnd()+",`n"+$newNodes+"`n]"},1)
$rels=(@($r)|ForEach-Object{$_|ConvertTo-Json -Compress -Depth 100}) -join ",`n"
$source=[regex]::Replace($source,'(?ms)^relations\s*=\[.*?^\]',[Text.RegularExpressions.MatchEvaluator]{param($m) "relations=[`n$rels`n]"},1)
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($out))
[IO.File]::WriteAllText($out,$source,[Text.UTF8Encoding]::new($false))
"OUTPUT=$out SLICE=immediate-aggregate-full-identity BOUNDS=reject CTX208=1 ORIGINAL_NODES=$($g.Nodes.Count) ADDED_NODES=$($added.Count)"
