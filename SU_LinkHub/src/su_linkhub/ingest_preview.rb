# frozen_string_literal: true

# 187: read-only geometry/UVQ/textures -> isolated HtmlDialog renderer. Never change the
# active model, native camera, thumbnail_camera, transaction, or source SKP.
module GavinTools
  module SULinkHubMultiSpace
    module Runtime
      INGEST_PREVIEW_TRIANGLE_LIMIT = 240_000
      INGEST_PREVIEW_ENTITY_LIMIT = 400_000
      INGEST_PREVIEW_LINE_LIMIT = 60_000

      # 187: texture pixels are copied into a bounded LOCAL scratch image only.
      # Never assign material/UV to a Face, explode a component, or open an operation.
      def ingest_preview_warning187(job, key)
        job[:warnings187] ||= {}
        job[:warnings187][key.to_s] = true
      end

      def ingest_preview_cleanup187(job)
        path = job && job.delete(:texture_dir187)
        FileUtils.remove_entry(path) if path && File.directory?(path)
        true
      rescue StandardError => e
        log_exception('清理入库预览临时纹理失败', e)
        false
      end

      def ingest_preview_texture_png187(job, texture)
        width = texture.image_width.to_i
        height = texture.image_height.to_i
        raise '纹理原图超限' unless width.positive? && height.positive? && [width, height].max <= 32_768 && width * height <= 16_777_216
        rep = texture.image_rep(true)
        raise '无法读取纹理像素' unless rep && rep.width.to_i.positive? && rep.height.to_i.positive?
        raise '纹理像素副本超限' if [rep.width, rep.height].max > 32_768 || rep.width * rep.height > 16_777_216
        if [rep.width, rep.height].max > 512
          channels = rep.bits_per_pixel.to_i / 8
          raise '不支持的纹理像素格式' unless [3, 4].include?(channels)
          scale = 512.0 / [rep.width, rep.height].max
          w = [(rep.width * scale).round, 1].max
          h = [(rep.height * scale).round, 1].max
          stride = rep.width * channels + rep.row_padding.to_i
          raw = rep.data
          raise '纹理像素数据不完整' unless raw && raw.bytesize >= stride * rep.height
          pixels = String.new(encoding: Encoding::BINARY)
          h.times do |y|
            sy = [((y + 0.5) * rep.height / h).floor, rep.height - 1].min
            w.times do |x|
              sx = [((x + 0.5) * rep.width / w).floor, rep.width - 1].min
              pixels << raw.byteslice(sy * stride + sx * channels, channels)
            end
          end
          smaller = Sketchup::ImageRep.new
          smaller.set_data(w, h, rep.bits_per_pixel, 0, pixels)
          rep = smaller
        end
        FileUtils.mkdir_p(TEMP_WORK_DIR)
        job[:texture_dir187] ||= Dir.mktmpdir('ingest-preview187-', TEMP_WORK_DIR)
        path = File.join(job[:texture_dir187], "#{SecureRandom.hex(8)}.png")
        rep.save_file(path)
        raise '纹理导出失败或超限' unless File.file?(path) && File.size(path).positive? && File.size(path) <= 1_250_000
        bytes = File.binread(path)
        total = job[:texture_bytes187].to_i + bytes.bytesize
        raise '本款预览纹理总量超限' if total > 12 * 1024 * 1024
        job[:texture_bytes187] = total
        ['data:image/png;base64,' + Base64.strict_encode64(bytes), rep.bits_per_pixel.to_i == 32]
      ensure
        File.delete(path) if defined?(path) && path && File.file?(path)
      end

      def ingest_preview_style187(job, material, plain: false)
        job[:styles187] ||= {}
        key = [material ? material.object_id : 0, plain]
        return job[:styles187][key] if job[:styles187].key?(key)
        raise '预览材质数量超限' if job[:styles187].length >= 1024
        alpha = material && material.respond_to?(:alpha) ? material.alpha.to_f : 1.0
        style = {id: job[:styles187].length, color: ingest_preview_color186(material), alpha: [[alpha, 0.0].max, 1.0].min}
        texture = material && material.respond_to?(:texture) ? material.texture : nil
        if texture && !plain
          begin
            raise '单款纹理数量超限' if job[:texture_count187].to_i >= 32
            job[:texture_count187] = job[:texture_count187].to_i + 1
            style[:image], style[:transparent] = ingest_preview_texture_png187(job, texture)
          rescue StandardError => e
            ingest_preview_warning187(job, '部分纹理回退材质色')
            log("入库纹理预览降级：#{e.message}")
          end
        end
        job[:styles187][key] = style
        raise '无法发送预览材质' unless ingest_preview_script186(job[:dialog], 'addIngestPreviewStyle', job[:token], style)
        style
      end

      def ingest_preview_side187(job, face, own_material, inherited, front)
        material = own_material || inherited
        style = ingest_preview_style187(job, material)
        side = {style: style, material: material, front: front}
        return side unless style[:image]
        texture = material.texture
        if own_material
          begin
            side[:helper] = face.get_UVHelper(front, !front)
          rescue StandardError
            ingest_preview_warning187(job, '部分UV采用默认投影')
          end
        else
          # Ruby cannot expose all historical UV tweaks for an unpainted Face.
          # Default face-plane projection preserves physical texture size, without
          # the unsafe workaround of temporarily painting/exploding the model.
          ingest_preview_warning187(job, '继承纹理使用默认投影')
        end
        unless side[:helper]
          side[:projection] = Geom::Transformation.new(Geom::Point3d.new(0, 0, 0), face.normal).inverse
          side[:width] = texture.width.to_f
          side[:height] = texture.height.to_f
          raise '继承纹理尺寸无效' unless side[:width].positive? && side[:height].positive?
        end
        side
      rescue StandardError
        ingest_preview_warning187(job, '部分UV回退材质色')
        {style: ingest_preview_style187(job, material, plain: true), material: material, front: front}
      end

      def ingest_preview_uvq187(job, side, point)
        return [0.0, 0.0, 1.0] unless side[:style][:image]
        if side[:helper]
          q = side[:front] ? side[:helper].get_front_UVQ(point) : side[:helper].get_back_UVQ(point)
          uvq = [q.x.to_f, q.y.to_f, q.z.to_f]
        else
          q = point.transform(side[:projection])
          uvq = [q.x.to_f / side[:width], q.y.to_f / side[:height], 1.0]
        end
        raise '无效UVQ' unless uvq.all?(&:finite?) && uvq[2].abs > 1.0e-10
        uvq # Retain Q for correct projective interpolation in the fragment shader.
      rescue StandardError
        ingest_preview_warning187(job, '部分UV回退材质色')
        side[:style] = ingest_preview_style187(job, side[:material], plain: true)
        [0.0, 0.0, 1.0]
      end

      def ingest_preview_mirrored187?(transform)
        a = transform.to_a
        a[0] * (a[5]*a[10]-a[6]*a[9]) - a[4] * (a[1]*a[10]-a[2]*a[9]) + a[8] * (a[1]*a[6]-a[2]*a[5]) < 0.0
      rescue StandardError
        false
      end

      def ingest_preview_status187(job)
        notes = (job[:warnings187] || {}).keys
        notes << '部分边线未显示' if job[:lines_truncated]
        notes << '图像对象显示轮廓' if job[:image_outlines]
        base = '纹理着色＋边线 · 点击放大'
        notes.empty? ? base : base + ' · ' + notes.join('；')
      end

      def ingest_preview_script186(dialog, method, *args)
        return false unless dialog && dialog.visible?
        dialog.execute_script("window.#{method}(#{args.map { |arg| JSON.generate(arg) }.join(',')})")
        true
      rescue StandardError
        false
      end

      def ingest_preview_definition_key186(row)
        entity = row[:entity]
        return '' unless entity && entity.valid? && entity.respond_to?(:definition)
        definition = entity.definition
        return '' unless definition && definition.valid?
        material = entity.respond_to?(:material) ? entity.material : nil
        ['textured187', definition.object_id, (definition.respond_to?(:guid) ? definition.guid.to_s : ''),
         ingest_preview_color186(material).join(',')].join('|')
      rescue StandardError
        ''
      end

      def ingest_preview_color186(material)
        return [184, 193, 204] unless material && material.respond_to?(:color)
        color = material.color
        [color.red, color.green, color.blue].map { |v| [[v.to_i, 0].max, 255].min }
      rescue StandardError
        [184, 193, 204]
      end

      def ingest_preview_owner186?(job)
        draft = @soft_batch_ingest_draft
        job && draft.equal?(job[:draft]) && draft.is_a?(Hash) &&
          @soft_batch_ingest_dialog.equal?(job[:dialog]) && job[:dialog].visible? &&
          draft[:rows][job[:key]].equal?(job[:row]) && job[:row][:preview_token186] == job[:token]
      rescue StandardError
        false
      end

      def ingest_preview_live186?(job)
        draft = @soft_batch_ingest_draft
        return false unless job && draft.equal?(job[:draft]) && draft[:model].equal?(Sketchup.active_model)
        return false unless @soft_batch_ingest_dialog.equal?(job[:dialog]) && job[:dialog].visible?
        row = draft[:rows][job[:key]]
        row.equal?(job[:row]) && row[:preview_token186] == job[:token] &&
          !job[:definition_key].to_s.empty? && ingest_preview_definition_key186(row) == job[:definition_key]
      rescue StandardError
        false
      end

      def enqueue_ingest_preview186(row_key, model, delay: 0.05)
        draft = @soft_batch_ingest_draft
        return false unless draft.is_a?(Hash) && draft[:model].equal?(model)
        row = draft[:rows].is_a?(Hash) ? draft[:rows][row_key.to_s] : nil
        dialog = @soft_batch_ingest_dialog
        return false unless row.is_a?(Hash) && dialog && dialog.visible?
        return true unless row[:preview_token186].to_s.empty?
        token = SecureRandom.hex(10)
        row[:preview_token186] = token
        @ingest_preview_queue186 ||= []
        @ingest_preview_queue186 << {draft: draft, row: row, model: model, dialog: dialog,
          key: row_key.to_s, token: token, definition_key: ingest_preview_definition_key186(row), phase: :prepare}
        ingest_preview_script186(dialog, 'setIngestPreviewStatus', row_key.to_s, '轴测预览排队中')
        schedule_ingest_preview_tick186(delay)
        true
      rescue StandardError => e
        row[:preview_token186] = nil if row.is_a?(Hash)
        log_exception('安排入库只读轴测预览失败', e)
        false
      end

      def schedule_ingest_preview_tick186(delay = 0.03)
        return false if @ingest_preview_timer186
        generation = (@ingest_preview_generation186 ||= 0)
        @ingest_preview_timer186 = true
        runtime_start_timer(delay, false, label: 'soft:ingest_readonly_preview') do
          next unless generation == @ingest_preview_generation186
          @ingest_preview_timer186 = false
          process_ingest_preview_tick186
        end
        true
      end

      def cancel_ingest_previews186!
        @ingest_preview_generation186 = @ingest_preview_generation186.to_i + 1
        @ingest_preview_timer186 = false
        Array(@ingest_preview_queue186).each do |job|
          job[:row][:preview_token186] = nil if job[:row].is_a?(Hash)
        end
        job = @ingest_preview_active186
        if job
          job[:row][:preview_token186] = nil if job[:row].is_a?(Hash)
          ingest_preview_script186(job[:dialog], 'cancelIngestPreview', job[:token])
          ingest_preview_cleanup187(job)
        end
        @ingest_preview_active186 = nil
        @ingest_preview_queue186 = []
        true
      end

      def finish_ingest_preview186(job, message = '')
        return false unless @ingest_preview_active186.equal?(job)
        ingest_preview_script186(job[:dialog], 'cancelIngestPreview', job[:token])
        if ingest_preview_owner186?(job)
          ingest_preview_script186(job[:dialog], 'setIngestPreviewStatus', job[:key], message) unless message.empty?
        end
        ingest_preview_cleanup187(job)
        job[:row][:preview_token186] = nil if job[:row][:preview_token186] == job[:token]
        @ingest_preview_active186 = nil
        true
      end

      # GPU/DOM acknowledgements never submit furniture or change model metadata.
      def accept_ingest_preview186(key, token, url, error = '')
        job = @ingest_preview_active186
        return false unless job && job[:key] == key.to_s && job[:token] == token.to_s && (job[:phase] == :awaiting || !error.to_s.empty?)
        return false unless ingest_preview_live186?(job)
        data = url.to_s
        if error.to_s.empty? && data.bytesize <= 1_500_000 && data.match?(/\Adata:image\/png;base64,[A-Za-z0-9+\/=]+\z/)
          job[:row][:thumbnail_url] = data
          job[:row][:preview_definition_key186] = job[:definition_key]
          ingest_preview_script186(job[:dialog], 'updateThumb', key.to_s, data)
          job[:row][:preview_status187] = ingest_preview_status187(job)
          finish_ingest_preview186(job, job[:row][:preview_status187])
          log("入库只读轴测预览：#{job[:row][:source_label]} / #{job[:triangles]} 三角面 / 纹理#{job[:texture_count187].to_i} / 边线#{job[:lines].to_i} / 分片读取 #{job[:work_ms].to_i}ms / #{(job[:warnings187] || {}).keys.join('；')}")
        else
          finish_ingest_preview186(job, '预览不可用 · 可继续分类入库')
          log("入库只读预览未完成：#{error.to_s[0, 160]}")
        end
        schedule_ingest_preview_tick186 unless Array(@ingest_preview_queue186).empty?
        true
      end

      def prepare_ingest_preview186(job)
        if job[:row][:preview_definition_key186] == job[:definition_key] &&
           job[:row][:thumbnail_url].to_s.start_with?('data:image/png;base64,')
          ingest_preview_script186(job[:dialog], 'updateThumb', job[:key], job[:row][:thumbnail_url])
          finish_ingest_preview186(job, job[:row][:preview_status187].to_s)
          return
        end
        standard = soft_batch_ingest_true_model_thumbnail_url(job[:row], soft_library_root)
        unless standard.to_s.empty?
          job[:row][:thumbnail_url] = standard
          ingest_preview_script186(job[:dialog], 'updateThumb', job[:key], standard)
          # Keep the library image as a fallback, but rebuild the requested textured/edges style.
        end
        entity = job[:row][:entity]
        definition = entity.definition
        material = entity.respond_to?(:material) ? entity.material : nil
        job[:stack] = [{iterator: definition.entities.to_enum(:each), transform: identity_transformation,
          material: material, trail: [definition.object_id]}]
        job[:triangles] = 0
        job[:entities] = 0
        job[:lines] = 0
        job[:work_ms] = 0.0
        job[:phase] = :geometry
        raise '无法连接预览画布' unless ingest_preview_script186(job[:dialog], 'beginIngestPreview', job[:key], job[:token], SOFT_LIBRARY_THUMBNAIL_MARGIN)
        ingest_preview_script186(job[:dialog], 'setIngestPreviewStatus', job[:key], '正在生成纹理＋边线预览…')
      end

      def ingest_preview_face_triangle186(job)
        pending = job[:face]
        mesh = pending[:mesh]
        unless pending[:polygon]
          polygon = pending[:polygons].next.map { |index| index.to_i.abs }
          return nil if polygon.length < 3
          pending[:polygon] = polygon
          pending[:fan] = 1
        end
        polygon = pending[:polygon]
        i = pending[:fan]
        indices = [polygon[0], polygon[i], polygon[i + 1]]
        indices[1], indices[2] = indices[2], indices[1] if pending[:mirrored]
        local_points = indices.map { |index| mesh.point_at(index) }
        result = local_points.flat_map do |point|
          p = point.transform(pending[:transform])
          [p.x.to_f, p.y.to_f, p.z.to_f]
        end
        front_uv = local_points.flat_map { |point| ingest_preview_uvq187(job, pending[:front], point) }
        back_uv = local_points.flat_map { |point| ingest_preview_uvq187(job, pending[:back], point) }
        raise '预览几何坐标无效' unless result.all?(&:finite?)
        pending[:fan] += 1
        pending[:polygon] = nil if pending[:fan] >= polygon.length - 1
        [result, pending[:color], front_uv + back_uv, [pending[:front][:style][:id], pending[:back][:style][:id]]]
      rescue StopIteration
        job[:face] = nil
        nil
      end

      def read_ingest_preview_chunk186(job)
        started = monotonic_time
        positions = []; colors = []; lines = []; uvqs = []; style_ids = []
        900.times do
          break if monotonic_time - started >= 0.018
          if job[:face]
            triangle = ingest_preview_face_triangle186(job)
            if triangle
              job[:triangles] += 1
              raise '模型过于复杂，未生成不完整的预览' if job[:triangles] > INGEST_PREVIEW_TRIANGLE_LIMIT
              positions.concat(triangle[0]); colors.concat(triangle[1]); uvqs.concat(triangle[2]); style_ids.concat(triangle[3])
            end
            next
          end
          frame = job[:stack].last
          break unless frame
          begin
            entity = frame[:iterator].next
          rescue StopIteration
            job[:stack].pop
            next
          end
          next unless entity && entity.valid?
          next if entity.respond_to?(:hidden?) && entity.hidden?
          job[:entities] += 1
          raise '预览对象数量超限' if job[:entities] > INGEST_PREVIEW_ENTITY_LIMIT
          transform = frame[:transform]
          own_material = entity.respond_to?(:material) ? entity.material : nil
          material = own_material || frame[:material]
          if entity.is_a?(Sketchup::Face)
            mesh = entity.mesh(0)
            raise '单面网格过于复杂' if mesh.count_polygons > INGEST_PREVIEW_TRIANGLE_LIMIT
            back_material = entity.respond_to?(:back_material) ? entity.back_material : nil
            job[:face] = {mesh: mesh, polygons: mesh.polygons.each, transform: transform,
              color: ingest_preview_color186(material), mirrored: ingest_preview_mirrored187?(transform),
              front: ingest_preview_side187(job, entity, own_material, frame[:material], true),
              back: ingest_preview_side187(job, entity, back_material, frame[:material], false)}
          elsif entity.is_a?(Sketchup::ComponentInstance) || entity.is_a?(Sketchup::Group)
            definition = entity.definition
            next unless definition && definition.valid?
            next if frame[:trail].include?(definition.object_id)
            raise '预览嵌套过深' if frame[:trail].length >= 64
            job[:stack] << {iterator: definition.entities.to_enum(:each), transform: transform * entity.transformation,
              material: material, trail: frame[:trail] + [definition.object_id]}
          elsif entity.is_a?(Sketchup::Edge)
            next if entity.respond_to?(:soft?) && entity.soft?
            if job[:lines] < INGEST_PREVIEW_LINE_LIMIT
              [entity.start.position, entity.end.position].each do |point|
                p = point.transform(transform); lines.concat([p.x.to_f, p.y.to_f, p.z.to_f])
              end
              job[:lines] += 1
            else
              job[:lines_truncated] = true
            end
          elsif defined?(Sketchup::Image) && entity.is_a?(Sketchup::Image)
            # Images have no supported read-only Face mesh. Show a clearly labelled
            # spatial outline, not a fabricated texture or a source-file rewrite.
            box = entity.bounds
            [[0,1],[1,3],[3,2],[2,0],[4,5],[5,7],[7,6],[6,4],[0,4],[1,5],[2,6],[3,7]].each do |a,b|
              raise '图像轮廓过多' if job[:lines] >= INGEST_PREVIEW_LINE_LIMIT
              [box.corner(a), box.corner(b)].each do |point|
                p = point.transform(transform); lines.concat([p.x.to_f, p.y.to_f, p.z.to_f])
              end
              job[:lines] += 1
            end
            job[:image_outlines] = true
          end
        end
        job[:work_ms] += (monotonic_time - started) * 1000
        raise '预览读取超时' if job[:work_ms] > 15_000
        unless positions.empty? && lines.empty?
          raise '预览面板已经关闭' unless ingest_preview_script186(job[:dialog], 'appendIngestPreview', job[:token], positions, colors, lines, uvqs, style_ids)
        end
        if job[:stack].empty? && !job[:face]
          raise '没有可显示的面或线' if job[:triangles].zero? && job[:lines].zero?
          raise '线框数量超限，未显示不完整预览' if job[:triangles].zero? && job[:lines_truncated]
          job[:phase] = :awaiting
          job[:awaiting_at] = monotonic_time
          ingest_preview_script186(job[:dialog], 'endIngestPreview', job[:token], !!job[:image_outlines])
        end
      end

      def process_ingest_preview_tick186
        @ingest_preview_queue186 ||= []
        job = (@ingest_preview_active186 ||= @ingest_preview_queue186.shift)
        return false unless job
        unless ingest_preview_live186?(job)
          finish_ingest_preview186(job, '对象已变化 · 请重新打开面板')
          return false
        end
        if job[:phase] == :awaiting
          finish_ingest_preview186(job, '预览响应超时 · 可继续分类入库') if monotonic_time - job[:awaiting_at].to_f > 25.0
          return true
        end
        # Read-only API work still yields to native save/capture/commit activity.
        return true if @shutting_down || @updating || publish_critical_section? || publish_post_quiet? ||
          @soft_thumbnail_rendering || @soft_visual_proxy_upgrade_job ||
          (@soft_ingest_batch_job.is_a?(Hash) && @soft_ingest_batch_job[:active_candidate])
        prepare_ingest_preview186(job) if job[:phase] == :prepare
        read_ingest_preview_chunk186(job) if @ingest_preview_active186.equal?(job) && job[:phase] == :geometry
        true
      rescue StandardError => e
        finish_ingest_preview186(job, '预览未完成 · 可继续分类入库') if job
        log_exception('生成入库只读轴测预览失败', e)
        false
      ensure
        schedule_ingest_preview_tick186(0.04) if @ingest_preview_active186 || !Array(@ingest_preview_queue186).empty?
      end
    end
  end
end
