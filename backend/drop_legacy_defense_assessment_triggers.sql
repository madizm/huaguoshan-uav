begin;

-- 旧版库内防御评估依赖已移除的 situation.track_defense_assessment_current
-- 和 situation.defense_worker_track_job。残留触发器会使目标航迹写入整体回滚。
drop trigger if exists target_track_defense_assessment on situation.target_track;
drop trigger if exists target_track_defense_job on situation.target_track;

commit;
