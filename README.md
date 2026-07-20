# oracle2tidb-sp

基于 **纯 shell** 的 Oracle 存储过程 → TiDB（MySQL 兼容）转换与对比工具。
对齐架构设计文档 `oracle-sp-to-tidb-sp-design.md`（模块设计 / 规则映射表 / 转换置信度报告 / 对比契约 / 风险）。

## 能力（设计文档 §1）

1. **export**：配 Oracle 连接 → 拉存储过程定义 → 导出 `.sql`。
2. **convert**：Oracle（PL/SQL）SP → TiDB 语法 SP（+ 转换置信度报告）。
3. **compare**：配 Oracle + TiDB → 跑 SP → 性能 + 结果一致性对比 → 报告。
4. **capability**：M1 硬前置，对目标 TiDB 跑能力探针。

> TiDB 存储过程兼容 MySQL 语法。

## 依赖

bash ≥ 4；Oracle 侧 `sqlplus`/`sqlcl`；TiDB 侧 `mysql`；GNU `sed`/`gawk`；可选 `bc`/`jq`。

## 目录结构

```
oracle2tidb-sp/
├── ora2tidb.conf            # 配置：Oracle/TiDB 连接、输出目录、compare 参数
├── bin/ora2tidb             # 主入口：export|convert|compare|capability|all
├── lib/
│   ├── common.sh           # 日志/配置/依赖/DB 客户端封装
│   ├── export_oracle.sh    # 模块1：Oracle SP → .sql（DBMS_METADATA.GET_DDL）
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
```

### 1. 配置连接

```bash
cp ora2tidb.conf.example ora2tidb.conf
# 编辑 ora2tidb.conf：
#   ORACLE_USER/PASS/HOST/PORT/SERVICE   Oracle 连接（export 导出 + compare 对比）
#   TIDB_USER/PASS/HOST/PORT/DB           TiDB 连接（compare 对比 + capability 探针）
#   EXPORT_DIR/CONVERTED_DIR/REPORT_DIR   产物目录（相对项目根，也可绝对路径）
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

### 3. 导出 Oracle SP（export）

```bash
./bin/ora2tidb export -c ora2tidb.conf
# DBMS_METADATA.GET_DDL('PROCEDURE'|'FUNCTION', name, owner) → exported/<OWNER>.<NAME>.sql
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
```

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

> M3 手动实跑真值（README 作预期产出示例）：**T1+T2 一致性 24/24 全绿（Route A）**；perf 见 `results/perf-oracle-vs-tidb.md`（信息性：Oracle PL/SQL 原生循环调用 ≈0 vs TiDB CALL ~3.5ms 固有调度底，SP-heavy OLTP 迁移需评估）。

### 一键全流程

```bash
./bin/ora2tidb all -c ora2tidb.conf   # export → convert（compare 为 M3，未串入）
```

## 里程碑（设计文档 §7）

- **M1** export 模块 + TiDB SP 能力验证 — ✅ 代码就绪 + 能力探针实跑通过（TiDB v7.1.9，含 GET DIAGNOSTICS 实证）
- **M2** convert 规则引擎 + 转换置信度报告 — ✅ 机械规则 + **结构层**（EXCEPTION→EXIT handler / 显式游标 / WHILE→DO / 数值 FOR→WHILE+计数器 / CONTINUE→ITERATE / `:=`→SET / DECLARE 序重排 / END 规范）+ 忠实 `||`/`DECODE`(`<=>`) + `TO_CHAR(date)`→`DATE_FORMAT` + 报告（含默认长度 NOTE）；**T1+T2 验收通过（8/8 CREATE + golden + 一致性）**；DATE→DATETIME / 嵌套块 / T3 族 deferred（标 TODO）
- **M3** compare harness — 🟡 用例契约 + `--validate-cases` 离线校验就绪；执行对比待联调
- **M4** 一键 `all` + 加固

## 转换覆盖（诚实边界，详见设计文档 §5）

**自动转换（机械 + 结构 + 忠实语义）**：
- 类型：`VARCHAR2→VARCHAR`、`NVARCHAR2→NVARCHAR`（裸类型给安全默认长度 `VARCHAR(4000)`）、`NUMBER(p,s)→DECIMAL(p,s)`、裸 `NUMBER→DECIMAL(65,30)`、`PLS_INTEGER/BINARY_INTEGER→INT`
- 内置：`NVL→IFNULL`、`SYSDATE→NOW()`、`SYSTIMESTAMP→CURRENT_TIMESTAMP(6)`、`TO_CHAR(date,'mask')→DATE_FORMAT`、`ELSIF→ELSEIF`
- 忠实语义：`a||b→NULLIF(CONCAT(IFNULL(a,''),IFNULL(b,'')),'')`（简单链，NULL 安全）、`DECODE(e,s1,r1,..,def)→CASE WHEN e<=>s1 THEN r1 .. ELSE def END`（`<=>` null-safe）
- 结构：EXCEPTION 块→`EXIT HANDLER`（NO_DATA_FOUND→`FOR NOT FOUND`、OTHERS→`FOR SQLEXCEPTION`+`GET DIAGNOSTICS`+`SQLERRM→v_errmsg`）；显式游标 `CURSOR c IS`→`DECLARE c CURSOR FOR`（+done 标志 + `CONTINUE HANDLER FOR NOT FOUND` + label + `EXIT WHEN c%NOTFOUND`→`IF done=1 THEN LEAVE`）；`WHILE..LOOP`→`WHILE..DO`；数值 `FOR v IN lo..hi LOOP`→`WHILE v<=hi DO`（+计数器递增）；`CONTINUE`→`ITERATE label`（FOR 内前置递增防死循环）；`:=`→`SET`/`DEFAULT`；DECLARE 序重排（变量/条件→游标→handler）；头部 `CREATE OR REPLACE`→`DROP IF EXISTS`+`CREATE`、双引号→反引号、去 owner 前缀、`RETURN<type>→RETURNS<type>`；去 Oracle `/` 终止行；`DELIMITER //` 包裹。

**自动标记 `-- TODO(需人工转换)`**：跨表达式/跨行 `||`（**Route A 下留字面交 PIPES_AS_CONCAT**，TODO 标部署要求——见 Usage Step 5）、`%TYPE/%ROWTYPE`、`EXECUTE IMMUTE`、`BULK COLLECT/FORALL`、`TO_CHAR(number/复杂)`、`DBMS_OUTPUT`、游标/REVERSE `FOR..IN`、`GOTO`（MySQL 不支持）、嵌套 `DECLARE..BEGIN..END`。

**⚠️ DECLARE 顺序**（@测试工程师 抓的坑，已纳入）：转换器生成声明时按 **变量/条件 → 游标 → handler（handler 最后）**，capability 探针 `02_declare_order.sql` 实证。

**覆盖率**：T1+T2 常见 SP 定义 8/8 全自动转换（corpus 实测 CREATE + golden + 一致性通过）；复杂 T3（PACKAGE / `%ROWTYPE` / BULK COLLECT / 动态 SQL / 集合 / 游标 FOR）标 TODO 走人工。**诚实边界**：纯正则无法区分字符串字面量与代码、无法处理嵌套，强行转换比「提示人工」更坏——不可靠处留 `-- TODO` 不臆造。

## 进度

- [x] 仓库骨架 + `ora2tidb` 入口 + 配置（对齐设计文档）
- [x] 模块1 export（sqlplus + `DBMS_METADATA.GET_DDL`）
- [x] 模块2 convert（机械规则 + **结构层**：EXCEPTION→EXIT handler / 显式游标 / WHILE→DO / 数值 FOR / CONTINUE / `:=`→SET / DECLARE 序重排 + 忠实 `||`/`DECODE`(`<=>`) + 报告含默认长度 NOTE）
- [x] M1 能力探针 6 个 + 运行器，**实跑通过**（TiDB v7.1.9，含 GET DIAGNOSTICS 实证）
- [x] compare 用例格式契约 + `--validate-cases` 离线校验
- [x] **T1+T2 验收**：8/8 CREATE + golden diff + 一致性通过（1/7→8/8）
- [x] Route A 部署方案（global `PIPES_AS_CONCAT` + SP 创建时锁定，见 Usage Step 5）
- [ ] M3 compare 执行对比（调用/归一/diff/perf/报告）
- [ ] deferred：DATE→DATETIME、嵌套 DECLARE..BEGIN..END、T3 族（PACKAGE·%ROWTYPE·BULK COLLECT·动态 SQL·集合·游标 FOR）、GOTO→unsupported TODO
