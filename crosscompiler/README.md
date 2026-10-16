# SWC crosscompiler sources and Windows compiler status

Current Windows update: **2026-10-16**. The active Windows compiler is
self-hosted and no longer has static DLL/CRT imports.

- `bin/swc.exe`: **228,352 bytes**, SHA256
  `D2148E6C8B4EEB829B4F956AECD95F967E98DD2C4424C942211FE8082BD1D4F5`.
- `source/windows/se/swc-selfhost-windows.se`: **7,278,749 bytes**, SHA256
  `AF18A2A4DF71AD90E9F0BEB5A74E5C290AC63EF436379B2132DDA6605AFDDD45`.
- `manifests/swc.smod`: the active, manifest-relative build entry.
- Stage1/Stage2/Stage3 are byte-identical; 38 native regression checks pass.
- `.text` virtual size: 227,759 bytes. No appended source or executable payload.

Import, bound-import, IAT and delay-import directories are zero. Windows APIs
are resolved dynamically through the PEB: Windows itself remains required.
No Go runtime, external helper executable, LLVM or external linker is needed
to run or selfhost this Windows compiler.

## Build and validate

From the repository root, using PowerShell 7:

```powershell
./crosscompiler/bin/swc.exe compile ./crosscompiler/manifests/swc.smod -o ./swc-rebuilt.exe --embed-all
./scripts/test-importfree-candidate.ps1 -Compiler ./crosscompiler/bin/swc.exe -FixtureDirectory ./crosscompiler/source/windows/se -OutputDirectory ./tmp/release-validation
```

From `crosscompiler/`, the equivalent selfhost command is:

```powershell
./bin/swc.exe compile ./manifests/swc.smod -o ./swc-rebuilt.exe --embed-all
```

Forward slashes and Windows backslashes are supported for the manifest path.
SMOD compilation without the optional flag no longer dereferences a missing
argument. The redundant second SMOD compilation has been removed. Filenames
with spaces and drive-absolute unit paths are covered by native tests.

## Tested coverage and boundaries

The regression suite checks actual native execution: return42, argc/argv,
redirected output, exact file write/read, tuple construction and nested indexing,
flat binding-pattern swaps and single evaluation, foreach sum/break/continue,
and the supported slice identity/index contract. Four invalid fixtures fail
closed with exit 3 and no executable, including memory-intrinsic arity.
This does not prove every arity variant or every catalogued UAST construct.

See [the current release evidence](docs/RELEASE-2026-10-16.md).
Older dated reports are historical evidence, not the current status.

## Existing layout

- `source/windows/se/`: active Windows graph and native regression fixtures.
- `source/shared/se/units/`: individual Semantic implementation units.
- `source/shared/se/transpiler-matrix/`: unchanged matrix sources.
- `source/shared/modules/`: shared library/module manifests.
- `source/linux/`, `source/mac/`: preserved platform sources.
- `manifests/`: active and historical compiler manifests.
- `docs/`: release evidence, audits and historical results.

The active SMOD selects the complete validated Windows graph. Shared units can
be ahead of that graph; their mere presence is not proof they are executed.
The transpiler CLI is not claimed as completed by this update. Separate
`.rdata`/`.data` emission and full UAST coverage are not claimed either.

Linux, macOS and the separate cross-target binaries are preserved. They were
not rebuilt or revalidated by this Windows release. Existing LFS rules remain
in place; no unrelated repository files are removed.
