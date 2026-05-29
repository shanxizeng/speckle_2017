#!/bin/bash

# run_perf.sh — 使用 perf.riscv 运行 SPEC benchmark 并采集性能数据
#
# 用法:
#   ./run_perf.sh [options] <benchmark-name>
#   ./run_perf.sh [options] --all
#
# 选项:
#   --perf <path>        perf.riscv 的路径 (默认: ./perf.riscv)
#   --params <path>      samplectrl.txt 的路径 (默认: ./samplectrl.txt)
#   --output <dir>       输出目录 (默认: ./perf_logs)
#   --workload <N>       只运行第 N 个 workload (默认: 全部)
#   --all                运行所选套件下所有 benchmark
#   --suite <type>       套件: intspeed | intrate | fpspeed | fprate | all
#                        可多次指定: --suite intspeed --suite fpspeed
#   --input <type>       输入集: test | train | ref (默认: ref)

set -e

# 默认值
PERF="${PWD}/perf.riscv"
PARAMS="${PWD}/samplectrl.txt"
OUTPUT_DIR="${PWD}/perf_logs"
WORKLOAD_NUM=""
BENCHMARK=""
ALL_MODE=false
SUITE_TYPES=()
INPUT_TYPE="ref"

ALL_SUITES=(intspeed intrate fpspeed fprate)

function usage {
    echo "usage: run_perf.sh [options] <benchmark-name>"
    echo "       run_perf.sh [options] --all [--suite <type> ...] [--input <type>]"
    echo ""
    echo "   --perf <path>        perf.riscv 路径 (默认: ./perf.riscv)"
    echo "   --params <path>      samplectrl.txt 路径 (默认: ./samplectrl.txt)"
    echo "   --output <dir>       输出目录 (默认: ./perf_logs)"
    echo "   --workload <N>       只运行第 N 个 workload (默认: 全部)"
    echo "   --all                运行所选套件下所有 benchmark"
    echo "   --suite <type>       套件: intspeed | intrate | fpspeed | fprate | all"
    echo "                        可多次指定: --suite intspeed --suite fpspeed"
    echo "   --input <type>       输入集: test | train | ref (默认: ref)"
}

while test $# -gt 0; do
    case "$1" in
        --perf)
            shift; PERF="$1" ;;
        --params)
            shift; PARAMS="$1" ;;
        --output)
            shift; OUTPUT_DIR="$1" ;;
        --workload)
            shift; WORKLOAD_NUM="$1" ;;
        --all)
            ALL_MODE=true ;;
        --suite)
            shift
            if [ "$1" = "all" ]; then
                SUITE_TYPES=("${ALL_SUITES[@]}")
            else
                SUITE_TYPES+=("$1")
            fi ;;
        --input)
            shift; INPUT_TYPE="$1" ;;
        -h | -H | --help)
            usage; exit 0 ;;
        --*)
            echo "ERROR: bad option $1"; usage; exit 1 ;;
        *)
            if [ -z "$BENCHMARK" ]; then
                BENCHMARK="$1"
            else
                echo "ERROR: unexpected argument $1"; usage; exit 1
            fi ;;
    esac
    shift
done

# 检查 perf.riscv 和参数文件
if [ ! -x "$PERF" ]; then
    echo "ERROR: perf.riscv not found or not executable: $PERF"
    exit 1
fi
if [ ! -f "$PARAMS" ]; then
    echo "ERROR: params file not found: $PARAMS"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

# 从 logname 参数提取日志基名
LOGBASE=$(grep -E "^logname:" "$PARAMS" | awk '{print $2}' | sed 's/\.log$//')
if [ -z "$LOGBASE" ]; then
    LOGBASE="counter"
fi

function find_benchmarks_in_dir {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        return
    fi
    for d in "$dir"/*/; do
        [ -d "$d" ] && basename "$d"
    done
}

function run_workload {
    local bmark_dir="$1"
    local workload_file="$2"
    local workload_idx="$3"

    # 解析 workload 脚本: 第3行格式为 "./binary_name args..."
    local cmd=$(sed -n '3p' "$workload_file")
    if [ -z "$cmd" ]; then
        echo "WARNING: empty command in $workload_file, skipping"
        return
    fi

    # 去掉开头的 "./" 提取 binary_name
    local full_cmd="${cmd#./}"
    local bin_name=$(echo "$full_cmd" | awk '{print $1}')
    local args=$(echo "$full_cmd" | cut -d' ' -f2-)

    if [ ! -f "${bmark_dir}/${bin_name}" ]; then
        echo "ERROR: binary not found: ${bmark_dir}/${bin_name}"
        return 1
    fi

    local bmark_name=$(basename "$bmark_dir")
    local log_file="${OUTPUT_DIR}/${bmark_name}_w${workload_idx}_${LOGBASE}.log"

    echo "  [${bmark_name}] workload ${workload_idx}: ${bin_name} $(echo "$args" | cut -c1-60)..."

    # 构建新的 samplectrl 参数文件，修改 logname
    local tmp_params="${OUTPUT_DIR}/.tmp_samplectrl_$$.txt"
    sed "s/^logname:.*/logname: ${log_file}/" "$PARAMS" > "$tmp_params"

    (
        cd "$bmark_dir" || exit 1
        "$PERF" "$tmp_params" "./${bin_name}" "${bin_name}" $args
    )
    local rc=$?

    rm -f "$tmp_params"

    if [ $rc -ne 0 ]; then
        echo "  WARNING: perf.riscv exited with code $rc"
    fi
}

function run_benchmark {
    local bmark_dir="$1"

    if [ ! -d "$bmark_dir" ]; then
        echo "ERROR: benchmark directory not found: $bmark_dir"
        return 1
    fi

    echo "=== Benchmark: $(basename "$bmark_dir") ==="

    if [ -n "$WORKLOAD_NUM" ]; then
        local wf="${bmark_dir}/run_workload${WORKLOAD_NUM}.sh"
        if [ -f "$wf" ]; then
            run_workload "$bmark_dir" "$wf" "$WORKLOAD_NUM"
        else
            echo "ERROR: $wf not found"
            return 1
        fi
    else
        local count=0
        for wf in "${bmark_dir}"/run_workload*.sh; do
            if [ -f "$wf" ]; then
                local widx=$(echo "$wf" | grep -oE 'workload[0-9]+' | grep -oE '[0-9]+')
                run_workload "$bmark_dir" "$wf" "$widx"
                count=$((count + 1))
            fi
        done
        if [ $count -eq 0 ]; then
            echo "WARNING: no run_workload*.sh files found in $bmark_dir"
        fi
    fi
}

# 主逻辑
echo "== run_perf =="
echo "  perf    : $PERF"
echo "  params  : $PARAMS"
echo "  output  : $OUTPUT_DIR"
echo "  suites  : ${SUITE_TYPES[*]:-(auto)}"
echo "  input   : $INPUT_TYPE"
echo ""

total=0

if [ "$ALL_MODE" = true ]; then
    # --all 模式: 遍历所选套件
    if [ ${#SUITE_TYPES[@]} -eq 0 ]; then
        # 未指定 --suite，扫描所有可用套件
        for s in "${ALL_SUITES[@]}"; do
            if [ -d "${s}/${INPUT_TYPE}" ]; then
                SUITE_TYPES+=("$s")
            fi
        done
    fi

    for suite in "${SUITE_TYPES[@]}"; do
        dir="${suite}/${INPUT_TYPE}"
        if [ ! -d "$dir" ]; then
            echo "WARNING: suite directory not found: $dir, skipping"
            continue
        fi
        echo "### Suite: ${suite}/${INPUT_TYPE} ###"
        benchmarks=$(find_benchmarks_in_dir "$dir")
        for b in $benchmarks; do
            run_benchmark "${dir}/${b}"
            echo ""
            total=$((total + 1))
        done
    done
else
    # 单 benchmark 模式
    if [ -z "$BENCHMARK" ]; then
        echo "ERROR: specify a benchmark name or --all"
        usage; exit 1
    fi

    if [ ${#SUITE_TYPES[@]} -eq 0 ]; then
        # 未指定套件，尝试在常见位置查找
        found=false
        for s in "${ALL_SUITES[@]}"; do
            dir="${s}/${INPUT_TYPE}"
            if [ -d "${dir}/${BENCHMARK}" ]; then
                run_benchmark "${dir}/${BENCHMARK}"
                found=true
                total=1
                break
            fi
        done
        if [ "$found" = false ]; then
            # 尝试当前目录
            if [ -d "$BENCHMARK" ]; then
                run_benchmark "$BENCHMARK"
                total=1
            else
                echo "ERROR: benchmark '$BENCHMARK' not found"
                echo "  Use --suite <type> --input <type> or run from overlay root"
                exit 1
            fi
        fi
    else
        for suite in "${SUITE_TYPES[@]}"; do
            dir="${suite}/${INPUT_TYPE}"
            if [ -d "${dir}/${BENCHMARK}" ]; then
                run_benchmark "${dir}/${BENCHMARK}"
                total=1
            else
                echo "WARNING: ${dir}/${BENCHMARK} not found, skipping"
            fi
        done
    fi
fi

echo "Done! Ran $total benchmarks. Logs in: $OUTPUT_DIR"
