import { http, requestPaged, type PagedResult } from './http'

export interface EmergencyResourceRow {
  category_code: string
  resource_id: number
  source_code: string
  name: string
  managing_unit_name: string | null
  contact_phone: string | null
  availability_status: string
  is_simulated: boolean
  longitude: number
  latitude: number
  details: Record<string, unknown>
  updated_at: string
}

export const emergencyResourceEndpoints: Record<string, string> = {
  medical_resource: '/emergency_medical_resources', expert_force: '/emergency_experts',
  shelter: '/emergency_shelters', material_warehouse: '/emergency_material_warehouses',
  water_point: '/emergency_water_points', landing_site: '/emergency_landing_sites',
  police_station: '/emergency_police_stations',
}

export function listEmergencyResources(params: { category?: string; keyword?: string; limit: number; offset: number }): Promise<PagedResult<EmergencyResourceRow>> {
  const query: Record<string, string> = { order: 'updated_at.desc' }
  if (params.category) query.category_code = `eq.${params.category}`
  if (params.keyword) query.or = `(source_code.ilike.*${params.keyword}*,name.ilike.*${params.keyword}*)`
  return requestPaged('/emergency_resource_admin_details', { query, limit: params.limit, offset: params.offset })
}

export function createEmergencyResource(category: string, payload: Record<string, unknown>): Promise<unknown> {
  return http.post(emergencyResourceEndpoints[category], payload, ['return=representation'])
}

export function updateEmergencyResource(category: string, id: number, payload: Record<string, unknown>): Promise<void> {
  return http.patch(emergencyResourceEndpoints[category], { id: `eq.${id}` }, payload)
}

export function listHistoricalRescueForces(): Promise<Record<string, unknown>[]> {
  return http.get('/emergency_rescue_forces_history', { order: 'updated_at.desc' })
}

export function deleteEmergencyResource(category: string, id: number): Promise<void> {
  return http.delete(emergencyResourceEndpoints[category], { id: `eq.${id}` })
}
