# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- 新增 GitHub Actions 工作流 CI 修复见 `8cdaad7`
- 新增 `zig build test`：解析 PE 头校验 `libmodbus-x64.dll` / `libmodbus-x86.dll` 的架构与导出函数，不测试串口或网络
- `zig build e2e` 支持 `-Dcom-port=<串口名>`，可指定实际接线的 COM 口（默认 `COM1`）
- 新增本地验证脚本：`scripts/ci-linux.sh`（Linux/macOS 上复现 CI）与 `scripts/test-windows.ps1`（Windows 一键构建 + 校验 + 实机环路测试）
- 为 CI 增加 Zig 编译缓存（`ZIG_GLOBAL_CACHE_DIR` / `ZIG_LOCAL_CACHE_DIR` + `actions/cache@v4`），并把工作目录排除出 Windows Defender 实时扫描
- 新增中英双语 README（`README.md` / `README.zh-CN.md`）
- 新增 LGPL-2.1 许可证文件 `LICENSE`，并添加 `.gitattributes` 将上游 C 源码标记为 `linguist-vendored`

### Changed

- 不再把 `zig-out/bin/*.dll` 提交进仓库，交付物改由 CI 构建产物与 GitHub Release 附件分发
- `.gitignore` 调整：仅忽略仓库根目录的 `/zig-out/`，并修正与二进制入库相关的过时说明

### Fixed

- 修复 `tests/exports_check.zig` 在 Windows 下因直接使用 `args.iterate()` 导致的编译错误；改用 `std.process.Init` + `iterateAllocator(gpa)` 完成 UTF-16 命令行转码

## [1.1.0] - 2026-11-14

### Added

- 新增 7 个原始寄存器取用函数，导出总数由 59 增至 66：
  - `mb_get_reg_u16` / `mb_get_reg_i16`：按下标读取单个寄存器的无符号/有符号原值；
  - `mb_put_reg_u16`：按下标写入单个寄存器；
  - `mb_get_reg_u32_abcd` / `mb_get_reg_u32_cdab`：将相邻两个寄存器组合为无符号 32 位；
  - `mb_get_reg_i32_abcd` / `mb_get_reg_i32_cdab`：同上，返回有符号 32 位
- 新增 `tools/pe_exports.zig`：零依赖 PE 导出表解析工具，用于跨版本比对 DLL 导出符号
- E2E 测试宿主支持自动定位 DLL：依次查找 exe 同目录、裸文件名、仓库根 `zig-out/bin`、以及从 `zig-out/bin` 运行时的相对路径；32 位架构隔离检查找不到 DLL 时标记为 SKIP，不再误报

### Changed

- 新导出函数均为纯追加，既有 59 个函数的名字、签名与行为保持不变，旧调用方无需修改
- README 新增「原始寄存器取用函数」章节与 Delphi 调用示例，并同步更新导出数与检查项统计

### Tests

- E2E 新增 19 项检查（T25–T30），覆盖负温度 `int16` 解释、下标偏移读取、负下标防御以及与 `mb_set_int32_*` 的交叉一致性；全量 94 项检查通过

## [1.0.0] - 2026-11-14

首个正式版本：用 Zig 交叉编译上游 libmodbus，产出面向 Windows x86/x64 的完整符号动态库1.0.0 之前的若干问题修复按约定未逐条列出，本节只汇总对外可见的特性

### Added

- 双架构产物：`libmodbus-x64.dll` 与 `libmodbus-x86.dll`，同时生成 `.pdb` 调试符号与 `.lib` 导入库；C 源码以 Windows 7 为最低目标（`_WIN32_WINNT=0x0601`），显式定义 `_WIN32` / `OS_WIN32`，并链接 `ws2_32`
- 稳定的 C ABI（`cdecl`），共 59 个导出函数，可直接供 Delphi、C++ Builder、MSVC 等调用
- 主站功能：覆盖 0x01、0x02、0x03、0x04、0x05、0x06、0x0F、0x10、0x11、0x16、0x17 全部常用功能码，支持异常应答（errno = `MODBUS_ENOBASE` + 异常码）与原始报文收发（`mb_send_raw_and_receive`）
- 从站模拟：内存数据区映射、线圈/离散输入/保持寄存器/输入寄存器的读写、TCP 从站监听与接入（`mb_tcp_slave_listen_and_accept`）、单次轮询、正常/异常应答与原始报文接收
- 数据转换工具：浮点数与 32 位整数的 `abcd` / `cdab` / `badc` / `dcba` 四种字节序互转
- 并发安全：每次库调用加锁，同一句柄可被多线程并发使用；TCP 从站监听阻塞期间不持锁，可由另一线程调用 `mb_close` 打断
- 面向工业现场的默认值：响应超时 200 ms、字节间隔超时 20 ms；链路级自动重连（TCP 连接错误时）与协议级恢复（CRC 错误时清空接收缓冲），可通过 `mb_set_auto_recovery` 关闭
- 高编号串口名兼容：`COM10` 及以上自动补全为 `\\.\COMxx`，串口名大小写不敏感
- 完整中文使用手册 `README.md`，包含 API 说明、地址与数据类型约定、使用限制，以及 Delphi 声明单元 `uMineModbus.pas` 与主/从站调用示例

### Tests

- 新增实机测试宿主 `tests/e2e_test.zig` 与 `zig build e2e`：加载真实 DLL 校验导出表，并在本机 TCP 回环与真实串口上跑完整功能测试（当时 75 项检查全部通过）
