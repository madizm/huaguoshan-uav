<script setup lang="ts">
import { computed, onMounted, reactive, ref, watch } from 'vue'
import { Close, Refresh, Search } from '@element-plus/icons-vue'
import { ElMessage } from 'element-plus'
import type { TagProps } from 'element-plus'
import VChart from 'vue-echarts'
import { use } from 'echarts/core'
import { PieChart, BarChart } from 'echarts/charts'
import {
  TitleComponent,
  TooltipComponent,
  LegendComponent,
  GridComponent,
} from 'echarts/components'
import { CanvasRenderer } from 'echarts/renderers'
import {
  getSourceTargetModelSummary,
  listSourceTargetModelSorties,
  type SourceTargetModelRow,
  type SourceTargetModelSortie,
} from '../api/sourceSorties'
import { listDetectionSources, type DetectionObservationSource } from '../api/detection'

use([
  CanvasRenderer,
  PieChart,
  BarChart,
  TitleComponent,
  TooltipComponent,
  LegendComponent,
  GridComponent,
])

const now = new Date()
const start = new Date(now.getTime() - 7 * 24 * 60 * 60 * 1000)
const dateRange = ref<[Date, Date]>([start, now])
const filters = reactive({
  sourceIds: [] as number[],
  riskLevels: [] as string[],
  models: [] as string[],
  detectionMethodCodes: [] as string[],
  sourceTargetIds: [] as string[],
})
const sources = ref<DetectionObservationSource[]>([])
const rows = ref<SourceTargetModelRow[]>([])
const totalGroups = ref(0)
const loading = ref(false)
const page = ref(1)
const pageSize = ref(50)

// 展开行的架次明细（懒加载）
const sortieCache = reactive(new Map<string, { total: number; sorties: SourceTargetModelSortie[] }>())
const sortieLoading = reactive(new Set<string>())

const modelOptions = computed(() => {
  const set = new Set<string>()
  rows.value.forEach((r) => set.add(r.model))
  return [...set].sort()
})

// 概览统计
const overviewStats = computed(() => {
  const totalSorties = rows.value.reduce((sum, r) => sum + r.sortieCount, 0)
  const totalDuration = rows.value.reduce((sum, r) => sum + r.totalDurationSeconds, 0)
  const totalHighRisk = rows.value.reduce((sum, r) => sum + r.highRiskCount, 0)
  return { totalSorties, totalDuration, totalHighRisk }
})

// 机型分布数据
const modelDistribution = computed(() => {
  const map = new Map<string, number>()
  rows.value.forEach((r) => {
    map.set(r.model, (map.get(r.model) || 0) + r.sortieCount)
  })
  return [...map.entries()]
    .map(([name, value]) => ({ name, value }))
    .sort((a, b) => b.value - a.value)
})

// 风险等级分布数据
const riskDistribution = computed(() => {
  const levels = ['critical', 'high', 'medium', 'low', 'none'] as const
  const labels: Record<string, string> = {
    critical: '严重',
    high: '高',
    medium: '中',
    low: '低',
    none: '正常',
  }
  const counts: Record<string, number> = {}
  levels.forEach((l) => (counts[l] = 0))
  rows.value.forEach((r) => {
    const level = r.maxRiskLevel || 'none'
    counts[level] = (counts[level] || 0) + 1
  })
  return levels
    .filter((l) => counts[l] > 0)
    .map((l) => ({ name: labels[l], value: counts[l], level: l }))
})

// TOP 10 来源目标数据
const top10Targets = computed(() => {
  const map = new Map<string, { total: number; highRisk: number }>()
  rows.value.forEach((r) => {
    const existing = map.get(r.sourceTargetId) || { total: 0, highRisk: 0 }
    existing.total += r.sortieCount
    existing.highRisk += r.highRiskCount
    map.set(r.sourceTargetId, existing)
  })
  return [...map.entries()]
    .map(([name, data]) => ({
      name,
      total: data.total,
      highRisk: data.highRisk,
      normal: data.total - data.highRisk,
    }))
    .sort((a, b) => b.total - a.total)
    .slice(0, 10)
    .reverse() // 水平柱状图从下到上显示
})

// ECharts 配置
const modelChartOption = computed(() => ({
  tooltip: { trigger: 'item', formatter: '{b}: {c} ({d}%)' },
  legend: { orient: 'vertical', right: 10, top: 'center' },
  series: [
    {
      type: 'pie',
      radius: ['40%', '70%'],
      center: ['35%', '50%'],
      avoidLabelOverlap: false,
      itemStyle: { borderRadius: 4, borderColor: '#fff', borderWidth: 2 },
      label: { show: false },
      emphasis: { label: { show: true, fontSize: 14, fontWeight: 'bold' } },
      data: modelDistribution.value,
    },
  ],
}))

const riskColors: Record<string, string> = {
  critical: '#f56c6c',
  high: '#e6a23c',
  medium: '#f0c75e',
  low: '#67c23a',
  none: '#909399',
}

const riskChartOption = computed(() => ({
  tooltip: { trigger: 'item', formatter: '{b}: {c} ({d}%)' },
  legend: { orient: 'vertical', right: 10, top: 'center' },
  series: [
    {
      type: 'pie',
      radius: ['40%', '70%'],
      center: ['35%', '50%'],
      avoidLabelOverlap: false,
      itemStyle: { borderRadius: 4, borderColor: '#fff', borderWidth: 2 },
      label: { show: false },
      emphasis: { label: { show: true, fontSize: 14, fontWeight: 'bold' } },
      data: riskDistribution.value.map((d) => ({
        name: d.name,
        value: d.value,
        itemStyle: { color: riskColors[d.level] },
      })),
    },
  ],
}))

const top10ChartOption = computed(() => ({
  tooltip: {
    trigger: 'axis',
    axisPointer: { type: 'shadow' },
    formatter: (params: any) => {
      const data = params[0]
      const row = top10Targets.value[data.dataIndex]
      return `${row.name}<br/>总架次: ${row.total}<br/>高风险: ${row.highRisk}`
    },
  },
  legend: { data: ['正常', '高风险'], top: 0 },
  grid: { left: '3%', right: '4%', bottom: '3%', top: '30', containLabel: true },
  xAxis: { type: 'value' },
  yAxis: {
    type: 'category',
    data: top10Targets.value.map((d) => d.name),
    axisLabel: {
      width: 120,
      overflow: 'truncate',
      ellipsis: '...',
    },
  },
  series: [
    {
      name: '正常',
      type: 'bar',
      stack: 'total',
      data: top10Targets.value.map((d) => d.normal),
      itemStyle: { color: '#67c23a' },
    },
    {
      name: '高风险',
      type: 'bar',
      stack: 'total',
      data: top10Targets.value.map((d) => d.highRisk),
      itemStyle: { color: '#f56c6c' },
    },
  ],
}))

function requestFilters() {
  return {
    startAt: dateRange.value[0].toISOString(),
    endAt: dateRange.value[1].toISOString(),
    sourceIds: filters.sourceIds,
    riskLevels: filters.riskLevels,
    models: filters.models,
    detectionMethodCodes: filters.detectionMethodCodes,
    sourceTargetIds: filters.sourceTargetIds,
  }
}

async function loadSources() {
  try {
    sources.value = await listDetectionSources()
  } catch {
    // 非关键，静默
  }
}

async function load(showSuccess = false) {
  if (!dateRange.value?.length) return
  if (dateRange.value[1].getTime() <= dateRange.value[0].getTime()) {
    ElMessage.warning('结束时间必须晚于开始时间')
    return
  }
  loading.value = true
  // 清除缓存
  sortieCache.clear()
  sortieLoading.clear()
  try {
    const result = await getSourceTargetModelSummary(
      requestFilters(),
      pageSize.value,
      (page.value - 1) * pageSize.value,
    )
    rows.value = result.rows
    totalGroups.value = result.totalGroups
    if (showSuccess) ElMessage.success('来源目标架次统计已刷新')
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    loading.value = false
  }
}

async function loadSorties(row: SourceTargetModelRow) {
  const key = `${row.sourceTargetId}::${row.model}`
  if (sortieCache.has(key)) return
  sortieLoading.add(key)
  try {
    const result = await listSourceTargetModelSorties(
      requestFilters(),
      row.sourceTargetId,
      row.model,
      500,
      0,
    )
    sortieCache.set(key, { total: result.total, sorties: result.sorties })
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    sortieLoading.delete(key)
  }
}

function handleExpandChange(row: SourceTargetModelRow, expandedList: SourceTargetModelRow[]) {
  const isExpanded = expandedList.some(
    (r) => r.sourceTargetId === row.sourceTargetId && r.model === row.model,
  )
  if (isExpanded) {
    loadSorties(row)
  }
}

function rowKeyFn(row: SourceTargetModelRow): string {
  return `${row.sourceTargetId}::${row.model}`
}

function sortieKey(row: SourceTargetModelRow): string {
  return `${row.sourceTargetId}::${row.model}`
}

function search() {
  page.value = 1
  load()
}

function changePage(nextPage: number) {
  page.value = nextPage
  load()
}

// 图表联动：点击机型饼图
function onModelChartClick(params: any) {
  const model = params.name
  if (filters.models.includes(model)) {
    filters.models = filters.models.filter((m) => m !== model)
  } else {
    filters.models = [model]
  }
  search()
}

// 图表联动：点击风险饼图
function onRiskChartClick(params: any) {
  const level = params.data.level
  if (filters.riskLevels.includes(level)) {
    filters.riskLevels = filters.riskLevels.filter((l) => l !== level)
  } else {
    filters.riskLevels = [level]
  }
  search()
}

// 图表联动：点击 TOP 10 柱状图
function onTop10ChartClick(params: any) {
  const targetId = top10Targets.value[params.dataIndex].name
  if (filters.sourceTargetIds.includes(targetId)) {
    filters.sourceTargetIds = filters.sourceTargetIds.filter((id) => id !== targetId)
  } else {
    filters.sourceTargetIds = [targetId]
  }
  search()
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

function riskLabel(level?: string): string {
  return { critical: '严重', high: '高', medium: '中', low: '低', none: '正常', unavailable: '不可评估' }[level ?? 'unavailable'] ?? '不可评估'
}

function riskTagType(level?: string): TagProps['type'] {
  return { critical: 'danger', high: 'danger', medium: 'warning', low: 'success', none: 'info', unavailable: 'info' }[level ?? 'unavailable'] as TagProps['type']
}

function ringLabel(code?: string): string {
  return { sensing: '感知圈', tracking: '跟踪圈', countermeasure: '反制圈', hard_strike: '硬打击圈', core: '核心圈' }[code ?? ''] ?? '--'
}

// 图表联动过滤条件标签
interface FilterTag {
  key: string
  type: 'model' | 'riskLevel' | 'sourceTarget'
  label: string
  value: string
}

const chartFilterTags = computed<FilterTag[]>(() => {
  const tags: FilterTag[] = []
  const riskLabels: Record<string, string> = {
    critical: '严重',
    high: '高',
    medium: '中',
    low: '低',
    none: '正常',
  }
  filters.models.forEach((m) => {
    tags.push({ key: `model:${m}`, type: 'model', label: `机型: ${m}`, value: m })
  })
  filters.riskLevels.forEach((l) => {
    tags.push({ key: `risk:${l}`, type: 'riskLevel', label: `风险: ${riskLabels[l] || l}`, value: l })
  })
  filters.sourceTargetIds.forEach((id) => {
    tags.push({ key: `target:${id}`, type: 'sourceTarget', label: `目标: ${id}`, value: id })
  })
  return tags
})

function removeFilterTag(tag: FilterTag) {
  if (tag.type === 'model') {
    filters.models = filters.models.filter((m) => m !== tag.value)
  } else if (tag.type === 'riskLevel') {
    filters.riskLevels = filters.riskLevels.filter((l) => l !== tag.value)
  } else if (tag.type === 'sourceTarget') {
    filters.sourceTargetIds = filters.sourceTargetIds.filter((id) => id !== tag.value)
  }
  search()
}

function clearAllChartFilters() {
  filters.models = []
  filters.riskLevels = []
  filters.sourceTargetIds = []
  search()
}

onMounted(() => {
  loadSources()
  load()
})
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
      <el-select
        v-model="filters.sourceIds"
        multiple
        collapse-tags
        clearable
        placeholder="全部侦测来源"
        class="source-filter"
      >
        <el-option
          v-for="src in sources"
          :key="src.id"
          :label="src.name"
          :value="src.id"
        />
      </el-select>
      <el-select
        v-model="filters.riskLevels"
        multiple
        collapse-tags
        clearable
        placeholder="全部风险等级"
        class="risk-filter"
      >
        <el-option label="严重" value="critical" />
        <el-option label="高" value="high" />
        <el-option label="中" value="medium" />
        <el-option label="低" value="low" />
        <el-option label="正常" value="none" />
        <el-option label="不可评估" value="unavailable" />
      </el-select>
      <el-select
        v-model="filters.models"
        multiple
        collapse-tags
        clearable
        filterable
        placeholder="全部机型"
        class="model-filter"
      >
        <el-option
          v-for="m in modelOptions"
          :key="m"
          :label="m"
          :value="m"
        />
      </el-select>
      <el-select
        v-model="filters.detectionMethodCodes"
        multiple
        collapse-tags
        clearable
        placeholder="全部侦测方式"
        class="method-filter"
      >
        <el-option label="雷达" value="radar" />
        <el-option label="电侦" value="radio_detection" />
        <el-option label="光电" value="electro_optical" />
        <el-option label="Remote ID" value="remote_id" />
        <el-option label="网络感知" value="network_sensing" />
        <el-option label="人工上报" value="manual" />
      </el-select>
      <el-button type="primary" :icon="Search" :loading="loading" @click="search">查询</el-button>
      <div class="page-toolbar-spacer" />
      <el-button :icon="Refresh" :loading="loading" @click="load(true)">刷新</el-button>
    </div>

    <el-alert
      title="统计口径：一条 source_target_session 计为一个来源架次，同一来源目标可能出现多种机型，按机型分别统计。点击图表可联动筛选列表。"
      type="info"
      show-icon
      :closable="false"
    />

    <!-- 图表联动过滤条件标签 -->
    <div v-if="chartFilterTags.length" class="filter-tags">
      <span class="filter-tags-label">当前筛选：</span>
      <el-tag
        v-for="tag in chartFilterTags"
        :key="tag.key"
        closable
        :type="tag.type === 'sourceTarget' ? 'primary' : tag.type === 'model' ? 'success' : 'warning'"
        @close="removeFilterTag(tag)"
      >
        {{ tag.label }}
      </el-tag>
      <el-button type="danger" link size="small" @click="clearAllChartFilters">
        <el-icon><Close /></el-icon>
        清除全部
      </el-button>
    </div>

    <!-- 概览卡片 -->
    <div class="overview-cards">
      <el-card shadow="never">
        <div class="card-content">
          <div class="card-label">总分组数</div>
          <div class="card-value">{{ formatCount(totalGroups) }}</div>
        </div>
      </el-card>
      <el-card shadow="never">
        <div class="card-content">
          <div class="card-label">总飞行次数</div>
          <div class="card-value">{{ formatCount(overviewStats.totalSorties) }}</div>
        </div>
      </el-card>
      <el-card shadow="never">
        <div class="card-content">
          <div class="card-label">总飞行时长</div>
          <div class="card-value">{{ formatDuration(overviewStats.totalDuration) }}</div>
        </div>
      </el-card>
      <el-card shadow="never">
        <div class="card-content">
          <div class="card-label">高风险架次</div>
          <div class="card-value danger">{{ formatCount(overviewStats.totalHighRisk) }}</div>
        </div>
      </el-card>
    </div>

    <!-- 图表区域 -->
    <div class="charts-row">
      <el-card shadow="never" class="chart-card">
        <template #header>
          <div class="card-header">
            <strong>机型分布</strong>
            <span class="hint">点击扇区筛选</span>
          </div>
        </template>
        <v-chart
          :option="modelChartOption"
          autoresize
          style="height: 300px"
          @click="onModelChartClick"
        />
      </el-card>
      <el-card shadow="never" class="chart-card">
        <template #header>
          <div class="card-header">
            <strong>风险等级分布</strong>
            <span class="hint">点击扇区筛选</span>
          </div>
        </template>
        <v-chart
          :option="riskChartOption"
          autoresize
          style="height: 300px"
          @click="onRiskChartClick"
        />
      </el-card>
    </div>

    <el-card shadow="never">
      <template #header>
        <div class="card-header">
          <strong>来源目标 TOP 10</strong>
          <span class="hint">点击柱状图筛选</span>
        </div>
      </template>
      <v-chart
        :option="top10ChartOption"
        autoresize
        style="height: 400px"
        @click="onTop10ChartClick"
      />
    </el-card>

    <!-- 列表区域 -->
    <el-card shadow="never">
      <template #header>
        <div class="card-header">
          <strong>来源目标架次统计</strong>
          <span>共 {{ formatCount(totalGroups) }} 个分组</span>
        </div>
      </template>
      <el-table
        v-loading="loading"
        :data="rows"
        stripe
        :row-key="rowKeyFn"
        @expand-change="handleExpandChange"
      >
        <el-table-column type="expand">
          <template #default="{ row }">
            <div class="expand-content">
              <div v-if="sortieLoading.has(sortieKey(row))" class="expand-loading">
                <el-icon class="is-loading"><Refresh /></el-icon>
                <span>加载架次明细…</span>
              </div>
              <template v-else-if="sortieCache.has(sortieKey(row))">
                <div class="expand-summary">
                  共 {{ formatCount(sortieCache.get(sortieKey(row))!.total) }} 个架次
                </div>
                <el-table :data="sortieCache.get(sortieKey(row))!.sorties" size="small" stripe>
                  <el-table-column label="架次 / 航迹" min-width="180">
                    <template #default="{ row: s }">
                      <div class="primary-cell">
                        <strong>#{{ s.sortieId }}</strong>
                        <span>{{ s.trackCode }}</span>
                      </div>
                    </template>
                  </el-table-column>
                  <el-table-column label="来源" min-width="120">
                    <template #default="{ row: s }">{{ s.sourceName }}</template>
                  </el-table-column>
                  <el-table-column label="开始时间" min-width="175">
                    <template #default="{ row: s }">{{ formatTime(s.startedAt) }}</template>
                  </el-table-column>
                  <el-table-column label="持续 / 观测" min-width="145">
                    <template #default="{ row: s }">
                      <div class="primary-cell">
                        <strong>{{ formatDuration(s.durationSeconds) }}</strong>
                        <span>{{ s.observationCount }} 条 / {{ s.spatialObservationCount }} 空间</span>
                      </div>
                    </template>
                  </el-table-column>
                  <el-table-column label="最大风险" width="115">
                    <template #default="{ row: s }">
                      <el-tag :type="riskTagType(s.maxRiskLevel)" effect="light">
                        {{ riskLabel(s.maxRiskLevel) }}{{ s.maxRiskScore == null ? '' : ` ${s.maxRiskScore}` }}
                      </el-tag>
                    </template>
                  </el-table-column>
                  <el-table-column label="最深圈层" width="110">
                    <template #default="{ row: s }">{{ ringLabel(s.deepestRingCode) }}</template>
                  </el-table-column>
                  <el-table-column label="结束状态" width="120">
                    <template #default="{ row: s }">
                      <div class="primary-cell">
                        <strong>{{ s.state }}</strong>
                        <span>{{ s.endReason || '--' }}</span>
                      </div>
                    </template>
                  </el-table-column>
                </el-table>
              </template>
              <el-empty v-else description="展开后加载架次明细" :image-size="48" />
            </div>
          </template>
        </el-table-column>
        <el-table-column label="来源目标" min-width="160">
          <template #default="{ row }">
            <strong>{{ row.sourceTargetId }}</strong>
          </template>
        </el-table-column>
        <el-table-column label="侦测来源" min-width="140">
          <template #default="{ row }">{{ row.sourceName }}</template>
        </el-table-column>
        <el-table-column label="机型" min-width="120">
          <template #default="{ row }">
            <el-tag effect="plain" size="small">{{ row.model }}</el-tag>
          </template>
        </el-table-column>
        <el-table-column label="飞行次数" width="100" align="right">
          <template #default="{ row }">
            <strong>{{ formatCount(row.sortieCount) }}</strong>
          </template>
        </el-table-column>
        <el-table-column label="总飞行时长" width="130" align="right">
          <template #default="{ row }">{{ formatDuration(row.totalDurationSeconds) }}</template>
        </el-table-column>
        <el-table-column label="高风险架次" width="110" align="right">
          <template #default="{ row }">
            <span :class="{ 'high-risk': row.highRiskCount > 0 }">{{ formatCount(row.highRiskCount) }}</span>
          </template>
        </el-table-column>
        <el-table-column label="最高风险" width="100">
          <template #default="{ row }">
            <el-tag :type="riskTagType(row.maxRiskLevel)" effect="light" size="small">
              {{ riskLabel(row.maxRiskLevel) }}
            </el-tag>
          </template>
        </el-table-column>
        <el-table-column label="最近飞行" min-width="175">
          <template #default="{ row }">{{ formatTime(row.lastSortieAt) }}</template>
        </el-table-column>
      </el-table>
      <div class="pagination">
        <el-pagination
          background
          layout="prev, pager, next, total"
          :total="totalGroups"
          :page-size="pageSize"
          :current-page="page"
          @current-change="changePage"
        />
      </div>
    </el-card>
  </section>
</template>

<style scoped>
.sortie-page { display: grid; gap: 16px; }
.page-toolbar { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
.page-toolbar-spacer { flex: 1; }
.source-filter { width: 200px; }
.risk-filter { width: 170px; }
.model-filter { width: 180px; }
.method-filter { width: 180px; }
.card-header { display: flex; justify-content: space-between; align-items: center; }
.card-header span { color: #87918c; font-size: 12px; }
.card-header .hint { color: #409eff; font-size: 12px; }
.primary-cell { display: grid; gap: 3px; }
.primary-cell span { color: #89928e; font-size: 11px; }
.expand-content { padding: 12px 20px; }
.expand-loading { display: flex; align-items: center; gap: 8px; color: #87918c; font-size: 13px; padding: 16px 0; }
.expand-summary { color: #7a8580; font-size: 12px; margin-bottom: 10px; }
.high-risk { color: #f56c6c; font-weight: 600; }

/* 图表联动过滤标签 */
.filter-tags {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 12px 16px;
  background: #f0f9ff;
  border: 1px solid #bae6fd;
  border-radius: 6px;
  flex-wrap: wrap;
}
.filter-tags-label {
  color: #0369a1;
  font-size: 13px;
  font-weight: 500;
}
.pagination { display: flex; justify-content: flex-end; padding-top: 16px; }

/* 概览卡片 */
.overview-cards {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 16px;
}
.overview-cards .card-content {
  text-align: center;
  padding: 8px 0;
}
.overview-cards .card-label {
  color: #909399;
  font-size: 13px;
  margin-bottom: 8px;
}
.overview-cards .card-value {
  font-size: 28px;
  font-weight: 600;
  color: #303133;
}
.overview-cards .card-value.danger {
  color: #f56c6c;
}

/* 图表区域 */
.charts-row {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 16px;
}
.chart-card {
  min-height: 380px;
}

@media (max-width: 1200px) {
  .source-filter, .risk-filter, .model-filter, .method-filter { width: 100%; }
  .overview-cards { grid-template-columns: repeat(2, 1fr); }
  .charts-row { grid-template-columns: 1fr; }
}
</style>
