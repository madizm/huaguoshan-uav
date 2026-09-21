<script setup lang="ts">
import { onMounted, reactive, ref } from 'vue'
import { Edit, Plus, Refresh } from '@element-plus/icons-vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import type { FormInstance, FormRules, TagProps } from 'element-plus'
import {
  createDetectionMethod,
  listDetectionMethodMappings,
  listDetectionMethodMappingHistory,
  listDetectionMethods,
  updateDetectionMethod,
  upsertDetectionMethodMapping,
  type DetectionMethod,
  type DetectionMethodLifecycle,
  type DetectionMethodMapping,
  type DetectionMethodMappingHistory,
} from '../api/detection'

const methods = ref<DetectionMethod[]>([])
const mappings = ref<DetectionMethodMapping[]>([])
const mappingHistory = ref<DetectionMethodMappingHistory[]>([])
const loading = ref(false)
const savingMethod = ref(false)
const savingMapping = ref(false)
const methodDrawerVisible = ref(false)
const mappingDrawerVisible = ref(false)
const editingMethod = ref<DetectionMethod | null>(null)
const editingMapping = ref<DetectionMethodMapping | null>(null)
const methodFormRef = ref<FormInstance>()
const mappingFormRef = ref<FormInstance>()

const methodForm = reactive({
  code: '',
  name: '',
  description: '',
  lifecycleStatus: 'active' as DetectionMethodLifecycle,
  visible: true,
  sortOrder: 0,
})
const mappingForm = reactive({
  sourceSystem: '',
  vendorCode: '',
  methodCode: '',
  acceptIngest: true,
})

const methodRules: FormRules = {
  code: [
    { required: true, message: '请输入稳定编码', trigger: 'blur' },
    { pattern: /^[a-z][a-z0-9_]*$/, message: '只能使用小写字母、数字和下划线', trigger: 'blur' },
  ],
  name: [{ required: true, message: '请输入侦测方式名称', trigger: 'blur' }],
}
const mappingRules: FormRules = {
  sourceSystem: [{ required: true, message: '请输入来源系统编码', trigger: 'blur' }],
  vendorCode: [{ required: true, message: '请输入厂商原始编码', trigger: 'blur' }],
  methodCode: [{ required: true, message: '请选择平台侦测方式', trigger: 'change' }],
}

function statusType(status: DetectionMethodLifecycle): TagProps['type'] {
  return status === 'active' ? 'success' : 'info'
}

async function load() {
  loading.value = true
  try {
    ;[methods.value, mappings.value, mappingHistory.value] = await Promise.all([
      listDetectionMethods(),
      listDetectionMethodMappings(),
      listDetectionMethodMappingHistory(),
    ])
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    loading.value = false
  }
}

function openCreateMethod() {
  editingMethod.value = null
  Object.assign(methodForm, {
    code: '', name: '', description: '', lifecycleStatus: 'active', visible: true, sortOrder: 0,
  })
  methodDrawerVisible.value = true
}

function openEditMethod(method: DetectionMethod) {
  editingMethod.value = method
  Object.assign(methodForm, {
    code: method.code,
    name: method.name,
    description: method.description ?? '',
    lifecycleStatus: method.lifecycle_status,
    visible: method.visible,
    sortOrder: method.sort_order,
  })
  methodDrawerVisible.value = true
}

async function saveMethod() {
  await methodFormRef.value?.validate()
  if (editingMethod.value?.lifecycle_status === 'active' && methodForm.lifecycleStatus === 'deprecated') {
    await ElMessageBox.confirm(
      '停用后不能再为该方式新增厂商映射，但历史观测仍可查询。确认停用？',
      '停用侦测方式',
      { type: 'warning', confirmButtonText: '确认停用' },
    )
  }
  savingMethod.value = true
  try {
    if (editingMethod.value) {
      await updateDetectionMethod(editingMethod.value.code, {
        name: methodForm.name,
        description: methodForm.description || null,
        lifecycle_status: methodForm.lifecycleStatus,
        visible: methodForm.visible,
        sort_order: methodForm.sortOrder,
      })
    } else {
      await createDetectionMethod({
        code: methodForm.code,
        name: methodForm.name,
        description: methodForm.description || null,
        visible: methodForm.visible,
        sortOrder: methodForm.sortOrder,
      })
    }
    ElMessage.success('侦测方式已保存')
    methodDrawerVisible.value = false
    await load()
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    savingMethod.value = false
  }
}

function openCreateMapping() {
  editingMapping.value = null
  Object.assign(mappingForm, { sourceSystem: '', vendorCode: '', methodCode: '', acceptIngest: true })
  mappingDrawerVisible.value = true
}

function openEditMapping(mapping: DetectionMethodMapping) {
  editingMapping.value = mapping
  Object.assign(mappingForm, {
    sourceSystem: mapping.source_system,
    vendorCode: mapping.vendor_code,
    methodCode: mapping.method_code,
    acceptIngest: mapping.accept_ingest,
  })
  mappingDrawerVisible.value = true
}

async function saveMapping() {
  await mappingFormRef.value?.validate()
  if (editingMapping.value?.accept_ingest && !mappingForm.acceptIngest) {
    await ElMessageBox.confirm(
      '停止接入后，该来源系统使用此厂商编码的新观测将被拒绝。确认停止？',
      '停止厂商类型接入',
      { type: 'warning', confirmButtonText: '确认停止' },
    )
  }
  savingMapping.value = true
  try {
    await upsertDetectionMethodMapping(mappingForm)
    ElMessage.success('厂商编码映射已保存')
    mappingDrawerVisible.value = false
    await load()
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    savingMapping.value = false
  }
}

onMounted(load)
</script>

<template>
  <section class="method-manager">
    <div class="section-heading">
      <div>
        <h3>平台侦测方式</h3>
        <p>稳定编码创建后不可修改；停用不会删除历史观测。</p>
      </div>
      <div>
        <el-button :icon="Refresh" :loading="loading" @click="load">刷新</el-button>
        <el-button type="primary" :icon="Plus" @click="openCreateMethod">新增侦测方式</el-button>
      </div>
    </div>

    <el-table v-loading="loading" :data="methods" border>
      <el-table-column prop="code" label="稳定编码" min-width="160" />
      <el-table-column prop="name" label="名称" min-width="130" />
      <el-table-column prop="description" label="说明" min-width="240" show-overflow-tooltip />
      <el-table-column label="生命周期" width="110">
        <template #default="{ row }">
          <el-tag :type="statusType(row.lifecycle_status)">
            {{ row.lifecycle_status === 'active' ? '使用中' : '已停用' }}
          </el-tag>
        </template>
      </el-table-column>
      <el-table-column label="筛选器展示" width="110">
        <template #default="{ row }">{{ row.visible ? '显示' : '隐藏' }}</template>
      </el-table-column>
      <el-table-column prop="observation_count" label="观测引用" width="100" />
      <el-table-column prop="sort_order" label="排序" width="80" />
      <el-table-column label="操作" width="90">
        <template #default="{ row }">
          <el-button text type="primary" :icon="Edit" @click="openEditMethod(row)">配置</el-button>
        </template>
      </el-table-column>
    </el-table>

    <div class="section-heading mapping-heading">
      <div>
        <h3>厂商编码映射</h3>
        <p>同一厂商编码在不同来源系统下可以映射为不同的平台侦测方式。</p>
      </div>
      <el-button type="primary" plain :icon="Plus" @click="openCreateMapping">新增映射</el-button>
    </div>

    <el-table v-loading="loading" :data="mappings" border>
      <el-table-column prop="source_system" label="来源系统" min-width="160" />
      <el-table-column prop="vendor_code" label="厂商编码" min-width="130" />
      <el-table-column label="平台侦测方式" min-width="190">
        <template #default="{ row }">{{ row.method_name }}（{{ row.method_code }}）</template>
      </el-table-column>
      <el-table-column label="接入状态" width="110">
        <template #default="{ row }">
          <el-tag :type="row.accept_ingest ? 'success' : 'danger'">
            {{ row.accept_ingest ? '允许接入' : '停止接入' }}
          </el-tag>
        </template>
      </el-table-column>
      <el-table-column label="操作" width="90">
        <template #default="{ row }">
          <el-button text type="primary" :icon="Edit" @click="openEditMapping(row)">配置</el-button>
        </template>
      </el-table-column>
    </el-table>

    <div class="section-heading mapping-heading">
      <div>
        <h3>最近映射变更</h3>
        <p>保留最近 100 条追加式审计记录，厂商编码映射不提供直接删除。</p>
      </div>
    </div>
    <el-table v-loading="loading" :data="mappingHistory" border max-height="360">
      <el-table-column prop="changed_at" label="变更时间" min-width="175">
        <template #default="{ row }">{{ new Date(row.changed_at).toLocaleString('zh-CN', { hour12: false }) }}</template>
      </el-table-column>
      <el-table-column prop="source_system" label="来源系统" min-width="140" />
      <el-table-column prop="vendor_code" label="厂商编码" min-width="110" />
      <el-table-column label="侦测方式" min-width="210">
        <template #default="{ row }">{{ row.old_method_code || '新建' }} → {{ row.new_method_code }}</template>
      </el-table-column>
      <el-table-column label="接入状态" min-width="150">
        <template #default="{ row }">
          {{ row.old_accept_ingest === null ? '新建' : (row.old_accept_ingest ? '允许' : '停止') }}
          → {{ row.new_accept_ingest ? '允许' : '停止' }}
        </template>
      </el-table-column>
      <el-table-column prop="changed_by" label="变更主体" min-width="130" />
    </el-table>

    <el-drawer v-model="methodDrawerVisible" :title="editingMethod ? '配置侦测方式' : '新增侦测方式'" size="480px" destroy-on-close>
      <el-form ref="methodFormRef" :model="methodForm" :rules="methodRules" label-width="110px">
        <el-form-item label="稳定编码" prop="code">
          <el-input v-model="methodForm.code" :disabled="Boolean(editingMethod)" placeholder="例如 acoustic_detection" />
          <div class="field-help">编码将用于接口和数据关联，创建后不可修改。</div>
        </el-form-item>
        <el-form-item label="名称" prop="name"><el-input v-model="methodForm.name" /></el-form-item>
        <el-form-item label="说明"><el-input v-model="methodForm.description" type="textarea" :rows="3" /></el-form-item>
        <el-form-item v-if="editingMethod" label="生命周期">
          <el-radio-group v-model="methodForm.lifecycleStatus">
            <el-radio-button value="active">使用中</el-radio-button>
            <el-radio-button value="deprecated">已停用</el-radio-button>
          </el-radio-group>
        </el-form-item>
        <el-form-item label="筛选器展示"><el-switch v-model="methodForm.visible" /></el-form-item>
        <el-form-item label="展示顺序"><el-input-number v-model="methodForm.sortOrder" :min="0" /></el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="methodDrawerVisible = false">取消</el-button>
        <el-button type="primary" :loading="savingMethod" @click="saveMethod">保存</el-button>
      </template>
    </el-drawer>

    <el-drawer v-model="mappingDrawerVisible" :title="editingMapping ? '配置厂商编码映射' : '新增厂商编码映射'" size="480px" destroy-on-close>
      <el-form ref="mappingFormRef" :model="mappingForm" :rules="mappingRules" label-width="110px">
        <el-form-item label="来源系统" prop="sourceSystem">
          <el-input v-model="mappingForm.sourceSystem" :disabled="Boolean(editingMapping)" placeholder="例如 radar_cloud" />
        </el-form-item>
        <el-form-item label="厂商编码" prop="vendorCode">
          <el-input v-model="mappingForm.vendorCode" :disabled="Boolean(editingMapping)" placeholder="数值或字符串编码" />
        </el-form-item>
        <el-form-item label="侦测方式" prop="methodCode">
          <el-select v-model="mappingForm.methodCode" filterable style="width: 100%">
            <el-option
              v-for="method in methods.filter((item) => item.lifecycle_status === 'active')"
              :key="method.code"
              :label="`${method.name}（${method.code}）`"
              :value="method.code"
            />
          </el-select>
        </el-form-item>
        <el-form-item label="允许接入"><el-switch v-model="mappingForm.acceptIngest" /></el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="mappingDrawerVisible = false">取消</el-button>
        <el-button type="primary" :loading="savingMapping" @click="saveMapping">保存</el-button>
      </template>
    </el-drawer>
  </section>
</template>

<style scoped>
.method-manager {
  margin-top: 28px;
}
.section-heading {
  display: flex;
  align-items: flex-end;
  justify-content: space-between;
  gap: 20px;
  margin-bottom: 14px;
}
.section-heading h3 {
  margin: 0 0 4px;
  font-size: 17px;
}
.section-heading p,
.field-help {
  margin: 0;
  color: #78827d;
  font-size: 12px;
}
.mapping-heading {
  margin-top: 28px;
}
.field-help {
  padding-top: 5px;
  line-height: 1.5;
}
@media (max-width: 760px) {
  .section-heading {
    align-items: flex-start;
    flex-direction: column;
  }
}
</style>
