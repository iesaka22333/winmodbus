const std = @import("std");
const c = @import("c");

const allocator = std.heap.c_allocator;

// ============================================================================
// 零依赖 Windows 原生临界区互斥锁 (免疫 Zig 标准库版本变动，跨线程安全)
// ============================================================================
extern "kernel32" fn InitializeCriticalSection(lpCriticalSection: *CRITICAL_SECTION) callconv(.winapi) void;
extern "kernel32" fn EnterCriticalSection(lpCriticalSection: *CRITICAL_SECTION) callconv(.winapi) void;
extern "kernel32" fn LeaveCriticalSection(lpCriticalSection: *CRITICAL_SECTION) callconv(.winapi) void;
extern "kernel32" fn DeleteCriticalSection(lpCriticalSection: *CRITICAL_SECTION) callconv(.winapi) void;

const CRITICAL_SECTION = extern struct {
    DebugInfo: ?*anyopaque = null,
    LockCount: i32 = 0,
    RecursionCount: i32 = 0,
    OwningThread: ?*anyopaque = null,
    LockSemaphore: ?*anyopaque = null,
    SpinCount: usize = 0,
};

const WinMutex = struct {
    cs: CRITICAL_SECTION = .{},
    pub fn init(self: *WinMutex) void {
        InitializeCriticalSection(&self.cs);
    }
    pub fn deinit(self: *WinMutex) void {
        DeleteCriticalSection(&self.cs);
    }
    pub fn lock(self: *WinMutex) void {
        EnterCriticalSection(&self.cs);
    }
    pub fn unlock(self: *WinMutex) void {
        LeaveCriticalSection(&self.cs);
    }
};

/// 导出给外部持有的不透明句柄结构
pub const ModbusHandle = struct {
    ctx: *c.modbus_t,
    mutex: WinMutex = .{},
    mapping: ?*c.modbus_mapping_t = null,
    tcp_listen_sock: c_int = -1,
    is_closing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// 原子地取走并关闭 TCP 从站监听 socket，避免并发重复关闭同一句柄
fn closeListenSocket(handle: *ModbusHandle) void {
    const sock = @atomicRmw(c_int, &handle.tcp_listen_sock, .Xchg, -1, .acq_rel);
    if (sock != -1) {
        _ = c.closesocket(@bitCast(@as(isize, sock)));
    }
}

/// 内部辅助：为新创建的上下文应用井下工业级默认参数
fn applyIndustrialDefaults(ctx: *c.modbus_t) void {
    // 1. 默认响应超时设为 200ms，防止单台从机掉线卡死轮询线程
    _ = c.modbus_set_response_timeout(ctx, 0, 200_000);
    // 2. 默认字节间超时设为 20ms，应对长距离 RS-485 偶发断帧
    _ = c.modbus_set_byte_timeout(ctx, 0, 20_000);
    // 3. 开启链路层(自动重连) + 协议层(自动清空脏数据)错误恢复
    _ = c.modbus_set_error_recovery(
        ctx,
        c.MODBUS_ERROR_RECOVERY_LINK | c.MODBUS_ERROR_RECOVERY_PROTOCOL,
    );
}

// ============================================================================
// 一、 上下文创建、连接管理与基础配置 (TCP & RTU)
// ============================================================================

export fn mb_new_tcp(ip: [*:0]const u8, port: c_int) ?*ModbusHandle {
    const ctx = c.modbus_new_tcp(ip, port) orelse return null;
    applyIndustrialDefaults(ctx);
    const handle = allocator.create(ModbusHandle) catch {
        c.modbus_free(ctx);
        return null;
    };
    handle.* = .{ .ctx = ctx };
    handle.mutex.init();
    return handle;
}

export fn mb_new_rtu(port_name: [*:0]const u8, baud: c_int, parity: u8, data_bit: c_int, stop_bit: c_int) ?*ModbusHandle {
    const raw_slice = std.mem.span(port_name);
    var path_buf: [64]u8 = undefined;
    var final_port: [*:0]const u8 = port_name;

    // 只要是 "COMx" 开头 (无论是 COM1 还是 COM128)，统一补全 "\\.\COMx"，彻底杜绝 Win32 串口名兼容问题
    if (raw_slice.len >= 4 and raw_slice.len < 58 and std.ascii.startsWithIgnoreCase(raw_slice, "COM")) {
        const prefix = "\\\\.\\";
        @memcpy(path_buf[0..prefix.len], prefix);
        @memcpy(path_buf[prefix.len .. prefix.len + raw_slice.len], raw_slice);
        path_buf[prefix.len + raw_slice.len] = 0;
        final_port = @ptrCast(&path_buf);
    }

    const ctx = c.modbus_new_rtu(final_port, baud, parity, data_bit, stop_bit) orelse return null;
    applyIndustrialDefaults(ctx);
    const handle = allocator.create(ModbusHandle) catch {
        c.modbus_free(ctx);
        return null;
    };
    handle.* = .{ .ctx = ctx };
    handle.mutex.init();
    return handle;
}

export fn mb_connect(h: ?*ModbusHandle) c_int {
    const handle = h orelse return -1;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    return c.modbus_connect(handle.ctx);
}

export fn mb_close(h: ?*ModbusHandle) void {
    const handle = h orelse return;
    handle.is_closing.store(true, .release);
    // 先关闭底层串口/Socket以打断可能正在阻塞的 modbus_receive
    c.modbus_close(handle.ctx);
    // TCP 从站的监听 socket 独立于会话 socket，同样关闭以打断阻塞的 accept 并释放端口
    closeListenSocket(handle);
    handle.mutex.lock();
    defer handle.mutex.unlock();
    handle.is_closing.store(false, .release);
}

export fn mb_free(h: ?*ModbusHandle) void {
    const handle = h orelse return;
    handle.is_closing.store(true, .release);

    closeListenSocket(handle);
    // 提前 close 唤醒任何阻塞在 receive 上的后台从站线程
    c.modbus_close(handle.ctx);

    handle.mutex.lock();
    if (handle.mapping) |map| {
        c.modbus_mapping_free(map);
        handle.mapping = null;
    }
    c.modbus_free(handle.ctx);
    handle.mutex.unlock();

    handle.mutex.deinit();
    allocator.destroy(handle);
}

export fn mb_set_slave(h: ?*ModbusHandle, slave_id: c_int) c_int {
    const handle = h orelse return -1;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    return c.modbus_set_slave(handle.ctx, slave_id);
}

export fn mb_get_slave(h: ?*ModbusHandle) c_int {
    const handle = h orelse return -1;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    return c.modbus_get_slave(handle.ctx);
}

export fn mb_set_timeout_ms(h: ?*ModbusHandle, response_ms: u32, byte_ms: u32) c_int {
    const handle = h orelse return -1;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const r1 = c.modbus_set_response_timeout(handle.ctx, response_ms / 1000, (response_ms % 1000) * 1000);
    const r2 = c.modbus_set_byte_timeout(handle.ctx, byte_ms / 1000, (byte_ms % 1000) * 1000);
    return if (r1 == 0 and r2 == 0) 0 else -1;
}

export fn mb_set_auto_recovery(h: ?*ModbusHandle, enable_auto_reconnect: c_int) c_int {
    const handle = h orelse return -1;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const mode: c_uint = if (enable_auto_reconnect != 0)
        (c.MODBUS_ERROR_RECOVERY_LINK | c.MODBUS_ERROR_RECOVERY_PROTOCOL)
    else
        c.MODBUS_ERROR_RECOVERY_NONE;
    return c.modbus_set_error_recovery(handle.ctx, mode);
}

export fn mb_set_debug(h: ?*ModbusHandle, flag: c_int) c_int {
    const handle = h orelse return -1;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    return c.modbus_set_debug(handle.ctx, flag);
}

export fn mb_flush(h: ?*ModbusHandle) c_int {
    const handle = h orelse return -1;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    return c.modbus_flush(handle.ctx);
}

// ============================================================================
// 二、 RS-485 硬件流控与方向引脚配置
// ============================================================================

export fn mb_rtu_set_serial_mode(h: ?*ModbusHandle, mode: c_int) c_int {
    const handle = h orelse return -1;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    return c.modbus_rtu_set_serial_mode(handle.ctx, mode);
}

export fn mb_rtu_set_rts(h: ?*ModbusHandle, mode: c_int) c_int {
    const handle = h orelse return -1;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    return c.modbus_rtu_set_rts(handle.ctx, mode);
}

export fn mb_rtu_set_rts_delay(h: ?*ModbusHandle, us: c_int) c_int {
    const handle = h orelse return -1;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    return c.modbus_rtu_set_rts_delay(handle.ctx, us);
}

// ============================================================================
// 三、 错误码与诊断信息获取
// ============================================================================

export fn mb_get_last_errno() c_int {
    return c._errno().*;
}

export fn mb_get_last_error_str() [*:0]const u8 {
    return c.modbus_strerror(c._errno().*);
}

// ============================================================================
// 四、 主站 (Master / Client) 全套标准读写功能码
// ============================================================================

export fn mb_read_bits(h: ?*ModbusHandle, addr: c_int, nb: c_int, dest: [*]u8) c_int {
    const handle = h orelse return -1;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    return c.modbus_read_bits(handle.ctx, addr, nb, dest);
}

export fn mb_read_input_bits(h: ?*ModbusHandle, addr: c_int, nb: c_int, dest: [*]u8) c_int {
    const handle = h orelse return -1;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    return c.modbus_read_input_bits(handle.ctx, addr, nb, dest);
}

export fn mb_read_registers(h: ?*ModbusHandle, addr: c_int, nb: c_int, dest: [*]u16) c_int {
    const handle = h orelse return -1;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    return c.modbus_read_registers(handle.ctx, addr, nb, dest);
}

export fn mb_read_input_registers(h: ?*ModbusHandle, addr: c_int, nb: c_int, dest: [*]u16) c_int {
    const handle = h orelse return -1;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    return c.modbus_read_input_registers(handle.ctx, addr, nb, dest);
}

export fn mb_write_bit(h: ?*ModbusHandle, coil_addr: c_int, status: c_int) c_int {
    const handle = h orelse return -1;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    return c.modbus_write_bit(handle.ctx, coil_addr, status);
}

export fn mb_write_register(h: ?*ModbusHandle, addr: c_int, value: u16) c_int {
    const handle = h orelse return -1;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    return c.modbus_write_register(handle.ctx, addr, value);
}

export fn mb_write_bits(h: ?*ModbusHandle, addr: c_int, nb: c_int, data: [*]const u8) c_int {
    const handle = h orelse return -1;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    return c.modbus_write_bits(handle.ctx, addr, nb, data);
}

export fn mb_write_registers(h: ?*ModbusHandle, addr: c_int, nb: c_int, src: [*]const u16) c_int {
    const handle = h orelse return -1;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    return c.modbus_write_registers(handle.ctx, addr, nb, src);
}

export fn mb_mask_write_register(h: ?*ModbusHandle, addr: c_int, and_mask: u16, or_mask: u16) c_int {
    const handle = h orelse return -1;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    return c.modbus_mask_write_register(handle.ctx, addr, and_mask, or_mask);
}

export fn mb_write_and_read_registers(
    h: ?*ModbusHandle,
    write_addr: c_int,
    write_nb: c_int,
    src: [*]const u16,
    read_addr: c_int,
    read_nb: c_int,
    dest: [*]u16,
) c_int {
    const handle = h orelse return -1;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    return c.modbus_write_and_read_registers(handle.ctx, write_addr, write_nb, src, read_addr, read_nb, dest);
}

export fn mb_report_slave_id(h: ?*ModbusHandle, max_dest: c_int, dest: [*]u8) c_int {
    const handle = h orelse return -1;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    return c.modbus_report_slave_id(handle.ctx, max_dest, dest);
}

export fn mb_send_raw_and_receive(h: ?*ModbusHandle, raw_req: [*]const u8, req_len: c_int, rsp_buf: [*]u8) c_int {
    const handle = h orelse return -1;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    if (c.modbus_send_raw_request(handle.ctx, raw_req, req_len) == -1) return -1;
    return c.modbus_receive_confirmation(handle.ctx, rsp_buf);
}

// ============================================================================
// 五、 从站 (Slave / Server) 内存四区管理与监听应答
// ============================================================================

export fn mb_slave_init_mapping_ex(
    h: ?*ModbusHandle,
    start_bits: c_int,
    nb_bits: c_int,
    start_input_bits: c_int,
    nb_input_bits: c_int,
    start_registers: c_int,
    nb_registers: c_int,
    start_input_registers: c_int,
    nb_input_registers: c_int,
) c_int {
    if (nb_bits < 0 or nb_input_bits < 0 or nb_registers < 0 or nb_input_registers < 0 or
        start_bits < 0 or start_input_bits < 0 or start_registers < 0 or start_input_registers < 0) return -1;
    const handle = h orelse return -1;
    handle.mutex.lock();
    defer handle.mutex.unlock();

    if (handle.mapping) |old_map| {
        c.modbus_mapping_free(old_map);
        handle.mapping = null; // 防止新表创建失败后留下悬空指针
    }
    const map = c.modbus_mapping_new_start_address(
        @intCast(start_bits),
        @intCast(nb_bits),
        @intCast(start_input_bits),
        @intCast(nb_input_bits),
        @intCast(start_registers),
        @intCast(nb_registers),
        @intCast(start_input_registers),
        @intCast(nb_input_registers),
    ) orelse return -1;
    handle.mapping = map;
    return 0;
}

export fn mb_slave_init_mapping(h: ?*ModbusHandle, nb_bits: c_int, nb_input_bits: c_int, nb_registers: c_int, nb_input_registers: c_int) c_int {
    return mb_slave_init_mapping_ex(h, 0, nb_bits, 0, nb_input_bits, 0, nb_registers, 0, nb_input_registers);
}

export fn mb_slave_set_coil(h: ?*ModbusHandle, index: c_int, val: u8) c_int {
    const handle = h orelse return -1;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const map = handle.mapping orelse return -1;
    if (index < 0 or index >= map.*.nb_bits) return -1;
    map.*.tab_bits[@intCast(index)] = if (val != 0) 1 else 0;
    return 0;
}

export fn mb_slave_get_coil(h: ?*ModbusHandle, index: c_int, out_val: *u8) c_int {
    const handle = h orelse return -1;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const map = handle.mapping orelse return -1;
    if (index < 0 or index >= map.*.nb_bits) return -1;
    out_val.* = map.*.tab_bits[@intCast(index)];
    return 0;
}

export fn mb_slave_set_input_bit(h: ?*ModbusHandle, index: c_int, val: u8) c_int {
    const handle = h orelse return -1;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const map = handle.mapping orelse return -1;
    if (index < 0 or index >= map.*.nb_input_bits) return -1;
    map.*.tab_input_bits[@intCast(index)] = if (val != 0) 1 else 0;
    return 0;
}

export fn mb_slave_get_input_bit(h: ?*ModbusHandle, index: c_int, out_val: *u8) c_int {
    const handle = h orelse return -1;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const map = handle.mapping orelse return -1;
    if (index < 0 or index >= map.*.nb_input_bits) return -1;
    out_val.* = map.*.tab_input_bits[@intCast(index)];
    return 0;
}

export fn mb_slave_set_holding_reg(h: ?*ModbusHandle, index: c_int, value: u16) c_int {
    const handle = h orelse return -1;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const map = handle.mapping orelse return -1;
    if (index < 0 or index >= map.*.nb_registers) return -1;
    map.*.tab_registers[@intCast(index)] = value;
    return 0;
}

export fn mb_slave_get_holding_reg(h: ?*ModbusHandle, index: c_int, out_val: *u16) c_int {
    const handle = h orelse return -1;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const map = handle.mapping orelse return -1;
    if (index < 0 or index >= map.*.nb_registers) return -1;
    out_val.* = map.*.tab_registers[@intCast(index)];
    return 0;
}

export fn mb_slave_set_input_reg(h: ?*ModbusHandle, index: c_int, value: u16) c_int {
    const handle = h orelse return -1;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const map = handle.mapping orelse return -1;
    if (index < 0 or index >= map.*.nb_input_registers) return -1;
    map.*.tab_input_registers[@intCast(index)] = value;
    return 0;
}

export fn mb_slave_get_input_reg(h: ?*ModbusHandle, index: c_int, out_val: *u16) c_int {
    const handle = h orelse return -1;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const map = handle.mapping orelse return -1;
    if (index < 0 or index >= map.*.nb_input_registers) return -1;
    out_val.* = map.*.tab_input_registers[@intCast(index)];
    return 0;
}

export fn mb_slave_set_holding_regs_bulk(h: ?*ModbusHandle, start_index: c_int, count: c_int, src: [*]const u16) c_int {
    const handle = h orelse return -1;
    if (start_index < 0 or count <= 0) return -1;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const map = handle.mapping orelse return -1;
    // 用减法比较，避免 start_index + count 在 c_int 上溢出绕过越界检查
    if (start_index >= map.*.nb_registers or count > map.*.nb_registers - start_index) return -1;
    const u_start: usize = @intCast(start_index);
    const u_count: usize = @intCast(count);
    @memcpy(map.*.tab_registers[u_start .. u_start + u_count], src[0..u_count]);
    return 0;
}

export fn mb_slave_get_holding_regs_bulk(h: ?*ModbusHandle, start_index: c_int, count: c_int, dest: [*]u16) c_int {
    const handle = h orelse return -1;
    if (start_index < 0 or count <= 0) return -1;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const map = handle.mapping orelse return -1;
    if (start_index >= map.*.nb_registers or count > map.*.nb_registers - start_index) return -1;
    const u_start: usize = @intCast(start_index);
    const u_count: usize = @intCast(count);
    @memcpy(dest[0..u_count], map.*.tab_registers[u_start .. u_start + u_count]);
    return 0;
}

export fn mb_slave_set_input_regs_bulk(h: ?*ModbusHandle, start_index: c_int, count: c_int, src: [*]const u16) c_int {
    const handle = h orelse return -1;
    if (start_index < 0 or count <= 0) return -1;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const map = handle.mapping orelse return -1;
    if (start_index >= map.*.nb_input_registers or count > map.*.nb_input_registers - start_index) return -1;
    const u_start: usize = @intCast(start_index);
    const u_count: usize = @intCast(count);
    @memcpy(map.*.tab_input_registers[u_start .. u_start + u_count], src[0..u_count]);
    return 0;
}

export fn mb_slave_get_input_regs_bulk(h: ?*ModbusHandle, start_index: c_int, count: c_int, dest: [*]u16) c_int {
    const handle = h orelse return -1;
    if (start_index < 0 or count <= 0) return -1;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const map = handle.mapping orelse return -1;
    if (start_index >= map.*.nb_input_registers or count > map.*.nb_input_registers - start_index) return -1;
    const u_start: usize = @intCast(start_index);
    const u_count: usize = @intCast(count);
    @memcpy(dest[0..u_count], map.*.tab_input_registers[u_start .. u_start + u_count]);
    return 0;
}

/// TCP 从站专用：监听端口并等待接收一个主站连接 (支持客户端断开后再次调用以重连)
export fn mb_tcp_slave_listen_and_accept(h: ?*ModbusHandle, nb_connection: c_int) c_int {
    const handle = h orelse return -1;
    if (handle.is_closing.load(.acquire)) return -1;

    // 首次调用创建监听 Socket；后续客户端断开重连时直接复用监听端口
    if (handle.tcp_listen_sock == -1) {
        const sock = c.modbus_tcp_listen(handle.ctx, nb_connection);
        if (sock == -1) return -1;
        handle.tcp_listen_sock = sock;
    } else {
        // 关闭上一次已断开的客户端会话 socket，准备 accept 新连接
        c.modbus_close(handle.ctx);
    }
    return c.modbus_tcp_accept(handle.ctx, &handle.tcp_listen_sock);
}

/// 从站轮询核心：接收一帧请求并自动回复
export fn mb_slave_poll_once(h: ?*ModbusHandle) c_int {
    const handle = h orelse return -1;
    if (handle.is_closing.load(.acquire)) return -1;

    // 仅检查映射表是否已初始化；不保存指针，避免阻塞期间被重新初始化后悬空
    {
        handle.mutex.lock();
        defer handle.mutex.unlock();
        if (handle.mapping == null) return -1;
    }

    var query: [c.MODBUS_MAX_ADU_LENGTH]u8 = undefined;
    // 接收不能持锁，否则会阻塞其他线程对同一句柄的所有调用
    const rc = c.modbus_receive(handle.ctx, &query);
    if (rc > 0 and !handle.is_closing.load(.acquire)) {
        handle.mutex.lock();
        defer handle.mutex.unlock();
        // 在锁内重新取映射表，拿到的一定是当前有效的
        const map = handle.mapping orelse return -1;
        return c.modbus_reply(handle.ctx, &query, rc, map);
    }
    return rc;
}

export fn mb_slave_receive_raw(h: ?*ModbusHandle, req_buf: [*]u8) c_int {
    const handle = h orelse return -1;
    if (handle.is_closing.load(.acquire)) return -1;
    return c.modbus_receive(handle.ctx, req_buf);
}

export fn mb_slave_reply_normal(h: ?*ModbusHandle, req_buf: [*]const u8, req_len: c_int) c_int {
    const handle = h orelse return -1;
    if (handle.is_closing.load(.acquire)) return -1;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const map = handle.mapping orelse return -1;
    return c.modbus_reply(handle.ctx, req_buf, req_len, map);
}

export fn mb_slave_reply_exception(h: ?*ModbusHandle, req_buf: [*]const u8, exception_code: c_uint) c_int {
    const handle = h orelse return -1;
    if (handle.is_closing.load(.acquire)) return -1;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    return c.modbus_reply_exception(handle.ctx, req_buf, exception_code);
}

// ============================================================================
// 六、 工业现场数据转换工具箱
// ============================================================================

export fn mb_get_float_abcd(src: [*]const u16) f32 {
    return c.modbus_get_float_abcd(src);
}
export fn mb_get_float_dcba(src: [*]const u16) f32 {
    return c.modbus_get_float_dcba(src);
}
export fn mb_get_float_badc(src: [*]const u16) f32 {
    return c.modbus_get_float_badc(src);
}
export fn mb_get_float_cdab(src: [*]const u16) f32 {
    return c.modbus_get_float_cdab(src);
}

export fn mb_set_float_abcd(f: f32, dest: [*]u16) void {
    c.modbus_set_float_abcd(f, dest);
}
export fn mb_set_float_dcba(f: f32, dest: [*]u16) void {
    c.modbus_set_float_dcba(f, dest);
}
export fn mb_set_float_badc(f: f32, dest: [*]u16) void {
    c.modbus_set_float_badc(f, dest);
}
export fn mb_set_float_cdab(f: f32, dest: [*]u16) void {
    c.modbus_set_float_cdab(f, dest);
}

export fn mb_get_int32_abcd(src: [*]const u16) i32 {
    const hi: u32 = src[0];
    const lo: u32 = src[1];
    return @bitCast((hi << 16) | lo);
}

export fn mb_set_int32_abcd(val: i32, dest: [*]u16) void {
    const u: u32 = @bitCast(val);
    dest[0] = @intCast((u >> 16) & 0xFFFF);
    dest[1] = @intCast(u & 0xFFFF);
}

export fn mb_get_int32_cdab(src: [*]const u16) i32 {
    const lo: u32 = src[0];
    const hi: u32 = src[1];
    return @bitCast((hi << 16) | lo);
}

export fn mb_set_int32_cdab(val: i32, dest: [*]u16) void {
    const u: u32 = @bitCast(val);
    dest[0] = @intCast(u & 0xFFFF);
    dest[1] = @intCast((u >> 16) & 0xFFFF);
}

// ============================================================================
// 七、 原始寄存器取用函数（兼容老项目：不做任何字节序/浮点解释）
// ----------------------------------------------------------------------------
// 这些函数只做「按下标取一个 16 位寄存器的原值」或「按下标组合两个相邻
// 16 位寄存器」，不涉及浮点解释，也不校验下标之外的内容。典型用法：
//     var r: [4]u16 = undefined;
//     if (mb_read_registers(h, 0, 4, &r) == 4) {
//         const temp_raw = mb_get_reg_i16(&r, 0);   // 有符号 16 位原值
//         const humi_raw = mb_get_reg_u16(&r, 1);   // 无符号 16 位原值
//         const total_lo = mb_get_reg_u16(&r, 2);
//     }
// index 越界不做检查（与 C 端语义一致），由调用方保证 index 在数组范围内。
// ============================================================================

/// 取单个 16 位寄存器原值（无符号），index 为数组下标（从 0 起）
export fn mb_get_reg_u16(src: [*]const u16, index: c_int) u16 {
    if (index < 0) return 0;
    return src[@intCast(index)];
}

/// 取单个 16 位寄存器原值（有符号 int16），用于负温度等场景
export fn mb_get_reg_i16(src: [*]const u16, index: c_int) i16 {
    if (index < 0) return 0;
    return @bitCast(src[@intCast(index)]);
}

/// 把单个 16 位值写入寄存器数组指定下标
export fn mb_put_reg_u16(value: u16, dest: [*]u16, index: c_int) void {
    if (index < 0) return;
    dest[@intCast(index)] = value;
}

/// 从左索引起始的两个相邻寄存器组合成无符号 32 位（高字在低地址，ABCD 语义）
export fn mb_get_reg_u32_abcd(src: [*]const u16, index: c_int) u32 {
    if (index < 0) return 0;
    const i: usize = @intCast(index);
    const hi: u32 = src[i];
    const lo: u32 = src[i + 1];
    return (hi << 16) | lo;
}

/// 从左索引起始的两个相邻寄存器组合成有符号 32 位（高字在低地址）
export fn mb_get_reg_i32_abcd(src: [*]const u16, index: c_int) i32 {
    return @bitCast(mb_get_reg_u32_abcd(src, index));
}

/// 从左索引起始的两个相邻寄存器组合成无符号 32 位（低字在低地址，CDAB 语义）
export fn mb_get_reg_u32_cdab(src: [*]const u16, index: c_int) u32 {
    if (index < 0) return 0;
    const i: usize = @intCast(index);
    const lo: u32 = src[i];
    const hi: u32 = src[i + 1];
    return (hi << 16) | lo;
}

/// 从左索引起始的两个相邻寄存器组合成有符号 32 位（低字在低地址）
export fn mb_get_reg_i32_cdab(src: [*]const u16, index: c_int) i32 {
    return @bitCast(mb_get_reg_u32_cdab(src, index));
}
