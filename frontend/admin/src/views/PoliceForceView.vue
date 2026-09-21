<script setup lang="ts">
import { onMounted, reactive, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import {
  listActivePoliceOfficers,
  listPoliceOfficers,
  listPoliceStations,
  listPoliceTeams,
  updatePoliceOfficer,
  updatePoliceTeam,
  type PoliceAvailabilityStatus,
  type PoliceOfficer,
  type PoliceStationOption,
  type PoliceTeamDetails,
  type PoliceTeamStatus,
} from '../api/police'
import PoliceOfficerEditorDrawer from '../components/PoliceOfficerEditorDrawer.vue'
import PoliceTeamEditorDrawer from '../components/PoliceTeamEditorDrawer.vue'
import PoliceTeamRosterDrawer from '../components/PoliceTeamRosterDrawer.vue'

const activeTab = ref('teams')
const stations = ref<PoliceStationOption[]>([])
const activeOfficers = ref<PoliceOfficer[]>([])

const teams = ref<PoliceTeamDetails[]>([])
const teamTotal = ref(0)
const teamLoading = ref(false)
const teamFilters = reactive({
  keyword: '',
  stationId: null as number | null,
  status: '' as '' | PoliceTeamStatus,
  simulation: '' as '' | 'real' | 'simulated',
})
const teamPage = reactive({ current: 1, size: 20 })
const teamEditorVisible = ref(false)
const editingTeam = ref<PoliceTeamDetails | null>(null)
const rosterVisible = ref(false)
const rosterTeam = ref<PoliceTeamDetails | null>(null)

const officers = ref<PoliceOfficer[]>([])
const officerTotal = ref(0)
const officerLoading = ref(false)
const officerFilters = reactive({
  keyword: '',
  status: '' as '' | PoliceAvailabilityStatus,
  simulation: '' as '' | 'real' | 'simulated',
  active: 'true' as 'true' | 'false' | 'all',
})
const officerPage = reactive({ current: 1, size: 20 })
const officerEditorVisible = ref(false)
const editingOfficer = ref<PoliceOfficer | null>(null)

const teamStatusLabels: Record<PoliceTeamStatus, string> = {
  active: '正常', standby: '待命', dispatched: '已出动', inactive: '停用',
}
const officerStatusLabels: Record<PoliceAvailabilityStatus, string> = {
  available: '可用', on_duty: '值勤', dispatched: '已出动', leave: '请假', unavailable: '不可用',
}

async function loadReferenceData() {
  try {
    const [stationRows, officerRows] = await Promise.all([
      listPoliceStations(),
      listActivePoliceOfficers(),
    ])
    stations.value = stationRows
    activeOfficers.value = officerRows
  } catch (error) {
    ElMessage.error((error as Error).message)
  }
}

async function loadTeams() {
  teamLoading.value = true
  try {
    const result = await listPoliceTeams({
      keyword: teamFilters.keyword || undefined,
      stationId: teamFilters.stationId ?? undefined,
      status: teamFilters.status || undefined,
      simulation: teamFilters.simulation || undefined,
      limit: teamPage.size,
      offset: (teamPage.current - 1) * teamPage.size,
    })
    teams.value = result.rows
    teamTotal.value = result.total
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    teamLoading.value = false
  }
}

async function loadOfficers() {
  officerLoading.value = true
  try {
    const result = await listPoliceOfficers({
      keyword: officerFilters.keyword || undefined,
      status: officerFilters.status || undefined,
      simulation: officerFilters.simulation || undefined,
      active: officerFilters.active === 'all' ? undefined : officerFilters.active === 'true',
      limit: officerPage.size,
      offset: (officerPage.current - 1) * officerPage.size,
    })
    officers.value = result.rows
    officerTotal.value = result.total
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    officerLoading.value = false
  }
}

function searchTeams() { teamPage.current = 1; loadTeams() }
function searchOfficers() { officerPage.current = 1; loadOfficers() }
function tabChanged(name: string | number) { if (name === 'officers') loadOfficers() }

function openCreateTeam() { editingTeam.value = null; teamEditorVisible.value = true }
function openEditTeam(team: PoliceTeamDetails) { editingTeam.value = team; teamEditorVisible.value = true }
function openRoster(team: PoliceTeamDetails) { rosterTeam.value = team; rosterVisible.value = true }
function openCreateOfficer() { editingOfficer.value = null; officerEditorVisible.value = true }
function openEditOfficer(officer: PoliceOfficer) { editingOfficer.value = officer; officerEditorVisible.value = true }

async function teamSaved() {
  await Promise.all([loadTeams(), loadReferenceData()])
}

async function officerSaved() {
  await Promise.all([loadOfficers(), loadReferenceData()])
}

async function toggleTeam(team: PoliceTeamDetails) {
  const activating = team.team_status === 'inactive'
  await ElMessageBox.confirm(`确认${activating ? '启用' : '停用'}编组「${team.team_name}」？`, '编组状态', { type: 'warning' })
  try {
    await updatePoliceTeam(team.team_id, { team_status: activating ? 'active' : 'inactive' })
    ElMessage.success(activating ? '编组已启用' : '编组已停用')
    await loadTeams()
  } catch (error) {
    ElMessage.error((error as Error).message)
  }
}

async function toggleOfficer(officer: PoliceOfficer) {
  const activating = !officer.is_active
  await ElMessageBox.confirm(`确认${activating ? '启用' : '停用'}警员「${officer.name}」？`, '警员档案状态', { type: 'warning' })
  try {
    await updatePoliceOfficer(officer.id, { is_active: activating })
    ElMessage.success(activating ? '警员档案已启用' : '警员档案已停用')
    await Promise.all([loadOfficers(), loadReferenceData()])
  } catch (error) {
    ElMessage.error((error as Error).message)
  }
}

function formatTime(value: string) {
  return new Date(value).toLocaleString('zh-CN')
}

onMounted(async () => {
  await loadReferenceData()
  await loadTeams()
})
</script>

<template>
  <section>
    <el-tabs v-model="activeTab" @tab-change="tabChanged">
      <el-tab-pane label="编组管理" name="teams">
        <div class="page-toolbar">
          <el-input v-model="teamFilters.keyword" clearable placeholder="编组编码 / 名称" style="width: 220px" @keyup.enter="searchTeams" @clear="searchTeams" />
          <el-select v-model="teamFilters.stationId" clearable filterable placeholder="全部警务站" style="width: 220px" @change="searchTeams">
            <el-option v-for="station in stations" :key="station.id" :label="station.name" :value="station.id" />
          </el-select>
          <el-select v-model="teamFilters.status" clearable placeholder="全部状态" style="width: 130px" @change="searchTeams">
            <el-option v-for="(label, value) in teamStatusLabels" :key="value" :label="label" :value="value" />
          </el-select>
          <el-select v-model="teamFilters.simulation" clearable placeholder="全部数据" style="width: 130px" @change="searchTeams">
            <el-option label="真实数据" value="real" />
            <el-option label="模拟数据" value="simulated" />
          </el-select>
          <el-button type="primary" @click="searchTeams">查询</el-button>
          <div class="page-toolbar-spacer" />
          <el-button type="primary" @click="openCreateTeam">新增编组</el-button>
        </div>

        <div class="table-shell">
          <el-table v-loading="teamLoading" :data="teams" stripe>
            <el-table-column prop="team_code" label="编组编码" width="170" />
            <el-table-column prop="team_name" label="编组名称" min-width="160" />
            <el-table-column prop="station_name" label="挂载警务站" min-width="210" show-overflow-tooltip>
              <template #default="{ row }">{{ row.station_name ?? '未挂载' }}</template>
            </el-table-column>
            <el-table-column prop="leader_name" label="组长" width="110">
              <template #default="{ row }">{{ row.leader_name ?? '未设置' }}</template>
            </el-table-column>
            <el-table-column prop="active_member_count" label="成员数" width="85" align="center" />
            <el-table-column label="状态" width="90">
              <template #default="{ row }"><el-tag>{{ teamStatusLabels[row.team_status as PoliceTeamStatus] }}</el-tag></template>
            </el-table-column>
            <el-table-column label="数据类型" width="95">
              <template #default="{ row }"><el-tag :type="row.is_simulated ? 'warning' : 'success'" effect="plain">{{ row.is_simulated ? '模拟' : '真实' }}</el-tag></template>
            </el-table-column>
            <el-table-column label="更新时间" width="175">
              <template #default="{ row }">{{ formatTime(row.updated_at) }}</template>
            </el-table-column>
            <el-table-column label="操作" width="220" fixed="right">
              <template #default="{ row }">
                <el-button text type="primary" @click="openRoster(row)">成员</el-button>
                <el-button text type="primary" @click="openEditTeam(row)">编辑</el-button>
                <el-button text :type="row.team_status === 'inactive' ? 'success' : 'danger'" @click="toggleTeam(row)">{{ row.team_status === 'inactive' ? '启用' : '停用' }}</el-button>
              </template>
            </el-table-column>
          </el-table>
        </div>
        <el-pagination v-model:current-page="teamPage.current" v-model:page-size="teamPage.size" :total="teamTotal" :page-sizes="[20, 50, 100]" layout="total, sizes, prev, pager, next" class="page-pagination" @current-change="loadTeams" @size-change="searchTeams" />
      </el-tab-pane>

      <el-tab-pane label="警员档案" name="officers">
        <div class="page-toolbar">
          <el-input v-model="officerFilters.keyword" clearable placeholder="警号 / 姓名" style="width: 220px" @keyup.enter="searchOfficers" @clear="searchOfficers" />
          <el-select v-model="officerFilters.status" clearable placeholder="全部状态" style="width: 130px" @change="searchOfficers">
            <el-option v-for="(label, value) in officerStatusLabels" :key="value" :label="label" :value="value" />
          </el-select>
          <el-select v-model="officerFilters.active" style="width: 130px" @change="searchOfficers">
            <el-option label="有效档案" value="true" />
            <el-option label="停用档案" value="false" />
            <el-option label="全部档案" value="all" />
          </el-select>
          <el-select v-model="officerFilters.simulation" clearable placeholder="全部数据" style="width: 130px" @change="searchOfficers">
            <el-option label="真实数据" value="real" />
            <el-option label="模拟数据" value="simulated" />
          </el-select>
          <el-button type="primary" @click="searchOfficers">查询</el-button>
          <div class="page-toolbar-spacer" />
          <el-button type="primary" @click="openCreateOfficer">新增警员</el-button>
        </div>

        <div class="table-shell">
          <el-table v-loading="officerLoading" :data="officers" stripe>
            <el-table-column prop="officer_no" label="警号" width="170" />
            <el-table-column prop="name" label="姓名" width="120" />
            <el-table-column prop="contact_phone" label="联系电话" width="145" />
            <el-table-column prop="organization_name" label="所属单位" min-width="210" show-overflow-tooltip />
            <el-table-column label="可用状态" width="100">
              <template #default="{ row }">{{ officerStatusLabels[row.availability_status as PoliceAvailabilityStatus] }}</template>
            </el-table-column>
            <el-table-column label="档案状态" width="95">
              <template #default="{ row }"><el-tag :type="row.is_active ? 'success' : 'info'">{{ row.is_active ? '有效' : '停用' }}</el-tag></template>
            </el-table-column>
            <el-table-column label="数据类型" width="95">
              <template #default="{ row }"><el-tag :type="row.is_simulated ? 'warning' : 'success'" effect="plain">{{ row.is_simulated ? '模拟' : '真实' }}</el-tag></template>
            </el-table-column>
            <el-table-column label="更新时间" width="175">
              <template #default="{ row }">{{ formatTime(row.updated_at) }}</template>
            </el-table-column>
            <el-table-column label="操作" width="160" fixed="right">
              <template #default="{ row }">
                <div class="action-buttons">
                  <el-button text type="primary" @click="openEditOfficer(row)">编辑</el-button>
                  <el-button text :type="row.is_active ? 'danger' : 'success'" @click="toggleOfficer(row)">{{ row.is_active ? '停用' : '启用' }}</el-button>
                </div>
              </template>
            </el-table-column>
          </el-table>
        </div>
        <el-pagination v-model:current-page="officerPage.current" v-model:page-size="officerPage.size" :total="officerTotal" :page-sizes="[20, 50, 100]" layout="total, sizes, prev, pager, next" class="page-pagination" @current-change="loadOfficers" @size-change="searchOfficers" />
      </el-tab-pane>
    </el-tabs>

    <PoliceTeamEditorDrawer v-model="teamEditorVisible" :team="editingTeam" :stations="stations" :officers="activeOfficers" @saved="teamSaved" />
    <PoliceTeamRosterDrawer v-model="rosterVisible" :team="rosterTeam" :officers="activeOfficers" @changed="loadTeams" />
    <PoliceOfficerEditorDrawer v-model="officerEditorVisible" :officer="editingOfficer" @saved="officerSaved" />
  </section>
</template>
<style scoped>
.action-buttons {
  display: flex;
  flex-wrap: nowrap;
  align-items: center;
  gap: 4px;
  white-space: nowrap;
}

.action-buttons :deep(.el-button) {
  margin-left: 0;
}
</style>
