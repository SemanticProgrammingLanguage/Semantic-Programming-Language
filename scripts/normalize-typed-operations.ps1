[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [switch]$DecodeGoStrings
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$source = (Resolve-Path -LiteralPath $InputPath).Path
$lines = [IO.File]::ReadAllLines($source)
$map = @{
    'integer.add' = 'add'; 'integer.subtract' = 'subtract';
    'integer.multiply' = 'multiply'; 'integer.divide' = 'divide'; 'integer.modulo' = 'modulo'; 'integer.less' = 'less_than';
    'integer.greater' = 'greater_than'; 'integer.less_or_equal' = 'less_or_equal';
    'integer.less_equal' = 'less_or_equal'; 'integer.greater_or_equal' = 'greater_or_equal';
    'integer.greater_equal' = 'greater_or_equal'; 'integer.equal' = 'equal';
    'integer.not_equal' = 'not_equal'; 'integer.and' = 'bit_and';
    'integer.or' = 'bit_or'; 'integer.xor' = 'bit_xor';
    'integer.bit_and' = 'bit_and'; 'integer.bit_or' = 'bit_or';
    'integer.bit_xor' = 'bit_xor'; 'integer.shift_left' = 'shift_left';
    'integer.shift_right' = 'shift_right'
}
$operatorMap = @{
    '+'='add'; '-'='subtract'; '*'='multiply'; '/'='divide'; '%'='modulo'; '<'='less_than'; '>'='greater_than';
    '<='='less_or_equal'; '>='='greater_or_equal'; '=='='equal'; '!='='not_equal';
    '&'='bit_and'; '|'='bit_or'; '<<'='shift_left'; '>>'='shift_right'
}
$normalized = 0
$literals = 0
$values = 0
$unknown = [Collections.Generic.List[string]]::new()
$binaryIds = @{}
$valueIds = @{}
$out = [Collections.Generic.List[string]]::new()

foreach ($line in $lines) {
    $trimmed = $line.Trim().TrimStart(',').TrimEnd(',')
    if ($DecodeGoStrings -and $trimmed -match '"structural_kind":"LiteralExpr"') {
        $literal = $trimmed | ConvertFrom-Json -Depth 100
        $operation = $literal.fields.operation
        if ($operation.literal_kind -eq 'string' -and [string]$operation.text -match '^".*"$') {
            $decoded = ([string]$operation.text) | ConvertFrom-Json
            if ($decoded -isnot [string]) { throw "Expected quoted Go string at node $($literal.id)" }
            $operation.text = $decoded
            if ($literal.fields.PSObject.Properties['value'] -and $literal.fields.value.PSObject.Properties['text']) {
                $literal.fields.value.text = $decoded
            }
            $comma = if ($line.TrimStart().StartsWith(',')) { ',' } else { '' }
            $out.Add($comma + ($literal | ConvertTo-Json -Compress -Depth 100)) | Out-Null
            continue
        }
    }
    # Canonical Go exports may serialize a node's field_mask before its id;
    # the flattened SWC graph normally starts records with id. Both are the
    # same node envelope, so identify operation nodes by structural_kind.
    if ($trimmed -match '"structural_kind":"OperationExpr"') {
        try {
            $node = $trimmed | ConvertFrom-Json -Depth 100
            $fields = $node.fields
            if ($fields.kind -eq 'expression') {
                # Typed Go serializes an expression statement as a generic
                # operation with an expression child. Canonical SWC uses
                # ExprStmt for that same ordered statement.
                $node.structural_kind = 'ExprStmt'
                $normalized++
            }
            $typed = $null
            $typedProperty = if ($null -ne $fields.operation) { $fields.operation.PSObject.Properties['typed'] } else { $null }
            if ($null -ne $typedProperty -and $null -ne $typedProperty.Value) {
                $typed = [string]$typedProperty.Value.name
            }
            if ([string]::IsNullOrEmpty($typed)) {
                $typed = ''
            }
            if ($typed -eq 'integer.literal') {
                $node.structural_kind = 'LiteralExpr'
                $fields.kind = 'literal'
                $fields.operation = [pscustomobject]@{
                    literal_kind = 'integer'
                    text = [string]$typedProperty.Value.text
                }
                $literals++
                $normalized++
            } elseif ($typed -eq 'integer.value') {
                $valueIds[[string]$node.id] = $true
                $values++
            } elseif ($map.ContainsKey($typed)) {
                $fields.kind = 'binary'
                $fields.operation = [pscustomobject]@{
                    semantic_id = $map[$typed]
                    semantics = [pscustomobject]@{ operation = $map[$typed] }
                }
                $binaryIds[[string]$node.id] = $true
                $normalized++
            } elseif ($typed -ne '') {
                $unknown.Add($typed) | Out-Null
            } elseif ($null -ne $fields.operation -and $null -ne $fields.operation.PSObject.Properties['operator']) {
                $operator = [string]$fields.operation.operator
                if ($operatorMap.ContainsKey($operator)) {
                    $fields.kind = 'binary'
                    $fields.operation = [pscustomobject]@{
                        semantic_id = $operatorMap[$operator]
                        semantics = [pscustomobject]@{ operation = $operatorMap[$operator] }
                    }
                    $normalized++
                }
            }
            $json = $node | ConvertTo-Json -Compress -Depth 100
            $comma = if ($line.TrimStart().StartsWith(',')) { ',' } else { '' }
            $out.Add($comma + $json) | Out-Null
            continue
        } catch {
            throw "OperationExpr line cannot be normalized in ${source}: $($_.Exception.Message)"
        }
    }
    # Relation object property order varies between native SE and canonical
    # JSON exports. Match the relation kind rather than a fixed key order.
    if ($trimmed -match '"kind":"syntax\.child"') {
        try {
            $relation = $trimmed | ConvertFrom-Json -Depth 100
            $from = [string]$relation.from
            if ($binaryIds.ContainsKey($from) -and [string]$relation.attributes.role -eq 'argument') {
                $relation.attributes.role = if ([int]$relation.attributes.ordinal -eq 0) { 'left' } else { 'right' }
                $json = $relation | ConvertTo-Json -Compress -Depth 100
                $comma = if ($line.TrimStart().StartsWith(',')) { ',' } else { '' }
                $out.Add($comma + $json) | Out-Null
                continue
            }
        } catch {
            throw "Relation line cannot be normalized in ${source}: $($_.Exception.Message)"
        }
    }
    $out.Add($line) | Out-Null
}

$uniqueUnknown = @($unknown | Sort-Object -Unique)
if ($uniqueUnknown.Count -gt 0) {
    throw "Unsupported typed operation names: $([string]::Join(', ', $uniqueUnknown))"
}
$parent = Split-Path -Parent $OutputPath
if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
[IO.File]::WriteAllLines([IO.Path]::GetFullPath($OutputPath), $out, [Text.UTF8Encoding]::new($false))
"OUTPUT=$([IO.Path]::GetFullPath($OutputPath)) NORMALIZED=$normalized LITERALS=$literals VALUES=$values"
