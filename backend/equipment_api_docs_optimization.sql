-- 优化设施设备管理 API 接口描述
-- 本脚本用于更新设施设备管理相关视图和函数的 COMMENT ON，使其更面向 API 使用者

begin;

-- ============================================================================
-- 设备资产核心视图
-- ============================================================================

comment on view api.equipment_assets is
  $$设施设备资产统一查询资源
  
  返回所有设施设备资产的统一视图，支持按类别过滤和分页查询。
  包含 13 个设备类别：6G 基站、反无设备、视频监控、无人机、无人车、车载监控、传感器、干扰设备、AOA 测向设备、微波雷达、RemoteID 接收器、定向能设备、光电设备。
  
  主要字段：
  - id: 资产 ID
  - asset_code: 资产编码（业务唯一标识）
  - category_code: 类别代码
  - type_code: 类型代码
  - name: 资产名称
  - source_system: 来源系统
  - source_asset_id: 来源资产 ID
  - managing_unit_name: 管理单位名称
  - deployment_mode: 部署模式（fixed/mobile）
  - lifecycle_status: 生命周期状态（active/inactive/decommissioned）
  - longitude / latitude: WGS84 坐标
  - elevation_amsl_m: 海拔高度（米）
  - height_datum: 高度基准（AMSL）
  - manufacturer: 厂商
  - model: 型号
  - serial_no: 序列号
  - is_simulated: 是否为模拟数据
  - metadata: 扩展属性 JSON
  - created_at / updated_at: 时间戳
  
  典型使用场景：
  - 设备资产管理后台列表页
  - 按类别筛选设备
  - 设备地图展示
  - 设备统计和报表
  
  注意：该视图支持 CRUD 操作，但建议使用 save_equipment_configuration() 函数进行原子保存。$$;

comment on view api.equipment_asset_admin_details is
  $$设备资产详情只读资源
  
  设备管理后台使用的资产详情视图，额外提供经纬度字段。
  与 equipment_assets 相比，该视图更适合详情页展示。
  
  主要字段：
  - id: 资产 ID
  - asset_code: 资产编码
  - category_code: 类别代码
  - type_code: 类型代码
  - name: 资产名称
  - source_system: 来源系统
  - source_asset_id: 来源资产 ID
  - managing_unit_name: 管理单位名称
  - deployment_mode: 部署模式
  - lifecycle_status: 生命周期状态
  - longitude: 经度（WGS84 十进制度）
  - latitude: 纬度（WGS84 十进制度）
  - elevation_amsl_m: 海拔高度（米）
  - height_datum: 高度基准
  - manufacturer: 厂商
  - model: 型号
  - serial_no: 序列号
  - is_simulated: 是否为模拟数据
  - metadata: 扩展属性 JSON
  - created_at / updated_at: 时间戳
  
  典型使用场景：
  - 设备详情页展示
  - 设备信息编辑表单
  - 设备导出报表
  
  注意：该视图为只读，不支持直接写操作。$$;

comment on view api.equipment_asset_status is
  $$设备当前状态 CRUD 资源
  
  设备当前连接、调度和位置状态的实时视图。
  
  主要字段：
  - asset_id: 资产 ID
  - connectivity_status: 连接状态（online/offline/degraded/unknown）
  - dispatch_status: 调度状态（available/dispatched/maintenance/unavailable）
  - position_geom: 当前位置（WGS84 Point）
  - position_height_amsl_m: 当前位置海拔（米）
  - height_datum: 高度基准
  - last_heartbeat_at: 最后心跳时间
  - observed_at: 最后观测时间
  - payload: 状态扩展信息 JSON
  - updated_at: 更新时间
  
  典型使用场景：
  - 设备在线状态监控
  - 设备调度状态管理
  - 设备实时位置展示
  - 设备心跳监控
  
  注意：该视图支持 CRUD 操作，状态通常由设备连接器自动更新。$$;

-- ============================================================================
-- 设备能力与覆盖
-- ============================================================================

comment on view api.equipment_asset_capabilities is
  $$设备能力及接入级别只读资源
  
  设备已配置的能力列表及接入级别。
  
  主要字段：
  - id: 能力配置 ID
  - asset_id: 资产 ID
  - capability_code: 能力代码
  - access_level: 接入级别（observable/recommendable/linkable/controllable）
  - enabled: 是否启用
  - parameters: 能力参数 JSON（如探测范围、频率范围等）
  - created_at / updated_at: 时间戳
  
  接入级别说明：
  - observable: 可观测（只读展示）
  - recommendable: 可建议（可推荐处置方案）
  - linkable: 可联动（可触发联动动作）
  - controllable: 可控制（可直接控制设备）
  
  典型使用场景：
  - 设备能力配置查看
  - 设备接入级别管理
  - 处置能力匹配
  
  注意：该视图为只读，能力配置通过 save_equipment_configuration() 函数管理。$$;

comment on view api.equipment_asset_coverages is
  $$设备能力空间覆盖只读资源
  
  设备能力的空间覆盖范围及 AMSL 高度范围。
  
  主要字段：
  - id: 覆盖 ID
  - asset_capability_id: 设备能力 ID
  - coverage_geom: 覆盖范围（WGS84 MultiPolygon）
  - min_height_amsl_m: 最小高度（米，AMSL）
  - max_height_amsl_m: 最大高度（米，AMSL）
  - height_datum: 高度基准（AMSL）
  - valid_from: 生效时间
  - valid_to: 失效时间
  - metadata: 覆盖元数据 JSON，包含：
    - coverage_model: 覆盖模型（manual/radial/sector）
    - radius_m: 覆盖半径（米，radial/sector 模型）
    - azimuth_start_deg: 起始方位角（度，sector 模型）
    - azimuth_end_deg: 结束方位角（度，sector 模型）
    - generated_from_asset_position: 是否从设备位置生成
  
  典型使用场景：
  - 设备覆盖范围地图展示
  - 覆盖范围分析
  - 处置能力覆盖匹配
  
  注意：该视图为只读，覆盖配置通过 save_equipment_configuration() 函数管理。$$;

comment on view api.equipment_capability_catalog is
  $$设备能力字典只读资源
  
  平台定义的所有设备能力类型。
  
  主要字段：
  - code: 能力代码
  - name: 能力名称
  - capability_type: 能力类型（detection/identification/tracking/countermeasure/communication）
  - description: 能力说明
  
  典型使用场景：
  - 设备能力配置下拉选择
  - 能力类型统计
  - 能力字典查询
  
  注意：该视图为只读，能力字典由系统管理员维护。$$;

comment on view api.equipment_asset_categories is
  $$设施设备类别字典只读资源
  
  平台定义的所有设备类别。
  
  主要字段：
  - code: 类别代码
  - name: 类别名称
  - category_group: 类别分组
  - description: 类别说明
  - enabled: 是否启用
  - sort_order: 排序权重
  
  典型使用场景：
  - 设备类别筛选器
  - 设备分类统计
  - 设备类别字典查询
  
  注意：该视图为只读，类别字典由系统管理员维护。$$;

-- ============================================================================
-- 设备专业属性视图
-- ============================================================================

comment on view api.equipment_microwave_radar_profiles is
  $$微波雷达设备专业属性只读资源
  
  微波雷达设备的专业属性配置。
  
  主要字段：
  - asset_id: 资产 ID
  - model_code: 型号代码
  - work_system: 工作体制
  - frequency_band: 频段
  - range_search_m: 搜索距离（米）
  - range_phase_search_m: 相控阵搜索距离（米）
  - coverage_height_m: 覆盖高度（米）
  - capacity_search: 搜索容量（批）
  - capacity_track: 跟踪容量（批）
  - power_w: 功率（瓦）
  - created_at / updated_at: 时间戳
  
  典型使用场景：
  - 微波雷达配置查看
  - 雷达性能参数展示
  - 雷达覆盖分析
  
  注意：该视图为只读，专业属性通过 save_microwave_radar_configuration() 函数管理。$$;

comment on view api.equipment_microwave_radar_assets is
  $$微波雷达资产台账只读资源
  
  微波雷达资产台账、型号关键规格与当前状态的联合视图。
  
  主要字段：
  - asset_id: 资产 ID
  - asset_code: 资产编码
  - name: 资产名称
  - model_code: 型号代码
  - model_name: 型号名称
  - manufacturer: 厂商
  - work_system: 工作体制
  - frequency_band: 频段
  - range_search_m: 搜索距离（米）
  - coverage_height_m: 覆盖高度（米）
  - connectivity_status: 连接状态
  - dispatch_status: 调度状态
  - longitude / latitude: WGS84 坐标
  - last_heartbeat_at: 最后心跳时间
  
  典型使用场景：
  - 微波雷达台账管理
  - 雷达状态监控
  - 雷达性能统计
  
  注意：该视图为只读，不支持直接写操作。$$;

comment on view api.equipment_radar_models is
  $$微波探测雷达型号只读资源
  
  微波探测雷达型号及静态规格。
  
  主要字段：
  - model_code: 型号代码
  - name: 型号名称
  - manufacturer: 厂商
  - work_system: 工作体制
  - frequency_band: 频段
  - range_search_m: 搜索距离（米）
  - range_phase_search_m: 相控阵搜索距离（米）
  - coverage_height_m: 覆盖高度（米）
  - capacity_search: 搜索容量（批）
  - capacity_track: 跟踪容量（批）
  - power_w: 功率（瓦）
  - created_at / updated_at: 时间戳
  
  典型使用场景：
  - 雷达型号字典查询
  - 雷达型号统计
  - 雷达性能对比
  
  注意：该视图为只读，型号信息由系统管理员维护。$$;

comment on view api.equipment_aoa_direction_finder_profiles is
  $$AOA 到达角测向设备专业属性只读资源
  
  AOA（Angle of Arrival）到达角测向设备的专业属性配置。
  
  典型使用场景：
  - AOA 测向设备配置查看
  - 测向性能参数展示
  
  注意：该视图为只读，专业属性通过 save_equipment_configuration() 函数管理。$$;

comment on view api.equipment_directed_energy_device_profiles is
  $$定向能处置设备专业属性只读资源
  
  定向能处置设备（如激光武器）的专业属性配置。
  
  典型使用场景：
  - 定向能设备配置查看
  - 处置性能参数展示
  
  注意：该视图为只读，专业属性通过 save_equipment_configuration() 函数管理。$$;

comment on view api.equipment_electro_optical_device_profiles is
  $$光电设备专业属性只读资源
  
  光电设备（可见光/红外/热成像）的专业属性配置。
  
  典型使用场景：
  - 光电设备配置查看
  - 观测性能参数展示
  
  注意：该视图为只读，专业属性通过 save_equipment_configuration() 函数管理。$$;

comment on view api.equipment_jamming_device_profiles is
  $$干扰设备专业属性只读资源
  
  干扰设备的专属性配置。
  
  典型使用场景：
  - 干扰设备配置查看
  - 干扰性能参数展示
  
  注意：该视图为只读，专业属性通过 save_equipment_configuration() 函数管理。$$;

comment on view api.equipment_remote_id_receiver_profiles is
  $$RemoteID 接收设备专业属性只读资源
  
  RemoteID（远程识别）接收设备的专业属性配置。
  
  典型使用场景：
  - RemoteID 接收器配置查看
  - 接收性能参数展示
  
  注意：该视图为只读，专业属性通过 save_equipment_configuration() 函数管理。$$;

-- ============================================================================
-- 反无设备遥测与状态
-- ============================================================================

comment on view api.counter_uas_telemetry_current is
  $$反无综合设备最新遥测只读资源
  
  反无综合设备（集成侦测和处置功能）的最新 config_status 遥测快照。
  
  主要字段：
  - asset_id: 资产 ID
  - observed_at: 观测时间
  - received_at: 接收时间
  - unattended: 是否无人值守
  - detection_device_online: 侦测子系统是否在线
  - countermeasure_device_online: 处置子系统是否在线
  - counter_voltage_v: 处置电压（V）
  - counter_current_a: 处置电流（A）
  - counter_power_w: 处置功率（W）
  - counter_temperature_c: 处置温度（℃）
  - detection_azimuth_deg: 侦测转台方位角（度）
  - detection_rotating: 侦测转台是否旋转
  - counter_azimuth_deg: 处置转台方位角（度）
  - counter_rotating: 处置转台是否旋转
  - active_frequencies_mhz: 当前开启频段（MHz 数组）
  - radar_device_sn: 雷达设备序列号
  - radar_asset_id: 关联雷达资产 ID
  - radar_online: 雷达是否在线
  - radar_geom: 雷达位置（WGS84 Point）
  - radar_altitude_amsl_m: 雷达海拔（米）
  - radar_heading_deg: 雷达航向角（度）
  - radar_base_heading_deg: 雷达安装基准航向角（度）
  - radar_gps_update_enabled: 雷达是否启用 GPS 更新
  - quality_flags: 数据质量标记数组
  - raw_payload: 原始载荷 JSON
  - updated_at: 更新时间
  
  典型使用场景：
  - 反无设备实时监控
  - 设备状态仪表板
  - 设备性能分析
  
  注意：该视图为只读，遥测数据由设备连接器自动更新。$$;

comment on view api.counter_uas_status_events is
  $$反无设备状态变化历史只读资源
  
  反无设备离散状态发生变化时追加保存的长期事件历史。
  
  主要字段：
  - id: 事件 ID
  - asset_id: 资产 ID
  - event_type: 事件类型（initialized/status_changed）
  - changed_fields: 变化字段列表
  - previous_state: 变化前状态 JSON
  - current_state: 变化后状态 JSON
  - observed_at: 观测时间
  - received_at: 接收时间
  - created_at: 创建时间
  
  典型使用场景：
  - 设备状态变化审计
  - 设备故障诊断
  - 设备运行历史回溯
  
  注意：该视图为只读，事件由设备连接器自动追加。$$;

comment on view api.counter_uas_telemetry_samples is
  $$反无设备遥测采样只读资源
  
  反无设备连续遥测的限频采样历史，默认每个设备最多每 60 秒一条。
  
  主要字段：
  - id: 采样 ID
  - asset_id: 资产 ID
  - observed_at: 观测时间
  - received_at: 接收时间
  - counter_voltage_v: 处置电压（V）
  - counter_current_a: 处置电流（A）
  - counter_power_w: 处置功率（W）
  - counter_temperature_c: 处置温度（℃）
  - detection_azimuth_deg: 侦测转台方位角（度）
  - counter_azimuth_deg: 处置转台方位角（度）
  - active_frequencies_mhz: 当前开启频段（MHz 数组）
  - radar_online: 雷达是否在线
  - radar_heading_deg: 雷达航向角（度）
  - quality_flags: 数据质量标记数组
  - raw_payload: 原始载荷 JSON
  - sampled_at: 采样时间
  
  典型使用场景：
  - 设备遥测历史查询
  - 设备性能趋势分析
  - 设备故障诊断
  
  注意：该视图为只读，采样数据由系统自动限频保存。$$;

-- ============================================================================
-- 设备观测与统计
-- ============================================================================

comment on view api.equipment_raw_observations is
  $$设备原始观测查询与追加资源
  
  设备产生的原始观测记录，禁止更新和删除。
  
  主要字段：
  - id: 观测 ID
  - asset_id: 资产 ID
  - source_system: 来源系统
  - source_observation_id: 来源观测 ID
  - observation_type: 观测类型
  - observed_at: 观测时间
  - received_at: 接收时间
  - geom: 观测位置（WGS84 Point）
  - height_amsl_m: 海拔高度（米）
  - height_datum: 高度基准
  - processing_status: 处理状态（normalized/needs_review/failed）
  - raw_payload: 原始载荷 JSON
  - is_simulated: 是否为模拟数据
  - created_at: 创建时间
  
  典型使用场景：
  - 设备观测历史查询
  - 观测数据质量检查
  - 观测数据回溯分析
  
  注意：该视图支持追加（POST），禁止更新（PATCH）和删除（DELETE）。$$;

comment on view api.equipment_online_statistics is
  $$设备在线统计只读资源
  
  按设备类别统计设备总数、在线设备数和在线率。
  
  主要字段：
  - category_code: 类别代码
  - category_name: 类别名称
  - total_count: 设备总数
  - online_count: 在线设备数
  - online_rate: 在线率（0-1）
  
  典型使用场景：
  - 设备在线率仪表板
  - 各类别设备统计
  - 设备可用性监控
  
  注意：该视图为只读，数据实时计算。$$;

comment on view api.equipment_statistics is
  $$设备统计资源
  
  按类别、连接状态和调度状态分组的设备统计。
  
  主要字段：
  - category_code: 类别代码
  - connectivity_status: 连接状态
  - dispatch_status: 调度状态
  - count: 设备数量
  
  典型使用场景：
  - 设备统计仪表板
  - 设备状态分布分析
  - 设备报表生成
  
  注意：该视图为只读，数据实时计算。$$;

comment on view api.aircraft_assets is
  $$无人机资产兼容查询资源
  
  基于统一设备模型的既有无人机兼容查询资源。
  该视图为向后兼容而保留，建议使用 equipment_assets 视图。
  
  典型使用场景：
  - 无人机资产查询（兼容旧接口）
  - 无人机统计
  
  注意：该视图为只读，新开发请使用 equipment_assets 视图。$$;

-- ============================================================================
-- 设备配置管理函数
-- ============================================================================

comment on function api.get_equipment_configuration(bigint) is
  $$获取设备完整配置
  
  返回单个设备的资产、专业属性、能力、传感通道和调度资源配置。
  适合设备详情页展示和编辑。
  
  参数说明：
  - p_asset_id: 设备资产 ID
  
  返回 JSON 结构：
  - asset: 资产基本信息（包含 longitude/latitude）
  - profile: 专业属性（根据 category_code 不同而结构不同）
  - capabilities: 能力配置数组，每项包含：
    - id: 能力配置 ID
    - capability_code: 能力代码
    - capability_name: 能力名称
    - capability_type: 能力类型
    - access_level: 接入级别
    - enabled: 是否启用
    - parameters: 能力参数 JSON
  - sensor_channels: 传感通道数组（仅 sensor 类别有值）
  - dispatch_resource: 调度资源配置（可为 null）
  - coverages: 覆盖范围数组，每项包含：
    - id: 覆盖 ID
    - capability_code: 能力代码
    - coverage_geom: 覆盖范围（GeoJSON）
    - min_height_amsl_m: 最小高度（米）
    - max_height_amsl_m: 最大高度（米）
    - height_datum: 高度基准
    - valid_from: 生效时间
    - valid_to: 失效时间
    - metadata: 覆盖元数据
    - coverage_model: 覆盖模型
    - radius_m: 覆盖半径（米）
    - azimuth_start_deg: 起始方位角（度）
    - azimuth_end_deg: 结束方位角（度）
    - generated_from_asset_position: 是否从设备位置生成
  
  典型使用场景：
  - 设备详情页加载
  - 设备配置编辑表单
  - 设备配置导出
  
  注意：返回的 updated_at 可用于乐观锁，防止并发冲突。$$;

comment on function api.save_equipment_configuration(jsonb,jsonb,timestamptz) is
  $$保存设备完整配置（原子事务）
  
  在单个事务中保存设备资产、专业属性、能力、传感通道和调度资源。
  支持新建和更新，使用乐观锁防止并发冲突。
  
  参数说明：
  - p_asset: 资产配置 JSON 对象，包含：
    - id: 资产 ID（更新时必填，新建时不传）
    - asset_code: 资产编码（必填）
    - category_code: 类别代码（必填，不可修改）
    - name: 资产名称（必填）
    - longitude / latitude: WGS84 坐标（必填）
    - elevation_amsl_m: 海拔高度（米）
    - manufacturer: 厂商
    - model: 型号
    - serial_no: 序列号
    - managing_unit_name: 管理单位名称
    - deployment_mode: 部署模式
    - is_simulated: 是否为模拟数据
    - metadata: 扩展属性 JSON
    - capabilities: 能力配置数组（可选）
    - coverages: 覆盖范围数组（可选）
    - sensor_channels: 传感通道数组（可选，仅 sensor 类别）
    - dispatch_resource: 调度资源配置（可选）
  - p_profile: 专业属性 JSON 对象（根据 category_code 不同而结构不同）
  - p_expected_updated_at: 期望的更新时间（可选，用于乐观锁）
  
  返回 JSON：
  - asset_id: 资产 ID
  - updated_at: 更新时间
  
  典型使用场景：
  - 新建设备资产
  - 更新设备配置
  - 批量配置设备能力和覆盖
  
  约束：
  - category_code 不可修改
  - 更新时必须提供 expected_updated_at 做乐观锁
  - 能力参数必须符合验证规则（距离、频率范围等）
  - 覆盖范围必须是有效的 Polygon 或 MultiPolygon GeoJSON
  - 扇形覆盖的方位角必须在 0-360 之间
  
  注意：请使用此函数而非直接操作视图，确保数据一致性。$$;

comment on function api.save_microwave_radar_configuration(jsonb,jsonb,timestamptz) is
  $$保存微波雷达配置（兼容接口）
  
  兼容雷达管理页面的事务保存接口，内部调用 save_equipment_configuration()。
  自动设置 category_code 为 'microwave_radar'。
  
  参数说明：
  - p_asset: 资产配置 JSON 对象（不需要 category_code）
  - p_profile: 雷达专业属性 JSON 对象，包含：
    - model_code: 型号代码（必填）
    - work_system: 工作体制
    - frequency_band: 频段
    - range_search_m: 搜索距离（米）
    - range_phase_search_m: 相控阵搜索距离（米）
    - coverage_height_m: 覆盖高度（米）
    - capacity_search: 搜索容量（批）
    - capacity_track: 跟踪容量（批）
    - power_w: 功率（瓦）
  - p_expected_updated_at: 期望的更新时间（可选，用于乐观锁）
  
  返回 JSON：
  - asset_id: 资产 ID
  - updated_at: 更新时间
  
  典型使用场景：
  - 新建微波雷达
  - 更新雷达配置
  
  注意：新开发建议直接使用 save_equipment_configuration()。$$;

comment on function api.update_equipment_category(text,jsonb) is
  $$更新设备类别
  
  按编码更新设备类别的名称、分组、说明、启用状态和排序。
  不允许修改编码。
  
  参数说明：
  - p_code: 类别编码（不可修改）
  - p_changes: 变更字段 JSON 对象，支持：
    - name: 新名称
    - category_group: 新分组
    - description: 新说明
    - enabled: 是否启用
    - sort_order: 排序权重
  
  无返回值。
  
  典型使用场景：
  - 修改类别名称
  - 调整类别分组
  - 启用或禁用类别
  - 调整类别排序
  
  注意：类别编码不可修改，仅可更新其他属性。$$;

comment on function api.update_equipment_capability(text,jsonb) is
  $$更新设备能力
  
  按编码更新设备能力的名称、类型和说明。
  不允许修改编码。
  
  参数说明：
  - p_code: 能力编码（不可修改）
  - p_changes: 变更字段 JSON 对象，支持：
    - name: 新名称
    - capability_type: 新类型
    - description: 新说明
  
  无返回值。
  
  典型使用场景：
  - 修改能力名称
  - 调整能力类型
  - 更新能力说明
  
  注意：能力编码不可修改，仅可更新其他属性。$$;

comment on function api.update_equipment_radar_model(text,jsonb) is
  $$更新雷达型号
  
  按型号编码更新雷达型号名称、厂商和常用静态规格。
  不允许修改型号编码。
  
  参数说明：
  - p_model_code: 型号编码（不可修改）
  - p_changes: 变更字段 JSON 对象，支持：
    - name: 新名称
    - manufacturer: 新厂商
    - work_system: 工作体制
    - frequency_band: 频段
    - range_search_m: 搜索距离（米）
    - range_phase_search_m: 相控阵搜索距离（米）
    - coverage_height_m: 覆盖高度（米）
    - capacity_search: 搜索容量（批）
    - capacity_track: 跟踪容量（批）
    - power_w: 功率（瓦）
  
  无返回值。
  
  典型使用场景：
  - 修改雷达型号名称
  - 更新厂商信息
  - 调整雷达规格参数
  
  注意：型号编码不可修改，仅可更新其他属性。$$;

commit;
