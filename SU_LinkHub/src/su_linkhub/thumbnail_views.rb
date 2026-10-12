# frozen_string_literal: true

# v0.13.7.3：软装缩略图“双轴测视图 + 刷新/反转”（随 runtime.rb 一起 Kernel.load，热重载整体刷新）。
#
# 问题：库/清单缩略图来自 SKP 内嵌缩略图，取景角度不可控，常常是背面或侧面；改了组件轴后还要
# 手动“入库/更新/刷新缩略图”多次才对，而且清单、模型库各自缓存，经常不同步。
#
# 方案：
# - 每个库模型用 View#write_image 离屏生成两张对角轴测图：
#     a = 从 +X −Y +Z 看（看到正面、右侧、顶面，SketchUp 默认轴测方向）
#     b = 从 −X +Y +Z 看（看到背面、左侧、顶面）
#   各一张 512px（卡片/清单）和一张 1024px 高清图（Excel 导出、放大查看）。
#   朝向相机的片状组件（always_face_camera）只生成正视图 front（从 −Y 看）。
# - 用户在清单或模型库点“反转”只是切换使用哪一张：把选中视图复制成标准缩略图
#   <id>.png，所有现有读取方（模型库卡片、清单、Excel、缓存）自动同步。选择写入共享的
#   缩略图索引 view_prefs，团队与以后的项目都保持。
# - 入库/更新完成、六面代理完成后自动排队，只在 SketchUp 空闲且位于世界根层时逐张生成；
#   用户点击“刷新/反转”的任务立即执行（必要时临时退出空间，完成后恢复）。
# - 不修改源 SKP；视图图片晚于源 SKP 才算有效，源模型改写后自动回到内嵌缩略图，等待重新生成。

module GavinTools
  module SULinkHubMultiSpace
    module Runtime
      SOFT_THUMBNAIL_VIEW_SIZE = 512
      SOFT_THUMBNAIL_VIEW_HD_SIZE = 1024
      SOFT_THUMBNAIL_VIEW_EYES = {
        'a' => [1.0, -1.0, 1.0],
        'b' => [-1.0, 1.0, 1.0],
        'front' => [0.0, -1.0, 0.0]
      }.freeze
      SOFT_THUMBNAIL_VIEW_LABELS = { 'a' => '正面轴测', 'b' => '反面轴测', 'front' => '正视图' }.freeze
      SOFT_THUMBNAIL_VIEW_IDLE_SECONDS = 1.2

      def soft_thumbnail_view_path(source_path, view, root = soft_library_root, hd: false)
        File.join(soft_library_thumbnail_dir(root), "#{soft_model_id_for_path(source_path)}.view_#{view}#{hd ? '.hd' : ''}.png")
      end

      def soft_thumbnail_view_current?(source_path, view, root = soft_library_root, hd: false)
        file = soft_thumbnail_view_path(source_path, view, root, hd: hd)
        return false unless File.file?(file) && File.size(file).positive? && File.file?(source_path)
        File.mtime(file).to_f >= File.mtime(source_path).to_f
      rescue StandardError
        false
      end

      def soft_thumbnail_view_pref(source_path, root = soft_library_root)
        prefs = read_soft_thumbnail_meta(root)['view_prefs']
        value = prefs.is_a?(Hash) ? prefs[soft_model_id_for_path(source_path)].to_s : ''
        SOFT_THUMBNAIL_VIEW_EYES.key?(value) ? value : ''
      rescue StandardError
        ''
      end

      def write_soft_thumbnail_view_pref!(source_path, view, root = soft_library_root)
        data = read_soft_thumbnail_meta(root)
        data['view_prefs'] = {} unless data['view_prefs'].is_a?(Hash)
        data['view_prefs'][soft_model_id_for_path(source_path)] = view.to_s
        write_soft_thumbnail_meta!(data, root)
      end

      # 当前应显示哪一张：用户选择 > 片状正视图 > a。
      def soft_thumbnail_effective_view(source_path, root = soft_library_root)
        pref = soft_thumbnail_view_pref(source_path, root)
        return pref unless pref.empty?
        soft_thumbnail_view_current?(source_path, 'front', root) ? 'front' : 'a'
      end

      # 有效视图图片存在时复制成标准缩略图 <id>.png。返回是否应用成功。
      def apply_soft_thumbnail_preferred_view!(source_path, root = soft_library_root, thumb_path: nil, record: true)
        view = soft_thumbnail_effective_view(source_path, root)
        return false unless soft_thumbnail_view_current?(source_path, view, root)
        thumb_path ||= soft_model_thumbnail_path(source_path, root)
        image = soft_thumbnail_view_path(source_path, view, root)
        temp = "#{thumb_path}.view-#{Process.pid}-#{SecureRandom.hex(4)}.png"
        FileUtils.cp(image, temp)
        linkhub_mv(temp, thumb_path)
        record_soft_thumbnail!(source_path, thumb_path, root, apply_views: false) if record
        true
      rescue StandardError => e
        log_exception("应用缩略图视图失败：#{source_path}", e)
        false
      ensure
        File.delete(temp) if defined?(temp) && temp && File.file?(temp)
      end

      # Excel 等需要高清图时调用：返回当前视图的 1024px 图，没有则返回空字符串。
      def soft_thumbnail_hd_path(source_path, root = soft_library_root)
        return '' if source_path.to_s.empty?
        view = soft_thumbnail_effective_view(source_path, root)
        soft_thumbnail_view_current?(source_path, view, root, hd: true) ? soft_thumbnail_view_path(source_path, view, root, hd: true) : ''
      rescue StandardError
        ''
      end

      # 组件本身朝向相机，或库包装组件里只有朝向相机的子组件（入库会包一层 wrapper）。
      def soft_definition_face_camera?(definition, depth = 0)
        return false unless definition && definition.valid?
        behavior = definition.behavior rescue nil
        return true if behavior && behavior.respond_to?(:always_face_camera?) && behavior.always_face_camera?
        return false if depth >= 4
        # 只检查“薄包装”（入库 wrapper 通常只有 1 个子实例）；大定义直接判否，避免清单统计时逐实体遍历。
        return false if definition.entities.length > 4
        children = definition.entities.to_a
        instances = children.select { |entity| entity.is_a?(Sketchup::ComponentInstance) || entity.is_a?(Sketchup::Group) }
        return false if instances.empty? || children.any? { |entity| entity.is_a?(Sketchup::Face) }
        instances.all? { |instance| soft_definition_face_camera?(instance.definition, depth + 1) }
      rescue StandardError
        false
      end

      def soft_thumbnail_view_camera(values, view, max_px)
        points = soft_thumbnail_bounds_points(values)
        box = Geom::BoundingBox.new
        points.each { |point| box.add(point) }
        center = box.center
        max_extent = [box.width.to_f, box.height.to_f, box.depth.to_f, 1.0].max
        eye_direction = Geom::Vector3d.new(*SOFT_THUMBNAIL_VIEW_EYES.fetch(view))
        eye_direction.normalize!
        eye = center.offset(eye_direction, max_extent * 4.0 + 100.0)
        forward = eye.vector_to(center)
        forward.normalize!
        up_hint = Geom::Vector3d.new(0.0, 0.0, 1.0)
        right = up_hint.cross(forward)
        right = Geom::Vector3d.new(1.0, 0.0, 0.0) if right.length.to_f < 1.0e-9
        right.normalize!
        screen_up = forward.cross(right)
        screen_up.normalize!
        horizontal = points.map { |point| center.vector_to(point).dot(right).abs }.max.to_f * 2.0
        vertical = points.map { |point| center.vector_to(point).dot(screen_up).abs }.max.to_f * 2.0
        if view == 'front'
          width_px, height_px = soft_visual_proxy_texture_size([horizontal, 0.001].max, [vertical, 0.001].max, max_px)
        else
          width_px = height_px = max_px.to_i
        end
        aspect = width_px.to_f / height_px.to_f
        frame_height = [vertical, horizontal / aspect, 1.0].max * SOFT_LIBRARY_THUMBNAIL_MARGIN
        camera = Sketchup::Camera.new(eye, center, screen_up, false)
        camera.height = frame_height if camera.respond_to?(:height=)
        camera.aspect_ratio = aspect if camera.respond_to?(:aspect_ratio=)
        [camera, width_px, height_px]
      end

      def soft_thumbnail_write_view_image!(view, path, width, height)
        temp = "#{path}.render-#{Process.pid}-#{SecureRandom.hex(4)}.png"
        view.invalidate
        view.refresh if view.respond_to?(:refresh)
        options = { filename: temp, width: width.to_i, height: height.to_i, antialias: true, transparent: false }
        ok = view.write_image(options)
        ok = view.write_image(options) unless ok && File.file?(temp) && File.size(temp).positive?
        raise "缩略图视图未能写出：#{File.basename(path)}" unless ok && File.file?(temp) && File.size(temp).positive?
        FileUtils.mkdir_p(File.dirname(path))
        linkhub_mv(temp, path)
        true
      ensure
        File.delete(temp) if defined?(temp) && temp && File.file?(temp)
      end

      # 只在一个可回滚 operation 内临时放置截图实例；结束时 abort，模型、样式、选择、相机全部恢复。
      def render_soft_thumbnail_view!(model, source_path, view, root = soft_library_root)
        with_soft_commit_world_context(model) do
          render_soft_thumbnail_view_world!(model, source_path, view, root)
        end
      end

      def render_soft_thumbnail_view_world!(model, source_path, view, root)
        definition_ids = model.definitions.to_a.map(&:object_id)
        original_selection = model.selection.to_a
        original_view = capture_active_view_state(model)
        layer_visibility = model.layers.to_a.map { |layer| [layer, layer.visible?] }
        visibility_rows = []
        operation_started = false
        interaction_started = false
        temp_source = nil
        face_camera = false
        begin
          begin_soft_heavy_interaction(:thumbnail_view)
          interaction_started = true
          @soft_thumbnail_rendering = true
          model.start_operation('生成缩略图视图', true, false, false)
          operation_started = true
          model.selection.clear
          # 拷贝到临时路径再载入，保证读到刚写好的源 SKP，而不是项目里同名的旧定义。
          FileUtils.mkdir_p(TEMP_VISUAL_PROXY_DIR)
          temp_source = File.join(TEMP_VISUAL_PROXY_DIR, "thumbview-#{Process.pid}-#{SecureRandom.hex(6)}.skp")
          FileUtils.cp(source_path, temp_source)
          definition = load_definition_compat(model.definitions, temp_source)
          raise '缩略图模型定义载入失败。' unless definition && definition.valid?
          values = soft_definition_bounds_values(definition)
          raise '模型没有可用于缩略图的有效几何。' unless soft_bounds_values_valid?(values)
          face_camera = soft_definition_face_camera?(definition)
          view = 'front' if face_camera
          model.layers.each { |layer| layer.visible = true rescue nil }
          shift = soft_visual_proxy_root_distant_capture_shift(model, values)
          if shift
            insert_transform = Geom::Transformation.translation(shift)
          else
            insert_transform = identity_transformation
            model.entities.to_a.each do |entity|
              next unless entity && entity.valid? && entity.respond_to?(:hidden=)
              visibility_rows << [entity, entity.hidden?]
              entity.hidden = true
            rescue StandardError
              next
            end
          end
          model.entities.add_instance(definition, insert_transform)
          camera, width_px, height_px = soft_thumbnail_view_camera(values, view, SOFT_THUMBNAIL_VIEW_SIZE)
          camera = soft_visual_proxy_shift_camera(camera, shift) if shift
          with_soft_bright_thumbnail_style(model, refresh_view: false) do
            soft_visual_proxy_set_background!(model, Sketchup::Color.new(255, 255, 255))
            active_view = model.active_view
            active_view.camera = camera
            soft_thumbnail_write_view_image!(active_view, soft_thumbnail_view_path(source_path, view, root), width_px, height_px)
            scale = SOFT_THUMBNAIL_VIEW_HD_SIZE.to_f / SOFT_THUMBNAIL_VIEW_SIZE
            active_view.camera = camera
            soft_thumbnail_write_view_image!(
              active_view, soft_thumbnail_view_path(source_path, view, root, hd: true),
              (width_px * scale).round, (height_px * scale).round
            )
          end
        ensure
          visibility_rows.reverse_each do |entity, hidden|
            entity.hidden = hidden if entity && entity.valid?
          rescue StandardError
            nil
          end
          restore_active_view_state(original_view, model) if original_view
          model.abort_operation rescue nil if operation_started
          layer_visibility.each { |layer, visible| layer.visible = visible if layer } rescue nil
          cleanup_soft_thumbnail_definitions!(model, definition_ids) rescue nil
          model.selection.clear rescue nil
          original_selection.each { |entity| model.selection.add(entity) if entity && entity.valid? } rescue nil
          @soft_thumbnail_rendering = false
          end_soft_heavy_interaction(:thumbnail_view) if interaction_started
          File.delete(temp_source) if temp_source && File.file?(temp_source)
        end
        { view: view, face_camera: face_camera }
      end

      # ---------------------------------------------------------------- 队列

      # immediate=true：用户点击触发，立即执行（允许在空间内临时切到世界根）。
      # apply_view：完成后把该视图设为默认；nil 表示保持原选择。
      def enqueue_soft_thumbnail_views!(model_id, reason: '', immediate: false, apply_view: nil, notify: false, force: false)
        id = model_id.to_s.strip
        return false if id.empty?
        @soft_thumbnail_view_queue ||= []
        job = @soft_thumbnail_view_queue.find { |item| item[:id] == id }
        if job
          job[:immediate] ||= immediate
          job[:notify] ||= notify
          job[:force] ||= force
          job[:apply_view] = apply_view unless apply_view.nil?
        else
          job = { id: id, reason: reason.to_s, immediate: immediate, apply_view: apply_view, notify: notify,
                  force: force, done: [], attempts: 0, queued_at: monotonic_time }
          @soft_thumbnail_view_queue << job
        end
        if immediate
          @soft_thumbnail_view_queue.delete(job)
          @soft_thumbnail_view_queue.unshift(job)
        end
        ensure_soft_thumbnail_view_driver!
        true
      rescue StandardError => e
        log_exception('缩略图视图排队失败', e)
        false
      end

      def ensure_soft_thumbnail_view_driver!
        timer = @soft_thumbnail_view_timer
        return true if timer && runtime_timer_registry[timer]
        @soft_thumbnail_view_timer = runtime_start_timer(0.4, true, label: 'library:thumbnail_views', key: 'library:thumbnail_views') do
          process_soft_thumbnail_view_queue_tick!
        end
        true
      end

      def stop_soft_thumbnail_view_driver!
        runtime_stop_timer(@soft_thumbnail_view_timer) if @soft_thumbnail_view_timer
        @soft_thumbnail_view_timer = nil
      end

      def soft_thumbnail_view_item(id)
        item = soft_library_item(id, force: false, include_proxy: false)
        return nil unless item && File.file?(item['path'].to_s)
        target = item['merged_into'].to_s
        unless target.empty?
          merged_target = soft_library_item(target, force: false, include_proxy: false)
          item = merged_target if merged_target && File.file?(merged_target['path'].to_s)
        end
        item
      rescue StandardError
        nil
      end

      def process_soft_thumbnail_view_queue_tick!
        queue = @soft_thumbnail_view_queue ||= []
        if queue.empty?
          stop_soft_thumbnail_view_driver!
          return
        end
        model = Sketchup.active_model
        job = queue.first
        ready, _reason, _retry = soft_visual_proxy_queue_ready?(model, allow_inside_space: job[:immediate] == true)
        return unless ready
        return if !job[:immediate] && runtime_interaction_age(model) < SOFT_THUMBNAIL_VIEW_IDLE_SECONDS
        return if @soft_visual_proxy_upgrade_job && !job[:immediate] && soft_heavy_interaction?

        item = soft_thumbnail_view_item(job[:id])
        unless item
          queue.shift
          return
        end
        root = soft_library_root
        source_path = item['path'].to_s
        job[:views] ||= soft_thumbnail_view_pref(source_path, root) == 'front' ? ['front'] : %w[a b]
        pending = job[:views].reject do |view|
          job[:done].include?(view) || (!job[:force] && soft_thumbnail_view_current?(source_path, view, root) &&
                                        soft_thumbnail_view_current?(source_path, view, root, hd: true))
        end
        unless pending.empty?
          result = render_soft_thumbnail_view!(model, source_path, pending.first, root)
          job[:done] << pending.first
          if result[:face_camera]
            # 片状朝向相机组件：只保留正视图，固定使用 front。
            job[:views] = ['front']
            job[:done] = ['front']
            job[:apply_view] = 'front'
          end
          return
        end

        queue.shift
        view = job[:apply_view].to_s
        write_soft_thumbnail_view_pref!(source_path, view, root) if SOFT_THUMBNAIL_VIEW_EYES.key?(view) && view != soft_thumbnail_view_pref(source_path, root)
        if apply_soft_thumbnail_preferred_view!(source_path, root)
          send_soft_thumbnail_view_update!(item, source_path, root)
          show_status("“#{item['name']}”缩略图已更新为#{SOFT_THUMBNAIL_VIEW_LABELS[soft_thumbnail_effective_view(source_path, root)]}。", 'success') if job[:notify]
        end
      rescue StandardError => e
        log_exception("生成缩略图视图失败：#{job && job[:id]}", e)
        if job
          job[:attempts] = job[:attempts].to_i + 1
          if job[:attempts] >= 2
            queue.delete(job)
            show_status("缩略图视图生成失败：#{e.message}", 'warning') if job[:notify]
          end
        end
      end

      def send_soft_thumbnail_view_update!(item, source_path, root = soft_library_root)
        thumb = soft_model_thumbnail_path(source_path, root)
        url = File.file?(thumb) ? soft_thumbnail_url(thumb) : ''
        view = soft_thumbnail_effective_view(source_path, root)
        ids = [item['id'].to_s]
        # 被“重复模型”合并到本模型的旧模型也一起刷新（清单行可能仍以旧 model_id 为主身份）。
        begin
          Hash(read_soft_library_index(root)['models']).each_value do |record|
            ids << record['model_id'].to_s if record.is_a?(Hash) && record['merged_into'].to_s == item['id'].to_s
          end
        rescue StandardError
          nil
        end
        updates = ids.uniq.reject(&:empty?).map do |id|
          { 'id' => id, 'thumbnail_url' => url, 'thumbnail_path' => thumb, 'thumbnail_ready' => !url.empty?,
            'thumbnail_finished' => true, 'thumbnail_view' => view }
        end
        cache = @soft_library_cache
        if cache.is_a?(Hash) && cache[:by_id].is_a?(Hash) && (cached = cache[:by_id][item['id'].to_s]).is_a?(Hash)
          cached['thumbnail_path'] = thumb
          cached['thumbnail_url'] = url
          cached['thumbnail_ready'] = !url.empty?
          cached['thumbnail_view'] = view
        end
        send_soft_thumbnail_updates(updates)
      end

      # 清单/模型库按钮：action = 'flip' | 'refresh' | 'a' | 'b'
      def handle_soft_thumbnail_view_action(model_id, action)
        item = soft_thumbnail_view_item(model_id)
        raise '找不到这个家具对应的模型库模型，无法切换缩略图。' unless item
        root = soft_library_root
        source_path = item['path'].to_s
        current = soft_thumbnail_effective_view(source_path, root)
        case action.to_s
        when 'refresh'
          enqueue_soft_thumbnail_views!(item['id'], reason: '用户刷新', immediate: true, notify: true, force: true)
          show_status("正在按组件轴重新生成“#{item['name']}”的正反两张轴测图…", 'info')
          return { 'ok' => true, 'queued' => true, 'view' => current }
        when 'flip', 'a', 'b'
          if current == 'front'
            show_status('朝向相机的片状组件只使用正视图，不需要反转。', 'info')
            return { 'ok' => true, 'view' => current }
          end
          target = %w[a b].include?(action.to_s) ? action.to_s : (current == 'a' ? 'b' : 'a')
          if soft_thumbnail_view_current?(source_path, target, root)
            write_soft_thumbnail_view_pref!(source_path, target, root)
            apply_soft_thumbnail_preferred_view!(source_path, root)
            send_soft_thumbnail_view_update!(item, source_path, root)
            show_status("“#{item['name']}”缩略图已切换为#{SOFT_THUMBNAIL_VIEW_LABELS[target]}；模型库与清单同步。", 'success')
            return { 'ok' => true, 'view' => target }
          end
          enqueue_soft_thumbnail_views!(item['id'], reason: '用户反转', immediate: true, apply_view: target, notify: true)
          show_status("正在生成“#{item['name']}”的#{SOFT_THUMBNAIL_VIEW_LABELS[target]}…", 'info')
          { 'ok' => true, 'queued' => true, 'view' => current }
        else
          raise "未知缩略图操作：#{action}"
        end
      end
    end
  end
end
