#!/usr/bin/env bash
# common.sh —— 公共函数：日志、配置加载、依赖检查、DB 客户端封装。
# 由 bin/spconvert.sh 与 lib/*.sh 通过 source 引入，不要直接执行。

set -euo pipefail

# ---------- 颜色与日志 ----------
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_RED=''; C_YEL=''; C_GRN=''; C_DIM=''; C_RST=''
fi

log()  { printf '%s[%s]%s %s\n' "$C_DIM" "$(date '+%H:%M:%S')" "$C_RST" "$*"; }
info() { printf '%s[INFO]%s  %s\n'  "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[WARN]%s  %s\n'  "$C_YEL" "$C_RST" "$*"; }
err()  { printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---------- 配置加载 ----------
# 用法: load_config /path/to/config.conf
load_config() {
  local cfg="$1"
  [[ -f "$cfg" ]] || die "配置文件不存在: $cfg"
  # shellcheck disable=SC1090
  set -a; source "$cfg"; set +a
  [[ -n "${ORACLE_HOST:-}" ]] || die "配置缺少 Oracle 连接信息（ORACLE_HOST 等）"
}

# ---------- 依赖检查 ----------
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少依赖命令: $1（请先安装并加入 PATH）"
}

# 校验 sed 是 GNU sed（脚本用 -E 扩展正则、\b 词边界等 GNU/BSD 扩展特性）。
# BSD sed（macOS 默认）的 -E 行为有细微差且不支持 \b，会静默产出错误结果。
require_gnu_sed() {
  command -v sed >/dev/null 2>&1 || die "缺少依赖命令: sed"
  if ! sed --version 2>&1 | grep -qi 'GNU sed'; then
    die "sed 非 GNU 版本（当前：$(sed --version 2>&1 | head -1)）。脚本依赖 GNU sed 的 -E/\\b 等扩展，macOS 需 brew install gnu-sed"
  fi
}

# 校验 awk 是 GNU awk（gawk）。
# 脚本多处用 `awk`，一处显式 `gawk`（convert.sh:251），依赖 gawk 的字段分隔/动态正则等扩展。
# 策略：优先用 gawk；若不存在则要求 awk 指向 GNU Awk（多数 Linux 发行版 awk 即 gawk）。
require_gawk() {
  if command -v gawk >/dev/null 2>&1; then
    return 0
  fi
  command -v awk >/dev/null 2>&1 || die "缺少依赖命令: awk/gawk（请安装 gawk）"
  if ! awk --version 2>&1 | grep -qi 'GNU Awk'; then
    die "awk 非 GNU Awk(gawk)（当前：$(awk --version 2>&1 | head -1)）。脚本依赖 gawk 扩展，macOS 需 brew install gawk"
  fi
}

# ---------- Oracle 连接串 ----------
# 形如 user/pass@//host:port/service
# 注意：口令含 / @ # 等特殊字符时该形式可能失效，需用钱包/转义，见 README。
oracle_connect() {
  : "${ORACLE_USER:?配置缺少 ORACLE_USER}"
  : "${ORACLE_PASS:?配置缺少 ORACLE_PASS}"
  : "${ORACLE_HOST:?配置缺少 ORACLE_HOST}"
  : "${ORACLE_PORT:?配置缺少 ORACLE_PORT}"
  : "${ORACLE_SERVICE:?配置缺少 ORACLE_SERVICE}"
  local charset="${ORACLE_CHARSET:-AL32UTF8}"
  export NLS_LANG="AMERICAN_AMERICA.${charset}"
  printf '%s/%s@//%s:%s/%s' "$ORACLE_USER" "$ORACLE_PASS" "$ORACLE_HOST" "$ORACLE_PORT" "$ORACLE_SERVICE"
}

# ---------- TiDB/MySQL 调用封装 ----------
# 用法: mysql_tidb [mysql 选项...] <<'SQL' ... SQL
mysql_tidb() {
  : "${TIDB_USER:?配置缺少 TIDB_USER}"
  : "${TIDB_HOST:?配置缺少 TIDB_HOST}"
  : "${TIDB_PORT:?配置缺少 TIDB_PORT}"
  : "${TIDB_DB:?配置缺少 TIDB_DB}"
  local pass_args=()
  [[ -z "${TIDB_PASS:-}" ]] || pass_args=(-p"$TIDB_PASS")
  command mysql -h"$TIDB_HOST" -P"$TIDB_PORT" -u"$TIDB_USER" "${pass_args[@]}" -D"$TIDB_DB" "$@"
}

# 把配置里的相对输出目录解析为基于 ROOT_DIR 的绝对路径（幂等）。
# 兼容 Windows 盘符绝对路径（C:/.. C:\..）与 Unix 绝对路径（/..）。
resolve_dir() {
  local var="$1"
  local val="${!var:-}"
  [[ -z "$val" ]] && return 0
  if [[ "$val" != /* && ! "$val" =~ ^[A-Za-z]:[/\\] ]]; then
    printf -v "$var" '%s/%s' "$ROOT_DIR" "$val"
  fi
}
