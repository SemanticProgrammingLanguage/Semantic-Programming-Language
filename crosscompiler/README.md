# SWC crosscompiler sources and validated Windows compiler

Current Windows update: 2026-10-15. `bin/swc.exe` and
`bin/swc-windows-selfhost.exe` contain the validated native Windows compiler.

- Compiler: 146,432 bytes, SHA256
  `39DAE62B08BDB1362C05BEF46C9315D121255E074C78ABDE883E8CF410AB4DD9`.
- Matching source: `source/windows/se/swc-selfhost-windows.se`, SHA256
  `1F8C8A04E000D653BCB0A60DA6DBA9673689529CFF7234C4FBB6EC573D8FE74B`.
- Build entry: `manifests/swc.smod`; its paths are relative to the manifest.
- Stage2, Stage3 and the native SMOD Embed-All build produce identical bytes.

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
