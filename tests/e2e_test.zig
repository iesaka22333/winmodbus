// ============================================================================
// winmodbus 实机测试宿主（零第三方依赖，仅用 Zig 标准库 + Win32 API）
//
// 作用：
//   1. 用 std.DynLib 加载 zig-out/bin/libmodbus-x64.dll（即真实交付产物）；
//   2. 校验 DLL 的全部导出符号；
//   3. 在本机用「TCP 从站 <-> TCP 主站」回环，跑通 01/02/03/04/05/06/0F/10/11/16/17
//      全部功能码、异常应答、参数越界、浮点/整型转换、多线程并发、断线自动重连；
//   4. 对本机真实串口（默认 COM1）做 RTU 打开、超时、参数校验等实机探测。
//
// 编译运行：
//   zig build-exe -OReleaseSafe --name e2e_test tests/e2e_test.zig -femit-bin=zig-out/bin/e2e_test.exe
//   zig-out\bin\e2e_test.exe [DLL路径] [串口名]
// ============================================================================
const std = @import("std");

extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(hModule: *anyopaque, lpProcName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn FreeLibrary(hModule: *anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn GetModuleFileNameA(hModule: ?*anyopaque, lpFilename: [*]u8, nSize: u32) callconv(.winapi) u32;

/// 极简动态库封装（Zig 0.17 的 std.DynLib 不再支持 Windows，直接用 Win32 API）
const Lib = struct {
    h: *anyopaque,

    fn open(path: [:0]const u8) ?Lib {
        const h = LoadLibraryA(path.ptr) orelse return null;
        return .{ .h = h };
    }

    fn close(self: *Lib) void {
        _ = FreeLibrary(self.h);
    }

    fn lookup(self: *const Lib, comptime T: type, comptime name: [:0]const u8) ?T {
        const p = GetProcAddress(self.h, name) orelse return null;
        return @ptrCast(p);
    }
};

const LoadedDll = struct {
    lib: Lib,
    path: [:0]const u8,
};

var g_dll_path: [512:0]u8 = undefined;

/// 取当前 exe 所在目录（不含末尾分隔符）
fn exeDir(buf: []u8) ?[]const u8 {
    const n = GetModuleFileNameA(null, buf.ptr, @intCast(buf.len));
    if (n == 0 or n >= buf.len) return null;
    const p = buf[0..n];
    var i = p.len;
    while (i > 0) : (i -= 1) {
        if (p[i - 1] == '\\' or p[i - 1] == '/') return p[0 .. i - 1];
    }
    return null;
}

fn keepPath(p: []const u8) [:0]const u8 {
    const len = @min(p.len, g_dll_path.len - 1);
    @memcpy(g_dll_path[0..len], p[0..len]);
    g_dll_path[len] = 0;
    return g_dll_path[0..len :0];
}

/// 按优先级自动查找 DLL，避免把工作目录写死：
///   1. exe 同目录（把 e2e_test.exe 和 DLL 放一起即可直接双击运行）
///   2. 裸文件名（Windows 加载器会依次搜索 exe 目录、系统目录、PATH、当前目录）
///   3. 仓库根目录相对路径（`zig build e2e` 的工作目录）
///   4. 从 zig-out/bin 里运行时的 `..\..\zig-out\bin\...`
fn loadDllAuto() ?LoadedDll {
    var exe_dir_buf: [512]u8 = undefined;
    var tmp: [512:0]u8 = undefined;

    if (exeDir(&exe_dir_buf)) |d| {
        if (std.mem.printSentinel(&tmp, "{s}\\libmodbus-x64.dll", .{d}, 0) catch null) |p| {
            if (Lib.open(p)) |lib| return .{ .lib = lib, .path = keepPath(p) };
        }
    }

    const fallbacks = [_][:0]const u8{
        "libmodbus-x64.dll",
        "zig-out/bin/libmodbus-x64.dll",
        "..\\..\\zig-out\\bin\\libmodbus-x64.dll",
    };
    for (fallbacks) |p| {
        if (Lib.open(p)) |lib| return .{ .lib = lib, .path = keepPath(p) };
    }
    return null;
}

fn sleepMs(ms: u32) void {
    Sleep(ms);
}

fn nowMs() u64 {
    return GetTickCount64();
}

const Handle = ?*anyopaque;

// ---------------------------------------------------------------------------
// 测试计数
// ---------------------------------------------------------------------------
var g_pass: u32 = 0;
var g_fail: u32 = 0;
var g_skip: u32 = 0;

fn ok(cond: bool, comptime name: []const u8) void {
    if (cond) {
        g_pass += 1;
        std.debug.print("  [PASS] {s}\n", .{name});
    } else {
        g_fail += 1;
        std.debug.print("  [FAIL] {s}\n", .{name});
    }
}

fn eqi(comptime name: []const u8, got: anytype, want: anytype) void {
    if (got == want) {
        g_pass += 1;
        std.debug.print("  [PASS] {s}\n", .{name});
    } else {
        g_fail += 1;
        std.debug.print("  [FAIL] {s}  (got={}, want={})\n", .{ name, got, want });
    }
}

fn info(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("  [INFO] " ++ fmt ++ "\n", args);
}

fn skip(comptime fmt: []const u8, args: anytype) void {
    g_skip += 1;
    std.debug.print("  [SKIP] " ++ fmt ++ "\n", args);
}

fn section(comptime name: []const u8) void {
    std.debug.print("\n==== {s} ====\n", .{name});
}

// ---------------------------------------------------------------------------
// DLL 导出函数表
// ---------------------------------------------------------------------------
const Api = struct {
    // 连接管理
    mb_new_tcp: *const fn ([*:0]const u8, c_int) callconv(.c) Handle,
    mb_new_rtu: *const fn ([*:0]const u8, c_int, u8, c_int, c_int) callconv(.c) Handle,
    mb_connect: *const fn (Handle) callconv(.c) c_int,
    mb_close: *const fn (Handle) callconv(.c) void,
    mb_free: *const fn (Handle) callconv(.c) void,
    mb_set_slave: *const fn (Handle, c_int) callconv(.c) c_int,
    mb_get_slave: *const fn (Handle) callconv(.c) c_int,
    mb_set_timeout_ms: *const fn (Handle, u32, u32) callconv(.c) c_int,
    mb_set_auto_recovery: *const fn (Handle, c_int) callconv(.c) c_int,
    mb_set_debug: *const fn (Handle, c_int) callconv(.c) c_int,
    mb_flush: *const fn (Handle) callconv(.c) c_int,
    mb_get_last_errno: *const fn () callconv(.c) c_int,
    mb_get_last_error_str: *const fn () callconv(.c) [*:0]const u8,

    // 主站读写
    mb_read_bits: *const fn (Handle, c_int, c_int, [*]u8) callconv(.c) c_int,
    mb_read_input_bits: *const fn (Handle, c_int, c_int, [*]u8) callconv(.c) c_int,
    mb_read_registers: *const fn (Handle, c_int, c_int, [*]u16) callconv(.c) c_int,
    mb_read_input_registers: *const fn (Handle, c_int, c_int, [*]u16) callconv(.c) c_int,
    mb_write_bit: *const fn (Handle, c_int, c_int) callconv(.c) c_int,
    mb_write_register: *const fn (Handle, c_int, u16) callconv(.c) c_int,
    mb_write_bits: *const fn (Handle, c_int, c_int, [*]const u8) callconv(.c) c_int,
    mb_write_registers: *const fn (Handle, c_int, c_int, [*]const u16) callconv(.c) c_int,
    mb_mask_write_register: *const fn (Handle, c_int, u16, u16) callconv(.c) c_int,
    mb_write_and_read_registers: *const fn (Handle, c_int, c_int, [*]const u16, c_int, c_int, [*]u16) callconv(.c) c_int,
    mb_report_slave_id: *const fn (Handle, c_int, [*]u8) callconv(.c) c_int,
    mb_send_raw_and_receive: *const fn (Handle, [*]const u8, c_int, [*]u8) callconv(.c) c_int,

    // 从站
    mb_slave_init_mapping: *const fn (Handle, c_int, c_int, c_int, c_int) callconv(.c) c_int,
    mb_slave_init_mapping_ex: *const fn (Handle, c_int, c_int, c_int, c_int, c_int, c_int, c_int, c_int) callconv(.c) c_int,
    mb_slave_set_coil: *const fn (Handle, c_int, u8) callconv(.c) c_int,
    mb_slave_get_coil: *const fn (Handle, c_int, *u8) callconv(.c) c_int,
    mb_slave_set_input_bit: *const fn (Handle, c_int, u8) callconv(.c) c_int,
    mb_slave_get_input_bit: *const fn (Handle, c_int, *u8) callconv(.c) c_int,
    mb_slave_set_holding_reg: *const fn (Handle, c_int, u16) callconv(.c) c_int,
    mb_slave_get_holding_reg: *const fn (Handle, c_int, *u16) callconv(.c) c_int,
    mb_slave_set_input_reg: *const fn (Handle, c_int, u16) callconv(.c) c_int,
    mb_slave_get_input_reg: *const fn (Handle, c_int, *u16) callconv(.c) c_int,
    mb_slave_set_holding_regs_bulk: *const fn (Handle, c_int, c_int, [*]const u16) callconv(.c) c_int,
    mb_slave_get_holding_regs_bulk: *const fn (Handle, c_int, c_int, [*]u16) callconv(.c) c_int,
    mb_slave_set_input_regs_bulk: *const fn (Handle, c_int, c_int, [*]const u16) callconv(.c) c_int,
    mb_slave_get_input_regs_bulk: *const fn (Handle, c_int, c_int, [*]u16) callconv(.c) c_int,
    mb_tcp_slave_listen_and_accept: *const fn (Handle, c_int) callconv(.c) c_int,
    mb_slave_poll_once: *const fn (Handle) callconv(.c) c_int,
    mb_slave_receive_raw: *const fn (Handle, [*]u8) callconv(.c) c_int,
    mb_slave_reply_normal: *const fn (Handle, [*]const u8, c_int) callconv(.c) c_int,
    mb_slave_reply_exception: *const fn (Handle, [*]const u8, c_uint) callconv(.c) c_int,

    // 数据转换
    mb_get_float_abcd: *const fn ([*]const u16) callconv(.c) f32,
    mb_get_float_cdab: *const fn ([*]const u16) callconv(.c) f32,
    mb_get_float_badc: *const fn ([*]const u16) callconv(.c) f32,
    mb_get_float_dcba: *const fn ([*]const u16) callconv(.c) f32,
    mb_set_float_abcd: *const fn (f32, [*]u16) callconv(.c) void,
    mb_set_float_cdab: *const fn (f32, [*]u16) callconv(.c) void,
    mb_set_float_badc: *const fn (f32, [*]u16) callconv(.c) void,
    mb_set_float_dcba: *const fn (f32, [*]u16) callconv(.c) void,
    mb_get_int32_abcd: *const fn ([*]const u16) callconv(.c) i32,
    mb_get_int32_cdab: *const fn ([*]const u16) callconv(.c) i32,
    mb_set_int32_abcd: *const fn (i32, [*]u16) callconv(.c) void,
    mb_set_int32_cdab: *const fn (i32, [*]u16) callconv(.c) void,

    // 原始寄存器取用（兼容老项目）
    mb_get_reg_u16: *const fn ([*]const u16, c_int) callconv(.c) u16,
    mb_get_reg_i16: *const fn ([*]const u16, c_int) callconv(.c) i16,
    mb_put_reg_u16: *const fn (u16, [*]u16, c_int) callconv(.c) void,
    mb_get_reg_u32_abcd: *const fn ([*]const u16, c_int) callconv(.c) u32,
    mb_get_reg_u32_cdab: *const fn ([*]const u16, c_int) callconv(.c) u32,
    mb_get_reg_i32_abcd: *const fn ([*]const u16, c_int) callconv(.c) i32,
    mb_get_reg_i32_cdab: *const fn ([*]const u16, c_int) callconv(.c) i32,
};

/// 设备手册中承诺导出的全部符号（用于导出表完整性校验）
const export_names = [_][:0]const u8{
    "mb_new_tcp",                     "mb_new_rtu",                   "mb_connect",
    "mb_close",                       "mb_free",                      "mb_set_slave",
    "mb_get_slave",                   "mb_set_timeout_ms",            "mb_set_auto_recovery",
    "mb_set_debug",                   "mb_flush",                     "mb_get_last_errno",
    "mb_get_last_error_str",          "mb_read_bits",                 "mb_read_input_bits",
    "mb_read_registers",              "mb_read_input_registers",      "mb_write_bit",
    "mb_write_register",              "mb_write_bits",                "mb_write_registers",
    "mb_mask_write_register",         "mb_write_and_read_registers",  "mb_report_slave_id",
    "mb_send_raw_and_receive",        "mb_slave_init_mapping",        "mb_slave_init_mapping_ex",
    "mb_slave_set_coil",              "mb_slave_get_coil",            "mb_slave_set_input_bit",
    "mb_slave_get_input_bit",         "mb_slave_set_holding_reg",     "mb_slave_get_holding_reg",
    "mb_slave_set_input_reg",         "mb_slave_get_input_reg",       "mb_slave_set_holding_regs_bulk",
    "mb_slave_get_holding_regs_bulk", "mb_slave_set_input_regs_bulk", "mb_slave_get_input_regs_bulk",
    "mb_tcp_slave_listen_and_accept", "mb_slave_poll_once",           "mb_slave_receive_raw",
    "mb_slave_reply_normal",          "mb_slave_reply_exception",     "mb_get_float_abcd",
    "mb_get_float_cdab",              "mb_get_float_badc",            "mb_get_float_dcba",
    "mb_set_float_abcd",              "mb_set_float_cdab",            "mb_set_float_badc",
    "mb_set_float_dcba",              "mb_get_int32_abcd",            "mb_get_int32_cdab",
    "mb_set_int32_abcd",              "mb_set_int32_cdab",            "mb_rtu_set_serial_mode",
    "mb_rtu_set_rts",                 "mb_rtu_set_rts_delay",         "mb_get_reg_u16",
    "mb_get_reg_i16",                 "mb_put_reg_u16",               "mb_get_reg_u32_abcd",
    "mb_get_reg_u32_cdab",            "mb_get_reg_i32_abcd",          "mb_get_reg_i32_cdab",
};

fn sym(comptime T: type, lib: *const Lib, comptime name: [:0]const u8) T {
    return lib.lookup(T, name) orelse @panic("missing export: " ++ name);
}

fn loadApi(lib: *const Lib) Api {
    return .{
        .mb_new_tcp = sym(@TypeOf(@as(Api, undefined).mb_new_tcp), lib, "mb_new_tcp"),
        .mb_new_rtu = sym(@TypeOf(@as(Api, undefined).mb_new_rtu), lib, "mb_new_rtu"),
        .mb_connect = sym(@TypeOf(@as(Api, undefined).mb_connect), lib, "mb_connect"),
        .mb_close = sym(@TypeOf(@as(Api, undefined).mb_close), lib, "mb_close"),
        .mb_free = sym(@TypeOf(@as(Api, undefined).mb_free), lib, "mb_free"),
        .mb_set_slave = sym(@TypeOf(@as(Api, undefined).mb_set_slave), lib, "mb_set_slave"),
        .mb_get_slave = sym(@TypeOf(@as(Api, undefined).mb_get_slave), lib, "mb_get_slave"),
        .mb_set_timeout_ms = sym(@TypeOf(@as(Api, undefined).mb_set_timeout_ms), lib, "mb_set_timeout_ms"),
        .mb_set_auto_recovery = sym(@TypeOf(@as(Api, undefined).mb_set_auto_recovery), lib, "mb_set_auto_recovery"),
        .mb_set_debug = sym(@TypeOf(@as(Api, undefined).mb_set_debug), lib, "mb_set_debug"),
        .mb_flush = sym(@TypeOf(@as(Api, undefined).mb_flush), lib, "mb_flush"),
        .mb_get_last_errno = sym(@TypeOf(@as(Api, undefined).mb_get_last_errno), lib, "mb_get_last_errno"),
        .mb_get_last_error_str = sym(@TypeOf(@as(Api, undefined).mb_get_last_error_str), lib, "mb_get_last_error_str"),
        .mb_read_bits = sym(@TypeOf(@as(Api, undefined).mb_read_bits), lib, "mb_read_bits"),
        .mb_read_input_bits = sym(@TypeOf(@as(Api, undefined).mb_read_input_bits), lib, "mb_read_input_bits"),
        .mb_read_registers = sym(@TypeOf(@as(Api, undefined).mb_read_registers), lib, "mb_read_registers"),
        .mb_read_input_registers = sym(@TypeOf(@as(Api, undefined).mb_read_input_registers), lib, "mb_read_input_registers"),
        .mb_write_bit = sym(@TypeOf(@as(Api, undefined).mb_write_bit), lib, "mb_write_bit"),
        .mb_write_register = sym(@TypeOf(@as(Api, undefined).mb_write_register), lib, "mb_write_register"),
        .mb_write_bits = sym(@TypeOf(@as(Api, undefined).mb_write_bits), lib, "mb_write_bits"),
        .mb_write_registers = sym(@TypeOf(@as(Api, undefined).mb_write_registers), lib, "mb_write_registers"),
        .mb_mask_write_register = sym(@TypeOf(@as(Api, undefined).mb_mask_write_register), lib, "mb_mask_write_register"),
        .mb_write_and_read_registers = sym(@TypeOf(@as(Api, undefined).mb_write_and_read_registers), lib, "mb_write_and_read_registers"),
        .mb_report_slave_id = sym(@TypeOf(@as(Api, undefined).mb_report_slave_id), lib, "mb_report_slave_id"),
        .mb_send_raw_and_receive = sym(@TypeOf(@as(Api, undefined).mb_send_raw_and_receive), lib, "mb_send_raw_and_receive"),
        .mb_slave_init_mapping = sym(@TypeOf(@as(Api, undefined).mb_slave_init_mapping), lib, "mb_slave_init_mapping"),
        .mb_slave_init_mapping_ex = sym(@TypeOf(@as(Api, undefined).mb_slave_init_mapping_ex), lib, "mb_slave_init_mapping_ex"),
        .mb_slave_set_coil = sym(@TypeOf(@as(Api, undefined).mb_slave_set_coil), lib, "mb_slave_set_coil"),
        .mb_slave_get_coil = sym(@TypeOf(@as(Api, undefined).mb_slave_get_coil), lib, "mb_slave_get_coil"),
        .mb_slave_set_input_bit = sym(@TypeOf(@as(Api, undefined).mb_slave_set_input_bit), lib, "mb_slave_set_input_bit"),
        .mb_slave_get_input_bit = sym(@TypeOf(@as(Api, undefined).mb_slave_get_input_bit), lib, "mb_slave_get_input_bit"),
        .mb_slave_set_holding_reg = sym(@TypeOf(@as(Api, undefined).mb_slave_set_holding_reg), lib, "mb_slave_set_holding_reg"),
        .mb_slave_get_holding_reg = sym(@TypeOf(@as(Api, undefined).mb_slave_get_holding_reg), lib, "mb_slave_get_holding_reg"),
        .mb_slave_set_input_reg = sym(@TypeOf(@as(Api, undefined).mb_slave_set_input_reg), lib, "mb_slave_set_input_reg"),
        .mb_slave_get_input_reg = sym(@TypeOf(@as(Api, undefined).mb_slave_get_input_reg), lib, "mb_slave_get_input_reg"),
        .mb_slave_set_holding_regs_bulk = sym(@TypeOf(@as(Api, undefined).mb_slave_set_holding_regs_bulk), lib, "mb_slave_set_holding_regs_bulk"),
        .mb_slave_get_holding_regs_bulk = sym(@TypeOf(@as(Api, undefined).mb_slave_get_holding_regs_bulk), lib, "mb_slave_get_holding_regs_bulk"),
        .mb_slave_set_input_regs_bulk = sym(@TypeOf(@as(Api, undefined).mb_slave_set_input_regs_bulk), lib, "mb_slave_set_input_regs_bulk"),
        .mb_slave_get_input_regs_bulk = sym(@TypeOf(@as(Api, undefined).mb_slave_get_input_regs_bulk), lib, "mb_slave_get_input_regs_bulk"),
        .mb_tcp_slave_listen_and_accept = sym(@TypeOf(@as(Api, undefined).mb_tcp_slave_listen_and_accept), lib, "mb_tcp_slave_listen_and_accept"),
        .mb_slave_poll_once = sym(@TypeOf(@as(Api, undefined).mb_slave_poll_once), lib, "mb_slave_poll_once"),
        .mb_slave_receive_raw = sym(@TypeOf(@as(Api, undefined).mb_slave_receive_raw), lib, "mb_slave_receive_raw"),
        .mb_slave_reply_normal = sym(@TypeOf(@as(Api, undefined).mb_slave_reply_normal), lib, "mb_slave_reply_normal"),
        .mb_slave_reply_exception = sym(@TypeOf(@as(Api, undefined).mb_slave_reply_exception), lib, "mb_slave_reply_exception"),
        .mb_get_float_abcd = sym(@TypeOf(@as(Api, undefined).mb_get_float_abcd), lib, "mb_get_float_abcd"),
        .mb_get_float_cdab = sym(@TypeOf(@as(Api, undefined).mb_get_float_cdab), lib, "mb_get_float_cdab"),
        .mb_get_float_badc = sym(@TypeOf(@as(Api, undefined).mb_get_float_badc), lib, "mb_get_float_badc"),
        .mb_get_float_dcba = sym(@TypeOf(@as(Api, undefined).mb_get_float_dcba), lib, "mb_get_float_dcba"),
        .mb_set_float_abcd = sym(@TypeOf(@as(Api, undefined).mb_set_float_abcd), lib, "mb_set_float_abcd"),
        .mb_set_float_cdab = sym(@TypeOf(@as(Api, undefined).mb_set_float_cdab), lib, "mb_set_float_cdab"),
        .mb_set_float_badc = sym(@TypeOf(@as(Api, undefined).mb_set_float_badc), lib, "mb_set_float_badc"),
        .mb_set_float_dcba = sym(@TypeOf(@as(Api, undefined).mb_set_float_dcba), lib, "mb_set_float_dcba"),
        .mb_get_int32_abcd = sym(@TypeOf(@as(Api, undefined).mb_get_int32_abcd), lib, "mb_get_int32_abcd"),
        .mb_get_int32_cdab = sym(@TypeOf(@as(Api, undefined).mb_get_int32_cdab), lib, "mb_get_int32_cdab"),
        .mb_set_int32_abcd = sym(@TypeOf(@as(Api, undefined).mb_set_int32_abcd), lib, "mb_set_int32_abcd"),
        .mb_set_int32_cdab = sym(@TypeOf(@as(Api, undefined).mb_set_int32_cdab), lib, "mb_set_int32_cdab"),
        .mb_get_reg_u16 = sym(@TypeOf(@as(Api, undefined).mb_get_reg_u16), lib, "mb_get_reg_u16"),
        .mb_get_reg_i16 = sym(@TypeOf(@as(Api, undefined).mb_get_reg_i16), lib, "mb_get_reg_i16"),
        .mb_put_reg_u16 = sym(@TypeOf(@as(Api, undefined).mb_put_reg_u16), lib, "mb_put_reg_u16"),
        .mb_get_reg_u32_abcd = sym(@TypeOf(@as(Api, undefined).mb_get_reg_u32_abcd), lib, "mb_get_reg_u32_abcd"),
        .mb_get_reg_u32_cdab = sym(@TypeOf(@as(Api, undefined).mb_get_reg_u32_cdab), lib, "mb_get_reg_u32_cdab"),
        .mb_get_reg_i32_abcd = sym(@TypeOf(@as(Api, undefined).mb_get_reg_i32_abcd), lib, "mb_get_reg_i32_abcd"),
        .mb_get_reg_i32_cdab = sym(@TypeOf(@as(Api, undefined).mb_get_reg_i32_cdab), lib, "mb_get_reg_i32_cdab"),
    };
}

// ---------------------------------------------------------------------------
// 从站后台线程
// ---------------------------------------------------------------------------
const SlaveRunner = struct {
    api: *const Api,
    h: Handle,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    accepted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    accept_rc: std.atomic.Value(i32) = std.atomic.Value(i32).init(-99),
    polls: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    last_rc: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
};

fn slaveMain(r: *SlaveRunner) void {
    const rc = r.api.mb_tcp_slave_listen_and_accept(r.h, 1);
    r.accept_rc.store(rc, .release);
    r.accepted.store(true, .release);
    if (rc < 0) return;
    while (!r.stop.load(.acquire)) {
        const p = r.api.mb_slave_poll_once(r.h);
        r.last_rc.store(@intCast(p), .monotonic);
        if (p > 0) g_unused_polls += 1;
        if (p < 0) sleepMs(5);
    }
}

var g_unused_polls: u32 = 0;

// ---------------------------------------------------------------------------
// 主站并发线程
// ---------------------------------------------------------------------------
const MtArg = struct {
    api: *const Api,
    h: Handle,
    iters: u32,
    fails: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    oks: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

fn mtMain(a: *MtArg) void {
    var buf: [4]u16 = undefined;
    var i: u32 = 0;
    while (i < a.iters) : (i += 1) {
        const rc = a.api.mb_read_registers(a.h, 0, 4, &buf);
        if (rc == 4 and buf[0] == 100 and buf[1] == 200 and buf[2] == 300 and buf[3] == 400) {
            _ = a.oks.fetchAdd(1, .monotonic);
        } else {
            _ = a.fails.fetchAdd(1, .monotonic);
        }
    }
}

// ---------------------------------------------------------------------------
// TCP 回环全功能测试
// ---------------------------------------------------------------------------
const SlavePort: c_int = 15020;

/// 启动一套从站（新句柄），返回句柄与运行器
fn startSlave(api: *const Api, port: c_int, runner: *SlaveRunner, thread: *std.Thread) !Handle {
    const h = api.mb_new_tcp("0.0.0.0", port) orelse return error.NewTcpFailed;
    if (api.mb_set_slave(h, 1) != 0) return error.SetSlaveFailed;
    if (api.mb_slave_init_mapping(h, 64, 64, 128, 64) != 0) {
        api.mb_free(h);
        return error.InitMappingFailed;
    }
    runner.* = .{ .api = api, .h = h };
    thread.* = try std.Thread.spawn(.{}, slaveMain, .{runner});
    // 注意：listen_and_accept 会阻塞到主站连入，因此这里不能等待 accepted 标志，
    // 由主站侧 connectMaster() 用重试方式等待监听端口就绪。
    return h;
}

fn stopSlave(api: *const Api, h: Handle, runner: *SlaveRunner, thread: std.Thread) void {
    runner.stop.store(true, .release);
    api.mb_close(h); // 打断阻塞中的 modbus_receive
    thread.join();
    api.mb_free(h);
}

fn connectMaster(api: *const Api, port: c_int) Handle {
    var attempt: u32 = 0;
    while (attempt < 100) : (attempt += 1) {
        const h = api.mb_new_tcp("127.0.0.1", port) orelse return null;
        _ = api.mb_set_slave(h, 1);
        if (api.mb_connect(h) == 0) return h;
        api.mb_free(h);
        sleepMs(10);
    }
    return null;
}

fn tcpSuite(api: *const Api) void {
    section("TCP loopback: full function-code suite");

    var runner: SlaveRunner = undefined;
    var thread: std.Thread = undefined;
    const slave_h = startSlave(api, SlavePort, &runner, &thread) catch {
        ok(false, "slave listen/accept on 127.0.0.1:15020");
        return;
    };

    const m = connectMaster(api, SlavePort);
    if (m == null) {
        ok(false, "master connect to loopback slave");
        info("slave accept_rc={} last_errno={} msg=\"{s}\"", .{
            runner.accept_rc.load(.acquire),
            api.mb_get_last_errno(),
            std.mem.span(api.mb_get_last_error_str()),
        });
        stopSlave(api, slave_h, &runner, thread);
        return;
    }
    ok(true, "slave listen+accept, master connect (real TCP socket)");
    eqi("T06 mb_get_slave == 1", api.mb_get_slave(m), 1);

    var regs_in = [4]u16{ 100, 200, 300, 400 };
    eqi("T07a slave bulk-set 4 holding regs", api.mb_slave_set_holding_regs_bulk(slave_h, 0, 4, &regs_in), 0);
    var regs_out = [8]u16{ 0, 0, 0, 0, 0, 0, 0, 0 };
    eqi("T07b FC03 read 4 holding regs", api.mb_read_registers(m, 0, 4, &regs_out), 4);
    ok(regs_out[0] == 100 and regs_out[1] == 200 and regs_out[2] == 300 and regs_out[3] == 400, "T07c FC03 payload correct");

    eqi("T08a FC06 write single register", api.mb_write_register(m, 5, 0xABCD), 1);
    var v16: u16 = 0;
    _ = api.mb_slave_get_holding_reg(slave_h, 5, &v16);
    eqi("T08b FC06 landed in slave memory", v16, 0xABCD);

    var wr3 = [3]u16{ 11, 22, 33 };
    eqi("T09a FC10 write 3 registers", api.mb_write_registers(m, 10, 3, &wr3), 3);
    var rd3 = [4]u16{ 0, 0, 0, 0 };
    _ = api.mb_slave_get_holding_regs_bulk(slave_h, 10, 3, &rd3);
    ok(rd3[0] == 11 and rd3[1] == 22 and rd3[2] == 33, "T09b FC10 payload landed");

    // FC01 / FC05 / FC0F 线圈
    var coil_pattern = [8]u8{ 1, 0, 1, 1, 0, 0, 1, 0 };
    var i: usize = 0;
    while (i < 8) : (i += 1) _ = api.mb_slave_set_coil(slave_h, @intCast(i), coil_pattern[i]);
    var bits = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    eqi("T10 FC01 read 8 coils", api.mb_read_bits(m, 0, 8, &bits), 8);
    ok(std.mem.eql(u8, bits[0..8], coil_pattern[0..8]), "T10b FC01 payload correct");

    eqi("T11a FC05 write coil 20 ON", api.mb_write_bit(m, 20, 1), 1);
    var b: u8 = 0;
    _ = api.mb_slave_get_coil(slave_h, 20, &b);
    eqi("T11b coil 20 == 1", b, 1);
    eqi("T11c FC05 write coil 20 OFF", api.mb_write_bit(m, 20, 0), 1);

    var wb = [8]u8{ 1, 1, 0, 0, 1, 0, 0, 1 };
    eqi("T12a FC0F write 8 coils", api.mb_write_bits(m, 30, 8, &wb), 8);
    var j: usize = 0;
    var coils_ok = true;
    while (j < 8) : (j += 1) {
        var cb: u8 = 0xEE;
        _ = api.mb_slave_get_coil(slave_h, @intCast(30 + j), &cb);
        if (cb != wb[j]) coils_ok = false;
    }
    ok(coils_ok, "T12b FC0F payload landed");

    // FC02 离散输入
    var inb = [8]u8{ 0, 1, 1, 0, 1, 0, 1, 1 };
    i = 0;
    while (i < 8) : (i += 1) _ = api.mb_slave_set_input_bit(slave_h, @intCast(i), inb[i]);
    var rdb = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    eqi("T13 FC02 read 8 input bits", api.mb_read_input_bits(m, 0, 8, &rdb), 8);
    ok(std.mem.eql(u8, rdb[0..8], inb[0..8]), "T13b FC02 payload correct");

    // FC04 输入寄存器
    var inregs = [3]u16{ 7, 8, 9 };
    _ = api.mb_slave_set_input_regs_bulk(slave_h, 0, 3, &inregs);
    var rdin = [4]u16{ 0, 0, 0, 0 };
    eqi("T14 FC04 read 3 input regs", api.mb_read_input_registers(m, 0, 3, &rdin), 3);
    ok(rdin[0] == 7 and rdin[1] == 8 and rdin[2] == 9, "T14b FC04 payload correct");

    // FC16 掩码写：(0x1234 & 0xFF00) | (0x0055 & ~0xFF00) = 0x1255
    _ = api.mb_slave_set_holding_reg(slave_h, 40, 0x1234);
    eqi("T15a FC16 mask-write", api.mb_mask_write_register(m, 40, 0xFF00, 0x0055), 1);
    v16 = 0;
    _ = api.mb_slave_get_holding_reg(slave_h, 40, &v16);
    eqi("T15b masked value == 0x1255", v16, 0x1255);

    // FC17 写读组合
    var w17 = [1]u16{0xAAAA};
    var r17 = [2]u16{ 0, 0 };
    eqi("T16 FC17 write+read", api.mb_write_and_read_registers(m, 50, 1, &w17, 50, 1, &r17), 1);
    eqi("T16b FC17 read-back value", r17[0], 0xAAAA);

    // FC11 报告从站 ID：libmodbus 返回剥离 MBAP/站号/功能码/字节数后的负载，
    // 负载以 0xB4(_REPORT_SLAVE_ID) + 0xFF(运行指示) + "LMBx.y.z" 开头
    var idbuf: [64]u8 = @splat(0);
    const idrc = api.mb_report_slave_id(m, 64, &idbuf);
    ok(idrc >= 2 and idbuf[0] == 0xB4 and idbuf[1] == 0xFF, "T17 FC11 report slave id");
    if (idrc >= 2) info("FC11 reply: {} bytes, id=0x{X} run=0x{X} text=\"{s}\"", .{ idrc, idbuf[0], idbuf[1], idbuf[2..@min(@as(usize, @intCast(idrc)), 64)] });

    // 异常应答：地址越界 → -1，errno == MODBUS_ENOBASE(112345678) + 异常码 2
    const modbus_enobase: c_int = 112345678;
    const exc_rc = api.mb_read_registers(m, 1000, 10, &regs_out);
    const exc_errno = api.mb_get_last_errno();
    eqi("T18a out-of-range read returns -1", exc_rc, -1);
    eqi("T18b errno == MODBUS_ENOBASE + ILLEGAL_DATA_ADDRESS", exc_errno, modbus_enobase + 2);
    info("exception errno=0x{X} msg=\"{s}\"", .{ exc_errno, std.mem.span(api.mb_get_last_error_str()) });
    // 地址合法但长度越界（100+50 > 128）→ 异常 2
    eqi("T18c range-overflow read returns -1", api.mb_read_registers(m, 100, 50, &regs_out), -1);
    eqi("T18d range-overflow errno", api.mb_get_last_errno(), modbus_enobase + 2);

    // 参数越界
    eqi("T19a nb=0 rejected", api.mb_read_registers(m, 0, 0, &regs_out), -1);
    eqi("T19b nb=126 (>125) rejected", api.mb_read_registers(m, 0, 126, &regs_out), -1);
    eqi("T19c null handle rejected", api.mb_read_registers(null, 0, 1, &regs_out), -1);
    eqi("T19d write nb=124 (>123) rejected", api.mb_write_registers(m, 0, 124, &wr3), -1);

    // 数据转换
    var pair = [2]u16{ 0, 0 };
    api.mb_set_float_cdab(3.1415927, &pair);
    ok(@abs(api.mb_get_float_cdab(&pair) - 3.1415927) < 1e-5, "T20a float cdab round-trip");
    api.mb_set_float_abcd(-12.5, &pair);
    ok(@abs(api.mb_get_float_abcd(&pair) + 12.5) < 1e-5, "T20b float abcd round-trip");
    api.mb_set_float_badc(0.5, &pair);
    ok(@abs(api.mb_get_float_badc(&pair) - 0.5) < 1e-6, "T20c float badc round-trip");
    api.mb_set_float_dcba(1000.25, &pair);
    ok(@abs(api.mb_get_float_dcba(&pair) - 1000.25) < 1e-3, "T20d float dcba round-trip");
    api.mb_set_int32_abcd(-123456789, &pair);
    eqi("T20e int32 abcd round-trip", api.mb_get_int32_abcd(&pair), -123456789);
    api.mb_set_int32_cdab(-123456789, &pair);
    eqi("T20f int32 cdab round-trip", api.mb_get_int32_cdab(&pair), -123456789);

    // ---- 原始寄存器取用函数（兼容老项目） ----
    // 构造有符号负温度 -12.5℃ ×10 = -125 → 0xFF83；湿度 654 = 65.4%
    var raw = [8]u16{ 0xFF83, 654, 0x0001, 0x86A0, 0x1234, 0x5678, 0xFFFF, 0x0000 };
    eqi("T25a mb_get_reg_u16 raw value", api.mb_get_reg_u16(&raw, 1), 654);
    eqi("T25b mb_get_reg_u16 sees signed bits as unsigned", api.mb_get_reg_u16(&raw, 0), 0xFF83);
    eqi("T25c mb_get_reg_i16 decodes negative", api.mb_get_reg_i16(&raw, 0), -125);
    eqi("T25d mb_get_reg_i16 positive unchanged", api.mb_get_reg_i16(&raw, 1), 654);

    // -12.5℃ 还原：raw × 0.1
    const temp = @as(f64, @floatFromInt(api.mb_get_reg_i16(&raw, 0))) / 10.0;
    ok(@abs(temp + 12.5) < 1e-9, "T25e temperature scaling -125 -> -12.5");

    eqi("T26a mb_get_reg_u32_abcd hi-lo order", api.mb_get_reg_u32_abcd(&raw, 2), 0x000186A0);
    // raw[6..8] = 0xFFFF,0x0000 → ABCD 组合 = 0xFFFF0000 = -65536；CDAB 组合 = 0x0000FFFF = 65535
    eqi("T26b mb_get_reg_i32_abcd signed", api.mb_get_reg_i32_abcd(&raw, 6), -65536);
    eqi("T26c mb_get_reg_u32_cdab swaps words", api.mb_get_reg_u32_cdab(&raw, 2), 0x86A00001);
    eqi("T26d mb_get_reg_i32_cdab on 0xFFFF,0x0000", api.mb_get_reg_i32_cdab(&raw, 6), 65535);

    // 下标偏移读取（等价于切片）
    eqi("T27a index offset from middle", api.mb_get_reg_u16(&raw, 4), 0x1234);
    eqi("T27b u32 from offset index", api.mb_get_reg_u32_abcd(&raw, 4), 0x12345678);

    // 写入
    var wbuf = [4]u16{ 0, 0, 0, 0 };
    api.mb_put_reg_u16(0xABCD, &wbuf, 0);
    api.mb_put_reg_u16(0x1234, &wbuf, 3);
    ok(wbuf[0] == 0xABCD and wbuf[1] == 0 and wbuf[2] == 0 and wbuf[3] == 0x1234, "T28 mb_put_reg_u16 writes at index");

    // 负下标防御（返回 0 / 不写入，不崩溃）
    eqi("T29a negative index u16 returns 0", api.mb_get_reg_u16(&raw, -1), 0);
    eqi("T29b negative index i16 returns 0", api.mb_get_reg_i16(&raw, -1), 0);
    eqi("T29c negative index u32 returns 0", api.mb_get_reg_u32_abcd(&raw, -5), 0);
    var guard = [2]u16{ 0x1111, 0x2222 };
    api.mb_put_reg_u16(0x9999, &guard, -1);
    ok(guard[0] == 0x1111 and guard[1] == 0x2222, "T29d negative index put is no-op");

    // 与 32 位转换函数一致性交叉验证
    var cross = [2]u16{ 0, 0 };
    api.mb_set_int32_abcd(-123456789, &cross);
    eqi("T30a reg_u32_abcd matches set_int32_abcd", api.mb_get_reg_u32_abcd(&cross, 0), @as(u32, @bitCast(@as(i32, -123456789))));
    api.mb_set_int32_cdab(-123456789, &cross);
    eqi("T30b reg_i32_cdab matches set_int32_cdab", api.mb_get_reg_i32_cdab(&cross, 0), -123456789);
    api.mb_set_float_cdab(3.5, &cross);
    ok(@abs(api.mb_get_float_cdab(&cross) - 3.5) < 1e-6, "T30c float unchanged by raw helpers");

    // 连续 200 次读，测吞吐与时延
    var seq_ok: u32 = 0;
    const t0 = nowMs();
    var k: u32 = 0;
    while (k < 200) : (k += 1) {
        if (api.mb_read_registers(m, 0, 4, &regs_out) == 4) seq_ok += 1;
    }
    const dt = nowMs() - t0;
    eqi("T22 200 sequential FC03 reads all OK", seq_ok, 200);
    info("200 x FC03 on loopback: {} ms total, avg {d:.2} ms/call", .{ dt, @as(f64, @floatFromInt(dt)) / 200.0 });

    // 多线程并发同一句柄（4 线程 x 50 次）
    var args: [4]MtArg = undefined;
    var ths: [4]std.Thread = undefined;
    var ci: usize = 0;
    while (ci < 4) : (ci += 1) {
        args[ci] = .{ .api = api, .h = m, .iters = 50 };
        ths[ci] = std.Thread.spawn(.{}, mtMain, .{&args[ci]}) catch unreachable;
    }
    ci = 0;
    while (ci < 4) : (ci += 1) ths[ci].join();
    var total_ok: u32 = 0;
    var total_fail: u32 = 0;
    ci = 0;
    while (ci < 4) : (ci += 1) {
        total_ok += args[ci].oks.load(.acquire);
        total_fail += args[ci].fails.load(.acquire);
    }
    eqi("T21 4 threads x 50 reads: failures", total_fail, 0);
    eqi("T21b 4 threads x 50 reads: successes", total_ok, 200);

    // 调试开关与 flush
    eqi("T23a mb_set_debug(1)", api.mb_set_debug(m, 1), 0);
    eqi("T23b mb_set_debug(0)", api.mb_set_debug(m, 0), 0);
    ok(api.mb_flush(m) >= 0, "T23c mb_flush >= 0");

    // ---- 断线自动重连 ----
    section("TCP loopback: link-loss auto recovery");
    stopSlave(api, slave_h, &runner, thread);
    const lost_rc = api.mb_read_registers(m, 0, 4, &regs_out);
    info("first read after peer close: rc={} errno={}", .{ lost_rc, api.mb_get_last_errno() });
    ok(lost_rc == -1, "T24a read fails while peer down");

    var runner2: SlaveRunner = undefined;
    var thread2: std.Thread = undefined;
    const slave2 = startSlave(api, SlavePort, &runner2, &thread2) catch {
        ok(false, "T24b restart slave on same port");
        api.mb_close(m);
        api.mb_free(m);
        return;
    };
    ok(true, "T24b restart slave on same port");

    var regained: c_int = -1;
    var tries: u32 = 0;
    while (tries < 10) : (tries += 1) {
        regained = api.mb_read_registers(m, 0, 4, &regs_out);
        if (regained == 4) break;
        sleepMs(100);
    }
    eqi("T24c master auto-reconnected (read ok)", regained, 4);
    info("recovery took {} retries", .{tries});

    api.mb_close(m);
    api.mb_free(m);
    stopSlave(api, slave2, &runner2, thread2);
}

// ---------------------------------------------------------------------------
// RTU 实串口测试（默认 COM1）
// ---------------------------------------------------------------------------
fn rtuSuite(api: *const Api, com: [:0]const u8) void {
    section("RTU real serial port");

    const h = api.mb_new_rtu(com.ptr, 9600, 'N', 8, 1);
    ok(h != null, "R01 mb_new_rtu(COMx,9600,N,8,1) creates handle");
    if (h == null) return;

    eqi("R02 mb_set_slave(1)", api.mb_set_slave(h, 1), 0);
    eqi("R03 mb_get_slave == 1", api.mb_get_slave(h), 1);

    const t0 = nowMs();
    const crc = api.mb_connect(h);
    const open_ms = nowMs() - t0;
    ok(crc == 0, "R04 mb_connect opens the real port");
    info("serial open took {} ms", .{open_ms});
    if (crc != 0) {
        info("open failed: errno={} msg=\"{s}\"", .{ api.mb_get_last_errno(), std.mem.span(api.mb_get_last_error_str()) });
        api.mb_free(h);
        return;
    }

    // 默认 200ms 响应超时：无外接从站时应快速失败
    var regs = [2]u16{ 0, 0 };
    const t1 = nowMs();
    const rc1 = api.mb_read_registers(h, 0, 2, &regs);
    const ms1 = nowMs() - t1;
    info("FC03 @9600 no-device: rc={} elapsed={} ms errno={} msg=\"{s}\"", .{ rc1, ms1, api.mb_get_last_errno(), std.mem.span(api.mb_get_last_error_str()) });
    if (rc1 == 2) {
        info("REAL DEVICE ANSWERED: regs={},{}", .{ regs[0], regs[1] });
        g_pass += 1;
    } else {
        ok(rc1 == -1, "R05 no-device read returns -1 (expected)");
        ok(ms1 < 1200, "R06 default 200ms timeout honored (did not hang)");
        if (ms1 > 150 and ms1 < 400) g_pass += 1 else {
            g_fail += 1;
            std.debug.print("  [FAIL] R07 timeout close to 200ms (actual {} ms)\n", .{ms1});
        }
    }

    eqi("R08 mb_set_timeout_ms(500,20)", api.mb_set_timeout_ms(h, 500, 20), 0);
    const t2 = nowMs();
    _ = api.mb_read_registers(h, 0, 2, &regs);
    const ms2 = nowMs() - t2;
    info("after timeout=500ms: elapsed={} ms", .{ms2});
    ok(ms2 >= 400, "R09 500ms timeout applied");
    eqi("R10 restore timeout 200ms", api.mb_set_timeout_ms(h, 200, 20), 0);

    ok(api.mb_flush(h) >= 0, "R11 mb_flush on real port");
    eqi("R12 mb_set_debug(1)", api.mb_set_debug(h, 1), 0);
    eqi("R13 mb_set_debug(0)", api.mb_set_debug(h, 0), 0);
    eqi("R14 mb_set_auto_recovery(0)", api.mb_set_auto_recovery(h, 0), 0);
    eqi("R15 mb_set_auto_recovery(1)", api.mb_set_auto_recovery(h, 1), 0);

    api.mb_close(h);
    api.mb_free(h);

    // 站号边界：libmodbus 允许 0（RTU 广播地址）与 1..247，超过 247 非法
    const h2 = api.mb_new_rtu(com.ptr, 9600, 'N', 8, 1);
    if (h2 != null) {
        eqi("R16 illegal slave id -1 rejected", api.mb_set_slave(h2, -1), -1);
        eqi("R17 illegal slave id 248 rejected", api.mb_set_slave(h2, 248), -1);
        const r0 = api.mb_set_slave(h2, 0);
        info("slave id 0 (RTU broadcast) accepted={}", .{r0 == 0});
        eqi("R17b valid slave id 247 accepted", api.mb_set_slave(h2, 247), 0);
        api.mb_free(h2);
    } else ok(false, "R16 handle for slave-id test");

    // 高编号串口名与大小写兼容（只验证创建、不要求真实存在）
    const h3 = api.mb_new_rtu("COM12", 38400, 'E', 8, 1);
    ok(h3 != null, "R18 mb_new_rtu(\"COM12\") handle (\\\\.\\ completion)");
    if (h3 != null) {
        const c3 = api.mb_connect(h3);
        info("COM12 connect rc={} (absent port expected to fail)", .{c3});
        if (c3 != 0) g_pass += 1 else {
            std.debug.print("  [INFO] COM12 physically present\n", .{});
        }
        api.mb_close(h3);
        api.mb_free(h3);
    }

    const lower = "com1";
    var lower_z: [5]u8 = undefined;
    @memcpy(lower_z[0..4], lower);
    lower_z[4] = 0;
    const h4 = api.mb_new_rtu(@ptrCast(&lower_z), 9600, 'N', 8, 1);
    ok(h4 != null, "R19 lowercase \"com1\" accepted");
    if (h4 != null) {
        _ = api.mb_set_slave(h4, 1);
        const c4 = api.mb_connect(h4);
        ok(c4 == 0, "R19b lowercase com1 opens");
        api.mb_close(h4);
        api.mb_free(h4);
    }

    // 不存在的端口
    const h5 = api.mb_new_rtu("COM199", 9600, 'N', 8, 1);
    ok(h5 != null, "R20 mb_new_rtu(\"COM199\") handle");
    if (h5 != null) {
        eqi("R20b connect to absent port returns -1", api.mb_connect(h5), -1);
        info("absent port errno={} msg=\"{s}\"", .{ api.mb_get_last_errno(), std.mem.span(api.mb_get_last_error_str()) });
        api.mb_free(h5);
    }

    // 非法校验位 / 波特率
    const h6 = api.mb_new_rtu(com.ptr, -1, 'N', 8, 1);
    if (h6 != null) {
        eqi("R21 negative baud connect rejected", api.mb_connect(h6), -1);
        api.mb_free(h6);
    } else ok(true, "R21 negative baud handle rejected");
}

// ---------------------------------------------------------------------------
// 32 位 DLL 架构隔离验证
// ---------------------------------------------------------------------------
fn archSuite() void {
    section("Architecture isolation");
    // 与主 DLL 一样不写死工作目录：依次尝试裸文件名（加载器先搜 exe 目录）、
    // 仓库根相对路径、从 zig-out/bin 运行时的相对路径
    const candidates = [_][:0]const u8{
        "libmodbus-x86.dll",
        "zig-out/bin/libmodbus-x86.dll",
        "..\\..\\zig-out\\bin\\libmodbus-x86.dll",
    };
    var saw_missing = false;
    for (candidates) |p| {
        if (Lib.open(p)) |lib| {
            var l = lib;
            l.close();
            std.debug.print("  [INFO] 32-bit DLL loaded inside 64-bit process (unexpected): {s}\n", .{p});
            g_skip += 1;
            return;
        }
        const err = GetLastError();
        if (err == 193) { // ERROR_BAD_EXE_FORMAT：架构不匹配，符合预期
            info("x64 process rejects 32-bit DLL (ERROR_BAD_EXE_FORMAT): {s}", .{p});
            g_pass += 1;
            return;
        }
        if (err == 126) saw_missing = true; // ERROR_MOD_NOT_FOUND
    }
    if (saw_missing) {
        skip("libmodbus-x86.dll not found next to exe or in zig-out/bin", .{});
    } else {
        skip("x86 DLL architecture check inconclusive", .{});
    }
}

// ---------------------------------------------------------------------------
pub fn main() !void {
    const com: [:0]const u8 = "COM1";

    std.debug.print("winmodbus real-device test harness\n", .{});
    info("zig {s}, builtin arch={s}, os={s}", .{ @import("builtin").zig_version_string, @tagName(@import("builtin").cpu.arch), @tagName(@import("builtin").os.tag) });

    section("Export table check");
    const loaded = loadDllAuto() orelse {
        std.debug.print("  [FAIL] cannot load libmodbus-x64.dll (searched exe dir, cwd, zig-out/bin), GetLastError={}\n", .{GetLastError()});
        std.process.exit(2);
    };
    var lib = loaded.lib;
    defer lib.close();
    info("DLL: {s}", .{loaded.path});

    var missing: u32 = 0;
    for (export_names) |name| {
        if (GetProcAddress(lib.h, name.ptr) == null) {
            std.debug.print("  [MISSING] {s}\n", .{name});
            missing += 1;
        }
    }
    eqi("all documented exports present", missing, 0);
    info("checked {} exports", .{export_names.len});

    var api = loadApi(&lib);

    tcpSuite(&api);
    rtuSuite(&api, com);
    archSuite();

    section("Summary");
    std.debug.print("  PASS={} FAIL={} SKIP={}\n", .{ g_pass, g_fail, g_skip });
    if (g_fail > 0) std.process.exit(1);
    std.debug.print("  RESULT: ALL CHECKS PASSED\n", .{});
}
