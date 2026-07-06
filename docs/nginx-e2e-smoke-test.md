# Nginx 统一入口部署级 smoke test

`tests/test_nginx_e2e_smoke.py` 是面向已部署栈的外部验收脚本，用一个检查覆盖 认证入口服务、PostgREST JWT 访问和 Scalar 文档门户。脚本只访问统一 Nginx 入口，不直接访问内部服务端口。

## 运行方式

```bash
NGINX_HOST=http://127.0.0.1:20000 \
SMOKE_TEST_USERNAME=admin \
SMOKE_TEST_PASSWORD='<admin-password>' \
uv run tests/test_nginx_e2e_smoke.py
```

也可以用参数覆盖环境变量：

```bash
uv run tests/test_nginx_e2e_smoke.py \
  --host http://10.1.109.151:20000 \
  --username admin \
  --password '<admin-password>'
```

## Required inputs

- `NGINX_HOST`: 统一 Nginx 入口的 base URL，例如 `http://127.0.0.1:20000`。
- `SMOKE_TEST_USERNAME`: 用于 `/auth/login` 的测试/管理员账号，默认 `admin`。
- `SMOKE_TEST_PASSWORD`: 对应密码。未提供时脚本会交互式提示输入。
- `SMOKE_TEST_BUSINESS_ENDPOINTS`: 逗号分隔的受保护 PostgREST 业务端点名，默认 `no_fly_zone,temp_control_zone`。端点必须在 `api` schema 中对 `admin` 角色可见，且匿名角色应被拒绝。

## 检查内容

脚本会通过 `NGINX_HOST` 依次验证：

1. `GET /healthz` 返回 healthy。
2. 匿名访问配置的 `/postgrest/<endpoint>` 业务端点被拒绝。
3. 匿名 `GET /postgrest/` OpenAPI 可访问，但允许因匿名角色无业务权限而为空。
4. `POST /auth/login` 使用配置账号登录并返回 `role=admin` 的 JWT。
5. `GET /auth/me` 携带返回 token 时成功，未携带 token 时返回 401。
6. 携带返回 token 访问配置的 `/postgrest/<endpoint>` 业务端点成功。
7. 携带返回 token 获取 PostgREST OpenAPI 时包含所有配置业务端点对应的受保护路径。
8. `GET /docs/` 返回 Scalar documentation portal 页面。

## Expected failure modes

- `/healthz` 失败：Nginx 没有路由到 认证入口服务，或认证服务未启动。
- anonymous PostgREST 访问成功：`anonymous` 角色可能被错误授予业务 API 权限，破坏 ADR-0004 的匿名隔离。
- `/auth/login` 失败：测试凭证不存在、账号被禁用/锁定、密码错误、JWT secret 配置不一致，或 Nginx `/auth/` 代理未连通。
- `/auth/me` 携带 token 失败：认证服务 token 校验配置与签发配置不一致，或 Nginx 未正确转发 `Authorization`。
- 携带 token 的 PostgREST 业务请求失败：Nginx `/postgrest/` 路由未转发 `Authorization`，PostgREST JWT secret/role 配置不一致，或 `admin` 角色缺少对应 API 权限。
- PostgREST OpenAPI 不包含业务路径：请求未携带有效 admin JWT、PostgREST 使用了匿名角色生成 OpenAPI、端点不在 `api` schema 暴露，或 `SMOKE_TEST_BUSINESS_ENDPOINTS` 配置了不存在的路径。
- `/docs/` 失败：Nginx 文档门户静态路径配置错误，或部署缺少 `deploy/docs/index.html`。
