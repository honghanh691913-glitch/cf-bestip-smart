# frozen_string_literal: true

# v0.13.7.7：组件外包盒（bounds）一致性。随 runtime.rb 一起 Kernel.load。
#
# 根因：SketchUp 的 ComponentDefinition#bounds 是缓存值。插件通过 Ruby API 改动组件内容
# （代理/真模型替换、拆壳压平、改轴、重载、六面代理建面）后，SketchUp 不会自动重算，
# 直到用户双击进入该组件。旧版只在一处调用 invalidate_bounds，导致：
#   1. 选择框比模型大，进入组件后才恢复；没进入的同定义实例仍然偏大；
#   2. 代理/真模型切换时按“过期的外包尺寸”计算补偿缩放，家具被放大或压扁，而且写进实例矩阵后
#      不会自己恢复——这就是“发布后第二天床变大”的主要来源。
#
# 修复（全部静默，无需确认）：
# - soft_invalidate_definition_bounds!：让定义及其所有上层定义（空间、包装）重新计算外包盒；
# - 所有插件改动组件内容的地方、用户每次提交编辑事务时都调用；
# - 打开/切换模型后分批修复全部受管软装定义及其上层空间；
# - 代理/真模型替换前先刷新两边外包盒；同一家具尺寸一致时直接保留原矩阵，不再重新推算缩放。

module GavinTools
  module SULinkHubMultiSpace
    module Runtime
      # 收集定义及其全部上层定义（去重）。
      def soft_bounds_definition_closure(definitions, limit: 20_000)
        queue = Array(definitions).compact
        seen = {}
        result = []
        until queue.empty? || result.length >= limit
          current = queue.shift
          next unless current.is_a?(Sketchup::ComponentDefinition) && current.valid?
          next if seen[current.object_id]
          seen[current.object_id] = true
          result << current
          current.instances.each do |instance|
            parent = instance.parent rescue nil
            queue << parent if parent.is_a?(Sketchup::ComponentDefinition) && !seen[parent.object_id]
          end
        end
        result
      rescue StandardError
        Array(definitions).compact
      end

      # 只做缓存失效：不写属性、不开 operation、不进入撤销栈。
      def soft_invalidate_definitions_bounds!(definitions, walk_parents: true)
        list = walk_parents ? soft_bounds_definition_closure(definitions) : Array(definitions).compact.uniq
        return false if list.empty?
        list.each do |definition|
          next unless definition.valid?
          definition.invalidate_bounds if definition.respond_to?(:invalidate_bounds)
          (@soft_definition_bounds_cache || {}).delete(definition.object_id)
        end
        if list.length <= 8
          list.each do |definition|
            invalidate_soft_representation_pair_cache!(nil, definition: definition) if definition.valid? && respond_to?(:invalidate_soft_representation_pair_cache!)
          end
        elsif respond_to?(:invalidate_soft_representation_pair_cache!)
          # 大批量时整体清空一次，避免对配对缓存逐个扫描（O(n²)）。
          invalidate_soft_representation_pair_cache!
        end
        true
      rescue StandardError => e
        log_exception('刷新组件外包盒失败', e)
        false
      end

      def soft_invalidate_definition_bounds!(definition, walk_parents: true)
        return false unless definition && definition.valid?
        soft_invalidate_definitions_bounds!([definition], walk_parents: walk_parents)
      end

      def soft_invalidate_entity_bounds!(entity, walk_parents: true)
        return false unless entity && entity.valid?
        definition = entity.respond_to?(:definition) ? entity.definition : nil
        definition ||= entity if entity.is_a?(Sketchup::ComponentDefinition)
        soft_invalidate_definition_bounds!(definition, walk_parents: walk_parents)
      rescue StandardError
        false
      end

      # 用户在组件内部编辑（含原生“全部解锁”后的直接编辑）每次提交事务后，
      # 把当前编辑路径上的定义标记为需重算。提交时就记下定义（退出组件后 active_path 已变），
      # 在 ModelObserver 回调之外合并执行。
      def soft_invalidate_active_path_bounds!(model = Sketchup.active_model)
        return false unless model
        path = Array(model.active_path).select { |node| node && node.valid? }
        return false if path.empty?
        node = path.last
        definition = node.respond_to?(:definition) ? node.definition : nil
        return false unless definition && definition.valid?
        @soft_pending_bounds_definitions ||= {}
        pending = (@soft_pending_bounds_definitions[model.object_id] ||= {})
        pending[definition.object_id] = definition
        runtime_start_timer(0.05, false, label: 'soft:active_path_bounds', key: "soft:active_path_bounds:#{model.object_id}", model: model) do
          batch = (@soft_pending_bounds_definitions || {}).delete(model.object_id) || {}
          soft_invalidate_definitions_bounds!(batch.values.select(&:valid?), walk_parents: true) unless batch.empty?
        end
        true
      rescue StandardError
        false
      end

      # 打开/切换模型后一次性修复：所有带 model_id 的软装定义（含代理）及其上层定义。
      # 只做缓存失效，单次遍历，赶在启动后代理队列恢复（0.9s）之前完成。
      def schedule_soft_bounds_repair!(model = Sketchup.active_model, delay: 0.3)
        return false unless model
        @soft_bounds_repair_done ||= {}
        key = model.object_id
        return true if @soft_bounds_repair_done[key]
        @soft_bounds_repair_done[key] = true
        runtime_start_timer(delay.to_f, false, label: 'soft:bounds_repair', key: "soft:bounds_repair:#{key}", model: model) do
          started = monotonic_time
          definitions = model.definitions.to_a.select do |definition|
            definition.valid? && !definition.image? &&
              !definition.get_attribute(SOFT_MODEL_DICT, 'model_id', '').to_s.empty?
          rescue StandardError
            false
          end
          next if definitions.empty?
          soft_invalidate_definitions_bounds!(definitions, walk_parents: true)
          log("外包盒一致性修复：#{definitions.length} 个软装定义 / #{elapsed_ms(started)}ms")
        end
        true
      rescue StandardError => e
        log_exception('安排外包盒一致性修复失败', e)
        false
      end

      # 两个定义是否为同一件家具（代理 ↔ 真模型、或同一来源的不同载入）。
      def soft_same_furniture_definitions?(first, second)
        return false unless first && second && first.valid? && second.valid?
        a = first.get_attribute(SOFT_MODEL_DICT, 'model_id', '').to_s
        b = second.get_attribute(SOFT_MODEL_DICT, 'model_id', '').to_s
        !a.empty? && a == b
      rescue StandardError
        false
      end

      # 外包尺寸相对误差都在 tolerance 以内（默认 0.3%）。
      def soft_definition_extents_close?(first, second, tolerance = 0.003)
        a = soft_definition_axis_extents(first)
        b = soft_definition_axis_extents(second)
        a.each_index.all? do |index|
          big = [a[index].to_f.abs, b[index].to_f.abs].max
          big < 1.0e-6 || (a[index].to_f - b[index].to_f).abs / big <= tolerance
        end
      rescue StandardError
        false
      end

      # 坐标轴变换是否为刚体（单位长度、两两正交）。带缩放/斜切的“轴”不能用于自动补偿。
      def soft_rigid_frame?(transform, tolerance = 1.0e-3)
        values = transform.respond_to?(:to_a) ? Array(transform.to_a).map(&:to_f) : Array(transform).map(&:to_f)
        return false unless values.length == 16
        axes = [values[0, 3], values[4, 3], values[8, 3]]
        lengths_ok = axes.all? { |axis| (Math.sqrt(axis.sum { |v| v * v }) - 1.0).abs <= tolerance }
        dots_ok = [[0, 1], [0, 2], [1, 2]].all? do |i, j|
          axes[i].each_index.sum { |k| axes[i][k] * axes[j][k] }.abs <= tolerance
        end
        lengths_ok && dots_ok
      rescue StandardError
        false
      end
    end
  end
end
