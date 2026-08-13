---
name: dsh-observation-writer
description: 观测事件 Ledger 追加与成本投影重建技能 / Skill for observation Ledger appends and cost-projection rebuilds
---

# Hermes 观测写入 / Hermes Observation Writer

本技能用于观测与成本证据写入：将观测事件幂等追加进 Ledger，并按日重建成本投影。

This skill covers observation and cost evidence writing: idempotently appending observation events to the Ledger and rebuilding daily cost projections.

## When to use / 何时使用

需要记录模型调用观测、重建成本投影或核对成本证据时。

Use when recording model-call observations, rebuilding cost projections, or verifying cost evidence.

## Workflow / 工作流

1. 构造观测事件（observation-event v0.2）。
2. AppendObservation 写入 Ledger。
3. RebuildCostProjection 按日聚合。
4. 核对投影 token 幂等性。

## References / 参考

- 项目 README: 见仓库根目录
- 作者: h565656445 (GitHub)