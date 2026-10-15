[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$InputPath,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [string]$WorkDir='tmp/foreach-native-worker'
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$source=(Resolve-Path -LiteralPath $InputPath).Path
$output=[IO.Path]::GetFullPath($OutputPath)
$work=[IO.Path]::GetFullPath($WorkDir)
foreach($p in @($output,$work)) {
    if(!$p.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {throw 'Output must be in workspace'}
    $relative=$p.Substring($root.Length+1)
    if($relative -match '^(src|\.git|\.codex|\.agents)([\\/]|$)' -or $relative -in @('swc.exe','swc.smod')) {throw "Protected output: $p"}
}
if($source -eq $output) {throw 'InputPath and OutputPath must differ'}
New-Item -ItemType Directory -Force -Path $work | Out-Null
function ReadGraph([string]$Path) {
    $script:lines=[IO.File]::ReadAllLines($Path);$script:nodes=@{};$script:rels=[Collections.Generic.List[object]]::new();$section=''
    $script:ns=-1;$script:re=-1
    for($i=0;$i -lt $lines.Length;$i++) {
        $t=$lines[$i].Trim().TrimStart(',').TrimEnd(',')
        if($t -eq 'nodes=['){$section='n';$script:ns=$i;continue}
        if($t -eq 'relations=['){$section='r';continue}
        if($t -eq ']'){if($section -eq 'r'){$script:re=$i};$section='';continue}
        if(!$t.StartsWith('{') -or !$section){continue}
        $x=$t|ConvertFrom-Json
        if($section -eq 'n'){$nodes[[int]$x.id]=$x}else{$rels.Add($x)}
    }
    if($ns -lt 0 -or $re -lt 0){throw 'Expected compact semantic_document.v1 graph'}
}
function WriteGraph([string]$Path) {
    $out=[Collections.Generic.List[string]]::new();$out.AddRange([string[]]$lines[0..($ns-1)]);$out.Add('nodes=[')
    $values=@($nodes.Values|Sort-Object id)
    for($i=0;$i -lt $values.Count;$i++) {
        $x=$values[$i];$s=$x|ConvertTo-Json -Compress -Depth 100
        if($i -lt $values.Count-1){$s+=','};$out.Add($s)
    }
    $out.Add(']');$out.Add('relations=[')
    for($i=0;$i -lt $rels.Count;$i++){$s=$rels[$i]|ConvertTo-Json -Compress -Depth 100;if($i -lt $rels.Count-1){$s+=','};$out.Add($s)}
    $out.Add(']');$out.Add('metadata={"expected_exit":0,"swc.patch":"foreach-native-execution","swc.scope":"foreach closure and k11 foreach dispatch only"}');$out.Add('}')
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path)|Out-Null
    [IO.File]::WriteAllLines($Path,$out,[Text.UTF8Encoding]::new($false))
}
function Edges([int]$Id,[string]$Role){@($rels|Where-Object {$_.from -eq $Id -and $_.attributes.role -eq $Role}|Sort-Object {$_.attributes.ordinal})}
function Child([int]$Id,[string]$Role){$e=@(Edges $Id $Role);if($e.Count -ne 1){throw "Expected one $Role on $Id"};[int]$e[0].to.id}
ReadGraph $source
# Remove every historical duplicate before the importer allocates fresh IDs.
# Shared descendants are retained if another function has a semantic edge to them.
$old=@($nodes.Values|Where-Object {$_.fields.kind -eq 'function' -and $_.fields.name -eq 'compile_foreach_stmt'})
$remove=[Collections.Generic.HashSet[int]]::new();$queue=[Collections.Generic.Queue[int]]::new()
foreach($fn in $old){$queue.Enqueue([int]$fn.id)}
while($queue.Count){$id=$queue.Dequeue();if(!$remove.Add($id)){continue};foreach($e in @($rels|Where-Object {$_.from -eq $id -and $_.kind -eq 'syntax.child'})){$queue.Enqueue([int]$e.to.id)}}
$roots=@($old|ForEach-Object {[int]$_.id})
foreach($e in $rels){if($e.to.domain -eq 'node' -and $remove.Contains([int]$e.to.id) -and !$remove.Contains([int]$e.from) -and [int]$e.to.id -notin $roots){throw 'Shared foreach subtree requires explicit preservation'}}
foreach($id in @($remove)){$nodes.Remove($id)}
$rels=[Collections.Generic.List[object]]@($rels|Where-Object {!$remove.Contains([int]$_.from) -and !($_.to.domain -eq 'node' -and $remove.Contains([int]$_.to.id))})
$clean=Join-Path $work 'deduplicated.se'
if($source -eq $clean){throw 'Input collides with intermediate'}
WriteGraph $clean
$imported=Join-Path $work 'imported.se'
if($source -eq $imported){throw 'Input collides with intermediate'}
& (Join-Path $PSScriptRoot 'import-semantic-function-closure.ps1') -CorePath $clean -UnitPath (Join-Path $root 'src/units/compile-foreach-native.se') -RootBinding compile_foreach_stmt -AllocateAfterMax -OutputPath $imported -ReportPath (Join-Path $work 'import-report.json')
ReadGraph $imported
$script:next=1+[int](($nodes.Keys|Measure-Object -Maximum).Maximum)
function Node([string]$Structural,[string]$Kind,[hashtable]$Extra=@{}) {
    $id=$script:next++;$f=[ordered]@{kind=$Kind};foreach($key in $Extra.Keys){$f[$key]=$Extra[$key]}
    $nodes[$id]=[pscustomobject]@{id=$id;structural_kind=$Structural;fields=[pscustomobject]$f};return $id
}
function Link([int]$From,[int]$To,[string]$Role,[int]$Ordinal=0){$rels.Add([pscustomobject]@{kind='syntax.child';from=$From;to=[pscustomobject]@{domain='node';id=[string]$To};attributes=[pscustomobject]@{role=$Role;ordinal=$Ordinal}})}
function Ref([string]$Name){Node SymbolRef identifier @{name=$Name}}
function Int([int]$V){Node LiteralExpr literal @{operation=@{literal_kind='integer';text=[string]$V}}}
$compile=@($nodes.Values|Where-Object {$_.fields.kind -eq 'function' -and $_.fields.name -eq 'compile_stmt'})
if($compile.Count -ne 1){throw 'Expected unique compile_stmt'}
$body=Child $compile[0].id body
$branches=@(Edges $body statement|Where-Object {$nodes[[int]$_.to.id].fields.kind -eq 'if'})
$loop=@($branches|Where-Object {
    $cond=Child ([int]$_.to.id) condition
    $nodes[$cond].fields.operation.semantic_id -eq 'equal' -and
    $nodes[(Child $cond left)].fields.name -eq 'k' -and $nodes[(Child $cond right)].fields.operation.text -eq '11'
})
if($loop.Count -ne 1){throw 'Expected unique k11 loop branch'}
$then=Child ([int]$loop[0].to.id) then
$calls=@(Edges $then statement|Where-Object {$nodes[[int]$_.to.id].fields.name -eq 'foreach_ret'})
if(!$calls.Count) {
    foreach($e in @(Edges $then statement)){$e.attributes.ordinal+=2}
    $a=Node AssignStmt assign @{name='foreach_ret'};$c=Node CallExpr call
    Link $c (Ref compile_foreach_stmt) callee;Link $c (Ref c) argument 0;Link $c (Ref id) argument 1;Link $c (Ref retk) argument 2;Link $a $c expression;Link $then $a statement 0
    $branch=Node IfStmt if;$cond=Node OperationExpr binary @{operation=@{semantic_id='not_equal';semantics=@{operation='not_equal'}}}
    Link $cond (Ref foreach_ret) left;Link $cond (Int 0) right 1;Link $branch $cond condition
    $b=Node Scope block;$ret=Node ReturnStmt return;Link $ret (Int 0) expression;Link $b $ret statement;Link $branch $b then;Link $then $branch statement 1
} elseif($calls.Count -eq 1) {
    $guards=@(Edges $then statement|Where-Object {
        $id=[int]$_.to.id
        if($nodes[$id].fields.kind -ne 'if'){return $false}
        $cond=Child $id condition
        $nodes[$cond].fields.operation.semantic_id -eq 'not_equal' -and $nodes[(Child $cond left)].fields.name -eq 'foreach_ret'
    })
    if($guards.Count -ne 1){throw 'Expected foreach_ret != 0 guard'}
    $gb=Child ([int]$guards[0].to.id) then
    $returns=@(Edges $gb statement|Where-Object {$nodes[[int]$_.to.id].fields.kind -eq 'return'})
    if($returns.Count -ne 1){throw 'Expected dispatcher return'}
    $rid=[int]$returns[0].to.id
    foreach($e in @(Edges $rid expression)+@(Edges $rid value)){$rels.Remove($e)|Out-Null}
    Link $rid (Int 0) expression
} else {throw 'Duplicate foreach dispatcher assignments'}
WriteGraph $output
"OUTPUT=$output DUPLICATES_REMOVED=$($old.Count) EXPECTED_EXIT=0"
