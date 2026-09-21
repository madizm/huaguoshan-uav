<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import {
  addPoliceTeamMember,
  assignPoliceTeamLeader,
  listPoliceTeamMemberHistory,
  listPoliceTeamRoster,
  removePoliceTeamMember,
  updatePoliceTeamMemberRole,
  type PoliceMembershipHistoryRow,
  type PoliceOfficer,
  type PoliceRosterRow,
  type PoliceTeamDetails,
} from '../api/police'

const visible = defineModel<boolean>({ required: true })
const props = defineProps<{ team: PoliceTeamDetails | null; officers: PoliceOfficer[] }>()
const emit = defineEmits<{ changed: [] }>()

const loading = ref(false)
const actionLoading = ref(false)
const roster = ref<PoliceRosterRow[]>([])
const history = ref<PoliceMembershipHistoryRow[]>([])
const activeTab = ref('current')
const selectedOfficerId = ref<number | null>(null)
const selectedRole = ref<'member' | 'deputy_leader'>('member')

const availableOfficers = computed(() => {
  const existing = new Set(roster.value.map((row) => row.officer_id))
  return props.officers.filter((officer) => !existing.has(officer.id))
})

const roleLabels: Record<string, string> = {
  leader: '组长',
  deputy_leader: '副组长',
  member: '成员',
}

async function load() {
  if (!props.team) return
  loading.value = true
  try {
    const [currentRows, historyRows] = await Promise.all([
      listPoliceTeamRoster(props.team.team_id),
      listPoliceTeamMemberHistory(props.team.team_id),
    ])
    roster.value = currentRows
    history.value = historyRows
    if (!availableOfficers.value.some((officer) => officer.id === selectedOfficerId.value)) {
      selectedOfficerId.value = null
    }
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    loading.value = false
  }
}

watch(visible, (open) => {
  if (!open) return
  activeTab.value = 'current'
  selectedOfficerId.value = null
  selectedRole.value = 'member'
  load()
})

async function addMember() {
  if (!props.team || selectedOfficerId.value === null) {
    ElMessage.warning('请选择要加入编组的警员')
    return
  }
  actionLoading.value = true
  try {
    await addPoliceTeamMember(props.team.team_id, selectedOfficerId.value, selectedRole.value)
    ElMessage.success('成员添加成功')
    selectedOfficerId.value = null
    await load()
    emit('changed')
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    actionLoading.value = false
  }
}

async function setLeader(row: PoliceRosterRow) {
  if (!props.team || row.member_role === 'leader') return
  await ElMessageBox.confirm(`确认将「${row.officer_name}」设置为组长？原组长将转为普通成员。`, '更换组长', {
    type: 'warning',
  })
  actionLoading.value = true
  try {
    await assignPoliceTeamLeader(props.team.team_id, row.officer_id)
    ElMessage.success('组长更换成功')
    await load()
    emit('changed')
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    actionLoading.value = false
  }
}

async function changeRole(row: PoliceRosterRow, role: 'member' | 'deputy_leader') {
  if (row.member_role === 'leader' || row.member_role === role) return
  actionLoading.value = true
  try {
    await updatePoliceTeamMemberRole(row.membership_id, role)
    ElMessage.success('成员角色更新成功')
    await load()
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    actionLoading.value = false
  }
}

async function leaveTeam(row: PoliceRosterRow) {
  if (row.member_role === 'leader') {
    ElMessage.warning('请先更换组长，再办理原组长离组')
    return
  }
  await ElMessageBox.confirm(`确认让「${row.officer_name}」离开当前编组？任职历史会保留。`, '成员离组', {
    type: 'warning',
  })
  actionLoading.value = true
  try {
    await removePoliceTeamMember(row.membership_id)
    ElMessage.success('成员已离组')
    await load()
    emit('changed')
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    actionLoading.value = false
  }
}

function formatTime(value: string | null) {
  return value ? new Date(value).toLocaleString('zh-CN') : '至今'
}
</script>

<template>
  <el-drawer v-model="visible" :title="team ? `成员管理 · ${team.team_name}` : '成员管理'" size="760px">
    <el-descriptions v-if="team" :column="3" border class="team-summary">
      <el-descriptions-item label="编组编码">{{ team.team_code }}</el-descriptions-item>
      <el-descriptions-item label="警务站">{{ team.station_name ?? '未挂载' }}</el-descriptions-item>
      <el-descriptions-item label="当前组长">{{ team.leader_name ?? '未设置' }}</el-descriptions-item>
    </el-descriptions>

    <el-tabs v-model="activeTab">
      <el-tab-pane label="当前成员" name="current">
        <div class="member-toolbar">
          <el-select v-model="selectedOfficerId" filterable placeholder="选择警员" style="min-width: 260px">
            <el-option
              v-for="officer in availableOfficers"
              :key="officer.id"
              :label="`${officer.name}（${officer.officer_no}）`"
              :value="officer.id"
            />
          </el-select>
          <el-select v-model="selectedRole" style="width: 120px">
            <el-option label="普通成员" value="member" />
            <el-option label="副组长" value="deputy_leader" />
          </el-select>
          <el-button type="primary" :loading="actionLoading" @click="addMember">添加成员</el-button>
        </div>

        <el-table v-loading="loading" :data="roster" stripe>
          <el-table-column prop="officer_no" label="警号" width="150" />
          <el-table-column prop="officer_name" label="姓名" width="110" />
          <el-table-column label="角色" width="105">
            <template #default="{ row }">
              <el-tag :type="row.member_role === 'leader' ? 'danger' : row.member_role === 'deputy_leader' ? 'warning' : 'info'">
                {{ roleLabels[row.member_role] }}
              </el-tag>
            </template>
          </el-table-column>
          <el-table-column prop="organization_name" label="所属单位" min-width="180" show-overflow-tooltip />
          <el-table-column prop="contact_phone" label="联系电话" width="135" />
          <el-table-column label="操作" width="240" fixed="right">
            <template #default="{ row }">
              <el-button v-if="row.member_role !== 'leader'" text type="primary" @click="setLeader(row)">设为组长</el-button>
              <el-dropdown v-if="row.member_role !== 'leader'" trigger="click" @command="changeRole(row, $event)">
                <el-button text type="primary">调整角色</el-button>
                <template #dropdown>
                  <el-dropdown-menu>
                    <el-dropdown-item command="member">普通成员</el-dropdown-item>
                    <el-dropdown-item command="deputy_leader">副组长</el-dropdown-item>
                  </el-dropdown-menu>
                </template>
              </el-dropdown>
              <el-button text type="danger" @click="leaveTeam(row)">离组</el-button>
            </template>
          </el-table-column>
        </el-table>
      </el-tab-pane>

      <el-tab-pane label="任职历史" name="history">
        <el-table v-loading="loading" :data="history" stripe>
          <el-table-column prop="officer_no" label="警号" width="150" />
          <el-table-column prop="officer_name" label="姓名" width="110" />
          <el-table-column label="角色" width="100">
            <template #default="{ row }">{{ roleLabels[row.member_role] }}</template>
          </el-table-column>
          <el-table-column label="加入时间" min-width="170">
            <template #default="{ row }">{{ formatTime(row.joined_at) }}</template>
          </el-table-column>
          <el-table-column label="离组时间" min-width="170">
            <template #default="{ row }">{{ formatTime(row.left_at) }}</template>
          </el-table-column>
        </el-table>
      </el-tab-pane>
    </el-tabs>
  </el-drawer>
</template>

<style scoped>
.team-summary { margin-bottom: 16px; }
.member-toolbar { display: flex; flex-wrap: wrap; gap: 10px; margin-bottom: 14px; }
</style>
