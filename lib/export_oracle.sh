#!/usr/bin/env bash
# 模块1：从 Oracle 导出存储过程定义为 .sql 文件。
# 依赖：sqlplus（Oracle Instant Client）。由 bin/spconvert.sh source 后调用 run_export。
set -euo pipefail

# 默认导出的 Oracle 对象类型（可由配置 EXPORT_OBJECT_TYPES 覆盖，冒号分隔）。
# 顺序与 convert.sh 的处理路径对齐：PROCEDURE/FUNCTION 直接转换，
# PACKAGE BODY 经 _split_package_body 拆分，PACKAGE spec 仅导出不自动转换。
_EXPORT_TYPES_DEFAULT='PROCEDURE:FUNCTION:PACKAGE BODY:PACKAGE'

run_export() {
  require_cmd sqlplus
  local conn; conn="$(oracle_connect)"
  local schema="${ORACLE_SCHEMA:-$ORACLE_USER}"
  resolve_dir EXPORT_DIR
  mkdir -p "$EXPORT_DIR"

  # 解析对象类型列表（冒号分隔）。PACKAGE BODY 含空格，须用冒号分隔避免歧义。
  local types_csv="${EXPORT_OBJECT_TYPES:-$_EXPORT_TYPES_DEFAULT}"
  local IFS=$':'
  local -a types=()
  read -r -a types <<<"$types_csv"
  unset IFS
  # 校验每个 token 是合法 Oracle object_type（防用户误用空格/逗号分隔导致 PACKAGE BODY 被拆）。
  local -a _valid=('PROCEDURE' 'FUNCTION' 'PACKAGE' 'PACKAGE BODY' 'TYPE' 'TRIGGER' 'SEQUENCE')
  local _t _v _known
  for _t in "${types[@]}"; do
    [[ -z "$_t" ]] && continue
    _known=0
    for _v in "${_valid[@]}"; do [[ "$_t" == "$_v" ]] && { _known=1; break; }; done
    [[ "$_known" -eq 1 ]] || die "EXPORT_OBJECT_TYPES 含非法值 <$_t>（须冒号分隔，合法值：${_valid[*]})"
  done

  info "导出 schema=$schema 的对象 → $EXPORT_DIR（类型：${types[*]}）"

  local list_file="$EXPORT_DIR/_proc_list.tsv"
  : >"$list_file"

  # 1) 逐类型取清单：owner<TAB>type<TAB>name
  local t type_quoted
  for t in "${types[@]}"; do
    [[ -z "$t" ]] && continue
    # 单引号转义：DBMS_METADATA 的 type 参数 Oracle 内部以字符串匹配，单引号需双写
    type_quoted="${t//\'/\'\'}"
    sqlplus -s -L "$conn" >>"$list_file" <<SQL
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF LINESIZE 32767 TRIMSPOOL ON
WHENEVER OSERROR EXIT FAILURE;
WHENEVER SQLERROR EXIT FAILURE;
SELECT owner || CHR(9) || object_type || CHR(9) || object_name
FROM   all_objects
WHERE  object_type = '$type_quoted'
  AND  owner = UPPER('$schema');
EXIT;
SQL
  done

  local total; total=$(grep -c . "$list_file" || true)
  if [[ "$total" -eq 0 ]]; then warn "schema=$schema 下未发现对象（类型：${types[*]}）"; return 0; fi
  info "发现 $total 个对象"

  # 2) 逐个用 DBMS_METADATA.GET_DDL 拉完整 DDL
  # 文件名规范：${owner}.${name}.sql（与 convert.sh 约定一致）。
  # PACKAGE BODY 的 DDL 含 'CREATE OR REPLACE PACKAGE BODY'，convert.sh 的
  # _split_package_body 会按内容检测并拆分，无需特殊命名。
  local i=0 owner otype name out ddl_type
  while IFS=$'\t' read -r owner otype name; do
    [[ -z "${name:-}" ]] && continue
    i=$((i+1))
    out="$EXPORT_DIR/${owner}.${name}.sql"
    # DBMS_METADATA.GET_DDL 的 type 参数：PACKAGE BODY 需传 'PACKAGE_BODY'（Oracle 内部名）
    # all_objects.object_type 显示为 'PACKAGE BODY'（带空格），需转成下划线形式。
    ddl_type="${otype// /_}"
    sqlplus -s -L "$conn" >"$out" <<SQL
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF LINESIZE 32767 TRIMSPOOL ON LONG 2000000 LONGCHUNKSIZE 2000000
SELECT DBMS_METADATA.GET_DDL('$ddl_type', '$name', '$owner') FROM DUAL;
EXIT;
SQL
    log "  [$i/$total] ${otype} ${owner}.${name} → $(wc -l <"$out") 行"
  done < "$list_file"

  # 3) 导出 schema 列定义 → _schema_columns.tsv（供 convert 的 %TYPE 锚定类型解析）
  # 字段：owner<TAB>table_name<TAB>column_name<TAB>data_type<TAB>data_length<TAB>data_precision<TAB>data_scale<TAB>nullable
  # 失败不阻断 export 主流程（列定义是 convert 的增强数据源，缺则 %TYPE 降级 TODO）。
  local cols_file="$EXPORT_DIR/_schema_columns.tsv"
  if sqlplus -s -L "$conn" >"$cols_file" <<SQL
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF LINESIZE 32767 TRIMSPOOL ON
WHENEVER OSERROR EXIT FAILURE;
WHENEVER SQLERROR EXIT FAILURE;
SELECT owner || CHR(9) || table_name || CHR(9) || column_name || CHR(9) ||
       data_type || CHR(9) || data_length || CHR(9) ||
       NVL(TO_CHAR(data_precision), '') || CHR(9) ||
       NVL(TO_CHAR(data_scale), '') || CHR(9) ||
       nullable
FROM   all_tab_columns
WHERE  owner = UPPER('$schema')
ORDER BY owner, table_name, column_id;
EXIT;
SQL
  then
    local col_count; col_count=$(grep -c . "$cols_file" || true)
    info "schema 列定义导出：$col_count 行 → $cols_file"
  else
    warn "schema 列定义导出失败（%TYPE 解析将降级为 TODO）"
    : >"$cols_file"
  fi

  # 4) 导出自定义函数源码 → _function_sources/*.fnc（供 convert 递归转换自定义函数调用）
  # P3-e：查 all_source WHERE type='FUNCTION'，按 name+line 排序拼接，每个函数一个 .fnc 文件。
  # 失败不阻断 export 主流程（函数源码是 convert 的增强数据源，缺则自定义函数降级 DDL 桩 + TODO）。
  local fn_src_dir="$EXPORT_DIR/_function_sources"
  mkdir -p "$fn_src_dir"
  # 先查函数清单：owner<TAB>name
  local fn_list_file="$EXPORT_DIR/_function_list.tsv"
  if sqlplus -s -L "$conn" >"$fn_list_file" <<SQL
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF LINESIZE 32767 TRIMSPOOL ON
WHENEVER OSERROR EXIT FAILURE;
WHENEVER SQLERROR EXIT FAILURE;
SELECT owner || CHR(9) || name
FROM   all_source
WHERE  type = 'FUNCTION'
  AND  owner = UPPER('$schema')
GROUP BY owner, name
ORDER BY owner, name;
EXIT;
SQL
  then
    local fn_count; fn_count=$(grep -c . "$fn_list_file" || true)
    if [[ "$fn_count" -gt 0 ]]; then
      local fn_owner fn_name fn_out_fn fn_idx=0
      while IFS=$'\t' read -r fn_owner fn_name; do
        [[ -z "${fn_name:-}" ]] && continue
        fn_idx=$((fn_idx+1))
        fn_out_fn="$fn_src_dir/${fn_owner}.${fn_name}.fnc"
        # 拉取函数完整源码（按 line 排序拼接 text 列）
        sqlplus -s -L "$conn" >"$fn_out_fn" <<SQL
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF LINESIZE 32767 TRIMSPOOL ON LONG 2000000 LONGCHUNKSIZE 2000000
SELECT text
FROM   all_source
WHERE  type = 'FUNCTION'
  AND  owner = UPPER('$fn_owner')
  AND  name = UPPER('$fn_name')
ORDER BY line;
EXIT;
SQL
        log "  [FN $fn_idx/$fn_count] FUNCTION ${fn_owner}.${fn_name} → $(wc -l <"$fn_out_fn") 行"
      done < "$fn_list_file"
      info "自定义函数源码导出：$fn_count 个 → $fn_src_dir/"
    else
      info "schema=$schema 下无自定义函数（_function_sources/ 为空）"
    fi
  else
    warn "自定义函数源码导出失败（all_source 权限不足？convert 将降级为 DDL 桩 + TODO）"
    : >"$fn_list_file"
  fi

  info "导出完成：$i 个文件写入 $EXPORT_DIR"
}
