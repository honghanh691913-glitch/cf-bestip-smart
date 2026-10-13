# frozen_string_literal: true

# v0.13.6.190：插件内置只读诊断中心。
# - 诊断当前选择（双击 / 联动空间 / 锁 / 索引重复）
# - 家具变形只读诊断（全模型，内置 FurnitureReadOnlyDiagnostic）
# - 导出日志诊断包（复制 %TEMP%\SU_LinkHub\logs 下的关键日志尾部）
# 全部只读：不开启 operation、不写实体属性、不改变 transformation / definition / 锁状态，
# 不读写共享目录。唯一写入是 %TEMP%\SU_LinkHub\diagnostics 下的诊断结果文件。

module GavinTools
  module SULinkHubMultiSpace
    module Runtime
    LH_DIAG_LOG_TAIL_BYTES = 6 * 1024 * 1024 unless const_defined?(:LH_DIAG_LOG_TAIL_BYTES, false)

    def lh_diag_output_dir(kind)
      stamp = Time.now.strftime('%Y%m%d_%H%M%S')
      dir = File.join(TEMP_DIAGNOSTIC_DIR, "#{kind}_#{stamp}")
      FileUtils.mkdir_p(dir)
      dir
    end

    def lh_diag_open_folder(path)
      return false if path.to_s.empty?
      UI.openURL("file:///#{path.to_s.tr('\\', '/')}")
      true
    rescue StandardError
      false
    end

    def lh_diag_try(fallback = nil)
      yield
    rescue StandardError => e
      fallback.nil? ? "（读取失败 #{e.class}: #{e.message}）" : fallback
    end

    def lh_diag_entity_label(entity)
      return '（无）' unless entity
      return '（已失效）' unless entity.valid?
      pid = entity.respond_to?(:persistent_id) ? entity.persistent_id : 0
      name = entity.respond_to?(:name) ? entity.name.to_s : ''
      dname = entity.respond_to?(:definition) && entity.definition ? entity.definition.name.to_s : ''
      "#{entity.class.name.split('::').last} pid=#{pid} 名称=“#{name}” 定义=“#{dname}”"
    rescue StandardError
      entity.class.name.to_s
    end

    def lh_diag_dict_dump(entity, dict_name, limit: 60)
      dict = entity.attribute_dictionary(dict_name, false) rescue nil
      return [] unless dict
      rows = []
      dict.each_pair do |key, value|
        text = value.is_a?(Array) ? "[#{value.length}项] #{value.first(4).inspect}" : value.inspect
        text = "#{text[0, 160]}…" if text.length > 160
        rows << "      #{key} = #{text}"
        break if rows.length >= limit
      end
      rows
    rescue StandardError
      []
    end

    # 世界根所有 space_model 根实例按 space_id 分组；返回重复项（同 id 多个根实例）。
    def lh_diag_duplicate_space_roots(model = Sketchup.active_model)
      groups = Hash.new { |hash, key| hash[key] = [] }
      model.entities.each do |entity|
        next unless entity && entity.valid? && entity.respond_to?(:get_attribute)
        next unless entity.get_attribute(ENTITY_DICT, 'managed', false) == true
        next unless entity.get_attribute(ENTITY_DICT, 'kind', '').to_s == 'space_model'
        space_id = entity.get_attribute(ENTITY_DICT, 'space_id', '').to_s
        groups[space_id] << entity unless space_id.empty?
      end
      groups.select { |_id, rows| rows.length > 1 }
    rescue StandardError
      {}
    end

    def lh_diag_log_tail_lines(path, pattern: nil, limit: 80, bytes: 2 * 1024 * 1024)
      return [] unless File.file?(path.to_s)
      size = File.size(path)
      data = File.open(path, 'rb') do |file|
        file.seek([size - bytes, 0].max)
        file.read
      end.to_s.force_encoding('UTF-8')
      data = data.scrub('?')
      lines = data.lines.map(&:rstrip)
      lines = lines.select { |line| line =~ pattern } if pattern
      lines.last(limit)
    rescue StandardError
      []
    end

    def lh_diag_selection_report(model = Sketchup.active_model)
      lines = []
      conclusions = []
      add = ->(text = '') { lines << text.to_s }
      add.call("SU LinkHub 选择 / 双击 / 联动空间 只读诊断  v#{EXTENSION_VERSION}")
      add.call("时间：#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}    SketchUp #{lh_diag_try { Sketchup.version }}")
      add.call("模型：#{model.path}")
      state = lh_diag_try({}) { cached_project_state_readonly(model) || load_state(model) }
      state = {} unless state.is_a?(Hash)
      configured = lh_diag_try(false) { workspace_selection_configured?(state, model) }
      add.call("工作区：host=#{state['host_discipline']}  当前=#{lh_diag_try { current_workspace_role(model) }}  已配置=#{configured}")
      conclusions << '工作区未完成配置/连接，双击桥不会接管任何对象。' unless configured == true
      path = Array(model.active_path)
      add.call("active_path 深度：#{path.length}#{path.empty? ? '（世界根）' : "  根=#{lh_diag_entity_label(path.first)}"}")
      add.call("当前工具：#{lh_diag_try { model.tools.active_tool_name }} (#{lh_diag_try { model.tools.active_tool_id }})")
      add.call

      key = model.object_id
      now = monotonic_seconds
      add.call('— 运行状态 —')
      add.call("  发布关键段=#{lh_diag_try { publish_critical_section? }}  发布后静默=#{lh_diag_try { publish_post_quiet? }}（剩余 #{lh_diag_try { publish_quiet_remaining.round(2) }}s）")
      add.call("  正在更新=#{!!@updating}  单空间更新=#{!!@single_space_update_job}  批量更新=#{!!@space_batch_update_job}  入库批次=#{!!@soft_ingest_batch_job}")
      add.call("  重交互(soft_heavy)=#{lh_diag_try { soft_heavy_interaction? }}  ESC退出过渡=#{lh_diag_try { workspace_escape_transition_active?(model) }}")
      suppress = (@workspace_double_click_rearm_suppress_until || {})[key].to_f - now
      click_suppress = (@workspace_double_click_suppress_until || {})[key].to_f - now
      add.call("  双击重武装屏蔽剩余=#{[suppress, 0].max.round(2)}s  双击执行屏蔽剩余=#{[click_suppress, 0].max.round(2)}s")
      bridge = (@workspace_double_click_bridge_records || {})[key]
      if bridge.is_a?(Hash)
        add.call("  双击桥：active=#{bridge[:active].inspect} handled=#{bridge[:handled].inspect} 等待确认=#{bridge[:awaiting_confirmation].inspect} 签名=#{bridge[:signature]}")
      else
        add.call('  双击桥：未激活')
      end
      armed = (@workspace_double_click_candidates || {})[key]
      add.call("  已武装候选：#{armed.is_a?(Hash) ? armed[:signature] : '无'}")
      placement = lh_diag_try(nil) { linked_space_copy_record(model) }
      if placement.is_a?(Hash)
        add.call("  联动操作记录：mode=#{placement[:mode]} phase=#{placement[:phase]} item=#{placement[:item_id]} 实体=#{lh_diag_entity_label(placement[:entity])}")
        conclusions << '存在未完成的联动操作记录：顶部应显示绿色对勾，先点对勾完成后才能调整其它联动空间。'
      else
        add.call('  联动操作记录：无')
      end
      add.call("  待登记副本观察：#{lh_diag_try { pending_linked_space_watch_active?(model) }}")
      add.call

      selection = model.selection.to_a
      add.call("— 当前选择：#{selection.length} 个 —")
      conclusions << '双击要求只选中 1 个对象（当前选择数量不是 1）。' if selection.length != 1
      index = lh_diag_try({}) { managed_root_index(model) }
      spaces_by_id = index.is_a?(Hash) ? Hash(index[:spaces_by_id]) : {}
      selection.first(5).each_with_index do |entity, i|
        add.call("  [#{i + 1}] #{lh_diag_entity_label(entity)}")
        next unless entity && entity.valid?
        root = entity.respond_to?(:parent) ? entity.parent.equal?(model.entities) : true
        locked = entity.respond_to?(:locked?) ? entity.locked? : false
        add.call("      世界根层级=#{root}  锁定=#{locked}  隐藏=#{entity.respond_to?(:hidden?) ? entity.hidden? : false}  标记=#{entity.respond_to?(:layer) && entity.layer ? entity.layer.name : ''}")
        if entity.respond_to?(:definition) && entity.definition
          definition = entity.definition
          roots = definition.instances.to_a.select { |inst| inst.valid? && inst.parent.equal?(model.entities) } rescue []
          add.call("      定义 guid=#{definition.guid rescue '?'}  实例总数=#{definition.instances.length rescue '?'}  其中世界根实例=#{roots.length}")
        end
        dump = lh_diag_dict_dump(entity, ENTITY_DICT)
        add.call("      #{ENTITY_DICT}：#{dump.empty? ? '（无）' : ''}")
        dump.each { |row| add.call(row) }
        managed = entity.get_attribute(ENTITY_DICT, 'managed', false) == true rescue false
        kind = entity.get_attribute(ENTITY_DICT, 'kind', '').to_s rescue ''
        space_id = entity.get_attribute(ENTITY_DICT, 'space_id', '').to_s rescue ''
        pending = lh_diag_try(false) { pending_linked_space_clone?(entity) }
        if pending == true
          add.call('      → 这是“待登记联动副本”。双击/顶部绿色对勾可调整并命名。')
        elsif managed && kind == 'space_model' && !space_id.empty?
          indexed = spaces_by_id[space_id]
          same_id_roots = model.entities.to_a.count do |other|
            other.valid? && other.respond_to?(:get_attribute) &&
              other.get_attribute(ENTITY_DICT, 'managed', false) == true &&
              other.get_attribute(ENTITY_DICT, 'kind', '').to_s == 'space_model' &&
              other.get_attribute(ENTITY_DICT, 'space_id', '').to_s == space_id
          end
          add.call("      索引中该 space_id 对应实体=#{indexed ? lh_diag_entity_label(indexed) : '无'}  是否就是本实体=#{indexed.equal?(entity)}  同 space_id 根实例数=#{same_id_roots}")
          item = lh_diag_try(nil) { space_model_record(state, space_id) }
          if item.is_a?(Hash)
            linked = lh_diag_try(false) { linked_space_record?(item) }
            source = lh_diag_try(nil) { canonical_space_record(state, item) }
            add.call("      清单记录：#{item['number']}:#{item['name']}  联动=#{linked}  来源=#{source ? "#{source['number']}:#{source['name']}" : '缺失'}  已保存变换=#{Array(item['linked_transform']).length == 16}")
            add.call("      正在实例调整=#{lh_diag_try { linked_space_transform_adjustment_active?(item, entity, model) }}")
            conclusions << '联动来源缺失：需要先刷新协同清单。' if linked == true && source.nil?
          else
            add.call('      清单记录：找不到（state.space_models 中没有这个 space_id）')
            conclusions << "选中对象带 space_id=#{space_id}，但项目清单里没有对应记录，双击不会识别。"
          end
          if !root
            conclusions << '选中的空间实例不在世界根层级（可能被编组/嵌套），插件只识别世界根上的空间根组件。'
          elsif indexed && !indexed.equal?(entity)
            conclusions << '选中的实例与另一个根实例共用同一个 space_id（原生复制/粘贴产生的重复实例），插件索引只认第一个，所以双击完全没反应、也无法解锁。v0.13.6.190 起：双击它或点顶部橙色对勾即可登记为联动副本。'
          end
        elsif !managed && !kind.empty?
          add.call("      → 非受管实例（kind=#{kind}）")
        else
          add.call('      → 不是 LinkHub 空间根（没有受管空间属性）')
        end
      end
      add.call

      active_root = path.first
      liminal = active_root && active_root.valid? &&
                ((entity_native_locked?(active_root) rescue false) || (active_root.get_attribute(ENTITY_DICT, 'safe_paused', false) rescue false))
      if liminal
        add.call('— 双击候选：跳过计算（当前处于需自愈的编辑层级，计算会触发自愈修改；为保持只读未执行）—')
      else
        candidate = lh_diag_try(nil) { workspace_double_click_candidate(model) }
        if candidate.is_a?(Hash)
          add.call("— 双击候选：kind=#{candidate[:kind]} id=#{candidate[:id]} 名称=#{candidate[:label]}")
        else
          add.call('— 双击候选：无（插件不会接管这次双击，所以“完全没反应”）')
          duplicate_info = lh_diag_try(nil) { selected_duplicate_space_root_info(model) }
          add.call("    重复实例识别：#{duplicate_info.is_a?(Hash) ? "是，来源 #{duplicate_info[:source_label]}" : '否'}")
        end
      end
      add.call

      duplicates = lh_diag_duplicate_space_roots(model)
      add.call("— 全模型同 space_id 重复根实例：#{duplicates.length} 组 —")
      duplicates.first(20).each do |space_id, rows|
        item = lh_diag_try(nil) { space_model_record(state, space_id) }
        label = item.is_a?(Hash) ? "#{item['number']}:#{item['name']}" : space_id
        indexed = spaces_by_id[space_id]
        add.call("  #{label}：#{rows.length} 个根实例（索引只认 pid=#{indexed.respond_to?(:persistent_id) ? indexed.persistent_id : '?'}）")
        rows.each { |row| add.call("     - #{lh_diag_entity_label(row)} 锁定=#{row.locked? rescue '?'}") }
      end
      conclusions << "全模型有 #{duplicates.length} 组重复空间根实例（原生复制产生），这些副本都无法双击/解锁。" unless duplicates.empty?
      add.call

      add.call('— 日志中最近的双击/联动记录 —')
      lh_diag_log_tail_lines(LOG_PATH, pattern: /双击|联动|候选|实例调整/, limit: 60).each { |line| add.call("  #{line}") }
      add.call
      conclusions << '未发现明显阻断条件；请把本报告和“导出日志诊断包”结果一起发给开发者。' if conclusions.empty?
      add.call('— 结论 —')
      conclusions.uniq.each { |text| add.call("  • #{text}") }
      { text: lines.join("\n"), conclusions: conclusions.uniq }
    end

    def run_linkhub_selection_diagnostic!(model = Sketchup.active_model)
      raise '没有打开的模型。' unless model
      report = lh_diag_selection_report(model)
      dir = lh_diag_output_dir('选择诊断')
      file = File.join(dir, '选择诊断.txt')
      File.write(file, "\uFEFF#{report[:text]}", mode: 'w:UTF-8')
      log("只读诊断：当前选择 → #{file}")
      UI.messagebox("LinkHub 选择诊断完成（未修改模型）\n\n#{report[:conclusions].map { |text| "• #{text}" }.join("\n")}\n\n完整报告：\n#{file}")
      lh_diag_open_folder(dir)
      file
    rescue StandardError => e
      log_exception('只读诊断：当前选择失败', e)
      UI.messagebox("选择诊断失败（模型未被修改）：#{e.class}: #{e.message}")
      nil
    end

    def run_linkhub_furniture_diagnostic!(model = Sketchup.active_model)
      raise '没有打开的模型。' unless model
      raise '家具变形诊断模块未载入。' unless GavinTools::SULinkHubMultiSpace.const_defined?(:FurnitureReadOnlyDiagnostic, false)
      unless model.active_path.nil?
        return nil unless native_confirm_yes?("当前处于组件编辑层级，坐标可能不准。\n建议先退出到世界根再诊断。\n\n仍要继续吗？")
      end
      dir = lh_diag_output_dir('家具变形诊断')
      result = GavinTools::SULinkHubMultiSpace::FurnitureReadOnlyDiagnostic.run(out_dir: dir)
      log("只读诊断：家具变形 → #{result}")
      lh_diag_open_folder(dir) if result
      result
    rescue StandardError => e
      log_exception('只读诊断：家具变形失败', e)
      UI.messagebox("家具变形诊断失败（模型未被修改）：#{e.class}: #{e.message}")
      nil
    end

    def export_linkhub_log_bundle!(model = Sketchup.active_model)
      dir = lh_diag_output_dir('日志诊断包')
      copied = []
      candidates = Dir.glob(File.join(TEMP_LOG_DIR, '*')).select { |path| File.file?(path) }
      candidates.sort_by! { |path| -File.mtime(path).to_f }
      candidates.first(24).each do |path|
        size = File.size(path)
        name = File.basename(path)
        name = "（尾部）#{name}" if size > LH_DIAG_LOG_TAIL_BYTES
        File.open(path, 'rb') do |input|
          input.seek([size - LH_DIAG_LOG_TAIL_BYTES, 0].max)
          File.open(File.join(dir, name), 'wb') { |output| IO.copy_stream(input, output) }
        end
        copied << name
      rescue StandardError => e
        log("导出日志诊断包跳过 #{path}：#{e.message}")
      end
      begin
        report = lh_diag_selection_report(model)
        File.write(File.join(dir, '选择诊断.txt'), "\uFEFF#{report[:text]}", mode: 'w:UTF-8')
        copied << '选择诊断.txt'
      rescue StandardError
        nil
      end
      info = [
        "SU LinkHub v#{EXTENSION_VERSION}",
        "SketchUp #{lh_diag_try { Sketchup.version }}",
        "模型：#{model ? model.path : ''}",
        "导出时间：#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}",
        "日志目录：#{TEMP_LOG_DIR}",
        '',
        *copied
      ].join("\n")
      File.write(File.join(dir, '说明.txt'), "\uFEFF#{info}", mode: 'w:UTF-8')
      UI.messagebox("日志诊断包已导出（未修改模型）：\n#{dir}\n\n共 #{copied.length} 个文件。请把整个文件夹发给开发者。")
      lh_diag_open_folder(dir)
      dir
    rescue StandardError => e
      log_exception('导出日志诊断包失败', e)
      UI.messagebox("导出日志诊断包失败：#{e.class}: #{e.message}")
      nil
    end

    def add_linkhub_diagnostic_menu_items!(menu)
      return false unless menu
      menu.add_item('诊断当前选择（双击 / 联动 / 锁）') { run_linkhub_selection_diagnostic!(Sketchup.active_model) }
      menu.add_item('家具变形只读诊断（全模型）') { run_linkhub_furniture_diagnostic!(Sketchup.active_model) }
      menu.add_item('导出日志诊断包') { export_linkhub_log_bundle!(Sketchup.active_model) }
      menu.add_item('打开诊断输出文件夹') { lh_diag_open_folder(TEMP_DIAGNOSTIC_DIR) }
      true
    rescue StandardError => e
      log_exception('建立诊断菜单失败', e)
      false
    end
    end
  end
end
