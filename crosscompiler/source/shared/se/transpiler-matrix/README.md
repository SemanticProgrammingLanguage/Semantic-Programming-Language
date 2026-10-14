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
reports. The active compiler baseline is 132608 bytes with SHA256
`8423BF8A1A3A98ECFDCAAB63A4556BE2A301EE4FD4A5CC7187FE1F239BE9DD22`.
