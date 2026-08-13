# dsh-observation-writer

<!-- DeepSeek Harness 衍生声明 -->
> **DeepSeek Harness 个人适配声明（Personal Adaptation Notice）**
>
> 本项目是 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的**个人适配产物（personal adaptation）**，**并非 DeepSeek Harness 官方文件（not an official DeepSeek Harness file）**，随附功能、使用说明与个人产物（bundled with features, documentation, and personal artifacts），可与 DeepSeek Harness 搭配使用，也可独立使用。
>
> This project is a **personal adaptation** for DeepSeek Harness, and is **NOT an official DeepSeek Harness file**, bundled with features, documentation, and personal artifacts. It can be used alongside DeepSeek Harness or standalone.

**作者 / Author**: [h565656445](https://github.com/h565656445)

**合作 / Collaboration**: 如有项目可以一起合作，欢迎联系。微信：`wohaishihenshuaide`。If you have projects, let's collaborate. WeChat: `wohaishihenshuaide`.


---

## 用途 / What this is for

观测写入模块：把观测事件、成本与质量数据写入统一观测账本。

Observation writer module: writes observation events, cost and quality data into the unified observation ledger.

---
## Hermes Observation Writer / Hermes 观测写入

观测与成本证据写入模块：`HermesObservationWriter.psm1` 将受信任观测事件（`observation-event` schema v0.2）幂等追加进 Ledger，并按日重建成本投影（`cost-projection` schema v0.2），供可观测性与预算治理使用。

Observation and cost evidence writer: `HermesObservationWriter.psm1` idempotently appends trusted observation events (`observation-event` schema v0.2) to the Ledger and rebuilds daily cost projections (`cost-projection` schema v0.2) for observability and budget governance.

## Features / 功能

- Ledger 追加：幂等只追加观测事件 / Idempotent append of observation events to the Ledger
- 成本投影：按日聚合重建 cost projection / Daily cost-projection rebuild
- Schema 绑定：事件与投影双 schema 身份校验 / Schema-bound identity for events and projections
- 幂等重建：重复重建返回相同 token / Deterministic rebuild returning an identical token

## What's inside / 目录结构

```
dsh-observation-writer/
├── README.md
├── LICENSE
├── src/HermesObservationWriter.psm1
└── .dsh/
```

## Quick start / 快速开始

```powershell
Import-Module .\src\HermesObservationWriter.psm1 -Force

Invoke-HermesObservationWriter -Action AppendObservation -RuntimeRoot .\runtime -Observation <observation>
Invoke-HermesObservationWriter -Action RebuildCostProjection -RuntimeRoot .\runtime -ProjectionDateUtc 2026-07-23
```

## DeepSeek Harness 衍生 / DSH Derivative

本项目附带 DeepSeek Harness 衍生包，位于 `.dsh/` 目录：

- `preset.yml` — Agent 预设元数据
- `agent.cordis.yml` — Cordis 组装（基于 standard 预设，persona 已定制）
- `skills/dsh-observation-writer/SKILL.md` — 项目专属技能（skill）

安装与接入方式见 [`.dsh/README.md`](.dsh/README.md)（双语）。

## License / 许可证

[MIT](LICENSE)