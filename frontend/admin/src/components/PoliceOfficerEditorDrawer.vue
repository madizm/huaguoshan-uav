<script setup lang="ts">
import { computed, reactive, ref, watch } from 'vue'
import { ElMessage, type FormInstance, type FormRules } from 'element-plus'
import {
  createPoliceOfficer,
  updatePoliceOfficer,
  type PoliceAvailabilityStatus,
  type PoliceOfficer,
} from '../api/police'

const visible = defineModel<boolean>({ required: true })
const props = defineProps<{ officer: PoliceOfficer | null }>()
const emit = defineEmits<{ saved: [] }>()

const formRef = ref<FormInstance>()
const saving = ref(false)
const form = reactive({
  officer_no: '',
  name: '',
  contact_phone: '',
  organization_name: '',
  availability_status: 'available' as PoliceAvailabilityStatus,
  is_active: true,
  is_simulated: false,
})
const isEdit = computed(() => props.officer !== null)
const rules: FormRules = {
  officer_no: [{ required: true, message: '请输入警号', trigger: 'blur' }],
  name: [{ required: true, message: '请输入姓名', trigger: 'blur' }],
}

const statusOptions: Array<{ value: PoliceAvailabilityStatus; label: string }> = [
  { value: 'available', label: '可用' },
  { value: 'on_duty', label: '值勤' },
  { value: 'dispatched', label: '已出动' },
  { value: 'leave', label: '请假' },
  { value: 'unavailable', label: '不可用' },
]

watch(visible, (open) => {
  if (!open) return
  Object.assign(form, {
    officer_no: props.officer?.officer_no ?? '',
    name: props.officer?.name ?? '',
    contact_phone: props.officer?.contact_phone ?? '',
    organization_name: props.officer?.organization_name ?? '',
    availability_status: props.officer?.availability_status ?? 'available',
    is_active: props.officer?.is_active ?? true,
    is_simulated: props.officer?.is_simulated ?? false,
  })
})

async function save() {
  await formRef.value?.validate()
  const payload = {
    officer_no: form.officer_no.trim(),
    name: form.name.trim(),
    contact_phone: form.contact_phone.trim() || null,
    organization_name: form.organization_name.trim() || null,
    availability_status: form.availability_status,
    is_active: form.is_active,
    is_simulated: form.is_simulated,
    metadata: props.officer?.metadata ?? {},
  }
  saving.value = true
  try {
    if (props.officer) await updatePoliceOfficer(props.officer.id, payload)
    else await createPoliceOfficer(payload)
    ElMessage.success('警员档案保存成功')
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
  <el-drawer v-model="visible" :title="isEdit ? '编辑警员' : '新增警员'" size="520px">
    <el-form ref="formRef" :model="form" :rules="rules" label-width="110px">
      <el-form-item label="警号" prop="officer_no">
        <el-input v-model="form.officer_no" :disabled="isEdit" maxlength="50" />
      </el-form-item>
      <el-form-item label="姓名" prop="name">
        <el-input v-model="form.name" maxlength="50" />
      </el-form-item>
      <el-form-item label="联系电话">
        <el-input v-model="form.contact_phone" maxlength="50" />
      </el-form-item>
      <el-form-item label="所属单位">
        <el-input v-model="form.organization_name" maxlength="200" />
      </el-form-item>
      <el-form-item label="可用状态">
        <el-select v-model="form.availability_status" style="width: 100%">
          <el-option v-for="option in statusOptions" :key="option.value" :label="option.label" :value="option.value" />
        </el-select>
      </el-form-item>
      <el-form-item label="档案状态">
        <el-switch v-model="form.is_active" active-text="有效" inactive-text="停用" />
      </el-form-item>
      <el-form-item label="数据类型">
        <el-switch v-model="form.is_simulated" active-text="模拟" inactive-text="真实" />
      </el-form-item>
      <el-alert title="停用警员不会删除其历史编组记录，也不能被设置为新组长。" type="info" :closable="false" />
      <div class="drawer-footer">
        <el-button @click="visible = false">取消</el-button>
        <el-button type="primary" :loading="saving" @click="save">保存</el-button>
      </div>
    </el-form>
  </el-drawer>
</template>

<style scoped>
.drawer-footer { display: flex; justify-content: flex-end; gap: 12px; margin-top: 24px; }
</style>
