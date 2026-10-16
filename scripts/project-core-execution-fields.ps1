[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-Items([string]$Path, [string]$Section) {
    $active = $false
    $items = [Collections.Generic.List[object]]::new()
    foreach ($line in [IO.File]::ReadLines((Resolve-Path -LiteralPath $Path))) {
        $s = $line.Trim()
        if ($s -eq "$Section=[") { $active = $true; continue }
        if ($active -and $s -eq ']') { break }
        if (!$active) { continue }
        $json = $s.TrimStart(',').TrimEnd(',')
        if ($json.StartsWith('{')) { $items.Add(($json | ConvertFrom-Json -Depth 100)) | Out-Null }
    }
    return $items
}

$source = (Resolve-Path -LiteralPath $InputPath).Path
$nodes = @(Read-Items $source 'nodes')
$relations = @(Read-Items $source 'relations')
$unknown = [Collections.Generic.List[string]]::new()
$projected = 0

foreach ($node in $nodes) {
    $old = $node.fields
    $kind = [string]$node.structural_kind
    $fields = [ordered]@{}
    switch ($kind) {
        'ClosureExpr' {
            $fields.kind = 'function'
            $fields.name = if ($null -ne $old.PSObject.Properties['name']) { [string]$old.name } else { '' }
            $binding = if ($null -ne $old.PSObject.Properties['operation'] -and $null -ne $old.operation.PSObject.Properties['function_binding']) { [string]$old.operation.function_binding } else { $fields.name }
            $fields.operation = [ordered]@{ function_binding = $binding }
        }
        'ParameterDecl' { $fields.kind = 'parameter'; $fields.name = if ($null -ne $old.PSObject.Properties['name']) { [string]$old.name } else { '' } }
        'Scope' { $fields.kind = 'block' }
        'SymbolRef' { $fields.kind = 'identifier'; $fields.name = [string]$old.name }
        'AssignStmt' { $fields.kind = 'assign'; $fields.name = if ($null -ne $old.PSObject.Properties['name']) { [string]$old.name } else { '' } }
        'CallExpr' { $fields.kind = 'call' }
        'ExprStmt' { $fields.kind = 'expression' }
        'IfStmt' { $fields.kind = 'if' }
        'LoopStmt' { $fields.kind = [string]$old.kind; if ([string]::IsNullOrEmpty($fields.kind)) { $fields.kind = 'while' } }
        'ForEachStmt' { $fields.kind = 'foreach' }
        'ContinueStmt' { $fields.kind = 'continue' }
        'BreakStmt' { $fields.kind = 'break' }
        'ReturnStmt' { $fields.kind = 'return' }
        'LiteralExpr' {
            $fields.kind = 'literal'
            $op = $old.operation
            $literalKind = if ($null -ne $op -and $null -ne $op.PSObject.Properties['literal_kind']) { [string]$op.literal_kind } else { '' }
            $literalText = if ($null -ne $op -and $null -ne $op.PSObject.Properties['text']) { [string]$op.text } else { '' }
            if ($literalKind -eq 'missing') { $literalKind = 'integer'; $literalText = '0' }
            if ([string]::IsNullOrEmpty($literalKind)) { throw "LiteralExpr $($node.id) has no literal kind" }
            $fields.operation = [ordered]@{ literal_kind = $literalKind; text = $literalText }
        }
        'OperationExpr' {
            $fields.kind = if ($null -ne $old.PSObject.Properties['kind']) { [string]$old.kind } else { 'binary' }
            $op = $old.operation
            $semantic = if ($null -ne $op -and $null -ne $op.PSObject.Properties['semantic_id']) { [string]$op.semantic_id } else { '' }
            if ([string]::IsNullOrEmpty($semantic)) { throw "OperationExpr $($node.id) has no canonical semantic_id" }
            $fields.operation = [ordered]@{ semantic_id = $semantic; semantics = [ordered]@{ operation = $semantic } }
        }
        'AggregateExpr' { $fields.kind = 'aggregate' }
        'IndexExpr' { $fields.kind = 'index' }
        'MemberAccessExpr' { $fields.kind = 'member'; $fields.name = if ($null -ne $old.PSObject.Properties['name']) { [string]$old.name } else { '' } }
        'SliceExpr' { $fields.kind = 'slice' }
        default { $unknown.Add("$kind@$($node.id)") | Out-Null; continue }
    }
    $node.fields = [pscustomobject]$fields
    $projected++
}
if ($unknown.Count -gt 0) { throw "Unsupported structural kinds: $([string]::Join(', ', @($unknown | Select-Object -First 20)))" }
$callIds = [Collections.Generic.HashSet[string]]::new()
foreach ($node in $nodes) {
    if ($node.structural_kind -eq 'CallExpr') { [void]$callIds.Add([string]$node.id) }
}
foreach ($relation in $relations) {
    # The typed Go exporter places a call's function value in role=value.
    # Native SWC's canonical role for that same edge is callee. This mapping
    # is restricted to CallExpr and does not rewrite ordinary data values.
    if ($relation.kind -eq 'syntax.child' -and $callIds.Contains([string]$relation.from) -and
        $relation.attributes.role -in @('value','function','target')) {
        $relation.attributes.role = 'callee'
    }
}
$nodeLines = @($nodes | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 100 })
$relLines = @($relations | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 100 })
$prefix = "# Semantic Programming Language`r`nse 1`r`nprogram {`r`nschema=1`r`nprojection=`"semantic_document.v1`"`r`norigin={`"source_language`":`"semantic`",`"entry_point`":`"main`"}`r`nevaluation=`"eager_left_to_right`"`r`nindex_base=0`r`nvalue_model=`"explicit`"`r`nnodes=[`r`n"
$result = $prefix + [string]::Join(",`r`n", $nodeLines) + "`r`n]`r`nrelations=[`r`n" + [string]::Join(",`r`n", $relLines) + "`r`n]`r`nmetadata={`"swc.projection`":`"core-execution-fields`"}`r`n}`r`n"
$parent = Split-Path -Parent $OutputPath
if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath), $result, [Text.UTF8Encoding]::new($false))
"OUTPUT=$([IO.Path]::GetFullPath($OutputPath)) PROJECTED_NODES=$projected RELATIONS=$($relations.Count)"
