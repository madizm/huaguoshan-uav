import { http, requestPaged, type PagedResult } from './http'

export interface AssetCategory {
  code: string
  name: string
  category_group: string
  description: string | null
  enabled: boolean
  sort_order: number
}
export interface CapabilityCatalogItem {
  code: string
  name: string
  capability_type: string
  description: string | null
}

export interface AssetCapabilityConfiguration {
  id?: number
  capability_code: string
  capability_name?: string
  capability_type?: string
  access_level: 'observable' | 'recommendable' | 'linkable' | 'controllable'
  enabled: boolean
  parameters: Record<string, unknown>
}

export interface SensorChannelConfiguration {
  id?: number
  channel_code: string
  metric_code: string
  unit: string | null
  warning_threshold: Record<string, unknown>
}

export interface AssetCoverageConfiguration {
  id?: number
  capability_code: string
  coverage_geom: Record<string, unknown>
  min_height_amsl_m: number | null
  max_height_amsl_m: number | null
  valid_from: string | null
  valid_to: string | null
  metadata: Record<string, unknown>
}

export interface DispatchResourceConfiguration {
  resource_role: string
  active: boolean
  available_from: string | null
  available_to: string | null
  metadata: Record<string, unknown>
}

export interface EquipmentAsset {
  id: number
  asset_code: string
  category_code: string
  type_code: string | null
  name: string
  source_system: string
  source_asset_id: string
  managing_unit_name: string | null
  deployment_mode: string | null
  lifecycle_status: string
  geom: unknown
  longitude: number
  latitude: number
  elevation_amsl_m: number | null
  manufacturer: string | null
  model: string | null
  serial_no: string | null
  created_at: string
  updated_at: string
  is_simulated: boolean
}

export interface RadarModel {
  model_code: string
  name: string
  manufacturer: string | null
  scan_mode: 'az_mech_el_phase' | 'four_face_phase'
  work_system: string
  frequency_band: string
  azimuth_coverage_deg: number
  range_search_m: number
  range_phase_search_m: number | null
  coverage_height_m: number
  capacity_search: number
  capacity_track: number
  power_w: number | null
}

export interface AssetListParams {
  categoryCode?: string
  keyword?: string
  isSimulated?: boolean
  limit: number
  offset: number
}

export function listCategories(): Promise<AssetCategory[]> {
  return http.get('/equipment_asset_categories', { order: 'sort_order.asc' })
}
export function listCapabilityCatalog(): Promise<CapabilityCatalogItem[]> {
  return http.get('/equipment_capability_catalog', { order: 'capability_type.asc,code.asc' })
}
export function updateCategory(code: string, changes: Partial<AssetCategory>): Promise<void> {
  return http.post('/rpc/update_equipment_category', { p_code: code, p_changes: changes })
}

export function updateCapability(code: string, changes: Partial<CapabilityCatalogItem>): Promise<void> {
  return http.post('/rpc/update_equipment_capability', { p_code: code, p_changes: changes })
}
export function updateRadarModel(modelCode: string, changes: Partial<RadarModel>): Promise<void> {
  return http.post('/rpc/update_equipment_radar_model', { p_model_code: modelCode, p_changes: changes })
}

export function listRadarModels(): Promise<RadarModel[]> {
  return http.get('/equipment_radar_models', { order: 'model_code.asc' })
}

export function listAssets(params: AssetListParams): Promise<PagedResult<EquipmentAsset>> {
  const query: Record<string, string> = {
    select: 'id,asset_code,category_code,type_code,name,source_system,source_asset_id,model,manufacturer,serial_no,managing_unit_name,deployment_mode,lifecycle_status,is_simulated,longitude,latitude,elevation_amsl_m,created_at,updated_at',
    order: 'id.desc',
  }
  if (params.categoryCode) query.category_code = `eq.${params.categoryCode}`
  if (params.keyword) query.or = `(asset_code.ilike.*${params.keyword}*,name.ilike.*${params.keyword}*)`
  if (params.isSimulated !== undefined) query.is_simulated = `eq.${params.isSimulated}`
  return requestPaged('/equipment_asset_admin_details', { query, limit: params.limit, offset: params.offset })
}

export interface AssetPayload {
  asset_code: string
  category_code: string
  name: string
  source_system: string
  source_asset_id: string
  managing_unit_name?: string | null
  deployment_mode?: string | null
  geom: string
  elevation_amsl_m?: number | null
  model?: string | null
  manufacturer?: string | null
}

export function updateAsset(id: number, payload: Partial<AssetPayload> & { lifecycle_status?: string }): Promise<void> {
  return http.patch('/equipment_assets', { id: `eq.${id}` }, payload)
}

export interface EquipmentConfiguration {
  asset: EquipmentAsset
  profile: Record<string, unknown>
  capabilities: AssetCapabilityConfiguration[]
  sensor_channels: SensorChannelConfiguration[]
  dispatch_resource: DispatchResourceConfiguration | null
  coverages: AssetCoverageConfiguration[]
}

export interface SaveEquipmentConfigurationRequest {
  asset: {
    id?: number
    asset_code: string
    category_code: string
    type_code: string | null
    name: string
    source_system?: string
    source_asset_id?: string
    managing_unit_name: string | null
    deployment_mode: string
    longitude: number
    latitude: number
    elevation_amsl_m: number | null
    manufacturer: string | null
    model: string | null
    serial_no: string | null
    is_simulated?: boolean
    capabilities?: AssetCapabilityConfiguration[]
    sensor_channels?: SensorChannelConfiguration[]
    dispatch_resource?: DispatchResourceConfiguration | null
    coverages?: AssetCoverageConfiguration[]
  }
  profile: Record<string, unknown>
  expectedUpdatedAt?: string
}

export interface SaveEquipmentConfigurationResult {
  asset_id: number
  updated_at: string
}

export function getEquipmentConfiguration(assetId: number): Promise<EquipmentConfiguration> {
  return http.post('/rpc/get_equipment_configuration', { p_asset_id: assetId })
}

export function saveEquipmentConfiguration(
  request: SaveEquipmentConfigurationRequest,
): Promise<SaveEquipmentConfigurationResult> {
  return http.post('/rpc/save_equipment_configuration', {
    p_asset: request.asset,
    p_profile: request.profile,
    p_expected_updated_at: request.expectedUpdatedAt ?? null,
  })
}
