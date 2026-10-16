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

function Resolve-WrapperId([string]$Id, [hashtable]$Map) {
    $seen = [Collections.Generic.HashSet[string]]::new()
    while ($Map.ContainsKey($Id)) {
        if (!$seen.Add($Id)) { throw "cycle in integer.value wrappers at node $Id" }
        $Id = [string]$Map[$Id]
    }
    return $Id
}

function Rewrite-NodeReferences([object]$Value, [hashtable]$Map) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [Array]) {
        $result = [Collections.Generic.List[object]]::new()
        foreach ($item in $Value) { $result.Add((Rewrite-NodeReferences $item $Map)) | Out-Null }
        return ,$result.ToArray()
    }
    if ($Value -is [string] -or $Value.GetType().IsValueType) { return $Value }
    $domain = $Value.PSObject.Properties['domain']
    $id = $Value.PSObject.Properties['id']
    if ($null -ne $domain -and [string]$domain.Value -eq 'node' -and $null -ne $id) {
        $id.Value = Resolve-WrapperId ([string]$id.Value) $Map
        return $Value
    }
    foreach ($property in @($Value.PSObject.Properties)) {
        $property.Value = Rewrite-NodeReferences $property.Value $Map
    }
    return $Value
}

$source = (Resolve-Path -LiteralPath $InputPath).Path
$nodes = [Collections.Generic.List[object]]::new(@(Read-Items $source 'nodes'))
$relations = [Collections.Generic.List[object]]::new(@(Read-Items $source 'relations'))
$outgoing = @{}
foreach ($relation in $relations) {
    $from = [string]$relation.from
    if (!$outgoing.ContainsKey($from)) { $outgoing[$from] = [Collections.Generic.List[object]]::new() }
    $outgoing[$from].Add($relation) | Out-Null
}

$wrapperMap = @{}
$lowered = 0
$rewiredDataUse = 0
foreach ($node in @($nodes | Where-Object {
    $_.structural_kind -eq 'OperationExpr' -and
    $null -ne $_.fields.operation -and
    $null -ne $_.fields.operation.PSObject.Properties['typed'] -and
    [string]$_.fields.operation.typed.name -eq 'integer.value'
})) {
    $id = [string]$node.id
    $edges = @()
    if ($outgoing.ContainsKey($id)) {
        $edges = @($outgoing[$id] | Where-Object {
            $_.kind -eq 'syntax.child' -and $_.to.domain -eq 'node' -and
            $_.attributes.role -eq 'argument'
        })
    }
    if ($edges.Count -ne 1) { throw "integer.value $id requires exactly one argument child" }
    $wrapperMap[$id] = [string]$edges[0].to.id
    $lowered++
}

foreach ($id in @($wrapperMap.Keys)) { [void](Resolve-WrapperId $id $wrapperMap) }
foreach ($node in $nodes) {
    if (!$wrapperMap.ContainsKey([string]$node.id)) {
        $node.fields = Rewrite-NodeReferences $node.fields $wrapperMap
    }
}
$newNodes = @($nodes | Where-Object { !$wrapperMap.ContainsKey([string]$_.id) })
$newRelations = [Collections.Generic.List[object]]::new()
foreach ($relation in $relations) {
    $sourceId = [string]$relation.from
    $sourceWasWrapper = $wrapperMap.ContainsKey($sourceId)
    $targetWasWrapper = $relation.to.domain -eq 'node' -and $wrapperMap.ContainsKey([string]$relation.to.id)
    if ($sourceWasWrapper -and $relation.kind -in @('syntax.child', 'operation.kind')) { continue }
    if ($sourceWasWrapper) { $relation.from = [long](Resolve-WrapperId $sourceId $wrapperMap) }
    if ($targetWasWrapper) { $relation.to.id = Resolve-WrapperId ([string]$relation.to.id) $wrapperMap }
    if ($relation.to.domain -eq 'node' -and [string]$relation.from -eq [string]$relation.to.id) { continue }
    if ($relation.kind -eq 'data.def_use' -and ($sourceWasWrapper -or $targetWasWrapper)) { $rewiredDataUse++ }
    $newRelations.Add($relation) | Out-Null
}
$metadata = [ordered]@{
    'swc.lowering.typed_value' = "transparent_value_wrappers=$lowered;data_def_use_retargeted=$rewiredDataUse"
}
$nodeLines = @($newNodes | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 100 })
$relLines = @($newRelations | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 100 })
$prefix = "# Semantic Programming Language`r`nse 1`r`nprogram {`r`nschema=1`r`nprojection=`"semantic_document.v1`"`r`norigin={`"source_language`":`"semantic`",`"entry_point`":`"main`"}`r`nevaluation=`"eager_left_to_right`"`r`nindex_base=0`r`nvalue_model=`"explicit`"`r`nnodes=[`r`n"
$nodeBody = [string]::Join(",`r`n", $nodeLines)
$relBody = [string]::Join(",`r`n", $relLines)
$metaJson = $metadata | ConvertTo-Json -Compress -Depth 20
$result = $prefix + $nodeBody + "`r`n]`r`nrelations=[`r`n" + $relBody + "`r`n]`r`nmetadata=" + $metaJson + "`r`n}`r`n"
$parent = Split-Path -Parent $OutputPath
if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath), $result, [Text.UTF8Encoding]::new($false))
"OUTPUT=$([IO.Path]::GetFullPath($OutputPath)) LOWERED_TYPED_VALUES=$lowered RETARGETED_DATA_DEF_USE=$rewiredDataUse NODES=$($newNodes.Count) RELATIONS=$($newRelations.Count)"
