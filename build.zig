const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseFast,
    });

    // 定义需要同步编译的两个 Windows 架构
    const targets = [_]struct {
        arch: std.Target.Cpu.Arch,
        lib_name: []const u8,
    }{
        .{ .arch = .x86_64, .lib_name = "libmodbus-x64" },
        .{ .arch = .x86, .lib_name = "libmodbus-x86" },
    };

    for (targets) |t| {
        const target = b.resolveTargetQuery(.{
            .cpu_arch = t.arch,
            .os_tag = .windows,
            .abi = .gnu,
        });

        // 1. 为对应架构翻译 modbus.h (32位与64位的指针/类型宽度不同，必须分开翻译)
        const translate_c = b.addTranslateC(.{
            .root_source_file = b.path("c_src/src/modbus.h"),
            .target = target,
            .optimize = optimize,
        });
        translate_c.addIncludePath(b.path("c_src/src"));
        translate_c.defineCMacro("HAVE_CONFIG_H", "1");
        translate_c.defineCMacro("_WIN32", "1");
        // 与 C 源码保持同一套 Windows 兼容定义，避免两边解析出不同的声明
        translate_c.defineCMacro("OS_WIN32", "1");
        translate_c.defineCMacro("_WIN32_WINNT", "0x0601");

        // 2. 创建该架构的 Zig 模块
        const mod = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("c", translate_c.createModule());

        // 3. 编译对应架构的 libmodbus C 源码
        mod.addIncludePath(b.path("c_src/src"));
        mod.addCSourceFiles(.{
            .files = &.{
                "c_src/src/modbus.c",
                "c_src/src/modbus-data.c",
                "c_src/src/modbus-rtu.c",
                "c_src/src/modbus-tcp.c",
            },
            .flags = &.{
                "-DHAVE_CONFIG_H",
                "-D_WIN32",
                // modbus-tcp.c 用 OS_WIN32 隔离 Winsock 专用分支（IP_TOS、ioctlsocket、
                // WSAEWOULDBLOCK 等），显式定义后不再依赖文件内 #if defined(_WIN32)
                "-DOS_WIN32=1",
                // 最低目标 Windows 7：保证 getaddrinfo/freeaddrinfo/inet_pton 等
                // ws2tcpip 声明可用
                "-D_WIN32_WINNT=0x0601",
                "-D_CRT_SECURE_NO_WARNINGS",
            },
        });
        mod.link_libc = true;
        mod.linkSystemLibrary("ws2_32", .{});

        // 4. 生成动态链接库，输出名为 libmodbus-x64.dll / libmodbus-x86.dll
        const lib = b.addLibrary(.{
            .linkage = .dynamic,
            .name = t.lib_name,
            .root_module = mod,
        });

        // 5. 两个架构的文件名不同，直接安装到 zig-out/bin/ 即可，不会同名覆盖
        b.installArtifact(lib);
    }

    // ========================================================================
    // 交付产物静态检查（CI 用）：zig build test
    // 不加载 DLL，也不依赖串口/网络等真实硬件，仅解析 PE 头校验两个产物
    // 的架构与导出表，可在任意平台（含 windows-latest）稳定运行。
    // ========================================================================
    const check_mod = b.createModule(.{
        .root_source_file = b.path("tests/exports_check.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const check_exe = b.addExecutable(.{
        .name = "exports_check",
        .root_module = check_mod,
    });
    const check_run = b.addRunArtifact(check_exe);
    check_run.setCwd(b.path("."));
    check_run.addArg("zig-out/bin/libmodbus-x64.dll");
    check_run.addArg("x64");
    check_run.addArg("zig-out/bin/libmodbus-x86.dll");
    check_run.addArg("x86");
    check_run.step.dependOn(b.getInstallStep());
    const test_step = b.step("test", "Verify built DLLs: PE architecture and exported functions (no hardware needed)");
    test_step.dependOn(&check_run.step);

    // ========================================================================
    // 实机测试步骤：zig build e2e [-Dcom-port=COM3]
    // 用 Zig 编写测试宿主，通过 Win32 LoadLibrary 加载 zig-out/bin/libmodbus-x64.dll，
    // 在本机 TCP 回环（主站<->从站）与本机真实串口（默认 COM1）上跑完整功能测试。
    // ========================================================================
    const com_port = b.option([]const u8, "com-port", "Serial port used by `zig build e2e` (default: COM1)") orelse "COM1";
    const e2e_mod = b.createModule(.{
        .root_source_file = b.path("tests/e2e_test.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const e2e_exe = b.addExecutable(.{
        .name = "e2e_test",
        .root_module = e2e_mod,
    });
    const e2e_run = b.addRunArtifact(e2e_exe);
    // 以项目根目录为工作目录，测试程序用相对路径加载 DLL
    e2e_run.setCwd(b.path("."));
    e2e_run.addArg(com_port);
    e2e_run.step.dependOn(b.getInstallStep());
    const e2e_step = b.step("e2e", "Run real-device E2E tests against zig-out/bin/libmodbus-x64.dll");
    e2e_step.dependOn(&e2e_run.step);
}
