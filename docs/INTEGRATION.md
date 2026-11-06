# 可选的信息整合接口

## 约定

在菜单栏选择一个目录，App 只读取其中两个固定名称的发布文件：

- `待办总表.md`：普通事项，可单独提供。
- `请款与付款清单.json`：款项事项，可单独提供。

不直接读取微信、企微或短信数据库。采集、AI 提取及发布由独立的本地工具负责。两个文件均缺失时提示目录不完整；已有本机事项不删除。请用临时文件写完后原子替换，避免读取半个文件。

`examples/` 中的文件是可解析的虚构示例。只有用户主动选择示例目录后才会导入，不会自动预置事项。

## 待办总表

UTF-8 Markdown，版本行格式为 `版本 <唯一递增版本>。发布于 <ISO 8601 时间>。`，事项表在 `## 桌面待办` 章节。

表的列依次为 ID、栏目、内容、负责人、对接人、截止、状态、来源、同事项 ID；还可追加备注、展示标题、原文、主要负责人、优先级、日期类型。栏目为 `本人 / 团队 / 待确认`，状态为 `待办 / 已完成 / 已取消 / 仅记录`。截止未知用 `—`。只含日期的截止在当天结束前不会判为逾期；活动开始时间不能当成截止时间。

ID 必须稳定且唯一，跨来源同一事项应通过同事项 ID（别名）显式合并。不要通过标题相似度自动覆盖人工记录。现有解析器要求至少一条有效事项；不要用空表表示清空所有待办。

## 款项清单

UTF-8 JSON，`schema_version=1`，必须有 version、updated_at、coverage、items。金额使用十进制字符串；未知金额省略或 null，不默认为 0。必须保留稳定 id、project、stage、evidence、updated_at。

公开界面为待请款、待付款、已付款、待核实。协议中的 `待申请` 对应待请款；旧 `已提交/审批中` 也归待付款，`已退回` 归待请款，兼容旧记录但不新增界面分类。款项标题与人工修改独立保存。

## 人工修改回传

已接入时，App 将操作事件写入所选目录的 `操作记录/<event_id>.json`，默认每 3 秒检查一次队列。未接入时只保存在 App Group，后续接入再回传。回传失败会重试；每个 event_id 幂等。

常见字段：schema_version、event_id、item_id、item_type（task/payment）、action、before、after、occurred_at、recorded_at、actor、base_version、reverts_event_id、note。actor 在单机版为「我」，整合端需根据目录/用户配置明确所属人，不能把不同同事的「我」当成同一个人。

- `create_task`：新手动事项，after 含 title、notes、owner、contact、lane、due、state、priority、source。
- `change_title`：任务用 title，款项用 project。
- complete / cancel / restore / reschedule：状态与日期修改。
- verify_payment / change_payment_stage：款项核实与进度记录。
- remove_payment：从列表排除，可恢复，不等于付款或清除原记录。
- undo：用 reverts_event_id 关联被撤销事件。

整合端应消费并去重事件，把人工确认作为本次修改依据；不要因源记录未改变而覆盖用户修改。款项金额、阶段等出现新冲突时仍需核实。这里不触发实际付款申请、审批或转账。
