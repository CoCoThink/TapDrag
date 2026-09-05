# TapDrag 维护文档

## 1. 产品边界

TapDrag 只负责一件事：在 macOS 原生触控板拖移关闭时，实现可立即释放的双击拖动。

后续修改应维持单一手势路径，避免重新引入会竞争同一鼠标事务的并行实现。

## 2. 目录

| 路径 | 用途 |
| --- | --- |
| `TapDrag/Sources/main.m` | 菜单、权限、原始触点识别、拖动状态机、event tap、日志。 |
| `TapDrag/Info.plist` | 应用名、版本、Bundle ID 和菜单栏应用配置。 |
| `TapDrag/Resources/AppIcon.png` | 应用图标源文件。 |
| `TapDrag/build.sh` | 编译、组装、签名和签名验证。 |
| `tests/touch_state_tests.m` | 状态机与手势边界回归测试。 |
| `tests/manual_wechat_probe.m` | 微信测试草稿上的手动集成回放，会发送鼠标事件。 |
| `scripts/generate-app-icon.m` | 可复现生成图标源文件。 |
| `scripts/create-local-signing-identity.sh` | 一次性创建稳定的本地签名身份。 |
| `scripts/signing-status.sh` | 检查签名身份和 designated requirement。 |
| `scripts/package-release.sh` | 生成发布压缩包。 |

## 3. 运行前提

1. 系统“轻点来点按”开启。
2. 系统触控板“拖移”关闭。
3. TapDrag 菜单中的 `Enabled` 开启。
4. 已授予辅助功能权限；若系统单独提示，也需授予输入监控权限。

原生拖移开启时，`replacementActive()` 返回 `NO`。这是互斥保护，不应改成与系统拖移并行。

## 4. 输入与输出

输入处理包括：

- `MultitouchSupport.framework` 的 raw contact frame，决定真实接触开始、移动、身份变化和抬起。
- HID event tap 的鼠标事件，在应用拥有拖动事务后过滤冲突事件。拥有事务时消费原生 movement，将替代拖动与 down/up 在同一锁保护下从 HID 发布。
- annotated-session 主动按钮过滤器按用户选择运行兼容或通用首击缓冲。兼容模式仅处理微信和 Dock；通用模式处理与唯一 raw 单指 tap 在时间和坐标上匹配的触控子类型点击。确认拖动时取消首击，否则补发普通点击。
- annotated-session 层的只读观察器仅记录下游事件，不参与拖动状态迁移；观察器失效不能中断拖动。

输出是一条带 `DoubleTapTag` 的完整事务：

```text
leftMouseDown -> leftMouseDragged* -> leftMouseUp
```

`mouseUp` 必须由真实 raw finger lift 驱动。不要添加固定延迟释放、系统 grace period 等待或影子拖动会话。

## 5. 手势判定

- 第一次接触必须在 250 ms 内结束，且移动不超过阈值。
- 第二次接触与第一次 raw lift 的间隔必须在 30–160 ms 内，同时受更短的系统双击间隔约束。
- 第二次接触移动超过 1.3 mm 时立即确认拖动。物理毫米坐标有效时只使用该阈值；归一化坐标仅在物理坐标无效时作为备用。
- TapDrag 作为解释 raw 触控板状态并生成鼠标事务的用户态输入工具，synthetic down/drag/up 必须使用 `kCGEventSourceStateHIDSystemState`。在 `Owned` 阶段消费原生 movement 并创建带本事务 event number 的 `leftMouseDragged`，保留坐标、delta 和修饰键，使用当前单调时间戳与本工具真实来源身份；不要伪造 source PID/UID/GID，也不要把 WindowServer 的 `target/window` 注释当作可靠路由。禁止原地返回修改后的原生 movement：实测该路径可越过异步发布的 down。
- 第二次接触保持 180 ms 也可确认拖动意图。
- 任意多指接触使候选失效。
- 物理按压产生的 native mouse-down 若发生在第一次接触尚未结束时，不得成为首击候选。
- 通用缓冲要求 annotated-session 的 `leftMouseDown` 为 `NSEventSubtypeTouch`，并在首击决策窗口内到达，事件坐标与 raw lift 时指针相距不超过 12 points；必须恰好匹配一个设备。任一条件不确定时直接放行。
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

## 7. Enabled 生命周期

`gEnabled` 是拖动功能开关，对应用户默认项 `DoubleTapDragReleaseEnabled`。关闭时必须：

1. 增加 `gFeatureEpoch`；
2. 中断当前链；
3. 重置所有设备状态；
4. 停止当前自动日志会话，但不改变用户的自动日志偏好。

开启时必须先确认权限并安装 event tap；仅当 `AutomaticDiagnosticLoggingEnabled` 也为真时启动自动日志。不要再增加实验功能开关。

### 登录启动

菜单中的 `Launch at Login` 使用 macOS 13 起提供的 `SMAppService.mainAppService` 注册或注销主应用登录项。只在用户操作菜单时修改注册状态，不保存第二份布尔偏好；应用启动及每次打开菜单时读取系统状态。已启用显示勾选，待系统批准显示横线并提供设置入口，未注册或未找到显示未勾选；失败显示系统错误且刷新实际状态。该选项与拖动功能的 `Enabled` 独立，退出应用时不注销登录项。构建和包含 `main.m` 的测试程序均需链接 `ServiceManagement.framework`。接口说明见 [Apple SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice?language=objc)。

### 首击缓冲模式

`First Tap Buffering` 通过 `FirstTapBufferMode` 持久化，默认值为兼容模式。`Compatibility (WeChat & Dock)` 保留按目标 PID 的既有路径；`Universal (All Trackpad Taps)` 不按目标程序分类，只缓冲通过 raw tap、触控 subtype、到达时间、事件坐标和唯一设备联合校验的点击。切换模式时先结束当前拖动链并补发完整待决点击，再重置 raw 候选，避免旧模式的异步任务进入新模式。

通用模式与系统级输入栈采用相同的全局判定策略，但本程序位于 `CGEventTap` 层，需要重放事件。普通 tap-to-click 因此会增加约 200 ms 延迟；物理触控板按压、鼠标点击、本工具自身的合成事件以及无法唯一关联的点击必须直接放行。目标 PID 只用于进程退出时清理属于该目标的待决点击，不作为通用模式的准入条件。

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
- schema 2 增加 `event_flags`、`button_number`、`mouse_subtype`、`hid_left_down`、`session_left_down`，并记录原生拖动作为对照。schema 4 的头部增加 `first_tap_buffer_mode`、`universal_first_tap_buffer` 和通用模式坐标阈值。左键状态是回调时的采样值。
- `wechat_pid` 表示当前首击缓冲目标，`target_observer_pid` 表示当前只读观察器绑定的微信进程，二者在诊断摘要中分别报告。`observed_target_process` 为该进程路由点的只读观察；不做窗口移动特判。
- Launchpad 启动器 `com.apple.launchpad.launcher` 不常驻，实际界面由 Dock 进程承载。`dock_pid` 由启动时枚举和 NSWorkspace 启动/退出通知维护。按钮事件的目标 PID 等于当前 Dock PID 时统一启用首击缓冲，覆盖 Launchpad 和普通 Dock 图标；其代价是两处普通 tap 点击约 200 ms 后才执行。不得依赖 `LPSpringboard` 窗口名称：该字段在 TapDrag 进程中并非可靠可用。Dock PID 更换时清除旧点击和 timer token，迟到的旧进程退出通知不得清除新 PID。
- 在主线程监听 NSWorkspace 的应用启动、退出和激活通知，按微信 Bundle ID 更新目标 PID。安装事件过滤器时先订阅通知再枚举现有进程，支持微信晚于 TapDrag 启动。PID 改变时丢弃旧点击缓冲、使旧超时任务失效并移除旧观察器；微信退出后不得向其他窗口补发旧点击。迟到的旧进程退出通知不得清除新 PID。观察器安装失败不影响首击缓冲，后续微信激活时重试；卸载过滤器时注销通知并清理目标。
- 专用首击缓冲使用独立的 annotated-session 主动按钮过滤器，以此阶段的目标 PID 判定应用，避免 HID 阶段仍指向旧前台应用。raw 首击已结束且系统原生拖移关闭时，暂存首击 down/up；约 200 ms 内没有进入第二接触则补发，确认拖动后丢弃首击。单击补发后恢复当前指针位置；真正双击的按钮事件统一发布，避免第二次 down 越过首击补发。
- 通用模式复用同一 annotated-session 过滤器和发布队列，但不调用目标 PID 白名单。它使用 raw lift 时记录的单调时钟和指针位置关联后续事件；过期、距离超限、多个设备同时符合或缺少坐标时均失败放行。
- 缓冲及补发与拖动共用 `gSyntheticLock`。该锁内允许取得 `gChainLock`，不得反向取 `gStateLock`。缓冲超时以 token 使旧回调失效；关闭功能、tap 失效时补发尚未提交的点击。`wechat_first_tap_buffer` 标识此路径；缓冲记录为 `native_event_filtered / first_tap`，确认拖动取消首击为 `native_event_filtered / second_tap`，补发为 `native_button_passed / first_tap`。

`synthetic_down/drag/up` 仍表示发布或改写，不是应用接收回执。释放后观察到的事件可能以 generation 0 记录，需用本会话中的 tag、event number 和时间顺序关联；下游观察也不能证明窗口已经移动。

日志环形缓冲容量 2048，自动文件最多保留 12 个，目录权限 0700、文件权限 0600。若出现“偶发”问题，先用事件序列还原状态迁移，不要仅凭体感改阈值。

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

手工回归至少包括：

1. 普通单击后移动不会开始拖动。
2. 普通双击仍由系统正常处理。
3. 双击后移动可稳定开始拖动。
4. 手指未离开时不会提前释放。
5. 手指离开时立即释放。
6. 释放后可立即开始下一次双击拖动。
7. 前景窗口和后层窗口都能正常激活并拖动。
8. Finder 桌面文件、文本选择、窗口标题栏都通过。
9. 拖动后第一次按压点击菜单栏图标即可打开菜单。
10. 系统原生拖移开启时 TapDrag 明确显示为 inactive，且不合成事件。
11. 关闭 `Enabled` 会安全结束当前状态，并停止处理新手势。
12. 重建后签名 requirement 不变，不重复请求授权。
13. 微信通过 Command+Q 退出再打开，或在 TapDrag 启动后才打开微信，双击文字拖选仍正常；无需重启 TapDrag。
14. `Launch at Login` 可启用和关闭；系统设置中修改登录项后，重新打开菜单能反映状态。需批准时显示设置入口。注销并重新登录后验证启动行为。
15. `Automatic Logging` 关闭后不再更新磁盘日志，复制与导出仍包含内存记录；重新启动应用后保持选择。再次开启会创建新的自动日志文件。
16. Launchpad 和 Dock 中第一次 tap 不会提前启动应用，双击拖动可移动图标；普通 tap 在约 200 ms 后仍能启动应用。重启 Dock 后两项行为保持不变。
17. 兼容模式下非微信/Dock 的普通 tap 不延迟；微信、Launchpad 和 Dock 保持既有行为。
18. 通用模式下 Finder、浏览器、菜单栏和第三方自绘窗口的普通 tap 延迟后仍只执行一次，双击拖动均在首击动作前开始。
19. 通用模式下物理触控板按压、外接鼠标点击、过期 raw 候选、坐标不匹配及多设备歧义均直接放行。
20. 切换缓冲模式并重启 TapDrag 后选择保持；切换瞬间不存在丢失点击或遗留按下状态。

2026-09-05 验收记录：用户确认微信 4.1.11 / macOS 15.7.7 上的真实触控板双击文字拖选恢复正常；实际首击缓冲路径的输入框回放、`make verify` 和手动探针严格编译均通过。微信窗口拖动及普通单击、双击的实机回归尚未获得用户明确确认；自动化点击顺序测试通过不代表上述手工矩阵全部完成。根因、对照数据和复现命令见 [微信诊断记录](WECHAT-DRAG-DIAGNOSIS.md)。

同日 Launchpad / Dock 验收记录：事件探针确认 Launchpad 的 annotated-session 鼠标 down/up 均以当前 Dock PID 为目标，窗口编号一致且 subtype 为触控；用户随后确认修复版在 Launchpad 和 Dock 中均可正常双击拖动图标。最终实现按当前 Dock PID 统一缓冲首击，不依赖窗口名称。`make verify` 已通过，包括 Dock PID 初始跟踪、重启更新、迟到退出通知和非 Dock PID 不匹配的回归测试。普通 tap 的约 200 ms 延迟是为区分拖动而保留的预期行为。

若改动图标，编译并运行 `scripts/generate-app-icon.m` 生成 1024×1024 PNG，再执行完整构建确认 Finder 和菜单栏显示正常。
