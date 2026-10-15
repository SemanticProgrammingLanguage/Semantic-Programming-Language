[CmdletBinding()]
param([Parameter(Mandatory)][string]$InputPath,[Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference='Stop'
if ([IO.Path]::GetFullPath($InputPath) -eq [IO.Path]::GetFullPath($OutputPath)) { throw 'Use a separate candidate output' }
# Reuse the existing importer reader; this is a bounded structural patch.
$importer=Join-Path $PSScriptRoot 'import-semantic-function-closure.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($importer,[ref]$null,[ref]$null)
$reader=$ast.Find({param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Read-SemanticGraph'},$false)
. ([scriptblock]::Create($reader.Extent.Text))
$g=Read-SemanticGraph $InputPath
$n=@{}; foreach($v in $g.Nodes){$n[[int]$v.id]=$v}
$r=[Collections.Generic.List[object]]::new();foreach($v in $g.Relations){$r.Add($v)}
$next=1+[int](($n.Keys|Measure-Object -Maximum).Maximum)
function Edges($id,$role){@($(foreach($e in $script:r){if($e.kind -eq 'syntax.child' -and [int]$e.from -eq $id -and $e.attributes.role -eq $role){$e}})|Sort-Object{$_.attributes.ordinal})}
function Child($id,$role){$es=@(Edges $id $role);if($es.Count -ne 1){throw "Expected one $role on $id"};[int]$es[0].to.id}
function Fn($name){$vs=@($script:n.Values|Where-Object{$_.structural_kind -eq 'ClosureExpr' -and $_.fields.operation.function_binding -eq $name});if($vs.Count -ne 1){throw "Expected one $name"};[int]$vs[0].id}
function Node($kind,$fields){$id=$script:next++;$script:n[$id]=[pscustomobject]@{id=$id;structural_kind=$kind;fields=$fields};$id}
function Edge($a,$b,$role,$ord){$script:r.Add([pscustomobject][ordered]@{kind='syntax.child';from=$a;to=[ordered]@{domain='node';id=[string]$b};attributes=[ordered]@{role=$role;ordinal=$ord}})}
function Ref($name){Node 'SymbolRef' ([ordered]@{kind='identifier';name=$name})}
function Lit($value){Node 'LiteralExpr' ([ordered]@{kind='literal';operation=@{literal_kind='integer';text=[string]$value}})}
function Fail($body){
 $s=Node 'ExprStmt' ([ordered]@{kind='expression'});$c=Node 'CallExpr' ([ordered]@{kind='call'})
 Edge $s $c 'expression' 0;Edge $c (Ref 'ctx_set') 'callee' 0;Edge $c (Ref 'c') 'argument' 0;Edge $c (Lit 208) 'argument' 1;Edge $c (Lit 1) 'argument' 2;Edge $body $s 'statement' 0
 $ret=Node 'ReturnStmt' ([ordered]@{kind='return'});Edge $ret (Lit -1) 'expression' 0;Edge $body $ret 'statement' 1
}
# The native reader does not retain structured field ordinals/type layouts.
# machine_compile.go memberField requires those facts. No name-only ABI.
$mb=Child (Fn 'compile_member_expr') 'body'
$r=[Collections.Generic.List[object]]@($r|Where-Object{-not ([int]$_.from -eq $mb -and $_.kind -eq 'syntax.child' -and $_.attributes.role -eq 'statement')})
Fail $mb
$ib=Child (Fn 'compile_index_expr') 'body'
$ss=@(Edges $ib 'statement')
$assign=@($ss|Where-Object{$n[[int]$_.to.id].structural_kind -eq 'AssignStmt' -and $n[[int]$_.to.id].fields.name -in @('base_node','index_node')})
$guards=@($ss|Where-Object{$n[[int]$_.to.id].structural_kind -eq 'IfStmt'}|Select-Object -First 2)
if($assign.Count -ne 2 -or $guards.Count -ne 2){throw 'Existing index assignments/guards changed; inspect before patching'}
$ordered=@($assign)+@($guards)+@($ss|Where-Object{$_ -notin $assign -and $_ -notin $guards})
for($i=0;$i -lt $ordered.Count;$i++){$ordered[$i].attributes.ordinal=$i}
foreach($guard in $guards){$b=Child ([int]$guard.to.id) 'then';$r=[Collections.Generic.List[object]]@($r|Where-Object{-not ([int]$_.from -eq $b -and $_.kind -eq 'syntax.child' -and $_.attributes.role -eq 'statement')});Fail $b}
# Locate the member dispatch structurally; leave every other tag untouched.
$cb=Child (Fn 'compile_expr') 'body'
$hits=0
foreach($s in @(Edges $cb 'statement')){
 $id=[int]$s.to.id;if($n[$id].structural_kind -ne 'IfStmt'){continue}
 $then=@(Edges $id 'then');if($then.Count -ne 1){continue}
 $found=$false
 foreach($st in @(Edges ([int]$then[0].to.id) 'statement')){foreach($ex in @(Edges ([int]$st.to.id) 'expression')){foreach($ca in @(Edges ([int]$ex.to.id) 'callee')){if($n[[int]$ca.to.id].fields.name -eq 'compile_member_expr'){$found=$true}}}}
 if($found){$cond=Child $id 'condition';$right=Child $cond 'right';if($n[$right].fields.operation.text -notin @('12','19')){throw 'Unexpected member tag'};$n[$right].fields.operation.text='19';$hits++;if($hits -gt 1){[void]$r.Remove($s)}}
}
if($hits -lt 1 -or $hits -gt 2){throw "Expected one or two historical member dispatches, got $hits"}
# Retain all existing nodes (including disconnected legacy source evidence),
# metadata and untouched relations. Only the owned executable paths change.
$source=[IO.File]::ReadAllText((Resolve-Path -LiteralPath $InputPath))
$nodes=(@($n.Values|Sort-Object id)|ForEach-Object{$_|ConvertTo-Json -Compress -Depth 100}) -join ",`n"
$rels=(@($r)|ForEach-Object{$_|ConvertTo-Json -Compress -Depth 100}) -join ",`n"
$source=[regex]::Replace($source,'(?ms)^nodes\s*=\[.*?^\]',[Text.RegularExpressions.MatchEvaluator]{param($m) "nodes=[`n$nodes`n]"},1)
$source=[regex]::Replace($source,'(?ms)^relations\s*=\[.*?^\]',[Text.RegularExpressions.MatchEvaluator]{param($m) "relations=[`n$rels`n]"},1)
$out=[IO.Path]::GetFullPath($OutputPath);[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($out));[IO.File]::WriteAllText($out,$source,[Text.UTF8Encoding]::new($false))
"OUTPUT=$out MEMBER=reject-unproven-layout INDEX=assignments-before-guards CTX208=1 SOURCE_NODES_RETAINED=$($g.Nodes.Count)"
