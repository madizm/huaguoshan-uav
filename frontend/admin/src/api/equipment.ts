import { http, requestPaged, type PagedResult } from './http'

export interface AssetCategory {
  code: string
  name: string
  category_group: string
  description: string | null
  enabled: boolean
  sort_order: number
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
  elevation_amsl_m: number | null
  manufacturer: string | null
  model: string | null
  serial_no: string | null
  created_at: string
  updated_at: string
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

export interface MicrowaveRadarProfile {
  asset_id: number
  model_code: string | null
  face_count: number
  install_azimuth_deg: number | null
  install_tilt_deg: number | null
  control_host: string | null
  control_port: number | null
  protocol: string | null
  detection_mode: string | null
  multi_target_supported: boolean
  recommendation_notes: string | null
}

export interface AssetListParams {
  categoryCode?: string
  keyword?: string
  limit: number
  offset: number
}

export function listCategories(): Promise<AssetCategory[]> {
  return http.get('/equipment_asset_categories', { order: 'sort_order.asc' })
}

export function listRadarModels(): Promise<RadarModel[]> {
  return http.get('/equipment_radar_models', { order: 'model_code.asc' })
}

export function listAssets(params: AssetListParams): Promise<PagedResult<EquipmentAsset>> {
  const query: Record<string, string> = {
    select: 'id,asset_code,category_code,name,model,managing_unit_name,deployment_mode,lifecycle_status,updated_at',
    order: 'id.desc',
  }
  if (params.categoryCode) query.category_code = `eq.${params.categoryCode}`
  if (params.keyword) query.or = `(asset_code.ilike.*${params.keyword}*,name.ilike.*${params.keyword}*)`
  return requestPaged('/equipment_assets', { query, limit: params.limit, offset: params.offset })
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

export function createAsset(payload: AssetPayload): Promise<EquipmentAsset[]> {
  return http.post('/equipment_assets', payload, ['return=representation'])
}

export function updateAsset(id: number, payload: Partial<AssetPayload> & { lifecycle_status?: string }): Promise<void> {
  return http.patch('/equipment_assets', { id: `eq.${id}` }, payload)
}

export function getRadarProfile(assetId: number): Promise<MicrowaveRadarProfile[]> {
  return http.get('/equipment_microwave_radar_profiles', { asset_id: `eq.${assetId}` })
}

// upsert：按主键 asset_id 冲突合并。
export function upsertRadarProfile(profile: Partial<MicrowaveRadarProfile> & { asset_id: number }): Promise<void> {
  return http.post('/equipment_microwave_radar_profiles', profile, ['resolution=merge-duplicates'])
}
