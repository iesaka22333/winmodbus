# Modbus 主从机动态库使用手册

适用库文件：`mine_modbus.dll`　｜　适用协议：Modbus RTU（串口）、Modbus TCP（网口）　｜　调用约定：`cdecl`

## 1. 概述

### 1.1 功能范围

本库是一个 Modbus RTU（RS-485/RS-232 串口）与 Modbus TCP（以太网）动态链接库，同时支持以下两种角色：

- 主站（Master）：主动读写传感器、变送器、PLC 等从站设备。
- 从站（Slave）：在本机内存中模拟一台 Modbus 设备，响应上位机的读写请求。

本库覆盖的功能码：0x01、0x02、0x03、0x04、0x05、0x06、0x0F、0x10、0x11、0x16、0x17，并提供非标准原始报文收发接口，以及浮点数、32 位整数与寄存器之间的转换工具。

### 1.2 内部加固机制

| 机制 | 说明 |
| :-- | :-- |
| 多线程安全锁 | 同一句柄可被多个线程并发调用，库对每次函数调用加锁，不会破坏内部状态。站号属于句柄状态，多线程轮询不同站号时，调用方需自行把“设置站号 + 读写”作为整体加锁（见第 9.1 节）。 |
| 断线自动重连 | 默认开启。连接级错误（如网线闪断导致连接复位、串口描述符失效）发生后，库在当次调用内尝试重连，该次调用仍返回 -1，后续调用恢复正常。超时、校验错误等协议级错误只清空接收缓冲区中的残留数据，不重连。可通过 `mb_set_auto_recovery` 关闭。 |
| 高编号串口兼容 | 可直接传入 `'COM12'` 等 COM10 及以上的串口名（以 COM 开头，不区分大小写），库自动补全为 `\\.\COM12` 形式，无需手工拼接。 |
| 默认快速超时 | 响应超时默认 200 ms，字节间隔超时默认 20 ms。设备掉线时，单次调用通常在约 0.2 秒内返回错误。自动恢复开启时，超时后的恢复流程会延长单次调用的总耗时，可接近 0.4 秒（见第 9.4 节）。可通过 `mb_set_timeout_ms` 修改。 |

## 2. 通用约定

### 2.1 地址约定（必须遵守）

本库所有函数中的地址参数均从 0 开始计数。设备说明书中常见的 `40001`、`30001` 等写法是 PLC 标号（含区号前缀），传入本库前必须减去对应区的基数。

| 设备说明书写法 | 所属区域 | 应调用的读取函数 | 功能码 | 传入 `addr` 的值 |
| :-- | :-- | :-- | :-: | :-- |
| `40001`（或 `0x0000`） | 4x 保持寄存器 | `mb_read_registers` | 03 | `0`（40001 - 40001） |
| `40010` | 4x 保持寄存器 | `mb_read_registers` | 03 | `9`（40010 - 40001） |
| `30001` | 3x 输入寄存器 | `mb_read_input_registers` | 04 | `0`（30001 - 30001） |
| `00001` | 0x 线圈（继电器） | `mb_read_bits` / `mb_write_bit` | 01 / 05 | `0`（00001 - 00001） |
| `10001` | 1x 离散输入（开关量） | `mb_read_input_bits` | 02 | `0`（10001 - 10001） |

### 2.2 返回值约定

| 函数类别 | 成功 | 失败 |
| :-- | :-- | :-- |
| 句柄创建函数（`mb_new_tcp`、`mb_new_rtu`） | 返回非零指针 | 返回 `nil`（0） |
| 其余有返回值的函数 | 返回值大于等于 0；读写类函数返回实际读写的寄存器（或位）个数 | 返回 -1（含通信超时） |
| 数据转换函数（`mb_get_float_*`、`mb_get_int32_*`） | 直接返回转换结果，不存在失败返回值 | 无 |

返回 -1 后，应立即调用 `mb_get_last_error_str()` 获取英文错误描述（例如 `Connection timed out` 通常表示线路未连接或站号错误），或调用 `mb_get_last_errno()` 获取错误数字码。错误码是线程局部变量，必须在发生错误的同一线程中、紧接着失败的调用读取。在其他线程读取，或中间又调用了其他库函数后再读取，得到的可能不是该次错误。

### 2.3 数据类型约定

| 类型 | 说明 |
| :-- | :-- |
| `TModbusHandle` | 句柄，本质为 `Pointer`，由 `mb_new_tcp` / `mb_new_rtu` 创建。 |
| `Word` | 16 位无符号整数，一个 Modbus 寄存器的数据宽度。寄存器数组的元素类型。 |
| `Byte` | 8 位无符号整数。位操作（线圈、离散输入）使用 `Byte` 数组，每个字节存放一个位的状态，取值 `0` 或 `1`。 |
| `Single` | 32 位浮点数，由两个连续寄存器组合而成。 |
| `PAnsiChar` | 以 `#0` 结尾的 ANSI 字符串指针，用于串口名、IP 地址、错误信息。 |
| 调用约定 | 所有导出函数均为 `cdecl`，声明时不得省略或改为 `stdcall`，否则会导致栈破坏。 |

### 2.4 典型调用流程

主站流程：`mb_new_rtu` / `mb_new_tcp` → `mb_set_slave` → `mb_connect` → 读写函数（循环）→ `mb_close` → `mb_free`。

从站流程：`mb_new_rtu` / `mb_new_tcp` → `mb_set_slave` → `mb_slave_init_mapping` → 连接（RTU 调用 `mb_connect`；TCP 调用 `mb_tcp_slave_listen_and_accept`）→ 在后台线程中循环调用 `mb_slave_poll_once` → `mb_close` → `mb_free`。

## 3. 连接、配置与销毁函数

主站与从站均需先使用本节函数创建并配置句柄。

| 函数 | 作用 | 参数 | 返回值 |
| :-- | :-- | :-- | :-- |
| `mb_new_rtu` | 创建串口（RS-485/RS-232）句柄 | `port_name`：串口名，如 `'COM3'`；`baud`：波特率，如 `9600`；`parity`：校验位的 ASCII 码，`78` 表示 N（无），`69` 表示 E（偶），`79` 表示 O（奇）；`data_bit`：数据位，通常为 `8`；`stop_bit`：停止位，通常为 `1` | 成功返回句柄，失败返回 `nil` |
| `mb_new_tcp` | 创建网口（TCP）句柄 | `ip`：目标 IP，如 `'192.168.1.10'`，作为从站时填 `'0.0.0.0'`；`port`：端口号，标准端口为 `502` | 成功返回句柄，失败返回 `nil` |
| `mb_set_slave` | 设置站号（设备地址） | `h`：句柄；`slave_id`：站号，范围 1 至 247，TCP 通常填 `1` | 0 成功，-1 失败 |
| `mb_get_slave` | 读取句柄当前的站号 | `h`：句柄 | 当前站号；失败返回 -1 |
| `mb_connect` | 打开串口或连接网口。TCP 连接超时沿用响应超时（默认 200 ms），网络较慢时应先调用 `mb_set_timeout_ms` 调大再连接 | `h`：句柄 | 0 成功，-1 失败（如串口被占用、网络不可达） |
| `mb_close` | 断开连接，句柄仍有效，可再次调用 `mb_connect`。可用于打断另一线程中阻塞的从站接收。若自动恢复仍开启，关闭后的下一次读写可能触发重连；需要彻底停止通信时，应先调用 `mb_set_auto_recovery(h, 0)` | `h`：句柄 | 无 |
| `mb_free` | 彻底销毁句柄并释放内存，程序退出前调用一次，调用后句柄作废。调用前必须确保没有线程仍在使用该句柄，包括从站轮询线程（见第 9.5 节） | `h`：句柄 | 无 |
| `mb_set_timeout_ms` | 修改超时时间 | `h`：句柄；`response_ms`：响应超时（毫秒），默认 200，不可为 0；`byte_ms`：字节间隔超时（毫秒），默认 20，为 0 表示禁用 | 0 成功，-1 失败 |
| `mb_set_auto_recovery` | 开关断线自动恢复。开启时，连接级错误触发自动重连，协议级错误（超时、校验错误等）触发接收缓冲区清理 | `h`：句柄；`enable_auto_reconnect`：`1` 开启（默认已开启），`0` 关闭 | 0 成功，-1 失败 |
| `mb_set_debug` | 在控制台窗口打印收发报文，用于调试。GUI 程序没有控制台，需先调用 `AllocConsole` | `h`：句柄；`flag`：`1` 开启，`0` 关闭 | 0 成功，-1 失败 |
| `mb_flush` | 清空接收缓冲区中的残留数据 | `h`：句柄 | 大于等于 0 成功（为丢弃的字节数），-1 失败 |
| `mb_get_last_errno` | 获取最近一次错误的数字码。线程局部，须在出错的同一线程读取 | 无 | 错误码整数 |
| `mb_get_last_error_str` | 获取最近一次错误的英文描述。线程局部，须在出错的同一线程读取 | 无 | `PAnsiChar` 字符串 |

## 4. 主站（Master）读写函数

主站用于主动读写其他设备。

说明：若同一条 RS-485 总线上挂有多台设备（例如站号 1 至 5），不需要创建多个句柄。只需 `mb_new_rtu` 与 `mb_connect` 各调用一次，每次读写前调用 `mb_set_slave(h, 站号)` 切换目标设备即可。多线程共用同一句柄时，“设置站号 + 读写”必须作为整体由调用方加锁（见第 9.1 节）。各函数单次读写个数的上限见第 9.2 节。

| 函数 | 功能码 | 作用 | 参数 | 返回值 |
| :-- | :-: | :-- | :-- | :-- |
| `mb_read_registers` | 0x03 | 读保持寄存器（4x 区，最常用） | `h`：句柄；`addr`：起始地址（从 0 起）；`nb`：读取个数；`dest`：接收数据的 `Word` 数组首地址 | 成功返回读到的个数，失败返回 -1 |
| `mb_read_input_registers` | 0x04 | 读输入寄存器（3x 区，只读数据，传感器常用） | 同 `mb_read_registers` | 成功返回读到的个数，失败返回 -1 |
| `mb_write_register` | 0x06 | 写单个保持寄存器 | `h`：句柄；`addr`：地址；`value`：写入值（`Word`，16 位无符号整数） | 成功返回 1，失败返回 -1 |
| `mb_write_registers` | 0x10 | 批量写多个保持寄存器 | `h`：句柄；`addr`：起始地址；`nb`：写入个数；`src`：待写入的 `Word` 数组首地址 | 成功返回写入个数，失败返回 -1 |
| `mb_read_bits` | 0x01 | 读多个线圈状态（0x 区） | `h`：句柄；`addr`：起始地址；`nb`：读取个数；`dest`：接收用 `Byte` 数组首地址，每个字节存放一个位（`0` 或 `1`） | 成功返回读到的个数，失败返回 -1 |
| `mb_read_input_bits` | 0x02 | 读多个离散输入状态（1x 区） | 同 `mb_read_bits` | 成功返回读到的个数，失败返回 -1 |
| `mb_write_bit` | 0x05 | 写单个线圈 | `h`：句柄；`coil_addr`：线圈地址；`status`：`1` 为吸合（ON），`0` 为断开（OFF） | 成功返回 1，失败返回 -1 |
| `mb_write_bits` | 0x0F | 批量写多个线圈 | `h`：句柄；`addr`：起始地址；`nb`：写入个数；`data`：存放 `0`/`1` 的 `Byte` 数组首地址 | 成功返回写入个数，失败返回 -1 |
| `mb_mask_write_register` | 0x16 | 按位掩码修改寄存器中指定的若干位。按 Modbus 标准，结果为 (原值 AND `and_mask`) OR (`or_mask` AND NOT `and_mask`) | `h`：句柄；`addr`：寄存器地址；`and_mask`：与掩码（`Word`）；`or_mask`：或掩码（`Word`） | 成功返回 1，失败返回 -1 |
| `mb_write_and_read_registers` | 0x17 | 一次通信同时完成多个寄存器的写入与读取 | `h`：句柄；`write_addr`：写起始地址；`write_nb`：写入个数；`src`：待写入 `Word` 数组首地址；`read_addr`：读起始地址；`read_nb`：读取个数；`dest`：接收用 `Word` 数组首地址 | 成功返回读取个数，失败返回 -1 |
| `mb_report_slave_id` | 0x11 | 读取从站设备的 ID 信息 | `h`：句柄；`max_dest`：接收缓冲区大小；`dest`：接收用 `Byte` 数组首地址 | 成功返回字节数，失败返回 -1 |
| `mb_send_raw_and_receive` | 自定义 | 发送非标准原始报文并接收应答。RTU 模式自动追加 CRC，TCP 模式自动追加 MBAP 头。应答长度按标准功能码推算，自定义功能码的应答可能超时或校验失败 | `h`：句柄；`raw_req`：发送字节数组首地址，内容为站号、功能码与数据；`req_len`：发送长度；`rsp_buf`：接收缓冲区，须不小于 260 字节 | 成功返回收到的总字节数，失败返回 -1 |

## 5. 数据转换工具函数

变送器经常使用两个连续的 16 位寄存器（`Word`）拼成一个 32 位浮点数（`Single`）或 32 位整数。字节序（字序）因设备厂商而异。如果读出的数值明显异常（例如 `1.23e-38`），通常是字节序选择错误，可更换下表中的其他字节序重试。国内设备较多使用 `cdab` 或 `abcd`。

以 32 位值 `A B C D`（A 为最高字节）为例，各字节序在两个寄存器中的排列如下：

| 字节序 | 寄存器 1（低地址） | 寄存器 2（高地址） | 说明 |
| :-- | :-- | :-- | :-- |
| `abcd` | `A B` | `C D` | 标准大端 |
| `cdab` | `C D` | `A B` | 高低字交换，最常用 |
| `badc` | `B A` | `D C` | 字内字节交换 |
| `dcba` | `D C` | `B A` | 完全小端 |

| 函数 | 作用 | 参数 | 返回值 |
| :-- | :-- | :-- | :-- |
| `mb_get_float_abcd` | 2 个寄存器转浮点数（ABCD） | `src`：长度为 2 的 `Word` 数组首地址 | `Single` |
| `mb_get_float_cdab` | 2 个寄存器转浮点数（CDAB） | 同上 | `Single` |
| `mb_get_float_badc` | 2 个寄存器转浮点数（BADC） | 同上 | `Single` |
| `mb_get_float_dcba` | 2 个寄存器转浮点数（DCBA） | 同上 | `Single` |
| `mb_set_float_abcd` | 浮点数拆成 2 个寄存器（ABCD），用于下发写入 | `f`：`Single` 数值；`dest`：长度为 2 的 `Word` 数组首地址 | 无 |
| `mb_set_float_cdab` | 浮点数拆成 2 个寄存器（CDAB） | 同上 | 无 |
| `mb_set_float_badc` | 浮点数拆成 2 个寄存器（BADC） | 同上 | 无 |
| `mb_set_float_dcba` | 浮点数拆成 2 个寄存器（DCBA） | 同上 | 无 |
| `mb_get_int32_abcd` | 2 个寄存器转 32 位有符号整数（ABCD） | `src`：长度为 2 的 `Word` 数组首地址 | `Integer` |
| `mb_get_int32_cdab` | 2 个寄存器转 32 位有符号整数（CDAB） | 同上 | `Integer` |
| `mb_set_int32_abcd` | 32 位整数拆成 2 个寄存器（ABCD） | `val`：整数；`dest`：长度为 2 的 `Word` 数组首地址 | 无 |
| `mb_set_int32_cdab` | 32 位整数拆成 2 个寄存器（CDAB） | 同上 | 无 |

注意：整数转换函数仅提供 `abcd` 与 `cdab` 两种字节序。

## 6. 从站（Slave）模拟设备函数

当工控机需要模拟一台下位机、被上位机读取或写入时，使用本节函数。从站在本机内存中维护四个数据区，由 `mb_slave_poll_once` 自动查表应答。

### 6.1 数据区与下标

| 数据区 | 对应读写函数的功能码 | 初始化参数 | 本机读写函数 |
| :-- | :-- | :-- | :-- |
| 0x 线圈 | 01、05、0F | `nb_bits` | `mb_slave_set_coil` / `mb_slave_get_coil` |
| 1x 离散输入 | 02 | `nb_input_bits` | `mb_slave_set_input_bit` / `mb_slave_get_input_bit` |
| 4x 保持寄存器 | 03、06、10、16、17 | `nb_registers` | `mb_slave_set_holding_reg` / `mb_slave_get_holding_reg`，以及批量版本 |
| 3x 输入寄存器 | 04 | `nb_input_registers` | `mb_slave_set_input_reg` / `mb_slave_get_input_reg`，以及批量版本 |

本机读写函数中的 `index` 为数据区数组下标，取值范围为 0 至 个数减 1。使用 `mb_slave_init_mapping` 初始化时，下标与上位机请求的 Modbus 地址一一对应；使用 `mb_slave_init_mapping_ex` 设置了非 0 起始地址时，上位机地址为起始地址加下标。

### 6.2 函数说明

| 函数 | 作用 | 参数 | 返回值 |
| :-- | :-- | :-- | :-- |
| `mb_slave_init_mapping` | 第 1 步：在内存中开辟四区寄存器表，起始地址为 0。应只在启动时调用一次：重复调用会先释放旧表再创建新表，原有数据丢失；新表创建失败时旧表同样已被释放，需重新初始化 | `h`：句柄；`nb_bits`：线圈个数；`nb_input_bits`：离散输入个数；`nb_registers`：保持寄存器个数；`nb_input_registers`：输入寄存器个数。各参数不得为负数 | 0 成功，-1 失败（句柄为空、参数为负、内存不足） |
| `mb_slave_init_mapping_ex` | 同上，但可为每个区设置非 0 起始地址 | `h`：句柄；依次传入线圈、离散输入、保持寄存器、输入寄存器四个区的起始地址与个数（`start_bits, nb_bits, start_input_bits, nb_input_bits, start_registers, nb_registers, start_input_registers, nb_input_registers`）。各参数不得为负数 | 同上 |
| `mb_slave_set_holding_reg` | 向本机保持寄存器写入数值（供上位机读取） | `h`：句柄；`index`：下标；`value`：`Word` 数值 | 0 成功，-1 失败（映射表未初始化、下标越界） |
| `mb_slave_get_holding_reg` | 读取本机保持寄存器的值（查看上位机写入了什么） | `h`：句柄；`index`：下标；`out_val`：接收数值的 `Word` 变量（传址） | 同上 |
| `mb_slave_set_input_reg` / `mb_slave_get_input_reg` | 读写本机 3x 输入寄存器 | 同上 | 同上 |
| `mb_slave_set_coil` / `mb_slave_get_coil` | 读写本机 0x 线圈。写入时非 0 值按 `1` 存储 | `h`：句柄；`index`：下标；`val` 或 `out_val`：`Byte` 类型 | 同上 |
| `mb_slave_set_input_bit` / `mb_slave_get_input_bit` | 读写本机 1x 离散输入。写入时非 0 值按 `1` 存储 | 同上 | 同上 |
| `mb_slave_set_holding_regs_bulk` | 批量写入一片保持寄存器 | `h`：句柄；`start_index`：起始下标；`count`：个数，须大于 0；`src`：`Word` 数组首地址 | 0 成功，-1 失败（映射表未初始化、范围越界、`count` 不合法） |
| `mb_slave_get_holding_regs_bulk` | 批量读取一片保持寄存器 | `h`：句柄；`start_index`：起始下标；`count`：个数，须大于 0；`dest`：`Word` 数组首地址 | 同上 |
| `mb_slave_set_input_regs_bulk` | 批量写入一片输入寄存器 | 参数同 `mb_slave_set_holding_regs_bulk` | 同上 |
| `mb_slave_get_input_regs_bulk` | 批量读取一片输入寄存器 | 参数同 `mb_slave_get_holding_regs_bulk` | 同上 |
| `mb_tcp_slave_listen_and_accept` | TCP 从站专用：监听端口并等待上位机连入，会阻塞直到有上位机连入。首次调用创建监听端口，上位机断开后再次调用会关闭已断开的会话并复用监听端口等待新连接 | `h`：句柄；`nb_connection`：监听队列长度，填 `1` 即可。同一句柄同一时刻只服务一个上位机 | 0 以上成功，-1 失败 |
| `mb_slave_poll_once` | 从站核心循环：接收一帧请求，并根据本机寄存器表自动回复。应放在后台线程的循环中持续调用。等待请求期间不持锁，不影响其他线程读写本机寄存器 | `h`：句柄 | 大于 0：已应答，值为应答字节数；0：请求被忽略（如站号不匹配）；-1：失败（映射表未初始化、句柄正在关闭、连接断开等） |
| `mb_slave_receive_raw` | 低层接口：只接收一帧原始请求，不自动应答 | `h`：句柄；`req_buf`：接收缓冲区 `Byte` 数组首地址，不小于 260 字节 | 大于 0：收到的字节数；0：请求被忽略；-1：失败 |
| `mb_slave_reply_normal` | 低层接口：对 `mb_slave_receive_raw` 收到的请求，按寄存器表给出正常应答 | `h`：句柄；`req_buf`：请求缓冲区；`req_len`：请求长度，取 `mb_slave_receive_raw` 的返回值 | 大于等于 0：应答字节数；-1：失败 |
| `mb_slave_reply_exception` | 低层接口：对收到的请求返回 Modbus 异常应答 | `h`：句柄；`req_buf`：请求缓冲区；`exception_code`：Modbus 异常码 | 大于等于 0：应答字节数；-1：失败 |

说明：

1. 大多数场景只需使用 `mb_slave_poll_once`。`mb_slave_receive_raw`、`mb_slave_reply_normal`、`mb_slave_reply_exception` 仅在需要自行拦截、过滤请求或自定义异常应答时使用。
2. 本机读写函数遵循第 2.2 节的返回值约定：0 成功，-1 失败。
3. TCP 从站在上位机断开后，`mb_slave_poll_once` 返回 -1。此时重新调用 `mb_tcp_slave_listen_and_accept` 即可等待上位机重新连入。
4. 运行期间应只用 `set` / `get` 函数更新本机寄存器，不要重复调用 `mb_slave_init_mapping`（见第 9.5 节）。

## 7. RS-485 硬件引脚流控

绝大多数 USB 转 RS-485 转换器和现代串口卡由硬件自动切换收发方向，不需要调用本节函数。仅当使用需要通过 RTS 引脚电平控制 RS-485 收发方向的老式板载串口时才使用。

| 函数 | 作用 | 参数 | 返回值 |
| :-- | :-- | :-- | :-- |
| `mb_rtu_set_serial_mode` | 设置串口模式 | `h`：句柄；`mode`：`0` 为 RS-232，`1` 为 RS-485 | 0 成功，-1 失败 |
| `mb_rtu_set_rts` | 设置发送时 RTS 引脚的电平策略 | `h`：句柄；`mode`：`0` 不使用，`1` 发送时拉高 RTS，`2` 发送时拉低 RTS | 0 成功，-1 失败 |
| `mb_rtu_set_rts_delay` | 设置 RTS 切换前后的延时 | `h`：句柄；`us`：延时，单位微秒 | 0 成功，-1 失败 |

平台限制：本节函数依赖 libmodbus 对操作系统串口驱动的支持。`mb_rtu_set_serial_mode` 依赖 Linux 的 RS-485 内核接口，在 Windows 下预期返回 -1；RTS 相关函数的实际效果取决于串口驱动。请在目标环境实测后再采用。

## 8. Delphi 调用

### 8.1 声明单元 uMineModbus.pas

将下列代码保存为 `uMineModbus.pas` 并放入工程目录，然后在主窗体的 `uses` 子句中加入 `uMineModbus`，即可调用本库全部函数。`mine_modbus.dll` 应放置在可执行文件同目录下或系统搜索路径中。

注意：所有函数声明末尾均带有 `cdecl;`，不得删除或改为 `stdcall`，否则会导致调用栈破坏。

```pascal
unit uMineModbus;

interface

uses
  Windows, SysUtils;

const
  MODBUS_DLL = 'mine_modbus.dll';

type
  // Modbus 句柄类型（当作普通指针使用）
  TModbusHandle = Pointer;
  PWordArray = ^TWordArray;
  TWordArray = array[0..32767] of Word;
  PByteArray = ^TByteArray;
  TByteArray = array[0..32767] of Byte;

// ==================== 1. 连接与基础配置（13 个）====================
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

// ==================== 2. RS-485 硬件方向流控（3 个）====================
function mb_rtu_set_serial_mode(h: TModbusHandle; mode: Integer): Integer; cdecl; external MODBUS_DLL;
function mb_rtu_set_rts(h: TModbusHandle; mode: Integer): Integer; cdecl; external MODBUS_DLL;
function mb_rtu_set_rts_delay(h: TModbusHandle; us: Integer): Integer; cdecl; external MODBUS_DLL;

// ==================== 3. 主站（Master）读写功能（12 个）====================
// 0x01 读线圈, 0x02 读离散输入
function mb_read_bits(h: TModbusHandle; addr: Integer; nb: Integer; dest: PByte): Integer; cdecl; external MODBUS_DLL;
function mb_read_input_bits(h: TModbusHandle; addr: Integer; nb: Integer; dest: PByte): Integer; cdecl; external MODBUS_DLL;
// 0x03 读保持寄存器, 0x04 读输入寄存器
function mb_read_registers(h: TModbusHandle; addr: Integer; nb: Integer; dest: PWord): Integer; cdecl; external MODBUS_DLL;
function mb_read_input_registers(h: TModbusHandle; addr: Integer; nb: Integer; dest: PWord): Integer; cdecl; external MODBUS_DLL;
// 0x05 写单线圈, 0x06 写单寄存器
function mb_write_bit(h: TModbusHandle; coil_addr: Integer; status: Integer): Integer; cdecl; external MODBUS_DLL;
function mb_write_register(h: TModbusHandle; addr: Integer; value: Word): Integer; cdecl; external MODBUS_DLL;
// 0x0F 写多线圈, 0x10 写多寄存器
function mb_write_bits(h: TModbusHandle; addr: Integer; nb: Integer; data: PByte): Integer; cdecl; external MODBUS_DLL;
function mb_write_registers(h: TModbusHandle; addr: Integer; nb: Integer; src: PWord): Integer; cdecl; external MODBUS_DLL;
// 0x16 掩码写, 0x17 读写合一, 0x11 读设备 ID, 非标原始帧
function mb_mask_write_register(h: TModbusHandle; addr: Integer; and_mask: Word; or_mask: Word): Integer; cdecl; external MODBUS_DLL;
function mb_write_and_read_registers(h: TModbusHandle; write_addr: Integer; write_nb: Integer; src: PWord; read_addr: Integer; read_nb: Integer; dest: PWord): Integer; cdecl; external MODBUS_DLL;
function mb_report_slave_id(h: TModbusHandle; max_dest: Integer; dest: PByte): Integer; cdecl; external MODBUS_DLL;
function mb_send_raw_and_receive(h: TModbusHandle; raw_req: PByte; req_len: Integer; rsp_buf: PByte): Integer; cdecl; external MODBUS_DLL;

// ==================== 4. 从站（Slave）寄存器映射与应答（19 个）====================
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

// ==================== 5. 浮点数与 32 位整数转换工具（12 个）====================
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

implementation

end.
```

### 8.2 主站调用示例：读取传感器浮点数

以下示例通过 RS-485 读取站号为 1 的设备，从保持寄存器地址 0 开始读取 2 个寄存器，并按 `cdab` 字节序转换为浮点数。

```pascal
procedure TForm1.ReadSensor;
var
  h: TModbusHandle;
  regs: array[0..1] of Word;
  value: Single;
begin
  h := mb_new_rtu('COM3', 9600, Ord('N'), 8, 1);
  if h = nil then
    raise Exception.Create('创建串口句柄失败');
  try
    mb_set_slave(h, 1);
    if mb_connect(h) < 0 then
      raise Exception.Create('连接失败: ' + string(AnsiString(mb_get_last_error_str())));

    if mb_read_registers(h, 0, 2, @regs[0]) < 0 then
      raise Exception.Create('读取失败: ' + string(AnsiString(mb_get_last_error_str())));

    value := mb_get_float_cdab(@regs[0]);
    Memo1.Lines.Add(FloatToStr(value));
  finally
    mb_close(h);
    mb_free(h);
  end;
end;
```

实际应用中，句柄通常在程序启动时创建并连接一次，在定时器或后台线程中重复读写，程序退出时再调用 `mb_close` 与 `mb_free`。

### 8.3 主站调用示例：写继电器与写寄存器

```pascal
// 吸合 0 号线圈（地址 00001）
if mb_write_bit(h, 0, 1) < 0 then
  ShowMessage(string(AnsiString(mb_get_last_error_str())));

// 向保持寄存器地址 9（40010）写入 1000
if mb_write_register(h, 9, 1000) < 0 then
  ShowMessage(string(AnsiString(mb_get_last_error_str())));
```

### 8.4 从站调用示例：TCP 从站

```pascal
var
  SlaveH: TModbusHandle;

procedure StartSlave;
begin
  SlaveH := mb_new_tcp('0.0.0.0', 502);
  mb_set_slave(SlaveH, 1);
  // 线圈 0 个、离散输入 0 个、保持寄存器 100 个、输入寄存器 0 个
  mb_slave_init_mapping(SlaveH, 0, 0, 100, 0);
  // 预置数据，供上位机读取
  mb_slave_set_holding_reg(SlaveH, 0, 1234);
end;

// 在后台线程的 Execute 中运行
procedure SlaveThreadBody;
var
  v: Word;
begin
  if mb_tcp_slave_listen_and_accept(SlaveH, 1) < 0 then Exit;
  while not Terminated do
  begin
    if mb_slave_poll_once(SlaveH) < 0 then
      Break;  // 连接断开或出错，必要时重新调用 listen_and_accept
    // 读取上位机写入的值
    mb_slave_get_holding_reg(SlaveH, 1, v);
  end;
end;
```

## 9. 使用限制与注意事项

### 9.1 多线程使用

库对每次函数调用加锁，同一句柄可被多线程并发调用而不会破坏内部状态，但存在以下约束：

1. 站号是句柄的状态。`mb_set_slave` 与随后的读写函数是两次独立调用，之间可能被其他线程改动站号。多个线程轮询同一句柄上的不同站号时，调用方必须用自己的锁，把“设置站号 + 读写”作为整体保护。
2. 一个串口只能打开一次，同一条串口总线应共用一个句柄，并配合上述外层锁。
3. 从站轮询线程在等待请求期间不持锁，其他线程可并发调用 `mb_slave_set_*` / `mb_slave_get_*` 更新或读取本机寄存器。
4. 错误码是线程局部变量，需在出错的线程中读取。

### 9.2 单次读写个数上限

超过上限的调用返回 -1。

| 函数 | 功能码 | 单次上限 |
| :-- | :-: | :-- |
| `mb_read_bits`、`mb_read_input_bits` | 01、02 | 2000 个位 |
| `mb_read_registers`、`mb_read_input_registers` | 03、04 | 125 个寄存器 |
| `mb_write_bits` | 0F | 1968 个位 |
| `mb_write_registers` | 10 | 123 个寄存器 |
| `mb_write_and_read_registers` | 17 | 写 121 个、读 125 个寄存器 |

### 9.3 缓冲区要求

| 缓冲区 | 最小大小 |
| :-- | :-- |
| `mb_send_raw_and_receive` 的 `rsp_buf` | 260 字节 |
| `mb_slave_receive_raw` 的 `req_buf` | 260 字节 |
| 读位函数的 `dest` | 至少 `nb` 个 `Byte` |
| 读寄存器函数的 `dest` | 至少 `nb` 个 `Word` |
| `mb_report_slave_id` 的 `dest` | 至少 `max_dest` 字节 |

### 9.4 超时与重连行为

1. 响应超时默认 200 ms。自动恢复开启（默认）时，一次超时之后库会再等待一个响应超时周期并清空接收缓冲区，单次调用的总耗时可接近响应超时的两倍（默认约 400 ms）。需要严格的耗时上限时，缩短 `response_ms` 或关闭自动恢复。
2. 自动重连只在连接级错误时发生。纯超时只清理缓冲区，不重连。触发重连的那次调用仍返回 -1。
3. `mb_close` 之后，若自动恢复仍开启，下一次读写可能重新连接。要彻底停止通信，先调用 `mb_set_auto_recovery(h, 0)`。
4. TCP 的 `mb_connect` 沿用响应超时作为连接超时，网络较慢时应先调大超时再连接。

以上时间相关行为依据 libmodbus 3.1.x 的实现，建议在目标环境实测。

### 9.5 句柄生命周期

1. 退出顺序：先让从站轮询线程退出（可调用 `mb_close` 打断其阻塞的接收，并等待线程结束），再调用 `mb_free`。`mb_free` 不会等待其他线程，句柄释放后仍在使用它的线程会访问已释放的内存。
2. `mb_slave_init_mapping` / `mb_slave_init_mapping_ex` 只在启动时调用一次。从站运行期间重复调用不会崩溃，但原有数据会丢失，上位机可能读到空表。运行期间只用 `set` / `get` 函数更新数据。
3. 新表创建失败时，旧表已被释放。此后各从站读写函数返回 -1，直到重新初始化成功。
4. `mb_free` 之后将句柄变量置为 `nil`，不再使用。

## 10. 常见问题排查

| 现象 | 可能原因 | 处理方法 |
| :-- | :-- | :-- |
| 函数返回 -1，错误为 `Connection timed out` | 线路未连接、站号错误、波特率或校验位与设备不一致 | 核对接线（A/B 是否接反）、`mb_set_slave` 站号、`mb_new_rtu` 的串口参数 |
| 读取到的数据整体偏移一位 | 地址未按 0 起算 | 按第 2.1 节将说明书中的 PLC 标号减去基数 |
| 浮点数读出为极小或极大的异常值 | 字节序选择错误 | 在 `abcd`、`cdab`、`badc`、`dcba` 中依次尝试 |
| `mb_connect` 失败 | 串口被其他程序占用，或串口号不存在；TCP 网络较慢超过 200 ms | 关闭占用串口的程序，在设备管理器中确认串口号；TCP 先用 `mb_set_timeout_ms` 调大超时 |
| 多台设备同总线，偶尔读不到 | 设备响应慢，超过默认 200 ms | 使用 `mb_set_timeout_ms` 适当增大 `response_ms` |
| 多线程轮询不同站号，读到的数据对不上 | 线程之间在 `mb_set_slave` 与读写之间互相改动了站号 | 将“设置站号 + 读写”作为整体加锁（见第 9.1 节） |
| 需要查看收发的原始报文 | 无 | 调用 `mb_set_debug(h, 1)`；GUI 程序需先调用 `AllocConsole` 才有控制台输出 |
| 调用后程序崩溃或栈异常 | 声明使用了 `stdcall` 或遗漏 `cdecl` | 所有声明保持 `cdecl` |
| 退出程序时崩溃 | 从站线程仍在使用句柄时调用了 `mb_free`，或释放后继续使用句柄 | 先让从站线程退出再调用 `mb_free`，之后将句柄置为 `nil`（见第 9.5 节） |
| 从站运行中上位机读到全 0 | 运行期间重复调用了 `mb_slave_init_mapping` | 只在启动时初始化一次，之后用 `set` / `get` 更新 |
| TCP 从站在上位机断开后不再应答 | 连接已断开，`mb_slave_poll_once` 返回 -1 | 重新调用 `mb_tcp_slave_listen_and_accept` 等待重连 |
