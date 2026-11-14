// 极简 PE 导出表解析器：打印 DLL 的导出函数名（用于跨版本比对）
// 用法: pe_exports.exe <dll路径>
const std = @import("std");

const PeError = error{ BadPe, ReadFailed, OpenFailed, ReadError };

const GENERIC_READ = 0x80000000;
const OPEN_EXISTING = 3;
const INVALID_HANDLE: *anyopaque = @ptrFromInt(std.math.maxInt(usize));

extern "kernel32" fn CreateFileA(
    lpFileName: [*:0]const u8,
    dwDesiredAccess: u32,
    dwShareMode: u32,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: u32,
    dwFlagsAndAttributes: u32,
    hTemplateFile: ?*anyopaque,
) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn ReadFile(
    hFile: *anyopaque,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: u32,
    lpNumberOfBytesRead: ?*u32,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) c_int;
extern "kernel32" fn GetFileSizeEx(hFile: *anyopaque, lpFileSize: *i64) callconv(.winapi) c_int;
extern "kernel32" fn CloseHandle(hObject: *anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn WriteFile(
    hFile: *anyopaque,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: u32,
    lpNumberOfBytesWritten: ?*u32,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) c_int;
extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(.winapi) ?*anyopaque;

fn stdoutPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    var written: u32 = 0;
    _ = WriteFile(GetStdHandle(0xFFFFFFF5) orelse return, s.ptr, @intCast(s.len), &written, null);
}

extern "kernel32" fn GetLastError() callconv(.winapi) u32;

fn u16at(d: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, d[off..][0..2], .little);
}
fn u32at(d: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, d[off..][0..4], .little);
}

pub fn main() !void {
    // Zig 0.17 移除了 std.process.argsAlloc，直接从命令行解析（路径中不含空格）
    const cmd = std.os.windows.peb().ProcessParameters.CommandLine;
    const wptr = cmd.Buffer orelse {
        std.debug.print("usage: pe_exports <dll>\n", .{});
        std.process.exit(2);
    };
    const wcmd = wptr[0 .. cmd.Length / 2];
    // 命令行第 0 个 token 是 exe 自身路径（可能带引号），第 1 个才是目标 DLL
    var path_buf: [512]u8 = undefined;
    var n: usize = 0;
    var seen_exe = false;
    var in_quotes = false;
    var i: usize = 0;
    while (i < wcmd.len) : (i += 1) {
        const ch: u8 = @truncate(wcmd[i]);
        if (!seen_exe) {
            if (ch == '"') in_quotes = !in_quotes;
            if (!in_quotes and (ch == ' ' or ch == '\t')) {
                seen_exe = true;
                in_quotes = false;
            }
            continue;
        }
        if (ch == '"') {
            in_quotes = !in_quotes;
            continue;
        }
        if (!in_quotes and (ch == ' ' or ch == '\t')) {
            if (n > 0) break;
            continue;
        }
        if (n < path_buf.len - 1) {
            path_buf[n] = ch;
            n += 1;
        }
    }
    if (n == 0) {
        std.debug.print("usage: pe_exports <dll>\n", .{});
        std.process.exit(2);
    }
    path_buf[n] = 0;
    const hfile = CreateFileA(@ptrCast(&path_buf), GENERIC_READ, 1, null, OPEN_EXISTING, 0, null) orelse return PeError.OpenFailed;
    if (hfile == INVALID_HANDLE) {
        std.debug.print("GetLastError={d} path={s}\n", .{ GetLastError(), path_buf[0..n] });
        return PeError.OpenFailed;
    }
    defer _ = CloseHandle(hfile);
    var fsize: i64 = 0;
    if (GetFileSizeEx(hfile, &fsize) == 0) return PeError.OpenFailed;
    const data = try std.heap.page_allocator.alloc(u8, @intCast(fsize));
    defer std.heap.page_allocator.free(data);
    var got: u32 = 0;
    if (ReadFile(hfile, data.ptr, @intCast(data.len), &got, null) == 0) return PeError.ReadError;
    if (got != data.len) return PeError.ReadError;

    if (data.len < 0x40 or data[0] != 'M' or data[1] != 'Z') return PeError.BadPe;
    const pe_off: usize = u32at(data, 0x3C);
    if (pe_off + 24 > data.len) return PeError.BadPe;
    if (!std.mem.eql(u8, data[pe_off .. pe_off + 4], "PE\x00\x00")) return PeError.BadPe;
    const coff = pe_off + 4;
    const nsections = u16at(data, coff + 2);
    const opt_size = u16at(data, coff + 16);
    const opt = coff + 20;
    const magic = u16at(data, opt);
    const dd_off: usize = if (magic == 0x20B) opt + 112 else opt + 96;
    const exp_rva = u32at(data, dd_off);
    if (exp_rva == 0) {
        std.debug.print("no export table\n", .{});
        return;
    }

    const sect = opt + opt_size;
    var si: usize = 0;
    var base: usize = 0;
    while (si < nsections) : (si += 1) {
        const s = sect + si * 40;
        const vsize = u32at(data, s + 8);
        const vaddr = u32at(data, s + 12);
        const raw = u32at(data, s + 20);
        if (exp_rva >= vaddr and exp_rva < vaddr + vsize) {
            base = raw + (exp_rva - vaddr);
            break;
        }
    }
    if (base == 0) return PeError.BadPe;

    const n_names = u32at(data, base + 24);
    const names_rva = u32at(data, base + 32);
    // 名字表所在节
    si = 0;
    var nbase: usize = 0;
    while (si < nsections) : (si += 1) {
        const s = sect + si * 40;
        const vsize = u32at(data, s + 8);
        const vaddr = u32at(data, s + 12);
        const raw = u32at(data, s + 20);
        if (names_rva >= vaddr and names_rva < vaddr + vsize) {
            nbase = raw + (names_rva - vaddr);
            break;
        }
    }

    stdoutPrint("count={d}\n", .{n_names});
    var k: usize = 0;
    while (k < n_names) : (k += 1) {
        const name_rva = u32at(data, nbase + k * 4);
        var pos: usize = 0;
        var sj: usize = 0;
        while (sj < nsections) : (sj += 1) {
            const s = sect + sj * 40;
            const vsize = u32at(data, s + 8);
            const vaddr = u32at(data, s + 12);
            const raw = u32at(data, s + 20);
            if (name_rva >= vaddr and name_rva < vaddr + vsize) {
                pos = raw + (name_rva - vaddr);
                break;
            }
        }
        if (pos == 0) continue;
        const end = std.mem.indexOfScalarPos(u8, data, pos, 0) orelse continue;
        stdoutPrint("{s}\n", .{data[pos..end]});
    }
}
