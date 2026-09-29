# Semantic Windows Compiler (SWC)

SWC is a native Windows x64 compiler for Semantic source and Universal AST documents. This repository package contains the current compiler executable, its Semantic source, the integrated reader/lowering/transpiler work, tests, and development tools.

This package intentionally contains no legacy source corpus.

## Quick start

```powershell
.\swc.exe version
.\swc.exe help
.\swc.exe compile .\program.se -o .\program.exe --no-modules
```

Accepted input extensions are `.se`, `.sp`, `.spz`, `.json`, and `.smod`.

## CLI

### Version

```powershell
.\swc.exe version
```

Current version: `swc 2.3.2 windows-x64`.

### Help

```powershell
.\swc.exe help
```

### Compile

```powershell
.\swc.exe compile <input> -o <output.exe> [--embed-all|--embed-needed|--no-modules]
```

Module modes accepted by the compiler:

- `--embed-all`: request complete embedding of resolved modules.
- `--embed-needed`: request embedding of referenced module parts.
- `--no-modules`: compile without module embedding.

Module resolution and embedding are still under active implementation. Use `--no-modules` for the currently verified self-hosting path.

The commands `transpile`, `show-modules`, `list-modules`, `setpath`, and `setmodulestore` are represented in the source architecture but are not yet exposed as completed production CLI commands.

## Package layout

```text
SWC/
|-- swc.exe
|-- swc.smod
|-- README.md
|-- LICENSE
|-- icon.ico
|-- icon.png
|-- src/
|   |-- swc-selfhost-windows.se
|   |-- transpiler-matrix/
|   `-- units/
|-- tests/
`-- tools/
```

- `swc.exe` is the current native Windows compiler.
- `swc.smod` is the SWC Semantic module package.
- `src/swc-selfhost-windows.se` is the canonical self-hosting compiler source.
- `src/transpiler-matrix` contains the current matrix-driven transpiler data.
- `src/units` contains the small Semantic reader, routing, lowering, module, and UAST units.
- `tests` contains Semantic compiler fixtures.
- `tools` contains development and verification utilities.

## Self-hosting check

From the package root:

```powershell
.\swc.exe compile .\src\swc-selfhost-windows.se -o .\stage2.exe --no-modules
.\stage2.exe compile .\src\swc-selfhost-windows.se -o .\stage3.exe --no-modules
Get-FileHash .\stage2.exe -Algorithm SHA256
Get-FileHash .\stage3.exe -Algorithm SHA256
```

The current production artifact previously passed Stage 2 and Stage 3 with exit code `0`, and both generated executables were byte-identical. Delete the generated proof executables after verification:

```powershell
Remove-Item -LiteralPath .\stage2.exe, .\stage3.exe
```

## Current scope

The package includes the current rich Semantic reader, UAST routing/lowering units, matrix data, module contracts, and native PE emission work. A fully exposed matrix-driven `transpile` CLI and complete module-store workflow remain development targets and are not claimed as finished here.

## License

See [LICENSE](LICENSE).
