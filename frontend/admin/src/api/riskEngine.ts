import { http } from './http'

export type RiskEngineHealth = 'healthy' | 'degraded' | 'offline'

export interface RiskWorkerStatus {
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
  lastObservationId: number
  cursorUpdatedAt?: string
}

export interface RiskEngineStatus {
  state: RiskEngineHealth
  generatedAt: string
  worker: RiskWorkerStatus
  backlog: {
    pendingCount: number
    pendingCountCapped: boolean
    cursorPendingCount: number
    repairPendingCount: number
    oldestPendingAt: string | null
    oldestPendingAgeSeconds: number
  }
  throughput: {
    assessedLastMinute: number
    assessedLastHour: number
    failedLastHour: number
    failureRateLastHour: number
    averageLatencySeconds: number
  }
  configuration: {
    ruleVersion: number | null
    protectedObjectCount: number
    defenseRingCount: number
  }
}

export interface RiskEngineFailure {
  assessmentId: number
  trackId: number
  observationId: number
  observedAt: string
  assessedAt: string
  errorCode: string | null
  ruleVersion: number | null
}

export interface RiskEngineFailures {
  startAt: string
  endAtExclusive: string
  limit: number
  failures: RiskEngineFailure[]
}

export function getRiskEngineStatus(): Promise<RiskEngineStatus> {
  return http.post('/rpc/get_risk_engine_status', {})
}

export function listRiskEngineFailures(limit = 50): Promise<RiskEngineFailures> {
  const end = new Date()
  const start = new Date(end.getTime() - 24 * 60 * 60 * 1000)
  return http.post('/rpc/list_risk_engine_failures', {
    p_start_at: start.toISOString(),
    p_end_at: end.toISOString(),
    p_limit: limit,
  })
}
