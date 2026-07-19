-- 探针5：转换后的内置等价物能否运行（IFNULL / CASE WHEN / NOW() / CONCAT）。
DROP PROCEDURE IF EXISTS probe_builtin;
DELIMITER //
CREATE PROCEDURE probe_builtin(IN p_a INT, IN p_b INT, OUT p_out VARCHAR(100))
BEGIN
  DECLARE v INT;
  SET v = IFNULL(p_a, 0) + IFNULL(p_b, 0);
  SET p_out = CASE WHEN v > 0 THEN CONCAT('pos:', v) ELSE 'non-pos' END;
END //
DELIMITER ;
CALL probe_builtin(3, NULL, @o);
SELECT 'probe_builtin' AS probe, @o AS out_val, NOW() AS now_ts;  -- 期望 out_val = 'pos:3'
