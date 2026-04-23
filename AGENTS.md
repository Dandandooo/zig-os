# AGENTS.md

## Purpose
This repository is a Zig-based hobby operating system targeting RISC-V and typically run in QEMU. Keep changes small, direct, and easy to verify.

## Working Style
- Perform work in concrete steps.
- Prefer the simplest correct solution.
- Use Zig standard library and existing project code before adding new dependencies or helpers.
- Avoid broad refactors unless the task explicitly requires them.
- Fix root causes instead of layering one-off patches.

## Project Facts
- Required Zig version: `0.15.2`
- Main kernel sources live under `src/`
- Build orchestration lives in `build.zig`
- Linker script: `kernel.ld`
- Common generated artifacts: `zig-out/`, `.zig-cache/`, `qemu.log`, `ktfs.raw`

## Expected Workflow
1. Read the relevant files before editing.
2. Make the minimum necessary code change.
3. Keep naming and formatting consistent with surrounding Zig code.
4. Verify the narrowest relevant build/test target first.
5. Summarize what changed and note any unverified follow-up.

## Preferred Commands
- Build/run kernel: `just run`
- Run tests in QEMU: `just test`
- Debug test kernel: `just debug`
- Launch GDB: `just gdb`
- Print kernel size: `just size`
- Translate test address: `just taddr <addr>`

## Editing Guidance
- Prefer touching existing files over creating new abstractions.
- Do not add inline comments unless they clarify non-obvious kernel logic.
- Keep low-level code explicit; avoid clever shortcuts.
- Preserve existing public interfaces unless the task requires changing them.
- If a task affects build logic, update `README.md` only when user-facing behavior changes.

## Validation Guidance
- For kernel/runtime changes, prefer `zig build test` when feasible.
- For build-only or compile-scope changes, use the smallest relevant `zig build ...` target.
- Do not fix unrelated failing tests or unrelated warnings.

## Safety Notes
- Assume QEMU, `riscv64-elf-gdb`, and Zig may be environment-specific.
- Do not delete generated artifacts or rewrite local editor config unless the user asks.
- Treat `ktfs.raw` and `qemu.log` as generated outputs, not source-of-truth files.
