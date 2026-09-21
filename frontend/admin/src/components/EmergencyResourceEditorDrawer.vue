<script setup lang="ts">
import { computed, defineAsyncComponent, reactive, ref, watch } from 'vue'
import { ElMessage } from 'element-plus'
import type { FormInstance, FormRules } from 'element-plus'
import { createEmergencyResource, updateEmergencyResource, type EmergencyResourceRow } from '../api/emergency'
import { emergencyResourceForms, emergencyResourceLabels } from '../emergencyResourceForms'
const EmergencyLocationMapDialog = defineAsyncComponent(() => import('./EmergencyLocationMapDialog.vue'))

const visible = defineModel<boolean>({ required: true })
const props = defineProps<{ resource: EmergencyResourceRow | null; category: string }>()
const emit = defineEmits<{ saved: [] }>()
const formRef = ref<FormInstance>()
const saving = ref(false)
const locationVisible = ref(false)
const details = reactive<Record<string, unknown>>({})
const form = reactive({ category_code: '', source_code: '', name: '', contact_phone: '', availability_status: 'available', is_simulated: false, longitude: null as number | null, latitude: null as number | null })
const definition = computed(() => emergencyResourceForms[form.category_code])
const isEdit = computed(() => !!props.resource)
const rules: FormRules = { category_code: [{ required: true, message: '请选择类别' }], source_code: [{ required: true, message: '请输入来源编码' }], name: [{ required: true, message: '请输入名称' }], longitude: [{ required: true, message: '请输入经度' }], latitude: [{ required: true, message: '请输入纬度' }] }

watch(visible, (open) => {
  if (!open) return
  Object.assign(form, { category_code: props.resource?.category_code ?? props.category, source_code: props.resource?.source_code ?? '', name: props.resource?.name ?? '', contact_phone: props.resource?.contact_phone ?? '', availability_status: props.resource?.availability_status ?? 'available', is_simulated: props.resource?.is_simulated ?? false, longitude: props.resource?.longitude ?? null, latitude: props.resource?.latitude ?? null })
  for (const key of Object.keys(details)) delete details[key]
  Object.assign(details, props.resource?.details ?? {})
  if (props.resource?.managing_unit_name) details[form.category_code === 'medical_resource' ? 'unit_name' : form.category_code === 'expert_force' ? 'organization_name' : 'managing_unit_name'] = props.resource.managing_unit_name
})
function changeCategory() { for (const key of Object.keys(details)) delete details[key]; form.availability_status = definition.value?.statuses[0] ?? 'available' }
function text(key: string) { const value = details[key]; return value == null ? '' : typeof value === 'object' ? JSON.stringify(value) : String(value) }
function set(key: string, value: unknown) { details[key] = value === '' ? null : value }
async function save() {
  await formRef.value?.validate()
  const payload: Record<string, unknown> = { ...details, source_code: form.source_code, name: form.name, contact_phone: form.contact_phone || null, availability_status: form.availability_status, is_simulated: form.is_simulated, metadata: props.resource?.details.metadata ?? {}, geom: `SRID=4326;POINT(${form.longitude} ${form.latitude})` }
  for (const field of definition.value?.fields ?? []) {
    if (field.required && !details[field.key]) { ElMessage.warning(`请填写${field.label}`); return }
    if (field.kind === 'json' && typeof details[field.key] === 'string') { try { payload[field.key] = JSON.parse(details[field.key] as string) } catch { ElMessage.error(`${field.label}不是有效 JSON`); return } }
  }
  saving.value = true
  try { if (props.resource) await updateEmergencyResource(form.category_code, props.resource.resource_id, payload); else await createEmergencyResource(form.category_code, payload); ElMessage.success('保存成功'); visible.value = false; emit('saved') } catch (error) { ElMessage.error((error as Error).message) } finally { saving.value = false }
}
</script>
<template>
  <el-drawer v-model="visible" :title="isEdit ? '编辑应急资源' : '新增应急资源'" size="520px">
    <el-form ref="formRef" :model="form" :rules="rules" label-width="120px">
      <el-form-item label="资源类别" prop="category_code"><el-select v-model="form.category_code" :disabled="isEdit" style="width:100%" @change="changeCategory"><el-option v-for="(_, code) in emergencyResourceForms" :key="code" :label="emergencyResourceLabels[code]" :value="code" /></el-select></el-form-item>
      <el-form-item label="来源编码" prop="source_code"><el-input v-model="form.source_code" :disabled="isEdit" /></el-form-item>
      <el-form-item label="名称" prop="name"><el-input v-model="form.name" /></el-form-item>
      <el-form-item label="联系电话"><el-input v-model="form.contact_phone" /></el-form-item>
      <el-form-item label="可用状态"><el-select v-model="form.availability_status" style="width:100%"><el-option v-for="status in definition?.statuses" :key="status" :label="status" :value="status" /></el-select></el-form-item>
      <el-form-item v-for="field in definition?.fields" :key="field.key" :label="field.label" :required="field.required"><el-input v-if="field.kind !== 'number'" :model-value="text(field.key)" :type="field.kind === 'json' ? 'textarea' : 'text'" @update:model-value="set(field.key, $event)" /><el-input-number v-else :model-value="typeof details[field.key] === 'number' ? details[field.key] as number : null" :min="field.min" style="width:100%" @update:model-value="set(field.key, $event)" /></el-form-item>
      <el-form-item label="经度" prop="longitude"><el-input-number v-model="form.longitude" :min="-180" :max="180" :precision="6" style="width:100%" /></el-form-item>
      <el-form-item label="纬度" prop="latitude"><el-input-number v-model="form.latitude" :min="-90" :max="90" :precision="6" style="width:100%" /></el-form-item>
      <el-form-item label="地图选点"><el-button type="primary" plain @click="locationVisible = true">打开地图选点</el-button></el-form-item>
      <el-form-item label="数据类型"><el-switch v-model="form.is_simulated" active-text="模拟" inactive-text="真实" /></el-form-item>
      <div class="footer"><el-button @click="visible = false">取消</el-button><el-button type="primary" :loading="saving" @click="save">保存</el-button></div>
    </el-form>
    <EmergencyLocationMapDialog v-model:visible="locationVisible" v-model:longitude="form.longitude" v-model:latitude="form.latitude" />
  </el-drawer>
</template>
<style scoped>.footer{display:flex;justify-content:flex-end;gap:12px;margin-top:24px}</style>
