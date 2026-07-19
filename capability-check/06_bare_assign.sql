-- 探针6：裸 := 赋值语句（不带 SET）。
-- 用途：判定 Oracle 风格 `v := expr;` 能否在目标 TiDB 直接保留。
-- 预期：MySQL/TiDB 通常「不支持」裸 := 语句，需转 SET。若本探针 CREATE 失败即证实。
DROP PROCEDURE IF EXISTS probe_bare_assign;
DELIMITER //
CREATE PROCEDURE probe_bare_assign(OUT p_out INT)
BEGIN
  DECLARE v INT;
  v := 10;                 -- 裸 := 赋值语句（无 SET）
  SET p_out = v;
END //
DELIMITER ;
CALL probe_bare_assign(@o);
SELECT 'probe_bare_assign' AS probe, @o AS out_val;  -- 若 CREATE 失败 → 证实需 := → SET 转换
