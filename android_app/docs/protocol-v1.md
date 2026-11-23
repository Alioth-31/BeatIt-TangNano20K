# NanoSynth UART / BLE 协议 v1

**简体中文** · [English](protocol-v1.en.md)

**Android 0.3.1 / FPGA App 桥接接口契约。** 基础合成器顶层不含此接口，需使用 App 桥接构建。Android 实现组帧、BLE 发送、ACK、状态及实体键/实际参数事件接收。

BLE 模块透明转发字节流，FPGA UART 115200 / 8N1（双方一致配置），3.3 V IO，共地。v3923 BLE 配置：模块 TX → PIN71（FPGA RX），模块 RX ← PIN72（FPGA TX）。USB 配置 UART TX69 / RX70 已接板载 BL616，不能并接外部发送端。每份位流仅有一个活动控制通道。BLE 单包按 20 字节分片，不要求特定 MTU；接收端不可把一包通知当一整帧。服务优先 NUS：服务 `6e400001-b5a3-f393-e0a9-e50e24dcca9e`，App 写 `…0002…`，App 订阅 `…0003…`；兼容 HM-10 `FFE0/FFE1`，需支持回传通知。

## 帧格式

| 字段 | 字节数 | 含义 |
|---|---:|---|
| 同步 | 2 | A5 5A |
| 版本 | 1 | 01 |
| 类型 | 1 | 见下表 |
| 序号 | 2 | 小端，无符号 16 bit |
| 长度 | 1 | 0..64 |
| 载荷 | 长度 | 定义见下 |
| CRC | 2 | 小端 CRC16-CCITT-FALSE，初值 FFFF，多项式 1021；覆盖版本至载荷 |

错误版本/长度/CRC 丢弃，扫描下一个 A5 5A；不得把错误状态应用到合成器。CRC 测试向量 `123456789` → `29B1`。最大帧 73 字节。UART 不完整帧接收超时为 20 ms。

所有整数小端。key ID 对应 `rtl/note_table.vh`：0..7 = MIDI 60,62,64,65,67,69,71,72；8..31 = MIDI 36..59。掩码 bit 31 必须作为无符号位操作。

## App → FPGA

| 类型 | 名称 | 载荷 |
|---:|---|---|
| 01 | HELLO | 空 |
| 02 | GET_STATUS | 空 |
| 03 | GET_INPUTS（可选诊断） | 空 |
| 10 | SET_STATE | mask:u32, volume:u16, bend:i8, preset:u8（8 字节） |
| 11 | SET_MAP | 八个 key ID:u8（8 字节） |
| 12 | SET_KEYS | 远程 mask:u32（4 字节，需 capabilities bit3） |
| 13 | SET_PARAMS | fields:u8, volume:u16, bend:i8, preset:u8（5 字节，需 bit3） |

SET_STATE 是完整的**远程按键状态**，和实体按键状态分别维护，按位 OR 后进入声部分配。volume 0..65535 映射到核心 0..65536；bend −32..+32 表示 −2..+2 半音，步进 1/16 半音，对应 bend_table 下标 bend+32；preset 0..2。

SET_KEYS 只更新远程键，不更新参数。SET_PARAMS 的 fields 为 1..7：bit0 音量、bit1 弯音、bit2 包络；保留位拒绝，只验证/更新选中的字段。不含键状态，不刷新音符看门狗。volume 65535 映射核心 65536，其余数值直接映射。

状态在 sample_ce 边界生效；ACK 在验证范围并应用状态后发出。实体编码器相对当前实际值增减，同一采样内实体操作优先。标准音量步进 2048，0..65535；弯音步进 1，−32..32；按压归零或切换包络。

扩展固件下 App 即时发送 SET_KEYS，参数约 50 ms 合并为 SET_PARAMS，只发送用户改变的字段；空闲每 200 ms 发送 SET_KEYS。固件**1 秒未收到有效 SET_KEYS 或 SET_STATE 时必须清除远程按键**，保留实体按键；即使蓝牙链路还在也要执行。SET_PARAMS 不能延续已卡住的远程键。App 有 2 秒 ACK 超时和 3 秒有效响应超时，超时断开并停止手机音符。

SET_MAP 设置实体八键映射；有键按下时拒绝为 busy。App 本地映射可独立工作；固件声明 MAP 能力时才下发。初始实体映射与 App 默认一致；GET_STATUS 不返回映射，若固件持久化自定义映射，应后续增加读取扩展。

## FPGA → App

| 类型 | 名称 | 载荷 |
|---:|---|---|
| 80 | ACK | request_type:u8, status:u8（2 字节） |
| 81 | HELLO_REPLY | version:u8, voices:u8, capabilities:u8, sample_rate:u32, supported_mask:u32, firmware_id:u16（13 字节） |
| 82 | STATUS | active_voices:u8, faults:u8, remote_mask:u32, physical_mask:u32, volume:u16, bend:i8, preset:u8, frame_counter:u32（18 字节） |
| 83 | EVENT | frame_counter:u32, key_id:u8, down:u8（6 字节） |
| 84 | PARAM_EVENT | frame_counter:u32, volume:u16, bend:i8, preset:u8（8 字节） |
| 85 | INPUTS（可选诊断） | raw_keys_n:u8, debounced_held:u8（2 字节） |

HELLO_REPLY、ACK、STATUS 的序号回显 App 请求序号。App HELLO_REPLY 还要求版本 1、采样率 48000、voices>0、supported_mask≠0、STATE 能力，不匹配不能进入 ready。桥接固件 HELLO capabilities=0x0F，firmware_id=0x0101。

capabilities：bit0=STATE 必须，bit1=MAP 可选，bit2=实体按键 EVENT 可选，bit3=SET_KEYS / SET_PARAMS / PARAM_EVENT 扩展，其余保留。voices 是实际复音数量，不是可选音高数量。supported_mask 是可演奏 key ID。

ACK status：0=接受，1=载荷/范围错误，2=忙，3=不支持。每个 SET_STATE / SET_MAP / SET_KEYS / SET_PARAMS 都回 ACK，类型字段对应原命令。未实现能力勿宣称。faults：bit0=音频供数故障，bit1=UART 接收/命令队列溢出，bit2=事件队列溢出，其余保留；复位前保持置位。非零值提示异常并将当前记录标记不完整；已知故障未清除时，新开始的记录也标记不完整。

GET_INPUTS / INPUTS 用于电脑接线诊断，序号回显请求。raw_keys_n 是两级同步后的八键原始低有效 GPIO 电平；debounced_held 是送入桥接器的消抖键状态，bench 构建关闭实体键时为 0。该命令不刷新远程键看门狗，不影响音频；Android 当前不使用它，旧固件可以不支持。

EVENT **只回传实体按键**，经同步消抖后的状态转换；不要回传远程键，避免记录两份手机音符。down 仅 0/1。PARAM_EVENT 在实际全局参数改变时发送，包含实体和远程操作应用后的实际值，每个事件携带完整参数状态。frame_counter 每 48 kHz 采样加 1。

EVENT 与 PARAM_EVENT **共享同一个连续 16 bit 事件序号**，回绕到 0；ACK/STATUS 使用请求序号，不能混入事件计数。App 据两类事件共同检测缺失和去重。tick 换算采用 48 帧/ms，延迟到达的记录保存时按时间排序。STATUS / PARAM_EVENT 更新界面，不触发反馈命令。待发及等待 ACK 的手机字段保留最新编辑；参数 ACK 后 GET_STATUS 读取实际仲裁结果。早于已接受参数 tick 的状态不能覆盖新的实时界面。

实时状态与录制历史分开维护：声明 EVENT 的固件以 EVENT 记录实体音符，声明 bit3 的固件以 PARAM_EVENT 记录实际参数；STATUS 仅更新界面和录制初始基线，避免与事件重复。排队事件即使早于后来到达的 STATUS，仍按采样 tick 进入录制历史，不会丢掉短音或中间参数变化。早于录制开始边界的事件只修正尚未过时的基线，不生成重复 note-on；晚于边界的事件单独保留。旧固件缺少对应事件能力时保留 STATUS 快照记录回退路径。

App 握手为 HELLO → 匹配的 HELLO_REPLY → GET_STATUS → 匹配且有效的 STATUS → SET_KEYS(0) → 匹配的成功 ACK → ready。总握手期限 2500 ms，清键 ACK 期限 2000 ms；超时主动断开并清空未完成请求，迟到的 ACK 无法重新进入 ready。读取实际参数之前不写参数；清键阶段到达的实体/参数事件也同步，避免丢失握手期间的新状态。旧固件未声明 bit3 时使用读回参数的 SET_STATE(0) 清键，随后保留旧完整状态路径；其完整参数心跳不提供扩展路径的实体旋钮并行控制保障。

GET_STATUS 至少返回一次完整状态；实体状态先回 STATUS 后续回 EVENT，避免启动录制时漏掉已按下的键。重复 STATUS 不应重复记录不变的参数/键状态。STATUS 的采样 tick 为该快照覆盖的边界；若回复先于排队事件送达，App 消费旧事件序号并保留历史，但实时界面忽略 tick ≤ 已接受快照的实体状态，避免重新激活已松开的键。

## 手机曲库跟弹

琴体跟弹要求 HELLO 能力位 7 和 2。App 先用 GET_PERFORMANCE（0x24，回复 0x89）读取设置状态、实体演奏键基线、配置版本与采样计数，再用 GET_KEY_PITCHES（0x25，回复 0x8B）读取同版本的八键 MIDI 音高。曲谱留在手机上。App 使用实体 EVENT 的键号判断起音和释放，每批按键事件在配置版本确认后计入练习。配置版本改变、事件缺失、超时或断连会停止本次判断。

启用实体控制、外设和练习模块的新版桥接在 HELLO 中报告固件版本 0x0102。SET_PRACTICE_LIGHTS（0x2A）接收 3 字节，依次为 8 位实体目标键掩码和 16 位小端配置版本。掩码为零时释放手机灯光控制。常规 ACK 的状态 1 表示长度错误，2 表示设置模式、板载练习模式、键灯离线或版本不匹配，3 表示固件缺少此功能。App 练习期间持续续租，FPGA 在约一秒未收到有效目标后恢复本地灯光。进入设置或板载练习、键位配置变化和灯驱动掉线都会清除手机目标。GET_GUIDE 第 7 字节（从零计数）继续回传灯驱动已应用的实际掩码。

## 固件实现验收

1. 随机 UART/BLE 分片、错误 CRC、噪声、最大长度后仍能重新同步。
2. HELLO 采样率与能力准确，错误参数拒绝；SET_STATE 不能改写实体按键身份。
3. 远程/实体同时按同音，单侧释放不关掉另一侧；断链 ≤1 秒远程音符释放。
4. 在采样边界更新全局参数，频率更新保持相位连续；不从 App 传 PCM 播放。
5. 实体按键 EVENT 与 PARAM_EVENT 共享序号及采样 tick，事件队列溢出置 faults，App 标记不完整记录。
6. 四复音和无线演奏延迟实测，独立于既有实体链路 ≤10 ms 验收。
