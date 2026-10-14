# 目标风险评估引擎

## 1. 职责边界

Python 风险引擎异步消费已关联到航迹的实际侦测观测，读取管理端发布的防御圈和评分规则，写入版本化风险历史与每条航迹的当前投影。引擎只产生风险属性和 `risk_changed` 增量，不调用反制或打击设备。

`equipment.raw_observation.observation_type=detection_offline_remove` 是生命周期通知，不参与评分，也不覆盖风险 current。接入仍保存原始记录、关闭航迹并发布 `target_remove`。排除依据是事件类型，不是坐标：实际侦测观测缺少坐标时仍写入 `target_location_unavailable`。

配置仍由 Vue 管理端通过防御圈 RPC 发布。worker 和 HTTP 接口都只从数据库读取已发布配置，调用方不能提交或覆盖防御圈、保护对象或评分规则。

## 2. 数据模型

- `event_response.target_risk_assessment`：追加式评估历史；`observation_id` 幂等，禁止更新和删除。
- `event_response.target_risk_current`：每条航迹最后一次实际侦测观测的风险评估；仅较新的 `(observed_at, observation_id)` 可以覆盖。它不是历史最高风险，也不是最后一次有坐标观测的风险。
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

worker 为每条观测读取同航迹最近 120 秒、最多 100 个实际侦测空间点，但历史表只保存参与计算的观测 ID，不复制原始轨迹坐标。离线移除通知即使带坐标也不参与轨迹因子计算，worker 和 HTTP 入口使用相同过滤条件。评分使用已发布规则中的阈值和参数：

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

对离线移除通知，HTTP 入口返回 `422`，响应为 `{"detail":"lifecycle events are not eligible for risk assessment"}`。即使历史库中已有该通知的旧评估，也不会直接返回它或重新评分。

HTTP 服务应仅暴露在内部网络或服务网关后；生产持续处理仍以 worker 为主。

## 7. 查询契约

以下现有 RPC 返回航迹级 `riskAssessment`：

- `api.get_detection_live_tracks_v3`
- `api.get_detection_situation_changes`
- `api.list_detection_target_tracks`
- `api.get_target_track_detail`

没有当前结果时返回 `{"status":"pending"}`，不会返回 SQL `NULL`。`get_target_track_detail` 的每个抽样观测包含可空的精简 `riskAssessment`，用于地图着色和回放。未抽样的完整观测级历史通过下列受限 RPC 查询：

航迹关闭后仍保留最后一次实际侦测评估。前端必须结合 `track.status` 和风险的 `observedAt` 展示“最后观测风险”，不能将关闭航迹的 `high` 显示为当前仍在现场的实时风险。详情的时间窗口只筛选观测，不按窗口重算航迹级 current。

详情仍保留离线移除通知。因此 `observations.length` 和 `evidence.returned_count` 是观测记录数，不是有效空间点数；绘制轨迹应检查 `target_location`。历史修复不删除旧评估，完整历史 RPC 可能仍返回离线通知的旧评估，这些记录是审计证据，不参与新的 current 选择。

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

## 8. 后台运行监控

管理后台通过只读 RPC 获取 worker 业务运行状态，不直接访问 `event_response` schema，也不通过 Web 页面控制 systemd：

```http
POST /postgrest/rpc/get_risk_engine_status
Authorization: Bearer <admin-jwt>
Content-Type: application/json

{}
```

返回 `state`、`worker`、`backlog`、`throughput` 和 `configuration`。积压统计与 worker 的消费条件一致，同时区分游标后的新观测和游标之前缺少评估的修复积压；查询最多扫描并报告 10000 条，`pendingCountCapped=true` 表示实际数量不低于该值。

worker 每 5 秒至少更新一次空闲心跳，并在批次成功后记录批量、耗时、成功时间、累计处理量和失败评估量。批次异常使用独立事务记录，避免与失败批次一起回滚。

最近失败评估通过以下 RPC 查询：

```http
POST /postgrest/rpc/list_risk_engine_failures
Authorization: Bearer <admin-jwt>
Content-Type: application/json

{
  "p_start_at": "2026-09-24T00:00:00Z",
  "p_end_at": "2026-09-25T00:00:00Z",
  "p_limit": 50
}
```

窗口采用半开区间，最长 31 天，最多返回 500 条。接口只暴露错误代码，不返回输入快照、数据库连接信息或内部异常堆栈。

## 9. 离线通知风险覆盖修复的部署

增量脚本：`backend/migrate_target_risk_offline_events.sql`。以数据库所有者执行，不用 `risk_engine` 角色。脚本更新积压统计条件，并修复 current 仍指向离线移除通知的航迹。

### 9.1 部署前核对

先在只读事务中核对影响数量：

```sql
begin read only;
select count(*) as affected_tracks
from event_response.target_risk_current c
join event_response.target_risk_assessment a on a.id=c.assessment_id
join equipment.raw_observation r on r.id=a.observation_id
where r.observation_type='detection_offline_remove';

select event_response.risk_assessment_json(28247);
rollback;
```

保留数据库备份或受影响 current 的导出用于复核。不要只运行修复 SQL 而保留旧引擎，否则新的离线通知会再次覆盖 current。

### 9.2 执行顺序

1. 暂停观测接入、风险 worker，以及启用的内部风险 HTTP 写入服务。
2. 部署新的 `detection_adapter.py` 和 `app.py`，先不启动写入服务。
3. 用 `psql -X -v ON_ERROR_STOP=1 "$DATABASE_URL" -f backend/migrate_target_risk_offline_events.sql` 执行增量迁移。
4. 核对影响数量及样例的 current、风险历史、`risk_changed`。
5. 恢复接入、worker 和内部 HTTP 服务，检查心跳、积压和日志。

迁移持有风险 history/current 表的排他锁，会暂时阻塞相关风险查询和写入；推荐在维护窗口执行。如果所有风险 worker 和启用的风险 HTTP 写入服务已更新并重启，可在线执行，事务锁会串行化风险写入。不得在旧版风险写入服务仍运行时执行。锁等待超过 30 秒时失败，事务整体回滚，不得跳过报错继续恢复服务。修复按真实观测的 `(observed_at, observation_id)` 选择最新已有评估，不按最高分或坐标是否为空选择。没有真实观测评估时删除错误 current，公共查询返回 `pending`，worker 后续补齐尚未评估的实际观测。

迁移保留原始观测和不可变风险历史，使用修复时刻发布完整 `risk_changed`，其中风险自身的 `observedAt` 仍是原观测时间。重复执行不会重复修复已恢复的投影，也不会重复发布对应增量。常规引擎的迟到观测保护条件不变。

对本次样例 `28247`，若部署时数据未变化，预期 current 指向 `319823`、`status=assessed`、`riskLevel=high`、`riskScore=75`，航迹仍为 `closed`；详情仍保留 41 条记录。

### 9.3 隔离数据库验证

新的迁移集成测试会在事务内执行真实修复脚本并持有表锁，最后回滚。`TEST_DATABASE_URL` 必须指向安装了上述 schema 的隔离测试库，不要指向运行中的业务数据库。

```bash
TEST_DATABASE_URL='<isolated-test-admin-dsn>' uv run pytest -q \
  backend/risk_engine/tests tests/test_target_risk_assessment_schema.py \
  tests/test_detection_situation_schema.py
```

### 9.4 开发环境执行记录（2026-10-14）

确认风险 worker 于北京时间 23:24 重启后，已在开发数据库 `huaguoshan_projd` 执行增量迁移并提交。

- 修复前：7489 条 current 指向离线通知；修复后：0 条。
- 恢复结果：5403 条 `assessed`、581 条 `outside_protected_objects`、1505 条实际侦测位置缺失；没有需要回退到 `pending` 的航迹。
- 发布了 7489 条 `risk_changed`，修复时间为 `2026-10-14T23:27:35.532857+08:00`；逐条核对增量中的完整风险对象与 current 一致。
- 航迹 `28247`：current 已恢复为 `319823 / assessed / high / 75`；航迹仍为 `closed`，详情仍为 41 条记录，其中 1 条非空间记录。评估历史仍包含 40 条 `assessed` 和 1 条旧的离线通知评估。
- 执行后监控：`state=healthy`，新观测积压和修复积压均为 0；worker 心跳正常。

执行前的受影响 current 备份和迁移日志保存在执行端 `/tmp/hgs-risk-offline-repair.RL3phP/`，目录仅执行用户可访问。该路径是临时文件，不替代长期数据库备份。
