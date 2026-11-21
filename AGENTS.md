# AGENTS.md

## Project Overview
- **winmodbus**: A Zig-based build and C ABI wrapper distributing full-symbol Windows DLLs (`libmodbus-x64.dll`, `libmodbus-x86.dll`) built from the vendored upstream `libmodbus` (`c_src/`, LGPL-2.1-or-later, see `LICENSE`). The wrapper lives in `src/main.zig` and exports exactly **66** `cdecl` functions documented in `README.md`.
- **Layout**: `build.zig` (two Windows targets: `x86_64-windows-gnu` + `x86-windows-gnu`), `c_src/` (vendored C sources, marked `linguist-vendored`), `tests/e2e_test.zig` (real-device harness), `tests/exports_check.zig` (hardware-free artifact check), `tools/pe_exports.zig` (PE export dumper), `scripts/` (local helpers), `.github/workflows/release.yml` (CI/release).
- **Toolchain**: Zig `0.17.0` (pinned in `.zigversion`). Use 0.17 stdlib APIs only; do not reintroduce 0.13/0.14 APIs (e.g. `std.process.argsAlloc`, `std.DynLib` on Windows). `--release[=fast|safe|small]` replaces the removed `-Doptimize=...` flag.
- **Platform target**: Windows 7+ (`_WIN32_WINNT=0x0601`), links `ws2_32`, defines `HAVE_CONFIG_H`, `_WIN32` and `OS_WIN32` for both `translate-c` and `addCSourceFiles`; keep those two flag sets in sync.

## Build & Verification Commands
- Build release DLLs: `zig build --release=fast` → `zig-out/bin/libmodbus-x64.dll`, `zig-out/bin/libmodbus-x86.dll` (plus `.pdb`; import libs under `zig-out/lib/`). Plain `zig build` is a Debug build.
- Verify PE headers & 66 exported symbols (no hardware required): `zig build test --release=fast`
- Run full loopback E2E tests on Windows: `zig build e2e -Dcom-port=COM1` (default is `COM1`; use the port the device is wired to). Requires a real serial port for the RTU part.
- Windows one-shot (build + checks + E2E): `.\scripts\test-windows.ps1 [-ComPort COM3] [-SkipE2E]`
- CI-equivalent on Linux/macOS: `./scripts/ci-linux.sh`
- Format check: `zig fmt --check build.zig src tests tools`

CI (`.github/workflows/release.yml`) runs `zig build --release=fast` and `zig build test --release=fast` on `windows-latest`, uploads `zig-out/bin/*.dll`, and publishes a GitHub Release on `v*` tags. Never add `zig build e2e` to CI: hosted runners have no serial device.

## Coding & Platform Guardrails
1. **Cross-Platform CLI Args**: Never call allocator-free `std.process.args()` or `args.iterate()` in code targeting Windows (`tests/exports_check.zig`, `tests/e2e_test.zig`). Those paths require UTF-16 conversion. Use `pub fn main(init: std.process.Init)`, then `var args = try init.minimal.args.iterateAllocator(init.gpa); defer args.deinit();`.
2. **ABI Stability**: Do not alter existing C ABI function names, signatures, calling convention, or struct layouts exported from `libmodbus`. Adding/removing an export requires updating `tests/exports_check.zig`, the E2E export list, `README.md`, and any client declaration units together.
3. **Test Separation**: Keep hardware-free checks in `zig build test` (PE architecture + export table, no `LoadLibrary`, no sockets/serial). Keep real-device probes in `zig build e2e`. New CI checks must not require hardware.
4. **CI Hygiene**: Keep `zig-out/` and `.zig-cache/` untracked in `.gitignore`. Append `[skip ci]` to commit messages when only modifying documentation (`*.md`), `.gitattributes`, or `LICENSE`.
5. **Cache Configuration**: The workflow pins `ZIG_GLOBAL_CACHE_DIR` and `ZIG_LOCAL_CACHE_DIR` to `$GITHUB_WORKSPACE/.zig-cache` and uses `actions/cache@v4` keyed on `build.zig` / `build.zig.zon` / `c_src/src/**`; `mlugg/setup-zig@v2` runs with `use-cache: false`. Preserve this split so compiler-rt and C objects stay reusable without unbounded cache growth.
