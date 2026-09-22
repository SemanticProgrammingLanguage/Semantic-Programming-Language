<p align="center">
  <img width="640" alt="Semantic Programming Language Logo" src="https://github.com/user-attachments/assets/ec1d4462-c5b0-4aa0-841a-435bf0868b1d">
</p>

<h1 align="center"><a href="https://snapcraft.io/semantic-programming-language">
  <img alt="Get it from the Snap Store" src="https://snapcraft.io/en/dark/install.svg" />
</a></h1>
<h1 align="center">Semantic Programming Language</h1>

<p align="center">
  A universal, matrix-driven programming language and compiler architecture based on canonical Semantic/UAST representations.
</p>

# <p align="center"> https://www.semantic-programming-language.com/ </p>

# MSPLC 0.2 — minimal Semantic compiler bootstrap (Windows x64)


`msplc.exe` accepts Semantic `.se` input and attempts to compile it with the real repository path:

`ParseSemanticSE -> CompileMachine(x86_64/windows/win64) -> PE32+`

There is no filename/module whitelist. Unsupported input is still attempted and fails with the real parser/backend error.

## Built-in help

Run:

```bat
msplc.exe help
```

The help command explains all commands, the fixed Windows x64 target, examples, exit codes, validation, and selfhosting.

## CLI

```bat
msplc.exe input.se
msplc.exe input.se output.exe
msplc.exe compile input.se -o output.exe
msplc.exe check input.se
msplc.exe help
msplc.exe version
```

With no output argument, `foo.se` becomes `foo.exe`.

## Readable selfhost source

`msplc-selfhost.se` is now approximately 104 KB and entirely readable text. It contains **no appended JSON, base64, embedded EXE, compressed image, or binary seed block**.

It contains one readable comment marker:

`# msplc-selfhost-readable-v1`

The source is validated by the normal SE parser first. In this bootstrap fixed-point mode the currently running compiler reproduces its own executable:

```bat
msplc.exe msplc-selfhost.se stage2.exe
stage2.exe msplc-selfhost.se stage3.exe
fc /b msplc.exe stage2.exe
fc /b stage2.exe stage3.exe
```

Ordinary `.se` files never use this special mode; they go through `ParseSemanticSE -> CompileMachine`.

This is intentionally a bootstrap fixed point, not a claim that the whole Go implementation has already been re-expressed semantically inside `msplc-selfhost.se`.


# Download

[https://github.com/tarekwasfy01/Semantic-Programming-Language/releases/download/v1.0.0/Semantic.Programming.Language.zip](https://github.com/tarekwasfy01/Semantic-Programming-Language/releases/download/v1.4.0/codetranspiler.zip)

## Pre Transpiled Modules

https://github.com/SemanticProgrammingLanguage?tab=repositories

## Overview

Semantic Programming Language represents programs independently of their original source language.

Source code is lowered into a canonical `SemanticProgram` and Universal Abstract Syntax Tree (UAST). The same semantic representation can then be validated, transformed, executed, transpiled, or compiled into a native executable.

```text
Source code
    ↓
Frontend
    ↓
SemanticProgram / UAST
    ↓
Semantic transformations and contracts
    ↓
Native backend
    ↓
Executable
```

The reference implementation and bootstrap compiler are provided by the Go package [Code-Transpiler](https://github.com/tarekwasfy01/Code-Transpiler).

```text
Go module:  github.com/tarekwasfy01/Code-Transpiler
Go package: codetranspiler
GUI:        Semantic Programming Language.exe
CLI:        sp / CodeTranspiler
```

## GUI

Start the application without arguments:

```powershell
& ".\Semantic Programming Language.exe"
```

The GUI provides access to:

- source-code translation
- Semantic/UAST generation
- `.se` and Semantic JSON processing
- native compilation
- script execution
- language and target selection
- compiler capability information
- embedded bundle verification

## CLI

The commands `sp` and `CodeTranspiler` are equivalent:

```text
sp <command> [options]
CodeTranspiler <command> [options]
```

### Compile Semantic source

```powershell
sp compile input.se -o input.exe
sp compile input.sp -o input.exe
sp compile input.json -o input.exe
```

The longer executable name can be used identically:

```powershell
CodeTranspiler compile input.se -o input.exe
```

### Compile source code directly

```powershell
sp compile -source go -target native-x86_64-windows input.go -o program.exe
```

### Export Semantic source

```powershell
sp semantic-export -source go input.go -format se -o program.se
```

### Validate and inspect Semantic documents

```powershell
sp semantic-validate program.se
sp semantic-info program.se
sp semantic-format program.se --readable -o readable.se
sp semantic-format program.se --compact -o compact.se
```

### Transpile through Semantic/UAST

```powershell
sp transpile -from python -to go input.py -o output.go
sp transpile -from c -to rust input.c -o output.rs
sp semantic-transpile -target cpp program.se -o output.cpp
```
### Semantic Moduls

Experimental support for Semantic Modules. 
The Goal is to make packages from all implemented languages accesible by transpiling and decompiling packages from other languages.
Modules can be added to the public module store via the website and github actions: https://www.semantic-programming-language.com/modules.html

```powershell
CodeTranspiler.exe module import <source|module.se|module.spz>
CodeTranspiler.exe module import --language go <source.go>
CodeTranspiler.exe module list
CodeTranspiler.exe module info <cache-key>
CodeTranspiler.exe module verify <cache-key>
CodeTranspiler.exe module remove <cache-key>
CodeTranspiler.exe semantic module import <target>
CodeTranspiler.exe semantic module import --language go <target>
Manage Semantic Modules in %LOCALAPPDATA%\\Semantic\\Modules.
 ```

### Execute a program

```powershell
sp run -source python -target embedded input.py
sp run -from c -to go input.c
```

### Verify the embedded compiler bundles

```powershell
sp bundle-info
sp bundle-verify
sp bundle-extract extracted-bundles
```

### Display all commands

```powershell
sp help
CodeTranspiler help
```

## Go package

Install the reference compiler package:

```bash
go get github.com/tarekwasfy01/Code-Transpiler
```

Import it in Go:

```go
import codetranspiler "github.com/tarekwasfy01/Code-Transpiler"
```

The Go package provides the bootstrap frontend, canonical SemanticProgram/UAST model, transformation pipeline, target emitters, native backend, GUI and CLI.

## Semantic representation

A Semantic program is modeled as a typed and attributed graph:

```text
P = (V, E, T, A, C)
```

Where:

- `V` contains UAST nodes
- `E` contains semantic and structural relations
- `T` contains type information
- `A` contains semantic attributes
- `C` contains contracts and execution constraints

The canonical representation preserves information such as:

- functions, parameters and multiple results
- variables, bindings and lexical scopes
- structured and primitive types
- operations and evaluation order
- effects and cleanup behavior
- control-flow and data-flow relations
- closures and captured environments
- aggregate layout and bounds contracts
- ABI and runtime requirements

## SFPC

**SFPC** means **Semantic Fixed Point Compression**.

SFPC is the transport and validation model for canonical SemanticProgram/UAST documents. It removes only information that can be reconstructed deterministically without changing program meaning.

For a semantic document `D` and its canonical form `C(D)`:

```text
Decode(Encode(C(D))) = C(D)
```

The encoded representation also reaches a byte-level fixed point:

```text
Encode(Decode(Encode(C(D)))) = Encode(C(D))
```

This means that decoding and encoding an already canonical Semantic document produces the same canonical bytes.

For a program graph `G`:

```text
F(G) = G_explicit ∪ derive(F(G))
closure(B) = G
```

where `B` is the smallest explicit basis. Grammar compression encodes a
repeated production `A → X₁…Xₙ` once and uses references, reducing repeated
cost from `k·Σ|Xᵢ|` to `Σ|Xᵢ| + k·|ref(A)|`. `.spz` compresses that canonical
stream; decoding satisfies `Decode(Encode(C(D))) ≡ C(D)`.

## SFGC

**SFGC** means **Semantic Fixed-Point Grammar Compression**.

SFGC represents a canonical Semantic program through explicit facts, stable references, schema defaults and deterministic derivations.

Let:

- `R(P)` be the reduction of program `P` into canonical `.se`
- `X(SE)` be expansion back into a SemanticProgram
- `N(P)` be canonical normalization

The central contract is:

```text
X(R(P)) ≡ N(P)
R(X(SE)) = SE
```

A compression rewrite is used only when it reduces the exact UTF-8 representation:

```text
gain(rule, S) = |UTF8(S)| - |UTF8(rule(S))|
```

Only rewrites with `gain > 0` are applied.

SFPC and SFGC do not introduce another intermediate representation. The canonical SemanticProgram/UAST remains the semantic source of truth.

## Supported ecosystem

The Code-Transpiler ecosystem registers frontends and target emitters for:

- Go
- R
- Rust
- C
- C++
- Python
- Zig
- Julia
- Nim
- C#
- Java
- Kotlin
- Swift

Available routes and individual language features are capability-gated. Route availability does not imply complete equivalence for every language-specific feature.

## File formats

| Extension | Description |
|---|---|
| `.se` | Canonical readable Semantic representation |
| `.sp` | Compatibility alias for Semantic source |
| `.spz` | Compressed Semantic transport format |
| `.semantic.json` | Semantic interchange and debugging format |
| `.exe` | Native Windows executable output |
| `.obj` | Native Windows object output |
| `.bin` | Raw machine-code output |
| `.asm` | Assembly output |

## Design principles

- one canonical SemanticProgram/UAST
- language-independent semantic contracts
- matrix-driven capability tracking
- deterministic serialization
- fail-closed validation
- explicit unsupported results
- native compilation without mandatory assembly
- preservation of evaluation order and effects
- reproducible Semantic identity
- gradual compiler self-hosting

## Related repository

The Go bootstrap compiler, GUI, CLI and importable package are maintained in:

[github.com/tarekwasfy01/Code-Transpiler](https://github.com/tarekwasfy01/Code-Transpiler)

## License

Semantic Programming Language is licensed under the terms provided in [LICENSE](LICENSE).

Copyright (c) 2026 Tarek Wasfy
