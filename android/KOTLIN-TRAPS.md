<!-- SPDX-License-Identifier: MIT -->
# Kotlin 陷阱（本移植踩过的，逐条附症状与代价）

这些不是风格问题：每一条都**编译通过或测试报错的位置与真凶位置相距很远**，且都让至少一条车道花掉 20 分钟以上。
新增条目时请写清「症状长什么样」，因为下一个人是先看到症状的。

## 1. `typealias` 不能做嵌套类型的限定符

```kotlin
typealias EngineState = EngineHostState          // 合法
val s: EngineState = ...                          // 合法
if (s is EngineState.Running) { ... }             // 编译不过：Unresolved reference
EngineState.Stopped                               // 编译不过
```

**症状**：改用 alias 之后，所有 `when (state) { EngineState.Stopped -> ... }` 一起红，报的是「Unresolved reference」，
看起来像 alias 没生效。

**做法**：变体一律写全名（`EngineHostState.Running`），alias 只用于类型位置。

**代价**：一条车道在 `:app` 里留了 40 处 `EngineState.<变体>`，整模块编译失败。

## 2. 块注释可嵌套，KDoc 里的 `/*` 会吞掉文件

```kotlin
/**
 * The WAL's current size: every `wal/*.xlwal` file, header included.
 */                                            // ← `/*` 在这里开了一个嵌套注释
class WalQuota { ... }                          // ← 整个类被注释掉了
```

**症状**：报的是**文件末尾**的「Unclosed comment」，以及**几百行之后**的「Unresolved reference」。
真凶那一行本身看起来完全正常。

**做法**：注释里不要出现 `/*`。写 `wal/<epoch>.<segment>.xlwal` 或 `wal/&#42;.xlwal`。
反引号救不了：`` `wal/*.xlwal` `` 里的 `/*` 照样嵌套。

**机器检查**：`structure_check` 第 9 项 `nested-comments`（状态机扫描，跳过字符串/原始字符串/字符字面量/行注释，
所以 `"/dsh/home/sessions/*/x.jsonl"` 这种路径 glob 不会误报）。

**代价**：两条车道各花 20 分钟；它上线两小时后就抓到了第三条车道的在途代码。

## 3. `java.nio.file.Path` 实现了 `Iterable<Path>`，`list += path` 会选错重载

```kotlin
val files: ArrayList<Path> = ArrayList()
for (entry in dir) {
    files += entry            // 编译错误：'val' cannot be reassigned
}                              // Assignment type mismatch: List<Path> vs ArrayList<Path>
```

**症状**：`files += entry` 明明像 `plusAssign`，报的却是「`val` 不可重新赋值」+「类型不匹配」。

**原因**：`Path` 实现了 `Iterable<Path>`，所以 `files += entry` 同时匹配 `plusAssign(element)` 与 `plus(Iterable)`，
Kotlin 选了后者，展开成 `files = files + entry`——对一个 `val` 赋值，且右侧类型是 `List`。

**做法**：写 `files.add(entry)`，不要对「元素本身可能可迭代」的类型用 `+=`。

**代价**：一条车道把 `:dsh` 编译搞红，另外两条车道的 `:lib`/`:dsh` 验证被挡。

## 4. `tasks.named("test")` 在 Android library 上不存在

```kotlin
tasks.named("test") { ... }        // Android library: Task with name 'test' not found
```

**症状**：**任何** gradle 命令在**配置阶段**就失败，报错指向一个看似无关的模块。

**做法**：`tasks.matching { it.name == "test" }.configureEach { ... }`（惰性配置），或直接测 `testDebugUnitTest`。

**代价**：一批车道被迫加 `--configure-on-demand` 才能跑任何命令。

## 5. 声明成 `inputs.file(...)` 的路径会先于 `doFirst` 校验

```kotlin
tasks.test {
    inputs.file(nativeLibrary).withPropertyName("pdshJniLibrary").optional()
    doFirst { check(nativeLibrary.isFile) { "missing ...; build it with: cargo build -p pdsh-jni" } }
}
```

**症状**：缺 dylib 时报的是 Gradle 自己的「specifies file ... which doesn't exist」，
`doFirst` 里那句可操作的提示**永远看不到**。

**做法**：不把可能缺失的文件声明成 input，把可读的检查留在 `doFirst`。代价是重建 dylib 不再自动触发重跑
（CI 本来就用 `--rerun-tasks`）。

**代价**：CI 上一条本来 5 秒能解决的问题，变成要看懂 Gradle 的输入校验才能定位。

## 6. 零断言的 `return` 会被 JUnit 记成 PASS

```kotlin
@Test
fun someTest() {
    if (Build.VERSION.SDK_INT < 34) {
        println("BLOCKED")
        return                     // ← 这条测试是绿的，且什么都没断言
    }
    ...
}
```

**症状**：仪表盘全绿，覆盖率没涨，行为没验。

**做法**：`assumeTrue(...)`（记 skip）或 `fail(...)`。**绿的 no-op 比红的测试更贵**，因为它会让人相信已经验过。

**代价**：一条 UIDT 测试在 API 33 上「通过」了很久，实际一行断言都没跑。

## 7. `BUILD SUCCESSFUL` 可以是「什么都没跑」

```text
$ ./gradlew test
BUILD SUCCESSFUL in 9s
276 actionable tasks: 10 executed, 266 up-to-date
```

**症状**：`BUILD SUCCESSFUL in 9s`，看起来全绿。真话在最后一行：`10 executed, 266 up-to-date`
——测试任务全被增量构建跳过，**一条断言都没执行**。

**真凶**：Gradle 的增量构建。测试任务的输入（源码、依赖）没变就跳过；而
`android/tools/test-count.sh` 读的是**上一次运行留下的 XML**，所以报告出来的数字也是旧的。
运行和计数两边一起说谎，且没有任何一处报错。

**代价**：改的东西如果不在 test 任务的输入里（资源、另一份文件里的期望值），会得到
「改完了还是全绿」的错觉。更常见的是：上一个人刚跑过，你这次的绿根本不是你的代码的绿。

**正确做法**：**验证性运行**（收口、验收、写进文档给人看的数字）必须带 `--rerun-tasks`，
并且读 `actionable tasks` 那行的 `executed` 数——`10 executed` 就是没跑。
本仓库 `android/README.md` 里的测试数全部来自一次 `./gradlew test --rerun-tasks`
（2026-10-31，`10 executed` 那一类输出不采信）。

## 8. 消费方的假设会随实现变更失效

```kotlin
// ChatScreenState：拿 node.parentID 当「回合节点」来关闭回合
openTurns.remove(node.parentID)          // 投影器还没发 turn-event 节点时，这是对的
```

**症状**：投影器补上 `turn-event` 节点之后（`trajectory.md` §7 要求每行挂在
`.../turn/<tid>/event/<seq>` 下），回合**永不关闭**：composer 一直显示 STOP，
运行中的工具行渲染成 STOPPED。**不崩溃、不报错、没有红测试**——UI 一致地说谎。

**真凶**：`/event/<seq>` 这一层的父是 `turn-event` 节点，不是 turn。消费方「父就是 turn」
的假设在它被写下的那一刻成立；投影器新增一层后，假设静默失效。修法不是再猜一层字符串，
而是按规范从自己的 `nodeID` 截出 turn 段（`nodeID.substringBefore("/event/")`），
见 `ChatScreenState.kt`。

**代价**：没有异常、没有堆栈、没有失败用例——只有一条从头到尾都在骗人的界面，
且它出现在「看起来最该有测试覆盖」的聊天气泡上。

## 9. 合成夹具照实现的假设手工构造数据

```kotlin
private fun node(...) = UiStateNode(
    nodeID = "session/s1/turn/turn-0001/event/1/$slot",
    parentID = "session/s1/turn/turn-0001",   // ← 照实现的旧假设手写，不是照规范
    ...
)
```

**症状**：测试**永远绿**。`ChatScreenStateTest` 手工建 TOOL_ROW，`parentID` 直接写成 turn
——旧假设在夹具里仍然成立，所以 #8 那个 bug 没有一条测试抓得到。

**真凶**：夹具照实现的当前行为构造，于是测试和实现共享同一个错误前提；改实现前提时，
夹具是「跟着改」的，永远不会变红。夹具的规格应当是 `spec/v1/trajectory.md` §7 的节点语法
（每行挂在 `turn-event` 下），不是实现今天怎么读字段。

**做法**：能从规范派生的夹具就派生（`SpecFixtures.projectCase` 从 `spec/v1/golden` 投影），
不得不手写时用语法断言兜住（`UiStateNodeIDGrammarTest` 会检查每个 `parentID` 恰好在
`nodeID` 上一级）。改断言前先问「规范怎么说」，再问「夹具为什么这么写」。

**代价**：#8 在整轮里没被任何测试抓到。（残留：`ChatScreenStateTest.node()` 至今仍把
`parentID` 写成 turn；实现改成按 `nodeID` 截断后它才不再是陷阱。）

## 10. 校验写在字段「起作用」的地方

```python
# 只在这两个 kind 上比 seq —— 因为只有那里 seq 决定 nodeID
if parsed[0] in ("event", "slot") and parsed[3] != row["seq"]:
    raise NormError("UNSTABLE_NODE_ID", where, "node id disagrees with seq")
```

**症状**：`trajectory_norm` **从不**校验结构节点（`root`/`session`/`turn`）的 `seq == 0`；
一个带 `seq = 17` 的 turn 行照样 normalize 通过，而规范说结构节点必须是 `0`。

**真凶**：校验被写在了字段「起作用」的地方。`seq` 只在 event/slot 上参与 `nodeID` 的拼装，
在结构节点上「没用」，于是没人校验它。判据是**规范要求**什么，不是**这项校验能改变哪个字节**
——`trajectory_norm.py` 里补上的那条检查就是一句话：`root`/`session`/`turn` 的 `seq != 0` 即错。

**代价**：错误输入被归一化成一份「看起来完全合法」的轨迹，问题在两跳之后才暴露，
而那时已经很难判断是输入坏了还是归一化坏了。
