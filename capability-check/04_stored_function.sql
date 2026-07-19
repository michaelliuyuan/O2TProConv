-- 探针4：存储函数（需 DETERMINISTIC 等特征，否则在未开 log_bin_trust_function_creators 时报错）。
DROP FUNCTION IF EXISTS probe_func;
DELIMITER //
CREATE FUNCTION probe_func(p_a INT) RETURNS INT
DETERMINISTIC
BEGIN
  RETURN p_a * p_a;
END //
DELIMITER ;
SELECT 'probe_stored_function' AS probe, probe_func(6) AS sq;  -- 期望 sq = 36
