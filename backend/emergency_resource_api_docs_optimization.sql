-- 优化应急资源与警务 API 接口描述
-- 本脚本用于更新应急资源与警务相关视图和函数的 COMMENT ON，使其更面向 API 使用者

begin;

-- ============================================================================
-- 应急资源台账与统计
-- ============================================================================

comment on view api.emergency_resource_admin_details is
  $$应急资源统一台账
  
  返回所有正式应急资源的统一视图，包含 8 个类别：医疗资源、专家力量、避难场所、物资仓库、取水点、起降点、警务站和设备资源。
  不包含逐步退出的历史救援队伍（rescue_force）。
  
  返回字段：
  - category_code: 资源类别代码（medical_resource/expert_force/shelter/material_warehouse/water_point/landing_site/police_station/equipment_resource）
  - resource_id: 资源 ID
  - source_code: 来源编码
  - name: 资源名称
  - managing_unit_name: 管理单位名称
  - contact_phone: 联系电话
  - availability_status: 可用状态（available/busy/standby/unavailable 等，按类别不同）
  - is_simulated: 是否为模拟数据
  - longitude / latitude: WGS84 坐标
  - details: 类别特有的扩展属性（JSON 对象）
  - created_at / updated_at: 时间戳
  
  典型使用场景：
  - 应急资源管理后台统一列表
  - 按类别筛选和统计
  - 资源地图展示
  - 资源可用性监控
  
  注意：该视图为只读，不支持直接 CRUD 操作。$$;

comment on view api.emergency_resource_admin_statistics is
  $$应急资源分类统计
  
  按资源类别实时统计总数、可用数、模拟数和最后更新时间。
  
  返回字段：
  - category_code: 资源类别代码
  - resource_count: 资源总数
  - available_count: 可用数（状态为 available 或 standby）
  - simulated_count: 模拟数据数量
  - last_updated_at: 最后更新时间
  
  典型使用场景：
  - 应急资源仪表板统计卡片
  - 各类别资源可用性监控
  - 模拟数据占比分析
  
  注意：该视图为只读，数据实时计算。$$;

comment on view api.emergency_resource_category_statistics is
  $$应急资源类别统计快照
  
  各类应急资源数量的物化统计快照，定期刷新。
  
  典型使用场景：
  - 应急资源统计仪表板
  - 快速查看各类别资源数量
  - 避免实时统计的性能开销
  
  注意：该视图为只读，数据通过 refresh_emergency_resource_category_statistics() 函数刷新。$$;

comment on view api.emergency_rescue_forces is
  $$救援力量 CRUD 资源
  
  可用于灾害应急场景的救援队伍或保障力量。
  当前记录均为花果山景区模拟数据。
  
  主要字段：
  - source_code: 来源编码
  - name: 队伍名称
  - force_type: 力量类型（forest_fire/rescue/ranger/volunteer）
  - unit_name: 所属单位
  - commander_name: 指挥官姓名
  - contact_phone: 联系电话
  - personnel_count: 人员数量
  - availability_status: 可用状态（available/deployed/standby/unavailable）
  - is_simulated: 是否为模拟数据
  - longitude / latitude: WGS84 坐标
  
  典型使用场景：
  - 救援力量管理后台
  - 灾害应急场景资源调度
  - 救援力量地图展示
  
  注意：该类别正在逐步退出，新增救援力量请使用其他应急资源类别。$$;

comment on view api.emergency_rescue_forces_history is
  $$历史救援队伍只读资源
  
  逐步退出的历史救援队伍记录，不允许新增、修改或删除。
  
  典型使用场景：
  - 历史救援队伍查询
  - 历史数据回溯
  - 数据迁移参考
  
  注意：该视图为只读，不支持任何写操作。$$;

-- ============================================================================
-- 应急资源具体类别
-- ============================================================================

comment on view api.emergency_medical_resources is
  $$医疗资源 CRUD 资源
  
  医疗救护站、医疗点和救护车辆等医疗保障资源。
  当前记录均为花果山景区模拟数据。
  
  主要字段：
  - source_code: 来源编码
  - name: 资源名称
  - resource_type: 资源类型（clinic/first_aid_station/ambulance_station）
  - unit_name: 所属单位
  - contact_phone: 联系电话
  - service_capacity: 单次可服务人数
  - ambulance_count: 救护车数量
  - availability_status: 可用状态（available/busy/standby/unavailable）
  - is_simulated: 是否为模拟数据
  - longitude / latitude: WGS84 坐标
  
  典型使用场景：
  - 医疗资源管理后台
  - 应急医疗资源调度
  - 医疗资源地图展示
  - 医疗容量估算$$;

comment on view api.emergency_experts is
  $$专家力量 CRUD 资源
  
  可参与应急处置的专家资源。
  当前记录均为花果山景区模拟数据。
  
  主要字段：
  - source_code: 来源编码
  - name: 专家姓名
  - organization_name: 所属机构
  - contact_phone: 联系电话
  - availability_status: 可用状态
  - is_simulated: 是否为模拟数据
  - longitude / latitude: WGS84 坐标
  
  典型使用场景：
  - 专家资源管理后台
  - 应急处置专家调度
  - 专家资源地图展示$$;

comment on view api.emergency_shelters is
  $$避难场所 CRUD 资源
  
  应急避难场所资源。
  当前记录均为花果山景区模拟数据。
  
  主要字段：
  - source_code: 来源编码
  - name: 场所名称
  - managing_unit_name: 管理单位
  - contact_phone: 联系电话
  - availability_status: 可用状态
  - is_simulated: 是否为模拟数据
  - longitude / latitude: WGS84 坐标
  
  典型使用场景：
  - 避难场所管理后台
  - 应急避难场所调度
  - 避难场所地图展示$$;

comment on view api.emergency_material_warehouses is
  $$物资仓库 CRUD 资源
  
  应急物资储备仓库。
  当前记录均为花果山景区模拟数据。
  
  主要字段：
  - source_code: 来源编码
  - name: 仓库名称
  - managing_unit_name: 管理单位
  - contact_phone: 联系电话
  - availability_status: 可用状态
  - is_simulated: 是否为模拟数据
  - longitude / latitude: WGS84 坐标
  
  典型使用场景：
  - 物资仓库管理后台
  - 应急物资调度
  - 物资仓库地图展示$$;

comment on view api.emergency_water_points is
  $$取水点 CRUD 资源
  
  消防和应急取水点资源。
  当前记录均为花果山景区模拟数据。
  
  主要字段：
  - source_code: 来源编码
  - name: 取水点名称
  - managing_unit_name: 管理单位
  - contact_phone: 联系电话
  - availability_status: 可用状态
  - is_simulated: 是否为模拟数据
  - longitude / latitude: WGS84 坐标
  
  典型使用场景：
  - 取水点管理后台
  - 消防取水调度
  - 取水点地图展示$$;

comment on view api.emergency_landing_sites is
  $$起降点 CRUD 资源
  
  无人机和直升机起降点资源。
  当前记录均为花果山景区模拟数据。
  
  主要字段：
  - source_code: 来源编码
  - name: 起降点名称
  - managing_unit_name: 管理单位
  - contact_phone: 联系电话
  - availability_status: 可用状态
  - is_simulated: 是否为模拟数据
  - longitude / latitude: WGS84 坐标
  
  典型使用场景：
  - 起降点管理后台
  - 无人机起降调度
  - 起降点地图展示$$;

-- ============================================================================
-- 警务管理
-- ============================================================================

comment on view api.emergency_police_stations is
  $$警务工作站 CRUD 资源
  
  警务工作站（警务站）资源。
  当前数据为天地图 POI 真实数据。
  
  主要字段：
  - source_code: 来源编码
  - name: 警务站名称
  - station_type: 警务站类型
  - address: 地址
  - county_name: 所属区县
  - contact_phone: 联系电话
  - availability_status: 可用状态
  - is_simulated: 是否为模拟数据
  - longitude / latitude: WGS84 坐标
  
  典型使用场景：
  - 警务站管理后台
  - 警务站地图展示
  - 警务编组挂载
  
  注意：警务站可以挂载多个警务编组。$$;

comment on view api.emergency_police_officers is
  $$警员档案 CRUD 资源
  
  可参与警务编组和事件处置调度的警员档案。
  警员档案与平台登录账号相互独立。
  
  主要字段：
  - officer_no: 警号（业务唯一标识）
  - name: 警员姓名
  - contact_phone: 工作联系方式（敏感信息，仅向已认证管理角色开放）
  - organization_name: 所属公安机关或业务单位
  - availability_status: 警员状态（available/on_duty/dispatched/leave/unavailable）
  - is_active: 档案是否有效
  - is_simulated: 是否为模拟数据
  
  典型使用场景：
  - 警员档案管理后台
  - 警员状态管理
  - 警务编组成员选择
  
  注意：联系方式为敏感信息，仅向已认证管理角色开放。$$;

comment on view api.emergency_police_teams is
  $$警务编组 CRUD 资源
  
  由一名组长和若干成员组成的警务编组，可挂载到一个警务站。
  
  主要字段：
  - team_code: 编组稳定且唯一的业务编码
  - name: 编组名称
  - station_id: 当前挂载的警务站 ID（为空表示暂未挂载）
  - team_status: 编组状态（active/standby/dispatched/inactive）
  - description: 编组描述
  - is_simulated: 是否为模拟数据
  
  典型使用场景：
  - 警务编组管理后台
  - 编组状态管理
  - 编组挂载到警务站
  
  注意：创建编组时请使用 create_police_team() 函数，确保同时设置组长。$$;

comment on view api.emergency_police_team_members is
  $$编组成员 CRUD 资源
  
  警员参加警务编组的成员关系及任职历史。
  组长也是 member_role=leader 的成员。
  
  主要字段：
  - team_id: 所属警务编组 ID
  - officer_id: 参加编组的警员 ID
  - member_role: 成员角色（leader/deputy_leader/member）
  - joined_at: 加入编组时间
  - left_at: 离开编组时间（为空表示当前成员）
  
  典型使用场景：
  - 编组成员管理
  - 成员任职历史查询
  - 编组花名册生成
  
  注意：
  - left_at 为空表示当前成员
  - 成员离组请使用 remove_police_team_member() 函数
  - 组长更换请使用 assign_police_team_leader() 函数$$;

comment on view api.emergency_police_team_roster is
  $$警务编组花名册只读资源
  
  当前警务编组的完整花名册，包含编组、警务站、警员和成员角色信息。
  
  返回字段：
  - membership_id: 当前编组成员关系 ID
  - team_id / team_code / team_name: 编组信息
  - team_status: 编组状态
  - station_id / station_source_code / station_name: 警务站信息
  - officer_id / officer_no / officer_name: 警员信息
  - contact_phone: 警员联系方式
  - organization_name: 警员所属单位
  - officer_availability_status: 警员状态
  - member_role: 当前成员角色（leader/deputy_leader/member）
  - joined_at: 加入时间
  
  典型使用场景：
  - 编组花名册展示
  - 编组人员详情查看
  - 编组结构分析
  
  注意：该视图为只读，仅返回当前成员（left_at 为空）。$$;

comment on view api.emergency_police_team_details is
  $$警务编组详情列表只读资源
  
  警务编组后台分页列表，返回编组、警务站、当前组长和当前成员数量。
  
  返回字段：
  - team_id / team_code / team_name: 编组信息
  - station_id / station_source_code / station_name: 警务站信息
  - team_status: 编组状态
  - description: 编组描述
  - is_simulated: 是否为模拟数据
  - leader_officer_id / leader_officer_no / leader_name: 当前组长信息
  - active_member_count: 当前成员数量
  - metadata: 扩展属性
  - created_at / updated_at: 时间戳
  
  典型使用场景：
  - 编组管理后台列表页
  - 编组详情快速查看
  - 编组统计信息展示
  
  注意：该视图为只读，适合列表页展示。$$;

comment on view api.emergency_police_team_member_history is
  $$编组成员任职历史只读资源
  
  警务编组成员的完整任职历史，包含当前及已离组成员。
  
  返回字段：
  - membership_id: 成员关系 ID
  - team_id / team_code / team_name: 编组信息
  - station_id / station_name: 警务站信息
  - officer_id / officer_no / officer_name: 警员信息
  - organization_name: 警员所属单位
  - member_role: 成员角色
  - joined_at: 加入时间
  - left_at: 离开时间（为空表示当前成员）
  - created_at / updated_at: 时间戳
  
  典型使用场景：
  - 编组成员历史查询
  - 警员任职轨迹追溯
  - 编组人员变动分析
  
  注意：该视图为只读，包含所有历史成员记录。$$;

comment on view api.emergency_police_station_team_details is
  $$警务站与编组层级结构只读资源
  
  面向前端的一站式层级结构：每行对应一个警务站，内嵌该站挂载的所有编组及当前成员。
  
  返回字段：
  - station_id / station_code / station_name: 警务站信息
  - station_type: 警务站类型
  - address: 地址
  - county_name: 所属区县
  - contact_phone: 联系电话
  - availability_status: 可用状态
  - geom: 空间位置
  - team_count: 挂载的编组数量
  - officer_count: 各编组当前成员关系总数（同一警员兼任多个编组时重复计数）
  - teams: 编组及其当前成员的 JSON 数组，每个编组包含：
    - team_id / team_code / team_name: 编组信息
    - team_status: 编组状态
    - is_simulated: 是否为模拟数据
    - leader_officer_id / leader_officer_no / leader_name: 组长信息
    - member_count: 成员数量
    - members: 成员列表 JSON 数组（按角色排序：组长 > 副组长 > 普通成员）
  
  典型使用场景：
  - 警务站与编组层级展示
  - 警务站详情页
  - 编组结构树形展示
  - 一键查看警务站下所有编组和成员
  
  注意：该视图为只读，数据结构适合前端树形或层级展示。$$;

-- ============================================================================
-- 警务编组操作函数
-- ============================================================================

comment on function api.create_police_team(text,text,bigint,bigint,text,text,boolean,jsonb) is
  $$创建警务编组
  
  原子创建警务编组并设置首任组长。
  避免后台产生没有组长的半完成记录。
  
  参数说明：
  - p_team_code: 编组业务编码（唯一，不可修改）
  - p_name: 编组名称
  - p_leader_officer_id: 首任组长警员 ID（必须是有效警员）
  - p_station_id: 挂载的警务站 ID（可选，为空表示暂未挂载）
  - p_team_status: 编组状态（active/standby/dispatched/inactive），默认 active
  - p_description: 编组描述（可选）
  - p_is_simulated: 是否为模拟数据，默认 false
  - p_metadata: 扩展属性 JSON，默认空对象
  
  返回：新建的警务编组完整记录
  
  典型使用场景：
  - 新建警务编组
  - 编组初始化
  
  注意：
  - 必须指定首任组长
  - 组长会自动成为编组成员（member_role=leader）
  - 请使用此函数而非直接插入 emergency_police_teams 视图$$;

comment on function api.assign_police_team_leader(bigint,bigint) is
  $$设置或更换编组组长
  
  原子设置或更换警务编组组长。
  如果指定警员已是成员，则升级为组长；否则新建成员关系。
  如果编组已有组长，则原组长降级为普通成员。
  
  参数说明：
  - p_team_id: 警务编组 ID
  - p_officer_id: 新组长警员 ID（必须是有效警员）
  
  返回：更新后的成员关系记录
  
  典型使用场景：
  - 更换编组组长
  - 组长职务调整
  - 编组领导权交接
  
  注意：
  - 操作是原子的，不会出现无组长状态
  - 原组长会降级为普通成员，不会离组
  - 请使用此函数而非直接修改成员角色$$;

comment on function api.remove_police_team_member(bigint,timestamptz) is
  $$成员离组
  
  记录普通成员或副组长离组，保留历史记录。
  通过设置 left_at 时间标记离组，不删除记录。
  
  参数说明：
  - p_membership_id: 成员关系 ID
  - p_left_at: 离组时间（可选，默认当前时间，不能早于加入时间）
  
  返回：更新后的成员关系记录
  
  典型使用场景：
  - 成员退出编组
  - 副组长职务调整
  - 成员离组历史记录
  
  约束：
  - 当前组长不能直接离组，必须先通过 assign_police_team_leader() 完成交接
  - left_at 不能早于 joined_at
  - 已离组的成员（left_at 不为空）重复调用会直接返回原记录
  
  注意：请使用此函数而非直接修改 left_at 字段$$;

comment on function api.refresh_emergency_resource_category_statistics() is
  $$刷新应急资源类别统计快照
  
  刷新各类应急资源数量统计快照。
  
  返回：本次刷新时间（timestamptz）
  
  典型使用场景：
  - 定期刷新统计快照
  - 统计数据变更后手动刷新
  - 避免实时统计的性能开销
  
  注意：
  - 该函数由管理员调用
  - 建议通过定时任务定期调用
  - 刷新后 emergency_resource_category_statistics 视图数据会更新$$;

commit;
