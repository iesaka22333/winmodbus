<div align="center">

# winmodbus

**Modbus RTU / Modbus TCP dynamic libraries for Windows — master and slave in one DLL**

Prebuilt Windows DLL modules (x86/x64) with full C ABI symbol exports for libmodbus.

[![GitHub release](https://img.shields.io/github/v/release/iesaka22333/winmodbus?style=flat-square&label=release&color=45658D)](https://github.com/iesaka22333/winmodbus/releases)
[![GitHub downloads](https://img.shields.io/github/downloads/iesaka22333/winmodbus/total?style=flat-square&color=277165)](https://github.com/iesaka22333/winmodbus/releases)
[![Platform](https://img.shields.io/badge/platform-Windows%20x86%20%7C%20x64-45658D?style=flat-square)](#download)
[![License](https://img.shields.io/badge/license-LGPL--2.1--or--later-277165?style=flat-square)](#license)

**English** · [简体中文](README.zh-CN.md)

[Download](#download) · [Quick Start](#quick-start) · [Build & Test](#build--test) · [API Reference](#api-reference) · [Usage Notes](#usage-notes) · [License](#license)

</div>

## Overview

`libmodbus-x86.dll` (32-bit) and `libmodbus-x64.dll` (64-bit) are self-contained Modbus libraries for Windows. Protocol: Modbus RTU (serial) and Modbus TCP (Ethernet). Calling convention: `cdecl`.

Each DLL supports both roles:

- **Master** — actively read and write sensors, transmitters, PLCs and other slave devices.
- **Slave** — emulate a Modbus device in local memory and answer a master's read/write requests.

Supported function codes: 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x0F, 0x10, 0x11, 0x16, 0x17. The library also exposes non-standard raw frame send/receive and helpers for converting between floats, 32-bit integers and registers. A set of **zero-interpretation raw register accessors** (`mb_get_reg_u16` / `mb_get_reg_i16` and friends, see [Raw register accessors](#raw-register-accessors)) reads 16-bit values by index for legacy projects that only need simple scaling. **66 functions are exported in total.**

### Built-in hardening

| Mechanism | Description |
| :-- | :-- |
| Thread-safe locking | A single handle can be called concurrently from multiple threads; every call is internally locked so the state cannot be corrupted. The slave ID is handle state: when several threads poll different slave IDs on one handle, the caller must lock "set slave + read/write" as one unit (see [Usage Notes](#usage-notes)). |
| Automatic reconnection | Split into link level (LINK) and protocol level (PROTOCOL), both enabled by default. Link level: after a TCP connection-level error (for example a reset caused by a flaky cable) the library closes the connection and reconnects; the call that triggered it still returns -1 and later calls recover. On Windows a serial port (RTU) is a file handle rather than a socket, so `WSAGetLastError()` never produces a Winsock error code and **serial connections are not reconnected automatically** — a failed write returns -1 directly. Protocol level: CRC errors and similar clear the residual bytes in the receive buffer. Disable both with `mb_set_auto_recovery`. |
| High-numbered COM ports | Port names such as `'COM12'` (a case-insensitive `COM` prefix) are accepted directly; the library expands them to `\\.\COM12` for you. |
| Winsock handle compatibility | On Windows a socket is a kernel handle whose value is unrelated to the POSIX `FD_SETSIZE` (64). The `FD_SETSIZE` range check is disabled so every TCP connection is not rejected as "descriptor out of range" (`errno=EINVAL`). |
| Fast default timeouts | Response timeout defaults to 200 ms and the byte timeout to 20 ms. When a device does not answer, a call usually fails within about 0.2 s (see [Timeouts and reconnection](#timeouts-and-reconnection)). Change them with `mb_set_timeout_ms`. |

## Download

### Artifacts

| Artifact | Target |
| :-- | :-- |
| `zig-out/bin/libmodbus-x86.dll` | 32-bit processes (the default target of 32-bit Delphi / C++ Builder) |
| `zig-out/bin/libmodbus-x64.dll` | 64-bit processes |
| `zig-out/lib/libmodbus-x86.lib`, `libmodbus-x64.lib` | Import libraries for tools that require one (MSVC and similar) |

All artifacts come from a single `zig build`; see [Build & Test](#build--test). Matching `.pdb` debug symbol files live in `zig-out/bin/` as well. They are useful to archive with the DLLs but are not required at deployment time.

Deploy the DLL whose bitness matches the target process, next to the executable or somewhere on the system search path. A 32-bit process cannot load a 64-bit DLL, and vice versa.

### Runtime requirements

The DLLs depend on `WS2_32.dll` and the UCRT (`api-ms-win-crt-*.dll`). Windows 10/11 ship both; Windows 7/8.1 need the VC++ 2015–2022 redistributable (or the UCRT update KB2999226) installed first.

## Quick Start

### Address convention (mandatory)

Every address parameter in this library is zero-based. The `40001` / `30001` style numbers found in device manuals are PLC labels that include a zone prefix; subtract the zone base before calling the library.

| Manual notation | Zone | Read function | Function code | Value passed as `addr` |
| :-- | :-- | :-- | :-: | :-- |
| `40001` (or `0x0000`) | 4x holding registers | `mb_read_registers` | 03 | `0` (40001 - 40001) |
| `40010` | 4x holding registers | `mb_read_registers` | 03 | `9` (40010 - 40001) |
| `30001` | 3x input registers | `mb_read_input_registers` | 04 | `0` (30001 - 30001) |
| `00001` | 0x coils (relays) | `mb_read_bits` / `mb_write_bit` | 01 / 05 | `0` (00001 - 00001) |
| `10001` | 1x discrete inputs | `mb_read_input_bits` | 02 | `0` (10001 - 10001) |

### Return values

| Function family | Success | Failure |
| :-- | :-- | :-- |
| Handle constructors (`mb_new_tcp`, `mb_new_rtu`) | Non-null pointer | `nil` (0) |
| Every other function with a return value | A value greater than or equal to 0; read/write calls return the number of registers (or bits) transferred | -1 (including communication timeouts) |
| Data conversion functions (`mb_get_float_*`, `mb_get_int32_*`) | The converted value; there is no failure return | None |

After a -1 you should immediately call `mb_get_last_error_str()` for an English error description (for example `Connection timed out` usually means the line is not connected or the slave ID is wrong), or `mb_get_last_errno()` for the numeric code. Error codes are thread-local: read them on the same thread, immediately after the failing call. Reading them from another thread, or after calling other library functions in between, may return a different error.

### Data types

| Type | Description |
| :-- | :-- |
| `TModbusHandle` | The handle. It is a `Pointer`, created by `mb_new_tcp` / `mb_new_rtu`. |
| `Word` | 16-bit unsigned integer, the width of one Modbus register; the element type of register arrays. |
| `Byte` | 8-bit unsigned integer. Bit operations (coils, discrete inputs) use `Byte` arrays where each byte holds one bit with the value `0` or `1`. |
| `Single` | 32-bit float, assembled from two consecutive registers. |
| `PAnsiChar` | Pointer to a `#0`-terminated ANSI string, used for port names, IP addresses and error messages. |
| Calling convention | Every exported function is `cdecl`. Never omit it or switch to `stdcall`, which would corrupt the stack. |

### Typical call flow

Master: `mb_new_rtu` / `mb_new_tcp` → `mb_set_slave` → `mb_connect` → read/write calls (loop) → `mb_close` → `mb_free`.

Slave: `mb_new_rtu` / `mb_new_tcp` → `mb_set_slave` → `mb_slave_init_mapping` → connect (RTU: `mb_connect`; TCP: `mb_tcp_slave_listen_and_accept`) → call `mb_slave_poll_once` in a background loop → `mb_close` → `mb_free`.

### Delphi integration

> **Note:** Call examples are currently provided for Delphi only. If you use C/C++, C#, Python, Rust or another language, bind the exported `cdecl` symbols directly using the table in [API Reference](#api-reference); the parameter semantics are identical.

<details>
<summary><b>uMineModbus.pas</b> — declaration unit for all 66 exports</summary>

Save the code below as `uMineModbus.pas` in your project directory, add `uMineModbus` to the main form's `uses` clause and every export becomes available. Pick the DLL that matches the target bitness: `libmodbus-x86.dll` for 32-bit programs, `libmodbus-x64.dll` for 64-bit ones. Place it next to the executable or on the system search path, and keep the `MODBUS_DLL` constant in sync with the actual file name (the example uses 32-bit Delphi).

Every declaration ends with `cdecl;`. Do not remove it or change it to `stdcall`, or the call stack will be corrupted.

```pascal
unit uMineModbus;

interface

uses
  Windows, SysUtils;

const
  MODBUS_DLL = 'libmodbus-x86.dll'; // 32-bit programs; use 'libmodbus-x64.dll' for 64-bit

type
  // Modbus handle type (used as a plain pointer)
  TModbusHandle = Pointer;
  PWordArray = ^TWordArray;
  TWordArray = array[0..32767] of Word;
  PByteArray = ^TByteArray;
  TByteArray = array[0..32767] of Byte;

// ==================== 1. Connection and base configuration (13) ====================
function mb_new_tcp(ip: PAnsiChar; port: Integer): TModbusHandle; cdecl; external MODBUS_DLL;
function mb_new_rtu(port_name: PAnsiChar; baud: Integer; parity: Byte; data_bit: Integer; stop_bit: Integer): TModbusHandle; cdecl; external MODBUS_DLL;
function mb_connect(h: TModbusHandle): Integer; cdecl; external MODBUS_DLL;
procedure mb_close(h: TModbusHandle); cdecl; external MODBUS_DLL;
procedure mb_free(h: TModbusHandle); cdecl; external MODBUS_DLL;

function mb_set_slave(h: TModbusHandle; slave_id: Integer): Integer; cdecl; external MODBUS_DLL;
function mb_get_slave(h: TModbusHandle): Integer; cdecl; external MODBUS_DLL;
function mb_set_timeout_ms(h: TModbusHandle; response_ms: Cardinal; byte_ms: Cardinal): Integer; cdecl; external MODBUS_DLL;
function mb_set_auto_recovery(h: TModbusHandle; enable_auto_reconnect: Integer): Integer; cdecl; external MODBUS_DLL;
function mb_set_debug(h: TModbusHandle; flag: Integer): Integer; cdecl; external MODBUS_DLL;
function mb_flush(h: TModbusHandle): Integer; cdecl; external MODBUS_DLL;

function mb_get_last_errno(): Integer; cdecl; external MODBUS_DLL;
function mb_get_last_error_str(): PAnsiChar; cdecl; external MODBUS_DLL;

// ==================== 2. RS-485 hardware direction control (3) ====================
function mb_rtu_set_serial_mode(h: TModbusHandle; mode: Integer): Integer; cdecl; external MODBUS_DLL;
function mb_rtu_set_rts(h: TModbusHandle; mode: Integer): Integer; cdecl; external MODBUS_DLL;
function mb_rtu_set_rts_delay(h: TModbusHandle; us: Integer): Integer; cdecl; external MODBUS_DLL;

// ==================== 3. Master read/write functions (12) ====================
// 0x01 read coils, 0x02 read discrete inputs
function mb_read_bits(h: TModbusHandle; addr: Integer; nb: Integer; dest: PByte): Integer; cdecl; external MODBUS_DLL;
function mb_read_input_bits(h: TModbusHandle; addr: Integer; nb: Integer; dest: PByte): Integer; cdecl; external MODBUS_DLL;
// 0x03 read holding registers, 0x04 read input registers
function mb_read_registers(h: TModbusHandle; addr: Integer; nb: Integer; dest: PWord): Integer; cdecl; external MODBUS_DLL;
function mb_read_input_registers(h: TModbusHandle; addr: Integer; nb: Integer; dest: PWord): Integer; cdecl; external MODBUS_DLL;
// 0x05 write single coil, 0x06 write single register
function mb_write_bit(h: TModbusHandle; coil_addr: Integer; status: Integer): Integer; cdecl; external MODBUS_DLL;
function mb_write_register(h: TModbusHandle; addr: Integer; value: Word): Integer; cdecl; external MODBUS_DLL;
// 0x0F write multiple coils, 0x10 write multiple registers
function mb_write_bits(h: TModbusHandle; addr: Integer; nb: Integer; data: PByte): Integer; cdecl; external MODBUS_DLL;
function mb_write_registers(h: TModbusHandle; addr: Integer; nb: Integer; src: PWord): Integer; cdecl; external MODBUS_DLL;
// 0x16 mask write, 0x17 read/write, 0x11 report slave ID, non-standard raw frame
function mb_mask_write_register(h: TModbusHandle; addr: Integer; and_mask: Word; or_mask: Word): Integer; cdecl; external MODBUS_DLL;
function mb_write_and_read_registers(h: TModbusHandle; write_addr: Integer; write_nb: Integer; src: PWord; read_addr: Integer; read_nb: Integer; dest: PWord): Integer; cdecl; external MODBUS_DLL;
function mb_report_slave_id(h: TModbusHandle; max_dest: Integer; dest: PByte): Integer; cdecl; external MODBUS_DLL;
function mb_send_raw_and_receive(h: TModbusHandle; raw_req: PByte; req_len: Integer; rsp_buf: PByte): Integer; cdecl; external MODBUS_DLL;

// ==================== 4. Slave register mapping and replies (19) ====================
function mb_slave_init_mapping(h: TModbusHandle; nb_bits: Integer; nb_input_bits: Integer; nb_registers: Integer; nb_input_registers: Integer): Integer; cdecl; external MODBUS_DLL;
function mb_slave_init_mapping_ex(h: TModbusHandle; start_bits, nb_bits, start_input_bits, nb_input_bits, start_registers, nb_registers, start_input_registers, nb_input_registers: Integer): Integer; cdecl; external MODBUS_DLL;

function mb_slave_set_coil(h: TModbusHandle; index: Integer; val: Byte): Integer; cdecl; external MODBUS_DLL;
function mb_slave_get_coil(h: TModbusHandle; index: Integer; out out_val: Byte): Integer; cdecl; external MODBUS_DLL;
function mb_slave_set_input_bit(h: TModbusHandle; index: Integer; val: Byte): Integer; cdecl; external MODBUS_DLL;
function mb_slave_get_input_bit(h: TModbusHandle; index: Integer; out out_val: Byte): Integer; cdecl; external MODBUS_DLL;

function mb_slave_set_holding_reg(h: TModbusHandle; index: Integer; value: Word): Integer; cdecl; external MODBUS_DLL;
function mb_slave_get_holding_reg(h: TModbusHandle; index: Integer; out out_val: Word): Integer; cdecl; external MODBUS_DLL;
function mb_slave_set_input_reg(h: TModbusHandle; index: Integer; value: Word): Integer; cdecl; external MODBUS_DLL;
function mb_slave_get_input_reg(h: TModbusHandle; index: Integer; out out_val: Word): Integer; cdecl; external MODBUS_DLL;

function mb_slave_set_holding_regs_bulk(h: TModbusHandle; start_index: Integer; count: Integer; src: PWord): Integer; cdecl; external MODBUS_DLL;
function mb_slave_get_holding_regs_bulk(h: TModbusHandle; start_index: Integer; count: Integer; dest: PWord): Integer; cdecl; external MODBUS_DLL;
function mb_slave_set_input_regs_bulk(h: TModbusHandle; start_index: Integer; count: Integer; src: PWord): Integer; cdecl; external MODBUS_DLL;
function mb_slave_get_input_regs_bulk(h: TModbusHandle; start_index: Integer; count: Integer; dest: PWord): Integer; cdecl; external MODBUS_DLL;

function mb_tcp_slave_listen_and_accept(h: TModbusHandle; nb_connection: Integer): Integer; cdecl; external MODBUS_DLL;
function mb_slave_poll_once(h: TModbusHandle): Integer; cdecl; external MODBUS_DLL;
function mb_slave_receive_raw(h: TModbusHandle; req_buf: PByte): Integer; cdecl; external MODBUS_DLL;
function mb_slave_reply_normal(h: TModbusHandle; req_buf: PByte; req_len: Integer): Integer; cdecl; external MODBUS_DLL;
function mb_slave_reply_exception(h: TModbusHandle; req_buf: PByte; exception_code: Cardinal): Integer; cdecl; external MODBUS_DLL;

// ==================== 5. Float and 32-bit integer conversion (12) ====================
function mb_get_float_abcd(src: PWord): Single; cdecl; external MODBUS_DLL;
function mb_get_float_dcba(src: PWord): Single; cdecl; external MODBUS_DLL;
function mb_get_float_badc(src: PWord): Single; cdecl; external MODBUS_DLL;
function mb_get_float_cdab(src: PWord): Single; cdecl; external MODBUS_DLL;

procedure mb_set_float_abcd(f: Single; dest: PWord); cdecl; external MODBUS_DLL;
procedure mb_set_float_dcba(f: Single; dest: PWord); cdecl; external MODBUS_DLL;
procedure mb_set_float_badc(f: Single; dest: PWord); cdecl; external MODBUS_DLL;
procedure mb_set_float_cdab(f: Single; dest: PWord); cdecl; external MODBUS_DLL;

function mb_get_int32_abcd(src: PWord): Integer; cdecl; external MODBUS_DLL;
procedure mb_set_int32_abcd(val: Integer; dest: PWord); cdecl; external MODBUS_DLL;
function mb_get_int32_cdab(src: PWord): Integer; cdecl; external MODBUS_DLL;
procedure mb_set_int32_cdab(val: Integer; dest: PWord); cdecl; external MODBUS_DLL;

{ ---- Raw register accessors (legacy compatibility, see "Raw register accessors") ---- }
function mb_get_reg_u16(src: PWord; index: Integer): Word; cdecl; external MODBUS_DLL;
function mb_get_reg_i16(src: PWord; index: Integer): SmallInt; cdecl; external MODBUS_DLL;
procedure mb_put_reg_u16(value: Word; dest: PWord; index: Integer); cdecl; external MODBUS_DLL;
function mb_get_reg_u32_abcd(src: PWord; index: Integer): Cardinal; cdecl; external MODBUS_DLL;
function mb_get_reg_u32_cdab(src: PWord; index: Integer): Cardinal; cdecl; external MODBUS_DLL;
function mb_get_reg_i32_abcd(src: PWord; index: Integer): Integer; cdecl; external MODBUS_DLL;
function mb_get_reg_i32_cdab(src: PWord; index: Integer): Integer; cdecl; external MODBUS_DLL;

implementation

end.
```

</details>

#### Master example: read a float from a sensor

<details>
<summary>Show example</summary>

The example reads slave 1 over RS-485, fetching two holding registers starting at address 0 and converting them to a float using `cdab` byte order.

```pascal
procedure TForm1.ReadSensor;
var
  h: TModbusHandle;
  regs: array[0..1] of Word;
  value: Single;
begin
  h := mb_new_rtu('COM3', 9600, Ord('N'), 8, 1);
  if h = nil then
    raise Exception.Create('Failed to create serial handle');
  try
    mb_set_slave(h, 1);
    if mb_connect(h) < 0 then
      raise Exception.Create('Connect failed: ' + string(AnsiString(mb_get_last_error_str())));

    if mb_read_registers(h, 0, 2, @regs[0]) < 0 then
      raise Exception.Create('Read failed: ' + string(AnsiString(mb_get_last_error_str())));

    value := mb_get_float_cdab(@regs[0]);
    Memo1.Lines.Add(FloatToStr(value));
  finally
    mb_close(h);
    mb_free(h);
  end;
end;
```

In a real application the handle is usually created and connected once at startup, read and written repeatedly from a timer or a background thread, and released with `mb_close` and `mb_free` on exit.

</details>

#### Master example: write a relay and a register

<details>
<summary>Show example</summary>

```pascal
// Energise coil 0 (address 00001)
if mb_write_bit(h, 0, 1) < 0 then
  ShowMessage(string(AnsiString(mb_get_last_error_str())));

// Write 1000 to holding register address 9 (40010)
if mb_write_register(h, 9, 1000) < 0 then
  ShowMessage(string(AnsiString(mb_get_last_error_str())));
```

</details>

#### Slave example: TCP slave

<details>
<summary>Show example</summary>

```pascal
var
  SlaveH: TModbusHandle;

procedure StartSlave;
begin
  SlaveH := mb_new_tcp('0.0.0.0', 502);
  mb_set_slave(SlaveH, 1);
  // 0 coils, 0 discrete inputs, 100 holding registers, 0 input registers
  mb_slave_init_mapping(SlaveH, 0, 0, 100, 0);
  // Preload data for the master to read
  mb_slave_set_holding_reg(SlaveH, 0, 1234);
end;

// Runs in a background thread's Execute method
procedure SlaveThreadBody;
var
  v: Word;
begin
  if mb_tcp_slave_listen_and_accept(SlaveH, 1) < 0 then Exit;
  while not Terminated do
  begin
    if mb_slave_poll_once(SlaveH) < 0 then
      Break;  // Connection lost or error; call listen_and_accept again if needed
    // Read a value written by the master
    mb_slave_get_holding_reg(SlaveH, 1, v);
  end;
end;
```

</details>

## API Reference

### Connection, configuration and teardown (13)

Both master and slave start by creating and configuring a handle with these functions.

| Function | Purpose | Parameters | Returns |
| :-- | :-- | :-- | :-- |
| `mb_new_rtu` | Create a serial (RS-485/RS-232) handle | `port_name`: port name such as `'COM3'`; `baud`: baud rate such as `9600`; `parity`: ASCII code of the parity, `78` = N (none), `69` = E (even), `79` = O (odd); `data_bit`: data bits, usually `8`; `stop_bit`: stop bits, usually `1` | Handle on success, `nil` on failure |
| `mb_new_tcp` | Create a TCP handle | `ip`: destination IP such as `'192.168.1.10'`; use `'0.0.0.0'` when acting as a slave; `port`: port number, `502` is standard | Handle on success, `nil` on failure |
| `mb_set_slave` | Set the slave ID (device address) | `h`: handle; `slave_id`: 1–247 (TCP usually uses `1`) | 0 on success, -1 on failure |
| `mb_get_slave` | Read the handle's current slave ID | `h`: handle | Current slave ID; -1 on failure |
| `mb_connect` | Open the serial port or connect the TCP socket. The TCP connection timeout reuses the response timeout (200 ms by default); on slow networks raise the timeout with `mb_set_timeout_ms` before connecting | `h`: handle | 0 on success, -1 on failure (port busy, network unreachable, …) |
| `mb_close` | Disconnect. The handle stays valid and can be passed to `mb_connect` again. It can also interrupt a slave `mb_slave_poll_once` / `mb_slave_receive_raw` / `mb_tcp_slave_listen_and_accept` blocked in another thread; a TCP slave's listening port is closed too, so call `mb_tcp_slave_listen_and_accept` again to resume listening. If automatic recovery is still enabled, the next TCP read/write after closing may reconnect (a serial write simply returns -1); to stop communication completely, call `mb_set_auto_recovery(h, 0)` first | `h`: handle | None |
| `mb_free` | Destroy the handle and release its memory. Call once before the program exits; the handle is invalid afterwards. Make sure no thread is still using it, including the slave polling thread (see [Handle lifecycle](#handle-lifecycle)) | `h`: handle | None |
| `mb_set_timeout_ms` | Change the timeouts | `h`: handle; `response_ms`: response timeout in milliseconds, default 200, must not be 0; `byte_ms`: inter-byte timeout in milliseconds, default 20, 0 disables it | 0 on success, -1 on failure |
| `mb_set_auto_recovery` | Enable or disable automatic recovery. When enabled: TCP connection-level errors trigger a reconnect, and protocol-level errors (CRC failures, …) clear the residual bytes in the receive buffer; serial (RTU) never reconnects and a failed write returns -1 (see [Timeouts and reconnection](#timeouts-and-reconnection)) | `h`: handle; `enable_auto_reconnect`: `1` enabled (the default), `0` disabled | 0 on success, -1 on failure |
| `mb_set_debug` | Print sent and received frames to the console. GUI programs have no console and must call `AllocConsole` first | `h`: handle; `flag`: `1` on, `0` off | 0 on success, -1 on failure |
| `mb_flush` | Discard residual bytes in the receive buffer | `h`: handle | ≥ 0 on success (number of bytes discarded), -1 on failure |
| `mb_get_last_errno` | Numeric code of the most recent error. Thread-local; read it on the thread where the error occurred | None | Error code |
| `mb_get_last_error_str` | English description of the most recent error. Thread-local; read it on the thread where the error occurred | None | `PAnsiChar` string |

### Master read/write (12)

A master actively reads from and writes to other devices.

> If several devices share one RS-485 bus (slave IDs 1–5, for example), you do **not** need multiple handles. Call `mb_new_rtu` and `mb_connect` once, then call `mb_set_slave(h, id)` before each transfer to switch targets. When several threads share a handle, the caller must lock "set slave + read/write" as one unit (see [Usage Notes](#usage-notes)). Per-call count limits are listed in [Operation limits](#operation-limits).

| Function | Code | Purpose | Parameters | Returns |
| :-- | :-: | :-- | :-- | :-- |
| `mb_read_registers` | 0x03 | Read holding registers (4x zone, the most common) | `h`: handle; `addr`: start address (zero-based); `nb`: count; `dest`: start of the receiving `Word` array | Count read on success, -1 on failure |
| `mb_read_input_registers` | 0x04 | Read input registers (3x zone, read-only, common for sensors) | Same as `mb_read_registers` | Count read on success, -1 on failure |
| `mb_write_register` | 0x06 | Write a single holding register | `h`: handle; `addr`: address; `value`: value to write (`Word`, 16-bit unsigned) | 1 on success, -1 on failure |
| `mb_write_registers` | 0x10 | Write multiple holding registers | `h`: handle; `addr`: start address; `nb`: count; `src`: start of the `Word` array to write | Count written on success, -1 on failure |
| `mb_read_bits` | 0x01 | Read coil states (0x zone) | `h`: handle; `addr`: start address; `nb`: count; `dest`: start of a `Byte` array, one bit per byte (`0` or `1`) | Count read on success, -1 on failure |
| `mb_read_input_bits` | 0x02 | Read discrete inputs (1x zone) | Same as `mb_read_bits` | Count read on success, -1 on failure |
| `mb_write_bit` | 0x05 | Write a single coil | `h`: handle; `coil_addr`: coil address; `status`: `1` = ON, `0` = OFF | 1 on success, -1 on failure |
| `mb_write_bits` | 0x0F | Write multiple coils | `h`: handle; `addr`: start address; `nb`: count; `data`: start of a `Byte` array holding `0`/`1` | Count written on success, -1 on failure |
| `mb_mask_write_register` | 0x16 | Modify selected bits of a register through a mask. Per the Modbus standard the result is (old AND `and_mask`) OR (`or_mask` AND NOT `and_mask`) | `h`: handle; `addr`: register address; `and_mask`: AND mask (`Word`); `or_mask`: OR mask (`Word`) | 1 on success, -1 on failure |
| `mb_write_and_read_registers` | 0x17 | Write and read several registers in a single transaction | `h`: handle; `write_addr`: write start; `write_nb`: write count; `src`: `Word` array to write; `read_addr`: read start; `read_nb`: read count; `dest`: receiving `Word` array | Count read on success, -1 on failure |
| `mb_report_slave_id` | 0x11 | Read the slave device's ID information | `h`: handle; `max_dest`: buffer size; `dest`: receiving `Byte` array | Byte count on success, -1 on failure |
| `mb_send_raw_and_receive` | custom | Send a non-standard raw frame and receive the reply. RTU mode appends the CRC automatically, TCP mode appends the MBAP header. The expected reply length is derived from the standard function code, so replies to custom function codes may time out or fail the checksum | `h`: handle; `raw_req`: request bytes (slave ID, function code, data); `req_len`: request length; `rsp_buf`: receive buffer, at least 260 bytes | Total bytes received on success, -1 on failure |

### Data conversion helpers (12)

Transmitters often pack a 32-bit float (`Single`) or 32-bit integer into two consecutive 16-bit registers (`Word`). The byte order differs between vendors. If a value looks obviously wrong (for example `1.23e-38`), the byte order is usually wrong — try the others. Devices in China most often use `cdab` or `abcd`.

For a 32-bit value `A B C D` (A is the most significant byte) the register layouts are:

| Order | Register 1 (low address) | Register 2 (high address) | Description |
| :-- | :-- | :-- | :-- |
| `abcd` | `A B` | `C D` | Standard big-endian |
| `cdab` | `C D` | `A B` | Word swap, the most common |
| `badc` | `B A` | `D C` | Byte swap within each word |
| `dcba` | `D C` | `B A` | Full little-endian |

| Function | Purpose | Parameters | Returns |
| :-- | :-- | :-- | :-- |
| `mb_get_float_abcd` | Two registers → float (ABCD) | `src`: start of a 2-element `Word` array | `Single` |
| `mb_get_float_cdab` | Two registers → float (CDAB) | Same | `Single` |
| `mb_get_float_badc` | Two registers → float (BADC) | Same | `Single` |
| `mb_get_float_dcba` | Two registers → float (DCBA) | Same | `Single` |
| `mb_set_float_abcd` | Float → two registers (ABCD), for writes | `f`: `Single` value; `dest`: start of a 2-element `Word` array | None |
| `mb_set_float_cdab` | Float → two registers (CDAB) | Same | None |
| `mb_set_float_badc` | Float → two registers (BADC) | Same | None |
| `mb_set_float_dcba` | Float → two registers (DCBA) | Same | None |
| `mb_get_int32_abcd` | Two registers → signed 32-bit integer (ABCD) | `src`: start of a 2-element `Word` array | `Integer` |
| `mb_get_int32_cdab` | Two registers → signed 32-bit integer (CDAB) | Same | `Integer` |
| `mb_set_int32_abcd` | Signed 32-bit integer → two registers (ABCD) | `val`: integer; `dest`: start of a 2-element `Word` array | None |
| `mb_set_int32_cdab` | Signed 32-bit integer → two registers (CDAB) | Same | None |

> Note: integer conversion only provides the `abcd` and `cdab` orders.

### Raw register accessors

The conversion functions above all interpret registers as some business type. Legacy projects often just want the **raw 16-bit value** and do their own scaling (for example `value = raw × 0.1`), or want to index a register without writing `r[i]` by hand. The following **zero-interpretation** accessors exist for that: no floating point, no byte-order conversion, no array-length validation — semantics are exactly those of C's `src[index]`.

| Function | Purpose | Parameters | Returns |
| :-- | :-- | :-- | :-- |
| `mb_get_reg_u16` | Read one register by index as an **unsigned** raw value | `src`: start of a `Word` array; `index`: zero-based index | `Word` (0–65535) |
| `mb_get_reg_i16` | Read one register by index as a **signed** raw value (negative temperatures, …) | Same | `SmallInt` (-32768–32767) |
| `mb_put_reg_u16` | Write one value into a register array at an index | `value`: value to write; `dest`: array start; `index`: index | None |
| `mb_get_reg_u32_abcd` | Combine 2 adjacent registers from `index` into **unsigned** 32-bit (high word at low address) | `src`: array start; `index`: start index | `Cardinal` |
| `mb_get_reg_u32_cdab` | Same, but **low word at low address** (word swap) | Same | `Cardinal` |
| `mb_get_reg_i32_abcd` | Same as above, **signed** 32-bit | Same | `Integer` |
| `mb_get_reg_i32_cdab` | Same as above, word-swapped and signed | Same | `Integer` |

Notes:

1. A negative `index` makes getters return 0 and `put` a no-op; nothing crashes. Out-of-range `index` is **not checked**, matching C semantics — the caller must guarantee validity.
2. For 32-bit combinations both the register at `index` and the one at `index + 1` must be valid.
3. These functions are independent of the rest of [Data conversion helpers](#data-conversion-helpers-12) and can be mixed with `mb_get_float_*`.

Typical use — read 4 registers and parse a mix of values:

```delphi
var
  R: array[0..3] of Word;
  TempRaw: SmallInt;
  HumiRaw: Word;
  Total: Cardinal;
begin
  if mb_read_registers(h, 0, 4, @R) = 4 then
  begin
    TempRaw := mb_get_reg_i16(@R, 0);          // -125 means -12.5 °C
    HumiRaw := mb_get_reg_u16(@R, 1);          // 654 means 65.4 %RH
    Total   := mb_get_reg_u32_abcd(@R, 2);     // 32-bit totaliser
    Writeln(Format('temp=%.1f humidity=%.1f total=%d',
      [TempRaw / 10.0, HumiRaw / 10.0, Total]));
  end;
end;
```

The most common single-register sensor:

```delphi
var R: Word;
if mb_read_registers(h, 0, 1, @R) = 1 then
  Value := mb_get_reg_i16(@R, 0) / 10.0;   // signed; use mb_get_reg_u16 if unsigned
```

> Tip: a negative reading that comes back as `60000+` means the sign was not interpreted — switch to `mb_get_reg_i16`.

### Slave emulation (19)

Use these functions when an industrial PC must emulate a field device and be read or written by a master. The slave keeps four data zones in local memory and `mb_slave_poll_once` answers requests from them automatically.

#### Zones and indexes

| Zone | Function codes | Init parameter | Local accessors |
| :-- | :-- | :-- | :-- |
| 0x coils | 01, 05, 0F | `nb_bits` | `mb_slave_set_coil` / `mb_slave_get_coil` |
| 1x discrete inputs | 02 | `nb_input_bits` | `mb_slave_set_input_bit` / `mb_slave_get_input_bit` |
| 4x holding registers | 03, 06, 10, 16, 17 | `nb_registers` | `mb_slave_set_holding_reg` / `mb_slave_get_holding_reg`, plus bulk variants |
| 3x input registers | 04 | `nb_input_registers` | `mb_slave_set_input_reg` / `mb_slave_get_input_reg`, plus bulk variants |

`index` is an array index within the zone, from 0 to count - 1. With `mb_slave_init_mapping` the index maps one-to-one to the Modbus address requested by the master. With `mb_slave_init_mapping_ex` and a non-zero start address, the master's address is start address + index.

#### Functions

| Function | Purpose | Parameters | Returns |
| :-- | :-- | :-- | :-- |
| `mb_slave_init_mapping` | Step 1: allocate the four register zones in memory, starting at address 0. Call it once at startup: calling it again frees the old tables before creating new ones, losing the data; if the new allocation fails the old tables are already gone, so re-initialise again | `h`: handle; `nb_bits`: coils; `nb_input_bits`: discrete inputs; `nb_registers`: holding registers; `nb_input_registers`: input registers. No parameter may be negative | 0 on success, -1 on failure (null handle, negative parameter, out of memory) |
| `mb_slave_init_mapping_ex` | Same, but each zone can have a non-zero start address | `h`: handle; then start address and count for coils, discrete inputs, holding registers and input registers (`start_bits, nb_bits, start_input_bits, nb_input_bits, start_registers, nb_registers, start_input_registers, nb_input_registers`). No parameter may be negative | Same as above |
| `mb_slave_set_holding_reg` | Write a holding register locally (for the master to read) | `h`: handle; `index`: index; `value`: `Word` value | 0 on success, -1 on failure (mapping not initialised, index out of range) |
| `mb_slave_get_holding_reg` | Read a local holding register (to see what the master wrote) | `h`: handle; `index`: index; `out_val`: receiving `Word` variable (by reference) | Same |
| `mb_slave_set_input_reg` / `mb_slave_get_input_reg` | Read/write local 3x input registers | Same | Same |
| `mb_slave_set_coil` / `mb_slave_get_coil` | Read/write local 0x coils. Non-zero values are stored as `1` | `h`: handle; `index`: index; `val` or `out_val`: `Byte` | Same |
| `mb_slave_set_input_bit` / `mb_slave_get_input_bit` | Read/write local 1x discrete inputs. Non-zero values are stored as `1` | Same | Same |
| `mb_slave_set_holding_regs_bulk` | Write a block of holding registers | `h`: handle; `start_index`: start index; `count`: count, must be > 0; `src`: `Word` array | 0 on success, -1 on failure (mapping not initialised, range out of bounds, invalid `count`) |
| `mb_slave_get_holding_regs_bulk` | Read a block of holding registers | `h`: handle; `start_index`: start index; `count`: count, must be > 0; `dest`: `Word` array | Same |
| `mb_slave_set_input_regs_bulk` | Write a block of input registers | Same as `mb_slave_set_holding_regs_bulk` | Same |
| `mb_slave_get_input_regs_bulk` | Read a block of input registers | Same as `mb_slave_get_holding_regs_bulk` | Same |
| `mb_tcp_slave_listen_and_accept` | TCP slave only: listen and wait for a master to connect; blocks until one does. The first call creates the listening socket; after the master disconnects, the next call closes the dead session and reuses the listening socket; if `mb_close` was called meanwhile the listening socket is gone and this call recreates it. The function holds no lock while blocking, so another thread can call `mb_close` to interrupt it | `h`: handle; `nb_connection`: listen backlog, `1` is enough. One handle serves one master at a time | ≥ 0 on success, -1 on failure |
| `mb_slave_poll_once` | Slave core loop: receive one request and reply from the local register tables. Call it continuously in a background thread. It holds no lock while waiting, so other threads can still read/write local registers | `h`: handle | > 0: replied, value is the reply length in bytes; 0: request ignored (e.g. slave ID mismatch); -1: failure (mapping not initialised, handle closing, connection lost) |
| `mb_slave_receive_raw` | Low-level: receive one raw request without replying | `h`: handle; `req_buf`: receive buffer, at least 260 bytes | > 0: bytes received; 0: request ignored; -1: failure |
| `mb_slave_reply_normal` | Low-level: send a normal reply to a request received by `mb_slave_receive_raw`, using the register tables | `h`: handle; `req_buf`: request buffer; `req_len`: request length, i.e. the return value of `mb_slave_receive_raw` | ≥ 0: reply length in bytes; -1: failure |
| `mb_slave_reply_exception` | Low-level: send a Modbus exception reply to a request | `h`: handle; `req_buf`: request buffer; `exception_code`: Modbus exception code | ≥ 0: reply length in bytes; -1: failure |

Notes:

1. Most scenarios only need `mb_slave_poll_once`. `mb_slave_receive_raw`, `mb_slave_reply_normal` and `mb_slave_reply_exception` are for intercepting or filtering requests, or sending custom exception replies.
2. Local accessors follow the [Return values](#return-values) convention: 0 on success, -1 on failure.
3. After a master disconnects, a TCP slave's `mb_slave_poll_once` returns -1. Call `mb_tcp_slave_listen_and_accept` again to wait for the master to reconnect.
4. While running, update local registers only through the `set` / `get` functions; do not call `mb_slave_init_mapping` again (see [Handle lifecycle](#handle-lifecycle)).
5. The start address plus count of each zone must not exceed 65536: the Modbus address field is only 16 bits, so anything above is unreachable by the master.

### RS-485 hardware flow control (3)

Almost all USB-to-RS-485 converters and modern serial cards switch direction in hardware and do not need these functions. They are implemented only in the Linux build of libmodbus and are **unavailable in this Windows build** (see the platform note below).

| Function | Purpose | Parameters | Returns |
| :-- | :-- | :-- | :-- |
| `mb_rtu_set_serial_mode` | Set the serial mode | `h`: handle; `mode`: `0` = RS-232, `1` = RS-485 | 0 on success, -1 on failure |
| `mb_rtu_set_rts` | Set the RTS pin policy while transmitting | `h`: handle; `mode`: `0` = unused, `1` = RTS high while sending, `2` = RTS low while sending | 0 on success, -1 on failure |
| `mb_rtu_set_rts_delay` | Set the delay before and after RTS toggling | `h`: handle; `us`: delay in microseconds | 0 on success, -1 on failure |

> **Platform limitation:** these functions rely on OS serial-driver support. **All three are unavailable in the current Windows build** and always return -1 with `mb_get_last_errno()` = `ENOTSUP`. They are implemented on top of Linux serial ioctls (`TIOCSRS485`, `TIOCMGET`/`TIOCMSET`) and Windows libmodbus has no equivalent. On Windows, rely on the automatic direction switching of your USB-to-RS-485 converter, or on a vendor-specific control mechanism.

## Build & Test

### Build

The library is cross-compiled from the bundled libmodbus C sources with Zig and produces both Windows architectures in one run:

```sh
zig build
```

For a release build add `--release=fast`. Zig 0.17 replaced the older `-Doptimize=ReleaseFast` with `--release[=fast|safe|small]`; `build.zig` declares `ReleaseFast` as its preferred mode. Without the flag you get a Debug build.

The C sources are compiled with Windows 7 as the minimum target (`_WIN32_WINNT=0x0601`), with `OS_WIN32` and `_WIN32` explicitly defined, so every Winsock-specific branch in `modbus-tcp.c` is active (non-blocking `connect` handling of `WSAEWOULDBLOCK`, `ioctlsocket` with `FIONBIO`, suppression of the unsupported `IP_TOS`).

### Self-check without hardware

```sh
zig build test
```

This parses the PE headers of both artifacts and verifies their architecture (x64/x86) and the 66 exports promised by this document. It does not load the DLLs and needs no serial port or network, so it runs reliably on any platform, including `windows-latest`.

### Real-device E2E

```sh
zig build e2e                    # uses COM1
zig build e2e -Dcom-port=COM3    # use the port your device is wired to
```

The step compiles and runs `tests/e2e_test.zig`, a zero-dependency test host that:

1. loads the real `zig-out/bin/libmodbus-x64.dll` with Win32 `LoadLibrary` and checks the 66 documented exports;
2. runs a slave listener plus a master client over the local TCP loopback, covering function codes 01/02/03/04/05/06/0F/10/11/16/17, exception replies (errno = `MODBUS_ENOBASE` + exception code), read/write count limits, all four byte orders for floats and 32-bit integers, the raw register accessors (including negative temperatures, index offsets and negative-index protection), 4-thread concurrency and automatic reconnection;
3. exercises a real serial port (COM1 by default): port open, the 200 ms default timeout, `mb_set_timeout_ms`, slave ID bounds, `COM12` expansion and case-insensitivity, and -1 for a missing port;
4. verifies that the 32-bit DLL cannot be loaded into a 64-bit process (architecture isolation).

The process exits 0 when every check passes and 1 otherwise, so it can be used before a release. There are currently 94 checks, all passing. `e2e` needs a real serial port and is therefore not suitable for hardware-less CI; use `zig build test` there.

### Local scripts

```sh
./scripts/ci-linux.sh                    # Linux / macOS: build + hardware-free self-check
```

```powershell
.\scripts\test-windows.ps1               # Windows: build + self-check + real-device e2e (COM1)
.\scripts\test-windows.ps1 -ComPort COM3 # specify the serial port
.\scripts\test-windows.ps1 -SkipE2E      # build and hardware-free self-check only
```

`scripts/ci-linux.sh` reproduces the build and the hardware-free self-check on Linux or macOS (Zig cross-compiles the Windows DLLs). `scripts/test-windows.ps1` adds the real-device E2E run and needs Windows with a serial port.

## Usage Notes

### Multithreading

Every call is internally locked, so one handle can be shared by multiple threads without corrupting its state, with these constraints:

1. The slave ID is handle state. `mb_set_slave` and the following read/write are two separate calls and another thread may change the ID in between. When several threads poll different slave IDs on one handle, the caller must protect "set slave + read/write" with its own lock.
2. One serial port can be opened only once; share a single handle for a bus and use the outer lock described above.
3. The slave polling thread holds no lock while waiting for requests, so other threads may call `mb_slave_set_*` / `mb_slave_get_*` concurrently.
4. Error codes are thread-local and must be read on the failing thread.

### Operation limits

Calls exceeding these limits return -1.

| Function | Code | Per-call limit |
| :-- | :-: | :-- |
| `mb_read_bits`, `mb_read_input_bits` | 01, 02 | 2000 bits |
| `mb_read_registers`, `mb_read_input_registers` | 03, 04 | 125 registers |
| `mb_write_bits` | 0F | 1968 bits |
| `mb_write_registers` | 10 | 123 registers |
| `mb_write_and_read_registers` | 17 | 121 registers written, 125 read |

### Buffer sizes

| Buffer | Minimum size |
| :-- | :-- |
| `rsp_buf` of `mb_send_raw_and_receive` | 260 bytes |
| `req_buf` of `mb_slave_receive_raw` | 260 bytes |
| `dest` of bit readers | `nb` `Byte` elements |
| `dest` of register readers | `nb` `Word` elements |
| `dest` of `mb_report_slave_id` | `max_dest` bytes |

### Timeouts and reconnection

1. The response timeout defaults to 200 ms, so a call fails within about 0.2 s when nobody answers. libmodbus' "wait one more response timeout and flush the receive buffer after a timeout" logic only runs on Unix; this Windows build returns immediately after a `select` timeout, so elapsed time is about one response timeout. Lower `response_ms` if you need a tighter bound.
2. TCP automatic reconnection triggers only on connection-level errors, not on plain timeouts. The call that triggers it still returns -1. Serial (RTU) never reconnects: a failed write or receive returns -1 directly.
3. If automatic recovery is still enabled after `mb_close`, the next TCP read/write may reconnect; a serial write returns -1 because the handle is closed. To stop communication completely, call `mb_set_auto_recovery(h, 0)` first.
4. TCP `mb_connect` uses the response timeout as its connect timeout; raise the timeout before connecting on slow networks.
5. During the **send phase**, if a TCP connection-level error occurs and automatic recovery is on, libmodbus enters a "reconnect + resend" loop and returns only once the send succeeds; that call may block for a long time. Serial (RTU) never enters this loop and fails immediately. If you need a hard per-call time limit over TCP, disable automatic recovery.

These timing behaviours follow libmodbus 3.1.x; measure them in your target environment.

### Handle lifecycle

1. Shutdown order: stop the slave polling thread first (call `mb_close` to interrupt a blocked receive or `accept`, then wait for the thread to end), then call `mb_free`. `mb_free` does not wait for other threads; a thread still using the handle after it is freed touches released memory.
2. Call `mb_slave_init_mapping` / `mb_slave_init_mapping_ex` once at startup only. Calling them again while the slave runs does not crash, but the data is lost and the master may read empty tables. While running, update data only through the `set` / `get` functions.
3. If creating a new table fails, the old one has already been freed. Slave read/write functions then return -1 until re-initialisation succeeds.
4. After `mb_free`, set the handle variable to `nil` and do not use it again.

## Troubleshooting

| Symptom | Likely cause | Remedy |
| :-- | :-- | :-- |
| A function returns -1 with `Connection timed out` | Line not connected, wrong slave ID, or baud rate / parity mismatch | Check the wiring (A/B swapped?), the `mb_set_slave` ID and the `mb_new_rtu` serial parameters |
| Data is shifted by one position | Address is not zero-based | Subtract the zone base from the PLC label as described in [Address convention](#address-convention-mandatory) |
| Floats read as tiny or huge values | Wrong byte order | Try `abcd`, `cdab`, `badc` and `dcba` in turn |
| `mb_connect` fails | Serial port busy or non-existent; TCP network slower than 200 ms | Close the program holding the port, confirm the port name in Device Manager; for TCP raise the timeout with `mb_set_timeout_ms` first |
| Several devices on one bus are occasionally missed | The device answers slower than the default 200 ms | Increase `response_ms` with `mb_set_timeout_ms` |
| Multi-threaded polling of different IDs returns mismatched data | Threads change the slave ID between `mb_set_slave` and the transfer | Lock "set slave + read/write" as one unit (see [Usage Notes](#usage-notes)) |
| Need to see raw frames | — | Call `mb_set_debug(h, 1)`; GUI programs need `AllocConsole` first |
| The program crashes or the stack is corrupted after a call | Declarations use `stdcall` or omit `cdecl` | Keep `cdecl` on every declaration |
| Crash on exit | `mb_free` while the slave thread still uses the handle, or use after free | Stop the slave thread before `mb_free`, then set the handle to `nil` (see [Handle lifecycle](#handle-lifecycle)) |
| The master reads all zeros while the slave runs | `mb_slave_init_mapping` was called again while running | Initialise once at startup and use `set` / `get` afterwards |
| A TCP slave stops answering after the master disconnects | The connection is gone and `mb_slave_poll_once` returned -1 | Call `mb_tcp_slave_listen_and_accept` again to wait for a reconnect |

## License

This project builds on [libmodbus](https://github.com/stephane/libmodbus), originally written by Stéphane Raimbault and contributors. The upstream sources bundled in `c_src/` are licensed under the **GNU Lesser General Public License, version 2.1 or later** (`LGPL-2.1-or-later`); see [`c_src/COPYING.LESSER`](c_src/COPYING.LESSER) and the `SPDX-License-Identifier` header in [`c_src/src/modbus.h`](c_src/src/modbus.h). The bundled snapshot is libmodbus 3.2.0.

Because the prebuilt DLLs are compiled from those sources, they are distributed under the same terms. The Zig wrapper in [`src/main.zig`](src/main.zig), the build script [`build.zig`](build.zig), the tests and the scripts are released under `LGPL-2.1-or-later` as well. The repository does not carry a separate top-level `LICENSE` file; the upstream license in `c_src/COPYING.LESSER` governs the bundled sources and the binaries built from them.

### Dynamic linking boundary

`libmodbus-x86.dll` and `libmodbus-x64.dll` are ordinary shared libraries. When your application calls them through the C ABI (typed imports, `LoadLibrary`/`GetProcAddress`, Delphi `external`, P/Invoke, …), the library is **linked dynamically at run time** and LGPL-2.1 section 6 applies:

- You may keep your own application closed-source, including commercial and proprietary software.
- Ship the unmodified DLL as a separate file next to your executable — do not statically link it into the binary, embed it in a resource, or re-license it.
- Allow the end user to replace the DLL with a modified version of the same library. Dynamic linking against a separate file already satisfies this.
- Keep the LGPL notice and make the corresponding source of the library available (this repository, or a written offer).
- If you modify the DLL itself, those modifications must be released under `LGPL-2.1-or-later`.

Statically linking the libmodbus objects into your executable, or embedding the library so it cannot be replaced, brings the relinking requirements of LGPL-2.1 section 6 into play and is not recommended for closed-source products.

> This section summarises the license for convenience and is not legal advice. Review the full text in [`c_src/COPYING.LESSER`](c_src/COPYING.LESSER) or consult your legal counsel before shipping a commercial product.
