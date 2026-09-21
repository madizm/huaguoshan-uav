<script setup lang="ts">
import { computed, reactive, ref, watch } from 'vue'
import { ElMessage, type FormInstance, type FormRules } from 'element-plus'
import {
  assignPoliceTeamLeader,
  createPoliceTeam,
  updatePoliceTeam,
  type PoliceOfficer,
  type PoliceStationOption,
  type PoliceTeamDetails,
  type PoliceTeamStatus,
} from '../api/police'

const visible = defineModel<boolean>({ required: true })
const props = defineProps<{
  team: PoliceTeamDetails | null
  stations: PoliceStationOption[]
  officers: PoliceOfficer[]
}>()
const emit = defineEmits<{ saved: [] }>()

const formRef = ref<FormInstance>()
const saving = ref(false)
const form = reactive({
  team_code: '',
  name: '',
  station_id: null as number | null,
  leader_officer_id: null as number | null,
  team_status: 'active' as PoliceTeamStatus,
  description: '',
  is_simulated: false,
})
const isEdit = computed(() => props.team !== null)
const rules: FormRules = {
  team_code: [{ required: true, message: '请输入编组编码', trigger: 'blur' }],
  name: [{ required: true, message: '请输入编组名称', trigger: 'blur' }],
  leader_officer_id: [{ required: true, message: '请选择组长', trigger: 'change' }],
}

const statusOptions: Array<{ value: PoliceTeamStatus; label: string }> = [
  { value: 'active', label: '正常' },
  { value: 'standby', label: '待命' },
  { value: 'dispatched', label: '已出动' },
  { value: 'inactive', label: '停用' },
]

watch(visible, (open) => {
  if (!open) return
  Object.assign(form, {
    team_code: props.team?.team_code ?? '',
    name: props.team?.team_name ?? '',
    station_id: props.team?.station_id ?? null,
    leader_officer_id: props.team?.leader_officer_id ?? null,
    team_status: props.team?.team_status ?? 'active',
    description: props.team?.description ?? '',
    is_simulated: props.team?.is_simulated ?? false,
  })
})

async function save() {
  await formRef.value?.validate()
  if (form.leader_officer_id === null) return
  saving.value = true
  try {
    if (props.team) {
      await updatePoliceTeam(props.team.team_id, {
        name: form.name.trim(),
        station_id: form.station_id,
        team_status: form.team_status,
        description: form.description.trim() || null,
        is_simulated: form.is_simulated,
      })
      if (form.leader_officer_id !== props.team.leader_officer_id) {
        await assignPoliceTeamLeader(props.team.team_id, form.leader_officer_id)
      }
    } else {
      await createPoliceTeam({
        teamCode: form.team_code.trim(),
        name: form.name.trim(),
        leaderOfficerId: form.leader_officer_id,
        stationId: form.station_id,
        status: form.team_status,
        description: form.description.trim() || null,
        isSimulated: form.is_simulated,
      })
    }
    ElMessage.success('警务编组保存成功')
    visible.value = false
    emit('saved')
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    saving.value = false
  }
}
</script>

<template>
  <el-drawer v-model="visible" :title="isEdit ? '编辑警务编组' : '新增警务编组'" size="560px">
    <el-form ref="formRef" :model="form" :rules="rules" label-width="110px">
      <el-form-item label="编组编码" prop="team_code">
        <el-input v-model="form.team_code" :disabled="isEdit" maxlength="80" />
      </el-form-item>
      <el-form-item label="编组名称" prop="name">
        <el-input v-model="form.name" maxlength="100" />
      </el-form-item>
      <el-form-item label="挂载警务站">
        <el-select v-model="form.station_id" clearable filterable style="width: 100%" placeholder="暂不挂载">
          <el-option
            v-for="station in stations"
            :key="station.id"
            :label="station.name"
            :value="station.id"
          >
            <span>{{ station.name }}</span>
            <small class="station-county">{{ station.county_name ?? '' }}</small>
          </el-option>
        </el-select>
      </el-form-item>
      <el-form-item label="组长" prop="leader_officer_id">
        <el-select v-model="form.leader_officer_id" filterable style="width: 100%" placeholder="按姓名或警号选择">
          <el-option
            v-for="officer in officers"
            :key="officer.id"
            :label="`${officer.name}（${officer.officer_no}）`"
            :value="officer.id"
          />
        </el-select>
      </el-form-item>
      <el-form-item label="编组状态">
        <el-select v-model="form.team_status" style="width: 100%">
          <el-option v-for="option in statusOptions" :key="option.value" :label="option.label" :value="option.value" />
        </el-select>
      </el-form-item>
      <el-form-item label="说明">
        <el-input v-model="form.description" type="textarea" :rows="3" maxlength="500" show-word-limit />
      </el-form-item>
      <el-form-item label="数据类型">
        <el-switch v-model="form.is_simulated" active-text="模拟" inactive-text="真实" />
      </el-form-item>
      <div class="drawer-footer">
        <el-button @click="visible = false">取消</el-button>
        <el-button type="primary" :loading="saving" @click="save">保存</el-button>
      </div>
    </el-form>
  </el-drawer>
</template>

<style scoped>
.station-county { float: right; margin-left: 16px; color: #909399; }
.drawer-footer { display: flex; justify-content: flex-end; gap: 12px; margin-top: 24px; }
</style>
