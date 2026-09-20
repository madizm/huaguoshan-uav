import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// 开发代理目标：开发环境（见 开发环境.md）。
// /auth → FastAPI 认证入口服务；/postgrest → PostgREST（剥离前缀）。
export default defineConfig({
  plugins: [vue()],
  base: '/admin/',
  server: {
    port: 5174,
    proxy: {
      '/auth': {
        target: 'http://10.1.109.151:13001',
        changeOrigin: true,
      },
      '/postgrest': {
        target: 'http://10.1.109.151:13000',
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/postgrest/, ''),
      },
    },
  },
})
