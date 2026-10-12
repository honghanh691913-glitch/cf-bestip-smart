# SU LinkHub 优化工作记录

每一步完成后追加一节。格式：日期、版本、状态、改动、验证、遗留。

## 步骤 0 — 基线（2026-10-12）

- 版本：0.13.6.192（未改代码）
- 分支：`vorflux/linkhub-optimization-step1`
- 内容：把 `SU_LinkHub_v0.13.6.192.rbz` 解压到 `src/`；新增 `HANDOFF.md`、`WORKLOG.md`、`tools/build_rbz.sh`。
- 验证：`tools/build_rbz.sh` 重新打包后文件数与原 rbz 一致（374 个文件，总大小 4997523 字节）。
- 用户决定（2026-10-12 问答）：
  - Excel 用户 WPS 和 Excel 都会用 → 图片保持浮动绘图，但锚定为随单元格移动和缩放。
  - 清单合并：按大类+子类+名称+尺寸+材质合并，并在模型库加「重复模型」提示和一键合并。
  - 两张轴测图：入库/更新/六面代理完成后空闲自动生成。
  - 无感入库：先主线程优化，再试独立进程。
  - 步骤顺序：由 agent 决定，可一次全部完成，但每一步都要提交记录。

## 步骤 1 — Excel 导出排版（2026-10-12）

- 版本：0.13.7.1　状态：完成（离线验证通过；需用户在 WPS/Excel 实际打开确认）
- 成品：`releases/SU_LinkHub_v0.13.7.1.rbz`
- 改动（`src/su_linkhub/runtime.rb`）：
  - 新增 `soft_schedule_export_space_label`（去“17:”前缀）、`soft_schedule_expand_rows_by_space`（项目总行按空间拆分，写 `_export_group`）、`soft_schedule_export_sort_rows`、`soft_schedule_export_row_groups`。
  - `soft_schedule_summary_table` / `soft_schedule_category_table` 返回第 4 个元素 row_groups；summary 支持 `title_override`。
  - `export_soft_schedule_xlsx`：总表/分类表用按空间拆分后的行；全部导出时末尾加“按款汇总”表（原合并行）。
  - 新增 `XLSX_SPACE_FILLS` 等常量、`xlsx_body_style`、`xlsx_styles_xml`、`xlsx_text_display_width`、`xlsx_image_header?`、`xlsx_sheet_layout`。
  - 重写 `xlsx_worksheet_xml`（逐单元格样式、统一行高、打印设置）和 `xlsx_drawing_xml`（twoCellAnchor editAs="twoCell"，图片居中在单元格内）。
  - `write_soft_schedule_xlsx!`：sheet 携带 row_groups 和 layout；workbook.xml 增加 `_xlnm.Print_Titles`、`_xlnm._FilterDatabase`；styles 改用 `xlsx_styles_xml`。
- 新增工具：`tools/bump_version.sh`；`dev/xlsx_offline_test.rb`（从 runtime.rb 抽取导出方法离线生成 xlsx）。
- 验证：`ruby SU_LinkHub/dev/xlsx_offline_test.rb /tmp/t1.xlsx` 成功；openpyxl 能读取；LibreOffice 转 PDF 渲染正常（预览图 `dev/xlsx_v0.13.7.1_preview.png`）；拆分前后数量总和一致。
- 遗留：图片清晰度取决于缩略图源（SKP 内嵌缩略图分辨率低），在步骤 3 用 1024px 渲染图解决；导出优先级届时改为优先高清视图。

## 步骤 2 — 清单同款合并 + 重复模型 + 刷新不卡死（2026-10-12）

- 版本：0.13.7.2　状态：完成（离线单测通过；需在 SketchUp 实测）
- 成品：`releases/SU_LinkHub_v0.13.7.2.rbz`
- 根因：
  - 不合并：清单合并键是 `model_id|尺寸|材质`（`each_soft_model_occurrence`），同一家具入库两次得到两个 model_id，所以分成 #1/#2 两行。
  - 卡 37%：渐进刷新的定时器在窗口关闭/被顶替/被停时静默退出，任务队列记录不结束；再点刷新时 `soft_schedule_refresh_task_active?` 认为仍在运行，直接返回“无需重复启动”。37% = 12 + 75×(1/3)，即第 1/3 空间完成后停止。
- 改动（runtime.rb）：
  - 新增 `SOFT_SCHEDULE_PRIMARY_FIELDS`、`soft_schedule_merge_name`、`soft_schedule_merge_key`、`soft_schedule_row_member_ids`、`soft_schedule_row_member_variants`、`soft_schedule_absorb_row_identity!`、`soft_schedule_merge_equivalent_rows`；`soft_measurement_rows` 在 enrich 后调用合并；`merge_soft_measurement_space_rows` 按 merge_key 跨空间合并。原始 variant_key 不变，合并行带 `merge_key`/`variant_keys`/`merged_model_ids`/`merged_model_count`。
  - 尺寸同步（`record[:variants]` 查找处）按 `variant_keys` 全部成员匹配。
  - Excel 拆分按 `soft_schedule_export_row_key`（merge_key 优先）。
  - 重复模型：`soft_library_duplicate_name_key`、`soft_library_duplicate_member`、`soft_library_duplicate_groups`、`send_soft_library_duplicates`、`soft_library_set_merged_into!`、`merge_soft_library_duplicates`、`unmerge_soft_library_duplicate`；索引记录字段 `merged_into`/`merged_at`；`build_soft_library_items` 输出 `merged_into`；`enrich_soft_measurement_rows!` 对 merged_into 记录改用保留模型资料（`row['library_alias_of']`）。回调：`list_duplicate_models`、`merge_duplicate_models`、`unmerge_duplicate_model`。
  - 刷新：`soft_schedule_refresh_task_active?` 增加存活检查 `soft_schedule_refresh_alive?`（45 秒心跳）；渐进刷新拆为 `start_soft_schedule_progressive_timer!`、`run_soft_schedule_progressive_tick!`、看门狗 `start_soft_schedule_progressive_watchdog!`（12 秒无心跳续跑）、`abandon_soft_schedule_progressive_job!`；每个空间先推送“正在统计 n/N”再统计；>3 秒慢空间写日志。
- 改动（UI）：`soft_schedule.html` 合并行绿色标签 `mergedModelHtml`；`buildModelPayload` 为合并成员追加 `x:` 前缀的同款提交；`buildDimensionSyncPayload` 带 `variant_keys`。`soft_designer.html` 新增“重复模型”按钮与面板（`#dupPanel`），列表隐藏 `merged_into` 模型。
- 工具：`dev/schedule_merge_test.rb`（合并单测）、`dev/check_ui_js.py`（HTML 内联 JS 语法检查，已接入 build_rbz.sh）。
- 验证：`ruby SU_LinkHub/dev/schedule_merge_test.rb` OK；xlsx 离线测试 OK；全部 .rb `ruby -c` OK；UI JS `node --check` OK。
- 遗留/风险：
  - 同款合并按名称判断：两个不同家具若名称、尺寸、材质完全一样也会合并（这是用户要求的规则）。
  - 单个空间统计本身仍是一次性递归（无法在空间内部切片）；如某空间特别慢，日志里会出现“采购清单单空间统计”慢记录，后续可针对性优化。

## 步骤 3 — 正反轴测缩略图 + 刷新/反转 + 朝向相机组件（2026-10-12）

- 版本：0.13.7.3　状态：完成（静态检查通过；渲染效果必须在 SketchUp 实测）
- 成品：`releases/SU_LinkHub_v0.13.7.3.rbz`
- 新文件 `src/su_linkhub/thumbnail_views.rb`（runtime.rb 在 image_media.rb 之后 Kernel.load）：
  - 视图文件：`_软装模型管理/缩略图/<id>.view_{a|b|front}.png`（512px）与 `.hd.png`（1024px）；有效条件：视图 mtime ≥ 源 SKP mtime。
  - 选择：缩略图索引 `缩略图索引.json` 新键 `view_prefs[<id>] = a|b|front`。
  - `apply_soft_thumbnail_preferred_view!` 把选中视图复制成标准缩略图 `<id>.png`，所有旧读取方自动同步。
  - 渲染 `render_soft_thumbnail_view!`：`with_soft_commit_world_context` + 可回滚 operation + 远端隔离（同六面代理），载入临时拷贝的源 SKP，`View#write_image` 白底；结束 abort 并清理临时定义。
  - 队列 `enqueue_soft_thumbnail_views!` / `process_soft_thumbnail_view_queue_tick!`（0.4s 定时器，每拍最多一张视图；非立即任务要求世界根层 + 空闲 1.2s + 不忙）。
  - 按钮入口 `handle_soft_thumbnail_view_action(model_id, 'flip'|'refresh'|'a'|'b')`。
  - 朝向相机判定 `soft_definition_face_camera?`（自身或薄包装内子组件 always_face_camera）。
- runtime.rb：`record_soft_thumbnail!` 新增 `apply_views:`（写标准图后自动换回选定视图）；入库校准定时器内排队视图；`refresh_thumbnail` 回调改为新流程；新增回调 `thumbnail_view_action`（模型库）、`schedule_thumbnail_view`（清单）；清单行与库条目带 `thumbnail_view`；Excel 优先 `soft_thumbnail_hd_path`；`build_soft_library_update_definition!` 对朝向相机源不压平并标记 `face_camera`、planar passthrough；`soft_definition_planar_reference?` 对朝向相机返回 true（不做六面代理）；新增 `soft_face_camera_dimensions_mm`，清单尺寸取朝向相机定义自身局部尺寸 × 缩放。
- proxy_queue.rb：`finish_soft_visual_proxy_candidate_success!` 完成后排队视图。
- UI：清单缩略图右上 ⟳/⇄ 按钮 + 左下视图标签（`data-thumb-act`）；模型库卡片 ⇄ 按钮（`data-flip-thumb`）。
- 验证：`ruby -c` 全部通过；UI JS 检查通过；合并单测通过。没有 SketchUp，无法验证截图效果。
- 需要用户实测确认：
  1. 清单/模型库点 ⇄ 能否立即切换；第一次点（还没生成）会排队生成，约 1–3 秒。
  2. 生成过程中视口是否有闪动（与六面代理相同的隔离方式）。
  3. 朝向相机组件入库后是否仍朝向相机、清单尺寸是否稳定。

## 步骤 4 — 六面代理主线程减负 第一阶段（2026-10-12）

- 版本：0.13.7.4　状态：完成（静态检查通过）
- 成品：`releases/SU_LinkHub_v0.13.7.4.rbz`
- 分析结论（静态）：空闲阈值本来就很短（0.28s/0.08s），250–900s 主要是任务卡片在排队/等待退出空间时就开始计时；真正的阻塞来自 `View#write_image`、`save_copy`、纯 Ruby 双底抠图，都在主线程。真正“零卡顿”只能靠独立进程（`soft_visual_proxy_external_worker_supported?` 目前固定返回 false）。
- 改动（proxy_queue.rb）：`begin_soft_visual_proxy_incremental_candidate_world` 自动任务统一 `SOFT_VISUAL_PROXY_BATCH_RESOLUTION`（128px），仅 `candidate[:priority]` 单款保留 192px；记录 `candidate[:active_started_at]`；`finish_soft_visual_proxy_candidate_success!` 的任务说明追加“实际生成 Ns”。
- 下一阶段候选（未做）：改轴时复用截图（需记录轴变化矩阵）、独立 SketchUp 进程渲染试验（需用户实测）。

## 步骤 5 — 清单窗口布局 + 审查修正（2026-10-12）

- 版本：0.13.7.5　状态：完成
- 成品：`releases/SU_LinkHub_v0.13.7.5.rbz`
- 布局（`ui/soft_schedule.html`，提交 754cc0d）：顶部主按钮 刷新/导出 Excel + 分类选择；“诊断 ▾”菜单（加载日志、提交报告）；底部粘性提交条（`提交资料修改`/`同步规格到模型`/`查看待提交`，沿用原按钮 id 与处理函数）；空间胶囊页签（数量、去编号）；状态筛选小按钮；模型变化黄色提示条。回调名称与 `window.SoftSchedule` 接口不变。
- 预览工具：`dev/schedule_preview.html`（浏览器里用模拟数据打开清单窗口，`?mode=drafts` 显示草稿/模型变化状态）。
- 审查修正（提交 3aca403 及本步）：
  - 别名行 `merged_model_ids` 加入保留模型 ID → 资料同时写保留模型；`applyResult` 中 `x:` 失败时保留对应草稿并显示原因。
  - 朝向相机：仅当被入库组件自身 always_face_camera 时不压平；压平循环绝不展开朝向相机子组件；`soft_face_camera_dimensions_mm` 穿过最多 6 层单子组件包装；`soft_definition_face_camera?` 深度 4。
  - 名称比较统一为 `soft_model_name_key`（清单合并与重复模型共用）。
- 审查结论：风险 6/10（中），建议在 SketchUp 中实测后发布。

## 步骤 6 — 缩略图去掉正反面文字（2026-10-12）

- 版本：0.13.7.6　状态：完成
- 用户反馈：没有绝对的正面/反面，用户选的那一面就是正面；只需要反转图标，不要文字。
- 改动：`soft_schedule.html` 删除 `.thumb-view-tag` 标签和 `viewName`；按钮提示改为中性说明；`soft_designer.html` 提示同步修改；`thumbnail_views.rb` 删除 `SOFT_THUMBNAIL_VIEW_LABELS`，状态提示改为“已反转/已更新”。内部视图键 a/b/front 不变（数据兼容）。
- 验证：`ruby -c`、UI JS 检查通过。
