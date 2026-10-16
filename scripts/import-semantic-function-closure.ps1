[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CorePath,
    [Parameter(Mandatory = $true)][string[]]$UnitPath,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [string[]]$RootBinding = @(),
    [switch]$ImportAll,
    [switch]$AllowUnresolved,
    [switch]$ReplaceStubs,
    [switch]$AllocateAfterMax,
    [switch]$KeepLowIds,
    [switch]$EnablePebIntrinsic,
    [switch]$EnableWin64CallIntrinsics,
    [string[]]$ReplaceBinding = @(),
    [string]$ReportPath
)

$ErrorActionPreference = 'Stop'

function Read-SemanticGraph([string]$Path) {
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $nodes = [Collections.Generic.List[object]]::new()
    $relations = [Collections.Generic.List[object]]::new()
    # Large linked bundles are valid semantic documents whose nodes and
    # relations are serialized on one line.  Parse those arrays as JSON first;
    # the line-oriented fallback below remains for ordinary compact units.
    $whole = [IO.File]::ReadAllText($resolved)
    # Canonical UAST JSON is the lossless transport emitted by
    # `semantic-convert`.  Import it directly instead of reparsing its readable
    # projection line-by-line, so field values and relation attributes retain
    # their exact JSON shape.
    if ($whole.TrimStart().StartsWith('{')) {
        try {
            $document = $whole | ConvertFrom-Json
            if ($null -ne $document.nodes -and $null -ne $document.relations) {
                foreach ($item in @($document.nodes)) { $nodes.Add($item) }
                foreach ($item in @($document.relations)) { $relations.Add($item) }
                if ($nodes.Count -gt 0) {
                    return [pscustomobject]@{ Path=$resolved; Nodes=$nodes; Relations=$relations; Extensions=$document.extensions }
                }
            }
        }
        catch {
            # Continue to the historical compact-SE paths below; their
            # diagnostics remain more specific for non-UAST JSON documents.
        }
    }
    $oneLineNodes = [regex]::Match($whole, '(?m)^nodes=\[(?<json>.*)\]\r?\nrelations=\[', [Text.RegularExpressions.RegexOptions]::Singleline)
    $oneLineRelations = [regex]::Match($whole, '(?m)^relations=\[(?<json>.*)\]\r?\nmetadata=', [Text.RegularExpressions.RegexOptions]::Singleline)
    if ($oneLineNodes.Success -and $oneLineRelations.Success) {
        $nodeBody = $oneLineNodes.Groups['json'].Value.Trim().TrimStart(',')
        $relationBody = $oneLineRelations.Groups['json'].Value.Trim().TrimStart(',')
        # Some historical linked bundles accidentally placed a second node
        # segment after `relations=[` and before the first actual relation.
        # Preserve that segment instead of discarding it or feeding it to the
        # relation decoder.
        $firstRelation = $relationBody.IndexOf('{"kind":"syntax.child"')
        # Only linked bundles with an actual node object at the beginning of
        # the relation segment need the historical extra-node recovery.  Rich
        # stream-split units serialize relations with `attributes` first; in
        # those files the first `{"kind":...}` may be the final root edge and
        # must not cause all preceding relations to be discarded.
        $leadingRelation = $relationBody.TrimStart()
        if ($firstRelation -gt 0 -and $leadingRelation.StartsWith('{"id":')) {
            $extraNodeBody = $relationBody.Substring(0, $firstRelation).Trim().TrimEnd(',')
            foreach ($item in @((('[' + $extraNodeBody + ']') | ConvertFrom-Json))) { $nodes.Add($item) }
            $relationBody = $relationBody.Substring($firstRelation)
        }
        try {
            foreach ($item in @((('[' + $nodeBody + ']') | ConvertFrom-Json))) { $nodes.Add($item) }
            foreach ($item in @((('[' + $relationBody + ']') | ConvertFrom-Json))) { $relations.Add($item) }
            if ($nodes.Count -eq 0) { throw "Linked semantic graph contains no nodes: $resolved" }
            return [pscustomobject]@{ Path=$resolved; Nodes=$nodes; Relations=$relations; Extensions=$null }
        } catch {
            # Large selfhost graphs can contain a valid line-oriented node
            # stream that is not a single JSON array after historical merges.
            # Fall through to the lossless line parser below instead of
            # rejecting the complete graph at the first JSON-array failure.
            $nodes.Clear()
            $relations.Clear()
        }
    }
    $section = ''
    foreach ($line in [IO.File]::ReadLines($resolved)) {
        $text = $line.Trim().TrimStart(',').TrimEnd(',')
        # Accept both canonical compact spellings emitted by the different
        # Semantic writers.  The whitespace form is semantically identical:
        # `nodes=[` and `nodes = [` must enter the same lossless reader path.
        if ($text -match '^nodes\s*=\s*\[$') { $section = 'nodes'; continue }
        if ($text -match '^relations\s*=\s*\[$') { $section = 'relations'; continue }
        if ($text -eq ']') { $section = ''; continue }
        if (!$text.StartsWith('{')) { continue }
        try { $item = $text | ConvertFrom-Json } catch { continue }
        if ($section -eq 'nodes') { $nodes.Add($item) }
        elseif ($section -eq 'relations') { $relations.Add($item) }
    }
    if ($nodes.Count -eq 0) { throw "No compact semantic graph found in $resolved" }
    [pscustomobject]@{ Path=$resolved; Nodes=$nodes; Relations=$relations; Extensions=$null }
}

function New-GraphIndex([object]$Graph) {
    $nodeById = @{}
    $children = @{}
    $childEdges = @{}
    $closures = @{}
    $closureCandidates = @{}
    $closureAssignments = @{}
    foreach ($node in $Graph.Nodes) {
        $id = [string]$node.id
        $nodeById[$id] = $node
        if ($node.structural_kind -eq 'ClosureExpr' -and $node.fields.operation.function_binding) {
            $binding = [string]$node.fields.operation.function_binding
            if (!$closureCandidates.ContainsKey($binding)) {
                $closureCandidates[$binding] = [Collections.Generic.List[string]]::new()
            }
            $closureCandidates[$binding].Add($id)
        }
    }
    foreach ($relation in $Graph.Relations) {
        # Historical stream-split units can deserialize scalar JSON fields as
        # Int64/PSCustomObject values instead of the exact string shape used
        # by the canonical writer.  Normalize only the discriminators here;
        # the relation payload itself remains lossless and is serialized below.
        if ([string]$relation.kind -ne 'syntax.child' -or [string]$relation.to.domain -ne 'node') { continue }
        $from = [string]$relation.from
        if (!$children.ContainsKey($from)) { $children[$from] = [Collections.Generic.List[string]]::new() }
        $children[$from].Add([string]$relation.to.id)
        if (!$childEdges.ContainsKey($from)) { $childEdges[$from] = [Collections.Generic.List[object]]::new() }
        $childEdges[$from].Add([pscustomobject]@{
            Id=[string]$relation.to.id
            Role=[string]$relation.attributes.role
            Ordinal=if ($null -ne $relation.attributes.ordinal) { [int]$relation.attributes.ordinal } else { 0 }
        })
        $childId = [string]$relation.to.id
        if ($nodeById.ContainsKey($childId) -and $nodeById[$childId].structural_kind -eq 'ClosureExpr') {
            if (!$closureAssignments.ContainsKey($childId)) { $closureAssignments[$childId] = [Collections.Generic.List[string]]::new() }
            $closureAssignments[$childId].Add($from)
        }
    }
    # Go-transpiler canonical JSON preserves a named function's assignment
    # (`AssignStmt.fields.name`) and its exact syntax.child edge to the
    # ClosureExpr, but semantic-convert does not serialize the SWC-specific
    # operation.function_binding field. Recover only the explicit native
    # function binding form; never infer a binding from a SymbolRef spelling.
    foreach ($closureId in $closureAssignments.Keys) {
        $parents = @($closureAssignments[$closureId] | Select-Object -Unique)
        if ($parents.Count -ne 1) { continue }
        $parent = $nodeById[[string]$parents[0]]
        if ($parent.structural_kind -ne 'AssignStmt') { continue }
        $binding = [string]$parent.fields.name
        if ($binding -notmatch '^native_function_[0-9]+$') { continue }
        if (!$closures.ContainsKey($binding)) { $closures[$binding] = [string]$closureId }
    }
    # Canonical Semantic JSON stores the source-level function binding in the
    # existing function_entry_bindings extension while the ClosureExpr itself
    # only carries the native_function_N assignment.  Preserve that explicit
    # contract instead of comparing or guessing names from the body.
    $entryBindings = $Graph.Extensions.function_entry_bindings
    if ($null -ne $entryBindings) {
        foreach ($property in $entryBindings.PSObject.Properties) {
            $semanticBinding = [string]$property.Name
            $nativeBinding = [string]$property.Value
            if ($closures.ContainsKey($nativeBinding)) {
                $closures[$semanticBinding] = [string]$closures[$nativeBinding]
            }
        }
    }
    # Linked Semantic graphs may contain historical duplicate implementations
    # of one binding.  Last-write-wins can select a one-node placeholder that
    # appears after the complete implementation.  Select the largest syntax
    # subtree and use the lowest ID as a deterministic tie-breaker.
    foreach ($binding in $closureCandidates.Keys) {
        $best = $null
        $bestSize = -1
        foreach ($candidateId in $closureCandidates[$binding]) {
            $seen = [Collections.Generic.HashSet[string]]::new()
            $queue = [Collections.Generic.Queue[string]]::new()
            $queue.Enqueue([string]$candidateId)
            while ($queue.Count -gt 0) {
                $current = $queue.Dequeue()
                if (!$seen.Add($current)) { continue }
                if ($children.ContainsKey($current)) {
                    foreach ($childId in $children[$current]) { $queue.Enqueue([string]$childId) }
                }
            }
            $size = $seen.Count
            if ($size -gt $bestSize -or ($size -eq $bestSize -and ($null -eq $best -or [int]$candidateId -lt [int]$best))) {
                $best = [string]$candidateId
                $bestSize = $size
            }
        }
        if ($null -ne $best) { $closures[$binding] = $best }
    }
    [pscustomobject]@{ NodeById=$nodeById; Children=$children; ChildEdges=$childEdges; Closures=$closures }
}

function Get-SyntaxSubtree([string]$Root, [object]$Index) {
    $seen = [Collections.Generic.HashSet[string]]::new()
    $queue = [Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($Root)
    while ($queue.Count -gt 0) {
        $id = $queue.Dequeue()
        if (!$seen.Add($id)) { continue }
        if ($Index.Children.ContainsKey($id)) {
            foreach ($child in $Index.Children[$id]) { $queue.Enqueue($child) }
        }
    }
    $seen
}

function Get-FunctionCalls([Collections.Generic.HashSet[string]]$Ids, [object]$Index, [hashtable]$KnownBindings) {
    $calls = [Collections.Generic.HashSet[string]]::new()
    foreach ($id in $Ids) {
        $node = $Index.NodeById[$id]
        if ($null -eq $node -or $node.structural_kind -ne 'CallExpr') { continue }
        if (!$Index.ChildEdges.ContainsKey($id)) {
            throw "CallExpr $id has no child relations; refusing incomplete function import"
        }
        $targetEdges = @($Index.ChildEdges[$id] | Where-Object { $_.Role -in @('callee','function','target','value') })
        if ($targetEdges.Count -eq 0) {
            throw "CallExpr $id has arguments but no callee relation; refusing incomplete function import"
        }
        foreach ($edge in @($Index.ChildEdges[$id] | Sort-Object Ordinal)) {
            # Canonical units use `callee`; the ISA-L execution projection
            # carries the direct call target in the same `value` slot used by
            # its original CallExpr graph.  This branch only runs for
            # CallExpr, so accepting value here cannot turn an ordinary data
            # dependency into a function import.
            if ($edge.Role -notin @('callee','function','target','value')) { continue }
            $child = $Index.NodeById[$edge.Id]
            if ($null -ne $child -and $child.structural_kind -eq 'SymbolRef' -and $child.fields.name) {
                $name = [string]$child.fields.name
                if ($name.StartsWith('native_var_')) {
                    $unwrapped = $name.Substring('native_var_'.Length)
                    if ($KnownBindings.ContainsKey($unwrapped)) { $name = [string]$KnownBindings[$unwrapped] }
                } elseif ($KnownBindings.ContainsKey($name)) {
                    $name = [string]$KnownBindings[$name]
                }
                [void]$calls.Add($name)
            }
        }
    }
    $calls
}

function Rewrite-NodeReferences([string]$Json, [hashtable]$Map) {
    [regex]::Replace($Json, '"domain":"node","id":"?(?<id>[0-9]+)"?', {
        param($match)
        $old = $match.Groups['id'].Value
        if (!$Map.ContainsKey($old)) { return $match.Value }
        '"domain":"node","id":"' + $Map[$old] + '"'
    })
}

$core = Read-SemanticGraph $CorePath
$coreIndex = New-GraphIndex $core
$sources = [Collections.Generic.List[object]]::new()
foreach ($pathPattern in $UnitPath) {
    $matches = @(Get-ChildItem -Path $pathPattern -File -ErrorAction SilentlyContinue)
    if ($matches.Count -eq 0 -and (Test-Path -LiteralPath $pathPattern -PathType Leaf)) {
        $matches = @(Get-Item -LiteralPath $pathPattern)
    }
    foreach ($file in $matches) {
        try {
            $graph = Read-SemanticGraph $file.FullName
            $sources.Add([pscustomobject]@{ Graph=$graph; Index=(New-GraphIndex $graph) })
        } catch {
            Write-Warning $_.Exception.Message
        }
    }
}
if ($sources.Count -eq 0) { throw 'No readable Semantic source units were supplied.' }

# Choose the richest deterministic implementation for each binding. This
# deduplicates repeated transpiler snapshots without comparing names alone:
# the complete syntax subtree size and source path participate in selection.
$catalog = @{}
foreach ($source in $sources) {
    foreach ($entry in $source.Index.Closures.GetEnumerator()) {
        $binding = [string]$entry.Key
        $subtree = Get-SyntaxSubtree ([string]$entry.Value) $source.Index
        $candidate = [pscustomobject]@{
            Binding=$binding; Root=[string]$entry.Value; Graph=$source.Graph
            Index=$source.Index; Nodes=$subtree; Size=$subtree.Count
            Path=$source.Graph.Path
        }
        if (!$catalog.ContainsKey($binding) -or
            $candidate.Size -gt $catalog[$binding].Size -or
            ($candidate.Size -eq $catalog[$binding].Size -and $candidate.Path -lt $catalog[$binding].Path)) {
            $catalog[$binding] = $candidate
        }
    }
}

# Preserve package-qualified backend calls when a transpiled Go unit stores
# its ClosureExpr binding with the equivalent underscore spelling.  Add only
# aliases whose target ClosureExpr is present; do not infer arbitrary names.
$bindingLookup = @{}
foreach ($binding in $catalog.Keys) { $bindingLookup[[string]$binding] = [string]$binding }
foreach ($binding in $coreIndex.Closures.Keys) { if (!$bindingLookup.ContainsKey([string]$binding)) { $bindingLookup[[string]$binding] = [string]$binding } }
foreach ($source in $sources) {
    $exports = $source.Graph.Extensions.function_entry_bindings
    if ($null -eq $exports) { continue }
    foreach ($export in $exports.PSObject.Properties) {
        $publicName = [string]$export.Name
        $internalName = [string]$export.Value
        if ($catalog.ContainsKey($publicName) -and $catalog.ContainsKey($internalName) -and
            $catalog[$publicName].Path -eq $source.Graph.Path -and
            $catalog[$internalName].Path -eq $source.Graph.Path -and
            $catalog[$publicName].Root -eq $catalog[$internalName].Root) {
            $bindingLookup[$internalName] = $publicName
        }
    }
}
# The rich reader bundle uses the documented memory ABI spellings while the
# Windows SWC core exposes the same four primitives under its native emitter
# bindings.  Preserve the call graph by aliasing only when the target core
# closure is actually present; do not manufacture arbitrary runtime symbols.
foreach ($abiAlias in @{
    'mem_load64' = 'load64'
    'mem_load8' = 'load8'
    'mem_store64' = 'store64'
    'mem_store8' = 'store8'
}.GetEnumerator()) {
    if ($coreIndex.Closures.ContainsKey([string]$abiAlias.Value) -and
        !$bindingLookup.ContainsKey([string]$abiAlias.Key)) {
        $bindingLookup[[string]$abiAlias.Key] = [string]$abiAlias.Value
    }
}

# The legacy CLI unit exposes the text-transpile entry under the historical
# `SLCTranspileText` binding.  The active SWC graph carries the same
# source/target/code -> result contract as `transpile_with_semantics`; keep
# the call graph intact by rebinding only when the canonical target closure is
# present.  This is a documented compatibility alias, not a synthesized
# implementation.
if ($coreIndex.Closures.ContainsKey('transpile_with_semantics')) {
    $bindingLookup['SLCTranspileText'] = 'transpile_with_semantics'
    # Legacy transpiler units use the short `transpile` export.  The active
    # SWC graph exposes the same source/target/code contract under the
    # semantic-preserving matrix entry; rebind only when that canonical
    # implementation is present.
    if (!$bindingLookup.ContainsKey('transpile')) {
        $bindingLookup['transpile'] = 'transpile_with_semantics'
    }
}
if ($coreIndex.Closures.ContainsKey('transpile_matrix_dispatch_languages') -and
    !$bindingLookup.ContainsKey('TranspileCore')) {
    # Many-to-Many SE snapshots call their canonical source/target/code entry
    # `TranspileCore`.  The current SWC graph exposes that same contract via
    # the already validated 13x13 language dispatcher.
    $bindingLookup['TranspileCore'] = 'transpile_matrix_dispatch_languages'
}
foreach ($binding in @($bindingLookup.Keys)) {
    if ($binding.StartsWith('backend_')) {
        $alias = 'backend.' + $binding.Substring('backend_'.Length)
        if (!$bindingLookup.ContainsKey($alias)) { $bindingLookup[$alias] = [string]$binding }
    } elseif ($binding.StartsWith('backend.')) {
        $alias = 'backend_' + $binding.Substring('backend.'.Length)
        if (!$bindingLookup.ContainsKey($alias)) { $bindingLookup[$alias] = [string]$binding }
    }
}
# The Go transpiler projection preserves package qualification in callee
# symbols, while the canonical SWC units expose the same closures at module
# scope.  Add the qualified spelling only when the unqualified closure is
# explicitly present in the catalog/core; this is a binding compatibility
# relation, not a synthesized implementation.
foreach ($binding in @($bindingLookup.Keys)) {
    if ($binding -notmatch '^(backend[._])' -and
        !$bindingLookup.ContainsKey('backend.' + [string]$binding)) {
        $bindingLookup['backend.' + [string]$binding] = [string]$binding
    }
}
if ($coreIndex.Closures.ContainsKey('parse') -and !$bindingLookup.ContainsKey('Parse')) {
    $bindingLookup['Parse'] = 'parse'
}
foreach ($intrinsicName in @('mem_load8','mem_load64','mem_store8','mem_store64','address_of','sys_mmap','sys_open','sys_read','sys_write','sys_close')) {
    if (!$bindingLookup.ContainsKey($intrinsicName)) { $bindingLookup[$intrinsicName] = $intrinsicName }
}
if ($EnablePebIntrinsic -or $coreIndex.Closures.ContainsKey('emit_win64_peb_address')) {
    # The unresolved source spelling is frontend qualification of the same
    # intrinsic, not a new external runtime dependency. Availability is checked
    # against compile_expr below before accepting the canonical call.
    $bindingLookup['ifree_peb_address'] = 'ifree_peb_address'
}
if ($EnableWin64CallIntrinsics -or $coreIndex.Closures.ContainsKey('compile_ifree_win64_call')) {
    foreach ($arity in 0..7) {
        $bindingLookup['ifree_win64_call'+$arity] = 'ifree_win64_call'+$arity
    }
}

$requested = [Collections.Generic.Queue[string]]::new()
if ($ImportAll) {
    foreach ($binding in @($catalog.Keys | Sort-Object)) { $requested.Enqueue($binding) }
} else {
    foreach ($binding in $RootBinding) { $requested.Enqueue($binding) }
}
if ($requested.Count -eq 0) { throw 'Specify -RootBinding or -ImportAll.' }

$selected = [Collections.Generic.HashSet[string]]::new()
$missing = [Collections.Generic.HashSet[string]]::new()
$dependencyEdges = [Collections.Generic.List[object]]::new()
while ($requested.Count -gt 0) {
    $binding = $requested.Dequeue()
    if (!$selected.Add($binding)) { continue }
    if (!$catalog.ContainsKey($binding)) { [void]$missing.Add($binding); continue }
    $candidate = $catalog[$binding]
    $calls = Get-FunctionCalls $candidate.Nodes $candidate.Index $bindingLookup
    foreach ($callee in $calls) {
        $dependencyEdges.Add([pscustomobject]@{ caller=$binding; callee=$callee })
        $coreNeedsImplementation = !$coreIndex.Closures.ContainsKey($callee)
        if (!$coreNeedsImplementation -and $catalog.ContainsKey($callee)) {
            $coreNeedsImplementation = (Get-SyntaxSubtree ([string]$coreIndex.Closures[$callee]) $coreIndex).Count -le 6
        }
        if ($catalog.ContainsKey($callee) -and $coreNeedsImplementation -and !$selected.Contains($callee)) {
            $requested.Enqueue($callee)
        }
    }
}

$replace = [Collections.Generic.HashSet[string]]::new()
foreach ($binding in $ReplaceBinding) { [void]$replace.Add($binding) }
if ($ReplaceStubs) {
    foreach ($entry in $coreIndex.Closures.GetEnumerator()) {
        $subtree = Get-SyntaxSubtree ([string]$entry.Value) $coreIndex
        if ($subtree.Count -le 6 -and $selected.Contains([string]$entry.Key)) { [void]$replace.Add([string]$entry.Key) }
    }
}

$unresolvedCallees = [Collections.Generic.HashSet[string]]::new()
$nativeRuntimeBindings = [Collections.Generic.HashSet[string]]::new([string[]]@(
    'sys_mmap','sys_open','sys_read','sys_write','sys_close',
    'mem_load8','mem_load64','mem_store8','mem_store64','address_of'
))
if ($EnablePebIntrinsic) { [void]$nativeRuntimeBindings.Add('ifree_peb_address') }
if ($EnableWin64CallIntrinsics) {
    foreach ($arity in 0..7) { [void]$nativeRuntimeBindings.Add('ifree_win64_call'+$arity) }
}
if ($coreIndex.Closures.ContainsKey('compile_ifree_win64_call') -and $coreIndex.Closures.ContainsKey('compile_expr')) {
    $compileIds = Get-SyntaxSubtree ([string]$coreIndex.Closures['compile_expr']) $coreIndex
    $compileCalls = Get-FunctionCalls $compileIds $coreIndex $bindingLookup
    if ($compileCalls.Contains('compile_ifree_win64_call')) {
        foreach ($arity in 0..7) { [void]$nativeRuntimeBindings.Add('ifree_win64_call'+$arity) }
    }
}
if ($coreIndex.Closures.ContainsKey('compile_expr') -and $coreIndex.Closures.ContainsKey('emit_win64_peb_address')) {
    $compileIds = Get-SyntaxSubtree ([string]$coreIndex.Closures['compile_expr']) $coreIndex
    $compileCalls = Get-FunctionCalls $compileIds $coreIndex $bindingLookup
    if ($compileCalls.Contains('emit_win64_peb_address')) {
        [void]$nativeRuntimeBindings.Add('ifree_peb_address')
    }
}
foreach ($edge in $dependencyEdges) {
    if (!$catalog.ContainsKey([string]$edge.callee) -and
        !$coreIndex.Closures.ContainsKey([string]$edge.callee) -and
        !$nativeRuntimeBindings.Contains([string]$edge.callee)) {
        [void]$unresolvedCallees.Add([string]$edge.callee)
    }
}
if ($unresolvedCallees.Count -gt 0 -and !$AllowUnresolved) {
    throw ('Unresolved transitive callees; refusing to emit an integration candidate: ' + (($unresolvedCallees | Sort-Object) -join ', '))
}

$removeIds = [Collections.Generic.HashSet[string]]::new()
foreach ($binding in $replace) {
    if ($coreIndex.Closures.ContainsKey($binding)) {
        $subtree = Get-SyntaxSubtree ([string]$coreIndex.Closures[$binding]) $coreIndex
        foreach ($id in $subtree) { [void]$removeIds.Add($id) }
    }
}

$outputNodes = [Collections.Generic.List[string]]::new()
$outputRelations = [Collections.Generic.List[string]]::new()
$usedIds = [Collections.Generic.HashSet[int]]::new()
$maxId = 0
$nextFreeId = 1
$maxRootOrdinal = -1
function Order-SymbolFields([object]$Fields) {
    # The native reader scans identifier fields in transport order. Preserve
    # all field values while putting kind before name, including retained core
    # nodes. Otherwise a semantically lossless merge can produce a compiler
    # that dereferences a null callee name during its next self-build.
    if (!$Fields -or !$Fields.PSObject.Properties['kind']) { return $Fields }
    $orderedFields = [ordered]@{ kind=$Fields.kind }
    foreach ($property in $Fields.PSObject.Properties) {
        if ($property.Name -ne 'kind') { $orderedFields[$property.Name]=$property.Value }
    }
    return [pscustomobject]$orderedFields
}
foreach ($node in $core.Nodes) {
    if ($removeIds.Contains([string]$node.id)) { continue }
    [void]$usedIds.Add([int]$node.id)
    $maxId = [Math]::Max($maxId, [int]$node.id)
    if ($node.structural_kind -eq 'SymbolRef') {
        $node.fields = Order-SymbolFields $node.fields
    }
    $outputNodes.Add(($node | ConvertTo-Json -Depth 100 -Compress))
}
# Appending after the real graph maximum is the safe default.  The old
# lowest-hole allocator can reuse IDs from historical deletion holes that are
# still meaningful to native dispatch tables; it is retained only for an
# explicit compatibility request.
if ($AllocateAfterMax -or !$KeepLowIds) { $nextFreeId = $maxId + 1 }
foreach ($relation in $core.Relations) {
    $fromRemoved = $removeIds.Contains([string]$relation.from)
    $toRemoved = $relation.to.domain -eq 'node' -and $removeIds.Contains([string]$relation.to.id)
    if ($fromRemoved -or $toRemoved) { continue }
    if ($relation.kind -eq 'syntax.child' -and [string]$relation.from -eq '0' -and $null -ne $relation.attributes.ordinal) {
        $maxRootOrdinal = [Math]::Max($maxRootOrdinal, [int]$relation.attributes.ordinal)
    }
    $outputRelations.Add(($relation | ConvertTo-Json -Depth 100 -Compress))
}

$imported = [Collections.Generic.List[object]]::new()
foreach ($binding in @($selected | Sort-Object)) {
    if (!$catalog.ContainsKey($binding)) { continue }
    if ($coreIndex.Closures.ContainsKey($binding) -and !$replace.Contains($binding)) { continue }
    $candidate = $catalog[$binding]
    $map = @{}
    $calleeIds = [Collections.Generic.HashSet[string]]::new()
    foreach ($oldId in $candidate.Nodes) {
        $oldNode = $candidate.Index.NodeById[$oldId]
        if ($oldNode.structural_kind -ne 'CallExpr' -or !$candidate.Index.ChildEdges.ContainsKey($oldId)) { continue }
        foreach ($edge in @($candidate.Index.ChildEdges[$oldId] | Sort-Object Ordinal)) {
            if ($edge.Role -notin @('callee','function','target','value')) { continue }
            $child = $candidate.Index.NodeById[$edge.Id]
            if ($null -ne $child -and $child.structural_kind -eq 'SymbolRef') { [void]$calleeIds.Add($edge.Id); break }
        }
    }
    foreach ($oldId in @($candidate.Nodes | Sort-Object {[int]$_})) {
        # In the default mode, append after the existing graph.  Only the
        # explicit -KeepLowIds compatibility mode fills historical holes.
        # Every relation is still rewritten through the explicit remap.
        while ($usedIds.Contains($nextFreeId)) { $nextFreeId++ }
        $map[$oldId] = $nextFreeId
        [void]$usedIds.Add($nextFreeId)
        $nextFreeId++
    }
    foreach ($oldId in @($candidate.Nodes | Sort-Object {[int]$_})) {
        $node = $candidate.Index.NodeById[$oldId]
        $fields = Rewrite-NodeReferences (($node.fields | ConvertTo-Json -Depth 100 -Compress)) $map
        if ($calleeIds.Contains($oldId) -and $node.structural_kind -eq 'SymbolRef') {
            $calleeName = [string]$node.fields.name
            if ($calleeName.StartsWith('native_var_')) {
                $unwrapped = $calleeName.Substring('native_var_'.Length)
                if ($bindingLookup.ContainsKey($unwrapped)) {
                    $fieldsObject = $fields | ConvertFrom-Json
                    $fieldsObject.name = [string]$bindingLookup[$unwrapped]
                    $fields = $fieldsObject | ConvertTo-Json -Depth 100 -Compress
                }
            } elseif ($bindingLookup.ContainsKey($calleeName)) {
                $fieldsObject = $fields | ConvertFrom-Json
                $fieldsObject.name = [string]$bindingLookup[$calleeName]
                $fields = $fieldsObject | ConvertTo-Json -Depth 100 -Compress
            }
        }
        if ($oldId -eq $candidate.Root -and $node.structural_kind -eq 'ClosureExpr') {
            # The import binding is established by the exact root selection
            # (which, for Go-derived units, came from the named assignment
            # edge); carry it into SWC's explicit ClosureExpr ABI so later
            # compiler passes can dispatch to the imported implementation.
            $fieldsObject = $fields | ConvertFrom-Json
            if ($null -eq $fieldsObject.operation) {
                $fieldsObject | Add-Member -NotePropertyName operation -NotePropertyValue ([pscustomobject]@{})
            }
            $fieldsObject.operation | Add-Member -NotePropertyName function_binding -NotePropertyValue $binding -Force
            $fields = $fieldsObject | ConvertTo-Json -Depth 100 -Compress
        }
        # Imported closures and control nodes also need their discriminator
        # before body/branches/operands in the current native reader. Unlike
        # the retained core, imported units all use this canonical ordering.
        $fields = (Order-SymbolFields ($fields | ConvertFrom-Json)) | ConvertTo-Json -Depth 100 -Compress
        $outputNodes.Add('{"id":' + $map[$oldId] + ',"structural_kind":' + ([string]$node.structural_kind | ConvertTo-Json -Compress) + ',"fields":' + $fields + '}')
    }
    $relationCount = 0
    foreach ($relation in $candidate.Graph.Relations) {
        $from = [string]$relation.from
        $toIsNode = $relation.to.domain -eq 'node'
        $to = if ($toIsNode) { [string]$relation.to.id } else { '' }
        if (!$map.ContainsKey($from) -or ($toIsNode -and !$map.ContainsKey($to))) { continue }
        $json = $relation | ConvertTo-Json -Depth 100 -Compress
        $json = Rewrite-NodeReferences $json $map
        $json = [regex]::Replace($json, '"from":' + [regex]::Escape($from) + '(?=,)', '"from":' + $map[$from], 1)
        $outputRelations.Add($json)
        $relationCount++
    }
    $maxRootOrdinal++
    $rootRelation = [ordered]@{
        kind='syntax.child'; from=0
        to=[ordered]@{domain='node';id=[string]$map[$candidate.Root]}
        attributes=[ordered]@{role='statement';ordinal=$maxRootOrdinal}
    }
    $outputRelations.Add(($rootRelation | ConvertTo-Json -Depth 20 -Compress))
    $imported.Add([pscustomobject]@{
        binding=$binding; source=$candidate.Path; source_root=[int]$candidate.Root
        target_root=[int]$map[$candidate.Root]; nodes=$candidate.Nodes.Count
        relations=$relationCount; replaced=$replace.Contains($binding)
    })
}

$builder = [Text.StringBuilder]::new()
[void]$builder.AppendLine('# Semantic Programming Language')
[void]$builder.AppendLine('se 1')
[void]$builder.AppendLine('program {')
[void]$builder.AppendLine('schema=1')
[void]$builder.AppendLine('projection="semantic_document.v1"')
[void]$builder.AppendLine('origin={"source_language":"semantic","modules":["swc","legacy-transpiler-import"],"entry_point":"main"}')
[void]$builder.AppendLine('evaluation="eager_left_to_right"')
[void]$builder.AppendLine('index_base=0')
[void]$builder.AppendLine('value_model="explicit"')
[void]$builder.AppendLine('nodes=[')
[void]$builder.AppendLine(($outputNodes -join ",`n"))
[void]$builder.AppendLine(']')
[void]$builder.AppendLine('relations=[')
[void]$builder.AppendLine(($outputRelations -join ",`n"))
[void]$builder.AppendLine(']')
[void]$builder.AppendLine('metadata={"swc.import":"semantic-function-closure.v1","relation_policy":"all_internal_relations_preserved"}')
[void]$builder.AppendLine('}')

$resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
$outputParent = Split-Path -Parent $resolvedOutput
if ($outputParent) { New-Item -ItemType Directory -Force -Path $outputParent | Out-Null }
[IO.File]::WriteAllText($resolvedOutput, $builder.ToString(), [Text.UTF8Encoding]::new($false))

if (!$ReportPath) { $ReportPath = [IO.Path]::ChangeExtension($resolvedOutput, '.import-report.json') }
$report = [ordered]@{
    schema='swc.semantic-function-import.v1'; core=(Resolve-Path $CorePath).Path
    output=$resolvedOutput; source_units=$sources.Count; catalog_bindings=$catalog.Count
    selected_bindings=@($selected | Sort-Object); missing_bindings=@($missing | Sort-Object)
    unresolved_callees=@($unresolvedCallees | Sort-Object)
    replaced_bindings=@($replace | Sort-Object); imported=$imported
    dependency_edges=$dependencyEdges; native_runtime_bindings=@($nativeRuntimeBindings | Sort-Object)
    output_nodes=$outputNodes.Count
    output_relations=$outputRelations.Count
}
$reportParent = Split-Path -Parent $ReportPath
if ($reportParent) { New-Item -ItemType Directory -Force -Path $reportParent | Out-Null }
$report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ReportPath -Encoding UTF8

"CATALOG_BINDINGS=$($catalog.Count)"
"SELECTED_BINDINGS=$($selected.Count)"
"IMPORTED_BINDINGS=$($imported.Count)"
"REPLACED_BINDINGS=$($replace.Count)"
"MISSING_BINDINGS=$($missing.Count)"
"UNRESOLVED_CALLEES=$($unresolvedCallees.Count)"
"OUTPUT_NODES=$($outputNodes.Count)"
"OUTPUT_RELATIONS=$($outputRelations.Count)"
"OUTPUT=$resolvedOutput"
"REPORT=$([IO.Path]::GetFullPath($ReportPath))"
