# 历正设备接口调用说明（实测）

> 本文含明文测试账号密码和内网地址，仅供受控测试环境使用。**不要提交到公开仓库、转发或用于生产环境**；对外分享前请删除凭据并轮换密码。
>
> 接口字段详见 [`../历正科技应用接口说明v3.17.pdf`](../历正科技应用接口说明v3.17.pdf)。以下地址、登录路径和认证方式以设备实测为准，PDF 的示例设备地址不是当前设备地址。

## 访问条件与凭据

| 项目 | 值 | 说明 |
| --- | --- | --- |
| 设备地址 | `https://10.10.0.93` | 需先连接 `docs/SQ-2.conf` 对应的 WireGuard VPN |
| 设备登录接口 | `POST /login` | JSON 请求体 |
| GraphQL 接口 | `POST /rf/graphql` | 请求头使用 `Authorization: Bearer <token>` |
| 设备测试用户名 | `admin` | 已实测登录成功 |
| 设备测试密码 | `admin` | **明文测试凭据** |
| 云平台地址 | `https://ccs.lizhengtech.com` | 与设备侧 API 不是同一服务；`/rf/graphql` 在该域名下返回 404 |
| 云平台提供的用户名 | `tongmai` | 在云平台 `/v1/login/jwt` 测试未通过；不能用作设备登录凭据 |
| 云平台提供的密码 | `tongmai123` | **明文测试凭据**；云平台登录返回 `username or password error`，有效性待确认 |

以下命令需要 `curl` 和 `jq`。设备使用自签名证书时才需要 `-k`；生产环境应验证证书。`--noproxy '*'` 用于避免本机代理拦截 VPN 内网请求。

## 1. 检查 VPN 与设备连通性

```bash
route -n get 10.10.0.93  # macOS：应显示 WireGuard 的 utun 接口，而非 en0
ping -c 3 10.10.0.93
```

## 2. 登录并获取 token

直接测试登录响应（**会输出 token，勿粘贴到聊天或日志**）：

```bash
curl --noproxy '*' -k -i -X POST 'https://10.10.0.93/login' \
  -H 'Content-Type: application/json' \
  --data '{"username":"admin","password":"admin"}'
```

建议在本地终端获取 token 到变量，而不输出 token：

```bash
TOKEN=$(curl --noproxy '*' -ksS --fail-with-body \
  -X POST 'https://10.10.0.93/login' \
  -H 'Content-Type: application/json' \
  --data '{"username":"admin","password":"admin"}' | jq -er '.token')
```

响应包含 `token`、`expLen`、`user`。后续请求必须使用 **`Authorization: Bearer $TOKEN`**；仅在 `token` 请求头中传 token 实测返回 401。

## 3. 查询版本（只读）

```bash
curl --noproxy '*' -ksS --fail-with-body \
  -X POST 'https://10.10.0.93/rf/graphql' \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  --data '{"query":"query { version }"}' | jq .
```

实测：HTTP 200，`data.version` 返回版本信息；controller 版本为 `4.0.2`。

## 4. 查询 Devices（只读）

查询所有设备的精简字段；不传 `id` 表示查询全部：

```bash
curl --noproxy '*' -ksS --fail-with-body \
  -X POST 'https://10.10.0.93/rf/graphql' \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  --data '{"query":"query { devices { id class node state gps_fixed faults } }"}' | jq .
```

按设备 ID 查询（文档中 `id` 参数类型为 String）：

```bash
curl --noproxy '*' -ksS --fail-with-body \
  -X POST 'https://10.10.0.93/rf/graphql' \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  --data '{"query":"query { devices(id: \"0\") { id class node state } }"}' | jq .
```

实测无 `id` 查询返回 HTTP 200、8 条记录且无 GraphQL 错误：controller 1 条、engine 3 条、sensor 3 条、jammer 1 条；7 条 `state=operational`，controller 的 `state` 为空，全部 `faults` 为空。sensor 和 jammer 均有 `id=179`，因此 `id` 不应被视为跨设备类别唯一。`status` 和 `config` 可能包含设备内网地址、坐标、许可证等敏感信息，示例默认不读取这些字段。

> GraphQL 即使返回 HTTP 200，也应检查响应的 `errors` 字段；认证失败时 HTTP 返回 401。测试结束后执行 `unset TOKEN`。上述示例只使用查询操作，未经授权不要调用文档中的打击、重启、删除或配置修改等 Mutation。
