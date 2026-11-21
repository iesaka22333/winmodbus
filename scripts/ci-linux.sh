#!/usr/bin/env bash
# ============================================================================
# 本地执行与 GitHub Actions (.github/workflows/release.yml) 相同的构建与自检：
#   zig build --release=fast        -> zig-out/bin/libmodbus-x64.dll / libmodbus-x86.dll
#   zig build test --release=fast   -> PE 架构 + 66 个导出函数校验（无需硬件）
#
# 该脚本可在 Linux / macOS 上运行（Zig 交叉编译 Windows DLL），
# 不包含 `zig build e2e`：实机环路测试需要 Windows + 真实串口。
# ============================================================================
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

ZIG="${ZIG:-zig}"
if ! command -v "$ZIG" >/dev/null 2>&1; then
    echo "错误：未找到 Zig（$ZIG），请安装 0.17.x 或设置 ZIG=/path/to/zig" >&2
    exit 1
fi

echo "==> Zig: $("$ZIG" version)"
echo "==> 构建 x64 / x86 DLL（ReleaseFast）"
"$ZIG" build --release=fast

echo "==> 校验产物架构与导出表"
"$ZIG" build test --release=fast

echo "==> 完成"
ls -l zig-out/bin/libmodbus-x64.dll zig-out/bin/libmodbus-x86.dll
