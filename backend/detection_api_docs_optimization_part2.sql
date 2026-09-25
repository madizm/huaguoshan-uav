-- 优化侦测态势 API 接口描述（第二批）
-- 本脚本用于更新侦测态势相关函数的 COMMENT ON，使其更面向 API 使用者

begin;

-- 1. 创建侦测方式
comment on function api.create_detection_method(text,text,text,boolean,integer,jsonb) is
  $$创建侦测方式
  
  创建新的平台稳定侦测方式。编码创建后不可修改。
  
  参数说明：
  - p_code: 侦测方式编码（小写字母、数字、下划线），创建后不可修改
  - p_name: 侦测方式名称
  - p_description: 侦测方式说明，可选
  - p_visible: 是否在管理端展示，默认 true
  - p_sort_order: 排序权重，默认 0
  - p_display_metadata: 展示配置（颜色、图标等），默认空对象
  
  返回 JSON：
  - code: 侦测方式编码
  - name: 名称
  - description: 说明
  - lifecycle_status: 生命周期状态（active/deprecated）
  - visible: 是否可见
  - sort_order: 排序权重
  - display_metadata: 展示配置
  - created_at / updated_at: 时间戳
  
  典型使用场景：
  - 新增侦测方式（如新增"声学侦测"）
  - 配置侦测方式的展示属性
  - 管理侦测方式字典$$;

-- 2. 更新侦测方式
comment on function api.update_detection_method(text,jsonb) is
  $$更新侦测方式
  
  更新侦测方式的名称、说明、生命周期和展示配置。
  稳定编码不可修改。
  
  参数说明：
  - p_code: 侦测方式编码（不可修改）
  - p_changes: 变更字段 JSON 对象，支持：
    - name: 新名称
    - description: 新说明
    - lifecycle_status: 生命周期状态（active/deprecated）
    - visible: 是否可见
    - sort_order: 排序权重
    - display_metadata: 展示配置
  
  返回 JSON：更新后的侦测方式完整信息
  
  典型使用场景：
  - 修改侦测方式名称或说明
  - 将侦测方式标记为 deprecated（仅阻止新映射，不删除历史引用）
  - 调整展示配置（颜色、图标等）
  - 调整排序权重$$;

-- 3. 创建或更新侦测方式映射
comment on function api.upsert_detection_method_mapping(text,text,text,boolean,jsonb) is
  $$创建或更新侦测方式映射
  
  新增或更新来源系统厂商编码到平台稳定侦测方式的映射。
  如果映射已存在则更新，否则创建。
  
  参数说明：
  - p_source_system: 来源系统稳定编码（如 radar_cloud、lizheng）
  - p_vendor_code: 厂商原始侦测方式编码（文本，兼容数值和字符串）
  - p_method_code: 映射后的平台稳定侦测方式编码
  - p_accept_ingest: 是否允许该厂商类型继续接入，默认 true
  - p_metadata: 扩展元数据，默认空对象
  
  返回 JSON：
  - id: 映射 ID
  - source_system: 来源系统
  - vendor_code: 厂商编码
  - method_code: 平台侦测方式编码
  - accept_ingest: 是否允许接入
  - metadata: 扩展元数据
  - created_at / updated_at: 时间戳
  
  典型使用场景：
  - 配置新来源系统的侦测方式映射
  - 更新现有映射的目标侦测方式
  - 临时禁用某个厂商类型的接入（accept_ingest=false）
  - 添加映射的扩展元数据
  
  注意：映射变更会自动记录到审计历史表。$$;

-- 4. 更新侦测观测来源
comment on function api.update_detection_observation_source(bigint,text,bigint,text,integer,boolean) is
  $$更新侦测观测来源配置
  
  管理员更新侦测来源的名称、资产映射、时区、超时和启停状态。
  
  参数说明：
  - p_source_id: 观测来源 ID
  - p_name: 来源名称
  - p_asset_id: 关联的设施设备资产 ID
  - p_source_timezone: 来源时区（如 Asia/Shanghai）
  - p_lost_timeout_seconds: 目标丢失宽限秒数（5-3600）
  - p_enabled: 是否启用
  
  返回 JSON：
  - id: 来源 ID
  - name: 名称
  - asset_id: 关联资产 ID
  - source_timezone: 时区
  - lost_timeout_seconds: 丢失超时秒数
  - enabled: 是否启用
  
  典型使用场景：
  - 修改侦测来源名称
  - 更换关联的设备资产
  - 调整目标丢失超时时间
  - 启用或禁用侦测来源
  
  注意：更新操作会自动记录到审计日志。$$;

-- 5. 实时航迹 v2
comment on function api.get_detection_live_tracks_v2(bigint[],bigint[],text[],integer,integer,integer,integer) is
  $$获取实时航迹（v2，多方式证据）
  
  返回当前活动目标及其最近一段时间的空间尾迹点。
  v2 版本支持按观测来源、实际生产设备和平台稳定侦测方式过滤，
  并返回多方式证据与有界空间尾迹。
  
  参数说明：
  - p_observation_source_ids: 观测来源 ID 列表，为空时返回所有来源
  - p_producer_asset_ids: 实际生产设备资产 ID 列表，为空时返回所有设备
  - p_detection_method_codes: 平台稳定侦测方式代码列表，为空时返回所有方式
  - p_active_within_seconds: 活动窗口秒数（5-3600），默认 120 秒
  - p_trail_seconds: 尾迹时间窗口秒数（30-1800），默认 300 秒
  - p_max_tracks: 最大航迹数量（1-5000），默认 1000
  - p_max_points_per_track: 每条航迹最大点数（2-1000），默认 300
  
  返回 JSON 结构：
  - generated_at: 生成时间
  - cursor: 变更事件游标
  - trail_seconds: 实际使用的尾迹时间窗口
  - detection_methods: 涉及的侦测方式列表
  - tracks: 活动航迹列表，每条包含：
    - track_id / track_code: 航迹标识
    - target_id: 目标 ID
    - observation_source_id: 观测来源 ID
    - producer_asset_id: 生产设备资产 ID
    - detection_method_codes: 涉及的侦测方式列表
    - points: 空间尾迹点数组
  - sources: 侦测来源状态列表
  
  典型使用场景：
  - 按侦测方式过滤航迹（只看雷达目标）
  - 按生产设备过滤航迹（只看特定设备的目标）
  - 多方式证据展示
  - 地图实时航迹展示（v2 版本）
  
  与 v1 的区别：
  - 支持按观测来源、生产设备、侦测方式过滤
  - 返回多方式证据（detection_method_codes）
  - 返回侦测方式列表（detection_methods）$$;

-- 6. 实时航迹 v3
comment on function api.get_detection_live_tracks_v3(bigint[],bigint[],text[],integer,integer,integer,integer) is
  $$获取实时航迹（v3，含风险评估和飞手位置）
  
  返回当前活动目标及其最近一段时间的空间尾迹点。
  v3 版本在 v2 基础上增加每条航迹的当前风险评估和每条观测的远程飞手位置。
  
  参数说明：
  - p_observation_source_ids: 观测来源 ID 列表，为空时返回所有来源
  - p_producer_asset_ids: 实际生产设备资产 ID 列表，为空时返回所有设备
  - p_detection_method_codes: 平台稳定侦测方式代码列表，为空时返回所有方式
  - p_active_within_seconds: 活动窗口秒数（5-3600），默认 120 秒
  - p_trail_seconds: 尾迹时间窗口秒数（30-1800），默认 300 秒
  - p_max_tracks: 最大航迹数量（1-5000），默认 1000
  - p_max_points_per_track: 每条航迹最大点数（2-1000），默认 300
  
  返回 JSON 结构：
  - generated_at: 生成时间
  - cursor: 变更事件游标
  - trail_seconds: 实际使用的尾迹时间窗口
  - detection_methods: 涉及的侦测方式列表
  - tracks: 活动航迹列表，每条包含：
    - track_id / track_code: 航迹标识
    - target_id: 目标 ID
    - observation_source_id: 观测来源 ID
    - producer_asset_id: 生产设备资产 ID
    - detection_method_codes: 涉及的侦测方式列表
    - riskAssessment: 当前风险评估（risk_level、risk_score、defense_ring_code 等）
    - observations: 观测点数组，每个点包含：
      - observation_id: 观测 ID
      - observed_at: 观测时间
      - position: 目标位置（GeoJSON）
      - remote_pilot_position: 远程飞手位置（GeoJSON，可选）
      - altitude_amsl_m: 海拔高度（米）
      - speed_mps: 速度（米/秒）
  - sources: 侦测来源状态列表
  
  典型使用场景：
  - 航迹风险评估展示（颜色编码）
  - 远程飞手位置标注
  - 目标与飞手位置对比
  - 地图实时航迹展示（v3 版本，推荐）
  
  与 v2 的区别：
  - 每条航迹包含当前风险评估（riskAssessment）
  - 每条观测包含远程飞手位置（remote_pilot_position）
  - 更适合需要风险可视化和飞手追踪的场景$$;

-- 7. 来源目标机型汇总
comment on function api.get_source_target_model_summary(timestamptz,timestamptz,bigint[],text[],text[],text[],text[],integer,integer) is
  $$获取来源目标机型汇总
  
  按来源目标 + 机型分组，返回架次汇总统计。
  适合机型分析、目标画像和统计报表场景。
  
  参数说明：
  - p_start_at: 开始时间（含时区）
  - p_end_at: 结束时间（含时区），窗口最大 90 天
  - p_source_ids: 来源 ID 列表，为空时返回所有来源
  - p_risk_levels: 最大风险等级列表（critical/high/medium/low/none/unavailable）
  - p_models: 机型列表，为空时返回所有机型
  - p_detection_method_codes: 侦测方式代码列表
  - p_source_target_ids: 来源目标 ID 列表
  - p_limit: 每页数量（1-500），默认 50
  - p_offset: 偏移量，默认 0
  
  返回 JSON 结构：
  - startAt / endAtExclusive: 统计时间窗口
  - totalGroups: 分组总数
  - rows[]: 每个分组的汇总信息：
    - sourceTargetId: 来源目标 ID
    - sourceName: 来源名称
    - observationSourceId: 观测来源 ID
    - model: 机型
    - sortieCount: 飞行次数
    - totalDurationSeconds: 总飞行时长（秒）
    - highRiskCount: 高风险架次数
    - maxRiskLevel: 最高风险等级
    - lastSortieAt: 最近飞行时间
  
  典型使用场景：
  - 机型统计分析
  - 目标画像（某机型的活动频率、风险分布）
  - 高频目标识别
  - 统计报表数据源
  - 按机型筛选和分析$$;

-- 8. 来源目标机型架次列表
comment on function api.list_source_target_model_sorties(timestamptz,timestamptz,text,text,bigint[],text[],text[],integer,integer) is
  $$查询来源目标机型架次列表
  
  查询指定来源目标 + 机型的架次明细分页列表。
  适合深入分析特定目标的活动详情。
  
  参数说明：
  - p_start_at: 开始时间（含时区）
  - p_end_at: 结束时间（含时区），窗口最大 90 天
  - p_source_target_id: 来源目标 ID（必填）
  - p_model: 机型（必填）
  - p_source_ids: 来源 ID 列表，为空时返回所有来源
  - p_risk_levels: 最大风险等级列表
  - p_detection_method_codes: 侦测方式代码列表
  - p_limit: 每页数量（1-500），默认 100
  - p_offset: 偏移量，默认 0
  
  返回 JSON 结构：
  - startAt / endAtExclusive: 查询时间窗口
  - sourceTargetId / model: 查询条件
  - total: 匹配架次总数
  - sorties[]: 架次列表，每条包含：
    - sortieId: 架次 ID
    - trackCode: 航迹编码
    - sourceName: 来源名称
    - state: 状态（active/lost/closed）
    - startedAt: 开始时间
    - durationSeconds: 持续时长（秒）
    - observationCount: 观测次数
    - maxRiskLevel: 最高风险等级
    - maxRiskScore: 最高风险分数
    - deepestRingCode: 最深防御圈代码
  
  典型使用场景：
  - 特定目标的架次详情列表
  - 目标活动历史回溯
  - 按风险等级筛选特定目标的架次
  - 目标行为分析
  
  使用建议：
  - 先调用 get_source_target_model_summary 获取分组列表
  - 再点击某个分组调用本接口查看明细$$;

commit;
