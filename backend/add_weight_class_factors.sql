-- 添加 weight_class 因子到风险评估规则集。
-- 依赖 create_target_risk_assessment.sql；可安全重复执行。

begin;

-- 获取当前活跃的 defense-risk 规则集 ID
DO $$
DECLARE
    v_rule_set_id bigint;
BEGIN
    SELECT id INTO v_rule_set_id
    FROM event_response.risk_rule_set
    WHERE code = 'defense-risk' AND status = 'active'
    ORDER BY effective_from DESC
    LIMIT 1;

    IF v_rule_set_id IS NULL THEN
        RAISE EXCEPTION 'no active defense-risk rule set found';
    END IF;

    -- 插入 weight_class 因子
    -- 这些因子属于同一个互斥组 'weight_class'，因为一个目标只能有一个 weight_class
    INSERT INTO event_response.risk_rule_factor (rule_set_id, factor_code, condition_code, threshold_value, score, exclusive_group, enabled)
    VALUES
        (v_rule_set_id, 'weight_class_micro', 'weight_class', NULL, 2, 'weight_class', true),
        (v_rule_set_id, 'weight_class_light', 'weight_class', NULL, 4, 'weight_class', true),
        (v_rule_set_id, 'weight_class_small', 'weight_class', NULL, 8, 'weight_class', true),
        (v_rule_set_id, 'weight_class_medium', 'weight_class', NULL, 12, 'weight_class', true),
        (v_rule_set_id, 'weight_class_large', 'weight_class', NULL, 15, 'weight_class', true)
    ON CONFLICT (rule_set_id, factor_code) DO UPDATE
    SET score = EXCLUDED.score,
        enabled = EXCLUDED.enabled;

    -- 更新规则集版本号
    UPDATE event_response.risk_rule_set
    SET version = version + 1
    WHERE id = v_rule_set_id;

    RAISE NOTICE 'added weight_class factors to rule set %, new version %', v_rule_set_id,
        (SELECT version FROM event_response.risk_rule_set WHERE id = v_rule_set_id);
END $$;

commit;
