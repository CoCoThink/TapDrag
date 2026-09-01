# 3FDragUnstuck 维护文档

## 1. 项目边界

程序处理两件事：

1. 三指拖动抬手时补发一次左键抬起。
2. 在 macOS 原生“使用触控板进行拖移”关闭时，完整实现双击拖动。

双击拖动只有一种实现，不存在原生 dragging 兼容路径。若检测到相关触控板仍开启原生 dragging，双击替代保持 inactive，不过滤或合成任何双击拖动事件。

macOS 没有公开的独立参数用于缩短 Without Drag Lock 的抬手等待。全局 double-click interval 同时决定双 tap 是否成立，不能用作释放延迟参数。本项目通过禁用原生 recognizer 绕过该状态，而不是清理其内部事务。

双击功能依赖私有 `MultitouchSupport.framework`，必须保持 Experimental。不要加入 `MTDeviceInjectFrame`、HID seize 或驱动修改。

## 2. 文件职责

| 路径 | 职责 |
| --- | --- |
| `3FDragUnstuck/Sources/main.m` | 菜单、权限、触点识别、五态拖动状态机、event tap、诊断日志。 |
| `tests/touch_state_tests.m` | 状态机、触点边界、事件策略、设备设置和日志测试。 |
| `3FDragUnstuck/Info.plist` | Bundle ID、版本和菜单栏应用配置。 |
| `3FDragUnstuck/build.sh` | 编译、打包和稳定签名。 |
| `scripts/create-local-signing-identity.sh` | 创建本机稳定开发签名。 |
| `scripts/signing-status.sh` | 检查签名和 designated requirement。 |
| `scripts/package-release.sh` | 生成发布压缩包。 |

项目没有 Xcode 工程，构建入口是 `Makefile`。

## 3. 前置条件

完整替代模式要求：

1. “系统设置 -> 辅助功能 -> 指针控制 -> 触控板选项”中的“使用触控板进行拖移”关闭。
2. Trackpad 中“轻点来点按”保持开启。
3. 菜单中的 `Double-Tap Drag Replacement (Experimental)` 开启。
4. Accessibility 和必要时的 Input Monitoring 已授权。

程序分别读取：

- `com.apple.AppleMultitouchTrackpad` 的 `Dragging`
- `com.apple.driver.AppleBluetoothMultitouch.trackpad` 的 `Dragging`

若 `MTDeviceIsBuiltIn` 可用，每台设备使用对应 preference domain，避免内建触控板和 Magic Trackpad 的设置互相误判。菜单打开时刷新设置；设置变化会中断当前 generation、补齐已拥有拖动的 up，并清空 raw tap 状态。

程序不自行写系统 preference。否则程序退出后用户可能在不知道设置已变化的情况下失去双击拖动。

## 4. 原始触点

`DeviceState` 只保存新方案需要的信息：

- 当前有效接触数和本周期最大接触数。
- `MakeTouch` / `Touching` 起点、时间、`pathIndex` 和 `fingerID`。
- raw 归一化坐标和 `absoluteVector` 毫米坐标的最大平方位移。
- 第一个短 tap 的完成时间。
- 当前第二触所属的 chain generation。
- 当前接触期间是否已经出现原生 `leftMouseDown`。

规则：

1. 只有 `MakeTouch` 和 `Touching` 算作手指仍在表面。`BreakTouch`、linger 和 out-of-range 不得延迟释放。
2. 第一 tap 最长 `0.25s`，移动不得超过下述 tap movement threshold，且接触期间不得出现原生 `leftMouseDown`。后者表示按压单击而不是 tap-to-click；该周期记录 `native_button_during_touch`，不能预置第二触。
3. 第二触必须在第一 tap 的 raw 抬起 `30–160ms` 内开始，同时受更短的 system double-click interval 限制。下限拒绝同一帧 `BreakTouch -> MakeTouch` identity 重启；上限来自同机同轮日志：真实双击拖动为 `40–160ms`，明确复现的单击后重新落指移动误触为 `176–560ms`。raw 接触本身没有额外的“第二击意图位”，不可再扩展到系统 `600–800ms` 双击窗口。
4. 合法第二触移动超过 `1.3mm` 时立即确认拖动；未越过阈值但持续触摸 `180ms` 时也确认拖动；在此之前抬手仍是普通双击，不合成 down/up。不得在第二触后增加固定 landing 等待：实测真实拖动常在落指后 `32–88ms` 越过阈值，该等待会大量漏识别。
5. `BreakTouch` 的最终位置必须参与位移判断，覆盖只在最后一帧移动的快速拖放。
6. `Idle` 中旧 identity 的 `BreakTouch` 与新 identity 的 `MakeTouch` 同帧出现时，先完成旧周期，再开始新周期，但 `0ms` 间隔的新周期会被 `intertap_too_short` 拒绝，不能成为第二触。`Starting` / `Owned` 中若有效接触数始终为 1，则视为驱动重分配 identity：转移 `pathIndex/fingerID` 并保持同一个 mouse transaction，禁止发布 up。
7. 多指接触立即使双击候选失效；三指释放路径仍按本周期最大有效接触数单独处理。

第一 tap 的系统 tap-to-click 完全放行，由 Finder/AppKit 自己完成选择和后台窗口激活。程序不执行 AX 命中测试、不重放首击，也不主动 raise 窗口。

## 5. 五态状态机

| phase | 含义 | 合法转换 |
| --- | --- | --- |
| `Idle` | 没有受控拖动。 | 有效第二触开始后进入 `Candidate`。 |
| `Candidate` | 第二触存在，仍可能是普通双击。 | 移动超过 `1.3mm` 或按住 `180ms` 后进入 `Starting`；此前抬手回 `Idle`。 |
| `Starting` | 已确认拖动，等待发布 synthetic down。 | 发布成功进入 `Owned`；若先抬手则进入 `Releasing`。 |
| `Owned` | 程序拥有完整鼠标事务。 | raw 抬手进入 `Releasing`。 |
| `Releasing` | 唯一 up owner 正在完成释放。 | up 发布后直接回 `Idle`。 |

不存在 release 后 rearm、AwaitingFirstTap、RestoringFirstTap 或 shadow generation。

### 5.1 开始拖动

第二触开始时记录屏幕坐标，并设置 `downNotBefore = now + 40ms`。这 40ms 只给第一 tap 的原生 click 一次送达 Finder/AppKit 的机会，不影响抬手释放速度。

毫米位移或按住超时确认后，starter 使用同一个 `kCGEventSourceStateCombinedSessionState` source 和正数 15-bit event number 发布：

```text
tagged leftMouseDown(clickState=1)
tagged leftMouseDragged*(clickState=1)
tagged leftMouseUp(clickState=1)
```

使用 `clickState=1`，避免标题栏把 synthetic down 当成第二次普通点击并执行缩放。WindowServer 可能把 event number 收窄为有符号 16 位，因此分配范围固定为 `1...32767` 并回绕。

### 5.2 释放竞态

`Starting` 与 raw 抬手可能并发：

- starter 先发布 down：phase 变为 `Owned`，raw callback 成为 up owner。
- raw callback 先到：phase 变为 `Releasing`，starter 在同一发布事务中补 `down -> dragged -> up`。

快速抬手时若没有可靠的屏幕位移位置，starter放弃该候选并回 `Idle`，不能制造一个原地 synthetic click。

关闭功能、设置变化、event-tap timeout 和 app 退出都会调用统一 interrupt。若 phase 是 `Owned`，必须先发布匹配 event number 的 up；其他 phase 直接失效 generation。

每次建立或清空 chain 都推进 generation。异步 starter 和 release finalizer 必须同时匹配 generation 与 phase，旧任务不得修改新拖动。

## 6. Event Tap 所有权

event tap 只执行以下策略：

| phase | 原生 down/up | mouseMoved/leftDragged |
| --- | --- | --- |
| `Idle` / `Candidate` / `Starting` | 放行 | 放行 |
| `Owned` | 过滤 | 替换为相同 event number 的 tagged `leftMouseDragged` |
| `Releasing` 且已有 event number | 过滤 | 过滤 |

`Candidate` 和 `Starting` 放行按钮事件非常重要：第一 tap-to-click 可能略晚于 raw lift 到达，它负责选择桌面文件和激活后层窗口。一旦 synthetic down 已发布，程序才开始排他拥有该事务。

带 `DoubleTapTag` 的事件直接放行，防止 event tap 递归处理自己的 down/drag/up。

## 7. 锁和线程

- `gStateLock`：每台设备的 raw contact 和 tap 分类。
- `gChainLock`：phase、generation、device、event number 和坐标。
- `gSyntheticLock`：event number 分配及 synthetic 事件发布顺序。
- `gDiagnosticLock`：固定大小诊断环。

raw callback 的顺序是 `gStateLock -> gChainLock`。starter 和 event replacement 使用 `gSyntheticLock -> gChainLock`。raw release 在取得 synthetic lock 前必须先释放 state/chain lock，避免反向嵌套。

输入回调不得写文件、序列化 JSON 或调用 UI。诊断只用 `trylock` 写入 POD ring；后台串行 timer 每 250ms 持久化。

## 8. 诊断日志

自动日志位置：

```text
~/Library/Logs/3FDragUnstuck/DoubleTap/double-tap-<session>-pid<pid>.jsonl
```

最多保留 12 个 session。目录权限 `0700`，文件权限 `0600`。

新方案的正常序列：

```text
raw_contact_started
first_tap
raw_contact_started
second_contact
movement_confirmed
native_button_passed*  # 第一 tap 的迟到 click，可选
synthetic_down
synthetic_drag*
identity_transferred*  # 持续拖动中硬件重分配 raw identity，可选
synthetic_up
chain_reset            # phase 从 releasing 回 idle
```

按压单击的拒绝序列为 `raw_contact_started -> native_button_observed(reason=native_button_during_touch) -> chain_reset`。所有原生 left down/up 都记录 `mouse_pressure`；这组日志用于核对按键相对 raw 接触边界的到达顺序。

重点字段包括 generation、phase、kind/reason、event type、event number、source user data、坐标、raw 时长、两击间隔、毫米位移、帧数、最大接触数，以及 native dragging 设置。header 同时记录系统双击间隔和本次实际采用的识别阈值。日志不记录文件名、窗口标题、键盘文本或 raw touch identity。

阈值和歧义状态参考 libinput 的 tap-and-drag 实现：短 tap 使用独立超时、移动以物理毫米计算，并在第二触期间区分普通双击与拖动。这里没有复制其 Linux 事件层代码，只采用同类判定原则；macOS raw 数据来自 `MultitouchSupport.framework` 的 `absoluteVector`（毫米坐标）。参考：

- <https://wayland.freedesktop.org/libinput/doc/latest/tapping.html>
- <https://gitlab.freedesktop.org/libinput/libinput/-/blob/main/src/evdev-mt-touchpad-tap.c>
- <https://github.com/lauschue/Remotastic/blob/main/MultitouchSupport.h>

## 9. 构建和签名

```bash
make setup-local-signing  # 每台开发机一次
make build
make test
make verify
make run
make release
```

正常开发构建使用 `3FDragUnstuck Local Development`。稳定 designated requirement 由 bundle identifier 和证书 leaf hash 组成，避免每次重建重新授权。不要删除或重建该证书，也不要修改 bundle identifier。

`make build-adhoc` 仅用于不需要保留 TCC 授权的临时构建。公开发布必须使用 Developer ID 和公证。

## 10. 回归清单

1. 关闭系统原生 dragging、开启 Tap to click，菜单显示 `Full replacement ready`。
2. 双击拖动桌面文件，抬手立即释放。
3. 连续至少 20 次“拖动 -> 抬手 -> 立即下一次双击拖动”。
4. 文件 1 拖完后第一次尝试即可拖动文件 2。
5. 前台窗口 1 拖完后第一次尝试即可拖动后层窗口 2，且不会双击缩放。
6. 双击拖动后第一次按压点击 `3F+` 即弹出菜单。
7. 第二 tap 在 `180ms` 内抬手且不移动时不出现 synthetic down；持续按住超过 `180ms` 后可正常起拖。
8. 极快短距离拖放在 BreakTouch 最后一帧越过 `1.3mm` 时仍能识别。
9. `Starting` 阶段快速抬手不会留下按下状态或生成普通 click。
10. 多指落下、关闭功能、设置变化、event tap timeout 和退出 app 后没有卡住的鼠标按下。
11. 普通单击、普通双击和三指拖动无回归。
12. 内建触控板关闭 dragging、外接 Magic Trackpad 开启 dragging 时，只在内建设备启用替代。
13. 持续单指拖动中 raw `pathIndex/fingerID` 被重分配时不发布 synthetic up，日志记录 `identity_transferred` 后继续同一 generation。
14. 单次按压点击后手指持续接触并移动不进入 `Candidate` / `Starting`；同帧 identity 重启记录 `intertap_too_short`，且没有 `synthetic_down`。
15. 原生 `leftMouseDown` 发生在第一段 raw 接触内时，该周期记录 `native_button_during_touch` 且不能产生后续 `second_contact`；轻点产生的迟到原生 click 不影响真正双击拖动。
16. 两触间隔 `40–160ms` 的快速双击拖动可在第二触移动越过 `1.3mm` 时立即启动；间隔 `168ms` 及以上的“单击后重新落指移动”不产生 `second_contact` 或 `synthetic_down`。

## 11. 已知限制

1. `MultitouchSupport.framework` 是私有接口，macOS 大版本升级后必须重新验证结构布局和状态值。
2. 程序运行期间才能提供双击拖动；程序退出后需重新启动，或重新开启系统原生 dragging。
3. 受控拖动的 `Owned` 阶段无法可靠区分外接鼠标和触控板的左键事件，不应同时操作两者。
4. 40ms 首击送达预算是经验性值，后续应依据新日志调整，但不得重新引入 AX、首击重放或 shadow 状态。
