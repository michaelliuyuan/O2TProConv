-- 探针1：基础 IN/OUT 参数、IF/ELSEIF/ELSE、SET 两种赋值形式（= 与 :=）。
DROP PROCEDURE IF EXISTS probe_basic_io;
DELIMITER //
CREATE PROCEDURE probe_basic_io(IN p_x INT, OUT p_out INT)
BEGIN
  DECLARE v INT;
  SET v   = p_x * 2;     -- SET = 形式
  SET v  := v + 1;        -- SET := 形式（SET 语句内合法）
  IF v > 10 THEN
    SET v = 99;
  ELSEIF v = 5 THEN
    SET v = 55;
  ELSE
    SET v = 0;
  END IF;
  SET p_out = v;
END //
DELIMITER ;
CALL probe_basic_io(2, @o);                      -- (2*2+1=5) → ELSEIF → 55
SELECT 'probe_basic_io' AS probe, @o AS out_val; -- 期望 out_val = 55
