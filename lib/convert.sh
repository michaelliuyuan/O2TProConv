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
  text="$(_convert_known_semantics <<<"$text")"
  text="$(_fix_header     <<<"$text")"
  text="$(_mark_complex   <<<"$text")"
  text="$(_rewrite_header <<<"$text")"
  text="$(_param_mode     <<<"$text")"
  text="$(_restructure    <<<"$text")"
  {
    echo "-- 由 oracle2tidb-sp 自动转换生成；请核对带 -- TODO(需人工转换) 的行"
    # _rewrite_header 注入了真实 DROP 语句（首行）。把它提到 DELIMITER // 之前——
    # 在默认分隔符下执行，幂等：反馈环每次 pull 新 hash 重跑不会因 duplicate 挂。
    local first rest
    if [[ "$text" == *$'\n'* ]]; then first="${text%%$'\n'*}"; rest="${text#*$'\n'}"; else first="$text"; rest=""; fi
    if [[ "$first" =~ ^DROP[[:space:]]+(PROCEDURE|FUNCTION)[[:space:]]+IF[[:space:]]+EXISTS ]]; then
      printf '%s\n' "$first"
      echo "DELIMITER //"
      [[ -n "$rest" ]] && printf '%s\n' "$rest"
    else
      echo "DELIMITER //"
      printf '%s\n' "$text"
    fi
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
  # 说明：|| 与 DECODE 现由 _convert_known_semantics 做「忠实版自动转换」（已知语义差，默认开启）；
  #   转不了的（跨行/操作数边界不可靠）才注入 TODO。DATE(类型)/%TYPE/EXECUTE IMMEDIATE/FOR..IN/
  #   BULK COLLECT/EXCEPTION/CURSOR..IS/DBMS_OUTPUT 仍由 _mark_complex 标人工。
}

# 已知 Oracle↔MySQL 语义差的忠实版自动转换（架构师决策：已知语义差→忠实修、默认开启；
# 未知结构失败→留 TODO 走 fail 清单）。
#   DECODE(expr,s1,r1,...,[default]) → CASE WHEN expr<=>s1 THEN r1 ... [ELSE default] END
#     （MySQL null-safe <=> 等价于 DECODE 的 NULL=NULL；TiDB 支持 <=>，比手搓 IS NULL 干净）。
#   a || b || c → NULLIF(CONCAT(IFNULL(a,''),IFNULL(b,''),IFNULL(c,'')),'')
#     （Oracle || 对 NULL 不敏感；CONCAT 任一 NULL 则 NULL，故内层 IFNULL；外层 NULLIF 补 Oracle"空串即 NULL"）。
# char 级扫描跟踪字符串字面量（'' 转义）+ () 深度，只动 CODE 不动数据；转换不了的（跨行 /
# 操作数边界不可靠 / 混运算符）原样保留并注入 TODO，绝不静默。
_convert_known_semantics() {
  gawk '
    BEGIN { q = sprintf("%c", 39) }
    function trim(s){ sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s); return s }
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
    function conv_decode(line,   out,pos,prev,cpos,epos,mid,A,n,i,expr,cs){
      out=""
      while(match(line,/DECODE[ \t]*\(/)){
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
        out=out substr(line,1,pos-1) cs
        line=substr(line,epos+1)
      }
      return out line
    }
    function conv_concat(line,   out,re,m,pre,chain,rest,A,n,i,inner,cs,unsafe,rs,rl){
      # 动态正则里 \( \) \. \| 都会被当普通字符（gawk 警告），故字面量一律用方括号类：
      # [(] [)] [|] [.] —— 避免 || 被解析成两个交替运算符破坏链匹配。
      re = "(:=|[(),])[ \t]*([A-Za-z_][A-Za-z0-9_.#$]*[(][^()]*[)]|[A-Za-z_][A-Za-z0-9_.#$]*|" q "[^" q "]*" q "|[0-9]+([.][0-9]+)?)([ \t]*[|][|][ \t]*([A-Za-z_][A-Za-z0-9_.#$]*[(][^()]*[)]|[A-Za-z_][A-Za-z0-9_.#$]*|" q "[^" q "]*" q "|[0-9]+([.][0-9]+)?))+"
      out=""
      while(match(line,re)){
        rs=RSTART; rl=RLENGTH                         # match(m,...) 下面会覆盖全局 RSTART/RLENGTH，先存
        m=substr(line,rs,rl)
        rest=substr(line,rs+rl)
        if(rest !~ /^[ \t]*([;),]|$)/){ out=out substr(line,1,rs); line=substr(line,rs+1); continue }
        if(match(m,/^(:=|[(),])[ \t]*/)){ pre=substr(m,1,RLENGTH); chain=substr(m,RLENGTH+1) } else { pre=""; chain=m }
        n=split_pipes(chain,A)
        unsafe=0
        for(i=1;i<=n;i++){ if(A[i] ~ /[+\-*/=<>]/ || A[i] ~ /(^|[^A-Za-z0-9_])(AND|OR|NOT|FROM|WHERE|SELECT|INTO|VALUES|THEN|ELSE|WHEN|CASE|END)([^A-Za-z0-9_]|$)/){ unsafe=1; break } }
        if(unsafe){ todo=todo "|| 拼接含混运算符/关键字，操作数边界不可靠，需人工 CONCAT; "; out=out substr(line,1,rs+rl-1); line=rest; continue }
        inner=""
        for(i=1;i<=n;i++){ inner=(i==1?"":inner ", ") "IFNULL(" trim(A[i]) "," q q ")" }
        cs="NULLIF(CONCAT(" inner ")," q q ")"
        out=out substr(line,1,rs-1) pre cs
        line=rest
      }
      return out line
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
      line=conv_decode(line)
      line=conv_concat(line)
      if(code_has_pipe(line))   todo=todo "|| 拼接未能自动转换（跨行/复杂），需人工 CONCAT; "
      if(code_has_decode(line)) todo=todo "DECODE 未能自动转换（跨行/畸形），需人工 CASE; "
      if(todo != "") print "-- TODO(需人工转换): " todo
      print line
    }
  '
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
    {
      if ($0 ~ /^[ \t]*--/) { print; next }      # 跳过注释行（不在注释里标 TODO）
      # 注：原 re_emptyif（IFNULL(x,空串) 的 NVL(x,空串) 语义分歧告警）已移除——|| 忠实转换器会
      # 生成 IFNULL(op,'')，与 NVL(x,'') 文本同形、post-mechanical 无法区分，全量标记只会误报每一处
      # ||。NVL(x,'') 分歧属已知 niche 边缘，由文档记录、不在此标记。
      if ($0 ~ /%TYPE|%ROWTYPE/)                 todo("锚定类型 %TYPE/%ROWTYPE 需解析为具体类型")
      if ($0 ~ /EXECUTE[ \t]+IMMEDIATE/)         todo("动态 SQL EXECUTE IMMEDIATE 需改 PREPARE/EXECUTE/DEALLOCATE")
      if ($0 ~ /BULK[ \t]+COLLECT|FORALL/)       todo("批量操作 BULK COLLECT/FORALL 无直接对应，需改写为游标循环")
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
        print "DROP " kind " IF EXISTS `" name "`;"
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
    # 仅 PROCEDURE 头部参数区做模式前置重排（name IN/OUT/IN OUT type → IN/OUT/INOUT name type）。
    # FUNCTION 参数 MySQL 禁 IN/OUT/INOUT，整体跳过（@测试 fail 清单 item 2）。
    BEGIN { depth=0; IGNORECASE=1; isfunc=0; active=0; closed=0 }
    /^create[ \t]+(or[ \t]+replace[ \t]+)?function[ \t]+/ { isfunc=1; active=1 }
    /^create[ \t]+(or[ \t]+replace[ \t]+)?procedure[ \t]+/ { isfunc=0; active=1 }
    {
      s=$0; no=gsub(/\(/,"",s); s=$0; nc=gsub(/\)/,"",s)
      if (active && !closed && !isfunc) {
        $0 = gensub(/([(, \t])([A-Za-z_][A-Za-z0-9_]*)[ \t]+(IN[ \t]+OUT|INOUT|IN|OUT)[ \t]+/, "\\1\\3 \\2 ", "g")
        gsub(/IN[ \t]+OUT/, "INOUT")
      }
      depth += (no - nc)
      if (active && !closed && depth<=0 && (no>0||nc>0)) closed=1
      print
    }
  '
}

# 结构改写 pass（架构师 spec：一个连贯的结构改写，不打逐条补丁）。
# Oracle `CREATE ... name(...) [RETURN t] AS|IS <decls> BEGIN <body> END[name];`
#   → MySQL `BEGIN DECLARE <decls>; <body> END`，配套：
#   - 删 AS/IS（item 1）
#   - 声明段移到 BEGIN 之后 + 加 DECLARE 前缀；声明段 `v T := x` → `DECLARE v T DEFAULT x`（item 4）
#   - 执行段 `v := x` → `SET v = x`（item 3，`:=` 两态：声明段 DEFAULT / 执行段 SET）
#   - `END[name];`/`END;` → `END`（item 5，但保留 END IF/LOOP/CASE/FOR）
# 顶层结构按 AS/IS→BEGIN→END 状态机走；嵌套 DECLARE..BEGIN..END 尽力（顶层为主）。
# 注释行（-- ...）原样透传，不参与状态机/改写。
_restructure() {
  awk '
    BEGIN { state="pre"; IGNORECASE=1 }
    function is_as_is_line(line) {
      return (line ~ /^[ \t]*(AS|IS)[ \t]*$/) || (line ~ /[)A-Za-z0-9_][ \t]+(AS|IS)[ \t]*$/)
    }
    function conv_decl(line,   s) {
      s=line; sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s)
      if (s=="") return ""
      if (s ~ /^CURSOR[ \t]/) return s "\t-- TODO(需人工转换): 游标声明 CURSOR..IS 需改 DECLARE..CURSOR FOR"
      sub(/[ \t]CONSTANT[ \t]+/, " ", s)                  # MySQL 无 CONSTANT
      gsub(/[ \t]*:=[ \t]*/, " DEFAULT ", s)               # 声明段 := → DEFAULT
      if (s !~ /^DECLARE[ \t]/) s="DECLARE " s
      return s
    }
    function conv_assign(line) {
      # gsub/sub 不支持 \1 反向引用，用 gensub（缩进 target := → SET target = ）
      return gensub(/^([ \t]*)([A-Za-z_][A-Za-z0-9_.]*)[ \t]*:=[ \t]*/, "\\1SET \\2 = ", "g", line)
    }
    function conv_end(line,   s) {
      if (line ~ /^[ \t]*END[ \t]+(IF|LOOP|CASE|FOR|RECORD)[ \t]*;/) return line   # 保留块结束（END IF/LOOP/CASE/FOR）
      s=line
      if (s ~ /^[ \t]*END[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*;?[ \t]*$/) { sub(/[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*;?[ \t]*$/, "", s); return s }  # END name; → END
      if (s ~ /^[ \t]*END[ \t]*;?[ \t]*$/) { sub(/;[ \t]*$/, "", s); return s }     # END; → END
      return line                                                                  # 非 END 行原样（保留 ;）
    }
    {
      line=$0
      if (line ~ /^[ \t]*--/) { print line; next }            # 注释透传
      if (state=="pre") {
        if (is_as_is_line(line)) { kept=line; sub(/[ \t]+(AS|IS)[ \t]*$/,"",kept); if (kept !~ /^[ \t]*$/) print kept; state="decls"; next }
        if (line ~ /^[ \t]*BEGIN[ \t]*$/) { print line; state="body"; next }   # 无声明段直入 body
        print line; next
      }
      if (state=="decls") {
        if (line ~ /^[ \t]*BEGIN[ \t]*$/) {
          print line
          # TiDB v7.1.9 强制 DECLARE 序：变量/条件 → 游标 → handler（@测试 ERROR 1337 实证）。
          # 本期处理声明段：var/condition 先、CURSOR 后；handler 槽留给 EXCEPTION→HANDLER（下期）。
          if (varbuf!="")  print varbuf
          if (curbuf!="")  print curbuf
          varbuf=""; curbuf=""; state="body"; next
        }
        d=conv_decl(line)
        if (d=="") next
        # 按强制序分类：游标(CURSOR)排后，其余(变量/条件)排前
        if (line ~ /^[ \t]*CURSOR[ \t]/) curbuf=(curbuf==""?"":curbuf "\n") d
        else                             varbuf=(varbuf==""?"":varbuf "\n") d
        next
      }
      # state == body
      line=conv_assign(line)
      line=conv_end(line)
      print line
    }
  '
}
