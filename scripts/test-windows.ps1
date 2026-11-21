# ============================================================================
# Windows 开发机：编译全部产物并执行完整环路自测。
#
#   .\scripts\test-windows.ps1              # 构建 + 产物校验 + 实机 e2e（默认 COM1）
#   .\scripts\test-windows.ps1 -ComPort COM3
#   .\scripts\test-windows.ps1 -SkipE2E     # 只做构建与无硬件校验（等同 CI）
#
# 实机测试会：
#   1. 加载 zig-out\bin\libmodbus-x64.dll 并校验 66 个导出；
#   2. 在本机 TCP 回环上跑全部功能码/异常/并发/重连；
#   3. 打开本机真实串口做 RTU 探测（无外接从站时以超时失败为预期）。
# ============================================================================
[CmdletBinding()]
param(
    [string]$ComPort = 'COM1',
    [switch]$SkipE2E
)

$ErrorActionPreference = 'Stop'

Push-Location (Join-Path $PSScriptRoot '..')
try {
    if (-not (Get-Command zig -ErrorAction SilentlyContinue)) {
        throw '未找到 zig，请把 Zig 0.17.x 加入 PATH'
    }

    Write-Host "==> Zig: $(zig version)"
    Write-Host '==> 构建 x64 / x86 DLL（ReleaseFast）'
    zig build --release=fast
    if ($LASTEXITCODE -ne 0) { throw "zig build 失败（exit $LASTEXITCODE）" }

    Write-Host '==> 校验产物架构与导出表'
    zig build test --release=fast
    if ($LASTEXITCODE -ne 0) { throw "zig build test 失败（exit $LASTEXITCODE）" }

    if ($SkipE2E) {
        Write-Host '==> 已跳过实机 e2e'
    } else {
        Write-Host "==> 实机环路自测（串口 $ComPort）"
        zig build e2e "-Dcom-port=$ComPort"
        if ($LASTEXITCODE -ne 0) { throw "zig build e2e 失败（exit $LASTEXITCODE）" }
    }

    Write-Host '==> 完成'
    Get-ChildItem zig-out\bin\*.dll | Select-Object Name, Length, LastWriteTime
}
finally {
    Pop-Location
}
