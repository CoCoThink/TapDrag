# 微信双击拖动与文字拖选：诊断与解决方案

## 结论与边界

2026-09-05 检查基线：仓库 `ec8f52e`、TapDrag 2.1.0 (210)、微信 4.1.11、macOS 15.7.7。以下修复基于该仓库版本实现。

用户补充确认：微信不只窗口双击拖动失败，双击拖选文字也失败。因此调查范围是微信的鼠标拖动输入链，不能用窗口位置移动特判作为解决方案。检查时微信显示登录窗口；登录窗口和登录后的主窗口必须分别验证，不能互相替代。

已确认：最近两条微信目标手势成功通过识别，生成了完整的 down/drag/up 事件序列。故这两条手势的问题位于识别之后，不应先调整 160 ms 间隔或 1.3 mm 门槛。

受控回放已定位文字拖选失败的触发条件：保留原生首击后，再于双击时间内补一个合成 down，微信进入双击选词状态，后续拖动不扩展选区。取消前一次点击或将两次按下间隔拉到 1100 ms，同样的合成拖动可以连续扩展选区。已实现首击缓冲并通过真实微信输入框的代码路径回放；用户随后确认真实触控板双击文字拖选恢复正常。微信窗口拖动仍需单独验收。

下文按调查顺序保留各轮实验及当时的判断，其中“待确认”“仍未解决”属于对应历史阶段；首击缓冲验收及后续重启问题的状态见文末。

## 本机证据

自动日志目录：`~/Library/Logs/TapDrag/Diagnostics/`。

最近日志：`double-tap-15D129A6-0B2F-489C-9842-589420A80174-pid24633.jsonl`。

| generation | 第二触点间隔 | down / drag / up 数量 | 指针起点 -> 终点 | 移动记录中的目标 PID |
| --- | --- | --- | --- | --- |
| 2 | 96 ms | 1 / 21 / 1 | (719,327) -> (518,299) | 23013 |
| 4 | 80 ms | 1 / 19 / 1 | (631,309) -> (316,275) | 23013 |

读取运行进程确认 PID 23013 对应 `/Applications/WeChat.app/Contents/MacOS/WeChat`。两条链均包含 `movement_confirmed`、`owned`、`synthetic_up` 和最终释放重置，没有 failure 记录，原生拖移配置为关闭。更早的 pid23054 日志也同时包含 Finder 和微信目标的完整事务。

这些坐标是鼠标坐标，不是窗口坐标。日志没有记录窗口是否移动，也没有在应用接收侧确认事件，因此“完整记录”不等于“拖动成功”。

## 代码中的差异

1. `startSyntheticDrag()` 和 `postUp()` 用 `CGEventPost(kCGHIDEventTap, ...)` 发布新建事件；`installEventTap()` 却在 `kCGSessionEventTap` 安装过滤器。
2. `prepareNativeMovementAsDrag()` 在该 session 回调内把原生 movement 原地改成 `leftMouseDragged`。这只证明事件从此处向后具有拖动类型，不能证明更早的输入处理阶段已按拖动更新状态。
3. `startSyntheticDrag()` 在发布 down 之前就设置 `DragPhaseOwned`。发布调用不提供应用接收确认；后续回调也在 `ownEvent(event)` 为真时直接返回，没有观察 down 是否到达。存在需要验证的跨线程、跨注入点排序风险。
4. 新建 down/up 的来源 PID 是 TapDrag，通常的移动事件保留原生来源 PID 0。这是当前实现的事实，但没有证据表明微信据此拒收，不能靠伪造来源 PID 解决。
5. `synthetic_down/up` 在发布前写日志，`synthetic_drag` 在回调返回前写日志。`target_pid` 与窗口注释不是应用接收回执；新建事件的目标为 0 也不能单独说明路由失败。

普通视图拖动与窗口拖动可能采用不同处理路径。Apple 的 `NSWindow.performDrag(with:)` 从 mouse-down 启动窗口拖动；这支持分别验证窗口与内容拖动的必要性，但不证明微信调用了该 API。

参考：[CGEventTapLocation](https://developer.apple.com/documentation/coregraphics/cgeventtaplocation)、[NSWindow.performDrag(with:)](https://developer.apple.com/documentation/appkit/nswindow/performdrag(with:))。本机 CoreGraphics SDK 的 `CGEvent.h` 也明确区分事件发布点和针对进程的事件路由。

## 推荐实施顺序

### 1. 先补足可观测性

为诊断构建增加下游只读观察器；优先在 annotated-session 层观察，必要时使用微信 PID 的 listen-only event tap。观察器不修改事件，不参与手势判定。

- 把记录区分为 `posted`、`observed_downstream`，按 generation、tag、event number 关联；不能把后者命名为“应用已处理”。
- 记录进入改写函数前的原始类型、时间戳、delta X/Y、click state、pressure，以及观察时的 HID/combined-session 左键状态。
- 对带本工具标记的 down/up 也记录观察结果；保留原生首击的顺序信息，检查是否有迟到的 up。
- 用事件流之外的工作队列采集目标窗口位置，比较手势前后位移。仅采集 PID、窗口标识、位置和命中角色，不采集聊天内容。
- AX/窗口查询不得放进 event-tap 回调或状态锁中；查询失败须明确记录，不可视为“窗口未动”。

### 2. 第一优先：验证统一的输入层级

做一个仅改变 event-tap 位置的诊断构建：把主动过滤及原生移动改写移到 `kCGHIDEventTap`，down/up 仍从 HID 发布，保留全部识别阈值、原生首击、单一 generation 和真实抬手释放规则。

目标是让拖动类型在更早的处理阶段形成，同时在同一层过滤冲突事件。先确认本机权限能创建该 tap；失败要明确报告，不能静默切回 session 后声称正在测试 HID 方案。

采用条件：相同窗口和手势下，原构建稳定失败、HID 构建稳定成功，下游事件与窗口位移相符，且 Finder、其他窗口、菜单栏点击回归通过。该试验成功后才有依据将层级差异确定为主因。

### 3. 按观测结果处理事件时序

若发现移动先于 down 或迟到的原生 up，增加“down 已发布、等待同一事件流观察”的明确子状态。将排队/发布与允许转换移动分开；观察到匹配 tag、generation、event number 的 down 后再放行拖动。

等待期间只缓存最新移动位置，不能在回调中阻塞。真实抬手到来时立即标记释放请求；尚未发布 down 可取消，已发布 down 必须保证对应 up，不得为了等待确认延迟释放。匹配超时、关闭功能、tap 失效及旧 generation 都须有明确清理路径。

此方案只能改善到达指定观察点的顺序，不能当作微信处理确认。不要与层级调整一起首次验证，以免无法判断哪项修复有效。

### 4. 仍不兼容时的选择

如果 HID 改写无效，再单独对照“过滤原生移动并从 HID 发布完整合成拖动事务”。整条事务的 click state、event number、pressure、delta 和来源应保持合理一致，避免全局与定向进程双发造成重复事件。保留自有 tag 防止回环，并验证指针跳动和多屏坐标。

用户已明确文字拖选也受影响，窗口专用 AX 后端不适用于当前问题，已撤除尝试实现。后续必须基于同一文本区域的原生按压拖选和合成拖选对照，确定鼠标状态、事件内容或接收阶段的差异。

## 验证矩阵与验收

分别测试微信登录窗口、微信主窗口、一个普通窗口、Finder 文件和文本选择；每类比较物理按压拖动、原构建双击拖动、候选构建双击拖动。统一起点和大致位移，每组至少 10 次，并区分前景与后台激活。

每次检查：手势识别、下游 down/drag/up 顺序、窗口或对象实际移动、真实抬手后无新位移、下一次点击与拖动正常。另测快速抬手、多指打断、tap 失效、关闭 Enabled、多显示器和原生拖移启用时的互斥。

单元测试重点覆盖事件顺序、迟到原生 up、等待 down 时抬手、旧 generation 回调、失败清理；现有测试只验证状态机和字段，不能替代微信窗口集成测试。

本次执行 `make test`：在正常图形会话权限下通过。初次受限运行卡在系统 `CGEventCreateMouseEvent` 内部，已终止该测试进程后重跑。未修改或替换应用实现，未执行候选方案的真实触控板 A/B 验证。

## 第一轮实现进展

用户要求开始修复后，已完成以下改动：

- 主动 event tap 从 session 改至 HID；down/drag/up 发布与主动过滤共用 `InputTapLocation`，不做静默降级。
- 增加 annotated-session 层的 listen-only 观察器，记录 `observed_downstream`；安装失败或失效仅影响诊断，不改变拖动所有权。
- 改写前增加 `movement_input`，事件记录增加 `delta_x/y`，日志头增加输入层级和观察器状态。
- 增加观察器不改变所有权、释放后事件关联、观察器失效不打断拖动，以及移动增量保留的回归断言。

`make verify` 已通过，包括构建、回归测试和严格签名验证。生成文件为 `build/TapDrag.app`，Bundle ID 和既有证书身份保持一致。

本轮尚未调整按下时序或引入 AX 后端。用户确认后，修复版已启动，PID 26295；新会话 `double-tap-E842E9D8-155F-45CC-805D-E21017694151-pid26295.jsonl` 确认 `input_event_tap: hid`、`downstream_observer_active: true`、原生拖移关闭。UI 工具启动时返回超时，但运行进程和新日志均证实启动成功。

已请求用户在原先失败的微信区域用真实触控板连续测试三次，并以普通窗口作对照。真实手势测试结果仍待确认，不能将构建通过或过滤器安装成功视为微信问题已修复。

## 实测发现与第二轮修复

第一轮运行日志证实存在实际事件乱序。会话 pid26295 的 event number 23383 中，sequence 105 为发布 down，sequence 109 在下游观察到目标微信 PID 23013 的 drag，sequence 110 才观察到 down。这说明仅把主动过滤器移到 HID 仍不能避免原地返回的原生事件越过异步发布的事件。它是已复现的事件链缺陷；仍不能单独解释全部微信失败手势。

第二轮已改为消费原生 movement，再创建和 down/up 使用同一 HID event source 的 drag。三种事件都在 `gSyntheticLock -> gChainLock` 的既有锁序约束下发布，移动发布前重新核对 generation、phase 和 event number。重发使用当前单调时钟时间戳，保留原生位置、delta 和修饰键，不复制原生事件的路由注释或伪造来源身份。自有事件按 tag 直接放行，避免重发回环；Releasing 或过期 generation 的 movement 不再发布。

事务测试使用截获发布函数的方式，不向桌面发送测试事件；已验证 down/drag/up 发布顺序、同一事件编号和来源、有效单调时间戳、原生 movement 被消费、自有事件不会再次发布，以及释放中/释放后旧移动被拒绝。`make verify` 再次通过。

第二轮应用已启动，PID 26511；会话 `double-tap-C9BE6D24-33E9-48B9-A8D2-DB7A9A0E5794-pid26511.jsonl` 标记 `drag_delivery: serialized_hid_post`，HID 与下游观察器均已启用。第二轮真实手势验收仍待完成。

## 第二轮反馈与输入链调查

用户反馈第二轮微信仍很难成功，普通窗口正常；随后明确文字拖选也失败。第二轮保留的完整微信链已在下游按 down/drag/up 顺序出现，故已证实的乱序缺陷不足以解释主要兼容问题。不能把它写成微信失败的唯一根因。

临时尝试的 AX 窗口路径已全部撤除，包含类型、窗口查询、移动队列、释放分支和专用测试；对应运行实例已结束。当前应用仅使用鼠标事件路径。

当前诊断 schema 2 增加事件 flags、button number、subtype，以及回调时采样的 HID/combined-session 左键状态。观察器也记录原生 leftMouseDragged，用于与真实按压拖动对照；采样状态反映观察时刻，不能替代事件自身的字段。

另外安装了微信 PID 的 listen-only event tap，记录 `observed_target_process`。它可以确认事件走到进程路由观察点，但仍不等同于微信内部控件已处理。它与下游观察器一样不改变事件或手势状态；重启微信后需重启诊断版以重新绑定 PID。

诊断应用 PID 28073，会话 `double-tap-1B7C8867-91DD-4413-A7E4-65AAD95C59A0-pid28073.jsonl`，确认 `target_observer_pid: 23013`。`make verify` 通过。已请求在同一文本区域先进行一次真实按压拖选，再进行两次双击拖选；尚未取得这组对照，当前不能确定微信失败的根因。

## 文字拖选对照：触控子类型丢失

用户随后完成按压与双击文字拖选，反馈双击只能选中 1–2 个字。pid28073 会话中的进程级观察显示：

| 事件组 | 代表 event number | 持续时间 | drag 数量 | 指针位移 | subtype |
| --- | --- | --- | --- | --- | --- |
| 原生按压 | 3515 | 650 ms | 26 | (945,396) -> (1042,394) | 3 |
| 合成拖选 | 18975 | 445 ms | 47 | (926,397) -> (1026,399) | 0 |

两组都到达微信窗口 5228，拖动过程中 HID/combined-session 左键状态均为按住，button number 为 0，flags 为 0，drag pressure 为 1，代表组 click state 均为 1。失败组不是只生成了 1–2 个字符距离的移动，也没有中途出现对应 up。

该日志保留的 109 条原生 drag 均为 subtype 3，368 条合成 drag 均为 0；363 条改写前 movement 输入也均为 3。说明本工具重建 CGEvent 时丢失了触控来源子类型。Apple 的 `NSEventSubtypeTouch` 与 SDK 的 `NX_SUBTYPE_MOUSE_TOUCH` 对应；[Handling Trackpad Events](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingTouchEvents/HandlingTouchEvents.html) 说明触控生成的鼠标事件携带该子类型。

已做单变量对照改动：`createTaggedEvent()` 为整套 raw-trackpad 驱动的 down/drag/up 设置 `NSEventSubtypeTouch`，其他识别参数与事件字段不变。事务回归同时验证 CGEvent 字段和转换为 NSEvent 后的 subtype；`make verify` 通过。

新运行实例 PID 28336，会话 `double-tap-995081FF-F122-4DDA-8E18-D70CDE1C2B6E-pid28336.jsonl`。日志头新增 `synthetic_mouse_subtype: 3`。触控子类型丢失是已确认的输入字段差异，但它是否是微信停止扩展选区的原因，仍须由该单变量版本的真实结果验证，不能提前宣告根因已证实。

## 触控子类型对照结果与观察范围补全

用户确认 subtype 3 版本仍只能选中 1–2 个字。这排除了仅补齐 subtype 即可解决的假设。该版本 event number 8771–8776 的微信链仍包含完整 down/drag/up，移动距离约 70–110 px；不能把字段差异当成主要根因。

在微信输入框现有测试草稿上，通过 UI 自动化直接拖动可以选中整段文字。该测试没有真实触控输入，也没有运行 TapDrag 的识别和事件构造路径，因此只证明至少存在一种可被微信正常处理的模拟拖动，不能作为本工具通过验收的依据。

随后微信出现要求重新登录的安全提示，原因未确定，已停止主动测试。临时命令行事件探针的日志目标是 PID 21461，而非微信 PID 23013，该次探针结果无效，不能用来判断事件内容是否兼容；探针源文件已撤除。恢复测试时需要重新确认窗口和目标进程，不能沿用已失效的屏幕坐标。

发现此前观察器虽订阅 mouseMoved，却主动忽略非自有 mouseMoved，因此原有记录无法排除拖动过程中普通移动插入。诊断 schema 3 在非 idle 手势期间记录此类事件并关联 generation；只读观察范围同时加入公开的滚轮、其他鼠标按钮和 tablet 事件，主动过滤范围不变。不采集键盘输入。本轮不引入新的行为修复，尚需真实复现来确定是否存在事件干扰。此观察范围也不等于 AppKit 内部的所有触控或手势回调。

`make verify` 与 `git diff --check` 通过。观察器回归验证空闲时忽略普通移动、拖动中两级观察器均保留并关联普通移动、事件不被改写或消费。运行实例 PID 28685，会话 `double-tap-987BD234-B74C-4996-B75C-A0FBB326BC93-pid28685.jsonl` 已确认 schema 3、下游观察器启用、微信观察 PID 23013。等待用户恢复微信登录后继续集成验证；当前问题仍未解决。

## 恢复登录后的对照：第二次按下与双击识别

用户恢复登录后，在文件传输助手输入框的测试草稿上比较了按压与双击拖选，双击仍停在 1–2 个字符。pid28685 的已保留完整链中，没有观察到 Owned 期间的非自有鼠标事件插入；普通移动只在 Candidate 阶段出现。这降低了已订阅鼠标事件干扰的可能性，但不能排除未观测到的 AppKit 内部触控处理。

用户进一步说明：双击拖动在微信中表现为双击，不能持续扩大选区。第二次触摸后保持手指不动并不能隔离双击判定，因为现有 hold promotion 会在 180 ms 时自动发送第二次 down。代表链 event number 17132 中，原生首击 down 在 wall_ms 810274132307，合成第二次 down 在 810274132468，相差 161 ms，仍处于本机 800 ms 的双击间隔内；第二次 down 的显式 click_state 为 1。不能仅据此认定微信使用了何种内部判定算法。

新增仅启动参数启用的 `--diagnostic-isolate-clicks` 对照模式，将第二次 down 的最早时刻改为第二次接触后 `max(1000 ms, 系统双击间隔 + 200 ms)`，保留其他事件字段和路径。若手指在延迟期间抬起，取消未启动事务并使旧任务失效，禁止事后补发点击。正常启动仍使用原 40 ms allowance；该参数不写入用户偏好，不作为正式交互方案。

`make verify` 通过，包含默认时序保持不变、实验时序超出双击间隔、提前抬手不发送事件的断言。诊断实例 PID 29110，会话 `double-tap-8E437CB6-E669-420A-A477-D41F091EDC4D-pid29110.jsonl` 已确认 `diagnostic_isolate_clicks: true`、`synthetic_down_allowance_ms: 1000`。已请求第二次接触停住约 2 秒后再移动的对照，结果待确认。

## 自动回放定位与首击缓冲修复

用户反馈延迟版仍不成功。检查 pid29110 保留的完整 generation 30–62，均在等待期结束前 `quick_release_aborted`，没有 synthetic down。因此这批手工结果不能排除双击判定。延迟实验及对应启动参数已经撤除，恢复正常启动时序。

用户同时确认 macOS 原生拖移在微信正常，随后恢复关闭原生拖移以测试修复。旧版本历史显示“只替原生拖动提前释放”曾导致连续拖动需要重新合成 down，因此没有直接回退到该方案。

新增 `tests/manual_wechat_probe.m`，仅在微信聚焦输入框的内容精确等于测试草稿 `0123456789 abcdefghij` 且屏幕起点最上层普通窗口属于微信时发送鼠标事件。通过公开 AXSelectedTextRange 属性读取选区长度，不发送键盘或消息。原先进程定向回放缺少有效窗口路由，没有改变选区，这些尝试不计入结论；最终探针仅保留经过目标确认的 HID 路径。前台应用 PID 并非鼠标命中窗口 PID，最终以鼠标起点窗口校验为准。

固定 140 px 距离、35 个 drag、每步 15 ms 的对照：

| 回放 | 第二次按下间隔 | 选区在 step 5/10/15/20/25/30/35 的长度 |
| --- | --- | --- |
| 单次按下后拖动 | 无首击 | 3 / 5 / 8 / 10 / 13 / 16 / 18 |
| 首击后再按下拖动，click_state 1 | 120 ms | 10 / 10 / 10 / 10 / 10 / 10 / 10 |
| 首击后再按下拖动，click_state 0 | 120 ms | 10 / 10 / 10 / 10 / 10 / 10 / 10 |
| 首击后再按下拖动，click_state 1 | 1100 ms | 3 / 5 / 8 / 10 / 13 / 16 / 18 |
| 实际首击缓冲 + startSyntheticDrag + postNativeMovementAsDrag 路径 | 正常启动 | 3 / 5 / 8 / 10 / 13 / 16 / 18 |

失败组在第二次 down 后即选中第一个 10 字符词，并保持该长度。它与用户在中文内容中看到的 1–2 字词选区一致。这个受控对照证明前置点击是该失败模式的触发条件；不能进一步断言微信内部使用哪个框架或哪段函数。

实现：独立 annotated-session 按钮过滤器只针对已识别 raw 首击、实际目标微信且原生拖移关闭的情况。保存首击 down/up，在约 200 ms 判定期内没有第二接触则补发；第二接触正在判定时继续暂存，创建拖动事务成功后取消首击。真正的普通双击统一序列化补发，以免第二次 down 越过首击。补发普通单击后恢复指针当前位置。其代价是微信轻触单击的短暂延迟；没有窗口位置移动后端。

`make verify` 通过，新增单击补发、双击顺序、过期 timer、拖动取消首击、指针恢复、其他目标与系统原生拖移开启时不缓冲的测试。探针另以相同严格编译警告通过。修复实例 PID 32055，日志 `double-tap-6C530807-4559-4BB3-8FFB-09BBE9F78578-pid32055.jsonl`，确认 `wechat_first_tap_buffer: true`。随后收到真实触控板文字拖选成功的用户反馈，具体边界见最终验收记录。

复现实验（会向已确认的测试输入框发送鼠标事件，不属于无副作用单元测试）：

```sh
clang -fobjc-arc -Wall -Wextra -Wswitch-enum -Werror tests/manual_wechat_probe.m -o build/tests/manual_wechat_probe -framework AppKit -framework ApplicationServices -framework ServiceManagement -framework UniformTypeIdentifiers
build/tests/manual_wechat_probe single-hid
build/tests/manual_wechat_probe double-hid 1 120
build/tests/manual_wechat_probe double-hid 1 1100
build/tests/manual_wechat_probe buffered-hid
```

## 最终验收记录

2026-09-05，用户测试修复版后确认：“测试后，微信可以正常双击拖选了”。这补齐了实际首击缓冲路径回放之外的真实触控板文字拖选验收。

| 验证项目 | 结果 |
| --- | --- |
| 微信真实触控板双击文字拖选 | 用户确认恢复正常 |
| 实际首击缓冲路径的微信输入框回放 | 选区随移动持续扩展，最终 18 个字符 |
| `make verify` | 构建、回归测试、严格签名验证通过 |
| 手动回放探针严格编译 | 通过 |
| 微信窗口拖动 | 尚未获得修复后的明确实测确认 |
| 微信普通单击、双击 | 自动化补发与顺序测试通过；实机回归尚未获得明确确认 |

首击缓冲方案保留正常的拖动启动时序，避免双击选词冲突。已知交互代价为微信轻触单击约 200 ms 的判定等待。该轮版本仍有微信重启后目标 PID 失效的限制，后续修复如下。

## 微信重启后的 PID 失效修复

用户随后报告：微信通过 Command+Q 退出再打开，双击拖动再次失效。代码确认 `installEventTap()` 仅在安装时读取微信 PID，首击缓冲与进程观察器始终绑定旧进程；新的微信鼠标事件绕过首击缓冲，因此重新触发双击选词冲突。

修复改为在主线程监听 NSWorkspace 启动、退出和激活通知，自动更新微信 PID 并重建进程观察器。初始化时先订阅再枚举现有微信，也支持先启动 TapDrag、后启动微信。PID 切换时丢弃旧进程的点击缓冲并使旧超时任务失效，避免补发到新窗口；迟到的旧进程退出通知不会清除新目标。只读观察器安装失败时，首击缓冲仍使用新 PID，微信再次激活时重试观察器安装。

`make verify` 通过。新增回归覆盖退出清理、新 PID 首击缓冲、旧 PID 不再匹配、迟到通知、无关应用通知、观察器失败与激活重试、停止监听后的通知忽略。测试截获鼠标发布，不向桌面发送点击。真实微信退出再启动后的触控板拖选仍待用户验收；此前文字拖选成功不作为本次重启场景的验收结果。
