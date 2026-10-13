# frozen_string_literal: true

# v0.13.6.190：联动空间调整入口加固。
# 1. 原生复制/粘贴出来、与另一根实例共用 space_id 的“重复空间根”过去不在受管索引里
#    （索引只认第一个），双击完全没反应、也无法解锁。现在可双击或点顶部橙色对勾，
#    把它登记为“待命名联动副本”，随后即可移动/旋转/缩放/镜像并命名。
# 2. 已登记联动空间：顶部主按钮改为“调整位置”（不再只能靠双击），右键菜单同样提供。
# 3. 完成调整时若检测到不等比缩放，提示家具会随之被压扁/拉长。

module GavinTools
  module SULinkHubMultiSpace
    module Runtime
    # 返回当前唯一选中的“重复空间根”信息；不是则返回 nil。只读。
    def selected_duplicate_space_root_info(model = Sketchup.active_model, state: nil)
      return nil unless model && model.active_path.nil?
      selected = model.selection.to_a
      return nil unless selected.length == 1
      entity = selected.first
      duplicate_space_root_info(entity, model, state: state)
    rescue StandardError
      nil
    end

    def duplicate_space_root_info(entity, model = Sketchup.active_model, state: nil)
      return nil unless entity && entity.valid? && entity.respond_to?(:get_attribute)
      return nil unless entity.is_a?(Sketchup::ComponentInstance) || entity.is_a?(Sketchup::Group)
      return nil unless linked_space_root_instance?(entity, model)
      return nil unless entity.get_attribute(ENTITY_DICT, 'managed', false) == true
      return nil unless entity.get_attribute(ENTITY_DICT, 'kind', '').to_s == 'space_model'
      return nil if pending_linked_space_clone?(entity)
      space_id = entity.get_attribute(ENTITY_DICT, 'space_id', '').to_s
      return nil if space_id.empty?
      indexed = space_model_entity(space_id, model)
      return nil unless indexed && indexed.valid? && !indexed.equal?(entity)
      state ||= cached_project_state_readonly(model) || load_state(model)
      item = space_model_record(state, space_id)
      return nil unless item
      source = canonical_space_record(state, item)
      return nil unless source
      {
        entity: entity, indexed: indexed, item: item, source: source,
        item_label: space_ui_label(item), source_label: space_ui_label(source)
      }
    rescue StandardError
      nil
    end

    def adopt_duplicate_space_root_as_linked_pending!(model = Sketchup.active_model, entity = nil)
      raise '请先退出组件内部，再登记空间副本。' unless model && model.active_path.nil?
      raise '已有联动空间操作未完成，请先点顶部对勾。' if linked_space_copy_active?(model)
      raise '发布或更新正在执行，请稍候再登记。' if publish_critical_section? || publish_post_quiet? || @updating || @single_space_update_job || @space_batch_update_job
      entity ||= model.selection.to_a.first
      info = duplicate_space_root_info(entity, model, state: load_state(model))
      raise '当前选择不是“原生复制产生的重复空间实例”。' unless info
      prompt = <<~TEXT
        检测到这个实例是“#{info[:item_label]}”的原生复制（与另一个实例共用同一个空间身份），
        LinkHub 只识别其中一个，所以它无法双击、也无法解锁。

        是否把它登记为“#{info[:source_label]}”的联动副本？
        · 只改这个实例的 LinkHub 身份属性，不改几何、不动原空间和共享文件
        · 登记后可直接移动/旋转/缩放/镜像，再点顶部绿色对勾命名
        · 如果它是误复制的，也可以选“否”后直接删除它
      TEXT
      return false unless native_confirm_yes?(prompt)
      operation_open = false
      model.start_operation('登记原生复制的空间副本', true)
      operation_open = true
      converted = convert_linked_native_clone_to_pending!(entity, info[:source], info[:item]['id'].to_s, model)
      raise '无法把该实例登记为待命名联动副本。' unless converted
      model.commit_operation
      operation_open = false
      invalidate_managed_root_index(model, reason: 'linked_space_duplicate_adopt')
      log("已把重复空间根登记为待命名联动副本：来源 #{info[:source_label]} / pid=#{entity.persistent_id rescue '?'}")
      begin_pending_linked_space_transform!(entity, model)
      schedule_coalesced_refresh_dialog(0.05) rescue nil
      show_workspace_floating_notice('已登记为联动副本 · 可移动，完成后点绿色对勾命名', 'success', duration: 4.0, model: model)
      true
    rescue StandardError
      model.abort_operation rescue nil if defined?(operation_open) && operation_open
      raise
    end

    def linked_space_transformation_scales(transformation)
      values = transformation.to_a.map(&:to_f)
      [
        Math.sqrt(values[0]**2 + values[1]**2 + values[2]**2),
        Math.sqrt(values[4]**2 + values[5]**2 + values[6]**2),
        Math.sqrt(values[8]**2 + values[9]**2 + values[10]**2)
      ]
    rescue StandardError
      [1.0, 1.0, 1.0]
    end

    def linked_space_transformation_non_uniform?(transformation)
      scales = linked_space_transformation_scales(transformation)
      min = scales.min.to_f
      return false unless min.positive?
      (scales.max.to_f / min) > 1.002
    rescue StandardError
      false
    end

    def warn_linked_space_non_uniform_scale!(entity, model = Sketchup.active_model)
      return false unless entity && entity.valid?
      return false unless linked_space_transformation_non_uniform?(entity.transformation)
      scales = linked_space_transformation_scales(entity.transformation).map { |value| value.round(3) }
      show_workspace_floating_notice("注意：联动空间为不等比缩放（#{scales.join(' / ')}），内部家具会被同比例压扁/拉长", 'warning', duration: 6.0, model: model)
      log("联动空间保存了不等比缩放：#{scales.join('/')}；家具会随之变形")
      true
    rescue StandardError
      false
    end

    # 双击候选为空时的轻量线索：只在“选中的是受管空间根却没被识别”时记一行日志，按实体节流。
    def lh_note_double_click_miss(entity, state, model = Sketchup.active_model)
      return false unless entity && entity.valid? && entity.respond_to?(:get_attribute)
      return false unless entity.get_attribute(ENTITY_DICT, 'kind', '').to_s == 'space_model'
      @lh_double_click_miss_logged ||= {}
      key = entity.object_id
      now = monotonic_seconds
      return false if (now - @lh_double_click_miss_logged[key].to_f) < 20.0
      @lh_double_click_miss_logged[key] = now
      space_id = entity.get_attribute(ENTITY_DICT, 'space_id', '').to_s
      indexed = space_id.empty? ? nil : space_model_entity(space_id, model)
      item = space_id.empty? ? nil : space_model_record(state, space_id)
      reasons = []
      reasons << '不在世界根' unless linked_space_root_instance?(entity, model)
      reasons << 'managed=false' unless entity.get_attribute(ENTITY_DICT, 'managed', false) == true
      reasons << '清单无记录' unless item
      reasons << '索引指向另一个同 id 实例（重复根）' if indexed && !indexed.equal?(entity)
      reasons << '索引中无此 id' unless indexed
      log("双击候选未识别：space_id=#{space_id} pid=#{entity.persistent_id rescue '?'} 原因=#{reasons.empty? ? '未知' : reasons.join('、')}")
      true
    rescue StandardError
      false
    end

    def lh_note_double_click_candidate_error(error)
      @lh_double_click_error_logged_at ||= 0.0
      now = monotonic_seconds
      return false if (now - @lh_double_click_error_logged_at.to_f) < 10.0
      @lh_double_click_error_logged_at = now
      log("双击候选计算异常：#{error.class}: #{error.message} @ #{Array(error.backtrace).first}")
      true
    rescue StandardError
      false
    end

    def populate_linked_space_context_menu(menu, model = Sketchup.active_model)
      return false unless menu && model && model.active_path.nil?
      selected = model.selection.to_a
      return false unless selected.length == 1
      entity = selected.first
      placement = linked_space_copy_record(model)
      if placement.is_a?(Hash) && placement[:mode].to_s == 'transform' && placement[:entity].equal?(entity)
        submenu = menu.add_submenu('LinkHub 联动空间')
        submenu.add_item('完成调整并锁定') do
          safe_callback('完成联动空间调整', guard: false) { finish_linked_space_copy!(model) }
        end
        return true
      end
      if pending_linked_space_clone?(entity)
        submenu = menu.add_submenu('LinkHub 联动空间')
        submenu.add_item('命名登记这个联动副本') do
          safe_callback('登记联动副本', guard: false) { finish_pending_linked_space_clone!(model) }
        end
        return true
      end
      duplicate = duplicate_space_root_info(entity, model)
      if duplicate
        submenu = menu.add_submenu('LinkHub 联动空间')
        submenu.add_item("登记为联动副本（原生复制自 #{duplicate[:source_label]}）") do
          safe_callback('登记原生复制的空间副本', guard: false) { adopt_duplicate_space_root_as_linked_pending!(model, entity) }
        end
        return true
      end
      state = cached_project_state_readonly(model) || load_state(model)
      item = selected_managed_space_record(state, model)
      return false unless item && linked_space_record?(item)
      submenu = menu.add_submenu('LinkHub 联动空间')
      submenu.add_item('调整位置（移动 / 旋转 / 缩放 / 镜像）') do
        safe_callback('调整联动空间位置', guard: false) { begin_linked_space_transform!(item['id'].to_s, entity, model) }
      end
      true
    rescue StandardError => e
      log_exception('建立联动空间右键菜单失败', e)
      false
    end
    end
  end
end
