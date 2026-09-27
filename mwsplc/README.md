# MWSPLC v2.3.2

**Mini Windows Semantic Compiler** — native Windows x64 / PE32+ compiler for the minimal Semantic UAST subset.

This build fixes the Win64 `__getmainargs` stack-argument bug found in v2.3.1. The entry stub already owns a 0x80-byte frame whose first 0x20 bytes are Win64 shadow space; v2.3.1 incorrectly moved RSP again before the 5-argument CRT call, shifting `_startupinfo*` and causing `0xC0000005` in self-generated Stage-2.

The same fix is encoded in `src/mwsplc-selfhost-windows.se`, so self-generated compilers use the corrected entry emitter as well.

## Commands

    mwsplc.exe version
    mwsplc.exe help
    mwsplc.exe compile input.se -o output.exe
    mwsplc.exe compile mwsplc.smod -o mwsplc-next.exe

## Selfhost test

Run `verify-selfhost.cmd` on native Windows. A valid closure requires Stage-2 and Stage-3 to execute and reproduce byte-identically.

The package contains no `field.i...` / `selfhost.x64...` microcode records.
