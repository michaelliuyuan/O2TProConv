# oracle2tidb-sp

基于 **纯 shell** 的 Oracle 存储过程 → TiDB（MySQL 兼容）转换与对比工具。
对齐架构设计文档 `oracle-sp-to-tidb-sp-design.md`（模块设计 / 规则映射表 / 转换置信度报告 / 对比契约 / 风险）。

## 能力（设计文档 §1）

1. **export**：配 Oracle 连接 → 拉 PROCEDURE/FUNCTION/PACKAGE BODY/PACKAGE 定义 → 导出 `.sql`（类型可配，见 `EXPORT_OBJECT_TYPES`）。
2. **convert**：Oracle（PL/SQL）SP → TiDB 语法 SP（+ 转换置信度报告）。
3. **compare**：配 Oracle + TiDB → 跑 SP → 性能 + 结果一致性对比 → 报告。
4. **capability**：M1 硬前置，对目标 TiDB 跑能力探针。

> TiDB 存储过程兼容 MySQL 语法。

## 架构与转换管线

转换在 `lib/convert.sh` 内按**有序管线**逐 pass 处理每个 `.sql`，每 pass 只读 stdin、写 stdout。转换链路（`convert_one()`）：

| 顺序 | pass | 职责 |
|------|------|------|
| 1 | `_tochar_date` | `TO_CHAR(date,'mask')`→`DATE_FORMAT(date,'%mask')` + `TO_DATE(s,'mask')`→`STR_TO_DATE(s,'%mask')`（须在机械层前，否则 `NOW()` 带括号匹配不到） |
| 2 | `_resolve_anchor_type` | `%TYPE` 锚定类型解析：查 `exported/_schema_columns.tsv` 将 `table.column%TYPE`/`owner.table.column%TYPE` 替换为 Oracle 原生类型（输出 `VARCHAR2(n)`/`NUMBER(p,s)` 等，由后续 `_apply_mechanical` 统一转 MySQL）；无 schema 数据或列未匹配 → 原样保留由 `_mark_complex` 兜底 TODO |
| 3 | `_apply_mechanical` | 确定性 token 替换（类型 / `NVL` / `SYSDATE` / `ELSIF` / 去 Oracle `/` …） |
| 4 | `_convert_known_semantics` | 忠实语义：`DECODE`→`CASE(<=>)`、`||`→`NULLIF(CONCAT(IFNULL…),'')`、`LISTAGG(..) WITHIN GROUP(ORDER BY ..)`→`GROUP_CONCAT(.. ORDER BY .. SEPARATOR ..)` |
| 5 | `_fix_header` | 头部双引号标识符→反引号、去 `owner.` 前缀 |
| 6 | `_mark_complex` | 复杂结构（`%ROWTYPE` / `BULK COLLECT` / 未解析的 `%TYPE` / `EXECUTE IMMEDIATE` INTO 子句 / …）注入 `-- TODO` |
| 7 | `_rewrite_header` | `CREATE OR REPLACE` → `DROP IF EXISTS`+`CREATE`；FUNCTION 头 `RETURN<type>`→`RETURNS<type>` |
| 8 | `_param_mode` | 参数模式前置（`name IN type`→`IN name type`）；FUNCTION 参数剥 `IN/OUT` |
| 9 | `_restructure` | 结构改写：删 `AS/IS`、`:=` 两态、DECLARE 序重排、EXCEPTION→EXIT handler、显式游标、WHILE/FOR/CONTINUE |

**三层 + 一条原则**：

- **机械层**：确定性 token / 模式替换，零歧义。
- **忠实语义层**：已知 Oracle↔MySQL 语义差，**默认开启**，产出与 Oracle 等价的 MySQL 写法。
- **结构改写层**：Oracle `AS <decls> BEGIN <body> [EXCEPTION] END` → MySQL `BEGIN <vars> <cursors> <handlers> <body> END`，严守 MySQL 强制 DECLARE 序（变量/条件 → 游标 → handler）。
- **原则（诚实边界）**：正则无法可靠判定的（跨行表达式、嵌套结构、字面量与运算符混排）**不臆造**，原样保留 + `-- TODO` + 报告汇总——强行转换的静默错误比「提示人工」更坏（典型：MySQL `||` 默认是逻辑或而非拼接）。

## 依赖

bash ≥ 4；Oracle 侧 `sqlplus`/`sqlcl`；TiDB 侧 `mysql`；**GNU `sed`/`gawk`**；可选 `bc`/`jq`。

> **工具链校验**：convert/compare 启动时会自动校验 `sed`/`awk` 是 GNU 版本（`require_gnu_sed`/`require_gawk`）：
> - **GNU sed**：脚本依赖 `-E` 扩展正则、`\b` 词边界等 GNU 特性。BSD sed（macOS 默认）行为有差异且不支持 `\b`，会**静默产出错误结果**——校验不通过会 `die` 并提示 `brew install gnu-sed`。
> - **gawk 优先策略**：PATH 有 `gawk` 直接用之；否则校验 `awk` 指向 GNU Awk（多数 Linux 发行版 `awk` 即 `gawk`）。macOS 默认 `awk` 非 gawk，需 `brew install gawk`。
> - convert 重度依赖 GNU sed + gawk；compare 多处用 awk（仅校验 gawk）。export/capability 不依赖这两个工具。

> **`%TYPE` 锚定类型解析（schema 内省）**：export 阶段会额外拉 `all_tab_columns`（owner/table_name/column_name/data_type/data_length/data_precision/data_scale/nullable）→ `exported/_schema_columns.tsv`，convert 的 `_resolve_anchor_type` pass 据此将 `table.column%TYPE` 解析为具体类型。**离线 fallback**：无 Oracle 连接（仅 convert 已导出文件）或列未匹配时，`%TYPE` 降级回 `-- TODO`（不臆造，保「离线可用」）。需要 export 用户对 `all_tab_columns` 有 SELECT 权限。

## 目录结构

```
oracle2tidb-sp/
├── ora2tidb.conf            # 配置：Oracle/TiDB 连接、输出目录、compare 参数
├── bin/ora2tidb             # 主入口：export|convert|compare|capability|all
├── lib/
│   ├── common.sh           # 日志/配置/依赖/DB 客户端封装
│   ├── export_oracle.sh    # 模块1：Oracle 对象 → .sql（DBMS_METADATA.GET_DDL；PROCEDURE/FUNCTION/PACKAGE BODY/PACKAGE，类型可配）
│   ├── convert.sh          # 模块2：PL/SQL → TiDB（机械规则 + TODO 标记 + 报告）
│   └── compare.sh          # 模块3：对比（已就绪：用例校验；待 M3：执行）
├── capability-check/        # M1：TiDB 能力探针（6 探针 + 运行器）
├── docs/
│   └── compare-case-contract.md  # compare 用例格式契约
├── exported/ converted/ reports/  # 产物（.gitignore）
```

> 与设计文档 §3 的小偏差：规则脚本暂集中于 `lib/convert.sh` 而非 `bin/lib/convert_rules.d/`（功能等价，M2 拆分时再分文件）。

## 使用示例（Usage）

按真实工作流走一遍：**依赖检查 → 配置 → 能力探针 → 导出 → 转换 → 部署 → 对比**。命令可直接复制（按你的连接改 `ora2tidb.conf`）。`-c` 可放在子命令前或后。

### 0. 前置：依赖检查

```bash
bash --version | head -1                 # bash ≥ 4
command -v sqlplus mysql sed awk          # Oracle/TiDB 客户端 + GNU 工具
sed --version | head -1                   # 须含 'GNU sed'（BSD sed 会静默错，macOS 需 brew install gnu-sed）
awk --version | head -1                   # 须含 'GNU Awk'（或 PATH 有 gawk；macOS 需 brew install gawk）
```

> convert/compare 启动时会自动做上述 GNU 版本校验，不通过直接 `die`，避免 BSD 工具链静默产出错误结果。

### 1. 配置连接

```bash
cp ora2tidb.conf.example ora2tidb.conf
# 编辑 ora2tidb.conf：
#   ORACLE_USER/PASS/HOST/PORT/SERVICE   Oracle 连接（export 导出 + compare 对比）
#   TIDB_USER/PASS/HOST/PORT/DB           TiDB 连接（compare 对比 + capability 探针）
#   EXPORT_DIR/CONVERTED_DIR/REPORT_DIR   产物目录（相对项目根，也可绝对路径）
#   EXPORT_OBJECT_TYPES                   导出对象类型（冒号分隔；留空=默认 PROCEDURE:FUNCTION:PACKAGE BODY:PACKAGE）
```

### 2. 能力探针（capability）—— 验目标 TiDB 支持

```bash
./bin/ora2tidb capability -c ora2tidb.conf
```

6 探针逐个 CREATE+CALL，出 `reports/capability_report.md` 矩阵。实测输出（TiDB v7.1.9）：

```
01_basic_io        ✅ 通过
02_declare_order   ✅ 通过
03_dynamic_sql     ✅ 通过
04_stored_function ✅ 通过
05_builtin_compat  ✅ 通过
06_bare_assign     ❌ 失败  ERROR 1064 ... near ":= 10"
[INFO] 能力探针完成：通过 5 / 失败 1
```

> 06 失败是**预期**——TiDB 不支持裸 `:=` 赋值，坐实转换器 `:=`→`SET` 必要性。02 实证 MySQL/TiDB DECLARE 强制序（变量/条件 → 游标 → handler）。`GET DIAGNOSTICS`（OTHERS handler 用）未在矩阵内，已单测确认支持。

### 3. 导出 Oracle 对象（export）

```bash
./bin/ora2tidb export -c ora2tidb.conf
# 默认按 EXPORT_OBJECT_TYPES（PROCEDURE:FUNCTION:PACKAGE BODY:PACKAGE）逐类型
# DBMS_METADATA.GET_DDL 拉完整 DDL → exported/<OWNER>.<NAME>.sql
# PACKAGE BODY 的 DDL 会被 convert 阶段 _split_package_body 自动拆分（见 FAQ）
```

### 4. 转换（convert）—— PL/SQL → TiDB + 报告

```bash
./bin/ora2tidb convert -c ora2tidb.conf
# exported/*.sql → converted/*.tidb.sql + reports/convert_report.md
```

报告示例：
```
| 过程                 | 状态       | TODO 标记数 |
|----------------------|------------|------------|
| sp_exception_handler | 已自动转换 |          0 |
| sp_explicit_cursor   | 已自动转换 |          0 |
| sp_while_paging      | 已自动转换 |          0 |
| sp_calc_bonus        | 需人工复核 |          1 |   ← 残字面 ||，见部署 Step 5

## 默认长度/精度填充 NOTE（不静默）
- sp_calc_bonus：VARCHAR(4000)×1，DECIMAL(65,30)×2
- VARCHAR(4000)：Oracle 参数裸 VARCHAR2 → MySQL VARCHAR 须带长度（4000 安全默认，不按列推断）。
- DECIMAL(65,30)：裸 NUMBER 安全兜底；高 scale NUMBER 有截断风险，请人工核对。

## 语义差异 NOTE（已转但有已知差，需核对）
- sp_xxx：SYS_GUID()→UUID()（32-hex vs 36 带连字符）
- sp_yyy：MONTHS_BETWEEN→TIMESTAMPDIFF（小数月 vs 整数月截断）

## TODO 明细（需人工转换项，按文件+行号定位）
下列行被标记 `-- TODO(需人工转换)`——正则无法可靠转换，需人工处理。定位格式：`输出文件:L行号`。

- **sp_calc_bonus**（sp_calc_bonus.tidb.sql:L12）：跨表达式 || 需人工或走 Route A
- **sp_a**（sp_a.tidb.sql:L6）：%ROWTYPE 锚定类型需 schema 内省
- **sp_a**（sp_a.tidb.sql:L8）：BULK COLLECT 需改游标循环
- **sp_b**（sp_b.tidb.sql:L1）：EXECUTE IMMEDIATE 需转 PREPARE/EXECUTE
```

> 报告含四段：① 逐过程状态表（TODO 计数）② 默认长度/精度填充 NOTE ③ 语义差异 NOTE ④ **TODO 明细**（按 `文件:L行号` 定位，直接跳转处理，无需手动 grep 输出文件）。

### 5. 部署到 TiDB —— ⚠️ Route A：`PIPES_AS_CONCAT`

转换出的 SP 可能含字面 `||`（Oracle 拼接）。MySQL/TiDB **默认 `||`=OR（逻辑或）**，须设 `PIPES_AS_CONCAT` 让 `||`=CONCAT。
**关键：`sql_mode` 在 SP「创建时」编译锁定，CALL 时不再按 session 重解析 → 必须 `SET GLOBAL` 后再 CREATE。**

```sql
-- 1) 显式列全 mode + PIPES_AS_CONCAT（勿用 CONCAT(@@sql_mode,..)——@@sql_mode 读的是 session 值）
SET GLOBAL sql_mode = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION,PIPES_AS_CONCAT';
SELECT @@GLOBAL.sql_mode;            -- 2) 验证含 PIPES_AS_CONCAT
-- 3) 在此模式下创建所有转换出的 SP（DROP 已在文件头、幂等）
USE o2t_sp_test;
SOURCE converted/sp_calc_bonus.tidb.sql;
SOURCE converted/sp_format_report.tidb.sql;
-- ... 其余 SP
```

> **NULL 边界**：含 NULL 操作数的 `||`（如 `fn_null_concat`）converter 已自动转
> `NULLIF(CONCAT(IFNULL(..)),'')`——NULL 安全、不依赖 sql_mode（`PIPES_AS_CONCAT` 的 `||` 遇 NULL 整体 NULL ≠ Oracle 视 NULL 为空串）。
> **全局影响**：`PIPES_AS_CONCAT` 对该库所有连接的所有 `||` 生效；库上若有别的应用用 `||` 做 OR 需评估。

### 6. 对比（compare）—— 一致性 + 性能

离线校验用例格式（不需 DB）：

```bash
./bin/ora2tidb compare --validate-cases ../ora2tidb-sp-tests/cases
```

实测输出：

```
== 覆盖一致性（test-cases.md ↔ *.cases）==
  [用例组] 规格有/用例无（漏跑风险）：✅ 无
  [SP]    用例有/规格无（未评审风险）：fn_decode_null / fn_null_concat / sp_continue_demo / sp_numeric_for
  TC-T1-01×3  02×2  03×3  04×2  08×4  11×2  |  TC-T2-05×2  06×3  07×4  09×4  10×4
[INFO] 用例校验完成（格式 + 覆盖）
```

> 「用例有/规格无」= 某个 SP 加了 `.cases` 但没同步进 `test-cases.md` 规格表——补齐 spec 即全绿。

执行对比（需两端连接，M3）：

```bash
./bin/ora2tidb compare -c ora2tidb.conf   # 两端跑用例 → 归一化 → diff + p50/p99 加速比
```

> M3 手动实跑真值：**单次连贯 33/33 一致性全绿 @ `c9c2718`（Route A）**——一个 mysql session、33 CALL 连贯跑（非跨轮聚合），归一化后 vs Oracle 基线零 diff。覆盖 11 SP（T1×16 + T2×17），含 `||`/NOT_FOUND EXIT/游标 top1/0 行/NULL-`||`/1..0 空循环/CONTINUE 不死循环/NULL-search DECODE 全分支。perf 见 `results/perf-oracle-vs-tidb.md`（信息性：Oracle PL/SQL 原生循环调用 ≈0 vs TiDB CALL ~3.5ms 固有调度底，SP-heavy OLTP 迁移需评估）。

### 一键全流程

```bash
./bin/ora2tidb all -c ora2tidb.conf   # export → convert（compare 为 M3，未串入）
```

## 转换示例（Oracle → TiDB，真实输出）

以一个含类型映射 / `:=` / `||` / EXCEPTION 的小过程为例（`convert_one` 实际产出）。

**输入**（Oracle PL/SQL，`exported/calc_status.sql`）：

```sql
CREATE OR REPLACE PROCEDURE calc_status(
    p_empno IN NUMBER,
    p_status OUT VARCHAR2
) AS
    v_sal NUMBER;
    v_grade NUMBER;
BEGIN
    SELECT salary INTO v_sal FROM emp WHERE empno = p_empno;
    v_grade := CASE WHEN v_sal >= 3000 THEN 1 ELSE 2 END;
    p_status := 'EMP:' || p_empno || '/G:' || v_grade;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        p_status := 'NOT_FOUND';
    WHEN OTHERS THEN
        p_status := 'ERR:' || SQLERRM;
END;
/
```

**输出**（`converted/calc_status.tidb.sql`，转换器实际产出）：

```sql
DROP PROCEDURE IF EXISTS `calc_status`;
DELIMITER //
CREATE PROCEDURE calc_status(
    IN p_empno DECIMAL(65,30),
    OUT p_status VARCHAR(4000)
)
BEGIN
DECLARE v_sal DECIMAL(65,30);
DECLARE v_grade DECIMAL(65,30);
    DECLARE v_errmsg VARCHAR(255);
    DECLARE EXIT HANDLER FOR NOT FOUND
    BEGIN
        SET p_status = 'NOT_FOUND';
    END;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 v_errmsg = MESSAGE_TEXT;
        SET p_status = NULLIF(CONCAT(IFNULL('ERR:',''), IFNULL(v_errmsg,'')),'');
    END;
    SELECT salary INTO v_sal FROM emp WHERE empno = p_empno;
    SET v_grade = CASE WHEN v_sal >= 3000 THEN 1 ELSE 2 END;
    SET p_status = NULLIF(CONCAT(IFNULL('EMP:',''), IFNULL(p_empno,''), IFNULL('/G:',''), IFNULL(v_grade,'')),'');
END
//
DELIMITER ;
```

**改了什么**（源 → 输出）：

| Oracle 源 | TiDB 输出 | 转换 pass |
|-----------|-----------|-----------|
| 裸 `NUMBER` / `VARCHAR2` | `DECIMAL(65,30)` / `VARCHAR(4000)`（报告 NOTE 不静默） | 机械层 |
| `name IN type` | `IN name type` | `_param_mode` |
| `:=`（执行段） | `SET … = …` | `_restructure` |
| `'EMP:' \|\| p_empno \|\| …` | `NULLIF(CONCAT(IFNULL('EMP:',''),IFNULL(p_empno,''),…),'')` | 忠实语义层 |
| `EXCEPTION WHEN NO_DATA_FOUND` | `DECLARE EXIT HANDLER FOR NOT FOUND BEGIN … END` | `_restructure` |
| `WHEN OTHERS … SQLERRM` | `DECLARE EXIT HANDLER FOR SQLEXCEPTION … GET DIAGNOSTICS … v_errmsg` | `_restructure` |
| `CREATE OR REPLACE PROCEDURE` | `DROP PROCEDURE IF EXISTS` + `CREATE`（幂等） | `_rewrite_header` |
| Oracle `/` 终止行 | 去除；`DELIMITER //` 包裹 | `_apply_mechanical` + `convert_one` |
| 声明序 | **变量 → handler**（MySQL 强制序，handler 最后） | `_restructure` assemble |

## 测试与验收报告

### 三维度验收

| 维度 | 方法 | 通过准则 |
|------|------|----------|
| 转换正确性·编译 | 转换器输出在 TiDB `CREATE` | T1+T2 全 CREATE 成功、`DROP IF EXISTS` 幂等 |
| 转换正确性·golden | 转换器输出 vs `golden/` 归一化文本 diff | 无语义差（仅格式差容忍） |
| 结果一致性 | 共享 schema 两端同入参 CALL，归一化值级 diff | 全用例两端一致 |
| T3 标记 | T3 样例被识别 | 全部打 `-- TODO` 并进报告 |
| 性能 | 同入参两端各 CALL N 次 | 产出 p50/p99/加速比（信息性，不阻断） |

### 验收结果（Oracle 23ai + TiDB v7.1.9，Route A）

| 维度 | 结果 |
|------|------|
| 编译 | **T1+T2 共 8/8 CREATE-OK** ✅ |
| golden 语义 | 通过（仅反引号 / `//` / DETERMINISTIC 格式差）✅ |
| 结果一致性 | **单次连贯 33/33 全绿 @ `c9c2718`**（一个 mysql session、33 CALL、归一化后 vs Oracle 基线零 diff；覆盖 11 SP：T1×16 + T2×17）✅ |
| T3 标记 | `%ROWTYPE` / BULK COLLECT / EXECUTE IMMEDIATE / 集合 / 游标 FOR 全标 TODO ✅；PACKAGE（spec+body）→ ⚠️ 转换失败/需人工（defensive check，Phase 2/T3 支持） |
| 性能 | 报告产出 ✅ |

**结构层转换逐条实证正确**：EXCEPTION→EXIT handler（NOT_FOUND 分叉对）、显式游标（top1 降序 + 0 行）、WHILE 分页、FUNCTION/INOUT、NULL-`||` 忠实写法、DECODE-`<=>`（NULL-search 实证 `<=>` 必要：simple CASE 漏判）、数值 FOR（含 1..0 空循环）、CONTINUE（前置递增无死循环）。

### 测试中回流修复的 7 个 converter bug

| # | bug | 发现 → 修复 |
|---|-----|-------------|
| 1 | `_restructure` 未定义 → convert 零输出 | `d34fb7a` → `ab04900` |
| 2 | 裸 VARCHAR2→VARCHAR（丢长度）4/7 CREATE 失败 | `ab04900` → `27527b6` |
| 3 | FUNCTION 参数误带 IN | `ab04900` → `27527b6` |
| 4 | WHILE...LOOP 未转 | `ab04900` → `27527b6` |
| 5 | EXCEPTION 块未转 | `ab04900` → `27527b6` |
| 6 | 显式游标 CURSOR..IS 未转 | `ab04900` → `27527b6` |
| 7 | 单行 FUNCTION 头 RETURN→RETURNS（type 正则漏逗号） | `27527b6` → `7dff66b` |

> 测试语料库（companion 目录 `ora2tidb-sp-tests/`，由测试工程师维护）：17 个分级 Oracle SP 样例（T1×6 / T2×5 / T3×6）+ golden + 用例 + 共享 schema + 测试计划。分级 = 转换置信度（T1 简单 / T2 中等 / T3 复杂预期 TODO）。详细结果见语料库 `results/`。

## 里程碑（设计文档 §7）

- **M1** export 模块 + TiDB SP 能力验证 — ✅ 代码就绪 + 能力探针实跑通过（TiDB v7.1.9，含 GET DIAGNOSTICS 实证）
- **M2** convert 规则引擎 + 转换置信度报告 — ✅ 机械规则 + **结构层**（EXCEPTION→EXIT handler / 显式游标 / WHILE→DO / 数值 FOR→WHILE+计数器 / CONTINUE→ITERATE / `:=`→SET / DECLARE 序重排 / END 规范）+ 忠实 `||`/`DECODE`(`<=>`) + `TO_CHAR(date)`→`DATE_FORMAT` + 报告（含默认长度 NOTE）；**T1+T2 验收通过（8/8 CREATE + golden + 一致性）**；DATE→DATETIME / 嵌套块 / T3 族 deferred（标 TODO）
- **M3** compare harness — ✅ 用例契约 + `--validate-cases` 离线校验 + `--run` 执行对比（CALL/归一/diff/perf p50/p99/报告）
- **M4** 一键 `all` + 加固

## 转换覆盖（诚实边界，详见设计文档 §5）

**自动转换（机械 + 结构 + 忠实语义）**：
- 类型：`VARCHAR2→VARCHAR`、`NVARCHAR2→NVARCHAR`（裸类型给安全默认长度 `VARCHAR(4000)`）、`NUMBER(p,s)→DECIMAL(p,s)`、裸 `NUMBER→DECIMAL(65,30)`、`PLS_INTEGER/BINARY_INTEGER→INT`、`RAW(n)→VARBINARY(n)`
- 锚定类型 `%TYPE`：`table.column%TYPE` / `owner.table.column%TYPE` → 查 `exported/_schema_columns.tsv` 替换为 Oracle 原生类型（如 `NUMBER(6,0)`），再经机械层统一转 MySQL（如 `DECIMAL(6,0)`）；`column%TYPE`（无表前缀）由 `_convert_type_aware` symtab 解析。无 schema 数据或列未匹配 → 降级 TODO
- 内置：`NVL→IFNULL`、`SYSDATE→NOW()`、`SYSTIMESTAMP→CURRENT_TIMESTAMP(6)`、`TO_CHAR(date,'mask')→DATE_FORMAT`、`TO_DATE(str,'mask')→STR_TO_DATE`、`LENGTH→CHAR_LENGTH`、`CHR→CHAR`、`SYS_GUID()→UUID()`⚠️、`NVL2(a,b,c)→IF(a IS NOT NULL,b,c)`⚠️、`ADD_MONTHS(d,n)→DATE_ADD(d,INTERVAL n MONTH)`、`MONTHS_BETWEEN(a,b)→TIMESTAMPDIFF(MONTH,b,a)`⚠️参数反转、`ELSIF→ELSEIF`
- 忠实语义：`a||b→NULLIF(CONCAT(IFNULL(a,''),IFNULL(b,'')),'')`（简单链，NULL 安全）、`DECODE(e,s1,r1,..,def)→CASE WHEN e<=>s1 THEN r1 .. ELSE def END`（`<=>` null-safe）、`LISTAGG(expr,sep) WITHIN GROUP(ORDER BY sortcol)→GROUP_CONCAT(expr ORDER BY sortcol SEPARATOR sep)`（无 separator 默认空串；`LISTAGG OVER(PARTITION BY..)` 分析函数形式标 TODO——MySQL GROUP_CONCAT 不支持；**跨行 OVER 漏检见下方已知限制**）
- ⚠️ **语义差异 NOTE**（已转但有已知差，转换报告「语义差异 NOTE」段列出，需核对）：`SYS_GUID()→UUID()`（Oracle 32-hex 无连字符 vs MySQL 36 带连字符）、`MONTHS_BETWEEN→TIMESTAMPDIFF`（Oracle 小数月 vs MySQL 整数月截断）、`NVL2→IF`（Oracle `''≡NULL` vs MySQL `''≠NULL`，空串路径分歧）。
- 结构：EXCEPTION 块→`EXIT HANDLER`（NO_DATA_FOUND→`FOR NOT FOUND`、OTHERS→`FOR SQLEXCEPTION`+`GET DIAGNOSTICS`+`SQLERRM→v_errmsg`）；显式游标 `CURSOR c IS`→`DECLARE c CURSOR FOR`（+done 标志 + `CONTINUE HANDLER FOR NOT FOUND` + label + `EXIT WHEN c%NOTFOUND`→`IF done=1 THEN LEAVE`）；游标 `FOR rec IN c LOOP`→`OPEN c` + `label:LOOP` + `FETCH c INTO rec`（**FETCH INTO 标 TODO：MySQL 无 RECORD 类型，需人工展开为标量变量列表**）+ done check + body + `END LOOP label` + `CLOSE c`（半自动）；`EXECUTE IMMEDIATE 'sql' [USING ..]`→`SET @sql=..; PREPARE stmt FROM @sql; EXECUTE stmt [USING ..]; DEALLOCATE PREPARE stmt;`（**INTO 子句标 TODO：MySQL PREPARE 无单行 SELECT 返回，需改游标**）（半自动）；`WHILE..LOOP`→`WHILE..DO`；数值 `FOR v IN lo..hi LOOP`→`DECLARE v INT DEFAULT lo; WHILE v<=hi DO`（+计数器递增）；`FOR v IN REVERSE lo..hi LOOP`→`DECLARE v INT DEFAULT hi; WHILE v>=lo DO`（计数器递减）；`CONTINUE`→`ITERATE label`（forward FOR 内前置递增防死循环；REVERSE FOR 内前置递减防死循环；游标 FOR 内直接 ITERATE，FETCH 在循环顶自动推进）；`:=`→`SET`/`DEFAULT`；DECLARE 序重排（变量/条件→游标→handler）；头部 `CREATE OR REPLACE`→`DROP IF EXISTS`+`CREATE`、双引号→反引号、去 owner 前缀、`RETURN<type>→RETURNS<type>`；去 Oracle `/` 终止行；`DELIMITER //` 包裹；嵌套 `DECLARE..BEGIN..END`（简单块→MySQL `BEGIN..END`，含 EXCEPTION 的标 TODO）。

**自动标记 `-- TODO(需人工转换)`**：跨表达式/跨行 `||`（**Route A 下留字面交 PIPES_AS_CONCAT**，TODO 标部署要求——见 Usage Step 5）、`%ROWTYPE`、未解析的 `%TYPE`（无 schema 数据或列未匹配）、`EXECUTE IMMEDIATE` 的 INTO 子句（MySQL PREPARE 无单行 SELECT 返回）、`LISTAGG OVER(PARTITION BY..)` 分析函数形式（MySQL GROUP_CONCAT 不支持）、`BULK COLLECT/FORALL`、`TO_CHAR(number/复杂)`、`DBMS_OUTPUT`、内联游标 `FOR rec IN (SELECT..)`、`GOTO`（MySQL 不支持）、嵌套 `DECLARE..BEGIN..END`（含 EXCEPTION 的复杂嵌套块）。

> ⚠️ **已知限制（LISTAGG OVER 跨行漏检）**：`LISTAGG OVER(PARTITION BY..)` 当 `OVER` 与 `LISTAGG(..) WITHIN GROUP(..)` 在**同一行**时正确标 TODO；当 `OVER` 在**下一行**（跨行）时，逐行处理的 `conv_listagg` 检测不到 → 静默转 `GROUP_CONCAT` 并残留孤立 `OVER (..)`（产出 MySQL 语法错误）。建议源码规范 `LISTAGG OVER` 写在同一行，或转换后人工检查残留 `OVER`。后续 `_mark_complex` 可能加跨行兜底检测。

> **FOR 计数器自动 DECLARE**：Oracle 的 FOR 循环变量（`FOR v IN lo..hi` / `FOR v IN REVERSE lo..hi` 的 `v`）是**隐式声明**的。转换器 assemble 阶段会自动注入 `DECLARE v INT DEFAULT <lo 或 hi>;`（forward 初始化=`lo`，REVERSE 初始化=`hi`）——无论源码中 `v` 是否显式 DECLARE。已显式声明的不会重复注入。

**PACKAGE BODY 拆分**：export 默认导出 PACKAGE BODY（`EXPORT_OBJECT_TYPES` 含 `PACKAGE BODY`），convert 阶段 `_split_package_body` 检测 `CREATE OR REPLACE PACKAGE BODY` → 自动提取内部 PROCEDURE/FUNCTION 为独立 `.sql` 分别转换，PACKAGE 级变量/类型/游标声明不随子程序迁移（需人工，见 FAQ）。PACKAGE spec（仅声明）导出但不自动转换。

**覆盖率**：T1+T2 常见 SP 定义 8/8 全自动转换（corpus 实测 CREATE + golden + 一致性通过）；复杂 T3（`%ROWTYPE` / BULK COLLECT / 集合 / 内联游标 FOR）标 `-- TODO` 走人工（`%TYPE` 已支持自动解析；游标 `FOR rec IN cur LOOP` 半自动：OPEN/FETCH/CLOSE 框架自动，FETCH INTO 展开标 TODO；`EXECUTE IMMEDIATE` 半自动：PREPARE/EXECUTE/DEALLOCATE 框架自动，INTO 子句标 TODO）；PACKAGE BODY 自动拆分+转换。**诚实边界**：纯正则无法区分字符串字面量与代码、无法处理嵌套，强行转换比「提示人工」更坏——不可靠处留 `-- TODO`，均不臆造。转换报告含 **TODO 明细**段（按 `文件:L行号` 定位每条 TODO 原因），便于人工直接跳转处理，无需手动 grep 输出文件。

## 进度

- [x] 仓库骨架 + `ora2tidb` 入口 + 配置（对齐设计文档）
- [x] 模块1 export（sqlplus + `DBMS_METADATA.GET_DDL`；PROCEDURE/FUNCTION/PACKAGE BODY/PACKAGE，类型可配 `EXPORT_OBJECT_TYPES`）
- [x] 模块2 convert（机械规则 + **结构层**：EXCEPTION→EXIT handler / 显式游标 / WHILE→DO / 数值 FOR / CONTINUE / `:=`→SET / DECLARE 序重排 + 忠实 `||`/`DECODE`(`<=>`) + 报告含默认长度 NOTE + 语义差异 NOTE + **TODO 明细（文件:行号定位）**）
- [x] M1 能力探针 6 个 + 运行器，**实跑通过**（TiDB v7.1.9，含 GET DIAGNOSTICS 实证）
- [x] compare 用例格式契约 + `--validate-cases` 离线校验
- [x] **T1+T2 验收**：8/8 CREATE + golden diff + 一致性通过（1/7→8/8）
- [x] Route A 部署方案（global `PIPES_AS_CONCAT` + SP 创建时锁定，见 Usage Step 5）
- [x] M3 compare 执行对比（两端调用/归一/diff/perf 计时 p50/p99/报告）
- [x] DATE→DATETIME 类型转换（`_apply_mechanical` 内 `\bDATE\b→DATETIME`，日期字面量保留 `DATE '...'`）
- [x] 嵌套 DECLARE..BEGIN..END 转换（简单嵌套块→MySQL `BEGIN..END`；含 EXCEPTION 的标 TODO）
- [x] PACKAGE BODY 拆分（自动提取内部 PROCEDURE/FUNCTION 为独立文件分别转换）
- [x] `%TYPE` 锚定类型自动解析（`_resolve_anchor_type`：schema 内省 + 离线 fallback）
- [x] 游标 `FOR rec IN cur LOOP` 半自动转换（OPEN/FETCH/CLOSE 框架；FETCH INTO 展开标 TODO）
- [x] `EXECUTE IMMEDIATE` 半自动转换（PREPARE/EXECUTE/DEALLOCATE 框架；INTO 子句标 TODO）
- [x] `RAW(n)→VARBINARY(n)` 类型映射（补 `%TYPE` 锚定 RAW 链路）
- [x] `LISTAGG(expr,sep) WITHIN GROUP(ORDER BY..)→GROUP_CONCAT(.. ORDER BY.. SEPARATOR sep)`（OVER 分析函数形式标 TODO）
- [x] EXECUTE IMMEDIATE INTO TODO 独立行 + `_collect_todos` 缩进匹配修复（报告 TODO 明细完整性）
- [x] `FOR v IN REVERSE lo..hi LOOP`→`WHILE v>=lo DO`（计数器递减；CONTINUE 前置递减防死循环）
- [x] Bug #2 修复：FOR 计数器隐式变量自动注入 `DECLARE v INT DEFAULT <lo/hi>;`
- [ ] deferred：T3 族（%ROWTYPE·BULK COLLECT·集合·内联游标 FOR 自动转换）、GOTO→unsupported TODO
- [ ] deferred：LISTAGG OVER 跨行兜底检测

## 常见问题（FAQ）

### Q: `EXPORT_OBJECT_TYPES` 怎么配？默认导出哪些类型？

`EXPORT_OBJECT_TYPES` 控制 export 阶段从 Oracle 拉取的对象类型，**冒号分隔**（因 `'PACKAGE BODY'` 含空格，不能用空格/逗号分隔）。留空走默认：`PROCEDURE:FUNCTION:PACKAGE BODY:PACKAGE`。

- PROCEDURE / FUNCTION → convert 直接转换
- PACKAGE BODY → convert 的 `_split_package_body` 拆分为独立子程序文件后分别转换
- PACKAGE spec（仅声明）→ 导出但不自动转换

可配子集，如只导 PACKAGE BODY 验证拆分链路：`EXPORT_OBJECT_TYPES=PACKAGE BODY`。非法值（如拼写错或用逗号分隔）会直接 `die` 拒绝运行，避免 `PACKAGE BODY` 被空格拆成两个 token 导致查询失败。

### Q: PACKAGE BODY 拆分后，PACKAGE 级变量/类型/游标怎么处理？

当前 `_split_package_body` 仅自动提取 PACKAGE BODY 内的 PROCEDURE/FUNCTION 子程序，**PACKAGE 级变量/类型/游标声明不随子程序迁移**——这些是子程序间共享的全局状态，TiDB 无对应概念，需人工评估处理：

- 简单常量/标量变量 → 评估是否在各子程序内重复声明，或改用 TiDB 会话变量
- PACKAGE 级 TYPE/RECORD → 映射为临时表或 JSON 结构（见 T3 族 TODO）
- PACKAGE 级游标 → 迁移到使用它的子程序内

PACKAGE spec（声明部分）目前只导出不自动转换。

### Q: `%TYPE` 锚定类型（如 `v_sal emp.salary%TYPE`）能自动转换吗？

能（需 export 阶段已拉 schema 列定义）。export 阶段会额外导出 `all_tab_columns` → `exported/_schema_columns.tsv`，convert 的 `_resolve_anchor_type` pass 据此将 `table.column%TYPE` 解析为具体类型（复用机械层类型映射规则：`VARCHAR2`→`VARCHAR(length)`、`NUMBER(p,s)`→`DECIMAL(p,s)`、裸 `NUMBER`→`DECIMAL(65,30)`）。`column%TYPE`（同包变量锚定）先查本地 symtab，无则查 schema。

**离线 fallback**：若 `exported/_schema_columns.tsv` 不存在（如只跑 convert 已导出文件、无 Oracle 连接）或列未匹配，`%TYPE` 降级回 `-- TODO(需人工转换)` 并进报告明细——不臆造，保「离线可用」特性。

**权限要求**：export 用户需对 `all_tab_columns` 有 SELECT 权限（通常 DBA/迁移账号已具备）。

> `%ROWTYPE`（如 `v_emp emp%ROWTYPE`，多字段 RECORD）不在 `%TYPE` 范围内，需扩为多字段结构，标 TODO 走人工（见 P2）。

### Q: 游标 `FOR rec IN cur LOOP` 转换后，为什么 FETCH INTO 标了 TODO？

MySQL/TiDB **无 RECORD 类型**——Oracle 的 `FETCH cur INTO rec`（`rec` 是整行记录）无法直接对应。转换器会自动生成完整的游标循环框架：

```sql
OPEN cur;
lp1: LOOP
    FETCH cur INTO rec; -- TODO(需人工转换): MySQL 无 RECORD 类型，须展开为标量变量列表（按游标 SELECT 列序）
    IF done = 1 THEN LEAVE lp1;
    END IF;
    -- ...body（CONTINUE 已转 ITERATE）...
END LOOP lp1;
CLOSE cur;
```

`FETCH INTO` 处的 TODO 需人工把 `rec` 展开为按游标 SELECT 列序声明的标量变量列表，如 `FETCH cur INTO v_id, v_name, v_sal;`（变量需在 DECLARE 段先声明）。`OPEN`/`CLOSE`/done handler/`LEAVE`/`ITERATE` 框架均自动生成。

> 内联游标 `FOR rec IN (SELECT..) LOOP`（游标定义内联在 FOR 里，无 `CURSOR..IS` 声明）和 `REVERSE FOR` 仍标 TODO 走人工。

### Q: `EXECUTE IMMEDIATE` 动态 SQL 转换后，为什么 INTO 子句标了 TODO？

Oracle `EXECUTE IMMEDIATE 'SELECT..' INTO var;` 用动态 SQL 取单行结果到变量。MySQL 的 `PREPARE/EXECUTE` **不支持单行 SELECT 返回值映射**（EXECUTE 只能执行不返回结果集到变量的语句）。转换器会自动生成 PREPARE 框架：

```sql
-- Oracle: EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM emp' INTO p_cnt;
-- 转换为：
SET @sql = 'SELECT COUNT(*) FROM emp';
PREPARE stmt FROM @sql;
EXECUTE stmt;
-- TODO(需人工转换): INTO p_cnt — MySQL PREPARE 无单行 SELECT 返回，需改游标 FETCH 或重组逻辑
DEALLOCATE PREPARE stmt;
```

`INTO` 处需人工改写为游标 `OPEN/FETCH/CLOSE` 或在应用层处理。`PREPARE`/`EXECUTE`/`DEALLOCATE` 框架及 `USING` 绑定变量自动生成；转换器正确区分引号外的 `INTO`（变量接收子句）与 SQL 字面量内的 `INSERT INTO`（不误判）。

### Q: macOS 上跑 convert/compare 报「sed 非 GNU 版本」/「awk 非 GNU Awk」？

macOS 默认的 `sed`/`awk` 是 BSD 版本，不支持 GNU 的 `-E` 扩展、`\b` 词边界、gawk 动态正则等特性——脚本会**静默产出错误结果**而非报错，因此 convert/compare 启动时强制校验 GNU 版本。安装 GNU 版本即可：

```bash
brew install gnu-sed gawk
# 默认装到 keg-only 路径，需加 PATH（或用 --with-default-names 选项，视 brew 版本）
export PATH="$(brew --prefix)/opt/gnu-sed/libexec/gnubin:$(brew --prefix)/opt/gawk/libexec/gnubin:$PATH"
```

Linux 多数发行版 `sed`/`awk` 已是 GNU 版本，无需额外操作。

### Q: 嵌套 DECLARE..BEGIN..END 能自动转换吗？

能。Oracle 嵌套块 `DECLARE <decls> BEGIN <body> END` 会自动转为 MySQL `BEGIN DECLARE <decls> <body> END`。嵌套块内的 `:=` 转为 `DEFAULT`。嵌套 EXCEPTION 暂标 TODO，需人工处理。

### Q: 转换报告里的 `-- TODO` 是什么意思？

`-- TODO` 表示转换器无法可靠自动转换该处（如 `%ROWTYPE`、`EXECUTE IMMEDIATE`、`BULK COLLECT`、跨行 `||` 等），需人工介入。详见「转换覆盖」章节的诚实边界策略。

### Q: 性能对比结果 TiDB 比 Oracle 慢很多？

Oracle PL/SQL 原生循环调用接近 0 开销，TiDB 每次 `CALL` 约 3.5ms 调度开销。SP-heavy OLTP 场景迁移需评估此差异。建议使用 `PERF_WARMUP`（预热）和 `PERF_REPEAT`（重复次数）获取稳定数据。
