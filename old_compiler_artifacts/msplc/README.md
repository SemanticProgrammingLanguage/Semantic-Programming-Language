# MSPLC v2.2.0

**MSPLC** is the Minimal Semantic Programming Language Compiler.

MSPLC v2.2.0 is a minimal self-hosted Linux x86-64 compiler for normal Semantic UAST `.se` programs. Its compiler implementation is `src/msplc-selfhost.se` and uses ordinary UAST nodes and `syntax.child` relations.

CLI:

```bash
./msplc help
./msplc version
./msplc compile input.se -o output
./msplc compile msplc.smod -o msplc-next
```

Self-host verification:

```bash
chmod +x msplc verify-selfhost.sh
./verify-selfhost.sh
```

The Module Store package contains no Python/Go/C bootstrap compiler, no `field.i...` microcode records, and no precompiled function-fragment payloads in the Semantic source. Target: static ELF64 x86-64 Linux.
