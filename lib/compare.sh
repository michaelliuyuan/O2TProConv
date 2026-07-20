#!/usr/bin/env bash
# 模块3（compare）：Oracle vs TiDB 性能 + 结果一致性对比。
#
# 状态（对齐设计文档里程碑）：
#   ✅ 已就绪：
#     - 用例格式契约 docs/compare-case-contract.md
#     - compare --validate-cases：① 格式校验 ② 覆盖一致性校验（test-cases.md ↔ *.cases，防双源漂移）
#     - compare --run：两端调用 + 归一化 + 值级 diff + perf 计时(p50/p99) + 报告（设计文档 §4.3/§6）
set -euo pipefail

run_compare() {
  local sub="${1:-}"
  case "$sub" in
    --validate-cases) shift || true; validate_cases "$@" ;;
    --run)            shift || true; run_exec "$@" ;;
    "")               run_exec ;;
    *)  die "未知 compare 子参数: $sub（--validate-cases 离线校验 / --run [-c conf] DB 一致性对比）" ;;
  esac
}

# ===== M3：一致性 + 性能路径（两端 CALL → 归一 → 值级 diff → perf p50/p99 → 报告）=====
# 解析 .cases → TSV（每 case 一行：id \t sp \t capture \t args \t norm \t perf）
#   args 保留 in/out 形参**声明顺序**（位置参数），形如 "in:p_empno=7839;out:p_bonus;out:p_label"
#   out 的期望值不进 args（仅名）；期望值单独取（_parse 同时回填到一个关联查询——Cut 1 简化：out 行 =期望，args 里只记名，期望从 out 行原值取）。
_cmp_parse() {
  awk '
    function kv(line, key,   m) { m=key "=([^ \t]+)"; if (match(line,m)) return substr(line,RSTART+length(key)+1,RLENGTH-length(key)-1); return "" }
    function flush() {
      if (id != "") {
        # 从 args 抽 out 期望（out:name=value → 期望存 out_exp[name]=value，args 留 out:name）
        print id "\t" sp "\t" capture "\t" args "\t" norm "\t" perf "\t" outexp
      }
      id=sp=capture=args=norm=perf=outexp=""
    }
    /^@@case[ \t]/ { flush(); id=kv($0,"id"); sp=kv($0,"sp"); capture=kv($0,"capture"); next }
    /^[ \t]*#/  { next }
    /^[ \t]*$/  { next }
    /^[ \t]*in[ \t]/  { v=$0; sub(/^[ \t]*in[ \t]+/,"",v);
                       n=split(v,ka,/[ \t]+/); for(i=1;i<=n;i++) if(ka[i]!="") args =(args ==""?"":args ";") "in:" ka[i] }
    /^[ \t]*out[ \t]/ { v=$0; sub(/^[ \t]*out[ \t]+/,"",v);
                       nm=v; sub(/=.*$/,"",nm);
                       args =(args ==""?"":args ";") "out:" nm;
                       outexp=(outexp==""?"":outexp ";") v }
    /^[ \t]*norm[ \t]/{ v=$0; sub(/^[ \t]*norm[ \t]+/,"",v); norm=(norm==""?"":norm " ") v }
    /^[ \t]*perf[ \t]/{ v=$0; sub(/^[ \t]*perf[ \t]+/,"",v); perf=(perf==""?"":perf " ") v }
    END { flush() }
  ' "$1"
}

# 展开 <DATE:Oraclefmt> 占位为今日日期（两端同日）
_cmp_expand_date() {
  local v="$1" out=""
  while [[ "$v" == *"<DATE:"*">"* ]]; do
    local pre="${v%%<DATE:*}" fmt="${v#*<DATE:}"; fmt="${fmt%%>*}"; v="${v#*<DATE:$fmt>}"
    local df="$fmt"
    df="${df//YYYY/%Y}"; df="${df//YY/%y}"; df="${df//MM/%m}"; df="${df//DD/%d}"; df="${df//HH24/%H}"; df="${df//MI/%M}"; df="${df//SS/%S}"
    out+="$pre$(date +"$df")"
  done
  printf '%s' "$out$v"
}

# 归一化值（按 norm 选项，空格分隔）。numeric_scale=N 格式化数字为 N 位小数；其余见 contract。
_cmp_norm() {
  local v="$1" opts="$2"
  [[ "$opts" == *null_as=NULL* && -z "$v" ]] && v="NULL"
  if [[ "$opts" == *num_str_strip_zeros* ]]; then
    v="$(printf '%s' "$v" | awk '{ n=$0; if(n~/\./){ sub(/0+$/,"",n); sub(/\.$/,"",n) }; print n }')"
  fi
  if [[ "$opts" == *numeric_scale=* ]]; then
    local ns; ns="$(printf '%s' "$opts" | grep -oE 'numeric_scale=[0-9]+' | head -1 | cut -d= -f2)"
    if [[ -n "$ns" && "$v" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
      v="$(printf '%s' "$v" | awk -v s="$ns" '{ printf "%." s "f", $0 }')"
    fi
  fi
  if [[ "$opts" == *trim* ]]; then v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"; fi
  if [[ "$opts" == *collapse_ws* ]]; then v="$(printf '%s' "$v" | tr -s '[:space:]' ' ')"; fi
  [[ "$opts" == *upper* ]] && v="${v^^}"
  printf '%s' "$v"
}

# 毫秒级计时（兼容 Linux date +%s%3N / macOS perl / Windows）
_cmp_now_ms() {
  if date +%s%3N 2>/dev/null | grep -qE '^[0-9]+$'; then date +%s%3N
  elif command -v perl >/dev/null 2>&1; then perl -MTime::HiRes=time -e 'printf "%.0f", time*1000'
  else
    local s; s="$(date +%s 2>/dev/null || echo 0)"
    printf '%s000' "$s"
  fi
}

# 计算百分位：从空格分隔的数值列表取 p50/p99/p95
_cmp_percentile() {
  local vals="$1" pct="$2"
  printf '%s' "$vals" | tr ' ' '\n' | sort -n | awk -v p="$pct" '
    { a[NR]=$1 }
    END {
      if (NR==0) { print "0"; exit }
      idx = int(NR * p / 100 + 0.5)
      if (idx < 1) idx = 1
      if (idx > NR) idx = NR
      print a[idx]
    }'
}

# 把 actual 的日期值按 Oracle fmt 重格式化（date=<field>:<fmt> 归一，field 在 _cmp_diff 判）
_cmp_norm_date() {
  local v="$1" fmt="$2" df
  df="$fmt"; df="${df//YYYY/%Y}"; df="${df//YY/%y}"; df="${df//MM/%m}"; df="${df//DD/%d}"; df="${df//HH24/%H}"; df="${df//MI/%M}"; df="${df//SS/%S}"
  local parsed; parsed="$(date -d "$v" +"$df" 2>/dev/null || true)"   # date(1) 解析常见日期形态
  [[ -n "$parsed" ]] && printf '%s' "$parsed" || printf '%s' "$v"
}

# 值级 diff：expected（字面/~正则/<DATE>）vs actual。opts 含 norm；field 用于 date=<field>:<fmt> 归一。
_cmp_diff() {
  local expected="$1" actual="$2" opts="$3" field="${4:-}"
  expected="$(_cmp_expand_date "$expected")"
  if [[ "$expected" == "~"* ]]; then
    printf '%s' "$actual" | grep -qE "${expected:1}" && return 0 || return 1
  fi
  # date=<field>:<fmt> 归一：若此 field 命中，重格式化 actual 的日期值（两端同 fmt）
  local dfmt=""
  if [[ -n "$field" && "$opts" == *"date=$field:"* ]]; then
    dfmt="${opts#*"date=$field:"}"; dfmt="${dfmt%%[ ;]*}"
    actual="$(_cmp_norm_date "$actual" "$dfmt")"
  fi
  [[ "$(_cmp_norm "$expected" "$opts")" == "$(_cmp_norm "$actual" "$opts")" ]] && return 0 || return 1
}

# IN 值按类型决定引号：NULL/数字裸传；串/日期加 '...'（启发式：数字外观的串如邮编 '12345' 会误判，
# Cut 1 实用；后续可让 .cases 显式 in:num/in:str）。@架构师 seq16 确认。
_cmp_quote_val() {
  local v="$1"
  [[ "$v" == "NULL" ]] && { printf 'NULL'; return; }
  if [[ "$v" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then printf '%s' "$v"; return; fi
  [[ "$v" == \'* ]] && { printf '%s' "$v"; return; }
  printf "'%s'" "$v"
}

# 生成 TiDB CALL。$1=sp $2=capture $3=args(ordered in/out 形参序)。capture-aware：function/inout/out_param。
_cmp_gen_tidb() {
  local sp="$1" capture="$2" args="$3"
  local IFS=';' kv tag rest name val
  local -a callargs=(); local sets="" sels=""
  if [[ "$capture" == "function" ]]; then
    for kv in $args; do tag="${kv%%:*}"; rest="${kv#*:}"; [[ "$tag" == "in" ]] && callargs+=( "$(_cmp_quote_val "${rest#*=}")" ); done
    printf 'SELECT %s(%s);\n' "$sp" "$(IFS=','; printf '%s' "${callargs[*]}")"
    return
  fi
  if [[ "$capture" == "inout" ]]; then   # INOUT 参全 @var（SET @name=val; CALL(@name)），in: 给初值
    for kv in $args; do
      tag="${kv%%:*}"; rest="${kv#*:}"; [[ "$tag" != "in" ]] && continue
      name="${rest%%=*}"; val="${rest#*=}"
      sets+="SET @$name=$(_cmp_quote_val "$val");"; callargs+=( "@$name" ); sels+="@$name,"
    done
    printf '%sCALL %s(%s);\n' "$sets" "$sp" "$(IFS=','; printf '%s' "${callargs[*]}")"
    [[ -n "$sels" ]] && printf 'SELECT %s;\n' "${sels%,}"
    return
  fi
  # out_param / result_set：in→引号值，out→@var
  for kv in $args; do
    tag="${kv%%:*}"; rest="${kv#*:}"
    if [[ "$tag" == "in" ]]; then callargs+=( "$(_cmp_quote_val "${rest#*=}")" )
    else name="$rest"; sets+="SET @$name=NULL;"; callargs+=( "@$name" ); sels+="@$name,"; fi
  done
  printf '%sCALL %s(%s);\n' "$sets" "$sp" "$(IFS=','; printf '%s' "${callargs[*]}")"
  [[ -n "$sels" ]] && printf 'SELECT %s;\n' "${sels%,}"
}

# 生成 Oracle 调用（sqlplus）：function→SELECT FROM dual；inout→VAR+:name:=val+EXEC(:name)+PRINT；out_param→VAR+EXEC(:out)+PRINT
_cmp_gen_oracle() {
  local sp="$1" capture="$2" args="$3"
  local IFS=';' kv tag rest name val
  local -a callargs=(); local vars="" prints=""
  if [[ "$capture" == "function" ]]; then
    for kv in $args; do tag="${kv%%:*}"; rest="${kv#*:}"; [[ "$tag" == "in" ]] && callargs+=( "$(_cmp_quote_val "${rest#*=}")" ); done
    printf 'SELECT %s(%s) FROM dual;\nEXIT;\n' "$sp" "$(IFS=','; printf '%s' "${callargs[*]}")"
    return
  fi
  if [[ "$capture" == "inout" ]]; then
    for kv in $args; do
      tag="${kv%%:*}"; rest="${kv#*:}"; [[ "$tag" != "in" ]] && continue
      name="${rest%%=*}"; val="${rest#*=}"
      vars+="VAR $name VARCHAR2(4000);\nEXEC :$name:=$(_cmp_quote_val "$val");\n"
      callargs+=( ":$name" ); prints+="PRINT $name;\n"
    done
    printf '%b' "$vars"; printf 'EXEC %s(%s);\n' "$sp" "$(IFS=','; printf '%s' "${callargs[*]}")"; printf '%b' "$prints"; printf 'EXIT;\n'
    return
  fi
  # out_param / result_set
  for kv in $args; do
    tag="${kv%%:*}"; rest="${kv#*:}"
    if [[ "$tag" == "in" ]]; then callargs+=( "$(_cmp_quote_val "${rest#*=}")" )
    else name="$rest"; vars+="VAR $name VARCHAR2(4000);\n"; callargs+=( ":$name" ); prints+="PRINT $name;\n"; fi
  done
  printf '%b' "$vars"; printf 'EXEC %s(%s);\n' "$sp" "$(IFS=','; printf '%s' "${callargs[*]}")"; printf '%b' "$prints"; printf 'EXIT;\n'
}

# 抓 TiDB SELECT 输出里的值（按列序，tab/换行分隔）→ 与 outexp 顺序对齐
# 简化：取 SELECT 输出的非表头数据行，第一行按 tab 分列。
_cmp_capture_tidb() { awk 'NR>1 && !/^[@a-zA-Z_]/ {print} /^[a-zA-Z_]/ {next}' | tail -n +1 | head -1; }

run_exec() {
  : "${CASES_DIR:?compare 需 CASES_DIR（ora2tidb.conf）}"
  [[ -d "$CASES_DIR" ]] || die "CASES_DIR 不存在: $CASES_DIR"
  require_cmd sqlplus mysql awk
  resolve_dir REPORT_DIR; mkdir -p "$REPORT_DIR"
  # pre-compare 序列重置：COMPARE_RESET_SEQUENCES=seq1,seq2 两端 DROP/CREATE SEQUENCE 同起点
  if [[ -n "${COMPARE_RESET_SEQUENCES:-}" ]]; then
    local IFS=',' seq
    log "pre-compare 重置序列: $COMPARE_RESET_SEQUENCES"
    for seq in $COMPARE_RESET_SEQUENCES; do
      [[ -z "$seq" ]] && continue
      printf 'DROP SEQUENCE IF EXISTS %s;\nCREATE SEQUENCE %s START WITH 1 INCREMENT BY 1;\n' "$seq" "$seq" | mysql_tidb 2>/dev/null || true
      printf 'DROP SEQUENCE %s;\nCREATE SEQUENCE %s START WITH 1 INCREMENT BY 1;\nEXIT;\n' "$seq" "$seq" | sqlplus -S "$(oracle_connect)" 2>/dev/null || true
    done
  fi
  local report="$REPORT_DIR/compare_report.md"
  {
    echo "# 一致性对比报告（M3）"
    echo
    echo "- Oracle: ${ORACLE_USER}@${ORACLE_HOST}"
    echo "- TiDB: ${TIDB_USER}@${TIDB_HOST}"
    echo "- 用例: $CASES_DIR"
    echo
    echo "| 用例 | SP | capture | 一致性 | Oracle(ms) | TiDB(ms) | 加速比 |"
    echo "|------|----|---------|--------|-----------|----------|--------|"
  } >"$report"
  shopt -s nullglob
  local f id sp capture args norm perf outexp pass total=0 ok=0
  local ora_times="" tidb_times="" warmup repeat t0 t1 t_ora t_tidb speedup
  for f in "$CASES_DIR"/*.cases; do
    while IFS=$'\t' read -r id sp capture args norm perf outexp; do
      [[ -z "$id" ]] && continue
      total=$((total+1)); pass="✅"
      local tsql osql tout oout
      tsql="$(_cmp_gen_tidb "$sp" "$capture" "$args")"
      osql="$(_cmp_gen_oracle "$sp" "$capture" "$args")"
      warmup="${PERF_WARMUP:-3}"; repeat="${PERF_REPEAT:-10}"
      if [[ "$perf" == *warmup=* ]]; then warmup="${perf#*warmup=}"; warmup="${warmup%%[ ;]*}"; fi
      if [[ "$perf" == *repeat=* ]]; then repeat="${perf#*repeat=}"; repeat="${repeat%%[ ;]*}"; fi
      t_ora=""; t_tidb=""
      # Oracle 执行 + 计时（warmup + repeat，取 repeat 轮的中位数）
      if [[ "$warmup" -gt 0 ]]; then
        printf '%s\n%s\n' "WHENEVER OSERROR EXIT;" "$osql" | sqlplus -S "$(oracle_connect)" >/dev/null 2>&1 || true
      fi
      local ora_samples=""
      for ((_r=0; _r<repeat; _r++)); do
        t0="$(_cmp_now_ms)"
        oout="$(printf '%s\n%s\n' "WHENEVER OSERROR EXIT;" "$osql" | sqlplus -S "$(oracle_connect)" 2>&1)" || { pass="❌ Oracle执行错"; break; }
        t1="$(_cmp_now_ms)"
        ora_samples="$ora_samples $((t1-t0))"
      done
      if [[ "$pass" == "✅" ]]; then t_ora="$(_cmp_percentile "$ora_samples" 50)"; fi
      # TiDB 执行 + 计时
      if [[ "$pass" == "✅" && "$warmup" -gt 0 ]]; then
        printf '%s\n%s\n' "USE $TIDB_DB;" "$tsql" | mysql_tidb >/dev/null 2>&1 || true
      fi
      local tidb_samples=""
      if [[ "$pass" == "✅" ]]; then
        for ((_r=0; _r<repeat; _r++)); do
          t0="$(_cmp_now_ms)"
          tout="$(printf '%s\n%s\n' "USE $TIDB_DB;" "$tsql" | mysql_tidb -B -N 2>&1)" || { pass="❌ TiDB执行错"; break; }
          t1="$(_cmp_now_ms)"
          tidb_samples="$tidb_samples $((t1-t0))"
        done
      fi
      if [[ "$pass" == "✅" ]]; then t_tidb="$(_cmp_percentile "$tidb_samples" 50)"; fi
      # 值级 diff（outexp 形如 "p_bonus=750;p_label=A_<DATE:YYYYMMDD>"，按 ; 分项）
      if [[ "$pass" == "✅" && -n "$outexp" ]]; then
        local IFS=';' oe exp_name exp_val
        local ncols; ncols="$(printf '%s' "$tout" | awk 'NR==1{print NF}' 2>/dev/null)"
        local i=0
        for oe in $outexp; do
          exp_name="${oe%%=*}"; exp_val="${oe#*=}"
          local actval; actval="$(printf '%s' "$tout" | awk -v c=$((i+1)) 'NR==1{print $c}')"
          if ! _cmp_diff "$exp_val" "$actval" "$norm" "$exp_name"; then pass="❌ $exp_name: 期望[$exp_val] 实际[$actval]"; break; fi
          i=$((i+1))
        done
      fi
      # 加速比
      speedup="-"
      if [[ "$pass" == "✅" && -n "$t_ora" && -n "$t_tidb" && "$t_tidb" != "0" ]]; then
        speedup="$(awk -v o="$t_ora" -v t="$t_tidb" 'BEGIN { if (t>0) printf "%.1fx", o/t; else print "-" }')"
      fi
      [[ "$pass" == "✅" ]] && ok=$((ok+1))
      printf '| %s | %s | %s | %s | %s | %s | %s |\n' "$id" "$sp" "$capture" "$pass" "${t_ora:--}" "${t_tidb:--}" "$speedup" >>"$report"
      log "  $id [$sp/$capture] → $pass (Oracle=${t_ora:--}ms TiDB=${t_tidb:--}ms)"
      [[ "$pass" == "✅" ]] && ora_times+=" $t_ora" && tidb_times+=" $t_tidb"
    done < <(_cmp_parse "$f")
  done
  shopt -u nullglob
  {
    echo
    echo "**合计**：$total 用例，$ok 一致。"
    if [[ -n "$ora_times" ]]; then
      echo
      echo "## 性能汇总（p50，毫秒）"
      echo
      local p50_ora p50_tidb p99_ora p99_tidb
      p50_ora="$(_cmp_percentile "${ora_times# }" 50)"
      p50_tidb="$(_cmp_percentile "${tidb_times# }" 50)"
      p99_ora="$(_cmp_percentile "${ora_times# }" 99)"
      p99_tidb="$(_cmp_percentile "${tidb_times# }" 99)"
      echo "| 指标 | Oracle | TiDB |"
      echo "|------|--------|------|"
      echo "| p50 | ${p50_ora}ms | ${p50_tidb}ms |"
      echo "| p99 | ${p99_ora}ms | ${p99_tidb}ms |"
    fi
  } >>"$report"
  info "一致性对比完成：$ok/$total 一致；报告 $report"
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
