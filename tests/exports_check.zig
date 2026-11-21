// ============================================================================
// 交付产物静态检查（不加载 DLL、不需要串口/网络等真实硬件）
//
// 用法：exports_check <dll路径> <x64|x86> [<dll路径> <x64|x86> ...]
//
// 检查项：
//   1. 文件是合法的 PE 动态库，且 Machine 字段与声明的架构一致；
//   2. 导出表恰好包含 README 承诺的 66 个函数，无缺失。
//
// 由 `zig build test` 调用（见 build.zig），可直接用于 CI。
// ============================================================================
const std = @import("std");

const expected_exports = [_][]const u8{
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

const machine_x64: u16 = 0x8664;
const machine_x86: u16 = 0x14c;

const PeError = error{ BadPe, MissingExport, WrongArch, WrongExportCount };

const Pe = struct {
    data: []const u8,

    fn u16at(self: Pe, off: usize) u16 {
        return std.mem.readInt(u16, self.data[off..][0..2], .little);
    }

    fn u32at(self: Pe, off: usize) u32 {
        return std.mem.readInt(u32, self.data[off..][0..4], .little);
    }

    fn rvaToOffset(self: Pe, nsections: usize, section_table: usize, rva: u32) ?usize {
        var i: usize = 0;
        while (i < nsections) : (i += 1) {
            const s = section_table + i * 40;
            const vsize = self.u32at(s + 8);
            const vaddr = self.u32at(s + 12);
            const raw = self.u32at(s + 20);
            if (rva >= vaddr and rva < vaddr + vsize) return raw + (rva - vaddr);
        }
        return null;
    }

    fn machine(self: Pe) u16 {
        const pe_off = self.u32at(0x3C);
        return self.u16at(pe_off + 4);
    }

    fn exportNames(self: Pe, gpa: std.mem.Allocator, names: *std.ArrayList([]const u8)) !void {
        if (self.data.len < 0x40 or self.data[0] != 'M' or self.data[1] != 'Z') return PeError.BadPe;
        const pe_off: usize = self.u32at(0x3C);
        if (pe_off + 24 > self.data.len) return PeError.BadPe;
        if (!std.mem.eql(u8, self.data[pe_off .. pe_off + 4], "PE\x00\x00")) return PeError.BadPe;

        const coff = pe_off + 4;
        const nsections = self.u16at(coff + 2);
        const opt_size = self.u16at(coff + 16);
        const opt = coff + 20;
        const magic = self.u16at(opt);
        const dd_off: usize = if (magic == 0x20B) opt + 112 else opt + 96;
        const exp_rva = self.u32at(dd_off);
        if (exp_rva == 0) return PeError.BadPe;

        const section_table = opt + opt_size;
        const exp = self.rvaToOffset(nsections, section_table, exp_rva) orelse return PeError.BadPe;
        const n_names = self.u32at(exp + 24);
        const names_rva = self.u32at(exp + 32);
        const names_base = self.rvaToOffset(nsections, section_table, names_rva) orelse return PeError.BadPe;

        var i: usize = 0;
        while (i < n_names) : (i += 1) {
            const name_rva = self.u32at(names_base + i * 4);
            const pos = self.rvaToOffset(nsections, section_table, name_rva) orelse continue;
            const end = std.mem.indexOfScalarPos(u8, self.data, pos, 0) orelse continue;
            try names.append(gpa, self.data[pos..end]);
        }
    }
};

fn checkDll(io: std.Io, gpa: std.mem.Allocator, path: []const u8, arch: []const u8) !void {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(data);

    const pe = Pe{ .data = data };
    const expected_machine: u16 = if (std.mem.eql(u8, arch, "x64")) machine_x64 else machine_x86;
    const actual_machine = pe.machine();
    if (actual_machine != expected_machine) {
        std.debug.print("  [FAIL] {s}: PE machine 0x{X} != expected 0x{X} ({s})\n", .{ path, actual_machine, expected_machine, arch });
        return PeError.WrongArch;
    }

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    try pe.exportNames(gpa, &names);

    if (names.items.len != expected_exports.len) {
        std.debug.print("  [FAIL] {s}: {d} exports, expected {d}\n", .{ path, names.items.len, expected_exports.len });
        return PeError.WrongExportCount;
    }

    var missing: usize = 0;
    for (expected_exports) |expected| {
        for (names.items) |actual| {
            if (std.mem.eql(u8, actual, expected)) break;
        } else {
            std.debug.print("  [MISSING] {s}: {s}\n", .{ path, expected });
            missing += 1;
        }
    }
    if (missing != 0) return PeError.MissingExport;

    std.debug.print("  [OK] {s}: {s}, {d} exports\n", .{ path, arch, names.items.len });
}

pub fn main(init: std.process.Init) !void {
    // Windows 下命令行是 UTF-16，必须用带分配器的迭代器完成转码
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();

    var checked: usize = 0;
    var failures: usize = 0;
    while (args.next()) |path| {
        const arch = args.next() orelse {
            std.debug.print("usage: exports_check <dll> <x64|x86> [...]\n", .{});
            std.process.exit(2);
        };
        checkDll(init.io, init.gpa, path, arch) catch {
            failures += 1;
        };
        checked += 1;
    }

    if (checked == 0) {
        std.debug.print("usage: exports_check <dll> <x64|x86> [...]\n", .{});
        std.process.exit(2);
    }
    if (failures != 0) {
        std.debug.print("exports_check: {d}/{d} artifact(s) failed\n", .{ failures, checked });
        std.process.exit(1);
    }
    std.debug.print("exports_check: all {d} artifact(s) passed\n", .{checked});
}
