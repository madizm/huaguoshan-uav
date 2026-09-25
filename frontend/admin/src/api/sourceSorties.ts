import { http } from './http'

export interface SourceSortieSummary {
  sortieCount: number
  activeCount: number
  spatialCount: number
  highRiskCount: number
  coreRingCount: number
  averageDurationSeconds: number
  observationCount: number
}

export interface SourceSortieStatistics {
  startAt: string
  endAtExclusive: string
  summary: SourceSortieSummary
  riskDistribution: Record<'critical' | 'high' | 'medium' | 'low' | 'none' | 'unavailable', number>
  quality: {
    timestampSuspectCount: number
    singleTimestampCount: number
    nonSpatialCount: number
    lifecycleOverlapCount: number
  }
}

export interface SourceSortieSeriesPoint {
  bucketAt: string
  sortieCount: number
  highRiskCount: number
  spatialCount: number
  timestampSuspectCount: number
}

export interface SourceSortieSeries {
  startAt: string
  endAtExclusive: string
  bucket: 'hour' | 'day'
  points: SourceSortieSeriesPoint[]
}

export interface SourceSortie {
  sortieId: number
  trackId: number
  trackCode: string
  sourceId: number
  sourceName: string
  stationId: string
  sourceTargetId: string
  state: 'active' | 'lost' | 'closed'
  startedAt: string
  lastObservedAt: string
  endedAt?: string
  endReason?: string
  durationSeconds: number
  observationCount: number
  spatialObservationCount: number
  firstReceivedAt?: string
  maxObservationGapSeconds?: number
  maxReceiveDelaySeconds?: number
  detectionMethodCodes: string[]
  timestampSuspect: boolean
  singleTimestamp: boolean
  nonSpatial: boolean
  lifecycleOverlap: boolean
  maxRiskLevel?: 'none' | 'low' | 'medium' | 'high' | 'critical'
  maxRiskScore?: number
  deepestRingCode?: string
  riskAssessmentCount: number
  locationUnavailableCount: number
  outsideProtectedObjectsCount: number
}

export interface SourceSortieList {
  startAt: string
  endAtExclusive: string
  limit: number
  offset: number
  total: number
  sorties: SourceSortie[]
}

interface SortieFilters {
  startAt: string
  endAt: string
  riskLevels?: string[] | null
  qualityIssue?: string | null
}

function commonPayload(filters: SortieFilters) {
  return {
    p_start_at: filters.startAt,
    p_end_at: filters.endAt,
    p_source_ids: null,
    p_detection_method_codes: null,
    p_quality_issue: filters.qualityIssue || null,
  }
}

export function getSourceSortieStatistics(filters: SortieFilters): Promise<SourceSortieStatistics> {
  return http.post('/rpc/get_source_sortie_statistics', commonPayload(filters))
}

export function getSourceSortieSeries(
  filters: SortieFilters,
  bucket: 'hour' | 'day',
): Promise<SourceSortieSeries> {
  return http.post('/rpc/get_source_sortie_series', {
    ...commonPayload(filters),
    p_bucket: bucket,
  })
}

export function listSourceSorties(
  filters: SortieFilters,
  limit: number,
  offset: number,
): Promise<SourceSortieList> {
  return http.post('/rpc/list_source_sorties', {
    ...commonPayload(filters),
    p_risk_levels: filters.riskLevels?.length ? filters.riskLevels : null,
    p_limit: limit,
    p_offset: offset,
  })
}

// ---------------------------------------------------------------------------
// 来源目标机型架次统计
// ---------------------------------------------------------------------------
export interface SourceTargetModelRow {
  sourceTargetId: string
  sourceName: string
  observationSourceId: number
  model: string
  sortieCount: number
  totalDurationSeconds: number
  highRiskCount: number
  maxRiskLevel?: 'none' | 'low' | 'medium' | 'high' | 'critical'
  lastSortieAt: string
}

export interface SourceTargetModelSummary {
  startAt: string
  endAtExclusive: string
  limit: number
  offset: number
  totalGroups: number
  rows: SourceTargetModelRow[]
}

export interface SourceTargetModelSortie {
  sortieId: number
  trackId: number
  trackCode: string
  sourceId: number
  sourceName: string
  state: 'active' | 'lost' | 'closed'
  startedAt: string
  lastObservedAt: string
  endedAt?: string
  endReason?: string
  durationSeconds: number
  observationCount: number
  spatialObservationCount: number
  detectionMethodCodes: string[]
  maxRiskLevel?: 'none' | 'low' | 'medium' | 'high' | 'critical'
  maxRiskScore?: number
  deepestRingCode?: string
  riskAssessmentCount: number
}

export interface SourceTargetModelSortieList {
  startAt: string
  endAtExclusive: string
  sourceTargetId: string
  model: string
  limit: number
  offset: number
  total: number
  sorties: SourceTargetModelSortie[]
}

interface ModelSummaryFilters {
  startAt: string
  endAt: string
  sourceIds?: number[] | null
  riskLevels?: string[] | null
  models?: string[] | null
  detectionMethodCodes?: string[] | null
  sourceTargetIds?: string[] | null
}

export function getSourceTargetModelSummary(
  filters: ModelSummaryFilters,
  limit: number,
  offset: number,
): Promise<SourceTargetModelSummary> {
  return http.post('/rpc/get_source_target_model_summary', {
    p_start_at: filters.startAt,
    p_end_at: filters.endAt,
    p_source_ids: filters.sourceIds?.length ? filters.sourceIds : null,
    p_risk_levels: filters.riskLevels?.length ? filters.riskLevels : null,
    p_models: filters.models?.length ? filters.models : null,
    p_detection_method_codes: filters.detectionMethodCodes?.length ? filters.detectionMethodCodes : null,
    p_source_target_ids: filters.sourceTargetIds?.length ? filters.sourceTargetIds : null,
    p_limit: limit,
    p_offset: offset,
  })
}

export function listSourceTargetModelSorties(
  filters: ModelSummaryFilters,
  sourceTargetId: string,
  model: string,
  limit: number,
  offset: number,
): Promise<SourceTargetModelSortieList> {
  return http.post('/rpc/list_source_target_model_sorties', {
    p_start_at: filters.startAt,
    p_end_at: filters.endAt,
    p_source_target_id: sourceTargetId,
    p_model: model,
    p_source_ids: filters.sourceIds?.length ? filters.sourceIds : null,
    p_risk_levels: filters.riskLevels?.length ? filters.riskLevels : null,
    p_detection_method_codes: filters.detectionMethodCodes?.length ? filters.detectionMethodCodes : null,
    p_limit: limit,
    p_offset: offset,
  })
}
