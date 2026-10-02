# masplc v2.2.0 — WSA module

**masplc** is the Minimal Semantic Programming Language Compiler module.

masplc v2.2.0 is a minimal self-hosted Linux x86-64 compiler for normal Semantic UAST `.se` programs. Its compiler implementation is `src/msplc-selfhost.se` and uses ordinary UAST nodes and `syntax.child` relations.

CLI:

```bash
./masplc help
./masplc version
./masplc compile input.se -o output
./masplc compile masplc.smod -o masplc-next
```

Self-host verification:

```bash
chmod +x masplc verify-selfhost.sh
./verify-selfhost.sh

## Verified on Windows Subsystem for Android

The bundled static x86-64 ELF was tested on WSA through `adb` at
`127.0.0.1:58526`.

Verified sequence:

```text
masplc compile src/msplc-selfhost.se -o stage-next          PASS
stage-next compile src/msplc-selfhost.se -o stage-next2     PASS
SHA-256(masplc)       = 67da98512c4f204f95a1c05646f35af49277f2504e3a86075896bcc7296332f6
SHA-256(stage-next)   = 67da98512c4f204f95a1c05646f35af49277f2504e3a86075896bcc7296332f6
SHA-256(stage-next2)  = 67da98512c4f204f95a1c05646f35af49277f2504e3a86075896bcc7296332f6
SHA-256(from-smod)    = 67da98512c4f204f95a1c05646f35af49277f2504e3a86075896bcc7296332f6
```

The `masplc.smod` path was verified from the module directory itself; the manifest
is intentionally resolved relative to its package root.

The module contains the readable Semantic source, the `.smod` manifest,
tests, license, and the reproducible self-host proof. The WSA run used only
the bundled static ELF and the Semantic source; no Go, LLVM, or host compiler
was involved.
```

The Module Store package contains no Python/Go/C bootstrap compiler, no `field.i...` microcode records, and no precompiled function-fragment payloads in the Semantic source. Target: static ELF64 x86-64 Linux.
