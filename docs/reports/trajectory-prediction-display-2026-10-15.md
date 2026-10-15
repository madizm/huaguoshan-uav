# 轨迹预测展示关联与时效优化

## 实施状态

已完成本地实现与测试。经用户授权，开发环境 RPC 已更新并完成数据库运行验证；前端尚未部署，未切换算法或修改预测时长。此改动与此前卡尔曼/IMM 实验独立。

## 用户可见变化

- 点击实时空域目标、尾迹、预测虚线、端点或不确定度圆环，通过 `(subject_kind, subject_id)` 联动高亮。实时目标与预测使用同一航迹详情面板，不按空间距离猜测关联。
- 增加“定位关联目标”按钮。关联目标不存在时提示开启实时态势或等待观测；图层隐藏时提示并定位已知位置，不强制改变图层开关。
- 无人机资产预测保留类型和 ID 关联，但当前侦测态势模块没有对应资产实体/详情适配器；这类对象可高亮预测，定位或详情会提示不可用，不冒充目标航迹。
- 默认只绘制当前时刻之后的预测部分。当前时刻落在两个预测点之间时插值裁剪，不修改原预测记录，不平移整条预测去贴合原始位置。
- 端点标签改为“距现在约 Ns”。选中状态显示基准观测年龄、剩余未来时长和不能生成预测的具体原因。
- 区分预测结束、计算未更新、基准观测陈旧、有效点不足、跨度不足、异常速度拒绝、读取异常及原因未知。
- 无法从空响应证明数据不足：旧版 RPC 没有 `states` 时明确显示“原因未知”。
- 实时目标、尾迹与预测改为按 Entity ID 增量更新，保留目标/预测 Entity、选择高亮和数据源可见性；删除已失效实体。
- 读取失败时保留尚未过期的缓存并标注异常，仍每秒推进时间裁剪，不让旧线无限保留。
- 禁用图层、退出登录、销毁或切换请求时忽略旧异步响应。退出登录清除关联选择并使延迟详情请求失效。

## 时间与回放口径

新增共享模块 `prediction-timeline.js`，供实时预测及航迹回放使用：

1. 点绝对时间为 `base_observed_at + eta_seconds`。
2. 预测的基准时间和生成时间都不能晚于展示时刻。
3. 实时模式检查计算年龄不超过 30 秒，基准观测年龄不超过 30 秒，并按实际预测结束时间裁剪。不是只检查“最近计算”。
4. 实时模式利用响应 `generated_at` 对齐服务器时间。按请求开始时间计算保守时间上界，不把响应延迟当作负时钟偏差；同步后不向回调时间偏移。高网络延迟可能提前隐藏轨迹，不能将该估计看作精确授时。
5. 回放不使用实时的 30 秒年龄限制，而是先选帧时刻已生成的最新计算，再判断是否仍有未来部分。新预测过期后，不恢复已被替代的更老长时预测。
6. 删除固定 130 秒回放有效期，改为实际点序列/预测范围。
7. 回放与实时共用 AMSL 高度。高度为 0 时保留 0；缺失高度才回退为 100 米，不再给所有回放点额外加 100 米。
8. 回放请求带序列失效保护，换航迹、重置或销毁后旧响应不能覆盖新状态。

历史 RPC 仍按桶抽稀且仅返回有效预测，本次没有实现逐次完整失败状态回放；不能宣称还原每次 worker 计算。实时数据源与预测仍各自轮询，没有合并成原子态势快照。

## RPC 兼容更新

修改 `backend/create_trajectory_prediction.sql` 中 `api.get_trajectory_predictions`，签名不变：

- `predictions` 增加记录 `id`，保持返回最近有效预测的语义。
- 增加 `states`，包括近 10 分钟每个对象最新计算的质量、原因和基准时间，不带预测点。
- 先根据最新计算选定共同对象池，并按计算时间优先取最多 `p_max_subjects` 个对象；两数组共用池，避免独立截断漏掉有效预测对应的新失败状态。
- 前端发现最新状态已失败时，隐藏对应较老有效预测，不能用旧成功结果掩盖新失败。

开发环境已更新该 RPC，可支持最新失败原因。前端兼容旧返回，但未升级数据库的其他环境只能将旧版空响应显示为原因未知。前端部署仍需单独执行。

具体返回字段及中文注释见 `docs/api/trajectory-prediction-api.md`。

## 文件

- `frontend/src/features/trajectory-prediction/prediction-timeline.js`：时间、裁剪、回放选择和高度纯函数。
- `frontend/src/features/trajectory-prediction/prediction-selection.js`：Cesium 属性关联、双向选中、定位和监听清理。
- `frontend/src/features/trajectory-prediction/trajectory-prediction-module.js`：状态、缓存、时钟、增量渲染与请求失效保护。
- `frontend/src/features/source-situation/source-situation-module.js`：目标元数据、增量更新、高亮、详情与历史回放。
- `frontend/src/app/create-huaguoshan-app.js`、`frontend/tianditu-3d.html`：加载顺序、状态栏、按钮、选择桥与退出登录清理。
- `backend/create_trajectory_prediction.sql`：兼容 RPC 扩展。

## 验证

- 四个相关 JavaScript 测试：timeline、selection、trajectory prediction、source situation 全部通过。
- 默认 Python 测试：134 passed，7 skipped。
- SQL schema、时间契约及 source situation RPC 专项：32 passed，5 skipped；与默认集存在重合。
- `git diff --check`、应用入口 JavaScript 语法检查通过。
- 本地页面已在 headless Chrome 加载，使用真实 Cesium Entity、PropertyBag、DataSourceCollection 验证预测/实时目标的实体身份保留、高亮、关联元数据及预测到期清除。测试数据为本地构造，不是线上联调。
- 本地静态 HTTP 服务没有配置 API 代理，因此页面完整后台操作不能在该服务下验收；不能把浏览器实体测试解释为线上端到端验证。
- 全部 16 个 `tests/test_*.js` 中，15 个通过。既有 `test_defense_ring_admin.js` 对 `map.on('singleclick'` 的断言失败；该测试和相关 `DefenseRingMap.vue` 与 HEAD 一致，本次未修改。
- 本地 SQL 测试为静态契约检查；授权后另外在开发库执行了下述事务内及提交后运行验证。未配置的本地数据库集成测试仍保持跳过，不冒充已执行。

## 开发环境数据库更新

用户授权后，于北京时间 **2026-10-15 23:24** 更新开发库 `huaguoshan_projd` 的 `api.get_trajectory_predictions(text[],integer,integer)` 及中文函数注释。仅提取执行该函数 DDL，没有运行整份迁移，没有修改 worker 或历史观测。

- 更新前备份原定义、注释、所有者和权限至本机 `/Users/madizm/.local/state/huaguoshan/db-backups/prediction-rpc-before-20261015T152426Z.json`，目录权限 0700，文件权限 0600。
- 在同一事务中保留函数所有者、ACL、参数、SECURITY DEFINER 和 search_path，并核查未变化。
- 使用保存点和显式负 ID 构造临时测试记录，验证最新失败状态、较老有效预测兼容返回、共同对象池、数量限制和 admin 角色执行权限。
- 测试记录在事务内回滚清除，未推进预测表 ID 序列，其他会话不可见；最后只提交函数定义、注释及 PostgREST schema reload 通知。
- 提交后用新只读连接验证函数定义 SHA-256：`044e78cf9cb3b6e68b8ad31fb9a50b936cf2c2eb055c1dd74cc880bf7f01ca59`。
- 新连接切换到 admin 角色，实际调用返回 `generated_at`、`predictions`、`states`。当时两数组均为空，且测试 ID 的残留记录数为 0。
- 已发送 `NOTIFY pgrst, 'reload schema'`；未宣称完成 PostgREST HTTP 或前端端到端验收。

## 尚未实施

没有强行连接原始末点与模型预测点，没有新增基准状态字段或辅助连接段，没有自动开启隐藏图层，也没有改变在线估计器、历史窗口或 120 秒默认预测时长。更改算法配置需另行验收。
