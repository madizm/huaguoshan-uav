import { authStore, clearToken } from './auth'

const BASE = (import.meta.env.VITE_POSTGREST_BASE || '/postgrest').replace(/\/$/, '')

export class ApiError extends Error {
  constructor(
    message: string,
    public status: number,
  ) {
    super(message)
  }
}

interface RequestOptions {
  method?: string
  query?: Record<string, string>
  body?: unknown
  prefer?: string[]
  signal?: AbortSignal
}

export interface PagedResult<T> {
  rows: T[]
  total: number
}

async function request<T>(path: string, options: RequestOptions = {}): Promise<T> {
  const url = new URL(BASE + path, window.location.origin)
  for (const [key, value] of Object.entries(options.query ?? {})) {
    url.searchParams.set(key, value)
  }
  const headers: Record<string, string> = { Accept: 'application/json' }
  if (authStore.token) headers.Authorization = `Bearer ${authStore.token}`
  if (options.body !== undefined) headers['Content-Type'] = 'application/json'
  if (options.prefer?.length) headers.Prefer = options.prefer.join(', ')

  const response = await fetch(url, {
    method: options.method ?? 'GET',
    headers,
    body: options.body !== undefined ? JSON.stringify(options.body) : undefined,
    signal: options.signal,
  })
  if (response.status === 401 || response.status === 403) {
    clearToken()
  }
  if (!response.ok) {
    const body = await response.json().catch(() => ({}))
    throw new ApiError(body.message || body.detail || `请求失败（${response.status}）`, response.status)
  }
  if (response.status === 204) return undefined as T
  return response.json() as Promise<T>
}

export async function requestPaged<T>(
  path: string,
  options: RequestOptions & { limit: number; offset: number },
): Promise<PagedResult<T>> {
  const url = new URL(BASE + path, window.location.origin)
  for (const [key, value] of Object.entries(options.query ?? {})) {
    url.searchParams.set(key, value)
  }
  const headers: Record<string, string> = {
    Accept: 'application/json',
    Prefer: 'count=exact',
    'Range-Unit': 'items',
    Range: `${options.offset}-${options.offset + options.limit - 1}`,
  }
  if (authStore.token) headers.Authorization = `Bearer ${authStore.token}`

  const response = await fetch(url, { headers, signal: options.signal })
  if (response.status === 401 || response.status === 403) {
    clearToken()
  }
  if (!response.ok && response.status !== 206) {
    const body = await response.json().catch(() => ({}))
    throw new ApiError(body.message || `请求失败（${response.status}）`, response.status)
  }
  const contentRange = response.headers.get('Content-Range') ?? ''
  const total = Number(contentRange.split('/')[1]) || 0
  const rows = (await response.json()) as T[]
  return { rows, total }
}

export const http = {
  get: <T>(path: string, query?: Record<string, string>) => request<T>(path, { query }),
  post: <T>(path: string, body: unknown, prefer?: string[]) => request<T>(path, { method: 'POST', body, prefer }),
  patch: <T>(path: string, query: Record<string, string>, body: unknown) =>
    request<T>(path, { method: 'PATCH', query, body }),
  delete: <T>(path: string, query: Record<string, string>) => request<T>(path, { method: 'DELETE', query }),
}
