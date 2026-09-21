import { createRouter, createWebHistory } from 'vue-router'
import { authStore } from './api/auth'
import AdminLayout from './layouts/AdminLayout.vue'
import LoginView from './views/LoginView.vue'
import AssetListView from './views/AssetListView.vue'
import DetectionSourcesView from './views/DetectionSourcesView.vue'
import EquipmentDictionaryView from './views/EquipmentDictionaryView.vue'

export const router = createRouter({
  history: createWebHistory('/admin/'),
  routes: [
    { path: '/login', name: 'login', component: LoginView, meta: { public: true } },
    {
      path: '/',
      component: AdminLayout,
      children: [
        { path: '', redirect: '/assets' },
        { path: 'assets', name: 'assets', component: AssetListView, meta: { title: '设备资产' } },
        { path: 'equipment-dictionaries', name: 'equipment-dictionaries', component: EquipmentDictionaryView, meta: { title: '设备字典' } },
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
