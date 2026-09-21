<script setup lang="ts">
import { onMounted, reactive, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { deleteEmergencyResource, listEmergencyResources, listHistoricalRescueForces, type EmergencyResourceRow } from '../api/emergency'
import EmergencyResourceEditorDrawer from '../components/EmergencyResourceEditorDrawer.vue'
const labels: Record<string,string>={medical_resource:'医疗资源',expert_force:'专家力量',shelter:'避难场所',material_warehouse:'物资仓库',water_point:'取水点',landing_site:'起降点',police_station:'智慧警务站',equipment_resource:'可调度设备'}
const rows=ref<EmergencyResourceRow[]>([]),historyRows=ref<Record<string,unknown>[]>([]),total=ref(0),loading=ref(false),editorVisible=ref(false),editing=ref<EmergencyResourceRow|null>(null)
const activeTab=ref('active')
const filters=reactive({category:'',keyword:''}),page=reactive({current:1,size:20})
async function load(){loading.value=true;try{const r=await listEmergencyResources({category:filters.category||undefined,keyword:filters.keyword||undefined,limit:page.size,offset:(page.current-1)*page.size});rows.value=r.rows;total.value=r.total}catch(e){ElMessage.error((e as Error).message)}finally{loading.value=false}}
async function loadHistory(){try{historyRows.value=await listHistoricalRescueForces() as Record<string,unknown>[]}catch(e){ElMessage.error((e as Error).message)}}
function tabChanged(name: string | number) { if (name === 'history') loadHistory() }
function search(){page.current=1;load()}function createResource(){editing.value=null;editorVisible.value=true}function editResource(row:EmergencyResourceRow){editing.value=row;editorVisible.value=true}
async function removeResource(row: EmergencyResourceRow) {
  await ElMessageBox.confirm(`确认永久删除「${row.name}」？删除后不可恢复。`, '删除应急资源', { type: 'warning', confirmButtonText: '删除', cancelButtonText: '取消' })
  try {
    await deleteEmergencyResource(row.category_code, row.resource_id)
    ElMessage.success('删除成功')
    if (rows.value.length === 1 && page.current > 1) page.current -= 1
    await load()
  } catch (error) { ElMessage.error((error as Error).message) }
}
onMounted(load)
</script>
<template>
<section><el-tabs v-model="activeTab" @tab-change="tabChanged"><el-tab-pane label="正式资源" name="active"><div class="page-toolbar"><el-select v-model="filters.category" clearable placeholder="全部类别" style="width:180px" @change="search"><el-option v-for="(label,code) in labels" :key="code" :label="label" :value="code"/></el-select><el-input v-model="filters.keyword" placeholder="编码 / 名称" clearable style="width:240px" @keyup.enter="search" @clear="search"/><el-button type="primary" @click="search">查询</el-button><div class="page-toolbar-spacer"/><el-button type="primary" @click="createResource">新增资源</el-button></div><div class="table-shell"><el-table v-loading="loading" :data="rows" stripe><el-table-column label="类别" width="120"><template #default="{row}">{{labels[row.category_code]}}</template></el-table-column><el-table-column prop="source_code" label="来源编码" width="180"/><el-table-column prop="name" label="名称" min-width="190"/><el-table-column prop="managing_unit_name" label="管理单位" min-width="170"/><el-table-column prop="contact_phone" label="联系电话" width="140"/><el-table-column prop="availability_status" label="可用状态" width="110"/><el-table-column label="数据类型" width="90"><template #default="{row}"><el-tag :type="row.is_simulated?'warning':'success'">{{row.is_simulated?'模拟':'真实'}}</el-tag></template></el-table-column><el-table-column label="操作" width="150"><template #default="{row}"><div v-if="row.category_code!=='equipment_resource'" class="action-buttons"><el-button text type="primary" @click="editResource(row)">编辑</el-button><el-button text type="danger" @click="removeResource(row)">删除</el-button></div><span v-else>设备页维护</span></template></el-table-column></el-table></div><el-pagination v-model:current-page="page.current" v-model:page-size="page.size" :total="total" :page-sizes="[20,50,100]" layout="total, sizes, prev, pager, next" class="page-pagination" @current-change="load" @size-change="search"/></el-tab-pane><el-tab-pane label="历史救援队伍" name="history"><el-alert title="历史类别，停止维护，仅保留查询。" type="info" :closable="false" class="history-alert"/><el-table :data="historyRows" stripe><el-table-column prop="source_code" label="来源编码" width="180"/><el-table-column prop="name" label="名称" min-width="190"/><el-table-column prop="force_type" label="力量类型" width="130"/><el-table-column prop="unit_name" label="所属单位" min-width="180"/><el-table-column prop="commander_name" label="负责人" width="110"/><el-table-column prop="contact_phone" label="联系电话" width="140"/><el-table-column prop="availability_status" label="状态" width="110"/></el-table></el-tab-pane></el-tabs><EmergencyResourceEditorDrawer v-model="editorVisible" :resource="editing" :category="filters.category" @saved="load"/></section>
</template>
<style scoped>.history-alert{margin-bottom:12px}.action-buttons{display:flex;align-items:center;gap:4px;white-space:nowrap}.action-buttons :deep(.el-button){margin-left:0}</style>
