# frozen_string_literal: true

module GavinTools
  module SULinkHubMultiSpace
    module Runtime
    # -------------------------
    # v0.13.6.67 空间异步发布队列（视口队列 + 快照硬链接 + 回滚身份复用）
    # -------------------------
    # SketchUp Definition 序列化仍只允许在主线程执行；候选一旦落到本机临时 SKP，
    # 后续 SHA / SMB 传输 / rollback / 安全快照全部交给单 worker 串行处理。

    def background_publish_stage_meta(stage, status = '')
      key = stage.to_s
      stat = status.to_s
      return [5, '等待后台发布'] if stat == 'queued'
      return [96, '远端发布完成 · 正在本地收尾'] if stat == 'success'
      return [98, '发布已完成 · 后台维护（不占发布队列）'] if stat == 'maintenance'
      return [100, '发布完成'] if stat == 'completed'
      return [100, '后台发布失败'] if stat == 'failed'
      mapping = {
        'background_worker_started' => [8, '后台任务已启动'],
        'background_candidate_verify_begin' => [12, '校验本机发布候选'],
        'background_candidate_verify_returned' => [18, '本机候选校验完成'],
        'space_recovery_candidate_adopted' => [18, '本机候选已直接作为恢复快照'],
        'space_recovery_candidate_reuse_begin' => [22, '复用本机恢复候选'],
        'space_recovery_candidate_reuse_returned' => [30, '本机恢复候选就绪'],
        'space_recovery_candidate_copy_begin' => [22, '保存本机恢复快照'],
        'space_recovery_candidate_copy_returned' => [30, '恢复快照完成'],
        'background_remote_publish_begin' => [34, '准备协同发布'],
        'target_snapshot_checkpoint_reuse_begin' => [34, '复用安全快照指纹'],
        'target_snapshot_checkpoint_reuse_returned' => [36, '安全快照指纹复用完成'],
        'target_snapshot_hash_begin' => [36, '首次读取共享旧版本完整指纹'],
        'target_snapshot_hash_returned' => [40, '共享旧版本指纹完成'],
        'candidate_local_ready' => [42, '本机候选与共享基线已核对'],
        'candidate_stage_copy_begin' => [44, '上传发布候选到协同目录'],
        'candidate_stage_copy_returned' => [63, '候选上传完成'],
        'remote_stage_hash_begin' => [58, '校验已上传候选完整内容'],
        'remote_stage_hash_reused' => [62, '同盘候选硬链接 · 复用内容校验'],
        'remote_stage_hash_returned' => [62, '已上传候选校验完成'],
        'remote_stage_network_trusted' => [62, '网络候选已按本机指纹与传输长度核验'],
        'network_final_swap_begin' => [68, '锁定最终替换窗口'],
        'network_final_swap_returned' => [84, '网络共享文件已快速原子替换'],
        'candidate_ready' => [64, '远端候选就绪'],
        'target_to_rollback_begin' => [66, '移动共享旧版本到瞬时回滚'],
        'target_to_rollback_returned' => [70, '共享旧版本已移入回滚'],
        'rollback_hash_begin' => [71, '核验回滚文件完整指纹'],
        'rollback_hash_reused' => [74, '同文件身份确认 · 复用回滚指纹'],
        'rollback_hash_returned' => [74, '回滚文件核验完成'],
        'candidate_replace_target_begin' => [76, '替换正式共享文件'],
        'candidate_replace_target_returned' => [80, '正式共享文件已替换'],
        'target_content_hash_begin' => [82, '核验正式共享文件完整内容'],
        'target_content_hash_reused' => [85, '复用正式文件内容校验'],
        'target_content_hash_returned' => [85, '正式共享文件内容核验完成'],
        'target_verify_size_ok' => [87, '正式共享文件稳定性核对'],
        'safe_checkpoint_begin' => [89, '保存最近安全快照'],
        'safe_checkpoint_returned' => [91, '最近安全快照完成'],
        'personal_checkpoint_deferred' => [94, '正式发布已完成 · 个人快照延后'],
        'personal_checkpoint_deferred_begin' => [97, '后台补存个人快照'],
        'personal_checkpoint_deferred_returned' => [100, '个人快照补存完成'],
        'personal_checkpoint_begin' => [92, '保存个人最近发布快照'],
        'personal_checkpoint_returned' => [93, '个人发布快照完成'],
        'rollback_archive_begin' => [94, '归档发布前版本'],
        'rollback_archive_returned' => [95, '发布前版本归档完成'],
        'atomic_publish_verified' => [95, '共享发布全部校验完成'],
        'background_remote_publish_returned' => [96, '正式共享文件完成 · 等待释放空间'],
        'post_publish_maintenance_deferred' => [96, '正式文件已验证 · 快照整理延后'],
        'post_publish_maintenance_begin' => [97, '发布已完成 · 后台维护（不阻塞编辑）'],
        'background_maintenance_completed' => [100, '发布完成 · 后台整理完成'],
        'safe_checkpoint_deferred_failed' => [98, '安全快照整理警告'],
        'rollback_archive_deferred_failed' => [99, '版本历史整理警告'],
        'background_publish_failed' => [100, '后台发布失败']
      }
      mapping[key] || [stat == 'running' ? 38 : 5, key.empty? ? '后台发布中' : key]
    rescue StandardError
      [0, stage.to_s]
    end

    # 185：worker 生命周期内复用本地 append 句柄，每条仍 flush；不改提交/恢复日志。
    # 计时包括调度等待，不能据此把停顿一律归因于磁盘。异常不会改变正式发布结果。
    def background_publish_trace!(message)
      started = monotonic_time
      stamp = Time.now.strftime('%Y-%m-%d %H:%M:%S.%L')
      @background_publish_trace_mutex ||= Mutex.new
      @background_publish_trace_mutex.synchronize do
        acquired = monotonic_time
        cached = Thread.current[:sulink_async_publish_context].is_a?(Hash)
        file = cached ? Thread.current[:sulink_publish_trace_io185] : nil
        opened = false
        unless file && !file.closed?
          file = File.open(BACKGROUND_PUBLISH_TRACE_PATH, 'ab')
          opened = true
          Thread.current[:sulink_publish_trace_io185] = file if cached
        end
        ready = monotonic_time
        begin
          line = "[#{stamp}] #{message}\n"
          # 附在下一条诊断中，共用同一次 write/flush，不为计时增加文件操作。
          previous = Thread.current[:sulink_publish_trace_perf185]
          if cached && previous && previous[:total_ms] >= 100.0
            line << "[#{stamp}] PERF185 trace_previous total_ms=#{previous[:total_ms]} mutex_ms=#{previous[:mutex_ms]} open_ms=#{previous[:open_ms]} write_flush_ms=#{previous[:write_flush_ms]} opened=#{previous[:opened]}\n"
          end
          file.write(line.encode('UTF-8'))
          file.flush
          done = monotonic_time
          Thread.current[:sulink_publish_trace_perf185] = {
            total_ms: ((done - started) * 1000).round(1), mutex_ms: ((acquired - started) * 1000).round(1),
            open_ms: ((ready - acquired) * 1000).round(1), write_flush_ms: ((done - ready) * 1000).round(1), opened: opened
          } if cached
        ensure
          file.close unless cached || file.closed?
        end
      end
      true
    rescue StandardError
      close_background_publish_trace185!
      false
    end

    def close_background_publish_trace185!
      file = Thread.current[:sulink_publish_trace_io185]
      Thread.current[:sulink_publish_trace_io185] = nil
      Thread.current[:sulink_publish_trace_perf185] = nil
      file.close if file && !file.closed?
      true
    rescue StandardError
      false
    end

    # 纯内存状态读取；只能给可延后的 I/O 工作避让，不能用于跳过提交保护。
    def background_publish_remote_io_busy185?
      @space_publish_queue_mutex ||= Mutex.new
      @space_publish_queue_mutex.synchronize do
        (@space_publish_queue_registry || {}).values.any? do |row|
          row[:status].to_s == 'running' && row[:native_preparation] != true
        end
      end
    rescue StandardError
      false
    end

    def background_publish_stage_elapsed_seconds(job)
      stamp = job.is_a?(Hash) ? job[:stage_at].to_s : ''
      return 0 if stamp.empty?
      [(Time.now - Time.iso8601(stamp)).to_i, 0].max
    rescue StandardError
      0
    end

    def update_background_publish_job_stage!(job, stage, details = nil)
      return false unless job.is_a?(Hash)
      @space_publish_queue_mutex ||= Mutex.new
      progress, label = background_publish_stage_meta(stage, job[:status])
      previous_stage = ''
      previous_elapsed = 0
      @space_publish_queue_mutex.synchronize do
        previous_stage = job[:stage].to_s
        previous_elapsed = background_publish_stage_elapsed_seconds(job) unless previous_stage.empty?
        job[:stage] = stage.to_s
        job[:stage_label] = label.to_s
        job[:progress] = progress.to_i
        job[:stage_at] = Time.now.iso8601(6)
        job[:stage_monotonic] = monotonic_time
        job[:stage_detail] = if details.is_a?(Hash)
                               details.map { |key, value| "#{key}=#{value}" }.join(' · ')
                             else
                               details.to_s
                             end
        job[:stage_history] ||= []
        job[:stage_history] << {
          'at' => job[:stage_at].to_s, 'stage' => stage.to_s, 'label' => label.to_s,
          'progress' => progress.to_i, 'detail' => job[:stage_detail].to_s
        }
        job[:stage_history] = job[:stage_history].last(16)
      end
      background_publish_trace!(
        "STAGE job=#{job[:job_id]} space=#{job[:label]} #{previous_stage.empty? ? '-' : previous_stage}(#{previous_elapsed}s) -> #{stage} progress=#{progress}% detail=#{job[:stage_detail]}"
      )
      true
    rescue StandardError => e
      background_publish_trace!("STAGE_ERROR #{e.class}: #{e.message}")
      false
    end

    def background_publish_job_snapshot(space_id)
      @space_publish_queue_mutex ||= Mutex.new
      @space_publish_queue_registry ||= {}
      @space_publish_queue_mutex.synchronize do
        row = @space_publish_queue_registry[space_id.to_s]
        next {} unless row.is_a?(Hash)
        progress, stage_label = background_publish_stage_meta(row[:stage], row[:status])
        {
          'job_id' => row[:job_id].to_s,
          'space_id' => row[:space_id].to_s,
          'job_kind' => background_publish_queue_kind(row),
          'label' => row[:label].to_s,
          'status' => row[:status].to_s,
          'stage' => row[:stage].to_s,
          'stage_label' => row[:stage_label].to_s.empty? ? stage_label.to_s : row[:stage_label].to_s,
          'progress' => row[:progress].to_i.positive? ? row[:progress].to_i : progress.to_i,
          'stage_detail' => row[:stage_detail].to_s,
          'stage_elapsed_seconds' => background_publish_stage_elapsed_seconds(row),
          'queued_at' => row[:queued_at].to_s,
          'started_at' => row[:started_at].to_s,
          'finished_at' => row[:finished_at].to_s,
          'error' => row[:error_message].to_s,
          'main_finalize_pending' => !!row[:main_finalize_pending]
        }
      end
    rescue StandardError
      {}
    end

    def background_publish_active_state?(item)
      return false unless item.is_a?(Hash)
      # 运行中的后台任务以“当前 Runtime 的 registry”为唯一事实源。
      # queued/running/finishing 会写进模型状态用于崩溃恢复提示，但 SketchUp 重启/热重载后
      # 旧 worker 已不存在，不能让这个持久字段把空间永久锁死。
      row = background_publish_job_snapshot(item['id'])
      %w[queued running success].include?(row['status'].to_s) || row['main_finalize_pending'] == true
    rescue StandardError
      false
    end

    def clear_orphan_background_publish_state!(item, model = Sketchup.active_model, state = nil)
      return false unless item.is_a?(Hash)
      persisted = item['background_publish_state'].to_s
      return false unless %w[preparing queued running finishing].include?(persisted)
      return false if background_publish_active_state?(item)
      state ||= load_state(model)
      actual = space_model_record(state, item['id']) || item
      actual['background_publish_state'] = ''
      actual['background_publish_job_id'] = ''
      actual['background_publish_error'] = '上次后台发布会话已中断；本机候选如仍存在会继续保留。'
      if initial_space_publish_pending?(actual)
        actual['initial_publish_error'] = '上次首次后台发布会话已中断；本地空间与候选仍保留，可点击重试。'
        actual['status'] = '首次发布中断 · 本地空间已保留 · 可重试'
      else
        actual['status'] = '上次后台发布已中断 · 可继续修改或重新发布'
      end
      background_publish_trace!("ORPHAN_RECOVERY space=#{actual['number']}:#{actual['name']} persisted_state=#{persisted} candidate=#{actual['background_publish_candidate']}")
      save_state(state, model, write_manifest: false) if state && model
      true
    rescue StandardError => e
      log_exception('清理遗留后台发布状态失败', e)
      false
    end

    # v0.13.6.67：发布队列改为 SketchUp 视口 Overlay，不再创建独立 HtmlDialog。
    # 这样完成后记录不会跟着窗口消失，也不会额外占用一个窗口/焦点。
    def space_publish_queue_dialog_html
      ''
    end

    def ensure_space_publish_queue_dialog!
      false
    end

    def refresh_space_publish_queue_dialog!
      true
    end

    def architecture_background_publish_active?(architecture_id)
      space_background_publish_active?("architecture_model:#{architecture_id}")
    end

    def architecture_collection_background_publish_active?(state = nil)
      rows = state.is_a?(Hash) ? Array(state['architecture_models']) : []
      rows.any? { |item| architecture_background_publish_active?(item['id']) }
    rescue StandardError
      false
    end

    def managed_discipline_background_publish_active?(discipline)
      space_background_publish_active?("discipline:#{discipline}")
    end

    # v0.13.6.69：统一队列崩溃/重启恢复。持久化的 queued/running/finishing 只用于提示，
    # 当前 Runtime registry 没有 worker 时必须主动降级为可恢复状态，不能把任何专业永久锁死。
    def clear_orphan_architecture_background_publish_states!(state, model = Sketchup.active_model)
      return false unless state.is_a?(Hash) && model
      changed = false
      Array(state['architecture_models']).each do |item|
        persisted = item['background_publish_state'].to_s
        next unless %w[queued running finishing].include?(persisted)
        next if architecture_background_publish_active?(item['id'])
        candidate = item['background_publish_candidate'].to_s
        if item['initial_publish_pending'] == true
          target = resolve_path(item['model_path'].to_s, model)
          if !target.to_s.empty? && File.file?(target)
            item['initial_publish_error'] = '上次首次后台发布会话中断，但共享目标已经存在；请刷新建筑清单核对，不会自动覆盖。'
            item['status'] = '首次发布会话中断 · 共享目标已存在 · 请刷新核对'
          else
            item['initial_publish_error'] = '上次首次后台发布会话已中断；本地建筑和候选仍保留，可点击重试。'
            item['status'] = '首次发布中断 · 本地建筑已保留 · 可重试'
          end
        else
          item['editing'] = true
          item['edit_safe_paused'] = true
          item['edit_safe_paused_at'] = Time.now.strftime('%Y-%m-%d %H:%M:%S')
          item['edit_safe_pause_reason'] = '后台发布会话中断'
          item['status'] = '后台发布中断 · 未发布建筑修改已安全暂存'
          entity = architecture_model_entity(item['id'], model)
          if entity && entity.valid?
            entity.locked = true if entity.respond_to?(:locked=)
            entity.set_attribute(ENTITY_DICT, 'editing', true)
            entity.set_attribute(ENTITY_DICT, 'safe_paused', true)
          end
        end
        item['background_publish_state'] = ''
        item['background_publish_job_id'] = ''
        item['background_publish_error'] = '上次后台发布 Runtime 已不存在；已转为安全恢复状态。'
        item['background_publish_candidate'] = candidate
        changed = true
        background_publish_trace!("ORPHAN_RECOVERY architecture=#{item['id']} state=#{persisted} candidate=#{candidate}")
      end
      save_state(state, model, write_manifest: false) if changed
      changed
    rescue StandardError => e
      log_exception('清理建筑遗留后台发布状态失败', e)
      false
    end

    def clear_orphan_managed_discipline_background_publish_state!(state, discipline, model = Sketchup.active_model)
      return false unless state.is_a?(Hash) && model
      key = discipline.to_s
      link = state.dig('links', key)
      return false unless link.is_a?(Hash)
      persisted = link['background_publish_state'].to_s
      return false unless %w[queued running finishing].include?(persisted)
      return false if managed_discipline_background_publish_active?(key)
      candidate = link['background_publish_candidate'].to_s
      first_pending = link['first_publish_pending'] == true
      if first_pending
        paths = collab_cache_paths_for(key, model, state) rescue {}
        full = paths.is_a?(Hash) ? paths[:full].to_s : ''
        manifest = paths.is_a?(Hash) ? paths[:manifest].to_s : ''
        if !full.empty? && !manifest.empty? && File.file?(full) && File.file?(manifest)
          link['first_publish_pending'] = false
          link['first_publish_error'] = '上次首次后台发布会话中断，但共享 FULL 与清单均已存在；请点击获取/更新核对。'
          link['status'] = '首次发布会话中断 · 共享版本已存在 · 请获取核对'
        else
          link['first_publish_pending'] = false
          link['first_publish_error'] = '上次首次后台发布会话已中断；本地工作模型仍保留，可重新发布。'
          link['status'] = '首次发布中断 · 本地工作模型已保留 · 可重新发布'
        end
      else
        link['edit_safe_paused'] = true
        link['preview_pending_publish'] = true
        link['edit_session_active'] = true
        link['status'] = '后台发布中断 · 未发布修改已安全暂存 · 可恢复'
        entity = native_edit_entity(key, model)
        if entity && entity.valid?
          entity.locked = true if entity.respond_to?(:locked=)
          entity.set_attribute(ENTITY_DICT, 'editing', true)
          entity.set_attribute(ENTITY_DICT, 'preview_editing', false)
        end
      end
      link['background_publish_state'] = ''
      link['background_publish_job_id'] = ''
      link['background_publish_error'] = '上次后台发布 Runtime 已不存在；已转为安全恢复状态。'
      link['background_publish_candidate'] = candidate
      save_state(state, model, write_manifest: false)
      background_publish_trace!("ORPHAN_RECOVERY discipline=#{key} state=#{persisted} candidate=#{candidate}")
      true
    rescue StandardError => e
      log_exception("清理#{discipline}遗留后台发布状态失败", e)
      false
    end

    def space_background_publish_active?(space_id)
      @space_publish_queue_mutex ||= Mutex.new
      @space_publish_queue_registry ||= {}
      @space_publish_queue_mutex.synchronize do
        row = @space_publish_queue_registry[space_id.to_s]
        row && (%w[queued running success].include?(row[:status].to_s) || row[:main_finalize_pending] == true)
      end
    rescue StandardError
      false
    end

    def any_background_publish_active?
      @space_publish_queue_mutex ||= Mutex.new
      @space_publish_queue_registry ||= {}
      @space_publish_queue_mutex.synchronize do
        @space_publish_queue_registry.values.any? do |row|
          %w[queued running success maintenance].include?(row[:status].to_s) || row[:main_finalize_pending] == true
        end
      end
    rescue StandardError
      false
    end

    def space_publish_queue_snapshot
      @space_publish_queue_mutex ||= Mutex.new
      @space_publish_queue_registry ||= {}
      rows = @space_publish_queue_mutex.synchronize do
        @space_publish_queue_registry.values.map do |row|
          queued_at = row[:queued_at].to_s
          finished_at = row[:finished_at].to_s
          published_at = row[:published_at].to_s
          effective_publish_finish = published_at.empty? ? finished_at : published_at
          publish_elapsed = begin
            if !queued_at.empty? && !effective_publish_finish.empty?
              [(Time.iso8601(effective_publish_finish) - Time.iso8601(queued_at)).to_i, 0].max
            elsif !queued_at.empty?
              [(Time.now - Time.iso8601(queued_at)).to_i, 0].max
            else
              0
            end
          rescue StandardError
            0
          end
          total_elapsed = begin
            if !queued_at.empty? && !finished_at.empty?
              [(Time.iso8601(finished_at) - Time.iso8601(queued_at)).to_i, 0].max
            else
              publish_elapsed
            end
          rescue StandardError
            publish_elapsed
          end
          {
            'job_id' => row[:job_id].to_s,
            'space_id' => row[:space_id].to_s,
            'job_kind' => background_publish_queue_kind(row),
            'label' => row[:label].to_s,
            'initial_publish' => !!row[:initial_publish],
            'status' => row[:status].to_s,
            'queued_at' => queued_at,
            'started_at' => row[:started_at].to_s,
            'finished_at' => finished_at,
            'published_at' => published_at,
            'publish_elapsed_seconds' => publish_elapsed,
            'target' => row[:target].to_s,
            'candidate' => row.dig(:prepared, :path).to_s,
            'stage' => row[:stage].to_s,
            'stage_label' => (row[:stage_label].to_s.empty? ? background_publish_stage_meta(row[:stage], row[:status])[1] : row[:stage_label].to_s),
            'progress' => (row[:progress].to_i.positive? ? row[:progress].to_i : background_publish_stage_meta(row[:stage], row[:status])[0]),
            'stage_detail' => row[:stage_detail].to_s,
            'stage_elapsed_seconds' => background_publish_stage_elapsed_seconds(row),
            'total_elapsed_seconds' => total_elapsed,
            'error' => row[:error_message].to_s,
            'main_finalize_pending' => !!row[:main_finalize_pending],
            'history' => Array(row[:stage_history]).last(8)
          }
        end
      end
      blocking = rows.select { |row| %w[queued running success].include?(row['status'].to_s) || row['main_finalize_pending'] == true }
      maintenance = rows.select { |row| row['status'].to_s == 'maintenance' && !blocking.include?(row) }
      history = rows - blocking - maintenance
      blocking.sort_by! { |row| row['queued_at'].to_s }
      maintenance.sort_by! { |row| row['queued_at'].to_s }.reverse!
      history.sort_by! { |row| row['finished_at'].to_s }.reverse!
      blocking + maintenance + history.first(SPACE_PUBLISH_QUEUE_MAX_HISTORY)
    rescue StandardError
      []
    end

    def trim_space_publish_queue_history!
      @space_publish_queue_mutex ||= Mutex.new
      @space_publish_queue_registry ||= {}
      @space_publish_queue_mutex.synchronize do
        inactive = @space_publish_queue_registry.values.reject { |row| %w[queued running success maintenance].include?(row[:status].to_s) || row[:main_finalize_pending] == true }
        inactive.sort_by! { |row| row[:finished_at].to_s }.reverse!
        keep = inactive.first(SPACE_PUBLISH_QUEUE_MAX_HISTORY).map { |row| row[:job_id].to_s }
        @space_publish_queue_registry.delete_if do |_space_id, row|
          !%w[queued running success maintenance].include?(row[:status].to_s) && row[:main_finalize_pending] != true && !keep.include?(row[:job_id].to_s)
        end
      end
      true
    rescue StandardError
      false
    end

    def clear_completed_space_publish_history!
      @space_publish_queue_mutex ||= Mutex.new
      @space_publish_queue_registry ||= {}
      @space_publish_queue_mutex.synchronize do
        @space_publish_queue_registry.delete_if { |_space_id, row| !%w[queued running success maintenance].include?(row[:status].to_s) && row[:main_finalize_pending] != true }
      end
      persist_space_publish_queue_snapshot!
      refresh_workspace_toolbar(Sketchup.active_model) rescue nil
      true
    rescue StandardError => e
      log_exception('清除发布队列历史失败', e)
      false
    end

    def persist_space_publish_queue_snapshot!(durable: true)
      @space_publish_queue_snapshot_write_mutex ||= Mutex.new
      # This is recovery/diagnostic metadata, not part of the formal SKP transaction. UI and
      # workers must never wait on each other for the same tiny snapshot file.
      return false unless @space_publish_queue_snapshot_write_mutex.try_lock
      # 该快照只用于重启后的队列提示，不参与正式 SKP/manifest 的提交事务。直接覆盖一份
      # 小 JSON 可避开 Windows 对高频 temp->rename 的长时间过滤；写到一半发生崩溃时读取
      # 会安全返回空快照，正式发布的随机 stage/rollback 不受影响。
      begin
        payload = {
          'schema' => 1,
          'plugin_version' => EXTENSION_VERSION,
          'runtime_session_id' => RUNTIME_SESSION_ID.to_s,
          'pid' => Process.pid,
          'updated_at' => Time.now.iso8601(6),
          'jobs' => space_publish_queue_snapshot
        }
        FileUtils.mkdir_p(File.dirname(BACKGROUND_PUBLISH_QUEUE_PATH))
        File.open(BACKGROUND_PUBLISH_QUEUE_PATH, 'wb') do |file|
          file.write(JSON.pretty_generate(payload).encode('UTF-8'))
          file.flush if durable
        end
      ensure
        @space_publish_queue_snapshot_write_mutex.unlock
      end
      true
    rescue StandardError => e
      log_exception('写入后台发布队列快照失败', e)
      false
    end

    # v0.13.6.69：同一后台发布队列同时承载空间、建筑模型、建筑/景观整专业 FULL。
    # worker 只做纯文件 I/O；所有 SketchUp 实体、Definition、锁状态收尾仍回主线程。
    def background_publish_asset_key(job)
      key = job.is_a?(Hash) ? job[:publish_key].to_s : ''
      return key unless key.empty?
      id = job.is_a?(Hash) ? job[:space_id].to_s : ''
      id.empty? ? 'publish' : "space_#{id}"
    end

    def background_publish_queue_kind(job)
      kind = job.is_a?(Hash) ? job[:job_kind].to_s : ''
      kind.empty? ? 'space' : kind
    end

    def background_publish_thread_context(job)
      kind = background_publish_queue_kind(job)
      subject = case kind
                when 'architecture_model'
                  job[:initial_publish] ? "建筑 #{job[:label]} 首次后台发布" : "建筑 #{job[:label]} 后台发布"
                when 'managed_discipline'
                  "#{job[:label]}后台发布"
                when 'discipline_first'
                  "#{job[:label]}首次后台发布"
                else
                  job[:initial_publish] ? "空间 #{job[:label]} 首次后台发布" : "空间 #{job[:label]} 后台发布"
                end
      {
        'schema' => 1,
        'publish_id' => job[:job_id].to_s,
        'kind' => kind,
        'subject' => subject,
        'target' => job[:target].to_s,
        'model_path' => job[:source_model_path].to_s,
        'stage' => 'background_worker_started',
        'stage_at' => Time.now.iso8601(6),
        'stage_index' => 0,
        'details' => {}
      }
    end

    def record_background_publish_history!(payload, success:, error: nil)
      row = payload.is_a?(Hash) ? payload.dup : {}
      row['status'] = success ? 'success' : 'error'
      row['finished_at'] = Time.now.iso8601(6)
      if error
        row['error_class'] = error.class.to_s
        row['error_message'] = error.message.to_s
        row['error_backtrace'] = Array(error.backtrace).first(30)
      end
      FileUtils.mkdir_p(File.dirname(BACKGROUND_PUBLISH_HISTORY_PATH))
      File.open(BACKGROUND_PUBLISH_HISTORY_PATH, 'ab') do |file|
        file.write((JSON.generate(row) + "\n").encode('UTF-8'))
        file.flush
      end
      true
    rescue StandardError => e
      log_exception('写入后台发布历史失败', e)
      false
    end

    def enqueue_space_publish_job!(job, model = Sketchup.active_model)
      raise '后台发布任务无效。' unless job.is_a?(Hash)
      space_id = job[:space_id].to_s
      raise '后台发布任务缺少空间 ID。' if space_id.empty?
      @space_publish_queue_mutex ||= Mutex.new
      @space_publish_queue ||= []
      @space_publish_queue_registry ||= {}
      @space_publish_queue_results ||= Queue.new
      @space_publish_queue_mutex.synchronize do
        existing = @space_publish_queue_registry[space_id]
        replacing_native_preparation = existing && existing[:native_preparation] == true &&
                                       existing[:job_id].to_s == job[:job_id].to_s
        if existing && (%w[queued running success].include?(existing[:status].to_s) || existing[:main_finalize_pending] == true) &&
           !replacing_native_preparation
          raise "#{existing[:label]} 已在发布队列中。"
        end
        job[:status] = 'queued'
        job[:stage] = 'queued'
        job[:stage_label] = '等待后台发布'
        job[:progress] = 5
        job[:main_finalize_pending] = false
        job[:queued_at] = Time.now.iso8601(6)
        job[:stage_at] = job[:queued_at]
        job[:stage_history] = [{ 'at' => job[:queued_at], 'stage' => 'queued', 'label' => '等待后台发布', 'progress' => 5, 'detail' => '' }]
        @space_publish_queue << job
        @space_publish_queue_registry[space_id] = job
      end
      persist_space_publish_queue_snapshot!
      start_space_publish_queue_worker!
      ensure_space_publish_queue_poll_timer!
      true
    end

    def finalize_first_discipline_remote_files_background!(job, result)
      return true unless background_publish_queue_kind(job) == 'discipline_first'
      manifest = job[:first_manifest].is_a?(Hash) ? job[:first_manifest].dup : {}
      manifest_path = job[:first_manifest_path].to_s
      project_dir = job[:project_dir].to_s
      raise '首次后台发布缺少专业 manifest 路径。' if manifest_path.empty?
      manifest['full_signature'] = result[:signature].to_s
      manifest['generated_at'] = Time.now.iso8601(6) if manifest['generated_at'].to_s.empty?
      manifest['published_by'] = current_user_name if manifest['published_by'].to_s.empty?
      manifest['host'] = current_host_name if manifest['host'].to_s.empty?
      manifest['plugin_version'] = EXTENSION_VERSION
      temp = "#{manifest_path}.tmp-#{Process.pid}-#{SecureRandom.hex(3)}"
      ensure_metadata_target!(manifest_path)
      File.write(temp, JSON.pretty_generate(manifest), mode: 'w:UTF-8')
      promote_file_create_only!(temp, manifest_path)
      project_manifest_path = ''
      unless project_dir.empty?
        project_manifest_path = write_project_collab_manifest!(
          project_dir,
          job[:discipline].to_s,
          manifest.merge('manifest_path' => manifest_path, 'full_resolved' => job[:target].to_s)
        )
      end
      job[:first_manifest] = manifest
      job[:project_manifest_path] = project_manifest_path.to_s
      true
    rescue StandardError => e
      # FULL 已经 create-only 成功而 manifest 失败时，只在确认内容仍是本次候选时回收 FULL，
      # 避免留下“有 SKP 无清单”的半发布状态，也绝不删除别人随后改写过的文件。
      begin
        target = job[:target].to_s
        expected = result.is_a?(Hash) ? result[:content_signature].to_s : ''
        if !target.empty? && File.file?(target) && !expected.empty? && full_file_content_signature(target) == expected
          File.delete(target)
        end
      rescue StandardError => cleanup_error
        log_exception('首次专业后台发布清单失败后回收 FULL 失败', cleanup_error)
      end
      raise e
    ensure
      File.delete(temp) if defined?(temp) && temp && File.file?(temp)
    end

    # Formal commits and maintenance use separate serial lanes. Maintenance intentionally waits
    # while any upload/commit is queued or running, so snapshots and history can never delay the
    # next user publish or compete with it for the same NAS disk queue.
    def space_publish_formal_work_pending?
      @space_publish_queue_mutex ||= Mutex.new
      @space_publish_queue ||= []
      @space_publish_queue_registry ||= {}
      @space_publish_queue_mutex.synchronize do
        !@space_publish_queue.empty? || @space_publish_queue_registry.values.any? do |row|
          if row[:native_preparation] == true
            row[:status].to_s == 'running'
          else
            %w[queued running].include?(row[:status].to_s)
          end
        end
      end
    rescue StandardError
      false
    end

    def enqueue_space_publish_maintenance!(job, result, context, candidate_path)
      @space_publish_maintenance_mutex ||= Mutex.new
      @space_publish_maintenance_queue ||= []
      task = {
        job: job, result: result, context: context,
        candidate_path: candidate_path.to_s, queued_at: monotonic_time
      }
      @space_publish_maintenance_mutex.synchronize { @space_publish_maintenance_queue << task }
      start_space_publish_maintenance_worker!
      true
    rescue StandardError => e
      log_exception("发布后维护入队失败（正式发布仍成功）：#{job[:label]}", e)
      false
    end

    def perform_space_publish_maintenance!(task)
      job = task[:job]
      result = task[:result].is_a?(Hash) ? task[:result] : {}
      candidate_path = task[:candidate_path].to_s
      context = task[:context].is_a?(Hash) ? task[:context] : background_publish_thread_context(job)
      warnings = []
      Thread.current[:sulink_async_publish_context] = context
      Thread.current[:sulink_async_publish_job] = job

      if result[:post_publish_maintenance_pending]
        while space_publish_formal_work_pending? && !@shutting_down
          sleep(0.08)
        end
        begin
          publish_breadcrumb!('safe_checkpoint_begin', target: job[:target].to_s)
          checkpoint = write_latest_safe_publish_checkpoint!(
            job[:target].to_s, background_publish_asset_key(job),
            signature: result[:signature].to_s,
            expected_content_signature: result[:content_signature].to_s
          )
          result[:safe_checkpoint] = checkpoint.to_s
          publish_breadcrumb!('safe_checkpoint_returned', checkpoint: checkpoint.to_s, ok: !checkpoint.to_s.empty?)
          warnings << '最近安全快照未写入' if checkpoint.to_s.empty?
        rescue StandardError => e
          warnings << "最近安全快照：#{e.message}"
          publish_breadcrumb!('safe_checkpoint_deferred_failed', error: e.message.to_s)
          log_exception("后台安全快照失败（正式发布已完成）：#{job[:label]}", e)
        end

        while space_publish_formal_work_pending? && !@shutting_down
          sleep(0.08)
        end
        rollback_path = result[:rollback_path].to_s
        if !rollback_path.empty? && File.file?(rollback_path)
          begin
            publish_breadcrumb!('rollback_archive_begin', rollback: rollback_path)
            history = archive_publish_rollback!(job[:target].to_s, rollback_path, background_publish_asset_key(job))
            result[:history] = history.to_s
            publish_breadcrumb!('rollback_archive_returned', history_backup: history.to_s, ok: !history.to_s.empty?)
            warnings << "发布前版本归档失败，已保留 #{rollback_path}" if history.to_s.empty?
          rescue StandardError => e
            warnings << "发布前版本归档：#{e.message}"
            publish_breadcrumb!('rollback_archive_deferred_failed', error: e.message.to_s, rollback: rollback_path)
            log_exception("后台发布前版本归档失败（正式发布已完成）：#{job[:label]}", e)
          end
        end

        while space_publish_formal_work_pending? && !@shutting_down
          sleep(0.08)
        end
        begin
          personal_source = result[:safe_checkpoint].to_s
          personal_source = job[:target].to_s unless !personal_source.empty? && File.file?(personal_source)
          publish_breadcrumb!('personal_checkpoint_deferred_begin', source: personal_source)
          personal = write_personal_publish_checkpoint!(
            personal_source, background_publish_asset_key(job),
            signature: result[:signature].to_s, published_target: job[:target].to_s,
            expected_content_signature: result[:content_signature].to_s
          )
          result[:personal_checkpoint] = personal.to_s
          result[:personal_checkpoint_pending] = false
          publish_breadcrumb!('personal_checkpoint_deferred_returned', checkpoint: personal.to_s, ok: !personal.to_s.empty?)
          warnings << '个人最近发布快照未写入' if personal.to_s.empty?
        rescue StandardError => e
          warnings << "个人快照：#{e.message}"
          publish_breadcrumb!('personal_checkpoint_deferred_failed', error: e.message.to_s)
          log_exception("后台个人发布快照失败（正式发布已完成）：#{job[:label]}", e)
        end
        result[:post_publish_maintenance_pending] = false
      end

      begin
        keep_candidate = job[:recovery_plan].is_a?(Hash) && !!job[:recovery_plan]['candidate_adopted']
        File.delete(candidate_path) if !keep_candidate && File.file?(candidate_path)
      rescue StandardError => e
        warnings << "本机候选稍后清理：#{e.message}"
        log_exception("后台候选清理延后（正式发布已完成）：#{job[:label]}", e)
      end

      @space_publish_queue_mutex.synchronize do
        job[:status] = 'completed'
        job[:stage] = 'background_maintenance_completed'
        job[:stage_label] = warnings.empty? ? '发布完成 · 后台整理完成' : '发布完成 · 后台整理有警告'
        job[:progress] = 100
        job[:finished_at] = Time.now.iso8601(6)
        job[:maintenance_warning] = warnings.join('；')
        job[:stage_detail] = job[:maintenance_warning].to_s
        job[:result] = result
      end
      trim_space_publish_queue_history!
      true
    rescue StandardError => e
      @space_publish_queue_mutex.synchronize do
        job[:status] = 'completed'
        job[:stage] = 'background_maintenance_completed'
        job[:stage_label] = '发布完成 · 后台整理有警告'
        job[:progress] = 100
        job[:finished_at] = Time.now.iso8601(6)
        job[:maintenance_warning] = "后台整理：#{e.message}"
        job[:stage_detail] = job[:maintenance_warning]
      end rescue nil
      log_exception("后台发布后维护异常（正式发布仍成功）：#{job[:label]}", e)
      false
    ensure
      close_background_publish_trace185!
      Thread.current[:sulink_async_publish_context] = nil
      Thread.current[:sulink_async_publish_job] = nil
      persist_space_publish_queue_snapshot!(durable: false)
    end

    def start_space_publish_maintenance_worker!
      return false if @shutting_down
      @space_publish_maintenance_mutex ||= Mutex.new
      @space_publish_maintenance_queue ||= []
      created = false
      @space_publish_maintenance_mutex.synchronize do
        return true if @space_publish_maintenance_thread && @space_publish_maintenance_thread.alive?
        @space_publish_maintenance_thread = Thread.new do
          Thread.current.name = 'SU_LinkHub-publish-maintenance' if Thread.current.respond_to?(:name=)
          # Give consecutive clicks a short chance to fill the formal lane before low-priority I/O.
          sleep(0.25)
          loop do
            while space_publish_formal_work_pending? && !@shutting_down
              sleep(0.08)
            end
            break if @shutting_down
            task = @space_publish_maintenance_mutex.synchronize { @space_publish_maintenance_queue.shift }
            break unless task
            perform_space_publish_maintenance!(task)
          end
        ensure
          restart = false
          @space_publish_maintenance_mutex.synchronize do
            @space_publish_maintenance_thread = nil if Thread.current == @space_publish_maintenance_thread
            restart = !@shutting_down && !@space_publish_maintenance_queue.empty?
          end rescue nil
          start_space_publish_maintenance_worker! if restart
        end
        register_background_gvl_thread!(@space_publish_maintenance_thread)
        created = true
      end
      created || true
    rescue StandardError => e
      log_exception('启动发布后维护 worker 失败', e)
      false
    end

    def start_space_publish_queue_worker!
      return false if @shutting_down
      @space_publish_queue_mutex ||= Mutex.new
      @space_publish_queue ||= []
      @space_publish_queue_registry ||= {}
      @space_publish_queue_results ||= Queue.new
      created = false
      @space_publish_queue_mutex.synchronize do
        return true if @space_publish_queue_thread && @space_publish_queue_thread.alive?
        @space_publish_queue_thread = Thread.new do
          Thread.current.name = 'SU_LinkHub-space-publish' if Thread.current.respond_to?(:name=)
          loop do
            job = nil
            @space_publish_queue_mutex.synchronize do
              job = @space_publish_queue.shift
              if job
                job[:status] = 'running'
                job[:stage] = 'background_worker_started'
                job[:stage_label] = '后台任务已启动'
                job[:progress] = 8
                job[:started_at] = Time.now.iso8601(6)
              end
            end
            break unless job
            context = background_publish_thread_context(job)
            Thread.current[:sulink_async_publish_context] = context
            Thread.current[:sulink_async_publish_job] = job
            remote_publish_completed = false
            begin
              publish_breadcrumb!('background_candidate_verify_begin', candidate: job.dig(:prepared, :path).to_s)
              prepared = job[:prepared].is_a?(Hash) ? job[:prepared] : {}
              candidate_path = prepared[:path].to_s
              raise '后台发布候选文件不存在。' unless File.file?(candidate_path) && File.size(candidate_path).positive?
              prepared[:content_signature] = background_full_file_content_signature(candidate_path) if prepared[:content_signature].to_s.empty?
              raise '后台发布候选无法生成完整内容指纹。' if prepared[:content_signature].to_s.empty?
              prepared[:verified_fast_signature] = fast_file_signature(candidate_path)
              raise '后台发布候选完整校验后无法读取快速签名。' if prepared[:verified_fast_signature].to_s.empty?
              publish_breadcrumb!('background_candidate_verify_returned', size: File.size(candidate_path), fast: prepared[:verified_fast_signature])

              if job[:recovery_plan].is_a?(Hash)
                persist_space_recovery_from_candidate_background!(
                  job[:recovery_plan], prepared, proxy_layout: !!job[:proxy_layout]
                )
              end

              publish_breadcrumb!('background_remote_publish_begin')
              result = atomic_publish_prepared_candidate!(
                prepared,
                job[:target].to_s,
                background_publish_asset_key(job),
                { 'name' => job[:label].to_s },
                expected_signature: job[:expected_signature].to_s,
                baseline_path: (job[:baseline_path].to_s.empty? ? job[:target].to_s : job[:baseline_path].to_s),
                baseline_signature: (job[:baseline_signature].to_s.empty? ? job[:expected_signature].to_s : job[:baseline_signature].to_s),
                force_overwrite: !!job[:force_overwrite],
                source_model_path: job[:source_model_path].to_s,
                keep_local_candidate: true,
                defer_personal_checkpoint: true,
                defer_post_publish_maintenance: true
              )
              publish_breadcrumb!('background_remote_publish_returned', signature: result[:signature].to_s, size: result[:size].to_i)
              finalize_first_discipline_remote_files_background!(job, result) if background_publish_queue_kind(job) == 'discipline_first'

              # Formal shared content is committed. Main-thread finalization receives immutable
              # snapshots, while low-priority maintenance owns the mutable result from here on.
              completion_job = nil
              completion_result = result.dup
              @space_publish_queue_mutex.synchronize do
                job[:status] = 'maintenance'
                job[:stage] = 'post_publish_maintenance_begin'
                job[:stage_label] = '正式发布完成 · 后台整理'
                job[:progress] = 97
                job[:published_at] = Time.now.iso8601(6)
                job[:stage_at] = job[:published_at]
                job[:result] = result
                job[:main_finalize_pending] = true
                completion_job = job.dup
              end
              @space_publish_queue_results << { job: completion_job, success: true, result: completion_result }
              remote_publish_completed = true
              record_background_publish_history!(context, success: true)
              unless enqueue_space_publish_maintenance!(job, result, context.dup, candidate_path)
                @space_publish_queue_mutex.synchronize do
                  job[:status] = 'completed'
                  job[:stage] = 'background_maintenance_completed'
                  job[:stage_label] = '发布完成 · 后台整理待下次启动'
                  job[:progress] = 100
                  job[:finished_at] = Time.now.iso8601(6)
                  job[:maintenance_warning] = '维护线程未启动；正式发布不受影响，候选与回滚文件已保留'
                  job[:stage_detail] = job[:maintenance_warning]
                end
              end
            rescue StandardError => e
              if remote_publish_completed
                # No post-commit failure may reverse an already delivered success completion.
                log_exception("后台发布后记录异常（正式发布仍成功）：#{job[:label]}", e)
              else
                completion_job = nil
                @space_publish_queue_mutex.synchronize do
                  job[:status] = 'failed'
                  job[:stage] = 'background_publish_failed'
                  job[:stage_label] = '后台发布失败'
                  job[:progress] = 100
                  job[:finished_at] = Time.now.iso8601(6)
                  job[:error_class] = e.class.to_s
                  job[:error_message] = e.message.to_s
                  job[:error_backtrace] = Array(e.backtrace).first(20)
                  job[:main_finalize_pending] = true
                  completion_job = job.dup
                end
                publish_breadcrumb!('background_publish_failed', error: e.message.to_s)
                record_background_publish_history!(context, success: false, error: e)
                @space_publish_queue_results << { job: completion_job, success: false, error: e }
                log_exception("后台发布失败：#{job[:label]}", e)
              end
            ensure
              close_background_publish_trace185!
              Thread.current[:sulink_async_publish_context] = nil
              Thread.current[:sulink_async_publish_job] = nil
              persist_space_publish_queue_snapshot!
            end
          end
        ensure
          restart = false
          @space_publish_queue_mutex.synchronize do
            @space_publish_queue_thread = nil if Thread.current == @space_publish_queue_thread
            restart = !@shutting_down && !@space_publish_queue.empty?
          end rescue nil
          start_space_publish_queue_worker! if restart
        end
        register_background_gvl_thread!(@space_publish_queue_thread)
        created = true
      end
      created || true
    rescue StandardError => e
      log_exception('启动空间后台发布 worker 失败', e)
      false
    end

    def sync_background_publish_queue_ui_state!(model = Sketchup.active_model)
      return false unless model
      rows = space_publish_queue_snapshot
      active = rows.select { |row| %w[queued running success].include?(row['status'].to_s) || row['main_finalize_pending'] == true }

      # 队列面板要保留 completed/failed/maintenance 历史，所以 UI 刷新签名必须看全部 rows，
      # 不能像 6.64 一样“active 为空就直接 return”，否则任务一完成面板就停在旧画面或消失。
      ui_signature = [model.object_id, rows.map do |row|
        elapsed_bucket = row['stage_elapsed_seconds'].to_i / 2
        [row['job_id'], row['status'], row['stage'], row['progress'], elapsed_bucket, row['stage_detail'].to_s]
      end].inspect
      if @background_publish_workspace_signature.to_s != ui_signature
        @background_publish_workspace_signature = ui_signature
        refresh_publish_queue_overlay_only!(model)
        sync_background_publish_floating_notice!(rows, active, model)
      end

      # The 0.12s progress poll must not reload/normalize the complete project state every pass.
      # Synchronize the persisted display hint only when a job changes blocking phase.
      state_sync_signature = [model.object_id, active.map do |row|
        [row['job_id'], row['space_id'], row['status'], row['main_finalize_pending'] == true]
      end].inspect
      if !active.empty? && @background_publish_state_sync_signature.to_s != state_sync_signature
        state = load_state(model)
        state_changed = false
        active.each do |row|
          item = space_model_record(state, row['space_id'])
          next unless item
          desired_state = if row['status'].to_s == 'queued'
                            'queued'
                          elsif row['status'].to_s == 'success' || row['main_finalize_pending'] == true
                            'finishing'
                          else
                            'running'
                          end
          if item['background_publish_state'].to_s != desired_state
            item['background_publish_state'] = desired_state
            state_changed = true
          end
        end
        save_state(state, model, write_manifest: false) if state_changed
        @background_publish_state_sync_signature = state_sync_signature
      end
      @background_publish_state_sync_signature = '' if active.empty?

      @background_publish_heartbeat_at ||= {}
      active.each do |row|
        next unless row['status'].to_s == 'running'
        job_id = row['job_id'].to_s
        elapsed = row['stage_elapsed_seconds'].to_i
        last_bucket = @background_publish_heartbeat_at[job_id].to_i
        bucket = elapsed / 10
        next if bucket <= last_bucket
        @background_publish_heartbeat_at[job_id] = bucket
        # Stage transitions are already written by the file worker. A main-thread heartbeat must
        # stay memory-only or Windows/NAS filters can turn it into a periodic viewport hitch.
        if [3, 6, 12, 30].include?(bucket)
          show_status("#{row['label']} 后台发布 #{row['progress']}% · #{row['stage_label']} · 本阶段已 #{elapsed}s", elapsed >= 60 ? 'warning' : 'info')
        end
      end
      true
    rescue StandardError => e
      log_exception('同步后台发布队列界面状态失败', e)
      background_publish_trace!("UI_SYNC_ERROR #{e.class}: #{e.message}")
      false
    end

    def sync_background_publish_floating_notice!(rows, active_rows = nil, model = Sketchup.active_model)
      return false unless model && model == Sketchup.active_model
      active = active_rows || Array(rows).select do |row|
        %w[queued running success].include?(row['status'].to_s) || row['main_finalize_pending'] == true
      end
      @background_publish_notice_active_ids ||= []
      previous_active_ids = @background_publish_notice_active_ids
      current_active_ids = active.map { |row| row['job_id'].to_s }
      @background_publish_notice_active_ids = current_active_ids

      unless active.empty?
        primary = active.find { |row| row['status'].to_s == 'running' } || active.first
        progress = active.sum { |row| row['progress'].to_i }.to_f / active.length
        prefix = active.length > 1 ? "发布队列 · #{active.length} 项" : primary['label'].to_s
        message = "#{prefix} · #{primary['stage_label']}"
        show_workspace_floating_notice(message, 'info', progress: progress, persistent: true, model: model)
        return true
      end

      # 首次打开已有历史时保持安静；只在本轮确实由活动状态转为结束时报告结果。
      return false if previous_active_ids.empty?
      finished = Array(rows).reverse.find { |row| previous_active_ids.include?(row['job_id'].to_s) }
      return false unless finished
      failed = finished['status'].to_s == 'failed'
      label = finished['label'].to_s
      message = failed ? "#{label} · 发布失败 · #{finished['error_message']}" : "#{label} · 发布完成"
      show_workspace_floating_notice(
        message, failed ? 'error' : 'success', progress: 100,
        duration: failed ? 5.5 : 3.2, model: model
      )
      true
    rescue StandardError => e
      log_exception('同步后台发布悬浮进度失败', e)
      false
    end

    def ensure_space_publish_queue_poll_timer!
      return true if @space_publish_queue_poll_timer
      @space_publish_queue_deferred_results ||= []
      timer_id = nil
      timer_id = runtime_start_timer(SPACE_PUBLISH_QUEUE_POLL_INTERVAL, true, label: 'publish:space_queue_poll') do
        begin
          model = Sketchup.active_model
          sync_background_publish_queue_ui_state!(model)
          pending = @space_publish_queue_deferred_results
          @space_publish_queue_deferred_results = []
          while @space_publish_queue_results && !@space_publish_queue_results.empty?
            pending << @space_publish_queue_results.pop(true)
          end
          pending.each do |completion|
            finalized = finalize_background_publish_completion!(completion, model)
            @space_publish_queue_deferred_results << completion unless finalized
          end

          worker_alive = @space_publish_queue_thread && @space_publish_queue_thread.alive?
          queue_empty = @space_publish_queue_mutex ? @space_publish_queue_mutex.synchronize { @space_publish_queue.empty? } : true
          results_empty = (!@space_publish_queue_results || @space_publish_queue_results.empty?) && @space_publish_queue_deferred_results.empty?
          maintenance_alive = @space_publish_maintenance_thread && @space_publish_maintenance_thread.alive?
          maintenance_empty = @space_publish_maintenance_mutex ? @space_publish_maintenance_mutex.synchronize { @space_publish_maintenance_queue.empty? } : true
          if !worker_alive && queue_empty && results_empty && !maintenance_alive && maintenance_empty
            runtime_stop_timer(timer_id) if timer_id
            @space_publish_queue_poll_timer = nil
          end
        rescue ThreadError
          nil
        rescue StandardError => e
          log_exception('轮询空间后台发布结果失败', e)
        end
      end
      @space_publish_queue_poll_timer = timer_id
      true
    rescue StandardError => e
      log_exception('启动空间后台发布结果轮询失败', e)
      false
    end

    def background_publish_main_finalize_ready?(completion, model = Sketchup.active_model)
      return true unless completion.is_a?(Hash) && completion[:success]
      return false unless model && model == Sketchup.active_model
      key = model.object_id
      click_tool = (@workspace_toolbar_click_tools || {})[key]
      return false if workspace_double_click_interaction_active?(model)
      return false if click_tool.is_a?(Hash) && click_tool[:active]
      return false if workspace_toolbar_fast_interaction_active?(model)
      # The upload has already committed at this point. Release the collaboration state at the
      # first safe main-thread tick instead of adding another camera/idle wait after 100% upload.
      runtime_interaction_age(model) >= 0.08
    rescue StandardError
      true
    end

    def finalize_background_publish_completion!(completion, model = Sketchup.active_model)
      return false unless background_publish_main_finalize_ready?(completion, model)
      job = completion.is_a?(Hash) ? completion[:job] : nil
      kind = background_publish_queue_kind(job)
      case kind
      when 'architecture_model'
        finalize_background_architecture_publish!(completion, model)
      when 'managed_discipline'
        finalize_background_managed_discipline_publish!(completion, model)
      when 'discipline_first'
        finalize_background_discipline_first_publish!(completion, model)
      else
        finalize_background_space_publish!(completion, model)
      end
    end

    def mark_background_publish_registry_finalized!(job, success)
      @space_publish_queue_mutex ||= Mutex.new
      @space_publish_queue_registry ||= {}
      @space_publish_queue_mutex.synchronize do
        retained = @space_publish_queue_registry[job[:space_id].to_s]
        if retained && retained[:job_id].to_s == job[:job_id].to_s
          retained[:main_finalize_pending] = false
          if success
            unless %w[maintenance completed].include?(retained[:status].to_s)
              retained[:status] = 'completed'
              retained[:stage] = 'background_publish_completed'
              retained[:stage_label] = '发布完成'
              retained[:progress] = 100
              retained[:finished_at] = Time.now.iso8601(6) if retained[:finished_at].to_s.empty?
            end
          else
            retained[:status] = 'failed'
            retained[:stage] = 'background_publish_failed'
            retained[:stage_label] = '发布失败'
            retained[:progress] = 100
            retained[:finished_at] = Time.now.iso8601(6) if retained[:finished_at].to_s.empty?
          end
        end
      end
      trim_space_publish_queue_history!
      persist_space_publish_queue_snapshot!(durable: false)
      true
    rescue StandardError => e
      log_exception('更新统一发布队列收尾状态失败', e)
      false
    end

    def background_publish_model_matches_job?(job, model)
      return false unless job.is_a?(Hash) && model
      source_model_path = job[:source_model_path].to_s
      if source_model_path.empty?
        job[:model_object_id].to_i == model.object_id
      else
        !model.path.to_s.empty? && same_file_path?(model.path.to_s, source_model_path)
      end
    rescue StandardError
      false
    end

    def finalize_background_architecture_publish!(completion, model = Sketchup.active_model)
      return false if publish_critical_section? || publish_post_quiet? || @architecture_explicit_publish_in_progress
      return true unless completion.is_a?(Hash)
      job = completion[:job]
      return true unless job.is_a?(Hash)
      return false unless background_publish_model_matches_job?(job, model)
      state = ensure_architecture_models_ready!(model)
      item = architecture_model_record(state, job[:architecture_id].to_s)
      unless item
        log("建筑后台发布已完成但当前模型找不到记录：#{job[:label]}")
        mark_background_publish_registry_finalized!(job, completion[:success])
        return true
      end
      entity = architecture_model_entity(item['id'], model)
      current_job_id = item['background_publish_job_id'].to_s
      if !current_job_id.empty? && current_job_id != job[:job_id].to_s
        log("忽略旧建筑后台发布收尾：#{job[:label]} / #{job[:job_id]} != #{current_job_id}")
        return true
      end

      if completion[:success]
        result = completion[:result].is_a?(Hash) ? completion[:result] : {}
        signature = result[:signature].to_s
        revision = job[:source_revision].to_s
        now = Time.now.iso8601(6)
        initial = !!job[:initial_publish] || item['initial_publish_pending'] == true
        lock_snapshot = item.dup
        item['model_path'] = store_path(job[:target].to_s, model)
        item['last_signature'] = signature
        item['source_revision'] = revision
        item['last_publish_at'] = now
        item['last_publish_by'] = current_user_name
        item['last_publish_host'] = current_host_name
        item['last_publish_plugin_version'] = EXTENSION_VERSION
        item['last_update'] = now
        item['editing'] = false
        item['publish_pending'] = false
        item['edit_safe_paused'] = false
        item['background_publish_state'] = 'finishing'
        item['background_publish_job_id'] = job[:job_id].to_s
        item['background_publish_candidate'] = ''
        item['background_publish_error'] = ''
        if entity && entity.valid?
          entity.locked = true if entity.respond_to?(:locked=)
          entity.set_attribute(ENTITY_DICT, 'editing', false)
          entity.set_attribute(ENTITY_DICT, 'safe_paused', false)
          mark_architecture_model_entity!(entity, item, item['model_path'], signature, model, revision: revision)
        end
        if initial
          item['initial_publish_pending'] = false
          item['initial_publish_candidate'] = ''
          item['initial_publish_error'] = ''
        else
          restore_architecture_model_isolation!(item, model)
        end
        # 建筑清单/分组是共享真相源；JSON 很小，留在主线程只做最后登记，不再传大 SKP。
        write_architecture_models_manifest!(state, model, local_model_ids: [item['id']])
        released = true
        unless initial
          released = release_space_lock!(
            lock_snapshot, job[:target].to_s, clear_state: false,
            process_cleanup: true, model: model, state: state
          )
          clear_space_lock_state!(item) if released
          clear_edit_root_protection!(edit_root_key_for_architecture_model(item['id']), model)
        end
        item['background_publish_state'] = released ? '' : 'lock_release_failed'
        item['background_publish_job_id'] = ''
        item['status'] = released ? '已更新' : '后台发布完成 · 协作锁释放失败 · 请刷新后处理'
        save_state(state, model, write_manifest: false)
        show_status("#{job[:label]} 后台发布完成#{released ? '' : '；协作锁未自动释放'}。", released ? 'success' : 'error')
      else
        error = completion[:error]
        msg = error ? error.message.to_s : job[:error_message].to_s
        candidate = job.dig(:prepared, :path).to_s
        if job[:initial_publish] || item['initial_publish_pending'] == true
          item['initial_publish_pending'] = true
          item['initial_publish_candidate'] = candidate
          item['initial_publish_error'] = msg
          item['editing'] = false
          item['status'] = '首次发布失败 · 本地建筑已保留 · 可重试'
          entity.locked = true if entity && entity.valid? && entity.respond_to?(:locked=)
        else
          item['editing'] = true
          item['edit_safe_paused'] = true
          item['edit_safe_paused_at'] = Time.now.strftime('%Y-%m-%d %H:%M:%S')
          item['edit_safe_pause_reason'] = '建筑后台发布失败'
          item['status'] = '后台发布失败 · 未发布建筑修改已安全暂存'
          if entity && entity.valid?
            entity.locked = true if entity.respond_to?(:locked=)
            entity.set_attribute(ENTITY_DICT, 'editing', true)
            entity.set_attribute(ENTITY_DICT, 'safe_paused', true)
          end
        end
        item['background_publish_state'] = 'failed'
        item['background_publish_job_id'] = ''
        item['background_publish_candidate'] = candidate
        item['background_publish_error'] = msg
        save_state(state, model, write_manifest: false)
        show_status("#{job[:label]} 后台发布失败：#{msg}", 'error')
      end
      mark_background_publish_registry_finalized!(job, !!completion[:success])
      refresh_dialog
      refresh_workspace_toolbar(model) rescue nil
      true
    rescue StandardError => e
      log_exception('完成建筑后台发布主线程收尾失败', e)
      false
    end

    def finalize_background_managed_discipline_publish!(completion, model = Sketchup.active_model)
      return false if publish_critical_section? || publish_post_quiet? || @architecture_explicit_publish_in_progress
      return true unless completion.is_a?(Hash)
      job = completion[:job]
      return true unless job.is_a?(Hash)
      return false unless background_publish_model_matches_job?(job, model)
      discipline = job[:discipline].to_s
      state = load_state(model)
      link = state.dig('links', discipline)
      return true unless link
      entity = native_edit_entity(discipline, model)
      if completion[:success]
        result = completion[:result].is_a?(Hash) ? completion[:result] : {}
        recorded = record_direct_collab_commit!(state, discipline, link, result, model)
        if collab_shared_cache_model_path?(job[:target].to_s) && !recorded
          link['background_publish_state'] = 'finishing'
          link['status'] = '正式共享文件已发布 · 版本清单登记待重试'
          save_state(state, model, write_manifest: false)
          return false
        end
        model.start_operation("完成#{link['name']}后台发布", true)
        if entity && entity.valid?
          entity.locked = true if entity.respond_to?(:locked=)
          entity.set_attribute(ENTITY_DICT, 'editing', false)
          entity.set_attribute(ENTITY_DICT, 'preview_editing', false)
          entity.set_attribute(ENTITY_DICT, 'source', store_path(job[:target].to_s, model))
          entity.set_attribute(ENTITY_DICT, 'source_signature', result[:signature].to_s)
          entity.set_attribute(ENTITY_DICT, 'source_file_signature', result[:signature].to_s)
          entity.set_attribute(ENTITY_DICT, 'source_revision', authoritative_link_revision(link, job[:target].to_s))
        end
        model.commit_operation
        link['native_publish_path'] = store_path(job[:target].to_s, model)
        link['native_original_source_path'] = link['model_path'].to_s if link['native_original_source_path'].to_s.empty?
        link['native_last_publish_at'] = Time.now.strftime('%Y-%m-%d %H:%M:%S')
        link['last_update'] = link['native_last_publish_at']
        link['last_commit_result'] = 'success'
        link['last_commit_path'] = store_path(job[:target].to_s, model)
        link['last_commit_backup_path'] = result[:backup].to_s
        link['last_commit_verified'] = true
        link['status'] = '后台发布完成 · 已写回共享 SKP'
        update_file_stamp(link, link['model_path'], job[:target].to_s)
        release_source_lock(link, job[:target].to_s, model, state)
        clear_edit_state!(link, restore_previous: false)
        clear_preview_state!(link, restore_auto: true)
        clear_edit_root_protection!(discipline, model)
        link['background_publish_state'] = ''
        link['background_publish_job_id'] = ''
        link['background_publish_candidate'] = ''
        link['background_publish_error'] = ''
        save_state(state, model)
        show_status("#{link['name']}后台发布完成。", 'success')
      else
        error = completion[:error]
        msg = error ? error.message.to_s : job[:error_message].to_s
        link['background_publish_state'] = 'failed'
        link['background_publish_job_id'] = ''
        link['background_publish_candidate'] = job.dig(:prepared, :path).to_s
        link['background_publish_error'] = msg
        link['last_commit_result'] = 'error'
        link['last_commit_verified'] = false
        link['status'] = "后台发布失败 · 继续修改 · #{msg}"
        if entity && entity.valid?
          entity.locked = false if entity.respond_to?(:locked=)
          entity.set_attribute(ENTITY_DICT, 'editing', true)
          entity.set_attribute(ENTITY_DICT, 'preview_editing', true)
          source = resolve_source_for_edit(link['model_path'].to_s, model)
          begin_preview_state!(link, entity, source, model) if File.file?(source)
        end
        save_state(state, model, write_manifest: false)
        show_status("#{link['name']}后台发布失败：#{msg}", 'error')
      end
      mark_background_publish_registry_finalized!(job, !!completion[:success])
      refresh_dialog
      refresh_workspace_toolbar(model) rescue nil
      true
    rescue StandardError => e
      model.abort_operation rescue nil
      log_exception('完成建筑/景观整专业后台发布收尾失败', e)
      false
    end

    def finalize_background_discipline_first_publish!(completion, model = Sketchup.active_model)
      return false if publish_critical_section? || publish_post_quiet?
      return true unless completion.is_a?(Hash)
      job = completion[:job]
      return true unless job.is_a?(Hash)
      return false unless background_publish_model_matches_job?(job, model)
      discipline = job[:discipline].to_s
      state = load_state(model)
      link = state.dig('links', discipline)
      return true unless link
      if completion[:success]
        result = completion[:result].is_a?(Hash) ? completion[:result] : {}
        manifest = job[:first_manifest].is_a?(Hash) ? job[:first_manifest] : {}
        paths = {
          full: job[:target].to_s,
          manifest: job[:first_manifest_path].to_s
        }
        apply_published_collab_cache_to_state!(state, discipline, manifest, paths, job[:project_manifest_path].to_s, model)
        link['background_publish_state'] = ''
        link['background_publish_job_id'] = ''
        link['background_publish_candidate'] = ''
        link['background_publish_error'] = ''
        link['first_publish_pending'] = false
        link['first_publish_error'] = ''
        link['status'] = '首次后台发布完成 · 可点击获取/修改'
        save_state(state, model)
        show_status("#{link['name']}首次后台发布完成；无需等待快照整理，可继续其它操作。", 'success')
      else
        error = completion[:error]
        msg = error ? error.message.to_s : job[:error_message].to_s
        link['background_publish_state'] = 'failed'
        link['background_publish_job_id'] = ''
        link['background_publish_candidate'] = job.dig(:prepared, :path).to_s
        link['background_publish_error'] = msg
        link['first_publish_pending'] = false
        link['first_publish_error'] = msg
        link['status'] = "首次后台发布失败 · 本地工作模型保留 · #{msg}"
        save_state(state, model, write_manifest: false)
        show_status("#{link['name']}首次后台发布失败：#{msg}", 'error')
      end
      mark_background_publish_registry_finalized!(job, !!completion[:success])
      refresh_dialog
      refresh_workspace_toolbar(model) rescue nil
      true
    rescue StandardError => e
      log_exception('完成建筑/景观首次后台发布收尾失败', e)
      false
    end

    def finalize_background_space_publish!(completion, model = Sketchup.active_model)
      return false if publish_critical_section? || publish_post_quiet? || @space_publish_in_progress || @space_explicit_publish_in_progress
      return true unless completion.is_a?(Hash)
      job = completion[:job]
      return true unless job.is_a?(Hash)
      source_model_path = job[:source_model_path].to_s
      return false unless model
      if source_model_path.empty?
        return false unless job[:model_object_id].to_i == model.object_id
      else
        return false unless !model.path.to_s.empty? && same_file_path?(model.path.to_s, source_model_path)
      end

      state = load_state(model)
      item = space_model_record(state, job[:space_id])
      unless item
        log("后台发布已完成但当前模型找不到空间：#{job[:label]}")
        mark_background_publish_registry_finalized!(job, !!completion[:success])
        return true
      end
      entity = space_model_entity(item['id'], model)
      current_job_id = item['background_publish_job_id'].to_s
      if !current_job_id.empty? && current_job_id != job[:job_id].to_s
        log("忽略旧后台发布收尾：#{job[:label]} / #{job[:job_id]} != #{current_job_id}")
        return true
      end

      if completion[:success]
        result = completion[:result].is_a?(Hash) ? completion[:result] : {}
        lock_snapshot = item.dup
        signature = result[:signature].to_s
        revision = job[:source_revision].to_s
        now = Time.now.iso8601(6)
        item['editing'] = false
        item['edit_safe_paused'] = false
        item['edit_safe_paused_at'] = ''
        item['edit_safe_pause_reason'] = ''
        item['publish_pending'] = false
        item['last_signature'] = signature
        item['source_revision'] = revision
        item['last_publish_at'] = now
        item['last_publish_by'] = current_user_name
        item['last_publish_host'] = current_host_name
        item['last_publish_plugin_version'] = EXTENSION_VERSION
        item['last_update'] = now
        item['model_path'] = store_path(job[:target].to_s, model)
        component_plan = Array(job[:shared_component_publish_plan]).select { |row| row.is_a?(Hash) && !row[:id].to_s.empty? }
        if component_plan.empty?
          item['component_bundle_id'] = ''
          item['component_bundle_state'] = ''
          item['component_bundle_started_at'] = ''
          item['component_bundle_completed_at'] = ''
          item['component_bundle_dependencies'] = []
        else
          item['component_bundle_id'] = job[:job_id].to_s
          item['component_bundle_state'] = 'pending'
          item['component_bundle_started_at'] = now
          item['component_bundle_completed_at'] = ''
          item['component_bundle_dependencies'] = component_plan.map do |row|
            { 'id' => row[:id].to_s, 'name' => row[:name].to_s, 'content_signature' => row[:content_signature].to_s }
          end
        end
        was_initial_publish = job[:initial_publish] || initial_space_publish_pending?(item)
        item['background_publish_state'] = 'finishing'
        item['background_publish_job_id'] = job[:job_id].to_s
        item['background_publish_candidate'] = ''
        item['background_publish_error'] = ''
        item['status'] = job[:proxy_layout] ? '后台发布完成 · 正在收尾' : '后台发布完成 · 真模型候选 · 正在收尾'
        item['status'] = "#{item['status']} · 安全快照失败" if result[:safe_checkpoint].to_s.empty? && !result[:post_publish_maintenance_pending]

        if entity && entity.valid?
          entity.locked = true if entity.respond_to?(:locked=)
          entity.set_attribute(ENTITY_DICT, 'editing', false)
          entity.set_attribute(ENTITY_DICT, 'safe_paused', false)
          entity.set_attribute(ENTITY_DICT, 'source_file_signature', signature)
          entity.set_attribute(ENTITY_DICT, 'source_revision', revision)
          entity.set_attribute(ENTITY_DICT, 'source_load_verified_schema', SPACE_LOAD_VERIFIED_SCHEMA)
          entity.set_attribute(ENTITY_DICT, 'source_verified_signature', signature)
          entity.set_attribute(ENTITY_DICT, 'source_package_revision', revision)
          entity.set_attribute(ENTITY_DICT, 'source_package_identity', 'background-publish')
        end
        linked_ids = linked_space_dependents(state, item['id']).map { |linked| linked['id'].to_s }
        sync_linked_space_instances_for_source!(state, item, entity, model) if entity && entity.valid?
        # 先写发布版本与共享 manifest，但暂不清本机锁身份。若 manifest 写失败，
        # 下一次主线程收尾仍能使用原 token 继续释放物理锁。
        save_state(state, model, write_manifest: false)
        write_space_models_manifest!(
          state, model, preserve_remote_layout: true, local_space_ids: [item['id']] + linked_ids,
          include_initial_space_ids: (was_initial_publish ? [item['id']] : [])
        )
        # merge_latest_space_manifest_for_content_write! 会规范化并替换 state 内的记录 Hash。
        # 写共享 manifest 后必须重新按稳定 id 取得当前记录，不能继续修改已经脱离 state 的旧引用。
        item = space_model_record(state, job[:space_id]) || item
        # 首次发布只有在共享 SKP + 两份共享 manifest 都成功落盘后才清掉 pending。
        # 任一 manifest 写失败时保留 pending，可由同一 completion 在下一帧继续收尾。
        if was_initial_publish
          # 独立空间分组清单也是共享真相源。首次发布如果带新组，必须在清 pending 前
          # 把当前空间的 group membership 一并写成功；否则下一次分组同步会把本地组归属冲掉。
          write_space_groups_manifest!(state, model, include_initial_space_ids: [item['id']])
          item['initial_publish_pending'] = false
          item['initial_publish_candidate'] = ''
          item['initial_publish_error'] = ''
        end
        # 后台发布完成时用户通常已经切到其它工作区。释放的是本任务入队时保留的
        # 当前进程锁，不能再用此刻 UI 的工作区角色判断，否则发布成功后会遗留占用。
        released = release_space_lock!(
          lock_snapshot, job[:target].to_s, clear_state: false,
          process_cleanup: true, model: model, state: state
        )
        if released
          clear_space_lock_state!(item)
          item['background_publish_state'] = ''
          item['background_publish_job_id'] = ''
          item['status'] = job[:proxy_layout] ? '已更新' : '真模型已更新'
          item['status'] = "#{item['status']} · 安全快照失败" if result[:safe_checkpoint].to_s.empty? && !result[:post_publish_maintenance_pending]
          save_state(state, model, write_manifest: false)
        else
          item['background_publish_state'] = 'lock_release_failed'
          item['background_publish_job_id'] = ''
          item['status'] = '后台发布完成 · 协作锁释放失败 · 请刷新后处理'
          save_state(state, model, write_manifest: false)
        end
        clear_edit_root_protection!(edit_root_key_for_space(item['id']), model)
        @native_lock_state_cache ||= {}
        @native_lock_state_cache[space_native_cache_key(model, item['id'])] = true
        mark_soft_resident_space_releasable!(
          item['id'].to_s, model, reason: 'background_publish', grace: SOFT_RESIDENT_CACHE_PUBLISH_GRACE_SECONDS
        )
        message = "#{job[:label]} 后台发布完成"
        message += '；协作锁未能自动释放' unless released
        show_status(message, released ? 'success' : 'error')
        log("空间后台发布完成：#{job[:label]} / #{job[:job_id]} / #{result[:size].to_i} bytes")
        mark_soft_measurement_dirty(model, item['id']) rescue nil
        bump_soft_measurement_revision(model) rescue nil
        # 发布成功只把清单快照标为已变化。清单打开或用户点击刷新时再重新统计，
        # 避免共享发布刚结束就紧接一次 2~4 秒的全空间扫描，造成第二次前台卡顿。
        mark_soft_schedule_snapshot_stale!(model, item['id'], revision_already_bumped: true) rescue nil
        if Array(job[:shared_component_publish_plan]).any?
          queued_components = enqueue_shared_component_publish_plan_from_space!(job, model) rescue false
          unless queued_components
            finalize_space_component_bundle_state!(item['id'].to_s, job[:job_id].to_s, 'incomplete', model) rescue nil
          end
        end
      else
        error = completion[:error]
        candidate_path = job.dig(:prepared, :path).to_s
        error_message = error ? error.message.to_s : job[:error_message].to_s
        if job[:initial_publish] || initial_space_publish_pending?(item)
          # 首次发布失败不能伪装成“已有共享上一版的未发布编辑”。本地新空间继续保留并锁定，
          # 释放 reservation 后允许用户明确点击“重试”；再次发布仍使用 create-only，不会覆盖别人。
          item['initial_publish_pending'] = true
          item['initial_publish_candidate'] = candidate_path
          item['initial_publish_error'] = error_message
          item['background_publish_state'] = 'failed'
          item['background_publish_job_id'] = ''
          item['background_publish_candidate'] = candidate_path
          item['background_publish_error'] = error_message
          item['editing'] = false
          item['publish_pending'] = false
          item['edit_safe_paused'] = false
          item['edit_safe_paused_at'] = ''
          item['edit_safe_pause_reason'] = ''
          item['status'] = '首次发布失败 · 本地空间已保留 · 可重试'
          if entity && entity.valid?
            entity.locked = true if entity.respond_to?(:locked=)
            entity.set_attribute(ENTITY_DICT, 'editing', false)
            entity.set_attribute(ENTITY_DICT, 'safe_paused', false)
          end
          release_space_lock!(
            item, job[:target].to_s, clear_state: true,
            process_cleanup: true, model: model, state: state
          ) rescue nil
        else
          item['background_publish_state'] = 'failed'
          item['background_publish_job_id'] = ''
          item['background_publish_candidate'] = candidate_path
          item['background_publish_error'] = error_message
          item['editing'] = true
          item['publish_pending'] = false
          item['edit_safe_paused'] = true
          item['edit_safe_paused_at'] = Time.now.strftime('%Y-%m-%d %H:%M:%S')
          item['edit_safe_pause_reason'] = '后台发布失败'
          item['status'] = '后台发布失败 · 未发布修改已安全暂存'
          if entity && entity.valid?
            entity.locked = true if entity.respond_to?(:locked=)
            entity.set_attribute(ENTITY_DICT, 'editing', true)
            entity.set_attribute(ENTITY_DICT, 'safe_paused', true)
          end
        end
        save_state(state, model, write_manifest: false)
        @native_lock_state_cache ||= {}
        @native_lock_state_cache[space_native_cache_key(model, item['id'])] = true
        message = "#{job[:label]} 后台发布失败：#{error_message}"
        show_status(message, 'error')
        log("#{message} / 本机候选保留：#{candidate_path}")
      end

      mark_background_publish_registry_finalized!(job, !!completion[:success])
      refresh_dialog
      refresh_workspace_toolbar(model) rescue nil
      true
    rescue StandardError => e
      log_exception('完成空间后台发布主线程收尾失败', e)
      false
    end

    # 空间发布的 SketchUp 原生候选保存不能进 Ruby Thread。这里把它从按钮回调
    # 移到可避让队列：目标空间先安全锁回，用户可立即进入其它空间；只在世界根、
    # 前台无操作且相机稳定时执行。真正的共享盘发布仍由现有文件 worker 完成。
    def enqueue_native_space_publish_preparation!(item, entity, model = Sketchup.active_model)
      raise '空间发布准备任务无效。' unless item.is_a?(Hash) && entity && entity.valid? && model
      space_id = item['id'].to_s
      raise '空间发布准备任务缺少空间 ID。' if space_id.empty?
      label = "#{item['number']}:#{item['name']}"
      job_id = "prepspace-#{Time.now.strftime('%Y%m%d_%H%M%S')}-#{Process.pid}-#{SecureRandom.hex(4)}"
      operation_open = false

      @space_publish_queue_mutex ||= Mutex.new
      @space_publish_queue_registry ||= {}
      @native_space_publish_prep_queues ||= {}
      @native_space_publish_prep_timers ||= {}
      queue = (@native_space_publish_prep_queues[model.object_id] ||= [])
      existing = @space_publish_queue_mutex.synchronize { @space_publish_queue_registry[space_id] }
      if existing && (%w[queued running success].include?(existing[:status].to_s) || existing[:main_finalize_pending] == true)
        raise "#{existing[:label]} 已在发布队列中。"
      end

      state = load_state(model)
      current_item = space_model_record(state, space_id)
      current_entity = current_item ? space_model_entity(space_id, model) : nil
      raise '发布准备前未能重新定位空间根组件。' unless current_item && current_entity && current_entity.valid?
      model.start_operation("暂存发布任务 #{label}", true, false, true)
      operation_open = true
      restore_space_isolation!(current_item, model)
      current_entity.locked = true if current_entity.respond_to?(:locked=)
      current_entity.set_attribute(ENTITY_DICT, 'editing', true)
      current_entity.set_attribute(ENTITY_DICT, 'safe_paused', true)
      clear_space_publish_pending!(current_item)
      current_item['editing'] = true
      current_item['edit_safe_paused'] = true
      current_item['edit_safe_paused_at'] = Time.now.strftime('%Y-%m-%d %H:%M:%S')
      current_item['edit_safe_pause_reason'] = '等待空闲窗口生成发布候选'
      current_item['background_publish_state'] = 'preparing'
      current_item['background_publish_job_id'] = job_id
      current_item['background_publish_error'] = ''
      current_item['status'] = '已加入发布队列 · 等待视图空闲'
      state['space_editing_id'] = '' if state['space_editing_id'].to_s == space_id
      state['space_edit_display_mode'] = ''
      save_state(state, model, write_manifest: false)
      model.commit_operation
      operation_open = false
      @native_lock_state_cache ||= {}
      @native_lock_state_cache[space_native_cache_key(model, space_id)] = true
      @space_edit_contexts&.delete(model.object_id)
      clear_edit_root_protection!(edit_root_key_for_space(space_id), model)

      now = Time.now.iso8601(6)
      row = {
        job_id: job_id, space_id: space_id, label: label, status: 'queued',
        stage: 'native_preparation_wait', stage_label: '等待视图空闲', progress: 2,
        stage_detail: '可继续编辑其它空间；退出到世界根并停止操作后自动开始',
        queued_at: now, started_at: '', finished_at: '', stage_at: now,
        error_message: '', main_finalize_pending: false, native_preparation: true,
        stage_history: [{ 'at' => now, 'stage' => 'native_preparation_wait', 'label' => '等待视图空闲', 'progress' => 2,
                          'detail' => '可继续编辑其它空间；退出到世界根并停止操作后自动开始' }]
      }
      request = {
        job_id: job_id, space_id: space_id, label: label, model: model,
        queued_at: monotonic_time, user_handoff: true, row: row
      }
      @space_publish_queue_mutex.synchronize { @space_publish_queue_registry[space_id] = row }
      queue << request
      persist_space_publish_queue_snapshot!(durable: false)
      started = ensure_native_space_publish_preparation_driver!(model, delay: 0.08)
      raise '未能启动发布候选准备队列；空间已保持安全暂存。' unless started
      show_status("#{label} 已加入发布队列；可继续编辑其它空间，空闲时自动发布。", 'success')
      refresh_dialog
      refresh_workspace_toolbar(model) rescue nil
      true
    rescue StandardError => e
      model.abort_operation rescue nil if operation_open
      if defined?(request) && request
        queue&.delete(request)
        fail_native_space_publish_preparation!(request, e)
      end
      raise e
    end

    def native_space_publish_preparation_wait_reason(model = Sketchup.active_model, request = nil)
      return '等待返回当前模型' unless model && model == Sketchup.active_model
      return '正在编辑其它空间，退出后继续' unless model.active_path.nil?

      queued_age = if request.is_a?(Hash) && request[:queued_at].to_f.positive?
                     [monotonic_time - request[:queued_at].to_f, 0.0].max
                   else
                     0.0
                   end

      # 这两个标记只应存在于 publish_space_now/publish_space_model 的同步调用栈内。
      # 若候选队列已经等待数秒、原生发布临界区也早已释放，说明标记属于异常中断残留；
      # 继续等待只会永久卡在 2%。自动清理比要求用户热重载更安全、更可恢复。
      stale_space_publish_flag = (@space_publish_in_progress || @space_explicit_publish_in_progress) &&
                                 !publish_critical_section? && queued_age >= NATIVE_SPACE_PUBLISH_PREP_TRANSACTION_MAX_WAIT_SECONDS
      if stale_space_publish_flag
        log("空间发布候选自愈：清理残留前台发布标记 / queued=#{queued_age.round(2)}s") unless request.is_a?(Hash) && request[:stale_publish_flag_repaired]
        request[:stale_publish_flag_repaired] = true if request.is_a?(Hash)
        @space_publish_in_progress = false
        @space_explicit_publish_in_progress = false
      end

      # :publish heavy-interaction 与发布临界区成对出现。临界区已经不存在却仍残留计数时，
      # 也属于异常中断门禁；只清理 :publish，不触碰缩略图/入库/代理等真实重任务。
      publish_heavy = (@soft_heavy_interactions || {})[:publish].to_i
      if publish_heavy.positive? && !publish_critical_section? && queued_age >= NATIVE_SPACE_PUBLISH_PREP_TRANSACTION_MAX_WAIT_SECONDS
        @soft_heavy_interactions.delete(:publish) if @soft_heavy_interactions
        @soft_heavy_interaction_started_at.delete(:publish) if @soft_heavy_interaction_started_at
        log("空间发布候选自愈：清理残留 publish heavy-interaction=#{publish_heavy}") unless request.is_a?(Hash) && request[:stale_publish_heavy_repaired]
        request[:stale_publish_heavy_repaired] = true if request.is_a?(Hash)
      end

      return '前台正在保存或更新，完成后继续' if @space_publish_in_progress || @space_explicit_publish_in_progress ||
                                                        @updating || @single_space_update_job || @space_batch_update_job ||
                                                        @soft_model_batch_job || soft_ingest_batch_processing? || @soft_thumbnail_rendering ||
                                                        soft_schedule_batch_applying? || soft_heavy_interaction? || publish_critical_section?
      if request.is_a?(Hash) && @soft_ingest_batch_job.is_a?(Hash) && @soft_ingest_batch_job[:model].equal?(model) &&
         @soft_ingest_batch_job[:space_id].to_s == request[:space_id].to_s
        return "本空间待入库家具处理中（#{soft_ingest_batch_queue_summary(@soft_ingest_batch_job)}），完成后继续"
      end
      return '六面代理正在生成，完成后继续' if @soft_visual_proxy_upgrade_job
      return '正在处理双击进入，完成后继续' if workspace_double_click_interaction_active?(model)
      return '正在执行前台工具操作' if workspace_toolbar_fast_interaction_active?(model)

      age = runtime_interaction_age(model)
      source = runtime_last_interaction_source(model)
      if source == 'model_transaction'
        # ModelObserver 事务可能来自 LinkHub 自己。只等待很短的 transaction quiet；
        # 若事务流持续刷新超过上限，在其它硬门禁均已通过的前提下自动放行。
        if age < NATIVE_SPACE_PUBLISH_PREP_TRANSACTION_IDLE_SECONDS &&
           queued_age < NATIVE_SPACE_PUBLISH_PREP_TRANSACTION_MAX_WAIT_SECONDS
          return '等待模型事务提交完成'
        end
        if age < NATIVE_SPACE_PUBLISH_PREP_TRANSACTION_IDLE_SECONDS && request.is_a?(Hash) && !request[:transaction_wait_bypassed]
          request[:transaction_wait_bypassed] = true
          log("空间发布候选自愈：连续模型事务已等待 #{queued_age.round(2)}s，忽略后台事务节流并继续")
        end
      else
        required_idle = request.is_a?(Hash) && request[:user_handoff] == true ?
                          NATIVE_SPACE_PUBLISH_PREP_FAST_IDLE_SECONDS : NATIVE_SPACE_PUBLISH_PREP_IDLE_SECONDS
        if age < required_idle
          return '等待前台操作停稳'
        end
      end

      return '等待相机停稳' unless runtime_camera_quiet?(model)
      ''
    rescue StandardError
      '等待安全执行窗口'
    end

    def update_native_space_publish_preparation_wait!(request, reason)
      row = request.is_a?(Hash) ? request[:row] : nil
      return false unless row.is_a?(Hash)
      reason = reason.to_s
      now = monotonic_time
      if request[:last_wait_reason].to_s == reason
        since = request[:last_wait_reason_since].to_f
        if since.positive? && (now - since) >= NATIVE_SPACE_PUBLISH_PREP_WAIT_DIAGNOSTIC_SECONDS && !request[:wait_reason_diagnostic_logged]
          request[:wait_reason_diagnostic_logged] = true
          source = runtime_last_interaction_source(request[:model])
          log("空间发布候选持续等待：#{request[:label]} / #{reason} / #{(now - since).round(1)}s / interaction=#{source.empty? ? 'unknown' : source}")
        end
        return true
      end
      request[:last_wait_reason] = reason
      request[:last_wait_reason_since] = now
      request[:wait_reason_diagnostic_logged] = false
      @space_publish_queue_mutex.synchronize do
        row[:status] = 'queued'
        row[:stage] = 'native_preparation_wait'
        row[:stage_label] = '等待视图空闲'
        row[:progress] = 2
        row[:stage_detail] = reason
        row[:stage_at] = Time.now.iso8601(6)
      end
      refresh_publish_queue_overlay_only!(request[:model]) rescue nil
      true
    rescue StandardError
      false
    end

    def ensure_native_space_publish_preparation_driver!(model = Sketchup.active_model, delay: NATIVE_SPACE_PUBLISH_PREP_RETRY_SECONDS)
      return false unless model && !@shutting_down
      @native_space_publish_prep_queues ||= {}
      @native_space_publish_prep_timers ||= {}
      key = model.object_id
      if (existing_timer = @native_space_publish_prep_timers[key])
        # 一次性 runtime timer 可能因模型 token/generation 变化被包装器丢弃；旧实现只看
        # Hash 中是否有 timer id，会把已经不存在的 timer 当成“driver 仍在运行”，从而永久 2%。
        if runtime_timer_registry.key?(existing_timer)
          return true
        end
        @native_space_publish_prep_timers.delete(key)
        log("空间发布候选自愈：发现失效 driver timer=#{existing_timer}，已重新调度")
      end
      timer_id = nil
      timer_id = runtime_start_timer(delay.to_f, false, label: 'publish:native_space_preparation', model: model) do
        @native_space_publish_prep_timers.delete(key) if @native_space_publish_prep_timers[key] == timer_id
        process_native_space_publish_preparation_queue!(model)
      end
      @native_space_publish_prep_timers[key] = timer_id
      true
    rescue StandardError => e
      log_exception('启动空间发布候选准备队列失败', e)
      false
    end

    def fail_native_space_publish_preparation!(request, error)
      model = request[:model]
      state = load_state(model)
      item = space_model_record(state, request[:space_id])
      entity = item ? space_model_entity(item['id'], model) : nil
      if item
        entity.locked = true if entity && entity.valid? && entity.respond_to?(:locked=)
        entity.set_attribute(ENTITY_DICT, 'editing', true) if entity && entity.valid?
        entity.set_attribute(ENTITY_DICT, 'safe_paused', true) if entity && entity.valid?
        item['editing'] = true
        item['edit_safe_paused'] = true
        item['edit_safe_paused_at'] = Time.now.strftime('%Y-%m-%d %H:%M:%S')
        item['edit_safe_pause_reason'] = '发布候选准备失败'
        item['background_publish_state'] = 'failed'
        item['background_publish_job_id'] = ''
        item['background_publish_error'] = error.message.to_s
        item['status'] = '发布准备失败 · 未发布修改已安全暂存'
        save_state(state, model, write_manifest: false)
      end
      row = request[:row]
      if row.is_a?(Hash)
        @space_publish_queue_mutex.synchronize do
          row[:status] = 'failed'
          row[:stage] = 'native_preparation_failed'
          row[:stage_label] = '发布准备失败'
          row[:progress] = 100
          row[:stage_detail] = error.message.to_s
          row[:error_message] = error.message.to_s
          row[:finished_at] = Time.now.iso8601(6)
          row[:stage_at] = row[:finished_at]
          row[:native_preparation] = false
        end
      end
      persist_space_publish_queue_snapshot!(durable: false)
      log_exception('空间发布候选准备失败', error)
      show_status("#{request[:label]} 发布准备失败：#{error.message}。修改与占用已保留，可重试发布。", 'error')
      refresh_dialog
      refresh_workspace_toolbar(model) rescue nil
      false
    rescue StandardError => recovery_error
      log_exception('恢复发布候选准备失败状态时出错', recovery_error)
      false
    end

    def process_native_space_publish_preparation_queue!(model = Sketchup.active_model)
      return false unless model && !@shutting_down
      attempted = false
      @native_space_publish_prep_queues ||= {}
      queue = (@native_space_publish_prep_queues[model.object_id] ||= [])
      request = queue.first
      return false unless request.is_a?(Hash)
      reason = native_space_publish_preparation_wait_reason(model, request)
      unless reason.empty?
        update_native_space_publish_preparation_wait!(request, reason)
        ensure_native_space_publish_preparation_driver!(model)
        return true
      end

      row = request[:row]
      attempted = true
      @space_publish_queue_mutex.synchronize do
        row[:status] = 'running'
        row[:stage] = 'native_preparation_running'
        row[:stage_label] = '正在生成本机发布候选'
        row[:progress] = 4
        row[:stage_detail] = 'SketchUp 原生保存阶段；完成后自动转入纯文件后台队列'
        row[:started_at] = Time.now.iso8601(6) if row[:started_at].to_s.empty?
        row[:stage_at] = Time.now.iso8601(6)
      end
      refresh_publish_queue_overlay_only!(model) rescue nil
      publish_space_model(request[:space_id], confirm: false, native_handoff: true, native_job_id: request[:job_id])
      true
    rescue StandardError => e
      if attempted && defined?(request) && request
        fail_native_space_publish_preparation!(request, e)
      else
        log_exception('空间发布候选准备队列轮询失败', e)
        ensure_native_space_publish_preparation_driver!(model)
      end
      false
    ensure
      if attempted && defined?(request) && request
        current_queue = (@native_space_publish_prep_queues || {})[model.object_id]
        current_queue.shift if current_queue && current_queue.first.equal?(request)
        if current_queue && !current_queue.empty?
          ensure_native_space_publish_preparation_driver!(model, delay: NATIVE_SPACE_PUBLISH_PREP_RETRY_SECONDS)
        end
      end
    end

    def stop_native_space_publish_preparation_queue!
      Array((@native_space_publish_prep_timers || {}).values).each { |timer| runtime_stop_timer(timer) if timer }
      @native_space_publish_prep_timers = {}
      @native_space_publish_prep_queues = {}
      true
    rescue StandardError
      false
    end

    def stop_space_publish_queue_worker!
      timer = @space_publish_queue_poll_timer
      runtime_stop_timer(timer) if timer
      @space_publish_queue_poll_timer = nil
      thread = @space_publish_queue_thread
      if thread && thread.alive? && thread != Thread.current
        thread.join(5.0)
        log('SketchUp 正在退出，后台发布仍在完成当前纯文件任务；候选和诊断记录已保留。') if thread.alive?
      end
      maintenance_thread = @space_publish_maintenance_thread
      if maintenance_thread && maintenance_thread.alive? && maintenance_thread != Thread.current
        maintenance_thread.join(2.0)
        log('SketchUp 正在退出，发布后快照整理将在下次启动时继续核对。') if maintenance_thread.alive?
      end
      true
    rescue StandardError => e
      log_exception('停止空间后台发布 worker 失败', e)
      false
    end

    # v0.13.6.190：代理队列中断后“继续发布”的空间在短时间内不再重复进入代理等待，
    # 否则 resume → defer → 再起队列 → 再中断 会形成循环，用户只看到“发布暂停”。
    SPACE_PUBLISH_SKIP_PROXY_DEFER_SECONDS = 300.0 unless const_defined?(:SPACE_PUBLISH_SKIP_PROXY_DEFER_SECONDS, false)

    def space_publish_proxy_defer_skipped?(space_id)
      stamp = (@space_publish_skip_proxy_defer || {})[space_id.to_s]
      return false unless stamp
      return true if monotonic_time - stamp.to_f < SPACE_PUBLISH_SKIP_PROXY_DEFER_SECONDS
      @space_publish_skip_proxy_defer.delete(space_id.to_s)
      false
    rescue StandardError
      false
    end

    def mark_space_publish_skip_proxy_defer!(space_id)
      @space_publish_skip_proxy_defer ||= {}
      @space_publish_skip_proxy_defer[space_id.to_s] = monotonic_time
      true
    end

    def clear_space_publish_skip_proxy_defer!(space_id)
      @space_publish_skip_proxy_defer&.delete(space_id.to_s)
      true
    rescue StandardError
      false
    end

    # v0.13.6.190：发布交接/结束编辑时仍有家具切不到代理，不再整单阻止。
    # 候选阶段（prepare_single_space_publish_candidate!）对同一批家具已经按 v0.13.6.182 规则
    # 以真模型随包发布（mixed）并排队补齐代理；交接阶段再为同一原因 raise，只会把已经
    # 生成的候选删掉、让用户反复看到“仍有 N 件家具未能切换到可发布代理”。
    # 这里改为：空间根标记 mixed，缺代理的实例保持真模型，后台补齐后自动替换。
    def tolerate_space_publish_proxy_shortfall!(item, entity, model, result, context: '发布', schedule_repair: true)
      return '' unless result.is_a?(Hash) && result[:unresolved].to_i.positive?
      soft_set_attribute_if_changed(entity, ENTITY_DICT, 'space_representation', 'mixed') if entity && entity.valid?
      pending = Array(result[:unresolved_instances]).select { |instance| instance && instance.valid? }
      held = Array(result[:held_instances]).select { |instance| instance && instance.valid? }
      names = begin
        soft_proxy_switch_instance_summary(pending + held, limit: 4)
      rescue StandardError
        ''
      end
      names = "#{result[:unresolved].to_i} 件家具" if names.to_s.empty?
      label = "#{item['number']}:#{item['name']}"
      log("#{context}：#{label} 有 #{result[:unresolved].to_i} 件家具暂无可用代理（#{names}；待入库#{held.length}），保持真模型，不再阻止#{context}")
      if schedule_repair && !pending.empty?
        space_id = item['id'].to_s
        ids = pending.map(&:object_id)
        runtime_start_timer(1.2, false, label: 'soft:publish_handoff_proxy_repair', key: "soft:publish_handoff_proxy_repair:#{model.object_id}:#{space_id}", model: model) do
          begin
            targets = pending.select { |instance| instance && instance.valid? && ids.include?(instance.object_id) }
            unless targets.empty?
              schedule_soft_lost_proxy_auto_repair!(targets, model, scope_space_id: space_id, reason: "#{context}后补齐缺失代理", notify: true, replace: true)
            end
          rescue StandardError => e
            log_exception("#{context}后排队补齐代理失败", e)
          end
        end
      end
      "#{names} 暂无可用代理，已保持真模型，代理会在后台补齐"
    rescue StandardError => e
      log_exception('处理发布代理缺口失败', e)
      ''
    end

    def defer_space_publish_until_pending_proxies_ready!(item, entity, model = Sketchup.active_model)
      if space_publish_proxy_defer_skipped?(item['id'])
        log("发布前代理等待已跳过：#{item['number']}:#{item['name']}（上一轮代理队列中断，本次以现有代理/真模型继续发布）")
        return false
      end
      records = soft_pending_proxy_records_for_space(item, entity, model)
      # 已经明确失败的款不再反复拦发布：它们保持真模型随包发布（混合包），日志与任务卡已记录原因。
      failed_records = records.select { |record| record[:phase].to_s == 'failed' }
      records -= failed_records
      unless failed_records.empty?
        log("发布前跳过已失败的代理重建：#{soft_furniture_name_summary(failed_records.map { |record| record[:model_name].to_s })}（保持真模型随包发布）")
      end
      return false if records.empty?
      # v0.13.6.182：已有代理队列时不再报错——本空间的待重建款会合并进同一条队列，
      # 队列结束后自动继续发布（resume 逻辑已按 space_id 匹配）。
      @space_publish_after_proxy ||= {}
      key = model.object_id
      existing = @space_publish_after_proxy[key]
      return true if existing.is_a?(Hash) && existing[:space_id].to_s == item['id'].to_s

      records.each do |record|
        record[:phase] = :queued
        record[:error] = ''
      end
      @space_publish_after_proxy[key] = {
        space_id: item['id'].to_s,
        label: "#{item['number']}:#{item['name']}",
        requested_at: monotonic_time
      }
      started = start_soft_pending_proxy_exit_batch!(
        model, scope_space_id: item['id'].to_s, reason: '发布队列准备六面代理',
        foreground_exit_batch: false
      )
      unless started
        # v0.13.6.190：代理任务起不来（队列忙/工作进程不可用）不再拦住发布：
        # 候选阶段会把缺代理的家具以真模型随包发布，并另行排队补齐。
        @space_publish_after_proxy.delete(key)
        log("发布前六面代理任务未能启动：#{item['number']}:#{item['name']}，改为直接发布（缺代理家具保持真模型）")
        return false
      end
      pending_names = soft_furniture_name_summary(records.map { |record| record[:model_name].to_s }, limit: 4)
      fresh_state = load_state(model)
      fresh_item = space_model_record(fresh_state, item['id'])
      if fresh_item
        fresh_item['status'] = "发布准备中 · 正在生成代理：#{pending_names}"
        save_state(fresh_state, model, write_manifest: false)
      end
      show_status("#{item['number']}:#{item['name']} 已进入发布准备；正在生成 #{pending_names} 的代理，完成后自动发布，可继续其它空间。", 'info')
      show_workspace_floating_notice("发布准备中 · 生成代理：#{pending_names}", 'info', duration: 3.5, model: model)
      true
    rescue StandardError
      @space_publish_after_proxy&.delete(model.object_id) if model
      raise
    end

    def resume_space_publish_after_proxy_job!(job, model = Sketchup.active_model, aborted: false, abort_message: '')
      return false unless model
      key = model.object_id
      request = (@space_publish_after_proxy || {})[key]
      return false unless request.is_a?(Hash)
      failed = job.is_a?(Hash) ? job[:failed].to_i : 1
      if aborted
        # v0.13.6.190：代理队列中断不再让发布请求“暂停后丢失”。按 v0.13.6.182 的混合包规则
        # 继续发布：已有代理的家具用代理，其余保持真模型；短时间内跳过代理等待以免循环。
        detail = abort_message.to_s
        detail = '代理队列已停止' if detail.empty?
        mark_space_publish_skip_proxy_defer!(request[:space_id].to_s)
        log("发布前代理队列中断：#{request[:label]} / #{detail}；继续发布（缺代理家具保持真模型）")
        show_status("#{request[:label]}：代理队列中断（#{detail}），缺代理的家具将以真模型随空间发布，发布继续。", 'warning')
        show_workspace_floating_notice("代理中断 · 改用真模型继续发布", 'warning', duration: 4.5, model: model)
      end
      if failed.positive? && !aborted
        # v0.13.6.182：单款代理失败不再拦住整个空间发布。失败款保持真模型随包发布
        # （候选阶段自动形成混合包），这里只把名单告诉用户，然后照常继续。
        failed_names = soft_furniture_name_summary(Array(job[:errors]).map { |row| row[:name].to_s }, limit: 4)
        show_status("#{request[:label]}：#{failed_names} 的代理生成失败，将以真模型随空间发布；其余家具已使用新代理，发布继续。", 'warning')
        show_workspace_floating_notice("代理失败改用真模型发布 · #{failed_names}", 'warning', duration: 4.5, model: model)
      end

      runtime_start_timer(0.10, false, label: 'space:publish_resume_after_proxy', key: "space:publish_resume_after_proxy:#{key}") do
        begin
          unless model == Sketchup.active_model && model.active_path.nil?
            # 用户已经进入其它空间时继续让路。发布请求保留在内存中，退出组件层级
            # 后自动重试；旧版在这里直接 next，会把已生成代理的自动发布请求永久丢掉。
            resume_space_publish_after_proxy_job!(job, model)
            next
          end
          current = (@space_publish_after_proxy || {})[key]
          next unless current.is_a?(Hash) && current[:space_id].to_s == request[:space_id].to_s
          @space_publish_after_proxy.delete(key)
          publish_space_model(request[:space_id].to_s, confirm: false)
        rescue StandardError => e
          @space_publish_after_proxy&.delete(key)
          log_exception('代理生成完成后自动继续空间发布失败', e)
          show_status("#{request[:label]} 代理已生成，但发布失败：#{e.message}。内容已保留，可重试。", 'error')
          refresh_dialog
          refresh_workspace_toolbar(model) rescue nil
        end
      end
      true
    rescue StandardError => e
      log_exception('衔接代理任务与空间发布失败', e)
      false
    end

    # 没有发生内容事务时，本次编辑会话可以直接结束：恢复进入前的世界视图、
    # 锁回空间并释放协作锁；不生成恢复副本、不序列化 SKP、不进入后台传输队列。
    #
    # preserve_representation=true 用于 ESC/切换焦点的“无修改自动返回”：
    # 用户只是误入空间时，不应因为退出动作额外把家具真/代理表示改成另一种状态。
    # 显式点击“发布”仍沿用原行为，可在结束会话时统一降为发布侧代理表示。
    def finish_unmodified_space_edit_session!(
      state, item, entity, target, model = Sketchup.active_model,
      reason: :publish, preserve_representation: false, notify: true, refresh: true
    )
      operation_open = false
      started_at = monotonic_time
      lock_snapshot = item.dup
      label = space_ui_label(item)
      reason_key = reason.to_sym rescue :publish

      model.start_operation("结束未修改空间 #{item['number']}:#{item['name']}", true, false, true)
      operation_open = true
      restore_space_isolation!(item, model)
      unless preserve_representation
        proxy_result = downgrade_space_soft_to_proxy_for_blur!(item, entity, model, reason: '未修改发布')
        if proxy_result.is_a?(Hash) && !proxy_result[:error].to_s.empty?
          raise "结束编辑前切换六面代理失败：#{proxy_result[:error]}"
        end
        if proxy_result.is_a?(Hash) && proxy_result[:unresolved].to_i.positive?
          tolerate_space_publish_proxy_shortfall!(item, entity, model, proxy_result, context: '结束编辑')
        end
      end
      entity.locked = true if entity.respond_to?(:locked=)
      entity.set_attribute(ENTITY_DICT, 'editing', false)
      entity.set_attribute(ENTITY_DICT, 'safe_paused', false)
      clear_space_safe_pause!(item, entity)
      clear_space_publish_pending!(item)
      item['editing'] = false
      item['publish_pending'] = false
      item['status'] = reason_key == :publish ? '已更新 · 本次内容未变化' : '已锁定 · 本次未修改'
      state['space_editing_id'] = '' if state['space_editing_id'].to_s == item['id'].to_s
      state['space_edit_display_mode'] = ''
      save_state(state, model, write_manifest: false)
      model.commit_operation
      operation_open = false

      released = release_space_lock!(
        lock_snapshot, target.to_s, clear_state: false,
        process_cleanup: true, model: model, state: state
      )
      if released
        clear_space_lock_state!(item)
      else
        item['status'] = '内容未变化 · 已锁定 · 协作占用释放失败'
      end
      save_state(state, model, write_manifest: false)
      @native_lock_state_cache ||= {}
      @native_lock_state_cache[space_native_cache_key(model, item['id'])] = true
      @space_edit_contexts&.delete(model.object_id)
      clear_edit_root_protection!(edit_root_key_for_space(item['id']), model)
      clear_space_edit_change_session!(model, item['id'])
      mark_soft_resident_space_releasable!(
        item['id'].to_s, model,
        reason: (reason_key == :publish ? 'unchanged_publish' : 'unchanged_exit'),
        grace: SOFT_RESIDENT_CACHE_PUBLISH_GRACE_SECONDS
      )
      if refresh
        refresh_dialog
        refresh_workspace_toolbar(model) rescue nil
      end
      elapsed = ((monotonic_time - started_at) * 1000.0).round
      if released
        if notify
          message = case reason_key
                    when :exit
                      "#{label} 未修改，已自动退出并释放占用。"
                    when :switch
                      "#{label} 未修改，已自动结束占用。"
                    when :cancel
                      "#{label} 无修改，已直接结束编辑。"
                    else
                      "#{label} 未修改，已结束编辑并释放占用。"
                    end
          show_status(message, 'success')
        end
        log("空间未修改快速结束：#{item['number']}:#{item['name']} / reason=#{reason_key} / #{elapsed}ms / 跳过候选序列化与后台发布")
      else
        show_status("#{label} 未修改且已锁定，但占用释放失败；请刷新后处理。", 'error') if notify
        log("空间未修改快速结束但释放占用失败：#{item['number']}:#{item['name']} / reason=#{reason_key} / #{elapsed}ms")
      end
      true
    rescue StandardError => e
      model.abort_operation rescue nil if operation_open
      log_exception('结束未修改空间编辑会话失败', e)
      raise
    end

    def finish_unmodified_space_publish!(state, item, entity, target, model = Sketchup.active_model)
      finish_unmodified_space_edit_session!(
        state, item, entity, target, model,
        reason: :publish, preserve_representation: false, notify: true, refresh: true
      )
    end

    def publish_space_model(space_id, confirm: true, native_handoff: false, native_job_id: '')
      handoff_committed = false
      candidate_operation_open = false
      queue_operation_open = false
      publish_guard_acquired = false
      publish_error = nil
      enqueued = false
      model = Sketchup.active_model
      state = load_state(model)
      item = space_model_record(state, space_id)
      raise '找不到该空间模型。' unless item
      if linked_space_record?(item)
        source = canonical_space_record(state, item)
        source_name = source ? source['name'].to_s : item['linked_source_name'].to_s
        raise "联动空间不生成独立发布文件；请发布来源空间（#{source_name}）。"
      end
      if space_background_publish_active?(item['id'])
        valid_native_handoff = false
        if native_handoff
          @space_publish_queue_mutex ||= Mutex.new
          @space_publish_queue_registry ||= {}
          valid_native_handoff = @space_publish_queue_mutex.synchronize do
            row = @space_publish_queue_registry[item['id'].to_s]
            row && row[:native_preparation] == true && row[:job_id].to_s == native_job_id.to_s
          end
        end
        raise '该空间已经在后台发布队列中，请等待完成后再操作。' unless valid_native_handoff
      end
      raise '该空间正处于强制解锁历史取物模式，禁止发布；只能先恢复到强制解锁前状态。' if space_force_recovery_active?(item, state)
      # v0.13.6.182：只有“本空间”还有待写库的家具时才需要等；其它空间的入库队列不影响发布。
      # 且这是排队等待（候选准备队列会在入库结束后自动继续），不再是失败。
      if @soft_ingest_batch_job && @soft_ingest_batch_job[:model].equal?(model) &&
         @soft_ingest_batch_job[:space_id].to_s == item['id'].to_s
        pending_names = soft_ingest_batch_queue_summary(@soft_ingest_batch_job)
        # 候选准备队列（native_space_publish_preparation_wait_reason）会等本空间入库结束后自动继续；
        # 这里只告知用户，不再把发布判为失败。
        unless native_handoff
          log("空间发布：#{item['number']}:#{item['name']} 仍有待入库家具（#{pending_names}），候选准备将在入库完成后自动继续")
          show_workspace_floating_notice("发布已排队 · 先完成入库：#{pending_names}", 'info', duration: 3.5, model: model)
        end
      end
      if native_handoff
        raise '用户已进入其它编辑层级，发布候选继续等待下一次空闲窗口。' unless model.active_path.nil?
      else
        model.active_path = nil unless model.active_path.nil?
      end
      raise 'LinkHub 未能自动退出组件层级，空间发布已取消。' unless model.active_path.nil?

      entity = space_model_entity(space_id, model)
      raise '该空间模型尚未载入，无法发布。' unless entity && entity.valid?
      # v0.13.6.136：组件修改不再单独上传。发布这个空间时，把当前空间定义图中
      # 所有 dirty 协同组件记录为同一发布动作的附带提交计划。为了避免后台空间发布期间
      # 用户又从其它空间继续修改同一 Definition 而把“未来内容”误带进本次提交，这里同时
      # 固定内容签名；空间正式发布成功后只有签名仍一致的组件才自动上传。
      component_publish_plan = shared_component_publish_plan_for_space_entity(entity, model)
      unless component_publish_plan.empty?
        log("空间发布将附带 #{component_publish_plan.length} 个协同组件修改；空间成功后自动同步组件资产")
      end
      target = auto_relocate(item['model_path'].to_s, model)
      raise '空间模型发布路径无效。' if target.to_s.empty?
      lock = space_lock_info(item, model, source_path: target, state: state)
      if lock['exists'] && !lock['owned'] && lock['same_user']
        lock = force_takeover_same_user_space_lock!(item, target, state, model, allow_current_process: true)
      end
      unless lock && lock['exists'] && !lock['stale'] && lock['owned'] &&
             (item['editing'] || entity.get_attribute(ENTITY_DICT, 'editing', false) || !entity_native_locked?(entity))
        raise '请先点击本行“修改”并取得该空间的协作占用后再发布。'
      end
      return request_space_publish(space_id) if confirm
      if !native_handoff && space_edit_content_unchanged?(item, entity, target, model)
        close_space_publish_dialog(item['id'], :unchanged)
        return finish_unmodified_space_publish!(state, item, entity, target, model)
      end
      return true if defer_space_publish_until_pending_proxies_ready!(item, entity, model)
      unless native_handoff
        close_space_publish_dialog(item['id'], :confirmed)
        return enqueue_native_space_publish_preparation!(item, entity, model)
      end

      publish_guard_acquired = enter_publish_critical_section!(
        kind: 'space',
        subject: "空间 #{item['number']}:#{item['name']} 发布候选封装",
        target: target,
        model: model
      )
      publish_breadcrumb!('space_publish_preflight', space_id: item['id'].to_s, target: target, background_queue: true)
      validate_space_edit_structure!(item, entity, model, interactive_definition_rebind: true)
      validate_space_soft_publish_membership!(item, entity, model)
      recovery_plan = save_space_recovery_before_collab_publish!(item, entity, model, context: "空间 #{item['number']}:#{item['name']} 发布")

      expected = item['last_signature'].to_s
      expected = fast_file_signature(target) if expected.empty? && File.file?(target)
      @space_publish_in_progress = true
      close_space_publish_dialog(item['id'], :confirmed)
      clear_space_publish_pending!(item)
      cancel_soft_resident_cache_cleanup!(model)

      source_revision = new_publish_revision("space-#{item['id']}")
      job_id = native_job_id.to_s
      job_id = "bgspace-#{Time.now.strftime('%Y%m%d_%H%M%S')}-#{Process.pid}-#{SecureRandom.hex(4)}" if job_id.empty?
      label = "#{item['number']}:#{item['name']}"

      # Phase A：唯一一次 SketchUp 原生序列化。内容 SHA 不在主线程计算，交给后台 worker。
      publish_breadcrumb!('candidate_operation_start_begin', background_queue: true)
      model.start_operation("生成后台发布候选 #{label}", true)
      candidate_operation_open = true
      publish_breadcrumb!('candidate_operation_started', background_queue: true)
      entity.locked = false if entity.respond_to?(:locked=)
      bake_space_outer_transformation!(entity)
      stamp_shared_component_space_snapshot_baselines!(entity, model)
      candidate_outcome = prepare_single_space_publish_candidate!(
        entity,
        target,
        "space_#{item['id']}",
        { 'name' => label },
        package_revision: source_revision,
        space_id: item['id'],
        defer_content_signature: true
      )
      prepared_candidate = candidate_outcome[:prepared]
      publish_breadcrumb!(
        'space_candidate_prepared',
        proxy_layout: candidate_outcome[:proxy_layout],
        local_candidate: prepared_candidate[:path].to_s,
        candidate_size: prepared_candidate[:size].to_i,
        background_queue: true
      )
      publish_breadcrumb!('candidate_operation_abort_begin', background_queue: true)
      model.abort_operation
      candidate_operation_open = false
      publish_breadcrumb!('candidate_operation_abort_returned', background_queue: true)

      # 候选与恢复目录同在本机同一卷时，直接 rename 成恢复文件；后续 worker 继续拿同一个文件发布。
      # 这样避免一份空间 SKP 在本机再 copy + SHA 一遍。
      adopt_background_publish_candidate_as_recovery!(recovery_plan, prepared_candidate) if recovery_plan.is_a?(Hash)

      entity = space_model_entity(space_id, model)
      raise '候选生成后未能恢复当前空间根实例，发布已停止。' unless entity && entity.valid?

      # Phase A.5：仅做“编辑权交接”。根组件锁回、恢复全模显示，但物理协作锁继续保留。
      # 从这一刻起用户可以立即去修改其它空间；同一空间在后台发布完成前禁止再次进入修改。
      model.start_operation("加入后台发布队列 #{label}", true, false, true)
      queue_operation_open = true
      restore_space_isolation!(item, model)
      publish_proxy_result = downgrade_space_soft_to_proxy_for_blur!(item, entity, model, reason: '正式发布')
      if publish_proxy_result.is_a?(Hash) && publish_proxy_result[:error].to_s != ''
        raise "发布前切换六面代理失败：#{publish_proxy_result[:error]}"
      end
      proxy_shortfall_note = ''
      if publish_proxy_result.is_a?(Hash) && publish_proxy_result[:unresolved].to_i.positive?
        # 候选阶段若已记录混合包（warning 非空），补齐代理的任务已由它排队，这里不重复排。
        proxy_shortfall_note = tolerate_space_publish_proxy_shortfall!(
          item, entity, model, publish_proxy_result,
          context: '发布', schedule_repair: candidate_outcome[:warning].to_s.empty?
        )
      end
      entity.locked = true if entity.respond_to?(:locked=)
      entity.set_attribute(ENTITY_DICT, 'editing', false)
      entity.set_attribute(ENTITY_DICT, 'safe_paused', false)
      clear_space_safe_pause!(item, entity)
      clear_space_publish_pending!(item)
      item['editing'] = false
      item['publish_pending'] = false
      item['background_publish_state'] = 'queued'
      item['background_publish_job_id'] = job_id
      item['background_publish_candidate'] = prepared_candidate[:path].to_s
      item['background_publish_error'] = ''
      item['status'] = '已加入发布队列 · 后台等待发布 · 协作占用保留'
      state['space_editing_id'] = '' if state['space_editing_id'].to_s == item['id'].to_s
      state['space_edit_display_mode'] = ''
      sync_linked_space_instances_for_source!(state, item, entity, model)
      save_state(state, model, write_manifest: false)
      model.commit_operation
      queue_operation_open = false
      handoff_committed = true
      @native_lock_state_cache ||= {}
      @native_lock_state_cache[space_native_cache_key(model, item['id'])] = true
      @space_edit_contexts&.delete(model.object_id)
      clear_edit_root_protection!(edit_root_key_for_space(item['id']), model)
      clear_space_edit_change_session!(model, item['id'])

      job = {
        job_id: job_id,
        space_id: item['id'].to_s,
        label: label,
        target: target.to_s,
        expected_signature: expected.to_s,
        source_revision: source_revision.to_s,
        source_model_path: model.path.to_s,
        model_object_id: model.object_id,
        prepared: prepared_candidate,
        proxy_layout: !!candidate_outcome[:proxy_layout],
        warning: candidate_outcome[:warning].to_s,
        recovery_plan: recovery_plan,
        queued_from_display_mode: state['space_display_mode'].to_s,
        shared_component_publish_plan: component_publish_plan
      }
      enqueue_space_publish_job!(job, model)
      enqueued = true
      clear_space_publish_skip_proxy_defer!(item['id'])
      publish_breadcrumb!('background_publish_queued', job_id: job_id, label: label, candidate: prepared_candidate[:path].to_s)
      # 主线程 native 阶段已经完整返回；后台 worker 使用独立的阶段文件。

      queue_position = begin
        @space_publish_queue_mutex.synchronize do
          running = @space_publish_queue_registry.values.count { |row| row[:status].to_s == 'running' }
          waiting = @space_publish_queue.count
          [running + waiting, 1].max
        end
      rescue StandardError
        1
      end
      if proxy_shortfall_note.to_s.empty?
        show_status("#{label} 已整理代理并加入发布队列（约 #{queue_position} 项）；可继续其它空间。", 'success')
      else
        show_status("#{label} 已加入发布队列（约 #{queue_position} 项）；#{proxy_shortfall_note}。", 'warning')
      end
      refresh_dialog
      refresh_workspace_toolbar(model) rescue nil
      true
    rescue StandardError => e
      publish_error = e
      model.abort_operation rescue nil if candidate_operation_open
      model.abort_operation rescue nil if queue_operation_open
      if defined?(prepared_candidate) && prepared_candidate.is_a?(Hash) && !enqueued
        candidate_path = prepared_candidate[:path].to_s
        File.delete(candidate_path) if !candidate_path.empty? && File.file?(candidate_path)
      end

      if handoff_committed && !enqueued && defined?(item) && item
        begin
          recovery_state = load_state(model)
          recovery_item = space_model_record(recovery_state, item['id'])
          recovery_entity = recovery_item ? space_model_entity(recovery_item['id'], model) : nil
          if recovery_item && recovery_entity && recovery_entity.valid?
            recovery_entity.locked = true if recovery_entity.respond_to?(:locked=)
            recovery_entity.set_attribute(ENTITY_DICT, 'editing', true)
            recovery_entity.set_attribute(ENTITY_DICT, 'safe_paused', true)
            recovery_item['editing'] = true
            recovery_item['edit_safe_paused'] = true
            recovery_item['edit_safe_paused_at'] = Time.now.strftime('%Y-%m-%d %H:%M:%S')
            recovery_item['edit_safe_pause_reason'] = '加入后台发布队列失败'
            recovery_item['background_publish_state'] = ''
            recovery_item['background_publish_job_id'] = ''
            recovery_item['status'] = '发布队列加入失败 · 未发布修改已安全暂存'
            save_state(recovery_state, model, write_manifest: false)
          end
        rescue StandardError => recovery_error
          log_exception('后台发布入队失败后恢复空间安全暂存失败', recovery_error)
        end
      end
      raise e
    ensure
      @space_publish_in_progress = false
      leave_publish_critical_section!(success: !!enqueued, error: publish_error, model: model) if publish_guard_acquired
    end


    end
  end
end
