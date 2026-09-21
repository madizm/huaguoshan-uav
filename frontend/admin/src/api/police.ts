import { http, requestPaged, type PagedResult } from './http'

export type PoliceAvailabilityStatus = 'available' | 'on_duty' | 'dispatched' | 'leave' | 'unavailable'
export type PoliceTeamStatus = 'active' | 'standby' | 'dispatched' | 'inactive'
export type PoliceMemberRole = 'leader' | 'deputy_leader' | 'member'

export interface PoliceOfficer {
  id: number
  officer_no: string
  name: string
  contact_phone: string | null
  organization_name: string | null
  availability_status: PoliceAvailabilityStatus
  is_active: boolean
  is_simulated: boolean
  metadata: Record<string, unknown>
  created_at: string
  updated_at: string
}

export interface PoliceTeamDetails {
  team_id: number
  team_code: string
  team_name: string
  station_id: number | null
  station_source_code: string | null
  station_name: string | null
  team_status: PoliceTeamStatus
  description: string | null
  is_simulated: boolean
  leader_officer_id: number | null
  leader_officer_no: string | null
  leader_name: string | null
  active_member_count: number
  metadata: Record<string, unknown>
  created_at: string
  updated_at: string
}

export interface PoliceTeam {
  id: number
  team_code: string
  name: string
  station_id: number | null
  team_status: PoliceTeamStatus
  description: string | null
  is_simulated: boolean
  metadata: Record<string, unknown>
  created_at: string
  updated_at: string
}

export interface PoliceStationOption {
  id: number
  source_code: string
  name: string
  address: string | null
  county_name: string | null
}

export interface PoliceTeamMember {
  id: number
  team_id: number
  officer_id: number
  member_role: PoliceMemberRole
  joined_at: string
  left_at: string | null
  created_at: string
  updated_at: string
}

export interface PoliceRosterRow {
  membership_id: number
  team_id: number
  team_code: string
  team_name: string
  team_status: PoliceTeamStatus
  station_id: number | null
  station_source_code: string | null
  station_name: string | null
  officer_id: number
  officer_no: string
  officer_name: string
  contact_phone: string | null
  organization_name: string | null
  officer_availability_status: PoliceAvailabilityStatus
  member_role: PoliceMemberRole
  joined_at: string
}

export interface PoliceMembershipHistoryRow {
  membership_id: number
  team_id: number
  team_code: string
  team_name: string
  station_id: number | null
  station_name: string | null
  officer_id: number
  officer_no: string
  officer_name: string
  organization_name: string | null
  member_role: PoliceMemberRole
  joined_at: string
  left_at: string | null
  created_at: string
  updated_at: string
}

export function listPoliceOfficers(params: {
  keyword?: string
  status?: PoliceAvailabilityStatus
  simulation?: 'real' | 'simulated'
  active?: boolean
  limit: number
  offset: number
}): Promise<PagedResult<PoliceOfficer>> {
  const query: Record<string, string> = { order: 'updated_at.desc' }
  if (params.keyword) query.or = `(officer_no.ilike.*${params.keyword}*,name.ilike.*${params.keyword}*)`
  if (params.status) query.availability_status = `eq.${params.status}`
  if (params.simulation) query.is_simulated = `eq.${params.simulation === 'simulated'}`
  if (params.active !== undefined) query.is_active = `eq.${params.active}`
  return requestPaged('/emergency_police_officers', { query, limit: params.limit, offset: params.offset })
}

export function listActivePoliceOfficers(): Promise<PoliceOfficer[]> {
  return http.get('/emergency_police_officers', {
    is_active: 'eq.true',
    order: 'officer_no.asc',
    limit: '1000',
  })
}

export function createPoliceOfficer(payload: Partial<PoliceOfficer>): Promise<PoliceOfficer[]> {
  return http.post('/emergency_police_officers', payload, ['return=representation'])
}

export function updatePoliceOfficer(id: number, payload: Partial<PoliceOfficer>): Promise<void> {
  return http.patch('/emergency_police_officers', { id: `eq.${id}` }, payload)
}

export function listPoliceTeams(params: {
  keyword?: string
  stationId?: number
  status?: PoliceTeamStatus
  simulation?: 'real' | 'simulated'
  limit: number
  offset: number
}): Promise<PagedResult<PoliceTeamDetails>> {
  const query: Record<string, string> = { order: 'updated_at.desc' }
  if (params.keyword) query.or = `(team_code.ilike.*${params.keyword}*,team_name.ilike.*${params.keyword}*)`
  if (params.stationId) query.station_id = `eq.${params.stationId}`
  if (params.status) query.team_status = `eq.${params.status}`
  if (params.simulation) query.is_simulated = `eq.${params.simulation === 'simulated'}`
  return requestPaged('/emergency_police_team_details', { query, limit: params.limit, offset: params.offset })
}

export function createPoliceTeam(payload: {
  teamCode: string
  name: string
  leaderOfficerId: number
  stationId: number | null
  status: PoliceTeamStatus
  description: string | null
  isSimulated: boolean
}): Promise<PoliceTeam> {
  return http.post('/rpc/create_police_team', {
    p_team_code: payload.teamCode,
    p_name: payload.name,
    p_leader_officer_id: payload.leaderOfficerId,
    p_station_id: payload.stationId,
    p_team_status: payload.status,
    p_description: payload.description,
    p_is_simulated: payload.isSimulated,
    p_metadata: {},
  })
}

export function updatePoliceTeam(id: number, payload: Partial<PoliceTeam>): Promise<void> {
  return http.patch('/emergency_police_teams', { id: `eq.${id}` }, payload)
}

export function listPoliceStations(): Promise<PoliceStationOption[]> {
  return http.get('/emergency_police_stations', {
    select: 'id,source_code,name,address,county_name',
    order: 'name.asc',
    limit: '1000',
  })
}

export function listPoliceTeamRoster(teamId: number): Promise<PoliceRosterRow[]> {
  return http.get('/emergency_police_team_roster', {
    team_id: `eq.${teamId}`,
    order: 'member_role.asc,officer_no.asc',
  })
}

export function listPoliceTeamMemberHistory(teamId: number): Promise<PoliceMembershipHistoryRow[]> {
  return http.get('/emergency_police_team_member_history', {
    team_id: `eq.${teamId}`,
    order: 'joined_at.desc',
  })
}

export function addPoliceTeamMember(
  teamId: number,
  officerId: number,
  role: Exclude<PoliceMemberRole, 'leader'>,
): Promise<PoliceTeamMember[]> {
  return http.post('/emergency_police_team_members', {
    team_id: teamId,
    officer_id: officerId,
    member_role: role,
  }, ['return=representation'])
}

export function updatePoliceTeamMemberRole(
  membershipId: number,
  role: Exclude<PoliceMemberRole, 'leader'>,
): Promise<void> {
  return http.patch('/emergency_police_team_members', { id: `eq.${membershipId}` }, { member_role: role })
}

export function assignPoliceTeamLeader(teamId: number, officerId: number): Promise<PoliceTeamMember> {
  return http.post('/rpc/assign_police_team_leader', {
    p_team_id: teamId,
    p_officer_id: officerId,
  })
}

export function removePoliceTeamMember(membershipId: number): Promise<PoliceTeamMember> {
  return http.post('/rpc/remove_police_team_member', { p_membership_id: membershipId })
}
