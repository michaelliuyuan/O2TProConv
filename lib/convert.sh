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

run_convert() {
  : "${ORACLE_DIR:=$EXPORT_DIR}"
  resolve_dir ORACLE_DIR
  resolve_dir CONVERTED_DIR
  resolve_dir REPORT_DIR
  mkdir -p "$CONVERTED_DIR" "$REPORT_DIR"

  local report="$REPORT_DIR/convert_report.md"
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
  local f base out todos status total=0 need_review=0
  for f in "$ORACLE_DIR"/*.sql; do
    [[ "$(basename "$f")" == _* ]] && continue      # 跳过 _proc_list.tsv 等辅助文件
    base="$(basename "$f" .sql)"
    out="$CONVERTED_DIR/${base}.tidb.sql"
    convert_one "$f" "$out"
    todos=$(grep -c '^-- TODO(' "$out" || true)
    total=$((total+1))
    if [[ "$todos" -gt 0 ]]; then status="需人工复核"; need_review=$((need_review+1)); else status="已自动转换"; fi
    printf '| %s | %s | %s |\n' "$base" "$status" "$todos" >>"$report"
    log "  $base → $out（TODO: $todos）"
  done
  shopt -u nullglob

  {
    echo
    echo "**合计**：$total 个过程，其中 $need_review 个需人工复核。"
  } >>"$report"

  info "转换完成：$total 个，需复核 $need_review 个；报告 $report"
}

# 转换单个文件
convert_one() {
  local in="$1" out="$2"
  local text; text="$(cat "$in")"
  text="$(_tochar_date    <<<"$text")"
  text="$(_apply_mechanical <<<"$text")"
  text="$(_fix_header     <<<"$text")"
  text="$(_mark_complex   <<<"$text")"
  text="$(_rewrite_header <<<"$text")"
  text="$(_param_mode     <<<"$text")"
  text="$(_restructure    <<<"$text")"
  {
    echo "-- 由 oracle2tidb-sp 自动转换生成；请核对带 -- TODO(需人工转换) 的行"
    echo "DELIMITER //"
    printf '%s\n' "$text"
    echo "//"
    echo "DELIMITER ;"
  } >"$out"
}

# 机械转换：安全的、确定性的 token / 模式替换（GNU sed，支持 \b 与 I 标志）。
_apply_mechanical() {
  sed -E \
    -e '/^[[:space:]]*--/b' \
    -e 's/\bNVARCHAR2\b/NVARCHAR/gI' \
    -e 's/\bVARCHAR2\b/VARCHAR/gI' \
    -e 's/\bNUMBER\(/DECIMAL(/gI' \
    -e 's/\bNUMBER\b/DECIMAL(65,30)/gI' \
    -e 's/\bPLS_INTEGER\b/INT/gI' \
    -e 's/\bBINARY_INTEGER\b/INT/gI' \
    -e 's/\bSIMPLE_INTEGER\b/BIGINT/gI' \
    -e 's/\bNVL\(/IFNULL(/gI' \
    -e 's/\bSYSDATE\b/NOW()/gI' \
    -e 's/\bSYSTIMESTAMP\b/CURRENT_TIMESTAMP(6)/gI' \
    -e 's/\bELSIF\b/ELSEIF/gI' \
    -e 's/^\/$//'                       # 去掉 Oracle 的 `/` 执行终止行
  # 说明：以下不做静默替换（见文件头注释），统一由 _mark_complex 标记人工：
  #   ||  DATE(类型)  DECODE  %TYPE/%ROWTYPE  EXECUTE IMMEDIATE
  #   FOR..IN 循环  BULK COLLECT/FORALL  EXCEPTION WHEN  CURSOR..IS  DBMS_OUTPUT
}

# TO_CHAR(date,'mask')→DATE_FORMAT(date,'%mask')：clean-auto（确定性掩码映射，对齐设计文档 §5.2）。
# 仅处理第一参数无逗号/括号的常见日期形态；剩余 TO_CHAR(number/复杂) 由 _mark_complex 标 TODO。
# 必须在 _apply_mechanical（SYSDATE→NOW）之前跑，否则 NOW() 带括号匹配不到。
_tochar_date() {
  awk '
    BEGIN { q = sprintf("%c", 39); re = "TO_CHAR\\([^,()]*,[ \\t]*" q "[^" q "]*" q }
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
      if ($0 ~ /^[ \t]*--/) { print; next }      # 跳过注释行（不在注释里做转换）
      while (match($0, re)) {
        whole = substr($0, RSTART, RLENGTH)
        p = index(whole, ",")
        arg = substr(whole, 9, p - 9)
        m = substr(whole, p + 1); sub(/^[ \t]*/, "", m); gsub(q, "", m)
        mm = mapmask(m)
        if (mm == m) break                              # 无日期 token → 非 date，留给 TODO
        rep = "DATE_FORMAT(" arg ", " q mm q            # 不含结尾 ")"，原 ")" 保留
        $0 = substr($0, 1, RSTART - 1) rep substr($0, RSTART + RLENGTH)
      }
      print
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

# 复杂结构检测：在匹配行上方注入 TODO 注释（保留原行）。
_mark_complex() {
  awk '
    function todo(msg){ print "-- TODO(需人工转换): " msg }
    BEGIN { re_emptyif = "IFNULL\\([^,]*,[ \\t]*\047\047[ \\t]*\\)" }
    {
      if ($0 ~ /^[ \t]*--/) { print; next }      # 跳过注释行（不在注释里标 TODO）
      if ($0 ~ re_emptyif)                      todo("NVL(x,空串) 语义分歧：Oracle 空串即 NULL，故 NVL(x,空串) 实为恒等/返回 x；TiDB 空串不等于 NULL，故 IFNULL(x,空串) 返回空串——不能盲转（@测试 跨库坑①）。解法二选一：保行为→取 x / IFNULL(x,NULL)；保意图→IFNULL(x,'')")
      if ($0 ~ /\|\|/)                          todo("字符串拼接 || 需改 CONCAT(...)；MySQL 中 || 默认是逻辑或，静默不转会语义错误")
      if ($0 ~ /%TYPE|%ROWTYPE/)                 todo("锚定类型 %TYPE/%ROWTYPE 需解析为具体类型")
      if ($0 ~ /EXECUTE[ \t]+IMMEDIATE/)         todo("动态 SQL EXECUTE IMMEDIATE 需改 PREPARE/EXECUTE/DEALLOCATE")
      if ($0 ~ /BULK[ \t]+COLLECT|FORALL/)       todo("批量操作 BULK COLLECT/FORALL 无直接对应，需改写为游标循环")
      if ($0 ~ /DECODE[ \t]*\(/)                 todo("DECODE 需改 CASE WHEN")
      if ($0 ~ /TO_CHAR[ \t]*\(/)                todo("TO_CHAR(number 或复杂参数) 无干净 MySQL 对应，需人工（DATE 形态已自动转 DATE_FORMAT）")
      if ($0 ~ /DBMS_OUTPUT/)                    todo("DBMS_OUTPUT 需改 SELECT 结果 / 写日志表")
      if ($0 ~ /EXCEPTION[ \t]+WHEN/)            todo("异常 EXCEPTION WHEN 需改 DECLARE ... HANDLER")
      if ($0 ~ /^[ \t]*EXCEPTION[ \t]*$/)        todo("异常块 EXCEPTION 需改 DECLARE ... HANDLER（跨行结构）")
      if ($0 ~ /CURSOR[ \t]+[A-Za-z_]+[ \t]+IS/) todo("显式游标 CURSOR..IS 需改 DECLARE ... CURSOR FOR")
      if ($0 ~ /[ \t]FOR[ \t]+.*[ \t]IN[ \t]+/)  todo("FOR..IN 循环：数值范围可转 WHILE，游标循环需改写，无法自动判定")
      print
    }
  '
}

# 头部改写：CREATE OR REPLACE PROCEDURE [owner.]name
#   → 注入 DROP PROCEDURE IF EXISTS `name`; 并去掉 OR REPLACE。
_rewrite_header() {
  awk '
    BEGIN { IGNORECASE=1; dropped=0 }
    /^create[ \t]+(or[ \t]+replace[ \t]+)?(procedure|function)[ \t]+/ {
      if (!dropped) {
        kind = ($0 ~ /^create[ \t]+(or[ \t]+replace[ \t]+)?function[ \t]+/) ? "FUNCTION" : "PROCEDURE"
        line=$0
        sub(/^create[ \t]+(or[ \t]+replace[ \t]+)?(procedure|function)[ \t]+/, "", line)
        name=line; sub(/[ \t(;].*$/, "", name)
        gsub(/["`]/, "", name)                              # 去引号/反引号
        sub(/^[A-Za-z_][A-Za-z0-9_]*\./, "", name)          # 去 owner. 前缀（TiDB 用当前库）
        print "-- DROP " kind " IF EXISTS `" name "`;"
        dropped=1
      }
      sub(/or[ \t]+replace[ \t]+/, "", $0)
      if (kind == "FUNCTION") sub(/[ \t]RETURN[ \t]/, " RETURNS ")   # 头部 RETURN<type> → RETURNS<type>
    }
    { print }
  '
}

# 参数模式前置重排：Oracle「name [IN|OUT|IN OUT] type」→ MySQL「[IN|OUT|INOUT] name type」。
# 仅在参数区（CREATE 头 (...) 内，按括号深度判定）操作，避免误伤 body 的 IN/赋值。
# 无模式的参数（如 p_n NUMBER）保持原样（MySQL 默认即 IN）。
_param_mode() {
  awk '
    BEGIN { depth=0; IGNORECASE=1 }
    {
      s=$0; no=gsub(/\(/,"",s); s=$0; nc=gsub(/\)/,"",s)
      in_params = (depth>0) || (no>0 && $0 ~ /^create[ \t]+(or[ \t]+replace[ \t]+)?(procedure|function)[ \t]+/)
      if (in_params) {
        $0 = gensub(/([(, \t])([A-Za-z_][A-Za-z0-9_]*)[ \t]+(IN[ \t]+OUT|INOUT|IN|OUT)[ \t]+/, "\\1\\3 \\2 ", "g")
        gsub(/IN[ \t]+OUT/, "INOUT")
      }
      depth += (no - nc)
      print
    }
  '
}
