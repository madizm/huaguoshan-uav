import { http } from './http'

export const DEFENSE_RING_CODES = ['sensing', 'tracking', 'countermeasure', 'hard_strike', 'core'] as const
export type DefenseRingCode = (typeof DEFENSE_RING_CODES)[number]

export interface DefenseRing {
  id: number
  code: DefenseRingCode
  name: string
  ring_level: number
  radius_m: number
  priority: number
  version: number
  center: { type: 'Point'; coordinates: [number, number] }
}

export interface ProtectedObject {
  id: number
  name: string
  longitude: number
  latitude: number
  enabled: boolean
  version: number
  rings: DefenseRing[]
}

export interface RiskFactor {
  score: number
  condition_code: string
  threshold_value: number | null
  unit: string | null
  exclusive_group: string | null
  enabled: boolean
}

export interface RiskRuleConfig {
  version: number
  factors: Record<string, RiskFactor>
  parameters: Record<string, { value: number; unit: string | null }>
}

export interface DefenseRingConfig {
  objects: ProtectedObject[]
  rules: RiskRuleConfig | null
}

export interface SaveDefenseRingPayload {
  id: number | null
  expected_version: number
  name: string
  longitude: number
  latitude: number
  enabled: boolean
  radii_m: number[]
  priorities: number[]
}

export function getDefenseRingConfig() {
  return http.post<DefenseRingConfig>('/rpc/get_defense_ring_config', {})
}

export function saveDefenseRingConfig(config: SaveDefenseRingPayload) {
  return http.post<{ id: number; version: number }>('/rpc/save_defense_ring_config', { p_config: config })
}

export function saveDefenseRiskScores(expectedVersion: number, scores: Record<string, number>) {
  return http.post<{ version: number }>('/rpc/save_defense_risk_scores', {
    p_expected_version: expectedVersion,
    p_scores: scores,
  })
}
