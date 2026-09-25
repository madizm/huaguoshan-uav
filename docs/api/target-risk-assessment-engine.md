# 目标风险评估引擎

## 1. 职责边界

Python 风险引擎异步消费已关联到航迹的侦测观测，读取管理端发布的防御圈和评分规则，写入版本化风险历史与每条航迹的当前投影。引擎只产生风险属性和 `risk_changed` 增量，不调用反制或打击设备。

配置仍由 Vue 管理端通过防御圈 RPC 发布。worker 和 HTTP 接口都只从数据库读取已发布配置，调用方不能提交或覆盖防御圈、保护对象或评分规则。

## 2. 数据模型

- `event_response.target_risk_assessment`：追加式评估历史；`observation_id` 幂等，禁止更新和删除。
- `event_response.target_risk_current`：每条航迹当前风险；仅较新的 `(observed_at, observation_id)` 可以覆盖。
- `event_response.risk_worker_cursor`：worker 持久化消费游标；与评估写入在同一事务提交。
- `situation.change_event`：状态、等级、分数或防御圈变化时追加 `risk_changed`。

每条历史记录冻结保护对象版本、防御圈版本、规则集 ID、规则版本、因子结果和最小输入快照。

## 3. 状态语义

- `pending`：航迹尚无当前评估记录。
- `target_location_unavailable`：观测存在，但目标位置缺失。
- `outside_protected_objects`：位置有效，但不在任何启用保护对象的防御圈内。
- `failed`：单条观测评估失败；失败记录会入库，后续观测继续处理。
- `assessed`：已完成评分；`riskScore=0` 仍是有效评估，不等同于其他状态。

## 4. 轨迹评分

worker 为每条观测读取同航迹最近 120 秒、最多 100 个有效空间点，但历史表只保存参与计算的观测 ID，不复制原始轨迹坐标。评分使用已发布规则中的阈值和参数：

- `continuous_approach`：满足 `approach_window_seconds`、`approach_min_points`，并达到配置的接近速度阈值。
- `fast_approach`：先满足持续接近，再达到更高接近速度阈值。
- `next_ring_eta_60` / `next_ring_eta_30`：根据短轨迹速度向量与下一内层圆边界的首次交点计算，只命中同一互斥组中分值最高的一档。
- 风险等级使用 `score_low`、`score_medium`、`score_high`、`score_critical`，不在 Python 中固定管理端可配置值。

每个因子记录 `matched`、`available`、`value` 和 `threshold`。轨迹点不足、方向不可靠或没有下一内层圈时，ETA 因子为 `available=false`，不会伪造秒数。当前 current 投影是即时航迹风险，不等同于需要连续确认和迟滞的正式空域事件。

## 5. 迁移顺序

依赖迁移按以下顺序执行：

1. 设备资产和原始观测 schema。
2. `backend/create_detection_situation_schema.sql`。
3. `backend/create_defense_ring_admin.sql`。
4. `backend/create_target_risk_assessment.sql`。
5. `backend/migrate_postgrest_api_roles.sql`。

迁移创建无默认密码的 `risk_engine` 登录角色。部署时由密钥系统单独设置密码，不得把密码写入仓库。

生产环境设置凭据示例：

```sql
alter role risk_engine password '<由密钥系统提供>';
```

## 6. 运行方式

安装锁定依赖：

```bash
uv sync --frozen
```

持续 worker：

```bash
export DATABASE_URL='postgresql://risk_engine:<password>@<db-host>:5432/huaguoshan_projd'
export LOG_LEVEL='INFO'
uv run python -m backend.risk_engine.worker --batch-size 100 --poll-interval 1
```

单批运维检查：

```bash
uv run python -m backend.risk_engine.worker --once --batch-size 100
```

可选内部 HTTP 服务：

```bash
uv run uvicorn backend.risk_engine.app:app --host 127.0.0.1 --port 8081
```

- `GET /healthz`：进程健康检查。
- `POST /v1/assessments/{observation_id}`：按数据库中的观测、已发布防御圈和规则执行幂等评估。

HTTP 服务应仅暴露在内部网络或服务网关后；生产持续处理仍以 worker 为主。

## 7. 查询契约

以下现有 RPC 返回航迹级 `riskAssessment`：

- `api.get_detection_live_tracks_v3`
- `api.get_detection_situation_changes`
- `api.list_detection_target_tracks`
- `api.get_target_track_detail`

没有当前结果时返回 `{"status":"pending"}`，不会返回 SQL `NULL`。`get_target_track_detail` 的每个抽样观测包含可空的精简 `riskAssessment`，用于地图着色和回放。未抽样的完整观测级历史通过下列受限 RPC 查询：

```http
POST /postgrest/rpc/list_target_risk_assessments
Authorization: Bearer <admin-jwt>
Content-Type: application/json
```

```json
{
  "p_track_id": 9,
  "p_start_at": "2026-09-21T00:00:00+08:00",
  "p_end_at": "2026-09-22T00:00:00+08:00",
  "p_limit": 500
}
```

时间窗口为半开区间，最大 7 天，最多返回 5000 条。

## 8. 验证

```bash
uv run pytest -q backend/risk_engine/tests tests/test_target_risk_assessment_schema.py
TEST_DATABASE_URL='<postgres-admin-dsn>' uv run pytest -q backend/risk_engine/tests/test_database_integration.py
```

数据库集成用例在单个事务内验证重复观测幂等、迟到观测不覆盖 current、`risk_changed` 和历史 RPC，结束时回滚测试数据。
