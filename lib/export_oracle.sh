#!/usr/bin/env bash
# 模块1：从 Oracle 导出存储过程定义为 .sql 文件。
# 依赖：sqlplus（Oracle Instant Client）。由 bin/spconvert.sh source 后调用 run_export。
set -euo pipefail

run_export() {
  require_cmd sqlplus
  local conn; conn="$(oracle_connect)"
  local schema="${ORACLE_SCHEMA:-$ORACLE_USER}"
  resolve_dir EXPORT_DIR
  mkdir -p "$EXPORT_DIR"

  info "导出 schema=$schema 的存储过程 → $EXPORT_DIR"

  # 1) 取过程清单：owner<TAB>name
  local list_file="$EXPORT_DIR/_proc_list.tsv"
  sqlplus -s -L "$conn" >"$list_file" <<SQL
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF LINESIZE 32767 TRIMSPOOL ON
WHENEVER OSERROR EXIT FAILURE;
WHENEVER SQLERROR EXIT FAILURE;
SELECT owner || CHR(9) || object_name
FROM   all_objects
WHERE  object_type = 'PROCEDURE'
  AND  owner = UPPER('$schema');
EXIT;
SQL

  local total; total=$(grep -c . "$list_file" || true)
  if [[ "$total" -eq 0 ]]; then warn "schema=$schema 下未发现存储过程"; return 0; fi
  info "发现 $total 个存储过程"

  # 2) 逐个用 DBMS_METADATA.GET_DDL 拉完整 DDL
  local i=0 owner name out
  while IFS=$'\t' read -r owner name; do
    [[ -z "${name:-}" ]] && continue
    i=$((i+1))
    out="$EXPORT_DIR/${owner}.${name}.sql"
    sqlplus -s -L "$conn" >"$out" <<SQL
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF LINESIZE 32767 TRIMSPOOL ON LONG 2000000 LONGCHUNKSIZE 2000000
SELECT DBMS_METADATA.GET_DDL('PROCEDURE', '$name', '$owner') FROM DUAL;
EXIT;
SQL
    log "  [$i/$total] ${owner}.${name} → $(wc -l <"$out") 行"
  done < "$list_file"

  info "导出完成：$i 个文件写入 $EXPORT_DIR"
}
