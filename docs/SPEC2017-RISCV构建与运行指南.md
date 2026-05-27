# SPEC CPU2017 RISC-V 构建与运行指南

## 环境要求

| 组件 | 说明 |
|---|---|
| SPEC CPU2017 | 需要许可的 SPEC CPU2017 安装（1.1.9 测试通过） |
| RISC-V 工具链 | `riscv64-unknown-linux-gnu-gcc/g++/gfortran` (GCC 14 测试通过) |
| 性能统计工具 | RISC-V 静态链接的 `perf.riscv`（基于 ptrace） |

### 环境变量

```bash
export SPEC_DIR=<spec2017安装目录>       # 如 /opt/cpu2017
export RISCV=<riscv工具链目录>            # 不带 /bin，riscv.cfg 会自动追加
```

示例：
```bash
export SPEC_DIR=/opt/cpu2017
export RISCV=/opt/riscv-toolchain
```

**注意：** `RISCV` 不要带 `/bin` 后缀，`riscv.cfg` 会自动追加 `/bin/`。

## 构建

### 命令

```bash
./gen_binaries.sh --compile [--suite <套件>] [--input <输入集>]
./gen_binaries.sh --genCommands [--suite <套件>] [--input <输入集>]
```

| 参数 | 可选值 | 默认值 | 说明 |
|---|---|---|---|
| `--suite` | intspeed, intrate, fpspeed, fprate | intspeed | 基准测试套件 |
| `--input` | test, train, ref | ref | 输入数据集规模 |
| `--compile` | — | — | 编译 + 打包 |
| `--genCommands` | — | — | 生成 `.cmd` 命令文件 |

### 构建流程（单次 `--compile` 内部做的事）

1. **复制配置文件** — 将 `riscv.cfg` 和 `host.cfg` 拷贝到 `$SPEC_DIR/config/`
2. **RISC-V target build** — 调用 `runcpu --config riscv --action build`，用交叉编译器生成 RISC-V 二进制，产物在 `$SPEC_DIR/benchspec/CPU/<benchmark>/exe/`
3. **Host build + 输入生成** — 调用 `runcpu --config host --action runsetup`，用主机编译器编译并**执行**输入生成程序（生成几 GB 的输入数据），产物在 `$SPEC_DIR/benchspec/CPU/<benchmark>/run/`
4. **打包 overlay** — 遍历 `commands/<suite>/` 下的 `.cmd` 文件，对每个 benchmark：
   - 拷贝 host run 目录中的输入文件
   - 拷贝 RISC-V 二进制替换主机二进制
   - 生成 `run.sh` 和 `run_workloadN.sh`
   - 若 RISC-V 二进制或 host run 目录不存在则跳过（打印 WARNING）
5. **复制套件脚本** — 将 `spec17-run-scripts/<suite>.sh` 和 `run_perf.sh` 复制到 overlay

### 一次性构建全部 4 个套件 × 3 种输入

```bash
# 1. int 套件直接构建（已有 test/train/ref 的 cmd 文件）
./gen_binaries.sh --compile --suite intspeed --input test
./gen_binaries.sh --compile --suite intspeed --input train
./gen_binaries.sh --compile --suite intspeed --input ref

./gen_binaries.sh --compile --suite intrate --input test
./gen_binaries.sh --compile --suite intrate --input train
./gen_binaries.sh --compile --suite intrate --input ref

# 2. fp 套件：先生成 train 的 cmd 文件，再构建
# 仓库里可能已经存在这些cmd文件，按照需求决定是否重建
./gen_binaries.sh --genCommands --suite fpspeed --input train
./gen_binaries.sh --genCommands --suite fprate --input train

./gen_binaries.sh --compile --suite fpspeed --input test
./gen_binaries.sh --compile --suite fpspeed --input train
./gen_binaries.sh --compile --suite fpspeed --input ref

./gen_binaries.sh --compile --suite fprate --input test
./gen_binaries.sh --compile --suite fprate --input train
./gen_binaries.sh --compile --suite fprate --input ref
```

### 构建耗时估算

| 套件 | C/C++ (~10个) | Fortran (~10-13个) |
|---|---|---|
| intspeed / intrate | ~8 分钟 | — |
| fpspeed / fprate | — | ~30-35 分钟 |

- `test` 和 `train` 的编译时间与 `ref` 基本一致（因为 benchmark 数量相同，编译产物不复用）
- 全部 12 个组合（4 套件 × 3 输入，fp 套件无 train 时为 10 组合）总计约 **2-3 小时**

### 构建后覆盖情况

| 套件 | test | train | ref |
|---|---|---|---|
| intspeed | 10 | 10 | 10 |
| intrate | 10 | 10 | 10 |
| fpspeed | 10 | 需 `--genCommands` 后构建 | 10 |
| fprate | 13 | 需 `--genCommands` 后构建 | 13 |

### 修复的问题

构建过程中修复了以下兼容性问题：

#### 1. host.cfg — SPEC 宏语法错误

**文件：** `host.cfg` 第 115 行

```
- %   define  gcc_dir        %{/usr/}
+ %   define  gcc_dir        /usr
```

`%{/usr/}` 被 SPEC 预处理器当作未定义宏引用，导致 host build 报警告。

#### 2. host.cfg — 602.gcc_s / 502.gcc_r 与新 glibc 不兼容

**文件：** `host.cfg`，在 500.perlbench_r 的 portability 块之前新增

```
+ 502.gcc_r,602.gcc_s:  #lang='C'
+    EXTRA_CFLAGS = -fgnu89-inline -U_FORTIFY_SOURCE
```

GCC 5.x 源码在新 glibc 的 `fcntl2.h` 中误用 `__builtin_va_arg_pack_len()`，`-fgnu89-inline` 恢复旧式 inline 语义解决。

#### 3. host.cfg + riscv.cfg — gfortran 类型检查过严

**文件：** `host.cfg` 和 `riscv.cfg` 中以下 benchmark 的 `FPORTABILITY` 行

| Benchmark | 修改 |
|---|---|
| `521.wrf_r,621.wrf_s` | `FPORTABILITY` 追加 `-fallow-argument-mismatch` |
| `527.cam4_r,627.cam4_s` | 新增 `FPORTABILITY = -fallow-argument-mismatch` |
| `628.pop2_s` | `FPORTABILITY` 追加 `-fallow-argument-mismatch` |

gfortran 10+ 对过程参数类型匹配检查更严格，旧 Fortran 代码（REAL/COMPLEX 混传、INTEGER/LOGICAL 混传）编译失败。

#### 4. riscv.cfg — 627.cam4_s C 代码 implicit int 错误

**文件：** `riscv.cfg`，`527.cam4_r,627.cam4_s` 块

```
+    EXTRA_CFLAGS  = -std=gnu89
```

RISC-V GCC 14 将 `-Wimplicit-int` 升级为错误，cam4_s 的 MPI stub 代码（`mpi.c`）中有函数未声明返回类型。`-std=gnu89` 恢复旧标准允许 implicit int。

#### 5. gen_binaries.sh — 构建失败时中断整体流程

**文件：** `gen_binaries.sh`，benchmark 遍历循环内

- host run 目录不存在时 `continue` 跳过（原来 `find` 失败 + `set -e` 直接退出脚本）
- target 二进制未生成时 `continue` 跳过
- suite runner 脚本（`spec17-run-scripts/*.sh`）不存在时不再中止

## 构建结果

```
build/overlay/
├── run_perf.sh                    # 性能统计包装脚本
├── intspeed/ref/                  # 10 benchmarks
├── fpspeed/ref/                   # 10 benchmarks
├── intrate/ref/                   # 10 benchmarks
└── fprate/ref/                    # 13 benchmarks
```

每个 benchmark 目录包含：

```
600.perlbench_s/
├── perlbench_s_base.riscv-64      # RISC-V 静态链接二进制
├── run.sh                         # 运行所有 workload
├── run_workload0.sh               # 单个 workload
├── run_workload1.sh
└── <输入文件...>                   # 从 host build 拷贝的输入数据
```

总计 **43 个 benchmark**（C/C++ 和 Fortran）：

| 套件 | 类型 | 数量 |
|---|---|---|
| intspeed | Integer Speed (6xx_s) | 10 |
| intrate | Integer Rate (5xx_r) | 10 |
| fpspeed | FP Speed (6xx_s) | 10 |
| fprate | FP Rate (5xx_r) | 13 |

## 在 FPGA 软核上运行

### 1. 部署

将以下内容拷贝到 FPGA 系统的文件系统中（NFS / SCP / SD 卡）：

```bash
# overlay 目录（包含所有 benchmark 和脚本）
scp -r build/overlay/ root@<fpga-ip>:/data/spec17/

# perf 工具及参数文件
scp <path-to-perf>/perf.riscv root@<fpga-ip>:/data/spec17/
scp <path-to-perf>/samplectrl.txt root@<fpga-ip>:/data/spec17/
```

### 2. 配置采样参数

编辑 `samplectrl.txt`：

```ini
eventsel: 0          # 采样事件类型
maxevent: 200000000  # 事件间隔（指令数）
warmupinst: 0        # 预热指令数
maxperiod: 2000      # 最大采样次数
logname: counter.log # 日志文件名
```

### 3. 直接运行（无性能统计）

```bash
cd /data/spec17/intspeed/ref/600.perlbench_s
./run.sh                    # 运行所有 workload
./run_workload0.sh          # 只运行 workload 0
```

### 4. 使用 perf.riscv 采集性能数据

`perf.riscv` 通过 `fork + execv + ptrace` 追踪被测程序，利用硬件计数器采集 IPC、各类微架构事件等数据。

**命令格式：**
```
./perf.riscv samplectrl.txt program_path program_name [args...]
```

**手动执行：**
```bash
cd /data/spec17/intspeed/ref/600.perlbench_s
/data/spec17/perf.riscv /data/spec17/samplectrl.txt \
    ./perlbench_s_base.riscv-64 \
    perlbench_s_base.riscv-64 \
    -I./lib checkspam.pl 2500 5 25 11 150 1 1 1 1
```

**使用 run_perf.sh 自动化（推荐）：**

```bash
cd /data/spec17

# 单个 benchmark
./run_perf.sh --suite intspeed --input ref 600.perlbench_s

# 单个 workload
./run_perf.sh --suite intspeed --input ref 600.perlbench_s --workload 0

# 多个套件
./run_perf.sh --all --suite intspeed --suite fpspeed --input ref

# 全部 4 个套件
./run_perf.sh --all --suite all --input ref

# 不指定 --suite 时，--all 自动扫描所有可用套件
./run_perf.sh --all --input test

# 跨套件、跨输入集（不同输入集需分开调用）
./run_perf.sh --all --suite intspeed --input test
./run_perf.sh --all --suite intspeed --input train

# 指定 perf 路径
./run_perf.sh --perf /opt/perf.riscv --params /opt/samplectrl.txt \
    --all --suite intspeed --input ref

# 自定义输出目录
./run_perf.sh --output /data/results/intrate \
    --all --suite intrate --input ref
```

输出日志：`perf_logs/{benchmark}_w{N}_counter.log`

### 5. 输出日志格式

每个日志文件包含 JSON 格式的性能数据：

```json
{"type": "max_inst", "times": 0, "cycles": 12345678, "inst": 10000000}
{"type": "event  0", "value": 5000}
{"type": "event  1", "value": 3000}
...
{"type": "event 127", "value": 0}
```

- `times`：采样序号
- `cycles`：自上次采样以来的周期数
- `inst`：自上次采样以来的指令数
- `event N`：128 个硬件计数器的值

通过这些数据可以计算出 IPC（inst/cycles）、分支预测准确率、缓存命中率等微架构指标。

## 文件说明

| 文件 | 用途 |
|---|---|
| `gen_binaries.sh` | 主构建脚本 |
| `riscv.cfg` | RISC-V 交叉编译配置 |
| `host.cfg` | x86 主机编译配置 |
| `run_perf.sh` | perf.riscv 自动化包装 |
| `commands/` | 各 benchmark 的运行参数（.cmd） |
| `spec17-run-scripts/` | 套件级运行脚本 |
