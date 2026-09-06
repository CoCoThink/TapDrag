# TapDrag 维护文档

## 1. 产品边界

TapDrag 只负责一件事：在 macOS 原生触控板拖移关闭时，实现可立即释放的双击拖动。

后续修改应维持单一手势路径，避免重新引入会竞争同一鼠标事务的并行实现。

## 2. 目录

| 路径 | 用途 |
| --- | --- |
| `TapDrag/Sources/main.m` | 进程入口。 |
| `TapDrag/Sources/AppDelegate.{h,m}` | 菜单、权限和 macOS 应用生命周期协调。 |
| `TapDrag/Sources/MultitouchManager.{h,m}` | 私有框架加载、设备枚举和 IOKit 热插拔。 |
| `TapDrag/Sources/TapDragEngine.{h,m}` | 应用层接口、触点识别、event tap、合成事务和诊断。 |
| `TapDrag/Info.plist` | 应用名、版本、Bundle ID 和菜单栏应用配置。 |
| `TapDrag/Resources/AppIcon.png` | 应用图标源文件。 |
| `TapDrag/build.sh` | 编译、组装、签名和签名验证。 |
| `tests/touch_state_tests.m` | 状态机与手势边界回归测试。 |
| `docs/MANUAL_TESTING.md` | 依赖真实界面、硬件和系统生命周期的人工测试清单。 |
| `scripts/generate-app-icon.m` | 可复现生成图标源文件。 |
| `scripts/create-local-signing-identity.sh` | 一次性创建稳定的本地签名身份。 |
| `scripts/signing-status.sh` | 检查签名身份和 designated requirement。 |
| `scripts/package-release.sh` | 生成发布压缩包。 |

模块依赖保持单向：`main.m` 创建 `TDAppDelegate`；应用层协调 `TDMultitouchManager` 与 `TapDragEngine`；设备管理器只把设备能力、设备列表和 raw contact frame 交给引擎。所有手势状态、输入锁、event tap 句柄及合成事件资源均由 `TapDragEngine.m` 独占，应用层不得绕过 `TapDragEngine.h` 访问内部状态。`TDGestureEngineSuspendInput()` 必须在一个操作中关闭输入门、释放事务并重置 raw 状态；`TDGestureEngineSetMultitouchDevices()` 必须同时更新设备数组与就绪状态；`TDGestureEngineResumeInput()` 在功能启用时自行验证设备及两个主动 event tap，调用方不能强行解除暂停。状态机白盒测试直接编译引擎实现，以验证文件内的锁和事务边界，同时用测试事件工厂隔离 WindowServer 的 event-source 生命周期。

## 3. 运行前提

1. 系统“轻点来点按”开启。
2. 系统触控板“拖移”关闭。
3. TapDrag 菜单中的 `Enabled` 开启。
4. 已授予辅助功能权限；若系统单独提示，也需授予输入监控权限。

原生拖移开启时，`replacementActive()` 返回 `NO`。这是互斥保护，不应改成与系统拖移并行。

## 4. 输入与输出

输入处理包括：

- `MultitouchSupport.framework` 的 raw contact frame，决定真实接触开始、移动、身份变化和抬起。
- HID event tap 对与唯一 raw 单指 tap 在时间和坐标上匹配的触控子类型点击执行首击缓冲，在事件进入 WindowServer 时阻止首击提前生效。拥有事务时消费原生 movement，将替代拖动与 down/up 在同一锁保护下从 HID 发布。
- annotated-session 主动按钮过滤器作为下游生成事件的兜底，与 HID 共用首击缓冲及事务所有权检查。确认拖动时取消首击，否则补发普通点击。不能只在 annotated-session 缓冲而从 HID 放行匹配的首击；Dock 文件夹弹出内容也必须走这条统一路径。各拦截层的位置见 [Apple CGEventTapLocation](https://developer.apple.com/documentation/coregraphics/cgeventtaplocation?language=objc)。
- annotated-session 层的只读观察器仅记录下游事件，不参与拖动状态迁移；观察器失效不能中断拖动。

输出是一条带 `DoubleTapTag` 的完整事务：

```text
leftMouseDown -> leftMouseDragged* -> leftMouseUp
```

`mouseUp` 必须由真实 raw finger lift 驱动。不要添加固定延迟释放、系统 grace period 等待或影子拖动会话。

## 5. 手势判定

- 第一次接触必须在 250 ms 内结束，且移动不超过阈值。
- 第二次接触与第一次 raw lift 的间隔必须在 30–160 ms 内，同时受更短的系统双击间隔约束。
- 第二次接触移动超过 1.3 mm 时立即确认拖动。物理毫米坐标有限且起止点不是设备的未填充零值时只使用该阈值；否则使用归一化坐标作为备用。
- TapDrag 作为解释 raw 触控板状态并生成鼠标事务的用户态输入工具，synthetic down/drag/up 必须使用 `kCGEventSourceStateHIDSystemState`。在 `Owned` 阶段消费原生 movement 并创建带本事务 event number 的 `leftMouseDragged`，保留坐标、delta 和修饰键，使用当前单调时间戳与本工具真实来源身份；不要伪造 source PID/UID/GID，也不要把 WindowServer 的 `target/window` 注释当作可靠路由。禁止原地返回修改后的原生 movement：实测该路径可越过异步发布的 down。
- 第二次接触保持 180 ms 也可确认拖动意图。
- 任意多指接触使候选失效。
- 物理按压产生的 native mouse-down 若发生在第一次接触尚未结束时，不得成为首击候选。
- 首击缓冲要求 HID 或 annotated-session 的 `leftMouseDown` 为 `NSEventSubtypeTouch`，并在首击决策窗口内到达，事件坐标与 raw lift 时指针相距不超过 12 points；必须恰好匹配一个设备。第二次 raw 接触已开始时，只要仍为同设备、同 generation 的有效单指 `Candidate` 或 `Starting`，迟到的首击仍可匹配。其余接触中、多指、失效候选或歧义输入直接放行。
- 驱动在连续单指接触期间更换 contact identity 时，应转移身份，不能误判为抬手。该规则覆盖首击、`Candidate`、`Starting` 和 `Owned`；只有真正出现零接触帧才构成 raw lift。

这些数字来自已有真实日志的误触与漏识别分界。调整前必须保存对照日志并补充测试。

## 6. 状态机

拖动链有五态：

```text
Idle -> Candidate -> Starting -> Owned -> Releasing -> Idle
```

- `Idle`：没有候选或应用拥有的拖动。
- `Candidate`：第二次 raw contact 合格，尚未达到移动/保持门槛。
- `Starting`：已经确认意图，等待发布 synthetic down。
- `Owned`：完整鼠标事务由 TapDrag 持有。
- `Releasing`：真实抬手已请求 synthetic up。

每条链带 generation。异步任务必须同时核对 generation、feature epoch 和 device，防止旧任务污染新手势。

允许的嵌套锁顺序只有：

```text
raw contact 路径：gStateLock -> gChainLock
事件发布路径：gSyntheticLock -> gChainLock
```

`gStateLock` 与 `gSyntheticLock` 不得同时持有；需要发布事件时必须先退出 raw state 临界区。不要在持有 `gChainLock` 时再获取另外两把锁。异步 block 不得捕获可变 `DeviceState *` 后在锁外长期使用。

## 7. Enabled 与系统生命周期

`gEnabled` 是拖动功能开关，对应用户默认项 `DoubleTapDragReleaseEnabled`。关闭时必须：

1. 增加 `gFeatureEpoch`；
2. 中断当前链；
3. 重置所有设备状态；
4. 停止当前自动日志会话，但不改变用户的自动日志偏好。

开启时必须先确认权限并安装 event tap；仅当 `AutomaticDiagnosticLoggingEnabled` 也为真时启动自动日志。不要再增加实验功能开关。

系统睡眠和用户会话失去活动状态时，必须先设置 `gInputSuspended`，再增加 feature epoch、释放已拥有的拖动、丢弃未提交的首击、停止 raw 设备并重置全部设备。挂起期间 `replacementActive()` 必须保持为假。睡眠状态与用户会话状态要分别跟踪：两者任一无效即暂停，只有系统已经唤醒且当前用户会话活跃时才能恢复。成对通知可能描述同一次转换，处理必须幂等，不能重复停止或重建设备。恢复时重新执行 `MTDeviceCreateList`、注册 callback、启动设备并验证 HID 与 annotated-session 两个主动 event tap；全部成功后才能解除 suspended。运行时检查会自动重建意外失效的主动 tap，并在设备枚举短暂失败后继续尝试恢复 raw 设备。只读诊断观察器仍是可选项。

`MTDeviceCreateList` 的结果不只包含触控板。`MTDeviceGetSensorDimensions` 成功时，少于 10 个传感器行的设备应被排除，以免把 Touch Bar 等设备当作拖动输入；查询失败时保留设备以兼容系统 ABI 差异。IOKit 对 `AppleMultitouchDevice` 的新增和移除通知必须持续排空 iterator，并在主 run loop 上停止旧设备、释放旧列表、重新枚举。退出程序时也必须停止设备并释放列表与通知资源。

程序每秒读取一次内建与蓝牙触控板的系统 `Dragging` 偏好。配置元组发生变化时立即中断当前链并重置设备，不依赖用户打开菜单。已知设备类型缺少自身偏好域时应保守视为原生拖移开启，不能借用另一类设备的偏好。

### 登录启动

菜单中的 `Launch at Login` 使用 macOS 13 起提供的 `SMAppService.mainAppService` 注册或注销主应用登录项。只在用户操作菜单时修改注册状态，不保存第二份布尔偏好；应用启动及每次打开菜单时读取系统状态。已启用显示勾选，待系统批准显示横线并提供设置入口，未注册或未找到显示未勾选；失败显示系统错误且刷新实际状态。该选项与拖动功能的 `Enabled` 独立，退出应用时不注销登录项。应用构建需链接 `ServiceManagement.framework`。接口说明见 [Apple SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice?language=objc)。

## 8. 诊断日志

Diagnostics 子菜单中的 `Automatic Logging` 控制自动文件写入，默认开启并通过 `AutomaticDiagnosticLoggingEnabled` 持久化。它与拖动功能 `Enabled` 独立：关闭时先刷新当前日志并停止 timer，之后仍保留容量为 2048 的内存环形记录，供复制摘要和手动导出使用；再次开启且拖动功能正在运行时创建新的日志会话。菜单状态文案区分 `auto saved`、因拖动功能关闭而 `auto save paused`、关闭自动写入后的 `memory only` 和写入失败。关闭开关不删除已有日志文件。

自动日志路径：

```text
~/Library/Logs/TapDrag/Diagnostics/double-tap-<session>-pid<pid>.jsonl
```

日志为 JSON Lines：首行是版本、阈值和环境摘要，后续是按 sequence 排序的状态事件。重点字段包括：

- `kind`、`reason`、`phase`、`generation`
- raw contact 数量、frame 数、接触时长、间隔和毫米移动距离
- native/synthetic 事件类型、event number、click state、source state、来源 PID/UID/GID、观察到的目标 PID 与窗口 ID
- native dragging 配置
- `input_event_tap` 和 `downstream_observer_active` 标明输入层级与观察器状态；`movement_input` 保留改写前事件，`observed_downstream` 记录下游观察，`delta_x/y` 保留移动增量。
- 当前诊断 schema 6 记录 `event_flags`、`button_number`、`mouse_subtype`、`first_click_allowance_ms` 与首击关联阈值。event tap 回调内不得调用 `CGEventSourceButtonState` 等可能同步等待 WindowServer 的查询，否则回调超时会反过来禁用输入 tap。
- 首击缓冲不检查目标 PID。单击补发后恢复当前指针位置，真正双击的按钮事件统一发布，避免第二次 down 越过首击补发。
- 日志头的 `first_tap_buffer_taps` 标识 HID 与 annotated-session 共用缓冲。两个层级都在 `gSyntheticLock` 内检查拖动所有权，拦截已在途的原生按钮。取消尚未收齐 up 的首击时保留其 event number，消费迟到的对应 up，即使此时合成拖动已经结束；新的原生 down 或输入重置清除此记录，避免事件编号复用误吞后续点击。
- 缓冲及补发与拖动共用 `gSyntheticLock`。该锁内允许取得 `gChainLock`，不得反向取 `gStateLock`。缓冲超时以 token 使旧回调失效；只有 down/up 齐全时才补发，任何中断都不得发布孤立的 down。系统挂起时直接丢弃未提交点击，其余正常取消路径可补发完整点击。缓冲记录为 `native_event_filtered / first_tap`，确认拖动取消首击为 `native_event_filtered / second_tap`，补发为 `native_button_passed / first_tap`。

`synthetic_down/drag/up` 仍表示发布或改写，不是应用接收回执。释放后观察到的事件可能以 generation 0 记录，需用本会话中的 tag、event number 和时间顺序关联；下游观察也不能证明窗口已经移动。

日志环形缓冲容量 2048，自动文件最多保留 12 个，目录权限 0700、文件权限 0600。新会话文件必须先创建并设置权限，再执行保留数量清理。若出现“偶发”问题，先用事件序列还原状态迁移，不要仅凭体感改阈值。

状态机约束可对照以下上游实现：[libinput](https://gitlab.freedesktop.org/libinput/libinput) 的 tapping state machine 在 suspend/config disable 时释放全部逻辑按钮；[mtrack](https://github.com/p2rkw/xf86-input-mtrack) 的 drag reset 会在活动拖动时明确发送 button-up；[旧版 VoodooPS2](https://github.com/RehabMan/OS-X-Voodoo-PS2-Controller) 的 predrag/drag/notouch 状态同样在睡眠和重新初始化时清理按钮。[现代 VoodooPS2](https://github.com/acidanthera/VoodooPS2) 通过 VoodooInput 模拟 Magic Trackpad，由 macOS 原生手势栈完成更上层识别。[macOSMiddleClick](https://github.com/SomeGuyNamedDaveIsTaken/macOSMiddleClick) 提供了 private MultitouchSupport 设备重建和 IOKit 热插拔处理的参考。TapDrag 的技术层级不同，但必须维持同样的成对按钮和生命周期不变量。

## 9. 签名与授权连续性

构建脚本要求 `TAPDRAG_BUILD_CONFIGURATION` 为 `Release` 或 `Debug`，默认值是 `Release`。Release 使用 `-O2 -DNDEBUG`，Debug 使用 `-O0 -g -DDEBUG=1`；`make build`、`make verify`、`make run` 和发布打包均显式选择 Release，`make build-debug` 用于调试。生成包的 `Contents/Info.plist` 包含 `TapDragBuildConfiguration`，应在测试或分发前检查它，未知配置必须直接失败。

应用对外名称和可执行文件已经改为 TapDrag，但 Bundle ID 与默认本地签名身份刻意保留旧值。macOS 权限依赖 designated requirement；保持 identifier 与证书私钥不变，可最大程度避免每次重建重新授权。

```sh
make setup-local-signing
make signing-status
```

环境变量使用 `TAPDRAG_CODESIGN_IDENTITY`、`TAPDRAG_LOCAL_SIGNING_IDENTITY` 和 `TAPDRAG_RELEASE_CODESIGN_IDENTITY`。

## 10. 发布检查

```sh
make verify
```

所有需要真实窗口、硬件、权限或系统生命周期参与的测试统一维护在 [人工测试清单](MANUAL_TESTING.md)。发布前执行其中适用于当前硬件和改动范围的项目，并记录结果。
