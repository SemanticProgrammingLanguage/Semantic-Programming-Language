# MWSPLC Windows UAST subset

The minimal compiler consumes ordinary Semantic UAST nodes and `syntax.child` relations.

Supported executable core:
- Function / Parameter / Scope
- Assign
- Literal / SymbolRef
- OperationExpr
- Call / Return
- If / While

Target runtime primitives are lowered only in the backend:
- address_of
- mem_load8 / mem_load64
- mem_store8 / mem_store64
- sys_open / sys_read / sys_write / sys_close
- sys_mmap (Windows lowering: zeroed allocation via calloc)

The Windows target is PE32+ x86-64. Internal compiler calls use MWSPLC's compact internal ABI; imported CRT calls use the Win64 ABI.
