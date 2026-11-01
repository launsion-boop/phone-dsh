<!-- SPDX-License-Identifier: MIT -->
# `:shell` — rg / jaq 的真加速器（JNI 薄包装 `pdsh-ffi`）

`:shell` 镜像 Swift 侧的 `Sources/PhoneDSHShell`：它是 Rust 只读加速器的 **JNI 绑定面**，
不是加速器的实现。本模块 Kotlin 侧共 **10 个文件、903 行**（`src/main`；`src/test` 另 714 行），
全部在做「把 argv 交给 Rust、把结果帧解码回来、把失败映射成 Kotlin 异常」这三件事。

**这里没有第二套 `rg`/`jaq`。** `rg` 的搜索语义在 `pdsh-rg`，`jaq` 的 jq 语言面在 `pdsh-jaq`
（`jaq-core`/`jaq-std`/`jaq-json`），两者都通过 `pdsh-ffi` 这一份统一 C ABI 暴露；Kotlin 侧
**不重写任何命令逻辑**，只做委托。写第二套实现的代价是它与 Swift 宿主跑的那套静默分叉，
而这个模块存在的理由正是不让这件事发生。

## 一、JNI 面：4 个导出符号

Rust 侧 `pdsh-jni` 导出的名字固定为 `Java_com_phonedsh_shell_NativeShell_<name>Native`
（类名固定，导出名就不依赖 Kotlin 的编译细节）：

| 导出 | 作用 |
| --- | --- |
| `capsJsonNative(hasToolBridge)` | 读链接库的 capability JSON（加速器名单、版本、limits） |
| `runNative(argv, cwd, env, mounts, limits…)` | 一次 `pdsh_run`；返回二进制结果帧 |
| `jaqReadsStdinNative(argv)` | 这条 argv 会不会去读进程 stdin（判据在 Rust，见第三节） |
| `panicForTestNative(message)` | 测试专用 panic 钩子，恒 panic |

`NativeShell` 单例里：`System.loadLibrary("pdsh_jni")` → 懒读 capability JSON →
所有调用先过 `available` 检查 → `run` 走 `Dispatchers.IO`（阻塞的原生调用不占调用方线程）。

## 二、C ABI：7 个 `extern "C"`

`pdsh-ffi` 的 C ABI（`shell/crates/pdsh-ffi/src/lib.rs`）一共导出 7 个符号：

```text
pdsh_monotonic_nanos   pdsh_version
pdsh_caps_json         pdsh_caps_json_with_bridge
pdsh_run               pdsh_cancel            pdsh_join
```

`:shell` 这条调用路径实际用到其中 4 个：`pdsh_caps_json_with_bridge`（读 capability JSON）、
`pdsh_version`（版本串）、`pdsh_run` + `pdsh_join`（一次执行）。`pdsh_cancel`、
`pdsh_monotonic_nanos` 与不带 bridge 的 `pdsh_caps_json` 本模块不用（`pdsh_cancel` 为什么用不到见第八节）。
执行**一次调用 = 一个 `pdsh_run` + 一个 `pdsh_join`**。`pdsh_run` 靠 **`argv[0]` 查 registry**
决定跑哪个命令（`registry.run(&request.argv[0], …)`），所以 Kotlin 侧「支持哪些命令」不是一张常量表，
而是 capability JSON 里 registry 自报的名字；`RgAccelerator.NAME = "rg"`、`JaqAccelerator.NAME = "jaq"`
只作为 `argv[0]` 的守卫使用（`argv[0] != name` → `IllegalArgumentException`）。

`pdsh_run` 起 worker 线程并返回 handle，`pdsh_join` 等它结束；handle 没有被交给 Kotlin，
所以 `pdsh_cancel` 在这条路径上用不到（见第八节）。

结果帧是二进制而不是 base64-in-JSON（两个流本来就被 `maxOutputBytes` 限住了）：

```text
offset 0  4 字节  exit code，big-endian i32
offset 4  4 字节  stdout 长度，big-endian u32
offset 8  N 字节  stdout
offset 8+N         stderr（帧的剩余部分）
```

帧短于 8 字节、或 stdout 长度超出帧体 → `IllegalStateException`：那是原生侧缺陷，不是命令结果。

## 三、`jaq` 是否读 stdin：判据在 Rust，Kotlin 没有第二套参数解析

`exec` 的 C ABI 没有 stdin 通道，所以「`jaq FILTER` 不接文件也不带 `-n`」这种形状必须被拒绝——
否则它会去读宿主进程继承来的 stdin，把「Worker 想过滤点输入」变成一次很有说服力的空结果。

判定逻辑只有一处：

```rust
// shell/crates/pdsh-ffi/src/lib.rs 的 jaq_reads_stdin
match pdsh_jaq::args::parse(argv) {
    Ok(cli) => cli.files.is_empty() && !cli.null_input && !cli.help && !cli.version,
    Err(_) => false,
}
```

Kotlin 侧只有 `JaqAccelerator.readsProcessStdin(argv)` 一个转发口（`NativeShell.jaqReadsStdin`），
**没有** jq 选项表、**没有** `-n`/`--arg`/`--indent` 的 Kotlin 副本。用法错误不算读 stdin
（`args::parse` 返回 `Err` → `false`）：命令会先以退出码 2 退出，不会打开任何东西。

## 四、不可用：`available = false`，`run` 抛 `AcceleratorUnavailable`

三种情况都会让加速器「不可用」，且三种都必须可见：

1. `System.loadLibrary("pdsh_jni")` 失败；
2. 库加载了但 capability JSON 读不出/解析不了；
3. 库和 JSON 都好，但这个进程的库没自报该命令。

`available` 为 `false` 时 **`run` 抛 `AcceleratorUnavailable`，绝不返回空结果**。这是与 iOS
`PDSHShellError.notLinked` 对齐的规则：一个缺失的库必须长得像「库缺失」，不能长得像「命令没匹配到」。
`ShellAccelerators.detect` 也只返回 `available` 的那些——不把跑不起来的命令写进 HELLO。

失败映射（`NativeShellBinding`）：

| 原生侧 | Kotlin 侧 |
| --- | --- |
| `"SHELL_INPUT_INVALID: …"` / `"SHELL_START_FAILED: …"` | `AcceleratorException(code, detail)`（code 原样保留，新码不丢） |
| `"PDSH_JNI_PANIC: <op>: <detail>"` | `AcceleratorPanicException(op, detail)`——panic 不 abort 进程 |
| 库缺失 / caps 不可读 / 命令未自报 | `AcceleratorUnavailable(accelerator, cause)` |

## 五、`detect(emptyList())` 恒为空

`ShellAccelerators.detect(mounts)` 的第一条规则不是过滤，而是短路：

```kotlin
if (mounts.isEmpty()) return emptyList()
```

理由不是审美：`pdsh-ffi` 拒绝**每一个**没有 mount 的 run（`AcceleratorRequest` 的构造器也
`require(mounts.isNotEmpty())`）。没有 mount 还对外宣称有 `rg`，那句 HELLO 就是谎话。
这条规则与 iOS 的 `PDSHShellProvider` 相同：mount 列表为空时不发布任何加速器名。
mount 本身两条约束：guest 路径必须等于 `/dsh` 或在它之下（`AcceleratorMount.GUEST_ROOT`），
host 路径必须是绝对路径且目录存在（canonicalize 在 Rust 的 `MountTable` 里）。

## 六、`.so` 体积（实测）

`libpdsh_jni.so` 由 cargo 构建，不是 Gradle 构建：

| 产物 | 字节 | 人类可读 |
| --- | --- | --- |
| `shell/target/aarch64-linux-android/debug/libpdsh_jni.so`（未 strip） | 109,162,200 | **104 MB** |
| 同一份经 NDK `llvm-strip --strip-debug` | 32,216,056 | **31 MB** |
| `shell/target/aarch64-linux-android/release/libpdsh_jni.so` | 18,481,208 | 18 MB |

debug 版带完整 DWARF，所以 104 MB → `--strip-debug` 后 31 MB（debug 符号是主体，代码不是）。
打包时 debug 只装 `arm64-v8a` + `x86_64`（模拟器与测试宿主需要 x86_64），release 只装 `arm64-v8a`；
`jniLibs.useLegacyPackaging = false` 保持 16 KB 页对齐的 `.so` 映射不被解压破坏。

数值用 `stat -f %z` / `du -h` 在 2026-10-31 实测；`llvm-strip` 来自 NDK `30.0.16248370`。

## 七、测试：39 条，跑的是真 Rust 加速器

```sh
cd shell && cargo build -p pdsh-jni     # 先构建 dylib，:shell 的测试是它的消费者
cd ../android && ./gradlew :shell:test --rerun-tasks --no-daemon --console=plain
```

`android/shell/build.gradle.kts` 把 `shell/target/debug` 放进 `java.library.path`，所以测试加载的
是真库、真的跑 `rg` 和 `jaq`——一个从不执行的 stub 证明不了任何事。库缺失时 `doFirst` 会报
可操作的提示（不要把它声明成 `inputs.file`，见 `KOTLIN-TRAPS.md` #5）。

| 测试类 | 条数 | 内容 |
| --- | --- | --- |
| `RgAcceleratorTest` | 12 | 真 `rg`：匹配/无匹配/退出码/沙箱越界 |
| `JaqAcceleratorTest` | 7 | 真 `jaq`：过滤器/`-n`/stdin 判定/退出码 |
| `NativeShellTest` | 5 | caps JSON、limits 与 Rust 默认值对齐 |
| `NativeShellBindingTest` | 4 | 加载失败 / caps 失败分支（fake 调用） |
| `NativeShellCapsTest` | 3 | capability JSON 解析与坏形状 |
| `NativeShellPanicTest` | 2 | panic 以 Java 异常跨过 JNI |
| `ShellFrameTest` | 6 | 结果帧解码与畸形帧 |
| **合计** | **39** | `bash android/tools/test-count.sh :shell`，0 failing |

## 八、限制（诚实清单）

- **取消是事件级的，不是执行级的。** `run` 里一次 `pdsh_run` start+join，C ABI 没把 handle 交给
  Kotlin，所以一次 EXEC_CTL `cancel`（或取消协程）只停**事件流**；Rust worker 会继续读到结束或
  `timeoutMs` 到期。真要中断执行需要 start/cancel/join 三个 JNI 口（iOS 的 shell 有）。
- **没有 stdin。** 见第三节；`stdin.mode = pipe` 的 exec 请求应由 exec 桥在到达加速器前拒绝。
- **`:shell` 不做 VFS 路径翻译。** guest→host 的映射由 `pdsh_core` 的 `MountTable` 做，
  Kotlin 只传 mount 对。
- **R8 必须保留原生方法名。** 它们靠 `System.loadLibrary` 在运行时解析；`consumer-rules.pro`
  随 AAR 下发，不带它的 release 构建会得到只在 release 出现的 `UnsatisfiedLinkError`。
- 默认 limits 与 `pdsh_core::Limits::default` 同值（timeout 30,000 ms、每流 1,048,576 字节、
  10,000 个文件、单文件 15,728,640 字节），并由 `NativeShellTest` 对着链接库自报的 JSON 钉住。
