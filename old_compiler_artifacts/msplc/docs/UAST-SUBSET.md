# MSPLC UAST subset

Executable Semantic node kinds used by the minimal compiler:

- `function`
- `parameter`
- `block` / `Scope`
- `assign`
- `literal`
- `identifier` / `SymbolRef`
- `binary` / `OperationExpr`
- `call`
- `return`
- `if`
- `while`
- expression statements

Integer operations include add, subtract, multiply, comparisons, bit-and, bit-or, bit-xor, left shift and right shift.

Low-level target/runtime operations are represented as ordinary calls and are lowered by the native Linux backend: `address_of`, `mem_load8`, `mem_load64`, `mem_store8`, `mem_store64`, `sys_read`, `sys_write`, `sys_open`, `sys_close`, and `sys_mmap`.

The readable self-host source uses one UAST node or relation JSON object per line. This keeps the bootstrap parser deliberately small while preserving ordinary UAST nodes and relations as the semantic program representation.
