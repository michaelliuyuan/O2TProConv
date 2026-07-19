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

## 快速开始

```bash
cp ora2tidb.conf.example ora2tidb.conf   # 或直接编辑 ora2tidb.conf
./bin/ora2tidb export     -c ora2tidb.conf   # 模块1
./bin/ora2tidb convert    -c ora2tidb.conf   # 模块2
./bin/ora2tidb capability -c ora2tidb.conf   # M1 能力探针（需 TiDB 连接）
./bin/ora2tidb compare --validate-cases ../ora2tidb-sp-tests/cases   # 离线校验用例
```

## 里程碑（设计文档 §7）

- **M1** export 模块 + TiDB SP 能力验证（并步）— ⏳ 代码就绪，**gated 决策② TiDB 目标版本 + 连接**
- **M2** convert 规则引擎 + 转换置信度报告 — 🟡 v0.1 机械规则 + TODO + 头部清洗已就绪并通过 smoke test；DECLARE 重排/`:=`→SET/DATE→DATETIME 等结构转换待决策锁定后补齐
- **M3** compare harness — ⏳ 用例契约 + 离线校验就绪；执行待 M1
- **M4** 一键 `all` + 加固

## 转换覆盖（诚实边界，详见设计文档 §5）

**自动转换（确定性）**：`VARCHAR2→VARCHAR`、`NVARCHAR2→NVARCHAR`、`NUMBER(p,s)→DECIMAL(p,s)`、`NUMBER(无精度)→DECIMAL(65,30)`、`PLS_INTEGER/BINARY_INTEGER→INT`、`NVL→IFNULL`、`SYSDATE→NOW()`、`SYSTIMESTAMP→CURRENT_TIMESTAMP(6)`、`ELSIF→ELSEIF`；头部 `CREATE OR REPLACE`→`DROP IF EXISTS`+`CREATE`、双引号标识符→反引号、去 owner 前缀；去 Oracle `/` 终止行；`DELIMITER //` 包裹。

**自动标记 `-- TODO(需人工转换)`**：`||` 拼接（MySQL 中 `||` 默认逻辑或，静默不转即语义错误）、`%TYPE/%ROWTYPE`、`EXECUTE IMMEDIATE`、`BULK COLLECT/FORALL`、`DECODE`、`DBMS_OUTPUT`、`EXCEPTION`、`CURSOR...IS`、`FOR..IN` 循环。

**⚠️ DECLARE 顺序**（@测试工程师 抓的坑，已纳入）：转换器生成声明时按 **变量/条件 → 游标 → handler（handler 最后）**，capability 探针 `02_declare_order.sql` 实证。

**根本原因**：纯正则无法区分字符串字面量与代码、无法处理嵌套，强行转换比「提示人工」更坏。常见场景自动覆盖率约 70~80%；更高保真需 PL/SQL 解析器（非 shell）——决策①待 @刘源 拍。

## 进度

- [x] 仓库骨架 + `ora2tidb` 入口 + 配置（对齐设计文档）
- [x] 模块1 export（sqlplus + `DBMS_METADATA.GET_DDL`）
- [x] 模块2 convert v0.1（机械规则 + TODO 标记 + 头部清洗 + 报告，smoke test 通过）
- [x] M1 能力探针 6 个（DECLARE 顺序 / 游标 / 动态 SQL / 存储函数 / 内置等价 / 裸 `:=`）+ 运行器
- [x] compare 用例格式契约 + `--validate-cases` 离线校验
- [ ] M2 结构转换补齐（DECLARE 重排、`:=`→SET、DATE→DATETIME）— gated 决策①
- [ ] M1 能力探针实跑 — gated 决策②
- [ ] M3 compare 执行（调用/归一/diff/perf/报告）— gated 决策②
- [ ] 端到端联调（真 Oracle ↔ 真 TiDB）
