-- 探针3：动态 SQL（Oracle EXECUTE IMMEDIATE 的 TiDB 对应 = PREPARE/EXECUTE/DEALLOCATE）。
DROP PROCEDURE IF EXISTS probe_dynamic_sql;
DELIMITER //
CREATE PROCEDURE probe_dynamic_sql(IN p_tbl VARCHAR(64), OUT p_n INT)
BEGIN
  SET @s = CONCAT('SELECT COUNT(*) INTO @c FROM ', p_tbl);
  PREPARE ps FROM @s;
  EXECUTE ps;
  DEALLOCATE PREPARE ps;
  SET p_n = @c;
END //
DELIMITER ;
DROP TABLE IF EXISTS probe_src;
CREATE TABLE probe_src (id INT);
INSERT INTO probe_src VALUES (1),(2),(3);
CALL probe_dynamic_sql('probe_src', @n);
SELECT 'probe_dynamic_sql' AS probe, @n AS cnt;  -- 期望 cnt = 3
