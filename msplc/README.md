# MSPLC

**MSPLC — Minimal Semantic Programming Language Compiler** is a small self-hosted compiler written as Semantic `.se` units. It accepts canonical `semantic_document.v1` UAST envelopes, validates the required graph sections fail-closed, and lowers the supported subset to the `selfhost.x64.fixed-slot.v1` Linux x86-64 ELF backend.

The package contains explicit UAST frontend and lowering contracts in `src/048_uast_frontend.se` and `src/049_uast_lowering.se`. The current executable remains deliberately finite: the fixed-slot backend is the proven Linux selfhost core, while broader UAST lowering is added behind these contracts without silently falling back to non-semantic stubs.

## CLI

```text
msplc compile <input.se> [more.se ...] -o <output>
msplc help
msplc version
```

Windows: run `msplc.cmd` (uses WSL for the Linux x86-64 self-hosted core).

Module manifest: `msplc.smod`  
Module icon: `icon.png`
