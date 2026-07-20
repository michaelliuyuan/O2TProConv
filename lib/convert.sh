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
  local note_section="" sem_section=""
  for f in "$ORACLE_DIR"/*.sql; do
    [[ "$(basename "$f")" == _* ]] && continue      # 跳过 _proc_list.tsv 等辅助文件
    base="$(basename "$f" .sql)"
    out="$CONVERTED_DIR/${base}.tidb.sql"
    convert_one "$f" "$out"
    todos=$(grep -c '^-- TODO(' "$out" || true)
    total=$((total+1))
    if [[ "$todos" -gt 0 ]]; then status="需人工复核"; need_review=$((need_review+1)); else status="已自动转换"; fi
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
    [[ "$dt" -gt 0 ]] && sem_line+="DATE 类型(Oracle 带时分秒 vs MySQL DATE 仅日期，时间分量被截断——若依赖时间须改 DATETIME)×${dt}；"
    [[ -n "$sem_line" ]] && sem_section+="  - **$base**：${sem_line}"$'\n'
    log "  $base → $out（TODO: $todos）"
  done
  shopt -u nullglob

  {
    echo
    echo "**合计**：$total 个过程，其中 $need_review 个需人工复核。"
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
  text="$(_convert_type_aware <<<"$text")"
  {
    echo "-- 由 oracle2tidb-sp 自动转换生成；请核对带 -- TODO(需人工转换) 的行"
    # _rewrite_header 注入的真实 DROP 可能位于首部注释之后（源文件带头部注释）。
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

# 机械转换：安全的、确定性的 token / 模式替换（GNU sed，支持 \b 与 I 标志）。
_apply_mechanical() {
  sed -E \
    -e '/^[[:space:]]*--/b' \
    -e 's/\bNVARCHAR2[ \t]*\(/NVARCHAR(/gI' \
    -e 's/\bNVARCHAR2\b/NVARCHAR(4000)/gI' \
    -e 's/\bVARCHAR2[ \t]*\(/VARCHAR(/gI' \
    -e 's/\bVARCHAR2\b/VARCHAR(4000)/gI' \
    -e 's/\bNUMBER\(/DECIMAL(/gI' \
    -e 's/\bNUMBER\b/DECIMAL(65,30)/gI' \
    -e 's/\bPLS_INTEGER\b/INT/gI' \
    -e 's/\bBINARY_INTEGER\b/INT/gI' \
    -e 's/\bSIMPLE_INTEGER\b/BIGINT/gI' \
    -e 's/\bNVL\(/IFNULL(/gI' \
    -e 's/\bSYSDATE\b/NOW()/gI' \
    -e 's/\bSYSTIMESTAMP\b/CURRENT_TIMESTAMP(6)/gI' \
    -e 's/\bLENGTH[ \t]*\(/CHAR_LENGTH(/gI' \
    -e 's/\bCHR[ \t]*\(/CHAR(/gI' \
    -e 's/\bSYS_GUID[ \t]*\(\)/UUID()/gI' \
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
      re = "(:=|[(),]|(RETURN|SELECT|VALUES|WHERE|THEN|ELSE|WHEN)[ \t]+)[ \t]*([A-Za-z_][A-Za-z0-9_.#$]*[(][^()]*[)]|[A-Za-z_][A-Za-z0-9_.#$]*|" q "[^" q "]*" q "|[0-9]+([.][0-9]+)?)([ \t]*[|][|][ \t]*([A-Za-z_][A-Za-z0-9_.#$]*[(][^()]*[)]|[A-Za-z_][A-Za-z0-9_.#$]*|" q "[^" q "]*" q "|[0-9]+([.][0-9]+)?))+"
      out=""
      while(match(line,re)){
        rs=RSTART; rl=RLENGTH                         # match(m,...) 下面会覆盖全局 RSTART/RLENGTH，先存
        m=substr(line,rs,rl)
        rest=substr(line,rs+rl)
        # rest 须以 ;/) /, 终结（非裸 EOL）：裸 EOL = 多行 || 链续行（如 sp_format_report
        # SELECT 'DEPT='||v_dname 续到下行），不在此部分转——Route A 下整链留字面交 PIPES_AS_CONCAT。
        if(rest !~ /^[ \t]*[;),]/){ out=out substr(line,1,rs); line=substr(line,rs+1); continue }
        if(match(m,/^(:=|[(),]|(RETURN|SELECT|VALUES|WHERE|THEN|ELSE|WHEN)[ \t]+)[ \t]*/)){ pre=substr(m,1,RLENGTH); chain=substr(m,RLENGTH+1) } else { pre=""; chain=m }
        n=split_pipes(chain,A)
        unsafe=0
        for(i=1;i<=n;i++){ ss=strip_str(A[i]); if(ss ~ /[+\-*/=<>]/ || ss ~ /(^|[^A-Za-z0-9_])(AND|OR|NOT|FROM|WHERE|SELECT|INTO|VALUES|THEN|ELSE|WHEN|CASE|END)([^A-Za-z0-9_]|$)/){ unsafe=1; break } }
        if(unsafe){ todo=todo "|| 操作数边界不可靠，保留字面；目标库须 sql_mode 含 PIPES_AS_CONCAT 且 SP 须此模式下 CREATE（创建时锁定），否则 ||=OR; "; out=out substr(line,1,rs+rl-1); line=rest; continue }
        inner=""
        for(i=1;i<=n;i++){ inner=(i==1?"":inner ", ") "IFNULL(" trim(A[i]) "," q q ")" }
        cs="NULLIF(CONCAT(" inner ")," q q ")"
        out=out substr(line,1,rs-1) pre cs
        line=rest
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
      line=conv_nvl2(line)
      line=conv_add_months(line)
      line=conv_months_between(line)
      if(code_has_pipe(line))   todo=todo "|| 保留字面（SELECT 列表/跨行表达式边界不可靠，未自动转）；目标库须 sql_mode 含 PIPES_AS_CONCAT 且 SP 须此模式下 CREATE（创建时锁定），否则 ||=OR 算错；含 NULL 操作数时改 CONCAT(IFNULL)（简单 || 已自动转）; "
      if(code_has_decode(line)) todo=todo "DECODE 未能自动转换（跨行/畸形），需人工 CASE; "
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
    BEGIN { q = sprintf("%c", 39); re = "(TO_CHAR|TO_DATE)\\([^,()]*,[ \\t]*" q "[^" q "]*" q }
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
        fn = (substr(whole,1,7) == "TO_DATE") ? "STR_TO_DATE" : "DATE_FORMAT"
        p = index(whole, ",")
        arg = substr(whole, 9, p - 9)
        m = substr(whole, p + 1); sub(/^[ \t]*/, "", m); gsub(q, "", m)
        mm = mapmask(m)
        if (mm == m) break                              # 无日期 token → 留给 TODO
        rep = fn "(" arg ", " q mm q                    # 不含结尾 ")"，原 ")" 保留
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
    function match_paren(s,op,   n,i,depth,c){ n=length(s); depth=0
      for(i=op;i<=n;i++){ c=substr(s,i,1); if(c=="(")depth++; else if(c==")"){depth--; if(depth==0)return i} }
      return 0 }
    function split_topcomma(s,A,   n,i,c,depth,cur,cnt){ n=length(s);depth=0;cur="";cnt=0
      for(i=1;i<=n;i++){ c=substr(s,i,1)
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
    function conv_to_char_num(line,   out,pos,prev,cpos,epos,mid,A,n,tc,rep){
      out=""   # TO_CHAR(number) 单参→CAST AS CHAR；TO_CHAR(date,'mask') 已由 _tochar_date 转 DATE_FORMAT
      while(match(line,/TO_CHAR[ \t]*\(/)){
        pos=RSTART
        if(pos>1){ prev=substr(line,pos-1,1); if(prev~/[A-Za-z0-9_]/){ out=out substr(line,1,pos); line=substr(line,pos+1); continue } }
        cpos=pos+RLENGTH-1; epos=match_paren(line,cpos)
        if(epos==0){ note=note "TO_CHAR 跨行需人工; "; out=out line; return out }
        mid=substr(line,cpos+1,epos-cpos-1); n=split_topcomma(mid,A); rep=substr(line,pos,epos-pos+1)
        if (n==1) { if (infer_type(A[1])=="number") rep="CAST(" A[1] " AS CHAR)"; else { note=note "TO_CHAR(" A[1] ") 非 number 单参需人工; "; rep="NULL" } }
        else        { note=note "TO_CHAR(..,..) 多参(number+fmt 或残留 date)需人工; "; rep="NULL" }
        out=out substr(line,1,pos-1) rep; line=substr(line,epos+1)
      }
      return out line }
    function conv_substr(line,   out,pos,prev,cpos,epos,mid,A,n,rep){
      out=""   # SUBSTR(s,0,n)→SUBSTRING(s,1,n)；start>=1 字面量 MySQL SUBSTR 兼容不变；start=变量→NOTE
      while(match(line,/SUBSTR[ \t]*\(/)){
        pos=RSTART
        if(pos>1){ prev=substr(line,pos-1,1); if(prev~/[A-Za-z0-9_]/){ out=out substr(line,1,pos); line=substr(line,pos+1); continue } }
        cpos=pos+RLENGTH-1; epos=match_paren(line,cpos)
        if(epos==0){ note=note "SUBSTR 跨行需人工; "; out=out line; return out }
        mid=substr(line,cpos+1,epos-cpos-1); n=split_topcomma(mid,A); rep=substr(line,pos,epos-pos+1)
        if (n>=2) {
          if (A[2]=="0") rep="SUBSTRING(" A[1] ", 1" (n>=3 ? ", " A[3] : "") ")"   # start=0→1，2/3 参通用（gsub 只匹 3 参会漏 2 参 SUBSTR(s,0)→SUBSTRING(s,0)='' silent）
          else if (A[2] !~ /^[0-9]+$/) { note=note "SUBSTR start 非字面量(" A[2] ") 可能 0 偏移需人工; "; rep="NULL" }
          # start>=1 字面量：原 SUBSTR 在 MySQL 合法（SUBSTRING 别名），不变
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
      if ($0 ~ /^[ \t]*--/) { print; next }      # 跳过注释行（不在注释里标 TODO）
      # 注：原 re_emptyif（IFNULL(x,空串) 的 NVL(x,空串) 语义分歧告警）已移除——|| 忠实转换器会
      # 生成 IFNULL(op,'')，与 NVL(x,'') 文本同形、post-mechanical 无法区分，全量标记只会误报每一处
      # ||。NVL(x,'') 分歧属已知 niche 边缘，由文档记录、不在此标记。
      if ($0 ~ /%TYPE|%ROWTYPE/)                 todo("锚定类型 %TYPE/%ROWTYPE 需解析为具体类型")
      if ($0 ~ /EXECUTE[ \t]+IMMEDIATE/)         todo("动态 SQL EXECUTE IMMEDIATE 需改 PREPARE/EXECUTE/DEALLOCATE")
      if ($0 ~ /BULK[ \t]+COLLECT|FORALL/)       todo("批量操作 BULK COLLECT/FORALL 无直接对应，需改写为游标循环")
      # 注：TRUNC / INSTR / TO_NUMBER / TO_CHAR(number) / SUBSTR(0-offset) / NEXTVAL 现由 _convert_type_aware
      # （Phase 1 类型推断，置 _restructure 后）按 symtab 自动转换；不确定项在那 pass 内注 TODO。此处不再标，避免残留假阳性。
      if ($0 ~ /(^|[^A-Za-z0-9_])TO_DATE[ \t]*\(/)  todo("TO_DATE(复杂参数/无掩码) 需人工 STR_TO_DATE（简单 TO_DATE(str,'mask') 已自动转 STR_TO_DATE，此处排除 STR_TO_DATE 子串假阳性）")
      if ($0 ~ /LISTAGG/)                        todo("LISTAGG(..) WITHIN GROUP(ORDER BY ..) 需改 GROUP_CONCAT(.. ORDER BY .. SEPARATOR ..)")
      if ($0 ~ /DBMS_OUTPUT/)                    todo("DBMS_OUTPUT 需改 SELECT 结果 / 写日志表")
      # 注：EXCEPTION 块（WHEN NO_DATA_FOUND/OTHERS）/ 显式游标 CURSOR..IS / 数值 FOR..IN 现由 _restructure
      # 自动转换（EXIT handler / DECLARE..CURSOR FOR + done / WHILE+计数器）；游标/REVERSE FOR 在 _restructure
      # 内单独标 TODO。此处不再标 FOR/EXCEPTION/CURSOR，避免残留假阳性。
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
      if (active && !closed && !isfunc) {
        $0 = gensub(/([(, \t])([A-Za-z_][A-Za-z0-9_]*)[ \t]+(IN[ \t]+OUT|INOUT|IN|OUT)[ \t]+/, "\\1\\3 \\2 ", "g")
        gsub(/IN[ \t]+OUT/, "INOUT")
      }
      # MySQL 函数参数禁 IN/OUT/INOUT：FUNCTION 参数区直接剥掉模式关键字，留 name type。
      if (active && !closed && isfunc) {
        $0 = gensub(/([A-Za-z_][A-Za-z0-9_]*)[ \t]+(IN[ \t]+OUT|INOUT|IN|OUT)[ \t]+/, "\\1 ", "g")
      }
      depth += (no - nc)
      if (active && !closed && depth<=0 && (no>0||nc>0)) closed=1
      print
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
# 组装序严守 MySQL 强制 DECLARE 序：变量/条件（含 done/v_errmsg）→ 游标 → handler → body。
# 注：顶层为主；嵌套 DECLARE..BEGIN..END / 自定义异常 CONDITION / RAISE_APPLICATION_ERROR / FOR..IN 未覆盖（标 known-limitation）。
_restructure() {
  awk '
    BEGIN { state="pre"; IGNORECASE=1; ltop=0; labeln=0; has_ndf=0; has_others=0; done_needed=0; in_cursor=0 }
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
    # 组装：header(DROP+CREATE+params) → BEGIN → 变量(+done/v_errmsg) → 游标 → handler → body → END
    function assemble(    h, vn, vl, i, vline, vname) {
      printf "%s", hdrbuf
      print "BEGIN"
      if (varbuf != "") {
        vn=split(varbuf, vl, "\n")
        for(i=1;i<=vn;i++){
          vline=vl[i]
          # 若声明的是数值 FOR 计数器变量 → 改 INT DEFAULT <lo>（计数器为整数、初值=FOR 下界）
          if (vline ~ /^DECLARE[ \t]+[A-Za-z_][A-Za-z0-9_]*/) {
            vname=vline; sub(/^DECLARE[ \t]+/,"",vname); sub(/[ \t].*$/,"",vname)
            if (vname in for_lo) vline="DECLARE " vname " INT DEFAULT " for_lo[vname] ";"
          }
          print vline
        }
      }
      if (done_needed)   print "    DECLARE done INT DEFAULT 0;"
      if (has_others)    print "    DECLARE v_errmsg VARCHAR(255);"
      if (curbuf != "")  printf "%s\n", curbuf
      h=""
      if (done_needed) h = h "    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;\n"
      if (has_ndf)     h = h "    DECLARE EXIT HANDLER FOR NOT FOUND\n    BEGIN\n" ndf_body "    END;\n"
      if (has_others)  h = h "    DECLARE EXIT HANDLER FOR SQLEXCEPTION\n    BEGIN\n        GET DIAGNOSTICS CONDITION 1 v_errmsg = MESSAGE_TEXT;\n" others_body "    END;\n"
      if (h != "") printf "%s", h
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
        if (in_cursor) { curbuf=(curbuf==""?"":curbuf "\n") line; if (line ~ /;[ \t]*$/) in_cursor=0; next }
        if (line ~ /^[ \t]*CURSOR[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+IS/) {
          done_needed=1
          core=line; sub(/^[ \t]+/,"",core); sub(/^CURSOR[ \t]+/,"",core); cname=core; sub(/[ \t]+IS.*$/,"",cname)
          rest=line; sub(/^[ \t]*CURSOR[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+IS/,"",rest)
          dline = "    DECLARE " cname " CURSOR FOR" (rest ~ /^[ \t]*$/ ? "" : rest)
          curbuf=(curbuf==""?"":curbuf "\n") dline
          if (line !~ /;[ \t]*$/) in_cursor=1
          next
        }
        if (line ~ /^[ \t]*BEGIN[ \t]*$/) { state="body"; next }            # BEGIN 在 assemble() 里发
        d=conv_decl(line); if (d=="") next; varbuf=(varbuf==""?"":varbuf "\n") d; next
      }
      if (state=="exception") {
        if (line ~ /^[ \t]*WHEN[ \t]+OTHERS[ \t]+THEN/)        { exc_curr="others"; has_others=1; next }
        if (line ~ /^[ \t]*WHEN[ \t]+NO_DATA_FOUND[ \t]+THEN/) { exc_curr="ndf";    has_ndf=1;     next }
        if (line ~ /^[ \t]*WHEN[ \t]+/)                         { exc_curr="other";   next }   # 自定义/其他异常（本批不细映射）
        if (is_sp_end(line)) { assemble(); state="end"; next }
        l=conv_assign(line); gsub(/SQLERRM/, "v_errmsg", l)
        if (exc_curr=="ndf")         ndf_body    = (ndf_body==""?"":ndf_body)    l "\n"
        else if (exc_curr=="others") others_body = (others_body==""?"":others_body) l "\n"
        next
      }
      # state == body
      if (line ~ /^[ \t]*EXCEPTION[ \t]*$/) { state="exception"; exc_curr=""; next }
      if (line ~ /^[ \t]*END[ \t]+LOOP/) {                                     # END LOOP：FOR→SET 计数器+1 + END WHILE label；WHILE→END WHILE；LOOP→保留
        ind=getindent(line)
        if (ltop>0) {
          if (ltype[ltop]=="FOR")      bodybuf=bodybuf ind "    SET " lvar[ltop] " = " lvar[ltop] " + 1;\n" ind "END WHILE " llabel[ltop] ";\n"
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
      if (line ~ /^[ \t]*FOR[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+IN[ \t]+/) {       # 游标 FOR / REVERSE FOR（无数值 .. 范围）→ TODO
        bodybuf=bodybuf line "\t-- TODO(需人工转换): 游标/REVERSE FOR..IN 需改 DECLARE CURSOR+LOOP/FETCH 或反向计数\n"; next
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
      if (line ~ /^[ \t]*CONTINUE[ \t]*;/) {                                   # CONTINUE; → ITERATE label（FOR 内先递增计数器防死循环；允许行尾 -- 注释）
        ind=getindent(line); lbl=(ltop>0?llabel[ltop]:"lp1")
        if (ltop>0 && ltype[ltop]=="FOR") bodybuf=bodybuf ind "SET " lvar[ltop] " = " lvar[ltop] " + 1;\n"
        bodybuf=bodybuf ind "ITERATE " lbl ";\n"; next
      }
      if (line ~ /^[ \t]*CONTINUE[ \t]+WHEN[ \t]+/) {                         # CONTINUE WHEN cond → IF cond THEN (SET+1)? ITERATE
        ind=getindent(line); core=line; sub(/^[ \t]*CONTINUE[ \t]+WHEN[ \t]+/,"",core); sub(/;[ \t]*$/,"",core)
        lbl=(ltop>0?llabel[ltop]:"lp1")
        bodybuf=bodybuf ind "IF " core " THEN\n"
        if (ltop>0 && ltype[ltop]=="FOR") bodybuf=bodybuf ind "    SET " lvar[ltop] " = " lvar[ltop] " + 1;\n"
        bodybuf=bodybuf ind "    ITERATE " lbl ";\n" ind "END IF;\n"; next
      }
      if (line ~ /^[ \t]*EXIT[ \t]+WHEN[ \t]+/) {                              # EXIT WHEN c%NOTFOUND → IF done=1 THEN LEAVE
        ind=getindent(line); core=line; sub(/^[ \t]*EXIT[ \t]+WHEN[ \t]+/,"",core); sub(/;[ \t]*$/,"",core)
        cond = (core ~ /[A-Za-z_][A-Za-z0-9_]*%NOTFOUND/ ? "done = 1" : core)
        lbl=(ltop>0?llabel[ltop]:"lp1")
        bodybuf=bodybuf ind "IF " cond " THEN\n" ind "    LEAVE " lbl ";\n" ind "END IF;\n"; next
      }
      if (line ~ /^[ \t]*EXIT[ \t]*;/) {                                       # 裸 EXIT; → LEAVE label（允许行尾 -- 注释）
        ind=getindent(line); lbl=(ltop>0?llabel[ltop]:"lp1")
        bodybuf=bodybuf ind "LEAVE " lbl ";\n"; next
      }
      if (is_sp_end(line)) { assemble(); state="end"; next }
      l=conv_assign(line); bodybuf=bodybuf l "\n"
    }
  '
}
