export type ProfileFieldKind = 'text' | 'number' | 'boolean' | 'tags'

export interface ProfileFieldDefinition {
  key: string
  label: string
  kind: ProfileFieldKind
  placeholder?: string
  min?: number
  max?: number
  precision?: number
  default?: unknown
}

const text = (key: string, label: string, placeholder?: string): ProfileFieldDefinition => ({ key, label, kind: 'text', placeholder })
const number = (key: string, label: string, options: Partial<ProfileFieldDefinition> = {}): ProfileFieldDefinition => ({ key, label, kind: 'number', ...options })
const bool = (key: string, label: string, defaultValue = false): ProfileFieldDefinition => ({ key, label, kind: 'boolean', default: defaultValue })
const tags = (key: string, label: string, placeholder?: string): ProfileFieldDefinition => ({ key, label, kind: 'tags', placeholder, default: [] })

export const equipmentProfileFields: Record<string, ProfileFieldDefinition[]> = {
  base_station_6g: [
    text('operator_name', '运营单位'), text('frequency_band', '频段'),
    number('bandwidth_mhz', '带宽（MHz）', { min: 0, precision: 2 }), text('backhaul_type', '回传链路'),
  ],
  counter_uas: [
    text('detection_mode', '探测方式'), text('identification_mode', '识别方式'),
    text('tracking_mode', '跟踪方式'), text('recommendation_notes', '推荐说明'),
  ],
  video_surveillance: [
    text('camera_type', '摄像机类型'), bool('ptz_supported', '支持云台'),
    number('optical_zoom', '光学变焦倍数', { min: 0, precision: 1 }), text('stream_ref', '视频流安全引用'),
  ],
  uav: [
    number('max_takeoff_weight_kg', '最大起飞重量（kg）', { min: 0, precision: 2 }),
    number('endurance_min', '续航时间（分钟）', { min: 1 }),
    number('max_payload_kg', '最大载荷（kg）', { min: 0, precision: 2 }),
  ],
  unmanned_vehicle: [
    text('vehicle_type', '车辆类型'), number('max_speed_kph', '最大速度（km/h）', { min: 0, precision: 1 }),
    number('endurance_min', '续航时间（分钟）', { min: 1 }),
    number('max_payload_kg', '最大载荷（kg）', { min: 0, precision: 2 }),
  ],
  vehicle_surveillance: [
    number('camera_count', '摄像机数量', { min: 0 }), number('sensor_count', '传感器数量', { min: 0 }),
    text('stream_ref', '视频流安全引用'),
  ],
  sensor: [text('sensor_type', '传感器类型'), number('sampling_interval_s', '采样间隔（秒）', { min: 1 })],
  jamming_device: [
    tags('jamming_modes', '干扰模式', '输入后回车添加'), text('frequency_range', '频率范围'),
    number('max_effective_range_m', '最大作用距离（m）', { min: 0, precision: 1 }),
    bool('directional_supported', '支持定向'), tags('target_protocols', '目标协议'),
    bool('authorization_required', '需要授权', true), text('recommendation_notes', '推荐说明'),
  ],
  aoa_direction_finder: [
    text('frequency_range', '频率范围'), number('azimuth_min_deg', '最小方位角（°）', { min: 0, max: 360, precision: 1 }),
    number('azimuth_max_deg', '最大方位角（°）', { min: 0, max: 360, precision: 1 }),
    number('azimuth_accuracy_deg', '方位精度（°）', { min: 0, precision: 2 }),
    bool('elevation_supported', '支持俯仰测量'), text('localization_mode', '定位方式'),
    number('antenna_count', '天线数量', { min: 1 }), text('recommendation_notes', '推荐说明'),
  ],
  microwave_radar: [
    number('face_count', '阵面数量', { min: 1, max: 4, default: 1 }),
    number('install_azimuth_deg', '安装方位角（°）', { min: 0, max: 359.9, precision: 1 }),
    number('install_tilt_deg', '安装俯仰角（°）', { min: -90, max: 90, precision: 1 }),
    text('control_host', '控制 IP'), number('control_port', '控制端口', { min: 1, max: 65535 }),
    text('protocol', '对接协议'), text('detection_mode', '探测方式'),
    bool('multi_target_supported', '支持多目标'), text('recommendation_notes', '推荐说明'),
  ],
  remote_id_receiver: [
    tags('protocol_codes', '协议编码'), text('receive_mode', '接收方式'),
    number('max_receive_range_m', '最大接收距离（m）', { min: 0, precision: 1 }),
    text('identity_resolution_mode', '身份解析方式'), text('time_synchronization_source', '时间同步源'),
    text('recommendation_notes', '推荐说明'),
  ],
  directed_energy_device: [
    text('effect_type', '作用类型'), number('effective_range_m', '有效距离（m）', { min: 0, precision: 1 }),
    number('azimuth_coverage_deg', '方位覆盖（°）', { min: 0, max: 360, precision: 1 }),
    number('elevation_coverage_deg', '俯仰覆盖（°）', { min: 0, max: 180, precision: 1 }),
    bool('tracking_supported', '支持跟踪'), bool('authorization_required', '需要授权', true),
    bool('simulated_linkage_only', '仅模拟联动', true), text('recommendation_notes', '推荐说明'),
  ],
  electro_optical_device: [
    tags('optical_modes', '光电模式'), text('camera_type', '摄像机类型'), bool('thermal_supported', '支持热成像'),
    bool('ptz_supported', '支持云台'), number('optical_zoom', '光学变焦倍数', { min: 0, precision: 1 }),
    number('detection_range_m', '探测距离（m）', { min: 0, precision: 1 }),
    number('recognition_range_m', '识别距离（m）', { min: 0, precision: 1 }),
    number('identification_range_m', '确认距离（m）', { min: 0, precision: 1 }),
    bool('tracking_supported', '支持跟踪'), text('stream_ref', '视频流安全引用'),
    text('recommendation_notes', '推荐说明'),
  ],
}

export function emptyProfile(categoryCode: string): Record<string, unknown> {
  return Object.fromEntries(
    (equipmentProfileFields[categoryCode] ?? []).map((field) => [field.key, field.default ?? null]),
  )
}
