# compare 用例格式契约

> 回应 @测试工程师：`cases/test-cases.md`（你已有，人类可读矩阵）作为 SSOT 保留；
> harness 额外读取一个**机器格式**伴生文件 `cases/<sp>.cases`，与 test-cases.md **1:1 对应**（人工转录，非重新设计）。
> 你的 §0 捕获表（OUT/INOUT/FUNCTION/result_set 两端抓取方式）已被采纳为本契约的模板来源。

## 两层模型

| 文件 | 角色 | 读者 |
|------|------|------|
| `cases/test-cases.md` | 人工 SSOT：入参/期望/归一/通过准则矩阵 | 人 |
| `cases/<sp>.cases` | 机器输入：harness 直接解析 | ora2tidb compare |

## 机器格式（stanza）

```
# 注释行（#）；空行忽略
@@case id=TC-T1-01a sp=sp_calc_bonus capture=out_param
in   p_empno=7839
out  p_bonus=750
out  p_label=A_<DATE:YYYYMMDD>
norm numeric_scale=2 date=p_label:YYYYMMDD
perf warmup=3 repeat=10
```

### 字段

- **`@@case` 头**（必填）：`id`（与 test-cases.md 子例号一致）、`sp`、`capture`∈`out_param|inout|function|result_set`（对齐你 §0 表）。
- **`in k=v`**：入参，按 sp 形参名（可多行）。
- **`out k=v`**：期望输出值（按 OUT/返回形参名）。值三态：
  - 字面量：`out p_bonus=750`
  - 正则：`out p_label=~^A_\d{8}$`（`~` 前缀；归一后正则匹配，处理动态日期段）
  - 今日日期占位：`out p_label=A_<DATE:YYYYMMDD>`（harness 按运行日展开，两端同日）
- **function 返回值**：`capture=function` 时用命名键 `out return=<值>`（与 procedure 的 `out <param>=<值>` 平行；每个捕获维度都命名，不取匿名/第一列，多结果时避免歧义）。harness 以 `SELECT fn(...)` 取返回值，按 `return` 键比对。
- **`result` / `result_file`**：`capture=result_set` 时的结果集期望；`result_file=` 指向 golden 文本文件。
- **`norm`**：归一选项（两端同策略，空格分隔）：`trim`、`collapse_ws`、`null_as=NULL`（Oracle 空串即 NULL，两端 `''`/NULL 归一同向）、`numeric_scale=N`、`num_str_strip_zeros`（字符串内数字段去无意义尾零：`8750.00`→`8750`，对冲 Oracle NUMBER 隐式 TO_CHAR 丢尾零 vs MySQL DECIMAL 拼接保 scale）、`date=<字段>:<fmt>`、`upper`。
- **`perf`**：`warmup=N repeat=N`（缺省取 `ora2tidb.conf` 的 `PERF_WARMUP/PERF_REPEAT`）。
- **可选覆盖**（模板生成不合用时的逃生口）：`call_oracle` / `call_tidb` / `fetch_oracle` / `fetch_tidb`。

## 调用生成（默认由 capture 模板自动生成，对齐你 §0）

| capture | Oracle 端 | TiDB 端 |
|---------|-----------|---------|
| `out_param` | `VAR ...; EXEC sp(...,:out); PRINT out;` | `SET @out=NULL; CALL sp(...,@out); SELECT @out;` |
| `inout` | `VAR a ...; EXEC :a:=v; EXEC sp(:a,...); PRINT a;` | `SET @a=v; CALL sp(@a,...); SELECT @a;` |
| `function` | `SELECT fn(...) FROM dual;` | `SELECT fn(...);` |
| `result_set` | `EXEC` 后 `PRINT refcursor` / `OPEN ... FOR SELECT` | `CALL` 直出结果集 |

模板由 `in`/`out` 形参名 + sp 名生成；复杂情形用 `call_*`/`fetch_*` 覆盖。

## 离线校验（不连库，即装即用）

```
ora2tidb compare --validate-cases <cases 目录>
```
逐个 `*.cases` 报告：每个 case 的 id/sp/capture 完整性、capture 合法性、是否含期望，以及无法识别的行。

## 示例（转录自 test-cases.md）

```
@@case id=TC-T1-01a sp=sp_calc_bonus capture=out_param
in   p_empno=7839
out  p_bonus=750
out  p_label=A_<DATE:YYYYMMDD>
norm numeric_scale=2 date=p_label:YYYYMMDD
perf warmup=3 repeat=10

@@case id=TC-T2-07a sp=sp_explicit_cursor capture=out_param
in   p_deptno=30
in   p_top=3
out  p_list=BLAKE=2850;ALLEN=1600;TURNER=1500
norm trim
perf warmup=3 repeat=10
```

## 跨库语义分歧（convert 侧标记 / compare 侧归一，见设计文档 §5/§6）
- **`NVL(x,'')`（Oracle 空串=NULL）**：Oracle `''`=NULL 故 `NVL(x,'')`≡`x`（恒等）；MySQL `''`≠NULL 故 `IFNULL(x,'')` 返回 `''`。转换器**不盲转**，打 `--TODO`（解法二选一：保行为→`x`/`IFNULL(x,NULL)`，保意图→`IFNULL(x,'')`）。compare 侧 `null_as=NULL` 归一兜底。
- **数值拼串尾零**：Oracle NUMBER 隐式 TO_CHAR 丢尾零（`8750`），MySQL DECIMAL 拼接保 scale（`8750.00`）。compare 侧 `num_str_strip_zeros` 归一。

## 实现状态

- ✅ 格式契约 + 离线 `--validate-cases`。
- ⏳ 两端调用/归一/diff/perf/报告 = M3，gated 决策②（TiDB 目标版本 + 连接）。
