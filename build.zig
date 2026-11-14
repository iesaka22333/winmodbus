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
}
