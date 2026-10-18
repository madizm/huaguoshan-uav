import { http } from './http'

export type AmplifierMode = 'omnidirectional_frequency' | 'target_coordinate'
export type AmplifierActualState = 'on' | 'off' | 'unknown'

export interface AmplifierStateCurrent {
  asset_id: number
  asset_code: string
  asset_name: string
  actual_state: AmplifierActualState
  active_frequencies_mhz: number[]
  trigger_source: string
  source_target_id: string | null
  vendor_duration_seconds: number | null
  observed_at: string
  received_at: string
  telemetry_stale: boolean
  active_operation_id: string | null
  operation_state: string | null
  correlation_quality: 'time_window' | 'unmatched' | null
  updated_at: string
}

export interface AmplifierOperation {
  id: string
  asset_id: number
  mode: AmplifierMode
  state: string
  terminal_at: string | null
  requested_frequencies_mhz: number[]
  requested_duration_seconds: number
  reason: string
  target_longitude: number | null
  target_latitude: number | null
  target_coordinate_system: 'WGS84' | null
  target_observed_at: string | null
  target_track_id: number | null
  requested_by_username: string | null
  requested_at: string
  start_dispatched_at: string | null
  dispatched_duration_seconds: number | null
  expected_expiry_at: string | null
  hard_deadline_at: string
  confirmed_on_at: string | null
  confirmed_off_at: string | null
  failure_code: string | null
}

export interface StartAmplifierRequest {
  assetId: number
  mode: AmplifierMode
  frequenciesMhz: number[]
  durationSeconds: number
  reason: string
  idempotencyKey: string
  target?: {
    longitude: number
    latitude: number
    coordinateSystem: 'WGS84'
    observedAt?: string | null
    trackId?: number | null
  }
}

export interface AmplifierCommandResult {
  operationId?: string
  commandId?: string
  assetId: number
  state: string
  requestedAt?: string
  hardDeadlineAt?: string
  strikeInterruptSupported?: boolean
}

export function listAmplifierState(assetId: number): Promise<AmplifierStateCurrent[]> {
  return http.get('/amplifier_state_current', { asset_id: `eq.${assetId}` })
}

export function listAmplifierOperations(assetId: number, limit = 20): Promise<AmplifierOperation[]> {
  return http.get('/amplifier_operations', {
    asset_id: `eq.${assetId}`,
    order: 'requested_at.desc',
    limit: String(limit),
  })
}

export function startAmplifier(request: StartAmplifierRequest): Promise<AmplifierCommandResult> {
  return http.post('/rpc/start_amplifier_operation', { p_request: request })
}

export function stopAmplifier(
  assetId: number,
  operationId: string,
  reason: string,
  idempotencyKey: string,
): Promise<AmplifierCommandResult> {
  return http.post('/rpc/stop_amplifier_operation', {
    p_asset_id: assetId,
    p_operation_id: operationId,
    p_reason: reason,
    p_idempotency_key: idempotencyKey,
  })
}

export function emergencyStopAmplifier(
  assetId: number,
  reason: string,
  idempotencyKey: string,
): Promise<AmplifierCommandResult> {
  return http.post('/rpc/emergency_stop_amplifier', {
    p_asset_id: assetId,
    p_reason: reason,
    p_idempotency_key: idempotencyKey,
  })
}
