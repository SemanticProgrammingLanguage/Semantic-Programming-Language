# SWC Universal Sparse Matrix

Reproducible matrix package for the current SWC compiler. It contains the
canonical 82-kind / 23-relation inventory, primitive contracts, ordered
lowering recipes, Semantic guard units, and native evidence reports. It is
not a second compiler and it does not silently claim native support.

The evidence report currently records 7 `NATIVE_PROVEN`, 2 `LOWERABLE`, 11
`DIRECT`, 61 `UNSUPPORTED`, and 1 `CONFLICT`. The conflict is
`SwitchMatchStmt`, whose legacy switch reservation lacks a dedicated
contract. Native evidence covers the tested aggregate/index and tuple/index
profiles, including nested tuples and single-evaluation effect ordering.

Directories: `matrices/`, `recipes/`, `semantic/`, `reports/`, and `tools/`.

Validate from the repository root:

```powershell
python integration/swc-universal-sparse-matrix/tools/matrix_bulk_import.py --root integration/swc-universal-sparse-matrix --strict
```

The validator checks catalog counts, dependencies, recipe structure, and
fixpoint inputs. Native claims require executable evidence and remain in the
reports. The checked-in Windows executable is 161,280 bytes (SHA256
`CC213E4BFCB5F8E6FFAB2F6C2279BB7D91F4902FF41FAC16B6008B2EF2476BD5`), built
from the current self-host source. `mem_store64` arity rejection is not yet
proven: zero through three arguments were accepted by the negative fixtures,
so this behavior remains outside `NATIVE_PROVEN`.
