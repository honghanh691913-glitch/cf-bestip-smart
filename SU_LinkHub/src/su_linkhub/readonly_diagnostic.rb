# frozen_string_literal: true
# v0.13.6.190：家具变形只读诊断（由独立脚本 LinkHub只读诊断.rb 内置而来）。
# 只读取当前模型：不调用 start_operation / set_attribute / transformation= / definition=，
# 不读写共享目录。唯一写入是把 JSON/CSV 结果写到 %TEMP%\SU_LinkHub\diagnostics 下。
require 'json'
require 'time'
require 'fileutils'

module GavinTools
  module SULinkHubMultiSpace
    remove_const(:FurnitureReadOnlyDiagnostic) if const_defined?(:FurnitureReadOnlyDiagnostic, false)

    module FurnitureReadOnlyDiagnostic
      extend self

      ENTITY_DICT = 'SU_LinkHub_Entity'
      SOFT_DICT   = 'SU_LinkHub_SoftModel'
      SHARED_DICT = 'SU_LinkHub_SharedComponent'
      MAX_DEPTH   = 14
      MAX_SECONDS = 180.0
      EDGE_LIMIT  = 25_000      # 每个定义最多分析多少条边
      NEST_LIMIT  = 4           # 几何分析时向下钻几层嵌套

      def run(out_dir: nil, quiet: false)
        model = Sketchup.active_model
        raise '没有打开的模型' unless model
        @started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @truncated = false
        @geometry_cache = {}
        @rows = []
        @spaces = []
        @space_seen = {}

        warn_context = model.active_path ? '注意：当前处于组件编辑层级，坐标按 SketchUp 当前编辑上下文读取，结果可能不准。' : ''

        walk(model.entities, Geom::Transformation.new, [], nil, 0)

        summary = build_summary
        out_dir ||= File.join(File.dirname(__FILE__), '诊断输出')
        FileUtils.mkdir_p(out_dir)
        stamp = Time.now.strftime('%Y%m%d_%H%M%S')
        json_path = File.join(out_dir, "LinkHub诊断_#{stamp}.json")
        csv_path  = File.join(out_dir, "LinkHub家具_#{stamp}.csv")

        payload = {
          'tool' => 'LinkHub 内置家具只读诊断 (v0.13.6.190)',
          'generated_at' => Time.now.iso8601,
          'sketchup' => Sketchup.version.to_s,
          'model_path' => model.path.to_s,
          'model_title' => model.title.to_s,
          'active_path_depth' => Array(model.active_path).length,
          'warning' => warn_context,
          'truncated_by_time_limit' => @truncated,
          'elapsed_seconds' => elapsed.round(1),
          'summary' => summary,
          'spaces' => @spaces,
          'furniture' => @rows
        }
        File.write(json_path, JSON.pretty_generate(payload), mode: 'w:UTF-8')
        write_csv(csv_path)

        msg = "LinkHub 只读诊断完成（未修改模型）\n\n" \
              "空间实例：#{@spaces.length}\n家具实例：#{@rows.length}\n" \
              "疑似变形/斜切：#{summary['deform_risk_count']}\n" \
              "组件轴与家具有夹角：#{summary['yaw_misaligned_count']}\n" \
              "同款多个不同定义：#{summary['models_with_multiple_definitions']}\n\n" \
              "结果文件：\n#{json_path}\n#{csv_path}"
        msg += "\n\n（超过 #{MAX_SECONDS.to_i} 秒已提前停止，结果不完整）" if @truncated
        puts msg
        UI.messagebox(msg) unless quiet
        json_path
      rescue StandardError => e
        text = "LinkHub 诊断失败（模型未被修改）：#{e.class}: #{e.message}\n#{Array(e.backtrace).first(6).join("\n")}"
        puts text
        UI.messagebox(text)
        nil
      end

      # ---------------------------------------------------------------- 遍历
      def elapsed
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started
      end

      def walk(entities, parent_tr, path, space_ctx, depth)
        return if depth > MAX_DEPTH
        entities.each do |e|
          if elapsed > MAX_SECONDS
            @truncated = true
            return
          end
          next unless e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)
          definition = definition_of(e)
          next unless definition
          combined = parent_tr * e.transformation

          ctx = space_ctx
          space_id = attr(e, ENTITY_DICT, 'space_id')
          if !space_id.to_s.empty?
            ctx = record_space(e, combined, path)
          end

          if furniture?(e, definition)
            record_furniture(e, definition, combined, path, ctx)
            next # 家具内部不再当作场景继续遍历
          end
          walk(definition.entities, combined, path + [e], ctx, depth + 1)
        end
      end

      def pid_of(e)
        e.persistent_id
      rescue StandardError
        e.object_id
      end

      def definition_of(e)
        e.respond_to?(:definition) ? e.definition : nil
      rescue StandardError
        nil
      end

      def attr(obj, dict, key, default = nil)
        obj.get_attribute(dict, key, default)
      rescue StandardError
        default
      end

      def furniture?(e, definition)
        !attr(e, SOFT_DICT, 'model_id').to_s.empty? ||
          !attr(definition, SOFT_DICT, 'model_id').to_s.empty? ||
          !attr(e, SOFT_DICT, 'representation').to_s.empty?
      end

      def dict_dump(obj, dict)
        d = obj.attribute_dictionary(dict, false)
        return {} unless d
        out = {}
        d.each_pair do |k, v|
          val = v.is_a?(String) && v.length > 240 ? "#{v[0, 240]}…(#{v.length}字)" : v
          val = val.to_a if val.respond_to?(:to_a) && !val.is_a?(String) && !val.is_a?(Array) && !val.is_a?(Hash)
          out[k.to_s] = val
        end
        out
      rescue StandardError
        {}
      end

      # ---------------------------------------------------------------- 空间
      def record_space(e, combined, path)
        key = (path + [e]).map { |p| pid_of(p) }.join('/')
        return @space_seen[key] if @space_seen[key]
        m = matrix_info(combined)
        local = matrix_info(e.transformation)
        ctx = {
          'space_id' => attr(e, ENTITY_DICT, 'space_id').to_s,
          'space_name' => (e.name.to_s rescue ''),
          'definition' => (e.definition.name.to_s rescue ''),
          'linked' => !!attr(e, ENTITY_DICT, 'linked_space', false) || !attr(e, ENTITY_DICT, 'linked_source_space_id').to_s.empty?,
          'linked_source_space_id' => attr(e, ENTITY_DICT, 'linked_source_space_id').to_s,
          'representation' => attr(e, ENTITY_DICT, 'space_representation').to_s,
          'source_revision' => attr(e, ENTITY_DICT, 'source_revision').to_s,
          'locked' => (e.locked? rescue nil),
          'scale_xyz' => local[:scales].map { |v| v.round(6) },
          'non_uniform_scale' => local[:non_uniform],
          'mirrored' => local[:mirrored],
          'shear_deg' => local[:shear_deg].round(4),
          'world_scale_xyz' => m[:scales].map { |v| v.round(6) },
          'definition_object_id' => (e.definition.object_id rescue 0)
        }
        @space_seen[key] = ctx
        @spaces << ctx
        ctx
      end

      # ---------------------------------------------------------------- 家具
      def record_furniture(e, definition, combined, path, space)
        m = matrix_info(combined)
        local = matrix_info(e.transformation)
        geo = geometry_info(definition)
        bb = definition.bounds
        local_dims_mm = [bb.width, bb.height, bb.depth].map { |v| (v.to_f * 25.4) }
        world_dims_mm = local_dims_mm.each_with_index.map { |v, i| v * m[:scales][i] }

        yaw = geo[:yaw_offset_deg]
        xy_ratio = m[:scales][1].abs > 1e-12 ? (m[:scales][0] / m[:scales][1]).abs : 1.0
        # 组件轴与几何有夹角 + XY 不等比缩放 => 几何被剪切（平行四边形变形）
        effective_shear = yaw && geo[:yaw_confidence].to_f >= 0.25 && yaw.abs > 0.5 && (xy_ratio - 1.0).abs > 0.002
        z_tilt = m[:z_tilt_deg]

        risks = []
        risks << '矩阵本身斜切' if m[:shear_deg] > 0.05
        risks << '组件轴与家具有夹角+不等比缩放=实际变形' if effective_shear
        risks << "不等比缩放(#{m[:scales].map { |v| v.round(3) }.join('/')})" if m[:non_uniform]
        risks << '镜像' if m[:mirrored]
        risks << "蓝轴不竖直(#{z_tilt.round(1)}°)" if z_tilt > 0.5
        risks << "组件轴与家具夹角#{yaw.round(2)}°" if yaw && yaw.abs > 0.5 && geo[:yaw_confidence].to_f >= 0.25
        risks << "嵌套包装#{geo[:wrapper_depth]}层" if geo[:wrapper_depth].to_i >= 2
        risks << '包装层内含斜切/不等比' if geo[:inner_shear_or_nonuniform]

        @rows << {
          'space_id' => space ? space['space_id'] : '',
          'space_name' => space ? space['space_name'] : '(不在空间内)',
          'space_linked' => space ? space['linked'] : false,
          'space_scale_xyz' => space ? space['scale_xyz'] : nil,
          'path' => path.map { |p| (p.name.to_s.empty? ? (p.definition.name rescue '?') : p.name.to_s) rescue '?' }.join(' > '),
          'instance_name' => (e.name.to_s rescue ''),
          'instance_pid' => pid_of(e),
          'is_group' => e.is_a?(Sketchup::Group),
          'definition' => definition.name.to_s,
          'definition_object_id' => definition.object_id,
          'definition_guid' => (definition.guid.to_s rescue ''),
          'definition_instance_count' => (definition.count_instances rescue nil),
          'model_id' => (attr(e, SOFT_DICT, 'model_id').to_s.empty? ? attr(definition, SOFT_DICT, 'model_id').to_s : attr(e, SOFT_DICT, 'model_id').to_s),
          'model_name' => (attr(e, SOFT_DICT, 'model_name').to_s.empty? ? attr(definition, SOFT_DICT, 'model_name').to_s : attr(e, SOFT_DICT, 'model_name').to_s),
          'representation' => attr(e, SOFT_DICT, 'representation').to_s,
          'local_dims_mm' => local_dims_mm.map { |v| v.round(1) },
          'world_dims_mm' => world_dims_mm.map { |v| v.round(1) },
          'instance_scale_xyz' => local[:scales].map { |v| v.round(6) },
          'world_scale_xyz' => m[:scales].map { |v| v.round(6) },
          'matrix_shear_deg' => m[:shear_deg].round(4),
          'mirrored' => m[:mirrored],
          'z_tilt_deg' => z_tilt.round(3),
          'yaw_offset_deg' => yaw ? yaw.round(3) : nil,
          'yaw_confidence' => geo[:yaw_confidence],
          'wrapper_depth' => geo[:wrapper_depth],
          'inner_shear_or_nonuniform' => geo[:inner_shear_or_nonuniform],
          'edges_sampled' => geo[:edges],
          'risks' => risks,
          'instance_attrs' => dict_dump(e, SOFT_DICT),
          'definition_attrs' => dict_dump(definition, SOFT_DICT),
          'world_matrix' => combined.to_a.map { |v| v.round(6) }
        }
      end

      # ---------------------------------------------------------------- 数学
      def basis(tr)
        a = tr.to_a
        [Geom::Vector3d.new(a[0], a[1], a[2]), Geom::Vector3d.new(a[4], a[5], a[6]), Geom::Vector3d.new(a[8], a[9], a[10])]
      end

      def matrix_info(tr)
        b = basis(tr)
        scales = b.map { |v| v.length.to_f }
        angle = lambda do |u, v|
          lu = u.length.to_f
          lv = v.length.to_f
          return 90.0 if lu < 1e-12 || lv < 1e-12
          c = (u.dot(v) / (lu * lv)).clamp(-1.0, 1.0)
          Math.acos(c) * 180.0 / Math::PI
        end
        shear = [angle.call(b[0], b[1]), angle.call(b[1], b[2]), angle.call(b[0], b[2])].map { |deg| (deg - 90.0).abs }.max
        det = b[0].cross(b[1]).dot(b[2]).to_f
        z = b[2]
        z_tilt = z.length.to_f < 1e-12 ? 0.0 : Math.acos((z.z.to_f.abs / z.length.to_f).clamp(-1.0, 1.0)) * 180.0 / Math::PI
        min = scales.min
        {
          scales: scales,
          non_uniform: min > 1e-12 && (scales.max / min - 1.0) > 0.002,
          mirrored: det < 0,
          shear_deg: shear,
          z_tilt_deg: z_tilt
        }
      end

      # 统计定义内部（含少量嵌套）近似水平边的方向，求“家具主方向”相对组件 X 轴的夹角（-45°~45°）。
      def geometry_info(definition)
        cached = @geometry_cache[definition.object_id]
        return cached if cached
        hist = Array.new(90, 0.0)
        @hc = Array.new(90, 0.0)
        @hs = Array.new(90, 0.0)
        count = [0]
        wrapper_depth = 0
        inner_bad = false

        # 记录 LinkHub 风格单 payload 包装层的深度与内部矩阵问题
        cur = definition
        6.times do
          ents = cur.entities.to_a.select { |x| x.is_a?(Sketchup::ComponentInstance) || x.is_a?(Sketchup::Group) }
          others = cur.entities.to_a.reject { |x| x.is_a?(Sketchup::ComponentInstance) || x.is_a?(Sketchup::Group) || x.is_a?(Sketchup::ConstructionPoint) || x.is_a?(Sketchup::ConstructionLine) }
          break unless ents.length == 1 && others.empty?
          wrapper_depth += 1
          mi = matrix_info(ents.first.transformation)
          inner_bad ||= mi[:shear_deg] > 0.05 || mi[:non_uniform]
          cur = definition_of(ents.first)
          break unless cur
        end

        collect_edges(definition.entities, Geom::Transformation.new, hist, count, 0)
        total = hist.sum
        yaw = nil
        conf = 0.0
        if total > 0
          peak = (0...90).max_by { |i| hist[i - 1] + hist[i] + hist[(i + 1) % 90] }
          near = [peak - 1, peak, (peak + 1) % 90]
          conf = (near.map { |i| hist[i] }.sum / total).round(3)
          # 以峰值为中心做加权平均（处理 0/89 环绕）
          sx = 0.0
          sy = 0.0
          near.each do |i|
            sx += @hc[i] # 各边实际角度的 4θ 加权向量（90° 周期闭合）
            sy += @hs[i]
          end
          deg = Math.atan2(sy, sx) * 180.0 / Math::PI / 4.0
          deg += 90.0 while deg < 0
          deg -= 90.0 while deg >= 90.0
          deg -= 90.0 if deg > 45.0
          yaw = deg
        end
        @geometry_cache[definition.object_id] = {
          yaw_offset_deg: yaw, yaw_confidence: conf, wrapper_depth: wrapper_depth,
          inner_shear_or_nonuniform: inner_bad, edges: count[0]
        }
      end

      def collect_edges(entities, tr, hist, count, depth)
        entities.each do |x|
          return if count[0] >= EDGE_LIMIT
          if x.is_a?(Sketchup::Edge)
            next if (x.soft? rescue false) || (x.hidden? rescue false)
            p1 = x.start.position.transform(tr)
            p2 = x.end.position.transform(tr)
            v = p2 - p1
            len = v.length.to_f
            next if len < 1e-6
            next if v.z.to_f.abs > 0.05 * len # 只取近似水平的边
            ang = Math.atan2(v.y.to_f, v.x.to_f) * 180.0 / Math::PI
            ang = ang % 90.0
            bin = ang.floor % 90
            hist[bin] += len
            rad4 = ang * 4.0 * Math::PI / 180.0
            @hc[bin] += Math.cos(rad4) * len
            @hs[bin] += Math.sin(rad4) * len
            count[0] += 1
          elsif (x.is_a?(Sketchup::ComponentInstance) || x.is_a?(Sketchup::Group)) && depth < NEST_LIMIT
            d = definition_of(x)
            collect_edges(d.entities, tr * x.transformation, hist, count, depth + 1) if d
          end
        end
      end

      # ---------------------------------------------------------------- 汇总
      def build_summary
        by_model = Hash.new { |h, k| h[k] = { defs: {}, reps: Hash.new(0), spaces: {}, name: '' } }
        @rows.each do |r|
          key = r['model_id'].to_s.empty? ? "(无ID)#{r['definition']}" : r['model_id']
          g = by_model[key]
          g[:name] = r['model_name'] unless r['model_name'].to_s.empty?
          g[:defs][r['definition_object_id']] = r['definition']
          g[:reps][r['representation']] += 1
          g[:spaces][r['space_name']] = true
        end
        multi = by_model.select { |_k, g| g[:defs].length > 1 }
        {
          'space_instances' => @spaces.length,
          'linked_space_instances' => @spaces.count { |s| s['linked'] },
          'linked_spaces_non_uniform_or_mirrored' => @spaces.select { |s| s['non_uniform_scale'] || s['mirrored'] || s['shear_deg'] > 0.05 }.map { |s| s['space_name'] },
          'furniture_instances' => @rows.length,
          'deform_risk_count' => @rows.count { |r| r['risks'].any? { |t| t.include?('实际变形') || t.include?('斜切') } },
          'yaw_misaligned_count' => @rows.count { |r| r['risks'].any? { |t| t.start_with?('组件轴与家具夹角') } },
          'non_uniform_count' => @rows.count { |r| r['risks'].any? { |t| t.start_with?('不等比') } },
          'models' => by_model.length,
          'models_with_multiple_definitions' => multi.length,
          'multi_definition_detail' => multi.first(200).map do |k, g|
            { 'model_id' => k, 'name' => g[:name], 'definitions' => g[:defs].values.uniq.first(20),
              'definition_count' => g[:defs].length, 'representations' => g[:reps], 'spaces' => g[:spaces].keys.first(30) }
          end
        }
      end

      def csv_cell(v)
        s = v.is_a?(Array) ? v.join('/') : v.to_s
        s.include?(',') || s.include?('"') || s.include?("\n") ? "\"#{s.gsub('"', '""')}\"" : s
      end

      def write_csv(path)
        cols = %w[space_name space_linked model_name model_id representation definition definition_instance_count
                  world_dims_mm world_scale_xyz matrix_shear_deg yaw_offset_deg yaw_confidence z_tilt_deg mirrored
                  wrapper_depth inner_shear_or_nonuniform risks path]
        File.open(path, 'w:UTF-8') do |f|
          f.write("\uFEFF")
          f.puts(cols.join(','))
          @rows.each { |r| f.puts(cols.map { |c| csv_cell(r[c]) }.join(',')) }
        end
      end
    end
  end
end
