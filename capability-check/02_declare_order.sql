-- 探针2：DECLARE 顺序 = 变量 → 游标 → handler（handler 必须最后）。
-- 验证 @测试工程师 的正确性提醒：若把 handler 前置于变量会编译失败。
DROP PROCEDURE IF EXISTS probe_declare_order;
DELIMITER //
CREATE PROCEDURE probe_declare_order(OUT p_cnt INT)
BEGIN
  DECLARE v_done INT DEFAULT 0;                                    -- ① 变量/条件
  DECLARE v_name VARCHAR(50);
  DECLARE c1 CURSOR FOR SELECT name FROM probe_src;                -- ② 游标
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;           -- ③ handler（最后）
  SET p_cnt = 0;
  OPEN c1;
  read_loop: LOOP
    FETCH c1 INTO v_name;
    IF v_done = 1 THEN LEAVE read_loop; END IF;
    SET p_cnt = p_cnt + 1;
  END LOOP read_loop;
  CLOSE c1;
END //
DELIMITER ;
DROP TABLE IF EXISTS probe_src;
CREATE TABLE probe_src (name VARCHAR(50));
INSERT INTO probe_src VALUES ('a'),('b'),('c');
CALL probe_declare_order(@c);
SELECT 'probe_declare_order' AS probe, @c AS row_count;  -- 期望 row_count = 3
