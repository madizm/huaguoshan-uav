import { http } from './http'

export type PredictionEngineHealth = 'healthy' | 'degraded' | 'offline'

export interface PredictionWorkerStatus {
  name: string
  instanceId?: string
  runtimeState?: 'running' | 'idle' | 'degraded' | 'stopped'
  engineVersion?: string
  startedAt?: string
  heartbeatAt?: string
  heartbeatAgeSeconds?: number
  lastBatchStartedAt?: string
  lastBatchFinishedAt?: string
  lastSuccessAt?: string
  lastErrorAt?: string
  lastErrorCode?: string
  lastErrorMessage?: string
  lastBatchSize: number
  lastBatchDurationMs?: number
  processedTotal: number
  failedTotal: number
}

export interface PredictionEngineStatus {
  state: PredictionEngineHealth
  generatedAt: string
  worker: PredictionWorkerStatus
  throughput: {
    writtenLastMinute: number
    writtenLastHour: number
    insufficientLastHour: number
    activeSubjects: number
    averageLatencySeconds: number | null
  }
  models: Partial<Record<'cv' | 'ct' | 'hover', number>>
}

export interface TrajectoryPredictionRow {
  id: number
  subject_kind: 'airspace_target' | 'aircraft_asset'
  subject_id: number
  base_observed_at: string
  predicted_at: string
  model_code: 'cv' | 'ct' | 'hover'
  model_version: number
  quality: 'ok' | 'insufficient_data'
  reason: string | null
  horizon_seconds: number
  speed_mps: number | null
  heading_deg: number | null
  turn_rate_dps: number | null
  window_point_count: number
  fit_residual_m: number | null
  point_count: number
}

export function getPredictionEngineStatus(): Promise<PredictionEngineStatus> {
  return http.post('/rpc/get_prediction_engine_status', {})
}

export function listTrajectoryPredictions(limit = 50): Promise<{ generatedAt: string; predictions: TrajectoryPredictionRow[] }> {
  return http.post('/rpc/list_trajectory_predictions', { p_limit: limit })
}

export interface PredictionAccuracySummary {
  evaluatedPredictions: number | null
  samples: number | null
  meanErrorM: number | null
  medianErrorM: number | null
  withinUncertaintyRate: number | null
}

export interface PredictionAccuracyBucket {
  modelCode: 'cv' | 'ct' | 'hover'
  subjectKind: 'airspace_target' | 'aircraft_asset'
  etaSeconds: number
  samples: number
  meanErrorM: number | null
  medianErrorM: number | null
  p90ErrorM: number | null
  withinUncertaintyRate: number | null
}

export interface PredictionAccuracyStats {
  generated_at: string
  hours: number
  summary: PredictionAccuracySummary | null
  buckets: PredictionAccuracyBucket[]
}

export interface PredictionEvaluation {
  etaSeconds: number
  errorM: number
  uncertaintyM: number
  withinUncertainty: boolean
  actualObservedAt: string
  timeOffsetS: number
  evaluatedAt: string
}

export function getPredictionAccuracyStats(hours = 24): Promise<PredictionAccuracyStats> {
  return http.post('/rpc/get_prediction_accuracy_stats', { p_hours: hours })
}

export function getPredictionEvaluationDetail(
  predictionId: number,
): Promise<{ generated_at: string; prediction_id: number; evaluations: PredictionEvaluation[] }> {
  return http.post('/rpc/get_prediction_evaluation_detail', { p_prediction_id: predictionId })
}
