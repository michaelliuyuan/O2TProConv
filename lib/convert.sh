#!/usr/bin/env bash
# 模块2：Oracle PL/SQL 存储过程 → TiDB（MySQL 兼容）语法转换。
#
# 设计原则（诚实边界）：
#   - 确定性能转的：做自动机械转换（_apply_mechanical）。
#   - 无法靠正则可靠转换的复杂结构：不臆造，原文保留并在上一行注入
#     `-- TODO(需人工转换): <原因>` 标记（_mark_complex），同时汇总进转换报告。
#   原因：正则无法区分字符串字面量/嵌套结构，强行转换会产生比「提示人工」更坏的静默错误。
#     例如 MySQL 中 || 默认是逻辑或而非拼接，静默不转即语义错误，故必须标记。
set -euo pipefail

# 收集转换输出中的 TODO 明细（文件名 + 行号 + 原因），追加到全局 todo_section。
# 用法：_collect_todos <output_file> <base_name>
# 格式：- **base**（输出文件:L行号）：reason
_collect_todos() {
  local out_file="$1" base="$2"
  local todo_lines
  # 匹配行首或缩进后的 -- TODO(...)（_restructure 的 TODO 可能带缩进）
  todo_lines="$(grep -nE '^[[:space:]]*--[[:space:]]*TODO\(' "$out_file" 2>/dev/null || true)"
  [[ -z "$todo_lines" ]] && return 0
  local lineno reason
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    lineno="${line%%:*}"
    reason="${line#*:}"
    # 去掉前导 "-- TODO(...): " 前缀，保留纯原因文本
    reason="${reason#*): }"
    [[ -z "${reason// }" ]] && reason="(未标注原因)"
    todo_section+="- **${base}**（${out_file##*/}:L${lineno}）：${reason}"$'\n'
  done <<<"$todo_lines"
}

run_convert() {
  # convert 重度依赖 GNU sed（-E/\b）和 gawk（动态正则/字段分隔），启动时校验避免静默错误产出。
  require_gnu_sed
  require_gawk
  : "${ORACLE_DIR:=$EXPORT_DIR}"
  resolve_dir ORACLE_DIR
  resolve_dir CONVERTED_DIR
  resolve_dir REPORT_DIR
  mkdir -p "$CONVERTED_DIR" "$REPORT_DIR"

  local report="$REPORT_DIR/convert_report.md"
  if [[ -f "$report" ]]; then
    local backup="$REPORT_DIR/convert_report_$(date +%Y%m%d_%H%M%S).md"
    cp "$report" "$backup"
    info "已备份旧报告 → ${backup##*/}"
  fi
  {
    echo "# 转换报告"
    echo
    echo "- 输入目录: \`$ORACLE_DIR\`"
    echo "- 输出目录: \`$CONVERTED_DIR\`"
    echo
    echo "| 过程 | 状态 | TODO 标记数 |"
    echo "|------|------|-----------:|"
  } >"$report"

  shopt -s nullglob
  local f base out todos status total=0 need_review=0 failed=0
  local note_section="" sem_section="" todo_section="" pipes_section="" tmpdir
  tmpdir="$(mktemp -d)"
  for f in "$ORACLE_DIR"/*.sql; do
    [[ "$(basename "$f")" == _* ]] && continue      # 跳过 _proc_list.tsv 等辅助文件
    base="$(basename "$f" .sql)"

    # PACKAGE BODY 拆分：一个 PACKAGE_BODY 含多个 PROCEDURE/FUNCTION → 拆为独立文件分别转换
    if grep -qiE 'CREATE[[:space:]]+OR[[:space:]]+REPLACE[[:space:]]+PACKAGE[[:space:]]+BODY' "$f" 2>/dev/null; then
      local pkg_sp_list; pkg_sp_list="$(_split_package_body "$f" "$tmpdir" "$base" | tr ' ' '\n' | sort -u | tr '\n' ' ')"
      if [[ -n "$pkg_sp_list" ]]; then
        local pkg_sp pkg_base pkg_out pkg_todos
        for pkg_sp in $pkg_sp_list; do
          pkg_base="$(basename "$pkg_sp" .sql)"
          pkg_out="$CONVERTED_DIR/${pkg_base}.tidb.sql"
          convert_one "$pkg_sp" "$pkg_out"
          pkg_todos=$(grep -cE '^[[:space:]]*--[[:space:]]*TODO\(' "$pkg_out" || true)
          [[ "$pkg_todos" -gt 0 ]] && _collect_todos "$pkg_out" "$pkg_base"
          total=$((total+1))
          if ! grep -qE '^CREATE[[:space:]]+(PROCEDURE|FUNCTION)' "$pkg_out"; then
            printf '| %s | %s | %s |\n' "$pkg_base" "⚠️ 转换失败/空输出（头部 parse 不了？）需人工" "0" >>"$report"; failed=$((failed+1))
          elif [[ "$pkg_todos" -gt 0 ]]; then
            printf '| %s | %s | %s |\n' "$pkg_base" "需人工复核" "$pkg_todos" >>"$report"; need_review=$((need_review+1))
          else
            printf '| %s | %s | %s |\n' "$pkg_base" "已自动转换" "0" >>"$report"
          fi
          log "  $pkg_base → $pkg_out（TODO: $pkg_todos）"
          local pkg_pipe_count
          pkg_pipe_count=$(grep -cE '\|\|' "$pkg_out" 2>/dev/null || true)
          [[ "$pkg_pipe_count" -gt 0 ]] && pipes_section+="  - **$pkg_base**：${pkg_pipe_count} 处 || 依赖 PIPES_AS_CONCAT（输出文件头部已注入 SET SESSION sql_mode）"$'\n'
        done
      else
        # PACKAGE BODY 拆分失败 → 原样转换（产出 defensive check 失败）
        out="$CONVERTED_DIR/${base}.tidb.sql"
        convert_one "$f" "$out"
        todos=$(grep -cE '^[[:space:]]*--[[:space:]]*TODO\(' "$out" || true)
        [[ "$todos" -gt 0 ]] && _collect_todos "$out" "$base"
        total=$((total+1)); failed=$((failed+1))
        printf '| %s | %s | %s |\n' "$base" "⚠️ PACKAGE BODY 拆分失败，需人工" "$todos" >>"$report"
        log "  $base → $out（PACKAGE BODY 拆分失败）"
        local pkg_pipe_count
        pkg_pipe_count=$(grep -cE '\|\|' "$out" 2>/dev/null || true)
        [[ "$pkg_pipe_count" -gt 0 ]] && pipes_section+="  - **$base**：${pkg_pipe_count} 处 || 依赖 PIPES_AS_CONCAT（输出文件头部已注入 SET SESSION sql_mode）"$'\n'
      fi
      continue
    fi

    # PACKAGE spec 处理：提取 TYPE 声明（特别是 REF CURSOR），保存供 PACKAGE BODY 转换使用
    if grep -qiE '^CREATE[[:space:]]+OR[[:space:]]+REPLACE[[:space:]]+PACKAGE[[:space:]]+' "$f" 2>/dev/null && \
       ! grep -qiE 'PACKAGE[[:space:]]+BODY' "$f" 2>/dev/null; then
      local pkg_types; pkg_types="$(_extract_pkg_spec_types "$f" "$tmpdir" "$base")"
      if [[ -n "$pkg_types" ]]; then
        printf '%s\n' "$pkg_types" > "$tmpdir/${base}_pkg_types.txt"
        log "  $base → PACKAGE spec（TYPE 声明已提取：$(echo "$pkg_types" | wc -l) 个）"
      else
        log "  $base → PACKAGE spec（无 TYPE 声明，跳过）"
      fi
      continue
    fi

    out="$CONVERTED_DIR/${base}.tidb.sql"
    convert_one "$f" "$out"
    todos=$(grep -cE '^[[:space:]]*--[[:space:]]*TODO\(' "$out" || true)
    [[ "$todos" -gt 0 ]] && _collect_todos "$out" "$base"
    total=$((total+1))
    # defensive check（@架构师 建议，非静默）：输出缺 CREATE PROCEDURE|FUNCTION = parse 不了的头部结构
    # （如 inline-decl `AS v_x TYPE;` 单行）→ SP 整个消失是 silent failure，比语义边更重。标失败 + 计数。
    if ! grep -qE '^CREATE[[:space:]]+(PROCEDURE|FUNCTION)' "$out"; then
      status="⚠️ 转换失败/空输出（头部 parse 不了？）需人工"; failed=$((failed+1))
    elif [[ "$todos" -gt 0 ]]; then status="需人工复核"; need_review=$((need_review+1)); else status="已自动转换"; fi
    printf '| %s | %s | %s |\n' "$base" "$status" "$todos" >>"$report"
    # 默认长度/精度填充 NOTE（架构师 guardrail：不静默）——列出被填 VARCHAR(4000)/DECIMAL(65,30)
    # 的参数/声明，避免掩盖真实长度/精度需求。post-hoc 扫描转换输出。
    local vc dc
    vc=$(grep -cE 'VARCHAR\(4000\)' "$out" || true)
    dc=$(grep -cE 'DECIMAL\(65,30\)' "$out" || true)
    if [[ "$vc" -gt 0 || "$dc" -gt 0 ]]; then
      local note_line="  - **$base**："
      [[ "$vc" -gt 0 ]] && note_line+="VARCHAR(4000)×${vc}"
      [[ "$vc" -gt 0 && "$dc" -gt 0 ]] && note_line+="，"
      [[ "$dc" -gt 0 ]] && note_line+="DECIMAL(65,30)×${dc}"
      note_section+="${note_line}"$'\n'
    fi
    # 语义差异 NOTE（@架构师 复核：下列函数/类型已自动转但有已知语义差，需核对）——扫源文件。
    local sg mb n2 dt sem_line=""
    sg=$(grep -cE '(^|[^A-Za-z0-9_])SYS_GUID[[:space:]]*\(' "$f" || true)
    mb=$(grep -cE '(^|[^A-Za-z0-9_])MONTHS_BETWEEN[[:space:]]*\(' "$f" || true)
    n2=$(grep -cE '(^|[^A-Za-z0-9_])NVL2[[:space:]]*\(' "$f" || true)
    dt=$(grep -cE '(^|[^A-Za-z0-9_])DATE([^A-Za-z0-9_]|$)' "$f" || true)
    [[ "$sg" -gt 0 ]] && sem_line+="SYS_GUID→UUID(Oracle 32-hex 无连字符 vs MySQL 36 带连字符)×${sg}；"
    [[ "$mb" -gt 0 ]] && sem_line+="MONTHS_BETWEEN→TIMESTAMPDIFF(Oracle 小数月 vs MySQL 整数月截断)×${mb}；"
    [[ "$n2" -gt 0 ]] && sem_line+="NVL2→IF(Oracle ''≡NULL vs MySQL ''≠NULL，空串路径分歧)×${n2}；"
    [[ "$dt" -gt 0 ]] && sem_line+="DATE→DATETIME widening(Oracle DATE 带时分秒→MySQL DATETIME 保时间；若下游期望 DATE 仅日期精度需核对)×${dt}；"
    [[ -n "$sem_line" ]] && sem_section+="  - **$base**：${sem_line}"$'\n'
    # P2-b: 检测输出中残留 ||（SQL 字符串值内/跨行），记录 PIPES_AS_CONCAT 依赖
    local pipe_count
    pipe_count=$(grep -cE '\|\|' "$out" 2>/dev/null || true)
    [[ "$pipe_count" -gt 0 ]] && pipes_section+="  - **$base**：${pipe_count} 处 || 依赖 PIPES_AS_CONCAT（输出文件头部已注入 SET SESSION sql_mode）"$'\n'
    log "  $base → $out（TODO: $todos）"
  done
  shopt -u nullglob
  rm -rf "$tmpdir"

  # P3-e: 自定义函数自动迁移——扫描所有转换输出中的 FUNC_xxx() 调用，
  # 查 _function_sources/*.fnc 递归转 TiDB CREATE FUNCTION DDL → _custom_functions.tidb.sql
  local custom_fn_report
  custom_fn_report="$(_convert_custom_functions)"
  local custom_fn_section=""
  if [[ -n "$custom_fn_report" ]]; then
    custom_fn_section="$custom_fn_report"
  fi

  {
    echo
    echo "**合计**：$total 个过程，其中 $need_review 个需人工复核、$failed 个转换失败/空输出。"
    echo
    echo "## 默认长度/精度填充 NOTE（不静默）"
    echo
    if [[ -n "$note_section" ]]; then
      echo "下列参数/声明被填了安全默认（裸 Oracle 类型 → MySQL 必须带长度/精度）："
      echo
      printf '%s' "$note_section"
      echo
      echo "- VARCHAR(4000)：Oracle PL/SQL 裸 VARCHAR2（参数禁精度）→ MySQL VARCHAR 必须带长度，4000 为安全默认（不按列推断）。真实长度需求请人工核对。"
      echo "- DECIMAL(65,30)：裸 NUMBER → DECIMAL(65,30) 安全兜底（不做列精度推断）；高 scale NUMBER 有截断风险，请人工核对。"
    else
      echo "无默认填充（所有 VARCHAR2/NUMBER 均带显式长度/精度）。"
    fi
    echo
    echo "## 语义差异 NOTE（已自动转换但有已知差异，需核对）"
    echo
    if [[ -n "$sem_section" ]]; then
      echo "下列函数已自动转换，但 Oracle↔MySQL 存在已知语义差——若 SP 依赖被转换方语义（比较/截取/proration/空串），需人工核对："
      echo
      printf '%s' "$sem_section"
    else
      echo "无语义差异（或未使用 SYS_GUID / MONTHS_BETWEEN / NVL2 / DATE 类型）。"
    fi
    echo
    echo "## TODO 明细（需人工转换项，按文件+行号定位）"
    echo
    if [[ -n "$todo_section" ]]; then
      echo "下列行被标记 \`-- TODO(需人工转换)\`——正则无法可靠转换，需人工处理。定位格式：\`输出文件:L行号\`。"
      echo
      printf '%s' "$todo_section"
    else
      echo "无 TODO 标记（所有结构均自动转换）。"
    fi
    echo
    echo "## 自定义函数迁移（P3-e）"
    echo
    if [[ -n "$custom_fn_section" ]]; then
      echo "下列 Oracle 自定义函数已被检测并处理（DDL 输出到 \`_custom_functions.tidb.sql\`）："
      echo
      printf '%s' "$custom_fn_section"
    else
      echo "无自定义函数调用（或函数已随 PACKAGE BODY 转换）。"
    fi
    echo
    echo "## PIPES_AS_CONCAT 部署检查"
    echo
    if [[ -n "$pipes_section" ]]; then
      echo "⚠️ 部署红线：目标 TiDB sql_mode 必须保留 PIPES_AS_CONCAT（v7.1.9 默认已含）。"
      echo "SP 内所有 ||（含动态 SQL PREPARE/EXECUTE）在 CREATE PROCEDURE 时锁定 sql_mode，后续 session sql_mode 变更不影响行为。"
      echo "输出文件头部已注入幂等 \`SET SESSION sql_mode = CONCAT(@@sql_mode, ',PIPES_AS_CONCAT')\` 作为保底。"
      echo
      printf '%s' "$pipes_section"
    else
      echo "无 || 残留（所有 || 已自动转 CONCAT(IFNULL)，不依赖 PIPES_AS_CONCAT）。"
    fi
  } >>"$report"

  info "转换完成：$total 个，需复核 $need_review 个；报告 $report"
}

# PACKAGE BODY 拆分：从 Oracle PACKAGE BODY 中提取独立的 PROCEDURE/FUNCTION 定义，
# 写入临时文件供后续 convert_one 逐个转换。返回空格分隔的临时文件路径列表。
# 注意：PACKAGE 级变量/类型/游标声明不随子程序迁移，需人工处理（标记 TODO）。
_split_package_body() {
  local pkg_file="$1" tmpdir="$2" prefix="$3"
  local sp_list=""
  awk -v tmpdir="$tmpdir" -v prefix="$prefix" '
    BEGIN { IGNORECASE=1; in_sp=0; sp_name=""; sp_type=""; sp_lines=0; sp_count=0; in_pkg_decls=1; pkg_decls_lines=0; flushed=0 }
    /^[ \t]*--/ { if (in_sp) sp_buf[sp_lines++] = $0; else if (in_pkg_decls) pkg_decls[pkg_decls_lines++] = $0; next }
    /^[ \t]*PROCEDURE[ \t]+[A-Za-z_][A-Za-z0-9_]*/ || /^[ \t]*FUNCTION[ \t]+[A-Za-z_][A-Za-z0-9_]*/ {
      if (in_sp) { flush_sp() }
      in_sp=1; in_pkg_decls=0; sp_lines=0; flushed=0
      if ($0 ~ /^[ \t]*PROCEDURE/) sp_type="PROCEDURE"
      else sp_type="FUNCTION"
      sp_name=$0; sub(/^[ \t]*(PROCEDURE|FUNCTION)[ \t]+/,"",sp_name); sub(/[ \t(;].*$/,"",sp_name)
      sp_buf[sp_lines++] = "CREATE OR REPLACE " sp_type " " sp_name
      rest=$0; sub(/^[ \t]*(PROCEDURE|FUNCTION)[ \t]+[A-Za-z_][A-Za-z0-9_]*/,"",rest)
      if (rest !~ /^[ \t]*$/) sp_buf[sp_lines-1] = sp_buf[sp_lines-1] rest
      next
    }
    {
      if (in_sp) sp_buf[sp_lines++] = $0
      else if (in_pkg_decls && $0 !~ /^[ \t]*$/ \
               && $0 !~ /^[ \t]*CREATE[ \t]/ \
               && $0 !~ /^[ \t]*END[ \t]/ \
               && $0 !~ /^[ \t]*\/[ \t]*$/ \
               && $0 !~ /^[ \t]*AS[ \t]*$/ \
               && $0 !~ /^[ \t]*IS[ \t]*$/) {
        pkg_decls[pkg_decls_lines++] = $0
      }
      # 检测子程序结束：END 后跟**当前子程序名**或单独分号（非 END IF/LOOP/CASE）
      # Bug #4 修复：原正则匹配任意 END <name>; 会误匹配 PACKAGE BODY 的 END <pkg_name>;
      # → 子程序 buffer 含 pkg END → flush_sp 输出含多余内容；END{} 再 flush → 重复
      if (in_sp) {
        if ($0 ~ /^[ \t]*END[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*;/) {
          # 校验 END 后的名字是否=当前子程序名（避免误匹配 PACKAGE END）
          end_name=$0; sub(/^[ \t]*END[ \t]+/,"",end_name); sub(/[ \t]*;.*/,"",end_name)
          if (tolower(end_name) == tolower(sp_name)) flush_sp()
        } else if ($0 ~ /^[ \t]*END[ \t]*;/) {
          # END; 无名 → 子程序结束（Oracle 允许 END; 不带名）
          flush_sp()
        }
      }
    }
    function flush_sp(   fname, i) {
      if (!in_sp || sp_lines == 0) return
      fname = tmpdir "/" prefix "_" sp_name ".sql"
      # P1-c：PACKAGE 级声明注入到每个子程序头部
      if (pkg_decls_lines > 0) {
        for (i=0; i<pkg_decls_lines; i++) print pkg_decls[i] > fname
        print "-- ^^^ PACKAGE 级声明(变量/类型/游标)已注入; 全局状态(跨子程序共享)不支持, 需人工核对" > fname
      }
      for (i=0; i<sp_lines; i++) print sp_buf[i] > fname
      close(fname)
      printf "%s ", fname
      sp_count++; flushed=1
      in_sp=0; sp_lines=0
    }
    END { if (in_sp && !flushed) flush_sp() }
  ' "$pkg_file"
  printf '%s' "$sp_list"
}

# PACKAGE spec TYPE 提取：从 Oracle PACKAGE 规范中提取 TYPE 声明（REF CURSOR 等），
# 输出格式：<类型名> <类型类别>，供 PACKAGE BODY 转换时注入类型信息。
_extract_pkg_spec_types() {
  local pkg_file="$1" tmpdir="$2" prefix="$3"
  awk '
    BEGIN { IGNORECASE=1 }
    /^[ \t]*TYPE[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+IS[ \t]+REF[ \t]+CURSOR/ {
      line = $0
      sub(/^[ \t]*TYPE[ \t]+/,"",line)
      type_name = line; sub(/[ \t]+IS.*$/,"",type_name)
      print type_name " REF_CURSOR"
    }
    /^[ \t]*TYPE[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+IS[ \t]+(TABLE[ \t]+OF|RECORD|VARRAY)/ {
      line = $0
      sub(/^[ \t]*TYPE[ \t]+/,"",line)
      type_name = line; sub(/[ \t]+IS.*$/,"",type_name)
      print type_name " COLLECTION"
    }
    /^[ \t]*SUBTYPE[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+IS/ {
      line = $0
      sub(/^[ \t]*SUBTYPE[ \t]+/,"",line)
      type_name = line; sub(/[ \t]+IS.*$/,"",type_name)
      print type_name " SUBTYPE"
    }
  ' "$pkg_file"
}

# %TYPE 锚定类型解析：查 _schema_columns.tsv 将 table.column%TYPE / column%TYPE
# 替换为具体 Oracle 类型（后续由 _apply_mechanical 统一转 MySQL 类型）。
# 位置：在 _apply_mechanical 前（输出 Oracle 原生类型，复用机械层映射），
#       在 _mark_complex 前（解析成功的不再标 TODO）。
# 离线 fallback：无 _schema_columns.tsv 或列未匹配 → 原样保留（由 _mark_complex 兜底 TODO）。
# SCHEMA_COLUMNS 环境变量可覆盖默认路径（$ORACLE_DIR/_schema_columns.tsv）。
_resolve_anchor_type() {
  local cols_file="${SCHEMA_COLUMNS:-${ORACLE_DIR:-$EXPORT_DIR}/_schema_columns.tsv}"
  [[ -f "$cols_file" ]] || { cat; return 0; }   # 无 schema 数据 → 原样透传
  gawk -v cols="$cols_file" '
    BEGIN {
      # 加载 schema 列定义：key="OWNER.TABLE.COLUMN" → val=Oracle 类型表达式
      while ((getline line < cols) > 0) {
        n = split(line, f, "\t")
        if (n < 8) continue
        owner = toupper(f[1]); tab = toupper(f[2]); col = toupper(f[3])
        dtype = toupper(f[4]); dlen = f[5]; dprec = f[6]; dscale = f[7]
        key = owner SUBSEP tab SUBSEP col
        coltype[key] = type_expr(dtype, dlen, dprec, dscale)
      }
      close(cols)
    }
    # 按 Oracle 元数据生成类型表达式（与 _apply_mechanical 的输入约定一致）
    function type_expr(dt, dl, dp, ds,    t) {
      t = dt
      if (t == "VARCHAR2" || t == "CHAR" || t == "NVARCHAR2" || t == "NCHAR" || t == "RAW") {
        return t "(" dl ")"
      }
      if (t == "NUMBER") {
        if (dp != "" && ds != "") return "NUMBER(" dp "," ds ")"
        if (dp != "") return "NUMBER(" dp ")"
        return "NUMBER"
      }
      return t   # DATE/FLOAT/TIMESTAMP(6)/BLOB/CLOB 等原样返回
    }
    {
      line = $0
      if (line ~ /^[[:space:]]*--/) { print; next }
      # 反复找 %TYPE 锚定并替换；找不到或解析失败则跳出（留给 _mark_complex）
      while (match(line, /[A-Za-z_][A-Za-z0-9_]*([.][A-Za-z_][A-Za-z0-9_]*){0,2}%TYPE/)) {
        pre = substr(line, 1, RSTART - 1)
        anchor = substr(line, RSTART, RLENGTH)
        post = substr(line, RSTART + RLENGTH)
        rt = resolve(anchor)
        if (rt == "") break   # 本行后续无法继续安全替换（避免死循环）
        line = pre rt post
      }
      print line
    }
    function resolve(anchor,    a, np, parts, tab, col, owner, k, kk) {
      a = anchor; sub(/%TYPE$/, "", a)
      np = split(a, parts, ".")
      if (np == 2) {
        # table.column%TYPE：owner 缺省 → 匹配任意 owner
        tab = toupper(parts[1]); col = toupper(parts[2])
        for (k in coltype) {
          split(k, kk, SUBSEP)
          if (kk[2] == tab && kk[3] == col) return coltype[k]
        }
        return ""
      } else if (np == 3) {
        owner = toupper(parts[1]); tab = toupper(parts[2]); col = toupper(parts[3])
        k = owner SUBSEP tab SUBSEP col
        return (k in coltype) ? coltype[k] : ""
      }
      # np==1（column%TYPE 无表前缀）或其他 → 不处理（需 symtab，留给 _convert_type_aware）
      return ""
    }
  '
}

# P4-a: %ROWTYPE 自动展开——查 _schema_columns.tsv 将 v_name table%ROWTYPE
# 展开为逐字段 DECLARE，并替换 body 中 v_name.column → v_name_column。
# 位置：在 _resolve_anchor_type 之后（复用已加载的 schema 列定义），
#       在 _apply_mechanical 之前（输出 Oracle 原生类型，复用机械层映射）。
# 离线 fallback：无 _schema_columns.tsv 或表未匹配 → 原样保留（由 _mark_complex 兜底 TODO）。
# SCHEMA_COLUMNS 环境变量可覆盖默认路径（$ORACLE_DIR/_schema_columns.tsv）。
_resolve_rowtype() {
  local cols_file="${SCHEMA_COLUMNS:-${ORACLE_DIR:-$EXPORT_DIR}/_schema_columns.tsv}"
  [[ -f "$cols_file" ]] || { cat; return 0; }   # 无 schema 数据 → 原样透传
  gawk -v cols="$cols_file" '
    BEGIN { q = sprintf("%c", 39) }

    # 加载 schema 列定义（与 _resolve_anchor_type 同格式）
    function load_schema(   line, n, f, owner, tab, col, dtype, dlen, dprec, dscale, key) {
      while ((getline line < cols) > 0) {
        n = split(line, f, "\t")
        if (n < 8) continue
        owner = toupper(f[1]); tab = toupper(f[2]); col = f[3]
        dtype = toupper(f[4]); dlen = f[5]; dprec = f[6]; dscale = f[7]
        coltype[owner SUBSEP tab SUBSEP toupper(col)] = type_expr(dtype, dlen, dprec, dscale)
        # 按出现顺序记录列名（TSV 已按 column_name 排序或保持 DDL 序）
        key = owner SUBSEP tab
        if (!(key in col_count)) { col_count[key] = 0; has_table[key] = 1 }
        col_count[key]++
        col_names[key, col_count[key]] = col
      }
      close(cols)
    }

    function type_expr(dt, dl, dp, ds,    t) {
      t = dt
      if (t == "VARCHAR2" || t == "CHAR" || t == "NVARCHAR2" || t == "NCHAR" || t == "RAW") return t "(" dl ")"
      if (t == "NUMBER") {
        if (dp != "" && ds != "") return "NUMBER(" dp "," ds ")"
        if (dp != "") return "NUMBER(" dp ")"
        return "NUMBER"
      }
      return t
    }

    # 引号感知替换：在代码段（非字符串内）将 v_name. 替换为 v_name_
    function code_replace_dot(s, vname,   n, i, c, nx, in_str, result, pat, vlen) {
      n = length(s); in_str = 0; result = ""
      vlen = length(vname)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (in_str) {
          result = result c
          if (c == q) { nx = substr(s, i + 1, 1); if (nx == q) { result = result nx; i++; continue } else in_str = 0 }
          continue
        }
        if (c == q) { in_str = 1; result = result c; continue }
        # 代码段：检测 v_name 后面跟 .
        if (substr(s, i, vlen) == vname && substr(s, i + vlen, 1) == ".") {
          result = result vname "_"
          i += vlen  # 跳过 vname，. 由 i++ 跳过
          continue
        }
        result = result c
      }
      return result
    }

    # 检测行中代码段是否含 v_name. 引用（引号感知）
    function code_has_dot(s, vname,   n, i, c, nx, in_str, vlen) {
      n = length(s); in_str = 0; vlen = length(vname)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (in_str) {
          if (c == q) { nx = substr(s, i + 1, 1); if (nx == q) { i++; continue } else in_str = 0 }
          continue
        }
        if (c == q) { in_str = 1; continue }
        if (substr(s, i, vlen) == vname && substr(s, i + vlen, 1) == ".") return 1
      }
      return 0
    }

    # 检测行中字符串段是否含 v_name. 引用（用于动态 SQL TODO 标记）
    function str_has_dot(s, vname,   n, i, c, nx, in_str, vlen) {
      n = length(s); in_str = 0; vlen = length(vname)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (in_str) {
          if (c == q) { nx = substr(s, i + 1, 1); if (nx == q) { i++; continue } else in_str = 0 }
          else if (substr(s, i, vlen) == vname && substr(s, i + vlen, 1) == ".") return 1
          continue
        }
        if (c == q) { in_str = 1; continue }
      }
      return 0
    }

    # 变量名安全 guard：长度 >= 3，非保留词
    function valid_varname(v) {
      if (length(v) < 3) return 0
      if (v ~ /^(CUR|ROW|REC|TMP|VAL|VAR|NUM|STR)$/i) return 0
      return 1
    }

    # 查表获取列列表 key（owner SUBSEP tab），owner 缺省时匹配任意 owner
    function find_table_key(tab_name,   np, parts, tab, owner, k, kk) {
      np = split(tab_name, parts, ".")
      if (np == 1) {
        tab = toupper(parts[1])
        for (k in has_table) {
          split(k, kk, SUBSEP)
          if (kk[2] == tab) return k
        }
        return ""
      } else if (np == 2) {
        owner = toupper(parts[1]); tab = toupper(parts[2])
        if ((owner SUBSEP tab) in has_table) return owner SUBSEP tab
        return ""
      }
      return ""
    }

    # 展开一张表的列为 DECLARE 声明片段（逐字段 v_prefix_colname TYPE）
    function expand_declares(vname, tkey,   i, nc, col, ct, out) {
      nc = col_count[tkey]
      out = ""
      for (i = 1; i <= nc; i++) {
        col = col_names[tkey, i]
        ct = coltype[tkey SUBSEP toupper(col)]
        if (ct == "") ct = "VARCHAR2(4000)"
        out = out vname "_" col " " ct
        if (i < nc) out = out ";\n  "
      }
      return out
    }

    # 生成逐字段 INTO 列表（v_name_col1, v_name_col2, ...）
    function expand_into_list(vname, tkey,   i, nc, col, out) {
      nc = col_count[tkey]
      out = ""
      for (i = 1; i <= nc; i++) {
        col = col_names[tkey, i]
        if (i > 1) out = out ", "
        out = out vname "_" col
      }
      return out
    }

    NR == 1 { load_schema() }

    {
      line = $0
      if (line ~ /^[[:space:]]*--/) { print; next }

      # 检测 %ROWTYPE 声明：v_name [owner.]table%ROWTYPE
      if (match(line, /[A-Za-z_][A-Za-z0-9_]*[[:space:]]+([A-Za-z_][A-Za-z0-9_]*[.])?[A-Za-z_][A-Za-z0-9_]*%ROWTYPE/)) {
        decl = substr(line, RSTART, RLENGTH)
        # 提取 var_name（第一个 token）
        var_name = decl; sub(/[[:space:]].*$/, "", var_name)
        # 提取 table_name（var_name 之后、%ROWTYPE 之前）
        table_part = decl; sub(/^[A-Za-z_][A-Za-z0-9_]*[[:space:]]+/, "", table_part); sub(/%ROWTYPE.*$/, "", table_part)

        if (!valid_varname(var_name)) {
          print "-- TODO(需人工转换): %ROWTYPE 变量名 " q var_name q " 过短或为保留词，需人工展开"
          next
        }

        tkey = find_table_key(table_part)
        if (tkey == "") {
          print "-- TODO(需人工转换): %ROWTYPE 表 " table_part " 未在 schema 数据中找到，需人工展开"
          next
        }

        # 记录 var → table 映射供后续行引用替换
        rowtype_var[var_name] = tkey
        # 输出逐字段 DECLARE
        print "-- INFO: " var_name " " table_part "%ROWTYPE 自动展开为逐字段"
        print "  " expand_declares(var_name, tkey) ";"
        next
      }

      # 对已收集的 %ROWTYPE 变量做引用替换
      line_done = 0
      str_todo = ""
      for (vn in rowtype_var) {
        # 1) 动态 SQL 字符串内含 v_name.col → 标 TODO 不替换该变量
        if (str_has_dot(line, vn)) {
          if (str_todo == "") str_todo = vn
          else str_todo = str_todo "," vn
          continue
        }
        # 2) 代码层 v_name.col → v_name_col（引号感知）
        if (code_has_dot(line, vn)) {
          line = code_replace_dot(line, vn)
        }
      }
      if (str_todo != "") {
        print "-- TODO(需人工转换): 动态 SQL 字符串内 " str_todo ".column 引用需人工展开为逐字段变量"
      }
      print line
    }
  '
}

# P2-d: REF CURSOR 后处理——删除 SP body 中使用 OPEN FOR 的 REF CURSOR OUT 参数，
# 并合并双重执行（EXECUTE IMMEDIATE var + OPEN cursor FOR var 同变量）。
# 在所有转换 pass 之后运行。输入：stdin，输出：stdout。
_cleanup_ref_cursor() {
  local text; text="$(cat)"
  # 检测是否有 OPEN <name> FOR 的 TODO（_restructure 转换后留下的标记）
  local cursor_var
  cursor_var="$(printf '%s\n' "$text" | sed -nE 's/.*OPEN ([A-Za-z_][A-Za-z0-9_]*) FOR.*已转为 PREPARE.*/\1/p' | head -1)"
  if [[ -n "$cursor_var" ]]; then
    # 1. 删除参数列表中的 OUT <cursor_var> <TYPE> 参数（处理尾逗号 + 补 ) 闭合）
    # 模式 A: 同行 ..., OUT cursor_var TYPE) → ...)
    text="$(printf '%s\n' "$text" | sed -E "s/,[[:space:]]*OUT[[:space:]]+${cursor_var}[[:space:]]+[A-Za-z_][A-Za-z0-9_]*([[:space:]]*\))/\1/g")"
    # 模式 B: 独占行 OUT cursor_var TYPE)
    # 先找到独占行行号，修复上一行尾逗号 + 补 )，再删除独占行
    local out_line
    out_line="$(printf '%s\n' "$text" | grep -nE "^[[:space:]]*OUT[[:space:]]+${cursor_var}[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\)" | head -1 | cut -d: -f1)"
    if [[ -n "$out_line" ]]; then
      # 上一行去尾逗号 + 补 )
      text="$(printf '%s\n' "$text" | sed -E "$((out_line-1))s/,[[:space:]]*$/)/")"
      # 删除独占行 OUT 参数
      text="$(printf '%s\n' "$text" | sed -E "${out_line}d")"
    fi
    # 2. 双重执行合并：删除 EXECUTE IMMEDIATE 残留的 PREPARE/EXECUTE/DEALLOCATE 块
    # 2. 双重执行合并：删除 EXECUTE IMMEDIATE 残留的 SET/PREPARE/EXECUTE/DEALLOCATE 块
    #    从 OPEN FOR TODO 行向前搜索，找到紧邻的 SET/PREPARE/EXECUTE/DEALLOCATE 4 行块
    local todo_line
    todo_line="$(printf '%s\n' "$text" | grep -n 'OPEN '"$cursor_var"' FOR.*已转为 PREPARE' | head -1 | cut -d: -f1)"
    if [[ -n "$todo_line" ]]; then
      # 向前搜索最多 10 行，找 SET @sql = 行
      local i found_set=0
      for ((i=todo_line-1; i>=todo_line-10 && i>=1; i--)); do
        local check_line
        check_line="$(printf '%s\n' "$text" | sed -n "${i}p")"
        if echo "$check_line" | grep -qE 'SET @sql = '; then
          # 验证后续 3 行是 PREPARE/EXECUTE/DEALLOCATE
          local l2 l3 l4
          l2="$(printf '%s\n' "$text" | sed -n "$((i+1))p")"
          l3="$(printf '%s\n' "$text" | sed -n "$((i+2))p")"
          l4="$(printf '%s\n' "$text" | sed -n "$((i+3))p")"
          if echo "$l2" | grep -q 'PREPARE stmt' && \
             echo "$l3" | grep -q 'EXECUTE stmt' && \
             echo "$l4" | grep -q 'DEALLOCATE PREPARE'; then
            # 删除这 4 行（EXECUTE IMMEDIATE 残留）
            text="$(printf '%s\n' "$text" | sed -E "${i},$((i+3))d")"
            found_set=1
            break
          fi
        fi
      done
    fi
  fi
  printf '%s' "$text"
}

# Strip -- inline comments inside dynamic SQL string literals.
# When PREPARE executes a string containing '-- comment', the -- is treated as
# a SQL comment at runtime, truncating the line. This pass removes -- comments
# that appear inside string literals (tracked via in_str state machine with '' escape).
# Code-level -- comments (outside strings) are preserved.
_strip_dynsql_inline_comments() {
  gawk '
    BEGIN { q = sprintf("%c", 39); in_str = 0 }
    {
      line = $0
      out = ""
      n = length(line)
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (in_str) {
          if (c == q) {
            nx = substr(line, i+1, 1)
            if (nx == q) { out = out c nx; i++; continue }
            in_str = 0; out = out c; continue
          }
          if (c == "-" && substr(line, i+1, 1) == "-") {
            break
          }
          out = out c
        } else {
          if (c == q) { in_str = 1 }
          out = out c
        }
      }
      print out
    }
  '
}

# Strip GBK-encoded comment bytes that break TiDB's UTF-8 parser.
# Strategy: strip non-ASCII bytes IN-PLACE (never delete entire lines) to preserve
# code structure (e.g. DECODE multi-line args between /* */ blocks).
# Also clears pure-comment lines that become empty after stripping.
_strip_gbk_comments() {
  local text; text="$(cat)"
  # If input is valid UTF-8 (no GBK corruption), skip all stripping —
  # Chinese chars are legitimate printable characters in UTF-8.
  if printf '%s' "$text" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
    printf '%s' "$text"
    return 0
  fi
  # GBK or corrupted encoding — strip non-ASCII bytes as ? to preserve quote pairing
  printf '%s' "$text" | sed -E \
    -e 's/[^[:print:][:space:]]/?/g' \
    -e 's/[[:space:]]*-*--[[:space:]]*$//' \
    -e 's/--([^[:space:]\/-])/-- \1/g' \
    -e '/^[[:space:]]*\/\*[[:space:]]*$/d' \
    -e '/^[[:space:]]*\*\/[[:space:]]*$/d' \
    -e '/^[[:space:]]*--[[:space:]]*$/d'
}

# 转换单个文件
convert_one() {
  local in="$1" out="$2"
  local text; text="$(cat "$in")"
  text="$(sed -E '1s/^\xEF\xBB\xBF//' <<<"$text")"
  text="$(_tochar_date       <<<"$text")"
  text="$(_strip_gbk_comments <<<"$text")"
  text="$(_strip_dynsql_inline_comments <<<"$text")"
  text="$(_resolve_anchor_type <<<"$text")"
  text="$(_resolve_rowtype   <<<"$text")"
  text="$(_apply_mechanical  <<<"$text")"
  text="$(_rename_reserved_kw <<<"$text")"
  text="$(_convert_known_semantics <<<"$text")"
  text="$(_fix_header     <<<"$text")"
  text="$(_mark_complex   <<<"$text")"
  text="$(_rewrite_header <<<"$text")"
  text="$(_param_mode     <<<"$text")"
  text="$(_nested_blocks  <<<"$text")"
  text="$(_restructure    <<<"$text")"
  text="$(_convert_type_aware <<<"$text")"
  text="$(_cleanup_ref_cursor <<<"$text")"
  {
    echo "-- 由 oracle2tidb-sp 自动转换生成；请核对带 -- TODO(需人工转换) 的行"
    # P2-b: 若输出含残留 ||（SQL 字符串值内或跨行未转），注入幂等 SET SESSION sql_mode
    # 保证 CREATE PROCEDURE 时当前连接含 PIPES_AS_CONCAT（TiDB v7.1.9 默认已含，此为保底）。
    # SP 在 CREATE 时锁定 sql_mode，后续 CALL 不受 session 变更影响（含 SP 内 PREPARE/EXECUTE）。
    local need_pipes
    need_pipes="$(printf '%s\n' "$text" | grep -cE '\|\|' 2>/dev/null || true)"
    if [[ "${need_pipes:-0}" -gt 0 ]]; then
      echo "-- INFO: 本文件含 || 拼接（SQL 字符串值内/跨行），依赖 PIPES_AS_CONCAT。"
      echo "-- CREATE PROCEDURE 时 sql_mode 须含 PIPES_AS_CONCAT（TiDB v7.1.9 默认已含）。"
      echo "-- SP 内所有 ||（含动态 SQL PREPARE/EXECUTE）在 CREATE 时锁定，后续 session 变更不影响。"
      echo "SET SESSION sql_mode = IF(LOCATE('PIPES_AS_CONCAT', @@sql_mode) > 0, @@sql_mode, CONCAT(@@sql_mode, ',PIPES_AS_CONCAT'));"
    fi
    # P3-e: 自定义函数调用检测——检测输出含 FUNC_xxx( 调用模式，
    # 记录函数名供 run_convert 全局去重递归转换（DDL 输出到 _custom_functions.tidb.sql）。
    # _mark_complex 已在各调用点注入 INFO 注释（含替代建议）。
    # 若 _function_sources/*.fnc 存在，run_convert 会递归转换出完整 TiDB CREATE FUNCTION；
    # 若不存在，run_convert 输出 DDL 桩 + TODO（需业务方实现）。
    local custom_fns
    custom_fns="$(printf '%s\n' "$text" | grep -oE 'FUNC_[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(' 2>/dev/null | sed -E 's/[[:space:]]*\(//' | sort -u || true)"
    if [[ -n "$custom_fns" ]]; then
      echo "-- INFO: 本 SP 调用以下自定义函数（DDL 见 _custom_functions.tidb.sql 或文件头部桩）:"
      local fn
      while IFS= read -r fn; do
        [[ -z "$fn" ]] && continue
        echo "--   $fn"
      done <<<"$custom_fns"
    fi
    # 从任意位置抽出 DROP 行、提到 DELIMITER // 之前——默认分隔符下执行、幂等：
    # 反馈环每次 pull 新 hash 重跑不会因 duplicate 挂；DROP 也不会被 // 分隔符吞掉成语法错。
    local drop_line body_text
    drop_line="$(printf '%s\n' "$text" | grep -m1 -E '^DROP[[:space:]]+(PROCEDURE|FUNCTION)[[:space:]]+IF[[:space:]]+EXISTS' || true)"
    if [[ -n "$drop_line" ]]; then
      body_text="$(printf '%s\n' "$text" | grep -v -E '^DROP[[:space:]]+(PROCEDURE|FUNCTION)[[:space:]]+IF[[:space:]]+EXISTS')"
      printf '%s\n' "$drop_line"
    else
      body_text="$text"
    fi
    echo "DELIMITER //"
    printf '%s\n' "$body_text"
    echo "//"
    echo "DELIMITER ;"
  } >"$out"
}

# P3-e: 自定义函数自动迁移——扫描所有转换输出中的 FUNC_xxx() 调用，
# 查 _function_sources/*.fnc 递归转 TiDB CREATE FUNCTION DDL。
# 输出：① _custom_functions.tidb.sql（全局合并，去重）② 报告文本（stdout）
# 逻辑：
#   - 收集所有 .tidb.sql 中的 FUNC_xxx( 调用 → 唯一函数名集合
#   - 对每个函数名：查 $ORACLE_DIR/_function_sources/<owner>.<name>.fnc（遍历所有 owner）
#   - 找到 .fnc → 注入 "CREATE OR REPLACE " 前缀 → 递归 convert_one → 输出完整 DDL
#   - 未找到 → 输出 DDL 桩 + TODO（参数/返回类型未知 → VARCHAR(4000) 兜底）
_convert_custom_functions() {
  local fn_dir="${ORACLE_DIR:-$EXPORT_DIR}/_function_sources"
  local out_file="$CONVERTED_DIR/_custom_functions.tidb.sql"
  local report=""

  # 1) 扫描所有转换输出，收集唯一自定义函数名（跳过注释行，避免注释中提及的函数名误生成桩）
  local all_fns
  all_fns="$(grep -rhE --exclude='_custom_functions.tidb.sql' 'FUNC_[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(' "$CONVERTED_DIR"/*.tidb.sql 2>/dev/null \
             | grep -vE '^[[:space:]]*--' \
             | grep -ohE 'FUNC_[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(' \
             | sed -E 's/[[:space:]]*\(//' | sort -u || true)"
  [[ -z "$all_fns" ]] && return 0

  : >"$out_file"
  echo "-- 自定义函数迁移（P3-e 自动递归转换）" >>"$out_file"
  echo "-- 由 oracle2tidb-sp 从 _function_sources/*.fnc 递归转换生成" >>"$out_file"
  echo >>"$out_file"

  local fn fn_found=0 fn_stub=0
  while IFS= read -r fn; do
    [[ -z "$fn" ]] && continue
    local fnc_file=""
    # 查找匹配的 .fnc 文件（文件名格式：<owner>.<function_name>.fnc）
    if [[ -d "$fn_dir" ]]; then
      # glob 匹配所有 *.<fn>.fnc 文件，取第一个匹配
      local fnc_glob
      shopt -s nullglob
      fnc_glob=( "$fn_dir"/*."${fn}".fnc )
      shopt -u nullglob
      if [[ ${#fnc_glob[@]} -gt 0 ]]; then
        fnc_file="${fnc_glob[0]}"
      fi
    fi

    if [[ -n "$fnc_file" && -f "$fnc_file" ]]; then
      # 2a) 找到 .fnc → 递归转换
      local fn_tmp; fn_tmp="$(mktemp)"
      # all_source 输出以 "FUNCTION name(...)" 开头，无 CREATE OR REPLACE
      # 注入 "CREATE OR REPLACE " 前缀使 convert_one pipeline 能识别头部
      # 去 UTF-8 BOM（EF BB BF）和前导空白，避免前缀与 FUNCTION 间夹 BOM 导致头部正则失配
      local fn_body; fn_body="$(sed -E '1s/^\xEF\xBB\xBF//; s/^[[:space:]]*//' "$fnc_file")"
      printf 'CREATE OR REPLACE %s\n' "$fn_body" >"$fn_tmp"
      local fn_out; fn_out="$(mktemp)"
      convert_one "$fn_tmp" "$fn_out"
      # 校验转换成功（输出含 CREATE FUNCTION）
      if grep -qE '^CREATE[[:space:]]+FUNCTION' "$fn_out"; then
        cat "$fn_out" >>"$out_file"
        echo >>"$out_file"
        report+="  - **$fn** ✅ 从 \`.fnc\` 递归转换（完整 TiDB DDL）"$'\n'
        fn_found=$((fn_found+1))
        local fn_todos; fn_todos=$(grep -cE '^[[:space:]]*--[[:space:]]*TODO\(' "$fn_out" || true)
        [[ "$fn_todos" -gt 0 ]] && report+="    - ⚠️ 转换含 ${fn_todos} 个 TODO 需人工复核"$'\n'
      else
        # 转换失败 → 桩 + TODO
        _emit_fn_stub "$fn" >>"$out_file"
        echo >>"$out_file"
        report+="  - **$fn** ⚠️ \`.fnc\` 存在但转换失败（头部 parse 失败），已输出 DDL 桩 + TODO"$'\n'
        fn_stub=$((fn_stub+1))
      fi
      rm -f "$fn_tmp" "$fn_out"
    else
      # 2b) 未找到 .fnc → DDL 桩 + TODO
      _emit_fn_stub "$fn" >>"$out_file"
      echo >>"$out_file"
      report+="  - **$fn** ⚠️ 无 \`.fnc\` 源码（权限不足或未导出），已输出 DDL 桩 + TODO"$'\n'
      fn_stub=$((fn_stub+1))
    fi
  done <<<"$all_fns"

  report+=$'\n'"**合计**：$((fn_found + fn_stub)) 个自定义函数（${fn_found} 个递归转换、${fn_stub} 个 DDL 桩）。"$'\n'
  printf '%s' "$report"
}

# 自定义函数 DDL 桩生成器——当无 .fnc 源码或转换失败时输出。
# 参数/返回类型未知 → VARCHAR(4000) 兜底 + TODO。
# 输出到 stdout。
_emit_fn_stub() {
  local fn="$1"
  echo "-- TODO(需人工实现): 自定义函数 $fn 无 Oracle 源码（.fnc 未导出或转换失败）"
  echo "-- 需手动实现或从 Oracle all_source 拉取后重跑 convert"
  echo "DROP FUNCTION IF EXISTS $fn;"
  echo "DELIMITER //"
  echo "CREATE FUNCTION $fn() RETURNS VARCHAR(4000)"
  echo "BEGIN"
  echo "  -- TODO: 实现函数逻辑（参数/返回类型未知，已用 VARCHAR(4000) 兜底）"
  echo "  RETURN NULL;"
  echo "END //"
  echo "DELIMITER ;"
}

# 机械转换：安全的、确定性的 token / 模式替换（GNU sed，支持 \b 与 I 标志）。
_apply_mechanical() {
  # 预处理：删除含 GBK 乱码字节的 /* */ 块注释行 + 残留的孤立 /* 或 */ 行
  sed -E '/\/\*/,/\*\// { /[^[:print:][:space:]]/d; }' | \
  sed -E '/^[[:space:]]*\/\*[[:space:]]*$/d; /^[[:space:]]*\*\/[[:space:]]*$/d' | \
  sed -E \
    -e '/^[[:space:]]*--.*[^[:print:][:space:]]/s/.*//' \
    -e '/^[[:space:]]*--/b' \
    -e 's/[[:space:]]*-*--[[:space:]]*[^[:print:][:space:]].*$//' \
    -e 's/\bNVARCHAR2[ \t]*\(/NVARCHAR(/gI' \
    -e 's/\bNVARCHAR2\b/NVARCHAR(4000)/gI' \
    -e 's/\bVARCHAR2[ \t]*\(/VARCHAR(/gI' \
    -e 's/\bVARCHAR2\b/VARCHAR(4000)/gI' \
    -e 's/VARCHAR[(]32767[)]/TEXT/gI' \
    -e 's/\bRAW[ \t]*\(/VARBINARY(/gI' \
    -e 's/\bNUMBER\(/DECIMAL(/gI' \
    -e 's/\bNUMBER\b/DECIMAL(65,30)/gI' \
    -e 's/\bPLS_INTEGER\b/INT/gI' \
    -e 's/\bBINARY_INTEGER\b/INT/gI' \
    -e 's/\bSIMPLE_INTEGER\b/BIGINT/gI' \
    -e 's/\bNVL\(/IFNULL(/gI' \
    -e 's/\bSYSDATE\b/NOW()/gI' \
    -e 's/\bSYSTIMESTAMP\b/CURRENT_TIMESTAMP(6)/gI' \
    -e 's/\bDATE\b/DATETIME/gI' \
    -e 's/\bDATETIME[ \t]*'\''/DATE '\''/gI' \
    -e 's/\bLENGTH[ \t]*\(/CHAR_LENGTH(/gI' \
    -e 's/\bCHR[ \t]*\(/CHAR(/gI' \
    -e 's/\bSYS_GUID[ \t]*\(\)/UUID()/gI' \
    -e 's/\bELSIF\b/ELSEIF/gI' \
    -e 's/^---/-- -/' \
    -e 's/[[:space:]]---/ -- -/g' \
    -e 's/^\/$/'                        # 去掉 Oracle 的 `/` 执行终止行
  # 说明：|| 与 DECODE 现由 _convert_known_semantics 做「忠实版自动转换」（已知语义差，默认开启）；
  #   转不了的（跨行/操作数边界不可靠）才注入 TODO。DATE(类型)/%TYPE/FOR..IN/
  #   BULK COLLECT/EXCEPTION/CURSOR..IS/DBMS_OUTPUT 仍由 _mark_complex 标人工。
  #   EXECUTE IMMEDIATE 现由 _restructure 半自动转 PREPARE/EXECUTE/DEALLOCATE。
}

# P5-d: MySQL/TiDB 保留关键字作为 JOIN 别名时自动改名（加 _ 后缀）。
# 两阶段：
#   1) 扫描 `) KW ON` 模式，提取确认为别名的 KW（需在 MySQL 保留字列表内）
#   2) 仅对确认的别名做 `) KW ON` → `) KW_ ON` 和 `KW.` → `KW_.` 替换
# 不做全局 KW. 替换——避免误改合法的 schema.table.column 引用。
# 不改字符串字面量内的内容（引号感知）。
_rename_reserved_kw() {
  local tmp; tmp=$(mktemp)
  cat > "$tmp"
  gawk '
    BEGIN {
      q = sprintf("%c", 39)
      # MySQL 8.0 reserved words (R) that could appear as SP table aliases
      n = split("ACCESSIBLE ADD ALL ALTER ANALYZE AND AS ASC ASENSITIVE BEFORE " \
        "BETWEEN BIGINT BINARY BLOB BOTH BY CALL CASCADE CASCADED CASE CAST " \
        "CHAR CHARACTER CHECK COLLATE COLUMN CONDITION CONSTRAINT CONTINUE " \
        "CONVERT CREATE CROSS CUBE CUME_DIST CURRENT_DATE CURRENT_TIME " \
        "CURRENT_TIMESTAMP CURRENT_USER CURSOR DATABASE DATABASES DAY_HOUR " \
        "DAY_MICROSECOND DAY_MINUTE DAY_SECOND DEC DECIMAL DECLARE DEFAULT " \
        "DELAYED DELETE DENSE_RANK DESC DESCRIBE DETERMINISTIC DISTINCT " \
        "DISTINCTROW DIV DOUBLE DROP DUAL EACH ELSE ELSEIF EMPTY ENCLOSED " \
        "ESCAPED EXCEPT EXISTS EXIT EXPLAIN FALSE FETCH FIRST_VALUE FLOAT " \
        "FLOAT4 FLOAT8 FOR FORCE FOREIGN FROM FULLTEXT FUNCTION GENERATED " \
        "GET GRANT GROUP GROUPING GROUPS HAVING HIGH_PRIORITY HOUR_MICROSECOND " \
        "HOUR_MINUTE HOUR_SECOND IF IGNORE IN INDEX INFILE INNER INOUT " \
        "INSENSITIVE INSERT INT INTEGER INTERVAL INTO IO_AFTER_GTIDS " \
        "IO_BEFORE_GTIDS IS ITERATE JOIN JSON_TABLE KEY KEYS KILL LAG " \
        "LAST_VALUE LATERAL LEAD LEADING LEAVE LEFT LIKE LIMIT LINEAR " \
        "LINES LOAD LOCALTIME LOCALTIMESTAMP LOCK LONG LONGBLOB LONGTEXT LOOP " \
        "LOW_PRIORITY MASTER_BIND MASTER_SSL_VERIFY_SERVER_CERT MATCH " \
        "MAXVALUE MEDIUMBLOB MEDIUMINT MEDIUMTEXT MIDDLEINT MINUTE_MICROSECOND " \
        "MINUTE_SECOND MOD MODIFIES NATURAL NOT NO_WRITE_TO_BINLOG NTH_VALUE " \
        "NTILE NULL NUMERIC OF ON OPTIMIZE OPTIMIZER_COSTS OPTION OPTIONALLY " \
        "OR ORDER OUT OUTER OVER PARTITION PERCENT_RANK PRECISION PRIMARY " \
        "PROCEDURE RANGE READ READS READ_WRITE REAL RECURSIVE REFERENCES " \
        "REGEXP RELEASE RENAME REPEAT REPLACE REQUIRE RESIGNAL RESTRICT " \
        "RETURN REVOKE RIGHT RLIKE ROW ROWS ROW_NUMBER SCHEMA SCHEMAS " \
        "SECOND_MICROSECOND SELECT SENSITIVE SEPARATOR SET SHOW SIGNAL " \
        "SMALLINT SPATIAL SPECIFIC SQL SQLEXCEPTION SQLSTATE SQLWARNING " \
        "SQL_BIG_RESULT SQL_CALC_FOUND_ROWS SQL_SMALL_RESULT SSL STARTING " \
        "STORED STRAIGHT_JOIN SYSTEM TABLE TABLES TERMINATED THEN TINYBLOB " \
        "TINYINT TINYTEXT TO TRIGGER TRUE UNDO UNION UNIQUE UNLOCK UNSIGNED " \
        "UPDATE USAGE USE USING UTC_DATE UTC_TIME UTC_TIMESTAMP VALUES " \
        "VARBINARY VARCHAR VARCHARACTER VARYING VIRTUAL WHEN WHERE WHILE " \
        "WINDOW WITH WRITE XOR YEAR_MONTH ZEROFILL", kw_arr, " ")
      for (i = 1; i <= n; i++) is_reserved[kw_arr[i]] = 1
    }
    # Pass 1: collect confirmed aliases from ") [AS] KW ON" patterns
    NR == FNR {
      line = $0
      while (match(line, /\)[ \t]+(AS[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]+ON\b/)) {
        seg = substr(line, RSTART, RLENGTH)
        sub(/^\)[ \t]+/, "", seg)
        sub(/^[Aa][Ss][ \t]+/, "", seg)
        sub(/[ \t]+ON$/, "", seg)
        seg_up = toupper(seg)
        if (seg_up in is_reserved) {
          confirmed[seg_up] = seg
        }
        line = substr(line, RSTART + RLENGTH)
      }
      next
    }
    # Pass 2: rename only confirmed aliases (string-aware — skip string literals)
    {
      out = ""
      rest = $0
      in_str = 0
      n = length(rest)
      i = 1
      while (i <= n) {
        c = substr(rest, i, 1)
        if (in_str) {
          out = out c
          if (c == q) {
            nx = substr(rest, i+1, 1)
            if (nx == q) { out = out nx; i += 2; continue }
            in_str = 0
          }
          i++
          continue
        }
        if (c == q) {
          out = out c
          in_str = 1
          i++
          continue
        }
        # Try to match ") [AS] KW ON" at position i
        if (c == ")") {
          m = match(substr(rest, i), /^\)[ \t]+(AS[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]+ON\b/)
          if (m > 0) {
            seg = substr(rest, i, RLENGTH)
            tmp = seg
            has_as = (tmp ~ /\)[ \t]+AS[ \t]+/i)
            sub(/^\)[ \t]+/, "", tmp)
            sub(/^[Aa][Ss][ \t]+/, "", tmp)
            sub(/[ \t]+ON$/, "", tmp)
            tmp_up = toupper(tmp)
            if (tmp_up in confirmed) {
              if (has_as)
                out = out ") AS " tmp "_ ON"
              else
                out = out ") " tmp "_ ON"
              i += RLENGTH
              continue
            }
          }
        }
        # Try to match "KW." at position i (word-start)
        if (c ~ /[A-Za-z_]/) {
          j = i
          while (j <= n && substr(rest, j, 1) ~ /[A-Za-z0-9_]/) j++
          word = substr(rest, i, j - i)
          word_up = toupper(word)
          after = substr(rest, j, 1)
          if (after == "." && word_up in confirmed) {
            out = out word "_."
            i = j + 1
            continue
          }
        }
        out = out c
        i++
      }
      print out
    }
  ' "$tmp" "$tmp"
  rm -f "$tmp"
}

# 已知 Oracle↔MySQL 语义差的忠实版自动转换（架构师决策：已知语义差→忠实修、默认开启；
# 未知结构失败→留 TODO 走 fail 清单）。
#   DECODE(expr,s1,r1,...,[default]) → CASE WHEN expr<=>s1 THEN r1 ... [ELSE default] END
#     （MySQL null-safe <=> 等价于 DECODE 的 NULL=NULL；TiDB 支持 <=>，比手搓 IS NULL 干净）。
#   a || b || c → COALESCE(CONCAT(IFNULL(a,''),IFNULL(b,''),IFNULL(c,'')),'')
#     （Oracle || 对 NULL 不敏感；MySQL CONCAT 传播 NULL，故内层 IFNULL；外层 COALESCE 确保 NULL→空串，防止 || 拼接传播 NULL）。
# char 级扫描跟踪字符串字面量（'' 转义）+ () 深度，只动 CODE 不动数据；转换不了的（跨行 /
# 操作数边界不可靠 / 混运算符）原样保留并注入 TODO，绝不静默。
_convert_known_semantics() {
  gawk '
    BEGIN { q = sprintf("%c", 39) }
    function trim(s){ sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s); return s }
    # 抹掉字符串字面量（含 '' 转义），用于 unsafe 判定——避免字面量里的 = + - 等
    # 字符被当成运算符误判 || 链 unsafe（如 v_ename||'='||v_sal 里的 '='）。
    function strip_str(s,   r,n,i,c,nx,instr){ n=length(s); r=""; i=1; instr=0; while(i<=n){ c=substr(s,i,1); if(instr){ if(c==q){ nx=substr(s,i+1,1); if(nx==q){ i+=2; continue } else { instr=0; i++; continue } }; i++; continue } if(c==q){ instr=1; i++; continue } r=r c; i++ } return r }
    function match_paren(s, op,   n,i,depth,c,in_str,nx){
      n=length(s); depth=0; in_str=0
      for(i=op;i<=n;i++){
        c=substr(s,i,1)
        if(in_str){ if(c==q){ nx=substr(s,i+1,1); if(nx==q){i++;continue} else in_str=0 } continue }
        if(c==q){ in_str=1; continue }
        if(c=="(") depth++
        else if(c==")"){ depth--; if(depth==0) return i }
      }
      return 0
    }
    function split_topcomma(s, A,   n,i,c,depth,in_str,cur,cnt,nx){
      n=length(s); depth=0; in_str=0; cur=""; cnt=0
      for(i=1;i<=n;i++){
        c=substr(s,i,1)
        if(in_str){ cur=cur c; if(c==q){ nx=substr(s,i+1,1); if(nx==q){cur=cur nx; i++;continue} else in_str=0 } continue }
        if(c==q){ in_str=1; cur=cur c; continue }
        if(c=="("){ depth++; cur=cur c; continue }
        if(c==")"){ depth--; cur=cur c; continue }
        if(c=="," && depth==0){ cnt++; A[cnt]=cur; cur=""; continue }
        cur=cur c
      }
      cnt++; A[cnt]=cur
      for(i=1;i<=cnt;i++) A[i]=trim(A[i])
      return cnt
    }
    function split_pipes(s, A,   n,i,c,depth,in_str,cur,cnt,nx){
      n=length(s); depth=0; in_str=0; cur=""; cnt=0
      for(i=1;i<=n;i++){
        c=substr(s,i,1)
        if(in_str){ cur=cur c; if(c==q){ nx=substr(s,i+1,1); if(nx==q){cur=cur nx; i++;continue} else in_str=0 } continue }
        if(c==q){ in_str=1; cur=cur c; continue }
        if(c=="("){ depth++; cur=cur c; continue }
        if(c==")"){ depth--; cur=cur c; continue }
        if(c=="|" && depth==0 && substr(s,i+1,1)=="|"){ cnt++; A[cnt]=cur; cur=""; i++; continue }
        cur=cur c
      }
      cnt++; A[cnt]=cur
      return cnt
    }
    # has_unclosed_decode: 检查行中是否有 DECODE( 的括号未闭合（跨行标志）
    # 逐字符扫描，跳过字符串字面量，找到 DECODE 后的 ( 检查 match_paren 是否闭合
    function has_unclosed_decode(s,   n,i,c,pos,cpos,epos,in_str,nx,depth){
      n=length(s); in_str=0; depth=0
      i=1
      while(i<=n){
        c=substr(s,i,1)
        if(in_str){ if(c==q){ nx=substr(s,i+1,1); if(nx==q){i++;continue} else in_str=0 } i++; continue }
        if(c==q){ in_str=1; i++; continue }
        if(c=="(") depth++
        else if(c==")") depth--
        # 检测 DECODE( 关键字（跳过被标识符字符前导的）
        if(depth>=0 && toupper(substr(s,i,6))=="DECODE"){
          pos=i
          # 确认是独立关键字（前面非标识符字符）
          if(pos==1 || substr(s,pos-1,1) !~ /[A-Za-z0-9_]/){
            # 找到 DECODE 后的 ( （允许空格）
            cpos=i+6
            while(cpos<=n && (substr(s,cpos,1)==" "||substr(s,cpos,1)=="\t")) cpos++
            if(cpos<=n && substr(s,cpos,1)=="("){
              epos=match_paren(s,cpos)
              if(epos==0) return 1  # 未闭合的 DECODE
              i=epos+1; continue  # 已闭合，跳过
            }
          }
        }
        i++
      }
      return 0
    }
    function conv_decode(line,   out,pos,prev,cpos,epos,mid,A,n,i,expr,cs){
      out=""
      while(match(line,/[Dd][Ee][Cc][Oo][Dd][Ee][ \t]*\(/)){
        pos=RSTART
        if(pos>1){ prev=substr(line,pos-1,1); if(prev~/[A-Za-z0-9_]/){ out=out substr(line,1,pos); line=substr(line,pos+1); continue } }
        cpos=pos+RLENGTH-1
        epos=match_paren(line,cpos)
        if(epos==0){ todo=todo "DECODE 跨行需人工 CASE; "; out=out line; return out }
        mid=substr(line,cpos+1,epos-cpos-1)
        n=split_topcomma(mid,A)
        if(n<3){ out=out substr(line,1,epos); line=substr(line,epos+1); continue }
        expr=A[1]; cs="CASE"; i=2
        while(i+1<=n){ cs=cs " WHEN " expr " <=> " A[i] " THEN " A[i+1]; i+=2 }
        if(i<=n) cs=cs " ELSE " A[i]
        cs=cs " END"
        out=out substr(line,1,pos-1)
        line=cs substr(line,epos+1)
      }
      return out line
    }
    # scan_concat: 字符级扫描行，找到第一个 || 链并返回 [prefix, chain, suffix]。
    # prefix = 链前的所有字符（含 := 或关键字前缀），chain = 完整 || 链表达式，
    # suffix = 链后字符（含终止符 ; ) , 等）。
    # 返回 1 表示找到可处理的链，0 表示无。
    # 设置全局 _concat_prefix / _concat_chain / _concat_suffix。
    function scan_concat(s,   n,i,c,in_str,nx,depth,pp1,chain_start,chain_end,c2,after_pipe){
      n=length(s); in_str=0; depth=0
      # 1. 正向扫描找到第一个 depth==0 的 ||
      pp1=0
      for(i=1;i<=n;i++){
        c=substr(s,i,1)
        if(in_str){ if(c==q){ nx=substr(s,i+1,1); if(nx==q){ i++; continue } else in_str=0 } continue }
        if(c==q){ in_str=1; continue }
        if(c=="(") depth++
        else if(c==")") depth--
        else if(depth==0 && c=="|" && i<n && substr(s,i+1,1)=="|"){ pp1=i; break }
      }
      if(pp1==0) return 0

      # 2. 从 pp1 向前找链起始：回扫到前缀边界（:= / 关键字 / 行首 / 分隔符）
      chain_start=pp1
      in_str=0; depth=0
      i=pp1-1
      # 跳过空格
      while(i>=1 && (substr(s,i,1)==" "||substr(s,i,1)=="\t")) i--
      # 向前扫描第一个 operand
      # operand 可以是：字符串字面量、标识符/函数调用、数字、(括号表达式)
      while(i>=1){
        c=substr(s,i,1)
        if(c==")"){ depth++; chain_start=i; i--; continue }
        if(c=="("){ if(depth>0){ depth--; chain_start=i; i--; continue } else break }
        if(depth>0){ chain_start=i; i--; continue }
        # depth==0
        if(c=="|"){
          # 可能是前一个 || 的尾 | ——说明前面还有 || 对
          if(i>=2 && substr(s,i-1,1)=="|"){ i-=2; while(i>=1 && (substr(s,i,1)==" "||substr(s,i,1)=="\t")) i--; continue }
          break
        }
        if(c==q){
          # 字符串字面量结尾——回扫匹配开头
          i--
          while(i>=1){
            if(substr(s,i,1)==q){ nx=substr(s,i-1,1); if(nx==q){ i-=2; continue } else { i--; break } }
            i--
          }
          chain_start=i+1
          # 字符串前可能有更多 operand 或前缀
          while(i>=1 && (substr(s,i,1)==" "||substr(s,i,1)=="\t")) i--
          if(i>=1 && substr(s,i,1)=="|"){ continue }
          break
        }
        if(c==","||c==";"||c=="("||c=="\t"){ break }
        if(c==" "){
          # 检查前面是否是 || 或关键字前缀
          j=i-1
          while(j>=1 && (substr(s,j,1)==" "||substr(s,j,1)=="\t")) j--
          if(j>=1 && substr(s,j,1)=="|"){ continue }
          break
        }
        chain_start=i
        i--
      }
      # 跳过链起始前导空格
      while(chain_start<pp1 && (substr(s,chain_start,1)==" "||substr(s,chain_start,1)=="\t")) chain_start++

      # 3. 从 pp1 向后找链结束
      chain_end=pp1+1  # 第二个 |
      in_str=0; depth=0
      i=pp1+2  # 第一个 || 之后
      while(i<=n){
        c=substr(s,i,1)
        if(in_str){ chain_end=i; if(c==q){ nx=substr(s,i+1,1); if(nx==q){ i+=2; continue } else in_str=0 } i++; continue }
        if(c==q){ in_str=1; chain_end=i; i++; continue }
        if(c=="(") depth++
        else if(c==")"){
          if(depth==0){ chain_end=i-1; break }  # 退出链包裹的括号（如 IF(x||y)）
          depth--
        }
        else if(depth==0 && c=="|" && i<n && substr(s,i+1,1)=="|"){
          i+=2; continue  # 下一个 ||
        }
        if(depth==0 && (c==";"||c==",")){ chain_end=i-1; break }
        chain_end=i
        i++
      }
      # trim trailing whitespace from chain
      while(chain_end>chain_start && (substr(s,chain_end,1)==" "||substr(s,chain_end,1)=="\t")) chain_end--

      _concat_prefix=substr(s,1,chain_start-1)
      _concat_chain=substr(s,chain_start,chain_end-chain_start+1)
      _concat_suffix=substr(s,chain_end+1)
      # P5-c: 检查链内字符串是否闭合（引号成对）——用于允许行末 || 链
      _concat_chain_balanced=1
      { nq=0; in_str=0; for(_i=1;_i<=length(_concat_chain);_i++){ _c=substr(_concat_chain,_i,1); if(in_str){ if(_c==q){ _nx=substr(_concat_chain,_i+1,1); if(_nx==q){ _i++; continue } else in_str=0 } continue } if(_c==q) in_str=1 } if(in_str) _concat_chain_balanced=0 }
      return 1
    }
    function conv_concat(line,   out,A,n,i,inner,cs,unsafe,ss,found){
      out=""
      while((found=scan_concat(line))){
        # suffix 须以 ;/) /, 终结（非裸 EOL）：裸 EOL = 多行续行
        # P5-c: 但若 suffix 为空且 chain 内字符串已闭合，则允许行末 || 链
        if(_concat_suffix !~ /^[ \t]*[;),]/){
          if(_concat_suffix ~ /^[ \t]*$/ && _concat_chain_balanced){
            # 允许：链完整且行末终止
          } else {
            pipe_info=pipe_info "|| 跨行续行保留字面，依赖 PIPES_AS_CONCAT; "
            out=out _concat_prefix _concat_chain
            line=_concat_suffix
            continue
          }
        }
        n=split_pipes(_concat_chain,A)
        if(n<2){ out=out _concat_prefix _concat_chain; line=_concat_suffix; continue }
        unsafe=0
        for(i=1;i<=n;i++){ ss=strip_str(A[i]); if(ss ~ /[+\-*/=<>]/ || ss ~ /(^|[^A-Za-z0-9_])(AND|OR|NOT|FROM|WHERE|SELECT|INTO|VALUES|THEN|ELSE|WHEN|CASE|END)([^A-Za-z0-9_]|$)/){ unsafe=1; break } }
        if(unsafe){ pipe_info=pipe_info "|| 操作数边界不可靠保留字面，依赖 PIPES_AS_CONCAT; "; out=out _concat_prefix _concat_chain; line=_concat_suffix; continue }
        inner=""
        for(i=1;i<=n;i++){ inner=(i==1?"":inner ", ") "IFNULL(" trim(A[i]) "," q q ")" }
        cs="COALESCE(CONCAT(" inner ")," q q ")"
        out=out _concat_prefix cs
        line=_concat_suffix
      }
      return out line
    }
    # NVL2(a,b,c) → IF(a IS NOT NULL, b, c)（a 非 NULL 返回 b，否则 c）。3 参，按括号深度切分。
    function conv_nvl2(line,   out,pos,prev,cpos,epos,mid,A,n){
      out=""
      while(match(line,/NVL2[ \t]*\(/)){
        pos=RSTART
        if(pos>1){ prev=substr(line,pos-1,1); if(prev~/[A-Za-z0-9_]/){ out=out substr(line,1,pos); line=substr(line,pos+1); continue } }
        cpos=pos+RLENGTH-1; epos=match_paren(line,cpos)
        if(epos==0){ todo=todo "NVL2 跨行需人工 IF; "; out=out line; return out }
        mid=substr(line,cpos+1,epos-cpos-1); n=split_topcomma(mid,A)
        if(n!=3){ out=out substr(line,1,epos); line=substr(line,epos+1); continue }
        out=out substr(line,1,pos-1) "IF(" trim(A[1]) " IS NOT NULL, " trim(A[2]) ", " trim(A[3]) ")"
        line=substr(line,epos+1)
      }
      return out line
    }
    # ADD_MONTHS(d,n) → DATE_ADD(d, INTERVAL n MONTH)。2 参。
    function conv_add_months(line,   out,pos,prev,cpos,epos,mid,A,n){
      out=""
      while(match(line,/ADD_MONTHS[ \t]*\(/)){
        pos=RSTART
        if(pos>1){ prev=substr(line,pos-1,1); if(prev~/[A-Za-z0-9_]/){ out=out substr(line,1,pos); line=substr(line,pos+1); continue } }
        cpos=pos+RLENGTH-1; epos=match_paren(line,cpos)
        if(epos==0){ todo=todo "ADD_MONTHS 跨行需人工 DATE_ADD; "; out=out line; return out }
        mid=substr(line,cpos+1,epos-cpos-1); n=split_topcomma(mid,A)
        if(n!=2){ out=out substr(line,1,epos); line=substr(line,epos+1); continue }
        out=out substr(line,1,pos-1) "DATE_ADD(" trim(A[1]) ", INTERVAL " trim(A[2]) " MONTH)"
        line=substr(line,epos+1)
      }
      return out line
    }
    # MONTHS_BETWEEN(a,b) → TIMESTAMPDIFF(MONTH, b, a)——⚠️参数位置反转（Oracle(end,start) vs TiDB(unit,start,end)）。
    function conv_months_between(line,   out,pos,prev,cpos,epos,mid,A,n){
      out=""
      while(match(line,/MONTHS_BETWEEN[ \t]*\(/)){
        pos=RSTART
        if(pos>1){ prev=substr(line,pos-1,1); if(prev~/[A-Za-z0-9_]/){ out=out substr(line,1,pos); line=substr(line,pos+1); continue } }
        cpos=pos+RLENGTH-1; epos=match_paren(line,cpos)
        if(epos==0){ todo=todo "MONTHS_BETWEEN 跨行需人工 TIMESTAMPDIFF; "; out=out line; return out }
        mid=substr(line,cpos+1,epos-cpos-1); n=split_topcomma(mid,A)
        if(n!=2){ out=out substr(line,1,epos); line=substr(line,epos+1); continue }
        out=out substr(line,1,pos-1) "TIMESTAMPDIFF(MONTH, " trim(A[2]) ", " trim(A[1]) ")"
        line=substr(line,epos+1)
      }
      return out line
    }
    # LISTAGG(expr, sep) WITHIN GROUP (ORDER BY ...) → GROUP_CONCAT(expr ORDER BY ... SEPARATOR sep)
    # 单行匹配。OVER (PARTITION BY...) 分析函数形式标 TODO（MySQL GROUP_CONCAT 无分析函数支持）。
    function conv_listagg(line,   out,pos,prev,cpos,epos,mid,A,n,wg_start,wg_end,wg_inner,
                          ob_start,ob_end,orderby,expr,sep,repl,rest,over_idx){
      out=""
      while(match(line,/LISTAGG[ \t]*\(/)){
        pos=RSTART
        if(pos>1){ prev=substr(line,pos-1,1); if(prev~/[A-Za-z0-9_]/){ out=out substr(line,1,pos); line=substr(line,pos+1); continue } }
        cpos=pos+RLENGTH-1; epos=match_paren(line,cpos)
        # 跨行 LISTAGG（括号不配对）→ 不在此处理，留 _mark_complex 统一检测
        if(epos==0){ out=out substr(line,1,pos); line=substr(line,pos+1); continue }
        mid=substr(line,cpos+1,epos-cpos-1); n=split_topcomma(mid,A)
        # 动态 SQL 内 LISTAGG(col, '','') 的 '' 转义：split_topcomma 将 '','' 误拆为两个空串
        # n==3 且 A[2]=='' 和 A[3]=='' → 合并为 n==2, A[2]='',''（动态 SQL 中的逗号分隔符，保留转义）
        if(n==3 && A[2]==q q && A[3]==q q){ n=2; A[2]=q q "," q q }
        if(n<1 || n>2){ out=out substr(line,1,epos); line=substr(line,epos+1); continue }
        expr=trim(A[1])
        has_sep=(n==2)
        sep=(has_sep ? trim(A[2]) : q q)
        sep_clause=(has_sep ? " SEPARATOR " sep : "")
        rest=substr(line,epos+1)
        # 必须跟 WITHIN GROUP (ORDER BY ...)
        if(match(rest,/^[ \t]*WITHIN[ \t]+GROUP[ \t]*\(/)){
          wg_start=RSTART
          wg_inner_start=epos+wg_start+RLENGTH-1   # 指向 ORDER BY 的 (
          wg_end=match_paren(rest, wg_start+RLENGTH-1)
          if(wg_end==0){ todo=todo "LISTAGG WITHIN GROUP 括号不配对需人工; "; out=out substr(line,1,epos); line=rest; continue }
          wg_inner=substr(rest, wg_start+RLENGTH, wg_end-wg_start-RLENGTH)
          # wg_inner 应为 "ORDER BY sortcol [DESC|ASC]"（大小写不敏感）
          if(match(toupper(wg_inner),/^[ \t]*ORDER[ \t]+BY[ \t]+/)){
            orderby=substr(wg_inner,RLENGTH+1)
            gsub(/^[ \t]+|[ \t]+$/,"",orderby)
          } else {
            orderby=wg_inner   # 非 ORDER BY 开头，原样保留
          }
          # 检查 OVER (PARTITION BY ...) 分析函数形式
          over_rest=substr(rest, wg_end+1)
          if(match(over_rest,/^[ \t]*OVER[ \t]*\(/)){
            todo=todo "LISTAGG OVER(PARTITION BY) 分析函数 MySQL GROUP_CONCAT 不支持，需人工; "
            out=out substr(line,1,epos); line=rest; continue
          }
          # 生成 GROUP_CONCAT(expr ORDER BY orderby [SEPARATOR sep])
          repl="GROUP_CONCAT(" expr " ORDER BY " orderby sep_clause ")"
          out=out substr(line,1,pos-1) repl
          line=substr(rest, wg_end+1)
        } else {
          # LISTAGG 不带 WITHIN GROUP → 直接转 GROUP_CONCAT（无 ORDER BY）；
          # 检查 OVER (PARTITION BY ...) 分析函数形式
          if(match(rest,/^[ \t]*OVER[ \t]*\(/)){
            todo=todo "LISTAGG OVER(PARTITION BY) 分析函数 MySQL GROUP_CONCAT 不支持，需人工; "
            out=out substr(line,1,epos); line=rest; continue
          }
          repl="GROUP_CONCAT(" expr sep_clause ")"
          if (!has_sep) todo=todo "LISTAGG 无分隔符: MySQL GROUP_CONCAT 默认逗号(vs Oracle 空串), 动态 SQL 内省略 SEPARATOR 避免引号转义; "
          out=out substr(line,1,pos-1) repl
          line=rest
        }
      }
      return out line
    }
    # P5-c: 检测未闭合的 || 字符串跨行——|| 后的字符串字面量未闭合，需缓冲后续行
    function has_unclosed_concat(s,   n,i,c,in_str,nx,last_pipe_pos){
      n=length(s); in_str=0; last_pipe_pos=0
      for(i=1;i<=n;i++){
        c=substr(s,i,1)
        if(in_str){ if(c==q){ nx=substr(s,i+1,1); if(nx==q){ i++; continue } else in_str=0 } continue }
        if(c==q){ in_str=1; continue }
        if(c=="|" && i<n && substr(s,i+1,1)=="|"){ last_pipe_pos=i; i++; continue }
      }
      if(last_pipe_pos==0) return 0
      # 检查 last_pipe_pos+2 之后是否有未闭合的字符串字面量
      in_str=0
      for(i=last_pipe_pos+2; i<=n; i++){
        c=substr(s,i,1)
        if(in_str){ if(c==q){ nx=substr(s,i+1,1); if(nx==q){ i++; continue } else in_str=0 } continue }
        if(c==q){ in_str=1 }
      }
      return in_str  # 1 = 字符串未闭合
    }
    function code_has_pipe(s,   n,i,c,depth,in_str,nx){
      n=length(s); depth=0; in_str=0
      for(i=1;i<=n;i++){
        c=substr(s,i,1)
        if(in_str){ if(c==q){ nx=substr(s,i+1,1); if(nx==q){i++;continue} else in_str=0 } continue }
        if(c==q){ in_str=1; continue }
        if(c=="(") depth++
        else if(c==")") depth--
        else if(c=="|" && depth==0 && substr(s,i+1,1)=="|") return 1
      }
      return 0
    }
    function code_has_decode(s,   n,i,c,depth,in_str,nx){
      n=length(s); depth=0; in_str=0
      for(i=1;i<=n;i++){
        c=substr(s,i,1)
        if(in_str){ if(c==q){ nx=substr(s,i+1,1); if(nx==q){i++;continue} else in_str=0 } continue }
        if(c==q){ in_str=1; continue }
        if(c=="|" && substr(s,i+1,1)=="|") continue
        if(depth==0 && i<=n-6 && toupper(substr(s,i,6))=="DECODE" && substr(s,i+6,1) ~ /[ \t]/ && substr(s,i+7,1)=="(") return 1
        if(depth==0 && i<=n-7 && toupper(substr(s,i,7))=="DECODE(") return 1
        if(c=="(") depth++
        else if(c==")") depth--
      }
      return 0
    }
    {
      line=$0
      if(line ~ /^[ \t]*--/){ print line; next }
      todo=""
      pipe_info=""
      # P2-c: 跨行 DECODE 归一化——检测未闭合的 DECODE(，缓冲后续行直到括号闭合
      if(has_unclosed_decode(line)){
        _dj=line; _dn=1
        while(_dn < 50 && has_unclosed_decode(_dj)){
          if((getline _dnx) <= 0) break
          _dn++
          if(_dnx ~ /^[ \t]*--/){ print _dnx; continue }
          _dj=_dj " " _dnx
        }
        line=_dj
      }
      # P5-c: 跨行 || 链归一化——检测未闭合的字符串字面量（|| 后字符串跨行），缓冲直到闭合
      if(has_unclosed_concat(line)){
        _cj=line; _cn=1
        while(_cn < 20 && has_unclosed_concat(_cj)){
          if((getline _cnx) <= 0) break
          _cn++
          if(_cnx ~ /^[ \t]*--/){ print _cnx; continue }
          _cj=_cj " " _cnx
        }
        line=_cj
      }
      line=conv_decode(line)
      line=conv_concat(line)
      line=conv_nvl2(line)
      line=conv_add_months(line)
      line=conv_months_between(line)
      line=conv_listagg(line)
      if(code_has_pipe(line))   pipe_info="|| 拼接保留字面（SQL 字符串值内/跨行/操作数不可靠），依赖 PIPES_AS_CONCAT（CREATE 时锁定，TiDB v7.1.9 默认已含）; "
      if(code_has_decode(line)) todo=todo "DECODE 未能自动转换（跨行/畸形），需人工 CASE; "
      if(pipe_info != "") print "-- INFO: " pipe_info
      if(todo != "") print "-- TODO(需人工转换): " todo
      print line
    }
  '
}

# TO_CHAR(date,'mask')→DATE_FORMAT(date,'%mask')：clean-auto（确定性掩码映射，对齐设计文档 §5.2）。
# 仅处理第一参数无逗号/括号的常见形态；剩余 TO_CHAR(number/复杂)/TO_DATE(复杂) 由 _mark_complex 标 TODO。
# 同时覆盖 TO_CHAR(date,'mask')→DATE_FORMAT 与 TO_DATE(str,'mask')→STR_TO_DATE（mask 映射同）。
# 必须在 _apply_mechanical（SYSDATE→NOW）之前跑，否则 NOW() 带括号匹配不到。
_tochar_date() {
  awk '
    BEGIN { q = sprintf("%c", 39) }
    function match_paren(s, op,   n,i,depth,c,in_str,nx){
      n=length(s); depth=0; in_str=0
      for(i=op;i<=n;i++){
        c=substr(s,i,1)
        if(in_str){ if(c==q){ nx=substr(s,i+1,1); if(nx==q){i++;continue} else in_str=0 } continue }
        if(c==q){ in_str=1; continue }
        if(c=="(") depth++
        else if(c==")"){ depth--; if(depth==0) return i }
      }
      return 0
    }
    function split_topcomma(s, A,   n,i,c,depth,in_str,cur,cnt,nx){
      n=length(s); depth=0; in_str=0; cur=""; cnt=0
      for(i=1;i<=n;i++){
        c=substr(s,i,1)
        if(in_str){ cur=cur c; if(c==q){ nx=substr(s,i+1,1); if(nx==q){cur=cur nx; i++;continue} else in_str=0 } continue }
        if(c==q){ in_str=1; cur=cur c; continue }
        if(c=="("){ depth++; cur=cur c; continue }
        if(c==")"){ depth--; cur=cur c; continue }
        if(c=="," && depth==0){ cnt++; A[cnt]=cur; cur=""; continue }
        cur=cur c
      }
      cnt++; A[cnt]=cur
      return cnt
    }
    function trim(s){ sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s); return s }
    function mapmask(s,   r) {
      r = s
      gsub(/YYYY/, "%Y", r); gsub(/YY/, "%y", r)
      gsub(/MONTH/, "%M", r); gsub(/MON/, "%b", r); gsub(/MM/, "%m", r)
      gsub(/DD/, "%d", r)
      gsub(/HH24/, "%H", r); gsub(/HH12/, "%h", r); gsub(/HH/, "%H", r)
      gsub(/MI/, "%i", r); gsub(/SS/, "%s", r)
      return r
    }
    {
      if ($0 ~ /^[ \t]*--/) { print; next }
      out=""
      line=$0
      while (match(line, /(TO_CHAR|TO_DATE)[ \t]*\(/)) {
        pos=RSTART
        # 跳过被标识符字符前导的（如 MY_TO_CHAR(）
        if(pos>1){ prev=substr(line,pos-1,1); if(prev~/[A-Za-z0-9_]/){ out=out substr(line,1,pos); line=substr(line,pos+1); continue } }
        kw=substr(line,pos,RLENGTH)
        cpos=pos+RLENGTH-1
        epos=match_paren(line,cpos)
        if(epos==0){ break }  # 跨行，留给后续 pass
        mid=substr(line,cpos+1,epos-cpos-1)
        n=split_topcomma(mid,A)
        if(n!=2){ out=out substr(line,1,epos); line=substr(line,epos+1); continue }
        arg1=trim(A[1]); arg2=trim(A[2])
        # 第二参数须是字符串字面量（日期掩码）
        if(substr(arg2,1,1)!=q) { out=out substr(line,1,epos); line=substr(line,epos+1); continue }
        # 检测是否在动态 SQL 字符串内（掩码用 '' 转义，即开头是 ''）
        dq = (substr(arg2,1,2) == q q)
        m=arg2; gsub(q,"",m)
        mm=mapmask(m)
        if(mm==m){ out=out substr(line,1,epos); line=substr(line,epos+1); continue }  # 无日期 token → 跳过，继续扫描后续
        fn=(substr(kw,1,6)=="TO_DAT") ? "STR_TO_DATE" : "DATE_FORMAT"
        # 动态 SQL 内保持 '' 转义，否则用单引号
        qq = dq ? (q q) : q
        rep=fn "(" arg1 ", " qq mm qq ")"
        out=out substr(line,1,pos-1) rep
        line=substr(line,epos+1)
      }
      print out line
    }
  '
}

# 头部行清洗：双引号标识符 → 反引号；去 owner. 前缀。仅作用于 CREATE [OR REPLACE] PROCEDURE/FUNCTION 行
# （头部行无字符串字面量，故引号转换安全；避免对过程体内字符串做全局误转）。
_fix_header() {
  sed -E '/^[[:space:]]*create[[:space:]]+(or[[:space:]]+replace[[:space:]]+)?(procedure|function)[[:space:]]+/I{
    s/"([A-Za-z_][A-Za-z0-9_.#$]*)"/`\1`/g
    s/((procedure|function)[[:space:]]+)`[^`]+`\./\1/Ig
  }'
}

# Phase 1 类型推断 pass（架构师 spec：本地 symtab + infer_type，解锁 TRUNC/INSTR/TO_NUMBER/TO_CHAR(num)/
# SUBSTR(0-offset)/NEXTVAL）。置 _restructure 后：此时声明已 MySQL `DECLARE v TYPE;`、body 已 MySQL 形态。
# 两遍 awk：① 扫 DECLARE 行 + CREATE 头参数建 symtab {var→typeclass}；② 按规则转 body，不确定→注 `-- TODO(需人工)`（非静默）。
# typeclass：number/date/string/bool；schema 列/复杂/未声明=unknown→NOTE（Phase 3 schema 内省后才解列）。
# 边界（架构师）：TRUNC(num,digits)→TRUNCATE(num,digits) 透传 digits；INSTR 负 start（反向搜索）→NOTE 不透传 LOCATE。
# date-arith（date1-date2/date+n）无关键字、需表达式解析，本批 defer。
_convert_type_aware() {
  awk '
    BEGIN { q = sprintf("%c", 39); inhdr=0; hdrdepth=0 }
    function trim(s){ sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s); return s }
    function typeclass(t,   tl){ tl=toupper(t); sub(/\(.*$/,"",tl)
      if (tl ~ /^(DECIMAL|NUMERIC|INT|INTEGER|BIGINT|SMALLINT|TINYINT|MEDIUMINT|FLOAT|DOUBLE|PLS_INTEGER|BINARY_INTEGER|SIMPLE_INTEGER)$/) return "number"
      if (tl ~ /^(DATE|DATETIME|TIMESTAMP|TIME)$/) return "date"
      if (tl ~ /^(VARCHAR|CHAR|TEXT|CLOB|NVARCHAR|NCHAR|BLOB|BINARY|VARBINARY)$/) return "string"
      if (tl ~ /^(BOOL|BOOLEAN)$/) return "bool"
      return "" }
    function match_paren(s,op,   n,i,depth,c,in_str,nx){ n=length(s); depth=0; in_str=0
      for(i=op;i<=n;i++){ c=substr(s,i,1)
        if(in_str){ if(c==q){ nx=substr(s,i+1,1); if(nx==q){i++;continue} else in_str=0 } continue }
        if(c==q){ in_str=1; continue }
        if(c=="(")depth++; else if(c==")"){depth--; if(depth==0)return i} }
      return 0 }
    function split_topcomma(s,A,   n,i,c,depth,in_str,cur,cnt,nx){ n=length(s);depth=0;in_str=0;cur="";cnt=0
      for(i=1;i<=n;i++){ c=substr(s,i,1)
        if(in_str){ cur=cur c; if(c==q){ nx=substr(s,i+1,1); if(nx==q){cur=cur nx; i++;continue} else in_str=0 } continue }
        if(c==q){ in_str=1; cur=cur c; continue }
        if(c=="(")depth++; else if(c==")")depth--
        else if(c==","&&depth==0){cnt++;A[cnt]=trim(cur);cur="";continue}
        cur=cur c }
      cnt++; A[cnt]=trim(cur); return cnt }
    function infer_type(e,   ee,h){
      ee=trim(e); if(ee=="") return "unknown"
      if (ee in type) return type[ee]
      if (ee=="NULL") return "unknown"
      if (substr(ee,1,1)==q) return "string"
      if (ee ~ /^[-+]?[0-9]+(\.[0-9]+)?$/) return "number"
      h=toupper(ee)
      if (h ~ /^(SYSDATE|NOW\(\)|CURRENT_TIMESTAMP(\([0-9]*\))?|CURRENT_DATE(\(\))?|SYSTIMESTAMP)$/) return "date"
      if (h ~ /^(TO_DATE|STR_TO_DATE|ADD_MONTHS|DATE_ADD|DATE_SUB|LAST_DAY)\(/) return "date"
      if (h ~ /^(TO_NUMBER|LENGTH|CHAR_LENGTH|INSTR|LOCATE|MOD|ROUND|TRUNCATE|ABS|CEIL|FLOOR|SIGN|POWER|SQRT|DATEDIFF|TIMESTAMPDIFF)\(/) return "number"
      if (h ~ /^(SUBSTR|SUBSTRING|CHR|CHAR|CONCAT|REPLACE|UPPER|LOWER|TRIM|LTRIM|RTRIM|LPAD|RPAD|TO_CHAR)\(/) return "string"
      return "unknown" }
    function reg_pair(p,   vn,tt){    # 输入含前缀 [(,]/DECLARE + 可选 mode + name + type → type[name]=class
      sub(/^[(,][ \t]*/,"",p)                                                        # 去前导 (,
      sub(/^DECLARE[ \t]+/,"",p)                                                     # 去前导 DECLARE
      sub(/^(IN[ \t]+OUT[ \t]+|INOUT[ \t]+|IN[ \t]+|OUT[ \t]+)/,"",p)                # 去参数 mode
      vn=p; sub(/[ \t].*$/,"",vn); tt=p; sub(/^[A-Za-z_][A-Za-z0-9_]*[ \t]+/,"",tt); sub(/[ \t].*$/,"",tt)
      if (typeclass(tt)!="" && !(vn in type)) type[vn]=typeclass(tt) }
    function conv_trunc(line,   out,pos,prev,cpos,epos,mid,A,n,tc,rep){
      out=""
      while(match(line,/TRUNC[ \t]*\(/)){
        pos=RSTART
        if(pos>1){ prev=substr(line,pos-1,1); if(prev~/[A-Za-z0-9_]/){ out=out substr(line,1,pos); line=substr(line,pos+1); continue } }
        cpos=pos+RLENGTH-1; epos=match_paren(line,cpos)
        if(epos==0){ note=note "TRUNC 跨行需人工; "; out=out line; return out }
        mid=substr(line,cpos+1,epos-cpos-1); n=split_topcomma(mid,A); rep=substr(line,pos,epos-pos+1)
        if (n==1) { tc=infer_type(A[1])
          if (tc=="number")    rep="TRUNCATE(" A[1] ",0)"
          else if (tc=="date") rep="CAST(" A[1] " AS DATE)"
          else                 { note=note "TRUNC(" A[1] ") 参数类型不可判需人工; "; rep="NULL" }
        } else if (n==2) {
          if (infer_type(A[1])=="number" && infer_type(A[2])=="number") rep="TRUNCATE(" A[1] ", " A[2] ")"
          else { note=note "TRUNC(" A[1] "," A[2] ") 2 参(date+fmt 或混类型)需人工; "; rep="NULL" }
        } else { note=note "TRUNC >2 参需人工; "; rep="NULL" }
        out=out substr(line,1,pos-1) rep; line=substr(line,epos+1)
      }
      return out line }
    function conv_instr(line,   out,pos,prev,cpos,epos,mid,A,n,rep){
      out=""
      while(match(line,/INSTR[ \t]*\(/)){
        pos=RSTART
        if(pos>1){ prev=substr(line,pos-1,1); if(prev~/[A-Za-z0-9_]/){ out=out substr(line,1,pos); line=substr(line,pos+1); continue } }
        cpos=pos+RLENGTH-1; epos=match_paren(line,cpos)
        if(epos==0){ note=note "INSTR 跨行需人工; "; out=out line; return out }
        mid=substr(line,cpos+1,epos-cpos-1); n=split_topcomma(mid,A); rep=substr(line,pos,epos-pos+1)
        if (n==2)      rep="LOCATE(" A[2] ", " A[1] ")"                                  # ⚠️前两参互换 INSTR(s,sub)→LOCATE(sub,s)
        else if (n==3) { if (A[3] ~ /^-/) { note=note "INSTR 负 start(反向搜索) LOCATE 不支持需人工; "; rep="NULL" }
                         else rep="LOCATE(" A[2] ", " A[1] ", " A[3] ")" }
        else           { note=note "INSTR 4 参(nth)无直接等价需人工; "; rep="NULL" }
        out=out substr(line,1,pos-1) rep; line=substr(line,epos+1)
      }
      return out line }
    function conv_to_number(line,   out,pos,prev,cpos,epos,mid,A,n,rep){
      out=""
      while(match(line,/TO_NUMBER[ \t]*\(/)){
        pos=RSTART
        if(pos>1){ prev=substr(line,pos-1,1); if(prev~/[A-Za-z0-9_]/){ out=out substr(line,1,pos); line=substr(line,pos+1); continue } }
        cpos=pos+RLENGTH-1; epos=match_paren(line,cpos)
        if(epos==0){ note=note "TO_NUMBER 跨行需人工; "; out=out line; return out }
        mid=substr(line,cpos+1,epos-cpos-1); n=split_topcomma(mid,A); rep=substr(line,pos,epos-pos+1)
        if (n==1) rep="CAST(" A[1] " AS DECIMAL(65,30))"
        out=out substr(line,1,pos-1) rep; line=substr(line,epos+1)
      }
      return out line }
    function mapmask(s,   r) {
      r = s
      gsub(/YYYY/, "%Y", r); gsub(/YY/, "%y", r)
      gsub(/MONTH/, "%M", r); gsub(/MON/, "%b", r); gsub(/MM/, "%m", r)
      gsub(/DD/, "%d", r)
      gsub(/HH24/, "%H", r); gsub(/HH12/, "%h", r); gsub(/HH/, "%H", r)
      gsub(/MI/, "%i", r); gsub(/SS/, "%s", r)
      return r
    }
    function conv_to_char_num(line,   out,pos,prev,cpos,epos,mid,A,n,tc,rep,mm,m){
      out=""   # TO_CHAR(number) 单参→CAST AS CHAR；TO_CHAR(date,'mask')→DATE_FORMAT
      while(match(line,/TO_CHAR[ \t]*\(/)){
        pos=RSTART
        if(pos>1){ prev=substr(line,pos-1,1); if(prev~/[A-Za-z0-9_]/){ out=out substr(line,1,pos); line=substr(line,pos+1); continue } }
        cpos=pos+RLENGTH-1; epos=match_paren(line,cpos)
        if(epos==0){ note=note "TO_CHAR 跨行需人工; "; out=out line; return out }
        mid=substr(line,cpos+1,epos-cpos-1); n=split_topcomma(mid,A); rep=substr(line,pos,epos-pos+1)
        if (n==1) { if (infer_type(A[1])=="number") rep="CAST(" A[1] " AS CHAR)"; else { note=note "TO_CHAR(" A[1] ") 非 number 单参需人工; "; rep="NULL" } }
        else if (n==2 && substr(A[2],1,1)==q) {
          # TO_CHAR(date_expr, 'mask') → DATE_FORMAT(date_expr, '%mask')（掩码含日期 token 时转）
          dq = (substr(A[2],1,2) == q q)
          m=A[2]; gsub(q,"",m)
          mm=mapmask(m)
          qq = dq ? (q q) : q
          if(mm!=m) rep="DATE_FORMAT(" A[1] ", " qq mm qq ")"
          else { note=note "TO_CHAR(..,..) 多参(number+fmt 或残留 date)需人工; "; rep="NULL" }
        }
        else        { note=note "TO_CHAR(..,..) 多参(number+fmt 或残留 date)需人工; "; rep="NULL" }
        out=out substr(line,1,pos-1) rep; line=substr(line,epos+1)
      }
      return out line }
    function conv_substr(line,   out,pos,prev,cpos,epos,mid,A,n,rep){
      out=""   # SUBSTR(s,0,n)→SUBSTRING(s,1,n)；start>=1 字面量 MySQL SUBSTR 兼容不变；start=变量→透传（Oracle/TiDB SUBSTR 语义一致，均 1-based）
      while(match(line,/SUBSTR[ \t]*\(/)){
        pos=RSTART
        if(pos>1){ prev=substr(line,pos-1,1); if(prev~/[A-Za-z0-9_]/){ out=out substr(line,1,pos); line=substr(line,pos+1); continue } }
        cpos=pos+RLENGTH-1; epos=match_paren(line,cpos)
        if(epos==0){ note=note "SUBSTR 跨行需人工; "; out=out line; return out }
        mid=substr(line,cpos+1,epos-cpos-1); n=split_topcomma(mid,A); rep=substr(line,pos,epos-pos+1)
        if (n>=2) {
          if (A[2]=="0") rep="SUBSTRING(" A[1] ", 1" (n>=3 ? ", " A[3] : "") ")"   # start=0→1，2/3 参通用
          # start 为变量/表达式：Oracle 和 TiDB SUBSTR 语义一致（均 1-based），直接透传不标 TODO
        }
        out=out substr(line,1,pos-1) rep; line=substr(line,epos+1)
      }
      return out line }
    function conv_nextval(line,   out,pos,m,seq){
      out=""   # seq.NEXTVAL → NEXTVAL(seq)
      while(match(line,/[A-Za-z_][A-Za-z0-9_]*\.NEXTVAL/)){
        pos=RSTART; m=substr(line,RSTART,RLENGTH); seq=m; sub(/\.NEXTVAL$/,"",seq)
        out=out substr(line,1,pos-1) "NEXTVAL(" seq ")"; line=substr(line,RSTART+RLENGTH)
      }
      return out line }
    function check_date_arith(line,   v,re){   # 粗粒度 date 算术 NOTE（堵 silent 坑，真正转换留 focused 批）
      for (v in type) { if (type[v]!="date") continue
        re = "(^|[^A-Za-z0-9_])" v "[ \t]*[-+][ \t]*"                       # <datevar> - / +
        if (line ~ re) { note=note "疑似 date 算术(" v "[+-]..)——MySQL 不直接支持 date-date/date+n(date 隐式转数字算错)，需 DATEDIFF/DATE_ADD; "; return }
        re = "[ \t][-+][ \t]*" v "([^A-Za-z0-9_]|$)"                         # ..- / + <datevar>
        if (line ~ re) { note=note "疑似 date 算术(..[+-]" v ")——MySQL date 算术需 DATEDIFF/DATE_ADD; "; return }
      }
    }
    # pass 1：建 symtab（DECLARE 行 + CREATE 头参数），存全部行
    {
      if ($0 ~ /^CREATE[ \t]+(OR[ \t]+REPLACE[ \t]+)?(PROCEDURE|FUNCTION)[ \t]+/) inhdr=1
      if (inhdr) { s=$0
        while (match(s, /(IN[ \t]+OUT[ \t]+|INOUT[ \t]+|IN[ \t]+|OUT[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]+[A-Za-z_][A-Za-z0-9_()]*/)) {
          reg_pair(substr(s,RSTART,RLENGTH)); s=substr(s, RSTART+RLENGTH) }
        # 头参数列表闭合按括号深度判（CREATE 的 `(` 被归零的 `)` 闭合），非任意 `)`——
        # 避开 DECIMAL(65,30)/VARCHAR(4000) 类型精度里的 `)` 误判提前关闭。
        tmp=$0; no=gsub(/\(/,"",tmp); tmp=$0; nc=gsub(/\)/,"",tmp); hdrdepth += no - nc
        if (hdrdepth <= 0) { inhdr=0; hdrdepth=0 }
      }
      if ($0 ~ /^[ \t]*DECLARE[ \t]+[A-Za-z_]/ && $0 !~ /CURSOR|HANDLER|CONDITION/) { s=$0
        if (match(s, /DECLARE[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+[A-Za-z_][A-Za-z0-9_()]*/)) reg_pair(substr(s,RSTART,RLENGTH)) }
      lines[NR]=$0
    }
    END {   # pass 2：类型感知转换 + NOTE
      for (i=1; i<=NR; i++) {
        l=lines[i]; note=""
        if (l ~ /^[ \t]*--/) { print l; continue }
        l=conv_trunc(l); l=conv_instr(l); l=conv_to_number(l); l=conv_to_char_num(l); l=conv_substr(l); l=conv_nextval(l)
        check_date_arith(l)
        if (note != "") print "-- TODO(需人工): " note
        print l
      }
    }
  '
}

# 复杂结构检测：在匹配行上方注入 TODO 注释（保留原行）。
_mark_complex() {
  awk '
    function todo(msg){ print "-- TODO(需人工转换): " msg }
    {
      if ($0 ~ /^[ \t]*--/) { print; prev_line=""; next }
      # 跨行 LISTAGG 检测（conv_listagg 已删 epos==0 分支，跨行 LISTAGG 由此处统一标 TODO）
      # 形态 1：当前行含 LISTAGG（括号不配对/跨行续行，conv_listagg 透传未处理）
      if ($0 ~ /LISTAGG/)              todo("跨行 LISTAGG 需人工 GROUP_CONCAT")
      # 形态 2：上一行含 LISTAGG，当前行才有 WITHIN GROUP（跨行续）
      if (prev_line ~ /LISTAGG/ && $0 ~ /WITHIN[ \t]+GROUP/) todo("跨行 LISTAGG WITHIN GROUP 需人工 GROUP_CONCAT")
      # 形态 3：上一行含 LISTAGG/GROUP_CONCAT，当前行才是 OVER (...)—分析函数形式 MySQL 不支持
      if (prev_line ~ /(LISTAGG|GROUP_CONCAT)/ && $0 ~ /(^|[^A-Za-z0-9_])OVER[ \t]*\(/) todo("LISTAGG OVER(PARTITION BY) 分析函数 MySQL GROUP_CONCAT 不支持，需人工")
      # 注：原 re_emptyif（IFNULL(x,空串) 的 NVL(x,空串) 语义分歧告警）已移除——|| 忠实转换器会
      # 生成 IFNULL(op,'')，与 NVL(x,'') 文本同形、post-mechanical 无法区分，全量标记只会误报每一处
      # ||。NVL(x,'') 分歧属已知 niche 边缘，由文档记录、不在此标记。
      if ($0 ~ /%TYPE|%ROWTYPE/)                 todo("锚定类型 %TYPE/%ROWTYPE 需解析为具体类型")
      # REF CURSOR 类型声明：TYPE x IS REF CURSOR → 删除（TiDB 不支持类型声明，P2-d 自动处理）
      if ($0 ~ /^[ \t]*TYPE[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+IS[ \t]+REF[ \t]+CURSOR/) { print "-- INFO: REF CURSOR 类型声明已删除（TiDB 不支持 TYPE 声明，SP 直接返回最后 SELECT 结果集）"; prev_line=$0; next }
      # 注：EXECUTE IMMEDIATE 现由 _restructure 半自动转 PREPARE/EXECUTE/DEALLOCATE（INTO 子句标 TODO）
      if ($0 ~ /BULK[ \t]+COLLECT|FORALL/)       todo("批量操作 BULK COLLECT/FORALL 无直接对应，需改写为游标循环")
      # Oracle PL/SQL 集合类型声明（关联 BULK COLLECT）→ MySQL 无对应，标 TODO
      if ($0 ~ /^[ \t]*TYPE[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+IS[ \t]+(TABLE[ \t]+OF|RECORD|VARRAY)/) todo("PL/SQL 集合/RECORD 类型 MySQL 无对应，需改临时表或 JSON")
      # 注：TRUNC / INSTR / TO_NUMBER / TO_CHAR(number) / SUBSTR(0-offset) / NEXTVAL 现由 _convert_type_aware
      # （Phase 1 类型推断，置 _restructure 后）按 symtab 自动转换；不确定项在那 pass 内注 TODO。此处不再标，避免残留假阳性。
      if ($0 ~ /(^|[^A-Za-z0-9_])TO_DATE[ \t]*\(/)  todo("TO_DATE(复杂参数/无掩码) 需人工 STR_TO_DATE（简单 TO_DATE(str,'mask') 已自动转 STR_TO_DATE，此处排除 STR_TO_DATE 子串假阳性）")
      # 注：LISTAGG WITHIN GROUP(ORDER BY) 现由 _convert_known_semantics 自动转 GROUP_CONCAT（OVER 分析函数形式标 TODO）
      if ($0 ~ /DBMS_OUTPUT/)                    todo("DBMS_OUTPUT 需改 SELECT 结果 / 写日志表")
      if ($0 ~ /(^|[^A-Za-z0-9_])GOTO[ \t]+[A-Za-z_]/) todo("GOTO 语句 MySQL 不支持，需改写为 IF/LOOP/LEAVE 控制流")
      if ($0 ~ /<<[A-Za-z_][A-Za-z0-9_]*>>/) todo("GOTO 标签 <<label>> MySQL 不支持，需配合 GOTO 改写移除")
      # P3-e: 外部自定义函数检测（通用 FUNC_xxx 模式）——标 INFO（非 TODO），DDL 由
      # _convert_custom_functions 全局递归转换到 _custom_functions.tidb.sql（有 .fnc 源码）
      # 或输出 DDL 桩 + TODO（无源码）。
      # 特定函数附加上下文提醒：
      if ($0 ~ /(^|[^A-Za-z0-9_])FUNC_dsensitive_permissions[ \t]*\(/) print "-- INFO: 调用自定义函数 FUNC_dsensitive_permissions（DDL 见 _custom_functions.tidb.sql）；注意：GROUP BY 中应使用原始列值，脱敏仅在 SELECT 层生效"
      else if ($0 ~ /(^|[^A-Za-z0-9_])FUNC_[A-Za-z_][A-Za-z0-9_]*[ \t]*\(/) {
        match($0, /FUNC_[A-Za-z_][A-Za-z0-9_]*/)
        fn_name = substr($0, RSTART, RLENGTH)
        print "-- INFO: 调用自定义函数 " fn_name "（DDL 见 _custom_functions.tidb.sql）"
      }
      # 注：EXCEPTION 块（WHEN NO_DATA_FOUND/OTHERS）/ 显式游标 CURSOR..IS / 数值 FOR..IN / 游标 FOR rec IN cur LOOP / REVERSE FOR
      # 现由 _restructure 自动转换（EXIT handler / DECLARE..CURSOR FOR + done / WHILE+计数器 / OPEN+FETCH+CLOSE / WHILE 递减）；
      # 非 REVERSE 数值范围外的 FOR..IN 在 _restructure 内单独标 TODO。此处不再标 FOR/EXCEPTION/CURSOR，避免残留假阳性。
      prev_line = $0
      print
    }
  '
}

# 头部改写：CREATE OR REPLACE PROCEDURE [owner.]name
#   → 注入 DROP PROCEDURE IF EXISTS `name`; 并去掉 OR REPLACE。
_rewrite_header() {
  awk '
    BEGIN { IGNORECASE=1; dropped=0; isfunc=0 }
    /^create[ \t]+(or[ \t]+replace[ \t]+)?(procedure|function)[ \t]+/ {
      if (!dropped) {
        kind = ($0 ~ /^create[ \t]+(or[ \t]+replace[ \t]+)?function[ \t]+/) ? "FUNCTION" : "PROCEDURE"
        isfunc = (kind == "FUNCTION")
        line=$0
        sub(/^create[ \t]+(or[ \t]+replace[ \t]+)?(procedure|function)[ \t]+/, "", line)
        name=line; sub(/[ \t(;].*$/, "", name)
        gsub(/["`]/, "", name)                              # 去引号/反引号
        sub(/^[A-Za-z_][A-Za-z0-9_]*\./, "", name)          # 去 owner. 前缀（TiDB 用当前库）
        print "DROP " kind " IF EXISTS `" name "`;"
        dropped=1
      }
      sub(/or[ \t]+replace[ \t]+/, "", $0)
    }
    # FUNCTION 头部 RETURN<type> 子句 → RETURNS<type>。多行头也能命中：RETURN-type 子句以 IS/AS 收尾，
    # body 的 RETURN<expr>; 不带 IS/AS 故不误伤（单行/多行 FUNCTION 头通用）。
    # type 用 [^ \t]+ 匹配：DECIMAL(65,30) 含逗号，[A-Za-z0-9_().] 类不含逗号会漏（fn_square 实测 bug）。
    isfunc && $0 ~ /RETURN[ \t]+[^ \t]+[ \t]+(IS|AS)[ \t]*$/ { sub(/RETURN[ \t]+/, "RETURNS ") }
    { print }
  '
}

# 参数模式前置重排：Oracle「name [IN|OUT|IN OUT] type」→ MySQL「[IN|OUT|INOUT] name type」。
# 仅在参数区（CREATE 头 (...) 内，按括号深度判定）操作，避免误伤 body 的 IN/赋值。
# 无模式的参数（如 p_n NUMBER）保持原样（MySQL 默认即 IN）。
_param_mode() {
  awk '
    # 仅 PROCEDURE 头部参数区做模式前置重排（name IN/OUT/IN OUT type → IN/OUT/INOUT name type）。
    # FUNCTION 参数 MySQL 禁 IN/OUT/INOUT，整体跳过（@测试 fail 清单 item 2）。
    BEGIN { depth=0; IGNORECASE=1; isfunc=0; active=0; closed=0 }
    /^create[ \t]+(or[ \t]+replace[ \t]+)?function[ \t]+/ { isfunc=1; active=1 }
    /^create[ \t]+(or[ \t]+replace[ \t]+)?procedure[ \t]+/ { isfunc=0; active=1 }
    {
      s=$0; no=gsub(/\(/,"",s); s=$0; nc=gsub(/\)/,"",s)
      # 先判断本行是否含 AS/IS（参数区结束标志），但参数重写仍需在本行执行
      line_has_as = ($0 ~ /[ \t](AS|IS)[ \t]*$/ || $0 ~ /^[ \t]*(AS|IS)[ \t]*$/)
      if (active && !closed) {
        # Oracle 参数行含行内 -- 注释（如 P_STATDATE1 IN VARCHAR2, --统计起始日期）
        # MySQL/TiDB CREATE PROCEDURE 参数列表不接受行内注释（ERROR 1064 in DELIMITER block）
        # 去掉参数区内的 -- 行内注释（-- 到行尾）
        sub(/--[ \t]*.*$/, "", $0)
        # 去注释后若只剩空白则跳过
        if ($0 ~ /^[ \t]*$/) { depth += (no - nc); next }
      }
      if (active && !closed && !isfunc) {
        $0 = gensub(/([(, \t])([A-Za-z_][A-Za-z0-9_]*)[ \t]+(IN[ \t]+OUT|INOUT|IN|OUT)[ \t]+/, "\\1\\3 \\2 ", "g")
        gsub(/IN[ \t]+OUT/, "INOUT")
      }
      # MySQL 函数参数禁 IN/OUT/INOUT：FUNCTION 参数区直接剥掉模式关键字，留 name type。
      if (active && !closed && isfunc) {
        $0 = gensub(/([A-Za-z_][A-Za-z0-9_]*)[ \t]+(IN[ \t]+OUT|INOUT|IN|OUT)[ \t]+/, "\\1 ", "g")
      }
      depth += (no - nc)
      # 参数区关闭条件（优先级）：① 本行含 AS/IS（无参或 AS 结尾） ② 括号 depth 回 0（有参 SP）
      if (active && !closed) {
        if (line_has_as) closed=1
        else if (depth<=0 && (no>0||nc>0)) closed=1
      }
      print
    }
  '
}

# 嵌套 DECLARE..BEGIN..END 块转换（Oracle 嵌套块 → MySQL 嵌套 BEGIN..END）。
# Oracle 允许在过程体内嵌套 DECLARE..BEGIN..END；MySQL 仅支持嵌套 BEGIN..END（无 DECLARE 关键字）。
# 处理：
#   - 嵌套 DECLARE → 移除，声明直接进入 BEGIN 内
#   - 嵌套 EXCEPTION → 标 TODO（需人工转为 DECLARE EXIT HANDLER）
#   - 简单嵌套块（无 EXCEPTION）→ 直接转 BEGIN..END
# 未处理：嵌套块内自定义 CONDITION / RAISE_APPLICATION_ERROR / 多层嵌套 → 标 TODO。
_nested_blocks() {
  awk '
    BEGIN { IGNORECASE=1; body_started=0; in_nested=0; nested_lines=0; nested_exc=0; nested_depth=0 }
    function is_top_begin(line) { return !in_nested && line ~ /^[ \t]*BEGIN[ \t]*$/ }
    function is_nested_declare(line) { return body_started && !in_nested && line ~ /^[ \t]*DECLARE[ \t]*$/ }
    function is_nested_end(line) {
      if (!in_nested) return 0
      if (line ~ /^[ \t]*END[ \t]*;?[ \t]*$/ && line !~ /END[ \t]+(IF|LOOP|CASE|FOR|REPEAT|WHILE)/) return 1
      return 0
    }
    {
      line = $0
      if (line ~ /^[ \t]*--/) { if (in_nested) nested[nested_lines++] = line; else print line; next }
      if (is_top_begin(line)) { body_started = 1; print line; next }
      if (!body_started) { print line; next }
      if (is_nested_declare(line)) {
        in_nested = 1; nested_lines = 0; nested_exc = 0; nested_depth = 0; next
      }
      if (in_nested) {
        nested[nested_lines++] = line
        if (line ~ /^[ \t]*EXCEPTION[ \t]*$/) nested_exc = 1
        if (line ~ /^[ \t]*BEGIN[ \t]*$/) {
          nested_depth++
          if (nested_depth > 1) nested[nested_lines-1] = "-- TODO(需人工转换): 多层嵌套 DECLARE..BEGIN..END 需人工展开"
        }
        # 嵌套块 END; 先减 nested_depth，再检查是否应 flush（顺序修复：原 L905 在 L921 前，
        # END; 时 nested_depth=1 不触发 flush，整个 SP 被 nested 吞掉 → 空输出）
        if (line ~ /^[ \t]*END[ \t]*;?[ \t]*$/ && line !~ /END[ \t]+(IF|LOOP|CASE|FOR|REPEAT|WHILE)/) nested_depth--
        if (is_nested_end(line) && nested_depth == 0) {
          in_nested = 0
          if (nested_exc) {
            print "-- TODO(需人工转换): 嵌套块含 EXCEPTION，需人工转为 DECLARE EXIT HANDLER"
            for (i=0; i<nested_lines; i++) print nested[i]
          } else {
            print "    BEGIN"
            for (i=0; i<nested_lines; i++) {
              l = nested[i]
              if (l ~ /^[ \t]*BEGIN[ \t]*$/) continue
              if (l ~ /^[ \t]*END[ \t]*;?[ \t]*$/) continue
              # 嵌套块内的声明行 "v T := x" → "DECLARE v T DEFAULT x"（有类型标识符）；
              # 赋值行 "v := x"（无类型）→ "SET v = x"（不在 DECLARE 段，是 body）。
              # 区分：声明行 := 前有 "identifier TYPE"（两个 token），赋值行 := 前只有 identifier。
              if (l ~ /^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]+[A-Za-z_][A-Za-z0-9_().,]*[ \t]*:=[ \t]/) {
                gsub(/[ \t]*:=[ \t]*/, " DEFAULT ", l)
                sub(/^[ \t]*/, "    DECLARE ", l)
              } else if (l ~ /^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*:=[ \t]/) {
                l = gensub(/^([ \t]*)([A-Za-z_][A-Za-z0-9_]*)[ \t]*:=[ \t]*/, "\\1SET \\2 = ", "", l)
              }
              print l
            }
            print "    END;"
          }
        }
        next
      }
      print line
    }
  '
}

# 结构改写 pass（架构师 spec：连贯结构改写，全量缓冲后按 MySQL 序组装）。
# Oracle `CREATE ... name(...) AS|IS <decls> BEGIN <body> [EXCEPTION ...] END;`
#   → MySQL `BEGIN <vars+done/v_errmsg> <cursors> <handlers> <body> END`
# 处理项：
#   - 删 AS/IS；声明段 `v T := x`→`DECLARE v T DEFAULT x`
#   - 显式游标 `CURSOR c IS <多行 SELECT;>`→`DECLARE c CURSOR FOR <SELECT;>`（按深度判定行止于 `;`）
#   - body 控制流：`WHILE c LOOP`→`WHILE c DO`（加 label）；`LOOP`→`label: LOOP`；
#     `EXIT WHEN c%NOTFOUND`→`IF done = 1 THEN LEAVE label`；`EXIT WHEN <cond>`→`IF <cond> THEN LEAVE label`；
#     裸 `EXIT`→`LEAVE label`；`END LOOP`(WHILE)→`END WHILE`（loop 栈判型）
#   - EXCEPTION 提升（架构 spec：块级 EXIT，非 CONTINUE）：NO_DATA_FOUND→`EXIT HANDLER FOR NOT FOUND`，
#     OTHERS→`EXIT HANDLER FOR SQLEXCEPTION` + `GET DIAGNOSTICS CONDITION 1 v_errmsg = MESSAGE_TEXT`，`SQLERRM`→`v_errmsg`
#   - fabricated：显式游标场景 `done INT DEFAULT 0` + `CONTINUE HANDLER FOR NOT FOUND SET done=1`；OTHERS 场景 `v_errmsg VARCHAR(255)`
#   - 嵌套 DECLARE..BEGIN..END：Oracle `DECLARE <decls> BEGIN <body> END;`→MySQL `BEGIN DECLARE <decls> <body> END;`
#     （block_depth 跟踪，嵌套 EXCEPTION 标 TODO）
# 组装序严守 MySQL 强制 DECLARE 序：变量/条件（含 done/v_errmsg）→ 游标 → handler → body。
# 注：顶层为主；嵌套 DECLARE..BEGIN..END 已自动转换（变量→DECLARE 前置，嵌套 EXCEPTION 标 TODO）；
#   自定义异常 CONDITION / RAISE_APPLICATION_ERROR 未覆盖（标 known-limitation）。
_restructure() {
  awk '
    BEGIN { state="pre"; IGNORECASE=1; ltop=0; labeln=0; has_ndf=0; has_others=0; done_needed=0; in_cursor=0; block_depth=0; nested_decl_buf=""; done_var="done"; verrmsg_var="v_errmsg"; _seen_done=0; _seen_verrmsg=0; custom_exc_body=""; inline_cursor_n=0 }
    function newlabel(){ labeln++; return "lp" labeln }
    function is_as_is_line(line) {
      return (line ~ /^[ \t]*(AS|IS)[ \t]*$/) || (line ~ /[)A-Za-z0-9_][ \t]+(AS|IS)[ \t]*$/)
    }
    function getindent(line){ if (match(line,/^[ \t]*/)) return substr(line,1,RLENGTH); return "" }
    # SP 终止 END：`END`/`END;`/`END <spname>;`，排除块结束 END IF/LOOP/CASE/FOR/REPEAT/WHILE。
    function is_sp_end(line) {
      if (line ~ /^[ \t]*END[ \t]*;?[ \t]*$/) return 1
      if (line ~ /^[ \t]*END[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*;?[ \t]*$/ && line !~ /^[ \t]*END[ \t]+(IF|LOOP|CASE|FOR|REPEAT|WHILE)([ \t;]|$)/) return 1
      return 0
    }
    function conv_decl(line,   s) {
      s=line; sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s)
      if (s=="") return ""
      sub(/[ \t]CONSTANT[ \t]+/, " ", s)                  # MySQL 无 CONSTANT
      gsub(/[ \t]*:=[ \t]*/, " DEFAULT ", s)               # 声明段 := → DEFAULT
      if (s !~ /^DECLARE[ \t]/) s="DECLARE " s
      return s
    }
    function conv_assign(line) {
      return gensub(/^([ \t]*)([A-Za-z_][A-Za-z0-9_.]*)[ \t]*:=[ \t]*/, "\\1SET \\2 = ", "g", line)
    }
    # 解析游标 SELECT 列名，存入 cursor_cols[cur_name] = "col1, col2, ..."
    # 取 SELECT 和 FROM 之间的列列表，按逗号拆分，优先取别名否则取列名
    function _parse_cursor_cols(cname, text,    sel_start, sel_end, cols, n, i, col, alias, rest) {
      rest = text
      if (!match(toupper(rest), /SELECT[ \t]+/)) return
      sel_start = RSTART + RLENGTH
      rest = substr(rest, sel_start)
      if (!match(toupper(rest), /[ \t]+FROM[ \t]+/)) return
      sel_end = RSTART - 1
      cols = substr(rest, 1, sel_end)
      n = split(cols, col_arr, ",")
      cursor_cols[cname] = ""
      for (i = 1; i <= n; i++) {
        col = col_arr[i]; gsub(/[\r\n]/, "", col); gsub(/^[ \t]+|[ \t]+$/, "", col)
        if (col == "*") { cursor_cols[cname] = ""; return }  # SELECT * 无法展开
        alias = ""
        # 取 AS alias 或末尾别名（Major #3 fix: 从匹配文本提取别名）
        if (match(toupper(col), /[ \t]+AS[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*$/)) {
          # RSTART..RLENGTH 从 " AS alias" 开始；从 RSTART+RLENGTH 往回提取标识符
          alias = substr(col, RSTART)
          gsub(/^[ \t]+AS[ \t]+/, "", alias)
          gsub(/[ \t]+$/, "", alias)
        } else if (match(col, /[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*$/)) {
          alias = substr(col, RSTART)
          gsub(/^[ \t]+/, "", alias)
          gsub(/[ \t]+$/, "", alias)
          if (toupper(alias) ~ /^(FROM|WHERE|JOIN|ON|GROUP|ORDER|HAVING|UNION|AND|OR|NOT|IN|IS|NULL|TRUE|FALSE)$/) alias = ""
        }
        if (alias != "") col = alias
        else { sub(/^.*\./, "", col) }
        if (i > 1) cursor_cols[cname] = cursor_cols[cname] ", "
        cursor_cols[cname] = cursor_cols[cname] col
      }
    }
    # 组装：header(DROP+CREATE+params) → BEGIN → 变量(+done/v_errmsg) → 游标 → handler → body → END
    function assemble(    h, vn, vl, i, vline, vname, _seen, _k, done_var, err_var) {
      printf "%s", hdrbuf
      print "BEGIN"
      # 收集 varbuf 中已声明的变量名，用于检测 FOR 计数器是否隐式声明 + P0-2 碰撞检测
      split("", _seen)
      if (varbuf != "") {
        vn=split(varbuf, vl, "\n")
        for(i=1;i<=vn;i++){
          vline=vl[i]
          # 若声明的是数值 FOR 计数器变量 → 改 INT DEFAULT <lo>（计数器为整数、初值=FOR 下界）
          if (vline ~ /^DECLARE[ \t]+[A-Za-z_][A-Za-z0-9_]*/) {
            vname=vline; sub(/^DECLARE[ \t]+/,"",vname); sub(/[ \t].*$/,"",vname)
            _seen[vname]=1
            if (vname in for_lo) vline="DECLARE " vname " INT DEFAULT " for_lo[vname] ";"
          }
          print vline
        }
      }
      # P0-2：合成标识符碰撞检测——若用户已声明 done/v_errmsg，则用 _o2t 后缀避免冲突
      done_var = (_seen["done"] ? "done_o2t" : "done")
      err_var  = (_seen["v_errmsg"] ? "v_errmsg_o2t" : "v_errmsg")
      # 注入隐式声明的 FOR 计数器变量（Oracle FOR v IN lo..hi 中 v 未在 DECLARE 段显式声明）
      for (_k in for_lo) {
        if (!(_k in _seen)) printf "    DECLARE %s INT DEFAULT %s;\n", _k, for_lo[_k]
      }
      if (done_needed)   printf "    DECLARE %s INT DEFAULT 0;\n", done_var
      if (has_others)    printf "    DECLARE %s VARCHAR(255);\n", err_var
      # P1-a Critical #1 fix: 游标 FOR 展开变量必须在游标 DECLARE 之前声明
      # 先做 rec.column → v_column 替换，再注入 DECLARE
      split("", _cursor_declared)
      for (_rvar in cursor_rec_map) {
        _cname = cursor_rec_map[_rvar]
        if (_cname in cursor_cols && cursor_cols[_cname] != "") {
          _n = split(cursor_cols[_cname], _cc, ",")
          for (_j = 1; _j <= _n; _j++) {
            _cn = _cc[_j]; gsub(/^[ \t]+|[ \t]+$/, "", _cn)
            _vname = "v_" _cn
            _pat = _rvar "\\." _cn
            _repl = _vname
            gsub(_pat, _repl, bodybuf)
            gsub(_pat, _repl, ndf_body)
            gsub(_pat, _repl, others_body)
            if (!(_vname in _seen) && !(_vname in _cursor_declared)) {
              _cursor_declared[_vname] = 1
            }
          }
        }
      }
      for (_dv in _cursor_declared) {
        printf "    DECLARE %s VARCHAR(4000); -- TODO(需人工核对类型): 游标 FOR 展开变量\n", _dv
      }
      if (curbuf != "")  printf "%s\n", curbuf
      h=""
      if (done_needed) h = h "    DECLARE CONTINUE HANDLER FOR NOT FOUND SET " done_var " = 1;\n"
      if (has_ndf)     h = h "    DECLARE EXIT HANDLER FOR NOT FOUND\n    BEGIN\n" ndf_body "    END;\n"
      if (has_others)  h = h "    DECLARE EXIT HANDLER FOR SQLEXCEPTION\n    BEGIN\n        GET DIAGNOSTICS CONDITION 1 " err_var " = MESSAGE_TEXT;\n" others_body "    END;\n"
      if (h != "") printf "%s", h
      if (custom_exc_body != "") printf "%s", custom_exc_body
      if (bodybuf != "") printf "%s", bodybuf
      print "END"
    }
    {
      line=$0
      if (line ~ /^[ \t]*--/) {                                              # 注释：按区缓冲（exception 区丢弃，corpus 无）
        if (state=="pre")        hdrbuf  = (hdrbuf==""?"":hdrbuf)  line "\n"
        else if (state=="decls") varbuf  = (varbuf==""?"":varbuf) "\n" line
        else if (state=="body")  bodybuf = (bodybuf==""?"":bodybuf) line "\n"
        next
      }
      if (state=="pre") {
        if (is_as_is_line(line)) { kept=line; sub(/[ \t]+(AS|IS)[ \t]*$/,"",kept); if (kept !~ /^[ \t]*$/) hdrbuf=(hdrbuf==""?"":hdrbuf) kept "\n"; state="decls"; next }
        hdrbuf = (hdrbuf==""?"":hdrbuf) line "\n"
        next
      }
      if (state=="decls") {
        if (in_cursor) {
          curbuf=(curbuf==""?"":curbuf "\n") line
          if (line ~ /;[ \t]*$/) { in_cursor=0; _parse_cursor_cols(cursor_buf_name, cursor_buf_raw); cursor_buf_raw="" }
          else cursor_buf_raw = cursor_buf_raw "\n" line
          next
        }
        if (line ~ /^[ \t]*CURSOR[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+IS/) {
          done_needed=1
          if (_seen_done) done_var = "done_o2t"
          core=line; sub(/^[ \t]+/,"",core); sub(/^CURSOR[ \t]+/,"",core); cname=core; sub(/[ \t]+IS.*$/,"",cname)
          rest=line; sub(/^[ \t]*CURSOR[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+IS/,"",rest)
          dline = "    DECLARE " cname " CURSOR FOR" (rest ~ /^[ \t]*$/ ? "" : rest)
          curbuf=(curbuf==""?"":curbuf "\n") dline
          cursor_buf_raw = rest
          cursor_buf_name = cname
          if (line !~ /;[ \t]*$/) in_cursor=1
          else _parse_cursor_cols(cname, cursor_buf_raw)
          next
        }
        if (line ~ /^[ \t]*BEGIN[ \t]*$/) { state="body"; next }            # BEGIN 在 assemble() 里发
        d=conv_decl(line); if (d=="") next
        # 碰撞检测：用户声明了 done / v_errmsg → 合成变量需改名
        if (match(d, /^DECLARE[ \t]+([A-Za-z_][A-Za-z0-9_]*)/, m)) { if (tolower(m[1])=="done") _seen_done=1; if (tolower(m[1])=="v_errmsg") _seen_verrmsg=1 }
        varbuf=(varbuf==""?"":varbuf "\n") d; next
      }
      if (state=="nested_decl") {
        if (line ~ /^[ \t]*BEGIN[ \t]*$/) {
          bodybuf=bodybuf line "\n"
          if (nested_decl_buf != "") bodybuf=bodybuf nested_decl_buf
          nested_decl_buf=""
          block_depth++
          state="body"
          next
        }
        if (line ~ /^[ \t]*EXCEPTION[ \t]*$/) {
          bodybuf=bodybuf "-- TODO(需人工转换): 嵌套 EXCEPTION 块\n"
          if (nested_decl_buf != "") bodybuf=bodybuf nested_decl_buf
          nested_decl_buf=""
          state="body"
          next
        }
        if (line ~ /^[ \t]*--/) next
        if (line ~ /^[ \t]*$/) next
        d=conv_decl(line); if (d=="") next
        if (match(d, /^DECLARE[ \t]+([A-Za-z_][A-Za-z0-9_]*)/, m)) { if (tolower(m[1])=="done") _seen_done=1; if (tolower(m[1])=="v_errmsg") _seen_verrmsg=1 }
        nested_decl_buf=nested_decl_buf d "\n"
        next
      }
      if (state=="exception") {
        if (line ~ /^[ \t]*WHEN[ \t]+OTHERS[ \t]+THEN/)        { exc_curr="others"; has_others=1; if (_seen_verrmsg) verrmsg_var = "v_errmsg_o2t"; next }
        if (line ~ /^[ \t]*WHEN[ \t]+NO_DATA_FOUND[ \t]+THEN/) { exc_curr="ndf";    has_ndf=1;     next }
        if (line ~ /^[ \t]*WHEN[ \t]+/)                         { exc_curr="other"; custom_exc_body = custom_exc_body "-- TODO(需人工转换): 自定义异常分支需人工创建 DECLARE CONDITION + 独立 EXIT HANDLER，原 body 已注释化保留\n"; next }
        if (is_sp_end(line)) { assemble(); state="end"; next }
        l=conv_assign(line); gsub(/SQLERRM/, verrmsg_var, l)
        if (exc_curr=="ndf")         ndf_body    = (ndf_body==""?"":ndf_body)    l "\n"
        else if (exc_curr=="others") others_body = (others_body==""?"":others_body) l "\n"
        else if (exc_curr=="other")  custom_exc_body = custom_exc_body "-- " line "\n"
        next
      }
      # state == body
      if (line ~ /^[ \t]*EXCEPTION[ \t]*$/) {
        if (block_depth > 0) { bodybuf=bodybuf "-- TODO(需人工转换): 嵌套 EXCEPTION 块\n"; next }
        state="exception"; exc_curr=""; next
      }
      if (line ~ /^[ \t]*END[ \t]+LOOP/) {                                     # END LOOP：FOR→+1 / RFOR→-1 / CFOR→CLOSE / WHILE→END WHILE / LOOP→保留
        ind=getindent(line)
        if (ltop>0) {
          if (ltype[ltop]=="FOR")      bodybuf=bodybuf ind "    SET " lvar[ltop] " = " lvar[ltop] " + 1;\n" ind "END WHILE " llabel[ltop] ";\n"
          else if (ltype[ltop]=="RFOR") bodybuf=bodybuf ind "    SET " lvar[ltop] " = " lvar[ltop] " - 1;\n" ind "END WHILE " llabel[ltop] ";\n"
          else if (ltype[ltop]=="CFOR") bodybuf=bodybuf ind "END LOOP " llabel[ltop] ";\n" ind "CLOSE " lcursor[ltop] ";\n"
          else if (ltype[ltop]=="WHILE") { l=line; sub(/LOOP/, "WHILE", l); bodybuf=bodybuf l "\n" }
          else                          bodybuf=bodybuf line "\n"
          ltop--
        } else bodybuf=bodybuf line "\n"
        next
      }
      if (line ~ /^[ \t]*FOR[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+IN[ \t]+[0-9]+[ \t]*\.\.[ \t]*[^ \t]+[ \t]+LOOP[ \t]*$/) {
        # 数值 FOR v IN lo..hi LOOP → lbl: WHILE v <= hi DO（计数器 v 在 assemble 改 INT DEFAULT lo；
        # 循环末尾 END LOOP 注入 SET v=v+1——MySQL WHILE 无 FOR 自动递增）。REVERSE 未覆盖（落 cursor-FOR TODO）。
        ind=getindent(line); core=substr(line,length(ind)+1)
        sub(/^FOR[ \t]+/,"",core); fvar=core; sub(/[ \t]+IN.*$/,"",fvar)
        sub(/^[A-Za-z_][A-Za-z0-9_]*[ \t]+IN[ \t]+/,"",core)                  # core = "lo..hi LOOP"
        dd=index(core,".."); lo=substr(core,1,dd-1); gsub(/[ \t]+$/,"",lo)
        hi=substr(core,dd+2); sub(/^[ \t]+/,"",hi); sub(/[ \t]+LOOP[ \t]*$/,"",hi)
        for_lo[fvar]=lo
        lbl=newlabel(); ltop++; ltype[ltop]="FOR"; llabel[ltop]=lbl; lvar[ltop]=fvar; llo[ltop]=lo
        bodybuf=bodybuf ind lbl ": WHILE " fvar " <= " hi " DO\n"; next
      }
      if (line ~ /^[ \t]*FOR[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+IN[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+LOOP[ \t]*$/) {
        # 游标 FOR rec IN cursor_name LOOP → OPEN + label:LOOP + FETCH + done check + body + END LOOP + CLOSE
        # MySQL 无 RECORD 类型，FETCH INTO 需标量变量列表（无法从游标名推断列）→ TODO 标 FETCH 目标
        ind=getindent(line); core=substr(line,length(ind)+1)
        sub(/^FOR[ \t]+/,"",core); fvar=core; sub(/[ \t]+IN.*$/,"",fvar)              # fvar = rec 变量名
        sub(/^[A-Za-z_][A-Za-z0-9_]*[ \t]+IN[ \t]+/,"",core)                           # core = "cursor_name LOOP"
        cname=core; sub(/[ \t]+LOOP[ \t]*$/,"",cname)
        done_needed=1
        if (_seen_done) done_var = "done_o2t"
        lbl=newlabel(); ltop++; ltype[ltop]="CFOR"; llabel[ltop]=lbl; lvar[ltop]=fvar; lcursor[ltop]=cname
        bodybuf=bodybuf ind "OPEN " cname ";\n"
        bodybuf=bodybuf ind lbl ": LOOP\n"
        # P1-a：若有游标列映射，自动展开 FETCH INTO 标量变量列表
        if (cname in cursor_cols && cursor_cols[cname] != "") {
          _cfetch_cols = cursor_cols[cname]
          _cfetch_vars = ""
          _n = split(_cfetch_cols, _cc, ",")
          for (_j = 1; _j <= _n; _j++) {
            _cn = _cc[_j]; gsub(/^[ \t]+|[ \t]+$/, "", _cn)
            if (_j > 1) _cfetch_vars = _cfetch_vars ", "
            _cfetch_vars = _cfetch_vars "v_" _cn
          }
          bodybuf=bodybuf ind "    FETCH " cname " INTO " _cfetch_vars ";\n"
          cursor_rec_map[fvar] = cname
        } else
          bodybuf=bodybuf ind "    FETCH " cname " INTO " fvar "; -- TODO(需人工转换): MySQL 无 RECORD 类型，须展开为标量变量列表（按游标 SELECT 列序）\n"
        bodybuf=bodybuf ind "    IF " done_var " = 1 THEN LEAVE " lbl ";\n" ind "    END IF;\n"; next
      }
      if (line ~ /^[ \t]*FOR[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+IN[ \t]+REVERSE[ \t]+[0-9]+[ \t]*\.\.[ \t]*[^ \t]+[ \t]+LOOP[ \t]*$/) {
        # REVERSE FOR v IN REVERSE lo..hi LOOP → lbl: WHILE v >= lo DO（计数器 v 初始化=hi，递减）
        ind=getindent(line); core=substr(line,length(ind)+1)
        sub(/^FOR[ \t]+/,"",core); fvar=core; sub(/[ \t]+IN.*$/,"",fvar)
        sub(/^[A-Za-z_][A-Za-z0-9_]*[ \t]+IN[ \t]+REVERSE[ \t]+/,"",core)          # core = "lo..hi LOOP"
        dd=index(core,".."); lo=substr(core,1,dd-1); gsub(/[ \t]+$/,"",lo)
        hi=substr(core,dd+2); sub(/^[ \t]+/,"",hi); sub(/[ \t]+LOOP[ \t]*$/,"",hi)
        for_lo[fvar]=hi   # REVERSE：计数器从 hi 开始递减
        lbl=newlabel(); ltop++; ltype[ltop]="RFOR"; llabel[ltop]=lbl; lvar[ltop]=fvar; llo[ltop]=lo
        bodybuf=bodybuf ind lbl ": WHILE " fvar " >= " lo " DO\n"; next
      }
      if (line ~ /^[ \t]*FOR[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+IN[ \t]+REVERSE[ \t]+/) {       # REVERSE FOR 非数值范围 → TODO
        bodybuf=bodybuf line "\t-- TODO(需人工转换): REVERSE FOR..IN 需改 WHILE 递减（hi→lo）\n"; next
      }
      # P1-a：内联游标 FOR rec IN (SELECT ...) LOOP → 生成 DECLARE CURSOR + OPEN/FETCH/CLOSE
      if (line ~ /^[ \t]*FOR[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+IN[ \t]+\(/) {
        ind=getindent(line); core=substr(line,length(ind)+1)
        sub(/^FOR[ \t]+/,"",core); fvar=core; sub(/[ \t]+IN.*$/,"",fvar)
        sub(/^[A-Za-z_][A-Za-z0-9_]*[ \t]+IN[ \t]+/,"",core)
        # core = "(SELECT ...) LOOP"
        # 提取括号内 SELECT 语句
        sub(/^\(/,"",core); sub(/\)[ \t]*LOOP[ \t]*$/,"",core)
        inline_select=core
        # 解析列名
        _parse_cursor_cols("_inline_" fvar, inline_select)
        _icname = "_cur_" fvar "_" (inline_cursor_n++)
        # 生成游标声明（放入 curbuf → assemble 时输出到 DECLARE 段）
        curbuf=(curbuf==""?"":curbuf "\n") "    DECLARE " _icname " CURSOR FOR " inline_select ";"
        done_needed=1
        if (_seen_done) done_var = "done_o2t"
        lbl=newlabel(); ltop++; ltype[ltop]="CFOR"; llabel[ltop]=lbl; lvar[ltop]=fvar; lcursor[ltop]=_icname
        bodybuf=bodybuf ind "OPEN " _icname ";\n"
        bodybuf=bodybuf ind lbl ": LOOP\n"
        if ("_inline_" fvar in cursor_cols && cursor_cols["_inline_" fvar] != "") {
          _cfetch_cols = cursor_cols["_inline_" fvar]
          _cfetch_vars = ""
          _n = split(_cfetch_cols, _cc, ",")
          for (_j = 1; _j <= _n; _j++) {
            _cn = _cc[_j]; gsub(/^[ \t]+|[ \t]+$/, "", _cn)
            if (_j > 1) _cfetch_vars = _cfetch_vars ", "
            _cfetch_vars = _cfetch_vars "v_" _cn
          }
          bodybuf=bodybuf ind "    FETCH " _icname " INTO " _cfetch_vars ";\n"
          cursor_rec_map[fvar] = "_inline_" fvar
        } else
          bodybuf=bodybuf ind "    FETCH " _icname " INTO " fvar "; -- TODO(需人工转换): 内联游标 SELECT * 或复杂列无法自动展开\n"
        bodybuf=bodybuf ind "    IF " done_var " = 1 THEN LEAVE " lbl ";\n" ind "    END IF;\n"; next
      }
      if (line ~ /^[ \t]*FOR[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+IN[ \t]+/) {       # 其他 FOR..IN（无法识别）→ TODO
        bodybuf=bodybuf line "\t-- TODO(需人工转换): FOR..IN 需改 DECLARE CURSOR+LOOP/FETCH 或反向计数\n"; next
      }
      if (line ~ /^[ \t]*WHILE[ \t].*[ \t]LOOP[ \t]*$/) {                      # WHILE c LOOP → label: WHILE c DO
        lbl=newlabel(); ltop++; ltype[ltop]="WHILE"; llabel[ltop]=lbl
        ind=getindent(line); core=substr(line,length(ind)+1); sub(/[ \t]+LOOP[ \t]*$/, " DO", core)
        bodybuf=bodybuf ind lbl ": " core "\n"; next
      }
      if (line ~ /^[ \t]*LOOP[ \t]*$/) {                                       # 裸 LOOP → label: LOOP
        lbl=newlabel(); ltop++; ltype[ltop]="LOOP"; llabel[ltop]=lbl
        ind=getindent(line); bodybuf=bodybuf ind lbl ": LOOP\n"; next
      }
      if (line ~ /^[ \t]*CONTINUE[ \t]*;/) {                                   # CONTINUE; → ITERATE label（FOR/RFOR 内先递增/递减计数器防死循环）
        ind=getindent(line); lbl=(ltop>0?llabel[ltop]:"lp1")
        if (ltop>0 && ltype[ltop]=="FOR") bodybuf=bodybuf ind "SET " lvar[ltop] " = " lvar[ltop] " + 1;\n"
        if (ltop>0 && ltype[ltop]=="RFOR") bodybuf=bodybuf ind "SET " lvar[ltop] " = " lvar[ltop] " - 1;\n"
        bodybuf=bodybuf ind "ITERATE " lbl ";\n"; next
      }
      if (line ~ /^[ \t]*CONTINUE[ \t]+WHEN[ \t]+/) {                         # CONTINUE WHEN cond → IF cond THEN (SET±1)? ITERATE
        ind=getindent(line); core=line; sub(/^[ \t]*CONTINUE[ \t]+WHEN[ \t]+/,"",core); sub(/;[ \t]*$/,"",core)
        lbl=(ltop>0?llabel[ltop]:"lp1")
        bodybuf=bodybuf ind "IF " core " THEN\n"
        if (ltop>0 && ltype[ltop]=="FOR") bodybuf=bodybuf ind "    SET " lvar[ltop] " = " lvar[ltop] " + 1;\n"
        if (ltop>0 && ltype[ltop]=="RFOR") bodybuf=bodybuf ind "    SET " lvar[ltop] " = " lvar[ltop] " - 1;\n"
        bodybuf=bodybuf ind "    ITERATE " lbl ";\n" ind "END IF;\n"; next
      }
      if (line ~ /^[ \t]*EXIT[ \t]+WHEN[ \t]+/) {                              # EXIT WHEN cond → IF cond THEN LEAVE
        # Bug #6 修复：原逻辑若含 %NOTFOUND 则整体替换为 done=1，丢弃复合条件（OR v_count >= 3）。
        # 正确做法：仅将 cursor%NOTFOUND 标记替换为 done=1，保留其余条件。
        ind=getindent(line); core=line; sub(/^[ \t]*EXIT[ \t]+WHEN[ \t]+/,"",core); sub(/;[ \t]*$/,"",core)
        # 替换所有 cursor_name%NOTFOUND → done = 1
        while (match(core, /[A-Za-z_][A-Za-z0-9_]*%NOTFOUND/)) {
          core = substr(core,1,RSTART-1) done_var " = 1" substr(core,RSTART+RLENGTH)
        }
        cond=core
        lbl=(ltop>0?llabel[ltop]:"lp1")
        bodybuf=bodybuf ind "IF " cond " THEN\n" ind "    LEAVE " lbl ";\n" ind "END IF;\n"; next
      }
      if (line ~ /^[ \t]*EXIT[ \t]*;/) {                                       # 裸 EXIT; → LEAVE label（允许行尾 -- 注释）
        ind=getindent(line); lbl=(ltop>0?llabel[ltop]:"lp1")
        bodybuf=bodybuf ind "LEAVE " lbl ";\n"; next
      }
      if (line ~ /^[ \t]*DECLARE[ \t]*$/) {                               # 嵌套 DECLARE..BEGIN..END
        state="nested_decl"; nested_decl_buf=""; next
      }
      if (line ~ /^[ \t]*BEGIN[ \t]*$/) {                                 # 嵌套 BEGIN
        block_depth++; bodybuf=bodybuf line "\n"; next
      }
      if (line ~ /^[ \t]*END[ \t]*;?[ \t]*$/) {                           # END（嵌套或 SP 终止）
        if (block_depth > 0) { block_depth--; bodybuf=bodybuf line "\n"; next }
        assemble(); state="end"; next
      }
      if (block_depth == 0 && is_sp_end(line)) { assemble(); state="end"; next }
      # EXECUTE IMMEDIATE 'sql' [INTO ...] [USING ...]; → PREPARE/EXECUTE/DEALLOCATE
      if (line ~ /^[ \t]*EXECUTE[ \t]+IMMEDIATE[ \t]+/) {
        ind=getindent(line); core=substr(line,length(ind)+1)
        sub(/^EXECUTE[ \t]+IMMEDIATE[ \t]+/,"",core); sub(/;[ \t]*$/,"",core)
        # 解析：sql_expr [INTO vars] [USING vars]
        # sql_expr 可能是 'literal' || var 或 var。先尝试匹配 INTO/USING 子句（须在引号外）。
        # 策略：先尝试匹配 INTO 子句（仅当 INTO 后跟标识符列表、非 SQL 字面量内）。
        sql_expr=core; into_vars=""; using_vars=""
        # 检查 USING（通常在最后）：找最后一个 " USING "
        u_idx = match(toupper(core), /[ \t]USING[ \t]+/)
        if (u_idx > 0) {
          sql_expr = substr(core, 1, u_idx - 1)
          using_vars = substr(core, u_idx + 1)
          sub(/^[ \t]*USING[ \t]+/,"",using_vars)
        }
        # 检查 INTO（在 sql_expr 内但须在引号外——简化：INTO 后跟变量列表、非表名）
        # Oracle EXECUTE IMMEDIATE 'sql' INTO var [, var...] [USING ...]
        # 判定：sql_expr 含 " INTO " 且 INTO 不在引号内。简单启发：sql_expr 以引号结尾后才匹配 INTO。
        # awk 在 bash 单引号内，用 \047（单引号 ASCII）避免提前终止 awk 字符串
        i_idx = match(toupper(sql_expr), /\047[ \t]+INTO[ \t]+/)
        if (i_idx > 0) {
          into_vars = substr(sql_expr, i_idx + 1)   # " INTO vars"
          sub(/^[ \t]*INTO[ \t]+/,"",into_vars)
          sql_expr = substr(sql_expr, 1, i_idx)
        } else {
          # 也检查非引号结尾的 INTO（如 EXECUTE IMMEDIATE v_sql INTO x）
          # 模式 [ \t]INTO[ \t]+ 已保证 INTO 前后有空格（词边界），无需额外守卫
          i_idx = match(sql_expr, /[ \t]INTO[ \t]+/)
          if (i_idx > 0) {
            into_vars = substr(sql_expr, i_idx + 1)
            sub(/^[ \t]*INTO[ \t]+/,"",into_vars)
            sql_expr = substr(sql_expr, 1, i_idx - 1)
          }
        }
        gsub(/^[ \t]+|[ \t]+$/,"",sql_expr)
        has_into = (into_vars != "")
        # 预组装 EXECUTE 子句后缀（USING 部分）
        exec_suffix = (using_vars != "" ? " USING " using_vars : "")
        # 生成 PREPARE/EXECUTE/DEALLOCATE 框架
        bodybuf=bodybuf ind "SET @sql = " sql_expr ";\n"
        bodybuf=bodybuf ind "PREPARE stmt FROM @sql;\n"
        if (has_into) {
          # P1-b：单变量 INTO → EXECUTE stmt INTO var [USING ...]（MySQL 8.0+）；多变量 → 游标 FETCH 框架
          # Critical #2 fix: EXECUTE...INTO 仅接受 local DECLARE 变量或 @user 变量，不接受 SP 参数。
          # 解决：对每个 INTO 目标用 @o2t_<var> 临时变量接收，再 SET 回原变量。
          _n_into = split(into_vars, _into_arr, /,[ \t]*/)
          if (_n_into == 1) {
            _into_var = _into_arr[1]; gsub(/^[ \t]+|[ \t]+$/, "", _into_var)
            # SP 参数(IN/OUT/INOUT) 或非 @ 开头 → 需通过 @user 变量中转
            if (_into_var !~ /^@/) {
              _tmp_var = "@o2t_into_" _into_var
              bodybuf=bodybuf ind "EXECUTE stmt INTO " _tmp_var exec_suffix ";\n"
              bodybuf=bodybuf ind "SET " _into_var " = " _tmp_var ";\n"
            } else {
              bodybuf=bodybuf ind "EXECUTE stmt INTO " _into_var exec_suffix ";\n"
            }
          } else {
            # P5-b: 多变量 INTO → 复用 @o2t_into_ 中转模式（与单变量一致）
            _into_list = ""
            _set_list = ""
            for (_vi = 1; _vi <= _n_into; _vi++) {
              _v = _into_arr[_vi]; gsub(/^[ \t]+|[ \t]+$/, "", _v)
              if (_v !~ /^@/) {
                _into_list = (_into_list == "" ? "" : _into_list ", ") "@o2t_into_" _v
                _set_list = _set_list ind "SET " _v " = @o2t_into_" _v ";\n"
              } else {
                _into_list = (_into_list == "" ? "" : _into_list ", ") _v
              }
            }
            bodybuf=bodybuf ind "EXECUTE stmt INTO " _into_list exec_suffix ";\n"
            bodybuf=bodybuf _set_list
          }
        } else {
          bodybuf=bodybuf ind "EXECUTE stmt" exec_suffix ";\n"
        }
        bodybuf=bodybuf ind "DEALLOCATE PREPARE stmt;\n"; next
      }
      # OPEN cursor_name FOR sql_expression; → PREPARE/EXECUTE/DEALLOCATE（TiDB SP 直接返回结果集）
      if (line ~ /^[ \t]*OPEN[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+FOR[ \t]+/) {
        ind=getindent(line); core=substr(line,length(ind)+1)
        sub(/^OPEN[ \t]+/,"",core); cursor_name=core; sub(/[ \t]+FOR.*$/,"",cursor_name)
        sub(/^[A-Za-z_][A-Za-z0-9_]*[ \t]+FOR[ \t]+/,"",core); sub(/;[ \t]*$/,"",core)
        sql_expr=core; gsub(/^[ \t]+|[ \t]+$/,"",sql_expr)
        bodybuf=bodybuf ind "-- INFO: OPEN " cursor_name " FOR 已转为 PREPARE/EXECUTE 返回结果集（TiDB SP 直接返回最后 SELECT 结果集；REF CURSOR OUT 参数已自动删除）\n"
        bodybuf=bodybuf ind "SET @sql = " sql_expr ";\n"
        bodybuf=bodybuf ind "PREPARE stmt FROM @sql;\n"
        bodybuf=bodybuf ind "EXECUTE stmt;\n"
        bodybuf=bodybuf ind "DEALLOCATE PREPARE stmt;\n"; next
      }
      l=conv_assign(line); bodybuf=bodybuf l "\n"
    }
  '
}
