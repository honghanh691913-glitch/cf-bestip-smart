# frozen_string_literal: true

module GavinTools
  module SULinkHubMultiSpace
    module Runtime
    # v0.13.5.18：代理修复不能再阻塞“提交修改”。
    # 旧版在提交回调里同步生成完整项目清单、逐个 File.stat NAS 模型、再判断每款代理，
    # 即使真正截图放到后台，按钮仍会长时间停在“提交中…”。现在只从已经显示过的清单
    # 快照/空间统计缓存提取轻量种子，代理是否过期、NAS 文件是否存在等检查全部拆到后台逐款执行。
    # v0.13.6.14：全空间六面代理维护必须是“已确认身份集合”，不能在这里顺便
    # 猜历史白盒身份。历史白盒的恢复是另一阶段；只有 model_id 已经稳定回写且
    # 当前模型库源文件可验证存在时，才允许进入代理后台队列。这样一个失联白盒
    # 不会因为普通全空间校对被偷偷送进 definition 载入/替换路径。
    def soft_visual_proxy_seeds_for_space(space_entity, model = Sketchup.active_model)
      return [] unless space_entity && space_entity.valid?
      seen = {}
      soft_instances_for_space(space_entity, model, force: true).each_with_object([]) do |instance, rows|
        next unless instance && instance.valid?
        next if soft_instance_planar_reference?(instance)
        info = soft_instance_metadata(instance)
        model_id = info['model_id'].to_s.strip
        source_path = info['source_path'].to_s.strip

        if soft_legacy_proxy_entity?(instance)
          # 仍是历史白盒时，只有稳定 model_id 能证明它已经完成第一阶段身份恢复。
          next unless soft_stable_model_id?(model_id)
          item = soft_library_item(model_id, force: false, source_path: source_path) rescue nil
          next unless item && File.file?(item['path'].to_s)
          source_path = item['path'].to_s
          info['model_name'] = item['name'].to_s unless item['name'].to_s.empty?
        else
          if soft_stable_model_id?(model_id)
            item = soft_library_item(model_id, force: false, source_path: source_path) rescue nil
            source_path = item['path'].to_s if item && File.file?(item['path'].to_s)
          end
          source_path = auto_relocate(source_path, model) unless source_path.empty?
          next if source_path.empty? || !File.file?(source_path)
        end

        if soft_library_id_ambiguous?(model_id)
          log_soft_proxy_identity_rejection_once(model_id, source_path, '模型库中同一 model_id 对应多个当前模型，需先修复模型库身份')
          next
        end

        key = model_id.empty? ? normalize_soft_library_key(source_path) : model_id
        next if key.to_s.empty? || seen[key]
        seen[key] = true
        rows << {
          model_id: model_id,
          model_name: info['model_name'].to_s,
          source_path: source_path
        }
      end
    rescue StandardError => e
      log_exception('读取当前空间六面代理种子失败', e)
      []
    end

    # 六面代理维护默认只作用于明确范围：当前编辑空间、选择对象或显式传入的 seeds。
    # 不再因为打开/提交总采购清单就遍历其它未编辑空间，避免“修一个空间，整个项目跟着修”。
    def soft_schedule_visual_proxy_seed_rows(model = Sketchup.active_model, scope_space_id: '')
      return [] unless model
      state = load_state(model)
      scope_id = scope_space_id.to_s
      scope_id = state['space_editing_id'].to_s if scope_id.empty?
      unless scope_id.empty?
        space = space_model_record(state, scope_id)
        entity = space ? space_model_entity(space['id'], model) : nil
        return soft_visual_proxy_seeds_for_space(entity, model) if entity && entity.valid?
      end

      # 未处于空间修改时，只接受视口明确选中的受管家具作为维护范围。
      selected = model.selection.to_a.select { |entity| entity.is_a?(Sketchup::ComponentInstance) || entity.is_a?(Sketchup::Group) }
      seen = {}
      selected.each_with_object([]) do |entity, rows|
        next if soft_instance_planar_reference?(entity)
        info = resolved_soft_instance_metadata(entity, model)
        model_id = info['model_id'].to_s
        source_path = info['source_path'].to_s
        next if model_id.empty? && source_path.empty?
        key = model_id.empty? ? normalize_soft_library_key(source_path) : model_id
        next if seen[key]
        seen[key] = true
        rows << {
          model_id: model_id,
          model_name: info['model_name'].to_s,
          source_path: source_path,
          replace_instances: [entity]
        }
      end
    rescue StandardError => e
      log_exception('读取六面代理后台扫描种子失败', e)
      []
    end

    def soft_visual_proxy_build_index_maps(index)
      by_id = {}
      Hash(index['models']).each do |path, record|
        next unless record.is_a?(Hash)
        id = record['model_id'].to_s
        by_id[id] ||= [path.to_s, record] unless id.empty?
      end
      by_id
    rescue StandardError
      {}
    end

    def soft_visual_proxy_candidate_from_seed(seed, job)
      root = job[:root].to_s
      index = job[:index].is_a?(Hash) ? job[:index] : { 'models' => {} }
      by_id = job[:index_by_model_id].is_a?(Hash) ? job[:index_by_model_id] : {}
      model = job[:model] || Sketchup.active_model

      model_id = seed[:model_id].to_s
      source_path = seed[:source_path].to_s
      source_path = auto_relocate(source_path, model) unless source_path.empty?
      record = nil

      if !source_path.empty?
        exact = Hash(index['models'])[normalize_soft_library_key(source_path)]
        record = exact if exact.is_a?(Hash)
      end

      if !record.is_a?(Hash) && !model_id.empty?
        matched = by_id[model_id]
        if matched
          source_path = matched[0].to_s
          record = matched[1]
        end
      end

      unless record.is_a?(Hash)
        recovered = full_soft_library_item_for(
          {
            'model_id' => model_id,
            'source_path' => source_path,
            'model_name' => seed[:model_name].to_s
          },
          model
        )
        if recovered
          model_id = recovered['id'].to_s
          source_path = recovered['path'].to_s
          record = Hash(index['models'])[normalize_soft_library_key(source_path)]
          if !record.is_a?(Hash) && !model_id.empty?
            matched = by_id[model_id]
            record = matched[1] if matched
          end
          record ||= default_soft_model_metadata(source_path) if File.file?(source_path)
        end
      end

      return nil unless record.is_a?(Hash)
      return nil if source_path.to_s.empty? || !File.file?(source_path)
      cached_bounds = soft_library_cached_bounds_values(record.merge('path' => source_path))
      return nil if soft_metadata_planar_reference?(record) || soft_bounds_planar_reference?(cached_bounds)
      model_id = record['model_id'].to_s if model_id.empty?
      effective_record = overlay_authoritative_visual_proxy_metadata(record.dup, model_id, root)
      needs_generation = seed[:force_rebuild] == true || soft_visual_proxy_upgrade_candidate?(effective_record, source_path, root)
      has_authoritative_visual = effective_record['proxy_kind'].to_s == SOFT_VISUAL_PROXY_KIND &&
        File.file?(effective_record['proxy_path'].to_s)
      return nil unless needs_generation || has_authoritative_visual

      {
        model_id: model_id,
        model_name: (record['name'].to_s.empty? ? seed[:model_name].to_s : record['name'].to_s),
        source_path: FastPath.expand(source_path),
        metadata: effective_record,
        reuse_existing: !needs_generation && has_authoritative_visual,
        force_rebuild: seed[:force_rebuild] == true,
        scope_space_id: seed[:scope_space_id].to_s.empty? ? job[:scope_space_id].to_s : seed[:scope_space_id].to_s,
        replace_instances: Array(seed[:replace_instances]).select { |instance| instance && instance.valid? },
        source_definition: (seed[:source_definition] if seed[:source_definition] && seed[:source_definition].valid?),
        legacy_recovery: seed[:legacy_recovery] == true,
        allow_inside_space: seed[:allow_inside_space] == true,
        priority: seed[:priority] == true,
        auto_repair: seed[:auto_repair] == true,
        proxy_task_id: seed[:proxy_task_id].to_s
      }
    rescue StandardError => e
      log_exception("检查六面代理候选失败：#{seed[:model_name] || seed[:model_id]}", e)
      nil
    end

    def soft_visual_proxy_upgrade_job_active?
      !!@soft_visual_proxy_upgrade_job
    end

    def soft_visual_proxy_seed_key(seed)
      return '' unless seed.is_a?(Hash)
      model_id = seed[:model_id].to_s.strip
      return "id:#{model_id}" unless model_id.empty?
      path = seed[:source_path].to_s.strip
      path.empty? ? '' : "path:#{normalize_soft_library_key(path)}"
    rescue StandardError
      ''
    end

    def soft_visual_proxy_pending_task_id_for_seed(seed)
      key = soft_visual_proxy_seed_key(seed)
      return '' if key.empty?
      job = @soft_visual_proxy_upgrade_job
      return '' unless job.is_a?(Hash)
      Array(job[:scan_queue]).each do |row|
        next unless soft_visual_proxy_seed_key(row) == key
        task_id = row[:proxy_task_id].to_s
        return task_id unless task_id.empty?
      end
      Array(job[:queue]).each do |row|
        next unless soft_visual_proxy_seed_key(row) == key
        task_id = row[:proxy_task_id].to_s
        return task_id unless task_id.empty?
      end
      ''
    rescue StandardError
      ''
    end

    def ensure_soft_visual_proxy_seed_task!(seed, model = Sketchup.active_model, detail: '')
      return '' unless seed.is_a?(Hash)
      current = seed[:proxy_task_id].to_s
      unless current.empty?
        snapshot = task_center_job_snapshot(current)
        if snapshot && %w[queued running].include?(snapshot[:status].to_s)
          return current
        end
        # 热重载/旧队列收尾后，seed 可能还记着一个已经不存在或已完成的 task_id。
        # 不能继续把新任务写到这个死 ID 上。
        seed[:proxy_task_id] = ''
        current = ''
      end
      existing = soft_visual_proxy_pending_task_id_for_seed(seed)
      unless existing.empty?
        seed[:proxy_task_id] = existing
        update_task_center_job!(existing, stage: '已合并最新修改', detail: detail.to_s.empty? ? '同款代理任务已在队列中，使用最新模型继续处理' : detail.to_s, status: 'queued')
        sync_task_center_overlay_ui!(model) rescue nil
        return existing
      end
      label = seed[:model_name].to_s.strip
      label = seed[:model_id].to_s.strip if label.empty?
      label = '未命名家具' if label.empty?
      active_job = @soft_visual_proxy_upgrade_job
      ahead = if active_job.is_a?(Hash)
                Array(active_job[:scan_queue]).length + Array(active_job[:queue]).length + (active_job[:active_candidate_state] ? 1 : 0)
              else
                0
              end
      queue_detail = detail.to_s.strip
      queue_detail = "已加入六面代理队列 · 当前排队位置约 #{ahead + 1}" if queue_detail.empty?
      task_id = start_task_center_job!(
        'visual_proxy', label: "六面代理 · #{label}", stage: '已加入队列', progress: 2,
        detail: queue_detail, status: 'queued'
      )
      seed[:proxy_task_id] = task_id unless task_id.to_s.empty?
      sync_task_center_overlay_ui!(model) rescue nil
      task_id.to_s
    rescue StandardError => e
      log_exception('登记六面代理任务中心失败', e)
      ''
    end

    # v0.13.6.94：统一六面代理队列 driver。历史版本在 scan/wait/slice/next 多处直接
    # UI.start_timer，多个入口（退出空间、发布、代理按钮）在同一时刻触发时可能同时挂起
    # 多个 process 回调。Ruby 本身仍是单线程，但回调会连续消费同一个 job，造成“2 个进行中”、
    # 某个 task 停在 2%/8% 而另一个已经继续的假死状态。现在任何时候只保留一个 driver timer。
    def soft_visual_proxy_driver_timer_alive?
      timer_id = @soft_visual_proxy_driver_timer_id
      timer_id && runtime_timer_registry.key?(timer_id)
    rescue StandardError
      false
    end

    def schedule_soft_visual_proxy_driver!(job = @soft_visual_proxy_upgrade_job, delay: 0.05, label: 'soft:visual_proxy_driver')
      return false unless job.is_a?(Hash) && @soft_visual_proxy_upgrade_job.equal?(job)
      return true if soft_visual_proxy_driver_timer_alive?
      token = job[:token].to_s
      timer_id = nil
      timer_id = runtime_start_timer([delay.to_f, 0.01].max, false, label: label) do
        @soft_visual_proxy_driver_timer_id = nil if @soft_visual_proxy_driver_timer_id == timer_id
        current = @soft_visual_proxy_upgrade_job
        next unless current.is_a?(Hash) && current[:token].to_s == token
        current[:last_driver_at] = monotonic_time
        process_soft_visual_proxy_upgrade_job
      end
      @soft_visual_proxy_driver_timer_id = timer_id if timer_id
      job[:driver_scheduled_at] = monotonic_time if timer_id
      ensure_soft_visual_proxy_driver_watchdog!
      !!timer_id
    rescue StandardError => e
      log_exception('挂起六面代理队列 driver 失败', e)
      false
    end

    def ensure_soft_visual_proxy_driver_watchdog!
      existing = @soft_visual_proxy_watchdog_timer_id
      return true if existing && runtime_timer_registry.key?(existing)
      timer_id = nil
      timer_id = runtime_start_timer(SOFT_VISUAL_PROXY_DRIVER_WATCHDOG_INTERVAL, true, label: 'soft:visual_proxy_watchdog') do
        job = @soft_visual_proxy_upgrade_job
        unless job.is_a?(Hash)
          current_id = @soft_visual_proxy_watchdog_timer_id
          @soft_visual_proxy_watchdog_timer_id = nil
          runtime_stop_timer(current_id) if current_id
          next
        end
        reconcile_soft_visual_proxy_task_center!(job[:model] || Sketchup.active_model, job)
        # 正常 driver 每一步都会重新挂一个一次性 timer。只有 timer 真正丢失时 watchdog 才补挂，
        # 不会在截图/写盘 API 尚未返回时并发执行，因为 Ruby 主线程此时无法运行 watchdog。
        unless soft_visual_proxy_driver_timer_alive? || @soft_visual_proxy_driver_processing
          age = monotonic_time - job[:last_driver_at].to_f
          if job[:last_driver_at].to_f <= 0.0 || age >= SOFT_VISUAL_PROXY_DRIVER_STALE_SECONDS
            log("六面代理队列 watchdog 恢复 driver：token=#{job[:token]} / idle=#{format('%.1f', age)}s")
            schedule_soft_visual_proxy_driver!(job, delay: 0.03, label: 'soft:visual_proxy_watchdog_resume')
          end
        end
      end
      @soft_visual_proxy_watchdog_timer_id = timer_id if timer_id
      !!timer_id
    rescue StandardError => e
      log_exception('启动六面代理队列 watchdog 失败', e)
      false
    end

    def stop_soft_visual_proxy_driver_timers!
      driver_id = @soft_visual_proxy_driver_timer_id
      watchdog_id = @soft_visual_proxy_watchdog_timer_id
      @soft_visual_proxy_driver_timer_id = nil
      @soft_visual_proxy_watchdog_timer_id = nil
      runtime_stop_timer(driver_id) if driver_id
      runtime_stop_timer(watchdog_id) if watchdog_id
      true
    rescue StandardError
      false
    end

    # 统一清掉已经没有 seed/candidate/pending 实例引用的 visual_proxy 活动卡片。旧版本发生
    # timer 丢失或同款任务被新任务替代后，2% 的“已加入队列”卡片可能永久留在左上角。
    def reconcile_soft_visual_proxy_task_center!(model = Sketchup.active_model, job = @soft_visual_proxy_upgrade_job)
      referenced = {}
      soft_pending_proxy_rebuild_records(model).each do |record|
        task_id = record[:proxy_task_id].to_s
        referenced[task_id] = true unless task_id.empty?
      end
      if job.is_a?(Hash)
        Array(job[:scan_queue]).each { |row| referenced[row[:proxy_task_id].to_s] = true if row.is_a?(Hash) && !row[:proxy_task_id].to_s.empty? }
        Array(job[:queue]).each { |row| referenced[row[:proxy_task_id].to_s] = true if row.is_a?(Hash) && !row[:proxy_task_id].to_s.empty? }
        state = job[:active_candidate_state]
        referenced[state[:task_id].to_s] = true if state.is_a?(Hash) && !state[:task_id].to_s.empty?
      end
      @task_center_mutex ||= Mutex.new
      @task_center_registry ||= {}
      stale = []
      @task_center_mutex.synchronize do
        @task_center_registry.each_value do |row|
          next unless row[:kind].to_s == 'visual_proxy'
          next unless %w[queued running].include?(row[:status].to_s)
          task_id = row[:task_id].to_s
          next if referenced[task_id]
          age = begin
            stamp = row[:queued_at].to_s
            stamp.empty? ? 0.0 : (Time.now - Time.iso8601(stamp)).to_f
          rescue StandardError
            0.0
          end
          stale << task_id if age >= SOFT_VISUAL_PROXY_TASK_ORPHAN_GRACE_SECONDS
        end
      end
      stale.each do |task_id|
        finish_task_center_job!(task_id, success: false, cancelled: true, stage: '旧代理任务已回收', detail: '该任务已被最新队列状态替代；未修改模型')
      end
      sync_task_center_overlay_ui!(model) rescue nil if stale.any?
      stale.length
    rescue StandardError => e
      log_exception('回收六面代理旧任务卡片失败', e)
      0
    end

    def start_soft_schedule_visual_proxy_upgrade(model = Sketchup.active_model, reason: '清单提交', seeds: nil, scope_space_id: '', replace_instances: nil, foreground_exit_batch: false)
      # v0.13.6.78：允许先登记队列；process 阶段会在单件家具编辑期间自动暂停。
      seeds = Array(seeds)
      seeds = soft_schedule_visual_proxy_seed_rows(model, scope_space_id: scope_space_id) if seeds.empty?
      explicit_instances = Array(replace_instances).select { |instance| instance && instance.valid? }
      unless explicit_instances.empty?
        seeds.each { |seed| seed[:replace_instances] = explicit_instances if seed.is_a?(Hash) && Array(seed[:replace_instances]).empty? }
      end
      seeds.each { |seed| seed[:scope_space_id] = scope_space_id.to_s if seed.is_a?(Hash) && seed[:scope_space_id].to_s.empty? }
      return { queued: 0, total: 0, running: false } if seeds.empty?
      if @soft_visual_proxy_upgrade_job
        seeds.each { |seed| ensure_soft_visual_proxy_seed_task!(seed, model) if seed.is_a?(Hash) }
      else
        seeds.each_with_index do |seed, index|
          ensure_soft_visual_proxy_seed_task!(seed, model, detail: (foreground_exit_batch ? "退出工作空间批处理 · 当前 #{index + 1}/#{seeds.length}" : "已加入代理队列 · 当前排队位置 #{index + 1}/#{seeds.length}")) if seed.is_a?(Hash)
        end
      end

      if @soft_visual_proxy_upgrade_job
        existing = @soft_visual_proxy_upgrade_job
        # v0.13.6.94：完全退出空间后如果已有一个后台代理 job，不能直接 return/等待它自己结束。
        # 把新 pending 合并进同一个 job，并把当前 job 晋升为“退出空间前台串行批处理”。
        # 这是 2% + 8% 两张卡长期并存的主要根因之一。
        if foreground_exit_batch && model && model.active_path.nil? && existing[:model].equal?(model)
          existing[:foreground_exit_batch] = true
          existing[:reason] = reason.to_s unless reason.to_s.empty?
          existing[:scope_space_id] = ''
          Array(existing[:queue]).each do |row|
            next unless row.is_a?(Hash)
            tid = row[:proxy_task_id].to_s
            update_task_center_job!(tid, stage: '已退出工作空间', detail: '恢复为单线程前台串行生成', status: 'queued') unless tid.empty?
          end
        end
        pending = {}
        Array(existing[:scan_queue]).each do |item|
          next unless item.is_a?(Hash)
          key = item[:model_id].to_s.empty? ? item[:source_path].to_s : item[:model_id].to_s
          pending[key] = item unless key.empty?
        end
        Array(existing[:queue]).each do |item|
          next unless item.is_a?(Hash)
          key = item[:model_id].to_s.empty? ? item[:source_path].to_s : item[:model_id].to_s
          pending[key] = item unless key.empty?
        end
        active_by_key = {}
        active_state = existing[:active_candidate_state]
        if active_state.is_a?(Hash) && active_state[:candidate].is_a?(Hash)
          active_item = active_state[:candidate]
          active_key = active_item[:model_id].to_s.empty? ? active_item[:source_path].to_s : active_item[:model_id].to_s
          active_by_key[active_key] = active_item unless active_key.empty?
        end
        added = 0
        seeds.each do |item|
          next unless item.is_a?(Hash)
          key = item[:model_id].to_s.empty? ? item[:source_path].to_s : item[:model_id].to_s
          next if key.empty?
          # 如果这个 seed 就是当前正在执行的同一 task，不要因为“退出空间”再次把它排一遍；
          # 若用户在当前生成过程中又修改了同款，新的 seed 会有不同 task_id，仍允许尾部重建一次。
          if (active = active_by_key[key]) && active[:proxy_task_id].to_s == item[:proxy_task_id].to_s
            active[:replace_instances] = (Array(active[:replace_instances]) + Array(item[:replace_instances])).select { |node| node && node.valid? }.uniq
            # v0.13.6.177：用户可能在任务已经成为 active candidate 之后才点击“代理”。
            # 这时也要把当前 candidate/state 晋升为可在空间内继续的高优先级任务，
            # 不能只合并实例名单后仍卡在“等待退出工作空间”。
            active[:allow_inside_space] = true if item[:allow_inside_space] == true
            active[:priority] = true if item[:priority] == true
            if active_state.is_a?(Hash) && active_state[:candidate].equal?(active)
              active_state[:allow_inside_space] = true if item[:allow_inside_space] == true
            end
            next
          end
          if (queued = pending[key])
            queued[:replace_instances] = (Array(queued[:replace_instances]) + Array(item[:replace_instances])).select { |node| node && node.valid? }.uniq
            if item[:force_rebuild] == true
              queued[:force_rebuild] = true
              queued[:reuse_existing] = false
            end
            queued[:source_definition] = item[:source_definition] if item[:source_definition] && item[:source_definition].valid?
            queued[:source_path] = item[:source_path].to_s unless item[:source_path].to_s.empty?
            queued[:model_name] = item[:model_name].to_s unless item[:model_name].to_s.empty?
            queued[:scope_space_id] = item[:scope_space_id].to_s unless item[:scope_space_id].to_s.empty?
            queued[:allow_inside_space] = true if item[:allow_inside_space] == true
            queued[:priority] = true if item[:priority] == true
            if item[:priority] == true
              if existing[:scan_queue].delete(queued)
                existing[:scan_queue].unshift(queued)
              elsif existing[:queue].delete(queued)
                existing[:queue].unshift(queued)
              end
            end
            next
          end
          # 已经 completed 的同 model_id 不能阻止新的 seed：模型库源 SKP 可能刚刚又被
          # 本次家具编辑写新，必须允许在同一个后台 job 尾部重新扫描/重建一次。
          if item[:priority] == true
            existing[:scan_queue].unshift(item)
          else
            existing[:scan_queue] << item
          end
          pending[key] = item
          added += 1
        end
        existing[:scan_total] = existing[:scan_total].to_i + added
        reconcile_soft_visual_proxy_task_center!(model, existing)
        schedule_soft_visual_proxy_driver!(existing, delay: 0.03, label: 'soft:visual_proxy_merge_resume')
        return { queued: existing[:queue].length, total: existing[:scan_total].to_i, running: true, scanning: true }
      end

      root = soft_library_root
      return { queued: 0, total: 0, running: false } if root.to_s.empty? || !Dir.exist?(root)
      index = read_soft_library_index(root)
      index_base_snapshot = soft_library_index_read_base_snapshot(index, root)
      @soft_visual_proxy_upgrade_job = {
        token: SecureRandom.hex(6), model: model, reason: reason.to_s, root: root,
        scope_space_id: scope_space_id.to_s,
        index: index, index_by_model_id: soft_visual_proxy_build_index_maps(index),
        index_base_snapshot: index_base_snapshot, index_dirty: false,
        scan_queue: seeds.dup, scan_total: seeds.length, scanned: 0,
        queue: [], total: 0, done: 0, success: 0, failed: 0,
        replaced: 0, errors: [], completed: [], legacy_unconverted: [], started_at: monotonic_time,
        last_driver_at: monotonic_time, last_progress_at: monotonic_time, driver_scheduled_at: 0.0,
        foreground_exit_batch: !!foreground_exit_batch
      }
      unless foreground_exit_batch
        show_status("已启动六面代理维护：#{seeds.length} 款，范围=#{scope_space_id.to_s.empty? ? '当前选择' : '当前空间'}。", 'info')
      end
      reconcile_soft_visual_proxy_task_center!(model, @soft_visual_proxy_upgrade_job)
      schedule_soft_visual_proxy_driver!(@soft_visual_proxy_upgrade_job, delay: 0.05, label: 'soft:visual_proxy_scan')
      { queued: 0, total: seeds.length, running: true, scanning: true }
    rescue StandardError => e
      log_exception('启动六面代理升级失败', e)
      { queued: 0, total: 0, running: false, error: e.message.to_s }
    end

    def queue_soft_schedule_visual_proxy_upgrade(model = Sketchup.active_model, reason: '清单提交', seeds: nil, scope_space_id: '', replace_instances: nil)
      queued_seeds = Array(seeds).map { |seed| seed.is_a?(Hash) ? seed.dup : seed }
      queued_seeds.each { |seed| ensure_soft_visual_proxy_seed_task!(seed, model) if seed.is_a?(Hash) }
      sync_task_center_overlay_ui!(model) rescue nil
      runtime_start_timer(0.08, false, label: 'soft:visual_proxy_deferred_start') do
        result = start_soft_schedule_visual_proxy_upgrade(
          model, reason: reason, seeds: queued_seeds, scope_space_id: scope_space_id, replace_instances: replace_instances
        )
        unless result.is_a?(Hash) && result[:running]
          message = result.is_a?(Hash) ? result[:error].to_s : ''
          message = '模型库路径不可用或后台任务未能启动' if message.empty?
          queued_seeds.each do |seed|
            next unless seed.is_a?(Hash)
            mark_soft_pending_proxy_rebuild_failed!(seed[:model_id].to_s, message, model)
            task_id = seed[:proxy_task_id].to_s
            finish_task_center_job!(task_id, success: false, stage: '代理任务未启动', detail: message) unless task_id.empty?
          end
          sync_task_center_overlay_ui!(model) rescue nil
          show_status("六面代理后台队列未能启动：#{message}。已写库家具保持真模型，不会套回旧代理。", 'warning') if reason.to_s.include?('家具编辑完成')
        end
      end
      true
    rescue StandardError => e
      log_exception('排队六面代理后台维护失败', e)
      false
    end

    def soft_visual_proxy_upgrade_busy?(model = Sketchup.active_model)
      individual_edit = soft_individual_edit_session(model)
      return true if individual_edit && %w[editing prompting saving awaiting_proxy_choice].include?(individual_edit[:phase].to_s)
      # v0.13.6.182：入库队列只在“正在写库”阶段让代理队列让路；用户仍在空间内、
      # 入库只是登记等待退出时，代理刷新/自动修复照常进行，两条队列互不锁死。
      publish_critical_section? || publish_post_quiet? || @updating || @single_space_update_job || @space_batch_update_job ||
        @soft_model_batch_job || soft_ingest_batch_processing? || @soft_thumbnail_rendering || soft_schedule_batch_applying? || soft_heavy_interaction?
    rescue StandardError
      true
    end

    def runtime_interaction_age(model = Sketchup.active_model)
      return Float::INFINITY unless model
      last = (@runtime_last_interaction_at || {})[model.object_id].to_f
      return Float::INFINITY if last <= 0.0
      [monotonic_time - last, 0.0].max
    rescue StandardError
      Float::INFINITY
    end

    def runtime_camera_signature(model = Sketchup.active_model)
      view = model && model.respond_to?(:active_view) ? model.active_view : nil
      camera = view && view.respond_to?(:camera) ? view.camera : nil
      return '' unless camera
      values = []
      [camera.eye, camera.target, camera.up].each do |point|
        values.concat([point.x.to_f.round(4), point.y.to_f.round(4), point.z.to_f.round(4)])
      end
      values << (camera.respond_to?(:perspective?) && camera.perspective? ? 1 : 0)
      values << (camera.respond_to?(:fov) ? camera.fov.to_f.round(3) : 0.0)
      values << (camera.respond_to?(:height) ? camera.height.to_f.round(4) : 0.0)
      values.join('|')
    rescue StandardError
      ''
    end

    # 只读取十余个相机数值，不扫描模型、定义或共享盘。首次采样和相机变化后等待
    # 很短的稳定窗口，防止发布候选保存恰好抢在环视/缩放过程中开始。
    def runtime_camera_quiet?(model = Sketchup.active_model, seconds: NATIVE_SPACE_PUBLISH_CAMERA_QUIET_SECONDS)
      return true unless model
      @runtime_camera_quiet_state ||= {}
      key = model.object_id
      signature = runtime_camera_signature(model)
      now = monotonic_time
      record = @runtime_camera_quiet_state[key]
      if !record.is_a?(Hash) || record[:signature].to_s != signature.to_s
        @runtime_camera_quiet_state[key] = { signature: signature.to_s, changed_at: now }
        return false
      end
      (now - record[:changed_at].to_f) >= seconds.to_f
    rescue StandardError
      false
    end

    # v0.13.6.165：用户在家具退出确认中选择“是”时，只更新本次家具，且应保持
    # 当前空间/嵌套层级。当前 SketchUp 仍可安全分片截图：把临时截图源放进当前
    # active_entities，并用 edit_transform 的逆矩阵抵消父层变换；整个临时场景在每个
    # operation 结束时恢复，不再通过 active_path=nil 假装退出空间。
    def soft_visual_proxy_inside_space_generation_allowed?(model = Sketchup.active_model)
      return false unless model && !model.active_path.nil?
      record = soft_individual_edit_session(model)
      return false if record && %w[editing prompting saving awaiting_proxy_choice].include?(record[:phase].to_s)
      _state, space_item, space_entity = current_local_editing_space(nil, model, required: false)
      return false unless space_item && space_entity && space_entity.valid?
      path = Array(model.active_path).select { |node| node && node.valid? }
      !path.empty? && path.first.equal?(space_entity)
    rescue StandardError
      false
    end

    # 返回 [ready, reason, retry_seconds]。与通用 background_work_idle? 不同，这里不会
    # 因每次 SelectionObserver / TransactionObserver 都重新等待 1.5 秒；代理任务一旦开始，
    # 只留 80ms 的交互缝隙，并继续按小切片推进。
    def soft_visual_proxy_queue_ready?(model = Sketchup.active_model, active_candidate: false, allow_inside_space: false)
      # 默认仍要求世界根。只有用户在家具退出确认中明确选择“立即更新代理”时，
      # 且当前系统支持独立 SketchUp 工作进程，才允许在“空间根层级”启动该单款任务。
      # 外部进程负责截图，当前模型只在最终安全瞬间替换这一款实例，不借用当前视口。
      unless model
        return [false, '当前模型不可用', 0.25]
      end
      unless model.active_path.nil?
        allowed_here = allow_inside_space && soft_visual_proxy_inside_space_generation_allowed?(model)
        return [false, '仍在工作空间内，六面代理等待正常退出后生成', 0.25] unless allowed_here
      end
      individual_edit = soft_individual_edit_session(model)
      if individual_edit && %w[editing prompting saving awaiting_proxy_choice].include?(individual_edit[:phase].to_s)
        return [false, '正在编辑家具，代理队列暂时让路', 0.18]
      end
      if soft_visual_proxy_upgrade_busy?(model)
        return [false, '前台有保存/发布/重操作，代理队列暂时让路', 0.18]
      end
      if workspace_toolbar_fast_interaction_active?(model)
        return [false, '正在执行前台工具操作', 0.12]
      end
      required = active_candidate ? SOFT_VISUAL_PROXY_QUEUE_ACTIVE_IDLE_SECONDS : SOFT_VISUAL_PROXY_QUEUE_START_IDLE_SECONDS
      age = runtime_interaction_age(model)
      if age < required
        remaining = [required - age, 0.02].max
        return [false, '前台刚有操作，自适应节流', [remaining, SOFT_VISUAL_PROXY_QUEUE_WAIT_RETRY_SECONDS].min]
      end
      [true, '', 0.0]
    rescue StandardError
      [false, '代理队列等待安全执行窗口', SOFT_VISUAL_PROXY_QUEUE_WAIT_RETRY_SECONDS]
    end

    def soft_visual_proxy_incremental_plans(bounds_values, cache_dir, max_px: SOFT_VISUAL_PROXY_RESOLUTION)
      values = Array(bounds_values).map(&:to_f)
      x0, y0, z0, x1, y1, z1 = values
      center = Geom::Point3d.new((x0 + x1) * 0.5, (y0 + y1) * 0.5, (z0 + z1) * 0.5)
      FileUtils.mkdir_p(cache_dir)
      token = "#{Process.pid}-#{SecureRandom.hex(6)}"
      SOFT_VISUAL_PROXY_VIEW_SPECS.map do |name, spec|
        axis_a, axis_b = spec[:axes]
        dim_a = soft_visual_proxy_axis_dimension(values, axis_a)
        dim_b = soft_visual_proxy_axis_dimension(values, axis_b)
        width_px, height_px = soft_visual_proxy_texture_size(dim_a, dim_b, max_px)
        max_dim = [dim_a, dim_b,
                   soft_visual_proxy_axis_dimension(values, :x),
                   soft_visual_proxy_axis_dimension(values, :y),
                   soft_visual_proxy_axis_dimension(values, :z), 1.0].max
        eye_axis = Geom::Vector3d.new(spec[:eye])
        direction = Geom::Vector3d.new(spec[:dir])
        up = Geom::Vector3d.new(spec[:up])
        eye = center.offset(eye_axis, max_dim * 4.0 + 100.0)
        target = center.offset(direction, 1.0)
        camera = Sketchup::Camera.new(eye, target, up, false)
        camera.height = [dim_b * SOFT_VISUAL_PROXY_PADDING, 0.001].max
        camera.aspect_ratio = width_px.to_f / height_px.to_f
        {
          name: name, camera: camera, width_px: width_px, height_px: height_px,
          white_path: File.join(cache_dir, "#{token}_#{name}_white.png"),
          black_path: File.join(cache_dir, "#{token}_#{name}_black.png"),
          final_path: File.join(cache_dir, "#{token}_#{name}.png")
        }
      end
    end

    def cleanup_soft_visual_proxy_incremental_state!(state)
      return false unless state.is_a?(Hash)
      Array(state[:plans]).each do |plan|
        next unless plan.is_a?(Hash)
        [:white_path, :black_path, :final_path].each do |key|
          path = plan[key].to_s
          File.delete(path) if !path.empty? && File.file?(path)
        rescue StandardError
          nil
        end
      end
      true
    rescue StandardError
      false
    end

    def begin_soft_visual_proxy_incremental_candidate(candidate, job)
      model = job[:model] || Sketchup.active_model
      with_soft_commit_world_context(model) { begin_soft_visual_proxy_incremental_candidate_world(candidate, job) }
    end

    def begin_soft_visual_proxy_incremental_candidate_world(candidate, job)
      model = job[:model] || Sketchup.active_model
      root = job[:root].to_s.empty? ? soft_library_root : job[:root].to_s
      source_path = FastPath.expand(candidate[:source_path].to_s)
      raise '源模型文件不存在，无法生成六面代理。' unless File.file?(source_path)
      raise '当前模型不可用，无法生成六面代理。' unless model
      inside_space = !model.active_path.nil?
      if inside_space
        unless candidate[:allow_inside_space] == true && soft_visual_proxy_inside_space_generation_allowed?(model)
          raise '仍在工作空间内，六面代理等待退出后生成。'
        end
      end
      source_definition = candidate[:source_definition]
      if candidate[:force_rebuild] == true
        fresh_path = File.join(TEMP_VISUAL_PROXY_DIR, "source184-#{Process.pid}-#{SecureRandom.hex(6)}.skp")
        FileUtils.mkdir_p(TEMP_VISUAL_PROXY_DIR)
        before_copy = soft_library_file_signature(source_path, force: true).to_s
        begin
          FileUtils.cp(source_path, fresh_path)
          after_copy = soft_library_file_signature(source_path, force: true).to_s
          raise '截图源在读取期间发生变化，请重新提交。' if before_copy.empty? || before_copy != after_copy
          source_definition = load_definition_compat(model.definitions, fresh_path)
          candidate[:source_definition] = source_definition
          soft_clear_definition_bounds_cache!(source_definition) if source_definition && source_definition.valid?
        ensure
          File.delete(fresh_path) if File.file?(fresh_path)
        end
      end
      unless source_definition && source_definition.valid?
        # 入库结束到用户退出空间之间，原 wrapper 可能已被常规缓存回收。
        # 在真正截图前从已经原子写好的源 SKP 重载，避免把旧 Ruby 引用当作截图源。
        source_definition = load_definition_compat(model.definitions, source_path)
        candidate[:source_definition] = source_definition if source_definition && source_definition.valid?
      end
      return nil unless source_definition && source_definition.valid?
      values = soft_definition_bounds_values(source_definition)
      return nil unless soft_bounds_values_valid?(values)
      return nil if soft_bounds_planar_reference?(values)
      model_id = candidate[:model_id].to_s
      model_name = candidate[:model_name].to_s
      metadata = candidate[:metadata].is_a?(Hash) ? candidate[:metadata].dup : {}
      source_signature = soft_library_file_signature(source_path, force: true).to_s
      target = soft_visual_proxy_target_path(model_id, model_name, metadata, root)
      cache_dir = TEMP_VISUAL_PROXY_DIR
      candidate[:active_started_at] ||= monotonic_time
      {
        candidate: candidate, source_definition: source_definition, bounds_values: values,
        model_id: model_id, model_name: model_name, metadata: metadata,
        source_path: source_path, source_signature: source_signature, target: target,
        plans: soft_visual_proxy_incremental_plans(
          values, cache_dir,
          # v0.13.7.4：自动任务一律 128px（像素量约为 192px 的 44%，截图与抠图都更快）；
          # 只有用户在退出确认里明确选“立即更新”的单款任务保留 192px。
          max_px: ((candidate[:priority] == true && job[:scan_total].to_i <= 1 && job[:total].to_i <= 1) ? SOFT_VISUAL_PROXY_RESOLUTION : SOFT_VISUAL_PROXY_BATCH_RESOLUTION)
        ), images: {},
        view_index: 0, phase: :capture,
        allow_inside_space: candidate[:allow_inside_space] == true,
        started_inside_space: inside_space,
        task_id: candidate[:proxy_task_id].to_s, started_at: monotonic_time
      }
    end

    # v0.13.6.169：根层六面截图优先使用“远端投影隔离”，不再 Ruby 遍历并隐藏所有根实体。
    # 把临时实例沿 X/Y/Z 同时移到当前模型 bounds 之外；六个相机同步平移后，任一主轴
    # 正交投影的另外两轴都与原模型完全分离，因此原模型不会进入截图画框。异常超大坐标
    # 自动返回 nil，调用方回退旧的逐实体隐藏逻辑，避免远离原点造成 SketchUp 精度问题。
    def soft_visual_proxy_root_distant_capture_shift(model, bounds_values)
      values = Array(bounds_values).map(&:to_f)
      return nil unless values.length >= 6 && soft_bounds_values_valid?(values)
      x0, y0, z0, x1, y1, z1 = values
      entities = model.entities rescue nil
      if entities && entities.respond_to?(:length) && entities.length.to_i.zero?
        return Geom::Vector3d.new(0.0, 0.0, 0.0)
      end

      box = model.bounds
      return nil unless box && (!box.respond_to?(:valid?) || box.valid?)
      min_pt = box.min
      max_pt = box.max
      return nil unless min_pt && max_pt
      source_span = [(x1 - x0).abs, (y1 - y0).abs, (z1 - z0).abs, 1.0].max
      model_span = [
        (max_pt.x.to_f - min_pt.x.to_f).abs,
        (max_pt.y.to_f - min_pt.y.to_f).abs,
        (max_pt.z.to_f - min_pt.z.to_f).abs, 1.0
      ].max
      gap = [source_span * 8.0, model_span * 0.05, 1000.0].max
      dx = max_pt.x.to_f - x0 + gap
      dy = max_pt.y.to_f - y0 + gap
      dz = max_pt.z.to_f - z0 + gap

      # 约 25km（SketchUp 内部单位为 inch）以上不使用远端法，宁可退回 O(N) 隔离。
      safe_limit = 1_000_000.0
      shifted = [x0 + dx, y0 + dy, z0 + dz, x1 + dx, y1 + dy, z1 + dz]
      original = [min_pt.x.to_f, min_pt.y.to_f, min_pt.z.to_f, max_pt.x.to_f, max_pt.y.to_f, max_pt.z.to_f]
      return nil if (shifted + original).any? { |value| !value.finite? || value.abs > safe_limit }
      Geom::Vector3d.new(dx, dy, dz)
    rescue StandardError
      nil
    end

    def soft_visual_proxy_shift_camera(camera, shift)
      return camera unless camera && shift
      eye = camera.eye.offset(shift)
      target = camera.target.offset(shift)
      shifted = Sketchup::Camera.new(eye, target, camera.up, camera.respond_to?(:perspective?) && camera.perspective?)
      if shifted.respond_to?(:height=) && camera.respond_to?(:height) && !(camera.respond_to?(:perspective?) && camera.perspective?)
        shifted.height = camera.height
      end
      shifted.aspect_ratio = camera.aspect_ratio if shifted.respond_to?(:aspect_ratio=) && camera.respond_to?(:aspect_ratio)
      shifted.fov = camera.fov if shifted.respond_to?(:fov=) && camera.respond_to?(:fov) && camera.respond_to?(:perspective?) && camera.perspective?
      shifted
    rescue StandardError
      camera
    end

    # v0.13.6.169：六方向仍共用一次临时场景；根层进一步优先使用远端投影隔离，
    # 正常建筑模型不再遍历/隐藏任何根实体。空间内编辑与异常超大坐标自动回退逐实体隔离。
    # 12 次 write_image、192px 双底 alpha、相机朝向与贴图算法完全不变。
    def soft_visual_proxy_capture_plan_batch!(state, model, plans, backgrounds, budget_seconds: nil)
      with_soft_commit_world_context(model) do
        soft_visual_proxy_capture_plan_batch_world!(state, model, plans, backgrounds, budget_seconds: budget_seconds)
      end
    end

    def soft_visual_proxy_capture_plan_batch_world!(state, model, plans, backgrounds, budget_seconds: nil)
      source_definition = state[:source_definition]
      raise '六面代理截图源 Definition 已失效。' unless source_definition && source_definition.valid?
      plans = Array(plans).select { |plan| plan.is_a?(Hash) }
      raise '六面代理截图计划为空。' if plans.empty?
      path = Array(model.active_path).select { |node| node && node.valid? }
      if path.empty?
        capture_entities = model.entities
        insert_transform = identity_transformation
      else
        unless state[:allow_inside_space] == true && soft_visual_proxy_inside_space_generation_allowed?(model)
          raise '当前编辑层级不允许立即生成六面代理；已等待退出空间后的队列。'
        end
        capture_entities = model.active_entities
        begin
          insert_transform = model.edit_transform.inverse
        rescue StandardError
          insert_transform = identity_transformation
        end
      end

      original_selection = model.selection.to_a
      original_view = capture_active_view_state(model)
      layer_visibility = model.layers.to_a.map { |layer| [layer, layer.visible?] }
      visibility_rows = []
      operation_started = false
      interaction_started = false
      root_distant_shift = nil
      root_distant_capture = false
      budget_deadline = budget_seconds.to_f.positive? ? monotonic_time + budget_seconds.to_f : nil
      begin
        begin_soft_heavy_interaction(:visual_proxy_capture_batch)
        interaction_started = true
        model.start_operation("六面代理批量截图 #{state[:model_name]}", true, false, false)
        operation_started = true
        model.selection.clear
        # 先开启全部 Tag，确保待截图 Definition 内部挂在任意 Tag 的可见几何都能参与；
        # 根层远端隔离的 model.bounds 也因此覆盖所有可能被这一步重新显示的场景几何。
        model.layers.each { |layer| layer.visible = true rescue nil }

        # 根层优先不碰现有实体：临时实例移到模型 AABB 三轴之外，相机同移。
        # 若坐标过大/Bounds 无法可靠取得，才回退 v0.13.6.167 的逐根实体隐藏。
        if path.empty?
          unless state[:force_near_origin] || soft_visual_proxy_root_distant_capture_disabled?
            root_distant_shift = soft_visual_proxy_root_distant_capture_shift(model, state[:bounds_values])
          end
          if root_distant_shift
            root_distant_capture = true
            state[:root_distant_capture_used] = true
            insert_transform = Geom::Transformation.translation(root_distant_shift)
          else
            model.entities.to_a.each do |entity|
              next unless entity && entity.valid? && entity.respond_to?(:hidden?) && entity.respond_to?(:hidden=)
              visibility_rows << [entity, entity.hidden?]
              entity.hidden = true
            rescue StandardError
              next
            end
          end
        else
          # 空间内立即模式仍沿 active_path 逐层只保留当前编辑脊柱；这里不能把实例
          # 移出编辑坐标系，否则 edit_transform 与父层裁剪语义会改变，因此继续安全回退。
          container = model.entities
          path.each do |path_node|
            container.to_a.each do |entity|
              next if entity.equal?(path_node)
              next unless entity && entity.valid? && entity.respond_to?(:hidden?) && entity.respond_to?(:hidden=)
              visibility_rows << [entity, entity.hidden?]
              entity.hidden = true
            rescue StandardError
              next
            end
            container = if path_node.respond_to?(:definition) && path_node.definition && path_node.definition.valid?
                          path_node.definition.entities
                        elsif path_node.respond_to?(:entities)
                          path_node.entities
                        else
                          nil
                        end
            break unless container
          end
          capture_entities.to_a.each do |entity|
            next unless entity && entity.valid? && entity.respond_to?(:hidden?) && entity.respond_to?(:hidden=)
            visibility_rows << [entity, entity.hidden?]
            entity.hidden = true
          rescue StandardError
            next
          end
        end

        source_instance = capture_entities.add_instance(source_definition, insert_transform)
        source_instance.hidden = false if source_instance.respond_to?(:hidden=)
        capture_plans = if root_distant_capture
                          plans.map { |plan| plan.merge(camera: soft_visual_proxy_shift_camera(plan[:camera], root_distant_shift)) }
                        else
                          plans
                        end
        with_soft_bright_thumbnail_style(model, refresh_view: false) do
          view = model.active_view
          modes = Array(backgrounds)
          if modes == [:adaptive_alpha]
            # v0.13.6.182：六个方向不再强制在同一个主线程片段内拍完。从 state[:capture_index]
            # 继续，每拍完一个方向检查一次时间预算；超预算就返回，下一 tick 重建临时场景
            # 继续拍剩余方向。根层用远端隔离，重建场景几乎零成本；空间内立即模式虽多几次
            # 隐藏/恢复，但每片主线程占用被压到 ~0.1–0.4s，视口不再出现 11–14s 卡死。
            index = state[:capture_index].to_i
            white_color = Sketchup::Color.new(255, 255, 255)
            black_color = Sketchup::Color.new(0, 0, 0)
            current_background = nil
            while index < capture_plans.length
              plan = capture_plans[index]
              mode = state[:capture_mode]
              mode = nil unless %i[native_alpha dual_matte].include?(mode)
              if mode.nil?
                capability = soft_visual_proxy_native_alpha_capability
                if capability == :good
                  mode = :native_alpha
                elsif capability == :bad
                  mode = :dual_matte
                else
                  # 首次只多拍 1 张透明图：当前方向 transparent + white + black 自检。
                  # 通过后其余方向直接透明截图；失败则其余方向走双底，后续本会话固定走已验证模式。
                  view.camera = plan[:camera]
                  soft_visual_proxy_write_transparent!(view, plan[:final_path], plan[:width_px], plan[:height_px])
                  soft_visual_proxy_set_background!(model, white_color)
                  view.camera = plan[:camera]
                  soft_visual_proxy_write_opaque!(view, plan[:white_path], plan[:width_px], plan[:height_px])
                  soft_visual_proxy_set_background!(model, black_color)
                  current_background = :black
                  view.camera = plan[:camera]
                  soft_visual_proxy_write_opaque!(view, plan[:black_path], plan[:width_px], plan[:height_px])
                  alpha_verdict = soft_visual_proxy_native_alpha_verdict(plan[:final_path], plan[:white_path], plan[:black_path])
                  if alpha_verdict == :good
                    remember_soft_visual_proxy_native_alpha_capability!(:good)
                    File.delete(plan[:white_path]) if File.file?(plan[:white_path])
                    File.delete(plan[:black_path]) if File.file?(plan[:black_path])
                    mode = :native_alpha
                  else
                    remember_soft_visual_proxy_native_alpha_capability!(alpha_verdict)
                    File.delete(plan[:final_path]) if File.file?(plan[:final_path])
                    mode = :dual_matte
                  end
                  state[:capture_mode] = mode
                  index += 1
                  state[:capture_index] = index
                  break if budget_deadline && monotonic_time >= budget_deadline
                  next
                end
                state[:capture_mode] = mode
              end

              if mode == :native_alpha
                view.camera = plan[:camera]
                soft_visual_proxy_write_transparent!(view, plan[:final_path], plan[:width_px], plan[:height_px])
              else
                unless current_background == :white
                  soft_visual_proxy_set_background!(model, white_color)
                  current_background = :white
                end
                view.camera = plan[:camera]
                soft_visual_proxy_write_opaque!(view, plan[:white_path], plan[:width_px], plan[:height_px])
                soft_visual_proxy_set_background!(model, black_color)
                current_background = :black
                view.camera = plan[:camera]
                soft_visual_proxy_write_opaque!(view, plan[:black_path], plan[:width_px], plan[:height_px])
              end
              index += 1
              state[:capture_index] = index
              break if budget_deadline && monotonic_time >= budget_deadline
            end
          else
            modes.each do |background|
              soft_visual_proxy_set_background!(model, background)
              white = background.red.to_i > 127
              capture_plans.each do |plan|
                view.camera = plan[:camera]
                path_out = white ? plan[:white_path] : plan[:black_path]
                soft_visual_proxy_write_opaque!(view, path_out, plan[:width_px], plan[:height_px])
              end
            end
          end
        end
      ensure
        visibility_rows.reverse_each do |entity, hidden|
          entity.hidden = hidden if entity && entity.valid? && entity.respond_to?(:hidden=)
        rescue StandardError
          nil
        end
        restore_active_view_state(original_view, model) if original_view
        model.abort_operation rescue nil if operation_started
        layer_visibility.each { |layer, visible| layer.visible = visible if layer } rescue nil
        model.selection.clear rescue nil
        original_selection.each { |entity| model.selection.add(entity) if entity && entity.valid? } rescue nil
        end_soft_heavy_interaction(:visual_proxy_capture_batch) if interaction_started
      end
      true
    end

    def soft_visual_proxy_capture_images!(state, model, plan, backgrounds)
      soft_visual_proxy_capture_plan_batch!(state, model, [plan], backgrounds)
    end

    def soft_visual_proxy_capture_all_matte_pairs!(state, model)
      state[:capture_index] = 0
      soft_visual_proxy_capture_plan_batch!(state, model, Array(state[:plans]), [:adaptive_alpha])
    end

    # 按时间预算继续拍摄剩余方向；返回 true 表示六个方向已全部拍完。
    def soft_visual_proxy_capture_plans_budgeted!(state, model, budget_seconds)
      plans = Array(state[:plans])
      return true if state[:capture_index].to_i >= plans.length
      soft_visual_proxy_capture_plan_batch!(state, model, plans, [:adaptive_alpha], budget_seconds: budget_seconds)
      state[:capture_index].to_i >= plans.length
    end

    def soft_visual_proxy_capture_single_image!(state, model, plan, background)
      soft_visual_proxy_capture_images!(state, model, plan, [background])
    end

    # 同一方向的白底、黑底在一次临时场景和一次 SketchUp operation 内连续完成。
    # 截图总数与透明算法不变，但每个方向只隐藏/恢复根实体、图层和视图一次。
    def soft_visual_proxy_capture_matte_pair!(state, model, plan)
      soft_visual_proxy_capture_images!(
        state, model, plan,
        [Sketchup::Color.new(255, 255, 255), Sketchup::Color.new(0, 0, 0)]
      )
    end

    def soft_visual_proxy_incremental_progress!(state, progress, stage, detail, status: 'running', model: Sketchup.active_model)
      task_id = state[:task_id].to_s
      unless task_id.empty?
        update_task_center_job!(task_id, progress: progress, stage: stage, detail: detail, status: status)
        sync_task_center_overlay_ui!(model) rescue nil
      end
      job = @soft_visual_proxy_upgrade_job
      if job.is_a?(Hash)
        job[:last_progress_at] = monotonic_time
        job[:last_progress_stage] = stage.to_s
      end
      total = job.is_a?(Hash) ? [job[:scan_total].to_i, job[:total].to_i, 1].max : 1
      done = job.is_a?(Hash) ? job[:done].to_i : 0
      current_index = [[done + 1, 1].max, total].min
      aggregate = ((done.to_f + [[progress.to_f, 0.0].max, 100.0].min / 100.0) / total.to_f * 100.0)
      aggregate = [[aggregate, 0.0].max, 99.0].min
      show_workspace_floating_notice("代理刷新中 · #{current_index}/#{total} · #{stage}", 'info', progress: aggregate, persistent: true, model: model)
      Sketchup.set_status_text("#{stage} · #{detail}") if Sketchup.respond_to?(:set_status_text)
      true
    rescue StandardError
      false
    end

    # v0.13.6.167：当前 SketchUp 的兼容回退路径把 12 张白/黑底截图一次完成，
    # 让六个方向共享同一个隐藏/恢复场景；透明抠图仍逐面切片，把纯 Ruby 处理继续
    # 分散到 driver 间隙。代价是截图这一步会形成一个较长的主线程片段，但避免大型项目
    # 6 次 O(N 根实体) 隐藏/恢复，整体完成时间显著更短。支持独立工作进程的平台不走此路径。
    def process_soft_visual_proxy_incremental_candidate_step!(state, job)
      model = job[:model] || Sketchup.active_model
      with_soft_commit_world_context(model) { process_soft_visual_proxy_incremental_candidate_world_step!(state, job) }
    end

    def process_soft_visual_proxy_incremental_candidate_world_step!(state, job)
      model = job[:model] || Sketchup.active_model
      plans = Array(state[:plans])
      case state[:phase]
      when :capture
        total = [plans.length, 1].max
        index = state[:capture_index].to_i
        current_plan = plans[[index, plans.length - 1].min]
        soft_visual_proxy_incremental_progress!(
          state, 12 + ((index.to_f / total) * 36.0).round, "截图 #{[index + 1, total].min}/#{total}",
          "#{current_plan ? current_plan[:name] : ''} · 分片截图，视口保持可响应", model: model
        )
        budget = job[:foreground_exit_batch] ? SOFT_VISUAL_PROXY_CAPTURE_TICK_BUDGET_EXIT_BATCH : SOFT_VISUAL_PROXY_CAPTURE_TICK_BUDGET
        finished = soft_visual_proxy_capture_plans_budgeted!(state, model, budget)
        return :more unless finished
        state[:view_index] = 0
        if state[:capture_mode] == :native_alpha
          plans.each { |plan| state[:images][plan[:name]] = plan[:final_path] }
          state[:phase] = :build
          soft_visual_proxy_incremental_progress!(state, 78, '原生透明六视图完成', '透明快路径已通过自检，准备构建代理模型', model: model)
        else
          state[:phase] = :matte
        end
        :more
      when :matte
        index = state[:view_index].to_i
        if index >= plans.length
          state[:phase] = :build
          soft_visual_proxy_incremental_progress!(state, 78, '六视图完成', '准备构建代理模型', model: model)
          return :more
        end
        plan = plans[index]
        progress = 50 + index * 5
        soft_visual_proxy_incremental_progress!(state, progress, "透明处理 #{index + 1}/6", plan[:name].to_s, model: model)
        soft_visual_proxy_matte_pair_to_png!(plan[:white_path], plan[:black_path], plan[:final_path])
        state[:images][plan[:name]] = plan[:final_path]
        # v184: retain matte pairs until image validation / failure diagnostics.
        state[:view_index] = index + 1
        :more
      when :build
        begin
          validate_soft_visual_proxy_images!(state[:images], state[:model_name])
        rescue SoftProxyImageQualityError => e
          return :more if retry_soft_visual_proxy_quality!(state, e)
          raise
        end
        unless state[:source_signature].to_s == soft_library_file_signature(state[:source_path], force: true).to_s
          raise '生成期间源模型已变化，未发布旧版本代理；请重新提交。'
        end
        soft_visual_proxy_incremental_progress!(state, 82, '构建六面代理', '创建六张贴图面', model: model)
        operation_started = false
        begin
          # 代理 Definition 只作为写盘临时候选，不应留在用户当前模型或 Undo 栈里。
          # 因此“构建 + save_as/原子写入”放在同一个可回滚 operation 中，写完立即 abort。
          model.start_operation("构建六面代理 #{state[:model_name]}", true, false, false)
          operation_started = true
          proxy_definition = build_soft_visual_proxy_definition!(
            model, state[:model_id], state[:model_name], state[:source_path],
            state[:bounds_values], state[:images], state[:source_signature]
          )
          soft_visual_proxy_incremental_progress!(state, 88, '写入六面代理', File.basename(state[:target].to_s), model: model)
          write_soft_visual_proxy_definition_atomic!(proxy_definition, state[:target])
        ensure
          model.abort_operation rescue nil if operation_started
        end
        state[:phase] = :metadata
        :more
      when :metadata
        unless state[:source_signature].to_s == soft_library_file_signature(state[:source_path], force: true).to_s
          raise '代理写入后源模型已变化；未更新权威映射，请重新提交。'
        end
        raise '六面代理文件没有成功写入模型库。' unless File.file?(state[:target]) && File.size(state[:target]).positive?
        soft_visual_proxy_incremental_progress!(state, 93, '更新模型库映射', state[:model_name], model: model)
        state[:updated_metadata] = update_soft_visual_proxy_metadata!(
          state[:source_path], state[:metadata], state[:target], state[:model_id],
          state[:model_name], state[:source_signature], job[:root].to_s,
          index: job[:index], write_index: false
        )
        job[:index_dirty] = true
        state[:candidate][:committed_source_signature] = state[:source_signature].to_s
        state[:phase] = :replace
        :more
      when :replace
        soft_visual_proxy_incremental_progress!(state, 97, '替换当前实例', '同步最新六面代理', model: model)
        candidate = state[:candidate]
        state[:replaced] = replace_project_legacy_soft_proxies_for_model!(
          state[:model_id], model,
          scope_space_id: candidate[:scope_space_id].to_s,
          instances: Array(candidate[:replace_instances])
        )
        state[:phase] = :done
        :done
      else
        :done
      end
    end

    # -------------------------
    # v0.13.6.82 · 独立 SketchUp 六面代理工作进程
    # -------------------------

    def soft_visual_proxy_external_worker_supported?
      # v0.13.6.84：撤回独立 SketchUp 工作进程方案。代理统一在用户完全退出
      # 工作空间后由当前 SketchUp 前台批处理，避免第二实例启动/授权/视口初始化问题。
      false
    end

    def soft_visual_proxy_current_process_executable
      return nil unless windows_platform?
      pid = Process.pid.to_i
      script = <<~POWERSHELL
        $ErrorActionPreference = 'Stop';
        $p = Get-Process -Id #{pid};
        if ($p.Path) {
          [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false);
          [Console]::Write($p.Path);
        }
      POWERSHELL
      output = IO.popen(
        ['powershell.exe', '-NoLogo', '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-Command', script],
        'rb', &:read
      )
      path = output.to_s.force_encoding(Encoding::UTF_8).strip
      return nil if path.empty? || !File.file?(path)
      return nil unless File.basename(path).casecmp('SketchUp.exe').zero?
      FastPath.expand(path)
    rescue StandardError => e
      log("独立代理：读取当前 SketchUp.exe 路径失败：#{e.class}: #{e.message}") rescue nil
      nil
    end

    def soft_visual_proxy_worker_sketchup_executable
      # Sketchup.version 在 SketchUp 2026 返回 26.x，而 Windows 默认安装目录使用
      # “SketchUp 2026”。v0.13.6.82 把 26 直接拼进目录名，导致找不到 EXE。
      # v0.13.6.83 首选从当前正在运行的进程反查 EXE，这也兼容自定义安装目录。
      current_exe = soft_visual_proxy_current_process_executable
      if current_exe && File.file?(current_exe)
        log("独立代理：复用当前 SketchUp 可执行文件：#{current_exe}") rescue nil
        return current_exe
      end

      major = Sketchup.version.to_s.split('.').first.to_s
      major_number = major.to_i
      release_year = if major_number >= 10 && major_number < 100
                       (2000 + major_number).to_s
                     else
                       major
                     end
      bases = [ENV['ProgramW6432'], ENV['ProgramFiles'], ENV['ProgramFiles(x86)']].compact.map(&:to_s).reject(&:empty?).uniq
      candidates = []
      bases.each do |base|
        candidates << File.join(base, 'SketchUp', "SketchUp #{release_year}", 'SketchUp.exe') unless release_year.empty?
        candidates << File.join(base, 'SketchUp', "SketchUp #{major}", 'SketchUp.exe') unless major.empty?
        # 最后再扫 SketchUp 安装根目录，兼容自定义小版本/目录命名；优先当前年份。
        begin
          discovered = Dir.glob(File.join(base, 'SketchUp', 'SketchUp *', 'SketchUp.exe'))
          discovered.sort_by! do |path|
            name = File.basename(File.dirname(path)).to_s
            [name.include?(release_year) ? 0 : 1, name]
          end
          candidates.concat(discovered)
        rescue StandardError
          nil
        end
      end
      ENV['PATH'].to_s.split(File::PATH_SEPARATOR).each do |entry|
        next if entry.to_s.empty?
        candidates << File.join(entry, 'SketchUp.exe')
      end
      candidates = candidates.map { |path| FastPath.expand(path.to_s) rescue path.to_s }.reject(&:empty?).uniq
      found = candidates.find { |path| File.file?(path) }
      if found
        log("独立代理：通过安装目录候选找到 SketchUp.exe：#{found}") rescue nil
        return found
      end

      preview = candidates.first(12).join(' | ')
      log("独立代理：SketchUp.exe 定位失败；version=#{Sketchup.version}; major=#{major}; year=#{release_year}; candidates=#{preview}") rescue nil
      raise "未找到当前 SketchUp #{release_year.empty? ? major : release_year} 的 SketchUp.exe，无法启动独立代理工作进程。"
    end

    def soft_visual_proxy_worker_boot_file
      File.expand_path('proxy_worker_boot.rb', __dir__)
    end

    def soft_visual_proxy_worker_status_payload(job_payload, status:, progress:, stage:, detail: '', error: '', extra: nil)
      result = {
        'schema' => 1,
        'job_id' => job_payload['job_id'].to_s,
        'plugin_version' => EXTENSION_VERSION,
        'worker_pid' => (ENV['SU_LINKHUB_PROXY_WORKER'].to_s == '1' ? Process.pid : 0),
        'status' => status.to_s,
        'progress' => progress.to_i,
        'stage' => stage.to_s,
        'detail' => detail.to_s,
        'error' => error.to_s,
        'updated_at' => Time.now.iso8601(6)
      }
      result.merge!(extra) if extra.is_a?(Hash)
      result
    end

    def write_soft_visual_proxy_worker_status!(job_payload, status:, progress:, stage:, detail: '', error: '', extra: nil)
      path = job_payload['status_path'].to_s
      return false if path.empty?
      write_json_atomic(
        path,
        soft_visual_proxy_worker_status_payload(
          job_payload, status: status, progress: progress, stage: stage,
          detail: detail, error: error, extra: extra
        )
      )
    rescue StandardError => e
      log_exception('写入独立六面代理工作进程状态失败', e)
      false
    end

    def soft_visual_proxy_external_job_paths(token)
      FileUtils.mkdir_p(TEMP_PROXY_WORKER_JOB_DIR)
      FileUtils.mkdir_p(TEMP_PROXY_WORKER_STATUS_DIR)
      {
        job_path: File.join(TEMP_PROXY_WORKER_JOB_DIR, "#{token}.json"),
        status_path: File.join(TEMP_PROXY_WORKER_STATUS_DIR, "#{token}.json"),
        pid_path: File.join(TEMP_PROXY_WORKER_STATUS_DIR, "#{token}.pid")
      }
    end

    def launch_soft_visual_proxy_worker_process!(job_payload)
      raise '当前系统不支持独立 SketchUp 代理工作进程。' unless soft_visual_proxy_external_worker_supported?
      sketchup_exe = soft_visual_proxy_worker_sketchup_executable
      boot_file = soft_visual_proxy_worker_boot_file
      raise "独立代理启动脚本不存在：#{boot_file}" unless File.file?(boot_file)
      source_path = job_payload['source_path'].to_s
      raise '独立代理源 SKP 不存在。' unless File.file?(source_path)
      pid_path = job_payload['pid_path'].to_s

      # 由 PowerShell 只负责最小化启动一个新的 SketchUp GUI 进程。真正的 SketchUp
      # Ruby API 都在该工作进程自己的主线程运行；当前建模进程只会轮询 JSON 文件。
      script = <<~'POWERSHELL'
        $ErrorActionPreference = 'Stop';
        $exe = $env:SU_LINKHUB_WORKER_EXE;
        $boot = $env:SU_LINKHUB_WORKER_BOOT;
        $source = $env:SU_LINKHUB_WORKER_SOURCE;
        $pidFile = $env:SU_LINKHUB_WORKER_PID_FILE;
        $mainPid = [int]$env:SU_LINKHUB_MAIN_PID;
        $argLine = '-RubyStartup "' + $boot.Replace('"','\"') + '" "' + $source.Replace('"','\"') + '"';
        $p = Start-Process -FilePath $exe -ArgumentList $argLine -WindowStyle Normal -PassThru;
        [System.IO.File]::WriteAllText($pidFile, [string]$p.Id, [System.Text.Encoding]::ASCII);
        try { $p.PriorityClass = 'BelowNormal'; } catch {}
        try { $null = $p.WaitForInputIdle(15000); } catch {}
        Start-Sleep -Milliseconds 250;
        try { $p.Refresh(); } catch {}
        try {
          Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class LinkHubWin32 {
  [DllImport("user32.dll", SetLastError=true)] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
}
'@;
          if ($p.MainWindowHandle -ne 0) {
            [LinkHubWin32]::SetWindowPos($p.MainWindowHandle, [IntPtr]::Zero, -20000, 80, 1280, 900, 0x0014) | Out-Null;
          }
          $main = Get-Process -Id $mainPid -ErrorAction SilentlyContinue;
          if ($main -and $main.MainWindowHandle -ne 0) {
            [LinkHubWin32]::SetForegroundWindow($main.MainWindowHandle) | Out-Null;
          }
        } catch {}
      POWERSHELL
      environment = {
        'SU_LINKHUB_PROXY_WORKER' => '1',
        'SU_LINKHUB_PROXY_WORKER_JOB' => job_payload['job_path'].to_s,
        'SU_LINKHUB_WORKER_EXE' => sketchup_exe,
        'SU_LINKHUB_WORKER_BOOT' => boot_file,
        'SU_LINKHUB_WORKER_SOURCE' => source_path,
        'SU_LINKHUB_WORKER_PID_FILE' => pid_path,
        'SU_LINKHUB_MAIN_PID' => Process.pid.to_s
      }
      command = [
        'powershell.exe', '-NoLogo', '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden',
        '-ExecutionPolicy', 'Bypass', '-Command', script
      ]
      pid = Process.spawn(environment, *command, out: File::NULL, err: File::NULL)
      Process.detach(pid)
      true
    rescue StandardError
      raise
    end

    def begin_soft_visual_proxy_external_candidate(candidate, job)
      raise '当前平台无法使用独立 SketchUp 六面代理工作进程。' unless soft_visual_proxy_external_worker_supported?
      root = job[:root].to_s.empty? ? soft_library_root : job[:root].to_s
      source_path = FastPath.expand(candidate[:source_path].to_s)
      raise '源模型文件不存在，无法提交独立代理工作进程。' unless File.file?(source_path)
      model_id = candidate[:model_id].to_s
      model_name = candidate[:model_name].to_s
      metadata = candidate[:metadata].is_a?(Hash) ? json_deep_copy(candidate[:metadata]) : {}
      source_signature = soft_library_file_signature(source_path, force: true).to_s
      raise '无法读取刚写回模型库的源模型版本签名。' if source_signature.empty?
      target = soft_visual_proxy_target_path(model_id, model_name, metadata, root)
      token = "proxy-#{Time.now.strftime('%Y%m%d_%H%M%S')}-#{Process.pid}-#{SecureRandom.hex(5)}"
      paths = soft_visual_proxy_external_job_paths(token)
      payload = {
        'schema' => 1,
        'job_id' => token,
        'plugin_version' => EXTENSION_VERSION,
        'created_at' => Time.now.iso8601(6),
        'job_path' => paths[:job_path],
        'status_path' => paths[:status_path],
        'pid_path' => paths[:pid_path],
        'model_id' => model_id,
        'model_name' => model_name,
        'source_path' => source_path,
        'source_signature' => source_signature,
        'root' => root,
        'target_path' => target,
        'metadata' => metadata
      }
      write_json_atomic(paths[:job_path], payload)
      write_soft_visual_proxy_worker_status!(payload, status: 'queued', progress: 9, stage: '启动独立工作进程', detail: '主 SketchUp 可继续丝滑操作')
      launch_soft_visual_proxy_worker_process!(payload)
      {
        mode: :external_worker,
        candidate: candidate,
        task_id: candidate[:proxy_task_id].to_s,
        job_path: paths[:job_path], status_path: paths[:status_path], pid_path: paths[:pid_path],
        target: target, source_signature: source_signature,
        launched_at: monotonic_time, last_progress: -1, last_stage: '', last_status_at: monotonic_time,
        worker_seen: false, pending_result: nil
      }
    rescue StandardError
      raise
    end

    def read_soft_visual_proxy_worker_status(state)
      path = state[:status_path].to_s
      return nil if path.empty? || !File.file?(path)
      data = JSON.parse(File.read(path, encoding: 'UTF-8'))
      data.is_a?(Hash) ? data : nil
    rescue JSON::ParserError, Errno::ENOENT
      nil
    end

    def soft_visual_proxy_external_finalize_ready?(model = Sketchup.active_model)
      return false unless model
      individual_edit = soft_individual_edit_session(model)
      return false if individual_edit && %w[editing prompting saving awaiting_proxy_choice].include?(individual_edit[:phase].to_s)
      return false if publish_critical_section? || @updating || @single_space_update_job || @space_batch_update_job
      return false if workspace_toolbar_fast_interaction_active?(model)
      age = runtime_interaction_age(model)
      age.infinite? || age >= SOFT_VISUAL_PROXY_EXTERNAL_FINALIZE_IDLE_SECONDS
    rescue StandardError
      false
    end

    # 返回 :running / :completed / :failed。这里绝不调用 View#write_image，也不碰
    # 当前用户模型的 Entities；只是读取一个几百字节的 JSON 状态文件。
    def poll_soft_visual_proxy_external_candidate!(state, job)
      model = job[:model] || Sketchup.active_model
      status = read_soft_visual_proxy_worker_status(state)
      elapsed = monotonic_time - state[:launched_at].to_f
      unless status
        if elapsed > SOFT_VISUAL_PROXY_EXTERNAL_START_TIMEOUT
          raise '独立 SketchUp 代理工作进程启动超时；当前家具继续保持真模型。'
        end
        return :running
      end

      state[:worker_seen] = true if status['worker_pid'].to_i.positive?
      if !state[:worker_seen] && elapsed > SOFT_VISUAL_PROXY_EXTERNAL_START_TIMEOUT
        raise '独立 SketchUp 代理工作进程启动超时；当前家具继续保持真模型。'
      end
      state[:last_status_at] = monotonic_time
      task_id = state[:task_id].to_s
      progress = status['progress'].to_i
      stage = status['stage'].to_s
      detail = status['detail'].to_s
      worker_status = status['status'].to_s
      if progress != state[:last_progress].to_i || stage != state[:last_stage].to_s
        update_task_center_job!(task_id, progress: progress, stage: stage, detail: detail, status: 'running') unless task_id.empty?
        sync_task_center_overlay_ui!(model) rescue nil
        state[:last_progress] = progress
        state[:last_stage] = stage
      end

      if worker_status == 'failed'
        message = status['error'].to_s
        message = detail if message.empty?
        message = '独立六面代理工作进程失败。' if message.empty?
        raise message
      end
      if worker_status == 'completed'
        target = status['target_path'].to_s
        target = state[:target].to_s if target.empty?
        raise '独立工作进程报告完成，但六面代理文件不存在。' unless File.file?(target) && File.size(target).positive?
        candidate = state[:candidate]
        unless state[:metadata_staged]
          updated_metadata = status['metadata']
          if updated_metadata.is_a?(Hash)
            job[:index] = { 'schema' => SOFT_LIBRARY_SCHEMA, 'models' => {} } unless job[:index].is_a?(Hash)
            job[:index]['models'] = {} unless job[:index]['models'].is_a?(Hash)
            source_key = normalize_soft_library_key(candidate[:source_path].to_s)
            job[:index]['models'][source_key] = updated_metadata
            update_soft_library_cache_item!(candidate[:source_path].to_s, updated_metadata, persist: false)
          else
            # 兼容热重载/旧工作进程状态：若 completed 没带 metadata，主进程只补小型
            # sidecar/权威映射，并仍然不写共享索引。
            updated_metadata = update_soft_visual_proxy_metadata!(
              candidate[:source_path].to_s, candidate[:metadata], target,
              candidate[:model_id].to_s, candidate[:model_name].to_s,
              status['source_signature'].to_s.empty? ? state[:source_signature].to_s : status['source_signature'].to_s,
              job[:root].to_s, index: job[:index], write_index: false
            )
          end
          job[:index_dirty] = true
          state[:pending_result] = { path: target, metadata: updated_metadata, replaced: 0 }
          state[:metadata_staged] = true
        end
        state[:pending_result] ||= { path: target, metadata: {}, replaced: 0 }
        unless soft_visual_proxy_external_finalize_ready?(model)
          update_task_center_job!(task_id, progress: 96, stage: '代理已生成', detail: '等待一个安全瞬间切回代理', status: 'running') unless task_id.empty?
          sync_task_center_overlay_ui!(model) rescue nil
          return :running
        end
        update_task_center_job!(task_id, progress: 98, stage: '瞬时切回代理', detail: '仅此步骤短暂占用前台', status: 'running') unless task_id.empty?
        sync_task_center_overlay_ui!(model) rescue nil
        replaced = replace_project_legacy_soft_proxies_for_model!(
          candidate[:model_id].to_s, model,
          scope_space_id: candidate[:scope_space_id].to_s,
          instances: Array(candidate[:replace_instances])
        )
        state[:pending_result][:replaced] = replaced.to_i
        return :completed
      end
      if elapsed > SOFT_VISUAL_PROXY_EXTERNAL_JOB_TIMEOUT
        raise '独立 SketchUp 六面代理工作进程运行超时；当前家具继续保持真模型。'
      end
      :running
    end

    def cleanup_soft_visual_proxy_external_state!(state)
      return false unless state.is_a?(Hash)
      [state[:job_path], state[:status_path], state[:pid_path]].each do |path|
        next if path.to_s.empty?
        File.delete(path) if File.file?(path)
      rescue StandardError
        nil
      end
      true
    rescue StandardError
      false
    end

    # 在独立 SketchUp 进程中调用。源 SKP 作为该进程自己的文档打开，所有相机、截图、
    # ImageRep 和代理 Definition 操作因此只占用工作进程的主线程，不会抢用户正在建模的
    # SketchUp 主线程。最终只通过 JSON + 代理 SKP 文件把结果交回主进程。
    def run_visual_proxy_worker_from_env!
      job_path = ENV['SU_LINKHUB_PROXY_WORKER_JOB'].to_s
      raise '缺少 SU_LINKHUB_PROXY_WORKER_JOB。' if job_path.empty? || !File.file?(job_path)
      payload = JSON.parse(File.read(job_path, encoding: 'UTF-8'))
      source_path = FastPath.expand(payload['source_path'].to_s)
      raise '工作进程源模型不存在。' unless File.file?(source_path)
      write_soft_visual_proxy_worker_status!(payload, status: 'running', progress: 10, stage: '工作进程已启动', detail: "PID #{Process.pid}")

      model = Sketchup.active_model
      current_path = FastPath.expand(model.path.to_s) rescue ''
      if current_path.empty? || normalize_soft_library_key(current_path) != normalize_soft_library_key(source_path)
        write_soft_visual_proxy_worker_status!(payload, status: 'running', progress: 12, stage: '载入源模型', detail: File.basename(source_path))
        opened = begin
          if Sketchup.method(:open_file).parameters.any? { |kind, name| kind == :key && name == :with_status }
            Sketchup.open_file(source_path, with_status: true)
          else
            Sketchup.open_file(source_path)
          end
        rescue ArgumentError
          Sketchup.open_file(source_path)
        end
        raise '独立工作进程无法打开源模型。' if opened == false
        model = Sketchup.active_model
      end

      expected_signature = payload['source_signature'].to_s
      actual_signature = soft_library_file_signature(source_path, force: true).to_s
      if !expected_signature.empty? && actual_signature != expected_signature
        raise '源模型在进入代理工作进程前已经发生变化；为避免生成错版本代理，本任务已取消。'
      end

      bounds = model.bounds
      values = [bounds.min.x, bounds.min.y, bounds.min.z, bounds.max.x, bounds.max.y, bounds.max.z].map(&:to_f)
      raise '工作进程源模型没有有效几何外包盒。' unless soft_bounds_values_valid?(values)
      raise '当前源模型属于平面图片指代模型，不需要六面代理。' if soft_bounds_planar_reference?(values)

      plans = soft_visual_proxy_incremental_plans(values, TEMP_VISUAL_PROXY_DIR)
      images = {}
      layer_visibility = model.layers.to_a.map { |layer| [layer, layer.visible?] }
      operation_started = false
      begin
        model.start_operation("LinkHub 独立六面代理 #{payload['model_name']}", true, false, false)
        operation_started = true
        model.layers.each { |layer| layer.visible = true rescue nil }
        with_soft_bright_thumbnail_style(model, refresh_view: false) do
          view = model.active_view
          soft_visual_proxy_set_background!(model, Sketchup::Color.new(255, 255, 255))
          plans.each_with_index do |plan, index|
            write_soft_visual_proxy_worker_status!(payload, status: 'running', progress: 14 + index * 5, stage: "白底截图 #{index + 1}/6", detail: plan[:name].to_s)
            view.camera = plan[:camera]
            soft_visual_proxy_write_opaque!(view, plan[:white_path], plan[:width_px], plan[:height_px])
          end
          soft_visual_proxy_set_background!(model, Sketchup::Color.new(0, 0, 0))
          plans.each_with_index do |plan, index|
            write_soft_visual_proxy_worker_status!(payload, status: 'running', progress: 44 + index * 5, stage: "黑底截图 #{index + 1}/6", detail: plan[:name].to_s)
            view.camera = plan[:camera]
            soft_visual_proxy_write_opaque!(view, plan[:black_path], plan[:width_px], plan[:height_px])
          end
          plans.each_with_index do |plan, index|
            write_soft_visual_proxy_worker_status!(payload, status: 'running', progress: 74 + index * 2, stage: "透明处理 #{index + 1}/6", detail: plan[:name].to_s)
            soft_visual_proxy_matte_pair_to_png!(plan[:white_path], plan[:black_path], plan[:final_path])
            images[plan[:name]] = plan[:final_path]
            File.delete(plan[:white_path]) if File.file?(plan[:white_path])
            File.delete(plan[:black_path]) if File.file?(plan[:black_path])
          end

          final_signature = soft_library_file_signature(source_path, force: true).to_s
          if !expected_signature.empty? && final_signature != expected_signature
            raise '源模型在六面截图期间又被更新；本次代理结果已丢弃，避免覆盖新版本。'
          end
          target = payload['target_path'].to_s
          root = payload['root'].to_s
          metadata = payload['metadata'].is_a?(Hash) ? payload['metadata'] : {}
          write_soft_visual_proxy_worker_status!(payload, status: 'running', progress: 87, stage: '构建六面代理', detail: payload['model_name'].to_s)
          proxy_definition = build_soft_visual_proxy_definition!(
            model, payload['model_id'].to_s, payload['model_name'].to_s, source_path,
            values, images, expected_signature.empty? ? final_signature : expected_signature
          )
          write_soft_visual_proxy_worker_status!(payload, status: 'running', progress: 91, stage: '写入代理模型库', detail: File.basename(target))
          write_soft_visual_proxy_definition_atomic!(proxy_definition, target)
          raise '独立工作进程没有成功写出六面代理。' unless File.file?(target) && File.size(target).positive?
          write_soft_visual_proxy_worker_status!(payload, status: 'running', progress: 94, stage: '更新代理映射', detail: payload['model_name'].to_s)
          # 工作进程只写每款独立 sidecar / model_id 权威映射，不再反复争写共享模型索引。
          # 主 SketchUp 收到 completed 后把 metadata 合入同一批 job[:index]，整批结束只写一次。
          worker_index = { 'schema' => SOFT_LIBRARY_SCHEMA, 'models' => {} }
          updated_metadata = update_soft_visual_proxy_metadata!(
            source_path, metadata, target, payload['model_id'].to_s, payload['model_name'].to_s,
            expected_signature.empty? ? final_signature : expected_signature, root,
            index: worker_index, write_index: false
          )
          write_soft_visual_proxy_worker_status!(
            payload, status: 'completed', progress: 96, stage: '代理生成完成', detail: '已交回主 SketchUp，等待瞬时切换',
            extra: {
              'target_path' => target,
              'source_signature' => (expected_signature.empty? ? final_signature : expected_signature),
              'metadata' => updated_metadata
            }
          )
        end
      ensure
        model.abort_operation rescue nil if operation_started
        layer_visibility.each { |layer, visible| layer.visible = visible if layer } rescue nil
        Array(plans).each do |plan|
          [:white_path, :black_path, :final_path].each do |key|
            file = plan[key].to_s
            File.delete(file) if !file.empty? && File.file?(file)
          rescue StandardError
            nil
          end
        end
      end
      true
    rescue StandardError => e
      begin
        payload ||= { 'job_id' => '', 'status_path' => '' }
        write_soft_visual_proxy_worker_status!(payload, status: 'failed', progress: 0, stage: '独立代理失败', detail: e.message.to_s, error: "#{e.class}: #{e.message}")
      rescue StandardError
        nil
      end
      log_exception('独立 SketchUp 六面代理工作进程失败', e) rescue nil
      false
    ensure
      # 工作进程绝不保存作为渲染宿主打开的源 SKP，避免相机/样式临时状态污染模型库。
      UI.start_timer(0.15, false) do
        begin
          Sketchup.active_model.close(true) if Sketchup.active_model && Sketchup.active_model.respond_to?(:close)
        rescue StandardError
          nil
        ensure
          Sketchup.quit rescue nil
        end
      end rescue nil
    end

    def finish_soft_visual_proxy_candidate_success!(job, candidate, result, task_id: '')
      model = job[:model] || Sketchup.active_model
      label = candidate[:model_name].to_s.empty? ? candidate[:model_id].to_s : candidate[:model_name].to_s
      verify_soft_proxy_requested_display!(candidate, model)
      job[:success] += 1
      job[:replaced] += result[:replaced].to_i
      job[:completed] << candidate
      job[:done] += 1
      (job[:success_names] ||= []) << label
      # 自动修复的完成提示只列“真的重建了代理文件或真的替换了实例”的款；仅复用
      # 现有权威代理且没有任何实例需要同步的款不算修复，避免每次载入都弹同一条提示。
      if result[:replaced].to_i.positive? || candidate[:reuse_existing] != true
        (job[:repaired_names] ||= []) << label
      end
      consumed_pending = complete_soft_pending_proxy_rebuilds_for_model!(candidate[:model_id].to_s, model)
      # v0.13.7.3：代理完成后空闲时补齐正反轴测缩略图（已是最新则直接跳过）。
      enqueue_soft_thumbnail_views!(candidate[:model_id].to_s, reason: '六面代理完成') rescue nil if candidate[:reuse_existing] != true
      if candidate[:legacy_recovery] == true
        remaining_legacy = Array(candidate[:replace_instances]).select do |instance|
          instance && instance.valid? && soft_legacy_proxy_entity?(instance) &&
            instance.get_attribute(SOFT_MODEL_DICT, 'representation', '').to_s == 'proxy'
        end
        unless remaining_legacy.empty?
          job[:legacy_unconverted].concat(remaining_legacy)
          log("历史白盒已恢复身份但未自动换六面代理（通常为旧/新轴关系不明确）：#{label} / #{remaining_legacy.length} 个")
        end
      end
      unless task_id.to_s.empty?
        detail = if result[:replaced].to_i.positive?
                   "权威代理已更新 · 已同步 #{result[:replaced].to_i} 个当前实例 · 已消费 #{consumed_pending} 个待提交标记"
                 elsif consumed_pending.to_i.positive?
                   "权威代理已更新 · 当前实例保持真模型 · 已消费 #{consumed_pending} 个待提交标记（不会重复生成）"
                 else
                   '权威代理已更新 · 当前实例无需同步'
                 end
        if candidate[:active_started_at]
          # v0.13.7.4：任务队列里的总耗时包含排队和“等待退出空间”；单独标出实际生成用时。
          detail += " · 实际生成 #{(monotonic_time - candidate[:active_started_at].to_f).round}s（其余为排队/等待空闲）"
        end
        finish_task_center_job!(task_id, success: true, stage: '六面代理完成', detail: detail)
        sync_task_center_overlay_ui!(model) rescue nil
      end
      log("六面代理升级完成：#{label} / 替换当前项目实例 #{result[:replaced].to_i} / 消费待提交 #{consumed_pending}")
      if model && !model.active_path.nil?
        @workspace_escape_suppress_until&.delete(model.object_id)
        @workspace_double_click_rearm_suppress_until&.delete(model.object_id)
        runtime_start_timer(0.03, false, label: 'soft:proxy_done_rearm', key: "soft:proxy_done_rearm:#{model.object_id}", model: model, active_model_only: true) do
          arm_workspace_double_click_candidate(model)
        end
      end
      true
    end

    def fail_soft_visual_proxy_candidate!(job, candidate, error, state = nil)
      model = job[:model] || Sketchup.active_model
      label = candidate[:model_name].to_s.empty? ? candidate[:model_id].to_s : candidate[:model_name].to_s
      job[:failed] += 1
      job[:done] += 1
      job[:errors] << { name: label, message: error.message.to_s }
      cleanup_soft_visual_proxy_incremental_state!(state) if state
      mark_soft_pending_proxy_rebuild_failed!(candidate[:model_id].to_s, error.message.to_s, model)
      task_id = state.is_a?(Hash) ? state[:task_id].to_s : candidate[:proxy_task_id].to_s
      finish_task_center_job!(task_id, success: false, stage: '六面代理失败', detail: error.message.to_s, error: error) unless task_id.empty?
      sync_task_center_overlay_ui!(model) rescue nil
      log_exception("六面代理升级失败：#{label}", error)
      true
    end

    def process_soft_visual_proxy_upgrade_job
      job = @soft_visual_proxy_upgrade_job
      return false unless job
      # 所有 SketchUp API 仍只在主线程执行；额外 guard 防止热重载/旧 timer 残留造成连续重入。
      if @soft_visual_proxy_driver_processing
        schedule_soft_visual_proxy_driver!(job, delay: 0.06, label: 'soft:visual_proxy_reentry_wait')
        return true
      end
      @soft_visual_proxy_driver_processing = true
      owns_proxy_driver = true
      job[:last_driver_at] = monotonic_time
      model = job[:model] || Sketchup.active_model

      # v0.13.6.82：一旦独立 SketchUp 工作进程已经启动，当前进程只轮询 JSON。
      # 不再检查“前台是否空闲”，因为轮询不会调用 View/Entities API，也不会抢视口。
      if (state = job[:active_candidate_state]).is_a?(Hash)
        candidate = state[:candidate]
        begin
          if state[:mode].to_s == 'external_worker'
            result_state = poll_soft_visual_proxy_external_candidate!(state, job)
            if result_state == :completed
              final_result = state[:pending_result] || { path: state[:target], metadata: {}, replaced: 0 }
              cleanup_soft_visual_proxy_external_state!(state)
              finish_soft_visual_proxy_candidate_success!(job, candidate, final_result, task_id: state[:task_id].to_s)
              job[:active_candidate_state] = nil
            else
              schedule_soft_visual_proxy_driver!(job, delay: SOFT_VISUAL_PROXY_EXTERNAL_POLL_INTERVAL, label: 'soft:visual_proxy_external_poll')
              return true
            end
          else
            # 当前 SketchUp 前台分片既支持世界根，也支持“家具退出确认=是”明确请求的
            # 当前空间就地生成；后者不修改 active_path，只在当前 active_entities 中建立
            # 可回滚临时截图场景。
            allowed_inside = state[:allow_inside_space] == true && soft_visual_proxy_inside_space_generation_allowed?(model)
            unless model && (model.active_path.nil? || allowed_inside)
              update_task_center_job!(state[:task_id].to_s, stage: '等待安全生成', detail: '当前层级已变化；退出空间后继续', status: 'queued') unless state[:task_id].to_s.empty?
              schedule_soft_visual_proxy_driver!(job, delay: 0.25, label: 'soft:visual_proxy_active_path_wait')
              return true
            end
            unless job[:foreground_exit_batch]
              queue_ready, _wait_reason, retry_seconds = soft_visual_proxy_queue_ready?(
                model, active_candidate: true, allow_inside_space: state[:allow_inside_space] == true
              )
              unless queue_ready
                schedule_soft_visual_proxy_driver!(job, delay: (retry_seconds.to_f.positive? ? retry_seconds.to_f : 0.12), label: 'soft:visual_proxy_front_wait')
                return true
              end
            end
            result_state = process_soft_visual_proxy_incremental_candidate_step!(state, job)
            if result_state == :done
              final_result = { path: state[:target], metadata: state[:updated_metadata], replaced: state[:replaced].to_i }
              cleanup_soft_visual_proxy_incremental_state!(state)
              finish_soft_visual_proxy_candidate_success!(job, candidate, final_result, task_id: state[:task_id].to_s)
              job[:active_candidate_state] = nil
            else
              schedule_soft_visual_proxy_driver!(job, delay: (job[:foreground_exit_batch] ? 0.02 : 0.08), label: 'soft:visual_proxy_front_slice')
              return true
            end
          end
        rescue StandardError => e
          cleanup_soft_visual_proxy_external_state!(state) if state[:mode].to_s == 'external_worker'
          fail_soft_visual_proxy_candidate!(job, candidate, e, (state[:mode].to_s == 'external_worker' ? nil : state))
          job[:active_candidate_state] = nil
        end
      end

      # 第一阶段仍只检查一款种子；该步骤不做任何截图。家具编辑完成后的单款任务
      # 通常只有一次索引/签名检查，随后立即交给外部进程。
      if Array(job[:scan_queue]).any?
        seed = job[:scan_queue].shift
        label = seed[:model_name].to_s.empty? ? seed[:model_id].to_s : seed[:model_name].to_s
        task_id = seed[:proxy_task_id].to_s
        begin
          update_task_center_job!(task_id, progress: 5, stage: '检查代理版本', detail: label, status: 'running') unless task_id.empty?
          sync_task_center_overlay_ui!(model) rescue nil
          candidate = soft_visual_proxy_candidate_from_seed(seed, job)
          if candidate
            job[:queue] << candidate
            job[:total] = job[:total].to_i + 1
            detail = job[:foreground_exit_batch] ? '等待退出空间前台统一生成' : '等待当前 SketchUp 分片生成'
            update_task_center_job!(task_id, progress: 8, stage: '已加入生成队列', detail: detail, status: 'queued') unless task_id.empty?
          else
            # 对普通“维护扫描”来说 nil 可以表示无需升级；但对已经写回模型库、实例仍带
            # proxy_rebuild_pending 的家具，nil 绝不能伪装成“代理已是最新”。否则 pending 不会清掉，
            # job 收尾又会重新排队，形成 2%/8% 永久循环。待提交家具解析不到候选时明确失败并保留真模型。
            pending_seed = soft_pending_proxy_rebuild_records(model).any? do |record|
              record[:model_id].to_s == seed[:model_id].to_s && record[:phase].to_s != 'failed'
            end
            if pending_seed
              message = '待刷新家具无法建立六面代理候选；已保留真模型，请查看任务日志中的模型库路径/索引错误。'
              mark_soft_pending_proxy_rebuild_failed!(seed[:model_id].to_s, message, model)
              job[:failed] = job[:failed].to_i + 1
              job[:errors] << { name: label, message: message }
              finish_task_center_job!(task_id, success: false, stage: '代理候选解析失败', detail: message) unless task_id.empty?
            elsif seed[:auto_repair] == true
              message = "#{label}：模型库中找不到可读真模型（#{seed[:source_path].to_s.empty? ? '无源路径' : File.basename(seed[:source_path].to_s)}），保持当前显示；修复模型库路径后会自动重试。"
              job[:errors] << { name: label, message: message }
              job[:failed] = job[:failed].to_i + 1
              finish_task_center_job!(task_id, success: false, stage: '自动修复未能解析真模型', detail: message) unless task_id.empty?
            else
              finish_task_center_job!(task_id, success: true, stage: '代理已是最新', detail: '无需重新生成') unless task_id.empty?
            end
          end
        rescue StandardError => e
          finish_task_center_job!(task_id, success: false, stage: '代理检查失败', detail: e.message.to_s, error: e) unless task_id.empty?
          log_exception("检查六面代理候选失败：#{label}", e)
        ensure
          job[:scanned] = job[:scanned].to_i + 1
          sync_task_center_overlay_ui!(model) rescue nil
        end
        schedule_soft_visual_proxy_driver!(job, delay: SOFT_VISUAL_PROXY_QUEUE_SCAN_INTERVAL, label: 'soft:visual_proxy_scan_next')
        return true
      end

      candidate = job[:queue].shift
      unless candidate
        finish_soft_visual_proxy_upgrade_job(job)
        return true
      end

      # 扫描索引可以在空间内完成，任何 Definition 载入、截图或实例替换必须等到
      # 世界根且前台安静。候选放回队首，保持原顺序和同一任务卡。
      queue_ready, wait_reason, retry_seconds = soft_visual_proxy_queue_ready?(model, active_candidate: false, allow_inside_space: candidate[:allow_inside_space] == true)
      unless queue_ready
        job[:queue].unshift(candidate)
        task_id = candidate[:proxy_task_id].to_s
        update_task_center_job!(task_id, progress: 8, stage: '等待安全生成', detail: wait_reason, status: 'queued') unless task_id.empty?
        schedule_soft_visual_proxy_driver!(job, delay: (retry_seconds.to_f.positive? ? retry_seconds.to_f : 0.25), label: 'soft:visual_proxy_candidate_wait')
        return true
      end

      label = candidate[:model_name].to_s.empty? ? candidate[:model_id].to_s : candidate[:model_name].to_s
      task_id = candidate[:proxy_task_id].to_s
      candidate_started = monotonic_time
      begin
        if candidate[:reuse_existing]
          # 已有权威代理时不需要任何截图，只做最终实例同步。
          unless soft_visual_proxy_external_finalize_ready?(model)
            job[:queue].unshift(candidate)
            update_task_center_job!(task_id, progress: 94, stage: '代理已就绪', detail: '等待安全瞬间同步实例', status: 'running') unless task_id.empty?
            schedule_soft_visual_proxy_driver!(job, delay: SOFT_VISUAL_PROXY_EXTERNAL_POLL_INTERVAL, label: 'soft:visual_proxy_reuse_wait')
            return true
          end
          update_task_center_job!(task_id, progress: 98, stage: '瞬时切回代理', detail: '同步当前实例', status: 'running') unless task_id.empty?
          result = generate_soft_visual_proxy_for_candidate!(candidate, model)
          finish_soft_visual_proxy_candidate_success!(job, candidate, result, task_id: task_id)
        elsif soft_visual_proxy_external_worker_supported?
          state = begin_soft_visual_proxy_external_candidate(candidate, job)
          job[:active_candidate_state] = state
          update_task_center_job!(task_id, progress: 9, stage: '独立工作进程', detail: '六面截图在第二个 SketchUp 中生成；主视口不参与渲染', status: 'running') unless task_id.empty?
          sync_task_center_overlay_ui!(model) rescue nil
          schedule_soft_visual_proxy_driver!(job, delay: SOFT_VISUAL_PROXY_EXTERNAL_POLL_INTERVAL, label: 'soft:visual_proxy_external_start')
          return true
        else
          # 当前版本统一使用本 SketchUp 前台分片路径；家具编辑完成任务只会在完全退出工作空间后进入这里。
          state = begin_soft_visual_proxy_incremental_candidate(candidate, job)
          raise '当前会话没有可用的六面代理截图 Definition。' unless state
          job[:active_candidate_state] = state
          soft_visual_proxy_incremental_progress!(state, 9, (job[:foreground_exit_batch] ? '退出空间批处理' : '前台分片模式'), (job[:foreground_exit_batch] ? '已离开工作空间，开始统一生成' : '当前 SketchUp 生成'), model: model)
          schedule_soft_visual_proxy_driver!(job, delay: (job[:foreground_exit_batch] ? 0.02 : 0.08), label: 'soft:visual_proxy_front_start')
          return true
        end
      rescue StandardError => e
        fail_soft_visual_proxy_candidate!(job, candidate, e)
      ensure
        log_slow_operation('六面代理单款调度耗时', candidate_started, 120.0, label) if defined?(candidate_started) && candidate_started
      end

      if job[:scan_queue].empty? && job[:queue].empty? && !job[:active_candidate_state]
        finish_soft_visual_proxy_upgrade_job(job)
      else
        schedule_soft_visual_proxy_driver!(job, delay: (job[:foreground_exit_batch] ? 0.02 : 0.08), label: 'soft:visual_proxy_upgrade_next')
      end
      true
    rescue StandardError => e
      log_exception('执行六面代理升级队列失败', e)
      finish_soft_visual_proxy_upgrade_job(job, aborted: true, abort_message: e.message.to_s) if job
      false
    ensure
      @soft_visual_proxy_driver_processing = false if owns_proxy_driver
      job[:last_driver_at] = monotonic_time if job.is_a?(Hash) && @soft_visual_proxy_upgrade_job.equal?(job)
    end

    def finish_soft_visual_proxy_upgrade_job(job, aborted: false, abort_message: '')
      return false unless job
      model = job[:model] || Sketchup.active_model
      # v0.13.6.167：整批代理共享索引只在这里回写一次；单款 sidecar/权威映射已先落盘。
      # abort 也要刷新此前已经成功完成的款式，避免成功项只存在权威映射而索引长期滞后。
      if job[:index_dirty] == true
        index_flushed = flush_soft_visual_proxy_job_index!(job)
        schedule_soft_visual_proxy_index_flush_retry!(job) unless index_flushed
      end
      @soft_visual_proxy_upgrade_job = nil
      stop_soft_visual_proxy_driver_timers!
      complete_soft_individual_edit_proxy_rebuilds!(job)
      if aborted
        if job[:active_candidate_state].is_a?(Hash)
          state = job[:active_candidate_state]
          if state[:mode].to_s == 'external_worker'
            cleanup_soft_visual_proxy_external_state!(state)
          else
            cleanup_soft_visual_proxy_incremental_state!(state)
          end
          candidate = state[:candidate]
          if candidate.is_a?(Hash)
            mark_soft_pending_proxy_rebuild_failed!(candidate[:model_id].to_s, abort_message.to_s, model)
            task_id = state[:task_id].to_s
            finish_task_center_job!(task_id, success: false, stage: '代理队列已停止', detail: abort_message.to_s) unless task_id.empty?
          end
        end
        (Array(job[:scan_queue]) + Array(job[:queue])).each do |candidate|
          next unless candidate.is_a?(Hash)
          mark_soft_pending_proxy_rebuild_failed!(candidate[:model_id].to_s, abort_message.to_s, model)
          task_id = candidate[:proxy_task_id].to_s
          finish_task_center_job!(task_id, success: false, stage: '代理队列已停止', detail: abort_message.to_s) unless task_id.empty?
        end
        sync_task_center_overlay_ui!(model) rescue nil
      end
      Sketchup.set_status_text('') if Sketchup.respond_to?(:set_status_text)
      persist_soft_library_cache! if job[:success].to_i.positive?
      schedule_soft_managed_definition_cleanup(job[:model] || Sketchup.active_model, delay: 1.0) if job[:success].to_i.positive?
      if @soft_designer_dialog && @soft_designer_dialog.visible? && job[:success].to_i.positive?
        schedule_soft_library_dialog_load(force: false)
      end
      if @soft_schedule_dialog && @soft_schedule_dialog.visible?
        # 六面代理文件/映射变化不会改变采购数量、规格或资料。旧版这里强制重建整张
        # 项目清单，等于代理刚生成完又立刻做一次跨空间/NAS 统计。现在只保留当前快照。
        # 若代理流程同时伴随了模型几何事务，事务观察器已经会把清单标为“模型有变化”。
      end
      emit_runtime_event(
        :visual_proxy_batch_finished,
        { success: job[:success].to_i, failed: job[:failed].to_i, replaced: job[:replaced].to_i, aborted: !!aborted, model: model }
      )
      message = if aborted
                  "六面代理升级已停止：#{abort_message}；此前成功 #{job[:success]}，失败 #{job[:failed]}。"
                elsif job[:failed].to_i.zero?
                  if job[:success].to_i.zero?
                    "六面代理检查完成：#{job[:scanned]} 款模型均无需升级。"
                  elsif job[:reason].to_s.include?('家具入库')
                    "六面代理重建完成：#{job[:success]} 款；已同步当前编辑空间 #{job[:replaced]} 个同款代理实例。其它未编辑空间将在下次进入/切代理时使用新代理。"
                  else
                    "六面代理升级完成：#{soft_furniture_name_summary(Array(job[:success_names]), limit: 6)}，当前项目替换 #{job[:replaced]} 个代理实例。"
                  end
                else
                  failed_rows = Array(job[:errors]).first(3).map { |row| "#{row[:name]}：#{row[:message]}" }
                  "六面代理升级完成：成功 #{job[:success]}，失败 #{job[:failed]}（#{failed_rows.join('；')}#{job[:errors].length > 3 ? '；…' : ''}）；当前项目替换 #{job[:replaced]} 个代理实例。"
                end
      legacy_unconverted = Array(job[:legacy_unconverted]).select { |instance| instance && instance.valid? }.uniq
      if legacy_unconverted.any?
        message += " 另有 #{legacy_unconverted.length} 个历史白盒虽已找回真模型身份，但因旧/新轴关系无法安全确认，仍保持白盒。"
      end
      status_kind = job[:failed].to_i.zero? && !aborted && legacy_unconverted.empty? ? 'success' : 'warning'
      success_names = soft_furniture_name_summary(Array(job[:success_names]), limit: 4)
      failed_names = soft_furniture_name_summary(Array(job[:errors]).map { |row| row[:name].to_s }, limit: 3)
      repair_job = job[:reason].to_s.include?('修复') || job[:reason].to_s.include?('补齐')
      repaired_names = soft_furniture_name_summary(Array(job[:repaired_names]), limit: 4)
      if aborted
        show_workspace_floating_notice("代理刷新已停止 · #{abort_message}", 'warning', duration: 5.0, model: model)
      elsif job[:failed].to_i.zero?
        if repair_job
          show_workspace_floating_notice("已自动修复代理 · #{repaired_names}", 'success', progress: 100, duration: 3.0, model: model) unless Array(job[:repaired_names]).empty?
        elsif job[:success].to_i.positive?
          show_workspace_floating_notice("代理刷新完成 · #{success_names}", 'success', progress: 100, duration: 3.0, model: model)
        end
      else
        show_workspace_floating_notice("代理刷新完成 · 失败：#{failed_names}#{job[:success].to_i.positive? ? " · 成功：#{success_names}" : ''}", 'warning', progress: 100, duration: 4.5, model: model)
      end
      show_status(message, status_kind) unless job[:foreground_exit_batch]
      # 自动修复任务不弹模态框：白盒轴关系不明确的款只写日志与状态栏，用户可在需要时手动校对。
      if legacy_unconverted.any? && repair_job
        log("自动修复：#{legacy_unconverted.length} 个历史白盒轴关系不明确，保持白盒（可用“家具入库”校对）")
      end
      if legacy_unconverted.any? && !repair_job && defined?(UI) && UI.respond_to?(:messagebox)
        grouped = legacy_unconverted.each_with_object(Hash.new(0)) do |instance, memo|
          info = soft_instance_metadata(instance)
          name = info['model_name'].to_s
          name = soft_identity_display_name(instance.definition.name.to_s) if name.empty? && instance.respond_to?(:definition)
          name = '未命名历史白盒' if name.empty?
          memo[name] += 1
        end
        lines = grouped.sort_by { |name, _count| name.to_s.downcase }.first(40).each_with_index.map do |(name, count), index|
          "#{index + 1}. #{name}#{count.to_i > 1 ? " ×#{count}" : ''}"
        end
        lines << "……另有 #{grouped.length - 40} 款，详见 LinkHub 日志。" if grouped.length > 40
        UI.messagebox(
          "历史白盒：未自动转换六面代理\n\n这些白盒已经重新找回真模型身份，但旧白盒 XYZ 与当前真模型轴关系无法安全确认。为避免再次压扁/放倒，它们暂时保持白盒；其它可安全处理的家具不受影响：\n\n#{lines.join("\n")}",
          MB_OK
        )
      end
      if model && (aborted || job[:failed].to_i.positive?)
        (@soft_proxy_switch_after_refresh || {}).delete(model.object_id)
      end
      if model && !aborted && job[:failed].to_i.zero?
        request = (@soft_proxy_switch_after_refresh || {}).delete(model.object_id)
        if request.is_a?(Hash)
          runtime_start_timer(0.08, false, label: 'soft:proxy_switch_after_refresh') do
            begin
              next unless model == Sketchup.active_model && model.active_path.nil?
              fresh_state = ensure_space_models_ready!(model)
              set_space_display_mode('proxy', model, scope_space_id: request[:scope_space_id].to_s, silent: true, state: fresh_state)
            rescue StandardError => e
              log_exception('代理刷新完成后切换代理失败', e)
              show_workspace_floating_notice("代理已刷新，但最终切换失败 · #{e.message}", 'warning', duration: 5.0, model: model)
            end
          end
        end
      end
      resume_space_publish_after_proxy_job!(job, model, aborted: aborted, abort_message: abort_message)
      reconcile_soft_visual_proxy_task_center!(model, nil) if model
      log("#{message} / #{elapsed_ms(job[:started_at])}ms")
      true
    rescue StandardError => e
      @soft_visual_proxy_upgrade_job = nil
      stop_soft_visual_proxy_driver_timers!
      log_exception('六面代理升级收尾失败', e)
      false
    end

    end
  end
end
