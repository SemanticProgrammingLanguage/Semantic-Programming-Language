# MSPLC

**MSPLC — Minimal Semantic Programming Language Compiler** is a small self-hosted compiler written as Semantic `.se` units. It compiles the minimal `selfhost.x64.v2` Semantic subset directly to Linux x86-64 ELF.

## CLI

```text
msplc compile <input.se> [more.se ...] -o <output>
msplc help
msplc version
```

Windows: run `msplc.cmd` (uses WSL for the Linux x86-64 self-hosted core).

Module manifest: `msplc.smod`  
Module icon: `icon.png`
