import { http } from './http'

export type ConnectorState = 'connected' | 'disconnected' | 'degraded' | 'unknown' | null

export interface DetectionObservationSource {
  id: number
  source_system: string
  station_id: string
  box_code: string
  name: string
  coordinate_system: string
  enabled: boolean
  connector_state: ConnectorState
  last_message_at: string | null
  last_snapshot_at: string | null
  updated_at: string | null
  asset_id: number
  asset_code: string
  asset_name: string
  asset_lifecycle_status: string
  source_timezone: string
  lost_timeout_seconds: number
  last_connected_at: string | null
  last_disconnected_at: string | null
  last_error_code: string | null
  last_error_at: string | null
  details: Record<string, unknown> | null
}

export interface DetectionSourceUpdate {
  name: string
  assetId: number
  sourceTimezone: string
  lostTimeoutSeconds: number
  enabled: boolean
}

export function listDetectionSources(): Promise<DetectionObservationSource[]> {
  return http.get('/detection_observation_sources', {
    order: 'source_system.asc,station_id.asc',
  })
}

export function updateDetectionSource(
  sourceId: number,
  values: DetectionSourceUpdate,
): Promise<Pick<DetectionObservationSource, 'id' | 'name' | 'asset_id' | 'source_timezone' | 'lost_timeout_seconds' | 'enabled'>> {
  return http.post(`/rpc/update_detection_observation_source`, {
    p_source_id: sourceId,
    p_name: values.name,
    p_asset_id: values.assetId,
    p_source_timezone: values.sourceTimezone,
    p_lost_timeout_seconds: values.lostTimeoutSeconds,
    p_enabled: values.enabled,
  })
}

export type DetectionMethodLifecycle = 'active' | 'deprecated'

export interface DetectionMethod {
  code: string
  name: string
  description: string | null
  lifecycle_status: DetectionMethodLifecycle
  visible: boolean
  sort_order: number
  display_metadata: Record<string, unknown>
  observation_count: number
  created_at: string
  updated_at: string
}

export interface DetectionMethodMapping {
  id: number
  source_system: string
  vendor_code: string
  method_code: string
  method_name: string
  accept_ingest: boolean
  metadata: Record<string, unknown>
  created_at: string
  updated_at: string
}

export interface DetectionMethodMappingHistory {
  id: number
  mapping_id: number
  source_system: string
  vendor_code: string
  old_method_code: string | null
  new_method_code: string
  old_accept_ingest: boolean | null
  new_accept_ingest: boolean
  old_metadata: Record<string, unknown> | null
  new_metadata: Record<string, unknown>
  changed_at: string
  changed_by: string | null
}

export interface DetectionMethodInput {
  code: string
  name: string
  description: string | null
  visible: boolean
  sortOrder: number
  displayMetadata?: Record<string, unknown>
}

export function listDetectionMethods(): Promise<DetectionMethod[]> {
  return http.get('/detection_methods', { order: 'sort_order.asc,code.asc' })
}

export function createDetectionMethod(values: DetectionMethodInput): Promise<DetectionMethod> {
  return http.post('/rpc/create_detection_method', {
    p_code: values.code,
    p_name: values.name,
    p_description: values.description,
    p_visible: values.visible,
    p_sort_order: values.sortOrder,
    p_display_metadata: values.displayMetadata ?? {},
  })
}

export function updateDetectionMethod(
  code: string,
  changes: Partial<Omit<DetectionMethod, 'code' | 'observation_count' | 'created_at' | 'updated_at'>>,
): Promise<DetectionMethod> {
  return http.post('/rpc/update_detection_method', { p_code: code, p_changes: changes })
}

export function listDetectionMethodMappings(): Promise<DetectionMethodMapping[]> {
  return http.get('/detection_method_mappings', { order: 'source_system.asc,vendor_code.asc' })
}

export function listDetectionMethodMappingHistory(): Promise<DetectionMethodMappingHistory[]> {
  return http.get('/detection_method_mapping_history', {
    order: 'changed_at.desc,id.desc',
    limit: '100',
  })
}

export function upsertDetectionMethodMapping(values: {
  sourceSystem: string
  vendorCode: string
  methodCode: string
  acceptIngest: boolean
  metadata?: Record<string, unknown>
}): Promise<DetectionMethodMapping> {
  return http.post('/rpc/upsert_detection_method_mapping', {
    p_source_system: values.sourceSystem,
    p_vendor_code: values.vendorCode,
    p_method_code: values.methodCode,
    p_accept_ingest: values.acceptIngest,
    p_metadata: values.metadata ?? {},
  })
}
