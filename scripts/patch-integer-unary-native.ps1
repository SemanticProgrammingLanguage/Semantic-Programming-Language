[CmdletBinding()]
param(
    [string]$InputPath = 'tmp/native-next/return-fixed.se',
    [string]$OutputPath = 'tmp/unary-integer-worker/candidate.se',
    [string]$WorkDir = 'tmp/unary-integer-worker'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$scope = [IO.Path]::GetFullPath($root)
function ScopedPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if (!$full.StartsWith($scope + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Candidate output must be inside workspace $scope : $full"
    }
    $relative=$full.Substring($scope.Length+1)
    if ($relative -match '^(\.git|\.agents|\.codex)([\\/]|$)' -or
        $relative -ieq 'src/swc-selfhost-windows.se' -or
        $relative -ieq 'src\swc-selfhost-windows.se' -or
        $relative -ieq 'swc.exe' -or $relative -ieq 'swc.smod') { throw "Protected active path: $full" }
    return $full
}
$output = ScopedPath $OutputPath
$work = [IO.Path]::GetFullPath($WorkDir)
$null = ScopedPath $work
$source = (Resolve-Path -LiteralPath $InputPath).Path
if ($source -eq $output) { throw 'Input and output must be distinct' }
New-Item -ItemType Directory -Force -Path $work | Out-Null
$imported = Join-Path $work 'imported.se'
if ($source -eq $imported) { throw 'Input must not be the importer intermediate' }
& (Join-Path $PSScriptRoot 'import-semantic-function-closure.ps1') `
    -CorePath $source -UnitPath (Join-Path $root 'src/units/compile-integer-unary-native.se') `
    -RootBinding compile_boolean_not_expr -ReplaceBinding compile_boolean_not_expr `
    -OutputPath $imported -ReportPath (Join-Path $work 'import-report.json')

# Existing importer supplies canonical nodes and preserves internal relations.
# Only operation table entries and compile_expr then-edges are changed here.
# In particular, existing ReturnStmt nodes and their value/expression edges
# are never rewritten; Main owns that repair and the unary reader mapping.
$lines = [IO.File]::ReadAllLines($imported)
$nodes = @{}; $relations = [Collections.Generic.List[object]]::new()
$section = ''; $nodeStart = -1; $relationEnd = -1
for ($i=0; $i -lt $lines.Count; $i++) {
    $t = $lines[$i].Trim().TrimStart(',').TrimEnd(',')
    if ($t -eq 'nodes=[') { $section='nodes'; $nodeStart=$i; continue }
    if ($t -eq 'relations=[') { $section='relations'; continue }
    if ($t -eq ']') { if ($section -eq 'relations') { $relationEnd=$i }; $section=''; continue }
    if (!$t.StartsWith('{')) { continue }
    if ($section -eq 'nodes') { $v=$t|ConvertFrom-Json; $nodes[[int]$v.id]=$v }
    if ($section -eq 'relations') { $relations.Add(($t|ConvertFrom-Json)) }
}
if ($nodeStart -lt 0 -or $relationEnd -lt 0) { throw 'Expected compact semantic_document.v1' }
$children = @{}
foreach ($r in $relations) {
    if ($r.kind -ne 'syntax.child' -or $r.to.domain -ne 'node') { continue }
    $from=[int]$r.from
    if (!$children.ContainsKey($from)) { $children[$from]=[Collections.Generic.List[object]]::new() }
    $children[$from].Add($r)
}
function Edges([int]$Id,[string]$Role) { @($children[$Id] | Where-Object { $_.attributes.role -eq $Role } | Sort-Object { [int]$_.attributes.ordinal }) }
function Child([int]$Id,[string]$Role) {
    $e=@(Edges $Id $Role)
    if ($e.Count -ne 1) { throw "Expected exactly one $Role edge on $Id; got $($e.Count)" }
    return [int]$e[0].to.id
}
function Binding([string]$Name) {
    $found=@($nodes.Values | Where-Object { $_.structural_kind -eq 'ClosureExpr' -and $_.fields.operation.function_binding -ceq $Name })
    if ($found.Count -ne 1) { throw "Expected unique binding $Name" }
    return [int]$found[0].id
}
$nextId = 1 + [int](($nodes.Keys | Measure-Object -Maximum).Maximum)
function Node([string]$Kind,[hashtable]$Fields) {
    # Native parse_node_line recognizes the literal prefix fields:{kind:.
    # Hashtable enumeration is not stable: always put kind first.
    $orderedFields=[ordered]@{kind=$Fields['kind']}
    foreach($key in @($Fields.Keys | Where-Object { $_ -ne 'kind' } | Sort-Object)) { $orderedFields[$key]=$Fields[$key] }
    $id=$script:nextId++; $script:nodes[$id]=[pscustomobject]@{id=$id;structural_kind=$Kind;fields=[pscustomobject]$orderedFields}; return $id
}
function Link([int]$From,[int]$To,[string]$Role,[int]$Ordinal=0) {
    $r=[pscustomobject]@{kind='syntax.child';from=$From;to=[pscustomobject]@{domain='node';id=[string]$To};attributes=[pscustomobject]@{role=$Role;ordinal=$Ordinal}}
    $script:relations.Add($r)
    if (!$script:children.ContainsKey($From)) { $script:children[$From]=[Collections.Generic.List[object]]::new() }
    $script:children[$From].Add($r)
}
function Ref([string]$Name) { Node 'SymbolRef' @{kind='identifier';name=$Name} }
function Int([int]$Value) { Node 'LiteralExpr' @{kind='literal';operation=@{literal_kind='integer';text=[string]$Value}} }
function Call([string]$Name,[int[]]$Arguments) {
    $id=Node 'CallExpr' @{kind='call'}; Link $id (Ref $Name) 'callee'
    for ($j=0;$j -lt $Arguments.Count;$j++) { Link $id $Arguments[$j] 'argument' $j }; return $id
}
$op=Binding 'op_code'; $opBody=Child $op 'body'
$compile=Binding 'compile_expr'; $compileBody=Child $compile 'body'
$helper=Binding 'compile_boolean_not_expr'
$reader=Binding 'parse_node_line'

# parse_node_line's semantic_id -> op_code -> node[24] is the existing ABI.
# The two new codes are private to this extension. Refuse collisions.
$opStatements=@(Edges $opBody 'statement')
$fallback=@($opStatements | Where-Object { $nodes[[int]$_.to.id].structural_kind -eq 'ReturnStmt' })
if ($fallback.Count -ne 1) { throw 'Expected one op_code fallback' }
$table=@{}
foreach ($e in $opStatements) {
    $branch=[int]$e.to.id
    if ($nodes[$branch].structural_kind -ne 'IfStmt') { continue }
    $condition=Child $branch 'condition'
    if ($nodes[$condition].structural_kind -ne 'CallExpr') { continue }
    $callee=Child $condition 'callee'
    if ($nodes[$callee].fields.name -ne 'slice_eq_cstr') { continue }
    $args=@(Edges $condition 'argument')
    if ($args.Count -ne 3) { continue }
    $text=[string]$nodes[[int]$args[2].to.id].fields.operation.text
    $then=Child $branch 'then'; $returns=@(Edges $then 'statement' | Where-Object { $nodes[[int]$_.to.id].structural_kind -eq 'ReturnStmt' })
    if ($returns.Count -ne 1) { continue }
    $returnEdges=@($children[[int]$returns[0].to.id] | Where-Object { $_.attributes.role -in @('expression','value') })
    if ($returnEdges.Count -ne 1) { throw "Ambiguous op_code return at $branch" }
    $code=[int]$nodes[[int]$returnEdges[0].to.id].fields.operation.text
    if ($table.ContainsKey($text)) { throw "Duplicate op_code semantic_id $text" }
    $table[$text]=$code
}
if (!$table.ContainsKey('boolean_not') -or $table['boolean_not'] -ne 15) { throw 'boolean_not=15 ABI missing' }
foreach ($pair in @(@('negate',16),@('bitwise_not',17))) {
    $name=[string]$pair[0]; $code=[int]$pair[1]
    if ($table.ContainsKey($name)) { if ($table[$name] -ne $code) { throw "$name ABI mismatch" }; continue }
    if (@($table.Values | Where-Object { $_ -eq $code }).Count) { throw "op_code $code already occupied" }
    $branch=Node 'IfStmt' @{kind='if'}
    $literal=Node 'LiteralExpr' @{kind='literal';operation=@{literal_kind='string';text=$name}}
    $condition=Call 'slice_eq_cstr' @((Ref 'p'),(Ref 'n'),$literal)
    $then=Node 'Scope' @{kind='block'}; $return=Node 'ReturnStmt' @{kind='return'}
    Link $return (Int $code) 'expression'; Link $then $return 'statement'
    Link $branch $condition 'condition'; Link $branch $then 'then'
    $at=[int]$fallback[0].attributes.ordinal
    foreach ($e in @(Edges $opBody 'statement')) { if ([int]$e.attributes.ordinal -ge $at) { $e.attributes.ordinal++ } }
    Link $opBody $branch 'statement' $at
    $table[$name]=$code
}

# Match the actual expression-context k==14 branches, including the first
# hand-emitter (baseline node3116), instead of trusting ordinal or node IDs.
# Break's shared backend tag14 is deliberately untouched in compile_stmt.
$rewired=[Collections.Generic.List[object]]::new()
foreach ($e in @(Edges $compileBody 'statement')) {
    $branch=[int]$e.to.id
    if ($nodes[$branch].structural_kind -ne 'IfStmt') { continue }
    $condition=Child $branch 'condition'; $v=$nodes[$condition]
    if ($v.structural_kind -ne 'OperationExpr' -or $v.fields.operation.semantic_id -ne 'equal') { continue }
    $left=$nodes[(Child $condition 'left')]; $right=$nodes[(Child $condition 'right')]
    if ($left.structural_kind -ne 'SymbolRef' -or $left.fields.name -ne 'k' -or $right.structural_kind -ne 'LiteralExpr' -or $right.fields.operation.text -ne '14') { continue }
    $then=Child $branch 'then'; $old=@(Edges $then 'statement')
    $returns=@($old | Where-Object { $nodes[[int]$_.to.id].structural_kind -eq 'ReturnStmt' })
    if ($returns.Count -ne 1) { throw "Expected unary branch terminal return at $branch" }
    foreach ($r in $old) { [void]$relations.Remove($r); [void]$children[$then].Remove($r) }
    $statement=Node 'ExprStmt' @{kind='expression'}
    Link $statement (Call 'compile_boolean_not_expr' @((Ref 'c'),(Ref 'id'))) 'expression'
    Link $then $statement 'statement' 0
    Link $then ([int]$returns[0].to.id) 'statement' 1
    $rewired.Add([pscustomobject]@{branch=$branch;condition=$condition;then=$then;ordinal=$e.attributes.ordinal})
}
if ($rewired.Count -lt 1) { throw 'No k==14 expression dispatch found' }
$out=[Collections.Generic.List[string]]::new()
foreach ($l in $lines[0..($nodeStart-1)]) { $out.Add($l) }
$out.Add('nodes=[')
$ordered=@($nodes.Values|Sort-Object id)
for($i=0;$i -lt $ordered.Count;$i++) { $j=$ordered[$i]|ConvertTo-Json -Compress -Depth 100; if($i -lt $ordered.Count-1){$j+=','}; $out.Add($j) }
$out.Add(']'); $out.Add('relations=[')
for($i=0;$i -lt $relations.Count;$i++) { $j=$relations[$i]|ConvertTo-Json -Compress -Depth 100; if($i -lt $relations.Count-1){$j+=','}; $out.Add($j) }
$out.Add(']')
foreach ($l in $lines[($relationEnd+1)..($lines.Count-1)]) { $out.Add($l) }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $output) | Out-Null
[IO.File]::WriteAllLines($output,$out,[Text.UTF8Encoding]::new($false))
$report=[ordered]@{input=$source;input_sha256=(Get-FileHash $source -Algorithm SHA256).Hash;output=$output;op_code=$op;parse_node_line=$reader;compile_expr=$compile;helper=$helper;rewired=@($rewired);semantic_codes=$table;return_stmt_policy='existing ReturnStmt nodes and value/expression relations untouched';reader_policy='Main owns unary kind/operand mapping'}
$report | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $work 'patch-report.json') -Encoding UTF8
$report | ConvertTo-Json -Depth 15
