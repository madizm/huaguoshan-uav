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
