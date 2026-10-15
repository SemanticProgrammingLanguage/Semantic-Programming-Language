[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$InputPath,[Parameter(Mandatory=$true)][string]$OutputPath)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

# Structural SE graph helpers follow inject-flat-binding-pattern.ps1.
# Existing identities and relations are retained; only fresh nodes are allocated.
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
if([IO.Path]::GetFullPath($OutputPath) -eq (Resolve-Path -LiteralPath $InputPath).Path){throw 'InputPath and OutputPath must differ'}
$used=[Collections.Generic.HashSet[int]]::new();foreach($id in $nodes.Keys){[void]$used.Add([int]$id)};$next=1+[int]($nodes.Keys|Measure-Object -Maximum).Maximum
function NewNode([string]$k,[hashtable]$f){while($script:used.Contains($script:next)){$script:next++};$id=$script:next;$script:next++;[void]$script:used.Add($id);$ordered=[ordered]@{kind=$f.kind};foreach($key in $f.Keys|Where-Object {$_ -ne 'kind'}|Sort-Object){$ordered[$key]=$f[$key]};$script:nodes[$id]=[pscustomobject]@{id=$id;structural_kind=$k;fields=[pscustomobject]$ordered};$id}
function AddChild([int]$a,[int]$b,[string]$r,[int]$o){$script:rels.Add([pscustomobject]@{kind='syntax.child';from=$a;to=[pscustomobject]@{domain='node';id=[string]$b};attributes=[pscustomobject]@{missing=$false;name='';ordinal=$o;role=$r}})}
function Rows([int]$id,[string]$role){@($script:rels|Where-Object{$_.kind -eq 'syntax.child' -and [int]$_.from -eq $id -and $_.attributes.role -eq $role}|Sort-Object {[int]$_.attributes.ordinal})}
function Ref([string]$n){NewNode 'SymbolRef' @{kind='identifier';name=$n}}
function Int([long]$n){NewNode 'LiteralExpr' @{kind='literal';operation=[pscustomobject]@{literal_kind='integer';text=[string]$n}}}
function Str([string]$s){NewNode 'LiteralExpr' @{kind='literal';operation=[pscustomobject]@{literal_kind='string';text=$s}}}
function Op([string]$name,[int]$a,[int]$b){$x=NewNode 'OperationExpr' @{kind='binary';operation=[pscustomobject]@{semantic_id=$name;semantics=[pscustomobject]@{operation=$name}}};AddChild $x $a 'left' 0;AddChild $x $b 'right' 1;$x}
function Call([string]$name,[int[]]$operands){$x=NewNode 'CallExpr' @{kind='call'};AddChild $x (Ref $name) 'callee' 0;for($j=0;$j -lt $operands.Count;$j++){AddChild $x $operands[$j] 'argument' $j};$x}
function Assign([string]$name,[int]$expr){$x=NewNode 'AssignStmt' @{kind='assign';name=$name};AddChild $x $expr 'expression' 0;$x}
function Return([int]$expr){$x=NewNode 'ReturnStmt' @{kind='return'};AddChild $x $expr 'expression' 0;$x}
function AddStmt([int]$scope,[int]$stmt,[int]$ord){AddChild $scope $stmt 'statement' $ord}
function NewIf([int]$cond){$i=NewNode 'IfStmt' @{kind='if'};$s=NewNode 'Scope' @{kind='block'};AddChild $i $cond 'condition' 0;AddChild $i $s 'then' 0;$i}
function Closure([string]$name){$a=@($script:nodes.Values|Where-Object{$_.structural_kind -eq 'ClosureExpr' -and $null -ne $_.fields.PSObject.Properties['operation'] -and $null -ne $_.fields.operation -and $_.fields.operation.function_binding -ceq $name});if($a.Count -ne 1){throw "Expected one closure $name; found $($a.Count)"};[int]$a[0].id}

$fn=Closure 'parse_rel_line';$body=[int](Rows $fn 'body'|Select-Object -First 1).to.id
$tp=@(Rows $body 'statement'|Where-Object{$n=$nodes[[int]$_.to.id];$n.structural_kind -eq 'AssignStmt' -and $n.fields.name -ceq 'tp'})
if($tp.Count -ne 1){throw 'Expected one original tp assignment'}
$expr=[int](Rows ([int]$tp[0].to.id) 'expression')[0].to.id
$callee=[int](Rows $expr 'callee')[0].to.id;$args=@(Rows $expr 'argument')
if($nodes[$callee].fields.name -cne 'find_sub' -or $args.Count -ne 3 -or $nodes[[int]$args[2].to.id].fields.operation.text -cne '"to":{"domain":"node","id":"'){throw 'Original quoted node search differs'}
$already=@($nodes.Values|Where-Object{$_.structural_kind -eq 'LiteralExpr' -and $_.fields.operation.literal_kind -eq 'string' -and $_.fields.operation.text -ceq '"to":{"domain":"node","id":'})
if($already.Count){throw 'Numeric relation search already present'}

# Keep the quoted search first. Its pointer already points past the quote.
$fallback=NewIf (Op 'equal' (Ref 'tp') (Int 0));$fb=[int](Rows $fallback 'then')[0].to.id
AddStmt $fb (Assign 'tp' (Call 'find_sub' @((Ref 's'),(Ref 'e'),(Str '"to":{"domain":"node","id":')))) 0
$found=NewIf (Op 'not_equal' (Ref 'tp') (Int 0));$fs=[int](Rows $found 'then')[0].to.id;AddStmt $fb $found 1
# Bound the read before loading a byte: eager bit_and would not protect it.
$loop=NewNode 'LoopStmt' @{kind='while'};$lb=NewNode 'Scope' @{kind='block'}
AddChild $loop (Op 'less_than' (Ref 'tp') (Ref 'e')) 'condition' 0;AddChild $loop $lb 'body' 0;AddStmt $fs $loop 0
AddStmt $lb (Assign 'numeric_rel_byte' (Call 'load8' @((Ref 'tp')))) 0
$space=Op 'equal' (Ref 'numeric_rel_byte') (Int 32)
foreach($b in @(9,10,13)){$space=Op 'bit_or' $space (Op 'equal' (Ref 'numeric_rel_byte') (Int $b))}
$advance=NewIf $space;$ab=[int](Rows $advance 'then')[0].to.id
AddStmt $ab (Assign 'tp' (Op 'add' (Ref 'tp') (Int 1))) 0
$stop=NewNode 'Scope' @{kind='block'};AddChild $advance $stop 'else' 0
$break=NewNode 'BreakStmt' @{kind='break'};AddStmt $stop $break 0;AddStmt $lb $advance 1

# Reject other relation kinds before either quoted or numeric edges are stored.
$guard=NewIf (Op 'equal' (Call 'find_sub' @((Ref 's'),(Ref 'e'),(Str '"kind":"syntax.child"'))) (Int 0))
$gb=[int](Rows $guard 'then')[0].to.id;AddStmt $gb (Return (Int 0)) 0
foreach($r in @(Rows $body 'statement')){$r.attributes.ordinal++}
AddStmt $body $guard 0
$at=[int]$tp[0].attributes.ordinal+1
foreach($r in @(Rows $body 'statement')){if([int]$r.attributes.ordinal -ge $at){$r.attributes.ordinal++}}
AddStmt $body $fallback $at

$out=[Collections.Generic.List[string]]::new();foreach($line in $lines[0..($nodeStart-1)]){$out.Add($line)};$out.Add('nodes=[');$all=@($nodes.Values|Sort-Object {[int]$_.id})
for($i=0;$i -lt $all.Count;$i++){$j=$all[$i]|ConvertTo-Json -Compress -Depth 100;if($i -lt $all.Count-1){$j+=','};$out.Add($j)}
$out.Add(']');$out.Add('relations=[');for($i=0;$i -lt $rels.Count;$i++){$j=$rels[$i]|ConvertTo-Json -Compress -Depth 60;if($i -lt $rels.Count-1){$j+=','};$out.Add($j)};$out.Add(']');foreach($line in $lines[($relationEnd+1)..($lines.Count-1)]){$out.Add($line)}
$dest=[IO.Path]::GetFullPath($OutputPath);[IO.Directory]::CreateDirectory((Split-Path -Parent $dest))|Out-Null;[IO.File]::WriteAllLines($dest,$out,[Text.UTF8Encoding]::new($false));"NUMERIC_RELATION_IDS=$dest"
