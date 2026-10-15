<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import { Refresh } from '@element-plus/icons-vue'
import { ElMessage } from 'element-plus'
import type { TagProps } from 'element-plus'
import {
  getPredictionAccuracyStats,
  getPredictionEngineStatus,
  getPredictionEvaluationDetail,
  listTrajectoryPredictions,
  type PredictionAccuracyStats,
  type PredictionEngineHealth,
  type PredictionEngineStatus,
  type PredictionEvaluation,
  type TrajectoryPredictionRow,
} from '../api/prediction'

const status = ref<PredictionEngineStatus | null>(null)
const predictions = ref<TrajectoryPredictionRow[]>([])
const accuracy = ref<PredictionAccuracyStats | null>(null)
const evaluations = ref<Record<number, PredictionEvaluation[]>>({})
const loading = ref(false)
const loadFailed = ref(false)
let refreshTimer: number | undefined

const stateMeta = computed(() => !status.value
  ? { label: loadFailed.value ? '状态获取失败' : '状态加载中', type: 'info' as const }
  : ({
  healthy: { label: '运行正常', type: 'success' },
  degraded: { label: '运行降级', type: 'warning' },
  offline: { label: '心跳离线', type: 'danger' },
}[status.value.state] as { label: string; type: TagProps['type'] }))

const insufficientRate = computed(() => {
  const throughput = status.value?.throughput
  const total = (throughput?.writtenLastHour ?? 0) + (throughput?.insufficientLastHour ?? 0)
  if (!total) return 0
  return (throughput?.insufficientLastHour ?? 0) / total
})

const MODEL_LABEL: Record<string, string> = { cv: '恒定速度', ct: '恒定转向', hover: '悬停' }
const SUBJECT_LABEL: Record<string, string> = { airspace_target: '空域目标', aircraft_asset: '无人机资产' }
const REASON_LABEL: Record<string, string> = {
  not_enough_points: '窗口点数不足',
  window_span_too_short: '窗口时长不足',
  unrealistic_speed: '速度异常',
}

function modelLabel(code?: string | null): string {
  return (code && MODEL_LABEL[code]) || code || '--'
}

function subjectLabel(kind?: string | null): string {
  return (kind && SUBJECT_LABEL[kind]) || kind || '--'
}

function qualityLabel(row: TrajectoryPredictionRow): string {
  if (row.quality === 'ok') return '有效'
  return `数据不足（${(row.reason && REASON_LABEL[row.reason]) || row.reason || '未知'}）`
}

function formatTime(value?: string | null): string {
  return value ? new Date(value).toLocaleString('zh-CN', { hour12: false }) : '--'
}

function formatDuration(seconds?: number | null): string {
  if (seconds == null) return '--'
  if (seconds < 60) return `${seconds} 秒`
  if (seconds < 3600) return `${Math.floor(seconds / 60)} 分 ${seconds % 60} 秒`
  return `${Math.floor(seconds / 3600)} 小时 ${Math.floor(seconds % 3600 / 60)} 分`
}

function formatCount(value?: number | null): string {
  return Number(value ?? 0).toLocaleString('zh-CN')
}

async function loadEvaluations(row: TrajectoryPredictionRow) {
  if (row.quality !== 'ok' || evaluations.value[row.id]) return
  try {
    const detail = await getPredictionEvaluationDetail(row.id)
    evaluations.value = { ...evaluations.value, [row.id]: detail.evaluations }
  } catch (error) {
    ElMessage.error((error as Error).message)
  }
}

async function load(showSuccess = false) {
  loading.value = true
  try {
    const [nextStatus, list, nextAccuracy] = await Promise.all([
      getPredictionEngineStatus(),
      listTrajectoryPredictions(),
      getPredictionAccuracyStats(),
    ])
    status.value = nextStatus
    loadFailed.value = false
    predictions.value = list.predictions
    accuracy.value = nextAccuracy
    if (showSuccess) ElMessage.success('轨迹预测引擎状态已刷新')
  } catch (error) {
    status.value = null
    loadFailed.value = true
    ElMessage.error((error as Error).message)
  } finally {
    loading.value = false
  }
}

function formatMeters(value?: number | null): string {
  return value == null ? '--' : `${value} m`
}

function formatRate(value?: number | null): string {
  return value == null ? '--' : `${(value * 100).toFixed(1)}%`
}

onMounted(() => {
  load()
  refreshTimer = window.setInterval(() => load(), 10_000)
})

onBeforeUnmount(() => {
  if (refreshTimer) window.clearInterval(refreshTimer)
})
</script>

<template>
  <section class="prediction-page">
    <div class="page-toolbar">
      <div class="health-title">
        <el-tag :type="stateMeta.type" effect="dark" round>{{ stateMeta.label }}</el-tag>
        <span>业务状态每 10 秒自动刷新</span>
      </div>
      <div class="page-toolbar-spacer" />
      <el-button :icon="Refresh" :loading="loading" @click="load(true)">刷新状态</el-button>
    </div>

    <el-alert
      v-if="status && status.state !== 'healthy'"
      :title="status?.state === 'offline' ? '轨迹预测 worker 心跳已中断' : '轨迹预测 worker 运行降级'"
      :description="status?.worker.lastErrorMessage || '请检查 prediction worker 进程与数据库连接。'"
      :type="status?.state === 'offline' ? 'error' : 'warning'"
      show-icon
      :closable="false"
    />

    <div class="metric-grid" aria-label="轨迹预测引擎核心指标">
      <article :data-tone="status?.state === 'healthy' ? 'success' : 'danger'">
        <span>心跳延迟</span>
        <strong>{{ formatDuration(status?.worker.heartbeatAgeSeconds) }}</strong>
        <small>{{ formatTime(status?.worker.heartbeatAt) }}</small>
      </article>
      <article>
        <span>活跃预测对象</span>
        <strong>{{ formatCount(status?.throughput.activeSubjects) }}</strong>
        <small>最近 30 秒有有效预测</small>
      </article>
      <article>
        <span>最近一分钟写入</span>
        <strong>{{ formatCount(status?.throughput.writtenLastMinute) }}</strong>
        <small>条有效预测</small>
      </article>
      <article :data-tone="insufficientRate > 0.5 ? 'warning' : 'success'">
        <span>一小时数据不足占比</span>
        <strong>{{ (insufficientRate * 100).toFixed(1) }}%</strong>
        <small>{{ formatCount(status?.throughput.insufficientLastHour) }} 条数据不足</small>
      </article>
    </div>

    <div class="detail-grid">
      <el-card shadow="never" header="Worker 运行状态">
        <el-descriptions :column="2" border size="small">
          <el-descriptions-item label="Worker">{{ status?.worker.name ?? '--' }}</el-descriptions-item>
          <el-descriptions-item label="运行状态">{{ status?.worker.runtimeState ?? '--' }}</el-descriptions-item>
          <el-descriptions-item label="实例" :span="2">{{ status?.worker.instanceId ?? '--' }}</el-descriptions-item>
          <el-descriptions-item label="引擎版本">{{ status?.worker.engineVersion ?? '--' }}</el-descriptions-item>
          <el-descriptions-item label="启动时间">{{ formatTime(status?.worker.startedAt) }}</el-descriptions-item>
          <el-descriptions-item label="最后成功">{{ formatTime(status?.worker.lastSuccessAt) }}</el-descriptions-item>
          <el-descriptions-item label="批次耗时">{{ status?.worker.lastBatchDurationMs == null ? '--' : `${status.worker.lastBatchDurationMs} ms` }}</el-descriptions-item>
          <el-descriptions-item label="最近批量">{{ formatCount(status?.worker.lastBatchSize) }}</el-descriptions-item>
          <el-descriptions-item label="累计写入">{{ formatCount(status?.worker.processedTotal) }}</el-descriptions-item>
          <el-descriptions-item label="最后错误" :span="2">
            <span v-if="status?.worker.lastErrorCode" class="error-text">{{ status.worker.lastErrorCode }} · {{ status.worker.lastErrorMessage }}</span>
            <span v-else>--</span>
          </el-descriptions-item>
        </el-descriptions>
      </el-card>

      <el-card shadow="never" header="预测质量（最近一小时）">
        <el-descriptions :column="2" border size="small">
          <el-descriptions-item label="恒定速度">{{ formatCount(status?.models.cv) }}</el-descriptions-item>
          <el-descriptions-item label="恒定转向">{{ formatCount(status?.models.ct) }}</el-descriptions-item>
          <el-descriptions-item label="悬停">{{ formatCount(status?.models.hover) }}</el-descriptions-item>
          <el-descriptions-item label="有效预测">{{ formatCount(status?.throughput.writtenLastHour) }}</el-descriptions-item>
          <el-descriptions-item label="平均观测至预测时差" :span="2">
            {{ status?.throughput.averageLatencySeconds == null ? '--' : `${status.throughput.averageLatencySeconds} 秒` }}
          </el-descriptions-item>
          <el-descriptions-item label="时差口径" :span="2">worker 本机预测时间减位置观测时间，含观测陈旧与处理等待，不是算法耗时；需各主机校时。</el-descriptions-item>
          <el-descriptions-item label="状态生成时间" :span="2">{{ formatTime(status?.generatedAt) }}</el-descriptions-item>
        </el-descriptions>
      </el-card>
    </div>

    <el-card shadow="never" class="prediction-card">
      <template #header>
        <div class="card-header">
          <strong>准确度评估（最近 {{ accuracy?.hours ?? 24 }} 小时）</strong>
          <span>预测越过检查点后与实际观测比对</span>
        </div>
      </template>
      <div class="metric-grid accuracy-grid" aria-label="预测准确度汇总">
        <article>
          <span>已评估预测</span>
          <strong>{{ formatCount(accuracy?.summary?.evaluatedPredictions) }}</strong>
          <small>{{ formatCount(accuracy?.summary?.samples) }} 个检查点样本</small>
        </article>
        <article>
          <span>平均误差</span>
          <strong>{{ formatMeters(accuracy?.summary?.meanErrorM) }}</strong>
          <small>中位数 {{ formatMeters(accuracy?.summary?.medianErrorM) }}</small>
        </article>
        <article :data-tone="(accuracy?.summary?.withinUncertaintyRate ?? 1) < 0.8 ? 'warning' : 'success'">
          <span>不确定度覆盖率</span>
          <strong>{{ formatRate(accuracy?.summary?.withinUncertaintyRate) }}</strong>
          <small>误差落在预测不确定半径内的比例</small>
        </article>
      </div>
      <el-table :data="accuracy?.buckets ?? []" stripe empty-text="暂无评估样本：预测需先越过 10/30/60/120 秒检查点">
        <el-table-column label="对象" width="120">
          <template #default="{ row }">{{ subjectLabel(row.subjectKind) }}</template>
        </el-table-column>
        <el-table-column label="模型" width="110">
          <template #default="{ row }">{{ modelLabel(row.modelCode) }}</template>
        </el-table-column>
        <el-table-column prop="etaSeconds" label="检查点" width="90">
          <template #default="{ row }">{{ row.etaSeconds }} 秒</template>
        </el-table-column>
        <el-table-column prop="samples" label="样本数" width="90" />
        <el-table-column label="平均误差" width="110">
          <template #default="{ row }">{{ formatMeters(row.meanErrorM) }}</template>
        </el-table-column>
        <el-table-column label="中位误差" width="110">
          <template #default="{ row }">{{ formatMeters(row.medianErrorM) }}</template>
        </el-table-column>
        <el-table-column label="P90 误差" width="110">
          <template #default="{ row }">{{ formatMeters(row.p90ErrorM) }}</template>
        </el-table-column>
        <el-table-column label="覆盖率" min-width="100">
          <template #default="{ row }">
            <el-tag :type="(row.withinUncertaintyRate ?? 1) < 0.8 ? 'warning' : 'success'" size="small">
              {{ formatRate(row.withinUncertaintyRate) }}
            </el-tag>
          </template>
        </el-table-column>
      </el-table>
    </el-card>

    <el-card shadow="never" class="prediction-card">
      <template #header>
        <div class="card-header">
          <strong>最近预测记录</strong>
          <span>{{ predictions.length }} 条</span>
        </div>
      </template>
      <el-table v-loading="loading" :data="predictions" stripe empty-text="暂无预测记录" row-key="id" @expand-change="loadEvaluations">
        <el-table-column type="expand">
          <template #default="{ row }">
            <div class="evaluation-detail" v-if="row.quality === 'ok'">
              <template v-if="evaluations[row.id]?.length">
                <el-table :data="evaluations[row.id]" size="small">
                  <el-table-column label="检查点" width="90">
                    <template #default="{ row: ev }">{{ ev.etaSeconds }} 秒</template>
                  </el-table-column>
                  <el-table-column label="误差" width="110">
                    <template #default="{ row: ev }">{{ ev.errorM }} m</template>
                  </el-table-column>
                  <el-table-column label="不确定半径" width="110">
                    <template #default="{ row: ev }">{{ ev.uncertaintyM }} m</template>
                  </el-table-column>
                  <el-table-column label="是否在半径内" width="120">
                    <template #default="{ row: ev }">
                      <el-tag :type="ev.withinUncertainty ? 'success' : 'danger'" size="small">
                        {{ ev.withinUncertainty ? '是' : '否' }}
                      </el-tag>
                    </template>
                  </el-table-column>
                  <el-table-column label="实际观测时刻" min-width="160">
                    <template #default="{ row: ev }">{{ formatTime(ev.actualObservedAt) }}</template>
                  </el-table-column>
                  <el-table-column label="时刻偏差" width="100">
                    <template #default="{ row: ev }">{{ ev.timeOffsetS }} 秒</template>
                  </el-table-column>
                </el-table>
              </template>
              <span v-else class="empty-value">尚未越过检查点或该时段无实际观测，暂无评估数据</span>
            </div>
            <span v-else class="empty-value">数据不足的预测不参与准确度评估</span>
          </template>
        </el-table-column>
        <el-table-column label="预测时间" min-width="160">
          <template #default="{ row }">{{ formatTime(row.predicted_at) }}</template>
        </el-table-column>
        <el-table-column label="对象" min-width="130">
          <template #default="{ row }">{{ subjectLabel(row.subject_kind) }} #{{ row.subject_id }}</template>
        </el-table-column>
        <el-table-column label="模型" width="100">
          <template #default="{ row }">{{ modelLabel(row.model_code) }}</template>
        </el-table-column>
        <el-table-column label="速度" width="100">
          <template #default="{ row }">{{ row.speed_mps == null ? '--' : `${row.speed_mps} m/s` }}</template>
        </el-table-column>
        <el-table-column label="航向" width="90">
          <template #default="{ row }">{{ row.heading_deg == null ? '--' : `${row.heading_deg}°` }}</template>
        </el-table-column>
        <el-table-column label="转向率" width="100">
          <template #default="{ row }">{{ row.turn_rate_dps == null ? '--' : `${row.turn_rate_dps}°/s` }}</template>
        </el-table-column>
        <el-table-column prop="point_count" label="预测点" width="80" />
        <el-table-column prop="window_point_count" label="窗口点" width="80" />
        <el-table-column label="拟合残差" width="100">
          <template #default="{ row }">{{ row.fit_residual_m == null ? '--' : `${row.fit_residual_m} m` }}</template>
        </el-table-column>
        <el-table-column label="质量" min-width="150">
          <template #default="{ row }">
            <el-tag :type="row.quality === 'ok' ? 'success' : 'info'" size="small">{{ qualityLabel(row) }}</el-tag>
          </template>
        </el-table-column>
      </el-table>
    </el-card>
  </section>
</template>

<style scoped>
.prediction-page { display: grid; gap: 16px; }
.page-toolbar { display: flex; align-items: center; gap: 12px; }
.page-toolbar-spacer { flex: 1; }
.health-title { display: flex; align-items: center; gap: 10px; color: #78817c; font-size: 13px; }
.metric-grid { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 14px; }
.metric-grid article { display: grid; gap: 6px; min-width: 0; padding: 18px; border: 1px solid #e1e7e3; border-radius: 8px; background: #fff; box-shadow: 0 4px 16px rgba(32, 37, 34, 0.04); }
.metric-grid article::before { width: 28px; height: 3px; border-radius: 2px; background: #809089; content: ''; }
.metric-grid article[data-tone="success"]::before { background: #28a36a; }
.metric-grid article[data-tone="warning"]::before { background: #e6a23c; }
.metric-grid article[data-tone="danger"]::before { background: #f56c6c; }
.metric-grid span, .metric-grid small { color: #7a8580; font-size: 12px; }
.metric-grid strong { color: #202522; font-size: 26px; line-height: 1.15; }
.detail-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 16px; }
.error-text { color: #d84b4b; overflow-wrap: anywhere; }
.card-header { display: flex; align-items: center; justify-content: space-between; }
.card-header span { color: #84908a; font-size: 12px; }
.accuracy-grid { grid-template-columns: repeat(3, minmax(0, 1fr)); margin-bottom: 14px; }
.evaluation-detail { padding: 4px 12px 12px 48px; }
.empty-value { color: #9aa39e; font-size: 12px; }
@media (max-width: 1100px) {
  .metric-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .detail-grid { grid-template-columns: 1fr; }
}
@media (max-width: 640px) {
  .metric-grid { grid-template-columns: 1fr; }
  .health-title span { display: none; }
}
</style>
