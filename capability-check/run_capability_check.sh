#!/usr/bin/env bash
# run_capability_check.sh —— TiDB 存储过程能力探针运行器（M1 硬前置）。
# 对目标 TiDB 逐个 CREATE+CALL 各探针 SP，汇总能力矩阵，回答关键构造支持度：
#   DECLARE 顺序(变量/条件→游标→handler)、显式游标、动态 SQL(PREPARE/EXECUTE)、
#   存储函数、转换后内置等价物、裸 := 赋值。
# 用法: ./capability-check/run_capability_check.sh -c config/config.conf
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$ROOT_DIR/lib"
# shellcheck source=../lib/common.sh
source "$LIB_DIR/common.sh"
# common.sh 开了 set -e（errexit）——会让失败的探针 mysql_tidb 直接终止运行器，
# rc 抓不到、后续探针与合计行全部丢失（@测试 fail 清单：06_bare_assign 失败即 abort）。
# 本运行器逐探针判 rc 自管错误，关掉 errexit（保留 -u / pipefail）。
set +e

main() {
  local cfg=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -c|--config) cfg="${2:-}"; [[ -n "$cfg" ]] || die "-c 缺少参数"; shift 2 ;;
      *) die "未知参数: $1" ;;
    esac
  done
  [[ -n "$cfg" ]] || cfg="$ROOT_DIR/config/config.conf"
  load_config "$cfg"
  require_cmd mysql
  resolve_dir REPORT_DIR
  mkdir -p "$REPORT_DIR"

  local report="$REPORT_DIR/capability_report.md"
  {
    echo "# TiDB 存储过程能力探针报告"
    echo
    echo "- 目标 TiDB: \`$TIDB_USER@$TIDB_HOST:$TIDB_PORT/$TIDB_DB\`"
    echo "- 探针目录: \`$SCRIPT_DIR\`"
    echo
    echo "| 探针 | 结果 | 错误摘要 |"
    echo "|------|------|----------|"
  } >"$report"

  shopt -s nullglob
  local f name rc tmperr err status note pass=0 fail=0
  for f in "$SCRIPT_DIR"/*.sql; do
    name="$(basename "$f" .sql)"
    tmperr="$(mktemp)"
    mysql_tidb --default-character-set=utf8mb4 <"$f" >/dev/null 2>"$tmperr"
    rc=$?
    err="$(<"$tmperr")"; rm -f "$tmperr"
    if [[ $rc -eq 0 && -z "$err" ]]; then
      status="✅ 通过"; note=""; pass=$((pass+1))
    else
      status="❌ 失败"; fail=$((fail+1))
      note="$(printf '%s' "$err" | grep -m1 -iE 'error|denied|not exist|unsupported' | sed 's/|/\\|/g')"
      [[ -n "$note" ]] || note="(见运行输出)"
    fi
    printf '| %s | %s | %s |\n' "$name" "$status" "$note" >>"$report"
    printf '%-26s %s  %s\n' "$name" "$status" "$note"
  done
  shopt -u nullglob

  { echo; echo "**合计**：通过 $pass，失败 $fail。失败的构造即转换落点需人工/替代方案。"; } >>"$report"
  info "能力探针完成：通过 $pass / 失败 $fail；报告 $report"
}

main "$@"
