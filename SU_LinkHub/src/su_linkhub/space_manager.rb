# frozen_string_literal: true

module GavinTools
  module SULinkHubMultiSpace
    module Runtime
    # -------------------------
    # 室内空间管理器：集中定位、重命名、删除和清单分组。
    # 分组只写入空间清单元数据，不创建组件、不复制 definition，也不触碰空间 SKP。
    # -------------------------

    def space_management_dialog_file
      File.join(__dir__, 'ui', 'space_manager.html')
    end

    def space_management_space_data(item, state, model = Sketchup.active_model)
      entity = space_model_entity(item['id'], model)
      loaded = !!(entity && entity.valid?)
      local_editing = local_space_edit_session?(item, state, model)
      lock = space_lock_info(item, model, state: state)
      lock_active = lock['exists'] && !lock['stale']
      owner = [lock['owner'], lock['host']].map(&:to_s).reject(&:empty?).join('@')
      busy_label = if local_editing
                     '当前正在修改'
                   elsif lock_active
                     owner.empty? ? '其他成员占用中' : "#{owner} 占用中"
                   elsif lock['exists'] && lock['stale']
                     '检测到过期占用'
                   else
                     ''
                   end
      source = resolve_path(item['model_path'].to_s, model)
      source_exists = !source.to_s.empty? && File.file?(source)
      raw_status = item['status'].to_s
      manager_status_code = if local_editing || lock_active
                              'editing'
                            elsif !source_exists || !loaded || raw_status.match?(/待|更新|载入|等待|中断/)
                              'pending'
                            else
                              'current'
                            end
      visible = loaded && !(entity.respond_to?(:hidden?) && entity.hidden?)
      {
        'id' => item['id'].to_s,
        'number' => item['number'].to_i,
        'name' => item['name'].to_s,
        'label' => "#{item['number']}:#{item['name']}",
        'group_id' => item['group_id'].to_s,
        'group_order' => item['group_order'].to_i,
        'status' => item['status'].to_s,
        'status_code' => manager_status_code,
        'loaded' => loaded,
        'visible' => visible,
        'file_exists' => source_exists,
        'editing' => !!local_editing,
        'busy' => !!(local_editing || lock_active),
        'busy_label' => busy_label,
        'can_focus' => loaded,
        'can_rename' => !local_editing && !lock_active,
        'can_delete' => !local_editing && !lock_active,
        'can_group' => !local_editing && !lock_active
      }
    rescue StandardError => e
      log_exception("生成空间管理条目失败：#{item && item['id']}", e)
      {
        'id' => item && item['id'].to_s,
        'number' => item && item['number'].to_i,
        'name' => item && item['name'].to_s,
        'label' => item ? "#{item['number']}:#{item['name']}" : '未知空间',
        'status' => '状态读取失败',
        'loaded' => false,
        'visible' => false,
        'file_exists' => false,
        'editing' => false,
        'busy' => true,
        'busy_label' => e.message.to_s,
        'can_focus' => false,
        'can_rename' => false,
        'can_delete' => false,
        'can_group' => false
      }
    end

    def space_management_data(model = Sketchup.active_model)
      state = ensure_space_models_ready!(model)
      host_key = host_discipline_for(state)
      inside_component = !model.active_path.nil?
      allowed = space_workspace_role?(host_key)
      collection_key = allowed ? host_key : SPACE_COLLECTION_KEY
      source_spaces = allowed ? spaces_for_collection(state, collection_key) : []
      spaces = source_spaces.sort_by { |item| [item['group_id'].to_s, item['group_order'].to_i, item['number'].to_i] }.map do |item|
        space_management_space_data(item, state, model)
      end
      used_group_ids = source_spaces.map { |item| item['group_id'].to_s }.reject(&:empty?).uniq
      groups = Array(state['space_groups']).select { |group| used_group_ids.include?(group['id'].to_s) }.sort_by { |group| group['order'].to_i }.map { |group| group.dup }
      collection_label = space_collection_label(collection_key)
      {
        'plugin_version' => EXTENSION_VERSION,
        'workspace' => host_key,
        'workspace_name' => allowed ? "#{collection_label}工作区" : '非空间工作区',
        'collection_key' => collection_key,
        'collection_label' => collection_label,
        'allowed' => allowed,
        'inside_component' => inside_component,
        'can_manage' => allowed && !inside_component,
        'space_count' => spaces.length,
        'group_min' => 1,
        'groups' => groups,
        'spaces' => spaces,
        'hint' => if !allowed
                    '请先切换到硬装或软装工作区。'
                  elsif inside_component
                    '请先退出所有组件编辑层级，再执行重命名、删除或分组。'
                  elsif spaces.empty?
                    "当前项目还没有#{collection_label}空间。"
                  else
                    "当前只管理#{collection_label}空间；分组只整理卡片，不合并模型。"
                  end
      }
    rescue StandardError => e
      log_exception('生成空间管理状态失败', e)
      {
        'plugin_version' => EXTENSION_VERSION,
        'workspace' => '',
        'workspace_name' => '',
        'allowed' => false,
        'inside_component' => false,
        'can_manage' => false,
        'space_count' => 0,
        'group_min' => 1,
        'groups' => [],
        'spaces' => [],
        'hint' => e.message.to_s,
        'error' => e.message.to_s
      }
    end

    def refresh_space_management_dialog(model = Sketchup.active_model)
      return false unless @space_management_dialog && @space_management_dialog.visible?
      payload = JSON.generate(space_management_data(model))
      @space_management_dialog.execute_script("window.SpaceManager && window.SpaceManager.receiveState(#{payload});")
      true
    rescue StandardError => e
      log_exception('刷新空间管理器失败', e)
      false
    end

    def space_management_dialog_error(dialog, context, error)
      log_exception(context, error)
      show_status(error.message.to_s, 'error')
      dialog.execute_script("window.SpaceManager && window.SpaceManager.showError(#{JSON.generate(error.message.to_s)});") rescue nil
      refresh_space_management_dialog rescue nil
      false
    end

    def focus_space_model_from_manager(space_id, model = Sketchup.active_model)
      raise '请先退出所有组件编辑层级。' unless model.active_path.nil?
      state = ensure_space_models_ready!(model)
      host_key = host_discipline_for(state)
      raise '空间管理只在硬装或软装工作区提供。' unless space_workspace_role?(host_key)
      item = space_model_record(state, space_id)
      raise '找不到该空间模型。' unless item
      raise '该空间不属于当前工作区。' unless space_record_collection_key(item) == host_key
      entity = space_model_entity(space_id, model)
      raise '该空间尚未载入，无法定位；请先在抽屉中更新该空间。' unless entity && entity.valid?

      collection_hidden = space_collection_hidden_active?(state, model)
      entity_hidden = entity.respond_to?(:hidden?) && entity.hidden?
      toggle_single_space_visibility(space_id, model) if collection_hidden || entity_hidden
      model.selection.clear
      model.selection.add(entity)
      model.active_view.zoom(entity) if model.active_view.respond_to?(:zoom)
      model.active_view.invalidate
      show_status("已定位 #{item['number']}:#{item['name']}。", 'success')
      true
    end

    def space_group_record(state, group_id)
      Array(state['space_groups']).find { |group| group.is_a?(Hash) && group['id'].to_s == group_id.to_s }
    end

    def next_space_group_order(state)
      values = Array(state['space_groups']).map { |group| group['order'].to_i }
      values.empty? ? 0 : values.max + 1
    end

    def normalize_space_group_orders!(state)
      groups = Array(state['space_groups']).sort_by { |group| [group['order'].to_i, group['name'].to_s] }
      groups.each_with_index { |group, index| group['order'] = index }
      group_ids = groups.each_with_object({}) { |group, memo| memo[group['id'].to_s] = true }
      Array(state['space_models']).each do |item|
        item['group_id'] = '' unless group_ids[item['group_id'].to_s]
      end
      grouped = Array(state['space_models']).group_by { |item| item['group_id'].to_s }
      grouped.each_value do |items|
        items.sort_by { |item| [item['group_order'].to_i, item['number'].to_i] }.each_with_index do |item, index|
          item['group_order'] = index
        end
      end
      state['space_groups'] = groups
      true
    end

    def update_workspace_group_layout_overlay!(state, model = Sketchup.active_model)
      overlay = workspace_toolbar_overlay(model)
      return false unless overlay && overlay.respond_to?(:update_space_group_layout!)
      overlay.update_space_group_layout!(Array(state['space_groups']).map(&:dup), Array(state['space_models']).map(&:dup))
    rescue StandardError
      false
    end

    # 分组属于共享清单的“布局层”，空间发布版本属于“内容层”。分组写回前
    # 必须先合并共享清单的最新内容层，绝不能用本机旧状态覆盖其他成员刚发布的
    # revision/signature/published_at；这正是 v0.9.82-v0.9.86 出现“面板最新、模型旧版”的根因之一。
    def merge_latest_space_publish_metadata!(state, model = Sketchup.active_model)
      manifest_path = space_models_manifest_path(state, model)
      return state unless !manifest_path.to_s.empty? && File.file?(manifest_path)

      local_by_id = Array(state['space_models']).each_with_object({}) do |item, memo|
        memo[item['id'].to_s] = item if item.is_a?(Hash) && !item['id'].to_s.empty?
      end
      remote = JSON.parse(JSON.generate(state))
      # sync_space_models_from_manifest! 的返回值只表示是否变化；始终使用其已变更的 remote。
      sync_space_models_from_manifest!(remote, model)

      # 内容层完全以共享端为准；只把本次本机布局的 group_id/group_order 套回
      # 共享端仍存在的空间。这样其他成员刚删除的空间不会被延迟分组写回“复活”。
      merged_spaces = Array(remote['space_models']).filter_map do |remote_item|
        next unless remote_item.is_a?(Hash)
        id = remote_item['id'].to_s
        next if id.empty?
        local_item = local_by_id[id]
        if local_item
          remote_item['group_id'] = local_item['group_id'].to_s
          remote_item['group_order'] = local_item['group_order'].to_i
        end
        remote_item
      end
      # 仅保留明确的旧项目迁移记录；普通本机陈旧条目不得重新写入共享清单。
      local_by_id.each_value do |item|
        next if merged_spaces.any? { |candidate| candidate['id'].to_s == item['id'].to_s }
        keep_local_unpublished = initial_space_publish_pending?(item) || background_publish_active_state?(item)
        merged_spaces << item if !item['legacy_key'].to_s.empty? || keep_local_unpublished
      end
      state['space_models'] = merged_spaces

      # 分组操作以本机刚完成的布局为主；若其他成员同时新增了本机尚未知的组，
      # 则补入而不丢失。并发修改同一个组时采用最后一次成功写入。
      local_group_ids = Array(state['space_groups']).each_with_object({}) do |group, memo|
        memo[group['id'].to_s] = true if group.is_a?(Hash)
      end
      Array(remote['space_groups']).each do |group|
        next unless group.is_a?(Hash)
        id = group['id'].to_s
        next if id.empty? || local_group_ids[id]
        state['space_groups'] << group
        local_group_ids[id] = true
      end
      used_group_ids = merged_spaces.each_with_object({}) do |item, memo|
        id = item['group_id'].to_s
        memo[id] = true unless id.empty?
      end
      state['space_groups'] = Array(state['space_groups']).select { |group| used_group_ids[group['id'].to_s] }
      normalize_space_models_state!(state, model)
      state
    rescue StandardError => e
      log_exception('合并共享空间发布版本失败', e)
      raise '共享空间清单正在变化，已取消本次分组写入，请稍后重试。'
    end

    # 内容操作（新增、发布、重命名、删除）只允许修改指定空间的内容层，
    # 分组与排序必须采用共享清单在落盘瞬间的最新值；其他空间则完整采用共享端
    # 最新记录。这样即使一个 100MB 空间发布期间另一成员完成了成组，发布收尾也
    # 不会把组结构覆盖回旧状态。
    def merge_latest_space_manifest_for_content_write!(
      state,
      model = Sketchup.active_model,
      local_space_ids: [],
      deleted_space_ids: []
    )
      manifest_path = space_models_manifest_path(state, model)
      return state unless !manifest_path.to_s.empty? && File.file?(manifest_path)

      local_ids = Array(local_space_ids).map(&:to_s).reject(&:empty?).uniq
      deleted_ids = Array(deleted_space_ids).map(&:to_s).reject(&:empty?).uniq
      local_id_set = local_ids.each_with_object({}) { |id, memo| memo[id] = true }
      deleted_id_set = deleted_ids.each_with_object({}) { |id, memo| memo[id] = true }
      local_by_id = Array(state['space_models']).each_with_object({}) do |item, memo|
        memo[item['id'].to_s] = item if item.is_a?(Hash) && !item['id'].to_s.empty?
      end

      # 从本机当前状态克隆后同步共享清单，可保留 collapsed 等本机浏览偏好，
      # 同时取得共享端最新 groups、group_id/group_order 与其他空间发布元数据。
      remote = JSON.parse(JSON.generate(state))
      sync_space_models_from_manifest!(remote, model)
      remote_by_id = Array(remote['space_models']).each_with_object({}) do |item, memo|
        memo[item['id'].to_s] = item if item.is_a?(Hash) && !item['id'].to_s.empty?
      end

      merged = []
      Array(remote['space_models']).each do |remote_item|
        next unless remote_item.is_a?(Hash)
        id = remote_item['id'].to_s
        next if id.empty? || deleted_id_set[id]
        if local_id_set[id] && local_by_id[id]
          local_item = local_by_id[id]
          # 内容操作保留目标空间本次产生的名称、路径、revision 与签名；
          # 仅将共享端最新分组归属和排序覆盖回来。
          local_item['group_id'] = remote_item['group_id'].to_s
          local_item['group_order'] = remote_item['group_order'].to_i
          merged << local_item
        else
          merged << remote_item
        end
      end

      # 新增空间尚不存在于共享清单，必须在远端基线之后补入；被删除的 ID 不复活。
      local_ids.each do |id|
        next if deleted_id_set[id] || remote_by_id.key?(id)
        item = local_by_id[id]
        merged << item if item
      end

      used_group_ids = merged.each_with_object({}) do |item, memo|
        id = item['group_id'].to_s
        memo[id] = true unless id.empty?
      end
      state['space_groups'] = Array(remote['space_groups']).select { |group| used_group_ids[group['id'].to_s] }
      state['space_models'] = merged
      normalize_space_models_state!(state, model)
      state
    rescue StandardError => e
      log_exception('合并共享空间布局失败', e)
      raise '共享空间清单正在变化，已取消本次内容清单写入；空间 SKP 已安全保留，请稍后重试同步。'
    end

    # 共享清单写入延后到用户动作结束后的空闲帧，并合并连续操作。卡片先立即变化，
    # SMB 小文件写入不再紧跟点击抢占主线程；最终共享状态仍会可靠落盘。
    def schedule_space_group_layout_sync!(model = Sketchup.active_model, delay: 0.25)
      @space_group_layout_sync_tokens ||= {}
      token = SecureRandom.hex(6)
      key = model.object_id
      @space_group_layout_sync_tokens[key] = token
      GavinTools::SULinkHubMultiSpace::Runtime.runtime_start_timer(delay, false, label: 'space_group:manifest_sync') do
        next unless @space_group_layout_sync_tokens && @space_group_layout_sync_tokens[key] == token
        begin
          current = load_state(model)
          write_space_models_manifest!(current, model, preserve_remote_publish_metadata: true)
          save_state(current, model, write_manifest: false)
          refresh_dialog
          refresh_space_management_dialog(model)
        rescue StandardError => e
          log_exception('同步空间分组清单失败', e)
          show_status("空间分组已在当前工作模型保存，但共享清单同步失败：#{e.message}", 'error')
        ensure
          @space_group_layout_sync_tokens.delete(key) if @space_group_layout_sync_tokens
        end
      end
      true
    rescue StandardError => e
      log_exception('安排空间分组清单同步失败', e)
      false
    end

    def persist_space_group_layout!(state, model = Sketchup.active_model, sync_manifest: true)
      normalize_space_group_orders!(state)
      normalize_space_models_state!(state, model)
      if sync_manifest
        state['space_layout_revision'] = new_publish_revision('space-layout')
        state['space_layout_updated_at'] = Time.now.iso8601(6)
        state['space_layout_updated_by'] = current_user_name
        state['space_layout_updated_host'] = current_host_name
        begin
          # 分组是很小的 JSON，必须先同步写入共享真相源再更新本机；不再依赖
          # 0.25 秒定时器，避免关闭模型、热重载或连续操作时分组只留在本机。
          write_space_groups_manifest!(state, model)
          # 兼容旧客户端：主空间清单也尽力写回，但失败不会破坏独立分组真相源。
          begin
            write_space_models_manifest!(state, model, preserve_remote_publish_metadata: true)
          rescue StandardError => compatibility_error
            log_exception('兼容写回空间模型清单失败；独立分组清单已成功保存', compatibility_error)
          end
        rescue StandardError => e
          # 共享写入失败时立即恢复共享端布局，不能让界面显示一个只有本机知道的组。
          sync_space_models_from_manifest!(state, model)
          sync_space_groups_from_manifest!(state, model)
          save_state(state, model, write_manifest: false)
          update_workspace_group_layout_overlay!(state, model)
          raise "空间分组未能写入共享目录，已恢复共享布局：#{e.message}"
        end
      end
      save_state(state, model, write_manifest: false)
      update_workspace_group_layout_overlay!(state, model)
      refresh_space_management_dialog(model)
      refresh_dialog
      true
    end

    # 空间组只是清单层级，不创建组件、不载入 SKP、不改写任何模型几何。
    def create_space_group(space_ids, group_name, model = Sketchup.active_model)
      raise '请先退出所有组件编辑层级，再管理空间分组。' unless model.active_path.nil?
      state = ensure_space_models_ready!(model)
      raise '空间分组只在硬装或软装工作区提供。' unless space_workspace_role?(host_discipline_for(state))
      ids = Array(space_ids).map(&:to_s).reject(&:empty?).uniq
      raise '请至少选择一个空间进行成组。' if ids.empty?
      name = normalize_space_name(group_name)
      raise '组名不能为空。' if name.empty?
      duplicate = Array(state['space_groups']).any? { |group| group['name'].to_s.casecmp(name).zero? }
      raise "空间组“#{name}”已经存在，请使用其他名称。" if duplicate
      host_key = host_discipline_for(state)
      records = ids.map do |space_id|
        item = space_model_record(state, space_id)
        raise '选择中包含已经不存在的空间，请刷新后重试。' unless item
        raise '选择中包含其他工作区的空间，请刷新后重试。' unless space_record_collection_key(item) == host_key
        item
      end
      pending = records.find { |record| initial_space_publish_pending?(record) }
      if pending
        raise "#{pending['number']}:#{pending['name']} 尚未完成首次发布；首次发布完成前不能成组或改动共享布局，可先重试发布或删除本地待发布空间。"
      end
      group = {
        'id' => SecureRandom.uuid,
        'name' => name,
        'order' => next_space_group_order(state),
        'collapsed' => true,
        'visibility_suspended' => false,
        'visibility_restore_ids' => [],
        'collection_visibility' => {}
      }
      previous_group_ids = records.map { |item| item['group_id'].to_s }.reject(&:empty?).uniq
      state['space_groups'] << group
      records.sort_by { |item| item['number'].to_i }.each_with_index do |item, index|
        item['group_id'] = group['id']
        item['group_order'] = index
      end
      previous_group_ids.each do |previous_group_id|
        previous_group = space_group_record(state, previous_group_id)
        if previous_group
          visibility_state = group_collection_visibility_state(previous_group, host_key)
          visibility_state['restore_ids'] = Array(visibility_state['restore_ids']).reject { |space_key| ids.include?(space_key.to_s) }
          visibility_state['suspended'] = false if visibility_state['restore_ids'].empty?
          sync_legacy_group_visibility_from_collection!(previous_group) if host_key == SPACE_COLLECTION_KEY
        end
        next if Array(state['space_models']).any? { |item| item['group_id'].to_s == previous_group_id }
        state['space_groups'].delete_if { |candidate| candidate['id'].to_s == previous_group_id }
      end
      persist_space_group_layout!(state, model)
      log("空间成组完成：#{name} / 组ID #{group['id']} / 成员 #{records.map { |item| item['number'] }.join(',')} / 默认折叠")
      show_status("已建立“#{name}”组并默认折叠；蓝色组卡片位于空间列表顶部，点击即可展开 #{records.length} 个空间。", 'success')
      group
    end

    def request_group_selected_space_models(space_ids, model = Sketchup.active_model)
      ids = Array(space_ids).map(&:to_s).reject(&:empty?).uniq
      raise '请先勾选要成组的空间。' if ids.empty?
      state = ensure_space_models_ready!(model)
      records = ids.map { |space_id| space_model_record(state, space_id) }.compact
      raise '选择中包含已经不存在的空间，请刷新后重试。' unless records.length == ids.length
      suggested = records.first && records.first['name'].to_s
      suggested = '新空间组' if suggested.to_s.empty?
      response = UI.inputbox(['组名称'], [suggested], "将 #{ids.length} 个空间成组")
      return false unless response
      group = create_space_group(ids, response[0], model)
      overlay = workspace_toolbar_overlay(model)
      if overlay
        overlay.clear_space_manage_selection! if overlay.respond_to?(:clear_space_manage_selection!)
        overlay.reveal_space_group!(group['id']) if group && overlay.respond_to?(:reveal_space_group!)
      end
      true
    end

    def rename_space_group(group_id, model = Sketchup.active_model)
      raise '请先退出所有组件编辑层级，再修改组名。' unless model.active_path.nil?
      state = ensure_space_models_ready!(model)
      group = space_group_record(state, group_id)
      raise '找不到该空间组。' unless group
      pending_member = Array(state['space_models']).find do |item|
        item['group_id'].to_s == group['id'].to_s && initial_space_publish_pending?(item)
      end
      if pending_member
        raise "组内 #{pending_member['number']}:#{pending_member['name']} 尚未完成首次发布；完成或删除该本地待发布空间后再修改组名。"
      end
      response = UI.inputbox(['组名称'], [group['name'].to_s], '修改空间组名称')
      return false unless response
      name = normalize_space_name(response[0])
      raise '组名不能为空。' if name.empty?
      duplicate = Array(state['space_groups']).any? do |candidate|
        candidate['id'].to_s != group['id'].to_s && candidate['name'].to_s.casecmp(name).zero?
      end
      raise "空间组“#{name}”已经存在。" if duplicate
      group['name'] = name
      persist_space_group_layout!(state, model)
      show_status("空间组已重命名为“#{name}”。", 'success')
      true
    end

    def toggle_space_group_collapsed(group_id, model = Sketchup.active_model)
      # 不再只依赖当前运行代的内存记录。后台热重载后可见 Overlay 可能仍属于
      # 上一运行代，必须先重新认领；能力不足时则原位重建，再执行展开/收纳。
      overlay = ensure_workspace_toolbar_for_model(
        model,
        required_methods: [:toggle_space_group_collapsed_local!]
      )
      raise '空间组抽屉暂时无法恢复，请重载插件后重试。' unless overlay
      collapsed = overlay.toggle_space_group_collapsed_local!(group_id)
      raise '找不到该空间组。' if collapsed.nil?

      # 纯视觉响应已经完成并立即返回；模型属性持久化延后且合并执行。
      # 连续快速点击只写最后状态，不阻塞当前鼠标事件，也不刷新完整抽屉状态。
      @space_group_collapse_persist_tokens ||= {}
      token_key = [model.object_id, group_id.to_s]
      token = @space_group_collapse_persist_tokens[token_key].to_i + 1
      @space_group_collapse_persist_tokens[token_key] = token
      runtime_start_timer(0.12, false, label: 'space_group:collapse_persist') do
        next unless (@space_group_collapse_persist_tokens || {})[token_key].to_i == token
        begin
          state = load_state(model)
          group = space_group_record(state, group_id)
          next unless group
          group['collapsed'] = !!collapsed
          save_state(state, model, write_manifest: false)
          refresh_space_management_dialog(model)
        rescue StandardError => e
          log_exception('保存空间组展开状态失败', e)
        ensure
          @space_group_collapse_persist_tokens.delete(token_key) if @space_group_collapse_persist_tokens
        end
      end
      true
    end

    def toggle_space_group_visibility(group_id, model = Sketchup.active_model)
      raise '请先退出所有组件编辑层级，再切换空间组显示。' unless model.active_path.nil?
      state = load_state(model)
      collection_key = host_discipline_for(state)
      raise '请先切换到硬装或软装工作区。' unless space_workspace_role?(collection_key)
      group = space_group_record(state, group_id)
      raise '找不到该空间组。' unless group
      members = spaces_for_collection(state, collection_key).select { |item| item['group_id'].to_s == group['id'].to_s }
      loaded = members.filter_map do |item|
        entity = space_model_entity(item['id'], model)
        entity && entity.valid? ? [item, entity] : nil
      end
      raise "该组内还没有已载入的#{space_collection_label(collection_key)}空间。" if loaded.empty?

      visibility_state = group_collection_visibility_state(group, collection_key)
      operation_started = false
      model.start_operation(visibility_state['suspended'] ? "显示#{space_collection_label(collection_key)}空间组" : "隐藏#{space_collection_label(collection_key)}空间组", true)
      operation_started = true

      # 若当前专业总眼睛此前隐藏了全部空间，只恢复当前专业，不碰另一工作区。
      if visibility_state['suspended'] && space_collection_hidden_active?(state, model, collection_key)
        snapshot = space_collection_visibility_snapshot_for(state, collection_key)
        space_collection_control_tags(model, collection_key).each do |tag|
          tag.visible = true if tag.respond_to?(:visible=)
        rescue StandardError
          next
        end
        space_model_entities_for_collection(state, collection_key, model).each do |space_entity|
          key = space_collection_entity_visibility_key(space_entity)
          legacy_key = entity_snapshot_id(space_entity)
          desired = if snapshot['entities'].key?(key)
                      !!snapshot['entities'][key]
                    elsif snapshot['entities'].key?(legacy_key)
                      !!snapshot['entities'][legacy_key]
                    else
                      false
                    end
          space_entity.hidden = desired if space_entity.respond_to?(:hidden=)
        rescue StandardError
          next
        end
        set_space_collection_visibility_snapshot_for!(state, collection_key, { 'entities' => {}, 'tags' => {} })
        set_space_collection_hidden_for!(state, collection_key, false)
      end

      if visibility_state['suspended']
        restore_ids = Array(visibility_state['restore_ids']).map(&:to_s)
        loaded.each do |item, entity|
          next unless restore_ids.include?(item['id'].to_s)
          entity.hidden = false if entity.respond_to?(:hidden=)
        end
        visibility_state['suspended'] = false
        visibility_state['restore_ids'] = []
        message = "已显示“#{group['name']}”中上次由组按钮隐藏的#{space_collection_label(collection_key)}空间；原本单独隐藏的空间保持隐藏。"
      else
        visible_ids = loaded.filter_map do |item, entity|
          next if entity.respond_to?(:hidden?) && entity.hidden?
          item['id'].to_s
        end
        raise '该组当前没有显示中的空间；组按钮不会强制显示原本单独隐藏的空间。' if visible_ids.empty?
        loaded.each do |item, entity|
          next unless visible_ids.include?(item['id'].to_s)
          entity.hidden = true if entity.respond_to?(:hidden=)
        end
        visibility_state['suspended'] = true
        visibility_state['restore_ids'] = visible_ids
        message = "已隐藏“#{group['name']}”中当前显示的 #{visible_ids.length} 个#{space_collection_label(collection_key)}空间；再次显示只恢复这些空间。"
      end
      sync_legacy_group_visibility_from_collection!(group) if collection_key == SPACE_COLLECTION_KEY

      save_state(state, model, write_manifest: false)
      model.commit_operation
      operation_started = false
      collection_hidden = space_collection_hidden_for(state, collection_key)
      visibility_map = loaded.each_with_object({}) do |(item, entity), memo|
        memo[item['id'].to_s] = !(entity.respond_to?(:hidden?) && entity.hidden?) && !collection_hidden
      end
      overlay = workspace_toolbar_overlay(model)
      if overlay
        overlay.set_space_group_visibility_local!(group_id, visibility_state['suspended'], visibility_state['restore_ids']) if overlay.respond_to?(:set_space_group_visibility_local!)
        overlay.update_space_visibility_local!(visibility_map) if overlay.respond_to?(:update_space_visibility_local!)
      end
      model.active_view.invalidate if model.respond_to?(:active_view) && model.active_view
      refresh_dialog
      show_status(message, 'success')
      true
    rescue StandardError
      model.abort_operation rescue nil if operation_started
      raise
    end

    def move_space_group_order(group_id, target_group_id:, position: 'after', model: Sketchup.active_model)
      raise '请先退出所有组件编辑层级，再拖动空间组。' unless model.active_path.nil?
      state = ensure_space_models_ready!(model)
      groups = Array(state['space_groups']).sort_by { |group| [group['order'].to_i, group['name'].to_s] }
      source = groups.find { |group| group['id'].to_s == group_id.to_s }
      target = groups.find { |group| group['id'].to_s == target_group_id.to_s }
      raise '找不到被拖动的空间组。' unless source
      raise '找不到目标空间组。' unless target
      pending_member = Array(state['space_models']).find do |item|
        initial_space_publish_pending?(item) && [source['id'].to_s, target['id'].to_s].include?(item['group_id'].to_s)
      end
      if pending_member
        raise "#{pending_member['number']}:#{pending_member['name']} 尚未完成首次发布；首次发布完成前暂不调整相关空间组顺序。"
      end
      return false if source['id'].to_s == target['id'].to_s
      groups.delete(source)
      target_index = groups.index { |group| group['id'].to_s == target['id'].to_s } || groups.length
      target_index += 1 unless position.to_s == 'before'
      groups.insert([[target_index, 0].max, groups.length].min, source)
      groups.each_with_index { |group, index| group['order'] = index }
      state['space_groups'] = groups
      persist_space_group_layout!(state, model)
      show_status("已调整空间组“#{source['name']}”的顺序。", 'success')
      true
    end

    def move_space_in_group_layout(space_id, target_group_id: '', target_space_id: '', position: 'after', model: Sketchup.active_model)
      raise '请先退出所有组件编辑层级，再拖动空间卡片。' unless model.active_path.nil?
      state = ensure_space_models_ready!(model)
      item = space_model_record(state, space_id)
      raise '找不到被拖动的空间。' unless item
      if initial_space_publish_pending?(item)
        raise '该空间尚未完成首次发布；首次发布完成前不能调整分组或排序，可先重试发布或删除本地待发布空间。'
      end
      host_key = host_discipline_for(state)
      raise '请先切换到硬装或软装工作区。' unless space_workspace_role?(host_key)
      item_collection = space_record_collection_key(item)
      raise "当前是#{space_collection_label(host_key)}工作区，不能拖动#{space_collection_label(item_collection)}空间。" unless item_collection == host_key
      target_group_id = target_group_id.to_s
      unless target_group_id.empty?
        raise '目标空间组不存在。' unless space_group_record(state, target_group_id)
      end
      target = target_space_id.to_s.empty? ? nil : space_model_record(state, target_space_id)
      if target && initial_space_publish_pending?(target)
        raise '目标空间尚未完成首次发布；首次发布完成前不能作为共享排序锚点。'
      end
      if target && space_record_collection_key(target) != item_collection
        raise '不能把硬装与软装空间通过拖拽混到同一个工作区排序中。'
      end
      target_group_id = target['group_id'].to_s if target
      spaces = Array(state['space_models'])
      source_group_id = item['group_id'].to_s
      target_members = spaces.reject { |candidate| candidate['id'].to_s == item['id'].to_s }
                            .select { |candidate| space_record_collection_key(candidate) == item_collection && candidate['group_id'].to_s == target_group_id }
                            .sort_by { |candidate| [candidate['group_order'].to_i, candidate['number'].to_i] }
      insert_at = target_members.length
      if target
        index = target_members.index { |candidate| candidate['id'].to_s == target['id'].to_s }
        insert_at = index || target_members.length
        insert_at += 1 unless position.to_s == 'before'
      end
      insert_at = [[insert_at, 0].max, target_members.length].min
      item['group_id'] = target_group_id
      target_members.insert(insert_at, item)
      target_members.each_with_index { |candidate, index| candidate['group_order'] = index }
      if source_group_id != target_group_id
        spaces.select { |candidate| candidate['group_id'].to_s == source_group_id && candidate['id'].to_s != item['id'].to_s }
              .sort_by { |candidate| [candidate['group_order'].to_i, candidate['number'].to_i] }
              .each_with_index { |candidate, index| candidate['group_order'] = index }
        source_group = space_group_record(state, source_group_id)
        if source_group
          visibility_state = group_collection_visibility_state(source_group, item_collection)
          visibility_state['restore_ids'] = Array(visibility_state['restore_ids']).reject { |space_key| space_key.to_s == item['id'].to_s }
          visibility_state['suspended'] = false if visibility_state['restore_ids'].empty?
          sync_legacy_group_visibility_from_collection!(source_group) if item_collection == SPACE_COLLECTION_KEY
        end
      end
      if !source_group_id.empty? && spaces.none? { |candidate| candidate['group_id'].to_s == source_group_id }
        state['space_groups'].delete_if { |group| group['id'].to_s == source_group_id }
      end
      group = space_group_record(state, target_group_id)
      group['collapsed'] = false if group
      persist_space_group_layout!(state, model)
      label = group ? group['name'].to_s : '未分组'
      show_status("已将 #{item['number']}:#{item['name']} 移至“#{label}”。", 'success')
      true
    end

    def handle_workspace_space_drop(payload, model = Sketchup.active_model)
      mark_workspace_toolbar_fast_interaction!(model, duration: 1.0)
      data = payload.is_a?(Hash) ? payload : JSON.parse(payload.to_s)
      if data['kind'].to_s == 'group'
        move_space_group_order(
          data['group_id'],
          target_group_id: data['target_group_id'],
          position: data['position'],
          model: model
        )
      else
        move_space_in_group_layout(
          data['space_id'],
          target_group_id: data['target_group_id'],
          target_space_id: data['target_space_id'],
          position: data['position'],
          model: model
        )
      end
    rescue JSON::ParserError
      raise '空间拖动参数无效。'
    end

    # 旧版几何合并空间功能已移除。空间管理仅维护逻辑分组，避免大模型复制、嵌套与额外发布。

    # 空间改名涉及 SketchUp 撤回事务之外的真实文件系统操作。必须先经过临时名，
    # 并在网络盘短暂占用时重试；否则清单已改名而 SKP 未移动，会留下难以恢复的
    # 半完成状态。
    def move_space_file_for_rename!(source_path, target_path)
      source = FastPath.expand(source_path.to_s)
      target = FastPath.expand(target_path.to_s)
      raise '待改名的空间 SKP 不存在。' unless File.file?(source)
      return target if source == target
      raise "目标空间文件已存在：#{target}" if File.exist?(target) && !same_file_path?(source, target)

      FileUtils.mkdir_p(File.dirname(target))
      expected_size = File.size(source)
      case_only = source.tr('\\', '/').downcase == target.tr('\\', '/').downcase
      bridge = case_only ? File.join(File.dirname(source), ".#{File.basename(source)}.rename-#{Process.pid}-#{SecureRandom.hex(4)}") : ''
      if case_only
        file_operation_with_retry { linkhub_mv!(source, bridge) }
        file_operation_with_retry { linkhub_mv!(bridge, target) }
      else
        file_operation_with_retry { linkhub_mv!(source, target) }
      end
      unless File.file?(target) && File.size(target) == expected_size && expected_size.positive?
        raise '空间 SKP 改名后的文件校验失败。'
      end
      target
    rescue StandardError
      begin
        linkhub_mv(bridge, source) if defined?(bridge) && !bridge.to_s.empty? && File.file?(bridge) && !File.file?(source)
      rescue StandardError
        nil
      end
      raise
    end

    def rollback_space_file_rename!(renamed_path, original_path)
      renamed = FastPath.expand(renamed_path.to_s)
      original = FastPath.expand(original_path.to_s)
      return true unless File.file?(renamed)
      return false if File.exist?(original) && !same_file_path?(renamed, original)
      FileUtils.mkdir_p(File.dirname(original))
      case_only = renamed.tr('\\', '/').downcase == original.tr('\\', '/').downcase
      bridge = case_only ? File.join(File.dirname(renamed), ".#{File.basename(renamed)}.rollback-#{Process.pid}-#{SecureRandom.hex(4)}") : ''
      if case_only
        file_operation_with_retry { linkhub_mv!(renamed, bridge) }
        file_operation_with_retry { linkhub_mv!(bridge, original) }
      else
        file_operation_with_retry { linkhub_mv!(renamed, original) }
      end
      File.file?(original)
    rescue StandardError => e
      log_exception('回滚空间文件改名失败', e)
      false
    ensure
      begin
        linkhub_mv(bridge, original) if defined?(bridge) && !bridge.to_s.empty? && File.file?(bridge) && !File.file?(original)
      rescue StandardError
        nil
      end
    end

    def rename_space_model(space_id, model = Sketchup.active_model)
      raise '请先退出所有组件编辑层级，再修改空间名称。' unless model.active_path.nil?
      state = ensure_space_models_ready!(model)
      item = space_model_record(state, space_id)
      raise '找不到该空间模型。' unless item
      raise '该空间正处于强制解锁历史取物模式。请先退出并恢复进入前状态，再改名。' if space_force_recovery_active?(item, state)
      if initial_space_publish_pending?(item)
        raise '该空间尚未完成首次发布。为避免本机名称与共享目标分叉，首次发布完成前不能改名；可先重试发布，或删除本地待发布空间后重新新增。'
      end

      entity = space_model_entity(space_id, model)
      local_editing = local_space_edit_session?(item, state, model)
      raise '该空间正在修改中，请先发布或更新放弃修改后再改名。' if local_editing

      lock = space_lock_info(item, model)
      if lock['exists'] && !lock['stale']
        who = [lock['owner'], lock['host']].reject(&:empty?).join('@')
        raise "该空间正由 #{who.empty? ? '其他成员' : who} 修改，暂时不能改名。"
      elsif lock['exists'] && lock['stale']
        stale_path = lock['path'].to_s
        source_for_archive = auto_relocate(item['model_path'].to_s, model)
        archive_lock_file(stale_path, source_for_archive, 'stale_before_rename') if File.file?(stale_path)
      end

      response = UI.inputbox(['空间名称'], [item['name'].to_s], "重命名 #{item['number']}:#{item['name']}")
      return false unless response
      parsed = parse_structured_space_name(response[0], default_collection: space_record_collection_key(item))
      raise '空间改名不能直接转换为建筑模型；请用“新增模型空间”并以 -建筑 结尾创建建筑模型。' if parsed['target_role'].to_s == 'architecture'
      new_name = parsed['name'].to_s
      raise '空间名称不能为空。' if new_name.empty?
      new_collection = normalize_space_collection_key(parsed['collection_key'], space_record_collection_key(item))
      new_group_id = parsed['group_name'].to_s.empty? ? item['group_id'].to_s : ensure_named_space_group!(state, parsed['group_name'])
      return false if new_name == item['name'].to_s && new_collection == space_record_collection_key(item) && new_group_id == item['group_id'].to_s
      duplicate = Array(state['space_models']).any? do |record|
        record['id'].to_s != item['id'].to_s &&
          space_record_collection_key(record) == new_collection &&
          record['name'].to_s.casecmp(new_name).zero?
      end
      raise "#{space_collection_label(new_collection)}空间名称“#{new_name}”已经存在，请使用不同名称。" if duplicate

      if linked_space_record?(item)
        source = canonical_space_record(state, item)
        raise '该联动空间的来源已缺失，请先刷新协同清单。' unless source
        raise '联动空间必须与来源空间属于同一专业。' unless new_collection == space_record_collection_key(source)
        old_name = item['name'].to_s
        model.start_operation("重命名联动空间 #{item['number']}:#{old_name}", true)
        item['name'] = new_name
        item['group_id'] = new_group_id
        item['linked_source_name'] = source['name'].to_s
        item['linked_transform'] = entity.transformation.to_a.map(&:to_f) if entity && entity.valid?
        item['status'] = "联动于（#{source['name']}）"
        entity.name = "#{item['number']}:#{new_name}.skp" if entity && entity.valid? && entity.respond_to?(:name=)
        normalize_space_models_state!(state, model)
        save_state(state, model, write_manifest: false)
        write_space_models_manifest!(state, model, preserve_remote_layout: true, local_space_ids: [item['id']])
        model.commit_operation
        refresh_dialog
        refresh_workspace_toolbar(model, detailed: true)
        refresh_space_management_dialog(model)
        show_status("已将联动空间 #{item['number']}:#{old_name} 重命名为 #{item['number']}:#{new_name}；联动来源未改变。", 'success')
        return true
      end

      old_name = item['name'].to_s
      old_collection = space_record_collection_key(item)
      old_group_id = item['group_id'].to_s
      old_stored = item['model_path'].to_s
      old_path = auto_relocate(old_stored, model).to_s
      base_dir = if !old_path.empty?
                   File.dirname(old_path)
                 else
                   space_models_assets_dir(state, model)
                 end
      raise '空间模型目录无效，无法改名。' if base_dir.to_s.empty?
      new_path = File.join(base_dir, "#{item['number']}_#{safe_space_filename("#{new_name}-#{space_collection_label(new_collection)}")}.skp")
      new_stored = store_path(new_path, model)
      if File.exist?(new_path) && !(File.file?(old_path) && same_file_path?(old_path, new_path))
        raise "目标文件“#{File.basename(new_path)}”已经存在，请使用其他空间名称。"
      end

      manifest_path = space_models_manifest_path(state, model)
      manifest_existed = !manifest_path.to_s.empty? && File.file?(manifest_path)
      manifest_backup = manifest_existed ? File.binread(manifest_path) : nil
      file_moved = false
      model.start_operation("重命名空间 #{item['number']}:#{old_name}", true)
      begin
        if File.file?(old_path) && FastPath.expand(old_path) != FastPath.expand(new_path)
          move_space_file_for_rename!(old_path, new_path)
          file_moved = true
        end

        item['name'] = new_name
        item['collection_key'] = new_collection
        item['group_id'] = new_group_id
        item['model_path'] = new_stored
        item['status'] = '空间名称已同步更新'
        linked_rows = linked_space_dependents(state, item['id'])
        linked_rows.each do |linked|
          linked['model_path'] = new_stored
          linked['linked_source_name'] = new_name
          linked['status'] = "联动于（#{new_name}）"
        end
        display_name = "#{item['number']}:#{new_name}.skp"
        if entity && entity.valid?
          representation = entity.get_attribute(ENTITY_DICT, 'space_representation', 'full').to_s
          mark_space_model_entity!(
            entity,
            item,
            new_stored,
            item['last_signature'].to_s,
            model,
            representation: representation
          )
          entity.name = display_name if entity.respond_to?(:name=)
          if entity.respond_to?(:definition) && entity.definition && entity.definition.valid?
            entity.definition.name = display_name if entity.definition.respond_to?(:name=)
          end
        end

        normalize_space_models_state!(state, model)
        save_state(state, model, write_manifest: false)
        write_space_models_manifest!(state, model, preserve_remote_layout: true, local_space_ids: [item['id']] + Array(linked_rows).map { |row| row['id'].to_s })
        model.commit_operation
      rescue StandardError
        model.abort_operation rescue nil
        rollback_space_file_rename!(new_path, old_path) if file_moved
        item['name'] = old_name if defined?(old_name)
        item['collection_key'] = old_collection if defined?(old_collection)
        item['group_id'] = old_group_id if defined?(old_group_id)
        if !manifest_path.to_s.empty?
          if manifest_existed
            File.write(manifest_path, manifest_backup, mode: 'wb') rescue nil
          elsif File.file?(manifest_path)
            File.delete(manifest_path) rescue nil
          end
        end
        raise
      end

      refresh_dialog
      refresh_soft_designer_fab(model)
      refresh_soft_designer_dialog(refresh_library: false, include_library: false, include_measurements: true)
      refresh_space_management_dialog(model)
      show_status("已将 #{item['number']}:#{old_name}.skp 重命名为 #{item['number']}:#{new_name}.skp，并同步共享文件与协同清单。", 'success')
      true
    end

    def space_delete_dialog_html(item, seconds = SPACE_DELETE_CONFIRM_SECONDS)
      title = "#{item['number']}:#{item['name']}"
      safe_title = title.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
      delete_note = if linked_space_record?(item)
                      '只会删除这个联动空间的放置、名称和清单记录；来源空间与共享 SKP 保持不变。'
                    else
                      '将从当前模型、空间清单和协同目录永久删除共享 SKP，不生成历史副本。需要保留时，请先在系统中手动复制该文件。'
                    end
      <<~HTML
        <!doctype html><html><head><meta charset="utf-8"><style>
        *{box-sizing:border-box}body{margin:0;background:#f7f8fa;color:#1f2937;font:13px -apple-system,BlinkMacSystemFont,"Segoe UI","Microsoft YaHei",sans-serif}
        .box{padding:18px}.title{font-size:15px;font-weight:750;margin-bottom:6px}.sub{font-size:12px;color:#667085;margin-bottom:18px;line-height:1.6}
        .actions{display:flex;justify-content:flex-end;gap:8px}button{height:32px;padding:0 15px;border:1px solid #d0d5dd;border-radius:8px;background:white;color:#344054;cursor:pointer;font-weight:650}button.danger{border-color:#d92d20;background:#d92d20;color:white}button:disabled{opacity:.48;cursor:default}.error{min-height:16px;margin-top:10px;color:#b42318;font-size:11px}
        </style></head><body><div class="box"><div class="title">删除“#{safe_title}”？</div><div class="sub">#{delete_note}</div><div class="actions"><button onclick="cancelDelete()">取消</button><button id="confirm" class="danger" disabled onclick="confirmDelete()">确认删除（#{seconds}）</button></div><div id="error" class="error"></div></div>
        <script>
        let left=#{seconds.to_i};const btn=document.getElementById('confirm');
        const tick=()=>{if(left<=0){btn.disabled=false;btn.textContent='确认删除';return;}btn.textContent='确认删除（'+left+'）';left-=1;setTimeout(tick,1000);};tick();
        function confirmDelete(){if(btn.disabled)return;btn.disabled=true;btn.textContent='删除中…';sketchup.confirm_delete();}
        function cancelDelete(){sketchup.cancel_delete();}
        function showError(message){document.getElementById('error').textContent=message||'删除失败';btn.disabled=false;btn.textContent='确认删除';}
        </script></body></html>
      HTML
    end

    def request_delete_space_model(space_id, model = Sketchup.active_model)
      raise '请先退出所有组件编辑层级。' unless model.active_path.nil?
      state = ensure_space_models_ready!(model)
      item = space_model_record(state, space_id)
      raise '找不到该空间模型。' unless item
      dependents = linked_space_dependents(state, item['id'])
      unless linked_space_record?(item) || dependents.empty?
        names = dependents.first(4).map { |linked| linked['name'].to_s }.join('、')
        raise "该空间仍有 #{dependents.length} 个联动空间（#{names}）。请先删除这些联动空间，再删除来源。"
      end
      raise '该空间正处于强制解锁历史取物模式。请先退出并恢复进入前状态，再删除。' if space_force_recovery_active?(item, state)
      raise '该空间仍在后台发布中；请等待任务完成或失败后再删除。' if background_publish_active_state?(item)
      raise '该空间当前仍有本机未发布修改，不能删除。' if local_space_edit_session?(item, state, model)
      lock = space_lock_info(item, model)
      if lock['exists'] && !lock['stale'] && !lock['owned']
        who = [lock['owner'], lock['host']].reject(&:empty?).join('@')
        raise "该空间正由 #{who.empty? ? '其他成员' : who} 修改，暂时不能删除。"
      end
      @space_delete_dialogs ||= {}
      @space_delete_requests ||= {}
      key = item['id'].to_s
      existing = @space_delete_dialogs[key]
      if existing
        existing.bring_to_front if existing.respond_to?(:bring_to_front)
        return true
      end
      deadline = Time.now.to_f + SPACE_DELETE_CONFIRM_SECONDS
      @space_delete_requests[key] = { 'deadline' => deadline, 'model_id' => model.object_id }
      dialog = UI::HtmlDialog.new(
        dialog_title: '删除空间', preferences_key: "GavinTools_SULinkHubMultiSpace_SpaceDelete_#{key}",
        scrollable: false, resizable: false, width: 380, height: 205,
        min_width: 380, min_height: 205, style: UI::HtmlDialog::STYLE_DIALOG
      )
      @space_delete_dialogs[key] = dialog
      dialog.set_html(space_delete_dialog_html(item))
      dialog.add_action_callback('confirm_delete') do |_ctx|
        begin
          request = @space_delete_requests[key]
          raise '删除确认已失效，请重新点击删除。' unless request && request['model_id'].to_i == model.object_id
          raise '当前已切换到其他 SketchUp 文件，请回到原文件后重新删除。' unless Sketchup.active_model.object_id == request['model_id'].to_i
          remaining = request['deadline'].to_f - Time.now.to_f
          raise "请再等待 #{remaining.ceil} 秒。" if remaining.positive?
          perform_delete_space_model(key)
          @space_delete_requests.delete(key)
          dialog.close if dialog.visible?
        rescue StandardError => e
          log_exception('确认删除空间失败', e)
          dialog.execute_script("showError(#{JSON.generate(e.message.to_s)})") rescue nil
          show_status(e.message.to_s, 'error')
        end
      end
      dialog.add_action_callback('cancel_delete') do |_ctx|
        @space_delete_requests.delete(key)
        dialog.close
      end
      dialog.set_on_closed do
        @space_delete_dialogs.delete(key)
        @space_delete_requests.delete(key)
      end
      dialog.show
      true
    end

    def delete_space_model(space_id)
      request_delete_space_model(space_id)
    end

    def request_delete_selected_space_models(space_ids, model = Sketchup.active_model)
      raise '请先退出所有组件编辑层级。' unless model.active_path.nil?
      state = ensure_space_models_ready!(model)
      raise '空间管理只在硬装或软装工作区提供。' unless space_workspace_role?(host_discipline_for(state))
      ids = Array(space_ids).map(&:to_s).reject(&:empty?).uniq
      raise '请先勾选要删除的空间。' if ids.empty?

      host_key = host_discipline_for(state)
      records = ids.map do |space_id|
        item = space_model_record(state, space_id)
        raise '选择中包含已经不存在的空间，请刷新后重试。' unless item
        raise '选择中包含其他工作区的空间，请刷新后重试。' unless space_record_collection_key(item) == host_key
        raise "#{item['number']}:#{item['name']} 正处于强制解锁历史取物模式，不能删除。" if space_force_recovery_active?(item, state)
        raise "#{item['number']}:#{item['name']} 仍在后台发布中，不能删除。" if background_publish_active_state?(item)
        local_editing = local_space_edit_session?(item, state, model)
        raise "#{item['number']}:#{item['name']} 正在修改中，不能删除。" if local_editing
        dependents = linked_space_dependents(state, item['id'])
        unless linked_space_record?(item) || dependents.empty? || dependents.all? { |linked| ids.include?(linked['id'].to_s) }
          raise "#{item['number']}:#{item['name']} 仍有未勾选的联动空间，请一并勾选删除，或先单独删除联动空间。"
        end
        lock = space_lock_info(item, model, state: state)
        if lock['exists'] && !lock['stale'] && !lock['owned']
          who = [lock['owner'], lock['host']].map(&:to_s).reject(&:empty?).join('@')
          raise "#{item['number']}:#{item['name']} 正由 #{who.empty? ? '其他成员' : who} 修改，不能删除。"
        end
        item
      end

      labels = records.map { |item| "#{item['number']}:#{item['name']}" }
      message = "确定永久删除以下 #{records.length} 个当前工作区空间吗？

#{labels.join('、')}

将同时删除当前模型中的空间实例、协同清单和共享 SKP，无法撤销。"
      return false unless native_confirm_yes?(message)

      deleted = []
      records.sort_by { |item| linked_space_record?(item) ? 0 : 1 }.each do |item|
        perform_delete_space_model(item['id'].to_s)
        deleted << item['id'].to_s
      end
      overlay = workspace_toolbar_overlay(model)
      overlay.clear_space_manage_selection! if overlay && overlay.respond_to?(:clear_space_manage_selection!)
      refresh_workspace_toolbar(model, detailed: true)
      show_status("已删除 #{deleted.length} 个勾选空间。", 'success')
      true
    end

    def perform_delete_space_model(space_id)
      model = Sketchup.active_model
      require_workspace_ready!(nil, model)
      raise '请先退出所有组件编辑层级。' unless model.active_path.nil?
      state = ensure_space_models_ready!(model)
      item = space_model_record(state, space_id)
      raise '找不到该空间模型。' unless item
      dependents = linked_space_dependents(state, item['id'])
      unless linked_space_record?(item) || dependents.empty?
        raise "该空间仍有 #{dependents.length} 个联动空间，请先删除联动空间。"
      end
      raise '该空间正处于强制解锁历史取物模式。请先退出并恢复进入前状态，再删除。' if space_force_recovery_active?(item, state)
      raise '该空间仍在后台发布中；请等待任务完成或失败后再删除。' if background_publish_active_state?(item)
      raise '该空间当前仍有本机未发布修改，不能删除。' if local_space_edit_session?(item, state, model)
      initial_pending = initial_space_publish_pending?(item)
      linked_space = linked_space_record?(item)
      lock = space_lock_info(item, model, state: state)
      if lock['exists'] && !lock['stale'] && !lock['owned']
        who = [lock['owner'], lock['host']].reject(&:empty?).join('@')
        raise "该空间正由 #{who.empty? ? '其他成员' : who} 修改，暂时不能删除。"
      end
      # 首次发布待完成时协同目标本来就可能不存在，禁止 auto_relocate 做无意义的递归恢复；
      # 更重要的是，即使同名目标后来被别人创建，也不能把它当成本机待发布空间的文件删除。
      path = initial_pending ? resolve_path(item['model_path'].to_s, model) : auto_relocate(item['model_path'].to_s, model)
      candidate_path = initial_pending ? item['initial_publish_candidate'].to_s : ''
      close_space_publish_dialog(item['id'], :delete)
      clear_space_publish_pending!(item)
      model.start_operation("删除空间 #{item['number']}:#{item['name']}", true)
      restore_space_isolation!(item, model)
      entity = space_model_entity(space_id, model)
      if entity && entity.valid?
        entity.locked = false if entity.respond_to?(:locked=)
        entity.erase!
      end
      if !linked_space && !initial_pending && File.file?(path)
        File.delete(path)
      end
      # 本地首次发布候选只属于当前工作文件，失败/中断后删除空间时一并清理。
      # 不触碰同名协同目标：它可能是另一成员在冲突窗口中创建的合法文件。
      if initial_pending && !candidate_path.to_s.empty? && File.file?(candidate_path)
        File.delete(candidate_path) rescue nil
      end
      release_space_lock!(item, path, model: model, state: state) unless linked_space
      removed_group_id = item['group_id'].to_s
      state['space_models'].delete_if { |record| record['id'].to_s == space_id.to_s }
      if !removed_group_id.empty? && Array(state['space_models']).none? { |record| record['group_id'].to_s == removed_group_id }
        state['space_groups'].delete_if { |group| group['id'].to_s == removed_group_id }
      end
      if state['space_editing_id'].to_s == space_id.to_s
        state['space_editing_id'] = ''
        state['space_edit_display_mode'] = ''
      end
      normalize_space_models_state!(state, model)
      apply_space_display_scope!(
        state,
        state['space_display_mode'],
        model,
        editing_id: '',
        update_status: false,
        purge: false
      )
      save_state(state, model, write_manifest: false)
      # 从未成功进入共享清单的首次发布待完成空间只做本地丢弃；不能写 deleted id，
      # 也不能误删/改写另一成员可能已经创建出的同名共享目标。
      write_space_models_manifest!(state, model, preserve_remote_layout: true, deleted_space_ids: [space_id]) unless initial_pending
      model.commit_operation
      purge_unused_soft_definitions!(model)
      refresh_dialog
      refresh_workspace_toolbar(model)
      refresh_space_management_dialog(model)
      if linked_space
        show_status("已删除联动空间 #{item['number']}:#{item['name']}；来源空间与共享 SKP 未改变。", 'success')
      elsif initial_pending
        show_status("已删除本地待首次发布空间 #{item['number']}:#{item['name']}；未触碰协同同名文件。", 'success')
      else
        show_status("已删除 #{item['number']}:#{item['name']}；共享文件已永久删除，未生成历史副本。", 'success')
      end
      true
    rescue StandardError
      model.abort_operation rescue nil
      raise
    end

    # 单空间眼睛直接控制该空间根组件。若室内总显示已关闭，先恢复总显示层及
    # 之前的单项状态，再确保目标空间可见，避免公共控制标签继续挡住实体。
    # 单空间眼睛只作用于该空间所属的硬装/软装集合。
    def toggle_single_space_visibility(space_id, model = Sketchup.active_model)
      state = ensure_space_models_ready!(model)
      item = space_model_record(state, space_id)
      raise '找不到该空间。' unless item
      collection_key = space_record_collection_key(item)
      host_key = host_discipline_for(state)
      if space_workspace_role?(host_key) && host_key != collection_key
        raise "当前是#{space_collection_label(host_key)}工作区，请切换到#{space_collection_label(collection_key)}后再控制该空间。"
      end
      entity = space_model_entity(space_id, model)
      raise '该空间尚未载入，无法切换显示。' unless entity && entity.valid?

      collection_hidden = space_collection_hidden_active?(state, model, collection_key)
      currently_hidden = collection_hidden || (entity.respond_to?(:hidden?) && entity.hidden?)
      if !currently_hidden && active_path_inside_space?(entity, model)
        raise '当前正在该空间组件内修改；请先 ESC 退出到全模，再隐藏当前空间。'
      end

      showing = currently_hidden
      model.start_operation(showing ? "显示单个#{space_collection_label(collection_key)}空间" : "隐藏单个#{space_collection_label(collection_key)}空间", true)
      if collection_hidden
        snapshot = space_collection_visibility_snapshot_for(state, collection_key)
        space_collection_control_tags(model, collection_key).each do |tag|
          tag.visible = true if tag.respond_to?(:visible=)
        rescue StandardError
          next
        end
        space_model_entities_for_collection(state, collection_key, model).each do |space_entity|
          key = space_collection_entity_visibility_key(space_entity)
          legacy_key = entity_snapshot_id(space_entity)
          desired = if snapshot['entities'].key?(key)
                      !!snapshot['entities'][key]
                    elsif snapshot['entities'].key?(legacy_key)
                      !!snapshot['entities'][legacy_key]
                    else
                      false
                    end
          space_entity.hidden = desired if space_entity.respond_to?(:hidden=)
        rescue StandardError
          next
        end
        set_space_collection_visibility_snapshot_for!(state, collection_key, { 'entities' => {}, 'tags' => {} })
        set_space_collection_hidden_for!(state, collection_key, false)
        entity.hidden = false if entity.respond_to?(:hidden=)
      else
        entity.hidden = !currently_hidden if entity.respond_to?(:hidden=)
      end

      save_state(state, model, write_manifest: false)
      model.commit_operation
      collection_hidden_now = space_collection_hidden_for(state, collection_key)
      visibility_map = spaces_for_collection(state, collection_key).each_with_object({}) do |space_item, memo|
        space_entity = space_model_entity(space_item['id'], model)
        next unless space_entity && space_entity.valid?
        memo[space_item['id'].to_s] = !(space_entity.respond_to?(:hidden?) && space_entity.hidden?) && !collection_hidden_now
      end
      overlay = workspace_toolbar_overlay(model)
      if overlay
        overlay.set_space_collection_hidden_local!(false) if overlay.respond_to?(:set_space_collection_hidden_local!)
        overlay.update_space_visibility_local!(visibility_map) if overlay.respond_to?(:update_space_visibility_local!)
      end
      model.active_view.invalidate if model.respond_to?(:active_view) && model.active_view
      refresh_dialog
      show_status(showing ? "已显示 #{item['number']}:#{item['name']}。" : "已隐藏 #{item['number']}:#{item['name']}。", 'success')
      true
    rescue StandardError
      model.abort_operation rescue nil
      raise
    end

    def toggle_space_collection_visibility
      model = Sketchup.active_model
      raise '请先退出所有组件编辑层级。' unless model.active_path.nil?
      state = ensure_space_models_ready!(model)
      collection_key = host_discipline_for(state)
      raise '请先切换到硬装或软装工作区。' unless space_workspace_role?(collection_key)
      active = space_model_record(state, state['space_editing_id']) unless state['space_editing_id'].to_s.empty?
      if active && active['editing'] && space_record_collection_key(active) == collection_key
        raise '空间修改期间请使用该条目上的小眼睛切换参考显示，完成发布或更新后再隐藏当前工作区空间。'
      end
      entities = space_model_entities_for_collection(state, collection_key, model)
      label = space_collection_label(collection_key)
      raise "当前模型中还没有已载入的#{label}空间。" if entities.empty?
      tags = space_collection_control_tags(model, collection_key)
      collection_hidden = space_collection_hidden_active?(state, model, collection_key)
      set_space_collection_hidden_for!(state, collection_key, collection_hidden)
      hiding = !collection_hidden
      model.start_operation(hiding ? "隐藏全部#{label}空间" : "显示全部#{label}空间", true)
      if hiding
        snapshot = { 'entities' => {}, 'tags' => {} }
        tags.each do |tag|
          snapshot['tags'][tag.name.to_s] = tag.respond_to?(:visible?) ? !!tag.visible? : true
          tag.visible = false if tag.respond_to?(:visible=)
        rescue StandardError
          next
        end
        entities.each do |entity|
          snapshot['entities'][space_collection_entity_visibility_key(entity)] = !!entity.hidden?
          entity.hidden = true if entity.respond_to?(:hidden=)
        rescue StandardError
          next
        end
        set_space_collection_visibility_snapshot_for!(state, collection_key, snapshot)
        set_space_collection_hidden_for!(state, collection_key, true)
      else
        snapshot = space_collection_visibility_snapshot_for(state, collection_key)
        tags.each do |tag|
          tag.visible = true if tag.respond_to?(:visible=)
        rescue StandardError
          next
        end
        entities.each do |entity|
          key = space_collection_entity_visibility_key(entity)
          legacy_key = entity_snapshot_id(entity)
          desired = if snapshot['entities'].key?(key)
                      !!snapshot['entities'][key]
                    elsif snapshot['entities'].key?(legacy_key)
                      !!snapshot['entities'][legacy_key]
                    else
                      false
                    end
          entity.hidden = desired if entity.respond_to?(:hidden=)
        rescue StandardError
          next
        end
        set_space_collection_visibility_snapshot_for!(state, collection_key, { 'entities' => {}, 'tags' => {} })
        set_space_collection_hidden_for!(state, collection_key, false)
      end
      model.active_view.invalidate if model.respond_to?(:active_view) && model.active_view
      save_state(state, model, write_manifest: false)
      model.commit_operation
      collection_hidden_now = space_collection_hidden_for(state, collection_key)
      visibility_map = spaces_for_collection(state, collection_key).each_with_object({}) do |space_item, memo|
        space_entity = space_model_entity(space_item['id'], model)
        next unless space_entity && space_entity.valid?
        memo[space_item['id'].to_s] = !(space_entity.respond_to?(:hidden?) && space_entity.hidden?) && !collection_hidden_now
      end
      overlay = workspace_toolbar_overlay(model)
      if overlay
        overlay.set_space_collection_hidden_local!(collection_hidden_now) if overlay.respond_to?(:set_space_collection_hidden_local!)
        overlay.update_space_visibility_local!(visibility_map) if overlay.respond_to?(:update_space_visibility_local!)
      end
      refresh_dialog
      show_status(hiding ? "已一键隐藏全部#{label}空间。" : "已显示#{label}空间，并恢复隐藏前的单项状态。", 'success')
      true
    rescue StandardError
      model.abort_operation rescue nil
      raise
    end

    def validate_space_display_switch_context!(state, model = Sketchup.active_model, allow_architecture_context: false, allow_landscape_context: false)
      editing_id = state['space_editing_id'].to_s
      path = model.respond_to?(:active_path) ? model.active_path : nil
      if editing_id.empty?
        return true if path.nil?
        if allow_architecture_context
          architecture_entity = native_edit_entity('architecture', model)
          architecture_source = architecture_edit_source_entity(architecture_entity)
          return true if architecture_entity && active_path_inside_architecture?(architecture_entity, architecture_source, model)
        end
        if allow_landscape_context
          landscape_entity = native_edit_entity('landscape', model)
          landscape_source = landscape_edit_source_entity(landscape_entity)
          return true if landscape_entity && active_path_inside_landscape?(landscape_entity, landscape_source, model)
        end
        raise '请先退出组件编辑层级，再切换全部空间的代/真模式。'
      end

      current = space_model_entity(editing_id, model)
      raise '当前修改空间尚未载入。' unless current && current.valid?
      return true if path.nil?
      unless path.is_a?(Array) && !path.empty? && path.first == current
        raise '代/真切换只能作用于当前正在修改的空间。'
      end

      # v0.12.6：允许在空间内部继续套群组/组件进行家具布置时直接切换代/真，
      # 不再强迫用户退回空间最外层。唯一需要避开的情况是“正钻进某个受管家具
      # 自己的组件内部编辑”，因为此时替换该家具 definition 会让 SU 的 active_path
      # 指向正在被替换的定义，容易造成上下文跳出或崩溃。
      nested_managed = Array(path)[1..].to_a.find do |node|
        next false unless node && node.valid?
        info = soft_instance_metadata(node)
        !info['model_id'].to_s.empty? || !info['source_path'].to_s.empty? || soft_legacy_proxy_entity?(node)
      end
      if nested_managed
        raise '当前正在进入某个受管家具组件内部编辑；请退到该家具外一层即可切换代/真，不需要退出整个空间。'
      end
      true
    end

    # v0.13.6.97：软装空间采用“活动空间独占真模”生命周期。离开空间只把实例
    # 切回代理，不 purge 真模 Definition；这样内存 resident 缓存仍在，下次进入可纯内存
    # 恢复，而其它被锁空间不会继续拿着同一批 full Definition 制造锁 occurrence 传播。
    def downgrade_space_soft_to_proxy_for_blur!(item, entity, model = Sketchup.active_model, reason: '离开空间')
      return { changed: 0, matched: 0 } unless item && entity && entity.valid? && model
      return { changed: 0, matched: 0 } unless space_record_collection_key(item) == SOFT_SPACE_COLLECTION_KEY
      instances = soft_instances_for_space(entity, model, force: true)
      instances = Array(instances).select { |instance| instance && instance.valid? }
      pending_ingest = soft_pending_ingest_entities(model)
      held_original = instances.select { |instance| pending_ingest.include?(instance) }
      instances -= held_original
      if instances.empty?
        soft_set_attribute_if_changed(entity, ENTITY_DICT, 'space_representation', 'mixed') if held_original.any?
        return { changed: 0, matched: held_original.length, unresolved: held_original.length,
                 unresolved_instances: [], held_instances: held_original }
      end
      needs_proxy = instances.any? { |instance| !soft_instance_representation_ready?(instance, 'proxy') }
      unless needs_proxy
        soft_set_attribute_if_changed(entity, ENTITY_DICT, 'space_representation', 'mixed') if held_original.any?
        return { changed: 0, matched: instances.length + held_original.length, unresolved: held_original.length,
                 unresolved_instances: [], held_instances: held_original }
      end
      changed = apply_space_soft_representation!(entity, 'proxy', model, purge: false, instances: instances).to_i
      unresolved_list = instances.select { |instance| instance && instance.valid? && !soft_instance_representation_ready?(instance, 'proxy') }
      unresolved = unresolved_list.length
      if held_original.any?
        unresolved += held_original.length
        soft_set_attribute_if_changed(entity, ENTITY_DICT, 'space_representation', 'mixed')
      end
      log("活动空间退出降级代理：#{item['number']}:#{item['name']} / #{reason} / 识别#{instances.length + held_original.length} / 替换#{changed} / 待入库保持原状#{held_original.length} / 未完成#{unresolved}")
      { changed: changed, matched: instances.length + held_original.length, unresolved: unresolved,
        unresolved_instances: unresolved_list, held_instances: held_original }
    rescue StandardError => e
      log_exception("活动空间退出切代理失败：#{item && item['number']}:#{item && item['name']}", e)
      { changed: 0, matched: 0, error: e.message.to_s }
    end

    # 只恢复本次 SketchUp 会话已经驻留的真模型；没有 resident 命中的家具继续代理，
    # 绝不为了自动进入空间访问 NAS / 模型库。现有 apply_space_soft_full_models! 已把
    # resident 命中放在所有文件 I/O 之前，所以这里只把“有 resident 的实例”传进去。
    def restore_space_soft_from_resident_cache!(item, entity, model = Sketchup.active_model)
      return { changed: 0, matched: 0 } unless item && entity && entity.valid? && model
      return { changed: 0, matched: 0 } unless space_record_collection_key(item) == SOFT_SPACE_COLLECTION_KEY
      instances = soft_instances_for_space(entity, model, force: true)
      instances = Array(instances).select { |instance| instance && instance.valid? }
      resident_instances = instances.select do |instance|
        resident_soft_full_match(soft_instance_metadata(instance), model)
      rescue StandardError
        nil
      end
      return { changed: 0, matched: 0, total: instances.length } if resident_instances.empty?
      changed = apply_space_soft_full_models!(entity, model, instances: resident_instances).to_i
      full_count = instances.count { |instance| instance && instance.valid? && soft_instance_representation_ready?(instance, 'full') }
      root_mode = full_count == instances.length && instances.length.positive? ? 'full' : (full_count.positive? ? 'mixed' : 'proxy')
      soft_set_attribute_if_changed(entity, ENTITY_DICT, 'space_representation', root_mode)
      log("活动空间进入恢复 resident 真模：#{item['number']}:#{item['name']} / resident=#{resident_instances.length}/#{instances.length} / 替换#{changed} / mode=#{root_mode}")
      { changed: changed, matched: resident_instances.length, total: instances.length, full: full_count }
    rescue StandardError => e
      log_exception("活动空间 resident 真模恢复失败：#{item && item['number']}:#{item && item['name']}", e)
      { changed: 0, matched: 0, error: e.message.to_s }
    end

    # 升级旧会话/旧项目时可能已有别的软装空间还保持 full。进入新空间前顺手把
    # 非活动软装空间降回代理；根锁只在本方法内部短暂释放并原样恢复，不改变协作状态。
    def downgrade_inactive_soft_spaces_to_proxy!(state, active_space_id, model = Sketchup.active_model)
      return 0 unless state.is_a?(Hash) && model
      changed = 0
      Array(state['space_models']).each do |other_item|
        next unless other_item.is_a?(Hash) && space_record_collection_key(other_item) == SOFT_SPACE_COLLECTION_KEY
        next if other_item['id'].to_s == active_space_id.to_s
        other_entity = space_model_entity(other_item['id'], model)
        next unless other_entity && other_entity.valid?
        instances = soft_instances_for_space(other_entity, model, force: true)
        next if instances.empty? || instances.all? { |instance| soft_instance_representation_ready?(instance, 'proxy') }
        was_locked = other_entity.respond_to?(:locked?) ? other_entity.locked? : false
        other_entity.locked = false if was_locked && other_entity.respond_to?(:locked=)
        result = downgrade_space_soft_to_proxy_for_blur!(other_item, other_entity, model, reason: '进入其它空间')
        changed += result[:changed].to_i
        other_entity.locked = true if was_locked && other_entity && other_entity.valid? && other_entity.respond_to?(:locked=)
      rescue StandardError => e
        other_entity.locked = true if defined?(was_locked) && was_locked && other_entity && other_entity.valid? && other_entity.respond_to?(:locked=)
        log_exception('非活动软装空间自动回代理失败', e)
        next
      end
      changed
    rescue StandardError => e
      log_exception('批量降级非活动软装空间失败', e)
      0
    end

    # 未修改空间时，代/真是全部空间的全局模式。修改某个空间时，其他联动
    # 根模型已经隐藏，开关只处理当前工作空间，不再为了不可见对象额外加载、
    # 替换或清理定义。退出修改后再一次性恢复全局模式。
    def apply_space_display_scope!(state, desired = nil, model = Sketchup.active_model, editing_id: nil, update_status: true, purge: true)
      desired = effective_space_display_mode(state) if desired.to_s.empty?
      desired = desired.to_s == 'full' ? 'full' : 'proxy'
      active_editing_id = editing_id.nil? ? state['space_editing_id'].to_s : editing_id.to_s
      loaded = Array(state['space_models']).map do |item|
        [item, space_model_entity(item['id'], model)]
      end.select { |_item, entity| entity && entity.valid? }
      loaded.select! { |item, _entity| item['id'].to_s == active_editing_id } unless active_editing_id.empty?
      failures = []
      failure_ids = []
      unresolved_instances = []
      changed = 0
      matched = 0

      # 顶层批量切换时先临时隐藏空间根组件。start_operation 已禁用 UI 更新，
      # 再隐藏根组件可避免每替换一个高模定义就触发一次昂贵的视口重建。
      hidden_records = []
      if model.active_path.nil? && loaded.length.positive?
        loaded.each do |_item, entity|
          next unless entity.respond_to?(:hidden?) && entity.respond_to?(:hidden=)
          hidden_records << [entity, entity.hidden?]
          entity.hidden = true unless entity.hidden?
        rescue StandardError
          next
        end
      end

      begin
        loaded.each do |item, entity|
          target = desired
          begin
            actual = entity.get_attribute(ENTITY_DICT, 'space_representation', 'full').to_s
            trusted = trusted_space_representation?(entity, target)
            # proxy 的“已验证”只能证明空间文件没变，不能证明它仍是最新代理形态。
            trusted = false if target == 'proxy' && trusted && space_proxy_visual_upgrade_needed?(entity, model)
            instances = []
            if trusted
              matched += 1
            else
              instances = soft_instances_for_space(entity, model)
              instances = soft_instances_for_space(entity, model, force: true) if instances.empty?
              matched += instances.length
              nested_mismatch = instances.any? do |instance|
                !soft_instance_representation_ready?(instance, target) ||
                  (target == 'proxy' && !soft_instance_uses_authoritative_visual_proxy?(instance))
              end
              if actual != target || nested_mismatch
                changed += apply_space_soft_representation!(entity, target, model, purge: false, instances: instances).to_i
              end
            end

            # v0.13.6.13：切真模型改为“能切的先切，失联的保持代理”。只有代理切换
            # 仍要求完整成功，因为代理是发布/性能安全模式，不能留下半真半代却声称已代理。
            remaining = if target == 'full' && !instances.empty?
                          instances.reject { |instance| soft_instance_representation_ready?(instance, 'full') }
                        elsif target == 'proxy' && !instances.empty?
                          instances.reject { |instance| soft_instance_representation_ready?(instance, 'proxy') }
                        else
                          []
                        end
            if target == 'full' && remaining.any?
              unresolved_instances.concat(remaining)
              failure_ids << item['id'].to_s unless failure_ids.include?(item['id'].to_s)
              names = soft_full_switch_failure_rows(remaining, model).first(5).map do |row|
                row[:count].to_i > 1 ? "#{row[:name]}×#{row[:count]}" : row[:name].to_s
              end
              detail = names.empty? ? '' : "：#{names.join('、')}#{soft_full_switch_failure_rows(remaining, model).length > 5 ? '…' : ''}"
              failures << "#{item['number']}:#{item['name']}（#{remaining.length} 个保持代理#{detail}）"
            elsif target == 'proxy' && remaining.any?
              # v0.13.6.179：代理切换允许“可用的先切，缺代理的立即补齐”，不再因为
              # 少数家具缺失/过期代理而撤销整个空间。unresolved_instances 会在事务提交
              # 后进入高优先级代理生成队列，生成完成后自动替换这些真模型实例。
              unresolved_instances.concat(remaining)
            end

            if update_status
              item['status'] = if target == 'full' && remaining.any?
                                 names = soft_proxy_switch_instance_summary(remaining, limit: 3)
                                 active_editing_id.empty? ? "真模型部分显示 · 保持代理：#{names}" : "当前空间真模型部分显示 · 保持代理：#{names}"
                               elsif target == 'proxy' && remaining.any?
                                 names = soft_proxy_switch_instance_summary(remaining)
                                 active_editing_id.empty? ? "代理补齐中 · #{names}" : "当前空间代理补齐中 · #{names}"
                               elsif active_editing_id.empty?
                                 target == 'proxy' ? '家具已切换为代理' : '家具已切换为真模型'
                               elsif item['id'].to_s == active_editing_id
                                 target == 'proxy' ? '当前空间使用代理' : '当前空间使用真模型预览'
                               end
            end
          rescue StandardError => e
            failure_ids << item['id'].to_s unless failure_ids.include?(item['id'].to_s)
            failures << "#{item['number']}:#{item['name']}（#{e.message}）"
            # 空间级异常也不能让“部分切真”失去诊断名单。重新只读扫描当前空间，
            # 把仍未处于 full 的家具标记为保持代理；不再因此撤销其它空间/款式。
            if target == 'full'
              failed_instances = soft_instances_for_space(entity, model, force: true).select do |instance|
                instance && instance.valid? && !soft_instance_representation_ready?(instance, 'full')
              end
              unless failed_instances.empty?
                mark_soft_full_switch_failure(failed_instances, "空间级切换异常：#{e.message}")
                unresolved_instances.concat(failed_instances)
              end
            end
          end
        end
      ensure
        hidden_records.each do |entity, was_hidden|
          entity.hidden = was_hidden if entity && entity.valid? && entity.respond_to?(:hidden=)
        rescue StandardError
          next
        end
      end
      purge_unused_soft_definitions!(model) if purge
      unresolved_instances = unresolved_instances.select { |instance| instance && instance.valid? }.uniq
      {
        failures: failures,
        failure_ids: failure_ids,
        unresolved_instances: unresolved_instances,
        unresolved_rows: soft_full_switch_failure_rows(unresolved_instances, model),
        changed: changed,
        matched: matched,
        scope: active_editing_id.empty? ? 'all' : 'current'
      }
    end

    def set_space_display_mode(mode, model = Sketchup.active_model, allow_architecture_context: false, allow_landscape_context: false, scope_space_id: '', silent: false, purge_full_after_proxy: nil, state: nil)
      switch_started = monotonic_time
      desired = mode.to_s == 'full' ? 'full' : 'proxy'
      raise '发布正在进行或仍处于原生收尾阶段，请稍后再切换代/真模型。' if publish_critical_section? || publish_post_quiet?
      raise '空间模型正在更新，请等待完成后再切换代/真模型。' if @updating || @single_space_update_job || @space_batch_update_job
      raise '模型库批量任务正在执行，请等待完成后再切换代/真模型。' if @soft_model_batch_job
      guard_soft_individual_edit_representation_switch!(model, desired: desired)
      state = ensure_space_models_ready!(model) unless state.is_a?(Hash)
      validate_space_display_switch_context!(
        state,
        model,
        allow_architecture_context: allow_architecture_context,
        allow_landscape_context: allow_landscape_context
      )
      scope_id = scope_space_id.to_s
      if state['space_editing_id'].to_s.empty? && scope_id.empty?
        if desired == 'full'
          selected_space = selected_workspace_space_record(state, model)
          raise '为避免一次载入全部空间高模，请先在视口中选中一个硬装/软装空间根组件，再切换真模型。插件只会临时展开该空间。' unless selected_space
          scope_id = selected_space['id'].to_s
        elsif desired == 'proxy'
          preview_id = state['space_preview_full_id'].to_s
          scope_id = preview_id unless preview_id.empty?
        end
      end
      if desired == 'full' && state['space_editing_id'].to_s.empty?
        pressure_scope_id = scope_id.to_s.empty? ? state['space_editing_id'].to_s : scope_id.to_s
        profile = soft_representation_pressure_profile(state, model, scope_space_id: pressure_scope_id)
        if soft_global_full_pressure_high?(profile)
          raise "目标空间规模较大（#{soft_pressure_summary(profile)}）。为避免 SketchUp 长时间无响应，请进入该空间修改后再切换真模型。"
        end
      end
      state_before = {
        'space_display_mode' => state['space_display_mode'],
        'space_edit_display_mode' => state['space_edit_display_mode'],
        'space_preview_full_id' => state['space_preview_full_id']
      }
      status_before = Array(state['space_models']).each_with_object({}) do |item, memo|
        memo[item['id'].to_s] = item['status']
      end
      scoped_preview = !scope_id.empty? && state['space_editing_id'].to_s.empty?
      if scoped_preview
        state['space_preview_full_id'] = desired == 'full' ? scope_id : ''
        state['space_display_mode'] = 'proxy'
        state['space_edit_display_mode'] = ''
      elsif state['space_editing_id'].to_s.empty?
        state['space_display_mode'] = desired
        state['space_edit_display_mode'] = ''
        state['space_preview_full_id'] = '' if desired == 'proxy'
      else
        state['space_edit_display_mode'] = desired
      end
      # 新一轮切换开始前让所有高模回收任务失效。用户交互永远高于后台回收；
      # 不能一边切真/代理，一边让上一轮发布后的 idle timer 删除同一个 Definition。
      note_runtime_interaction!(model)
      cancel_soft_full_definition_cleanup!(model)
      cancel_soft_resident_cache_cleanup!(model)
      operation_started = false
      operation_committed = false
      result = nil
      with_soft_representation_switch(model) do
        model.start_operation(desired == 'proxy' ? '家具切换为代理' : '家具切换为真模型', true)
        operation_started = true
        result = apply_space_display_scope!(
          state,
          desired,
          model,
          editing_id: (scope_id.empty? ? nil : scope_id),
          update_status: true,
          purge: false
        )
        # v0.13.6.179：代理模式不再要求“所有实例一次性成功”才提交事务。
        # 能解析代理的家具先切；真正缺失/过期代理的实例留在真模型，事务提交后立即
        # 生成对应六面代理并自动补切。这样不会再出现“47 件里 2 件缺代理，全部回滚”。
        save_state(state, model, write_manifest: false)
        model.commit_operation
        operation_started = false
        operation_committed = true
      end

      proxy_pending_instances = if desired == 'proxy'
                                  Array(result && result[:unresolved_instances]).select { |instance| instance && instance.valid? }.uniq
                                else
                                  []
                                end
      proxy_refresh_result = { started: 0, rows: [], error: '' }
      # v0.13.6.182：用户刚切真模型，后台自动修复/代理刷新完成时不得再把这些实例弹回代理。
      drop_soft_proxy_queue_replace_targets!(model, scope_space_id: scope_id.to_s) if desired == 'full'
      unless proxy_pending_instances.empty?
        queue_scope_id = scope_id.to_s
        queue_scope_id = state['space_editing_id'].to_s if queue_scope_id.empty?
        proxy_refresh_result = request_immediate_soft_proxy_refresh_for_instances!(
          proxy_pending_instances, model, scope_space_id: queue_scope_id
        )
      end

      host_key = host_discipline_for(state)
      # v0.13.6.61：只保留最近两个空间的真模型热缓存。切到第三个空间时，较旧预览
      # 会由压力回收器在空闲帧逐个 Definition 卸载；当前/新空间因为仍有实例不会被删。
      # 这比“每次切回代理立即 purge”稳定，也避免连续预览十几个空间后内存一直抬高。
      if desired == 'full' && host_key == SOFT_SPACE_COLLECTION_KEY && !scope_id.empty?
        if soft_resident_cache_pressure?(model)
          schedule_soft_resident_cache_cleanup(model, delay: 0.9, reason: 'preview_lru_pressure', force_pressure: true)
        end
      end
      # 建筑/景观仍保留原有代理优先释放策略；软装家具的交互代/真切换改为会话驻留。
      # 对软装来说，“删除后再加载”比“保留并复用”更耗内存、更慢，而且会被 Undo/native
      # allocator 保留高水位，因此即使显式 purge_full_after_proxy 也不在这里执行。
      should_purge_full = if host_key == SOFT_SPACE_COLLECTION_KEY
                            false
                          elsif purge_full_after_proxy.nil?
                            desired == 'proxy' && SOFT_PROXY_FIRST_HOSTS.include?(host_key)
                          else
                            desired == 'proxy' && purge_full_after_proxy == true
                          end
      cleanup_scheduled = should_purge_full ? schedule_soft_full_definition_cleanup(model) : false
      resident_cleanup_scheduled = false
      if host_key == SOFT_SPACE_COLLECTION_KEY && desired == 'proxy'
        # 如果这个空间此前已经“发布成功→可回收”，发布时的 worker 可能因当时仍是
        # full 显示而没有候选。此刻切回代理后再轻量唤醒一次即可；未发布热缓存
        # releasable=false，不会因为普通回切而被删除。
        if !soft_resident_cleanup_candidates(model, force_pressure: false).empty?
          resident_cleanup_scheduled = schedule_soft_resident_cache_cleanup(
            model, delay: SOFT_RESIDENT_CACHE_STEP_DELAY, reason: 'proxy_after_publish', force_pressure: false
          )
        end
      end
      overlay = workspace_toolbar_overlay(model)
      if overlay && overlay.respond_to?(:set_representation_mode_local!)
        overlay.set_representation_mode_local!(
          desired,
          preview_space_id: state['space_preview_full_id'].to_s
        )
      end
      model.active_view.invalidate if model.respond_to?(:active_view) && model.active_view
      schedule_coalesced_refresh_dialog(0.12)

      unresolved = Array(result[:unresolved_instances]).select { |instance| instance && instance.valid? }
      if scoped_preview
        message = desired == 'proxy' ? '选中空间已恢复家具代理。' : '选中空间已展开可用真模型；其他空间继续保持代理。'
      elsif result[:scope] == 'current'
        message = desired == 'proxy' ? '当前工作空间已切换为代理。' : '当前工作空间已展开可用真模型。'
      else
        message = desired == 'proxy' ? '全部空间已切换为家具代理。' : '已展开作用域内可用的家具真模型。'
      end
      message += ' 闲置真模型将在后台分批卸载。' if cleanup_scheduled
      if desired == 'proxy' && host_key == SOFT_SPACE_COLLECTION_KEY
        message += ' 已加载真模型保留为本会话热缓存，后续再次切真将直接复用。'
      end
      if result[:matched].to_i.zero?
        message = result[:scope] == 'current' ? '当前空间没有识别到受管家具；请使用模型库“放置”或“替换”登记家具。' : '已载入空间中没有识别到受管家具。'
      elsif desired == 'full' && unresolved.any?
        message += " #{soft_proxy_switch_instance_summary(unresolved)} 失联/载入失败，保持原代理；其它正常家具已切换。"
      elsif desired == 'proxy' && unresolved.any?
        names = soft_proxy_switch_instance_summary(unresolved)
        if proxy_refresh_result[:started].to_i.positive?
          message = "可用家具已正常切换为代理；#{names} 暂保持真模型，正在立即生成最新代理，完成后自动切换。"
        else
          detail = proxy_refresh_result[:error].to_s
          detail = '代理生成任务未能启动' if detail.empty?
          message = "可用家具已正常切换为代理；#{names} 暂保持真模型。#{detail}。"
        end
      elsif result[:changed].to_i.zero? && result[:failures].empty?
        message += ' 当前家具已经处于该显示模式。'
      end
      if desired == 'proxy' && !result[:failures].empty?
        message += " 切换异常：#{Array(result[:failures]).first(3).join('；')}#{result[:failures].length > 3 ? "；另 #{result[:failures].length - 3} 个空间" : ''}。"
      end
      log("软装代真切换 #{desired}：#{elapsed_ms(switch_started)}ms，作用域=#{scope_id.empty? ? result[:scope] : scope_id}，识别 #{result[:matched]}，替换 #{result[:changed]}，空间异常 #{result[:failures].length}，保持代理 #{unresolved.length}，后台清理=#{cleanup_scheduled}，驻留回收=#{resident_cleanup_scheduled}")
      unless silent
        status_type = if (desired == 'full' || desired == 'proxy') && unresolved.any?
                        'warning'
                      elsif result[:failures].empty? && result[:matched].to_i.positive?
                        'success'
                      else
                        'error'
                      end
        show_status(message, status_type)
        show_soft_full_switch_failure_report(unresolved, model, title: '真模型部分切换完成') if desired == 'full' && unresolved.any?
      end
      true
    rescue StandardError
      model.abort_operation rescue nil if operation_started
      if !operation_committed && defined?(state) && state.is_a?(Hash)
        state_before&.each { |key, value| state[key] = value }
        if defined?(status_before) && status_before.is_a?(Hash)
          Array(state['space_models']).each do |item|
            item['status'] = status_before[item['id'].to_s] if status_before.key?(item['id'].to_s)
          end
        end
      end
      raise
    end

    def space_model_needs_update?(item, model = Sketchup.active_model)
      state = load_state(model)
      sync_space_models_from_manifest!(state, model)
      current_item = space_model_record(state, item['id']) || item
      entity = space_model_entity(current_item['id'], model)
      actual = entity && entity.valid? ? entity.get_attribute(ENTITY_DICT, 'space_representation', state['space_display_mode']).to_s : state['space_display_mode'].to_s
      asset = space_asset_for(current_item, state, model, representation: actual)
      path = asset[:path]
      return false unless File.file?(path)
      return true unless entity && entity.valid?
      return true if entity.get_attribute(ENTITY_DICT, 'source_load_verified_schema', 0).to_i < SPACE_LOAD_VERIFIED_SCHEMA
      direction = space_update_direction(current_item, entity, path)
      direction != :same
    rescue StandardError
      true
    end

    def update_all_with_spaces
      model = Sketchup.active_model
      architecture_ok = update_all_architecture_models(notify: false, model: model)
      landscape_ok = update_links(%w[landscape], notify: false, force: false)
      success = architecture_ok && landscape_ok
      completion = proc do |batch|
        refresh_dialog
        if batch[:failed].empty?
          message = batch[:updated].positive? ? "建筑、景观与硬装/软装空间更新完成；已更新 #{batch[:updated]} 个空间。" : '建筑、景观与硬装/软装空间均已是当前发布版。'
          show_status(message, success ? 'success' : 'error')
        else
          show_status("部分硬装/软装空间更新失败：#{batch[:failed].join('；')}", 'error')
        end
      end
      batch = update_space_models_batch(notify: false, model: model, completion: completion)
      if batch[:pending]
        show_status('建筑与景观阶段已完成；硬装/软装空间文件正在后台准备，完成后会自动载入。', success ? 'info' : 'error')
        return success
      end
      success && batch[:ok]
    end


    end
  end
end
