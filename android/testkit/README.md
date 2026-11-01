<!-- SPDX-License-Identifier: MIT -->
# `:testkit` — 场景 catalog 的第三个 runner

`:testkit` 合并了 Swift 侧的两个模块（包名 1:1，Gradle 只做构建边界）：

- `com.phonedsh.testkit.scenario` — `ScenarioRunner` / `CatalogLoader` / 内存执行器；
- `com.phonedsh.testkit.trajectory` — 轨迹归一化；
- `com.phonedsh.testkit.harness` — **第三 runner 的 host 执行**（本文件新增的部分）。

"第三 runner" 指与 macOS / iOS Simulator 并列的 Android 一侧：同一份
`scripts/ci/scenarios/catalog.json`，在纯 JVM 上解码、执行、判决，不需要 WebView、
不需要设备、不需要模型。

## 现在覆盖什么

### `HostScenarioExecution`（`harness/`）

用**真的** `:core` WAL 和 `:dsh` host 实现 `ScenarioExecution`：

| 环节 | 真实组件 | 事实 |
| --- | --- | --- |
| 建工作区 | `HostChannel` → `VfsSink` → `WorkspaceLog.appendMutation` → `Materializer` | 每个种子文件一条 `VFS_MUT`，走 Rust codec 解码；**从不直接写物化目录** |
| 确认写入 | 每条 mutation 的 `VFS_ACK(level=1, upto_mseq=mseq)` | mseq 与发送值必须一致，否则抛执行错误 |
| 封 epoch | `VfsSink.closeEpoch` → D18 顺序 | `VFS_ACK(level=2)`，覆盖 `durable_upto` |
| self-check | 物化树 | seed 后逐字节比对 `materialized/workspace`，不一致即抛异常（不交给 runner 判） |
| HELLO | `DefaultPhoneDshHost` 的门面 | 从实际发出的帧里断言 `channel/1`、`wal/1`、`exec/1`、`accelerator:phone` |
| 读取 | `workspaceFiles()` / `readFile()` | 直接读 WAL 的 `materialized/workspace`，带路径穿越防护 |
| `consoleErrors` | host 门面的 error 级日志（注入 `HostLog` recorder） | 没有 Worker console（没有 WebView），所以 `no_console_error` 比 macOS 弱：它只证明 host 没报错 |
| `runWorkspaceCommand` | `ToyboxWorkspaceCommandRunner` | 见下 |
| `perturbationCoverage` | `null` | 没有重启驱动；runner 会把 `restart_recovered` 判成失败，**不会**空过 |

测试里用的 engine / clock / durability / notifier 是 `:platform` 的共享 JVM 替身
（`FakePlatform`）：JVM 测试没有 WebView，门面只需要 `EngineHost` 到达 `Running` 让
D14 打开 admission。WAL、VFS sink、channel、codec 都是真的。

### 两种 turn 驱动（都没有真模型）

- **`ScriptedTurnDriver`** — 回放**预置的** `TurnOutcome`。模型由脚本驱动，不是真模型；
  它不读 prompt、不写工作区。想表达"这一轮算成功，去按真实物化树判 file 断言"就用它。
- **`NoModelTurnDriver`**（默认）— 每一轮都 `delivered = false`。这不是产品失败，
  而是"本 lane 还没有模型"的事实：runner 的 run-completion gate 会把所有进度相关断言
  标成 `NOT_EXECUTED`，场景永远不可能通过。

接真模型需要 `:net` 的 `GatewaySession` + 真 upstream + engine 的 turn/tool 循环，
属于后续工作，不是驱动能伪造的。

### `runWorkspaceCommand`：`ToyboxWorkspaceCommandRunner`

Android 沙箱没有 `bash` / `python3` / `git`。这个执行器只做两件事，并且说清楚做了哪件：

1. **真跑**：命令若只使用 POSIX sh 控制流 + toybox 子集的 coreutils（`grep`/`test`/
   `wc`/`find`/`sed`/`awk`/`ls`/`cut`/`sort`/`tail`/…），就 `ProcessBuilder(sh, "-c", …)`：
   - 把物化树（`workspace/` + `home/`）拷进临时目录，`/dsh/workspace` 重写成该副本；
   - cwd 指向副本，副本是一次性的（命令写文件不会污染物化树）；
   - 返回**进程自己的退出码和输出**；exit 0 就是真的 0。
2. **如实延后**：需要 `git`/`python3`/`bash`/`tar`/`xargs`/`find -exec`、需要 bash 专有
   语法（`[[`、`${…}`、`<<<`、进程替换、here-doc、函数/数组……），或者本机没有
   `sh` 时，返回 `CommandOutcome.pendingHost(...)`——runner 记为 `PENDING_HOST`，
   **永远不算 pass**。

执行的证据里写明执行者：`exit 0 (host-sh /bin/sh; toybox-subset command; N file(s)
copied from the materialized tree)`。在真机上同一份代码会解析到 `/system/bin/sh` +
toybox applet；二者是同一子集，但不是同一个二进制。

### `CatalogOnHostTest` 跑的真实场景

G2-C04（唯一纯内存可满足的场景）已由 `ScenarioRunnerEndToEndTest` 覆盖，这里不重复。
其余 55 个场景都要求模型产出文件/状态，因此**没有模型时不可能通过**；测试断言的是
**诚实的判决形状**，不是"pass"：

| 场景 | 结果 | 为什么挑它 |
| --- | --- | --- |
| `G2-B06` | 通过 3 + `PENDING_HOST` 4，失败 0 | 唯一"非命令断言全部被 seed 满足"的场景；4 条 `git` 如实延后，1 条 POSIX sh 真跑 exit 0，`file_regex` 真读物化树 |
| `G2-A10` | 失败 4（1 missing + 3 真进程非 0） | 3 条命令全在 toybox 子集；证明**不会伪造 exit 0**（`wc`/`awk`/`sed` 真的报错） |
| `G2-A06` | 失败 2 | POSIX `for` 循环与 `||` 控制流真跑；3 个 seed 日志文件存在，模型没写 rotate.sh |
| `G2-C01` | 通过 3 + 失败 7 | 同一个执行器上既有真 exit 0（两条 `if grep` 守卫）也有真 exit 2（`grep` 读不到的 README） |
| `G2-E03` | 通过 3 + 失败 4 | `tail` 管道接 `while read` 与 `for` 循环真跑；`find`/`grep` 的真实诊断 |
| `G2-E08` | 通过 2 + `PENDING_HOST` 2 + 失败 1 | `office-files` 的 6 个二进制 OOXML **逐字节**穿过 `VFS_MUT` → WAL → 物化；`python3` 两条如实延后 |
| `G2-C06` | 失败 9 + 通过 4 | 钉死 fail-loud：没有重启驱动时 `restart_recovered` 是 ERROR；另有一条 `ls` + `awk` 命令真 exit 0 |
| `G2-B06`（`NoModelTurnDriver`） | `NOT_EXECUTED` 6 + 通过 1 | 钉死 run-completion gate：没交付 turn 就没有进度判决，物化树仍然是真的 |

### 真回合的测试面（`upstream/`、`channel/`、`androidTest/`）

这一节是 N1 车道新增的：**脚本化 upstream + 一个完整回合**。它不是"第三 runner 交付了一个 turn"，
而是"模型是脚本、其余全真"的一次设备实测：

| 环节 | 组件 | 真的 / 脚本的 |
| --- | --- | --- |
| 模型 | `upstream/ScriptedModelUpstream` | **脚本**。第一次请求回一个 `bash` tool call（命令 `phone info`），带着 tool result 的第二次请求回最终文本。实现了 worker 真正用的 Messages SSE（`POST /v1/messages`）与任务要求的 OpenAI 兼容（`POST /v1/chat/completions`）两种编码 |
| 出网 | `upstream/UrlConnectionGatewayTransport` + `upstream/GatewayFrontServer` | **真** `:net` `GatewaySession`（allowlist 精确到 `http://127.0.0.1:<port>`、头策略、响应日志）。`/v1/http` 前置是测试面替身：app 里的该路由属于 `src/main`，本车道没有实现 |
| 通道 API 车道 | `channel/ApiFrameChannel` | **真帧**：`API_REQ`(0x40)/`API_RES`(0x41)/`API_END`(0x42)/`API_ABORT`(0x43)，编码/解码走 `:core` 的 Rust codec。`:dsh` 的 `HostChannel` 只实现 HELLO/VFS/EXEC，所以这半边在测试面 |
| 会话驱动 | `channel/DshTurnClient` | **真 Worker**：`session/create` → `session/prompt` → `POST /api/remote.mux`（`session/follow`）读回 worker 自己产生的 host event |
| 工具执行 | `:dsh` `HostExec` + `PhoneInfoTool` | **真**：worker 发 `EXEC_REQ(argv=["phone","info"])`，host 真的执行并回 `EXEC_EVT`；设备实测日志见 `exec dispatch: tool=phone` / `tool executed: phone` |

设备测试是 `TurnOverChannelInstrumentedTest`（androidTest）：真 WebView、真 65 MB worker bundle、
真 loopback origin、真 WAL、真 channel。运行：

```sh
bash android/tools/run-turn-demo.sh
```

**诚实红线**（与仓库其余部分一致）：

- 模型由脚本驱动，报告里必须这么写；本车道从不声称跑过模型。
- `turn_started` / `tool_call` / `tool_result` / `turn_ended` 全部来自 worker 的
  `session/follow` 记录，不是测试自己打印的。
- 测试面补了两处 `:dsh` 未实现的主机行为：`/api` 车道与 `JOURNAL_ACK`（0x31）。
  两条都写在测试文件的注释和最终报告里；JOURNAL ack **不**写入任何持久化，只是让
  worker 的 durability wait 在测试里不超时。
- `VFS` 断言读的是 `WorkspaceLog` 的物化树（`materialized/home`、`materialized/workspace`），
  不直接写盘。

## 还缺什么（逐条）

1. **真模型**。`:net` 的 gateway + 真 upstream + engine turn 循环都没接到本 lane。
   在此之前，catalog 里只有 G2-C04 能在 seed 上通过；其余场景的 file 断言必然失败。
   这不是 runner 的缺陷，是"没有模型就没有产出"的事实。
2. **真重启 / 扰动驱动**。`perturbationCoverage()` 恒为 `null`，`restart_recovered`
   永远是失败行（fail-loud），不是通过。要做真重启需要进程被真的杀掉再拉起。
3. **bash 专有语法**。`[[`、`${…}`、`<<<`、`<(...)`、here-doc、函数、数组等一律
   `pending_host`；catalog 里大量命令属于这一类。
4. **宿主工具**。`git`（含 fixture 的确定性历史）、`python3`（130 条 `workspace_command` 断言里的大头）、
   `tar`/`gzip`、`xargs`、`find -exec` 一律 `pending_host`。
5. **设备执行**。`HostScenarioExecution` 目前只在 JVM 单测里跑；真要跑 instrumented
   还得把 `libpdsh_jni` 打进 APK，并把 `FakePlatform` 换成 Android 实现。
6. **host coreutils 与 toybox 的 flag 差异不检测**。`sed -i`、`find -printf`、
   `stat -f`、`tail -r` 之类在 macOS 上能跑、在 toybox 上语义不同；执行器只能保证
   **工具名**在子集内，不能保证每个 flag 一致。evidence 里写明 `host-sh`。
7. **没有 Worker/WebView console**。`no_console_error` 只看 host 门面的 error 日志。
8. **fixture 的确定性 git 历史没有 host 侧合成**。runner 只拷 `fixtures/<name>/files/`，
   所以 fixture 声明里的 `fixture.json` git 块不参与（与 `ScenarioRunner` 的 KDoc 一致）。
9. **没有落盘产物**。macOS runner 会写 `report.json` / `transcript.jsonl` /
   `workspace.tar`；这里只有内存里的 `ScenarioReport` 与测试日志。

## 怎么跑

```sh
# 1. host 侧 JNI（WorkspaceLog 的 Rust kernel + wire codec）
cd shell && cargo build -p pdsh-jni

# 2. :testkit 单测（JVM，无设备）
cd android && ./gradlew :testkit:test --no-daemon --console=plain
```

`:testkit` 的 test task 没有把 `shell/target/debug` 放进 `java.library.path`（本 lane
不能改 `android/testkit/build.gradle.kts`）。JVM 默认的 `java.library.path` 含 `.`，
Gradle 又用模块目录作为 test worker 的 cwd，所以 `HostHarness.stageNativeCodec()` 会把
`libpdsh_jni.dylib`（或 `.so`）拷到 `android/testkit/` 下再让 `System.loadLibrary`
找到它。那是**构建产物**，不是源码；已存在且大小一致时跳过拷贝，JVM 退出时由
shutdown hook 删除，工作树里不会留下二进制。

## 诚实红线

- 没跑的命令**绝不**返回 exit 0；跑不了就是 `PENDING_HOST`。
- `PENDING_HOST` / `NOT_EXECUTED` **永远**不算 pass（runner 的契约）。
- `runTurn` 的模型是脚本或缺席，任何驱动都不能往工作区写文件。
- `setupWorkspace` 只通过 `VFS_MUT` 物化；ACK 或字节对不上就抛异常，不交给 runner 判。
- 没有重启驱动就返回 `null`，让 runner 判失败。
