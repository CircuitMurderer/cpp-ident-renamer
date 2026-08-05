# cpp-ident-renamer

`cpp-ident-renamer` 是一个用 Zig 和 libclang 实现的 C++ 语义命名检查与重构工具。默认扫描、报告并把可修复项写入项目根目录的 `idents.tsv`；只有显式传入 `--fix` 或 `-f` 才会修改源码。

它会读取 `compile_commands.json`，遍历真实的 Clang AST，并检查：

- 非静态成员变量：`numberOfSlice` → `m_nNumberOfSlice`
- 静态成员变量：按 `static_member` 前缀检查
- 全局及命名空间变量：`defaultKeyword` → `g_sDefaultKeyword`
- 指针层级位于作用域和类型前缀之间：`char* name` → `char* m_psName`，`char** names` → `char** g_ppsNames`
- 成员函数和自由函数：`GetSize` → `getSize`
- 无类型映射的变量：输出 note，提醒补全项目配置

局部变量、构造/析构函数、运算符、系统头文件和项目根目录以外的声明不会被检查。重复包含的头文件诊断会按文件位置去重。

## 依赖

- Zig 0.16.0
- Ruby 2.6 或更新版本（只使用标准库）
- 支持 `.tar.xz` 的 `tar`（常见 Linux/macOS 默认提供）
- CMake 项目通常用 `-DCMAKE_EXPORT_COMPILE_COMMANDS=on` 生成 compilation database

不要求系统预装 Clang/libclang。项目根目录的 Ruby 构建脚本会下载 LLVM release 预编译包到 `.tools/llvm/`，校验 SHA-256，解压后让 Zig 从这个私有目录查找头文件和 `libclang`：

```sh
ruby build.rb install
ruby build.rb build
```

默认固定 LLVM 18.1.8，支持 Linux x86_64、Linux ARM64 和 macOS Apple Silicon。Linux x86_64 使用 Ubuntu 18.04 构建，最低要求 glibc 2.27，可运行于 glibc 2.28 的 Kylin Linux Advanced Server V10。压缩包约为 0.8–1.0 GiB，下载缓存和解压目录会同时保留，建议预留约 10 GiB 空间。缓存位于 `.tools/downloads/`，下载中断后再次执行会从 `.part` 文件续传。仓库不会修改系统目录，也不需要 `sudo`。运行以下命令可以检查当前环境，且不会触发下载：

```sh
ruby build.rb doctor
```

Linux 上 `doctor` 会显示检测到的内核、glibc 版本及各自最低要求。安装 LLVM 时还会实际运行私有目录中的 `clang --version`；安装离线 Zig 时会实际运行 `zig version`，任一工具存在架构或运行库不兼容都会在编译前终止。

Zig 0.16.0 保持不变。Zig 自带用于编译和 `@cImport` 的 Clang/LLVM 21，不需要在目标机另外安装 Clang 21；外部 LLVM 18.1.8 只提供运行时扫描 C++ AST 的稳定 libclang C API，两者不要求主版本一致。编辑器可以继续使用单独安装的 clangd 22，它也不参与本工具的链接和运行。

Zig 当前官方 Linux 支持基线是内核 5.10，但这不是类似 glibc 符号版本的加载硬门槛。已确认 Zig 0.16.0 可以在目标 Kylin 4.19 内核上启动，因此构建脚本只在 `doctor` 中提示“超出官方支持范围”，不会阻止安装或编译。4.19 环境仍应至少完整执行一次 `ruby build.rb test`：它不仅运行 `zig version`，还会编译、链接并实际运行本工具的单元、端到端和修复安全测试。全部通过即可继续保留 Zig 0.16.0；若实际测试暴露内核相关错误，再考虑降级 Zig。

如果机器已经有可用的 LLVM，也可以跳过下载。这个选项同样适合开发时临时覆盖：

```sh
ruby build.rb build --llvm-prefix /opt/homebrew/opt/llvm@21
# 或：CPP_IDENT_RENAMER_LLVM_PREFIX=/opt/llvm ruby build.rb build
```

VS Code/ZLS 分析 `@cImport` 时也需要同一个构建选项。仓库根目录的 `zls.build.json` 已指向 `.tools/llvm/current`；执行一次 `ruby build.rb install` 后运行 `Zig: Restart ZLS` 即可恢复 `@cImport("clang-c/Index.h")` 的补全。

Ruby 脚本实际执行的命令会逐条打印，便于调试。更多选项（离线缓存、自定义 LLVM 下载地址和强制重装）可运行 `ruby build.rb help` 查看。仍可绕过包装器直接运行 Zig：

```sh
zig build -Dllvm-prefix="$PWD/.tools/llvm/current"
```

清理下载缓存、未完成的下载、Zig 构建缓存、`zig-out/` 和 `dist/`：

```sh
ruby build.rb clean
```

默认保留已经安装在 `.tools/llvm/` 和 `.tools/zig/` 中的本地工具链，避免下次重新解压。需要完全重置时使用：

```sh
ruby build.rb clean --all
```

`--all` 还会删除本地安装的 LLVM、Zig 和离线清单；之后必须重新下载安装，或者从原始离线包重新解包。

## Linux 纯内网部署

在可访问互联网的机器上执行：

```sh
# Linux x86_64；省略目标时也默认使用它
ruby build.rb --pack-offline linux-x64

# Linux ARM64/AArch64
ruby build.rb --pack-offline linux-arm64
```

也可以写成 `ruby build.rb --pack-offline --offline-target linux-arm64`。命令会为指定架构下载并校验 LLVM 18.1.8 和 Zig 0.16.0，然后在 `dist/` 生成对应文件：

```text
cpp-ident-renamer-offline-linux-x64.tar
cpp-ident-renamer-offline-linux-x64.tar.sha256

或：

cpp-ident-renamer-offline-linux-arm64.tar
cpp-ident-renamer-offline-linux-arm64.tar.sha256
```

离线包包含当前项目源码、配置、LLVM 压缩包和 Zig 压缩包。LLVM 和 Zig 本身已经使用 xz 压缩，因此外层使用普通 tar，避免耗费大量时间重复压缩。

把 `.tar` 文件复制到内网机器并解包：

```sh
sha256sum -c cpp-ident-renamer-offline-linux-x64.tar.sha256
tar -xf cpp-ident-renamer-offline-linux-x64.tar
cd cpp-ident-renamer-offline-linux-x64
ruby build.rb build
```

ARM64 包使用同样流程，只需把文件名中的 `linux-x64` 换成 `linux-arm64`。解包后的项目会自动进入离线模式：不再访问网络，先分别验证 LLVM/Zig 的 SHA-256，再安装到 `.tools/` 并使用包内 Zig 编译。内网机器不需要系统 Clang、libclang、Zig、新版 GCC 或 Clang 21；仍需 Ruby 2.6+、支持 xz 的 tar，以及对应的 Linux 架构。Linux x64 还要求 glibc 2.27 或更新版本。低于 Linux 5.10 属于 Zig 官方支持范围之外，但不会被脚本硬性拦截。首次解包和编译建议预留约 12 GiB 空间。

## 使用

复制并编辑示例配置：

```sh
cp cpp-ident-renamer.toml.example cpp-ident-renamer.toml
ruby build.rb run -- check -p build
```

先扫描并检查 `idents.tsv`，删除暂时不希望修改的行，再自动修复并验证：

```sh
ruby build.rb run -- check -p build
# 审核项目根目录的 idents.tsv
ruby build.rb run -- check -p build --fix
# -f 是 --fix 的短选项
```

`-p` 既可指向目录，也可直接指向 `compile_commands.json`。默认只报告当前目录下的项目文件；可用 `--root` 指定其他项目根目录。

不带 `--fix` 时，工具每次都会运行完整扫描，并原子覆盖 `<root>/idents.tsv`。它是标准的 Tab 分隔文本文件，可以直接用支持 TSV 的编辑器或表格工具查看。文件每行是一项可修复问题，格式为：

```text
<SHA-256 标记>    <variable|function>    <旧名称>    <建议名称>    <文件>:<行>:<列>
```

首字段是修复授权使用的稳定标记，后面的字段用于人工检查。可以直接删除整行来排除某项；空行、注释行和格式无效的行会被忽略。无类型映射的 note 不可自动修复，因此不会写入 `idents.tsv`。

带 `--fix` 时仍会先运行完整扫描，但不会创建、覆盖或补写 `idents.tsv`，只会修复当前文件中仍与扫描结果匹配的标记。文件不存在、为空，或者里面没有仍有效的标记时，命令退化为普通扫描：不修改源码，也不写 `idents.tsv`；若仍有命名问题，退出码仍为 `1`。这样可以把“扫描 → 审核清单 → 精确修复”拆成两个明确步骤。

文本输出适合人和编译器诊断面板：

```text
src/processor.cpp:8:9: warning: variable 'numberOfSlice' should be named 'm_nNumberOfSlice' (type: int) [cpp-ident-renamer-variable]
```

机器读取可使用 JSON：

```sh
zig-out/bin/cpp-ident-renamer check -p build --format json
```

退出码为 `0` 表示命名通过或修复验证成功，`1` 表示存在命名问题，`2` 表示有编译单元无法解析，`3` 表示修复因安全检查被拒绝或验证失败后已经回滚，`4` 表示验证和回滚同时失败、需要人工检查。无映射类型本身不导致失败。

`--fix` 使用声明的 USR 收集已授权标识符的声明、定义和语义引用，不进行全局字符串替换。写入前会验证每个字节位置仍与旧名称匹配；宏展开、项目根目录外引用、位置冲突和初始 Clang 错误都会让整次修复在写盘前终止。写入后会重新解析 compilation database 中的全部翻译单元，并确认没有解析错误且已授权的问题不再存在，否则恢复所有被修改文件。未写入 `idents.tsv` 的命名问题允许保留，供以后分批处理。

验证范围是当前 `compile_commands.json` 覆盖的翻译单元。它不能证明仓库外部调用方的 ABI、未进入 compilation database 的源码或最终链接步骤仍然正确；公开 API 重命名后仍应运行项目自己的完整构建与测试。

运行测试：

```sh
ruby build.rb test
```

## 配置

```toml
use_canonical_type = true

[scope]
member = "m_"
static_member = "m_"
global = "g_"

[functions]
member = "camel"    # camel / snake / unchanged
free = "camel"

[pointers]
marker = "p"
char = "s"          # char* -> ps, char** -> pps

[types]
int = "n"
"std::string" = "s"
"std::vector" = "vec"  # 同时匹配 std::vector<...>
"project::Request" = "req"
```

`use_canonical_type = true` 会穿透 typedef/using；设为 `false` 时可以直接给别名配置前缀。配置中的类型条目会覆盖同名内置映射。

指针规则的组合顺序固定为 `scope + pointer + type + PascalName`。每增加一级指针就增加一个 `marker`；`[pointers]` 中的类型映射优先于 `[types]`，所以普通 `char` 仍可使用 `ch`，而 `char*` 使用字符串前缀 `s`。例如 `int*` 使用普通 `int = "n"` 映射得到 `m_pnCount`。

## 当前边界

当前支持不修改源码的扫描审核流以及事务式 `--fix`。尚未提供独立的 diff 预览模式；宏展开中的引用会保守拒绝自动修改。
