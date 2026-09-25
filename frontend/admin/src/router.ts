import { createRouter, createWebHistory } from 'vue-router'
import { authStore } from './api/auth'
import AdminLayout from './layouts/AdminLayout.vue'
import LoginView from './views/LoginView.vue'
import AssetListView from './views/AssetListView.vue'
import DetectionSourcesView from './views/DetectionSourcesView.vue'
import EquipmentDictionaryView from './views/EquipmentDictionaryView.vue'
import EmergencyResourceView from './views/EmergencyResourceView.vue'
import PoliceForceView from './views/PoliceForceView.vue'
import DefenseRingView from './views/DefenseRingView.vue'
import RiskEngineView from './views/RiskEngineView.vue'
import SourceSortieStatisticsView from './views/SourceSortieStatisticsView.vue'

export const router = createRouter({
  history: createWebHistory(import.meta.env.BASE_URL),
  routes: [
    { path: '/login', name: 'login', component: LoginView, meta: { public: true } },
    {
      path: '/',
      component: AdminLayout,
      children: [
        { path: '', redirect: '/assets' },
        { path: 'assets', name: 'assets', component: AssetListView, meta: { title: '设备资产' } },
        { path: 'equipment-dictionaries', name: 'equipment-dictionaries', component: EquipmentDictionaryView, meta: { title: '设备字典' } },
        { path: 'emergency-resources', name: 'emergency-resources', component: EmergencyResourceView, meta: { title: '应急资源' } },
        { path: 'police-forces', name: 'police-forces', component: PoliceForceView, meta: { title: '警务力量' } },
        { path: 'defense-rings', name: 'defense-rings', component: DefenseRingView, meta: { title: '防御圈配置' } },
        { path: 'risk-engine', name: 'risk-engine', component: RiskEngineView, meta: { title: '风险评估引擎' } },
        { path: 'source-sorties', name: 'source-sorties', component: SourceSortieStatisticsView, meta: { title: '来源架次统计' } },
        {
          path: 'detection-sources',
          name: 'detection-sources',
          component: DetectionSourcesView,
          meta: { title: '侦测来源' },
        },
      ],
    },
  ],
})

router.beforeEach((to) => {
  if (!to.meta.public && !authStore.token) {
    return { name: 'login', query: { redirect: to.fullPath } }
  }
  if (to.name === 'login' && authStore.token) {
    return { name: 'assets' }
  }
  return true
})
