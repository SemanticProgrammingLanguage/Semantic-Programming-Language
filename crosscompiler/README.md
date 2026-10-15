# SWC crosscompiler sources and Windows compiler status

Current Windows update: 2026-10-15. `bin/swc.exe` now contains the larger
validated self-host candidate; superseded Windows-native candidates are
preserved under the repository's existing `old_compiler_artifacts/SWC/` tree.

- Active `bin/swc.exe`: 161,280 bytes, SHA256
  `CC213E4BFCB5F8E6FFAB2F6C2279BB7D91F4902FF41FAC16B6008B2EF2476BD5`.
- Current source: `source/windows/se/swc-selfhost-windows.se`, 5,721,230 bytes,
  SHA256 `64CEDDE1265ABD44F427E0B459A61AFE7834069AFAF17791E8951F14B089CFBC`.
- Build entry: `manifests/swc.smod`; it points to that exact source hash and
  uses paths relative to the `crosscompiler` working directory.
- Latest local self-host candidate: 161,280 bytes, SHA256
  `CC213E4BFCB5F8E6FFAB2F6C2279BB7D91F4902FF41FAC16B6008B2EF2476BD5`.
  Stage2 and Stage3 were reported byte-identical; this candidate is now the
  active checked-in Windows executable.

The `mem_store64` fail-closed arity check is still unproven: calls with zero,
one, two, and three arguments were accepted with exit code 0. The arity fixture
is a regression probe, not evidence of a passing rejection path.

Only the current `swc.legacy.primitives.smod` remains under
`source/shared/modules/`; it records nine shared Semantic source units and
does not claim that those units are embedded or active in
`swc.exe`. Older module manifests are kept under
`old_compiler_artifacts/SWC/modules/`. Historical aggregate manifests retain
their references to that archive and are not the active `manifests/swc.smod`
build entry.

Build from the `crosscompiler` directory on Windows:

```powershell
./bin/swc.exe compile ./manifests/swc.smod -o ./swc-rebuilt.exe --embed-all
./bin/swc.exe compile ./source/windows/se/return42.se -o ./return42.exe
.\return42.exe
# Expected process exit: 42
```

Use forward slashes for the SMOD input path: the current native manifest
resolver searches for `/` when resolving manifest-relative source paths.

The validated Windows graph supports the tested flat tuple destructuring,
ordered single evaluation, boolean-not, integer negation/complement, numeric
node-relation IDs, and ReturnStmt operands using `expression` or `value`.
This is not a claim that every catalogued UAST kind is executable.

## Existing source layout

- `source/windows/se/`: Windows compiler graph and native SE regression fixtures.
- `source/shared/se/units/`: individual Semantic implementation units.
- `source/shared/se/transpiler-matrix/`: matrix source and existing matrix material.
- `source/shared/modules/`: existing shared module manifests.
- `source/linux/` and `source/mac/`: existing platform sources.
- `manifests/`: compiler build and cross-validation manifests.
- `docs/`: validation evidence and implementation status.

Shared units can be ahead of the activated compiler graph. The newer foreach,
member/index and slice experiments are source material, not validated release
features. The active manifest intentionally selects the validated graph rather
than importing every experimental unit. See `docs/RELEASE-2026-10-13.md` for the
current update and limitations; that existing filename is retained.

The Linux, macOS and Windows-to-ELF executables are retained from their existing
releases. They were not rebuilt or revalidated by this Windows update.

No Go host wrapper, appended Semantic-source payload, LLVM or external linker
is introduced by this update. Existing Git LFS rules are retained.
