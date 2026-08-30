# 3FDragUnstuck 维护文档

## 1. 项目目的与边界

3FDragUnstuck 是一个轻量级 macOS 菜单栏程序。它处理两个彼此独立的问题：

1. 三指拖动结束时，向系统补发左键抬起，以缩短应用收到释放事件的等待。
2. 可选的双击拖动快速释放：根据触控板原始触点识别 `短第一触 -> 有移动的第二触`，在第二触离开时提前释放；在紧接着的一次双击拖动中，用受控的应用层鼠标流避免迟到的旧事件结束新拖动。

第二项依赖 `MultitouchSupport.framework` 的私有接口和 Quartz 事件过滤，因此必须保持为 Experimental。macOS 没有公开 API 用来取消触控板驱动内部的 tap-to-drag grace 状态；本项目只能控制应用收到的鼠标事件流，不能修改驱动本身。

不支持的组合：开启双击拖动快速释放时，同时使用外接鼠标按键和触控板。Quartz 没有可靠的公开方式把这两类左键事件逐条区分，候选拖动期间可能会过滤外接鼠标事件。

## 2. 目录和职责

| 路径 | 职责 |
| --- | --- |
| `3FDragUnstuck/Sources/main.m` | 全部运行时代码：菜单栏 UI、权限、原始触点回调、三指和双击状态机、Quartz event tap。 |
| `3FDragUnstuck/Info.plist` | Bundle ID、版本、菜单栏应用配置、图标声明。 |
| `3FDragUnstuck/Resources/AppIcon.icns` | 应用图标。 |
| `3FDragUnstuck/build.sh` | 编译、打包 `.app`、清理扩展属性、签名。 |
| `Makefile` | 常用入口：`build`、`run`、`verify`、`release`、`clean`。 |
| `scripts/package-release.sh` | 生成可分发压缩包。 |
| `README.md` | 面向使用者的说明和构建指引。 |
| `docs/MAINTENANCE.md` | 本文档，面向后续维护。 |

项目没有 Xcode 工程文件；编译参数直接保存在 `3FDragUnstuck/build.sh` 中。

## 3. 运行时结构

应用启动后，`AppDelegate` 完成以下工作：

1. 注册 `NSUserDefaults` 默认值，恢复开关和 Override Modifier。
2. 建立菜单栏图标和菜单项。
3. 请求或读取辅助功能权限。
4. 通过 `dlopen` 加载私有的 `MultitouchSupport.framework`，为每个触控板注册 contact-frame callback。
5. 只有启用双击拖动快速释放时，才建立 `kCGSessionEventTap`。它需要事件发布和监听权限。

触点回调在非主线程环境中执行，菜单和 event tap 回调可能与其并发。因此代码使用两种同步方式：

- `gStateLock`：保护每台设备的 `DeviceState`，包括当前接触、第一短 tap 和原始位移。
- 原子变量：保护跨回调可见的双击链 phase、设备标识、截止时间和开关。

不要在持有 `gStateLock` 时调用 `CGEventPost`、`CGEventTapPostEvent` 或 UI API；这些调用都必须在解锁后执行。

## 4. 原始触点识别

`DeviceState` 保存单次物理接触的状态：

- `rawTouchMade` / `rawTouchStartedTimestamp`：是否见到有效单指接触及其起点。
- `rawTouchStartedPosition` / `rawTouchMoved`：第二次接触是否在原始触点数据中真实移动过。
- `rawFirstTapPending`：上一轮是否是一个足够短、可作为双击第一击的 tap。
- `rawChainCandidate`：当前接触是否已经被确认成“连续拖动”的第二触。

判定规则如下：

1. 多指接触会使当前候选失效。
2. 第一触必须短于 `MaximumTapDurationSeconds`，才成为等待中的第一 tap。
3. 第二触必须在系统 double-click interval 内开始。
4. 第二触是否是拖动依据实际原始位移，或该接触期间观察到的原生 `leftMouseDragged`，而不是接触时长。这样快速拖放不会再因为小于 200ms 而漏判。

`MTTouch` 结构来自私有 framework。字段布局或状态值在 macOS 大版本升级后可能变化；这类升级后先验证 `MTTouchStateMakeTouch`、`MTTouchStateTouching` 和 `normalizedVector.position`，再发布新版本。

## 5. 双击拖动状态机

双击快速释放的主要状态定义在 `DoubleTapChainPhase`：

| 状态 | 含义 | 接收原始触点后的转换 |
| --- | --- | --- |
| `Idle` | 没有连续拖动保护。 | 一次正常双击拖动释放后进入 `AwaitingFirstTap`。 |
| `AwaitingFirstTap` | 正在等待旧 grace 窗内的下一次第一短 tap。 | 第一短 tap 完成后进入 `AwaitingSecondTap`。 |
| `AwaitingSecondTap` | 正在等待下一次第二触。 | 原始第二触开始后进入 `SecondContact`。 |
| `SecondContact` | 已确认候选，但尚未发生指针移动。 | 首次 mouse move/drag 时建立受控拖动。 |
| `StartingDrag` | 正在投递合成 mouse-down，处理抬指竞争。 | 成功后进入 `OwnedDrag`；若已抬指，立即转释放。 |
| `OwnedDrag` | 程序拥有这一次连续拖动的应用层事件流。 | 第二触离开时进入 `Releasing`。 |
| `Releasing` | 已决定释放，正在屏蔽迟到的原生事件。 | 合成 mouse-up 发出后重新进入 `AwaitingFirstTap`。 |

受控拖动的事件顺序必须始终是：

```text
tagged leftMouseDown -> leftMouseDragged* -> tagged leftMouseUp
```

其中首次移动时无条件发送 tagged `leftMouseDown`。不要再依赖一个“最近是否见过原生 down”的布尔值：原生事件可能是上一轮 grace 留下的事件，无法仅靠时间窗口证明它属于当前第二触。

候选、启动、拥有和释放状态都会过滤未标记的原生 `leftMouseDown` / `leftMouseUp`；释放状态还过滤移动事件。合成事件带有 `kCGEventSourceUserData` 标签，event tap 会直接放行它们，避免递归处理。候选状态之外不设置全局过滤窗口，避免吞掉下一次第一短 tap 的正常 `mouseUp`。

## 6. 三指拖动路径

三指路径与双击路径分离：每当同一接触周期的最大有效 contact count 恰好为 3，且未按住当前 Override Modifier，程序通过 `postLeftMouseUpAtCurrentPointer()` 投递一次 tagged left mouse up。

`MinimumReleaseIntervalMillis` 防止同一释放被相邻 contact-frame 重复投递。修改双击状态机时不要改变三指的 `maxContacts`、`contactCount` 收尾逻辑。

## 7. 菜单、权限和持久化

默认项和 key：

| key | 默认值 | 作用 |
| --- | --- | --- |
| `ShiftOverrideEnabled` | `YES` | 是否允许 Override Modifier 保留原生释放。 |
| `OverrideModifier` | `Option` | 可选 `Shift`、`Control`、`Option`、`Fn`。 |
| `DoubleTapDragReleaseEnabled` | `NO` | 是否启用实验性双击拖动快速释放。 |

双击功能要求：

- `CGPreflightPostEventAccess()`：允许发布合成鼠标事件。
- `CGPreflightListenEventAccess()`：允许建立可过滤的 session event tap。
- 辅助功能通常会满足两者；不同 macOS 版本也可能单独要求 Input Monitoring。

每次 ad-hoc 重新签名后，macOS 可能把它当成新构建并失去既有授权。排查权限时务必针对 `build/3FDragUnstuck.app` 这个确切路径和当前签名。

## 8. 构建、签名与发布

常用命令：

```bash
make build
make verify
make run
make release
```

`make verify` 会重新构建，并运行 `codesign --verify --deep --strict --verbose=4` 和 `file` 检查。默认签名是 ad-hoc；如需稳定本地开发签名：

```bash
THREE_F_DRAG_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" make build
```

发布前更新 `3FDragUnstuck/Info.plist` 的 `CFBundleShortVersionString` 和 `CFBundleVersion`。前者是用户可见版本，后者应单调递增。

## 9. 验证清单

每次改动输入处理后，至少完成以下人工测试：

1. 启动新 app，确认菜单栏出现 `3F+`，并检查双击功能的权限状态是 granted。
2. 三指拖动桌面文件，抬手后立即确认拖动结束。
3. 开启双击功能，双击并拖动桌面文件，分别测试短距离快速拖放和较长拖放，抬手后应立即释放。
4. 在原本的 grace 窗内，连续执行至少 10 次 `双击拖动 -> 抬手 -> 立即双击拖动`。每一轮都应能开始，且上一轮不会结束下一轮。
5. 在受控拖动期间抬起过快、多指落下、关闭功能、退出 app、event tap timeout 后，确认没有留下“鼠标一直按住”的状态。
6. 按住已选 Override Modifier 完成拖动，确认保留原生行为。
7. 验证普通单击、双击、三指拖动和菜单操作没有明显回归。实验性双击功能开启时，不要将外接鼠标与触控板同时用于同一个测试。

## 10. 排障与维护原则

- 菜单的 `Double-Tap last` 行用于快速判断：第一 tap 是否捕获、连续拖动是否进入 owned/released、是否被多指或 override 中断。
- 若“释放仍慢”，先检查第二触是否被识别为真实移动；不要用接触时长代替位移判断。
- 若“下一轮不开始”，检查是否存在完整的 `down -> dragged -> up` 序列。最常见错误是借用了迟到的原生 down，导致只剩 drag/up。
- 若 Finder 或其他应用出现拖动卡住，优先检查 `OwnedDrag`、`StartingDrag`、`Releasing` 的所有退出路径是否都匹配发出一次 tagged up。
- 不要调用 `MTDeviceInjectFrame`、`IOHIDDeviceOpen(...SeizeDevice)` 或其他“夺取”内建触控板的接口；它们没有稳定的公开契约，可能造成系统级输入故障。
- 所有 feature 修改都应保持双击功能 opt-in，并同步更新 `README.md`、本文档、版本号和人工验证清单。

## 11. 已知限制

1. 不能通过公开 API 清空触控板驱动内部的 tap-to-drag grace，因此这里实现的是应用层事件隔离，不是驱动级修复。
2. `MultitouchSupport.framework` 是私有 framework，未来 macOS 更新可能造成回调失效。
3. 候选连续拖动期间无法可靠区分外接鼠标与触控板左键事件。
4. 如果第二触没有实际移动，程序不会伪造点击来猜测用户意图，避免额外单击、双击或意外打开桌面文件。
