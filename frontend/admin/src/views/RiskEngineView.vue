<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import { Refresh } from '@element-plus/icons-vue'
import { ElMessage } from 'element-plus'
import type { TagProps } from 'element-plus'
import {
  getRiskEngineStatus,
  listRiskEngineFailures,
  type RiskEngineFailure,
  type RiskEngineHealth,
  type RiskEngineStatus,
} from '../api/riskEngine'

const status = ref<RiskEngineStatus | null>(null)
const failures = ref<RiskEngineFailure[]>([])
const loading = ref(false)
let refreshTimer: number | undefined

const stateMeta = computed(() => ({
  healthy: { label: '运行正常', type: 'success' },
  degraded: { label: '运行降级', type: 'warning' },
  offline: { label: '心跳离线', type: 'danger' },
}[status.value?.state ?? 'offline'] as { label: string; type: TagProps['type'] }))

const backlogTone = computed(() => {
  const age = status.value?.backlog.oldestPendingAgeSeconds ?? 0
  if (age > 120) return 'danger'
  if (age > 30) return 'warning'
  return 'success'
})

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

function formatRate(value?: number | null): string {
  return `${(Number(value ?? 0) * 100).toFixed(2)}%`
}

async function load(showSuccess = false) {
  loading.value = true
  try {
    const [nextStatus, failureResult] = await Promise.all([
      getRiskEngineStatus(),
      listRiskEngineFailures(),
    ])
    status.value = nextStatus
    failures.value = failureResult.failures
    if (showSuccess) ElMessage.success('风险评估引擎状态已刷新')
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    loading.value = false
  }
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
  <section class="risk-engine-page">
    <div class="page-toolbar">
      <div class="health-title">
        <el-tag :type="stateMeta.type" effect="dark" round>{{ stateMeta.label }}</el-tag>
        <span>业务状态每 10 秒自动刷新</span>
      </div>
      <div class="page-toolbar-spacer" />
      <el-button :icon="Refresh" :loading="loading" @click="load(true)">刷新状态</el-button>
    </div>

    <el-alert
      v-if="status?.state !== 'healthy'"
      :title="status?.state === 'offline' ? '风险评估 worker 心跳已中断' : '风险评估处理存在积压或最近批次失败'"
      :description="status?.worker.lastErrorMessage || '请检查积压时长、最近错误及 systemd 服务日志。'"
      :type="status?.state === 'offline' ? 'error' : 'warning'"
      show-icon
      :closable="false"
    />

    <div class="metric-grid" aria-label="风险评估引擎核心指标">
      <article :data-tone="status?.state === 'healthy' ? 'success' : 'danger'">
        <span>心跳延迟</span>
        <strong>{{ formatDuration(status?.worker.heartbeatAgeSeconds) }}</strong>
        <small>{{ formatTime(status?.worker.heartbeatAt) }}</small>
      </article>
      <article :data-tone="backlogTone">
        <span>待处理观测</span>
        <strong>{{ status?.backlog.pendingCountCapped ? '≥ ' : '' }}{{ formatCount(status?.backlog.pendingCount) }}</strong>
        <small>最老积压 {{ formatDuration(status?.backlog.oldestPendingAgeSeconds) }}</small>
      </article>
      <article>
        <span>最近一分钟</span>
        <strong>{{ formatCount(status?.throughput.assessedLastMinute) }}</strong>
        <small>条评估完成</small>
      </article>
      <article :data-tone="status?.throughput.failedLastHour ? 'warning' : 'success'">
        <span>一小时失败率</span>
        <strong>{{ formatRate(status?.throughput.failureRateLastHour) }}</strong>
        <small>{{ formatCount(status?.throughput.failedLastHour) }} 条失败</small>
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
          <el-descriptions-item label="累计处理">{{ formatCount(status?.worker.processedTotal) }}</el-descriptions-item>
          <el-descriptions-item label="消费游标">{{ formatCount(status?.worker.lastObservationId) }}</el-descriptions-item>
          <el-descriptions-item label="最后错误" :span="2">
            <span v-if="status?.worker.lastErrorCode" class="error-text">{{ status.worker.lastErrorCode }} · {{ status.worker.lastErrorMessage }}</span>
            <span v-else>--</span>
          </el-descriptions-item>
        </el-descriptions>
      </el-card>

      <el-card shadow="never" header="积压与配置">
        <el-descriptions :column="2" border size="small">
          <el-descriptions-item label="游标后积压">{{ formatCount(status?.backlog.cursorPendingCount) }}</el-descriptions-item>
          <el-descriptions-item label="遗漏修复">{{ formatCount(status?.backlog.repairPendingCount) }}</el-descriptions-item>
          <el-descriptions-item label="最老待处理" :span="2">{{ formatTime(status?.backlog.oldestPendingAt) }}</el-descriptions-item>
          <el-descriptions-item label="一小时处理">{{ formatCount(status?.throughput.assessedLastHour) }}</el-descriptions-item>
          <el-descriptions-item label="平均延迟">{{ Number(status?.throughput.averageLatencySeconds ?? 0).toFixed(2) }} 秒</el-descriptions-item>
          <el-descriptions-item label="规则版本">v{{ status?.configuration.ruleVersion ?? '--' }}</el-descriptions-item>
          <el-descriptions-item label="保护对象">{{ formatCount(status?.configuration.protectedObjectCount) }}</el-descriptions-item>
          <el-descriptions-item label="有效防御圈">{{ formatCount(status?.configuration.defenseRingCount) }}</el-descriptions-item>
          <el-descriptions-item label="状态生成时间">{{ formatTime(status?.generatedAt) }}</el-descriptions-item>
        </el-descriptions>
      </el-card>
    </div>

    <el-card shadow="never" class="failure-card">
      <template #header>
        <div class="card-header">
          <strong>最近 24 小时失败评估</strong>
          <span>{{ failures.length }} 条</span>
        </div>
      </template>
      <el-table v-loading="loading" :data="failures" stripe empty-text="最近 24 小时没有失败评估">
        <el-table-column prop="assessmentId" label="评估 ID" width="110" />
        <el-table-column prop="trackId" label="航迹 ID" width="110" />
        <el-table-column prop="observationId" label="观测 ID" width="120" />
        <el-table-column label="观测时间" min-width="180">
          <template #default="{ row }">{{ formatTime(row.observedAt) }}</template>
        </el-table-column>
        <el-table-column label="失败时间" min-width="180">
          <template #default="{ row }">{{ formatTime(row.assessedAt) }}</template>
        </el-table-column>
        <el-table-column prop="errorCode" label="错误代码" min-width="180">
          <template #default="{ row }"><code>{{ row.errorCode || 'unknown' }}</code></template>
        </el-table-column>
        <el-table-column label="规则版本" width="110">
          <template #default="{ row }">{{ row.ruleVersion == null ? '--' : `v${row.ruleVersion}` }}</template>
        </el-table-column>
      </el-table>
    </el-card>
  </section>
</template>

<style scoped>
.risk-engine-page { display: grid; gap: 16px; }
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
code { color: #b64242; }
@media (max-width: 1100px) {
  .metric-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .detail-grid { grid-template-columns: 1fr; }
}
@media (max-width: 640px) {
  .metric-grid { grid-template-columns: 1fr; }
  .health-title span { display: none; }
}
</style>
