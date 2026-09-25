-- 优化侦测态势 API 接口描述
-- 本脚本用于更新侦测态势相关视图和函数的 COMMENT ON，使其更面向 API 使用者

begin;

-- 1. 侦测方式字典
comment on view api.detection_methods is
  $$侦测方式字典
  
  返回平台定义的所有侦测方式（雷达、电侦、光电、Remote ID 等）。
  用于业务筛选器和下拉选择，包含每种方式的历史观测引用数量。
  
  典型使用场景：
  - 前端筛选器加载侦测方式选项
  - 统计各侦测方式的目标数量
  - 配置界面展示可用侦测方式$$;

-- 2. 侦测方式映射
comment on view api.detection_method_mappings is
  $$侦测方式映射表
  
  管理厂商侦测枚举到平台稳定侦测方式的映射关系。
  用于将不同厂商的侦测方式编码统一转换为平台标准编码。
  
  典型使用场景：
  - 查看当前厂商编码映射配置
  - 排查侦测方式转换问题
  - 审计映射配置变更历史$$;

-- 3. 侦测方式映射历史
comment on view api.detection_method_mapping_history is
  $$侦测方式映射变更历史
  
  记录厂商侦测方式映射的所有变更操作，包括创建、修改和删除。
  用于审计追踪和配置回溯。
  
  典型使用场景：
  - 审计映射配置变更
  - 排查映射问题时的时间线回溯
  - 查看谁在什么时候修改了映射配置$$;

-- 4. 侦测来源类型
comment on view api.detection_source_types is
  $$侦测来源类型字典
  
  返回雷达和电侦的来源类型定义。
  用于区分不同侦测设备的来源类型。
  
  典型使用场景：
  - 前端筛选器加载来源类型选项
  - 按来源类型统计目标数量
  - 配置界面展示可用来源类型$$;

-- 5. 侦测观测来源
comment on view api.detection_observation_sources is
  $$侦测观测来源配置
  
  返回侦测设备站点、边缘盒子的观测接入配置和连接状态。
  包含设备资产映射、时区配置、超时设置等信息。
  
  典型使用场景：
  - 查看侦测设备接入状态
  - 排查设备连接问题
  - 查看设备与站点的映射关系
  - 监控设备在线状态和最后消息时间$$;

-- 6. 侦测态势快照
comment on function api.get_detection_situation_snapshot(text[],smallint[],double precision,double precision,double precision,double precision,integer,integer) is
  $$获取当前侦测态势快照
  
  返回当前活动目标的综合态势信息，包括有位置目标和无位置侦测。
  适合大屏展示和态势总览场景。
  
  参数说明：
  - p_station_ids: 站点 ID 列表，为空时返回所有站点
  - p_source_type_codes: 来源类型代码列表（10=雷达，20=电侦），为空时返回所有类型
  - p_west/p_south/p_east/p_north: WGS84 边界框，为空时返回所有区域
  - p_active_within_seconds: 活动窗口秒数（5-3600），默认 30 秒
  - p_limit: 返回数量上限（1-5000），默认 1000
  
  返回 JSON 结构：
  - generated_at: 快照生成时间
  - cursor: 变更事件游标，用于增量更新
  - targets: 有位置的活动目标列表，包含坐标、高度、速度等
  - non_spatial_detections: 无位置的侦测目标列表
  - sources: 侦测来源状态列表
  
  典型使用场景：
  - 大屏态势展示（首次加载）
  - 定时轮询刷新态势
  - 基于 cursor 的增量更新
  - 按区域或站点过滤展示$$;

-- 7. 侦测实时航迹
comment on function api.get_detection_live_tracks(text[],smallint[],integer,integer,integer,integer) is
  $$获取当前活动目标及航迹尾迹
  
  返回当前活动目标及其最近一段时间的空间尾迹点。
  适合地图展示和航迹回放场景。
  
  参数说明：
  - p_station_ids: 站点 ID 列表，为空时返回所有站点
  - p_source_type_codes: 来源类型代码列表，为空时返回所有类型
  - p_active_within_seconds: 活动窗口秒数（5-3600），默认 120 秒
  - p_trail_seconds: 尾迹时间窗口秒数（30-1800），默认 300 秒
  - p_max_tracks: 最大航迹数量（1-5000），默认 1000
  - p_max_points_per_track: 每条航迹最大点数（2-1000），默认 300
  
  返回 JSON 结构：
  - generated_at: 生成时间
  - cursor: 变更事件游标
  - trail_seconds: 实际使用的尾迹时间窗口
  - tracks: 活动航迹列表，每条包含航迹信息和尾迹点数组
  - sources: 侦测来源状态列表
  
  典型使用场景：
  - 地图实时航迹展示
  - 航迹尾迹可视化
  - 目标运动轨迹回放
  - 按站点或来源类型过滤航迹$$;

-- 8. 态势增量变更
comment on function api.get_detection_situation_changes(bigint,text[],integer) is
  $$获取态势增量变更
  
  基于游标获取目标航迹的增量变更事件。
  适合实时更新和增量同步场景，减少数据传输量。
  
  参数说明：
  - p_after_cursor: 上次获取的游标位置，首次传 0
  - p_station_ids: 站点 ID 列表，为空时返回所有站点
  - p_limit: 返回数量上限（1-1000），默认 500
  
  返回 JSON 结构：
  - cursor: 新的游标位置，用于下次请求
  - changes: 变更事件列表，包含事件类型、航迹 ID、目标 ID 等
  - has_more: 是否还有更多变更
  
  典型使用场景：
  - 实时态势增量更新
  - WebSocket 推送后的数据补充
  - 减少轮询数据传输量
  - 断线重连后的数据同步$$;

-- 9. 目标航迹列表
comment on function api.list_detection_target_tracks(timestamptz,timestamptz,text[],smallint[],integer) is
  $$查询目标航迹列表
  
  分页查询目标航迹，支持按时间范围、站点、来源类型等条件过滤。
  适合航迹管理列表和查询场景。
  
  参数说明：
  - p_start_at: 开始时间（含时区）
  - p_end_at: 结束时间（含时区）
  - p_station_ids: 站点 ID 列表，为空时返回所有站点
  - p_source_type_codes: 来源类型代码列表，为空时返回所有类型
  - p_limit: 每页数量（1-500），默认 200
  
  返回 JSON 结构：
  - total: 总数量
  - limit: 每页数量
  - tracks: 航迹列表，包含航迹编码、状态、目标信息、观测统计等
  
  典型使用场景：
  - 航迹管理列表页
  - 历史航迹查询
  - 按站点或来源类型筛选航迹
  - 航迹统计分析$$;

-- 10. 目标航迹详情
comment on function api.get_target_track_detail(bigint,timestamptz,timestamptz,integer) is
  $$获取目标航迹详情
  
  返回指定航迹在时间范围内的完整信息，包括航迹基本信息、目标信息、
  观测来源、关联观测列表和风险评估历史。
  
  参数说明：
  - p_track_id: 航迹 ID
  - p_start_at: 开始时间（含时区）
  - p_end_at: 结束时间（含时区）
  - p_max_points: 最大观测点数，默认 2000
  
  返回 JSON 结构：
  - track: 航迹基本信息（编码、状态、时间范围、观测统计等）
  - target: 关联目标信息（编码、类别、身份状态等）
  - source: 观测来源信息（站点、设备、连接状态等）
  - observations: 关联观测列表
  - risk_assessments: 风险评估历史
  
  典型使用场景：
  - 航迹详情页展示
  - 航迹证据链查看
  - 目标风险评估历史
  - 观测数据溯源$$;

-- 11. 原始来源态势
comment on function api.get_raw_source_situation(timestamp without time zone,timestamp without time zone,integer) is
  $$获取原始来源态势数据
  
  返回 raw schema 中两路无人机和华飞无源雷达的原始态势数据。
  包含数据质量统计和抽样后的坐标点。
  
  参数说明：
  - p_start_at: 开始时间（不含时区，来源时间语义）
  - p_end_at: 结束时间（不含时区，来源时间语义）
  - p_drone_sample_seconds: 无人机数据抽样间隔秒数（10-86400），默认 60
  
  返回 JSON 结构：
  - window: 时间窗口和抽样参数
  - bounds: 1%-99% 稳健定位范围
  - sources: 各来源的数据质量统计
  - tracks: 按来源和航迹分组的坐标点列表
  
  典型使用场景：
  - 原始数据质量检查
  - 数据回溯和验证
  - 地图校验和调试
  - 数据来源分析
  
  注意：时间窗口最大 31 天，无人机数据按时间抽样，雷达每个 batch 返回末次位置。$$;

-- 12. 来源架次列表
comment on function api.list_source_sorties(timestamptz,timestamptz,bigint[],text[],text[],text,integer,integer) is
  $$查询来源架次列表
  
  分页查询来源架次（一次来源目标会话），支持多种过滤条件。
  架次包含观测统计、风险评估和数据质量信息。
  
  参数说明：
  - p_start_at: 开始时间（含时区）
  - p_end_at: 结束时间（含时区），窗口最大 31 天
  - p_source_ids: 来源 ID 列表，为空时返回所有来源
  - p_detection_method_codes: 侦测方式代码列表
  - p_risk_levels: 最大风险等级列表（critical/high/medium/low/none/unavailable）
  - p_quality_issue: 质量问题过滤（normal/timestamp_suspect/single_timestamp/non_spatial/lifecycle_overlap）
  - p_limit: 每页数量（1-500），默认 100
  - p_offset: 偏移量（0-10000），默认 0
  
  返回 JSON 结构：
  - total: 总数量
  - sorties: 架次列表，包含架次信息、观测统计、风险评估、质量问题等
  
  典型使用场景：
  - 架次管理列表页
  - 按风险等级筛选架次
  - 数据质量问题排查
  - 架次统计分析$$;

-- 13. 来源架次统计
comment on function api.get_source_sortie_statistics(timestamptz,timestamptz,bigint[],text[],text) is
  $$获取来源架次统计汇总
  
  返回时间窗口内的架次统计汇总，包括总数、风险分布、质量问题统计等。
  
  参数说明：
  - p_start_at: 开始时间（含时区）
  - p_end_at: 结束时间（含时区），窗口最大 90 天
  - p_source_ids: 来源 ID 列表
  - p_detection_method_codes: 侦测方式代码列表
  - p_quality_issue: 质量问题过滤
  
  返回 JSON 结构：
  - summary: 架次总统计（总数、活动数、空间数、高风险数等）
  - riskDistribution: 风险等级分布
  - quality: 数据质量问题统计
  
  典型使用场景：
  - 架次统计仪表板
  - 风险分布可视化
  - 数据质量监控
  - 趋势分析基础数据$$;

-- 14. 来源架次时间序列
comment on function api.get_source_sortie_series(timestamptz,timestamptz,text,bigint[],text[],text) is
  $$获取来源架次时间序列
  
  按小时或日期分桶，返回架次数量、高风险架次等的时间序列数据。
  适合趋势图表展示。
  
  参数说明：
  - p_start_at: 开始时间（含时区）
  - p_end_at: 结束时间（含时区），窗口最大 90 天
  - p_bucket: 分桶粒度（hour/day），默认 day
  - p_source_ids: 来源 ID 列表
  - p_detection_method_codes: 侦测方式代码列表
  - p_quality_issue: 质量问题过滤
  
  返回 JSON 结构：
  - bucket: 分桶粒度
  - points: 时间序列点列表，每个点包含桶时间、架次数、高风险数等
  
  典型使用场景：
  - 架次趋势折线图
  - 高风险架次时间分布
  - 数据质量问题趋势
  - 按小时/日期对比分析$$;

commit;
