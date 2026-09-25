<script setup lang="ts">
import { computed } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { Aim, Connection, FirstAidKit, Grid, Histogram, List, Odometer, Setting, SwitchButton, UserFilled } from '@element-plus/icons-vue'
import { authStore, logout } from '../api/auth'

const route = useRoute()
const router = useRouter()
const pageTitle = computed(() => String(route.meta.title ?? '设备管理'))

function handleLogout() {
  logout()
  router.push({ name: 'login' })
}
</script>

<template>
  <el-container class="admin-layout">
    <el-aside class="sidebar" width="216px">
      <div class="brand">
        <span class="brand-mark">反无</span>
        <div>
          <strong>连云港反无</strong>
          <small>设备管理后台</small>
        </div>
      </div>
      <el-menu router :default-active="route.path" class="navigation">
        <el-menu-item index="/assets">
          <el-icon><List /></el-icon>
          <span>设备资产</span>
        </el-menu-item>
        <el-menu-item index="/equipment-dictionaries">
          <el-icon><Setting /></el-icon>
          <span>设备字典</span>
        </el-menu-item>
        <el-menu-item index="/emergency-resources">
          <el-icon><FirstAidKit /></el-icon>
          <span>应急资源</span>
        </el-menu-item>
        <el-menu-item index="/police-forces">
          <el-icon><UserFilled /></el-icon>
          <span>警务力量</span>
        </el-menu-item>
        <el-menu-item index="/defense-rings">
          <el-icon><Aim /></el-icon>
          <span>防御圈配置</span>
        </el-menu-item>
        <el-menu-item index="/detection-sources">
          <el-icon><Connection /></el-icon>
          <span>侦测来源</span>
        </el-menu-item>
        <el-menu-item index="/risk-engine">
          <el-icon><Odometer /></el-icon>
          <span>风险评估引擎</span>
        </el-menu-item>
        <el-menu-item index="/source-sorties">
          <el-icon><Histogram /></el-icon>
          <span>来源架次统计</span>
        </el-menu-item>
        <el-menu-item index="/source-target-sorties">
          <el-icon><Grid /></el-icon>
          <span>来源目标架次</span>
        </el-menu-item>
      </el-menu>
    </el-aside>

    <el-container class="workspace">
      <el-header class="topbar">
        <h1>{{ pageTitle }}</h1>
        <div class="account">
          <span>{{ authStore.username }}</span>
          <el-button text :icon="SwitchButton" @click="handleLogout">退出登录</el-button>
        </div>
      </el-header>
      <el-main class="page-content">
        <router-view />
      </el-main>
    </el-container>
  </el-container>
</template>

<style scoped>
.admin-layout {
  min-height: 100vh;
  background: #f4f6f5;
}
.sidebar {
  position: fixed;
  inset: 0 auto 0 0;
  z-index: 10;
  background: #202522;
  color: #fff;
}
.brand {
  height: 64px;
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 0 18px;
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
}
.brand-mark {
  display: grid;
  place-items: center;
  width: 36px;
  height: 36px;
  border-radius: 6px;
  background: #28a36a;
  font-size: 12px;
  font-weight: 700;
}
.brand strong,
.brand small {
  display: block;
  letter-spacing: 0;
}
.brand strong {
  font-size: 15px;
}
.brand small {
  margin-top: 2px;
  color: rgba(255, 255, 255, 0.58);
  font-size: 12px;
}
.navigation {
  border-right: 0;
  background: transparent;
  --el-menu-text-color: rgba(255, 255, 255, 0.72);
  --el-menu-hover-bg-color: rgba(255, 255, 255, 0.07);
  --el-menu-active-color: #65d49a;
}
.workspace {
  min-width: 0;
  margin-left: 216px;
}
.topbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  background: #fff;
  border-bottom: 1px solid #dfe4e1;
}
.topbar h1 {
  margin: 0;
  font-size: 18px;
  font-weight: 600;
  color: #202522;
}
.account {
  display: flex;
  align-items: center;
  gap: 12px;
  color: #5d6862;
  font-size: 14px;
}
.page-content {
  padding: 20px;
}
@media (max-width: 760px) {
  .sidebar {
    width: 64px !important;
  }
  .brand {
    justify-content: center;
    padding: 0;
  }
  .brand div {
    display: none;
  }
  .navigation :deep(.el-menu-item) {
    justify-content: center;
    padding: 0 !important;
  }
  .navigation :deep(.el-menu-item span) {
    display: none;
  }
  .workspace {
    margin-left: 64px;
  }
  .page-content {
    padding: 12px;
  }
  .account > span {
    display: none;
  }
}
</style>
