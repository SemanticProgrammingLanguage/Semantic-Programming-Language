# SWC crosscompiler sources and Windows compiler status

Current Windows update: 2026-10-15. The checked-in binaries remain the
previously published native Windows compiler; the source and manifest now
track a newer self-host candidate.

- Published `bin/swc.exe`: 146,432 bytes, SHA256
  `39DAE62B08BDB1362C05BEF46C9315D121255E074C78ABDE883E8CF410AB4DD9`.
- Current source: `source/windows/se/swc-selfhost-windows.se`, 5,721,230 bytes,
  SHA256 `64CEDDE1265ABD44F427E0B459A61AFE7834069AFAF17791E8951F14B089CFBC`.
- Build entry: `manifests/swc.smod`; it points to that exact source hash and
  uses paths relative to the manifest.
- Latest local self-host candidate: 161,280 bytes, SHA256
  `CC213E4BFCB5F8E6FFAB2F6C2279BB7D91F4902FF41FAC16B6008B2EF2476BD5`.
  Stage2 and Stage3 were reported byte-identical. This candidate was not copied
  over the checked-in executable in this source/docs update.

The `mem_store64` fail-closed arity check is still unproven: calls with zero,
one, two, and three arguments were accepted with exit code 0. The arity fixture
is a regression probe, not evidence of a passing rejection path.

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
