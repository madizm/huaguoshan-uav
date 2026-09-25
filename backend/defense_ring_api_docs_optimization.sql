-- 优化防御圈与风险研判 API 接口描述
-- 本脚本用于更新防御圈与风险研判相关函数的 COMMENT ON，使其更面向 API 使用者

begin;

-- 1. 获取防御圈配置
comment on function api.get_defense_ring_config() is
  $$获取防御圈与风险规则配置
  
  返回当前所有保护对象的五层同心防御圈配置，以及当前激活的风险评分规则。
  适合防御圈管理页面和风险规则配置页面。
  
  无需参数。
  
  返回 JSON 结构：
  - objects[]: 保护对象列表，每个包含：
    - id: 保护对象 ID
    - name: 名称
    - longitude / latitude: WGS84 中心点
    - enabled: 是否启用
    - version: 当前发布版本（0 表示尚未发布）
    - rings[]: 五层同心圈（由外到内），每层包含：
      - code: 圈代码（sensing/tracking/countermeasure/hard_strike/core）
      - name: 圈名称（感知圈/跟踪圈/反制圈/硬打击圈/核心圈）
      - ring_level: 圈层级（1-5，1 最外，5 最内）
      - radius_m: 半径（米）
      - priority: 重叠选圈优先级（数值越大越先选）
      - version: 圈版本
      - center: 固化圆心（GeoJSON）
  - rules: 当前激活的风险评分规则：
    - version: 规则版本
    - factors: 评分因子（10 个固定编码），每个包含 score、condition_code、threshold_value、unit、exclusive_group、enabled
    - parameters: 数值参数（风险阈值、确认窗口等），每个包含 value、unit
  
  典型使用场景：
  - 防御圈管理页面加载配置
  - 风险规则配置页面展示当前规则
  - 大屏展示防御圈叠加层
  
  评分因子说明（10 个固定编码）：
  - zone_sensing / zone_tracking / zone_countermeasure / zone_hard_strike / zone_core: 五层防御圈命中分
  - continuous_approach / fast_approach: 接近速度分
  - next_ring_eta_60 / next_ring_eta_30: 下一圈预计到达时间分（互斥组）
  - identity_unverified: 身份未确认分$$;

-- 2. 保存防御圈配置
comment on function api.save_defense_ring_config(jsonb) is
  $$保存防御圈配置（原子发布）
  
  原子保存一个保护对象及其五层同心防御圈。
  采用版本追加模式：每次保存生成新版本，历史版本不可修改。
  新建保护对象时不传 id，更新时必须传 expected_version 做乐观锁。
  
  参数说明（JSON 对象）：
  - id: 保护对象 ID（可选，新建时不传，更新时必填）
  - expected_version: 期望版本号（新建时为 0 或不传，更新时必填，用于乐观锁）
  - name: 保护对象名称（1-120 字符）
  - longitude: WGS84 经度（-180 到 180）
  - latitude: WGS84 纬度（-90 到 90）
  - enabled: 是否启用，默认 true
  - radii_m: 五个半径数组（由外到内，单位米，递减，1-100000）
  - priorities: 五个优先级数组（由外到内，递增整数）
  
  返回 JSON：
  - id: 保护对象 ID
  - version: 新发布的版本号
  
  典型使用场景：
  - 新建保护对象并发布防御圈
  - 调整防御圈半径或优先级
  - 移动保护对象位置（生成新版本）
  - 启用或禁用保护对象
  
  约束：
  - 半径必须由外到内递减
  - 优先级必须由外到内递增
  - 更新时必须提供 expected_version 做乐观锁，防止并发冲突
  - 历史版本不可修改，变更通过发布新版本实现$$;

-- 3. 保存风险评分规则
comment on function api.save_defense_risk_scores(integer,jsonb) is
  $$发布新风险评分规则版本
  
  调整 10 个固定评分因子的分值，发布为新的规则版本。
  采用版本追加模式：旧规则标记为 retired，新规则复制条件和参数后发布。
  历史风险评估结果不受影响。
  
  参数说明：
  - p_expected_version: 当前激活规则的版本号（乐观锁，防止并发冲突）
  - p_scores: 10 个因子的新分值（JSON 对象，键为因子编码，值为 0-100 整数）
  
  必须提供的 10 个因子编码：
  - zone_sensing: 感知圈命中分
  - zone_tracking: 跟踪圈命中分
  - zone_countermeasure: 反制圈命中分
  - zone_hard_strike: 硬打击圈命中分
  - zone_core: 核心圈命中分
  - continuous_approach: 持续接近分
  - fast_approach: 快速接近分
  - next_ring_eta_60: 下一圈 60 秒内到达分
  - next_ring_eta_30: 下一圈 30 秒内到达分
  - identity_unverified: 身份未确认分
  
  返回 JSON：
  - version: 新发布的规则版本号
  
  约束：
  - 五层防御圈分值必须递增（sensing < tracking < countermeasure < hard_strike < core）
  - sensing 分值至少 20
  - 所有分值在 0-100 之间
  - 必须提供完整的 10 个因子
  
  典型使用场景：
  - 调整风险评分权重
  - 优化风险分级阈值
  - 发布新版风险规则
  
  注意：发布后历史评估结果不变，新评估使用新规则。$$;

-- 4. 查询目标风险评估历史
comment on function api.list_target_risk_assessments(bigint,timestamptz,timestamptz,integer) is
  $$查询目标风险评估历史
  
  按时间范围查询指定航迹的风险评估历史记录。
  每条记录冻结了评估时的输入快照和规则版本，支持完整的审计追溯。
  
  参数说明：
  - p_track_id: 航迹 ID（必填）
  - p_start_at: 开始时间（含时区）
  - p_end_at: 结束时间（含时区），窗口最大 7 天
  - p_limit: 返回数量上限（1-5000），默认 500
  
  返回 JSON 结构：
  - trackId: 航迹 ID
  - startAt / endAtExclusive: 查询时间窗口
  - limit: 返回数量上限
  - assessments[]: 评估记录列表，每条包含：
    - assessmentId: 评估 ID
    - observationId: 触发评估的观测 ID
    - observedAt: 观测时间
    - assessedAt: 评估完成时间
    - status: 评估状态（assessed/outside_protected_objects/target_location_unavailable/pending/failed）
    - riskLevel: 风险等级（none/low/medium/high/critical）
    - riskScore: 风险分数（0-100）
    - protectedObjectId: 保护对象 ID
    - protectedObjectVersion: 保护对象版本
    - ringId: 命中的防御圈 ID
    - ringCode: 防御圈代码（sensing/tracking/countermeasure/hard_strike/core）
    - ringLevel: 防御圈层级（1-5）
    - ringVersion: 防御圈版本
    - distanceM: 目标到圆心距离（米）
    - ruleSetId: 使用的规则集 ID
    - ruleVersion: 使用的规则版本
    - factors: 各因子命中详情 JSON 数组
    - inputSnapshot: 评估输入快照
    - reason: 失败原因（仅 status=failed 时有值）
  
  典型使用场景：
  - 航迹详情页展示风险评估时间线
  - 风险等级变化趋势分析
  - 防御圈命中历史回溯
  - 评估失败原因排查
  - 规则版本变更影响分析
  
  注意：评估历史不可修改，每条记录冻结了评估时的完整上下文。$$;

-- 5. 获取风险引擎状态
comment on function api.get_risk_engine_status(text) is
  $$获取风险评估引擎运行状态
  
  返回风险评估 worker 的运行状态、积压情况、吞吐量和当前配置摘要。
  适合运维监控和故障排查。
  
  参数说明：
  - p_worker_name: worker 名称，默认 'defense-assessment'
  
  返回 JSON 结构：
  - state: 引擎整体状态（healthy/degraded/offline）
    - healthy: 心跳正常，无积压
    - degraded: 心跳超时或积压超过 30 秒
    - offline: 心跳超过 60 秒未更新
  - generatedAt: 状态生成时间
  - worker: worker 详细信息：
    - name: worker 名称
    - instanceId: 实例 ID
    - runtimeState: 运行状态（running/idle/degraded/stopped）
    - engineVersion: 引擎版本
    - startedAt: 启动时间
    - heartbeatAt: 最后心跳时间
    - heartbeatAgeSeconds: 心跳距今秒数
    - lastBatchStartedAt / lastBatchFinishedAt: 最后批次时间
    - lastSuccessAt / lastErrorAt: 最后成功/失败时间
    - lastErrorCode / lastErrorMessage: 最后错误信息
    - lastBatchSize / lastBatchDurationMs: 最后批次大小和耗时
    - processedTotal / failedTotal: 累计处理/失败数
    - lastObservationId: 最后处理的观测 ID
    - cursorUpdatedAt: 游标更新时间
  - backlog: 积压统计：
    - pendingCount: 待处理数量（最多 10000）
    - pendingCountCapped: 是否超过 10000 上限
    - cursorPendingCount: 游标待处理数
    - repairPendingCount: 修复待处理数
    - oldestPendingAt: 最早待处理时间
    - oldestPendingAgeSeconds: 最早待处理距今秒数
  - throughput: 吞吐量统计（最近 1 小时）：
    - assessedLastMinute: 最近 1 分钟评估数
    - assessedLastHour: 最近 1 小时评估数
    - failedLastHour: 最近 1 小时失败数
    - failureRateLastHour: 最近 1 小时失败率
    - averageLatencySeconds: 平均延迟秒数
  - configuration: 当前配置摘要：
    - ruleVersion: 激活规则版本
    - protectedObjectCount: 保护对象数量
    - defenseRingCount: 防御圈数量
  
  典型使用场景：
  - 运维监控仪表板
  - 风险评估延迟排查
  - worker 故障诊断
  - 积压告警
  - 吞吐量趋势分析$$;

-- 6. 查询风险引擎失败记录
comment on function api.list_risk_engine_failures(timestamptz,timestamptz,integer) is
  $$查询风险评估失败记录
  
  按时间范围查询风险评估失败的记录列表。
  仅返回错误代码，不返回输入快照和内部异常详情。
  
  参数说明：
  - p_start_at: 开始时间（含时区），默认 24 小时前
  - p_end_at: 结束时间（含时区），默认当前时间，窗口最大 31 天
  - p_limit: 返回数量上限（1-500），默认 50
  
  返回 JSON 结构：
  - startAt / endAtExclusive: 查询时间窗口
  - limit: 返回数量上限
  - failures[]: 失败记录列表，每条包含：
    - assessmentId: 评估 ID
    - trackId: 航迹 ID
    - observationId: 观测 ID
    - observedAt: 观测时间
    - assessedAt: 评估时间
    - errorCode: 错误代码
    - ruleVersion: 使用的规则版本
  
  典型使用场景：
  - 风险评估失败排查
  - 错误代码统计分析
  - worker 故障诊断
  - 评估质量监控
  
  注意：失败记录不可修改，仅暴露错误代码用于排查。$$;

commit;
