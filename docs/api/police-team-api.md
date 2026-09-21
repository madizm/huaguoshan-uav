# 警员与警务编组 API

- API 形式：PostgREST REST API
- 数据库脚本：`backend/create_police_team_schema.sql`
- 前置脚本：`backend/create_police_station_schema.sql`
- 权限：仅已认证的 `admin` 角色可以访问

## 1. 数据关系

```text
police_station 1 ── N police_team
police_team    1 ── N police_team_member
police_officer 1 ── N police_team_member
```

- 警员可以同时参加多个编组。
- 一个编组当前最多挂载一个警务站，一个警务站可以挂载多个编组。
- 组长也是编组成员，以 `member_role=leader` 表示。
- 每个编组最多有一个当前组长。
- `left_at` 为空表示当前成员；离组时填写 `left_at`，不要删除历史记录。

## 2. 接口总览

| 资源 | 路径 | 权限 | 用途 |
|---|---|---|---|
| 警员档案 | `/emergency_police_officers` | CRUD | 管理姓名、警号、联系方式和当前状态 |
| 警务编组 | `/emergency_police_teams` | CRUD | 管理组名、状态以及挂载的警务站 |
| 编组成员 | `/emergency_police_team_members` | CRUD | 管理成员、角色和任职历史 |
| 当前花名册 | `/emergency_police_team_roster` | 只读 | 联合查询编组、警务站和当前成员 |
| 编组管理列表 | `/emergency_police_team_details` | 只读 | 分页查询警务站、组长和当前成员数 |
| 成员任职历史 | `/emergency_police_team_member_history` | 只读 | 查询当前及已离组成员 |
| 原子创建编组 | `/rpc/create_police_team` | RPC | 创建编组并设置首任组长 |
| 成员离组 | `/rpc/remove_police_team_member` | RPC | 保留任职历史并阻止组长直接离组 |
| 设置组长 | `/rpc/assign_police_team_leader` | RPC | 原子设置或更换编组组长 |

下文假定：

```bash
export API_BASE='http://<host>:20000/postgrest'
export TOKEN='<access_token>'
```

所有请求均应携带：

```http
Authorization: Bearer <access_token>
```

## 3. 警员档案

### 3.1 字段

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | bigint | 主键 |
| `officer_no` | text | 警号，全局唯一 |
| `name` | text | 姓名 |
| `contact_phone` | text | 工作联系方式，敏感信息 |
| `organization_name` | text | 所属公安机关或单位 |
| `availability_status` | text | `available`、`on_duty`、`dispatched`、`leave`、`unavailable` |
| `is_active` | boolean | 档案是否有效 |
| `is_simulated` | boolean | 是否为模拟数据 |
| `metadata` | jsonb | 扩展属性 |

警员档案与登录账号相互独立。警员离职或停用时设置 `is_active=false`，不要删除仍有历史成员关系的警员。

### 3.2 新增警员

```bash
curl -X POST "$API_BASE/emergency_police_officers" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -H 'Prefer: return=representation' \
  -d '{
    "officer_no": "32070001",
    "name": "张三",
    "contact_phone": "13800000001",
    "organization_name": "连云港市公安局海州分局",
    "availability_status": "available"
  }'
```

## 4. 警务编组

### 4.1 字段

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | bigint | 主键 |
| `team_code` | text | 编组稳定业务编码，全局唯一 |
| `name` | text | 组名 |
| `station_id` | bigint/null | 挂载的 `police_station.id` |
| `team_status` | text | `active`、`standby`、`dispatched`、`inactive` |
| `description` | text | 编组说明 |
| `is_simulated` | boolean | 是否为模拟数据 |
| `metadata` | jsonb | 扩展属性 |

删除警务站不会删除编组，编组的 `station_id` 会自动置空。

### 4.2 新增并挂载警务站

先查询警务站：

```bash
curl -G "$API_BASE/emergency_police_stations" \
  -H "Authorization: Bearer $TOKEN" \
  --data-urlencode 'select=id,name,address' \
  --data-urlencode 'name=ilike.*花果山*'
```

再通过原子 RPC 新增编组并设置首任组长：

```bash
curl -X POST "$API_BASE/rpc/create_police_team" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -H 'Prefer: return=representation' \
  -d '{
    "p_team_code": "TEAM-HGS-001",
    "p_name": "花果山一组",
    "p_leader_officer_id": 1,
    "p_station_id": 1,
    "p_team_status": "active",
    "p_description": null,
    "p_is_simulated": false,
    "p_metadata": {}
  }'
```

更换或解除挂载：

```bash
curl -X PATCH "$API_BASE/emergency_police_teams?id=eq.1" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"station_id": null}'
```

## 5. 编组成员

### 5.1 增加普通成员

```bash
curl -X POST "$API_BASE/emergency_police_team_members" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -H 'Prefer: return=representation' \
  -d '{
    "team_id": 1,
    "officer_id": 2,
    "member_role": "member"
  }'
```

同一个警员不能在同一个编组中存在两条 `left_at=null` 的当前成员记录，但离组后可以重新加入并形成新的历史记录。

### 5.2 设置或更换组长

不要通过两次独立请求先撤销旧组长、再设置新组长。应调用原子 RPC：

```bash
curl -X POST "$API_BASE/rpc/assign_police_team_leader" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -H 'Prefer: return=representation' \
  -d '{
    "p_team_id": 1,
    "p_officer_id": 1
  }'
```

返回一条成员关系记录，字段为：

```json
{
  "id": 10,
  "team_id": 1,
  "officer_id": 1,
  "member_role": "leader",
  "joined_at": "2026-01-01T08:00:00Z",
  "left_at": null,
  "created_at": "2026-01-01T08:00:00Z",
  "updated_at": "2026-01-01T08:00:00Z"
}
```

如果指定警员尚不是该编组成员，RPC 会自动建立成员关系；如果已有组长，原组长会改为普通成员。已停用的警员不能被设置为组长。

### 5.3 成员离组

成员离组应调用受控 RPC，不直接删除或手工修改组长记录：

```bash
curl -X POST "$API_BASE/rpc/remove_police_team_member" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"p_membership_id": 10}'
```

## 6. 查询当前花名册

查询某个警务站的全部当前编组成员：

```bash
curl -G "$API_BASE/emergency_police_team_roster" \
  -H "Authorization: Bearer $TOKEN" \
  --data-urlencode 'station_id=eq.1' \
  --data-urlencode 'select=team_id,team_name,member_role,officer_id,officer_no,officer_name,contact_phone' \
  --data-urlencode 'order=team_id.asc,member_role.asc,officer_no.asc'
```

查询某个编组：

```bash
curl -G "$API_BASE/emergency_police_team_roster" \
  -H "Authorization: Bearer $TOKEN" \
  --data-urlencode 'team_id=eq.1'
```

`emergency_police_team_roster` 只返回 `left_at` 为空的当前成员。后台分页列表使用 `/emergency_police_team_details`，任职历史使用 `/emergency_police_team_member_history`。

## 7. 数据约束说明

- `officer_no` 和 `team_code` 分别唯一。
- 一个编组最多有一名当前组长。
- 同一警员在同一编组中最多有一条当前成员关系。
- 当前允许一个警员同时参加多个编组，以支持临时任务组和跨站协作。
- 后台应通过 `create_police_team` 原子创建编组和首任组长，避免半完成记录。
- 当前组长不能直接离组，必须先通过 `assign_police_team_leader` 完成交接。
- 联系方式仅授权 `admin` 访问，不向 `anonymous` 或 `public` 开放。
