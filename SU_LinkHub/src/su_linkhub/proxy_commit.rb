# frozen_string_literal: true

# v0.13.6.184: shared submission and guarded world-coordinate capture.
# Loaded with Kernel.load so every runtime generation has fresh methods/state.
module GavinTools
  module SULinkHubMultiSpace
    module Runtime
      class SoftProxyImageQualityError < StandardError; end
      # v0.13.6.192：六个方向全部透明（截图里根本没拍到家具）单独分类，
      # 便于识别“根层远端隔离截图在本机无效”并在本会话内改走近原点隔离。
      class SoftProxyImageBlankError < SoftProxyImageQualityError; end

      def soft_commit_world_context_active?(model = Sketchup.active_model)
        model && (@soft_commit_world_depth || {})[model.object_id].to_i.positive?
      end

      # No timer/yield-to-UI is permitted inside this block. Each native operation
      # must finish/abort BEFORE active_path is restored. Never enter while a
      # single-furniture editing transaction is open.
      def with_soft_commit_world_context(model)
        return yield if model.active_path.nil? || soft_commit_world_context_active?(model)
        raise '当前仍在家具编辑/保存事务中，请先结束本件编辑。' unless soft_visual_proxy_inside_space_generation_allowed?(model)
        path = Array(model.active_path).dup
        selection = model.selection.to_a
        view_state = capture_active_view_state(model)
        @soft_commit_world_depth ||= Hash.new(0)
        @soft_commit_world_depth[model.object_id] += 1
        begin
          with_internal_sync_guard do
            with_soft_selection_refresh_suspended do
              begin
                model.active_path = nil
                raise '无法建立世界坐标提交窗口，未执行本次任务。' unless model.active_path.nil?
                yield
              ensure
                # Do not silently claim success if restoration fails.
                raise '原编辑路径已失效；已停止本次提交，请检查当前模型。' unless path.all? { |node| node && node.valid? }
                model.active_path = path
                unless Array(model.active_path) == path
                  raise '未能恢复原编辑层级；已停止本次提交，请重新进入原空间。'
                end
                restore_active_view_state(view_state, model) if view_state
                model.selection.clear
                selection.each { |node| model.selection.add(node) if node && node.valid? }
              end
            end
          end
        ensure
          @soft_commit_world_depth[model.object_id] -= 1
          @soft_commit_world_depth.delete(model.object_id) if @soft_commit_world_depth[model.object_id].zero?
        end
      end

      # Record intent for both written-source pending and not-yet-written ingest.
      # An explicit selection must never flush unrelated candidates in the space.
      def request_soft_ingest_commit_from_button!(targets, desired, model = Sketchup.active_model, all_in_scope: false)
        job = @soft_ingest_batch_job
        return [] unless job.is_a?(Hash) && job[:model].equal?(model)
        selected = Array(targets).select { |node| node && node.valid? }
        raise '发布/更新期间不能提交家具，请等待本次任务结束。' if publish_critical_section? || publish_post_quiet? || @updating
        guard_soft_individual_edit_representation_switch!(model, desired: desired, targets: selected)
        ids = selected.to_h { |node| [node.object_id, true] }
        matched = []
        Array(job[:queue]).each do |candidate|
          members = soft_pending_ingest_candidate_entities(candidate)
          chosen = all_in_scope ? members : members.select { |node| ids[node.object_id] }
          next if chosen.empty?
          candidate[:explicit_commit] = true
          # One source is written once; display intent remains per-instance.
          candidate[:display_intents] ||= {}
          chosen.each { |node| candidate[:display_intents][node.object_id] = desired.to_s }
          matched.concat(chosen)
        end
        return [] if matched.empty?
        guard_soft_individual_edit_representation_switch!(model, desired: desired, targets: matched)
        raise '发布/更新期间不能提交家具，请等待本次任务结束。' if publish_critical_section? || publish_post_quiet? || @updating
        runtime_start_timer(0.06, false, label: 'soft:explicit_ingest_commit', key: "soft:explicit_ingest_commit:#{model.object_id}") do
          process_soft_tagged_furniture_ingest_job
        end
        show_workspace_floating_notice('已请求提交所选家具 · 写库后更新代理 · 最终显示' + (desired.to_s == 'full' ? '真模型' : '代理'), 'info', duration: 4.0, model: model)
        matched.uniq
      end

      def soft_ingest_commit_display_intents(job)
        job[:commit_display_intents] ||= {}
        candidate = job[:active_candidate]
        job[:commit_display_intents].merge!(candidate[:display_intents] || {}) if candidate.is_a?(Hash)
        job[:commit_display_intents]
      end

      # Called AFTER writing sources, outside native operations. Also used by the
      # in-context, explicitly selected subset of an unfinished ingest batch.
      def enqueue_soft_ingest_proxy_followup!(job, seeds, model)
        intents = job[:commit_display_intents] || {}
        count = defer_soft_visual_proxy_seeds_until_publish!(seeds, model)
        records = soft_pending_proxy_rebuild_records(model)
        ids = Array(seeds).map { |seed| seed[:model_id].to_s }
        relevant = records.select { |record| ids.include?(record[:model_id].to_s) }
        relevant.each do |record|
          entity = record[:entity]
          record[:desired_representation] = intents[entity.object_id] if entity && intents.key?(entity.object_id)
          record[:force_rebuild] = true
        end
        return count if relevant.empty?
        if model.active_path.nil?
          schedule_soft_pending_proxy_exit_batch!(model, delay: 0.20, scope_space_id: job[:space_id].to_s)
        else
          request_immediate_soft_proxy_refresh_for_records!(relevant, model, desired: nil)
        end
        count
      end

      # Inspects PNG content, not file length. Tiny/thin objects are accepted if
      # at least one of six directions contains even one alpha>3 pixel.
      def soft_visual_proxy_image_stats(path)
        width, height, channels, stride, data, offsets = soft_visual_proxy_load_image_rep(path)
        # v0.13.6.192：地毯、柜体等“方盒”家具的正交视图会被家具完全铺满，所有像素
        # alpha=255；SketchUp 的 ImageRep#save_file / write_image 此时会把 PNG 存成 24 位 RGB。
        # 这不是坏图，而是“完全不透明”的合法贴图：按全部可见统计，不再误判失败。
        if channels == 3
          return { pixels: width * height, visible: width * height, max_alpha: 255, opaque_rgb: true }
        end
        raise SoftProxyImageQualityError, '六面代理图像不是 RGBA，已保留当前模型。' unless channels == 4 && offsets[:alpha]
        visible = 0
        max_alpha = 0
        height.times do |y|
          width.times do |x|
            alpha = data.getbyte(y * stride + x * channels + offsets[:alpha]).to_i
            visible += 1 if alpha > 3
            max_alpha = alpha if alpha > max_alpha
          end
        end
        { pixels: width * height, visible: visible, max_alpha: max_alpha }
      end

      def validate_soft_visual_proxy_images!(images, model_name = '')
        stats = SOFT_VISUAL_PROXY_IMAGE_SPECS.keys.map do |name|
          path = images[name].to_s
          raise SoftProxyImageQualityError, "#{model_name} 缺少 #{name} 视图，未替换当前模型。" if path.empty?
          [name, soft_visual_proxy_image_stats(path)]
        end
        summary = stats.map { |name, row| "#{name}=#{row[:visible]}/#{row[:pixels]}" }.join(' ')
        log("[proxy184] 图像验收 #{model_name} #{summary}")
        if stats.all? { |_name, row| row[:visible].zero? }
          raise SoftProxyImageBlankError, "#{model_name} 六个方向全部透明；未覆盖代理、未替换真模型。"
        end
        stats
      end

      def preserve_soft_proxy_quality_diagnostics!(state)
        return '' unless state.is_a?(Hash)
        dir = File.join(TEMP_VISUAL_PROXY_DIR, 'quality_failures', "#{Time.now.strftime('%Y%m%d_%H%M%S')}-#{SecureRandom.hex(3)}")
        FileUtils.mkdir_p(dir)
        Array(state[:plans]).each do |plan|
          [:white_path, :black_path, :final_path].each do |key|
            path = plan[key].to_s
            FileUtils.cp(path, File.join(dir, File.basename(path))) if File.file?(path)
          end
        end
        File.write(File.join(dir, 'diagnostic.json'), JSON.pretty_generate({
          model_id: state[:model_id], model_name: state[:model_name], source_path: state[:source_path],
          source_signature: state[:source_signature], bounds: state[:bounds_values],
          capture_mode: state[:capture_mode], fallback_attempt: state[:quality_retry].to_i
        }))
        log("[proxy184] 空白代理诊断已保留：#{dir}")
        dir
      rescue StandardError => e
        log_exception('保留空白代理诊断失败', e)
        ''
      end

      # One bounded retry: world-coordinate capture, near-origin isolation,
      # dual matte, no capability-cache fast path. Never publish an all-zero PNG.
      def retry_soft_visual_proxy_quality!(state, error)
        preserve_soft_proxy_quality_diagnostics!(state)
        if error.is_a?(SoftProxyImageBlankError) && state[:root_distant_capture_used] == true
          disable_soft_visual_proxy_root_distant_capture!(state[:model_name])
        end
        return false if state[:quality_retry].to_i >= 1
        state[:quality_retry] = 1
        state[:capture_mode] = :dual_matte
        state[:force_near_origin] = true
        state[:capture_index] = 0
        state[:view_index] = 0
        state[:images] = {}
        state[:phase] = :capture
        log("[proxy184] #{state[:model_name]} 图像异常，安全隔离重拍一次：#{error.message}")
        true
      end

      # v0.13.6.192：根层“远端投影隔离”在部分显卡/大模型上六个方向全部拍空（实测
      # 每款首拍 0 像素，靠近原点隔离重拍才成功，单款白耗约 15 秒）。第一次出现远端
      # 全空即在本会话内关闭远端法，后续家具直接走近原点隔离（与重拍完全相同的路径）。
      def soft_visual_proxy_root_distant_capture_disabled?
        @soft_visual_proxy_root_distant_capture_disabled == true
      end

      def disable_soft_visual_proxy_root_distant_capture!(model_name = '')
        return false if soft_visual_proxy_root_distant_capture_disabled?
        @soft_visual_proxy_root_distant_capture_disabled = true
        log("[proxy192] 根层远端隔离截图在本机拍空（#{model_name}），本次会话后续六面代理改用近原点隔离，省去每款一次失败重拍。") rescue nil
        true
      end

      # Pending should not disappear merely because the generated file exists.
      def verify_soft_proxy_requested_display!(candidate, model)
        expected = candidate[:committed_source_signature].to_s
        failed = Array(candidate[:replace_instances]).select do |instance|
          next false unless instance && instance.valid?
          ready = soft_instance_representation_ready?(instance, 'proxy')
          unless expected.empty?
            actual = instance.definition.get_attribute(SOFT_MODEL_DICT, 'proxy_source_signature', '').to_s
            ready &&= actual == expected
          end
          !ready
        end
        return true if failed.empty?
        raise "代理文件已更新，但 #{failed.length} 个目标实例未完成同步；待处理标记保留，请重试。"
      end
    end
  end
end
