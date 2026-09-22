import { reactive } from 'vue'

const TOKEN_KEY = 'postgrest.jwt'
const USERNAME_KEY = 'postgrest.username'
const AUTH_BASE = (import.meta.env.VITE_AUTH_BASE || '/auth').replace(/\/$/, '')

// 与主场景 postgrest-client.js 共用同一 storage key，登录态互通。
export const authStore = reactive({
  token: localStorage.getItem(TOKEN_KEY) as string | null,
  username: (localStorage.getItem(USERNAME_KEY) ?? '') as string,
})

export function setToken(token: string, username: string) {
  authStore.token = token
  authStore.username = username
  localStorage.setItem(TOKEN_KEY, token)
  localStorage.setItem(USERNAME_KEY, username)
}

export function clearToken() {
  authStore.token = null
  authStore.username = ''
  localStorage.removeItem(TOKEN_KEY)
  localStorage.removeItem(USERNAME_KEY)
}

export async function login(username: string, password: string): Promise<void> {
  const response = await fetch(`${AUTH_BASE}/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username, password }),
  })
  if (!response.ok) {
    const body = await response.json().catch(() => ({}))
    throw new Error(body.detail || '登录失败')
  }
  const payload = await response.json()
  setToken(payload.access_token, username)
}

export function logout() {
  clearToken()
}
