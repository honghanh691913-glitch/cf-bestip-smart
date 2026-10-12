# SU LinkHub 优化 — 交接文档（任何 agent 接手前先读）

本目录保存 SketchUp 插件 **SU LinkHub 多空间联动** 的源码、分步优化记录和每一步的 rbz 版本。
基线：仓库根目录 `SU_LinkHub_v0.13.6.192.rbz`（用户原始上传，不要修改它）。

## 目录结构

| 路径 | 说明 |
| --- | --- |
| `src/` | 插件源码（rbz 解压内容）。`src/su_linkhub.rb` 是加载器，`src/su_linkhub/*.rb` 是代码，`src/su_linkhub/ui/*.html` 是对话框。 |
| `tools/build_rbz.sh` | 从 `src/` 打包 rbz 到 `releases/`，会先对所有 .rb 做 `ruby -c` 语法检查，并核对两处版本号一致。 |
| `releases/` | 每一步完成后的 rbz 成品，文件名带版本号。 |
| `dev/` | 本地验证脚本（不进 rbz），例如 Excel 导出离线生成器。 |
| `WORKLOG.md` | 按时间顺序的分步工作记录：每步做了什么、改了哪些函数、验证结果、未完成项。 |
| `HANDOFF.md` | 本文件：总体需求、路线图、约定。 |

## 版本约定

- 版本号写在两处，必须一致：`src/su_linkhub.rb` 的 `EXTENSION_VERSION`、`src/su_linkhub/constants.rb` 的 `EXTENSION_VERSION`（同文件里的日志文件名也带版本号）。
- 本轮优化从 `0.13.7.1` 开始，每完成一步 +1。
- 每步新增 `src/CHANGELOG_v<版本>.txt`（中文，面向用户），并在 `src/su_linkhub/main.rb` 顶部注释加一行摘要（沿用原作者风格）。
- 运行 `tools/build_rbz.sh` 生成 `releases/SU_LinkHub_v<版本>.rbz` 并提交。

## 环境限制

- 沙箱里没有 SketchUp，只能做静态修改、`ruby -c` 语法检查和不依赖 SketchUp API 的离线测试（例如 xlsx 生成）。
- SketchUp API 只能在主线程调用；`UI.start_timer` 只是切片，不是后台线程。

## 用户需求总表（2026-10-12 原始需求整理）

1. **缩略图**：清单缩略图上加「刷新」「反转」按钮；同时生成两张对角轴测图（+X−Y+Z 与 −X+Y+Z），点击切换；选择写入库记录，库和清单同步，以后默认用选中的那张。入库/更新/六面代理完成后，在空闲时自动生成两张。轴改了以后缩略图要跟着更新。
2. **入库与六面代理**：目标是「无感」。决定：先做主线程优化（只在真正空闲时跑、降低分辨率、只改轴不整套重做、复用代理正面图、任务队列分开显示等待/计算时间），之后单独一步试验独立 SketchUp 进程后台渲染（代码里已有但被 `soft_visual_proxy_external_worker_supported?` 关闭）。
3. **清单合并**：同大类+子类+名称+尺寸+材质的行要合并（即使库里是两个不同 model_id）。另外模型库提示「发现重复模型」，可一键合并成一个库模型。
4. **清单刷新**：不能卡死（曾卡在 37% 超过 1500s）；尽量无感/增量，但不能像以前实时刷新那样一直卡。
5. **清单窗口**：梳理布局、空间切换、同步/修改/提交流程，更简洁美观。
6. **Excel 导出**：默认边框；按空间分区淡色底色（相邻空间可区分）；空间列去掉「17:」序号，字体稍大略加粗；排版整齐；统一行高；图片随单元格（用户 WPS 和 Excel 都用 → 浮动图片但锚定为随单元格移动和缩放 twoCellAnchor editAs=twoCell）；点击查看的图片更高清。
7. **朝向相机的片状组件**（`always_face_camera?`）：不转代理、尺寸保持一致、保持原样；但要入库并计入清单；缩略图用朝向相机的正面（正视图，不用轴测）；Excel 同样。
8. 其他发现的可优化点：先向用户提出，用户确认后再做。

## 路线图（状态以 WORKLOG.md 为准）

| 步骤 | 版本 | 内容 |
| --- | --- | --- |
| 0 | 0.13.6.192 | 基线源码入库、交接文档、打包脚本 |
| 1 | 0.13.7.1 | Excel 导出美化（需求 6） |
| 2 | 0.13.7.2 | 清单合并 + 库重复模型提示/合并 + 刷新不卡死（需求 3、4） |
| 3 | 0.13.7.3 | 双轴测缩略图 + 刷新/反转 + 偏好同步 + 片状朝向相机组件（需求 1、7） |
| 4 | 0.13.7.4 | 六面代理/入库主线程优化（需求 2 第一阶段） |
| 5 | 0.13.7.5 | 清单窗口布局梳理（需求 5） |
| 6 | 待定 | 独立进程后台渲染试验（需求 2 第二阶段） |

## 关键代码位置（v0.13.6.192 行号，改动后会漂移，用函数名搜索）

- Excel：`export_soft_schedule_xlsx`、`write_soft_schedule_xlsx!`、`xlsx_worksheet_xml`、`xlsx_drawing_xml`、`soft_schedule_export_common`（runtime.rb ~33800–34660）。
- 清单收集/合并：`each_soft_model_occurrence`（variant_key）、`merge_soft_measurement_space_rows`、`soft_schedule_apply_unique_display_names!`、`soft_project_schedule_data`。
- 清单刷新：`refresh_soft_schedule_dialog`、`start_soft_schedule_progressive_project_refresh!`、`soft_schedule_refresh_task_progress`、`soft_measurement_rows_cached`。
- 缩略图：`soft_source_thumbnail_camera`、`write_standard_thumbnail_into_source_skp!`、`render_standard_soft_model_thumbnail`（保留但未调用）、`soft_model_thumbnail_path`、`send_soft_thumbnail_updates`、`enrich_soft_measurement_rows!`。
- 六面代理：`proxy_queue.rb`、`proxy_visual.rb`、`proxy_commit.rb`；独立进程开关 `soft_visual_proxy_external_worker_supported?`。
- 平面/片状：`soft_bounds_planar_reference?`；`always_face_camera?` 目前没有专门处理。
