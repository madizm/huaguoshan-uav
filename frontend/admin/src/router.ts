import { createRouter, createWebHistory } from 'vue-router'
import { authStore } from './api/auth'
import LoginView from './views/LoginView.vue'
import AssetListView from './views/AssetListView.vue'

export const router = createRouter({
  history: createWebHistory('/admin/'),
  routes: [
    { path: '/login', name: 'login', component: LoginView, meta: { public: true } },
    { path: '/', redirect: '/assets' },
    { path: '/assets', name: 'assets', component: AssetListView },
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
