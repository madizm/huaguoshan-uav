<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import { Refresh, Search } from '@element-plus/icons-vue'
import { ElMessage } from 'element-plus'
import type { TagProps } from 'element-plus'
import {
  getSourceSortieSeries,
  getSourceSortieStatistics,
  listSourceSorties,
  type SourceSortie,
  type SourceSortieSeriesPoint,
  type SourceSortieStatistics,
} from '../api/sourceSorties'

const now = new Date()
const start = new Date(now.getTime() - 7 * 24 * 60 * 60 * 1000)
const dateRange = ref<[Date, Date]>([start, now])
const filters = reactive({ riskLevels: [] as string[], qualityIssue: 'normal' })
const statistics = ref<SourceSortieStatistics | null>(null)
const series = ref<SourceSortieSeriesPoint[]>([])
const sorties = ref<SourceSortie[]>([])
const total = ref(0)
const page = ref(1)
const pageSize = ref(50)
const loading = ref(false)

const maxSeriesCount = computed(() => Math.max(1, ...series.value.map((point) => point.sortieCount)))
const summary = computed(() => statistics.value?.summary)
const quality = computed(() => statistics.value?.quality)
const riskRows = computed(() => {
  const levels = ['critical', 'high', 'medium', 'low', 'none', 'unavailable'] as const
  const totalCount = statistics.value?.summary.sortieCount ?? 0
  return levels.map((level) => {
    const count = statistics.value?.riskDistribution[level] ?? 0
    return { level, count, percentage: totalCount ? Math.round(count / totalCount * 100) : 0 }
  })
})

function requestFilters() {
  return {
    startAt: dateRange.value[0].toISOString(),
    endAt: dateRange.value[1].toISOString(),
    riskLevels: filters.riskLevels,
    qualityIssue: filters.qualityIssue,
  }
}

async function load(showSuccess = false) {
  if (!dateRange.value?.length) return
  if (dateRange.value[1].getTime() <= dateRange.value[0].getTime()) {
    ElMessage.warning('结束时间必须晚于开始时间')
    return
  }
  if (dateRange.value[1].getTime() - dateRange.value[0].getTime() > 31 * 86400_000) {
    ElMessage.warning('架次明细查询最多支持 31 天')
    return
  }
  loading.value = true
  try {
    const query = requestFilters()
    const bucket = dateRange.value[1].getTime() - dateRange.value[0].getTime() <= 2 * 86400_000 ? 'hour' : 'day'
    const [nextStatistics, nextSeries, list] = await Promise.all([
      getSourceSortieStatistics(query),
      getSourceSortieSeries(query, bucket),
      listSourceSorties(query, pageSize.value, (page.value - 1) * pageSize.value),
    ])
    statistics.value = nextStatistics
    series.value = nextSeries.points
    sorties.value = list.sorties
    total.value = list.total
    if (showSuccess) ElMessage.success('来源架次统计已刷新')
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    loading.value = false
  }
}

function search() {
  page.value = 1
  load()
}

function changePage(nextPage: number) {
  page.value = nextPage
  load()
}

function formatCount(value?: number | null): string {
  return Number(value ?? 0).toLocaleString('zh-CN')
}

function formatTime(value?: string | null): string {
  return value ? new Date(value).toLocaleString('zh-CN', { hour12: false }) : '--'
}

function formatDuration(value?: number | null): string {
  const seconds = Math.round(Number(value ?? 0))
  if (seconds < 60) return `${seconds} 秒`
  if (seconds < 3600) return `${Math.floor(seconds / 60)} 分 ${seconds % 60} 秒`
  return `${Math.floor(seconds / 3600)} 小时 ${Math.floor(seconds % 3600 / 60)} 分`
}

function bucketLabel(value: string): string {
  const date = new Date(value)
  return series.value.length > 48
    ? `${date.getMonth() + 1}-${date.getDate()}`
    : date.toLocaleString('zh-CN', { month: 'numeric', day: 'numeric', hour: '2-digit', hour12: false })
}

function riskLabel(level?: string): string {
  return { critical: '严重', high: '高', medium: '中', low: '低', none: '正常', unavailable: '不可评估' }[level ?? 'unavailable'] ?? '不可评估'
}

function riskTagType(level?: string): TagProps['type'] {
  return { critical: 'danger', high: 'danger', medium: 'warning', low: 'success', none: 'info', unavailable: 'info' }[level ?? 'unavailable'] as TagProps['type']
}

function ringLabel(code?: string): string {
  return { sensing: '感知圈', tracking: '跟踪圈', countermeasure: '反制圈', hard_strike: '硬打击圈', core: '核心圈' }[code ?? ''] ?? '--'
}

function qualityLabels(sortie: SourceSortie): string[] {
  const labels: string[] = []
  if (sortie.timestampSuspect) labels.push('时间异常')
  if (sortie.singleTimestamp) labels.push('单一时刻')
  if (sortie.nonSpatial) labels.push('无坐标')
  if (sortie.lifecycleOverlap) labels.push('生命周期重叠')
  return labels
}

onMounted(() => load())
</script>

<template>
  <section class="sortie-page">
    <div class="page-toolbar">
      <el-date-picker
        v-model="dateRange"
        type="datetimerange"
        range-separator="至"
        start-placeholder="开始时间"
        end-placeholder="结束时间"
      />
      <el-select v-model="filters.riskLevels" multiple collapse-tags clearable placeholder="明细最大风险" class="risk-filter">
        <el-option label="严重" value="critical" />
        <el-option label="高" value="high" />
        <el-option label="中" value="medium" />
        <el-option label="低" value="low" />
        <el-option label="正常" value="none" />
        <el-option label="不可评估" value="unavailable" />
      </el-select>
      <el-select v-model="filters.qualityIssue" clearable placeholder="全部质量状态" class="quality-filter">
        <el-option label="数据质量正常" value="normal" />
        <el-option label="时间戳异常" value="timestamp_suspect" />
        <el-option label="单一观测时刻" value="single_timestamp" />
        <el-option label="无空间坐标" value="non_spatial" />
        <el-option label="生命周期重叠" value="lifecycle_overlap" />
      </el-select>
      <el-button type="primary" :icon="Search" :loading="loading" @click="search">查询</el-button>
      <div class="page-toolbar-spacer" />
      <el-button :icon="Refresh" :loading="loading" @click="load(true)">刷新</el-button>
    </div>

    <el-alert
      title="统计口径：一条 source_target_session 计为一个来源架次，不代表跨来源融合后的实际物理飞行架次。"
      type="info"
      show-icon
      :closable="false"
    />

    <div class="summary-grid" aria-label="来源架次统计概览">
      <article><span>来源架次</span><strong>{{ formatCount(summary?.sortieCount) }}</strong><small>{{ formatCount(summary?.observationCount) }} 条观测</small></article>
      <article data-tone="success"><span>空间架次</span><strong>{{ formatCount(summary?.spatialCount) }}</strong><small>具备至少一个空间点</small></article>
      <article data-tone="danger"><span>高风险架次</span><strong>{{ formatCount(summary?.highRiskCount) }}</strong><small>最大风险为高或严重</small></article>
      <article data-tone="warning"><span>进入核心圈</span><strong>{{ formatCount(summary?.coreRingCount) }}</strong><small>架次最深圈层</small></article>
      <article><span>平均持续时间</span><strong class="duration-value">{{ formatDuration(summary?.averageDurationSeconds) }}</strong><small>按观测起止时间</small></article>
    </div>

    <div class="analysis-grid">
      <el-card shadow="never">
        <template #header><strong>架次趋势</strong></template>
        <div v-if="series.length" class="series-chart">
          <div v-for="point in series" :key="point.bucketAt" class="series-column" :title="`${formatTime(point.bucketAt)}：${point.sortieCount} 架次`">
            <div class="series-stack">
              <i class="series-high" :style="{ height: `${point.highRiskCount / maxSeriesCount * 100}%` }" />
              <i class="series-total" :style="{ height: `${point.sortieCount / maxSeriesCount * 100}%` }" />
            </div>
            <span>{{ bucketLabel(point.bucketAt) }}</span>
          </div>
        </div>
        <el-empty v-else description="所选时间段没有来源架次" :image-size="72" />
        <div class="legend"><span><i class="total-dot" />全部架次</span><span><i class="high-dot" />高/严重风险</span></div>
      </el-card>

      <el-card shadow="never">
        <template #header><strong>风险与质量</strong></template>
        <div class="distribution-list">
          <div v-for="row in riskRows" :key="row.level">
            <span>{{ riskLabel(row.level) }}</span>
            <el-progress :percentage="row.percentage" :stroke-width="8" :show-text="false" />
            <strong>{{ formatCount(row.count) }}</strong>
          </div>
        </div>
        <dl class="quality-grid">
          <div><dt>时间戳异常</dt><dd>{{ formatCount(quality?.timestampSuspectCount) }}</dd></div>
          <div><dt>单一观测时刻</dt><dd>{{ formatCount(quality?.singleTimestampCount) }}</dd></div>
          <div><dt>无坐标</dt><dd>{{ formatCount(quality?.nonSpatialCount) }}</dd></div>
          <div><dt>生命周期重叠</dt><dd>{{ formatCount(quality?.lifecycleOverlapCount) }}</dd></div>
        </dl>
      </el-card>
    </div>

    <el-card shadow="never">
      <template #header><div class="card-header"><strong>来源架次明细</strong><span>共 {{ formatCount(total) }} 条</span></div></template>
      <el-table v-loading="loading" :data="sorties" stripe>
        <el-table-column label="架次 / 来源目标" min-width="220">
          <template #default="{ row }"><div class="primary-cell"><strong>#{{ row.sortieId }} · {{ row.sourceTargetId }}</strong><span>{{ row.trackCode }} · {{ row.sourceName }}</span></div></template>
        </el-table-column>
        <el-table-column label="开始时间" min-width="175"><template #default="{ row }">{{ formatTime(row.startedAt) }}</template></el-table-column>
        <el-table-column label="持续 / 观测" min-width="145"><template #default="{ row }"><div class="primary-cell"><strong>{{ formatDuration(row.durationSeconds) }}</strong><span>{{ row.observationCount }} 条 / {{ row.spatialObservationCount }} 空间</span></div></template></el-table-column>
        <el-table-column label="最大风险" width="115"><template #default="{ row }"><el-tag :type="riskTagType(row.maxRiskLevel)" effect="light">{{ riskLabel(row.maxRiskLevel) }}{{ row.maxRiskScore == null ? '' : ` ${row.maxRiskScore}` }}</el-tag></template></el-table-column>
        <el-table-column label="最深圈层" width="110"><template #default="{ row }">{{ ringLabel(row.deepestRingCode) }}</template></el-table-column>
        <el-table-column label="结束状态" width="120"><template #default="{ row }"><div class="primary-cell"><strong>{{ row.state }}</strong><span>{{ row.endReason || '--' }}</span></div></template></el-table-column>
        <el-table-column label="数据质量" min-width="210"><template #default="{ row }"><div v-if="qualityLabels(row).length" class="quality-tags"><el-tag v-for="label in qualityLabels(row)" :key="label" type="warning" size="small" effect="plain">{{ label }}</el-tag></div><el-tag v-else type="success" size="small" effect="plain">正常</el-tag></template></el-table-column>
      </el-table>
      <div class="pagination"><el-pagination background layout="prev, pager, next" :total="total" :page-size="pageSize" :current-page="page" @current-change="changePage" /></div>
    </el-card>
  </section>
</template>

<style scoped>
.sortie-page { display: grid; gap: 16px; }
.page-toolbar { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
.page-toolbar-spacer { flex: 1; }
.risk-filter { width: 190px; }
.quality-filter { width: 180px; }
.summary-grid { display: grid; grid-template-columns: repeat(5, minmax(0, 1fr)); gap: 12px; }
.summary-grid article { display: grid; gap: 6px; padding: 17px; border: 1px solid #e1e7e3; border-radius: 8px; background: #fff; }
.summary-grid article::before { width: 26px; height: 3px; border-radius: 2px; background: #809089; content: ''; }
.summary-grid article[data-tone="success"]::before { background: #28a36a; }
.summary-grid article[data-tone="danger"]::before { background: #f56c6c; }
.summary-grid article[data-tone="warning"]::before { background: #e6a23c; }
.summary-grid span, .summary-grid small { color: #7a8580; font-size: 12px; }
.summary-grid strong { color: #202522; font-size: 25px; }
.summary-grid .duration-value { font-size: 19px; }
.analysis-grid { display: grid; grid-template-columns: minmax(0, 1.4fr) minmax(320px, 0.6fr); gap: 16px; }
.series-chart { display: flex; align-items: stretch; gap: 4px; height: 210px; overflow-x: auto; padding-top: 10px; }
.series-column { display: grid; grid-template-rows: 175px auto; gap: 7px; min-width: 24px; flex: 1; }
.series-stack { position: relative; display: flex; align-items: end; justify-content: center; border-bottom: 1px solid #dfe5e1; }
.series-stack i { position: absolute; bottom: 0; width: 70%; min-height: 1px; border-radius: 3px 3px 0 0; }
.series-total { background: #77c9a0; }
.series-high { z-index: 1; width: 38% !important; background: #f56c6c; }
.series-column > span { overflow: hidden; color: #8a948f; font-size: 9px; text-align: center; white-space: nowrap; }
.legend { display: flex; justify-content: center; gap: 18px; color: #77817c; font-size: 11px; }
.legend span { display: flex; align-items: center; gap: 5px; }
.legend i { width: 8px; height: 8px; border-radius: 2px; }
.total-dot { background: #77c9a0; }.high-dot { background: #f56c6c; }
.distribution-list { display: grid; gap: 10px; }
.distribution-list > div { display: grid; grid-template-columns: 54px minmax(80px, 1fr) 42px; gap: 9px; align-items: center; color: #66716b; font-size: 12px; }
.distribution-list strong { text-align: right; }
.quality-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 8px; margin: 18px 0 0; }
.quality-grid div { padding: 10px; border-radius: 6px; background: #f4f7f5; }
.quality-grid dt { color: #7c8781; font-size: 11px; }.quality-grid dd { margin: 4px 0 0; color: #27302b; font-size: 18px; font-weight: 700; }
.card-header { display: flex; justify-content: space-between; }.card-header span { color: #87918c; font-size: 12px; }
.primary-cell { display: grid; gap: 3px; }.primary-cell span { color: #89928e; font-size: 11px; }
.quality-tags { display: flex; gap: 4px; flex-wrap: wrap; }
.pagination { display: flex; justify-content: flex-end; padding-top: 16px; }
@media (max-width: 1200px) { .summary-grid { grid-template-columns: repeat(3, 1fr); }.analysis-grid { grid-template-columns: 1fr; } }
@media (max-width: 720px) { .summary-grid { grid-template-columns: 1fr 1fr; }.risk-filter,.quality-filter { width: 100%; } }
</style>
