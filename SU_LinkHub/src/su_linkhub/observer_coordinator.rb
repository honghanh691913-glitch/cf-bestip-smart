# frozen_string_literal: true

module GavinTools
  module SULinkHubMultiSpace
    module Runtime
    class CoordinateModelObserver < Sketchup::ModelObserver
      def onPreSaveModel(model)
        GavinTools::SULinkHubMultiSpace::Runtime.write_coordinate_metadata_for_model(model)
      rescue StandardError
        nil
      end

      def onSaveModel(model)
        GavinTools::SULinkHubMultiSpace::Runtime.write_coordinate_metadata_for_model(model)
      rescue StandardError
        nil
      end

      def onPostSaveModel(model)
        GavinTools::SULinkHubMultiSpace::Runtime.write_coordinate_metadata_for_model(model)
      rescue StandardError
        nil
      end

      def onTransactionCommit(model)
        runtime = GavinTools::SULinkHubMultiSpace::Runtime
        return if runtime.internal_sync_active?
        # ModelObserver 回调必须保持只读。过去这里直接同步原生锁定状态，
        # 同步过程中会写实体属性和项目 JSON，污染刚完成的移动/缩放事务，
        # 甚至让 Undo 看起来完全失效。这里仅安排空闲帧检查：软装清单刷新与
        # 空间内部原生锁定防误操作都在回调结束之后真正执行。
        runtime.soft_model_transaction_committed(model)
        runtime.schedule_space_internal_lock_guard(model, 0.025)
        runtime.linked_space_copy_transaction_committed(model)
      rescue StandardError
        nil
      end

      def onTransactionUndo(model)
        GavinTools::SULinkHubMultiSpace::Runtime.native_history_transaction_finished(model)
        GavinTools::SULinkHubMultiSpace::Runtime.soft_model_transaction_committed(model)
        GavinTools::SULinkHubMultiSpace::Runtime.schedule_space_internal_lock_guard(model, 0.04)
      rescue StandardError
        nil
      end

      def onTransactionRedo(model)
        GavinTools::SULinkHubMultiSpace::Runtime.native_history_transaction_finished(model)
        GavinTools::SULinkHubMultiSpace::Runtime.soft_model_transaction_committed(model)
        GavinTools::SULinkHubMultiSpace::Runtime.schedule_space_internal_lock_guard(model, 0.04)
      rescue StandardError
        nil
      end

      def onActivePathChanged(model)
        # 这里只安排空闲处理；ModelObserver 回调自身绝不写模型，继续遵守
        # v0.9.14 的撤回隔离约束。
        GavinTools::SULinkHubMultiSpace::Runtime.space_active_path_changed(model)
      rescue StandardError
        nil
      end

      def onDeleteModel(model)
        # 模型真正关闭时只清理当前进程拥有的外部锁文件，不写模型状态，
        # 因此“关闭但不保存”也不会把协作占用遗留在共享目录。
        GavinTools::SULinkHubMultiSpace::Runtime.release_model_collaboration_locks!(model)
        GavinTools::SULinkHubMultiSpace::Runtime.forget_coordinate_model_observer(model)
        GavinTools::SULinkHubMultiSpace::Runtime.forget_workspace_toolbar_selection_observer(model)
        GavinTools::SULinkHubMultiSpace::Runtime.forget_workspace_double_click_tools_observer(model)
        GavinTools::SULinkHubMultiSpace::Runtime.forget_soft_model_caches(model)
        GavinTools::SULinkHubMultiSpace::Runtime.forget_shared_component_caches(model)
      rescue StandardError
        nil
      end
    end

    # 受管软装实例的外层变换或动态属性发生变化时，立即标记清单过期。
    # 同一个观察器可以安全挂接到多个 ComponentInstance / Group；这里只做轻量
    # 版本递增与延迟刷新，不在观察器回调中执行完整项目扫描。
    class SoftMeasurementEntityObserver < Sketchup::EntityObserver
      def onChangeEntity(entity)
        model = entity.respond_to?(:model) ? entity.model : Sketchup.active_model
        GavinTools::SULinkHubMultiSpace::Runtime.soft_measurement_entity_changed(entity, model)
      rescue StandardError
        nil
      end

      def onEraseEntity(entity)
        model = entity.respond_to?(:model) ? entity.model : Sketchup.active_model
        GavinTools::SULinkHubMultiSpace::Runtime.soft_measurement_entity_changed(entity, model)
      rescue StandardError
        nil
      end
    end

    # v0.13.6.150：单件家具编辑不能只依赖 ModelObserver#onTransactionCommit。
    # SketchUp 在复杂真模型里有时会先发 active_path 退层，再补最后一次事务提交；旧版
    # 因此会在“真模型直接双击编辑”路径上把真实修改误判成未修改。这里对当前真正
    # 正在编辑的 Entities 集合挂一个极轻量观察器，只做布尔脏标记，不扫描几何、不访问文件。
    class SoftIndividualEditEntitiesObserver < Sketchup::EntitiesObserver
      def initialize(model)
        @model = model
      end

      def onElementAdded(_entities, _entity)
        notify
      end

      def onElementRemoved(_entities, _entity_id)
        notify
      end

      def onElementModified(_entities, _entity)
        notify
      end

      def onEraseEntities(_entities)
        notify
      end

      private

      def notify
        GavinTools::SULinkHubMultiSpace::Runtime.mark_soft_individual_edit_entities_change!(@model)
      rescue StandardError
        nil
      end
    end

    # 选择变化使用 SketchUp 原生事件刷新，不再由网页每 650ms 轮询 Ruby。
    # 回调只安排一次只读 UI 刷新，绝不写模型或启动 operation。
    class SoftSelectionObserver < Sketchup::SelectionObserver
      def onSelectionAdded(_selection, _entity)
        GavinTools::SULinkHubMultiSpace::Runtime.soft_selection_changed(Sketchup.active_model)
      rescue StandardError
        nil
      end

      def onSelectionRemoved(_selection, _entity)
        GavinTools::SULinkHubMultiSpace::Runtime.soft_selection_changed(Sketchup.active_model)
      rescue StandardError
        nil
      end

      def onSelectionCleared(_selection)
        GavinTools::SULinkHubMultiSpace::Runtime.soft_selection_changed(Sketchup.active_model)
      rescue StandardError
        nil
      end

      def onSelectionBulkChange(_selection)
        GavinTools::SULinkHubMultiSpace::Runtime.soft_selection_changed(Sketchup.active_model)
      rescue StandardError
        nil
      end
    end

    # 顶部快捷条需要在抽屉收起时仍能感知“选中了哪个空间”。
    # 使用独立选择观察器，避免软装库关闭时 detach_soft_selection_observer
    # 把快捷条的选择联动一并移除。
    class WorkspaceToolbarSelectionObserver < Sketchup::SelectionObserver
      def initialize(model)
        @model = model
      end

      def onSelectionAdded(_selection, _entity)
        notify
      end

      def onSelectionRemoved(_selection, _entity)
        notify
      end

      def onSelectionCleared(_selection)
        notify
      end

      def onSelectionBulkChange(_selection)
        notify
      end

      private

      def notify
        runtime = GavinTools::SULinkHubMultiSpace::Runtime
        runtime.workspace_toolbar_selection_changed(@model)
        # 第一次单击受管根组件时记住候选，并临时压入轻量桥接工具。
        # 第二次点击会用 PickHelper 确认仍位于同一根组件，再进入修改。
        runtime.arm_workspace_double_click_candidate(@model)
      rescue StandardError
        nil
      end
    end

    # 保留 ToolsObserver 作为旧版兼容回退。SU 2026 的 SelectionTool 不一定
    # 上报可用的双击状态，因此实际双击识别优先使用下方轻量桥接工具。
    class WorkspaceDoubleClickToolsObserver < Sketchup::ToolsObserver
      SELECTION_TOOL_ID = 21_022

      def initialize(model)
        @model = model
      end

      def onActiveToolChanged(_tools, tool_name, tool_id)
        GavinTools::SULinkHubMultiSpace::Runtime.workspace_double_click_tool_changed(
          @model, tool_name, tool_id
        )
      rescue StandardError
        nil
      end

      def onToolStateChanged(_tools, tool_name, tool_id, tool_state)
        GavinTools::SULinkHubMultiSpace::Runtime.workspace_double_click_tool_action(
          @model, tool_name, tool_id, tool_state
        )
      rescue StandardError
        nil
      end
    end

    # 原生 SelectionTool 对已经锁定的组件不会向扩展暴露可靠的双击事件，
    # SelectionObserver 也只会在第一次选中时触发一次。这里在第一次选中本专业
    # 锁定工作模型后临时压入一个极轻量桥接工具：它不绘制、不修改模型，只接收
    # 下一次左键并用 PickHelper 确认仍点在同一根组件上。这样既能稳定识别双击，
    # 又不会长期替换 SketchUp 原生选择工具。
    class WorkspaceDoubleClickBridgeTool
      CONFIRM_SIZE = 40.0
      CONFIRM_GAP = 10.0
      CONFIRM_BUTTONS_W = CONFIRM_SIZE * 2 + CONFIRM_GAP
      CONFIRM_W = 104.0
      CONFIRM_TITLE_H = 26.0

      def initialize(model, signature)
        @model = model
        @signature = signature.to_s
        @soft_edit_confirm = false
        @soft_edit_confirm_ready = false
        @confirm_x = 0
        @confirm_y = 0
        @confirm_hover = nil
        @confirm_title = '是否进入？'
        @confirm_kind = :generic
        # 普通双击侦测期间只允许极小鼠标抖动；一旦用户明显移向其它对象，
        # 立即退出桥接 Tool，把后续 Shift/Ctrl 复选交回 SketchUp 原生选择工具。
        @passive_pointer_x = nil
        @passive_pointer_y = nil
      end

      attr_reader :model, :signature

      def soft_edit_confirmation_active?
        @soft_edit_confirm == true
      end

      def show_soft_edit_confirmation(x, y, view)
        @soft_edit_confirm = true
        @soft_edit_confirm_ready = false
        @confirm_title = '是否进入？'
        @confirm_kind = :soft_proxy
        # “是”的圆心位于双击点附近；标题与两个圆按钮作为整体限制在视口内。
        @confirm_x = x.to_f - CONFIRM_SIZE / 2 - (CONFIRM_W - CONFIRM_BUTTONS_W) / 2
        @confirm_y = y.to_f - CONFIRM_SIZE / 2
        fit_soft_edit_confirmation(view)
        @confirm_hover = soft_edit_confirmation_action_at(x, y)
        # 理论上 SketchUp 会紧接着发 onLButtonDoubleClick 来结束本次双击；
        # 少数鼠标/系统设置只给两次 Down 时，用一个很短的兜底让下一次真正单击可确认。
        UI.start_timer(0.22, false) { mark_soft_edit_confirmation_ready! if soft_edit_confirmation_active? } rescue nil
        view.invalidate if view
        true
      rescue StandardError
        false
      end

      def show_workspace_switch_confirmation(role_label, x, y, view)
        @soft_edit_confirm = true
        @soft_edit_confirm_ready = false
        @confirm_title = "进入#{role_label}工作区？"
        @confirm_kind = :workspace_switch
        @confirm_x = x.to_f - CONFIRM_SIZE / 2 - (CONFIRM_W - CONFIRM_BUTTONS_W) / 2
        @confirm_y = y.to_f - CONFIRM_SIZE / 2
        fit_soft_edit_confirmation(view)
        @confirm_hover = soft_edit_confirmation_action_at(x, y)
        UI.start_timer(0.22, false) { mark_soft_edit_confirmation_ready! if soft_edit_confirmation_active? } rescue nil
        view.invalidate if view
        true
      rescue StandardError
        false
      end

      def clear_soft_edit_confirmation(view = nil)
        @soft_edit_confirm = false
        @soft_edit_confirm_ready = false
        @confirm_hover = nil
        @confirm_title = '是否进入？'
        @confirm_kind = :generic
        view.invalidate if view
        true
      rescue StandardError
        false
      end

      def mark_soft_edit_confirmation_ready!
        @soft_edit_confirm_ready = true if soft_edit_confirmation_active?
        true
      rescue StandardError
        false
      end

      def soft_edit_confirmation_ready?
        soft_edit_confirmation_active? && @soft_edit_confirm_ready == true
      end

      def fit_soft_edit_confirmation(view)
        return unless view
        @confirm_x = [[@confirm_x.to_f, 6.0].max, [view.vpwidth.to_f - CONFIRM_W - 6.0, 6.0].max].min
        @confirm_y = [[@confirm_y.to_f, CONFIRM_TITLE_H + 6.0].max, [view.vpheight.to_f - CONFIRM_SIZE - 6.0, CONFIRM_TITLE_H + 6.0].max].min
      end

      def soft_edit_confirmation_action_at(x, y)
        return nil unless soft_edit_confirmation_active?
        fit_soft_edit_confirmation(@model.active_view)
        radius = CONFIRM_SIZE / 2
        cy = @confirm_y + radius
        [:edit, :cancel].each_with_index do |action, index|
          buttons_x0 = @confirm_x + (CONFIRM_W - CONFIRM_BUTTONS_W) / 2
          cx = buttons_x0 + radius + index * (CONFIRM_SIZE + CONFIRM_GAP)
          return action if (x.to_f - cx)**2 + (y.to_f - cy)**2 <= radius**2
        end
        nil
      rescue StandardError
        nil
      end

      def draw_confirm_shape(view, points, fill, border = nil)
        center = Geom::Point3d.new(points.sum(&:x) / points.length, points.sum(&:y) / points.length, 0)
        triangles = points.each_index.flat_map { |i| [center, points[i], points[(i + 1) % points.length]] }
        view.drawing_color = fill
        view.draw2d(GL_TRIANGLES, triangles)
        if border
          view.drawing_color = border
          view.draw2d(GL_LINE_LOOP, points)
        end
      end

      def draw_confirm_text(view, cx, cy, label, size)
        options = { color: Sketchup::Color.new(255, 255, 255, 245), size: size, bold: false }
        origin = Geom::Point3d.new(0, 0, 0)
        bounds = view.text_bounds(origin, label, options)
        point = Geom::Point3d.new(cx - bounds.width / 2, cy - bounds.height / 2, 0)
        view.draw_text(point, label, options)
      rescue StandardError
        view.draw_text(Geom::Point3d.new(cx - label.length * size / 2, cy - size * 0.7, 0), label, options)
      end

      def draw(view)
        return unless soft_edit_confirmation_active? && view
        fit_soft_edit_confirmation(view)
        view.line_stipple = ''
        view.line_width = 1
        x0, y0 = @confirm_x, @confirm_y
        # 紧凑半透明标题底，浅色/深色模型背景上都可辨认。
        title_points = []
        radius = 10.0
        [[x0 + radius, y0 - 14, 180], [x0 + CONFIRM_W - radius, y0 - 14, 270],
         [x0 + CONFIRM_W - radius, y0 - 12, 0], [x0 + radius, y0 - 12, 90]].each do |cx, cy, start|
          (0..6).each do |step|
            angle = (start + step * 15) * Math::PI / 180
            title_points << Geom::Point3d.new(cx + Math.cos(angle) * radius, cy + Math.sin(angle) * radius, 0)
          end
        end
        draw_confirm_shape(view, title_points, Sketchup::Color.new(49, 51, 60, 165))
        draw_confirm_text(view, x0 + CONFIRM_W / 2, y0 - 13, @confirm_title.to_s, 10)
        [:edit, :cancel].each_with_index do |action, index|
          buttons_x0 = x0 + (CONFIRM_W - CONFIRM_BUTTONS_W) / 2
          cx = buttons_x0 + CONFIRM_SIZE / 2 + index * (CONFIRM_SIZE + CONFIRM_GAP)
          cy = y0 + CONFIRM_SIZE / 2
          points = (0...48).map do |i|
            angle = i * Math::PI * 2 / 48
            Geom::Point3d.new(cx + Math.cos(angle) * CONFIRM_SIZE / 2, cy + Math.sin(angle) * CONFIRM_SIZE / 2, 0)
          end
          alpha = @confirm_hover == action ? 215 : 155
          fill = action == :edit ? Sketchup::Color.new(56, 119, 84, alpha) : Sketchup::Color.new(80, 78, 94, alpha)
          draw_confirm_shape(view, points, fill, Sketchup::Color.new(255, 255, 255, 150))
          draw_confirm_text(view, cx, cy, index.zero? ? '是' : '否', 12)
        end
      rescue StandardError
        nil
      ensure
        if view
          view.line_stipple = ''
          view.line_width = 1
        end
      end

      def onMouseMove(_flags, x, y, view)
        unless soft_edit_confirmation_active?
          if @passive_pointer_x.nil? || @passive_pointer_y.nil?
            @passive_pointer_x = x.to_f
            @passive_pointer_y = y.to_f
            return false
          end
          dx = x.to_f - @passive_pointer_x.to_f
          dy = y.to_f - @passive_pointer_y.to_f
          threshold = GavinTools::SULinkHubMultiSpace::Runtime::WORKSPACE_DOUBLE_CLICK_POINTER_RELEASE_PX.to_f
          if (dx * dx + dy * dy) >= threshold * threshold
            GavinTools::SULinkHubMultiSpace::Runtime.workspace_double_click_bridge_pointer_moved_away(@model, self)
          end
          return false
        end
        @confirm_hover = soft_edit_confirmation_action_at(x, y)
        view.invalidate if view
        true
      rescue StandardError
        false
      end

      def activate
        GavinTools::SULinkHubMultiSpace::Runtime.workspace_double_click_bridge_activated(
          @model, self, @signature
        )
      rescue StandardError
        nil
      end

      def deactivate(_view)
        GavinTools::SULinkHubMultiSpace::Runtime.workspace_double_click_bridge_deactivated(
          @model, self
        )
      rescue StandardError
        nil
      end

      def onLButtonDown(_flags, x, y, view)
        if soft_edit_confirmation_active?
          # 确认框可能正好在第二次按下时出现；同一双击手势剩余的 Down 事件不能
          # 被误算成用户的“第三下确认”。等 onLButtonDoubleClick 收尾后才接受下一次单击。
          return true unless soft_edit_confirmation_ready?
          GavinTools::SULinkHubMultiSpace::Runtime.workspace_double_click_confirmation_click(
            @model, self, @signature, x, y, view
          )
        else
          GavinTools::SULinkHubMultiSpace::Runtime.workspace_double_click_bridge_click(
            @model, self, @signature, x, y, view, false
          )
        end
      rescue StandardError
        nil
      end

      def onLButtonDoubleClick(_flags, x, y, view)
        # 同一次双击的 DoubleClick 回调只负责结束双击手势并“解锁第三下”，
        # 绝不在这里直接点击确认按钮。
        if soft_edit_confirmation_active?
          mark_soft_edit_confirmation_ready!
          return true
        end
        result = GavinTools::SULinkHubMultiSpace::Runtime.workspace_double_click_bridge_click(
          @model, self, @signature, x, y, view, true
        )
        mark_soft_edit_confirmation_ready! if soft_edit_confirmation_active?
        result
      rescue StandardError
        nil
      end

      def onCancel(reason, view)
        # v0.13.6.100：家具确认框本身拥有一次 ESC——只关闭“是否编辑真模型”确认，
        # 绝不能顺便退出空间。用户若要继续退层，再按下一次 ESC 交还给统一退层事务。
        if soft_edit_confirmation_active?
          clear_soft_edit_confirmation(view)
          GavinTools::SULinkHubMultiSpace::Runtime.cancel_workspace_double_click_bridge(@model, self)
          return true
        end
        # v0.13.6.94：这个桥接 Tool 是 push_tool 临时压在 SketchUp 原生 SelectionTool
        # 上面的。旧版这里只 pop 自己，导致用户按 ESC 时真正的“退出组件编辑层级”
        # 被桥接 Tool 吞掉；如果选择观察器随后再次武装桥接，就会表现为 ESC 怎么按都
        # 退不出空间，而发布因为直接 active_path=nil 反而能退出。
        # 现在把用户 ESC 明确转交给 LinkHub 的安全退层逻辑：先卸载桥接 Tool，
        # 下一空闲帧再退 active_path 一级，避免在 Tool#onCancel 回调内部直接改编辑上下文。
        GavinTools::SULinkHubMultiSpace::Runtime.workspace_double_click_bridge_cancelled(
          @model, self, reason
        )
      rescue StandardError
        nil
      end
    end

    # v0.13.6.151：家具编辑退出后的“是否立即更新代理”就地确认。
    # 与双击进入确认保持同一视觉语言，但语义不同：默认/取消都等价于“否”，
    # 即保存真模型修改并把代理刷新留到退出空间后的统一批处理；“是”则优先刷新
    # 当前这一款并在完成后把受影响实例切回最新六面代理。
    class SoftIndividualEditExitConfirmTool
      CONFIRM_SIZE = 40.0
      CONFIRM_GAP = 10.0
      CONFIRM_BUTTONS_W = CONFIRM_SIZE * 2 + CONFIRM_GAP
      CONFIRM_W = 112.0
      CONFIRM_TITLE_H = 26.0

      def initialize(model, token, x = nil, y = nil)
        @model = model
        @token = token.to_s
        @resolved = false
        @confirm_hover = :cancel
        @confirm_x = x.nil? ? nil : x.to_f
        @confirm_y = y.nil? ? nil : y.to_f
      end

      def activate
        view = @model.active_view rescue nil
        if view
          if @confirm_x.nil? || @confirm_y.nil?
            @confirm_x = view.vpwidth.to_f * 0.5 - CONFIRM_W * 0.5
            @confirm_y = view.vpheight.to_f * 0.5 - CONFIRM_SIZE * 0.5
          else
            @confirm_x = @confirm_x.to_f - CONFIRM_SIZE / 2 - (CONFIRM_W - CONFIRM_BUTTONS_W) / 2
            @confirm_y = @confirm_y.to_f - CONFIRM_SIZE / 2
          end
          fit(view)
          view.invalidate
        end
      rescue StandardError
        nil
      end

      def deactivate(view)
        view.invalidate if view
        return if @resolved
        @resolved = true
        runtime = GavinTools::SULinkHubMultiSpace::Runtime
        runtime.runtime_start_timer(
          0.01, false, label: '家具编辑退出确认默认取消', model: @model, active_model_only: false
        ) do
          runtime.soft_individual_edit_exit_confirmation_choice!(
            @model, @token, :cancel, tool_already_gone: true
          )
        end
      rescue StandardError
        nil
      end

      def onMouseMove(_flags, x, y, view)
        @confirm_hover = action_at(x, y) || :cancel
        view.invalidate if view
        true
      rescue StandardError
        false
      end

      def onLButtonDown(_flags, x, y, view)
        resolve(action_at(x, y) || :cancel, view)
      rescue StandardError
        false
      end

      def onCancel(_reason, view)
        resolve(:cancel, view)
      rescue StandardError
        false
      end

      def onKeyDown(key, _repeat, _flags, view)
        # Enter/Space 采用默认“否”；Y 作为快捷“是”。
        return resolve(:edit, view) if [89, 121].include?(key.to_i)
        return resolve(:cancel, view) if [13, 27, 32].include?(key.to_i)
        false
      rescue StandardError
        false
      end

      def resolve(action, view = nil)
        return true if @resolved
        @resolved = true
        GavinTools::SULinkHubMultiSpace::Runtime.soft_individual_edit_exit_confirmation_choice!(
          @model, @token, action == :edit ? :edit : :cancel
        )
        view.invalidate if view
        true
      end

      def fit(view)
        return unless view
        @confirm_x = [[@confirm_x.to_f, 6.0].max, [view.vpwidth.to_f - CONFIRM_W - 6.0, 6.0].max].min
        @confirm_y = [[@confirm_y.to_f, CONFIRM_TITLE_H + 6.0].max, [view.vpheight.to_f - CONFIRM_SIZE - 6.0, CONFIRM_TITLE_H + 6.0].max].min
      end

      def action_at(x, y)
        view = @model.active_view rescue nil
        fit(view) if view
        radius = CONFIRM_SIZE / 2
        cy = @confirm_y.to_f + radius
        [:edit, :cancel].each_with_index do |action, index|
          buttons_x0 = @confirm_x.to_f + (CONFIRM_W - CONFIRM_BUTTONS_W) / 2
          cx = buttons_x0 + radius + index * (CONFIRM_SIZE + CONFIRM_GAP)
          return action if (x.to_f - cx)**2 + (y.to_f - cy)**2 <= radius**2
        end
        nil
      rescue StandardError
        nil
      end

      def draw_shape(view, points, fill, border = nil)
        center = Geom::Point3d.new(points.sum(&:x) / points.length, points.sum(&:y) / points.length, 0)
        triangles = points.each_index.flat_map { |i| [center, points[i], points[(i + 1) % points.length]] }
        view.drawing_color = fill
        view.draw2d(GL_TRIANGLES, triangles)
        if border
          view.drawing_color = border
          view.draw2d(GL_LINE_LOOP, points)
        end
      end

      def draw_text(view, cx, cy, label, size)
        options = { color: Sketchup::Color.new(255, 255, 255, 245), size: size, bold: false }
        bounds = view.text_bounds(Geom::Point3d.new(0, 0, 0), label, options)
        view.draw_text(Geom::Point3d.new(cx - bounds.width / 2, cy - bounds.height / 2, 0), label, options)
      rescue StandardError
        view.draw_text(Geom::Point3d.new(cx - label.to_s.length * size / 2, cy - size * 0.7, 0), label.to_s, options)
      end

      def draw(view)
        return unless view
        fit(view)
        x0, y0 = @confirm_x.to_f, @confirm_y.to_f
        title_points = []
        radius = 10.0
        [[x0 + radius, y0 - 14, 180], [x0 + CONFIRM_W - radius, y0 - 14, 270],
         [x0 + CONFIRM_W - radius, y0 - 12, 0], [x0 + radius, y0 - 12, 90]].each do |cx, cy, start|
          (0..6).each do |step|
            angle = (start + step * 15) * Math::PI / 180
            title_points << Geom::Point3d.new(cx + Math.cos(angle) * radius, cy + Math.sin(angle) * radius, 0)
          end
        end
        draw_shape(view, title_points, Sketchup::Color.new(49, 51, 60, 175))
        draw_text(view, x0 + CONFIRM_W / 2, y0 - 13, '立即更新本次？', 10)
        [:edit, :cancel].each_with_index do |action, index|
          buttons_x0 = x0 + (CONFIRM_W - CONFIRM_BUTTONS_W) / 2
          cx = buttons_x0 + CONFIRM_SIZE / 2 + index * (CONFIRM_SIZE + CONFIRM_GAP)
          cy = y0 + CONFIRM_SIZE / 2
          points = (0...48).map do |i|
            angle = i * Math::PI * 2 / 48
            Geom::Point3d.new(cx + Math.cos(angle) * CONFIRM_SIZE / 2, cy + Math.sin(angle) * CONFIRM_SIZE / 2, 0)
          end
          # 默认“否”视觉上更亮；鼠标经过“是”后才提升绿色按钮。
          hovered = (@confirm_hover == action)
          alpha = hovered ? 220 : (action == :cancel ? 190 : 145)
          fill = action == :edit ? Sketchup::Color.new(56, 119, 84, alpha) : Sketchup::Color.new(88, 84, 102, alpha)
          draw_shape(view, points, fill, Sketchup::Color.new(255, 255, 255, 150))
          draw_text(view, cx, cy, index.zero? ? '是' : '否', 12)
        end
      rescue StandardError
        nil
      ensure
        if view
          view.line_stipple = ''
          view.line_width = 1
        end
      end
    end

    class CoordinateAppObserver < Sketchup::AppObserver
      def expectsStartupModelNotifications
        true
      end

      def onNewModel(model)
        GavinTools::SULinkHubMultiSpace::Runtime.attach_coordinate_observer(model)
        GavinTools::SULinkHubMultiSpace::Runtime.handle_active_model_for_status_card(model)
        GavinTools::SULinkHubMultiSpace::Runtime.handle_active_model_for_workspace_toolbar(model)
      rescue StandardError
        nil
      end

      def onOpenModel(model)
        GavinTools::SULinkHubMultiSpace::Runtime.attach_coordinate_observer(model)
        GavinTools::SULinkHubMultiSpace::Runtime.schedule_soft_bounds_repair!(model)
        GavinTools::SULinkHubMultiSpace::Runtime.handle_active_model_for_status_card(model)
        GavinTools::SULinkHubMultiSpace::Runtime.handle_active_model_for_workspace_toolbar(model)
      rescue StandardError
        nil
      end

      def onActivateModel(model)
        GavinTools::SULinkHubMultiSpace::Runtime.attach_coordinate_observer(model)
        GavinTools::SULinkHubMultiSpace::Runtime.schedule_soft_bounds_repair!(model)
        GavinTools::SULinkHubMultiSpace::Runtime.handle_active_model_for_status_card(model)
        GavinTools::SULinkHubMultiSpace::Runtime.handle_active_model_for_workspace_toolbar(model)
      rescue StandardError
        nil
      end

      def onQuit
        # 正常退出 SketchUp 时主动释放全部本进程锁。真正崩溃无法执行回调，
        # 由锁记录中的本机 PID 存活检查在下次打开时立即回收。
        GavinTools::SULinkHubMultiSpace::Runtime.release_all_model_collaboration_locks!
      rescue StandardError
        nil
      end
    end

    end
  end
end
