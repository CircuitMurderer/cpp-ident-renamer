# ident-mod

基于 Zig 和 libclang 的 C++ 标识符检查与安全重构工具。

## 安装

联网构建要求 Ruby 2.6+、Zig 0.16.0 和 `tar`。LLVM 18.1.8 会安装到项目自己的 `.tools/`，不修改系统目录。

```sh
git clone git@github.com:CircuitMurderer/ident-mod.git
cd ident-mod

ruby build.rb doctor
ruby build.rb build
./zig-out/bin/ident-mod --help
```

已有 LLVM：

```sh
ruby build.rb build --llvm-prefix /opt/llvm
IDENT_MOD_LLVM_PREFIX=/opt/llvm ruby build.rb build
```

Linux 纯内网部署：

```sh
# 联网机器：选择目标平台，包内同时包含 Zig 和 LLVM
ruby build.rb --pack-offline linux-x64
ruby build.rb --pack-offline linux-arm64

# 把 dist/ident-mod-offline-linux-x64.tar{,.sha256} 复制到内网机器
sha256sum -c ident-mod-offline-linux-x64.tar.sha256
tar -xf ident-mod-offline-linux-x64.tar
cd ident-mod-offline-linux-x64
ruby build.rb build
```

Linux x86_64 最低要求 glibc 2.27；Kylin V10 的 glibc 2.28 可用。

## 使用

生成 compilation database：

```sh
cd /path/to/workdir
cmake -S . -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
```

扫描实际项目：

```sh
cd /path/to/workdir

/path/to/ident-mod/zig-out/bin/ident-mod check \
  -p build \
  -c /path/to/workdir/ident-mod.toml \
  --root .
```

输出文件位于 `--root`：

```text
idents.tsv             可修复的命名标记
clang_problems.json    普通扫描时生成；按 -Wxxx 分组 Clang warning/error
```

审核并修复：

```sh
# 扫描并生成 idents.tsv
ident-mod check -p build --root .

# 删除 idents.tsv 中暂时不想修改的行，然后只修复保留的标记
ident-mod check -p build --root . --fix
ident-mod check -p build --root . -f
```

`--fix` 仍会完整扫描。`idents.tsv` 不存在或为空时不会修改源码，也不会重写该文件；修复模式不会创建或覆盖 `clang_problems.json`。

```sh
ident-mod --help
ident-mod check -p build --format json
ident-mod check -p build --no-unmapped
```

## 配置

默认读取当前目录的 `ident-mod.toml`：

```sh
cp ident-mod.toml.example ident-mod.toml
```

```toml
# true：typedef/using 按底层类型匹配；false：可直接配置别名
use_canonical_type = true

[clang]
downgrade_all_warnings = false
downgrade_warnings = ["sign-conversion", "conversion"]

[variables]
case = "pascal"       # pascal / camel / snake

[scan]
local = false         # 普通局部变量
static_local = true   # 静态局部变量
member = true         # 非静态成员变量
static_member = true  # 静态成员变量
global = true         # 全局/命名空间变量
static_global = true  # static 全局变量
functions = true      # 成员函数和自由函数

[scope]
local = ""
static_local = "s_"
member = "m_"
static_member = "s_"
global = "g_"
static_global = "s_"

# 只有顶层 const 全局变量允许 UPPER_SNAKE
[scope_alternatives.const]
global = ["upper_snake"]

# 若不区分 const，改用：
# [scope_alternatives]
# global = ["upper_snake"]

[functions]
member = "camel"  # GetSize -> getSize
free = "pascal"   # calculate_total -> CalculateTotal

[pointers]
marker = "p"
char = "s"        # char* -> ps，char** -> pps

[types]
bool = "b"
char = "ch"
int = "n"
double = "d"
"std::string" = "s"
"std::vector" = "vec"
"project::Request" = "req"
"project::Response" = "rsp"
```

Clang warning 被 `-Werror` 提升时，可以全部或按分组恢复成 warning；真正的语法、类型和头文件错误仍会阻止修复：

```toml
[clang]

# 移除 -Werror，并把 -Werror=xxx 改成 -Wxxx
downgrade_all_warnings = true

# 选择性追加 -Wno-error=xxx；可直接复制 clang_problems.json 中的 -Wxxx
downgrade_warnings = ["sign-conversion", "-Wconversion"]
```

不使用类型前缀时，把变量主体改为小驼峰，并将对应类型映射为空：

```toml
[variables]
case = "camel"

[types]
int = ""
bool = ""
"std::string" = ""
```

代码内置的标准类型输出前缀均为 `""`；匈牙利输出前缀完全由配置文件决定。工具仍能识别常见旧前缀以迁移已有代码，但不会默认生成它们。`variables.case` 使用 `camel` 或 `snake` 时，非空类型前缀会自动补一个缺失的 `_`：

不需要迁移旧匈牙利前缀时可以关闭识别；显式写在 `[types]` 和 `[pointers]` 中的当前前缀不受影响：

```toml
[migration]
legacy_prefixes = false
```

```toml
[variables]
case = "camel"

[types]
int = "n"             # 输出 n_
bool = "b_"           # 输出 b_，不重复添加
double = "d__"        # 输出 d__，保留原配置
"std::string" = ""   # 不使用类型前缀
```

```text
int funcName          -> m_funcName
static int funcName   -> s_funcName
int* funcName         -> m_p_funcName
```

下划线命名使用同一开关：

```toml
[variables]
case = "snake"        # funcName -> m_func_name（int = ""）

[functions]
member = "snake"      # GetSize -> get_size
free = "snake"        # CalculateTotal -> calculate_total
```

命名组合：

```text
作用域前缀 + 每级指针的 p + 类型前缀 + 按 variables.case 格式化的名称

char* funcName             -> psFuncName
static char* funcName      -> s_psFuncName
成员 char* funcName        -> m_psFuncName
全局 char** names          -> g_ppsNames
```

当类型前缀为 `""` 时，`camel` 和 `snake` 会在整段指针标记后自动补一个 `_`；`pascal` 继续使用大写主体作为边界：

```text
pascal + int* funcName -> m_pFuncName
camel  + int* funcName -> m_p_funcName
snake  + int* funcName -> m_p_func_name
snake  + int** names   -> m_pp_names
```

const 判断使用 Clang 类型语义：

```cpp
const int TIME_ESCAPE = 30;       // 顶层 const，可用 UPPER_SNAKE
int TIME_ESCAPE = 30;             // 不合规 -> g_nTimeEscape
const int* POINTER_TO_CONST;      // 指针可变，不是顶层 const
int* const CONST_POINTER = NULL;  // 指针本身 const
```

```text
函数风格：camel | pascal | snake | unchanged
作用域键：local | static_local | member | static_member | global | static_global
```

所有 `[scan]` 开关默认都是 `true`。关闭某项后 Clang 仍解析 AST，但该类标识符不会进入命名分析或 `idents.tsv`。函数参数目前不扫描。
