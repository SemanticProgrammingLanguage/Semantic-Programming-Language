param([Parameter(Mandatory)][string]$SourcePath,[Parameter(Mandatory)][string]$ExecutablePath,[Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference='Stop'
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'import-semantic-function-closure.ps1'),[ref]$null,[ref]$null)
$reader=$ast.Find({param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Read-SemanticGraph'},$false)
. ([scriptblock]::Create($reader.Extent.Text))
$g=Read-SemanticGraph $SourcePath
$functions=@($g.Nodes|Where-Object structural_kind -eq ClosureExpr|Sort-Object {[int]$_.id})
$bytes=[IO.File]::ReadAllBytes((Resolve-Path $ExecutablePath))
$pe=[BitConverter]::ToInt32($bytes,60)
$section=$pe+24+[BitConverter]::ToUInt16($bytes,$pe+20)
if([Text.Encoding]::ASCII.GetString($bytes,$section,5) -ne '.text'){throw 'Expected native SWC .text section'}
$raw=[BitConverter]::ToUInt32($bytes,$section+20)
$end=$raw+[BitConverter]::ToUInt32($bytes,$section+8)
$signature=[byte[]]@(85,72,137,229,72,129,236)
$offsets=[Collections.Generic.List[int]]::new()
for($i=[int]$raw;$i -lt $end-7;$i++){
 $match=$true;for($j=0;$j -lt 7;$j++){if($bytes[$i+$j] -ne $signature[$j]){$match=$false;break}}
 if($match){$offsets.Add($i)}
}
if($offsets.Count -ne $functions.Count){throw "Function boundary mismatch: $($functions.Count) source closures, $($offsets.Count) native prologues"}
if($functions[0].fields.operation.function_binding -ne 'main'){throw 'Expected unused fixture main before the runtime functions'}
$start=$offsets[1];$code=$bytes[$start..($end-1)]
$exports=@{};for($i=1;$i -lt $functions.Count;$i++){$exports[[string]$functions[$i].fields.operation.function_binding]=$offsets[$i]-$start}
$runtimeNames=@('ifree_sys_mmap','ifree_sys_open','ifree_sys_read','ifree_sys_write','ifree_sys_close','ifree_startup','ifree_exit')
foreach($name in $runtimeNames){if(!$exports.ContainsKey($name)){throw "Missing runtime entry $name"}}
$n=@{};$r=[Collections.Generic.List[object]]::new();$added=[Collections.Generic.List[object]]::new();$next=0
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'patch-slice-native-execution.ps1'),[ref]$null,[ref]$null)
foreach($f in $ast.FindAll({param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
function S($body,$stmt){Edge $body $stmt statement (@(Edges $body statement).Count)}
function Decode($body,$name){
 $test=Node IfStmt ([ordered]@{kind='if'});$yes=Node Scope ([ordered]@{kind='block'});$no=Node Scope ([ordered]@{kind='block'})
 Edge $test (Op greater_than (Ref $name) (Lit 96)) condition 0;Edge $test $yes then 0;Edge $test $no else 0
 S $yes (Assign $name (Op subtract (Ref $name) (Lit 87)));S $no (Assign $name (Op subtract (Ref $name) (Lit 48)));S $body $test
}
$root=Node Scope ([ordered]@{kind='block'})
$fn=Node ClosureExpr ([ordered]@{kind='function';name='emit_ifree_runtime_template';operation=[ordered]@{function_binding='emit_ifree_runtime_template'}})
$param=Node ParameterDecl ([ordered]@{kind='parameter';name='c'});$body=Node Scope ([ordered]@{kind='block'})
Edge $root $fn statement 0;Edge $fn $param parameter 0;Edge $fn $body body 0
S $body (Assign runtime_base (Call ctx_get @((Ref c),(Lit 48))))
S $body (Assign runtime_labels (Call ctx_get @((Ref c),(Lit 72))))
S $body (Assign runtime_label_base (Op add (Lit 4096) (Op multiply (Lit 11) (Op add (Call ctx_get @((Ref c),(Lit 96))) (Lit 1)))))
for($i=0;$i -lt $runtimeNames.Count;$i++){
 $address=Op add (Ref runtime_labels) (Op multiply (Op add (Ref runtime_label_base) (Lit $i)) (Lit 8))
 $value=Op add (Ref runtime_base) (Lit (1+$exports[$runtimeNames[$i]]))
 S $body (Expr (Call store64 @($address,$value)))
}
$hex=[BitConverter]::ToString($code).Replace('-','').ToLowerInvariant()
$literal=Node LiteralExpr ([ordered]@{kind='literal';operation=[ordered]@{literal_kind='string';text=$hex}})
S $body (Assign runtime_hex $literal);S $body (Assign runtime_index (Lit 0))
$loop=Node LoopStmt ([ordered]@{kind='while'});$loopBody=Node Scope ([ordered]@{kind='block'})
Edge $loop (Op less_than (Ref runtime_index) (Lit $code.Length)) condition 0;Edge $loop $loopBody body 0
S $loopBody (Assign runtime_high (Call load8 @((Op add (Ref runtime_hex) (Op multiply (Ref runtime_index) (Lit 2))))))
S $loopBody (Assign runtime_low (Call load8 @((Op add (Ref runtime_hex) (Op add (Op multiply (Ref runtime_index) (Lit 2)) (Lit 1))))))
Decode $loopBody runtime_high;Decode $loopBody runtime_low
S $loopBody (Expr (Call emit8 @((Ref c),(Op add (Op multiply (Ref runtime_high) (Lit 16)) (Ref runtime_low)))))
S $loopBody (Assign runtime_index (Op add (Ref runtime_index) (Lit 1)));S $body $loop;S $body (Ret (Lit 0))
$nodeLines=(@($added)|ForEach-Object{$_|ConvertTo-Json -Compress -Depth 100}) -join ",`n"
$relLines=(@($r)|ForEach-Object{$_|ConvertTo-Json -Compress -Depth 100}) -join ",`n"
$meta=[ordered]@{source='Go to canonical SE to native SWC';native_template_bytes=$code.Length;native_entries=$exports;source_sha256=(Get-FileHash $SourcePath).Hash;executable_sha256=(Get-FileHash $ExecutablePath).Hash}
$metadata=$meta|ConvertTo-Json -Compress -Depth 20
$text="# Semantic Programming Language`nse 1`nprogram {`nschema=1`nprojection=`"semantic_document.v1`"`norigin={`"source_language`":`"semantic`",`"modules`":[]}`nevaluation=`"eager_left_to_right`"`nindex_base=0`nvalue_model=`"explicit`"`nnodes=[`n$nodeLines`n]`nrelations=[`n$relLines`n]`nmetadata=$metadata`n}`n"
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),$text,[Text.UTF8Encoding]::new($false))
"OUTPUT=$OutputPath TEMPLATE_BYTES=$($code.Length) VERIFIED_FUNCTION_BOUNDARIES=$($functions.Count)"
