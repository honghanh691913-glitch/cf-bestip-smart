# frozen_string_literal: true

module GavinTools
  module SULinkHubMultiSpace
    module Runtime
    class LibraryPipetteTool
      BOX_EDGES = [
        [0, 1], [1, 2], [2, 3], [3, 0],
        [4, 5], [5, 6], [6, 7], [7, 4],
        [0, 4], [1, 5], [2, 6], [3, 7]
      ].freeze

      def initialize(runtime, model, discipline)
        @runtime = runtime
        @model = model
        @discipline = discipline.to_s
        @target = nil
        @target_kind = ''
        @last_xy = nil
      end

      def activate
        update_status
        @model.active_view.invalidate
      rescue StandardError => e
        @runtime.log_exception('启动库吸管失败', e)
        @runtime.show_status("吸管启动失败：#{e.message}", 'error')
        @model.select_tool(nil) rescue nil
      end

      def onSetCursor
        cursor = @runtime.library_pipette_cursor_id
        return false unless cursor
        UI.set_cursor(cursor)
        true
      rescue StandardError
        false
      end

      def onMouseMove(_flags, x, y, view)
        xy = [x.to_i, y.to_i]
        return if @last_xy == xy
        @last_xy = xy
        @target, @target_kind = pick_target(view, x, y)
        view.tooltip = target_tooltip if view.respond_to?(:tooltip=)
        view.invalidate
      rescue StandardError => e
        @runtime.log_exception('更新库吸管拾取失败', e)
      end

      def onLButtonDown(_flags, x, y, view)
        @target, @target_kind = pick_target(view, x, y) unless @target && @target.valid?
        unless @target && @target.valid?
          UI.beep if UI.respond_to?(:beep)
          return
        end
        target = @target
        kind = @target_kind.to_s
        @runtime.with_soft_selection_refresh_suspended do
          @model.selection.clear
          @model.selection.add(target)
        end
        @model.select_tool(nil)
        # 退出 Tool 回调后再弹原生输入框，避免某些 SU 版本在鼠标回调中直接打开
        # UI.inputbox 时吞掉下一次点击或留下自定义光标。
        GavinTools::SULinkHubMultiSpace::Runtime.runtime_start_timer(0.01, false, label: 'library:pipette_commit') do
          begin
            @runtime.handle_library_pipette(@model, picked_kind: kind)
          rescue StandardError => e
            @runtime.log_exception('库吸管入库失败', e)
            @runtime.show_status(e.message.to_s, 'error')
          end
        end
      rescue StandardError => e
        @runtime.log_exception('库吸管确认失败', e)
        @runtime.show_status("吸管失败：#{e.message}", 'error')
        @model.select_tool(nil) rescue nil
      end

      def onCancel(_reason, view)
        view.invalidate if view
        @model.select_tool(nil) rescue nil
      end

      def deactivate(view)
        Sketchup.set_status_text('') if Sketchup.respond_to?(:set_status_text)
        view.invalidate if view
        @runtime.library_pipette_tool_finished(self) if @runtime.respond_to?(:library_pipette_tool_finished)
      rescue StandardError
        nil
      end

      def draw(view)
        return unless @target && @target.valid?
        if @target_kind == 'furniture' && @target.respond_to?(:bounds)
          box = @target.bounds
          return unless box && !box.empty?
          corners = (0..7).map { |i| box.corner(i) }
          points = BOX_EDGES.flat_map { |a, b| [corners[a], corners[b]] }
          view.line_width = 2 if view.respond_to?(:line_width=)
          view.draw(GL_LINES, points)
        elsif @target_kind == 'material' && @target.is_a?(Sketchup::Face)
          view.draw(GL_LINE_LOOP, @target.outer_loop.vertices.map(&:position))
        end
      rescue StandardError
        nil
      end

      private

      def update_status
        text = if @discipline == SOFT_SPACE_COLLECTION_KEY
                 '吸管：单击家具组件/群组入模型库；单击裸面吸取材质；Esc 取消'
               else
                 '材质吸管：单击有材质的面入库；Esc 取消'
               end
        Sketchup.set_status_text(text) if Sketchup.respond_to?(:set_status_text)
      end

      def target_tooltip
        return '没有可吸取的对象' unless @target && @target.valid?
        if @target_kind == 'furniture'
          name = @runtime.soft_library_selected_entity_name(@target)
          "吸取家具：#{name}"
        else
          '吸取当前面材质'
        end
      rescue StandardError
        '单击吸取'
      end

      def pick_target(view, x, y)
        helper = view.pick_helper
        count = helper.do_pick(x, y).to_i
        if @discipline == SOFT_SPACE_COLLECTION_KEY
          (0...count).each do |index|
            raw_path = helper.path_at(index) rescue nil
            path = raw_path.respond_to?(:to_a) ? raw_path.to_a : Array(raw_path)
            candidate = path.find do |entity|
              (entity.is_a?(Sketchup::ComponentInstance) || entity.is_a?(Sketchup::Group)) && entity.valid?
            end
            return [candidate, 'furniture'] if candidate
          end
        end
        face = helper.picked_face rescue nil
        face ||= begin
          best = helper.best_picked
          best if best.is_a?(Sketchup::Face)
        rescue StandardError
          nil
        end
        return [face, 'material'] if face && face.valid?
        [nil, '']
      rescue StandardError
        [nil, '']
      end
    end

    # 软装模型自定义放置工具。
    #
    # 旧版在鼠标移动前就把完整家具实例加入当前编辑层级，并在每一帧修改实例
    # transformation。高面数模型会因此持续重算几何、触发观察器，同时预览实例
    # 还可能被 InputPoint 自身捕捉，造成卡顿与落点漂移。
    #
    # 新版只绘制轻量外包框预览；单击确认时才创建一次真实实例。家具始终写入
    # 当前空间的根定义，而不是误写进用户偶然打开的某个家具/硬装子组件。
    class SoftPlacementTool
      KEY_TAB = defined?(VK_TAB) ? VK_TAB : 9
      KEY_LEFT = defined?(VK_LEFT) ? VK_LEFT : 37
      KEY_UP = defined?(VK_UP) ? VK_UP : 38
      KEY_RIGHT = defined?(VK_RIGHT) ? VK_RIGHT : 39
      KEY_DOWN = defined?(VK_DOWN) ? VK_DOWN : 40

      LEVELS = %i[bottom middle top].freeze
      LEVEL_LABELS = {
        bottom: '底部',
        middle: '中部',
        top: '顶部'
      }.freeze
      SIDE_LABELS = {
        center: '中心',
        front: '前面（+绿轴）',
        back: '背面（-绿轴）',
        left: '左面（-红轴）',
        right: '右面（+红轴）'
      }.freeze
      BOX_EDGES = [
        [0, 1], [1, 2], [2, 3], [3, 0],
        [4, 5], [5, 6], [6, 7], [7, 4],
        [0, 4], [1, 5], [2, 6], [3, 7]
      ].freeze

      def initialize(runtime, model, definition, library_item, target_entities, target_to_model, desired_representation = 'full', library_kind = 'soft', collaboration_context = nil)
        @runtime = runtime
        @model = model
        @definition = definition
        @library_item = library_item
        @target_entities = target_entities
        @target_to_model = target_to_model || Geom::Transformation.new
        @collaboration_context = collaboration_context.is_a?(Hash) ? collaboration_context : {}
        @target_inverse = @runtime.safe_inverse_transformation(@target_to_model, '当前放置上下文变换')
        @desired_representation = desired_representation.to_s == 'proxy' ? 'proxy' : 'full'
        @definition_representation = begin
          definition.get_attribute(SOFT_MODEL_DICT, 'representation', '').to_s
        rescue StandardError
          ''
        end
        @library_kind = library_kind.to_s == 'landscape' ? 'landscape' : 'soft'
        @library_label = @library_kind == 'landscape' ? '景观' : '软装'
        @input_point = Sketchup::InputPoint.new
        @side = :center
        @level = :bottom
        @instance = nil
        @operation_open = false
        @committed = false
        @last_model_point = nil
        @last_local_point = nil
        @last_mouse_xy = nil
        @last_pick_at = 0.0
        @current_pick_valid = false
        @bounds_values = @runtime.soft_definition_bounds_values(@definition)
        @anchor_points = build_anchor_points(@bounds_values)
        @local_bounds_corners = build_local_bounds_corners(@bounds_values)
        @preview_corners = []
      end

      def activate
        raise "当前#{@library_label}放置目标不可用。" unless @target_entities
        raise '模型有效几何外包盒无效。' unless @bounds_values && @bounds_values.length == 6
        @runtime.begin_soft_heavy_interaction(:placement) if @runtime.respond_to?(:begin_soft_heavy_interaction)
        update_status
        @model.active_view.invalidate
      rescue StandardError => e
        cleanup_failed_activation
        @runtime.log_exception("启动#{@library_label}放置工具失败", e)
        @runtime.show_status("放置失败：#{e.message}", 'error')
        @model.select_tool(nil) rescue nil
      end

      def onMouseMove(_flags, x, y, view)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        xy = [x.to_i, y.to_i]
        # 高刷新率鼠标可能在一帧内触发多次事件。重复坐标不再重复执行
        # InputPoint 推断，避免 SU 主线程在模型较复杂时被无意义 pick 占满。
        return if @last_mouse_xy == xy && (now - @last_pick_at) < 0.012
        @last_mouse_xy = xy
        @last_pick_at = now
        @input_point.pick(view, x, y)
        @current_pick_valid = @input_point.valid?
        unless @current_pick_valid
          @last_model_point = nil
          @last_local_point = nil
          @preview_corners = []
          view.invalidate
          return
        end

        # InputPoint#position 始终是模型世界坐标。这里转换到启动放置时的
        # SketchUp 当前编辑上下文坐标，根层级和任意嵌套组件使用同一套逻辑。
        @last_model_point = @input_point.position
        @last_local_point = @last_model_point.transform(@target_inverse)
        rebuild_preview_corners!
        view.tooltip = @input_point.tooltip if view.respond_to?(:tooltip=)
        view.invalidate
      rescue StandardError => e
        @runtime.log_exception('更新软装放置预览失败', e)
      end

      def onLButtonDown(_flags, x, y, view)
        # 鼠标按下通常紧接最后一次 onMouseMove。只有坐标变化或当前点无效时
        # 才重新 pick，避免确认放置时无条件执行第二次几何推断。
        onMouseMove(0, x, y, view) if @last_mouse_xy != [x.to_i, y.to_i] || !@current_pick_valid
        unless @current_pick_valid && @last_local_point
          UI.beep if UI.respond_to?(:beep)
          return
        end

        @model.start_operation("放置#{@library_label} #{@library_item['name']}", true)
        @operation_open = true
        @instance = @target_entities.add_instance(@definition, placement_transformation)
        raise 'SketchUp 未能创建家具实例。' unless @instance && @instance.valid?
        stamp_instance!
        # 放置结果必须与顶部“代/真”状态一致。旧版即使当前是代理模式，仍先
        # 放入真模型，而组件缓存又可能保持为空，于是按钮文字变化但视口不变。
        # 这里直接处理这个新实例，不扫描整个空间；首次创建方块代理后，后续
        # 放置同款只复用缓存定义。
        if @library_kind == 'soft' && @desired_representation == 'proxy' && @definition_representation != 'proxy'
          changed = @runtime.apply_space_soft_proxies!(nil, @model, instances: [@instance]).length
          raise '新放置家具未能建立代理，请检查模型库文件。' if changed.zero?
        elsif @library_kind == 'soft' && @desired_representation == 'proxy'
          @runtime.soft_set_attribute_if_changed(@instance, SOFT_MODEL_DICT, 'representation', 'proxy')
        end
        @runtime.with_soft_selection_refresh_suspended do
          @model.selection.clear
          @model.selection.add(@instance)
        end
        @model.commit_operation
        @operation_open = false
        @committed = true
        name = @library_item['name'].to_s
        @runtime.show_status("已放置 #{name} · #{anchor_label}", 'success')
        @runtime.schedule_soft_selection_refresh(@model, 0.12) if @runtime.respond_to?(:schedule_soft_selection_refresh)
        @model.select_tool(nil)
      rescue StandardError => e
        cancel_operation
        @runtime.log_exception("确认放置#{@library_label}模型失败", e)
        @runtime.show_status("放置失败：#{e.message}", 'error')
        @model.select_tool(nil) rescue nil
      end

      def onKeyDown(key, repeat, _flags, view)
        return false if repeat.to_i > 1
        handled = case key.to_i
                  when KEY_TAB
                    index = LEVELS.index(@level) || 0
                    @level = LEVELS[(index + 1) % LEVELS.length]
                    true
                  when KEY_UP
                    toggle_side(:front)
                    true
                  when KEY_DOWN
                    toggle_side(:back)
                    true
                  when KEY_LEFT
                    toggle_side(:left)
                    true
                  when KEY_RIGHT
                    toggle_side(:right)
                    true
                  else
                    false
                  end
        if handled
          rebuild_preview_corners!
          update_status
          view.invalidate
        end
        handled
      rescue StandardError => e
        @runtime.log_exception("切换#{@library_label}放置锚点失败", e)
        false
      end

      def onCancel(_reason, view)
        cancel_operation
        @runtime.show_status("已取消#{@library_label}模型放置。", 'info')
        view.invalidate if view
        @model.select_tool(nil) rescue nil
      end

      def deactivate(view)
        cancel_operation unless @committed
        Sketchup.set_status_text('') if Sketchup.respond_to?(:set_status_text)
        view.invalidate if view
      rescue StandardError
        nil
      ensure
        @runtime.end_soft_heavy_interaction(:placement) if @runtime.respond_to?(:end_soft_heavy_interaction)
        @runtime.soft_placement_tool_finished(self) if @runtime.respond_to?(:soft_placement_tool_finished)
      end

      def draw(view)
        @input_point.draw(view) if @input_point && @input_point.valid?
        points = preview_line_points
        return if points.empty?
        view.line_width = 2 if view.respond_to?(:line_width=)
        view.line_stipple = '' if view.respond_to?(:line_stipple=)
        view.draw(GL_LINES, points)
      rescue StandardError
        nil
      end

      def getExtents
        return @definition.bounds if @preview_corners.empty?
        box = Geom::BoundingBox.new
        @preview_corners.each { |point| box.add(point) }
        box
      rescue StandardError
        @definition.bounds
      end

      private

      def toggle_side(side)
        @side = (@side == side ? :center : side)
      end

      def anchor_label
        "#{SIDE_LABELS[@side]} · #{LEVEL_LABELS[@level]}"
      end

      def update_status
        message = "放置#{@library_label} #{@library_item['name']} · 当前：#{anchor_label}｜Tab 切换底/中/顶｜↑前 ↓后 ←左 →右（同键返回中心）｜单击放置，Esc 取消"
        Sketchup.set_status_text(message) if Sketchup.respond_to?(:set_status_text)
      end

      def placement_transformation
        anchor = @anchor_points.fetch([@side, @level])
        vector = Geom::Vector3d.new(
          @last_local_point.x.to_f - anchor.x.to_f,
          @last_local_point.y.to_f - anchor.y.to_f,
          @last_local_point.z.to_f - anchor.z.to_f
        )
        Geom::Transformation.translation(vector)
      end

      def build_anchor_points(values)
        return {} unless values && values.length == 6
        x0, y0, z0, x1, y1, z1 = values.map(&:to_f)
        xs = { left: x0, center: (x0 + x1) / 2.0, right: x1 }
        ys = { back: y0, center: (y0 + y1) / 2.0, front: y1 }
        zs = { bottom: z0, middle: (z0 + z1) / 2.0, top: z1 }
        result = {}
        SIDE_LABELS.each_key do |side|
          LEVELS.each do |level|
            x = side == :left ? xs[:left] : (side == :right ? xs[:right] : xs[:center])
            y = side == :front ? ys[:front] : (side == :back ? ys[:back] : ys[:center])
            result[[side, level]] = Geom::Point3d.new(x, y, zs[level])
          end
        end
        result
      end

      def build_local_bounds_corners(values)
        return [] unless values && values.length == 6
        x0, y0, z0, x1, y1, z1 = values.map(&:to_f)
        [
          Geom::Point3d.new(x0, y0, z0), Geom::Point3d.new(x1, y0, z0),
          Geom::Point3d.new(x1, y1, z0), Geom::Point3d.new(x0, y1, z0),
          Geom::Point3d.new(x0, y0, z1), Geom::Point3d.new(x1, y0, z1),
          Geom::Point3d.new(x1, y1, z1), Geom::Point3d.new(x0, y1, z1)
        ]
      end

      def rebuild_preview_corners!
        if @last_local_point.nil? || @local_bounds_corners.empty?
          @preview_corners = []
          return @preview_corners
        end
        transform = @target_to_model * placement_transformation
        @preview_corners = @local_bounds_corners.map { |point| point.transform(transform) }
      end

      def preview_line_points
        return [] unless @preview_corners.length == 8
        BOX_EDGES.each_with_object([]) do |pair, result|
          result << @preview_corners[pair[0]] << @preview_corners[pair[1]]
        end
      end

      def stamp_instance!
        return unless @instance && @instance.valid?
        if @library_kind == 'landscape' && @runtime.respond_to?(:stamp_landscape_library_instance!)
          @runtime.stamp_landscape_library_instance!(@instance, @library_item, @model)
        else
          @runtime.stamp_soft_library_instance!(@instance, @library_item, @model)
          # 记录家具真正所属的协同空间。这个字段不是发布依据，而是用于
          # 事故追踪和防止旧版“根层级放置”再次悄悄变成无法发布的孤儿家具。
          unless @collaboration_context.empty?
            @runtime.soft_set_attribute_if_changed(@instance, SOFT_MODEL_DICT, 'host_space_id', @collaboration_context['space_id'].to_s)
            @runtime.soft_set_attribute_if_changed(@instance, SOFT_MODEL_DICT, 'host_space_name', @collaboration_context['space_name'].to_s)
            @runtime.soft_set_attribute_if_changed(@instance, SOFT_MODEL_DICT, 'placed_by', @collaboration_context['owner'].to_s)
            @runtime.soft_set_attribute_if_changed(@instance, SOFT_MODEL_DICT, 'placed_at', @collaboration_context['placed_at'].to_s)
            @runtime.soft_set_attribute_if_changed(@instance, SOFT_MODEL_DICT, 'placed_plugin_version', @collaboration_context['plugin_version'].to_s)
          end
        end
      end

      def cancel_operation
        if @operation_open
          @model.abort_operation
          @operation_open = false
        elsif @instance && @instance.valid? && !@committed
          @instance.erase!
        end
        # 已载入的库定义保留为会话缓存。取消一次放置不再立即卸载 SKP，
        # 下一次放置同一模型可直接复用定义，避免反复磁盘解析。
      rescue StandardError
        nil
      end

      def cleanup_failed_activation
        @model.abort_operation if @operation_open
        @operation_open = false
      rescue StandardError
        nil
      end
    end


    end
  end
end
