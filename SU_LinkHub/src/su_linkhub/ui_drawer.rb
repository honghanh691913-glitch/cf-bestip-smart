# frozen_string_literal: true

module GavinTools
  module SULinkHubMultiSpace
    module Runtime
    if defined?(Sketchup::Overlay)
      # SketchUp 2023+ 原生视口叠加层。它不是 HtmlDialog，不可拖动，也不会脱离模型视口。
      # 这里只绘制本地缓存的联动状态，不轮询网络文件，不自动更新任何模型。
      class ViewportStatusOverlay < Sketchup::Overlay
        attr_reader :model

        def initialize(model)
          super(HUD_OVERLAY_ID, HUD_OVERLAY_NAME)
          @model = model
          @active = true
          @items = []
          @message = ''
          @message_level = 'info'
          @camera_signature = nil
          @hidden_until = 0.0
          @reveal_timer = nil
          @message_timer = nil
        end

        def activate!
          @active = true
          invalidate_view
          true
        end

        def deactivate!
          @active = false
          cancel_reveal_timer
          cancel_message_timer
          invalidate_view
          true
        end

        def update_items(items)
          @items = Array(items).map { |item| item.is_a?(Hash) ? item.dup : {} }
          invalidate_view
          true
        end

        def show_message(message, level = 'info', duration = nil)
          @message = message.to_s.gsub(/\s+/, ' ').strip
          @message = @message[0, 54] + '…' if @message.length > 55
          @message_level = level.to_s
          cancel_message_timer
          seconds = duration || (@message_level == 'error' ? 6.0 : 3.4)
          @message_timer = GavinTools::SULinkHubMultiSpace::Runtime.runtime_start_timer(seconds, false) do
            @message_timer = nil
            @message = ''
            invalidate_view
          end
          invalidate_view
          true
        rescue StandardError
          false
        end

        def start
          activate!
        end

        def stop
          deactivate!
        end

        def suspend
          @active = false
          cancel_reveal_timer
        end

        def resume
          @active = true
          @camera_signature = nil
          invalidate_view
        end

        def draw(view)
          return unless @active
          signature = camera_signature(view)
          now = monotonic_time
          if @camera_signature.nil?
            @camera_signature = signature
          elsif signature != @camera_signature
            @camera_signature = signature
            @hidden_until = now + HUD_REVEAL_DELAY
            schedule_reveal
            return
          end
          return if now < @hidden_until
          draw_card(view)
        rescue StandardError => e
          GavinTools::SULinkHubMultiSpace::Runtime.log_exception('绘制视口状态卡失败', e)
        end

        def getExtents
          return @model.bounds if @model && @model.respond_to?(:bounds)
          Geom::BoundingBox.new
        rescue StandardError
          Geom::BoundingBox.new
        end

        private

        def monotonic_time
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        rescue StandardError
          Time.now.to_f
        end

        def camera_signature(view)
          camera = view.camera
          values = []
          [camera.eye, camera.target, camera.up].each do |point|
            values.concat(point.to_a.map { |value| value.to_f.round(6) })
          end
          values << (camera.perspective? ? 1 : 0)
          values << (camera.respond_to?(:fov) ? camera.fov.to_f.round(5) : 0.0)
          values << (camera.respond_to?(:height) ? camera.height.to_f.round(5) : 0.0)
          values << view.vpwidth.to_i
          values << view.vpheight.to_i
          values
        rescue StandardError
          [view.vpwidth.to_i, view.vpheight.to_i]
        end

        def schedule_reveal
          cancel_reveal_timer
          @reveal_timer = GavinTools::SULinkHubMultiSpace::Runtime.runtime_start_timer(HUD_REVEAL_DELAY + 0.05, false) do
            @reveal_timer = nil
            invalidate_view if @active
          end
        rescue StandardError
          @reveal_timer = nil
        end

        def cancel_reveal_timer
          GavinTools::SULinkHubMultiSpace::Runtime.runtime_stop_timer(@reveal_timer) if @reveal_timer
        rescue StandardError
          nil
        ensure
          @reveal_timer = nil
        end

        def cancel_message_timer
          GavinTools::SULinkHubMultiSpace::Runtime.runtime_stop_timer(@message_timer) if @message_timer
        rescue StandardError
          nil
        ensure
          @message_timer = nil
        end

        # Runtime -> Overlay bridge methods are defined later in this class.
        # Do not call `public :method_name` here: Ruby requires the methods to
        # already exist and otherwise aborts the whole runtime at load time.

        def invalidate_view
          return unless @model && @model == Sketchup.active_model
          @model.active_view.invalidate
        rescue StandardError
          nil
        end

        def rgba(red, green, blue, alpha = 255)
          Sketchup::Color.new(red, green, blue, alpha)
        rescue ArgumentError
          Sketchup::Color.new(red, green, blue)
        end

        def screen_point(x, y)
          Geom::Point3d.new(x.to_f, y.to_f, 0.0)
        end

        def draw_rect(view, x, y, width, height, color)
          view.drawing_color = color
          points = [
            screen_point(x, y),
            screen_point(x + width, y),
            screen_point(x + width, y + height),
            screen_point(x, y + height)
          ]
          view.draw2d(GL_QUADS, points)
        end

        def draw_round_rect(view, x, y, width, height, radius, color)
          view.drawing_color = color
          r = [radius.to_f, width / 2.0, height / 2.0].min
          k = 0.7071
          points = [
            screen_point(x + r, y),
            screen_point(x + width - r, y),
            screen_point(x + width, y + r),
            screen_point(x + width, y + height - r),
            screen_point(x + width - r, y + height),
            screen_point(x + r, y + height),
            screen_point(x, y + height - r),
            screen_point(x, y + r)
          ]
          view.draw2d(GL_POLYGON, points)
        rescue StandardError
          draw_rect(view, x, y, width, height, color)
        end

        def draw_text_safe(view, x, y, text, color, size: 12, bold: false)
          options = { color: color, size: size, bold: bold, font: 'DengXian' }
          view.draw_text(screen_point(x, y), text.to_s, options)
        rescue ArgumentError
          view.drawing_color = color
          view.draw_text(screen_point(x, y), text.to_s)
        end

        def draw_card(view)
          items = @items.empty? ? fallback_items : @items.first(4)
          y = 94
          row_height = 18
          gap = 3
          text_size = 10
          padding_x = 7
          bar_height = 16

          # v0.6.19：只绘制四条干净状态色条。字体改用 DengXian，减少阴影，提高清晰度。
          items.each_with_index do |item, index|
            py = y + index * (row_height + gap)
            color = Array(item['color'])
            color = [112, 122, 138] unless color.length >= 3
            text = "#{item['name']}：#{item['label']}"
            width = [[(text.length * 8.9 + padding_x * 2).round, 86].max, 138].min
            maximum_x = [view.vpwidth.to_f - width - 8.0, 8.0].max
            x = [[(view.vpwidth.to_f - width) / 2.0, 8.0].max, maximum_x].min
            draw_round_rect(view, x + 1, py + 1, width, bar_height, 6, rgba(0, 0, 0, 34))
            draw_round_rect(view, x, py, width, bar_height, 6, rgba(color[0], color[1], color[2], 228))
            draw_text_safe(view, x + padding_x, py - 1, text, rgba(255, 255, 255, 255), size: text_size, bold: false)
          end

          return if @message.empty?
          message_y = y + items.length * (row_height + gap) + 3
          message_color = case @message_level
                          when 'error' then rgba(255, 214, 214, 242)
                          when 'success' then rgba(202, 248, 218, 242)
                          else rgba(235, 240, 246, 240)
                          end
          msg_width = [[(@message.length * 7.0 + 16).round, 96].max, 180].min
          maximum_x = [view.vpwidth.to_f - msg_width - 8.0, 8.0].max
          x = [[(view.vpwidth.to_f - msg_width) / 2.0, 8.0].max, maximum_x].min
          draw_round_rect(view, x, message_y, msg_width, 15, 6, rgba(20, 25, 34, 165))
          draw_text_safe(view, x + 7, message_y - 1, @message, message_color, size: 8, bold: false)
        end

        def fallback_items
          %w[建筑 软装＋硬装 景观].map do |name|
            { 'name' => name, 'label' => '读取中', 'color' => [112, 122, 138] }
          end
        end
      end
    end

    if defined?(Sketchup::Overlay)
      # 清单缩略图双击使用纯绘制叠加层标出真实实例。Overlay 绘制不可拾取、
      # 不写模型，也不会进入组件编辑上下文，因此不会改变当前选择或协作锁状态。
      class SoftScheduleHighlightOverlay < Sketchup::Overlay
        EDGE_INDEXES = [0, 1, 1, 3, 3, 2, 2, 0, 4, 5, 5, 7, 7, 6, 6, 4, 0, 4, 1, 5, 2, 6, 3, 7].freeze
        FACE_INDEXES = [
          0, 1, 3, 2,
          4, 6, 7, 5,
          0, 4, 5, 1,
          2, 3, 7, 6,
          0, 2, 6, 4,
          1, 5, 7, 3
        ].freeze

        def initialize(model)
          super('gavin_tools_su_linkhub_soft_schedule_highlight', 'SU LinkHub 清单定位高亮')
          @model = model
          @boxes = []
          @primary_index = 0
          @bounds = Geom::BoundingBox.new
          @active = true
        end

        def update_boxes(boxes, primary_index = 0)
          @boxes = Array(boxes).map { |points| Array(points).compact }.select { |points| points.length == 8 }
          requested = primary_index.to_i
          @primary_index = if @boxes.empty?
                             0
                           else
                             [[requested, 0].max, @boxes.length - 1].min
                           end
          @bounds = Geom::BoundingBox.new
          @boxes.each { |points| @bounds.add(points) }
          @active = !@boxes.empty?
          @model.active_view.invalidate if @model && @model.active_view
          true
        end

        def clear
          @boxes = []
          @primary_index = 0
          @bounds = Geom::BoundingBox.new
          @active = false
          @model.active_view.invalidate if @model && @model.active_view
          true
        end

        def start
          @active = true unless @boxes.empty?
        end

        def stop
          @active = false
        end

        def getExtents
          @bounds
        end

        def draw(view)
          return unless @active && !@boxes.empty?
          view.line_stipple = '' if view.respond_to?(:line_stipple=)
          @boxes.each_with_index do |corners, index|
            primary = index == @primary_index
            fill = primary ? Sketchup::Color.new(255, 92, 42, 62) : Sketchup::Color.new(255, 92, 42, 28)
            edge = primary ? Sketchup::Color.new(255, 70, 24, 255) : Sketchup::Color.new(255, 104, 64, 175)
            faces = FACE_INDEXES.map { |corner_index| corners[corner_index] }
            view.drawing_color = fill
            view.draw(GL_QUADS, faces)
            view.drawing_color = edge
            view.line_width = primary ? 6 : 3 if view.respond_to?(:line_width=)
            lines = EDGE_INDEXES.map { |corner_index| corners[corner_index] }
            view.draw(GL_LINES, lines)
          end
        rescue StandardError
          nil
        ensure
          view.line_width = 1 if view && view.respond_to?(:line_width=)
        end
      end
    end

    if defined?(Sketchup::Overlay)
      # 视口顶部居中快捷工具条 + 左侧悬停抽屉。
      # Overlay 只负责绘制和鼠标悬停。官方 Overlay 接口没有按钮按下/释放回调，
      # 因此鼠标进入实际按钮时临时 push 一个极轻量 Tool，由 Tool 接收真实点击；
      # 离开交互区后立即 pop，恢复用户原来的 SketchUp 工具。
      class WorkspaceToolbarOverlay < Sketchup::Overlay
        BUTTON_SIZE = 30.0
        BUTTON_GAP = 3.0
        TOOLBAR_GROUP_GAP = 13.0
        ORIGIN_Y = 12.0
        TOOLBAR_PADDING = 4.0
        VIEW_EDGE_GAP = 8.0
        DRAWER_WIDTH = 276.0
        DRAWER_MIN_HEIGHT = 420.0
        DRAWER_MAX_HEIGHT = 840.0
        DRAWER_VIEW_GAP = 12.0
        DRAWER_HANDLE_WIDTH = 28.0
        DRAWER_HANDLE_HEIGHT = 132.0
        # 鼠标进入后尽快给出位移反馈；延迟过长会让用户误以为抽屉卡住。
        DRAWER_OPEN_DELAY = 0.06
        DRAWER_CLOSE_DELAY = 0.62
        # 临时点击 Tool 被 pop 时，SketchUp 会合成一次 Overlay#onMouseLeave。
        # 这不代表鼠标真的离开抽屉；短暂保留交互租约，防止点击展开/管理后抽屉误收回。
        DRAWER_INTERACTION_HOLD_SECONDS = 0.48
        DRAWER_ANIMATION_DURATION = 0.22
        DRAWER_ANIMATION_INTERVAL = 0.016
        # 展开前段只绘制轻量外壳，避免完整卡片树把动画帧挤掉。
        DRAWER_CONTENT_REVEAL_PROGRESS = 0.82
        # 完整状态扫描必须等展开动画结束，不能抢占最关键的首帧。
        DRAWER_LIVE_REFRESH_AFTER_OPEN_DELAY = 0.06
        MODE_SWITCH_ANIMATION_DURATION = 0.14
        MODE_SWITCH_ANIMATION_INTERVAL = 0.02
        REFRESH_GROUP_ANIMATION_DURATION = 0.14
        REFRESH_GROUP_ANIMATION_INTERVAL = 0.02
        LIBRARY_GROUP_ANIMATION_DURATION = 0.14
        LIBRARY_GROUP_ANIMATION_INTERVAL = 0.02
        # 分组层级不能只靠颜色表达：统一收紧列表节奏，组内空间再通过
        # 右缩进、较矮卡片和小一级字号建立清晰的父子层级。
        DRAWER_ROW_PITCH = 36.0
        DRAWER_GROUP_CARD_HEIGHT = 33.0
        DRAWER_SPACE_CARD_HEIGHT = 31.0
        DRAWER_GROUP_MEMBER_CARD_HEIGHT = 28.0
        DRAWER_GROUP_MEMBER_INDENT = 13.0
        # 室内标题右侧快捷按钮统一使用一个 30px 圆形视觉单元；
        # 代/真切换保留药丸形态，宽度严格等于两个圆形按钮加一个标准间距。
        DRAWER_SPACE_TOOL_BUTTON_SIZE = 30.0
        DRAWER_SPACE_TOOL_BUTTON_GAP = 4.0
        DRAWER_SPACE_MODE_SWITCH_WIDTH = DRAWER_SPACE_TOOL_BUTTON_SIZE * 2.0 + DRAWER_SPACE_TOOL_BUTTON_GAP
        # 展开状态下“建筑 / 室内”本身是明确的可点击按钮，不再只绘制成普通文字。
        DRAWER_PROFESSIONAL_TITLE_BUTTON_WIDTH = 50.0
        # 室内代/真开关与顶部工具条保持一致：平时收成一个圆形按钮，悬停后
        # 从右侧固定点向左展开，避免相邻小眼睛跳动或鼠标离开命中区。
        DRAWER_MODE_SWITCH_ANIMATION_DURATION = 0.14
        DRAWER_MODE_SWITCH_ANIMATION_INTERVAL = 0.02
        PUBLISH_QUEUE_PANEL_WIDTH = 392.0
        PUBLISH_QUEUE_PANEL_ROW_HEIGHT = 64.0
        PUBLISH_QUEUE_PANEL_MAX_ROWS = 6
        # 已修改但尚未完成代理刷新的家具，以纯 Overlay 外包盒体块标记。
        # 不写材质、不加临时几何、不进入撤销栈；代理队列每完成一款，对应体块立即消失。
        PENDING_PROXY_EDGE_INDEXES = [0, 1, 1, 3, 3, 2, 2, 0, 4, 5, 5, 7, 7, 6, 6, 4, 0, 4, 1, 5, 2, 6, 3, 7].freeze
        PENDING_PROXY_FACE_INDEXES = [
          0, 1, 3, 2,
          4, 6, 7, 5,
          0, 4, 5, 1,
          2, 3, 7, 6,
          0, 2, 6, 4,
          1, 5, 7, 3
        ].freeze

        attr_reader :model

        def initialize(model)
          super(WORKSPACE_OVERLAY_ID, WORKSPACE_OVERLAY_NAME, description: '左侧悬停抽屉、顶部居中快捷更新、发布、参考显示及空间模型库')
          @model = model
          @active = true
          @state = { 'visible' => false }
          @hover_action = nil
          @pressed_action = nil
          @last_view_width = 0.0
          @last_view_height = 0.0
          @drawer_open = false
          @drawer_pinned = false
          @drawer_pointer_inside = false
          @drawer_interaction_hold_until = 0.0
          @drawer_interaction_hold_token = 0
          # 点击层 pop 后 SketchUp 会伪造一次 Overlay#onMouseLeave。这里用一次性
          # 释放护栏而不是固定延时猜测；本地抽屉操作则保持点击 Tool 常驻到鼠标
          # 真正移出抽屉，从根本上避免“点完按钮抽屉自动收回”。
          @drawer_release_guard = false
          @drawer_release_guard_until = 0.0
          @drawer_open_timer = nil
          @drawer_close_timer = nil
          @drawer_animation_timer = nil
          @drawer_animation_target = 0.0
          @drawer_live_refresh_timer = nil
          @drawer_live_refresh_token = 0
          @drawer_progress = 0.0
          @space_scroll_index = 0
          @architecture_scroll_index = 0
          @architecture_manage_mode = false
          @architecture_manage_selected = {}
          @professional_section_collapsed_overrides = {}
          @mode_switch_progress = 0.0
          @mode_switch_animation_timer = nil
          @drawer_mode_switch_progress = 0.0
          @drawer_mode_switch_animation_timer = nil
          @refresh_group_progress = 0.0
          @refresh_group_animation_timer = nil
          @library_group_progress = 0.0
          @library_group_animation_timer = nil
          @space_manage_mode = false
          @space_manage_selected = {}
          @architecture_manage_mode = false
          @architecture_manage_selected = {}
          @professional_section_collapsed_overrides = {}
          @hover_row_key = nil
          @space_drag_candidate = nil
          @space_drag_timer = nil
          @space_dragging = false
          @space_drag_point = nil
          @space_drag_target_key = nil
          @space_drag_last_scroll_at = 0.0
          @drawer_tools_mode = false
          @drawer_workspace_picker = false
          @workspace_switch_expanded = false
          @publish_queue_open = false
          @floating_notice_message = ''
          @floating_notice_level = 'info'
          @floating_notice_progress = nil
          @floating_notice_timer = nil
          @floating_notice_persistent = false
          @floating_notice_expires_at = nil
          @floating_notice_layout_cache = nil
        end

        def cancel_floating_notice_timer
          if @floating_notice_timer
            GavinTools::SULinkHubMultiSpace::Runtime.runtime_stop_timer(@floating_notice_timer) rescue nil
            @floating_notice_timer = nil
          end
          true
        rescue StandardError
          false
        end

        def show_floating_notice(message, level = 'info', progress: nil, persistent: false, duration: nil)
          @floating_notice_message = compact_floating_notice_message(message, level)
          @floating_notice_level = level.to_s
          @floating_notice_progress = progress.nil? ? nil : [[progress.to_f, 0.0].max, 100.0].min
          @floating_notice_persistent = !!persistent
          @floating_notice_layout_cache = nil
          cancel_floating_notice_timer
          if @floating_notice_persistent
            @floating_notice_expires_at = nil
          else
            base_seconds = (duration || (@floating_notice_level == 'error' ? 5.5 : 3.0)).to_f
            # 两三行通知自动多留一点阅读时间；短通知仍保持原来的轻快消失节奏。
            reading_extra = [[@floating_notice_message.length - 48, 0].max * 0.025, 2.2].min
            seconds = base_seconds + reading_extra
            @floating_notice_expires_at = Time.now.to_f + seconds
            @floating_notice_timer = GavinTools::SULinkHubMultiSpace::Runtime.runtime_start_timer(seconds, false) do
              @floating_notice_timer = nil
              @floating_notice_message = ''
              @floating_notice_progress = nil
              @floating_notice_persistent = false
              @floating_notice_expires_at = nil
              invalidate_view
            end
          end
          invalidate_view
          # 部分版本在 active_path 刚变化时会吞掉第一次 invalidate。下一帧再补一次，
          # 不使用 refresh，避免为了提示本身阻塞前台。
          GavinTools::SULinkHubMultiSpace::Runtime.runtime_start_timer(0.01, false) { invalidate_view } rescue nil
          true
        rescue StandardError
          false
        end

        # 底部通知是“即时反馈”，不是状态说明书。所有 show_status / 发布通知 /
        # 直接 floating notice 最终都会经过这里；完整原文继续保留在 SketchUp 状态栏、
        # 日志及相关面板中。这样核心链路可以短而明确，异常原因又不会丢失。
        def compact_floating_notice_message(message, level = 'info')
          text = message.to_s.gsub(/\s+/, ' ').strip
          return '' if text.empty?

          # v0.13.6.130：先处理高频核心状态，避免靠零散字符串替换漏掉真正长的通知。
          if (match = text.match(/\A(.+?) 已进入 LinkHub 空间根(?:；|。|$)/))
            return "#{match[1]} 已进入修改"
          end
          if (match = text.match(/\A(.+?) 已继续未发布修改(?:；|。|$)/))
            return "#{match[1]} 已继续修改"
          end
          if (match = text.match(/\A已安全暂存上一编辑焦点，并进入 (.+?)(?:；|。|$)/))
            return "已进入 #{match[1]}；上一空间已暂存"
          end
          if (match = text.match(/\A(.+?) 未检测到内容修改，已结束编辑并释放占用/))
            return "#{match[1]} 无修改，已退出并释放占用"
          end
          if (match = text.match(/\A(.+?) 内容未变化且已安全锁定，但协作占用未能自动释放/))
            return "#{match[1]} 无修改，但占用释放失败；请刷新后处理"
          end
          if (match = text.match(/\A(.+?) 已退出编辑，保留解锁与协作占用.*?；双击继续，发布时锁定/))
            return "#{match[1]} 已退出编辑；双击继续，顶部发布"
          end
          if (match = text.match(/\A已退出到全模；(.+?) 占用保留。双击继续，顶部按钮发布/))
            return "#{match[1]} 已退出编辑；双击继续，顶部发布"
          end
          if (match = text.match(/\A已退出到全模；(.+?)仍由你占用，发布只能使用 LinkHub 按钮/))
            return "#{match[1]} 已退出编辑；占用保留"
          end
          if (match = text.match(/\A(.+?) 已整理代理并加入发布队列(?:（约\s*([^）]+)）)?/))
            suffix = match[2].to_s.empty? ? '' : " · #{match[2]}"
            return "#{match[1]} 已加入发布队列#{suffix}"
          end
          if (match = text.match(/\A(.+?) 已加入发布队列(?:；|。|$)/))
            return "#{match[1]} 已加入发布队列"
          end
          if (match = text.match(/\A(.+?) 首次发布已重新加入后台队列/))
            return "#{match[1]} 已重新加入发布队列"
          end
          if (match = text.match(/\A(.+?) 首次发布已重新加入队列/))
            return "#{match[1]} 已重新加入发布队列"
          end
          if (match = text.match(/\A(.+?) 已进入发布准备/))
            return "#{match[1]} 正在准备发布"
          end
          if (match = text.match(/\A(.+?) 首次后台发布完成/))
            return "#{match[1]} 首次发布完成"
          end
          if (match = text.match(/\A(.+?) 首次后台发布失败：(.+)/))
            text = "#{match[1]} 首次发布失败：#{match[2]}"
          elsif (match = text.match(/\A(.+?) 后台发布完成(?:；协作锁未自动释放)?[。]?\z/))
            return match[0].include?('协作锁未自动释放') ? "#{match[1]} 发布完成，但占用释放失败" : "#{match[1]} 发布完成"
          elsif (match = text.match(/\A(.+?)后台发布完成[。]?\z/))
            return "#{match[1]} 发布完成"
          elsif (match = text.match(/\A(.+?) 后台发布失败：(.+)/))
            text = "#{match[1]} 发布失败：#{match[2]}"
          elsif (match = text.match(/\A(.+?)后台发布失败：(.+)/))
            text = "#{match[1]} 发布失败：#{match[2]}"
          end

          text = text.gsub(/正在后台发布\s*/, '发布中 ')
          text = text.gsub(/后台发布\s+(\d+)%/, '发布中 \\1%')
          text = text.gsub(/本阶段已\s*\d+s/, '').gsub(/\s*·\s*·\s*/, ' · ').sub(/\s*·\s*\z/, '')

          if (match = text.match(/\A(.+?) 不是最新发布版；请先更新/))
            return "#{match[1]} 不是最新版；请先更新"
          end
          if (match = text.match(/\A(.+?) 已强制解锁，仅供历史取物/))
            return "#{match[1]} 已强制解锁（历史取物）；ESC 恢复"
          end
          if (match = text.match(/\A(.+?) 已恢复强制解锁前快照/))
            return "#{match[1]} 已恢复强制解锁前状态"
          end
          if (match = text.match(/\A(.+?) 占用已失效；本地内容保留，已安全锁定/))
            return "#{match[1]} 占用失效；修改已保留并锁定"
          end
          if (match = text.match(/\A(.+?) 占用已失效；修改保留并已锁定/))
            return "#{match[1]} 占用失效；修改已保留并锁定"
          end
          if (match = text.match(/\A(.+?) 已自动重新锁定；请(?:点击|使用) LinkHub“修改”/))
            return "#{match[1]} 已重新锁定；请点“修改”"
          end
          if (match = text.match(/\A(.+?) 仍保持修改；请使用 LinkHub 发布按钮提交/))
            return "#{match[1]} 仍在修改；请点发布"
          end
          if (match = text.match(/\A上一发布版已缓存；退出当前组件后自动载入/))
            return '更新已就绪；退出组件后自动载入'
          end
          if (match = text.match(/\A正在准备 (.+?) 的上一发布版；完成后自动载入/))
            return "正在准备 #{match[1]} 更新"
          end
          if (match = text.match(/\A正在载入来源空间 (.+?)；完成后自动恢复联动/))
            return "正在载入来源空间 #{match[1]}"
          end
          if (match = text.match(/\A(.+?) 已阻止直接进入；请先点“修改”取得占用/))
            return "#{match[1]} 请先点“修改”再进入"
          end
          if (match = text.match(/\A(.+?) 空间内部禁止使用 SketchUp 原生“锁定”；已自动恢复 \d+ 个对象/))
            return "#{match[1]} 已撤销原生锁定；请用 LinkHub 发布/取消"
          end
          if (match = text.match(/\A已将“(.+?)”保持为真模型并进入安全编辑/))
            return "“#{match[1]}” 已进入安全编辑；发布时生成代理"
          end

          replacements = {
            '现在可以继续操作其它空间/建筑/景观' => '',
            '现在可以继续编辑其它空间' => '',
            '现在可以继续操作其它空间' => '',
            '现在可以继续操作其它模型' => '',
            '可继续编辑其它空间' => '',
            '可继续操作其它空间' => '',
            '可继续其它空间' => '',
            '空闲时自动发布' => '',
            '完成后再由 SketchUp 载入' => '完成后自动载入',
            '完成后会自动恢复所有联动副本' => '完成后自动恢复联动',
            '请使用 LinkHub“发布/取消修改”结束编辑' => '请用 LinkHub 发布/取消',
            '请使用 LinkHub 发布按钮提交' => '请点发布',
            '请重新点击修改并取得协作占用后再发布空间' => '请重新点“修改”后发布',
            '本地修改与空间占用均已保留' => '修改与占用已保留',
            '未发布修改和协作占用均已安全保留' => '修改与占用已保留',
            '空间内容仍保留，可重新点击发布' => '内容已保留，可重试'
          }
          replacements.each { |from, to| text = text.gsub(from, to) }
          text = text.gsub(/；{2,}/, '；').gsub(/；[。]?\z/, '').gsub(/\s+/, ' ').strip

          # 底部只显示摘要：普通提示尽量控制在两行内；错误允许更长，完整详情仍在状态栏。
          limit = case level.to_s
                  when 'error' then 118
                  when 'warning' then 88
                  else 72
                  end
          if text.length > limit
            clipped = text[0, limit].to_s
            boundary = [clipped.rindex('；'), clipped.rindex('。'), clipped.rindex('，')].compact.max
            clipped = clipped[0...boundary] if boundary && boundary >= 32
            clipped = clipped.rstrip.sub(/[，；。:：]+\z/, '')
            text = "#{clipped}…"
          end
          text
        rescue StandardError
          message.to_s.strip
        end

        def floating_notice_text_width(view, text, size: 10, bold: true)
          value = text.to_s
          return 0.0 if value.empty?
          if view && view.respond_to?(:text_bounds)
            begin
              bounds = view.text_bounds(
                screen_point(0.0, 0.0), value,
                font: 'DengXian', size: size, bold: bold
              )
              measured = if bounds.respond_to?(:width)
                           bounds.width.to_f
                         elsif bounds.respond_to?(:upper_right) && bounds.respond_to?(:lower_left)
                           bounds.upper_right.x.to_f - bounds.lower_left.x.to_f
                         else
                           0.0
                         end
              return measured if measured.positive?
            rescue StandardError
              nil
            end
          end
          value.each_char.sum do |char|
            code = char.ord
            if char =~ /\s/
              size.to_f * 0.38
            elsif code < 128
              size.to_f * (char =~ /[MW@#%]/ ? 0.78 : 0.62)
            else
              size.to_f * 1.16
            end
          end
        rescue StandardError
          text.to_s.length * size.to_f
        end

        def wrap_floating_notice_lines(view, text, max_width, max_lines = 2, size: 10, bold: true)
          chars = text.to_s.each_char.to_a
          return [''] if chars.empty?
          width_cache = {}
          width_for = lambda do |char|
            width_cache[char] ||= floating_notice_text_width(view, char, size: size, bold: bold) * 1.05
          end
          lines = []
          current = ''
          current_width = 0.0
          overflowed = false

          chars.each do |char|
            char_width = width_for.call(char)
            if !current.empty? && current_width + char_width > max_width.to_f
              if lines.length < max_lines.to_i - 1
                lines << current.rstrip
                current = ''
                current_width = 0.0
                next if char =~ /\s/
              else
                overflowed = true
                break
              end
            end
            current << char
            current_width += char_width
          end

          if overflowed
            ellipsis = '…'
            ellipsis_width = width_for.call(ellipsis)
            while current.length > 1 && current_width + ellipsis_width > max_width.to_f
              removed = current[-1]
              current = current[0...-1]
              current_width -= width_for.call(removed)
            end
            current = current.rstrip + ellipsis
          end
          lines << current.rstrip unless current.empty?
          lines = [''] if lines.empty?
          lines.first([max_lines.to_i, 1].max)
        rescue StandardError
          [text.to_s]
        end

        def floating_notice_layout(view, message, progress)
          viewport_width = [view.vpwidth.to_f, 1.0].max
          cache_key = [message.to_s, @floating_notice_level.to_s, progress.nil? ? 0 : 1, viewport_width.round]
          cache = @floating_notice_layout_cache
          return cache[:layout] if cache.is_a?(Hash) && cache[:key] == cache_key

          max_width = [viewport_width * 0.94, 920.0].min
          max_width = [max_width, viewport_width - 8.0].min
          max_width = [max_width, 120.0].max
          text_padding_left = 32.0
          text_padding_right = progress.nil? ? 16.0 : 58.0
          content_max_width = [max_width - text_padding_left - text_padding_right, 72.0].max
          max_lines = @floating_notice_level.to_s == 'error' ? 3 : 2
          lines = wrap_floating_notice_lines(view, message, content_max_width, max_lines, size: 10, bold: true)
          line_widths = lines.map { |line| floating_notice_text_width(view, line, size: 10, bold: true) }
          longest = line_widths.max.to_f
          minimum_width = progress.nil? ? 132.0 : 230.0
          desired_width = longest + text_padding_left + text_padding_right + 2.0
          width = [[desired_width, minimum_width].max, max_width].min
          layout = {
            viewport_width: viewport_width, max_width: max_width, width: width, lines: lines,
            text_padding_left: text_padding_left, text_padding_right: text_padding_right
          }
          @floating_notice_layout_cache = { key: cache_key, layout: layout }
          layout
        rescue StandardError
          viewport_width = [view.vpwidth.to_f, 1.0].max
          fallback_width = [[floating_notice_text_width(view, message.to_s, size: 10, bold: true) + 50.0, 132.0].max, [viewport_width - 8.0, 920.0].min].min
          { viewport_width: viewport_width, width: fallback_width, lines: [message.to_s], text_padding_left: 32.0, text_padding_right: 18.0 }
        end

        def clear_floating_notice
          cancel_floating_notice_timer
          @floating_notice_message = ''
          @floating_notice_progress = nil
          @floating_notice_persistent = false
          @floating_notice_expires_at = nil
          @floating_notice_layout_cache = nil
          invalidate_view
          true
        rescue StandardError
          false
        end

        def draw_floating_notice(view)
          message = @floating_notice_message.to_s
          return if message.empty?
          progress = @floating_notice_progress
          layout = floating_notice_layout(view, message, progress)
          viewport_width = layout[:viewport_width].to_f
          width = layout[:width].to_f
          lines = Array(layout[:lines])

          # v0.13.6.130：短通知按真实文字像素收缩；长通知按真实 text_bounds 扩展并换行。
          # 不再用“中文字符数 × 固定像素”猜宽度，因此 DPI、中文字体和中英混排都不会越框。
          line_height = 16.0
          text_top = 7.0
          text_height = [lines.length, 1].max * line_height
          progress_extra = progress.nil? ? 0.0 : 14.0
          base_height = lines.length <= 1 ? 38.0 : (lines.length == 2 ? 54.0 : 70.0)
          height = [base_height, text_top + text_height + 6.0 + progress_extra].max
          x = [[(viewport_width - width) / 2.0, 4.0].max, [viewport_width - width - 4.0, 4.0].max].min
          y = [view.vpheight.to_f - height - 22.0, 10.0].max
          rgb = case @floating_notice_level.to_s
                when 'error' then [205, 67, 73]
                when 'warning' then [205, 132, 36]
                when 'success' then [43, 151, 105]
                else [72, 132, 224]
                end
          radius = [height / 2.0, 24.0].min
          draw_round_rect(view, x + 2.0, y + 3.0, width, height, radius, rgba(0, 0, 0, 54))
          shell = draw_round_rect(view, x, y, width, height, radius, rgba(27, 32, 42, 242))
          view.drawing_color = rgba(rgb[0], rgb[1], rgb[2], 224)
          view.line_width = 2 if view.respond_to?(:line_width=)
          view.draw2d(GL_LINE_LOOP, shell)
          view.line_width = 1 if view.respond_to?(:line_width=)
          dot_y = y + text_top + [text_height / 2.0 - 5.0, 0.0].max
          draw_round_rect(view, x + 11.0, dot_y, 10.0, 10.0, 5.0, rgba(rgb[0], rgb[1], rgb[2], 250))
          lines.each_with_index do |line, index|
            draw_text_safe(view, x + 29.0, y + text_top + index * line_height, line, rgba(250, 252, 255, 252), size: 10, bold: true)
          end
          unless progress.nil?
            bar_x = x + 29.0
            bar_y = y + text_top + text_height + 5.0
            bar_w = [width - 84.0, 80.0].max
            draw_round_rect(view, bar_x, bar_y, bar_w, 6.0, 3.0, rgba(255, 255, 255, 42))
            filled = bar_w * progress.to_f / 100.0
            draw_round_rect(view, bar_x, bar_y, filled, 6.0, 3.0, rgba(rgb[0], rgb[1], rgb[2], 245)) if filled > 0.5
            label = "#{progress.round}%"
            draw_text_safe(view, x + width - 47.0, bar_y - 10.0, label, rgba(222, 230, 243, 238), size: 8, bold: true)
          end
        rescue StandardError
          nil
        ensure
          view.line_width = 1 if view && view.respond_to?(:line_width=)
        end

        def draw_pending_proxy_highlights(view)
          runtime = GavinTools::SULinkHubMultiSpace::Runtime
          rows = runtime.soft_pending_proxy_highlight_boxes(@model)
          rows.concat(runtime.soft_pending_ingest_highlight_boxes(@model))
          return if rows.empty?
          view.line_stipple = '' if view.respond_to?(:line_stipple=)
          rows.each do |row|
            corners = Array(row[:points])
            next unless corners.length == 8
            status = row[:status].to_s
            blue_pending = %w[ingest edit].include?(row[:kind].to_s)
            fill_rgb = blue_pending ? [54, 137, 235] : [255, 208, 42]
            edge_rgb = if status == 'failed'
                         [231, 138, 38]
                       elsif blue_pending
                         [92, 174, 255]
                       else
                         [236, 184, 28]
                       end
            fill_alpha = status == 'processing' ? 92 : 62
            edge_alpha = status == 'failed' ? 245 : (status == 'processing' ? 244 : 215)
            faces = PENDING_PROXY_FACE_INDEXES.map { |corner_index| corners[corner_index] }
            view.drawing_color = rgba(fill_rgb[0], fill_rgb[1], fill_rgb[2], fill_alpha)
            view.draw(GL_QUADS, faces)
            view.drawing_color = rgba(edge_rgb[0], edge_rgb[1], edge_rgb[2], edge_alpha)
            view.line_width = status == 'processing' ? 5 : 3 if view.respond_to?(:line_width=)
            lines = PENDING_PROXY_EDGE_INDEXES.map { |corner_index| corners[corner_index] }
            view.draw(GL_LINES, lines)
          end
        rescue StandardError => e
          GavinTools::SULinkHubMultiSpace::Runtime.log_exception('绘制待处理家具高亮失败', e)
        ensure
          view.line_width = 1 if view && view.respond_to?(:line_width=)
        end

        def activate!
          @active = true
          invalidate_view
          true
        end

        def deactivate!
          @active = false
          @hover_action = nil
          @hover_row_key = nil
          @pressed_action = nil
          @drawer_pointer_inside = false
          @drawer_interaction_hold_until = 0.0
          @drawer_interaction_hold_token = @drawer_interaction_hold_token.to_i + 1
          @drawer_release_guard = false
          @drawer_release_guard_until = 0.0
          cancel_drawer_timers
          cancel_drawer_live_refresh
          cancel_mode_switch_animation
          cancel_drawer_mode_switch_animation
          cancel_refresh_group_animation
          cancel_library_group_animation
          @mode_switch_progress = 0.0
          @drawer_mode_switch_progress = 0.0
          @refresh_group_progress = 0.0
          @library_group_progress = 0.0
          @space_manage_mode = false
          @space_manage_selected = {}
          @hover_row_key = nil
          cancel_space_drag!
          @drawer_tools_mode = false
          @drawer_workspace_picker = false
          @workspace_switch_expanded = false
          cancel_floating_notice_timer
          @floating_notice_message = ''
          @floating_notice_progress = nil
          invalidate_view
          true
        end

        def update_state(state)
          previous_host = @state.is_a?(Hash) ? @state['host_discipline'].to_s : ''
          previous_auto_expand = space_edit_tools_auto_expanded?
          incoming = state.is_a?(Hash) ? state.dup : { 'visible' => false }
          # 抽屉关闭或后台轻量轮询时，workspace_toolbar_state 会故意省略昂贵的空间明细。
          # v0.9.82 直接用空数组覆盖旧状态，会让刚建立的组卡片和“2F:空间名”瞬间消失。
          # 只有明确的 detailed payload 才替换空间树；轻量 payload 延用最近一次完整树。
          if incoming['drawer_detailed'] != true && @state.is_a?(Hash)
            incoming['drawer_spaces'] = @state['drawer_spaces'] if Array(incoming['drawer_spaces']).empty? && !Array(@state['drawer_spaces']).empty?
            incoming['drawer_groups'] = @state['drawer_groups'] if Array(incoming['drawer_groups']).empty? && !Array(@state['drawer_groups']).empty?
            incoming['drawer_space_loaded_count'] = @state['drawer_space_loaded_count'] unless incoming.key?('drawer_space_loaded_count')
            incoming['drawer_space_hidden'] = @state['drawer_space_hidden'] unless incoming.key?('drawer_space_hidden')
            incoming['drawer_architecture_models'] = @state['drawer_architecture_models'] if Array(incoming['drawer_architecture_models']).empty? && !Array(@state['drawer_architecture_models']).empty?
            incoming['drawer_architecture_groups'] = @state['drawer_architecture_groups'] if Array(incoming['drawer_architecture_groups']).empty? && !Array(@state['drawer_architecture_groups']).empty?
            incoming['drawer_architecture_loaded_count'] = @state['drawer_architecture_loaded_count'] unless incoming.key?('drawer_architecture_loaded_count')
            incoming['drawer_architecture_hidden'] = @state['drawer_architecture_hidden'] unless incoming.key?('drawer_architecture_hidden')
            incoming['professional_section_collapsed'] = @state['professional_section_collapsed'] unless incoming['professional_section_collapsed'].is_a?(Hash)
          end
          @state = incoming
          if incoming['drawer_detailed'] == true
            @drawer_role_snapshots ||= {}
            role_key = incoming['drawer_space_collection_key'].to_s
            if SPACE_COLLECTION_KEYS.include?(role_key)
              @drawer_role_snapshots[role_key] = {
                'drawer_spaces' => Array(incoming['drawer_spaces']).map { |row| row.is_a?(Hash) ? row.dup : row },
                'drawer_groups' => Array(incoming['drawer_groups']).map { |row| row.is_a?(Hash) ? row.dup : row },
                'drawer_space_loaded_count' => incoming['drawer_space_loaded_count'].to_i,
                'drawer_space_hidden' => incoming['drawer_space_hidden'] == true
              }
            end
            if incoming['host_discipline'].to_s == 'architecture'
              @drawer_role_snapshots['architecture'] = {
                'drawer_architecture_models' => Array(incoming['drawer_architecture_models']).map { |row| row.is_a?(Hash) ? row.dup : row },
                'drawer_architecture_groups' => Array(incoming['drawer_architecture_groups']).map { |row| row.is_a?(Hash) ? row.dup : row },
                'drawer_architecture_loaded_count' => incoming['drawer_architecture_loaded_count'].to_i,
                'drawer_architecture_hidden' => incoming['drawer_architecture_hidden'] == true
              }
            end
          end
          current_auto_expand = space_edit_tools_auto_expanded?
          if current_auto_expand
            cancel_mode_switch_animation
            cancel_drawer_mode_switch_animation
            cancel_library_group_animation
            @mode_switch_progress = 1.0
            @drawer_mode_switch_progress = 1.0
            @library_group_progress = 1.0
          elsif previous_auto_expand
            # 从空间内部退出到安全暂存/全模，或正式结束编辑时立即恢复紧凑工具条。
            # 后续仍可按原逻辑通过鼠标悬停临时展开。
            cancel_mode_switch_animation
            cancel_drawer_mode_switch_animation
            cancel_library_group_animation
            @mode_switch_progress = 0.0
            @drawer_mode_switch_progress = 0.0
            @library_group_progress = 0.0
          end
          if !previous_host.empty? && previous_host != @state['host_discipline'].to_s
            persisted_sections = @state['professional_section_collapsed'].is_a?(Hash) ? @state['professional_section_collapsed'] : {}
            @professional_section_collapsed_overrides = persisted_sections.dup
          end
          valid_space_ids = Array(@state['drawer_spaces']).map { |item| item['id'].to_s }
          @space_manage_selected ||= {}
          @space_manage_selected.delete_if { |space_id, _selected| !valid_space_ids.include?(space_id.to_s) }
          valid_architecture_ids = Array(@state['drawer_architecture_models']).map { |item| item['id'].to_s }
          @architecture_manage_selected ||= {}
          @architecture_manage_selected.delete_if { |architecture_id, _selected| !valid_architecture_ids.include?(architecture_id.to_s) }
          unless SPACE_COLLECTION_KEYS.include?(@state['host_discipline'].to_s) && @state['drawer_project_connected'] == true
            @space_manage_mode = false
            @space_manage_selected = {}
          end
          unless @state['host_discipline'].to_s == 'architecture' && @state['drawer_project_connected'] == true
            @architecture_manage_mode = false
            @architecture_manage_selected = {}
          end
          # 第一次进入项目时按当前工作区建立专业区默认展开状态：当前专业展开，另一专业收纳。
          @professional_section_collapsed_overrides ||= {}
          if @professional_section_collapsed_overrides.empty? && @state['drawer_project_connected'] == true
            persisted = @state['professional_section_collapsed'].is_a?(Hash) ? @state['professional_section_collapsed'] : {}
            unless persisted.key?('architecture') || persisted.key?(SPACE_COLLECTION_KEY) || persisted.key?(SOFT_SPACE_COLLECTION_KEY)
              host = @state['host_discipline'].to_s
              @professional_section_collapsed_overrides['architecture'] = host != 'architecture'
              @professional_section_collapsed_overrides[SPACE_COLLECTION_KEY] = host != SPACE_COLLECTION_KEY
              @professional_section_collapsed_overrides[SOFT_SPACE_COLLECTION_KEY] = host != SOFT_SPACE_COLLECTION_KEY
            end
          end
          @drawer_workspace_picker = false unless @state['drawer_project_connected'] == true
          @drawer_tools_mode = false unless drawer_stage == 'ready'
          clamp_space_scroll
          animate_mode_switch(false) unless @state['representation_supported'] == true
          animate_drawer_mode_switch(false) if professional_section_collapsed?(drawer_space_collection_key) || @state['representation_supported'] != true
          animate_refresh_group(false) unless refresh_group_expandable?
          animate_library_group(false) unless library_group_expandable?
          collapse_drawer!(force: true) unless @state['visible'] == true
          invalidate_view
          true
        end

        # 后台任务的阶段和耗时每隔很短时间都会变化。这里只替换任务中心的两项
        # 内存状态并重绘视口，避免为一行进度反复读取项目、锁、共享目录和空间树。
        def update_publish_queue_state!(jobs, active_count)
          @state = {} unless @state.is_a?(Hash)
          @state['publish_queue_jobs'] = Array(jobs)
          @state['publish_queue_active_count'] = active_count.to_i
          invalidate_view
          true
        rescue StandardError
          false
        end

        def start
          activate!
        end

        def stop
          deactivate!
        end

        def draw(view)
          return unless @active
          remember_view(view)
          draw_pending_proxy_highlights(view)
          if toolbar_visible?
            draw_drawer(view)
            if quick_toolbar_visible?
              draw_toolbar(view)
              draw_publish_queue_panel(view) if @publish_queue_open
            end
          end
          draw_floating_notice(view)
        rescue StandardError => e
          GavinTools::SULinkHubMultiSpace::Runtime.log_exception('绘制工作空间工具条失败', e)
        end

        def getExtents
          return @model.bounds if @model && @model.respond_to?(:bounds)
          Geom::BoundingBox.new
        rescue StandardError
          Geom::BoundingBox.new
        end

        def onMouseEnter(flags, x, y, view)
          handle_overlay_pointer(flags, x, y, view)
        end

        def onMouseMove(flags, x, y, view)
          handle_overlay_pointer(flags, x, y, view)
        end

        def onMouseLeave(view)
          changed = !@hover_action.nil? || !@pressed_action.nil?
          animate_mode_switch(false) if @hover_action == 'representation'
          animate_drawer_mode_switch(false) if @hover_action == 'drawer_toggle_space_mode'
          animate_refresh_group(false)
          animate_library_group(false)
          @workspace_switch_expanded = false
          @hover_action = nil
          @hover_row_key = nil
          @pressed_action = nil
          # push_tool/pop_tool 会在鼠标仍位于抽屉上时合成一次 leave。
          # v0.9.86 使用一次性释放护栏吞掉这一次伪 leave；真正移出抽屉时，
          # 后续真实 move/leave 才会把 pointer_inside 改为 false 并启动收纳。
          unless consume_drawer_release_guard? || drawer_interaction_hold_active?
            @drawer_pointer_inside = false
            schedule_drawer_close
          end
          view.invalidate if changed
          true
        rescue StandardError
          false
        end

        # ---- 供临时点击 Tool 调用的公开接口 ----

        def hit_action(x, y, view = nil)
          return nil unless toolbar_visible?
          remember_view(view)
          row = architecture_row_at(x, y, view) || drawer_row_at(x, y, view)
          @hover_row_key = row ? "#{row['kind']}:#{row['id']}" : nil
          action_at(x, y, view)
        end

        def hovering_action?
          toolbar_visible? && !@hover_action.nil?
        end

        def contains_point?(x, y, view = nil)
          return false unless toolbar_visible?
          remember_view(view)
          toolbar_inside = quick_toolbar_visible? && toolbar_layout(view)[:groups].any? { |group| point_in_rect?(x, y, group[:rect]) }
          queue_inside = quick_toolbar_visible? && @publish_queue_open && point_in_rect?(x, y, publish_queue_panel_rect(view))
          toolbar_inside || queue_inside || point_in_rect?(x, y, drawer_rect(view))
        end

        def drawer_contains_point?(x, y, view = nil)
          return false unless toolbar_visible? && @drawer_open
          remember_view(view)
          point_in_rect?(x, y, drawer_rect(view))
        rescue StandardError
          false
        end

        def update_tool_pointer(x, y, view, pressed_action = nil)
          remember_view(view)
          update_drawer_pointer(x, y, view)
          refresh_hover = refresh_group_hover_at?(x, y, view)
          library_hover = library_group_hover_at?(x, y, view)
          workspace_hover = workspace_switch_hover_at?(x, y, view)
          workspace_changed = (@workspace_switch_expanded == true) != workspace_hover
          @workspace_switch_expanded = workspace_hover
          row = architecture_row_at(x, y, view) || drawer_row_at(x, y, view)
          row_key = row ? "#{row['kind']}:#{row['id']}" : nil
          previous_row = @hover_row_key
          @hover_row_key = row_key
          action = action_at(x, y, view)
          previous_hover = @hover_action
          changed = action != previous_hover || pressed_action != @pressed_action || row_key != previous_row || workspace_changed
          @hover_action = action
          @pressed_action = pressed_action
          if action != previous_hover
            animate_mode_switch(action == 'representation')
            animate_drawer_mode_switch(action == 'drawer_toggle_space_mode')
          end
          animate_refresh_group(refresh_hover)
          animate_library_group(library_hover)
          if view.respond_to?(:tooltip=)
            if action
              view.tooltip = tooltip_for(action, view)
            elsif library_hover
              view.tooltip = '展开模型库、材质库与吸管'
            elsif refresh_hover
              view.tooltip = '展开其他专业更新'
            elsif workspace_hover
              view.tooltip = '选择建筑 / 硬装 / 软装 / 景观工作区'
            else
              view.tooltip = ''
            end
          end
          view.invalidate if changed
          true
        rescue StandardError
          false
        end

        def clear_tool_pointer(view = nil, preserve_drawer: false)
          changed = !@hover_action.nil? || !@pressed_action.nil?
          animate_mode_switch(false) if @hover_action == 'representation'
          animate_drawer_mode_switch(false) if @hover_action == 'drawer_toggle_space_mode'
          animate_refresh_group(false)
          animate_library_group(false)
          @hover_action = nil
          @hover_row_key = nil
          @pressed_action = nil
          if preserve_drawer && @drawer_open
            @drawer_pointer_inside = true
            cancel_drawer_close_timer
            arm_drawer_release_guard!
          elsif !drawer_interaction_hold_active?
            @drawer_pointer_inside = false
            schedule_drawer_close
          end
          target_view = view || (@model.active_view if @model)
          target_view.invalidate if changed && target_view
          true
        rescue StandardError
          false
        end

        def expand_drawer!(pin: false)
          cancel_drawer_open_timer
          cancel_drawer_close_timer
          changed = !@drawer_open || @drawer_progress.to_f < 0.999 || (pin && !@drawer_pinned)
          @drawer_open = true
          @drawer_pinned = true if pin
          animate_drawer_to(1.0) if changed
          invalidate_view if changed
          schedule_drawer_live_refresh_after_open if changed && @model
          true
        end

        def toggle_drawer_pin!
          @drawer_open = true
          @drawer_pinned = !@drawer_pinned
          animate_drawer_to(1.0) if @drawer_progress.to_f < 0.999
          cancel_drawer_close_timer if @drawer_pinned
          schedule_drawer_close unless @drawer_pinned || @drawer_pointer_inside
          invalidate_view
          true
        end

        def collapse_drawer!(force: false)
          return true if @drawer_pinned && !force
          cancel_drawer_timers
          cancel_drawer_live_refresh
          changed = @drawer_open || @drawer_progress.to_f.positive? || @drawer_pinned
          @drawer_pinned = false if force
          @drawer_pointer_inside = false if force
          @hover_action = nil if @hover_action.to_s.start_with?('drawer_')
          @hover_row_key = nil
          cancel_space_drag! if force
          animate_drawer_to(0.0) if changed
          invalidate_view if changed
          true
        end

        def drawer_open?
          !!@drawer_open
        end

        def drawer_tools_mode?
          !!@drawer_tools_mode
        end

        def toggle_drawer_tools_mode!
          @drawer_tools_mode = !@drawer_tools_mode
          @space_manage_mode = false if @drawer_tools_mode
          @space_manage_selected = {} if @drawer_tools_mode
          @space_scroll_index = 0
          invalidate_view
          @drawer_tools_mode
        rescue StandardError
          false
        end

        def finish_drawer_tools_mode!
          changed = !!@drawer_tools_mode
          @drawer_tools_mode = false
          invalidate_view if changed
          true
        rescue StandardError
          false
        end

        def workspace_picker_mode?
          !!@drawer_workspace_picker
        end

        # 工作区归属只在抽屉内选择。切换时进入轻量本地页面，不弹 UI.inputbox，
        # 不读取共享 SKP，也不刷新主面板。
        def open_workspace_picker!
          @drawer_workspace_picker = true
          @drawer_tools_mode = false
          @space_manage_mode = false
          @space_manage_selected = {}
          @space_scroll_index = 0
          @drawer_open = true
          animate_drawer_to(1.0) if @drawer_progress.to_f < 0.999
          invalidate_view
          true
        rescue StandardError
          false
        end

        def close_workspace_picker!
          changed = !!@drawer_workspace_picker
          @drawer_workspace_picker = false
          # v0.13.6.21：顶部四专业标签是主导航。切换专业时清空旧专业的临时管理/拖拽状态，
          # 避免硬装管理选择残留到软装，或建筑滚动位置带入新的当前工作区。
          @space_scroll_index = 0
          @architecture_scroll_index = 0
          @space_manage_mode = false
          @space_manage_selected = {}
          @architecture_manage_mode = false
          @architecture_manage_selected = {}
          cancel_space_drag!
          invalidate_view if changed
          true
        rescue StandardError
          false
        end

        def pointer_in_interactive_area?
          toolbar_visible? && (@drawer_pointer_inside || !@hover_action.nil?)
        end

        def scroll_drawer(delta, x, y, view)
          return false unless toolbar_visible? && @drawer_open
          remember_view(view)
          return false unless point_in_rect?(x, y, drawer_rect(view))
          layout = drawer_layout(view)
          step = delta.to_i.positive? ? -1 : 1
          if layout[:architecture_expanded] && layout[:architecture_list_y] &&
             y.to_f >= layout[:architecture_list_y].to_f && y.to_f <= layout[:architecture_list_bottom].to_f
            old_index = @architecture_scroll_index.to_i
            @architecture_scroll_index = old_index + step
            clamp_architecture_scroll(view)
            view.invalidate if @architecture_scroll_index != old_index
          elsif layout[:space_expanded] && layout[:list_y] &&
                y.to_f >= layout[:list_y].to_f && y.to_f <= layout[:list_bottom].to_f
            old_index = @space_scroll_index.to_i
            @space_scroll_index = old_index + step
            clamp_space_scroll(view)
            view.invalidate if @space_scroll_index != old_index
          else
            return false
          end
          true
        rescue StandardError
          false
        end

        def space_manage_mode?
          !!@space_manage_mode
        end

        def toggle_space_manage_mode!
          @space_manage_mode = !@space_manage_mode
          @space_manage_selected = {} unless @space_manage_mode
          @space_scroll_index = 0
          clamp_architecture_scroll
          clamp_space_scroll
          clamp_architecture_scroll
          invalidate_view
          @space_manage_mode
        rescue StandardError
          false
        end

        def finish_space_manage_mode!
          changed = @space_manage_mode || !(@space_manage_selected || {}).empty?
          @space_manage_mode = false
          @space_manage_selected = {}
          cancel_space_drag!
          @space_scroll_index = 0
          clamp_space_scroll
          invalidate_view if changed
          true
        rescue StandardError
          false
        end

        def toggle_space_manage_selection!(space_id)
          return false unless @space_manage_mode
          key = space_id.to_s
          return false if key.empty?
          @space_manage_selected ||= {}
          if @space_manage_selected[key]
            @space_manage_selected.delete(key)
          else
            @space_manage_selected[key] = true
          end
          invalidate_view
          true
        rescue StandardError
          false
        end

        def space_manage_selected?(space_id)
          !!(@space_manage_selected && @space_manage_selected[space_id.to_s])
        end

        def space_manage_selected_ids
          (@space_manage_selected || {}).select { |_space_id, selected| selected }.keys
        rescue StandardError
          []
        end

        def clear_space_manage_selection!
          @space_manage_selected = {}
          invalidate_view
          true
        rescue StandardError
          false
        end

        def architecture_manage_mode?
          !!@architecture_manage_mode
        end

        def toggle_architecture_manage_mode!
          @architecture_manage_mode = !@architecture_manage_mode
          @architecture_manage_selected = {} unless @architecture_manage_mode
          @architecture_scroll_index = 0
          clamp_architecture_scroll
          invalidate_view
          @architecture_manage_mode
        rescue StandardError
          false
        end

        def finish_architecture_manage_mode!
          changed = @architecture_manage_mode || !(@architecture_manage_selected || {}).empty?
          @architecture_manage_mode = false
          @architecture_manage_selected = {}
          @architecture_scroll_index = 0
          clamp_architecture_scroll
          invalidate_view if changed
          true
        rescue StandardError
          false
        end

        def toggle_architecture_manage_selection!(architecture_id)
          return false unless @architecture_manage_mode
          key = architecture_id.to_s
          return false if key.empty?
          @architecture_manage_selected ||= {}
          if @architecture_manage_selected[key]
            @architecture_manage_selected.delete(key)
          else
            @architecture_manage_selected[key] = true
          end
          invalidate_view
          true
        rescue StandardError
          false
        end

        def architecture_manage_selected?(architecture_id)
          !!(@architecture_manage_selected && @architecture_manage_selected[architecture_id.to_s])
        end

        def architecture_manage_selected_ids
          (@architecture_manage_selected || {}).select { |_architecture_id, selected| selected }.keys
        rescue StandardError
          []
        end

        def professional_section_collapsed?(key)
          section = key.to_s
          overrides = @professional_section_collapsed_overrides ||= {}
          return !!overrides[section] if overrides.key?(section)
          persisted = @state['professional_section_collapsed'].is_a?(Hash) ? @state['professional_section_collapsed'] : {}
          return !!persisted[section] if persisted.key?(section)
          @state['host_discipline'].to_s != section
        rescue StandardError
          false
        end

        def toggle_professional_section!(key)
          section = key.to_s
          return false unless ['architecture', SPACE_COLLECTION_KEY, SOFT_SPACE_COLLECTION_KEY].include?(section)
          collapsed = !professional_section_collapsed?(section)
          @professional_section_collapsed_overrides ||= {}
          @professional_section_collapsed_overrides[section] = collapsed
          @architecture_scroll_index = 0 if section == 'architecture'
          @space_scroll_index = 0 if SPACE_COLLECTION_KEYS.include?(section)
          @architecture_manage_mode = false if collapsed && section == 'architecture'
          @architecture_manage_selected = {} if collapsed && section == 'architecture'
          @space_manage_mode = false if collapsed && SPACE_COLLECTION_KEYS.include?(section)
          @space_manage_selected = {} if collapsed && SPACE_COLLECTION_KEYS.include?(section)
          GavinTools::SULinkHubMultiSpace::Runtime.set_professional_section_collapsed!(section, collapsed, @model)
          invalidate_view
          collapsed
        rescue StandardError
          false
        end

        def begin_space_drag_candidate(x, y, view = nil)
          return false unless @space_manage_mode
          row = drawer_row_at(x, y, view)
          return false unless row
          layout = drawer_layout(view)
          row_index = visible_drawer_spaces(view).index(row)
          return false unless row_index
          row_y = layout[:list_y] + row_index * DRAWER_ROW_PITCH

          kind = row['kind'].to_s
          if kind == 'space'
            # 组内成员向右缩进；复选框和右侧悬停按钮保持普通点击，名称主体支持短按重命名、长按拖动。
            indent = grouped_space_row?(row) ? DRAWER_GROUP_MEMBER_INDENT : 0.0
            card_y, card_height = drawer_row_vertical_metrics(row, row_y)
            return false unless x.to_f >= layout[:x] + 42.0 + indent && x.to_f <= layout[:x] + 192.0 &&
                                y.to_f >= card_y && y.to_f <= card_y + card_height
          elsif kind == 'group'
            return false if row['pseudo']
            # 组名称主体支持短按改名、长按拖动排序；右侧小眼睛和圆形箭头保持独立点击。
            return false unless x.to_f >= layout[:x] + 14.0 && x.to_f <= layout[:x] + layout[:width] - 78.0 && y.to_f <= row_y + 36.0
          else
            return false
          end

          cancel_space_drag!
          @space_drag_candidate = {
            'kind' => kind,
            'id' => row['id'].to_s,
            'label' => row['name'].to_s,
            'origin_x' => x.to_f,
            'origin_y' => y.to_f,
            'started_at' => Process.clock_gettime(Process::CLOCK_MONOTONIC)
          }
          @space_drag_point = [x.to_f, y.to_f]
          # 0.28 秒足以区分点击与拖动，同时比旧版 0.38 秒更跟手。
          @space_drag_timer = GavinTools::SULinkHubMultiSpace::Runtime.runtime_start_timer(0.28, false, label: 'space_group:long_press') do
            if @space_drag_candidate && @space_manage_mode
              @space_dragging = true
              @space_drag_target_key = nil
              invalidate_view
            end
            @space_drag_timer = nil
          end
          true
        rescue StandardError
          cancel_space_drag!
          false
        end

        def update_space_drag(x, y, view = nil)
          return false unless @space_drag_candidate || @space_dragging
          @space_drag_point = [x.to_f, y.to_f]
          if @space_drag_candidate && !@space_dragging
            dx = x.to_f - @space_drag_candidate['origin_x'].to_f
            dy = y.to_f - @space_drag_candidate['origin_y'].to_f
            cancel_space_drag! if Math.sqrt(dx * dx + dy * dy) > 8.0
            return false unless @space_drag_candidate
          end
          if @space_dragging
            layout = drawer_layout(view)
            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            if now - @space_drag_last_scroll_at.to_f >= 0.12
              old_index = @space_scroll_index.to_i
              if y.to_f <= layout[:list_y] + 15.0
                @space_scroll_index = old_index - 1
              elsif y.to_f >= layout[:list_bottom] - 15.0
                @space_scroll_index = old_index + 1
              end
              clamp_space_scroll(view)
              @space_drag_last_scroll_at = now if @space_scroll_index.to_i != old_index
            end
            row = drawer_row_at(x, y, view)
            candidate_kind = @space_drag_candidate['kind'].to_s
            candidate_id = @space_drag_candidate['id'].to_s
            valid_target = if candidate_kind == 'group'
                             row && ((row['kind'].to_s == 'group' && !row['pseudo'] && row['id'].to_s != candidate_id) ||
                               (row['kind'].to_s == 'space' && !row['group_id'].to_s.empty? && row['group_id'].to_s != candidate_id))
                           else
                             row && !(row['kind'].to_s == 'space' && row['id'].to_s == candidate_id)
                           end
            @space_drag_target_key = if valid_target && candidate_kind == 'group' && row['kind'].to_s == 'space'
                                       "group:#{row['group_id']}"
                                     elsif valid_target
                                       "#{row['kind']}:#{row['id']}"
                                     end
            invalidate_view
          end
          true
        rescue StandardError
          cancel_space_drag!
          false
        end

        def finish_space_drag(x, y, view = nil)
          return nil unless @space_drag_candidate || @space_dragging
          update_space_drag(x, y, view)
          payload = nil
          if @space_dragging && @space_drag_candidate
            row = drawer_row_at(x, y, view)
            candidate_kind = @space_drag_candidate['kind'].to_s
            candidate_id = @space_drag_candidate['id'].to_s
            if candidate_kind == 'group'
              target_group_id = if row && row['kind'].to_s == 'group' && !row['pseudo']
                                  row['id'].to_s
                                elsif row && row['kind'].to_s == 'space'
                                  row['group_id'].to_s
                                else
                                  ''
                                end
              if !target_group_id.empty? && target_group_id != candidate_id
                layout = drawer_layout(view)
                row_index = visible_drawer_spaces(view).index(row)
                row_y = layout[:list_y] + row_index.to_i * DRAWER_ROW_PITCH
                payload = {
                  'kind' => 'group',
                  'group_id' => candidate_id,
                  'target_group_id' => target_group_id,
                  'position' => y.to_f < drawer_row_center_y(row, row_y) ? 'before' : 'after'
                }
              end
            elsif row && !(row['kind'].to_s == 'space' && row['id'].to_s == candidate_id)
              if row['kind'].to_s == 'group'
                payload = {
                  'kind' => 'space',
                  'space_id' => candidate_id,
                  'target_group_id' => row['id'].to_s,
                  'target_space_id' => '',
                  'position' => 'after'
                }
              else
                layout = drawer_layout(view)
                row_index = visible_drawer_spaces(view).index(row)
                row_y = layout[:list_y] + row_index.to_i * DRAWER_ROW_PITCH
                payload = {
                  'kind' => 'space',
                  'space_id' => candidate_id,
                  'target_group_id' => row['group_id'].to_s,
                  'target_space_id' => row['id'].to_s,
                  'position' => y.to_f < drawer_row_center_y(row, row_y) ? 'before' : 'after'
                }
              end
            end
          end
          cancel_space_drag!
          payload
        rescue StandardError
          cancel_space_drag!
          nil
        end

        def space_drag_active?
          !!(@space_drag_candidate || @space_dragging)
        end

        def space_dragging?
          !!@space_dragging
        end

        def cancel_space_drag!
          if @space_drag_timer
            GavinTools::SULinkHubMultiSpace::Runtime.runtime_stop_timer(@space_drag_timer)
          end
          @space_drag_timer = nil
          @space_drag_candidate = nil
          @space_dragging = false
          @space_drag_point = nil
          @space_drag_target_key = nil
          @space_drag_last_scroll_at = 0.0
          invalidate_view
          true
        rescue StandardError
          @space_drag_timer = nil
          @space_drag_candidate = nil
          @space_dragging = false
          @space_drag_point = nil
          @space_drag_target_key = nil
          @space_drag_last_scroll_at = 0.0
          false
        end

        # 成组后把新组卡片滚动到可见位置，避免成员空间折叠后看起来像“消失”。
        def reveal_space_group!(group_id)
          key = group_id.to_s
          return false if key.empty?
          rows = drawer_rows
          index = rows.index { |row| row['kind'].to_s == 'group' && row['id'].to_s == key }
          return false unless index
          capacity = visible_space_capacity
          max_start = [rows.length - capacity, 0].max
          @space_scroll_index = [[index, 0].max, max_start].min
          @hover_row_key = "group:#{key}"
          clamp_space_scroll
          invalidate_view
          true
        rescue StandardError
          false
        end

        # 热重载必须使用新运行代的 Overlay 类，否则即使方法名相同，视口中仍会
        # 执行旧版本的方法体。这里只导出纯界面状态，绝不携带计时器、拖动事务或
        # SketchUp 对象；新 Overlay 重建后可无感恢复抽屉开合、钉住和滚动位置。
        def export_hot_reload_state
          state_copy = begin
            Marshal.load(Marshal.dump(@state))
          rescue StandardError
            @state.is_a?(Hash) ? @state.dup : { 'visible' => false }
          end
          {
            'state' => state_copy,
            'drawer_open' => !!@drawer_open,
            'drawer_pinned' => !!@drawer_pinned,
            'drawer_progress' => @drawer_progress.to_f,
            'space_scroll_index' => @space_scroll_index.to_i,
            'architecture_scroll_index' => @architecture_scroll_index.to_i,
            'professional_section_collapsed_overrides' => (@professional_section_collapsed_overrides || {}).dup,
            'architecture_manage_mode' => !!@architecture_manage_mode,
            'architecture_manage_selected' => (@architecture_manage_selected || {}).dup,
            'drawer_tools_mode' => !!@drawer_tools_mode,
            'drawer_workspace_picker' => !!@drawer_workspace_picker,
            'space_manage_mode' => !!@space_manage_mode,
            'space_manage_selected' => (@space_manage_selected || {}).dup,
            'floating_notice_message' => @floating_notice_message.to_s,
            'floating_notice_level' => @floating_notice_level.to_s,
            'floating_notice_progress' => @floating_notice_progress,
            'floating_notice_persistent' => !!@floating_notice_persistent,
            'floating_notice_expires_at' => @floating_notice_expires_at
          }
        rescue StandardError
          {}
        end

        def import_hot_reload_state!(snapshot)
          data = snapshot.is_a?(Hash) ? snapshot : {}
          incoming_state = data['state']
          @state = incoming_state if incoming_state.is_a?(Hash)
          @drawer_open = data['drawer_open'] == true
          @drawer_pinned = data['drawer_pinned'] == true
          @drawer_progress = if @drawer_open
                               value = data['drawer_progress'].to_f
                               value.positive? ? [[value, 0.0].max, 1.0].min : 1.0
                             else
                               0.0
                             end
          @space_scroll_index = [data['space_scroll_index'].to_i, 0].max
          @architecture_scroll_index = [data['architecture_scroll_index'].to_i, 0].max
          collapsed_overrides = data['professional_section_collapsed_overrides']
          @professional_section_collapsed_overrides = collapsed_overrides.is_a?(Hash) ? collapsed_overrides.dup : {}
          @architecture_manage_mode = data['architecture_manage_mode'] == true
          architecture_selected = data['architecture_manage_selected']
          @architecture_manage_selected = architecture_selected.is_a?(Hash) ? architecture_selected.dup : {}
          @drawer_tools_mode = data['drawer_tools_mode'] == true
          @drawer_workspace_picker = data['drawer_workspace_picker'] == true
          @space_manage_mode = data['space_manage_mode'] == true
          selected = data['space_manage_selected']
          @space_manage_selected = selected.is_a?(Hash) ? selected.dup : {}
          cancel_floating_notice_timer
          @floating_notice_message = data['floating_notice_message'].to_s
          @floating_notice_level = data['floating_notice_level'].to_s.empty? ? 'info' : data['floating_notice_level'].to_s
          fp = data['floating_notice_progress']
          @floating_notice_progress = fp.nil? ? nil : [[fp.to_f, 0.0].max, 100.0].min
          @floating_notice_persistent = data['floating_notice_persistent'] == true
          @floating_notice_expires_at = data['floating_notice_expires_at']
          @floating_notice_layout_cache = nil
          if !@floating_notice_message.empty? && !@floating_notice_persistent
            remaining = @floating_notice_expires_at.to_f - Time.now.to_f
            if remaining > 0.05
              @floating_notice_timer = GavinTools::SULinkHubMultiSpace::Runtime.runtime_start_timer(remaining, false) do
                @floating_notice_timer = nil
                @floating_notice_message = ''
                @floating_notice_progress = nil
                @floating_notice_persistent = false
                @floating_notice_expires_at = nil
                invalidate_view
              end
            else
              @floating_notice_message = ''
              @floating_notice_progress = nil
              @floating_notice_persistent = false
              @floating_notice_expires_at = nil
            end
          end
          @drawer_pointer_inside = false
          @hover_action = nil
          @hover_row_key = nil
          @pressed_action = nil
          cancel_drawer_timers
          cancel_space_drag!
          clamp_space_scroll
          invalidate_view
          true
        rescue StandardError
          false
        end

        private

        def toolbar_visible?
          @active && @state['visible'] == true
        end

        def quick_toolbar_visible?
          toolbar_visible? && @state['quick_toolbar_visible'] != false
        end

        def screen_point(x, y)
          Geom::Point3d.new(x.to_f, y.to_f, 0.0)
        end

        def rgba(red, green, blue, alpha = 255)
          Sketchup::Color.new(red, green, blue, alpha)
        rescue ArgumentError
          Sketchup::Color.new(red, green, blue)
        end

        def rounded_rect_points(x, y, width, height, radius, segments = 5)
          r = [radius.to_f, width.to_f / 2.0, height.to_f / 2.0].min
          return [
            screen_point(x, y), screen_point(x + width, y),
            screen_point(x + width, y + height), screen_point(x, y + height)
          ] if r <= 0.01
          points = []
          corners = [
            [x + r, y + r, Math::PI, Math::PI * 1.5],
            [x + width - r, y + r, Math::PI * 1.5, Math::PI * 2.0],
            [x + width - r, y + height - r, 0.0, Math::PI * 0.5],
            [x + r, y + height - r, Math::PI * 0.5, Math::PI]
          ]
          corners.each do |cx, cy, start_angle, end_angle|
            segments.times do |i|
              t = segments == 1 ? 0.0 : i.to_f / (segments - 1).to_f
              angle = start_angle + (end_angle - start_angle) * t
              points << screen_point(cx + Math.cos(angle) * r, cy + Math.sin(angle) * r)
            end
          end
          points
        end

        def draw_round_rect(view, x, y, width, height, radius, color)
          points = rounded_rect_points(x, y, width, height, radius)
          view.drawing_color = color
          view.draw2d(GL_POLYGON, points)
          points
        rescue StandardError
          view.drawing_color = color
          points = [screen_point(x, y), screen_point(x + width, y), screen_point(x + width, y + height), screen_point(x, y + height)]
          view.draw2d(GL_QUADS, points)
          points
        end

        def draw_text_safe(view, x, y, text, color, size: 12, bold: true)
          view.draw_text(screen_point(x, y), text.to_s, color: color, size: size, bold: bold, font: 'Microsoft YaHei')
        rescue ArgumentError
          view.drawing_color = color
          view.draw_text(screen_point(x, y), text.to_s)
        end

        def button_definitions
          representation = @state['display_mode'].to_s == 'full' ? 'full' : 'proxy'
          preview_space_id = @state['representation_preview_space_id'].to_s
          representation_selection_count = @state['representation_selection_count'].to_i
          representation_selection_mixed = @state['representation_selection_mixed'] == true
          representation_selection_label = @state['representation_selection_label'].to_s
          representation_selection_scope = @state['representation_selection_scope'].to_s
          proxy_first_host = %w[architecture landscape].include?(@state['host_discipline'].to_s)
          refs_visible = @state['references_visible'] == true
          primary_icon = @state['quick_primary_icon'].to_s
          buttons = []
          queue_jobs = Array(@state['publish_queue_jobs'])
          queue_active = @state['publish_queue_active_count'].to_i
          queue_total = queue_jobs.length
          buttons << {
            action: 'publish_queue_toggle', label: queue_active.to_s, icon: :history,
            group: :queue, slot: 0, active: @publish_queue_open || queue_active.positive?, enabled: true,
            tooltip: "任务队列：#{queue_active} 个进行中 / #{queue_total} 条可查看记录；发布、清单刷新、Excel、目录扫描统一显示",
            color: queue_active.positive? ? [84, 104, 166] : [61, 64, 73], kind: :publish_queue
          }
          context_text = @state['quick_context_text'].to_s.strip
          unless context_text.empty?
            buttons << {
              action: 'quick_context_label', label: context_text, group: :context, slot: 0,
              active: false, enabled: false, tooltip: @state['quick_context_tooltip'].to_s,
              color: [28, 31, 38], kind: :context_label,
              context_width: @state['quick_context_width'].to_f
            }
          end
          Array(@state['quick_library_buttons']).each_with_index do |raw, index|
            next unless raw.is_a?(Hash)
            icon_name = raw['icon'].to_s
            buttons << {
              action: raw['action'].to_s,
              label: raw['label'].to_s,
              icon: icon_name.empty? ? nil : icon_name.to_sym,
              group: :library, slot: index,
              active: raw['active'] == true,
              enabled: raw['enabled'] != false,
              tooltip: raw['tooltip'].to_s,
              color: Array(raw['color']).length >= 3 ? Array(raw['color']) : [116, 75, 202],
              kind: :library_tool
            }
          end
          buttons << {
              action: (@state['quick_primary_action'].to_s.empty? ? 'quick_primary_disabled' : @state['quick_primary_action'].to_s),
              label: @state['quick_primary_label'].to_s,
              icon: primary_icon.empty? ? nil : primary_icon.to_sym,
              group: :main, slot: 0,
              active: @state['quick_primary_active'] == true,
              enabled: @state['quick_primary_enabled'] == true,
              tooltip: @state['quick_primary_tooltip'].to_s,
              color: Array(@state['quick_primary_color']).length >= 3 ? Array(@state['quick_primary_color']) : [58, 119, 225]
            }

          main_slot = 1
          component_action = @state['quick_component_action'].to_s
          unless component_action.empty?
            component_icon = @state['quick_component_icon'].to_s
            buttons << {
              action: component_action,
              label: '', icon: (component_icon.empty? ? :plus : component_icon.to_sym),
              group: :main, slot: main_slot,
              active: @state['quick_component_active'] == true,
              enabled: @state['quick_component_enabled'] != false,
              tooltip: @state['quick_component_tooltip'].to_s,
              color: Array(@state['quick_component_color']).length >= 3 ? Array(@state['quick_component_color']) : [49, 145, 111]
            }
            main_slot += 1
          end
          # v0.13.6.139：协同组件“更新全部”是项目级提醒，不属于当前空间的主操作。
          # 它独立放到整条顶部悬浮栏最右侧，避免夹在发布/显示/代真等主操作中造成误解。
          component_update_action = @state['quick_component_update_action'].to_s
          unless component_update_action.empty?
            component_update_icon = @state['quick_component_update_icon'].to_s
            buttons << {
              action: component_update_action,
              label: '', icon: (component_update_icon.empty? ? :download : component_update_icon.to_sym),
              group: :component_update, slot: 0,
              active: @state['quick_component_update_active'] == true,
              enabled: @state['quick_component_update_enabled'] != false,
              tooltip: @state['quick_component_update_tooltip'].to_s,
              color: Array(@state['quick_component_update_color']).length >= 3 ? Array(@state['quick_component_update_color']) : [214, 164, 45],
              kind: :standalone_alert
            }
          end
          copy_action = @state['quick_copy_action'].to_s
          unless copy_action.empty?
            buttons << {
              action: copy_action,
              label: '', icon: (@state['quick_copy_confirm'] == true ? :check : :copy),
              group: :main, slot: main_slot,
              active: @state['quick_copy_active'] == true,
              enabled: @state['quick_copy_enabled'] != false,
              tooltip: @state['quick_copy_tooltip'].to_s,
              color: Array(@state['quick_copy_color']).length >= 3 ? Array(@state['quick_copy_color']) : [48, 132, 218]
            }
            main_slot += 1
          end
          if @state['references_button_visible'] == true
            buttons << {
              action: 'references', label: '', group: :main, slot: main_slot,
              active: refs_visible, enabled: @state['references_enabled'] == true,
              tooltip: if @state['references_enabled'] == true
                         refs_visible ? '隐藏其他专业参考' : '显示其他专业参考'
                       else
                         '当前没有可切换的其他专业参考'
                       end,
              color: refs_visible ? [52, 137, 203] : [61, 64, 73]
            }
            main_slot += 1
          end

          if @state['representation_supported'] == true
            buttons << {
              action: 'representation', label: '', group: :main, slot: main_slot,
              active: true, enabled: @state['representation_enabled'] != false,
              hover_expand: false, wide: true, directional: true, kind: :mode_switch,
              tooltip: if representation_selection_scope == 'empty_container'
                         '当前选中的组/组件内没有 LinkHub 家具；不会误切换整个空间'
                       elsif representation_selection_count.positive?
                         scope_text = representation_selection_label.empty? ? '已选中' : representation_selection_label
                         "#{scope_text} #{representation_selection_count} 个家具#{representation_selection_mixed ? '（代/真混合）' : ''}；左侧=仅此范围代理，右侧=仅此范围真模型"
                       elsif proxy_first_host
                         '左侧=代理、右侧=真模型；未选家具时作用于当前/选中的空间范围'
                       else
                         '左侧=代理、右侧=真模型；点击目标方向，不再做盲目反向切换'
                       end,
              color: [88, 67, 144]
            }
            main_slot += 1
          end

          # v0.13.6.18：强制解锁紧跟在代/真切换右侧。它不是“协同修改”的旁路，
          # 只进入本地历史取物模式；退出时恢复进入前快照，且任何发布入口都会拒绝。
          force_action = @state['quick_force_unlock_action'].to_s
          unless force_action.empty?
            buttons << {
              action: force_action,
              label: '', icon: :unlock,
              group: :main, slot: main_slot,
              active: @state['quick_force_unlock_active'] == true,
              enabled: @state['quick_force_unlock_enabled'] != false,
              tooltip: @state['quick_force_unlock_tooltip'].to_s,
              color: Array(@state['quick_force_unlock_color']).length >= 3 ? Array(@state['quick_force_unlock_color']) : [195, 74, 65]
            }
            main_slot += 1
          end

          # “取消修改”仍使用琥珀色强调它是回退动作，但视觉上并入主操作胶囊。
          # 排在强制解锁右侧，与发布 / 参考眼睛 / 代真保持同一组，不再单独套一层外框。
          cancel_action = @state['quick_cancel_action'].to_s
          unless cancel_action.empty?
            buttons << {
              action: cancel_action,
              label: '', icon: :close,
              group: :main, slot: main_slot,
              active: true,
              enabled: @state['quick_cancel_enabled'] != false,
              tooltip: @state['quick_cancel_tooltip'].to_s,
              color: Array(@state['quick_cancel_color']).length >= 3 ? Array(@state['quick_cancel_color']) : [190, 82, 64]
            }
            main_slot += 1
          end

          # v0.13.2.3：顶部悬浮条不再暴露任何“全部/跨专业更新”入口。
          # 大项目里这类按钮一次可能触发大量空间/专业更新，误触会让 SketchUp 长时间无响应。
          # quick_aux_buttons 的底层状态和动作仍保留给抽屉、诊断和兼容逻辑使用；这里只是不绘制日常顶部入口。
          buttons
        end

        def remember_view(view = nil)
          return unless view
          @last_view_width = view.vpwidth.to_f if view.respond_to?(:vpwidth)
          @last_view_height = view.vpheight.to_f if view.respond_to?(:vpheight)
        rescue StandardError
          nil
        end

        def view_width(view = nil)
          remember_view(view)
          width = @last_view_width.to_f
          width = @model.active_view.vpwidth.to_f if width <= 0.0 && @model
          [width, 1.0].max
        rescue StandardError
          1.0
        end

        def view_height(view = nil)
          remember_view(view)
          height = @last_view_height.to_f
          height = @model.active_view.vpheight.to_f if height <= 0.0 && @model
          [height, 1.0].max
        rescue StandardError
          1.0
        end

        def refresh_group_expandable?
          aux = Array(@state['quick_aux_buttons'])
          aux.length > 1 && aux.all? { |item| item.is_a?(Hash) && item['kind'].to_s == 'discipline_refresh' }
        rescue StandardError
          false
        end

        def refresh_group_progress
          return 1.0 unless refresh_group_expandable?
          [[@refresh_group_progress.to_f, 0.0].max, 1.0].min
        rescue StandardError
          0.0
        end

        def refresh_group_hover_at?(x, y, view = nil)
          return false unless quick_toolbar_visible? && refresh_group_expandable?
          group = toolbar_layout(view)[:groups].find { |entry| entry[:name] == :aux }
          !!(group && point_in_rect?(x, y, group[:rect]))
        rescue StandardError
          false
        end

        # 当前正在室内空间根内部协同修改时，把最常用的“模型库/家具入库”
        # 与“代理/真模型”直接展开。退出空间根进入安全暂存、结束修改或切换工作区后
        # 自动恢复收纳；不再要求用户每次把鼠标悬停到药丸上。
        def space_edit_tools_auto_expanded?
          @state.is_a?(Hash) &&
            @state['host_discipline'].to_s == SOFT_SPACE_COLLECTION_KEY &&
            @state['space_editing'] == true &&
            @state['space_inside'] == true
        rescue StandardError
          false
        end

        def mode_switch_progress
          return 1.0 if space_edit_tools_auto_expanded?
          [[@mode_switch_progress.to_f, 0.0].max, 1.0].min
        rescue StandardError
          0.0
        end

        def library_group_expandable?
          items = Array(@state['quick_library_buttons'])
          items.length > 1 && items.all? { |item| item.is_a?(Hash) }
        rescue StandardError
          false
        end

        def library_group_progress
          return 1.0 unless library_group_expandable?
          return 1.0 if space_edit_tools_auto_expanded?
          [[@library_group_progress.to_f, 0.0].max, 1.0].min
        rescue StandardError
          0.0
        end

        def library_group_hover_at?(x, y, view = nil)
          return false unless quick_toolbar_visible? && library_group_expandable?
          group = toolbar_layout(view)[:groups].find { |entry| entry[:name] == :library }
          !!(group && point_in_rect?(x, y, group[:rect]))
        rescue StandardError
          false
        end

        # v0.13.6.21：工作区切换固定为抽屉顶部四个专业标签。
        # 下方只绘制当前专业树，最大化纵向空间。
        def workspace_switch_rect(view = nil)
          return nil unless @drawer_open && drawer_stage == 'ready' && !@drawer_tools_mode
          x, _y, width, = drawer_rect(view)
          layout = drawer_layout(view)
          [x + 10.0, layout[:project_y], width - 20.0, 30.0]
        rescue StandardError
          nil
        end

        # v0.13.6.30：顶部四专业不再等宽。当前专业适度变宽，其他专业轻微收窄，
        # 让视觉焦点一眼落在正在工作的专业上；绘制与点击命中统一复用同一份几何，避免错位。
        def workspace_professional_segments(rect, host_role = nil)
          return [] unless rect && rect.length >= 4
          x, y, width, height = rect.map(&:to_f)
          gap = 4.0
          roles = [
            ['architecture', '建筑'],
            [SPACE_COLLECTION_KEY, '硬装'],
            [SOFT_SPACE_COLLECTION_KEY, '软装'],
            ['landscape', '景观']
          ]
          host = host_role.to_s
          host = @state['host_discipline'].to_s if host.empty?
          usable = [width - gap * (roles.length - 1), 40.0].max
          # 等宽是 25%；当前专业提高到约 29.5%，其余三项均分剩余宽度。
          active_width = usable * 0.295
          inactive_width = (usable - active_width) / 3.0
          cursor_x = x
          roles.map do |role, label|
            current = role.to_s == host
            segment_width = current ? active_width : inactive_width
            result = {
              role: role,
              label: label,
              current: current,
              rect: [cursor_x, y, segment_width, height]
            }
            cursor_x += segment_width + gap
            result
          end
        rescue StandardError
          []
        end

        def workspace_switch_hover_at?(_x, _y, _view = nil)
          # v0.13.6.21：工作区标签固定横排，不再靠悬停展开，因此不再制造额外重绘。
          false
        rescue StandardError
          false
        end

        def workspace_switch_expanded?
          # 建筑 / 硬装 / 软装 / 景观始终固定显示在抽屉顶部。
          true
        end

        # 顶部空间/分组名称必须按照 SketchUp 实际绘制后的文字像素宽度排版。
        # 之前按“中文字符约多少 px”估算，在微软雅黑 + 中文/数字/括号混排时会明显偏宽，
        # 导致灰色胶囊看起来仍像固定宽度。SU 2020+ 提供 View#text_bounds，
        # 这里直接用和 draw_text 完全相同的字体参数测量；旧版本才退回字符估算。
        def toolbar_context_text_width(view, text)
          value = text.to_s
          return 30.0 if value.empty?
          if view && view.respond_to?(:text_bounds)
            begin
              bounds = view.text_bounds(
                screen_point(0.0, 0.0),
                value,
                font: 'Microsoft YaHei',
                size: 11,
                bold: true
              )
              measured = if bounds.respond_to?(:width)
                           bounds.width.to_f
                         elsif bounds.respond_to?(:upper_right) && bounds.respond_to?(:lower_left)
                           bounds.upper_right.x.to_f - bounds.lower_left.x.to_f
                         else
                           0.0
                         end
              # 左右各 7px，只留文字需要的呼吸边距。
              return [[measured + 14.0, 30.0].max, 390.0].min if measured.positive?
            rescue StandardError
              # 某些旧 SU/驱动环境 text_bounds 不可用时继续走保守回退。
            end
          end
          estimate = 14.0 + value.each_char.sum { |ch| ch.ascii_only? ? 5.2 : 9.0 }
          [[estimate, 30.0].max, 390.0].min
        rescue StandardError
          30.0
        end

        def overlay_text_width(view, text, size: 10, bold: false)
          value = text.to_s
          return 0.0 if value.empty?
          if view && view.respond_to?(:text_bounds)
            begin
              bounds = view.text_bounds(
                screen_point(0.0, 0.0), value,
                font: 'Microsoft YaHei', size: size, bold: bold
              )
              measured = if bounds.respond_to?(:width)
                           bounds.width.to_f
                         elsif bounds.respond_to?(:upper_right) && bounds.respond_to?(:lower_left)
                           bounds.upper_right.x.to_f - bounds.lower_left.x.to_f
                         else
                           0.0
                         end
              return measured if measured.positive?
            rescue StandardError
              nil
            end
          end
          value.each_char.sum { |char| char.ascii_only? ? size.to_f * 0.56 : size.to_f }
        rescue StandardError
          text.to_s.length * size.to_f * 0.56
        end

        def toolbar_button_width(button, view = nil)
          return BUTTON_SIZE unless button
          if button[:kind] == :context_label
            return toolbar_context_text_width(view, button[:label])
          end
          if button[:kind] == :mode_switch && button[:hover_expand] == true
            expanded = BUTTON_SIZE * 2.0 + BUTTON_GAP
            progress = mode_switch_progress
            return BUTTON_SIZE + (expanded - BUTTON_SIZE) * progress
          end
          button[:wide] == true ? (BUTTON_SIZE * 2.0 + BUTTON_GAP) : BUTTON_SIZE
        end

        def toolbar_layout(view = nil)
          buttons = button_definitions
          group_names = [:queue, :context, :library, :main, :cancel, :aux, :component_update].select { |name| buttons.any? { |button| button[:group] == name } }
          extra_groups = buttons.map { |button| button[:group] }.compact.uniq - group_names
          group_names.concat(extra_groups)
          height = TOOLBAR_PADDING * 2.0 + BUTTON_SIZE
          refresh_progress = refresh_group_progress
          group_specs = group_names.map do |group_name|
            members = buttons.select { |button| button[:group] == group_name }.sort_by { |button| button[:slot].to_i }
            if group_name == :library && library_group_expandable?
              expanded_extra = [members.length - 1, 0].max * (BUTTON_SIZE + BUTTON_GAP)
              content_width = BUTTON_SIZE + expanded_extra * library_group_progress
            elsif group_name == :aux && refresh_group_expandable?
              expanded_extra = [members.length - 1, 0].max * (BUTTON_SIZE + BUTTON_GAP)
              content_width = BUTTON_SIZE + expanded_extra * refresh_progress
            else
              content_width = members.sum { |button| toolbar_button_width(button, view) }
              content_width += BUTTON_GAP * [members.length - 1, 0].max
            end
            # 独立提醒按钮没有外层胶囊 padding；按钮自身就是完整圆形点击面。
            group_width = group_name == :component_update ? content_width : (TOOLBAR_PADDING * 2.0 + content_width)
            { name: group_name, buttons: members, width: group_width }
          end

          # 6.65：发布队列固定在视口顶部左侧；原来的工作区/模型库/代真/发布快捷条
          # 继续居中。这样队列数量始终在左上角可见，但不会把整条快捷工具条挤偏。
          queue_spec = group_specs.find { |group| group[:name] == :queue }
          # v138：黄色协同组件更新按钮作为独立提醒，不参与主悬浮栏居中计算。
          # 这样它出现/消失时，原来的发布、显示、代真等主按钮不会左右跳动。
          component_update_spec = group_specs.find { |group| group[:name] == :component_update }
          main_specs = group_specs.reject { |group| [:queue, :component_update].include?(group[:name]) }
          viewport_width = view_width(view)
          main_total_width = main_specs.sum { |group| group[:width] }
          main_total_width += TOOLBAR_GROUP_GAP * [main_specs.length - 1, 0].max
          main_centered = (viewport_width - main_total_width) / 2.0
          main_maximum = [viewport_width - main_total_width - VIEW_EDGE_GAP, VIEW_EDGE_GAP].max
          main_origin_x = [[main_centered, VIEW_EDGE_GAP].max, main_maximum].min

          queue_x = VIEW_EDGE_GAP
          if @drawer_open
            drawer_x, _drawer_y, drawer_width, = drawer_rect(view)
            queue_x = [drawer_x.to_f + drawer_width.to_f + VIEW_EDGE_GAP, VIEW_EDGE_GAP].max
          end
          if queue_spec && !main_specs.empty?
            queue_x = [queue_x, main_origin_x - queue_spec[:width] - TOOLBAR_GROUP_GAP].min
            queue_x = VIEW_EDGE_GAP if queue_x < VIEW_EDGE_GAP
          end

          entries = []
          groups = []
          positioned = []
          positioned << [queue_spec, queue_x] if queue_spec
          cursor = main_origin_x
          main_specs.each do |group|
            positioned << [group, cursor]
            cursor += group[:width] + TOOLBAR_GROUP_GAP
          end
          if component_update_spec
            # 放在主悬浮栏最右侧，并留出独立间距。正常视口下不改变主栏位置；
            # 极窄视口只做边缘夹紧，保证按钮仍可点击。
            update_x = cursor
            update_max = [viewport_width - component_update_spec[:width] - VIEW_EDGE_GAP, VIEW_EDGE_GAP].max
            update_x = [[update_x, VIEW_EDGE_GAP].max, update_max].min
            positioned << [component_update_spec, update_x]
          end

          positioned.each do |group, group_x|
            groups << { name: group[:name], rect: [group_x, ORIGIN_Y, group[:width], height] }
            base_x = group[:name] == :component_update ? group_x : (group_x + TOOLBAR_PADDING)
            if group[:name] == :library && library_group_expandable?
              progress = library_group_progress
              group[:buttons].each_with_index do |button, index|
                width = index.zero? ? BUTTON_SIZE : BUTTON_SIZE * progress
                x = base_x + index * (BUTTON_SIZE + BUTTON_GAP) * progress
                entries << { button: button, rect: [x, ORIGIN_Y + TOOLBAR_PADDING, width, BUTTON_SIZE], group_index: index }
              end
            elsif group[:name] == :aux && refresh_group_expandable?
              group[:buttons].each_with_index do |button, index|
                width = index.zero? ? BUTTON_SIZE : BUTTON_SIZE * refresh_progress
                x = base_x + index * (BUTTON_SIZE + BUTTON_GAP) * refresh_progress
                entries << { button: button, rect: [x, ORIGIN_Y + TOOLBAR_PADDING, width, BUTTON_SIZE], group_index: index }
              end
            else
              cursor_x = base_x
              group[:buttons].each_with_index do |button, index|
                width = toolbar_button_width(button, view)
                entries << { button: button, rect: [cursor_x, ORIGIN_Y + TOOLBAR_PADDING, width, BUTTON_SIZE], group_index: index }
                cursor_x += width + BUTTON_GAP
              end
            end
          end

          min_x = groups.map { |group| group[:rect][0].to_f }.min || VIEW_EDGE_GAP
          max_x = groups.map { |group| group[:rect][0].to_f + group[:rect][2].to_f }.max || (min_x + BUTTON_SIZE)
          {
            rect: [min_x, ORIGIN_Y, [max_x - min_x, BUTTON_SIZE].max, height],
            groups: groups,
            buttons: entries
          }
        end

        def publish_queue_jobs
          Array(@state['publish_queue_jobs']).select { |row| row.is_a?(Hash) }
        rescue StandardError
          []
        end

        def publish_queue_active_count
          @state['publish_queue_active_count'].to_i
        rescue StandardError
          0
        end

        def publish_queue_button_rect(view = nil)
          entry = toolbar_layout(view)[:buttons].find { |candidate| candidate[:button][:action].to_s == 'publish_queue_toggle' }
          entry ? entry[:rect] : [VIEW_EDGE_GAP, ORIGIN_Y + TOOLBAR_PADDING, BUTTON_SIZE, BUTTON_SIZE]
        rescue StandardError
          [VIEW_EDGE_GAP, ORIGIN_Y + TOOLBAR_PADDING, BUTTON_SIZE, BUTTON_SIZE]
        end

        def publish_queue_panel_rect(view = nil)
          bx, by, _bw, bh = publish_queue_button_rect(view)
          rows = [publish_queue_jobs.length, PUBLISH_QUEUE_PANEL_MAX_ROWS].min
          rows = 1 if rows.zero?
          width = [PUBLISH_QUEUE_PANEL_WIDTH, view_width(view) - VIEW_EDGE_GAP * 2.0].min
          height = 46.0 + rows * PUBLISH_QUEUE_PANEL_ROW_HEIGHT + 12.0
          x = [[bx, VIEW_EDGE_GAP].max, [view_width(view) - width - VIEW_EDGE_GAP, VIEW_EDGE_GAP].max].min
          y = by + bh + 9.0
          [x, y, width, height]
        rescue StandardError
          [VIEW_EDGE_GAP, ORIGIN_Y + BUTTON_SIZE + 12.0, PUBLISH_QUEUE_PANEL_WIDTH, 120.0]
        end

        def publish_queue_panel_controls(view = nil)
          return [] unless @publish_queue_open
          x, y, width, = publish_queue_panel_rect(view)
          [
            { action: 'publish_queue_open_logs', rect: [x + width - 116.0, y + 9.0, 52.0, 24.0], tooltip: '打开 LinkHub 日志目录', enabled: true },
            { action: 'publish_queue_clear_completed', rect: [x + width - 59.0, y + 9.0, 50.0, 24.0], tooltip: '清除已完成/失败的任务历史；不会删除模型、发布文件或导出文件', enabled: true }
          ]
        rescue StandardError
          []
        end

        def draw_publish_queue_panel(view)
          jobs = publish_queue_jobs
          x, y, width, height = publish_queue_panel_rect(view)
          shell = draw_round_rect(view, x, y, width, height, 18.0, rgba(24, 28, 36, 222))
          view.drawing_color = rgba(255, 255, 255, 54)
          view.draw2d(GL_LINE_LOOP, shell)
          active = publish_queue_active_count
          running_count = jobs.count do |row|
            status = row['status'].to_s
            status == 'running' || status == 'success' || row['main_finalize_pending'] == true
          end
          queued_count = jobs.count { |row| row['status'].to_s == 'queued' }
          header = if active.positive?
                     "任务队列 · #{running_count}执行 · #{queued_count}等待"
                   else
                     '任务队列 · 当前空闲'
                   end
          draw_text_safe(view, x + 13.0, y + 10.0, header, rgba(250, 252, 255, 250), size: 11, bold: true)
          publish_queue_panel_controls(view).each do |control|
            cx, cy, cw, ch = control[:rect]
            hovered = @hover_action.to_s == control[:action].to_s
            card = draw_round_rect(view, cx, cy, cw, ch, ch / 2.0, rgba(72, 81, 98, hovered ? 218 : 154))
            view.drawing_color = rgba(255, 255, 255, hovered ? 110 : 38)
            view.draw2d(GL_LINE_LOOP, card)
            label = control[:action].to_s == 'publish_queue_open_logs' ? '日志' : '清记录'
            draw_text_safe(view, cx + (label == '日志' ? 14.0 : 7.0), cy + 4.0, label, rgba(244, 247, 252, 244), size: 9, bold: true)
          end
          if jobs.empty?
            draw_text_safe(view, x + 15.0, y + 52.0, '当前没有耗时任务 · 发布、刷新、导出、扫描都会在这里显示', rgba(181, 191, 207, 220), size: 9, bold: false)
            return
          end
          rows = jobs.first(PUBLISH_QUEUE_PANEL_MAX_ROWS)
          rows.each_with_index do |job, index|
            ry = y + 42.0 + index * PUBLISH_QUEUE_PANEL_ROW_HEIGHT
            status = job['status'].to_s
            progress = [[job['progress'].to_i, 0].max, 100].min
            tint = if status == 'failed'
                     [151, 64, 67]
                   elsif %w[completed success maintenance cancelled].include?(status)
                     [54, 124, 92]
                   elsif status == 'queued'
                     [105, 94, 68]
                   else
                     [61, 94, 151]
                   end
            row_shell = draw_round_rect(view, x + 9.0, ry, width - 18.0, PUBLISH_QUEUE_PANEL_ROW_HEIGHT - 5.0, 12.0, rgba(tint[0], tint[1], tint[2], 78))
            view.drawing_color = rgba(255, 255, 255, 24)
            view.draw2d(GL_LINE_LOOP, row_shell)
            label = job['label'].to_s
            label = label[0, 22] + '…' if label.length > 23
            draw_text_safe(view, x + 19.0, ry + 6.0, label, rgba(250, 252, 255, 246), size: 10, bold: true)
            pct_text = status == 'failed' ? '失败' : (status == 'cancelled' ? '取消' : (status == 'completed' ? '完成' : "#{progress}%"))
            draw_text_safe(view, x + width - 54.0, ry + 6.0, pct_text, rgba(224, 231, 241, 226), size: 9, bold: true)
            stage = job['stage_label'].to_s
            stage = job['stage'].to_s if stage.empty?
            elapsed = job['stage_elapsed_seconds'].to_i
            total_elapsed = job['total_elapsed_seconds'].to_i
            publish_elapsed = job['publish_elapsed_seconds'].to_i
            suffix = if status == 'maintenance' && publish_elapsed.positive?
                       " · 发布#{publish_elapsed}s · 整理#{elapsed}s"
                     elsif %w[completed failed].include?(status) && publish_elapsed.positive?
                       total_elapsed > publish_elapsed ? " · 发布#{publish_elapsed}s / 总#{total_elapsed}s" : " · 发布#{publish_elapsed}s"
                     elsif elapsed.positive?
                       " · 本阶段#{elapsed}s"
                     else
                       ''
                     end
            draw_text_safe(view, x + 19.0, ry + 23.0, (stage + suffix)[0, 54], rgba(209, 219, 233, 224), size: 8, bold: false)
            detail = job['stage_detail'].to_s
            detail = job['error'].to_s if status == 'failed' && !job['error'].to_s.empty?
            draw_text_safe(view, x + 19.0, ry + 39.0, detail[0, 62], rgba(166, 180, 201, 205), size: 7, bold: false) unless detail.empty?
            bar_x = x + 19.0
            bar_y = ry + PUBLISH_QUEUE_PANEL_ROW_HEIGHT - 12.0
            bar_w = width - 38.0
            draw_round_rect(view, bar_x, bar_y, bar_w, 3.0, 1.5, rgba(255, 255, 255, 36))
            fill = bar_w * progress.to_f / 100.0
            draw_round_rect(view, bar_x, bar_y, fill, 3.0, 1.5, rgba(tint[0] + [255 - tint[0], 55].min, tint[1] + [255 - tint[1], 55].min, tint[2] + [255 - tint[2], 55].min, 220)) if fill.positive?
          end
          if jobs.length > rows.length
            draw_text_safe(view, x + 15.0, y + height - 13.0, "另有 #{jobs.length - rows.length} 条较早记录", rgba(154, 167, 187, 190), size: 7, bold: false)
          end
        rescue StandardError => e
          GavinTools::SULinkHubMultiSpace::Runtime.log_exception('绘制发布队列面板失败', e)
        end

        def toolbar_dimensions(view = nil)
          _x, _y, width, height = toolbar_layout(view)[:rect]
          [width, height]
        end

        def toolbar_origin_x(view = nil)
          toolbar_layout(view)[:rect][0]
        end

        def button_rect(button, view = nil)
          entry = toolbar_layout(view)[:buttons].find do |candidate|
            other = candidate[:button]
            other[:action].to_s == button[:action].to_s &&
              other[:group] == button[:group] && other[:slot].to_i == button[:slot].to_i
          end
          entry ? entry[:rect] : [0.0, 0.0, 0.0, 0.0]
        end

        def toolbar_rect(view = nil)
          toolbar_layout(view)[:rect]
        end

        def drawer_height(view = nil)
          available = [view_height(view) - DRAWER_VIEW_GAP * 2.0, 260.0].max
          preferred = [[available, DRAWER_MIN_HEIGHT].max, DRAWER_MAX_HEIGHT].min
          [preferred, available].min
        end

        def drawer_y(view = nil)
          [(view_height(view) - drawer_height(view)) / 2.0, 6.0].max
        end

        def drawer_rect(view = nil)
          if @drawer_open
            progress = [[@drawer_progress.to_f, 0.0].max, 1.0].min
            slide_x = -(DRAWER_WIDTH - DRAWER_HANDLE_WIDTH) * (1.0 - progress)
            [slide_x, drawer_y(view), DRAWER_WIDTH, drawer_height(view)]
          else
            y = drawer_y(view) + (drawer_height(view) - DRAWER_HANDLE_HEIGHT) / 2.0
            [0.0, y, DRAWER_HANDLE_WIDTH, DRAWER_HANDLE_HEIGHT]
          end
        end

        def drawer_layout(view = nil)
          x, y, width, height = @drawer_open ? drawer_rect(view) : [0.0, drawer_y(view), DRAWER_WIDTH, drawer_height(view)]
          # v0.13.6.21：四专业固定横排在抽屉顶部；下方全部竖向空间只服务当前工作区。
          # 不再长期占用“建筑折叠卡 + 当前空间卡 + 底部景观卡”三段高度。
          content_top = y + 122.0
          content_bottom = y + height - 28.0
          tools_h = 32.0
          row_pitch = DRAWER_ROW_PITCH
          host = @state['host_discipline'].to_s
          architecture_expanded = host == 'architecture'
          space_expanded = SPACE_COLLECTION_KEYS.include?(host) && host == drawer_space_collection_key
          landscape_current = host == 'landscape'
          hidden_y = y + height + 1000.0

          architecture_rows_count = architecture_expanded ? architecture_drawer_rows.length : 0
          space_rows_count = space_expanded ? drawer_rows.length : 0
          manage_h = if architecture_expanded && @architecture_manage_mode
                       40.0
                     elsif space_expanded && @space_manage_mode
                       40.0
                     else
                       0.0
                     end
          current_tools_h = (architecture_expanded || space_expanded) ? (tools_h + 4.0) : 0.0
          available_rows_height = [content_bottom - content_top - current_tools_h - manage_h, 0.0].max
          total_slots = (available_rows_height / row_pitch).floor
          architecture_capacity = architecture_expanded ? [total_slots, architecture_rows_count].min : 0
          space_capacity = space_expanded ? [total_slots, space_rows_count].min : 0

          architecture_y = architecture_expanded ? content_top : hidden_y
          architecture_controls_y = architecture_expanded ? architecture_y + 2.0 : nil
          architecture_list_y = architecture_expanded ? architecture_y + tools_h + 4.0 : nil
          architecture_list_bottom = architecture_expanded ? architecture_list_y + architecture_capacity * row_pitch : nil

          space_y = space_expanded ? content_top : hidden_y
          space_controls_y = space_expanded ? space_y + 2.0 : nil
          list_y = space_expanded ? space_y + tools_h + 4.0 : nil
          list_bottom = space_expanded ? list_y + space_capacity * row_pitch : nil

          {
            x: x, y: y, width: width, height: height,
            # v0.13.6.29：项目级操作放上层，专业工作区标签放其下。
            # 已连接项目时不再把“新建项目”常驻在工作面板里，避免误触创建新项目。
            project_y: y + 84.0,
            global_y: y + 48.0,
            content_top: content_top,
            content_bottom: content_bottom,
            architecture_y: architecture_y,
            architecture_expanded: architecture_expanded,
            architecture_controls_y: architecture_controls_y,
            architecture_list_y: architecture_list_y,
            architecture_list_bottom: architecture_list_bottom,
            architecture_capacity: architecture_capacity,
            space_y: space_y,
            space_expanded: space_expanded,
            space_controls_y: space_controls_y,
            list_y: list_y,
            list_bottom: list_bottom,
            space_capacity: space_capacity,
            landscape_y: landscape_current ? content_top : hidden_y,
            landscape_current: landscape_current
          }
        end

        def architecture_rows_bottom(view = nil)
          layout = drawer_layout(view)
          layout[:architecture_list_bottom].to_f
        end

        def visible_architecture_capacity(view = nil)
          drawer_layout(view)[:architecture_capacity].to_i
        end

        def architecture_manage_action_y(view = nil, visible_count = nil)
          layout = drawer_layout(view)
          count = visible_count.nil? ? visible_drawer_architecture_models(view).length : visible_count.to_i
          natural_y = layout[:architecture_list_y].to_f + [count, 0].max * DRAWER_ROW_PITCH
          [natural_y, layout[:architecture_list_bottom].to_f].min
        end

        def space_rows_bottom(view = nil)
          drawer_layout(view)[:list_bottom].to_f
        end

        def visible_space_capacity(view = nil)
          drawer_layout(view)[:space_capacity].to_i
        end

        def space_manage_action_y(view = nil, visible_count = nil)
          layout = drawer_layout(view)
          count = visible_count.nil? ? visible_drawer_spaces(view).length : visible_count.to_i
          natural_y = layout[:list_y].to_f + [count, 0].max * DRAWER_ROW_PITCH
          [natural_y, layout[:list_bottom].to_f].min
        end

        def drawer_spaces
          Array(@state['drawer_spaces'])
        end


        def drawer_space_collection_key
          key = @state['drawer_space_collection_key'].to_s
          SPACE_COLLECTION_KEYS.include?(key) ? key : SPACE_COLLECTION_KEY
        rescue StandardError
          SPACE_COLLECTION_KEY
        end

        def drawer_space_collection_label
          label = @state['drawer_space_collection_label'].to_s
          label.empty? ? (drawer_space_collection_key == SOFT_SPACE_COLLECTION_KEY ? '软装' : '硬装') : label
        rescue StandardError
          '硬装'
        end

        def drawer_architecture_models
          Array(@state['drawer_architecture_models'])
        end

        def drawer_architecture_groups
          Array(@state['drawer_architecture_groups'])
        end

        def drawer_stage
          return 'workspace' if @drawer_workspace_picker && @state['drawer_project_connected'] == true
          stage = @state['drawer_stage'].to_s
          %w[connect workspace ready].include?(stage) ? stage : 'connect'
        end

        def drawer_groups
          Array(@state['drawer_groups'])
        end

        # Runtime -> Overlay bridge API. Switch visibility before defining the
        # methods instead of using `public :method_name` before they exist; the
        # latter raises NameError during runtime load and forces bootstrap rollback.
        public

        def toggle_publish_queue_panel!
          @publish_queue_open = !@publish_queue_open
          invalidate_view
          @publish_queue_open
        rescue StandardError
          false
        end

        def close_publish_queue_panel!
          @publish_queue_open = false
          invalidate_view
          true
        rescue StandardError
          false
        end

        # 分组、改名、排序等轻量操作先直接更新 Overlay 的本地树，避免为了一个
        # 卡片动作重新扫描锁文件、共享 SKP 和全部空间状态。共享清单随后在空闲帧写入。
        def update_space_group_layout!(groups, spaces = nil)
          existing_groups = drawer_groups.each_with_object({}) { |group, memo| memo[group['id'].to_s] = group if group.is_a?(Hash) }
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          overrides = (@space_group_collapse_overrides ||= {})
          overrides.delete_if { |_id, payload| !payload.is_a?(Hash) || payload['expires_at'].to_f <= now }
          @state['drawer_groups'] = Array(groups).map do |group|
            next unless group.is_a?(Hash)
            group_id = group['id'].to_s
            previous = existing_groups[group_id]
            patched = previous ? previous.merge(group) : group.dup
            override = overrides[group_id]
            patched['collapsed'] = !!override['collapsed'] if override.is_a?(Hash)
            patched
          end.compact

          unless spaces.nil?
            layout_by_id = Array(spaces).each_with_object({}) { |item, memo| memo[item['id'].to_s] = item if item.is_a?(Hash) }
            group_names = @state['drawer_groups'].each_with_object({}) { |group, memo| memo[group['id'].to_s] = group['name'].to_s }
            @state['drawer_spaces'] = drawer_spaces.map do |row|
              item = layout_by_id[row['id'].to_s]
              next row unless item
              patched = row.dup
              patched['number'] = item['number'].to_i if item.key?('number')
              raw_name = item['name'].to_s.empty? ? patched['raw_name'].to_s : item['name'].to_s
              patched['raw_name'] = raw_name
              patched['group_id'] = item['group_id'].to_s
              patched['group_order'] = item['group_order'].to_i
              group_name = group_names[patched['group_id'].to_s]
              patched['name'] = group_name.to_s.empty? ? "#{patched['number']}:#{raw_name}" : "#{group_name}:#{raw_name}"
              patched
            end
          end
          recompute_drawer_group_visibility!
          clamp_space_scroll
          invalidate_view
          true
        rescue StandardError
          false
        end

        def recompute_drawer_group_visibility!
          @state['drawer_groups'] = drawer_groups.map do |group|
            members = drawer_spaces.select { |space| space['group_id'].to_s == group['id'].to_s }
            loaded = members.select { |space| space['loaded'] == true }
            visible_count = loaded.count { |space| space['visible'] == true }
            suspended = !!group['visibility_suspended']
            patched = group.dup
            patched['count'] = members.length
            patched['loaded_count'] = loaded.length
            patched['visible_count'] = visible_count
            patched['visible'] = !suspended && visible_count.positive?
            patched['visibility_enabled'] = !loaded.empty? && loaded.all? { |space| space['visibility_enabled'] != false } && (suspended || visible_count.positive?)
            patched['visibility_tooltip'] = if loaded.empty?
                                              '组内空间尚未载入，无法切换显示'
                                            elsif suspended
                                              "显示组内上次被组按钮隐藏的 #{restore_ids.length} 个空间；原本单独隐藏的空间保持隐藏"
                                            elsif visible_count.positive?
                                              "隐藏组内当前显示的 #{visible_count} 个空间；再次显示时只恢复这些空间"
                                            else
                                              '组内当前没有显示中的空间；原本单独隐藏的状态不会被组按钮改动'
                                            end
            patched
          end
          true
        rescue StandardError
          false
        end

        def update_space_visibility_local!(visibility_by_id)
          map = visibility_by_id.is_a?(Hash) ? visibility_by_id : {}
          @state['drawer_spaces'] = drawer_spaces.map do |row|
            key = row['id'].to_s
            next row unless map.key?(key)
            row.merge('visible' => !!map[key])
          end
          recompute_drawer_group_visibility!
          invalidate_view
          true
        rescue StandardError
          false
        end

        def set_space_collection_hidden_local!(hidden)
          @state['drawer_space_hidden'] = !!hidden
          if hidden
            @state['drawer_spaces'] = drawer_spaces.map { |row| row.merge('visible' => false) }
            recompute_drawer_group_visibility!
          end
          invalidate_view
          true
        rescue StandardError
          false
        end

        # 代/真切换仅补丁本地 Overlay 状态；保留 0.13.3.2 的稳定卡片绘制逻辑。
        def set_representation_mode_local!(mode, preview_space_id: nil)
          @state['display_mode'] = mode.to_s == 'full' ? 'full' : 'proxy'
          unless preview_space_id.nil?
            @state['representation_preview_space_id'] = preview_space_id.to_s
          end
          invalidate_view
          true
        rescue StandardError
          false
        end

        # v0.13.6.29：工作区标签点击先纯本地切换视觉状态，不等待 NAS、锁文件、
        # 全项目状态重算。详细树使用每个专业最近一次快照；权威刷新只在用户空闲后执行。
        def set_workspace_local!(role, local_snapshot: nil)
          role = role.to_s
          old_role = @state['host_discipline'].to_s
          @drawer_role_snapshots ||= {}
          if SPACE_COLLECTION_KEYS.include?(old_role) && !Array(@state['drawer_spaces']).empty?
            @drawer_role_snapshots[old_role] = {
              'drawer_spaces' => Array(@state['drawer_spaces']).map { |row| row.is_a?(Hash) ? row.dup : row },
              'drawer_groups' => Array(@state['drawer_groups']).map { |row| row.is_a?(Hash) ? row.dup : row },
              'drawer_space_loaded_count' => @state['drawer_space_loaded_count'].to_i,
              'drawer_space_hidden' => @state['drawer_space_hidden'] == true
            }
          end
          if old_role == 'architecture' && !Array(@state['drawer_architecture_models']).empty?
            @drawer_role_snapshots['architecture'] = {
              'drawer_architecture_models' => Array(@state['drawer_architecture_models']).map { |row| row.is_a?(Hash) ? row.dup : row },
              'drawer_architecture_groups' => Array(@state['drawer_architecture_groups']).map { |row| row.is_a?(Hash) ? row.dup : row },
              'drawer_architecture_loaded_count' => @state['drawer_architecture_loaded_count'].to_i,
              'drawer_architecture_hidden' => @state['drawer_architecture_hidden'] == true
            }
          end

          @state['host_discipline'] = role
          @state['drawer_context'] = "当前工作区 · #{role == 'architecture' ? '建筑' : (role == SPACE_COLLECTION_KEY ? '硬装' : (role == SOFT_SPACE_COLLECTION_KEY ? '软装' : '景观'))}"
          if SPACE_COLLECTION_KEYS.include?(role)
            @state['drawer_space_collection_key'] = role
            @state['drawer_space_collection_label'] = role == SOFT_SPACE_COLLECTION_KEY ? '软装' : '硬装'
            # 首次进入某专业时，Runtime 会传入仅基于当前 SU 内存构造的轻量快照。
            # 它不会访问 NAS、锁文件或重载 definition，因此切换后立即有卡片可看；
            # 稍后的权威刷新只校准数据，不再经历“先清空、再突然出现”的闪烁。
            if !@drawer_role_snapshots.key?(role) && local_snapshot.is_a?(Hash) && !Array(local_snapshot['drawer_spaces']).empty?
              @drawer_role_snapshots[role] = local_snapshot
            end
            snap = @drawer_role_snapshots[role] || (local_snapshot.is_a?(Hash) ? local_snapshot : {})
            @state['drawer_spaces'] = Array(snap['drawer_spaces'])
            @state['drawer_groups'] = Array(snap['drawer_groups'])
            @state['drawer_space_loaded_count'] = snap['drawer_space_loaded_count'].to_i
            @state['drawer_space_hidden'] = snap['drawer_space_hidden'] == true
          elsif role == 'architecture'
            snap = @drawer_role_snapshots['architecture'] || {}
            @state['drawer_architecture_models'] = Array(snap['drawer_architecture_models']) unless snap.empty?
            @state['drawer_architecture_groups'] = Array(snap['drawer_architecture_groups']) unless snap.empty?
            @state['drawer_architecture_loaded_count'] = snap['drawer_architecture_loaded_count'].to_i unless snap.empty?
            @state['drawer_architecture_hidden'] = snap['drawer_architecture_hidden'] == true unless snap.empty?
          end
          @space_scroll_index = 0
          @architecture_scroll_index = 0
          @space_manage_mode = false
          @space_manage_selected = {}
          @architecture_manage_mode = false
          @architecture_manage_selected = {}
          invalidate_view
          true
        rescue StandardError
          false
        end

        # v0.13.6.29：判断目标专业是否已有一份完整抽屉快照。
        # 有快照时切换专业不再触发任何详细协同扫描；只复用本地数据。
        def workspace_snapshot_available?(role)
          role = role.to_s
          @drawer_role_snapshots ||= {}
          return true if @drawer_role_snapshots.key?(role)
          if role == 'architecture'
            return !Array(@state['drawer_architecture_models']).empty?
          end
          false
        rescue StandardError
          false
        end

        def set_space_group_collapsed_local!(group_id, collapsed)
          group = drawer_groups.find { |candidate| candidate['id'].to_s == group_id.to_s }
          return false unless group
          group['collapsed'] = !!collapsed
          (@space_group_collapse_overrides ||= {})[group_id.to_s] = {
            'collapsed' => !!collapsed,
            'expires_at' => Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1.5
          }
          clamp_space_scroll
          invalidate_view
          true
        rescue StandardError
          false
        end

        # 展开/折叠是纯视觉动作，必须先在 Overlay 内立即完成，不能等待
        # load_state/save_state 或任何 HtmlDialog 刷新。返回切换后的状态，持久化由
        # Runtime 在空闲帧合并写入。
        def toggle_space_group_collapsed_local!(group_id)
          group = drawer_groups.find { |candidate| candidate['id'].to_s == group_id.to_s }
          return nil unless group
          group['collapsed'] = !group['collapsed']
          (@space_group_collapse_overrides ||= {})[group_id.to_s] = {
            'collapsed' => !!group['collapsed'],
            'expires_at' => Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1.5
          }
          clamp_space_scroll
          invalidate_view
          !!group['collapsed']
        rescue StandardError
          nil
        end

        # 空间通过“更新/载入”成功进入当前 SU 后，卡片默认显示为睁眼。
        # 这里只做即时视觉补丁，详细状态仍由下一次权威刷新补齐。
        def mark_space_loaded_visible_local!(space_id)
          key = space_id.to_s
          found = false
          @state['drawer_spaces'] = drawer_spaces.map do |row|
            next row unless row['id'].to_s == key
            found = true
            row.merge('loaded' => true, 'visible' => true, 'visibility_enabled' => true)
          end
          recompute_drawer_group_visibility! if found
          invalidate_view if found
          found
        rescue StandardError
          false
        end

        def set_space_group_visibility_local!(group_id, suspended, restore_ids = nil)
          group = drawer_groups.find { |candidate| candidate['id'].to_s == group_id.to_s }
          return false unless group
          group['visibility_suspended'] = !!suspended
          group['visibility_restore_ids'] = Array(restore_ids).map(&:to_s) unless restore_ids.nil?
          recompute_drawer_group_visibility!
          invalidate_view
          true
        rescue StandardError
          false
        end

        # The remaining layout, hit-test and drawing methods are implementation
        # details and stay private.
        private

        def architecture_drawer_rows
          models = drawer_architecture_models.map { |item| item.merge('kind' => 'architecture_model') }
          groups = drawer_architecture_groups.sort_by { |group| [group['order'].to_i, group['name'].to_s] }
          return models.sort_by { |item| [item['group_order'].to_i, item['number'].to_i] } if groups.empty?

          grouped = models.group_by { |item| item['group_id'].to_s }
          rows = []
          groups.each do |group|
            members = Array(grouped[group['id'].to_s]).sort_by { |item| [item['group_order'].to_i, item['number'].to_i] }
            status_mix = { 'editing' => 0, 'pending' => 0, 'current' => 0, 'other' => 0, 'total' => members.length }
            members.each do |item|
              bucket = case item['status_code'].to_s
                       when 'editing', 'error', 'locked' then 'editing'
                       when 'pending', 'waiting', 'syncing', 'disconnected' then 'pending'
                       when 'current' then 'current'
                       else 'other'
                       end
              status_mix[bucket] += 1
            end
            member_statuses = members.map do |item|
              case item['status_code'].to_s
              when 'editing', 'error', 'locked' then 'editing'
              when 'pending', 'waiting', 'syncing', 'disconnected' then 'pending'
              when 'current' then 'current'
              else 'other'
              end
            end
            rows << {
              'kind' => 'architecture_group', 'id' => group['id'].to_s, 'name' => group['name'].to_s,
              'collapsed' => !!group['collapsed'], 'count' => members.length, 'pseudo' => false,
              'visibility_suspended' => !!group['visibility_suspended'],
              'visibility_restore_ids' => Array(group['visibility_restore_ids']).map(&:to_s),
              'visibility_enabled' => group['visibility_enabled'] == true,
              'visibility_tooltip' => group['visibility_tooltip'].to_s,
              'visible' => group['visible'] == true,
              'status_mix' => status_mix, 'member_statuses' => member_statuses,
              'order' => group['order'].to_i
            }
            rows.concat(members) unless group['collapsed']
          end
          ungrouped = Array(grouped['']).sort_by { |item| [item['group_order'].to_i, item['number'].to_i] }
          if @architecture_manage_mode
            rows << { 'kind' => 'architecture_group', 'id' => '', 'name' => '未分组', 'collapsed' => false, 'count' => ungrouped.length, 'pseudo' => true }
          end
          rows.concat(ungrouped)
          rows
        end

        def max_architecture_scroll(view = nil)
          [architecture_drawer_rows.length - visible_architecture_capacity(view), 0].max
        end

        def clamp_architecture_scroll(view = nil)
          @architecture_scroll_index = [[@architecture_scroll_index.to_i, 0].max, max_architecture_scroll(view)].min
        rescue StandardError
          @architecture_scroll_index = 0
        end

        def visible_drawer_architecture_models(view = nil)
          return [] unless drawer_layout(view)[:architecture_expanded]
          return [] if visible_architecture_capacity(view) <= 0
          clamp_architecture_scroll(view)
          architecture_drawer_rows.slice(@architecture_scroll_index, visible_architecture_capacity(view)) || []
        end

        def architecture_row_at(x, y, view = nil)
          return nil unless @drawer_open
          layout = drawer_layout(view)
          return nil unless layout[:architecture_expanded] && layout[:architecture_list_y]
          return nil unless x.to_f >= layout[:x] + 8.0 && x.to_f <= layout[:x] + layout[:width] - 8.0
          index = ((y.to_f - layout[:architecture_list_y].to_f) / DRAWER_ROW_PITCH).floor
          rows = visible_drawer_architecture_models(view)
          return nil if index.negative? || index >= rows.length
          row_y = layout[:architecture_list_y].to_f + index * DRAWER_ROW_PITCH
          row = rows[index]
          card_y, card_height = architecture_row_vertical_metrics(row, row_y)
          return nil unless y.to_f >= card_y && y.to_f <= card_y + card_height
          row
        rescue StandardError
          nil
        end

        def grouped_architecture_row?(row)
          row.is_a?(Hash) && row['kind'].to_s == 'architecture_model' && !row['group_id'].to_s.empty?
        rescue StandardError
          false
        end

        def architecture_row_vertical_metrics(row, row_y)
          if row.is_a?(Hash) && row['kind'].to_s == 'architecture_group'
            [row_y.to_f, DRAWER_GROUP_CARD_HEIGHT]
          elsif grouped_architecture_row?(row)
            [row_y.to_f + 2.0, DRAWER_GROUP_MEMBER_CARD_HEIGHT]
          else
            [row_y.to_f + 1.0, DRAWER_SPACE_CARD_HEIGHT]
          end
        end

        def drawer_architecture_card_metrics(row, x, row_y, width)
          grouped = grouped_architecture_row?(row)
          indent = grouped ? DRAWER_GROUP_MEMBER_INDENT : 0.0
          card_y, card_height = architecture_row_vertical_metrics(row, row_y)
          {
            grouped: grouped,
            x: x.to_f + 10.0 + indent,
            y: card_y,
            width: width.to_f - 20.0 - indent,
            height: card_height,
            text_x: x.to_f + 34.0 + indent,
            dot_x: x.to_f + 20.0 + indent
          }
        end

        def drawer_rows
          spaces = drawer_spaces.map { |space| space.merge('kind' => 'space') }
          groups = drawer_groups.sort_by { |group| [group['order'].to_i, group['name'].to_s] }
          return spaces.sort_by { |space| [space['group_order'].to_i, space['number'].to_i] } if groups.empty?

          grouped = spaces.group_by { |space| space['group_id'].to_s }
          rows = []
          groups.each do |group|
            members = Array(grouped[group['id'].to_s]).sort_by { |space| [space['group_order'].to_i, space['number'].to_i] }
            status_mix = { 'editing' => 0, 'pending' => 0, 'current' => 0, 'other' => 0, 'total' => members.length }
            members.each do |space|
              bucket = case space['status_code'].to_s
                       when 'editing', 'error', 'locked' then 'editing'
                       when 'pending', 'waiting', 'syncing', 'disconnected' then 'pending'
                       when 'current' then 'current'
                       else 'other'
                       end
              status_mix[bucket] += 1
            end
            member_statuses = members.map do |space|
              case space['status_code'].to_s
              when 'editing', 'error', 'locked' then 'editing'
              when 'pending', 'waiting', 'syncing', 'disconnected' then 'pending'
              when 'current' then 'current'
              else 'other'
              end
            end
            rows << {
              'kind' => 'group', 'id' => group['id'].to_s, 'name' => group['name'].to_s,
              'collapsed' => !!group['collapsed'], 'count' => members.length, 'pseudo' => false,
              'visibility_suspended' => !!group['visibility_suspended'],
              'visibility_restore_ids' => Array(group['visibility_restore_ids']).map(&:to_s),
              'visibility_enabled' => group['visibility_enabled'] == true,
              'visibility_tooltip' => group['visibility_tooltip'].to_s,
              'visible' => group['visible'] == true,
              'status_mix' => status_mix,
              # 八个以内直接以一空间一圆点显示，顺序与组内卡片一致；超过八个再用文字数量。
              'member_statuses' => member_statuses,
              'order' => group['order'].to_i
            }
            rows.concat(members) unless group['collapsed']
          end
          ungrouped = Array(grouped['']).sort_by { |space| [space['group_order'].to_i, space['number'].to_i] }
          if @space_manage_mode
            rows << { 'kind' => 'group', 'id' => '', 'name' => '未分组', 'collapsed' => false, 'count' => ungrouped.length, 'pseudo' => true }
          end
          rows.concat(ungrouped)
          rows
        end

        def max_space_scroll(view = nil)
          [drawer_rows.length - visible_space_capacity(view), 0].max
        end

        def clamp_space_scroll(view = nil)
          @space_scroll_index = [[@space_scroll_index.to_i, 0].max, max_space_scroll(view)].min
        rescue StandardError
          @space_scroll_index = 0
        end

        def visible_drawer_spaces(view = nil)
          clamp_space_scroll(view)
          drawer_rows.slice(@space_scroll_index, visible_space_capacity(view)) || []
        end

        def drawer_row_at(x, y, view = nil)
          return nil unless @drawer_open
          layout = drawer_layout(view)
          return nil unless x.to_f >= layout[:x] + 8.0 && x.to_f <= layout[:x] + layout[:width] - 8.0
          index = ((y.to_f - layout[:list_y]) / DRAWER_ROW_PITCH).floor
          rows = visible_drawer_spaces(view)
          return nil if index.negative? || index >= rows.length
          row_y = layout[:list_y] + index * DRAWER_ROW_PITCH
          row = rows[index]
          card_y, card_height = drawer_row_vertical_metrics(row, row_y)
          return nil unless y.to_f >= card_y && y.to_f <= card_y + card_height
          row
        rescue StandardError
          nil
        end

        def grouped_space_row?(row)
          row.is_a?(Hash) && row['kind'].to_s == 'space' && !row['group_id'].to_s.empty?
        rescue StandardError
          false
        end

        def drawer_row_vertical_metrics(row, row_y)
          if row.is_a?(Hash) && row['kind'].to_s == 'group'
            [row_y.to_f, DRAWER_GROUP_CARD_HEIGHT]
          elsif grouped_space_row?(row)
            [row_y.to_f + 2.0, DRAWER_GROUP_MEMBER_CARD_HEIGHT]
          else
            [row_y.to_f + 1.0, DRAWER_SPACE_CARD_HEIGHT]
          end
        end

        def drawer_row_center_y(row, row_y)
          card_y, card_height = drawer_row_vertical_metrics(row, row_y)
          card_y + card_height / 2.0
        end

        def drawer_space_card_metrics(row, x, row_y, width)
          grouped = grouped_space_row?(row)
          indent = grouped ? DRAWER_GROUP_MEMBER_INDENT : 0.0
          card_y, card_height = drawer_row_vertical_metrics(row, row_y)
          {
            grouped: grouped,
            x: x.to_f + 10.0 + indent,
            y: card_y,
            width: width.to_f - 20.0 - indent,
            height: card_height,
            text_x: x.to_f + 34.0 + indent,
            dot_x: x.to_f + 20.0 + indent
          }
        end

        def point_in_rect?(x, y, rect)
          rx, ry, rw, rh = rect
          px = x.to_f
          py = y.to_f
          px >= rx && px <= rx + rw && py >= ry && py <= ry + rh
        end

        def drawer_tools_button_definitions(x, y, width, _height)
          half = (width - 38.0) / 2.0
          backup_ready = @state['drawer_backup_dir_exists'] == true
          project_ready = !@state['drawer_project_dir'].to_s.empty?
          model_saved = !@state['drawer_model_path'].to_s.empty?
          [
            {
              action: 'drawer_tool_save_model', rect: [x + 14.0, y + 95.0, half, 34.0],
              tooltip: model_saved ? '执行一次 SketchUp 原生保存' : '为当前未命名模型选择路径并保存', enabled: true
            },
            {
              action: 'drawer_tool_save_backup_now', rect: [x + 24.0 + half, y + 95.0, half, 34.0],
              tooltip: backup_ready ? '立即保存整份工作模型副本' : '先选择副本文件夹，再保存整份工作模型副本', enabled: true
            },
            {
              action: 'drawer_tool_open_backup_folder', rect: [x + 14.0, y + 137.0, half, 34.0],
              tooltip: backup_ready ? "打开副本文件夹：#{@state['drawer_backup_dir']}" : '尚未设置副本文件夹；点击后选择', enabled: true
            },
            {
              action: 'drawer_tool_choose_backup_folder', rect: [x + 24.0 + half, y + 137.0, half, 34.0],
              tooltip: '更改工作模型副本文件夹', enabled: true
            },
            {
              action: 'drawer_tool_backup_interval', rect: [x + 14.0, y + 179.0, width - 28.0, 34.0],
              tooltip: "设置建筑更新前的副本提醒间隔；当前 #{@state['drawer_backup_interval_minutes'].to_i} 分钟", enabled: true
            },
            {
              action: 'drawer_tool_open_project_folder', rect: [x + 14.0, y + 239.0, half, 34.0],
              tooltip: project_ready ? "打开协同项目文件夹：#{@state['drawer_project_dir']}" : '当前尚未连接有效协同项目', enabled: project_ready
            },
            {
              action: 'drawer_tool_open_data_folder', rect: [x + 24.0 + half, y + 239.0, half, 34.0],
              tooltip: model_saved ? '打开当前工作模型的 LinkHub 数据目录' : '请先保存当前 SketchUp 模型', enabled: model_saved
            },
            {
              action: 'drawer_tool_open_log_folder', rect: [x + 14.0, y + 281.0, width - 28.0, 34.0],
              tooltip: '打开 LinkHub 日志所在文件夹', enabled: true
            },
            {
              action: 'drawer_refresh_status', rect: [x + 14.0, y + 323.0, width - 28.0, 34.0],
              tooltip: '全面检查协同状态、发布锁、残留临时文件与上次崩溃阶段', enabled: true
            },
            {
              action: 'drawer_tools_done', rect: [x + 56.0, y + 365.0, width - 112.0, 34.0],
              tooltip: '返回快速协同面板', enabled: true
            }
          ]
        end

        def professional_section_button_definitions(view, x, width, layout)
          controls = []
          architecture_workspace = @state['host_discipline'].to_s == 'architecture'
          space_workspace = SPACE_COLLECTION_KEYS.include?(@state['host_discipline'].to_s) && @state['host_discipline'].to_s == drawer_space_collection_key
          space_label = drawer_space_collection_label

          architecture_y = layout[:architecture_y]
          if layout[:architecture_expanded]
            tool_size = DRAWER_SPACE_TOOL_BUTTON_SIZE
            tool_gap = DRAWER_SPACE_TOOL_BUTTON_GAP
            tools = [
              ['drawer_manage_architecture', architecture_workspace ? (@architecture_manage_mode ? '结束建筑模型管理' : '管理建筑模型、分组、改名与删除') : '请切换到建筑工作区后管理建筑模型'],
              ['drawer_architecture_library', '打开建筑模型库与材质库'],
              ['drawer_add_architecture', "用当前选中的 #{@state['drawer_selection_count'].to_i} 个对象新增建筑模型"],
              ['drawer_toggle_architecture_visibility', @state['drawer_architecture_hidden'] == true ? '显示全部建筑模型' : '隐藏全部建筑模型']
            ]
            tools_total_width = tool_size * tools.length + tool_gap * (tools.length - 1)
            cursor_x = x + width - 10.0 - tools_total_width

            # v0.13.6.29：当前专业标题改为纯文字“建筑模型：”，不再占用一个伪按钮/折叠入口。
            tools.each_with_index do |(action, tooltip), index|
              enabled = case action
                        when 'drawer_manage_architecture'
                          architecture_workspace && @state['drawer_project_connected'] == true
                        when 'drawer_add_architecture'
                          architecture_workspace && @state['drawer_project_connected'] == true && !@architecture_manage_mode
                        when 'drawer_toggle_architecture_visibility'
                          !@architecture_manage_mode && @state['drawer_architecture_loaded_count'].to_i.positive?
                        else
                          architecture_workspace
                        end
              controls << { action: action, rect: [cursor_x, layout[:architecture_controls_y], tool_size, tool_size], tooltip: tooltip, enabled: enabled }
              cursor_x += tool_size + tool_gap
            end

            visible_architecture = visible_drawer_architecture_models(view)
            visible_architecture.each_with_index do |row, index|
              row_y = layout[:architecture_list_y].to_f + index * DRAWER_ROW_PITCH
              if row['kind'].to_s == 'architecture_group'
                unless row['pseudo']
                  controls << {
                    action: "drawer_architecture_group_visibility:#{row['id']}",
                    rect: [x + width - 72.0, row_y + (DRAWER_GROUP_CARD_HEIGHT - 26.0) / 2.0, 26.0, 26.0],
                    tooltip: row['visibility_tooltip'].to_s.empty? ? '切换建筑组显示' : row['visibility_tooltip'].to_s,
                    enabled: row['visibility_enabled'] == true
                  }
                  controls << {
                    action: "drawer_architecture_group_toggle:#{row['id']}",
                    rect: [x + width - 40.0, row_y + (DRAWER_GROUP_CARD_HEIGHT - 26.0) / 2.0, 26.0, 26.0],
                    tooltip: row['collapsed'] ? '展开建筑组' : '收纳建筑组', enabled: true
                  }
                  if @architecture_manage_mode
                    controls << {
                      action: "drawer_architecture_group_rename:#{row['id']}",
                      rect: [x + 40.0, row_y + 1.0, width - 118.0, DRAWER_GROUP_CARD_HEIGHT - 2.0],
                      tooltip: '修改建筑组名称', enabled: true
                    }
                  end
                  controls << {
                    action: "drawer_architecture_group_toggle:#{row['id']}",
                    rect: [x + 10.0, row_y, width - 20.0, DRAWER_GROUP_CARD_HEIGHT],
                    tooltip: row['collapsed'] ? '点击组卡片展开建筑模型' : '点击组卡片收纳建筑模型', enabled: true
                  }
                end
                next
              end

              hovered = @hover_row_key == "architecture_model:#{row['id']}"
              card = drawer_architecture_card_metrics(row, x, row_y, width)
              control_y = card[:y] + [((card[:height] - 26.0) / 2.0), 1.0].max
              if @architecture_manage_mode
                indent = card[:grouped] ? DRAWER_GROUP_MEMBER_INDENT : 0.0
                controls << {
                  action: "drawer_architecture_manage_toggle:#{row['id']}",
                  rect: [x + 16.0 + indent, control_y + 1.0, 22.0, 22.0],
                  tooltip: architecture_manage_selected?(row['id']) ? '取消选择建筑模型' : '选择建筑模型用于批量成组或删除',
                  enabled: row['manage_selectable'] != false
                }
                controls << {
                  action: "drawer_architecture_manage_rename:#{row['id']}",
                  rect: [x + 42.0 + indent, card[:y], 145.0 - indent, [card[:height] - 11.0, 17.0].max],
                  tooltip: row['manage_can_rename'] == false ? '修改中或占用中的建筑模型不能改名' : '修改建筑模型名称',
                  enabled: row['manage_can_rename'] != false
                }
              elsif hovered
                right_edge = card[:x] + card[:width] - 4.0
                action_rect = [right_edge - 28.0, control_y, 28.0, 26.0]
                visibility_rect = [right_edge - 60.0, control_y, 26.0, 26.0]
                resident_rect = [right_edge - 92.0, control_y, 26.0, 26.0]
                release_rect = [right_edge - 124.0, control_y, 26.0, 26.0]
                release_action = row['release_occupancy_action'].to_s
                controls << { action: release_action, rect: release_rect, tooltip: row['release_occupancy_tooltip'].to_s, enabled: true } unless release_action.empty?
                resident_action = row['resident_action'].to_s
                controls << { action: resident_action, rect: resident_rect, tooltip: row['resident_tooltip'].to_s, enabled: row['resident_enabled'] != false } unless resident_action.empty?
                visibility_action = row['visibility_action'].to_s
                visibility_action = "drawer_architecture_model_visibility_disabled:#{row['id']}" if visibility_action.empty?
                controls << {
                  action: visibility_action,
                  rect: visibility_rect,
                  tooltip: row['visibility_tooltip'].to_s,
                  enabled: row['visibility_enabled'] == true
                }
                controls << { action: row['action'].to_s, rect: action_rect, tooltip: row['tooltip'].to_s, enabled: row['enabled'] != false } unless row['action'].to_s.empty?
              end
            end

            if @architecture_manage_mode
              selected_ids = architecture_manage_selected_ids
              selected_models = drawer_architecture_models.select { |item| selected_ids.include?(item['id'].to_s) }
              delete_enabled = !selected_models.empty? && selected_models.all? { |item| item['manage_can_delete'] != false }
              group_enabled = !selected_models.empty? && selected_models.all? { |item| item['manage_can_group'] != false }
              action_y = architecture_manage_action_y(view, visible_architecture.length)
              controls << { action: 'drawer_architecture_manage_delete_selected', rect: [x + 50.0, action_y + 3.0, 62.0, 30.0], tooltip: selected_models.empty? ? '请先勾选建筑模型' : "删除已勾选的 #{selected_models.length} 个建筑模型", enabled: delete_enabled }
              controls << { action: 'drawer_architecture_manage_group_selected', rect: [x + 118.0, action_y + 3.0, 62.0, 30.0], tooltip: selected_models.empty? ? '请先勾选建筑模型' : "将已勾选的 #{selected_models.length} 个建筑模型成组", enabled: group_enabled }
              controls << { action: 'drawer_architecture_manage_done', rect: [x + 186.0, action_y + 3.0, 62.0, 30.0], tooltip: '完成并退出建筑模型管理', enabled: true }
            end
          else
            # 收纳后只保留一张专业状态卡：小眼睛 + 展开按钮。
            controls << {
              action: 'drawer_toggle_architecture_visibility_header',
              rect: [x + 198.0, architecture_y + 6.0, 28.0, 28.0],
              tooltip: @state['drawer_architecture_hidden'] == true ? '显示全部建筑模型' : '隐藏全部建筑模型',
              enabled: @state['drawer_architecture_loaded_count'].to_i.positive?
            }
            controls << {
              action: 'drawer_toggle_section:architecture',
              rect: [x + 232.0, architecture_y + 6.0, 28.0, 28.0],
              tooltip: '展开建筑板块', enabled: true
            }
            controls << {
              action: 'drawer_toggle_section:architecture',
              rect: [x + 10.0, architecture_y, width - 20.0, 40.0],
              tooltip: '点击建筑卡片展开建筑板块', enabled: true
            }
          end

          space_y = layout[:space_y]
          if layout[:space_expanded]
            manage_tooltip = if !space_workspace
                               "请切换到#{space_label}工作区后管理空间"
                             elsif @space_manage_mode
                               "结束#{space_label}空间管理"
                             else
                               "进入#{space_label}空间管理：勾选、成组、拖动整理、重命名与删除"
                             end
            space_controls = [
              ['drawer_manage_spaces', manage_tooltip],
              ['drawer_add_space', "用当前选中的 #{@state['drawer_selection_count'].to_i} 个对象新增空间"],
              ['drawer_toggle_space_visibility', @state['drawer_space_hidden'] ? "显示全部#{space_label}空间" : "隐藏全部#{space_label}空间"]
            ]
            tool_size = DRAWER_SPACE_TOOL_BUTTON_SIZE
            tool_gap = DRAWER_SPACE_TOOL_BUTTON_GAP

            # “清单”已移到顶部悬浮工具条。v0.13.6.29 起当前专业只显示文字“#{space_label}空间：”，
            # 不再绘制旧的专业标题/折叠按钮。
            right_x = x + width - 10.0
            visibility_rect = [right_x - tool_size, layout[:space_controls_y], tool_size, tool_size]
            right_x = visibility_rect[0] - tool_gap
            add_rect = [right_x - tool_size, layout[:space_controls_y], tool_size, tool_size]
            right_x = add_rect[0] - tool_gap
            manage_rect = [right_x - tool_size, layout[:space_controls_y], tool_size, tool_size]
            space_rects = [manage_rect, add_rect, visibility_rect]
            space_controls.each_with_index do |(action, tooltip), index|
              enabled = case action
                        when 'drawer_manage_spaces'
                          space_workspace && @state['drawer_project_connected'] == true
                        when 'drawer_add_space'
                          space_workspace && @state['drawer_project_connected'] == true && !@space_manage_mode
                        when 'drawer_toggle_space_visibility'
                          !@space_manage_mode && @state['drawer_space_loaded_count'].to_i.positive?
                        else
                          @state['drawer_space_loaded_count'].to_i.positive?
                        end
              controls << { action: action, rect: space_rects[index], tooltip: tooltip, enabled: enabled }
            end

            visible_spaces = visible_drawer_spaces(view)
            visible_spaces.each_with_index do |row, index|
              row_y = layout[:list_y].to_f + index * DRAWER_ROW_PITCH
              if row['kind'].to_s == 'group'
                unless row['pseudo']
                  controls << { action: "drawer_space_group_visibility:#{row['id']}", rect: [x + width - 72.0, row_y + (DRAWER_GROUP_CARD_HEIGHT - 26.0) / 2.0, 26.0, 26.0], tooltip: row['visibility_tooltip'].to_s.empty? ? '切换空间组显示' : row['visibility_tooltip'].to_s, enabled: row['visibility_enabled'] == true }
                  controls << { action: "drawer_space_group_toggle:#{row['id']}", rect: [x + width - 40.0, row_y + (DRAWER_GROUP_CARD_HEIGHT - 26.0) / 2.0, 26.0, 26.0], tooltip: row['collapsed'] ? '展开空间组' : '折叠空间组', enabled: true }
                  if @space_manage_mode
                    controls << { action: "drawer_space_group_rename:#{row['id']}", rect: [x + 40.0, row_y + 1.0, width - 118.0, DRAWER_GROUP_CARD_HEIGHT - 2.0], tooltip: '短按修改空间组名称；长按拖动调整组顺序', enabled: true }
                  end
                  controls << { action: "drawer_space_group_toggle:#{row['id']}", rect: [x + 10.0, row_y, width - 20.0, DRAWER_GROUP_CARD_HEIGHT], tooltip: row['collapsed'] ? '点击组卡片展开空间' : '点击组卡片收纳空间', enabled: true }
                end
                next
              end

              row_hovered = @hover_row_key == "space:#{row['id']}"
              card = drawer_space_card_metrics(row, x, row_y, width)
              control_y = card[:y] + [((card[:height] - 26.0) / 2.0), 1.0].max
              if @space_manage_mode
                selectable = row['manage_selectable'] != false
                indent = card[:grouped] ? DRAWER_GROUP_MEMBER_INDENT : 0.0
                controls << { action: "drawer_space_manage_toggle:#{row['id']}", rect: [x + 16.0 + indent, control_y + 1.0, 22.0, 22.0], tooltip: space_manage_selected?(row['id']) ? '取消选择此空间' : '选择此空间用于批量删除或成组', enabled: selectable }
                controls << { action: "drawer_space_manage_rename:#{row['id']}", rect: [x + 42.0 + indent, card[:y], 145.0 - indent, [card[:height] - 11.0, 17.0].max], tooltip: row['manage_can_rename'] == false ? '该空间正在修改或占用中，不能重命名' : '短按修改名称；长按拖动到其他空间组', enabled: row['manage_can_rename'] != false }
                if row_hovered
                  controls << { action: "drawer_space_manage_locate:#{row['id']}", rect: [x + 232.0, control_y, 28.0, 26.0], tooltip: row['loaded'] == true ? '定位并缩放到此空间' : '该空间尚未载入，无法定位', enabled: row['loaded'] == true }
                end
              elsif row_hovered
                release_action = row['release_occupancy_action'].to_s
                controls << { action: release_action, rect: [x + 134.0, control_y, 26.0, 26.0], tooltip: row['release_occupancy_tooltip'].to_s, enabled: true } unless release_action.empty?
                resident_action = row['resident_action'].to_s
                controls << { action: resident_action, rect: [x + 166.0, control_y, 26.0, 26.0], tooltip: row['resident_tooltip'].to_s, enabled: row['resident_enabled'] != false } unless resident_action.empty?
                visibility_action = row['visibility_action'].to_s
                visibility_action = "drawer_space_visibility_disabled:#{row['id']}" if visibility_action.empty?
                controls << { action: visibility_action, rect: [x + 198.0, control_y, 26.0, 26.0], tooltip: row['visibility_tooltip'].to_s, enabled: row['visibility_enabled'] == true }
                controls << { action: row['action'].to_s, rect: [x + 232.0, control_y, 28.0, 26.0], tooltip: row['tooltip'].to_s, enabled: row['enabled'] != false } unless row['action'].to_s.empty?
              end
            end

            if @space_manage_mode
              selected_ids = space_manage_selected_ids
              selected_spaces = drawer_spaces.select { |space| selected_ids.include?(space['id'].to_s) }
              delete_enabled = !selected_spaces.empty? && selected_spaces.all? { |space| space['manage_can_delete'] != false }
              group_enabled = !selected_spaces.empty? && selected_spaces.all? { |space| space['manage_can_group'] != false }
              action_y = space_manage_action_y(view, visible_spaces.length)
              controls << { action: 'drawer_space_manage_delete_selected', rect: [x + 50.0, action_y + 3.0, 62.0, 30.0], tooltip: selected_spaces.empty? ? '请先勾选要删除的空间' : "删除已勾选的 #{selected_spaces.length} 个空间", enabled: delete_enabled }
              controls << { action: 'drawer_space_manage_group_selected', rect: [x + 118.0, action_y + 3.0, 62.0, 30.0], tooltip: selected_spaces.empty? ? '请先勾选要成组的空间' : "将已勾选的 #{selected_spaces.length} 个空间建立为清单组", enabled: group_enabled }
              controls << { action: 'drawer_space_manage_done', rect: [x + 186.0, action_y + 3.0, 62.0, 30.0], tooltip: '完成并退出空间管理', enabled: true }
            end
          else
            controls << {
              action: 'drawer_toggle_space_visibility_header',
              rect: [x + 198.0, space_y + 6.0, 28.0, 28.0],
              tooltip: @state['drawer_space_hidden'] ? "显示全部#{space_label}空间" : "隐藏全部#{space_label}空间",
              enabled: @state['drawer_space_loaded_count'].to_i.positive?
            }
            controls << {
              action: "drawer_toggle_section:#{drawer_space_collection_key}",
              rect: [x + 232.0, space_y + 6.0, 28.0, 28.0],
              tooltip: "展开#{space_label}板块", enabled: true
            }
            controls << {
              action: "drawer_toggle_section:#{drawer_space_collection_key}",
              rect: [x + 10.0, space_y, width - 20.0, 40.0],
              tooltip: "点击#{space_label}卡片展开#{space_label}板块", enabled: true
            }
          end
          controls
        end

        def drawer_button_definitions(view = nil)
          x, y, width, height = drawer_rect(view)
          unless @drawer_open
            return [{
              action: 'drawer_pin_open', rect: [x, y, DRAWER_HANDLE_WIDTH, DRAWER_HANDLE_HEIGHT],
              tooltip: '悬停展开 LinkHub 快速操作台', enabled: true
            }]
          end
          return [] if @drawer_progress.to_f < 0.94

          layout = drawer_layout(view)
          stage = drawer_stage
          controls = [
            {
              action: 'drawer_pin', rect: [x + width - 56.0, y + 11.0, 22.0, 22.0],
              tooltip: @drawer_pinned ? '取消固定；移开鼠标后自动收起' : '固定左侧抽屉', enabled: true
            },
            {
              action: 'drawer_collapse', rect: [x + width - 28.0, y + 11.0, 22.0, 22.0],
              tooltip: '收起左侧抽屉', enabled: true
            }
          ]
          controls << {
            action: 'drawer_copy_version', rect: [x + (width - 150.0) / 2.0, y + height - 24.0, 150.0, 18.0],
            tooltip: "复制 SU LinkHub v#{EXTENSION_VERSION}", enabled: true
          }
          if stage == 'ready'
            controls.unshift({
              action: 'drawer_reload_plugin', rect: [x + width - 84.0, y + 11.0, 22.0, 22.0],
              tooltip: (@state['drawer_plugin_update_available'] == true ? "发现 v#{@state['drawer_plugin_update_version']}：点击安装并热重载" : (@state['drawer_plugin_update_error'].to_s.empty? ? '重新载入 SU LinkHub 插件运行时；配置插件发布目录后可自动检测更新' : "插件更新检查异常：#{@state['drawer_plugin_update_error']}")), enabled: true
            })
          elsif stage == 'connect'
            controls << {
              action: 'drawer_create_project', rect: [x + 18.0, y + 184.0, 114.0, 38.0],
              tooltip: '新建项目并自动创建协同.json', enabled: true
            }
            controls << {
              action: 'drawer_connect_project', rect: [x + 144.0, y + 184.0, 114.0, 38.0],
              tooltip: '连接已有项目根目录中的协同.json', enabled: true
            }
            return controls
          else
            [
              ['architecture', '建筑'],
              [SPACE_COLLECTION_KEY, '硬装'],
              [SOFT_SPACE_COLLECTION_KEY, '软装'],
              ['landscape', '景观']
            ].each_with_index do |(role, label), index|
              controls << {
                action: "drawer_set_workspace:#{role}", rect: [x + 18.0, y + 132.0 + index * 50.0, width - 36.0, 40.0],
                tooltip: "将当前 SketchUp 文件设置为#{label}工作区", enabled: true
              }
            end
            if @drawer_workspace_picker && @state['drawer_workspace_configured'] == true
              controls << {
                action: 'drawer_cancel_workspace', rect: [x + 80.0, y + 338.0, width - 160.0, 30.0],
                tooltip: '取消切换并返回当前工作区', enabled: true
              }
            else
              controls << {
                action: 'drawer_connect_project', rect: [x + 80.0, y + 338.0, width - 160.0, 30.0],
                tooltip: '当前连接不正确时更换协同项目', enabled: true
              }
            end
            return controls
          end
          if @drawer_tools_mode
            controls.concat(drawer_tools_button_definitions(x, y, width, drawer_height(view)))
            return controls
          end

          project_rect = [x + 10.0, layout[:project_y], width - 20.0, 30.0]
          if workspace_switch_expanded?
            workspace_professional_segments(project_rect).each do |segment|
              controls << {
                action: "drawer_set_workspace:#{segment[:role]}",
                rect: segment[:rect],
                tooltip: "切换到#{segment[:label]}工作区", enabled: true
              }
            end
          else
            controls << {
              action: 'drawer_choose_workspace', rect: project_rect,
              tooltip: '靠近后展开建筑 / 硬装 / 软装 / 景观工作区', enabled: true
            }
          end

          global_buttons = if @state['drawer_project_connected'] == true
                             [
                               ['drawer_connect_project', '更换协同项目（新建项目只在未连接/全新项目入口提供）'],
                               ['drawer_tools', @drawer_tools_mode ? '返回快速协同面板' : '工作副本、文件夹与保存工具'],
                               ['drawer_refresh_status', '全面检查：直接显示协同、占用、路径、代理与发布问题'],
                               ['drawer_project_settings', '项目固定路径：模型库、材质库与插件发布目录']
                             ]
                           else
                             [
                               ['drawer_create_project', '新建一个全新的协同项目'],
                               ['drawer_connect_project', '连接已有协同项目'],
                               ['drawer_tools', @drawer_tools_mode ? '返回快速协同面板' : '工作副本、文件夹与保存工具'],
                               ['drawer_refresh_status', '全面检查：直接显示协同、占用、路径、代理与发布问题'],
                               ['drawer_project_settings', '项目固定路径：模型库、材质库与插件发布目录']
                             ]
                           end
          global_width = (width - 36.0) / global_buttons.length.to_f
          global_buttons.each_with_index do |(action, tooltip), index|
            controls << {
              action: action,
              rect: [x + 10.0 + index * (global_width + 4.0), layout[:global_y], global_width, 30.0],
              tooltip: tooltip, enabled: true
            }
          end

          controls.concat(professional_section_button_definitions(view, x, width, layout))

          if layout[:landscape_current]
            landscape = drawer_items.find { |item| item['key'].to_s == 'landscape' } || drawer_items.last || {}
            controls << {
              action: landscape['action'].to_s,
              rect: [x + 232.0, layout[:landscape_y] + 16.0, 30.0, 30.0],
              tooltip: landscape['tooltip'].to_s, enabled: landscape['enabled'] != false
            }
            landscape_eye_action = landscape['visibility_action'].to_s
            landscape_eye_action = 'drawer_landscape_visibility_disabled' if landscape_eye_action.empty?
            controls << {
              action: landscape_eye_action,
              rect: [x + 198.0, layout[:landscape_y] + 17.0, 28.0, 28.0],
              tooltip: landscape['visibility_tooltip'].to_s.empty? ? '当前景观没有可切换的参考实例' : landscape['visibility_tooltip'].to_s,
              enabled: landscape['visibility_enabled'] == true
            }
          end
          controls
        end

        def action_at(x, y, view = nil)
          if @publish_queue_open
            publish_queue_panel_controls(view).each do |control|
              return control[:action] if control[:enabled] != false && point_in_rect?(x, y, control[:rect])
            end
          end
          if quick_toolbar_visible?
            toolbar_layout(view)[:buttons].each do |entry|
              button = entry[:button]
              next if button[:action].to_s.empty? || button[:enabled] == false
              if button[:group] == :library && library_group_expandable? && entry[:group_index].to_i.positive?
                next if library_group_progress < 0.72
                next if entry[:rect][2].to_f < BUTTON_SIZE * 0.70
              elsif button[:group] == :aux && refresh_group_expandable?
                next if refresh_group_progress < 0.72
                next if entry[:rect][2].to_f < BUTTON_SIZE * 0.70
              end
              if point_in_rect?(x, y, entry[:rect])
                if button[:kind] == :mode_switch && button[:directional] == true
                  rx, _ry, rw, _rh = entry[:rect]
                  return x.to_f < rx.to_f + rw.to_f / 2.0 ? 'representation_proxy' : 'representation_full'
                end
                return button[:action]
              end
            end
          end
          drawer_button_definitions(view).each do |button|
            next if button[:action].to_s.empty?
            return button[:action] if button[:enabled] != false && point_in_rect?(x, y, button[:rect])
          end
          nil
        end

        def tooltip_for(action, view = nil)
          action_name = action.to_s
          if %w[representation_proxy representation_full].include?(action_name)
            button = button_definitions.find { |item| item[:action].to_s == 'representation' }
            target = action_name.end_with?('_full') ? '真模型' : '六视图代理'
            return "#{target}：#{button ? button[:tooltip].to_s : '将当前选择统一切换到目标状态'}"
          end
          button = button_definitions.find { |item| item[:action] == action }
          button ||= publish_queue_panel_controls(view).find { |item| item[:action] == action }
          button ||= drawer_button_definitions(view).find { |item| item[:action] == action }
          button ? button[:tooltip].to_s : ''
        end

        def update_drawer_pointer(x, y, view)
          inside = point_in_rect?(x, y, drawer_rect(view))
          @drawer_pointer_inside = inside
          if inside
            cancel_drawer_close_timer
            schedule_drawer_open unless @drawer_open && @drawer_progress.to_f >= 0.999
          else
            # 真实鼠标坐标已经落到抽屉外，优先级高于任何 pop/leave 护栏。
            clear_drawer_release_guard!
            cancel_drawer_open_timer
            schedule_drawer_close unless drawer_interaction_hold_active?
          end
          inside
        end

        def arm_drawer_release_guard!(duration = 0.75)
          @drawer_release_guard = true
          @drawer_release_guard_until = Process.clock_gettime(Process::CLOCK_MONOTONIC) + [duration.to_f, 0.20].max
          @drawer_pointer_inside = true if @drawer_open
          cancel_drawer_close_timer
          true
        rescue StandardError
          false
        end

        def consume_drawer_release_guard?
          return false unless @drawer_release_guard
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          active = @drawer_release_guard_until.to_f >= now
          @drawer_release_guard = false
          @drawer_release_guard_until = 0.0
          active
        rescue StandardError
          @drawer_release_guard = false
          @drawer_release_guard_until = 0.0
          false
        end

        def clear_drawer_release_guard!
          @drawer_release_guard = false
          @drawer_release_guard_until = 0.0
          true
        rescue StandardError
          false
        end

        def drawer_interaction_hold_active?
          @drawer_interaction_hold_until.to_f > Process.clock_gettime(Process::CLOCK_MONOTONIC)
        rescue StandardError
          false
        end

        # 本地抽屉按钮在临时 Tool 卸载后仍保持展开。真实鼠标移动会立即重新
        # 计算 inside/outside；本方法只屏蔽 Tool 切换产生的伪 leave。
        def begin_drawer_interaction!(duration = DRAWER_INTERACTION_HOLD_SECONDS)
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          @drawer_interaction_hold_token = @drawer_interaction_hold_token.to_i + 1
          token = @drawer_interaction_hold_token
          @drawer_interaction_hold_until = now + [duration.to_f, 0.12].max
          @drawer_pointer_inside = true if @drawer_open
          cancel_drawer_close_timer
          GavinTools::SULinkHubMultiSpace::Runtime.runtime_start_timer([duration.to_f, 0.12].max + 0.04, false, label: 'drawer:interaction_hold') do
            next unless @drawer_interaction_hold_token.to_i == token
            @drawer_interaction_hold_until = 0.0
            # 鼠标若已真实移出，update_drawer_pointer 会把 inside 改为 false；
            # 此时才恢复正常延迟收纳。仍在面板内则继续保持展开。
            schedule_drawer_close unless @drawer_pinned || @drawer_pointer_inside
          end
          true
        rescue StandardError
          false
        end

        def cancel_mode_switch_animation
          GavinTools::SULinkHubMultiSpace::Runtime.runtime_stop_timer(@mode_switch_animation_timer) if @mode_switch_animation_timer
        rescue StandardError
          nil
        ensure
          @mode_switch_animation_timer = nil
        end

        def animate_mode_switch(expand)
          expand = true if space_edit_tools_auto_expanded?
          target = expand ? 1.0 : 0.0
          start_value = [[@mode_switch_progress.to_f, 0.0].max, 1.0].min
          return true if (start_value - target).abs < 0.001
          cancel_mode_switch_animation
          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          @mode_switch_animation_timer = GavinTools::SULinkHubMultiSpace::Runtime.runtime_start_timer(MODE_SWITCH_ANIMATION_INTERVAL, true) do
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
            linear = [[elapsed / MODE_SWITCH_ANIMATION_DURATION, 0.0].max, 1.0].min
            eased = linear < 0.5 ? 2.0 * linear * linear : 1.0 - ((-2.0 * linear + 2.0)**2) / 2.0
            @mode_switch_progress = start_value + (target - start_value) * eased
            if linear >= 1.0
              cancel_mode_switch_animation
              @mode_switch_progress = target
            end
            invalidate_view
          end
          true
        rescue StandardError
          cancel_mode_switch_animation
          @mode_switch_progress = target
          invalidate_view
          false
        end

        def cancel_drawer_mode_switch_animation
          GavinTools::SULinkHubMultiSpace::Runtime.runtime_stop_timer(@drawer_mode_switch_animation_timer) if @drawer_mode_switch_animation_timer
        rescue StandardError
          nil
        ensure
          @drawer_mode_switch_animation_timer = nil
        end

        def drawer_mode_switch_progress
          return 1.0 if space_edit_tools_auto_expanded?
          [[@drawer_mode_switch_progress.to_f, 0.0].max, 1.0].min
        rescue StandardError
          0.0
        end

        def drawer_mode_switch_width
          collapsed = DRAWER_SPACE_TOOL_BUTTON_SIZE
          expanded = DRAWER_SPACE_MODE_SWITCH_WIDTH
          collapsed + (expanded - collapsed) * drawer_mode_switch_progress
        rescue StandardError
          DRAWER_SPACE_TOOL_BUTTON_SIZE
        end

        def animate_drawer_mode_switch(expand)
          expand = true if space_edit_tools_auto_expanded?
          target = expand ? 1.0 : 0.0
          start_value = drawer_mode_switch_progress
          return true if (start_value - target).abs < 0.001
          cancel_drawer_mode_switch_animation
          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          @drawer_mode_switch_animation_timer = GavinTools::SULinkHubMultiSpace::Runtime.runtime_start_timer(DRAWER_MODE_SWITCH_ANIMATION_INTERVAL, true) do
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
            linear = [[elapsed / DRAWER_MODE_SWITCH_ANIMATION_DURATION, 0.0].max, 1.0].min
            eased = linear < 0.5 ? 2.0 * linear * linear : 1.0 - ((-2.0 * linear + 2.0)**2) / 2.0
            @drawer_mode_switch_progress = start_value + (target - start_value) * eased
            if linear >= 1.0
              cancel_drawer_mode_switch_animation
              @drawer_mode_switch_progress = target
            end
            invalidate_view
          end
          true
        rescue StandardError
          cancel_drawer_mode_switch_animation
          @drawer_mode_switch_progress = target
          invalidate_view
          false
        end

        def cancel_refresh_group_animation
          GavinTools::SULinkHubMultiSpace::Runtime.runtime_stop_timer(@refresh_group_animation_timer) if @refresh_group_animation_timer
        rescue StandardError
          nil
        ensure
          @refresh_group_animation_timer = nil
        end

        def animate_refresh_group(expand)
          target = (expand && refresh_group_expandable?) ? 1.0 : 0.0
          start_value = [[@refresh_group_progress.to_f, 0.0].max, 1.0].min
          return true if (start_value - target).abs < 0.001
          cancel_refresh_group_animation
          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          @refresh_group_animation_timer = GavinTools::SULinkHubMultiSpace::Runtime.runtime_start_timer(REFRESH_GROUP_ANIMATION_INTERVAL, true) do
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
            linear = [[elapsed / REFRESH_GROUP_ANIMATION_DURATION, 0.0].max, 1.0].min
            eased = linear < 0.5 ? 2.0 * linear * linear : 1.0 - ((-2.0 * linear + 2.0)**2) / 2.0
            @refresh_group_progress = start_value + (target - start_value) * eased
            if linear >= 1.0
              cancel_refresh_group_animation
              @refresh_group_progress = target
            end
            invalidate_view
          end
          true
        rescue StandardError
          cancel_refresh_group_animation
          @refresh_group_progress = target
          invalidate_view
          false
        end

        def cancel_library_group_animation
          GavinTools::SULinkHubMultiSpace::Runtime.runtime_stop_timer(@library_group_animation_timer) if @library_group_animation_timer
        rescue StandardError
          nil
        ensure
          @library_group_animation_timer = nil
        end

        def animate_library_group(expand)
          expand = true if space_edit_tools_auto_expanded?
          target = (expand && library_group_expandable?) ? 1.0 : 0.0
          start_value = [[@library_group_progress.to_f, 0.0].max, 1.0].min
          return true if (start_value - target).abs < 0.001
          cancel_library_group_animation
          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          @library_group_animation_timer = GavinTools::SULinkHubMultiSpace::Runtime.runtime_start_timer(LIBRARY_GROUP_ANIMATION_INTERVAL, true) do
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
            linear = [[elapsed / LIBRARY_GROUP_ANIMATION_DURATION, 0.0].max, 1.0].min
            eased = linear < 0.5 ? 2.0 * linear * linear : 1.0 - ((-2.0 * linear + 2.0)**2) / 2.0
            @library_group_progress = start_value + (target - start_value) * eased
            if linear >= 1.0
              cancel_library_group_animation
              @library_group_progress = target
            end
            invalidate_view
          end
          true
        rescue StandardError
          cancel_library_group_animation
          @library_group_progress = target
          invalidate_view
          false
        end

        def schedule_drawer_open
          return if (@drawer_open && @drawer_progress.to_f >= 0.999) || @drawer_open_timer
          @drawer_open_timer = GavinTools::SULinkHubMultiSpace::Runtime.runtime_start_timer(DRAWER_OPEN_DELAY, false) do
            @drawer_open_timer = nil
            expand_drawer! if @active && @drawer_pointer_inside
          end
        rescue StandardError
          @drawer_open_timer = nil
        end

        def schedule_drawer_close
          return unless @drawer_open
          return if drawer_interaction_hold_active?
          return if @drawer_pinned || @drawer_pointer_inside || @drawer_close_timer
          @drawer_close_timer = GavinTools::SULinkHubMultiSpace::Runtime.runtime_start_timer(DRAWER_CLOSE_DELAY, false) do
            @drawer_close_timer = nil
            collapse_drawer! unless @drawer_pinned || @drawer_pointer_inside
          end
        rescue StandardError
          @drawer_close_timer = nil
        end

        def cancel_drawer_open_timer
          GavinTools::SULinkHubMultiSpace::Runtime.runtime_stop_timer(@drawer_open_timer) if @drawer_open_timer
        rescue StandardError
          nil
        ensure
          @drawer_open_timer = nil
        end

        def cancel_drawer_close_timer
          GavinTools::SULinkHubMultiSpace::Runtime.runtime_stop_timer(@drawer_close_timer) if @drawer_close_timer
        rescue StandardError
          nil
        ensure
          @drawer_close_timer = nil
        end

        def cancel_drawer_timers
          cancel_drawer_open_timer
          cancel_drawer_close_timer
          cancel_drawer_animation
        end

        def cancel_drawer_live_refresh
          @drawer_live_refresh_token = @drawer_live_refresh_token.to_i + 1
          GavinTools::SULinkHubMultiSpace::Runtime.runtime_stop_timer(@drawer_live_refresh_timer) if @drawer_live_refresh_timer
        rescue StandardError
          nil
        ensure
          @drawer_live_refresh_timer = nil
        end

        def schedule_drawer_live_refresh_after_open
          cancel_drawer_live_refresh
          @drawer_live_refresh_token = @drawer_live_refresh_token.to_i + 1
          token = @drawer_live_refresh_token
          delay = DRAWER_ANIMATION_DURATION + DRAWER_LIVE_REFRESH_AFTER_OPEN_DELAY
          @drawer_live_refresh_timer = GavinTools::SULinkHubMultiSpace::Runtime.runtime_start_timer(delay, false, label: 'drawer:live_refresh_after_open') do
            next unless @drawer_live_refresh_token.to_i == token
            @drawer_live_refresh_timer = nil
            next unless @active && @drawer_open && @drawer_progress.to_f >= 0.98
            GavinTools::SULinkHubMultiSpace::Runtime.activate_workspace_toolbar_live_refresh(@model)
          end
          true
        rescue StandardError
          @drawer_live_refresh_timer = nil
          false
        end

        def cancel_drawer_animation
          GavinTools::SULinkHubMultiSpace::Runtime.runtime_stop_timer(@drawer_animation_timer) if @drawer_animation_timer
        rescue StandardError
          nil
        ensure
          @drawer_animation_timer = nil
        end

        def animate_drawer_to(target)
          GavinTools::SULinkHubMultiSpace::Runtime.note_runtime_interaction!(@model)
          target = target.to_f >= 0.5 ? 1.0 : 0.0
          cancel_drawer_animation
          @drawer_animation_target = target
          start_value = [[@drawer_progress.to_f, 0.0].max, 1.0].min
          if (start_value - target).abs < 0.001
            @drawer_progress = target
            @drawer_open = target.positive?
            return true
          end
          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          @drawer_animation_timer = GavinTools::SULinkHubMultiSpace::Runtime.runtime_start_timer(DRAWER_ANIMATION_INTERVAL, true) do
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
            linear = [[elapsed / DRAWER_ANIMATION_DURATION, 0.0].max, 1.0].min
            eased = 1.0 - ((1.0 - linear)**3)
            @drawer_progress = start_value + (target - start_value) * eased
            if linear >= 1.0
              cancel_drawer_animation
              @drawer_progress = target
              @drawer_open = target.positive?
            end
            invalidate_view
          end
          true
        rescue StandardError
          cancel_drawer_animation
          @drawer_progress = target
          @drawer_open = target.positive?
          invalidate_view
          false
        end

        def drawer_opening_animation?
          !!@drawer_animation_timer && @drawer_animation_target.to_f > @drawer_progress.to_f
        rescue StandardError
          false
        end

        def draw_drawer_opening_shell(view, x, y, width, height)
          draw_round_rect(view, x + 2.0, y + 5.0, width + 3.0, height, 22.0, rgba(0, 0, 0, 42))
          shell = draw_round_rect(view, x - 8.0, y, width + 8.0, height, 22.0, rgba(27, 33, 44, 168))
          draw_round_rect(view, x - 5.0, y + 1.0, width + 3.0, 43.0, 21.0, rgba(74, 112, 190, 58))
          view.drawing_color = rgba(255, 255, 255, 52)
          view.draw2d(GL_LINE_LOOP, shell)
          draw_round_rect(view, x + 1.0, y + 20.0, 3.0, height - 40.0, 1.5, rgba(82, 145, 255, 205))

          project_title = @state['drawer_project_label'].to_s
          project_title = 'SU LinkHub' if project_title.empty?
          project_title = project_title[0, 11] + '…' if project_title.length > 12
          draw_text_safe(view, x + 12.0, y + 3.0, project_title, rgba(250, 252, 255, 246), size: 12, bold: true)
          draw_text_safe(view, x + 12.0, y + 22.0, '快速协同操作', rgba(210, 219, 235, 196), size: 9, bold: false)

          # 少量静态骨架让位移动画可见，但不绘制空间树、按钮命中区和复杂图标。
          body_alpha = (56 + 52 * [[@drawer_progress.to_f, 0.0].max, 1.0].min).to_i
          draw_round_rect(view, x + 14.0, y + 70.0, width - 28.0, 62.0, 14.0, rgba(255, 255, 255, body_alpha))
          draw_round_rect(view, x + 14.0, y + 145.0, width - 28.0, 118.0, 14.0, rgba(255, 255, 255, body_alpha - 12))
          draw_round_rect(view, x + 14.0, y + 276.0, width - 28.0, 62.0, 14.0, rgba(255, 255, 255, body_alpha - 18))
          true
        rescue StandardError
          false
        end

        def handle_overlay_pointer(_flags, x, y, view)
          unless toolbar_visible?
            @hover_action = nil
            @hover_row_key = nil
            @pressed_action = nil
            return false
          end
          remember_view(view)
          update_drawer_pointer(x, y, view)
          refresh_hover = refresh_group_hover_at?(x, y, view)
          library_hover = library_group_hover_at?(x, y, view)
          workspace_hover = workspace_switch_hover_at?(x, y, view)
          workspace_changed = (@workspace_switch_expanded == true) != workspace_hover
          @workspace_switch_expanded = workspace_hover
          # 建筑与室内必须使用同一套悬停行解析。此前 Overlay 只查室内 drawer_row_at，
          # 而点击 Tool 会先查 architecture_row_at；同一鼠标移动因此会把建筑 hover
          # 刚设好又清掉，留下旧 tooltip 却不再绘制悬停图标。
          row = architecture_row_at(x, y, view) || drawer_row_at(x, y, view)
          row_key = row ? "#{row['kind']}:#{row['id']}" : nil
          previous_row = @hover_row_key
          @hover_row_key = row_key
          action = action_at(x, y, view)
          if action != @hover_action || row_key != previous_row || workspace_changed
            @hover_action = action
            animate_mode_switch(action == 'representation')
            animate_drawer_mode_switch(action == 'drawer_toggle_space_mode')
            view.invalidate
          end
          animate_refresh_group(refresh_hover)
          animate_library_group(library_hover)
          if view.respond_to?(:tooltip=)
            if action
              view.tooltip = tooltip_for(action, view)
            elsif library_hover
              view.tooltip = '展开模型库、材质库与吸管'
            elsif refresh_hover
              view.tooltip = '展开其他专业更新'
            elsif workspace_hover
              view.tooltip = '选择建筑 / 硬装 / 软装 / 景观工作区'
            else
              view.tooltip = ''
            end
          end
          if action || refresh_hover || workspace_hover || @drawer_pointer_inside
            GavinTools::SULinkHubMultiSpace::Runtime.ensure_workspace_toolbar_click_tool(@model, self)
          end
          true
        rescue StandardError
          false
        end

        def draw_eye(view, x, y, open_state, color)
          cx = x + BUTTON_SIZE / 2.0
          cy = y + BUTTON_SIZE / 2.0
          rx = 8.5
          ry = 5.2
          points = []
          9.times do |i|
            t = i.to_f / 8.0
            px = cx - rx + rx * 2.0 * t
            py = cy - Math.sin(Math::PI * t) * ry
            points << screen_point(px, py)
          end
          8.downto(0) do |i|
            t = i.to_f / 8.0
            px = cx - rx + rx * 2.0 * t
            py = cy + Math.sin(Math::PI * t) * ry
            points << screen_point(px, py)
          end
          view.line_width = 1.5 if view.respond_to?(:line_width=)
          view.drawing_color = color
          view.draw2d(GL_LINE_LOOP, points)
          if open_state
            pupil = []
            16.times do |i|
              angle = Math::PI * 2.0 * i / 16.0
              pupil << screen_point(cx + Math.cos(angle) * 2.4, cy + Math.sin(angle) * 2.4)
            end
            view.draw2d(GL_POLYGON, pupil)
          else
            view.draw2d(GL_LINES, [screen_point(cx - 6.6, cy - 6.6), screen_point(cx + 6.6, cy + 6.6)])
          end
        rescue StandardError
          draw_text_safe(view, x + 9, y + 4, open_state ? '显' : '隐', color, size: 11)
        end

        def drawer_items
          items = Array(@state['drawer_items']).first(4)
          return items unless items.empty?
          [
            { 'name' => '建筑', 'status' => '读取中', 'color' => [112, 122, 138], 'action' => 'architecture_sync', 'action_label' => '更新', 'enabled' => false },
            { 'name' => '硬装', 'status' => '读取中', 'color' => [112, 122, 138], 'action' => "drawer_set_workspace:#{SPACE_COLLECTION_KEY}", 'action_label' => '进入', 'enabled' => false },
            { 'name' => '软装', 'status' => '读取中', 'color' => [112, 122, 138], 'action' => "drawer_set_workspace:#{SOFT_SPACE_COLLECTION_KEY}", 'action_label' => '进入', 'enabled' => false },
            { 'name' => '景观', 'status' => '读取中', 'color' => [112, 122, 138], 'action' => 'landscape_sync', 'action_label' => '更新', 'enabled' => false }
          ]
        end

        def drawer_control(action, view = nil)
          drawer_button_definitions(view).find { |item| item[:action].to_s == action.to_s }
        end

        def draw_pill_button(view, action, label, rgb, size: 9)
          button = drawer_control(action, view)
          return unless button
          x, y, width, height = button[:rect]
          enabled = button[:enabled] != false
          hovered = @hover_action == button[:action]
          pressed = @pressed_action == button[:action]
          alpha = enabled ? (pressed ? 238 : (hovered ? 218 : 158)) : 48
          shift = pressed ? 1.0 : 0.0
          points = draw_round_rect(view, x, y + shift, width, height, height / 2.0, rgba(rgb[0], rgb[1], rgb[2], alpha))
          view.drawing_color = hovered ? rgba(255, 255, 255, 148) : rgba(255, 255, 255, 44)
          view.draw2d(GL_LINE_LOOP, points)
          text_width = label.to_s.length * (size + 1.0)
          text_y = y + (height - size - 4.0) / 2.0 + shift
          draw_text_safe(view, x + (width - text_width) / 2.0, text_y, label, enabled ? rgba(255, 255, 255, 248) : rgba(235, 238, 244, 112), size: size, bold: true)
        end

        def draw_icon_segments(view, segments, color, line_width = 1.6)
          points = Array(segments).flat_map do |segment|
            x1, y1, x2, y2 = segment
            [screen_point(x1, y1), screen_point(x2, y2)]
          end
          return if points.empty?
          view.line_width = line_width if view.respond_to?(:line_width=)
          view.drawing_color = color
          view.draw2d(GL_LINES, points)
        end

        def icon_arc_segments(cx, cy, rx, ry, start_angle, end_angle, steps = 9)
          points = (0..steps).map do |index|
            angle = start_angle + (end_angle - start_angle) * index.to_f / steps.to_f
            [cx + Math.cos(angle) * rx, cy + Math.sin(angle) * ry]
          end
          points.each_cons(2).map { |a, b| [a[0], a[1], b[0], b[1]] }
        end

        # 视口原生矢量图标，不依赖系统 Emoji 或外部图标字体。
        def draw_vector_icon(view, icon, rect, color)
          x, y, width, height = rect
          cx = x + width / 2.0
          cy = y + height / 2.0
          size = [width, height].min * 0.36
          segments = []
          case icon.to_sym
          when :menu
            [-0.55, 0.0, 0.55].each { |offset| segments << [cx - size, cy + size * offset, cx + size, cy + size * offset] }
          when :pin
            head = [
              screen_point(cx - size * 0.55, cy - size * 0.72), screen_point(cx + size * 0.55, cy - size * 0.72),
              screen_point(cx + size * 0.35, cy - size * 0.05), screen_point(cx - size * 0.35, cy - size * 0.05)
            ]
            view.drawing_color = color
            view.draw2d(GL_LINE_LOOP, head)
            segments = [[cx - size * 0.72, cy - size * 0.05, cx + size * 0.72, cy - size * 0.05], [cx, cy - size * 0.05, cx, cy + size * 0.82]]
          when :collapse, :chevron_right
            segments = [[cx + size * 0.32, cy - size * 0.72, cx - size * 0.32, cy], [cx - size * 0.32, cy, cx + size * 0.32, cy + size * 0.72]]
          when :chevron_down
            segments = [[cx - size * 0.72, cy - size * 0.32, cx, cy + size * 0.32], [cx, cy + size * 0.32, cx + size * 0.72, cy - size * 0.32]]
          when :folder, :folder_plus
            points = [
              screen_point(cx - size, cy - size * 0.55), screen_point(cx - size * 0.25, cy - size * 0.55),
              screen_point(cx + size * 0.02, cy - size * 0.28), screen_point(cx + size, cy - size * 0.28),
              screen_point(cx + size, cy + size * 0.68), screen_point(cx - size, cy + size * 0.68)
            ]
            view.drawing_color = color
            view.draw2d(GL_LINE_LOOP, points)
            if icon.to_sym == :folder_plus
              segments = [[cx + size * 0.28, cy + size * 0.18, cx + size * 0.78, cy + size * 0.18], [cx + size * 0.53, cy - size * 0.07, cx + size * 0.53, cy + size * 0.43]]
            end
          when :connect
            segments = [
              [cx - size * 0.58, cy - size * 0.42, cx + size * 0.58, cy + size * 0.42],
              [cx - size * 0.58, cy + size * 0.42, cx + size * 0.58, cy - size * 0.42]
            ]
            [[cx - size * 0.72, cy - size * 0.52], [cx + size * 0.72, cy - size * 0.52], [cx, cy + size * 0.66]].each do |nx, ny|
              draw_round_rect(view, nx - size * 0.19, ny - size * 0.19, size * 0.38, size * 0.38, size * 0.19, color)
            end
          when :shield
            points = [
              screen_point(cx, cy - size), screen_point(cx + size * 0.82, cy - size * 0.62),
              screen_point(cx + size * 0.68, cy + size * 0.35), screen_point(cx, cy + size),
              screen_point(cx - size * 0.68, cy + size * 0.35), screen_point(cx - size * 0.82, cy - size * 0.62)
            ]
            view.drawing_color = color
            view.draw2d(GL_LINE_LOOP, points)
            segments = [[cx - size * 0.4, cy, cx - size * 0.08, cy + size * 0.32], [cx - size * 0.08, cy + size * 0.32, cx + size * 0.48, cy - size * 0.3]]
          when :refresh
            segments = icon_arc_segments(cx, cy, size * 0.78, size * 0.78, -Math::PI * 0.82, Math::PI * 0.72, 10)
            segments += [[cx - size * 0.78, cy - size * 0.32, cx - size * 0.86, cy - size * 0.86], [cx - size * 0.78, cy - size * 0.32, cx - size * 0.28, cy - size * 0.48]]
          when :pencil
            points = [
              screen_point(cx - size * 0.72, cy + size * 0.46), screen_point(cx - size * 0.46, cy + size * 0.72),
              screen_point(cx + size * 0.78, cy - size * 0.52), screen_point(cx + size * 0.52, cy - size * 0.78)
            ]
            view.drawing_color = color
            view.draw2d(GL_LINE_LOOP, points)
            segments = [[cx - size * 0.72, cy + size * 0.46, cx - size * 0.88, cy + size * 0.88], [cx - size * 0.46, cy + size * 0.72, cx - size * 0.88, cy + size * 0.88]]
          when :upload, :download
            upward = icon.to_sym == :upload
            direction = upward ? -1.0 : 1.0
            arrow_y = cy + direction * size * 0.76
            base_y = cy - direction * size * 0.05
            segments = [
              [cx, base_y, cx, arrow_y],
              [cx, arrow_y, cx - size * 0.42, arrow_y - direction * size * 0.42],
              [cx, arrow_y, cx + size * 0.42, arrow_y - direction * size * 0.42],
              [cx - size * 0.8, cy + size * 0.8, cx + size * 0.8, cy + size * 0.8],
              [cx - size * 0.8, cy + size * 0.8, cx - size * 0.8, cy + size * 0.42],
              [cx + size * 0.8, cy + size * 0.8, cx + size * 0.8, cy + size * 0.42]
            ]
          when :unload
            # 本机卸载：弹出/移除当前工作 SU 中的受管空间，不触碰共享发布文件。
            tray_y = cy + size * 0.62
            segments = [
              [cx - size * 0.82, tray_y, cx + size * 0.82, tray_y],
              [cx - size * 0.82, tray_y, cx - size * 0.82, tray_y - size * 0.30],
              [cx + size * 0.82, tray_y, cx + size * 0.82, tray_y - size * 0.30],
              [cx, cy + size * 0.20, cx, cy - size * 0.72],
              [cx, cy - size * 0.72, cx - size * 0.38, cy - size * 0.34],
              [cx, cy - size * 0.72, cx + size * 0.38, cy - size * 0.34]
            ]
          when :history
            segments = icon_arc_segments(cx, cy, size * 0.75, size * 0.75, -Math::PI * 0.85, Math::PI * 0.8, 10)
            segments += [[cx - size * 0.75, cy - size * 0.28, cx - size * 0.85, cy - size * 0.82], [cx - size * 0.75, cy - size * 0.28, cx - size * 0.25, cy - size * 0.46], [cx, cy - size * 0.42, cx, cy + size * 0.05], [cx, cy + size * 0.05, cx + size * 0.38, cy + size * 0.28]]
          when :lock
            segments = icon_arc_segments(cx, cy - size * 0.18, size * 0.52, size * 0.58, Math::PI, Math::PI * 2.0, 7)
            body = rounded_rect_points(cx - size * 0.78, cy - size * 0.05, size * 1.56, size * 1.0, size * 0.18, 4)
            view.drawing_color = color
            view.draw2d(GL_LINE_LOOP, body)
            segments += [[cx, cy + size * 0.22, cx, cy + size * 0.52]]
          when :unlock
            # 打开的锁扣只表示“回收本人遗留占用”，避免与普通锁定/发布按钮混淆。
            body = rounded_rect_points(cx - size * 0.78, cy - size * 0.05, size * 1.56, size * 1.0, size * 0.18, 4)
            view.drawing_color = color
            view.draw2d(GL_LINE_LOOP, body)
            segments = icon_arc_segments(cx - size * 0.18, cy - size * 0.18, size * 0.52, size * 0.58, Math::PI, Math::PI * 1.72, 6)
            segments += [
              [cx + size * 0.31, cy - size * 0.63, cx + size * 0.72, cy - size * 0.63],
              [cx, cy + size * 0.22, cx, cy + size * 0.52]
            ]
          when :manage
            # 三条管理滑杆：在 30px 抽屉按钮内比齿轮更清晰，也避免小尺寸齿轮发糊。
            segments = [
              [cx - size * 0.88, cy - size * 0.56, cx + size * 0.88, cy - size * 0.56],
              [cx - size * 0.88, cy, cx + size * 0.88, cy],
              [cx - size * 0.88, cy + size * 0.56, cx + size * 0.88, cy + size * 0.56]
            ]
            draw_round_rect(view, cx - size * 0.42, cy - size * 0.72, size * 0.28, size * 0.32, size * 0.14, color)
            draw_round_rect(view, cx + size * 0.18, cy - size * 0.16, size * 0.28, size * 0.32, size * 0.14, color)
            draw_round_rect(view, cx - size * 0.12, cy + size * 0.40, size * 0.28, size * 0.32, size * 0.14, color)
          when :locate
            # 定位图标：中心准星与四个方向短刻度。
            segments = icon_arc_segments(cx, cy, size * 0.52, size * 0.52, 0.0, Math::PI * 2.0, 14)
            segments += [
              [cx, cy - size * 0.98, cx, cy - size * 0.58],
              [cx, cy + size * 0.58, cx, cy + size * 0.98],
              [cx - size * 0.98, cy, cx - size * 0.58, cy],
              [cx + size * 0.58, cy, cx + size * 0.98, cy]
            ]
            draw_round_rect(view, cx - size * 0.12, cy - size * 0.12, size * 0.24, size * 0.24, size * 0.12, color)
          when :close
            segments = [
              [cx - size * 0.68, cy - size * 0.68, cx + size * 0.68, cy + size * 0.68],
              [cx + size * 0.68, cy - size * 0.68, cx - size * 0.68, cy + size * 0.68]
            ]
          when :note
            body = rounded_rect_points(cx - size * 0.78, cy - size * 0.82, size * 1.56, size * 1.72, size * 0.12, 4)
            view.drawing_color = color
            view.draw2d(GL_LINE_LOOP, body)
            segments = [
              [cx - size * 0.42, cy - size * 0.95, cx - size * 0.42, cy - size * 0.58],
              [cx + size * 0.42, cy - size * 0.95, cx + size * 0.42, cy - size * 0.58],
              [cx - size * 0.42, cy - size * 0.22, cx + size * 0.42, cy - size * 0.22],
              [cx - size * 0.42, cy + size * 0.18, cx + size * 0.42, cy + size * 0.18],
              [cx - size * 0.42, cy + size * 0.58, cx + size * 0.18, cy + size * 0.58]
            ]
          when :settings
            segments = [
              [cx - size * 0.82, cy - size * 0.50, cx + size * 0.82, cy - size * 0.50],
              [cx - size * 0.82, cy, cx + size * 0.82, cy],
              [cx - size * 0.82, cy + size * 0.50, cx + size * 0.82, cy + size * 0.50]
            ]
            draw_round_rect(view, cx - size * 0.34, cy - size * 0.64, size * 0.28, size * 0.28, size * 0.14, color)
            draw_round_rect(view, cx + size * 0.24, cy - size * 0.14, size * 0.28, size * 0.28, size * 0.14, color)
            draw_round_rect(view, cx - size * 0.02, cy + size * 0.36, size * 0.28, size * 0.28, size * 0.14, color)
          when :plus
            segments = [[cx - size * 0.72, cy, cx + size * 0.72, cy], [cx, cy - size * 0.72, cx, cy + size * 0.72]]
          when :copy
            back = rounded_rect_points(cx - size * 0.78, cy - size * 0.78, size * 1.18, size * 1.18, size * 0.12, 4)
            front = rounded_rect_points(cx - size * 0.36, cy - size * 0.34, size * 1.18, size * 1.18, size * 0.12, 4)
            view.drawing_color = color
            view.draw2d(GL_LINE_LOOP, back)
            view.draw2d(GL_LINE_LOOP, front)
          when :check
            segments = [
              [cx - size * 0.78, cy + size * 0.02, cx - size * 0.18, cy + size * 0.62],
              [cx - size * 0.18, cy + size * 0.62, cx + size * 0.82, cy - size * 0.58]
            ]
          when :palette
            # 材质库：三片错位色板与右下角取样点，保持小尺寸下仍可识别。
            draw_round_rect(view, cx - size * 0.82, cy - size * 0.72, size * 1.10, size * 1.10, size * 0.18, color)
            draw_round_rect(view, cx - size * 0.22, cy - size * 0.20, size * 1.02, size * 1.02, size * 0.18, color)
            segments = [
              [cx - size * 0.58, cy - size * 0.42, cx - size * 0.18, cy - size * 0.42],
              [cx + size * 0.04, cy + size * 0.08, cx + size * 0.42, cy + size * 0.08]
            ]
            draw_round_rect(view, cx + size * 0.42, cy + size * 0.48, size * 0.24, size * 0.24, size * 0.12, color)
          when :pipette
            # 轻量吸管：斜向管身、滴嘴与取样小滴。
            segments = [
              [cx - size * 0.72, cy + size * 0.62, cx + size * 0.48, cy - size * 0.58],
              [cx - size * 0.48, cy + size * 0.82, cx + size * 0.70, cy - size * 0.36],
              [cx + size * 0.34, cy - size * 0.72, cx + size * 0.82, cy - size * 0.24],
              [cx - size * 0.72, cy + size * 0.62, cx - size * 0.90, cy + size * 0.92]
            ]
            draw_round_rect(view, cx - size * 0.98, cy + size * 0.78, size * 0.22, size * 0.22, size * 0.11, color)
          when :grid
            # 模型库使用四个轻量线框方格，避免小尺寸下形成一整块实心图形。
            cell = size * 0.54
            gap = size * 0.24
            left = cx - cell - gap / 2.0
            top = cy - cell - gap / 2.0
            [[left, top], [cx + gap / 2.0, top], [left, cy + gap / 2.0], [cx + gap / 2.0, cy + gap / 2.0]].each do |gx, gy|
              points = rounded_rect_points(gx, gy, cell, cell, cell * 0.12, 4)
              view.drawing_color = color
              view.draw2d(GL_LINE_LOOP, points)
            end
          when :building
            # 最简房屋线稿：屋顶、墙体和一个门洞，不再绘制楼房窗格或实心块。
            segments = [
              [cx - size * 0.92, cy - size * 0.02, cx, cy - size * 0.86],
              [cx, cy - size * 0.86, cx + size * 0.92, cy - size * 0.02],
              [cx - size * 0.70, cy - size * 0.20, cx - size * 0.70, cy + size * 0.82],
              [cx + size * 0.70, cy - size * 0.20, cx + size * 0.70, cy + size * 0.82],
              [cx - size * 0.70, cy + size * 0.82, cx + size * 0.70, cy + size * 0.82],
              [cx - size * 0.18, cy + size * 0.82, cx - size * 0.18, cy + size * 0.24],
              [cx - size * 0.18, cy + size * 0.24, cx + size * 0.22, cy + size * 0.24],
              [cx + size * 0.22, cy + size * 0.24, cx + size * 0.22, cy + size * 0.82]
            ]
          when :sofa
            # 四分之三侧视的极简单椅：靠背、坐面、扶手和三条腿。
            # 全部使用开放线条，避免原沙发双层圆角框在 32px 按钮中显得厚重。
            segments = [
              [cx - size * 0.72, cy - size * 0.72, cx - size * 0.58, cy + size * 0.10],
              [cx - size * 0.72, cy - size * 0.72, cx + size * 0.18, cy - size * 0.48],
              [cx + size * 0.18, cy - size * 0.48, cx + size * 0.34, cy + size * 0.05],
              [cx - size * 0.58, cy + size * 0.10, cx + size * 0.34, cy + size * 0.05],
              [cx - size * 0.58, cy + size * 0.10, cx - size * 0.18, cy + size * 0.42],
              [cx - size * 0.18, cy + size * 0.42, cx + size * 0.76, cy + size * 0.26],
              [cx + size * 0.76, cy + size * 0.26, cx + size * 0.34, cy + size * 0.05],
              [cx + size * 0.34, cy + size * 0.05, cx + size * 0.78, cy - size * 0.08],
              [cx - size * 0.18, cy + size * 0.42, cx - size * 0.24, cy + size * 0.88],
              [cx + size * 0.66, cy + size * 0.28, cx + size * 0.60, cy + size * 0.74],
              [cx - size * 0.52, cy + size * 0.12, cx - size * 0.58, cy + size * 0.66]
            ]
          when :mountain
            # 极简双峰山线稿，不绘制底边、积雪或填充面。
            segments = [
              [cx - size * 0.98, cy + size * 0.66, cx - size * 0.34, cy - size * 0.52],
              [cx - size * 0.34, cy - size * 0.52, cx + size * 0.02, cy + size * 0.12],
              [cx - size * 0.10, cy + size * 0.34, cx + size * 0.42, cy - size * 0.66],
              [cx + size * 0.42, cy - size * 0.66, cx + size * 1.00, cy + size * 0.66]
            ]
          when :plant
            # 绿色景观模型库入口：花盆、主茎与左右叶片。
            segments = [
              [cx, cy + size * 0.62, cx, cy - size * 0.62],
              [cx, cy - size * 0.18, cx - size * 0.54, cy - size * 0.50],
              [cx, cy + size * 0.06, cx + size * 0.56, cy - size * 0.30],
              [cx - size * 0.54, cy - size * 0.50, cx - size * 0.22, cy - size * 0.58],
              [cx + size * 0.56, cy - size * 0.30, cx + size * 0.24, cy - size * 0.40]
            ]
            pot = rounded_rect_points(cx - size * 0.48, cy + size * 0.48, size * 0.96, size * 0.48, size * 0.10, 4)
            view.drawing_color = color
            view.draw2d(GL_LINE_LOOP, pot)
          when :cube_outline, :cube_solid
            top = [cx, cy - size * 0.9]
            left = [cx - size * 0.8, cy - size * 0.4]
            right = [cx + size * 0.8, cy - size * 0.4]
            middle = [cx, cy + size * 0.08]
            left_bottom = [cx - size * 0.8, cy + size * 0.45]
            right_bottom = [cx + size * 0.8, cy + size * 0.45]
            bottom = [cx, cy + size * 0.92]
            if icon.to_sym == :cube_solid
              view.drawing_color = color
              view.draw2d(GL_POLYGON, [top, left, middle, right].map { |px, py| screen_point(px, py) })
              view.draw2d(GL_POLYGON, [left, left_bottom, bottom, middle].map { |px, py| screen_point(px, py) })
              view.draw2d(GL_POLYGON, [right, middle, bottom, right_bottom].map { |px, py| screen_point(px, py) })
            end
            edges = [[top, left], [top, right], [left, middle], [right, middle], [left, left_bottom], [right, right_bottom], [middle, bottom], [left_bottom, bottom], [right_bottom, bottom]]
            segments = edges.map { |a, b| [a[0], a[1], b[0], b[1]] }
          when :enter
            segments = [
              [cx - size * 0.78, cy - size * 0.82, cx - size * 0.78, cy + size * 0.82],
              [cx - size * 0.78, cy - size * 0.82, cx + size * 0.1, cy - size * 0.82],
              [cx - size * 0.78, cy + size * 0.82, cx + size * 0.1, cy + size * 0.82],
              [cx - size * 0.15, cy, cx + size * 0.82, cy],
              [cx + size * 0.82, cy, cx + size * 0.42, cy - size * 0.4],
              [cx + size * 0.82, cy, cx + size * 0.42, cy + size * 0.4]
            ]
          when :switch
            segments = [[cx - size * 0.75, cy - size * 0.3, cx + size * 0.55, cy - size * 0.3], [cx + size * 0.55, cy - size * 0.3, cx + size * 0.2, cy - size * 0.62], [cx + size * 0.75, cy + size * 0.3, cx - size * 0.55, cy + size * 0.3], [cx - size * 0.55, cy + size * 0.3, cx - size * 0.2, cy + size * 0.62]]
          else
            segments = [[cx - size * 0.65, cy, cx + size * 0.65, cy]]
          end
          draw_icon_segments(view, segments, color)
        rescue StandardError
          draw_text_safe(view, cx - 3.0, cy - 7.0, '·', color, size: 12, bold: true)
        end

        def draw_icon_control(view, action, icon, rgb, active: false)
          button = drawer_control(action, view)
          return unless button
          x, y, width, height = button[:rect]
          enabled = button[:enabled] != false
          hovered = @hover_action == button[:action]
          pressed = @pressed_action == button[:action]
          alpha = enabled ? (pressed ? 238 : (hovered ? 214 : (active ? 176 : 116))) : 38
          shift = pressed ? 1.0 : 0.0
          points = draw_round_rect(view, x, y + shift, width, height, height / 2.0, rgba(rgb[0], rgb[1], rgb[2], alpha))
          view.drawing_color = hovered ? rgba(255, 255, 255, 146) : rgba(255, 255, 255, 38)
          view.draw2d(GL_LINE_LOOP, points)
          icon_color = enabled ? rgba(255, 255, 255, 244) : rgba(225, 231, 241, 88)
          padding = [width, height].min <= 22.0 ? 3.0 : 5.0
          draw_vector_icon(view, icon, [x + padding, y + padding + shift, width - padding * 2.0, height - padding * 2.0], icon_color)
        end

        # v0.13.5.3：建筑行的悬停按钮直接按行卡片已计算的坐标绘制。
        # 建筑列表在“待载入/已载入/分组”混合状态下，draw_icon_control 会再次
        # 反查整套 drawer controls；该二次反查可能在同一帧重算 hover，导致建筑
        # 行按钮有命中区却没有视觉图标。室内继续保留 0.13.3.2 的稳定绘制路径。
        def draw_icon_control_rect(view, action, rect, icon, rgb, enabled: true, active: false)
          return if action.to_s.empty? || !rect.is_a?(Array) || rect.length < 4
          x, y, width, height = rect.map(&:to_f)
          hovered = @hover_action.to_s == action.to_s
          pressed = @pressed_action.to_s == action.to_s
          alpha = enabled ? (pressed ? 238 : (hovered ? 214 : (active ? 176 : 116))) : 38
          shift = pressed ? 1.0 : 0.0
          points = draw_round_rect(view, x, y + shift, width, height, height / 2.0, rgba(rgb[0], rgb[1], rgb[2], alpha))
          view.drawing_color = hovered ? rgba(255, 255, 255, 146) : rgba(255, 255, 255, 38)
          view.draw2d(GL_LINE_LOOP, points)
          icon_color = enabled ? rgba(255, 255, 255, 244) : rgba(225, 231, 241, 88)
          padding = [width, height].min <= 22.0 ? 3.0 : 5.0
          draw_vector_icon(view, icon, [x + padding, y + padding + shift, width - padding * 2.0, height - padding * 2.0], icon_color)
        rescue StandardError
          nil
        end

        def drawer_action_icon(item)
          label = item.is_a?(Hash) ? item['action_label'].to_s : item.to_s
          return :upload if label.include?('发布')
          return :pencil if label.include?('修改')
          return :history if label.include?('上版') || label.include?('恢复')
          return :lock if label.include?('占用')
          return :download if label.include?('更新')
          :connect
        end

        def draw_mode_switch(view, action)
          button = drawer_control(action, view)
          return unless button
          x, y, width, height = button[:rect]
          enabled = button[:enabled] != false
          hovered = @hover_action == action
          pressed = @pressed_action == action
          full = @state['display_mode'].to_s == 'full'
          progress = drawer_mode_switch_progress
          alpha = enabled ? (pressed ? 220 : (hovered ? 188 : 126)) : 36
          shell = draw_round_rect(view, x, y + (pressed ? 1.0 : 0.0), width, height, height / 2.0, rgba(88, 67, 144, alpha))
          view.drawing_color = hovered ? rgba(255, 255, 255, 140) : rgba(255, 255, 255, 42)
          view.draw2d(GL_LINE_LOOP, shell)

          # 收缩状态只显示当前模式，保持与管理、清单、加号、小眼睛相同的单圆尺寸。
          if progress < 0.48 || width < DRAWER_SPACE_TOOL_BUTTON_SIZE * 1.42
            icon = full ? :cube_solid : :cube_outline
            icon_color = enabled ? rgba(255, 255, 255, hovered ? 252 : 238) : rgba(225, 231, 241, 88)
            padding = 5.0
            draw_vector_icon(view, icon, [x + padding, y + padding + (pressed ? 1.0 : 0.0), width - padding * 2.0, height - padding * 2.0], icon_color)
            return
          end

          half = width / 2.0
          active_x = full ? x + half : x
          active_alpha = enabled ? (pressed ? 242 : 218) : 48
          draw_round_rect(view, active_x + 2.0, y + 2.0 + (pressed ? 1.0 : 0.0), half - 4.0, height - 4.0,
                          (height - 4.0) / 2.0, rgba(132, 88, 221, active_alpha))
          fade = [[(progress - 0.38) / 0.62, 0.0].max, 1.0].min
          inactive = enabled ? rgba(223, 228, 240, (146 + 30 * fade).round) : rgba(223, 228, 240, 72)
          selected = enabled ? rgba(255, 255, 255, (226 + 26 * fade).round) : rgba(235, 239, 247, 82)
          icon_box = [height, DRAWER_SPACE_TOOL_BUTTON_SIZE].min
          left_icon_x = x + (half - icon_box) / 2.0
          right_icon_x = x + half + (half - icon_box) / 2.0
          shift = pressed ? 1.0 : 0.0
          draw_vector_icon(view, :cube_outline, [left_icon_x + 5.0, y + 5.0 + shift, icon_box - 10.0, height - 10.0], full ? inactive : selected)
          draw_vector_icon(view, :cube_solid, [right_icon_x + 5.0, y + 5.0 + shift, icon_box - 10.0, height - 10.0], full ? selected : inactive)
          divider_x = x + half
          view.drawing_color = rgba(255, 255, 255, (28 * fade).round)
          view.draw2d(GL_LINES, [screen_point(divider_x, y + 7.0), screen_point(divider_x, y + height - 7.0)])
        rescue StandardError
          nil
        end

        def professional_discipline_color(key)
          case key.to_s
          when 'architecture' then [62, 132, 232] # 建筑蓝
          when SPACE_COLLECTION_KEY, 'interior', 'hard_finish' then [188, 128, 44] # 硬装金
          when SOFT_SPACE_COLLECTION_KEY, 'soft_finish' then [139, 91, 218] # 软装紫
          when 'landscape' then [48, 168, 112] # 景观绿
          else [96, 118, 151]
          end
        rescue StandardError
          [96, 118, 151]
        end

        def draw_professional_title_button(view, action, label, discipline_key, current_workspace: false)
          button = drawer_control(action, view)
          return unless button
          x, y, width, height = button[:rect]
          hovered = @hover_action == action
          pressed = @pressed_action == action
          accent = professional_discipline_color(discipline_key)
          # 专业色只做轻量底色与左侧竖条，避免图标和短标题挤在一起。
          base = current_workspace ? accent : accent.map { |value| (value * 0.62).round }
          alpha = pressed ? 230 : (hovered ? 202 : (current_workspace ? 158 : 116))
          shift = pressed ? 1.0 : 0.0
          points = draw_round_rect(view, x, y + shift, width, height, height / 2.0, rgba(base[0], base[1], base[2], alpha))
          view.drawing_color = hovered ? rgba(255, 255, 255, 146) : rgba(255, 255, 255, 40)
          view.draw2d(GL_LINE_LOOP, points)
          stripe_h = [height - 12.0, 14.0].max
          draw_round_rect(view, x + 6.0, y + (height - stripe_h) / 2.0 + shift, 3.0, stripe_h, 1.5, rgba(accent[0], accent[1], accent[2], 248))
          draw_text_safe(view, x + 14.0, y + 7.0 + shift, label, rgba(252, 253, 255, 250), size: 9, bold: true)
        rescue StandardError
          nil
        end

        def draw_eye_control(view, action, open_state, rgb = [67, 126, 235])
          button = drawer_control(action, view)
          return unless button
          x, y, width, height = button[:rect]
          enabled = button[:enabled] != false
          hovered = @hover_action == button[:action]
          pressed = @pressed_action == button[:action]
          alpha = enabled ? (pressed ? 230 : (hovered ? 204 : (open_state ? 168 : 96))) : 42
          points = draw_round_rect(view, x, y + (pressed ? 1.0 : 0.0), width, height, height / 2.0, rgba(rgb[0], rgb[1], rgb[2], alpha))
          view.drawing_color = hovered ? rgba(255, 255, 255, 140) : rgba(255, 255, 255, 38)
          view.draw2d(GL_LINE_LOOP, points)
          cx = x + width / 2.0
          cy = y + height / 2.0 + (pressed ? 1.0 : 0.0)
          eye_points = []
          7.times do |index|
            t = index.to_f / 6.0
            eye_points << screen_point(cx - 6.0 + 12.0 * t, cy - Math.sin(Math::PI * t) * 3.6)
          end
          6.downto(0) do |index|
            t = index.to_f / 6.0
            eye_points << screen_point(cx - 6.0 + 12.0 * t, cy + Math.sin(Math::PI * t) * 3.6)
          end
          eye_color = enabled ? rgba(255, 255, 255, 238) : rgba(225, 230, 239, 98)
          view.drawing_color = eye_color
          view.draw2d(GL_LINE_LOOP, eye_points)
          draw_round_rect(view, cx - 1.8, cy - 1.8, 3.6, 3.6, 1.8, eye_color) if open_state
        rescue StandardError
          draw_pill_button(view, action, open_state ? '显' : '隐', rgb, size: 8)
        end

        def draw_eye_control_rect(view, action, rect, open_state, rgb = [67, 126, 235], enabled: true)
          return if action.to_s.empty? || !rect.is_a?(Array) || rect.length < 4
          x, y, width, height = rect.map(&:to_f)
          hovered = @hover_action.to_s == action.to_s
          pressed = @pressed_action.to_s == action.to_s
          alpha = enabled ? (pressed ? 230 : (hovered ? 204 : (open_state ? 168 : 96))) : 42
          points = draw_round_rect(view, x, y + (pressed ? 1.0 : 0.0), width, height, height / 2.0, rgba(rgb[0], rgb[1], rgb[2], alpha))
          view.drawing_color = hovered ? rgba(255, 255, 255, 140) : rgba(255, 255, 255, 38)
          view.draw2d(GL_LINE_LOOP, points)
          cx = x + width / 2.0
          cy = y + height / 2.0 + (pressed ? 1.0 : 0.0)
          eye_points = []
          7.times do |index|
            t = index.to_f / 6.0
            eye_points << screen_point(cx - 6.0 + 12.0 * t, cy - Math.sin(Math::PI * t) * 3.6)
          end
          6.downto(0) do |index|
            t = index.to_f / 6.0
            eye_points << screen_point(cx - 6.0 + 12.0 * t, cy + Math.sin(Math::PI * t) * 3.6)
          end
          eye_color = enabled ? rgba(255, 255, 255, 238) : rgba(225, 230, 239, 98)
          view.drawing_color = eye_color
          view.draw2d(GL_LINE_LOOP, eye_points)
          draw_round_rect(view, cx - 1.8, cy - 1.8, 3.6, 3.6, 1.8, eye_color) if open_state
        rescue StandardError
          nil
        end

        def drawer_status_color(item)
          rgb = Array(item && item['color'])
          rgb.length >= 3 ? rgb : [112, 122, 138]
        end

        # 组卡片不再把红／黄／绿直接平均成一个 RGB 颜色。红绿等量平均会
        # 变成灰褐色，视觉上反而像没有状态。底色仅表达展开／收纳，成员状态
        # 则按数量比例铺成连续色段；一个红、一个绿时就是半红半绿。
        def group_status_tint(base_tint, _row)
          base_tint
        rescue StandardError
          base_tint
        end

        def group_status_segments(row, fallback_color = [112, 122, 138])
          mix = row.is_a?(Hash) ? row['status_mix'] : nil
          total = mix.is_a?(Hash) ? mix['total'].to_i : 0
          return [] unless total.positive?
          colors = {
            'editing' => [218, 73, 78],
            'pending' => [224, 151, 45],
            'current' => [55, 165, 112],
            'other' => fallback_color
          }
          %w[editing pending current other].filter_map do |key|
            count = mix[key].to_i
            next unless count.positive?
            [key, count, colors[key]]
          end
        rescue StandardError
          []
        end

        def draw_group_status_proportional_fill(view, rect, row, hovered: false, expanded: false)
          segments = group_status_segments(row)
          return false if segments.empty?
          total = segments.sum { |_key, count, _color| count.to_i }
          return false unless total.positive?

          x, y, width, height = rect
          inset = 3.0
          fill_x = x + inset
          fill_y = y + inset
          fill_width = [width - inset * 2.0, 1.0].max
          fill_height = [height - inset * 2.0, 1.0].max
          alpha = expanded ? 92 : 76
          alpha += 14 if hovered
          alpha = [alpha, 118].min
          cursor = fill_x
          remaining = fill_width

          segments.each_with_index do |(_key, count, color), index|
            segment_width = if index == segments.length - 1
                              remaining
                            else
                              [fill_width * count.to_f / total.to_f, remaining].min
                            end
            next unless segment_width.positive?
            # 用实际比例色段覆盖大部分卡片高度。色段留出 3px 内边距，既不会
            # 穿出圆角，也保留底色来区分展开／收纳。
            draw_rect(view, cursor, fill_y, segment_width, fill_height,
                      rgba(color[0], color[1], color[2], alpha))
            cursor += segment_width
            remaining -= segment_width
          end
          true
        rescue StandardError
          false
        end

        def group_status_priority_color(row, fallback = [126, 176, 255])
          mix = row.is_a?(Hash) ? row['status_mix'] : nil
          return fallback unless mix.is_a?(Hash)
          return [226, 83, 88] if mix['editing'].to_i.positive?
          return [232, 167, 59] if mix['pending'].to_i.positive?
          return [75, 183, 129] if mix['current'].to_i.positive?
          fallback
        rescue StandardError
          fallback
        end

        def group_member_status_dot_color(status)
          case status.to_s
          when 'editing' then [226, 83, 88]
          when 'pending' then [232, 167, 59]
          when 'current' then [75, 183, 129]
          else [132, 145, 164]
          end
        rescue StandardError
          [132, 145, 164]
        end

        # 组内成员不超过八个时，用一空间一圆点表达数量和状态。圆点顺序与组内
        # 卡片顺序一致，比“2 个空间”更节省宽度，也能直接看到红/黄/绿分布。
        def draw_group_member_status_dots(view, row, start_x, center_y)
          statuses = Array(row && row['member_statuses'])
          return false if statuses.empty? || statuses.length > 8
          diameter = 5.5
          gap = 4.0
          statuses.each_with_index do |status, index|
            rgb = group_member_status_dot_color(status)
            dot_x = start_x + index * (diameter + gap)
            dot_y = center_y - diameter / 2.0
            dot = draw_round_rect(view, dot_x, dot_y, diameter, diameter, diameter / 2.0,
                                  rgba(rgb[0], rgb[1], rgb[2], 242))
            view.drawing_color = rgba(255, 255, 255, 72)
            view.draw2d(GL_LINE_LOOP, dot)
          end
          true
        rescue StandardError
          false
        end

        def draw_group_status_ratio_bar(view, rect, row)
          mix = row.is_a?(Hash) ? row['status_mix'] : nil
          total = mix.is_a?(Hash) ? mix['total'].to_i : 0
          return false unless total.positive?

          x, y, width, height = rect
          bar_x = x + 8.0
          bar_y = y + height - 3.2
          bar_width = [width - 16.0, 1.0].max
          cursor = bar_x
          remaining = bar_width
          segments = [
            ['editing', [218, 73, 78]],
            ['pending', [224, 151, 45]],
            ['current', [55, 165, 112]],
            ['other', [112, 122, 138]]
          ]
          segments.each_with_index do |(key, color), index|
            count = mix[key].to_i
            next unless count.positive?
            segment_width = if index == segments.length - 1
                              remaining
                            else
                              [bar_width * count.to_f / total.to_f, remaining].min
                            end
            next unless segment_width.positive?
            draw_rect(view, cursor, bar_y, segment_width, 2.2, rgba(color[0], color[1], color[2], 224))
            cursor += segment_width
            remaining -= segment_width
          end
          true
        rescue StandardError
          false
        end

        def draw_glass_card(view, rect, alpha = 20, tint: nil)
          x, y, width, height = rect
          fill = tint ? rgba(tint[0], tint[1], tint[2], 54) : rgba(255, 255, 255, alpha)
          border = if tint
                     rgba([tint[0].to_i + 76, 255].min, [tint[1].to_i + 76, 255].min, [tint[2].to_i + 76, 255].min, 92)
                   else
                     rgba(255, 255, 255, 24)
                   end
          points = draw_round_rect(view, x, y, width, height, 14.0, fill)
          view.drawing_color = border
          view.draw2d(GL_LINE_LOOP, points)
          points
        end

        def draw_drawer_tools(view, x, y, width, _height)
          draw_glass_card(view, [x + 10.0, y + 52.0, width - 20.0, 398.0], 22)
          draw_text_safe(view, x + 22.0, y + 62.0, '工作模型与文件工具', rgba(248, 250, 254, 248), size: 12, bold: true)
          backup_dir = @state['drawer_backup_dir'].to_s
          backup_label = backup_dir.empty? ? '副本目录：未设置' : "副本目录：#{File.basename(backup_dir.tr('\\', '/'))}"
          backup_label = backup_label[0, 24] + '…' if backup_label.length > 25
          draw_text_safe(view, x + 22.0, y + 81.0, backup_label, rgba(200, 211, 229, 216), size: 8, bold: false)
          draw_pill_button(view, 'drawer_tool_save_model', '保存当前 SU', [58, 114, 178], size: 9)
          draw_pill_button(view, 'drawer_tool_save_backup_now', '立即保存副本', [69, 131, 99], size: 9)
          draw_pill_button(view, 'drawer_tool_open_backup_folder', '打开副本文件夹', [67, 77, 94], size: 9)
          draw_pill_button(view, 'drawer_tool_choose_backup_folder', '更改副本目录', [67, 77, 94], size: 9)
          interval = @state['drawer_backup_interval_minutes'].to_i
          interval_label = interval.zero? ? '副本提醒：每次建筑更新前询问' : "副本提醒间隔：#{interval} 分钟"
          draw_pill_button(view, 'drawer_tool_backup_interval', interval_label, [87, 102, 145], size: 9)

          draw_text_safe(view, x + 22.0, y + 224.0, '项目与诊断', rgba(248, 250, 254, 238), size: 10, bold: true)
          draw_pill_button(view, 'drawer_tool_open_project_folder', '协同项目文件夹', [58, 114, 178], size: 9)
          draw_pill_button(view, 'drawer_tool_open_data_folder', '模型数据目录', [58, 114, 178], size: 9)
          draw_pill_button(view, 'drawer_tool_open_log_folder', '日志文件夹', [86, 93, 109], size: 9)
          draw_pill_button(view, 'drawer_refresh_status', '全面检查', [120, 92, 52], size: 9)
          draw_pill_button(view, 'drawer_tools_done', '完成', [58, 114, 178], size: 9)
        rescue StandardError => e
          GavinTools::SULinkHubMultiSpace::Runtime.log_exception('绘制抽屉工具页失败', e)
        end

        def professional_section_summary(rows, empty_label)
          list = Array(rows).select do |row|
            row.is_a?(Hash) && !%w[group architecture_group].include?(row['kind'].to_s)
          end
          return [empty_label, [112, 122, 138]] if list.empty?
          editing = list.count { |row| %w[editing error locked].include?(row['status_code'].to_s) }
          pending = list.count { |row| %w[pending waiting syncing disconnected].include?(row['status_code'].to_s) }
          current = list.count { |row| row['status_code'].to_s == 'current' }
          latest = list.map { |row| row['last_update'].to_s }.reject(&:empty?).max.to_s
          time_label = latest.length >= 16 ? latest[11, 5] : ''
          if editing.positive?
            text = "#{editing} 修改中"
            text += " · #{pending} 待更新" if pending.positive?
            [text, [205, 78, 82]]
          elsif pending.positive?
            ["#{pending} 待更新 · #{current} 已更新", [230, 145, 38]]
          else
            text = "#{current}/#{list.length} 已更新"
            text += " · #{time_label}" unless time_label.empty?
            [text, [35, 174, 102]]
          end
        rescue StandardError
          [empty_label, [112, 122, 138]]
        end

        def draw_professional_section_header(view, x, width, y, key, title, rows, hidden, expanded, current_workspace, empty_label)
          summary, rgb = professional_section_summary(rows, empty_label)
          discipline_rgb = professional_discipline_color(key)
          base_tint = if current_workspace
                        discipline_rgb.map { |value| (value * (expanded ? 0.47 : 0.40)).round }
                      else
                        discipline_rgb.map { |value| (value * (expanded ? 0.34 : 0.29)).round }
                      end
          header_height = 40.0
          draw_glass_card(view, [x + 10.0, y, width - 20.0, header_height], 17, tint: base_tint)
          draw_round_rect(view, x + 12.0, y + 6.0, 3.0, header_height - 12.0, 1.5, rgba(discipline_rgb[0], discipline_rgb[1], discipline_rgb[2], 244))
          draw_text_safe(view, x + 22.0, y + 2.0, title, rgba(250, 252, 255, 250), size: 10, bold: true)
          summary = summary[0, 22] + '…' if summary.length > 23
          draw_text_safe(view, x + 22.0, y + 18.0, summary, rgba(198, 211, 231, 218), size: 7, bold: false)
          eye_action = key == 'architecture' ? 'drawer_toggle_architecture_visibility_header' : 'drawer_toggle_space_visibility_header'
          draw_eye_control(view, eye_action, !hidden, [47, 126, 177])
          arrow_action = "drawer_toggle_section:#{key}"
          draw_icon_control(view, arrow_action, expanded ? :chevron_down : :chevron_right, current_workspace ? [61, 103, 170] : [67, 77, 94], active: expanded)
        end

        def draw_collection_group_row(view, x, width, row_y, row, architecture: false)
          row_key = "#{row['kind']}:#{row['id']}"
          hovered = @hover_row_key == row_key
          base_group_tint = if row['pseudo']
                              [68, 76, 91]
                            elsif row['visibility_suspended']
                              [43, 61, 92]
                            elsif row['collapsed']
                              hovered ? [50, 86, 142] : [43, 75, 125]
                            else
                              hovered ? [64, 105, 170] : [54, 94, 154]
                            end
          group_tint = group_status_tint(base_group_tint, row)
          group_rect = [x + 10.0, row_y, width - 20.0, DRAWER_GROUP_CARD_HEIGHT]
          draw_glass_card(view, group_rect, 15, tint: group_tint)
          unless row['pseudo']
            draw_group_status_proportional_fill(view, group_rect, row, hovered: hovered, expanded: !row['collapsed'])
            draw_group_status_ratio_bar(view, group_rect, row)
          end
          accent = row['pseudo'] ? [126, 176, 255] : group_status_priority_color(row)
          draw_round_rect(view, x + 11.0, row_y + 5.0, 3.0, DRAWER_GROUP_CARD_HEIGHT - 10.0, 1.5, rgba(accent[0], accent[1], accent[2], row['pseudo'] ? 90 : 236))
          group_icon_size = 14.0
          group_icon_y = row_y + (DRAWER_GROUP_CARD_HEIGHT - group_icon_size) / 2.0
          draw_vector_icon(view, row['pseudo'] ? :menu : :folder, [x + 20.0, group_icon_y, group_icon_size, group_icon_size], rgba(213, 229, 255, 232))
          name = row['name'].to_s
          name = name[0, 10] + '…' if name.length > 11
          draw_text_safe(view, x + 40.0, row_y + 2.0, name, rgba(250, 252, 255, 250), size: 9, bold: true)
          count = row['count'].to_i
          if !row['pseudo'] && count.positive? && count <= 8
            label = row['visibility_suspended'] ? '组隐藏' : (row['collapsed'] ? '已收纳' : '已展开')
            draw_text_safe(view, x + 40.0, row_y + 16.0, label, rgba(201, 216, 239, 214), size: 7, bold: false)
            draw_group_member_status_dots(view, row, x + 76.0, row_y + 22.0)
          else
            noun = architecture ? '建筑' : '空间'
            detail = row['pseudo'] ? "#{count} 个未分组#{noun}" : "#{count} 个#{noun}"
            draw_text_safe(view, x + 40.0, row_y + 16.0, detail, rgba(201, 216, 239, 214), size: 7, bold: false)
          end
          return if row['pseudo']
          prefix = architecture ? 'drawer_architecture_group' : 'drawer_space_group'
          draw_eye_control(view, "#{prefix}_visibility:#{row['id']}", row['visible'] == true, [47, 126, 177])
          draw_icon_control(view, "#{prefix}_toggle:#{row['id']}", row['collapsed'] ? :chevron_right : :chevron_down, [63, 91, 140], active: !row['collapsed'])
        end

        def draw_architecture_model_row(view, x, width, row_y, row)
          hovered = @hover_row_key == "architecture_model:#{row['id']}"
          selected = @architecture_manage_mode && architecture_manage_selected?(row['id'])
          status_tint = case row['status_code'].to_s
                        when 'current' then [36, 126, 91]
                        when 'editing' then [170, 54, 61]
                        when 'pending', 'waiting' then [166, 104, 28]
                        when 'error' then [176, 54, 60]
                        end
          card = drawer_architecture_card_metrics(row, x, row_y, width)
          tint = selected ? [51, 111, 202] : status_tint
          draw_glass_card(view, [card[:x], card[:y], card[:width], card[:height]], card[:grouped] ? 13 : 15, tint: tint)
          if card[:grouped]
            guide_x = x + 16.0
            view.drawing_color = rgba(151, 178, 218, hovered ? 120 : 66)
            view.line_width = 1
            view.draw2d(GL_LINES, [screen_point(guide_x, row_y - 4.0), screen_point(guide_x, card[:y] + card[:height] / 2.0), screen_point(guide_x, card[:y] + card[:height] / 2.0), screen_point(card[:x] - 3.0, card[:y] + card[:height] / 2.0)])
          end
          rgb = drawer_status_color(row)
          if @architecture_manage_mode
            box_x = card[:x] + 9.0
            box_y = card[:y] + (card[:height] - 13.0) / 2.0
            box = draw_round_rect(view, box_x, box_y, 13.0, 13.0, 3.0, selected ? rgba(74, 132, 235, 236) : rgba(255, 255, 255, 26))
            view.drawing_color = selected ? rgba(174, 207, 255, 246) : rgba(215, 224, 237, 128)
            view.draw2d(GL_LINE_LOOP, box)
            if selected
              view.line_width = 1.7
              view.draw2d(GL_LINES, [screen_point(box_x + 2.8, box_y + 6.6), screen_point(box_x + 5.5, box_y + 9.2), screen_point(box_x + 5.5, box_y + 9.2), screen_point(box_x + 10.7, box_y + 3.2)])
              view.line_width = 1
            end
            field_x = card[:x] + 29.0
            field_w = [card[:width] - 103.0, 95.0].max
            field_h = [card[:height] - 10.0, 16.0].max
            field = draw_round_rect(view, field_x, card[:y] + 1.0, field_w, field_h, 5.0, rgba(255, 255, 255, 12))
            view.drawing_color = rgba(255, 255, 255, 22)
            view.draw2d(GL_LINE_LOOP, field)
            name = row['name'].to_s
            name = name[0, card[:grouped] ? 15 : 17] + '…' if name.length > (card[:grouped] ? 16 : 18)
            draw_text_safe(view, field_x + 5.0, card[:y] + (card[:grouped] ? 0.8 : 1.2), name, rgba(245, 248, 252, 244), size: card[:grouped] ? 8 : 9, bold: true)
            status = row['status'].to_s
            status = status[0, 16] + '…' if status.length > 17
            draw_text_safe(view, field_x + 1.0, card[:y] + (card[:grouped] ? 14.0 : 16.0), status, rgba(188, 199, 218, 205), size: 7, bold: false)
          else
            dot_size = card[:grouped] ? 6.0 : 7.0
            draw_round_rect(view, card[:dot_x], card[:y] + (card[:height] - dot_size) / 2.0, dot_size, dot_size, dot_size / 2.0, rgba(rgb[0], rgb[1], rgb[2], 242))
            name = row['name'].to_s
            max_name = card[:grouped] ? 19 : 18
            name = name[0, max_name - 1] + '…' if name.length > max_name
            draw_text_safe(view, card[:text_x], card[:y] + (card[:grouped] ? 0.7 : 1.1), name, rgba(245, 248, 252, 244), size: card[:grouped] ? 8 : 9, bold: true)
            status = row['status'].to_s
            status = status[0, 15] + '…' if status.length > 16
            draw_text_safe(view, card[:text_x], card[:y] + (card[:grouped] ? 14.0 : 16.0), status, rgba(188, 199, 218, 205), size: 7, bold: false)
            if hovered
              release = row['release_occupancy_action'].to_s
              draw_icon_control(view, release, :unlock, [188, 78, 66], active: true) unless release.empty?
              resident = row['resident_action'].to_s
              resident_icon = :close
              resident_rgb = [166, 78, 78]
              draw_icon_control(view, resident, resident_icon, resident_rgb, active: row['resident_enabled'] != false) unless resident.empty?
              visibility = row['visibility_action'].to_s
              visibility = "drawer_architecture_model_visibility_disabled:#{row['id']}" if visibility.empty?
              draw_eye_control(view, visibility, row['visible'] == true, [47, 126, 177])
              draw_icon_control(view, row['action'].to_s, drawer_action_icon(row), rgb, active: row['enabled'] != false) unless row['action'].to_s.empty?
            end
          end
        end

        def draw_space_model_row(view, x, width, row_y, row)
          hovered = @hover_row_key == "space:#{row['id']}"
          selected = @space_manage_mode && space_manage_selected?(row['id'])
          publish_warning = row['publish_warning'] == true
          status_tint = case row['status_code'].to_s
                        when 'current' then [36, 126, 91]
                        when 'editing' then [170, 54, 61]
                        when 'pending', 'waiting' then [166, 104, 28]
                        when 'error' then [176, 54, 60]
                        end
          card = drawer_space_card_metrics(row, x, row_y, width)
          tint = if row['linked_space'] == true
                   [43, 126, 211]
                 elsif selected
                   [51, 111, 202]
                 else
                   publish_warning ? [176, 54, 60] : status_tint
                 end
          draw_glass_card(view, [card[:x], card[:y], card[:width], card[:height]], card[:grouped] ? 13 : 15, tint: tint)
          if card[:grouped]
            guide_x = x + 16.0
            view.drawing_color = rgba(151, 178, 218, hovered ? 120 : 66)
            view.line_width = 1
            view.draw2d(GL_LINES, [screen_point(guide_x, row_y - 4.0), screen_point(guide_x, card[:y] + card[:height] / 2.0), screen_point(guide_x, card[:y] + card[:height] / 2.0), screen_point(card[:x] - 3.0, card[:y] + card[:height] / 2.0)])
          end
          rgb = drawer_status_color(row)
          if @space_manage_mode
            box_x = card[:x] + 9.0
            box_y = card[:y] + (card[:height] - 13.0) / 2.0
            box = draw_round_rect(view, box_x, box_y, 13.0, 13.0, 3.0, selected ? rgba(74, 132, 235, 236) : rgba(255, 255, 255, 26))
            view.drawing_color = selected ? rgba(174, 207, 255, 246) : rgba(215, 224, 237, 128)
            view.draw2d(GL_LINE_LOOP, box)
            if selected
              view.line_width = 1.7
              view.draw2d(GL_LINES, [screen_point(box_x + 2.8, box_y + 6.6), screen_point(box_x + 5.5, box_y + 9.2), screen_point(box_x + 5.5, box_y + 9.2), screen_point(box_x + 10.7, box_y + 3.2)])
              view.line_width = 1
            end
            field_x = card[:x] + 29.0
            field_w = [card[:width] - 103.0, 95.0].max
            field_h = [card[:height] - 10.0, 16.0].max
            field = draw_round_rect(view, field_x, card[:y] + 1.0, field_w, field_h, 5.0, rgba(255, 255, 255, 12))
            view.drawing_color = rgba(255, 255, 255, 22)
            view.draw2d(GL_LINE_LOOP, field)
            name = row['name'].to_s
            name = name[0, card[:grouped] ? 15 : 17] + '…' if name.length > (card[:grouped] ? 16 : 18)
            draw_text_safe(view, field_x + 5.0, card[:y] + (card[:grouped] ? 0.8 : 1.2), name, rgba(245, 248, 252, 244), size: card[:grouped] ? 8 : 9, bold: true)
            status = row['status'].to_s
            status = status[0, 16] + '…' if status.length > 17
            draw_text_safe(view, field_x + 1.0, card[:y] + (card[:grouped] ? 14.0 : 16.0), status, rgba(188, 199, 218, 205), size: 7, bold: false)
            draw_icon_control(view, "drawer_space_manage_locate:#{row['id']}", :locate, [47, 126, 177], active: row['loaded'] == true) if hovered
          else
            dot_size = card[:grouped] ? 6.0 : 7.0
            draw_round_rect(view, card[:dot_x], card[:y] + (card[:height] - dot_size) / 2.0, dot_size, dot_size, dot_size / 2.0, rgba(rgb[0], rgb[1], rgb[2], 242))
            name = row['name'].to_s
            max_name = card[:grouped] ? 17 : 18
            name = name[0, max_name - 1] + '…' if name.length > max_name
            draw_text_safe(view, card[:text_x], card[:y] + (card[:grouped] ? 0.7 : 1.1), name, rgba(245, 248, 252, 244), size: card[:grouped] ? 8 : 9, bold: true)
            status = row['status'].to_s
            status = status[0, 15] + '…' if status.length > 16
            color = publish_warning ? rgba(255, 205, 208, 232) : rgba(188, 199, 218, 205)
            draw_text_safe(view, card[:text_x], card[:y] + (card[:grouped] ? 14.0 : 16.0), status, color, size: 7, bold: false)
            if hovered
              release = row['release_occupancy_action'].to_s
              draw_icon_control(view, release, :unlock, [188, 78, 66], active: true) unless release.empty?
              resident = row['resident_action'].to_s
              resident_icon = :close
              resident_rgb = [166, 78, 78]
              draw_icon_control(view, resident, resident_icon, resident_rgb, active: row['resident_enabled'] != false) unless resident.empty?
              visibility = row['visibility_action'].to_s
              visibility = "drawer_space_visibility_disabled:#{row['id']}" if visibility.empty?
              draw_eye_control(view, visibility, row['visible'] == true, [47, 126, 177])
              draw_icon_control(view, row['action'].to_s, drawer_action_icon(row), rgb, active: row['enabled'] != false) unless row['action'].to_s.empty?
            end
          end
        end

        def draw_professional_sections(view, layout, x, width)
          if layout[:architecture_expanded]
            # v0.13.6.29：当前专业不再有折叠/标题按钮，直接以文字说明当前列表语义。
            # v0.13.6.30：当前专业列表标题统一使用高对比白色，专业色只留给顶部标签和状态语义。
            draw_text_safe(view, x + 12.0, layout[:architecture_controls_y].to_f + 7.0, '建筑模型：',
                           rgba(250, 252, 255, 248), size: 10, bold: true)
            draw_icon_control(view, 'drawer_manage_architecture', :manage, [58, 114, 178], active: @architecture_manage_mode)
            draw_icon_control(view, 'drawer_architecture_library', :grid, [105, 72, 174])
            draw_icon_control(view, 'drawer_add_architecture', :plus, [176, 108, 26])
            draw_eye_control(view, 'drawer_toggle_architecture_visibility', @state['drawer_architecture_hidden'] != true, [47, 126, 177])
            visible_architecture = visible_drawer_architecture_models(view)
            if visible_architecture.empty?
              draw_text_safe(view, x + 22.0, layout[:architecture_list_y].to_f + 7.0,
                             @architecture_manage_mode ? '当前没有可管理的建筑模型' : '选择对象后点击“＋”建立第一个建筑模型',
                             rgba(178, 190, 209, 188), size: 8, bold: false)
            else
              visible_architecture.each_with_index do |row, index|
                row_y = layout[:architecture_list_y].to_f + index * DRAWER_ROW_PITCH
                if row['kind'].to_s == 'architecture_group'
                  draw_collection_group_row(view, x, width, row_y, row, architecture: true)
                else
                  draw_architecture_model_row(view, x, width, row_y, row)
                end
              end
            end
            if @architecture_manage_mode
              selected_count = architecture_manage_selected_ids.length
              draw_pill_button(view, 'drawer_architecture_manage_delete_selected', selected_count.positive? ? "删除 #{selected_count}" : '删除', [185, 54, 61], size: 9)
              draw_pill_button(view, 'drawer_architecture_manage_group_selected', selected_count.positive? ? "成组 #{selected_count}" : '成组', [176, 108, 26], size: 9)
              draw_pill_button(view, 'drawer_architecture_manage_done', '完成', [58, 114, 178], size: 9)
            end
            total = architecture_drawer_rows.length
            capacity = visible_architecture_capacity(view)
            if total > capacity && capacity.positive?
              track_y = layout[:architecture_list_y].to_f
              track_h = [layout[:architecture_list_bottom].to_f - track_y - 4.0, 20.0].max
              draw_round_rect(view, x + width - 5.0, track_y, 2.0, track_h, 1.0, rgba(255, 255, 255, 34))
              thumb_h = [track_h * capacity.to_f / total.to_f, 20.0].max
              travel = track_h - thumb_h
              ratio = max_architecture_scroll(view).positive? ? @architecture_scroll_index.to_f / max_architecture_scroll(view).to_f : 0.0
              draw_round_rect(view, x + width - 6.0, track_y + travel * ratio, 4.0, thumb_h, 2.0, rgba(112, 153, 239, 174))
            end
          end

          if layout[:space_expanded]
            # v0.13.6.29：直接显示“硬装空间：/软装空间：”，不再保留旧专业折叠按钮。
            # v0.13.6.30：硬装/软装空间标题改为白色，避免紫色/金色文字在深灰抽屉上对比不足。
            draw_text_safe(view, x + 12.0, layout[:space_controls_y].to_f + 7.0, "#{drawer_space_collection_label}空间：",
                           rgba(250, 252, 255, 248), size: 10, bold: true)
            draw_icon_control(view, 'drawer_manage_spaces', :manage, [58, 114, 178], active: @space_manage_mode)
            draw_icon_control(view, 'drawer_add_space', :plus, [176, 108, 26])
            draw_eye_control(view, 'drawer_toggle_space_visibility', @state['drawer_space_hidden'] != true, [47, 126, 177])
            visible_spaces = visible_drawer_spaces(view)
            if visible_spaces.empty?
              draw_text_safe(view, x + 22.0, layout[:list_y].to_f + 7.0,
                             @space_manage_mode ? "当前没有可管理的#{drawer_space_collection_label}空间" : "选择对象后点击“＋”建立第一个#{drawer_space_collection_label}空间",
                             rgba(178, 190, 209, 188), size: 8, bold: false)
            else
              visible_spaces.each_with_index do |row, index|
                row_y = layout[:list_y].to_f + index * DRAWER_ROW_PITCH
                if row['kind'].to_s == 'group'
                  draw_collection_group_row(view, x, width, row_y, row, architecture: false)
                else
                  draw_space_model_row(view, x, width, row_y, row)
                end
              end
            end
            if @space_dragging && @space_drag_candidate && @space_drag_point
              dx, dy = @space_drag_point
              floating_x = [[dx.to_f - 92.0, x + 12.0].max, x + width - 196.0].min
              floating_y = [[dy.to_f - 18.0, layout[:list_y].to_f].max, layout[:list_bottom].to_f - 40.0].min
              tint = @space_drag_candidate['kind'].to_s == 'group' ? [48, 86, 145] : [64, 117, 212]
              draw_glass_card(view, [floating_x, floating_y, 184.0, 36.0], 16, tint: tint)
              icon = @space_drag_candidate['kind'].to_s == 'group' ? :folder : :menu
              draw_vector_icon(view, icon, [floating_x + 9.0, floating_y + 9.0, 16.0, 16.0], rgba(224, 236, 255, 238))
              label = @space_drag_candidate['label'].to_s
              label = label[0, 18] + '…' if label.length > 19
              draw_text_safe(view, floating_x + 31.0, floating_y + 8.0, label, rgba(255, 255, 255, 248), size: 10, bold: true)
            end
            if @space_manage_mode
              selected_count = space_manage_selected_ids.length
              draw_pill_button(view, 'drawer_space_manage_delete_selected', selected_count.positive? ? "删除 #{selected_count}" : '删除', [185, 54, 61], size: 9)
              draw_pill_button(view, 'drawer_space_manage_group_selected', selected_count.positive? ? "成组 #{selected_count}" : '成组', [176, 108, 26], size: 9)
              draw_pill_button(view, 'drawer_space_manage_done', '完成', [58, 114, 178], size: 9)
            end
            total = drawer_rows.length
            capacity = visible_space_capacity(view)
            if total > capacity && capacity.positive?
              track_y = layout[:list_y].to_f
              track_h = [layout[:list_bottom].to_f - track_y - 4.0, 20.0].max
              draw_round_rect(view, x + width - 5.0, track_y, 2.0, track_h, 1.0, rgba(255, 255, 255, 34))
              thumb_h = [track_h * capacity.to_f / total.to_f, 20.0].max
              travel = track_h - thumb_h
              ratio = max_space_scroll(view).positive? ? @space_scroll_index.to_f / max_space_scroll(view).to_f : 0.0
              draw_round_rect(view, x + width - 6.0, track_y + travel * ratio, 4.0, thumb_h, 2.0, rgba(112, 153, 239, 174))
            end
          end
        end

        def draw_drawer(view)
          x, y, width, height = drawer_rect(view)
          stage = drawer_stage
          unless @drawer_open
            draw_round_rect(view, x + 1.0, y + 3.0, width + 2.0, height, 15.0, rgba(0, 0, 0, 42))
            shell = draw_round_rect(view, x - 5.0, y, width + 5.0, height, 15.0, rgba(28, 34, 45, 158))
            view.drawing_color = rgba(255, 255, 255, 52)
            view.draw2d(GL_LINE_LOOP, shell)
            draw_round_rect(view, x + 5.0, y + 12.0, 18.0, 18.0, 9.0, rgba(66, 122, 238, 205))
            draw_vector_icon(view, :connect, [x + 7.0, y + 14.0, 14.0, 14.0], rgba(255, 255, 255, 244))
            if stage == 'ready'
              %w[architecture hard_finish soft_finish landscape].each_with_index do |key, index|
                item = drawer_items.find { |entry| entry['key'].to_s == key } || drawer_items[index]
                rgb = drawer_status_color(item)
                draw_round_rect(view, x + 10.0, y + 45.0 + index * 18.0, 8.0, 8.0, 4.0, rgba(rgb[0], rgb[1], rgb[2], 232))
              end
            else
              rgb = if stage == 'workspace'
                      [230, 145, 38]
                    elsif @state['drawer_error'].to_s.empty?
                      [67, 126, 235]
                    else
                      [218, 82, 82]
                    end
              draw_round_rect(view, x + 9.0, y + 53.0, 10.0, 10.0, 5.0, rgba(rgb[0], rgb[1], rgb[2], 236))
            end
            draw_text_safe(view, x + 7.5, y + 108.0, '›', rgba(255, 255, 255, 210), size: 12, bold: true)
            return
          end

          if drawer_opening_animation? && @drawer_progress.to_f < DRAWER_CONTENT_REVEAL_PROGRESS
            draw_drawer_opening_shell(view, x, y, width, height)
            return
          end

          layout = drawer_layout(view)
          draw_round_rect(view, x + 2.0, y + 5.0, width + 3.0, height, 22.0, rgba(0, 0, 0, 48))
          shell = draw_round_rect(view, x - 8.0, y, width + 8.0, height, 22.0, rgba(27, 33, 44, 174))
          draw_round_rect(view, x - 5.0, y + 1.0, width + 3.0, 43.0, 21.0, rgba(74, 112, 190, 62))
          view.drawing_color = rgba(255, 255, 255, 58)
          view.draw2d(GL_LINE_LOOP, shell)
          draw_round_rect(view, x + 1.0, y + 20.0, 3.0, height - 40.0, 1.5, rgba(82, 145, 255, 215))

          project_title = @state['drawer_project_label'].to_s
          project_title = '未连接项目' if project_title.empty?
          project_title = project_title[0, 11] + '…' if project_title.length > 12
          draw_text_safe(view, x + 12.0, y + 3.0, project_title, rgba(250, 252, 255, 252), size: 12, bold: true)
          subtitle = case stage
                     when 'connect' then '连接项目后开始协同'
                     when 'workspace' then '项目已连接 · 待选择工作区'
                     else '快速协同操作'
                     end
          draw_text_safe(view, x + 12.0, y + 22.0, subtitle, rgba(210, 219, 235, 210), size: 9, bold: false)
          if stage == 'ready'
            reload_rgb = if @state['drawer_plugin_update_error'].to_s.empty?
                           @state['drawer_plugin_update_available'] == true ? [210, 146, 38] : [72, 81, 98]
                         else
                           [190, 72, 72]
                         end
            draw_icon_control(view, 'drawer_reload_plugin', :refresh, reload_rgb, active: @state['drawer_plugin_update_available'] == true)
          end
          draw_icon_control(view, 'drawer_pin', :pin, @drawer_pinned ? [87, 125, 229] : [72, 81, 98], active: @drawer_pinned)
          draw_icon_control(view, 'drawer_collapse', :collapse, [72, 81, 98])
          version_label = "v#{EXTENSION_VERSION}"
          version_hovered = @hover_action.to_s == 'drawer_copy_version'
          version_rgb = version_hovered ? [76, 119, 197] : [43, 53, 69]
          version_alpha = version_hovered ? 158 : 112
          version_width = 150.0
          version_shell = draw_round_rect(view, x + (width - version_width) / 2.0, y + height - 24.0, version_width, 18.0, 9.0, rgba(version_rgb[0], version_rgb[1], version_rgb[2], version_alpha))
          view.drawing_color = version_hovered ? rgba(255, 255, 255, 126) : rgba(255, 255, 255, 42)
          view.draw2d(GL_LINE_LOOP, version_shell)
          version_text_width = overlay_text_width(view, version_label, size: 8, bold: false)
          draw_text_safe(
            view, x + (width - version_text_width) / 2.0, y + height - 23.0, version_label,
            version_hovered ? rgba(250, 253, 255, 250) : rgba(218, 226, 240, 226), size: 8, bold: false
          )

          if stage == 'connect'
            error = @state['drawer_error'].to_s
            tint = error.empty? ? nil : [132, 73, 77]
            draw_glass_card(view, [x + 14.0, y + 72.0, width - 28.0, 170.0], 24, tint: tint)
            draw_round_rect(view, x + width / 2.0 - 22.0, y + 91.0, 44.0, 44.0, 22.0, rgba(76, 121, 215, 122))
            draw_vector_icon(view, :connect, [x + width / 2.0 - 12.0, y + 101.0, 24.0, 24.0], rgba(255, 255, 255, 244))
            draw_text_safe(view, x + 48.0, y + 139.0, '尚未连接协同项目', rgba(250, 252, 255, 248), size: 12, bold: true)
            message = @state['drawer_message'].to_s
            message = '请连接项目协同.json，或者新建项目' if message.empty?
            draw_text_safe(view, x + 30.0, y + 160.0, message[0, 28], rgba(213, 222, 237, 224), size: 9, bold: false)
            draw_text_safe(view, x + 30.0, y + 237.0, error[0, 32], rgba(255, 179, 183, 220), size: 8, bold: false) unless error.empty?
            draw_pill_button(view, 'drawer_create_project', '新建项目', [58, 119, 225], size: 10)
            draw_pill_button(view, 'drawer_connect_project', '连接 JSON', [55, 142, 117], size: 10)
            return
          elsif stage == 'workspace'
            draw_glass_card(view, [x + 14.0, y + 70.0, width - 28.0, 318.0], 22)
            title = @drawer_workspace_picker ? '切换当前文件的工作区' : '请选择当前文件的工作区'
            hint = @drawer_workspace_picker ? '直接选择即生效，不再弹出二次确认' : '选择后直接进入协同工作面板'
            draw_text_safe(view, x + 47.0, y + 86.0, title, rgba(250, 252, 255, 248), size: 12, bold: true)
            draw_text_safe(view, x + 30.0, y + 107.0, hint, rgba(202, 213, 231, 214), size: 9, bold: false)
            draw_pill_button(view, 'drawer_set_workspace:architecture', '建筑', [61, 121, 224], size: 11)
            draw_pill_button(view, "drawer_set_workspace:#{SPACE_COLLECTION_KEY}", '硬装', [185, 126, 42], size: 11)
            draw_pill_button(view, "drawer_set_workspace:#{SOFT_SPACE_COLLECTION_KEY}", '软装', [139, 91, 218], size: 11)
            draw_pill_button(view, 'drawer_set_workspace:landscape', '景观', [47, 151, 112], size: 11)
            if @drawer_workspace_picker && @state['drawer_workspace_configured'] == true
              draw_pill_button(view, 'drawer_cancel_workspace', '取消切换', [72, 81, 98], size: 9)
            else
              draw_pill_button(view, 'drawer_connect_project', '更换项目', [72, 81, 98], size: 9)
            end
            return
          end

          if @drawer_tools_mode
            draw_drawer_tools(view, x, y, width, height)
            return
          end

          project_rect = workspace_switch_rect(view)
          if project_rect
            px, py, pw, ph = project_rect
            if workspace_switch_expanded?
              workspace_professional_segments(project_rect).each do |segment|
                role = segment[:role]
                label = segment[:label]
                current = segment[:current]
                sx, sy, segment_width, segment_height = segment[:rect]
                rgb = professional_discipline_color(role)
                action = "drawer_set_workspace:#{role}"
                hovered = @hover_action == action
                # v0.13.6.30：当前专业更宽、更大、更粗；其他专业收窄并淡显，但专业名仍保持粗体可读。
                alpha = current ? (hovered ? 240 : 218) : (hovered ? 104 : 34)
                pill = draw_round_rect(view, sx, sy, segment_width, segment_height, segment_height / 2.0,
                                       rgba(rgb[0], rgb[1], rgb[2], alpha))
                view.drawing_color = current ? rgba(255, 255, 255, 178) : (hovered ? rgba(255, 255, 255, 82) : rgba(255, 255, 255, 22))
                view.draw2d(GL_LINE_LOOP, pill)
                status_item = drawer_items.find { |entry| entry['key'].to_s == role.to_s }
                status_rgb = drawer_status_color(status_item)
                dot_size = current ? 6.0 : 5.0
                draw_round_rect(view, sx + 7.0, sy + segment_height / 2.0 - dot_size / 2.0,
                                dot_size, dot_size, dot_size / 2.0,
                                rgba(status_rgb[0], status_rgb[1], status_rgb[2], 246))
                font_size = current ? 11 : 9
                text_color = current ? rgba(255, 255, 255, 255) : rgba(231, 236, 246, hovered ? 222 : 166)
                text_width = label.to_s.length * (font_size + 1.0)
                text_x = sx + [(segment_width - text_width) / 2.0 + 2.0, 16.0].max
                text_y = sy + (segment_height - font_size - 4.0) / 2.0
                draw_text_safe(view, text_x, text_y, label, text_color, size: font_size, bold: true)
              end
            else
              hovered = @hover_action == 'drawer_choose_workspace'
              surface = draw_round_rect(view, px, py, pw, ph, ph / 2.0, rgba(255, 255, 255, hovered ? 42 : 22))
              view.drawing_color = hovered ? rgba(255, 255, 255, 104) : rgba(255, 255, 255, 30)
              view.draw2d(GL_LINE_LOOP, surface)
              context = @state['drawer_context'].to_s.sub('当前工作区 · ', '')
              label = "当前工作区 · #{context}"
              label = label[0, 17] + '…' if label.length > 18
              rgb = professional_discipline_color(@state['host_discipline'].to_s)
              draw_round_rect(view, px + 9.0, py + 8.0, 14.0, 14.0, 7.0, rgba(rgb[0], rgb[1], rgb[2], 220))
              draw_text_safe(view, px + 31.0, py + 4.0, label, rgba(235, 240, 249, 238), size: 10, bold: false)
              draw_vector_icon(view, :switch, [px + pw - 26.0, py + 7.0, 16.0, 16.0], rgba(185, 205, 245, 224))
            end
          end

          global_icon_buttons = if @state['drawer_project_connected'] == true
                                  [
                                    ['drawer_connect_project', :connect],
                                    ['drawer_tools', :manage],
                                    ['drawer_refresh_status', :shield],
                                    ['drawer_project_settings', :settings]
                                  ]
                                else
                                  [
                                    ['drawer_create_project', :folder_plus],
                                    ['drawer_connect_project', :connect],
                                    ['drawer_tools', :manage],
                                    ['drawer_refresh_status', :shield],
                                    ['drawer_project_settings', :settings]
                                  ]
                                end
          global_icon_buttons.each_with_index do |(action, icon), index|
            rgb = if action == 'drawer_tools' && @drawer_tools_mode
                    [58, 114, 178]
                  elsif action == 'drawer_refresh_status'
                    [89, 107, 139]
                  else
                    [67, 77, 94]
                  end
            draw_icon_control(view, action, icon, rgb, active: action == 'drawer_tools' && @drawer_tools_mode)
          end

          draw_professional_sections(view, layout, x, width)

          if layout[:landscape_current]
            landscape = drawer_items.find { |item| item['key'].to_s == 'landscape' } || drawer_items.last || {}
            landscape_rgb = drawer_status_color(landscape)
            ly = layout[:landscape_y]
            draw_glass_card(view, [x + 10.0, ly, width - 20.0, 58.0], 20)
            draw_round_rect(view, x + 20.0, ly + 15.0, 8.0, 8.0, 4.0, rgba(landscape_rgb[0], landscape_rgb[1], landscape_rgb[2], 242))
            draw_text_safe(view, x + 36.0, ly + 3.0, '景观', rgba(248, 250, 254, 248), size: 11, bold: true)
            draw_text_safe(view, x + 36.0, ly + 27.0, landscape['status'].to_s, rgba(198, 208, 224, 218), size: 9, bold: false)
            draw_icon_control(view, landscape['action'].to_s, drawer_action_icon(landscape), landscape_rgb, active: landscape['enabled'] != false)
            landscape_eye_action = landscape['visibility_action'].to_s
            landscape_eye_action = 'drawer_landscape_visibility_disabled' if landscape_eye_action.empty?
            draw_eye_control(view, landscape_eye_action, landscape['visible'] == true)
          end
        end

        def draw_toolbar_mode_switch(view, _button, rect, hovered: false, pressed: false)
          x, y, width, height = rect
          full = @state['display_mode'].to_s == 'full'
          progress = _button[:directional] == true ? 1.0 : mode_switch_progress
          # v0.13.6.29：代/真改为方向性双按钮。左=代理、右=真模型，始终可直接点击目标状态。
          if _button[:directional] != true && (progress < 0.48 || width < BUTTON_SIZE * 1.42)
            icon = full ? :cube_solid : :cube_outline
            icon_color = rgba(255, 255, 255, pressed ? 255 : (hovered ? 252 : 238))
            padding = 6.0
            draw_vector_icon(view, icon, [x + padding, y + padding, width - padding * 2.0, height - padding * 2.0], icon_color)
            return
          end

          half = width / 2.0
          active_x = full ? x + half : x
          active_alpha = pressed ? 252 : (hovered ? 238 : 218)
          draw_round_rect(view, active_x + 2.0, y + 2.0, half - 4.0, height - 4.0, (height - 4.0) / 2.0, rgba(132, 88, 221, active_alpha))
          fade = [[(progress - 0.38) / 0.62, 0.0].max, 1.0].min
          inactive = rgba(223, 228, 240, (146 + 30 * fade).round)
          selected = rgba(255, 255, 255, (226 + 26 * fade).round)
          icon_padding = 6.0
          draw_vector_icon(view, :cube_outline, [x + icon_padding, y + icon_padding, half - icon_padding * 2.0, height - icon_padding * 2.0], full ? inactive : selected)
          draw_vector_icon(view, :cube_solid, [x + half + icon_padding, y + icon_padding, half - icon_padding * 2.0, height - icon_padding * 2.0], full ? selected : inactive)
          divider_x = x + half
          view.drawing_color = rgba(255, 255, 255, (28 * fade).round)
          view.draw2d(GL_LINES, [screen_point(divider_x, y + 7.0), screen_point(divider_x, y + height - 7.0)])
        rescue StandardError
          nil
        end

        def draw_toolbar_discipline_refresh(view, button, rect, enabled: true)
          x, y, width, height = rect
          icon_color = enabled ? rgba(255, 255, 255, 246) : rgba(225, 231, 241, 88)
          icon = button[:icon] || :refresh
          draw_vector_icon(view, icon, [x + 4.0, y + 4.0, width - 11.0, height - 11.0], icon_color)
          badge_size = 11.0
          badge_x = x + width - badge_size - 2.0
          badge_y = y + height - badge_size - 2.0
          draw_round_rect(view, badge_x, badge_y, badge_size, badge_size, badge_size / 2.0, rgba(27, 30, 38, enabled ? 224 : 92))
          draw_vector_icon(view, :refresh, [badge_x + 1.7, badge_y + 1.7, badge_size - 3.4, badge_size - 3.4], icon_color)
        rescue StandardError
          draw_vector_icon(view, :refresh, [x + 6.0, y + 6.0, width - 12.0, height - 12.0], icon_color)
        end

        def draw_toolbar(view)
          layout = toolbar_layout(view)
          layout[:groups].each do |group|
            # context 自己绘制文字卡；component_update 是完全独立的圆形提醒按钮，
            # 都不再额外套顶部组胶囊外壳。
            next if [:context, :component_update].include?(group[:name])
            gx, gy, gw, gh = group[:rect]
            radius = [gh / 2.0, 18.0].min
            draw_round_rect(view, gx + 1.0, gy + 2.0, gw, gh, radius, rgba(0, 0, 0, 40))
            shell = draw_round_rect(view, gx, gy, gw, gh, radius, rgba(28, 31, 38, 150))
            view.drawing_color = rgba(255, 255, 255, 38)
            view.draw2d(GL_LINE_LOOP, shell)
          end

          layout[:buttons].each do |entry|
            button = entry[:button]
            x, y, width, height = entry[:rect]
            next if width.to_f < 1.5
            library_member = button[:group] == :library && library_group_expandable?
            library_progress = library_group_progress
            refresh_member = button[:group] == :aux && refresh_group_expandable?
            refresh_progress = refresh_group_progress
            collapsed_refresh = refresh_member && entry[:group_index].to_i.zero? && refresh_progress < 0.56
            collapsed_group_enabled = Array(@state['quick_aux_buttons']).any? { |item| item.is_a?(Hash) && item['enabled'] != false }
            effective_enabled = collapsed_refresh ? collapsed_group_enabled : button[:enabled] != false
            directional_mode = button[:kind] == :mode_switch && button[:directional] == true
            hovered = directional_mode ? %w[representation_proxy representation_full].include?(@hover_action.to_s) : (@hover_action == button[:action])
            pressed = directional_mode ? %w[representation_proxy representation_full].include?(@pressed_action.to_s) : (@pressed_action == button[:action])
            if button[:kind] == :context_label
              label = button[:label].to_s
              card = draw_round_rect(view, x, y, width, height, height / 2.0, rgba(28, 31, 38, 118))
              view.drawing_color = rgba(255, 255, 255, 28)
              view.draw2d(GL_LINE_LOOP, card)
              draw_text_safe(view, x + 7.0, y + 4.0, label, rgba(242, 245, 250, 238), size: 11, bold: true)
              next
            end
            rgb = collapsed_refresh ? [61, 64, 73] : button[:color]
            alpha = if !effective_enabled
                      62
                    elsif pressed
                      252
                    elsif hovered
                      232
                    elsif button[:active]
                      205
                    else
                      135
                    end
            if library_member && entry[:group_index].to_i.positive?
              alpha = (alpha * library_progress).round
            elsif refresh_member && entry[:group_index].to_i.positive?
              alpha = (alpha * refresh_progress).round
            end
            shift = pressed ? 1.0 : 0.0
            button_points = draw_round_rect(view, x, y + shift, width, height, height / 2.0, rgba(rgb[0], rgb[1], rgb[2], alpha))
            view.drawing_color = hovered ? rgba(255, 255, 255, 150) : rgba(255, 255, 255, 36)
            view.draw2d(GL_LINE_LOOP, button_points)
            if button[:kind] == :publish_queue
              icon_color = rgba(255, 255, 255, 246)
              draw_vector_icon(view, :history, [x + 6.0, y + 6.0 + shift, width - 12.0, height - 12.0], icon_color)
              count = publish_queue_active_count
              badge_text = count > 99 ? '99+' : count.to_s
              badge_w = count > 9 ? 16.0 : 13.0
              badge_x = x + width - badge_w + 2.0
              badge_y = y - 2.0 + shift
              draw_round_rect(view, badge_x, badge_y, badge_w, 13.0, 6.5, rgba(count.positive? ? 94 : 72, count.positive? ? 116 : 78, count.positive? ? 210 : 88, 245))
              draw_text_safe(view, badge_x + (count > 9 ? 2.0 : 3.5), badge_y + 1.0, badge_text, rgba(255,255,255,250), size: 7, bold: true)
            elsif button[:kind] == :mode_switch
              draw_toolbar_mode_switch(view, button, [x, y + shift, width, height], hovered: hovered, pressed: pressed)
            elsif button[:kind] == :discipline_refresh
              if collapsed_refresh
                icon_color = effective_enabled ? rgba(255, 255, 255, 246) : rgba(225, 231, 241, 88)
                draw_vector_icon(view, :refresh, [x + 6.0, y + 6.0 + shift, width - 12.0, height - 12.0], icon_color)
              else
                draw_toolbar_discipline_refresh(view, button, [x, y + shift, width, height], enabled: button[:enabled] != false)
              end
            elsif button[:action] == 'references'
              draw_eye(view, x, y + shift, @state['references_visible'] == true, button[:enabled] == false ? rgba(225, 231, 241, 88) : rgba(255, 255, 255, 246))
            elsif button[:icon]
              icon_color = button[:enabled] == false ? rgba(225, 231, 241, 88) : rgba(255, 255, 255, 246)
              draw_vector_icon(view, button[:icon], [x + 6.0, y + 6.0 + shift, width - 12.0, height - 12.0], icon_color)
            else
              text_color = button[:enabled] == false ? rgba(225, 231, 241, 88) : rgba(255, 255, 255, 250)
              draw_text_safe(view, x + 8.5, y + 3.5 + shift, button[:label], text_color, size: 12, bold: true)
            end
          end
        end

        def invalidate_view
          return unless @model && @model == Sketchup.active_model
          @model.active_view.invalidate
        rescue StandardError
          nil
        end
      end

      # Overlay 没有左键与滚轮事件，因此用 push_tool/pop_tool 建立一个只在
      # 顶部按钮或左抽屉内存在的点击层。离开后立即还原原工具，抽屉外滚轮仍缩放视口。
      class WorkspaceToolbarClickTool
        def initialize(runtime, model, overlay)
          @runtime = runtime
          @model = model
          @overlay = overlay
          @down_action = nil
          @finished = false
          @preserve_drawer_on_deactivate = false
        end

        def activate
          @runtime.workspace_toolbar_click_tool_activated(@model, self)
          @model.active_view.invalidate
          true
        end

        def deactivate(view)
          if @overlay
            @overlay.clear_tool_pointer(view, preserve_drawer: @preserve_drawer_on_deactivate)
          end
          @runtime.workspace_toolbar_click_tool_deactivated(@model, self)
          true
        rescue StandardError
          false
        end

        def onMouseMove(_flags, x, y, view)
          if @overlay && @overlay.space_drag_active?
            @overlay.update_space_drag(x, y, view)
            @overlay.update_tool_pointer(x, y, view, @down_action)
            @preserve_drawer_on_deactivate = @overlay.drawer_contains_point?(x, y, view)
            true
          elsif @overlay && @overlay.contains_point?(x, y, view)
            @overlay.update_tool_pointer(x, y, view, @down_action)
            @preserve_drawer_on_deactivate = @overlay.drawer_contains_point?(x, y, view)
            true
          elsif @down_action
            @overlay.update_tool_pointer(x, y, view, @down_action) if @overlay
            @preserve_drawer_on_deactivate = false
            true
          else
            # 这是带真实屏幕坐标的鼠标移出，先通知 Overlay，再退出点击层。
            # 抽屉只会由这类真实移出触发延迟收纳，不会因按钮点击触发。
            @overlay.update_tool_pointer(x, y, view, nil) if @overlay
            @preserve_drawer_on_deactivate = false
            finish_tool
            false
          end
        rescue StandardError
          finish_tool(preserve_drawer: @preserve_drawer_on_deactivate)
          false
        end

        def onLButtonDown(_flags, x, y, view)
          action = @overlay && @overlay.hit_action(x, y, view)
          drag_candidate = @overlay && @overlay.begin_space_drag_candidate(x, y, view)
          unless action || drag_candidate
            finish_tool
            return false
          end
          @down_action = action
          @preserve_drawer_on_deactivate = @overlay && @overlay.drawer_contains_point?(x, y, view)
          @overlay.update_tool_pointer(x, y, view, @down_action)
          true
        rescue StandardError
          finish_tool(preserve_drawer: @preserve_drawer_on_deactivate)
          false
        end

        def onLButtonUp(_flags, x, y, view)
          inside_drawer = @overlay && @overlay.drawer_contains_point?(x, y, view)
          drag_was_active = @overlay && @overlay.space_dragging?
          drop_payload = @overlay && @overlay.finish_space_drag(x, y, view)
          release_action = @overlay && @overlay.hit_action(x, y, view)
          action = (drop_payload || drag_was_active) ? nil : (release_action == @down_action ? @down_action : nil)
          @down_action = nil
          @preserve_drawer_on_deactivate = !!inside_drawer
          @overlay.update_tool_pointer(x, y, view, nil) if @overlay

          if drop_payload
            # 分组拖放属于抽屉内本地操作，完成后保留点击层；用户可以继续操作，
            # 直到鼠标真的离开抽屉才退出并收纳。
            GavinTools::SULinkHubMultiSpace::Runtime.runtime_start_timer(0.01, false) do
              begin
                @runtime.handle_workspace_space_drop(drop_payload, @model)
                @overlay.update_tool_pointer(x, y, view, nil) if @overlay && !@finished
              rescue StandardError => e
                GavinTools::SULinkHubMultiSpace::Runtime.log_exception('拖动空间卡片失败', e)
                GavinTools::SULinkHubMultiSpace::Runtime.show_status("拖动失败：#{e.message}", 'error')
              end
            end
          elsif drag_was_active
            finish_tool unless inside_drawer
          elsif action
            if @runtime.respond_to?(:workspace_toolbar_immediate_local_action?) && @runtime.workspace_toolbar_immediate_local_action?(action)
              # 抽屉内展开/折叠、组与单空间眼睛、管理、复选等操作完成后，
              # 点击 Tool 保持激活。这样连续点击不会反复 push/pop，也就不会产生
              # 伪 leave，更不会让抽屉自动收回。
              begin
                @runtime.handle_workspace_toolbar_action(action, @model)
              ensure
                @overlay.update_tool_pointer(x, y, view, nil) if @overlay && !@finished
                finish_tool if action == 'drawer_collapse' || !inside_drawer
              end
            else
              preserve = !!inside_drawer
              GavinTools::SULinkHubMultiSpace::Runtime.runtime_start_timer(0.01, false) do
                finish_tool(preserve_drawer: preserve)
                @runtime.handle_workspace_toolbar_action(action, @model)
              end
            end
          else
            finish_tool unless inside_drawer
          end
          true
        rescue StandardError
          finish_tool(preserve_drawer: @preserve_drawer_on_deactivate)
          false
        end

        # 仅当鼠标位于展开抽屉内时，滚轮用于浏览空间列表；返回 false
        # 会把滚轮交还给 SketchUp，继续执行原生视口缩放。
        def onMouseWheel(_flags, delta, x, y, view)
          return true if @overlay && @overlay.scroll_drawer(delta, x, y, view)
          false
        rescue StandardError
          false
        end

        def onCancel(reason, _view)
          # v0.13.6.98：Overlay 点击层也是 push_tool 临时 Tool。旧版 ESC 只会
          # 关闭这个点击层，却不会退出 SketchUp 当前组件编辑层；鼠标仍在工具条/
          # 抽屉上时 Overlay 又会马上 push 回来，于是用户必须狂按 ESC 才偶尔能
          # 抢到原生 SelectionTool。现在把用户 ESC 交给统一的“稳定退一级”事务。
          user_escape = reason.to_i == 0
          @overlay.cancel_space_drag! if @overlay
          finish_tool(preserve_drawer: @preserve_drawer_on_deactivate)
          @runtime.request_workspace_escape_step!(@model, source: 'toolbar_click_tool') if user_escape
          true
        rescue StandardError
          false
        end

        def onSetCursor
          false
        end

        private

        def finish_tool(preserve_drawer: false)
          return true if @finished
          @preserve_drawer_on_deactivate ||= !!preserve_drawer
          @finished = true
          @runtime.release_workspace_toolbar_click_tool(@model, self)
          true
        rescue StandardError
          false
        end
      end
    end

    # v0.13.6.148：联动空间复制的“基点 -> 目标点”改为虚拟预览。
    # 147 在鼠标移动时会真的移动临时副本；下一帧 InputPoint 又会把这个移动中的
    # 副本当成捕捉候选，于是出现“自己吸自己”、点线面乱跳，同时大空间每帧修改
    # transformation 也会触发重算和观察器。148 在第二击之前完全不创建真实副本，
    # 只绘制轻量外包框；目标点确认时才一次性建立实例，因此推断手感更接近原生 Move/Copy。
    class LinkedSpacePlacementTool
      EDGE_INDEXES = [0, 1, 1, 3, 3, 2, 2, 0, 4, 5, 5, 7, 7, 6, 6, 4, 0, 4, 1, 5, 2, 6, 3, 7].freeze
      FACE_INDEXES = [0, 1, 3, 2, 4, 6, 7, 5, 0, 4, 5, 1, 2, 3, 7, 6, 0, 2, 6, 4, 1, 5, 7, 3].freeze

      def initialize(runtime, model, source_entity, original_transformation)
        @runtime = runtime
        @model = model
        @source_entity = source_entity
        @original_transformation = original_transformation
        @phase = :base_point
        @base_input_point = Sketchup::InputPoint.new
        @target_input_point = Sketchup::InputPoint.new
        @base_position = nil
        @preview_transformation = original_transformation
        @last_mouse_xy = nil
        @last_pick_at = 0.0
        @finished = false
      end

      # v0.13.6.158：复制基点/目标点完全服从 SketchUp 原生 InputPoint 推断，
      # 但只接受自由度为 0 的“稳定点”作为最终落点。这样端点、中点、交点、圆心、
      # 参考点等仍按 SU 原生方式捕捉；面内任意点、边上漂移点不会被 LinkHub 接受，
      # 避免大模型里推断来回跳。
      def stable_snap_input_point?(input_point)
        return false unless input_point && input_point.valid?
        if input_point.respond_to?(:degrees_of_freedom)
          return input_point.degrees_of_freedom.to_i == 0
        end
        # 老版本 SketchUp 的兜底：明确顶点仍视为稳定点。
        input_point.respond_to?(:vertex) && !input_point.vertex.nil?
      rescue StandardError
        false
      end

      def stable_snap_hint(input_point, fallback)
        return fallback unless stable_snap_input_point?(input_point)
        tip = input_point.tooltip.to_s
        tip.empty? ? fallback : tip
      rescue StandardError
        fallback
      end

      def activate
        Sketchup.set_status_text('复制空间：请选择基准点（端点/中点/交点/圆心/参考点）。Esc 取消。') rescue nil
        @model.active_view.invalidate
        true
      end

      def onMouseMove(_flags, x, y, view)
        return false unless @source_entity && @source_entity.valid?
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        xy = [x.to_i, y.to_i]
        # 高频鼠标事件的同坐标重复帧不再重复做 InputPoint 推断。
        return true if @last_mouse_xy == xy && (now - @last_pick_at) < 0.008
        @last_mouse_xy = xy
        @last_pick_at = now

        if @phase == :base_point
          @base_input_point.pick(view, x, y)
          view.tooltip = if stable_snap_input_point?(@base_input_point)
                           stable_snap_hint(@base_input_point, '单击选择复制基准点')
                         else
                           '请捕捉端点 / 中点 / 交点 / 圆心 / 参考点'
                         end
        else
          begin
            # 只让 SketchUp 根据“固定基点 + 当前场景”做原生推断；移动阶段模型中并不存在
            # 临时副本，所以不会捕捉到自身，也不会产生每帧 transformation 重算。
            @target_input_point.pick(view, x, y, @base_input_point)
          rescue StandardError
            @target_input_point.pick(view, x, y)
          end
          if stable_snap_input_point?(@target_input_point) && @base_position
            vector = @base_position.vector_to(@target_input_point.position)
            @preview_transformation = Geom::Transformation.translation(vector) * @original_transformation
            view.tooltip = stable_snap_hint(@target_input_point, '单击确定复制位置')
          else
            view.tooltip = '请捕捉端点 / 中点 / 交点 / 圆心 / 参考点'
          end
        end
        view.invalidate
        true
      rescue StandardError => e
        GavinTools::SULinkHubMultiSpace::Runtime.log_exception('更新联动空间复制预览失败', e)
        false
      end

      def onLButtonDown(_flags, x, y, view)
        return false unless @source_entity && @source_entity.valid?
        if @phase == :base_point
          @base_input_point.pick(view, x, y)
          unless stable_snap_input_point?(@base_input_point)
            Sketchup.set_status_text('请捕捉端点、中点、交点、圆心或参考点作为复制基准点。') rescue nil
            view.invalidate
            return false
          end
          @base_position = @base_input_point.position
          @phase = :target_point
          @runtime.linked_space_copy_base_point_selected(@model, nil, @base_position)
          Sketchup.set_status_text('复制空间：请选择目标点（端点/中点/交点/圆心/参考点）。Esc 取消。') rescue nil
          view.invalidate
          return true
        end

        onMouseMove(0, x, y, view)
        unless stable_snap_input_point?(@target_input_point) && @preview_transformation
          Sketchup.set_status_text('请捕捉端点、中点、交点、圆心或参考点作为复制目标点。') rescue nil
          return false
        end
        @runtime.linked_space_copy_initial_placement_finished(@model, nil, @preview_transformation)
        finish_tool
        true
      rescue StandardError => e
        GavinTools::SULinkHubMultiSpace::Runtime.log_exception('放置联动空间失败', e)
        false
      end

      def draw(view)
        return unless @source_entity && @source_entity.valid?
        transformation = @phase == :target_point ? @preview_transformation : @original_transformation
        corners = preview_corners(transformation)
        unless corners.empty?
          view.drawing_color = Sketchup::Color.new(48, 142, 232, 34)
          view.draw(GL_QUADS, FACE_INDEXES.map { |index| corners[index] })
          view.drawing_color = Sketchup::Color.new(73, 169, 255, 220)
          view.line_width = 2
          view.line_stipple = '_'
          view.draw(GL_LINES, EDGE_INDEXES.map { |index| corners[index] })
          view.line_stipple = ''
          view.line_width = 1
        end
        if @phase == :base_point
          @base_input_point.draw(view) if @base_input_point && @base_input_point.valid?
        else
          @base_input_point.draw(view) if @base_input_point && @base_input_point.valid?
          @target_input_point.draw(view) if @target_input_point && @target_input_point.valid?
          if @base_position && @target_input_point && @target_input_point.valid?
            view.drawing_color = Sketchup::Color.new(73, 169, 255, 230)
            view.line_width = 1
            view.line_stipple = '-'
            view.draw(GL_LINES, [@base_position, @target_input_point.position])
            view.line_stipple = ''
          end
        end
      rescue StandardError
        nil
      end

      def getExtents
        bounds = Geom::BoundingBox.new
        transformation = @phase == :target_point ? @preview_transformation : @original_transformation
        preview_corners(transformation).each { |point| bounds.add(point) }
        bounds.empty? ? @model.bounds : bounds
      rescue StandardError
        @model.bounds
      end

      def onCancel(reason, _view)
        @runtime.cancel_linked_space_copy!(@model, reason: '用户取消复制') if reason.to_i == 0
        finish_tool
        true
      rescue StandardError
        false
      end

      def deactivate(view)
        Sketchup.set_status_text('') rescue nil
        view.invalidate if view
        true
      rescue StandardError
        false
      end

      private

      def preview_corners(transformation)
        return [] unless transformation && @source_entity && @source_entity.valid?
        definition = @source_entity.respond_to?(:definition) ? @source_entity.definition : nil
        return [] unless definition && definition.valid?
        bounds = definition.bounds
        (0..7).map { |index| bounds.corner(index).transform(transformation) }
      rescue StandardError
        []
      end

      def finish_tool
        return true if @finished
        @finished = true
        @model.tools.pop_tool
        true
      rescue StandardError
        false
      end
    end

    # v0.13.6.101：连续单击即加入；悬停只绘制预选，不改变模型选择和内容。
    class SoftBatchIngestAddSelectionTool
      EDGE_INDEXES = [0, 1, 1, 3, 3, 2, 2, 0, 4, 5, 5, 7, 7, 6, 6, 4, 0, 4, 1, 5, 2, 6, 3, 7].freeze
      FACE_INDEXES = [0, 1, 3, 2, 4, 6, 7, 5, 0, 4, 5, 1, 2, 3, 7, 6, 0, 2, 6, 4, 1, 5, 7, 3].freeze

      def initialize(runtime, model)
        @runtime = runtime
        @model = model
        @finished = false
        @suspended = false
        @hover_entity = nil
        @corners = []
      end

      def activate
        Sketchup.set_status_text('家具入库：悬停绿色预选，单击立即加入，可连续点选；Esc 退出加选。')
        @runtime.soft_batch_ingest_set_adding(true)
        @model.active_view.invalidate
        true
      end

      def deactivate(view)
        @finished = true
        clear_hover(view)
        Sketchup.set_status_text('')
        @runtime.soft_batch_ingest_add_selection_tool_deactivated(@model, self)
        true
      rescue StandardError
        false
      end

      def clear_hover(view)
        @hover_entity = nil
        @corners = []
        view.tooltip = '' if view
        view.invalidate if view
      end

      def suspend(view)
        @suspended = true
        clear_hover(view)
      end

      def resume(view)
        @suspended = false
        if @finished
          @model.tools.pop_tool
        else
          activate
          clear_hover(view)
        end
      end

      def onMouseLeave(view)
        clear_hover(view)
      end

      def onMouseMove(_flags, x, y, view)
        return false if @finished || @suspended
        entity = @runtime.soft_batch_ingest_pick_entity(@model, view, x, y)
        if entity
          bounds = entity.definition.bounds
          transform = @model.edit_transform * entity.transformation
          @corners = (0..7).map { |i| bounds.corner(i).transform(transform) }
          @hover_entity = entity
          view.tooltip = @runtime.soft_batch_ingest_draft_includes?(entity) ? '已在入库列表中' : '单击加入家具入库'
        else
          clear_hover(view)
        end
        view.invalidate
        true
      rescue StandardError
        clear_hover(view)
        false
      end

      def getExtents
        bounds = Geom::BoundingBox.new
        bounds.add(@corners) unless @corners.empty?
        bounds
      end

      def draw(view)
        return if @finished || @suspended || !view || !@hover_entity || !@hover_entity.valid? || @corners.length != 8
        view.line_stipple = ''
        view.drawing_color = Sketchup::Color.new(55, 158, 94, 36)
        view.draw(GL_QUADS, FACE_INDEXES.map { |i| @corners[i] })
        view.drawing_color = Sketchup::Color.new(46, 156, 85, 205)
        view.line_width = 2
        view.line_stipple = '-'
        view.draw(GL_LINES, EDGE_INDEXES.map { |i| @corners[i] })
      rescue StandardError
        nil
      ensure
        if view
          view.line_stipple = ''
          view.line_width = 1
        end
      end

      def onLButtonDown(_flags, x, y, view)
        return false if @finished || @suspended
        @runtime.soft_batch_ingest_add_entity_from_view(@model, view, x, y)
        onMouseMove(0, x, y, view)
        true
      rescue StandardError => e
        @runtime.soft_batch_ingest_dialog_error(e.message)
        @runtime.show_status("家具加选失败：#{e.message}", 'warning') rescue nil
        false
      end

      def onCancel(_reason, _view)
        finish
        true
      end

      def finish
        return true if @finished
        @finished = true
        clear_hover(@model.active_view)
        # Orbit 等临时工具在顶部时，等待 resume 再弹出自己，不误弹其他工具。
        @model.tools.pop_tool unless @suspended
        true
      end
    end


    end
  end
end
