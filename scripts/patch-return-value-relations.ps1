[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$InputPath,[Parameter(Mandatory=$true)][string]$OutputPath)
$ErrorActionPreference='Stop'
# Normalize the two existing ReturnStmt operand roles at the Semantic graph
# boundary. Preserve all IDs and other relations; reject ambiguous operands.
$lines=[IO.File]::ReadAllLines((Resolve-Path -LiteralPath $InputPath).Path)
$nodes=@{};$relations=[Collections.Generic.List[object]]::new();$section=''
for($i=0;$i -lt $lines.Count;$i++){
 $s=$lines[$i].Trim().TrimEnd(',')
 if($s -eq 'nodes=['){$section='n';continue};if($s -eq 'relations=['){$section='r';continue};if($s -eq ']'){$section='';continue}
 if(!$s.StartsWith('{')){continue}
 $o=$s|ConvertFrom-Json
 if($section -eq 'n'){$nodes[[int]$o.id]=$o}
 elseif($section -eq 'r'){$relations.Add([pscustomobject]@{line=$i;relation=$o})}
}
$changed=0
foreach($row in $relations){
 $r=$row.relation
 if($r.kind -ne 'syntax.child' -or $r.to.domain -ne 'node' -or $r.attributes.role -ne 'value'){continue}
 if($nodes[[int]$r.from].structural_kind -ne 'ReturnStmt'){continue}
 $other=@($relations|Where-Object {$_.relation.kind -eq 'syntax.child' -and [int]$_.relation.from -eq [int]$r.from -and $_.relation.attributes.role -in @('value','expression')})
 if($other.Count -ne 1 -or [int]$r.attributes.ordinal -ne 0){throw "Ambiguous return operand at node $($r.from)"}
 $r.attributes.role='expression';$suffix=if($lines[$row.line].TrimEnd().EndsWith(',')){','}else{''}
 $lines[$row.line]=($r|ConvertTo-Json -Compress -Depth 80)+$suffix;$changed++
}
$dest=[IO.Path]::GetFullPath($OutputPath);[IO.Directory]::CreateDirectory((Split-Path -Parent $dest))|Out-Null
[IO.File]::WriteAllLines($dest,$lines,[Text.UTF8Encoding]::new($false))
"RETURN_VALUE_RELATIONS_NORMALIZED=$changed OUTPUT=$dest"
