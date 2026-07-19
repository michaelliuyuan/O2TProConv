#!/usr/bin/env bash
# 模块3（compare）：Oracle vs TiDB 性能 + 结果一致性对比。
#
# 状态（对齐设计文档里程碑）：
#   ✅ 已就绪：
#     - 用例格式契约 docs/compare-case-contract.md
#     - compare --validate-cases：① 格式校验 ② 覆盖一致性校验（test-cases.md ↔ *.cases，防双源漂移）
#   ⏳ 待 gated（决策② TiDB 目标版本 + 目标库连接）：
#     - 两端调用 + 归一化 + 值级 diff + perf 计时(p50/p99) + 报告（设计文档 §4.3/§6）
set -euo pipefail

run_compare() {
  local sub="${1:-}"
  case "$sub" in
    --validate-cases) shift || true; validate_cases "$@" ;;
    "") die "compare 待 M3（gated 决策② TiDB 版本+连接）。离线可先校验用例：ora2tidb compare --validate-cases <cases 目录> [--spec test-cases.md]" ;;
    *)  die "未知 compare 子参数: $sub" ;;
  esac
}

# 离线校验：① cases/*.cases 格式；② 与 test-cases.md 的覆盖一致性（防双源漂移）。不连库。
# 用法: validate_cases <cases 目录> [--spec <test-cases.md>]
validate_cases() {
  local dir="" spec=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --spec) spec="${2:-}"; [[ -n "$spec" ]] || die "--spec 缺少参数"; shift 2 ;;
      -*)     die "未知参数: $1" ;;
      *)      dir="$1"; shift ;;
    esac
  done
  [[ -n "$dir" ]] || dir="${CASES_DIR:-}"
  [[ -n "$dir" ]] || die "用法: ora2tidb compare --validate-cases <cases 目录> [--spec test-cases.md]"
  [[ -d "$dir" ]] || die "用例目录不存在: $dir"
  require_cmd awk

  # ---- ① 格式校验（逐 .cases 文件）----
  shopt -s nullglob
  local f
  for f in "$dir"/*.cases; do
    echo "▸ $(basename "$f")"
    awk '
      BEGIN { caps = " out_param inout function result_set " }
      function flush(   e) {
        if (id == "") return
        n_cases++
        e = ""
        if (id == "" || sp == "" || capture == "")           e = e " 缺 id/sp/capture"
        else if (index(caps, " " capture " ") == 0)          e = e " capture非法:" capture
        if (n_out == 0 && capture != "result_set")           e = e " 无out期望"
        if (capture == "result_set" && n_out == 0 && n_res == 0) e = e " 无结果集期望"
        if (e != "") { n_err++; printf "    ❌ %s [%s/%s]%s\n", id, sp, capture, e }
        else          { printf "    ✅ %s [%s/%s] out=%d\n", id, sp, capture, n_out }
        id = sp = capture = ""; n_out = 0; n_res = 0
      }
      function gkey(s, k,   re) { re = k "=([^ \t]*)"; if (match(s, re)) return substr(s, RSTART+length(k)+1, RLENGTH-length(k)-1); return "" }
      /^@@case[ \t]/ { flush(); line = $0; sub(/^@@case[ \t]+/, "", line);
                       id = gkey(line, "id"); sp = gkey(line, "sp"); capture = gkey(line, "capture"); next }
      /^[ \t]*#/      { next }
      /^[ \t]*$/      { next }
      /^[ \t]*in[ \t]/   { next }
      /^[ \t]*out[ \t]/  { n_out++; next }
      /^[ \t]*(result|result_file)[ \t]/ { n_res++; next }
      /^[ \t]*(norm|perf)[ \t]/ { next }
      /^[ \t]*(call_oracle|call_tidb|fetch_oracle|fetch_tidb)[ \t]/ { next }
      { printf "    ⚠ 无法识别的行: %s\n", $0 }
      END { flush(); if (n_cases) printf "    → %d 用例，%d 错误\n", n_cases, n_err }
    ' "$f"
  done
  shopt -u nullglob

  # ---- ② 覆盖一致性：test-cases.md ↔ *.cases（防双源漂移）----
  [[ -n "$spec" ]] || spec="$dir/test-cases.md"
  if [[ ! -f "$spec" ]]; then
    echo; info "未找到规格文件（$spec），跳过覆盖校验；可用 --spec <path> 指定。"
    return 0
  fi
  echo; echo "== 覆盖一致性（$(basename "$spec") ↔ *.cases）=="
  echo "  仅校验可运行用例组 TC-T1/T2；T3 为 convert-TODO 断言，由转换置信度报告覆盖，不在此列。"

  local tmp; tmp="$(mktemp -d)"
  # 汇集 .cases 的 section-id 前缀（去尾部字母）与 sp（来自 @@case 头）
  awk '
    /@@case[ \t]/ {
      if (match($0, /id=[^ \t]+/)) { id = substr($0, RSTART+3, RLENGTH-3); sub(/[a-z]+$/, "", id); print "I\t" id }
      if (match($0, /sp=[^ \t]+/)) { sp = substr($0, RSTART+3, RLENGTH-3); print "S\t" sp }
    }
  ' "$dir"/*.cases > "$tmp/cases.set"
  grep '^I' "$tmp/cases.set" | cut -f2 | sort -u > "$tmp/case_ids"
  grep '^S' "$tmp/cases.set" | cut -f2 | sort -u > "$tmp/case_sps"

  # 从规格抽 T1/T2 用例组 id 与 对象名（T3 不纳入 compare 覆盖）。
  # 对象名只取 T1/T2 章节标题行里的 sp_*/fn_* token，避免误纳 T3 SP / 漏 fn_。
  grep -hoE 'TC-T[12]-[0-9]+' "$spec" | sort -u > "$tmp/spec_ids"
  awk '
    /^### TC-T[12]-[0-9]+/ {
      for (i = 1; i <= NF; i++) if ($i ~ /^(sp|fn)_[a-z0-9_]+/) { sub(/[（(].*/, "", $i); print $i }
    }
  ' "$spec" | sort -u > "$tmp/spec_sps"

  local only_spec_ids only_case_ids only_spec_sps only_case_sps
  only_spec_ids=$(comm -23 "$tmp/spec_ids" "$tmp/case_ids" || true)
  only_case_ids=$(comm -13 "$tmp/spec_ids" "$tmp/case_ids" || true)
  only_spec_sps=$(comm -23 "$tmp/spec_sps" "$tmp/case_sps" || true)
  only_case_sps=$(comm -13 "$tmp/spec_sps" "$tmp/case_sps" || true)

  echo "  [用例组] 规格有/用例无（漏跑风险）：${only_spec_ids:-✅ 无}"
  echo "  [用例组] 用例有/规格无（未评审风险）：${only_case_ids:-✅ 无}"
  echo "  [SP]    规格有/用例无（漏跑风险）：${only_spec_sps:-✅ 无}"
  echo "  [SP]    用例有/规格无（未评审风险）：${only_case_sps:-✅ 无}"
  echo "  各用例组 .cases 子例数（对规格表逐行核对）："
  grep '^I' "$tmp/cases.set" | cut -f2 | sort | uniq -c | awk '{printf "    %s × %s\n", $2, $1}'

  rm -rf "$tmp"
  info "用例校验完成（格式 + 覆盖）: $dir"
}
