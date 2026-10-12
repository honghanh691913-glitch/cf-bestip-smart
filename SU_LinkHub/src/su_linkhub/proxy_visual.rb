# frozen_string_literal: true

module GavinTools
  module SULinkHubMultiSpace
    module Runtime
    # -------------------------
    # 六面可视化家具代理 v1
    # -------------------------

    def soft_visual_proxy_truthy?(value)
      value == true || %w[1 true yes on].include?(value.to_s.strip.downcase)
    rescue StandardError
      false
    end

    def soft_visual_proxy_channel_offsets(channels)
      windows = if Sketchup.respond_to?(:platform)
                  Sketchup.platform == :platform_win
                else
                  RUBY_PLATFORM.to_s.downcase.include?('win')
                end
      { red: (windows ? 2 : 0), green: 1, blue: (windows ? 0 : 2), alpha: (channels == 4 ? 3 : nil) }
    end

    def soft_visual_proxy_load_image_rep(path)
      raise "截图文件不存在：#{path}" unless File.file?(path) && File.size(path).positive?
      raise '当前 SketchUp 不支持 ImageRep，无法生成透明六面代理。' unless defined?(Sketchup::ImageRep)
      rep = Sketchup::ImageRep.new
      rep.load_file(path)
      width = rep.width.to_i
      height = rep.height.to_i
      bits = rep.bits_per_pixel.to_i
      padding = rep.row_padding.to_i
      raise '六面代理截图像素格式不受支持。' unless width.positive? && height.positive? && [24, 32].include?(bits)
      channels = bits / 8
      stride = width * channels + padding
      data = rep.data.to_s.b
      raise '六面代理截图像素数据不完整。' if data.bytesize < stride * height
      [width, height, channels, stride, data, soft_visual_proxy_channel_offsets(channels)]
    end

    def soft_visual_proxy_edge_background_luma(width, height, channels, stride, data, offsets)
      samples = []
      step_x = [width / 64, 1].max
      step_y = [height / 64, 1].max
      points = []
      (0...width).step(step_x) { |x| points << [x, 0] << [x, height - 1] }
      (0...height).step(step_y) { |y| points << [0, y] << [width - 1, y] }
      points.uniq.each do |x, y|
        offset = y * stride + x * channels
        red = data.getbyte(offset + offsets[:red]).to_i
        green = data.getbyte(offset + offsets[:green]).to_i
        blue = data.getbyte(offset + offsets[:blue]).to_i
        next if [red, green, blue].max - [red, green, blue].min > 36
        samples << (red * 0.2126 + green * 0.7152 + blue * 0.0722)
      end
      return 255.0 if samples.empty?
      samples.sort!
      samples[samples.length / 2].to_f
    rescue StandardError
      255.0
    end

    # 与上传的 SU_UltraProxy 稳定方案一致：同一正交视图分别截图白底/黑底，
    # 由两张图反推 Alpha 与真实前景色。这样白色家具不会被误抠，代理也不会
    # 因普通 Face/Material 再次参与 SketchUp 受光而整体发黑。
    def soft_visual_proxy_matte_pair_to_png!(white_path, black_path, output_path)
      white = soft_visual_proxy_load_image_rep(white_path)
      black = soft_visual_proxy_load_image_rep(black_path)
      raise '六面代理黑白底截图尺寸不一致。' unless white[0] == black[0] && white[1] == black[1]
      width, height = white[0], white[1]
      wc, ws, wd, wo = white[2], white[3], white[4], white[5]
      bc, bs, bd, bo = black[2], black[3], black[4], black[5]
      luma = soft_visual_proxy_edge_background_luma(width, height, wc, ws, wd, wo)
      gain = if luma > 8.0 && luma < 248.0
               [[255.0 / luma, 1.0].max, 5.0].min
             else
               1.0
             end
      out_stride = width * 4
      out = "\x00".b * (out_stride * height)
      oo = soft_visual_proxy_channel_offsets(4)

      # v0.13.6.166 PERFORMANCE：不要 unpack('C*')。192px 双图展开成 Ruby Array
      # 会制造数十万槽位和额外 GC；实测真正热点是每像素临时 Array + sort/min/max
      # 以及 gain==1 时仍做 6 次浮点乘法。这里保持 getbyte/setbyte 的紧凑 String，
      # 用无分配三数中位数与 gain 快路径，输出算法/通道顺序保持完全一致。
      wr_off = wo[:red]; wg_off = wo[:green]; wb_off = wo[:blue]
      br_off = bo[:red]; bg_off = bo[:green]; bb_off = bo[:blue]
      or_off = oo[:red]; og_off = oo[:green]; ob_off = oo[:blue]; oa_off = oo[:alpha]
      apply_gain = (gain - 1.0).abs > 1.0e-9

      height.times do |y|
        wrow = y * ws
        brow = y * bs
        orow = y * out_stride
        width.times do |x|
          wi = wrow + x * wc
          bi = brow + x * bc
          oi = orow + x * 4

          wr = wd.getbyte(wi + wr_off)
          wg = wd.getbyte(wi + wg_off)
          wb = wd.getbyte(wi + wb_off)
          br = bd.getbyte(bi + br_off)
          bg = bd.getbyte(bi + bg_off)
          bb = bd.getbyte(bi + bb_off)

          if apply_gain
            wr = (wr * gain).round; wr = 255 if wr > 255
            wg = (wg * gain).round; wg = 255 if wg > 255
            wb = (wb * gain).round; wb = 255 if wb > 255
            br = (br * gain).round; br = 255 if br > 255
            bg = (bg * gain).round; bg = 255 if bg > 255
            bb = (bb * gain).round; bb = 255 if bb > 255
          end

          dr = wr > br ? wr - br : 0
          dg = wg > bg ? wg - bg : 0
          db = wb > bb ? wb - bb : 0
          min_diff = dr < dg ? (dr < db ? dr : db) : (dg < db ? dg : db)
          max_diff = dr > dg ? (dr > db ? dr : db) : (dg > db ? dg : db)
          median_diff = dr + dg + db - min_diff - max_diff
          alpha_f = 1.0 - median_diff.to_f / 255.0
          alpha = (alpha_f * 255.0).round

          if alpha <= 3
            rr = gg = bb2 = 255
            alpha = 0
          else
            inv = 1.0 / (alpha_f > 0.02 ? alpha_f : 0.02)
            rr = (br * inv).round; rr = 255 if rr > 255
            gg = (bg * inv).round; gg = 255 if gg > 255
            bb2 = (bb * inv).round; bb2 = 255 if bb2 > 255
            if alpha < 96
              t = alpha / 96.0
              u = 1.0 - t
              rr = (rr * t + wr * u).round
              gg = (gg * t + wg * u).round
              bb2 = (bb2 * t + wb * u).round
            end
          end

          out.setbyte(oi + or_off, rr)
          out.setbyte(oi + og_off, gg)
          out.setbyte(oi + ob_off, bb2)
          out.setbyte(oi + oa_off, alpha)
        end
      end
      rep = Sketchup::ImageRep.new
      rep.set_data(width, height, 32, 0, out)
      rep.save_file(output_path)
      raise '六面代理透明 PNG 写出失败。' unless File.file?(output_path) && File.size(output_path).positive?
      output_path
    end

    def soft_visual_proxy_axis_dimension(values, axis)
      data = Array(values).map(&:to_f)
      case axis
      when :x then (data[3] - data[0]).abs
      when :y then (data[4] - data[1]).abs
      when :z then (data[5] - data[2]).abs
      else 0.0
      end
    end

    def soft_visual_proxy_texture_size(width, height, max_px = SOFT_VISUAL_PROXY_RESOLUTION)
      w = [width.to_f.abs, 0.001].max
      h = [height.to_f.abs, 0.001].max
      if w >= h
        px_w = max_px.to_i
        px_h = (max_px.to_f * h / w).round
      else
        px_h = max_px.to_i
        px_w = (max_px.to_f * w / h).round
      end
      width_px = [[px_w, 16].max, max_px.to_i].min
      height_px = [[px_h, 16].max, max_px.to_i].min
      [width_px, height_px]
    end

    def soft_visual_proxy_set_background!(model, color)
      options = model.rendering_options
      available = options.respond_to?(:keys) ? options.keys : []
      %w[BackgroundColor SkyColor GroundColor].each { |key| options[key] = color if available.include?(key) }
      model.styles.update_selected_style if model.styles.respond_to?(:update_selected_style)
      true
    rescue StandardError
      false
    end

    def soft_visual_proxy_write_opaque!(view, path, width, height)
      view.invalidate
      view.refresh
      ok = view.write_image(filename: path, width: width.to_i, height: height.to_i, antialias: true, transparent: false)
      raise "六面代理截图失败：#{File.basename(path)}" unless ok && File.file?(path) && File.size(path).positive?
      true
    end

    # v0.13.6.170：SketchUp API 原生支持 transparent:true，但历史显卡/渲染器上
    # 曾出现“透明 PNG 整体发黑”。因此绝不盲用；首次会用白/黑双底做像素自检，
    # 只有合成结果与双底截图吻合后，本会话才切到 6 张原生透明截图快路径。
    def soft_visual_proxy_write_transparent!(view, path, width, height)
      view.invalidate
      view.refresh
      ok = view.write_image(filename: path, width: width.to_i, height: height.to_i, antialias: true, transparent: true)
      raise "六面代理透明截图失败：#{File.basename(path)}" unless ok && File.file?(path) && File.size(path).positive?
      true
    end

    def soft_visual_proxy_native_alpha_valid?(transparent_path, white_path, black_path)
      soft_visual_proxy_native_alpha_verdict(transparent_path, white_path, black_path) == :good
    end

    # v0.13.6.192：返回 :good / :bad / :inconclusive。旧逻辑把“画面里没有家具像素”
    # （例如远端隔离拍空）或“家具铺满整幅没有背景像素”也当成 :bad，并永久锁定本会话
    # 走 12 次双底截图。这两种情况根本无法比对透明度，只算“无法判定”，下一款再自检。
    def soft_visual_proxy_native_alpha_verdict(transparent_path, white_path, black_path)
      transparent = soft_visual_proxy_load_image_rep(transparent_path)
      white = soft_visual_proxy_load_image_rep(white_path)
      black = soft_visual_proxy_load_image_rep(black_path)
      return :bad unless transparent[0] == white[0] && transparent[1] == white[1] &&
                         white[0] == black[0] && white[1] == black[1]
      width, height = transparent[0], transparent[1]
      tc, ts, td, to = transparent[2], transparent[3], transparent[4], transparent[5]
      wc, ws, wd, wo = white[2], white[3], white[4], white[5]
      bc, bs, bd, bo = black[2], black[3], black[4], black[5]
      return :inconclusive if tc == 3
      return :bad unless tc == 4 && to[:alpha]

      step_x = [width / 48, 1].max
      step_y = [height / 48, 1].max
      total_error = 0.0
      channel_samples = 0
      severe = 0
      transparent_pixels = 0
      visible_pixels = 0
      y = 0
      while y < height
        x = 0
        while x < width
          ti = y * ts + x * tc
          wi = y * ws + x * wc
          bi = y * bs + x * bc
          alpha = td.getbyte(ti + to[:alpha]).to_i
          transparent_pixels += 1 if alpha <= 8
          visible_pixels += 1 if alpha >= 64
          a = alpha / 255.0
          inv = 1.0 - a
          [[to[:red], wo[:red], bo[:red]], [to[:green], wo[:green], bo[:green]], [to[:blue], wo[:blue], bo[:blue]]].each do |t_off, w_off, b_off|
            color = td.getbyte(ti + t_off).to_i
            actual_white = wd.getbyte(wi + w_off).to_i
            actual_black = bd.getbyte(bi + b_off).to_i
            expected_black = color * a
            expected_white = expected_black + 255.0 * inv
            e1 = (actual_black - expected_black).abs
            e2 = (actual_white - expected_white).abs
            total_error += e1 + e2
            channel_samples += 2
            severe += 1 if e1 > 48.0 || e2 > 48.0
          end
          x += step_x
        end
        y += step_y
      end
      return :inconclusive if channel_samples.zero? || transparent_pixels.zero? || visible_pixels.zero?
      mean_error = total_error / channel_samples.to_f
      severe_ratio = severe.to_f / (channel_samples / 2.0)
      (mean_error <= 14.0 && severe_ratio <= 0.08) ? :good : :bad
    rescue StandardError => e
      log_exception('六面代理原生透明自检失败', e) rescue nil
      :bad
    end

    def soft_visual_proxy_native_alpha_capability
      value = @soft_visual_proxy_native_alpha_capability
      %i[good bad unknown].include?(value) ? value : :unknown
    rescue StandardError
      :unknown
    end

    def remember_soft_visual_proxy_native_alpha_capability!(value)
      if value == :inconclusive
        log('六面代理原生透明快路径：本款画面无法比对（无家具像素或无背景像素），本款走双底，下一款再自检') rescue nil
        return soft_visual_proxy_native_alpha_capability
      end
      @soft_visual_proxy_native_alpha_capability = (value == :good ? :good : :bad)
      log("六面代理原生透明快路径：#{@soft_visual_proxy_native_alpha_capability == :good ? '已通过自检，后续每款 6 次截图' : '自检未通过，继续使用稳定双底 12 次截图'}") rescue nil
      @soft_visual_proxy_native_alpha_capability
    end

    def soft_visual_proxy_capture_six!(source, bounds_values, model, cache_dir)
      raise '六面代理源实例无效。' unless source && source.valid?
      raise '六面代理源模型外包盒无效。' unless soft_bounds_values_valid?(bounds_values)
      values = Array(bounds_values).map(&:to_f)
      x0, y0, z0, x1, y1, z1 = values
      center = Geom::Point3d.new((x0 + x1) * 0.5, (y0 + y1) * 0.5, (z0 + z1) * 0.5)
      FileUtils.mkdir_p(cache_dir)
      token = "#{Process.pid}-#{SecureRandom.hex(6)}"
      view = model.active_view
      images = {}

      # v0.13.6.40 PERFORMANCE PASS 2：仍保留已经验证稳定的“白底 + 黑底双截图
      # 反推 alpha”算法，绝不退回曾导致黑图的 transparent:true。旧版每个方向都
      # 白/黑切换一次，6 个方向会提交 12 次 style + 大量额外 refresh。现在先构造
      # 六个相机计划，再一次白底拍完 6 张、一次黑底拍完 6 张，最后统一抠图。
      # 截图数量仍是 12，像素/相机/透明算法完全不变，只消除无意义的样式抖动。
      plans = SOFT_VISUAL_PROXY_VIEW_SPECS.map do |name, spec|
        axis_a, axis_b = spec[:axes]
        dim_a = soft_visual_proxy_axis_dimension(values, axis_a)
        dim_b = soft_visual_proxy_axis_dimension(values, axis_b)
        width_px, height_px = soft_visual_proxy_texture_size(dim_a, dim_b)
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

      stage_started = monotonic_time
      capability = soft_visual_proxy_native_alpha_capability
      if capability == :good
        plans.each do |plan|
          view.camera = plan[:camera]
          soft_visual_proxy_write_transparent!(view, plan[:final_path], plan[:width_px], plan[:height_px])
          images[plan[:name]] = plan[:final_path]
        end
        log_slow_operation('六面代理原生透明6视图', stage_started, 80.0, "#{plans.length} 视图")
      elsif capability == :bad
        soft_visual_proxy_set_background!(model, Sketchup::Color.new(255, 255, 255))
        plans.each do |plan|
          view.camera = plan[:camera]
          soft_visual_proxy_write_opaque!(view, plan[:white_path], plan[:width_px], plan[:height_px])
        end
        soft_visual_proxy_set_background!(model, Sketchup::Color.new(0, 0, 0))
        plans.each do |plan|
          view.camera = plan[:camera]
          soft_visual_proxy_write_opaque!(view, plan[:black_path], plan[:width_px], plan[:height_px])
        end
        plans.each do |plan|
          soft_visual_proxy_matte_pair_to_png!(plan[:white_path], plan[:black_path], plan[:final_path])
          images[plan[:name]] = plan[:final_path]
          File.delete(plan[:white_path]) if File.file?(plan[:white_path])
          File.delete(plan[:black_path]) if File.file?(plan[:black_path])
        end
        log_slow_operation('六面代理稳定双底6视图', stage_started, 80.0, "#{plans.length} 视图")
      else
        probe = plans.first
        view.camera = probe[:camera]
        soft_visual_proxy_write_transparent!(view, probe[:final_path], probe[:width_px], probe[:height_px])
        soft_visual_proxy_set_background!(model, Sketchup::Color.new(255, 255, 255))
        view.camera = probe[:camera]
        soft_visual_proxy_write_opaque!(view, probe[:white_path], probe[:width_px], probe[:height_px])
        soft_visual_proxy_set_background!(model, Sketchup::Color.new(0, 0, 0))
        view.camera = probe[:camera]
        soft_visual_proxy_write_opaque!(view, probe[:black_path], probe[:width_px], probe[:height_px])
        alpha_verdict = soft_visual_proxy_native_alpha_verdict(probe[:final_path], probe[:white_path], probe[:black_path])
        if alpha_verdict == :good
          remember_soft_visual_proxy_native_alpha_capability!(:good)
          images[probe[:name]] = probe[:final_path]
          File.delete(probe[:white_path]) if File.file?(probe[:white_path])
          File.delete(probe[:black_path]) if File.file?(probe[:black_path])
          plans.drop(1).each do |plan|
            view.camera = plan[:camera]
            soft_visual_proxy_write_transparent!(view, plan[:final_path], plan[:width_px], plan[:height_px])
            images[plan[:name]] = plan[:final_path]
          end
        else
          remember_soft_visual_proxy_native_alpha_capability!(alpha_verdict)
          File.delete(probe[:final_path]) if File.file?(probe[:final_path])
          soft_visual_proxy_set_background!(model, Sketchup::Color.new(255, 255, 255))
          plans.drop(1).each do |plan|
            view.camera = plan[:camera]
            soft_visual_proxy_write_opaque!(view, plan[:white_path], plan[:width_px], plan[:height_px])
          end
          soft_visual_proxy_set_background!(model, Sketchup::Color.new(0, 0, 0))
          plans.drop(1).each do |plan|
            view.camera = plan[:camera]
            soft_visual_proxy_write_opaque!(view, plan[:black_path], plan[:width_px], plan[:height_px])
          end
          plans.each do |plan|
            soft_visual_proxy_matte_pair_to_png!(plan[:white_path], plan[:black_path], plan[:final_path])
            images[plan[:name]] = plan[:final_path]
            File.delete(plan[:white_path]) if File.file?(plan[:white_path])
            File.delete(plan[:black_path]) if File.file?(plan[:black_path])
          end
        end
        log_slow_operation('六面代理透明能力自检与截图', stage_started, 80.0, "#{plans.length} 视图")
      end
      images
    ensure
      if defined?(token) && token && defined?(cache_dir) && cache_dir
        Dir.glob(File.join(cache_dir, "#{token}_*_white.png")).each { |file| File.delete(file) rescue nil }
        Dir.glob(File.join(cache_dir, "#{token}_*_black.png")).each { |file| File.delete(file) rescue nil }
      end
    end

    def soft_visual_proxy_rigid_transform(origin, x_values, y_values, z_values)
      x_axis = Geom::Vector3d.new(x_values)
      y_axis = Geom::Vector3d.new(y_values)
      z_axis = Geom::Vector3d.new(z_values)
      x_axis.normalize!
      y_axis.normalize!
      z_axis.normalize!
      Geom::Transformation.axes(origin, x_axis, y_axis, z_axis)
    end

    def build_soft_visual_proxy_definition!(model, model_id, model_name, source_path, bounds_values, images, source_signature = '')
      validate_soft_visual_proxy_images!(images, model_name)
      raise '六面代理外包盒无效。' unless soft_bounds_values_valid?(bounds_values)
      values = Array(bounds_values).map(&:to_f)
      x0, y0, z0, x1, y1, z1 = values
      points = {
        p000: Geom::Point3d.new(x0, y0, z0), p100: Geom::Point3d.new(x1, y0, z0),
        p110: Geom::Point3d.new(x1, y1, z0), p010: Geom::Point3d.new(x0, y1, z0),
        p001: Geom::Point3d.new(x0, y0, z1), p101: Geom::Point3d.new(x1, y0, z1),
        p111: Geom::Point3d.new(x1, y1, z1), p011: Geom::Point3d.new(x0, y1, z1)
      }
      definition = model.definitions.add(model.definitions.unique_name("LH_六面可视代理_#{model_name}"))
      SOFT_VISUAL_PROXY_IMAGE_SPECS.each do |name, spec|
        width = soft_visual_proxy_axis_dimension(values, spec[:width])
        height = soft_visual_proxy_axis_dimension(values, spec[:height])
        raise "#{name} 六面代理尺寸无效。" if width <= 1.0e-9 || height <= 1.0e-9
        image_path = images[name].to_s
        raise "#{name} 六面代理视图缺失。" unless File.file?(image_path)
        image = definition.entities.add_image(image_path, ORIGIN, width, height)
        raise "#{name} 六面代理图像面创建失败。" unless image && image.valid?
        image.transform!(soft_visual_proxy_rigid_transform(points.fetch(spec[:origin]), spec[:x], spec[:y], spec[:z]))
        image.casts_shadows = false if image.respond_to?(:casts_shadows=)
        image.receives_shadows = false if image.respond_to?(:receives_shadows=)
        image.set_attribute(SOFT_MODEL_DICT, 'visual_proxy_view', name)
        image.set_attribute(SOFT_MODEL_DICT, 'visual_proxy_version', SOFT_VISUAL_PROXY_VERSION)
      end
      signature = soft_bounds_signature_from_values(values)
      soft_set_attribute_if_changed(definition, SOFT_MODEL_DICT, 'representation', 'proxy')
      soft_set_attribute_if_changed(definition, SOFT_MODEL_DICT, 'managed_tree', true)
      soft_set_attribute_if_changed(definition, SOFT_MODEL_DICT, 'exact_bounds_proxy', true)
      soft_set_attribute_if_changed(definition, SOFT_MODEL_DICT, 'proxy_full_bounds_signature', signature)
      soft_set_attribute_if_changed(definition, SOFT_MODEL_DICT, 'auto_proxy_style', SOFT_VISUAL_PROXY_KIND)
      soft_set_attribute_if_changed(definition, SOFT_MODEL_DICT, 'visual_proxy_kind', SOFT_VISUAL_PROXY_KIND)
      soft_set_attribute_if_changed(definition, SOFT_MODEL_DICT, 'visual_proxy_version', SOFT_VISUAL_PROXY_VERSION)
      soft_set_attribute_if_changed(definition, SOFT_MODEL_DICT, 'visual_proxy_render_mode', 'image_planes_dual_matte')
      soft_set_attribute_if_changed(definition, SOFT_MODEL_DICT, 'model_id', model_id.to_s) unless model_id.to_s.empty?
      soft_set_attribute_if_changed(definition, SOFT_MODEL_DICT, 'model_name', model_name.to_s)
      soft_set_attribute_if_changed(definition, SOFT_MODEL_DICT, 'source_path', source_path.to_s)
      soft_set_attribute_if_changed(definition, SOFT_MODEL_DICT, 'proxy_source_signature', source_signature.to_s) unless source_signature.to_s.empty?
      soft_set_attribute_if_changed(definition, SOFT_MODEL_DICT, 'proxy_stale', false)
      persist_soft_definition_bounds_values!(definition, values)
      raise '六面代理生成后外包盒与真模型不一致。' unless soft_definition_bounds_equivalent_to_values?(definition, values, 1.0e-5)
      definition
    end

    # v0.13.6.168：六面代理是可再生资源，但仍不能为了速度牺牲并发保护。
    # 本地盘沿用完整 SHA 强校验，并在候选与代理目录同卷时优先 hard-link，避免一次复制+读回；
    # UNC/SMB 则使用“本机完整 SHA + 首/中/尾抽样 + size/mtime + 最终同目录 rename”。这样不再把
    # 刚上传的代理和旧代理从 NAS 各完整读一遍，同时仍能发现传输损坏与并发替换。
    # v0.13.6.169：内容抽样签名与并发 guard 必须分离。v0.13.6.168 把 mtime
    # 混进了候选内容签名，导致本机候选 copy 到 SMB 后即使字节完全相同，也可能因目标
    # mtime 不同而误报“传输失败”。内容签名现在只含 size + 首/中/尾 SHA；并发 guard
    # 另加 fast signature（mtime+size），既能跨文件系统比较内容，也保留目标变化检测。
    def soft_visual_proxy_sampled_signature(path, sample_bytes: 65_536)
      stat = File.stat(path.to_s)
      return '' unless stat.file? && stat.size.to_i.positive?
      size = stat.size.to_i
      bytes = [[sample_bytes.to_i, 4096].max, size].min
      offsets = [0, [(size - bytes) / 2, 0].max, [size - bytes, 0].max].uniq
      digest = Digest::SHA256.new
      File.open(path.to_s, 'rb') do |file|
        offsets.each do |offset|
          file.seek(offset, IO::SEEK_SET)
          chunk = file.read(bytes).to_s
          return '' unless chunk.bytesize == [bytes, size - offset].min
          digest.update("#{offset}:#{chunk.bytesize}:")
          digest.update(chunk)
        end
      end
      "#{size}|sample3-sha256:#{digest.hexdigest}"
    rescue StandardError
      ''
    end

    def soft_visual_proxy_network_guard(path)
      fast = fast_file_signature(path)
      sampled = soft_visual_proxy_sampled_signature(path)
      return '' if fast.empty? || sampled.empty?
      "#{fast}|#{sampled}"
    rescue StandardError
      ''
    end

    def soft_visual_proxy_network_swap_preverified_stage!(remote_stage, target, candidate_size, candidate_signature, candidate_sample, target_existed:, target_guard:, target_sample: '')
      rollback = nil
      promoted = nil
      with_publish_final_swap_lock(target) do
        current_exists = File.exist?(target)
        current_guard = current_exists ? soft_visual_proxy_network_guard(target) : ''
        if current_exists != !!target_existed || (current_exists && current_guard != target_guard.to_s)
          raise PublishConflictError.new('六面代理在上传期间已被其他任务更新；本次未覆盖。', '')
        end

        if current_exists
          rollback = "#{target}.rollback-#{Process.pid}-#{SecureRandom.hex(4)}"
          File.delete(rollback) if File.exist?(rollback)
          file_operation_with_retry { File.rename(target, rollback) }
          # rename 只移动目录项，但少数 SMB 实现可能重写时间元数据；这里验证纯内容抽样，
          # 不再因为 mtime 表示差异误判 rollback。并发变化已在锁内 rename 前用 guard 检查。
          rollback_sample = soft_visual_proxy_sampled_signature(rollback)
          unless !rollback_sample.empty? && rollback_sample == target_sample.to_s && !File.exist?(target)
            begin
              File.rename(rollback, target) if File.exist?(rollback) && !File.exist?(target)
            rescue StandardError
              nil
            end
            raise PublishConflictError.new('六面代理旧版本在最终替换窗口发生变化；已停止重建。', '')
          end
        end

        raise '六面代理远端候选不存在。' unless File.file?(remote_stage)
        raise '六面代理最终替换窗口目标文件意外存在。' if File.exist?(target)
        file_operation_with_retry { File.rename(remote_stage, target) }
        stat = File.stat(target)
        final_sample = soft_visual_proxy_sampled_signature(target)
        unless stat.file? && stat.size.to_i == candidate_size.to_i && candidate_size.to_i.positive? &&
               !candidate_sample.to_s.empty? && final_sample == candidate_sample.to_s
          # 验证异常时绝不直接 delete 正式路径：把现场原子隔离后再尝试恢复旧代理，
          # 即使极端情况下第三方刚好改写了该路径，也不会把未知内容静默删除。
          failed = "#{target}.failed-visual-#{Process.pid}-#{SecureRandom.hex(4)}"
          begin
            File.rename(target, failed) if File.exist?(target)
            File.rename(rollback, target) if rollback && File.exist?(rollback) && !File.exist?(target)
          rescue StandardError
            nil
          end
          raise "六面代理网络正式文件抽样/大小验证失败；异常候选已保留：#{failed}"
        end
        fast = "#{stat.mtime.to_f}|#{stat.size.to_i}"
        promoted = {
          'fast_signature' => fast,
          'content_signature' => candidate_signature.to_s,
          'snapshot_signature' => "#{fast}|#{candidate_signature}"
        }
      end
      { rollback_path: rollback.to_s, promoted: promoted }
    rescue StandardError
      begin
        File.rename(rollback, target) if rollback && File.exist?(rollback) && !File.exist?(target)
      rescue StandardError
        nil
      end
      raise
    end

    # 自动六面代理只保留短生命周期 rollback；成功后立即删除，避免代理目录持续膨胀。
    def write_soft_visual_proxy_definition_atomic!(definition, target)
      target = FastPath.expand(target.to_s)
      FileUtils.mkdir_p(File.dirname(target))
      token = "#{Process.pid}-#{SecureRandom.hex(4)}"
      local_candidate = File.join(TEMP_WORK_DIR, "SU_LinkHub-visual-proxy-#{token}.skp")
      remote_stage = File.join(File.dirname(target), ".#{File.basename(target)}.visual-#{token}.skp")
      rollback = "#{target}.rollback-#{token}"
      target_existed = File.file?(target)
      network_fast = publish_unc_network_path?(target)

      baseline_started = monotonic_time
      if network_fast
        baseline_sample = target_existed ? soft_visual_proxy_sampled_signature(target) : ''
        baseline_guard = target_existed ? soft_visual_proxy_network_guard(target) : ''
        if target_existed && (baseline_guard.empty? || baseline_sample.empty?)
          raise '无法稳定读取现有六面代理网络基线，已取消重建。'
        end
      else
        baseline = target_existed ? stable_full_file_snapshot_signature(target) : ''
        log_slow_operation('六面代理旧文件完整基线校验', baseline_started, 120.0, File.basename(target)) if target_existed
        raise '无法稳定读取现有六面代理版本，已取消重建。' if target_existed && baseline.empty?
        baseline_fast = full_snapshot_fast_signature(baseline)
        baseline_identity = target_existed ? stable_file_identity_token(target) : ''
      end

      save_method = definition.respond_to?(:save_copy) ? :save_copy : :save_as
      saved = definition.respond_to?(save_method) ? definition.public_send(save_method, local_candidate) : false
      raise 'SketchUp 未能写出六面代理本机候选。' unless (saved || File.file?(local_candidate)) && File.file?(local_candidate) && File.size(local_candidate).positive?
      candidate_size = File.size(local_candidate).to_i
      candidate_signature = full_file_content_signature(local_candidate)
      candidate_sample = soft_visual_proxy_sampled_signature(local_candidate)
      raise '六面代理候选完整校验失败。' if candidate_signature.empty? || candidate_sample.empty?

      if target_existed
        unchanged = network_fast ? (soft_visual_proxy_network_guard(target) == baseline_guard) : (fast_file_signature(target) == baseline_fast)
        raise '六面代理在候选生成期间已被其他任务更新；本次未覆盖。' unless unchanged
      elsif File.exist?(target)
        raise '六面代理在候选生成期间被另一任务创建；本次未覆盖。'
      end

      transfer_started = monotonic_time
      stage_linked = false
      begin
        File.delete(remote_stage) if File.exist?(remote_stage)
        File.link(local_candidate, remote_stage)
        stage_linked = true
      rescue StandardError
        file_operation_with_retry { linkhub_copy_file(local_candidate, remote_stage) }
      end
      raise '六面代理传输到模型库失败。' unless File.file?(remote_stage) && File.size(remote_stage).to_i == candidate_size

      if stage_linked
        # 同卷 hard-link 与本机完整 SHA 候选共享同一 inode，无需再次读文件。
        stage_verified = true
      elsif network_fast
        # 网络只读首/中/尾各 64KB + 单次 stat，避免上传完成后立刻从 NAS 再完整读取整份 SKP。
        stage_verified = soft_visual_proxy_sampled_signature(remote_stage) == candidate_sample
      else
        stage_verified = full_file_content_signature(remote_stage) == candidate_signature
      end
      raise '六面代理传输到模型库后的校验失败。' unless stage_verified
      log_slow_operation('六面代理候选传输与校验', transfer_started, 120.0, File.basename(target))

      if target_existed
        unchanged = network_fast ? (soft_visual_proxy_network_guard(target) == baseline_guard) : (fast_file_signature(target) == baseline_fast)
        raise '六面代理在候选传输期间已被其他任务更新；本次未覆盖。' unless unchanged
      elsif File.exist?(target)
        raise '六面代理在候选传输期间被另一任务创建；本次未覆盖。'
      end

      if network_fast
        swap = soft_visual_proxy_network_swap_preverified_stage!(
          remote_stage, target, candidate_size, candidate_signature, candidate_sample,
          target_existed: target_existed,
          target_guard: (target_existed ? baseline_guard : ''),
          target_sample: (target_existed ? baseline_sample : '')
        )
        remote_stage = nil
        rollback = swap[:rollback_path].to_s
        promoted = swap[:promoted]
        raise '六面代理网络正式文件验证失败。' unless promoted.is_a?(Hash) && promoted['content_signature'].to_s == candidate_signature
      else
        if File.file?(target)
          linkhub_mv(target, rollback)
          # 同目录 rename 不改变 inode/内容；本地文件系统能提供稳定 identity 时直接复用
          # 已经做过的 baseline SHA，避免把旧代理再完整读第二遍。拿不到 identity 才回退强校验。
          rollback_identity = stable_file_identity_token(rollback)
          rollback_matches = if !baseline_identity.to_s.empty? && rollback_identity == baseline_identity.to_s
                               true
                             else
                               stable_full_file_snapshot_signature(rollback) == baseline
                             end
          unless rollback_matches
            promote_file_create_only!(rollback, target) unless File.exist?(target)
            raise '六面代理在最终替换窗口发生变化；已停止重建。'
          end
        end
        begin
          promoted = promote_preverified_file_create_only!(remote_stage, target, candidate_signature)
          remote_stage = nil unless File.file?(remote_stage)
          raise '六面代理正式文件验证失败。' unless promoted['content_signature'].to_s == candidate_signature
          raise '六面代理正式文件在验证后立即变化。' unless fast_file_signature(target) == promoted['fast_signature'].to_s
        rescue StandardError
          remove_file_if_content_matches!(target, candidate_signature) if File.file?(target) && !candidate_signature.to_s.empty?
          promote_file_create_only!(rollback, target) if File.file?(rollback) && !File.exist?(target)
          raise
        end
      end

      File.delete(rollback) if rollback && !rollback.empty? && File.file?(rollback)
      invalidate_soft_library_file_signature!(target)
      target
    ensure
      File.delete(local_candidate) if defined?(local_candidate) && local_candidate && File.file?(local_candidate)
      File.delete(remote_stage) if defined?(remote_stage) && remote_stage && File.file?(remote_stage)
    end

    # 六面代理成为正式代理后的权威映射表。它独立于“模型记录.json/目录索引”保存，
    # 这样旧版客户端即使重写了模型索引、或旧空间包里仍带白盒代理，最新版仍能只凭
    # model_id 找回已经生成的六面代理，不会再次退回白盒。
    def soft_visual_proxy_registry_dir(root = soft_library_root)
      return '' if root.to_s.empty?
      File.join(soft_library_manager_dir(root), '六面代理映射')
    rescue StandardError
      ''
    end

    def soft_visual_proxy_registry_entry_path(model_id, root = soft_library_root)
      id = model_id.to_s.strip
      return '' if id.empty?
      dir = soft_visual_proxy_registry_dir(root)
      return '' if dir.to_s.empty?
      File.join(dir, "#{safe_soft_library_filename(id)}.json")
    rescue StandardError
      ''
    end

    # 每个 model_id 独立一个映射文件。这样多人同时生成不同家具代理时不会争写同一个总 JSON，
    # 旧版客户端也不会碰这些文件，权威映射因此比目录索引更稳定。
    def register_soft_visual_proxy!(model_id, model_name, source_path, proxy_path, source_signature, bounds_signature = '', root = soft_library_root)
      id = model_id.to_s.strip
      entry = soft_visual_proxy_registry_entry_path(id, root)
      return false if id.empty? || entry.to_s.empty? || proxy_path.to_s.empty?
      FileUtils.mkdir_p(File.dirname(entry))
      payload = {
        'schema' => SOFT_VISUAL_PROXY_REGISTRY_SCHEMA,
        'model_id' => id,
        'model_name' => model_name.to_s,
        'source_path' => FastPath.expand(source_path.to_s),
        'proxy_path' => FastPath.expand(proxy_path.to_s),
        'proxy_relative_path' => begin
          Pathname.new(FastPath.expand(proxy_path.to_s)).relative_path_from(Pathname.new(root)).to_s.tr('\\', '/')
        rescue StandardError
          ''
        end,
        'proxy_kind' => SOFT_VISUAL_PROXY_KIND,
        'proxy_visual_version' => SOFT_VISUAL_PROXY_VERSION,
        'proxy_auto_generated' => true,
        'proxy_source_signature' => source_signature.to_s,
        'proxy_full_bounds_signature' => bounds_signature.to_s,
        'proxy_render_mode' => 'image_planes_dual_matte',
        'updated_at' => Time.now.strftime('%Y-%m-%d %H:%M:%S')
      }
      write_json_atomic(entry, payload)
      @soft_visual_proxy_registry_entry_cache ||= {}
      @soft_visual_proxy_registry_entry_cache[[normalize_soft_library_key(root), id]] = {
        signature: fast_file_signature(entry).to_s,
        data: payload,
        checked_at: monotonic_time
      }
      true
    rescue StandardError => e
      log_exception('写入六面代理权威映射失败', e)
      false
    end

    def soft_visual_proxy_registry_record(model_id, root = soft_library_root)
      id = model_id.to_s.strip
      return nil if id.empty?
      entry = soft_visual_proxy_registry_entry_path(id, root)
      return nil if entry.to_s.empty?
      @soft_visual_proxy_registry_entry_cache ||= {}
      cache_key = [normalize_soft_library_key(root), id]
      cached = @soft_visual_proxy_registry_entry_cache[cache_key]
      now = monotonic_time
      # 同一会话短窗口直接复用已验证映射。旧版每次切换每一款都访问 NAS 做 stat，
      # 几个家具也会被 SMB metadata 延迟放大。30 秒后才重新核对文件签名。
      if cached && cached[:data].is_a?(Hash) &&
         (now - cached[:checked_at].to_f) <= SOFT_VISUAL_PROXY_REGISTRY_CACHE_TTL
        record = cached[:data]
        signature = cached[:signature].to_s
      else
        signature = fast_file_signature(entry).to_s
        record = if cached && cached[:signature].to_s == signature && !signature.empty?
                   cached[:data]
                 elsif File.file?(entry)
                   JSON.parse(File.read(entry, mode: 'r:UTF-8')) rescue nil
                 end
        if record.is_a?(Hash)
          @soft_visual_proxy_registry_entry_cache[cache_key] = {
            signature: signature, data: record, checked_at: now
          }
        end
      end

      # 首次升级到 v0.13.5.19 时，v0.13.5.17/18 已经生成的六面代理还只记录在旧索引里。
      # 这里一次性认领并写成 model_id 独立映射。
      unless record.is_a?(Hash)
        index = read_soft_library_index(root)
        matched_path = nil
        matched = nil
        Hash(index['models']).each do |path, candidate|
          next unless candidate.is_a?(Hash) && candidate['model_id'].to_s == id
          next unless candidate['proxy_kind'].to_s == SOFT_VISUAL_PROXY_KIND
          proxy = candidate['proxy_path'].to_s
          proxy = FastPath.expand(candidate['proxy_relative_path'].to_s, root) if proxy.empty? && !candidate['proxy_relative_path'].to_s.empty?
          next unless File.file?(proxy) && File.size(proxy).to_i.positive?
          matched_path = path.to_s
          matched = candidate.dup
          matched['proxy_path'] = proxy
          break
        end
        if matched
          bounds_signature = soft_bounds_values_valid?(matched['bounds_values']) ? soft_bounds_signature_from_values(matched['bounds_values']) : ''
          register_soft_visual_proxy!(id, matched['name'].to_s, matched_path, matched['proxy_path'], matched['proxy_source_signature'].to_s, bounds_signature, root)
          signature = fast_file_signature(entry).to_s
          record = JSON.parse(File.read(entry, mode: 'r:UTF-8')) rescue nil
          @soft_visual_proxy_registry_entry_cache[cache_key] = { signature: signature, data: record, checked_at: monotonic_time } if record.is_a?(Hash)
        end
      end

      return nil unless record.is_a?(Hash)
      path = record['proxy_path'].to_s
      path = FastPath.expand(record['proxy_relative_path'].to_s, root) if path.empty? && !record['proxy_relative_path'].to_s.empty?
      return nil unless File.file?(path) && File.size(path).to_i.positive?
      result = record.dup
      result['proxy_path'] = FastPath.expand(path)
      result
    rescue StandardError
      nil
    end

    def strip_unsafe_soft_proxy_metadata(metadata, reason = '')
      data = metadata.is_a?(Hash) ? metadata.dup : {}
      %w[proxy_path proxy_relative_path proxy_kind proxy_visual_version proxy_auto_generated proxy_source_signature proxy_render_mode proxy_model_id proxy_name].each do |field|
        data.delete(field)
      end
      data.delete('proxy_registry_authoritative')
      data['proxy_identity_rejected'] = true
      data['proxy_identity_reject_reason'] = reason.to_s
      data
    rescue StandardError
      {}
    end

    def log_soft_proxy_identity_rejection_once(model_id, source_path, reason)
      @soft_proxy_identity_rejection_logs ||= {}
      key = [model_id.to_s, normalize_soft_library_key(source_path), reason.to_s].join('|')
      return false if @soft_proxy_identity_rejection_logs[key]
      @soft_proxy_identity_rejection_logs[key] = true
      log("拒绝不匹配的家具代理：model_id=#{model_id} / #{File.basename(source_path.to_s)} / #{reason}")
      true
    rescue StandardError
      false
    end

    def sanitize_soft_proxy_metadata_for_source(metadata, model_id = '')
      data = metadata.is_a?(Hash) ? metadata.dup : {}
      source_path = data['source_path'].to_s
      source_path = data['path'].to_s if source_path.empty?
      expected_signature = data['bounds_source_signature'].to_s
      proxy_signature = data['proxy_source_signature'].to_s
      if !expected_signature.empty? && !proxy_signature.empty? && expected_signature != proxy_signature
        reason = '代理源签名与当前真模型不一致'
        log_soft_proxy_identity_rejection_once(model_id, source_path, reason)
        return strip_unsafe_soft_proxy_metadata(data, reason)
      end
      data
    rescue StandardError
      strip_unsafe_soft_proxy_metadata(metadata, '代理身份校验异常')
    end

    # 模型索引里的旧 proxy_path 不再是唯一依据。权威映射必须同时属于当前源模型；
    # model_id 碰撞或源 SKP 更新后留下的旧代理都只能失效，不能被拉伸后继续冒充。
    def overlay_authoritative_visual_proxy_metadata(metadata, model_id, root = soft_library_root)
      data = sanitize_soft_proxy_metadata_for_source(metadata, model_id)
      id = model_id.to_s.strip
      id = data['model_id'].to_s.strip if id.empty?
      # 平面图片模型明确采用“原组件即代理”。即使旧版本的权威代理表中还残留
      # 同 model_id 的六面代理，也不能在读取目录时重新覆盖这个决定。
      return data if soft_metadata_planar_reference?(data)
      record = soft_visual_proxy_registry_record(id, root)
      return data unless record
      source_path = data['source_path'].to_s
      source_path = data['path'].to_s if source_path.empty?
      expected_signature = data['bounds_source_signature'].to_s
      record_source = record['source_path'].to_s
      record_signature = record['proxy_source_signature'].to_s
      signature_conflict = !expected_signature.empty? && !record_signature.empty? && expected_signature != record_signature
      path_conflict = !source_path.empty? && !record_source.empty? && !same_file_path?(source_path, record_source)
      if signature_conflict || (expected_signature.empty? && path_conflict)
        reason = signature_conflict ? '权威代理签名属于另一份真模型' : '权威代理路径属于另一份真模型'
        log_soft_proxy_identity_rejection_once(id, source_path, reason)
        # 精确 source_path 对应的普通索引可能已经有一份正确代理。此时只忽略冲突的
        # model_id 权威映射，保留前面已通过源签名校验的路径级元数据。
        data['proxy_registry_rejected'] = true
        data['proxy_registry_reject_reason'] = reason
        return data
      end
      %w[proxy_path proxy_relative_path proxy_kind proxy_visual_version proxy_auto_generated proxy_source_signature proxy_render_mode].each do |field|
        data[field] = record[field] if record.key?(field)
      end
      data['proxy_model_id'] = "visual-#{id}"
      data['proxy_name'] = "六面可视代理｜#{record['model_name']}"
      data['proxy_registry_authoritative'] = true
      data
    rescue StandardError
      metadata.is_a?(Hash) ? metadata : {}
    end

    def soft_visual_proxy_current?(metadata, source_path, root = soft_library_root)
      return false unless metadata.is_a?(Hash) && File.file?(source_path.to_s)
      return false unless metadata['proxy_kind'].to_s == SOFT_VISUAL_PROXY_KIND
      return false unless metadata['proxy_visual_version'].to_i == SOFT_VISUAL_PROXY_VERSION
      proxy_path = metadata['proxy_path'].to_s
      if proxy_path.empty? && !metadata['proxy_relative_path'].to_s.empty?
        proxy_path = FastPath.expand(metadata['proxy_relative_path'].to_s, root)
      end
      return false unless File.file?(proxy_path) && File.size(proxy_path).positive?
      stored = metadata['proxy_source_signature'].to_s
      current = soft_library_file_signature(source_path.to_s).to_s
      !stored.empty? && stored == current
    rescue StandardError
      false
    end

    # 只自动接管“没有自定义代理的旧白盒”以及本插件自己生成但已过期的六面代理。
    # 用户手工定义过 proxy_path 的轻量代理不自动覆盖，避免把明确的人工意图抹掉。
    def soft_visual_proxy_upgrade_candidate?(metadata, source_path, root = soft_library_root)
      return false unless metadata.is_a?(Hash) && File.file?(source_path.to_s)
      return false if soft_metadata_planar_reference?(metadata)
      return false if soft_visual_proxy_current?(metadata, source_path, root)
      proxy_path = metadata['proxy_path'].to_s
      if proxy_path.empty? && !metadata['proxy_relative_path'].to_s.empty?
        proxy_path = FastPath.expand(metadata['proxy_relative_path'].to_s, root)
      end
      return true if proxy_path.to_s.empty? || !File.file?(proxy_path)
      soft_visual_proxy_truthy?(metadata['proxy_auto_generated']) || metadata['proxy_kind'].to_s == SOFT_VISUAL_PROXY_KIND
    rescue StandardError
      false
    end

    def soft_visual_proxy_target_path(model_id, model_name, metadata = {}, root = soft_library_root)
      existing = metadata.is_a?(Hash) ? metadata['proxy_path'].to_s : ''
      if !existing.empty? && soft_visual_proxy_truthy?(metadata['proxy_auto_generated'])
        return FastPath.expand(existing)
      end
      basename = safe_soft_library_filename(model_name.to_s.empty? ? model_id.to_s : model_name.to_s)
      File.join(soft_library_proxy_dir(root), "#{model_id}_#{basename}_六面代理.skp")
    end

    # v0.13.6.167：代理批处理可复用 job 启动时已经读取的模型索引，并把共享索引
    # 延迟到整批结束时只写一次。每款独立 sidecar + model_id 权威映射仍立即原子写入，
    # 因此即使主进程中途退出，已经完成的代理仍能由权威映射找回；只减少共享 JSON 的
    # 反复 read/backup/write/verify，尤其降低 NAS/SMB 上的 metadata 往返。
    def update_soft_visual_proxy_metadata!(source_path, metadata, proxy_path, model_id, model_name, source_signature, root = soft_library_root, index: nil, write_index: true, persist_cache: nil)
      persist_cache = write_index if persist_cache.nil?
      index = read_soft_library_index(root) unless index.is_a?(Hash)
      index['schema'] = SOFT_LIBRARY_SCHEMA
      index['models'] = {} unless index['models'].is_a?(Hash)
      source_key = normalize_soft_library_key(source_path)
      current = default_soft_model_metadata(source_path)
      current.merge!(index['models'][source_key]) if index['models'][source_key].is_a?(Hash)
      current.merge!(metadata) if metadata.is_a?(Hash)
      timestamp = Time.now.strftime('%Y-%m-%d %H:%M:%S')
      current['model_id'] = model_id.to_s unless model_id.to_s.empty?
      current['name'] = model_name.to_s unless model_name.to_s.empty?
      current['proxy_model_id'] = "visual-#{model_id}"
      current['proxy_path'] = FastPath.expand(proxy_path)
      current['proxy_relative_path'] = begin
        Pathname.new(current['proxy_path']).relative_path_from(Pathname.new(root)).to_s.tr('\\', '/')
      rescue StandardError
        ''
      end
      current['proxy_name'] = "六面可视代理｜#{model_name}"
      current['proxy_kind'] = SOFT_VISUAL_PROXY_KIND
      current['proxy_visual_version'] = SOFT_VISUAL_PROXY_VERSION
      current['proxy_auto_generated'] = true
      current['proxy_source_signature'] = source_signature.to_s
      current['proxy_render_mode'] = 'image_planes_dual_matte'
      current['proxy_updated_at'] = timestamp
      current['updated_at'] = timestamp
      index['models'][source_key] = current
      write_soft_library_index!(index, root) if write_index
      if current['organized'] || normalize_soft_library_key(source_path).start_with?(normalize_soft_library_key(soft_library_organized_dir(root)))
        write_json_atomic(soft_model_sidecar_path(source_path), current.merge('schema' => SOFT_LIBRARY_SCHEMA))
      end
      update_soft_library_cache_item!(source_path, current, persist: persist_cache != false)
      bounds_signature = current['proxy_full_bounds_signature'].to_s
      if bounds_signature.empty? && soft_bounds_values_valid?(current['bounds_values'])
        bounds_signature = soft_bounds_signature_from_values(current['bounds_values'])
      end
      unless register_soft_visual_proxy!(model_id, model_name, source_path, proxy_path, source_signature, bounds_signature, root)
        raise '代理文件已写入，但权威映射登记失败；待处理状态保留，请重试。'
      end
      current
    end

    def flush_soft_visual_proxy_job_index!(job)
      return true unless job.is_a?(Hash) && job[:index_dirty] == true
      index = job[:index]
      root = job[:root].to_s.empty? ? soft_library_root : job[:root].to_s
      return false unless index.is_a?(Hash) && !root.empty?
      write_soft_library_index!(
        index, root,
        base_snapshot: job[:index_base_snapshot],
        trusted_input: true
      )
      job[:index_dirty] = false
      true
    rescue StandardError => e
      # 单款 model_id 权威映射和 sidecar 已经先行原子写入，因此共享索引批量回写失败
      # 不会让已生成代理失联；保持严格三方合并冲突策略，不用“强制覆盖最新索引”兜底。
      log_exception('批量回写六面代理模型索引失败', e)
      job[:index_flush_error] = e.message.to_s if job.is_a?(Hash)
      false
    end

    # v0.13.6.168：批量索引只写一次后，瞬时 SMB/文件锁失败不能让成功款式长期只存在 sidecar。
    # 重试仍使用最初读取基线 + 三方合并，不会用旧快照强行覆盖别人随后写入的字段。
    def schedule_soft_visual_proxy_index_flush_retry!(job, attempt: 1)
      return false unless job.is_a?(Hash) && job[:index].is_a?(Hash)
      delays = [0.8, 2.0, 5.0]
      index = json_deep_copy(job[:index])
      base = json_deep_copy(job[:index_base_snapshot]) if job[:index_base_snapshot].is_a?(Hash)
      root = job[:root].to_s.empty? ? soft_library_root : job[:root].to_s
      return false if root.empty? || !base.is_a?(Hash)
      current_attempt = [[attempt.to_i, 1].max, delays.length].min
      runtime_start_timer(delays[current_attempt - 1], false, label: 'soft:proxy_index_flush_retry', key: "soft:proxy_index_flush_retry:#{normalize_soft_library_key(root)}") do
        begin
          write_soft_library_index!(index, root, base_snapshot: base, trusted_input: true)
          log("六面代理批量索引自动重试成功：第 #{current_attempt} 次 / #{File.basename(root)}")
        rescue StandardError => e
          log_exception("六面代理批量索引自动重试失败（第 #{current_attempt} 次）", e)
          if current_attempt < delays.length
            retry_job = { index: index, index_base_snapshot: base, root: root }
            schedule_soft_visual_proxy_index_flush_retry!(retry_job, attempt: current_attempt + 1)
          else
            show_status('六面代理文件已生成，但共享模型索引暂时无法回写；sidecar/权威映射仍有效，下次模型库刷新可继续恢复。', 'warning')
          end
        end
      end
      true
    rescue StandardError => e
      log_exception('安排六面代理批量索引重试失败', e)
      false
    end

    def update_soft_planar_reference_metadata!(source_path, metadata, model_id, model_name, bounds_values, root = soft_library_root)
      index = read_soft_library_index(root)
      source_key = normalize_soft_library_key(source_path)
      current = default_soft_model_metadata(source_path)
      current.merge!(index['models'][source_key]) if index['models'][source_key].is_a?(Hash)
      current.merge!(metadata) if metadata.is_a?(Hash)
      timestamp = Time.now.strftime('%Y-%m-%d %H:%M:%S')
      current['model_id'] = model_id.to_s unless model_id.to_s.empty?
      current['name'] = model_name.to_s unless model_name.to_s.empty?
      current['bounds_values'] = Array(bounds_values).map(&:to_f)
      current['bounds_source_signature'] = fast_file_signature(source_path).to_s
      current['planar_reference'] = true
      current['proxy_passthrough'] = true
      current['proxy_kind'] = SOFT_PLANAR_PROXY_KIND
      current['proxy_model_id'] = current['model_id'].to_s
      current['proxy_path'] = ''
      current['proxy_relative_path'] = ''
      current['proxy_name'] = '原平面组件（直接作为代理）'
      current['proxy_visual_version'] = 0
      current['proxy_auto_generated'] = false
      current['proxy_source_signature'] = current['bounds_source_signature']
      current['proxy_render_mode'] = 'native_passthrough'
      current['proxy_updated_at'] = timestamp
      current['updated_at'] = timestamp
      index['models'][source_key] = current
      write_soft_library_index!(index, root)
      if current['organized'] || normalize_soft_library_key(source_path).start_with?(normalize_soft_library_key(soft_library_organized_dir(root)))
        write_json_atomic(soft_model_sidecar_path(source_path), current.merge('schema' => SOFT_LIBRARY_SCHEMA))
      end
      update_soft_library_cache_item!(source_path, current)
      current
    rescue StandardError => e
      log_exception("标记平面图片指代模型失败：#{source_path}", e)
      metadata.is_a?(Hash) ? metadata : {}
    end

    # v0.13.6.28：模型库中的真模型一旦写回，旧六视图代理在当前 SketchUp 会话里
    # 仍可能被 session cache / loaded-definition index 直接复用。这里按 model_id 精准
    # 失效对应代理缓存；只做浅层 Definition 属性检查，不递归实体树，也不删除 Definition。
    def invalidate_soft_visual_proxy_runtime_for_model!(model_id, model = Sketchup.active_model, source_path: '', mark_loaded_stale: false)
      return false unless model
      target_id = model_id.to_s.strip
      source_key = normalize_soft_library_key(source_path)
      key = model.object_id

      if @soft_session_visual_proxy_caches && (cache = @soft_session_visual_proxy_caches[key])
        cache.delete_if do |_instance_id, record|
          next true unless record.is_a?(Hash)
          same_id = !target_id.empty? && record[:model_id].to_s == target_id
          same_source = !source_key.empty? && record[:source_path].to_s == source_key
          same_id || same_source
        end
      end
      @soft_loaded_visual_proxy_indexes&.delete(key)

      [@soft_proxy_definition_caches, @soft_custom_proxy_definition_caches].compact.each do |root_cache|
        cache = root_cache[key] rescue nil
        next unless cache.respond_to?(:delete_if)
        cache.delete_if do |_cache_key, definition|
          next true unless definition && definition.valid?
          did = definition.get_attribute(SOFT_MODEL_DICT, 'model_id', '').to_s rescue ''
          raw_source = definition.get_attribute(SOFT_MODEL_DICT, 'source_path', '').to_s rescue ''
          same_id = !target_id.empty? && did == target_id
          same_source = !source_key.empty? && normalize_soft_library_key(raw_source) == source_key
          same_id || same_source
        end
      end

      if @soft_representation_pair_caches && (cache = @soft_representation_pair_caches[key])
        cache.delete_if do |_cache_key, pair|
          proxy_definition = pair.is_a?(Hash) ? pair[:proxy_definition] : nil
          next false unless proxy_definition && proxy_definition.valid?
          did = proxy_definition.get_attribute(SOFT_MODEL_DICT, 'model_id', '').to_s rescue ''
          raw_source = proxy_definition.get_attribute(SOFT_MODEL_DICT, 'source_path', '').to_s rescue ''
          (!target_id.empty? && did == target_id) || (!source_key.empty? && normalize_soft_library_key(raw_source) == source_key)
        end
      end

      if mark_loaded_stale
        model.definitions.each do |definition|
          begin
            next unless definition && definition.valid? && soft_six_view_proxy_definition?(definition)
            did = definition.get_attribute(SOFT_MODEL_DICT, 'model_id', '').to_s rescue ''
            raw_source = definition.get_attribute(SOFT_MODEL_DICT, 'source_path', '').to_s rescue ''
            next unless (!target_id.empty? && did == target_id) || (!source_key.empty? && normalize_soft_library_key(raw_source) == source_key)
            soft_set_attribute_if_changed(definition, SOFT_MODEL_DICT, 'proxy_stale', true)
          rescue StandardError
            next
          end
        end
      end
      true
    rescue StandardError => e
      log_exception('失效六面代理运行时缓存失败', e)
      false
    end

    def soft_visual_proxy_definition_stale?(definition)
      return true unless definition && definition.valid?
      definition.get_attribute(SOFT_MODEL_DICT, 'proxy_stale', false) == true
    rescue StandardError
      false
    end

    # 更新一款家具时，除了本次明确选中的实例，还要同步当前正在编辑空间中
    # 已经以代理方式显示的同 model_id 实例。其它未编辑空间不主动改动，避免越过
    # 协作锁边界；它们下次进入/切代理时会读取新的权威代理映射。
    # 185：仅跳过身份明确且属于另一款的正常家具；不是身份认证/提交许可。
    # 冷缓存、旧白盒、ID/路径冲突都回退原解析，显式选择也永不走这个排除器。
    def soft_visual_proxy_unrelated_identity185?(instance, target_id)
      return false if soft_legacy_proxy_entity?(instance)
      definition = instance.definition
      own_id = instance.get_attribute(SOFT_MODEL_DICT, 'model_id', '').to_s.strip
      def_id = definition.get_attribute(SOFT_MODEL_DICT, 'model_id', '').to_s.strip
      return false if !own_id.empty? && !def_id.empty? && own_id != def_id
      id = own_id.empty? ? def_id : own_id
      return false unless soft_stable_model_id?(id) && id != target_id.to_s
      own_path = instance.get_attribute(SOFT_MODEL_DICT, 'source_path', '').to_s
      def_path = definition.get_attribute(SOFT_MODEL_DICT, 'source_path', '').to_s
      return false if !own_path.empty? && !def_path.empty? && !same_file_path?(own_path, def_path)
      source = own_path.empty? ? def_path : own_path
      return false if source.empty?
      cache = @soft_library_cache
      return false unless cache.is_a?(Hash) && cache[:root].to_s == soft_library_root.to_s
      return false unless soft_library_id_conflict_items(id, cache).empty?
      row = cache[:by_id].is_a?(Hash) ? cache[:by_id][id] : nil
      return false unless row.is_a?(Hash) && row['id'].to_s == id && same_file_path?(row['path'], source)
      wanted = cache[:by_id].is_a?(Hash) ? cache[:by_id][target_id.to_s] : nil
      return false if wanted.is_a?(Hash) && same_file_path?(wanted['path'], source)
      true
    rescue StandardError
      false
    end

    def soft_visual_proxy_sync_targets_for_model(model_id, model = Sketchup.active_model, scope_space_id: '', explicit_instances: nil)
      target_id = model_id.to_s.strip
      targets = Array(explicit_instances).select { |instance| instance && instance.valid? }
      return targets.uniq if target_id.empty? || !model || scope_space_id.to_s.empty?

      started = monotonic_time
      scanned = skipped = resolved = 0
      explicit_ids = targets.each_with_object({}) { |instance, memo| memo[instance.object_id] = true }
      state = load_state(model)
      space = space_model_record(state, scope_space_id.to_s)
      space_entity = space ? space_model_entity(space['id'], model) : nil
      if space_entity && space_entity.valid?
        soft_instances_for_space(space_entity, model, force: true).each do |instance|
          next unless instance && instance.valid?
          scanned += 1
          # 显式目标已由调用者逐一解析；其它真模本来就不属于本次代理同步范围。
          if explicit_ids[instance.object_id] || soft_instance_representation(instance) != 'proxy' ||
             soft_visual_proxy_unrelated_identity185?(instance, target_id)
            skipped += 1
            next
          end
          resolved += 1
          info = resolved_soft_instance_metadata(instance, model)
          next unless info['model_id'].to_s == target_id
          targets << instance
        rescue StandardError
          next
        end
      end
      result = targets.uniq
      log("性能185：代理目标收集 #{elapsed_ms(started)}ms / 扫描#{scanned} / 排除或已确认#{skipped} / 深解析#{resolved} / 目标#{result.length}")
      result
    rescue StandardError => e
      log_exception('收集同款六面代理同步实例失败', e)
      Array(explicit_instances).select { |instance| instance && instance.valid? }.uniq
    end

    def replace_project_legacy_soft_proxies_for_model!(model_id, model = Sketchup.active_model, scope_space_id: '', instances: nil)
      target_id = model_id.to_s
      return 0 if target_id.empty? || !model

      resolves_to_target = lambda do |instance|
        next false unless instance && instance.valid?
        info = resolved_soft_instance_metadata(instance, model)
        info['model_id'].to_s == target_id
      rescue StandardError
        false
      end

      explicit = Array(instances).select { |instance| instance && instance.valid? }
      explicit = explicit.select { |instance| resolves_to_target.call(instance) }
      # v0.13.6.28：显式实例不再屏蔽 scope。更新一款家具时，把本次更新实例与
      # 当前编辑空间中正在显示的同 model_id 代理合并，确保同款六面体一起刷新。
      # 其它空间不主动改动，维持协作作用域边界。
      targets = soft_visual_proxy_sync_targets_for_model(
        target_id, model, scope_space_id: scope_space_id.to_s, explicit_instances: explicit
      )
      # v0.13.5.19：绝不再默认遍历并修改整个项目的其它空间。没有明确选择或空间作用域，
      # 只更新模型库的权威六面代理文件；各空间在下一次载入/切代理时按 model_id 自动映射。
      return 0 if targets.empty?

      # 旧白盒若属于“归正轴之前”的坐标系，不能直接拿当前六面代理做 preserving_box，
      # 否则 XYZ 会按旧顺序硬套到新代理。先把能明确识别的旧白盒无损迁到当前真模型
      # 坐标，再走普通 full -> six-face；无法明确判断的对象保留原白盒，不冒险自动改坏。
      legacy_candidates = targets.select do |instance|
        definition = instance.definition rescue nil
        definition && !definition.get_attribute(SOFT_MODEL_DICT, 'fallback_proxy_for', '').to_s.empty?
      end
      safe_targets = targets.dup
      unless legacy_candidates.empty?
        item = soft_library_item(target_id, force: false) rescue nil
        if item && File.file?(item['path'].to_s)
          full_definition = load_soft_library_definition(item, model)
          if full_definition && full_definition.valid?
            stamp_soft_library_definition!(full_definition, item)
            legacy_candidates.each do |instance|
              relation = soft_fallback_proxy_axis_relation(instance.definition, full_definition)
              case relation[:kind]
              when :legacy
                replace_legacy_fallback_proxy_with_canonical_full!(instance, full_definition, relation)
                stamp_soft_library_instance!(instance, item, model, stamp_definition: false, bump_registry: false)
                soft_set_attribute_if_changed(instance, SOFT_MODEL_DICT, 'representation', 'full')
                instance.delete_attribute(SOFT_MODEL_DICT, 'proxy_source_path') rescue nil
              when :ambiguous
                safe_targets.delete(instance)
                log("旧白盒六面迁移已跳过（轴关系不明确，避免破坏）：#{item['name']} / instance=#{instance.object_id}")
              else
                # canonical / not_fallback：可由普通代理替换逻辑按外包盒处理。
              end
            end
            bump_soft_instance_registry_revision(model)
          end
        end
      end

      return 0 if safe_targets.empty?
      # 权威六面代理刚刚重建时绝不能走“会话原代理快路径”，否则真模型实例会
      # 被旧 session cache 直接切回旧六面体。先失效同 model_id 的运行时代理缓存，
      # 再强制从最新权威映射 / 最新代理文件解析。
      source_path = ''
      begin
        source_path = resolved_soft_instance_metadata(safe_targets.first, model)['source_path'].to_s if safe_targets.first
      rescue StandardError
        source_path = ''
      end
      invalidate_soft_visual_proxy_runtime_for_model!(target_id, model, source_path: source_path, mark_loaded_stale: false)
      swaps = apply_space_soft_proxies!(nil, model, instances: safe_targets, strict: false, prefer_session: false, verified_commit: true)
      changed = Array(swaps).length
      safe_targets.each do |instance|
        remember_soft_session_visual_proxy!(instance, model) if instance && instance.valid? && soft_instance_proxy_ready?(instance)
      end
      schedule_soft_managed_definition_cleanup(model, delay: 1.2) if changed.positive?
      model.active_view.invalidate rescue nil if changed.positive?
      log("六面代理权威同步：model_id=#{target_id} / 当前空间目标 #{safe_targets.length} / 实际替换 #{changed}")
      changed
    rescue StandardError => e
      log_exception("替换当前作用域旧白盒代理失败：#{target_id}", e)
      0
    end

    def generate_soft_visual_proxy_for_candidate!(candidate, model = Sketchup.active_model)
      root = soft_library_root
      if candidate[:reuse_existing]
        metadata = overlay_authoritative_visual_proxy_metadata(candidate[:metadata], candidate[:model_id], root)
        path = metadata['proxy_path'].to_s
        raise '权威六面代理文件不存在。' unless File.file?(path) && File.size(path).to_i.positive?
        replaced = replace_project_legacy_soft_proxies_for_model!(
          candidate[:model_id], model,
          scope_space_id: candidate[:scope_space_id].to_s,
          instances: Array(candidate[:replace_instances])
        )
        return { path: path, metadata: metadata, replaced: replaced, reused: true }
      end
      ensure_soft_library_structure!(root)
      source_path = FastPath.expand(candidate[:source_path].to_s)
      raise '源模型文件不存在，无法生成六面代理。' unless File.file?(source_path)
      model_id = candidate[:model_id].to_s
      model_name = candidate[:model_name].to_s
      metadata = candidate[:metadata].is_a?(Hash) ? candidate[:metadata].dup : {}
      source_signature = soft_library_file_signature(source_path).to_s
      target = soft_visual_proxy_target_path(model_id, model_name, metadata, root)

      original_path = Array(model.active_path)
      original_selection = model.selection.to_a
      original_view = capture_active_view_state(model)
      original_definition_ids = model.definitions.to_a.map(&:object_id)
      layer_visibility = model.layers.to_a.map { |layer| [layer, layer.visible?] }
      existing_root_visibility = nil
      source_instance = nil
      source_definition = nil
      proxy_definition = nil
      images = {}
      operation_started = false
      interaction_started = false
      planar_reference = false
      planar_bounds_values = nil
      cache_dir = TEMP_VISUAL_PROXY_DIR

      begin
        begin_soft_heavy_interaction(:visual_proxy_capture)
        interaction_started = true
        model.start_operation("生成六面代理 #{model_name}", true, false, false)
        operation_started = true
        model.selection.clear
        model.active_path = nil if model.respond_to?(:active_path=)
        existing_root_visibility = model.entities.to_a.map { |entity| [entity, entity.hidden?] }
        existing_root_visibility.each { |entity, _hidden| entity.hidden = true if entity && entity.valid? && entity.respond_to?(:hidden=) }
        # 家具刚刚“写回模型库”时，优先使用本次更新事务里已经接管到当前模型的
        # 新 Definition 作为截图源。直接 definitions.load(source_path) 可能被 SketchUp
        # 依据组件内部 GUID 复用当前会话中的旧 Definition，形成“源 SKP/缩略图已更新，
        # 六面代理却仍拍到旧内容”的错位。只有没有可靠的本次 Definition 时才从文件载入。
        hinted_definition = candidate[:source_definition]
        source_definition = hinted_definition if hinted_definition && hinted_definition.valid?
        source_definition ||= load_definition_compat(model.definitions, source_path)
        raise '源模型定义载入失败，无法生成六面代理。' unless source_definition && source_definition.valid?
        source_instance = model.entities.add_instance(source_definition, identity_transformation)
        source_instance.hidden = false if source_instance.respond_to?(:hidden=)
        values = soft_definition_bounds_values(source_definition)
        raise '源模型没有有效几何外包盒，无法生成六面代理。' unless soft_bounds_values_valid?(values)
        planar_reference = soft_bounds_planar_reference?(values)
        planar_bounds_values = values if planar_reference
        mark_soft_planar_reference!(source_definition, true) if planar_reference
        unless planar_reference
          model.layers.each { |layer| layer.visible = true rescue nil }
          # 六面代理后台队列使用静默截图模式：临时相机/样式仅供 write_image，
          # 不强制刷新用户正在看的主视口。普通缩略图路径仍保留原来的 refresh。
          with_soft_bright_thumbnail_style(model, refresh_view: false) do
            capture_started = monotonic_time
            images = soft_visual_proxy_capture_six!(source_instance, values, model, cache_dir)
            log_slow_operation('六面代理六视图截图+透明抠图', capture_started, 120.0, model_name)
            proxy_definition = build_soft_visual_proxy_definition!(model, model_id, model_name, source_path, values, images, source_signature)
            proxy_write_started = monotonic_time
            write_soft_visual_proxy_definition_atomic!(proxy_definition, target)
            log_slow_operation('六面代理SKP写入模型库', proxy_write_started, 120.0, model_name)
          end
        end
      ensure
        existing_root_visibility&.each do |entity, hidden|
          entity.hidden = hidden if entity && entity.valid? && entity.respond_to?(:hidden=)
        rescue StandardError
          nil
        end
        begin
          model.active_path = (original_path.empty? ? nil : original_path) if model.respond_to?(:active_path=)
        rescue StandardError
          model.active_path = nil rescue nil
        end
        # 先恢复用户相机，再 abort 临时代理事务。某些 SketchUp 版本在 abort 时会
        # 触发一次原生重绘；这样即使发生重绘，也只会显示用户原视角。
        restore_active_view_state(original_view, model) if original_view
        model.abort_operation rescue nil if operation_started
        layer_visibility.each { |layer, visible| layer.visible = visible if layer } rescue nil
        model.selection.clear rescue nil
        original_selection.each { |entity| model.selection.add(entity) if entity && entity.valid? } rescue nil
        cleanup_soft_thumbnail_definitions!(model, original_definition_ids)
        Array(images.values).each { |file| File.delete(file) if File.file?(file) rescue nil }
        end_soft_heavy_interaction(:visual_proxy_capture) if interaction_started
      end

      if planar_reference
        updated = update_soft_planar_reference_metadata!(
          source_path, metadata, model_id, model_name, planar_bounds_values, root
        )
        replaced = replace_project_legacy_soft_proxies_for_model!(
          model_id, model,
          scope_space_id: candidate[:scope_space_id].to_s,
          instances: Array(candidate[:replace_instances])
        )
        log("平面图片指代模型跳过六面代理：#{model_name} / 原组件直接作为代理")
        return { path: source_path, metadata: updated, replaced: replaced, planar_reference: true }
      end

      raise '六面代理文件没有成功写入模型库。' unless File.file?(target) && File.size(target).positive?
      updated = update_soft_visual_proxy_metadata!(source_path, metadata, target, model_id, model_name, source_signature, root)
      replaced = replace_project_legacy_soft_proxies_for_model!(
        model_id, model,
        scope_space_id: candidate[:scope_space_id].to_s,
        instances: Array(candidate[:replace_instances])
      )
      { path: target, metadata: updated, replaced: replaced }
    rescue StandardError
      raise
    end


    end
  end
end
