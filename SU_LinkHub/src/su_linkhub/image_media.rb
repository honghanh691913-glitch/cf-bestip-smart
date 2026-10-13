# frozen_string_literal: true

# v0.13.6.188：图片媒体统一层（随 runtime.rb 一起 Kernel.load，热重载时整体刷新）。
#
# 一、真实格式识别与结构校验（实物图导入、Excel 导出共用）
#   旧版“严格校验”只认文件头，并要求 JPEG 最后两个字节必须是 FFD9、PNG 最后 12 字节
#   必须是 IEND。于是两类完全正常、资源管理器/浏览器都能显示的图片会被拒绝，导出时
#   也会静默缺图：
#     1) 结束标记之后带附加数据的原图：手机多图 MPF、动态照片、部分网站/聊天软件追加
#        的尾巴；
#     2) 扩展名是 .jpg、真实内容却是 WebP/AVIF/HEIC 的网络图片（网页“另存为”很常见）。
#   这里改为结构校验：JPEG 必须 SOI→SOF(尺寸)→SOS→EOI，PNG 必须 IHDR→IDAT→IEND；
#   结束标记后的尾随数据允许存在，原始字节保持不变。失败时给出“实际格式/具体原因”。
#
# 二、模型缩略图“显示适配”
#   SketchUp 原生/内嵌缩略图的取景并不可靠：抽样 159 张里约 8% 的吊灯、纸灯等物体只占
#   画面 3%~40%，或偏在一角、被画框裁切。清单格子里因此只剩一个点或一条线。
#   这里不修改源 SKP、不修改模型库原缩略图和缩略图索引，只按像素内容计算主体外包框，
#   生成“裁切居中”的显示用派生图（共享目录 缩略图/显示适配_v1/，团队复用）；网页与
#   Excel 统一使用派生图。分析只在空闲时逐张进行（每轮约 30ms），结论写入本机索引，
#   以后打开清单零成本；原缩略图一旦被重新生成（修改时间/大小变化）会自动重新适配。
module GavinTools
  module SULinkHubMultiSpace
    module Runtime
      IMAGE_MEDIA_PNG_SIGNATURE = "\x89PNG\r\n\x1A\n".b.freeze
      IMAGE_MEDIA_JPEG_SOI = "\xFF\xD8".b.freeze
      IMAGE_MEDIA_JPEG_EOI = "\xFF\xD9".b.freeze
      IMAGE_MEDIA_JPEG_SOF_MARKERS = [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF].freeze
      IMAGE_MEDIA_SCAN_BLOCK = 1024 * 1024
      IMAGE_MEDIA_INSPECT_MEMO_LIMIT = 4096
      IMAGE_MEDIA_FORMAT_LABELS = {
        'jpeg' => 'JPG', 'png' => 'PNG', 'webp' => 'WebP', 'avif' => 'AVIF', 'heic' => 'HEIC/HEIF',
        'gif' => 'GIF', 'bmp' => 'BMP', 'tiff' => 'TIFF', 'psd' => 'PSD', 'jxl' => 'JPEG XL',
        'ico' => 'ICO', 'isobmff' => 'HEIF/AVIF 容器', 'svg' => 'SVG 矢量图', 'unknown' => '未知格式'
      }.freeze

      SOFT_THUMBNAIL_FIT_DIR = '显示适配_v1'
      SOFT_THUMBNAIL_FIT_INDEX_SCHEMA = 1
      SOFT_THUMBNAIL_FIT_INDEX_LIMIT = 20_000
      SOFT_THUMBNAIL_FIT_TICK_BUDGET = 0.030
      # 主体（含留白）已占画框 86% 以上视为取景正常，不生成派生图。
      SOFT_THUMBNAIL_FIT_OK_RATIO = 0.86
      SOFT_THUMBNAIL_FIT_MARGIN = 0.05
      SOFT_THUMBNAIL_FIT_LOW_SIDE = 40
      SOFT_THUMBNAIL_FIT_NAME_PATTERN = /\A[0-9a-f]{20}\.png\z/i.freeze

      # 带错误码的实物图导入异常：网页据此决定“浏览器重编码后重试”还是直接提示原因。
      class PhotoImportError < StandardError
        attr_reader :code

        def initialize(message, code = 'invalid')
          super(message)
          @code = code.to_s
        end
      end

      # ---------------------------------------------------------------------
      # 一、格式识别与结构校验
      # ---------------------------------------------------------------------

      def image_media_sniff_head(head)
        bytes = head.to_s.b
        return 'unknown' if bytes.bytesize < 4
        return 'png' if bytes.start_with?(IMAGE_MEDIA_PNG_SIGNATURE)
        return 'jpeg' if bytes.start_with?(IMAGE_MEDIA_JPEG_SOI)
        return 'gif' if bytes.start_with?('GIF87a'.b, 'GIF89a'.b)
        return 'webp' if bytes.byteslice(0, 4) == 'RIFF'.b && bytes.byteslice(8, 4) == 'WEBP'.b
        if bytes.byteslice(4, 4) == 'ftyp'.b
          brands = bytes.byteslice(8, 32).to_s
          major = brands.byteslice(0, 4).to_s
          return 'avif' if %w[avif avis].include?(major) || brands.include?('avif')
          heif_brands = %w[heic heix hevc hevx heim heis hevm hevs mif1 msf1]
          return 'heic' if heif_brands.include?(major) || brands.include?('heic') || brands.include?('mif1')
          return 'isobmff'
        end
        return 'bmp' if bytes.start_with?('BM'.b)
        return 'tiff' if bytes.start_with?("II*\x00".b, "MM\x00*".b)
        return 'psd' if bytes.start_with?('8BPS'.b)
        return 'jxl' if bytes.start_with?("\xFF\x0A".b) || bytes.byteslice(4, 4) == 'JXL '.b
        return 'ico' if bytes.start_with?("\x00\x00\x01\x00".b)
        return 'svg' if bytes.byteslice(0, 64).to_s.match?(/<svg|<\?xml/in)
        'unknown'
      rescue StandardError
        'unknown'
      end

      def image_media_format_label(format)
        IMAGE_MEDIA_FORMAT_LABELS[format.to_s] || format.to_s.upcase
      end

      # 顺序解析 JPEG 段直到第一个 SOS。返回 { width:, height:, scan_offset: }。
      def image_media_jpeg_layout(file)
        file.rewind
        return nil unless file.read(2).to_s.b == IMAGE_MEDIA_JPEG_SOI
        width = nil
        height = nil
        loop do
          byte = file.read(1)
          return nil unless byte
          next unless byte.getbyte(0) == 0xFF
          marker = nil
          loop do
            marker_byte = file.read(1)
            return nil unless marker_byte
            marker = marker_byte.getbyte(0)
            break unless marker == 0xFF
          end
          next if marker.zero? || marker == 0x01 || marker == 0xD8 || (0xD0..0xD7).cover?(marker)
          return nil if marker == 0xD9
          length_raw = file.read(2)
          return nil unless length_raw && length_raw.bytesize == 2
          length = length_raw.unpack1('n').to_i
          return nil if length < 2
          if IMAGE_MEDIA_JPEG_SOF_MARKERS.include?(marker)
            data = file.read(5)
            return nil unless data && data.bytesize == 5
            _precision, height, width = data.unpack('Cnn')
            file.seek(length - 7, IO::SEEK_CUR) if length > 7
          elsif marker == 0xDA
            return nil unless width.to_i.positive? && height.to_i.positive?
            file.seek(length - 2, IO::SEEK_CUR)
            return { width: width.to_i, height: height.to_i, scan_offset: file.pos }
          else
            file.seek(length - 2, IO::SEEK_CUR)
          end
        end
      end

      # 熵编码数据中的 0xFF 一定以 00/RSTn 填充，FFD9 只可能是真正的 EOI。
      def image_media_jpeg_eoi_offset(file, from)
        file.seek(from, IO::SEEK_SET)
        carry = ''.b
        offset = from
        while (block = file.read(IMAGE_MEDIA_SCAN_BLOCK))
          chunk = carry + block.b
          index = chunk.index(IMAGE_MEDIA_JPEG_EOI)
          return offset - carry.bytesize + index if index
          carry = chunk.byteslice(-1, 1)
          offset += block.bytesize
        end
        nil
      end

      def image_media_jpeg_report(path, size)
        File.open(path, 'rb') do |file|
          layout = image_media_jpeg_layout(file)
          return { ok: false, format: 'jpeg', reason: 'damaged' } unless layout
          base = { format: 'jpeg', width: layout[:width], height: layout[:height] }
          file.seek(-2, IO::SEEK_END)
          if file.read(2).to_s.b == IMAGE_MEDIA_JPEG_EOI
            return base.merge(ok: true, extension: 'jpg', content_type: 'image/jpeg', trailing: 0)
          end
          eoi = image_media_jpeg_eoi_offset(file, layout[:scan_offset])
          return base.merge(ok: false, reason: 'truncated') unless eoi
          base.merge(ok: true, extension: 'jpg', content_type: 'image/jpeg', trailing: size - (eoi + 2))
        end
      end

      def image_media_png_report(path, size)
        File.open(path, 'rb') do |file|
          head = file.read(33).to_s.b
          return { ok: false, format: 'png', reason: 'damaged' } unless head.bytesize == 33 && head.start_with?(IMAGE_MEDIA_PNG_SIGNATURE)
          length, type = head.byteslice(8, 8).unpack('Na4')
          return { ok: false, format: 'png', reason: 'damaged' } unless type == 'IHDR' && length == 13
          width, height = head.byteslice(16, 8).unpack('N2')
          return { ok: false, format: 'png', reason: 'damaged' } unless width.to_i.positive? && height.to_i.positive?
          base = { format: 'png', width: width.to_i, height: height.to_i }
          if size >= 45
            file.seek(-12, IO::SEEK_END)
            tail = file.read(12).to_s.b
            return base.merge(ok: true, extension: 'png', content_type: 'image/png', trailing: 0) if tail.byteslice(4, 4) == 'IEND'.b
          end
          position = 33
          seen_idat = false
          while position + 12 <= size
            file.seek(position, IO::SEEK_SET)
            header = file.read(8).to_s.b
            break unless header.bytesize == 8
            chunk_length, chunk_type = header.unpack('Na4')
            break if chunk_length > 0x7FFFFFFF
            seen_idat ||= chunk_type == 'IDAT'
            if chunk_type == 'IEND'
              return base.merge(ok: false, reason: 'damaged') unless seen_idat
              return base.merge(ok: true, extension: 'png', content_type: 'image/png', trailing: size - (position + 12 + chunk_length))
            end
            position += 12 + chunk_length
          end
          base.merge(ok: false, reason: 'truncated')
        end
      end

      # 返回冻结的检测报告：{ ok:, format:, reason:, width:, height:, extension:, content_type:, trailing:, bytes: }
      # 以 路径+大小+修改时间 记忆，导出时同一张图被多处引用也只读一次 NAS。
      def image_media_inspect(path)
        text = path.to_s
        return nil if text.empty?
        stat = File.stat(text)
        return nil unless stat.file? && stat.size.positive?
        memo_key = "#{FastPath.expand(text)}|#{stat.size}|#{stat.mtime.to_f}"
        memo = (@image_media_inspect_memo ||= {})
        cached = memo[memo_key]
        return cached if cached
        head = File.binread(text, 64).to_s.b
        format = image_media_sniff_head(head)
        report = case format
                 when 'jpeg' then image_media_jpeg_report(text, stat.size)
                 when 'png' then image_media_png_report(text, stat.size)
                 else { ok: false, format: format, reason: 'unsupported_format' }
                 end
        report = report.merge(bytes: stat.size)
        memo.clear if memo.length >= IMAGE_MEDIA_INSPECT_MEMO_LIMIT
        memo[memo_key] = report.freeze
      rescue StandardError
        nil
      end

      def image_media_embeddable_info(path)
        report = image_media_inspect(path)
        report && report[:ok] ? report : nil
      end

      def image_media_hex_edges(path, count = 16)
        size = File.size(path)
        File.open(path, 'rb') do |file|
          head = file.read([count, size].min).to_s.b
          file.seek([size - count, 0].max, IO::SEEK_SET)
          tail = file.read(count).to_s.b
          [head.unpack1('H*').scan(/../).join(' '), tail.unpack1('H*').scan(/../).join(' ')]
        end
      rescue StandardError
        ['', '']
      end

      def soft_schedule_photo_rejection_message(name, report)
        label = image_media_format_label(report[:format])
        display = name.to_s.empty? ? '这张图片' : "“#{name}”"
        case report[:reason].to_s
        when 'truncated'
          "#{display}文件本身不完整（#{label} 缺少结束标记，可能下载/复制未完成）。请重新下载，或用看图软件另存为 JPG 后再添加。"
        when 'damaged'
          "#{display}的 #{label} 文件结构已损坏，无法可靠嵌入 Excel。请用看图软件另存为 JPG/PNG 后再添加。"
        else
          case report[:format].to_s
          when 'heic', 'isobmff'
            "#{display}的实际格式是 #{label}（苹果手机照片常用格式），只是扩展名写成了#{File.extname(name.to_s).empty? ? '图片' : File.extname(name.to_s)}。SketchUp 无法解码该格式，请用系统“照片”或看图软件另存为 JPG 后再添加。"
          when 'unknown'
            "#{display}不是可识别的图片文件，无法作为实物图保存。"
          else
            "#{display}的实际格式是 #{label}，不是 Excel 可直接嵌入的 JPG/PNG，且自动转换未成功。请用看图软件另存为 JPG/PNG 后再添加。"
          end
        end
      end

      # 非 JPG/PNG 内容的最后兜底：交给 SketchUp ImageRep 转为 PNG（BMP/TIFF/TGA/GIF 等）。
      # 网页端对 WebP/AVIF/GIF/BMP 已优先用浏览器解码转换，这里只处理浏览器也解不了的格式。
      def soft_schedule_photo_native_convert(temp_path)
        return nil unless defined?(Sketchup::ImageRep)
        target = "#{temp_path}.converted.png"
        File.delete(target) if File.file?(target)
        return nil unless convert_image_file_to_png!(temp_path, target)
        report = image_media_inspect(target)
        return target if report && report[:ok]
        File.delete(target) if File.file?(target)
        nil
      rescue StandardError
        nil
      end

      # ---------------------------------------------------------------------
      # 二、模型缩略图显示适配
      # ---------------------------------------------------------------------

      def soft_thumbnail_fit_candidate?(path)
        base = File.basename(path.to_s)
        return false unless base.match?(SOFT_THUMBNAIL_FIT_NAME_PATTERN)
        parent = File.dirname(path.to_s)
        File.basename(parent) == SOFT_LIBRARY_THUMB_DIR &&
          File.basename(File.dirname(parent)) == SOFT_LIBRARY_MANAGER_DIR
      rescue StandardError
        false
      end

      # 本机索引键含路径；派生图文件名只取“原图版本”（修改时间+大小），不含盘符/UNC 写法，
      # 否则映射盘与 UNC 路径的同事会各生成一份并互相清理。
      def soft_thumbnail_fit_version(stat)
        "#{format('%.3f', stat.mtime.to_f)}|#{stat.size}"
      end

      def soft_thumbnail_fit_key(path, stat)
        "#{normalize_soft_library_key(path)}|#{soft_thumbnail_fit_version(stat)}"
      end

      def soft_thumbnail_fit_derivative_name(path, key)
        version = key.to_s.split('|').last(2).join('|')
        "#{File.basename(path.to_s, '.*').downcase}-#{Digest::SHA1.hexdigest("v1|#{version}")[0, 12]}.png"
      end

      def soft_thumbnail_fit_shared_dir(path)
        File.join(File.dirname(path.to_s), SOFT_THUMBNAIL_FIT_DIR)
      end

      def soft_thumbnail_fit_local_root
        base = ENV['LOCALAPPDATA'].to_s
        base = (ENV['TEMP'].to_s.empty? ? Dir.tmpdir : ENV['TEMP'].to_s) if base.empty?
        File.join(base, 'SU_LinkHub', 'thumbnail_fit')
      end

      def soft_thumbnail_fit_index_path
        File.join(soft_thumbnail_fit_local_root, 'index_v1.json')
      end

      def soft_thumbnail_fit_index
        return @soft_thumbnail_fit_index if @soft_thumbnail_fit_index.is_a?(Hash)
        entries = {}
        begin
          path = soft_thumbnail_fit_index_path
          if File.file?(path)
            data = JSON.parse(File.read(path, encoding: 'UTF-8'))
            if data.is_a?(Hash) && data['schema'].to_i == SOFT_THUMBNAIL_FIT_INDEX_SCHEMA && data['entries'].is_a?(Hash)
              data['entries'].each do |key, value|
                entries[key.to_s] = value.freeze if value.is_a?(Hash) && %w[ok fit].include?(value['s'].to_s)
              end
            end
          end
        rescue StandardError => e
          log("缩略图显示适配索引读取失败，将重新分析：#{e.class}: #{e.message}")
        end
        @soft_thumbnail_fit_index = entries
      end

      def schedule_soft_thumbnail_fit_index_persist!
        return false unless @soft_thumbnail_fit_index_dirty
        runtime_start_timer(2.0, false, label: 'thumbnail:fit_index_persist', key: 'thumbnail:fit_index_persist') do
          persist_soft_thumbnail_fit_index!
        end
        true
      rescue StandardError
        false
      end

      def persist_soft_thumbnail_fit_index!
        return false unless @soft_thumbnail_fit_index_dirty
        entries = soft_thumbnail_fit_index
        if entries.length > SOFT_THUMBNAIL_FIT_INDEX_LIMIT
          keep = entries.sort_by { |_key, value| -value['t'].to_i }.first(SOFT_THUMBNAIL_FIT_INDEX_LIMIT)
          entries = keep.to_h
          @soft_thumbnail_fit_index = entries
        end
        @soft_thumbnail_fit_index_dirty = false
        payload = {
          'schema' => SOFT_THUMBNAIL_FIT_INDEX_SCHEMA,
          'plugin_version' => EXTENSION_VERSION,
          'updated_at' => Time.now.strftime('%Y-%m-%d %H:%M:%S'),
          'entries' => entries.dup
        }
        enqueue_background_io_task(
          'json_write', key: 'soft_thumbnail_fit_index',
          data: { path: soft_thumbnail_fit_index_path, payload: payload }, label: '缩略图显示适配索引'
        )
      rescue StandardError => e
        log_exception('保存缩略图显示适配索引失败', e)
        false
      end

      def soft_thumbnail_fit_on_ui_thread?
        !defined?(SKETCHUP_UI_THREAD_OBJECT_ID) || Thread.current.object_id == SKETCHUP_UI_THREAD_OBJECT_ID
      end

      # soft_thumbnail_url 的唯一接入点：已适配 → 返回派生图；未分析 → 排队并暂用原图。
      def soft_thumbnail_display_variant(path, stat)
        return nil unless soft_thumbnail_fit_candidate?(path)
        key = soft_thumbnail_fit_key(path, stat)
        entry = soft_thumbnail_fit_index[key]
        unless entry
          enqueue_soft_thumbnail_fit(path, key) if soft_thumbnail_fit_on_ui_thread?
          return nil
        end
        return nil unless entry['s'].to_s == 'fit'
        fitted = soft_thumbnail_fit_entry_path(path, entry)
        verified = (@soft_thumbnail_fit_verified ||= {})
        unless verified[fitted]
          unless File.file?(fitted)
            # 派生图被人为删除：丢弃结论（只在主线程改索引），空闲时重新生成；本次先用原图。
            if soft_thumbnail_fit_on_ui_thread?
              @soft_thumbnail_fit_index.delete(key) if @soft_thumbnail_fit_index.is_a?(Hash)
              @soft_thumbnail_fit_index_dirty = true
              enqueue_soft_thumbnail_fit(path, key)
            end
            return nil
          end
          verified[fitted] = true
        end
        { path: fitted, stamp: Digest::SHA1.hexdigest("fit|#{key}|#{entry['f']}")[0, 10] }
      rescue StandardError
        nil
      end

      def soft_thumbnail_fit_entry_path(path, entry)
        File.join(soft_thumbnail_fit_shared_dir(path), File.basename(entry['f'].to_s))
      end

      # Excel 与其它需要“文件路径”的地方：有派生图就用派生图，否则用原图。
      def soft_thumbnail_display_path(path)
        text = path.to_s
        return text if text.empty? || !soft_thumbnail_fit_candidate?(text)
        stat = File.stat(text)
        entry = soft_thumbnail_fit_index[soft_thumbnail_fit_key(text, stat)]
        return text unless entry && entry['s'].to_s == 'fit'
        fitted = soft_thumbnail_fit_entry_path(text, entry)
        File.file?(fitted) ? fitted : text
      rescue StandardError
        path.to_s
      end

      def enqueue_soft_thumbnail_fit(path, key, front: false)
        queued = (@soft_thumbnail_fit_queued ||= {})
        queue = (@soft_thumbnail_fit_queue ||= [])
        failed = (@soft_thumbnail_fit_failed ||= {})
        return false if failed[key]
        if queued[key]
          if front
            job = queue.find { |item| item[:key] == key }
            if job
              queue.delete(job)
              queue.unshift(job)
            end
          end
          return true
        end
        queued[key] = true
        job = { path: path.to_s, key: key }
        front ? queue.unshift(job) : queue.push(job)
        schedule_soft_thumbnail_fit_tick(front ? 0.2 : 0.6)
        true
      rescue StandardError
        false
      end

      # 采购清单打开/刷新后调用：当前清单用到的缩略图优先分析。
      def schedule_soft_thumbnail_fit_for_rows(rows)
        return false unless soft_thumbnail_fit_on_ui_thread?
        seen = {}
        Array(rows).reverse_each do |row|
          next unless row.is_a?(Hash)
          path = row['thumbnail_path'].to_s
          next if path.empty? || seen[path] || !soft_thumbnail_fit_candidate?(path)
          seen[path] = true
          checked = (@soft_thumbnail_fit_session_checked ||= {})
          next if checked[path]
          checked[path] = true
          stat = File.stat(path) rescue nil
          next unless stat && stat.file?
          key = soft_thumbnail_fit_key(path, stat)
          entry = soft_thumbnail_fit_index[key]
          if entry
            # 快照里可能还是原图 URL（旧版本/其他同事写的缓存）：已有结论时直接推送更新。
            next unless entry['s'].to_s == 'fit'
            url = row['thumbnail_url'].to_s
            next if url.include?("/#{SOFT_THUMBNAIL_FIT_DIR}/")
            (@soft_thumbnail_fit_pending_updates ||= []) << { path: path, key: key }
            schedule_soft_thumbnail_fit_tick(0.2)
          else
            enqueue_soft_thumbnail_fit(path, key, front: true)
          end
        end
        true
      rescue StandardError => e
        log_exception('安排采购清单缩略图显示适配失败', e)
        false
      end

      def schedule_soft_thumbnail_fit_tick(delay = 0.6)
        return true if @soft_thumbnail_fit_timer_pending
        @soft_thumbnail_fit_timer_pending = true
        runtime_start_timer(delay.to_f, false, label: 'thumbnail:display_fit', key: 'thumbnail:display_fit') do
          @soft_thumbnail_fit_timer_pending = false
          process_soft_thumbnail_fit_queue
        end
        true
      rescue StandardError
        @soft_thumbnail_fit_timer_pending = false
        false
      end

      def soft_thumbnail_fit_should_yield?
        return true if @soft_model_batch_job || @soft_ingest_batch_job || @soft_thumbnail_rendering || @soft_schedule_batch_applying
        return true if respond_to?(:soft_visual_proxy_upgrade_job_active?) && soft_visual_proxy_upgrade_job_active?
        return true if respond_to?(:soft_heavy_interaction?) && soft_heavy_interaction?
        return true if respond_to?(:soft_thumbnail_idle?) && !soft_thumbnail_idle?
        false
      rescue StandardError
        false
      end

      def process_soft_thumbnail_fit_queue
        queue = (@soft_thumbnail_fit_queue ||= [])
        pending_updates = (@soft_thumbnail_fit_pending_updates ||= [])
        return false if queue.empty? && pending_updates.empty?
        consumer_visible = (@soft_designer_dialog && @soft_designer_dialog.visible?) ||
                           (@soft_schedule_dialog && @soft_schedule_dialog.visible?)
        # 没有界面在看缩略图时保留队列、不消耗 CPU；下次打开清单/模型库会重新触发。
        return false unless consumer_visible
        if soft_thumbnail_fit_should_yield?
          schedule_soft_thumbnail_fit_tick(0.8)
          return true
        end
        started = monotonic_time
        updates = []
        until pending_updates.empty?
          item = pending_updates.shift
          entry = soft_thumbnail_fit_index[item[:key]]
          update = soft_thumbnail_fit_update(item[:path], item[:key], entry)
          updates << update if update
        end
        fitted = 0
        while (job = queue.shift)
          @soft_thumbnail_fit_queued.delete(job[:key]) if @soft_thumbnail_fit_queued
          record = build_soft_thumbnail_fit!(job[:path], job[:key])
          if record && record['s'].to_s == 'fit'
            update = soft_thumbnail_fit_update(job[:path], job[:key], record)
            if update
              updates << update
              fitted += 1
            end
          end
          break if monotonic_time - started >= SOFT_THUMBNAIL_FIT_TICK_BUDGET
        end
        @soft_thumbnail_fit_batch_fitted = @soft_thumbnail_fit_batch_fitted.to_i + fitted
        send_soft_thumbnail_updates(updates) unless updates.empty?
        schedule_soft_thumbnail_fit_index_persist!
        if queue.empty? && pending_updates.empty?
          total = @soft_thumbnail_fit_batch_fitted.to_i
          log("缩略图显示适配：本轮自动放大/居中 #{total} 张（原图取景过小或偏移；源 SKP 与原缩略图未改动）") if total.positive?
          @soft_thumbnail_fit_batch_fitted = 0
        else
          schedule_soft_thumbnail_fit_tick(0.12)
        end
        true
      rescue StandardError => e
        log_exception('缩略图显示适配队列失败', e)
        schedule_soft_thumbnail_fit_tick(2.0) unless Array(@soft_thumbnail_fit_queue).empty?
        false
      end

      def soft_thumbnail_fit_update(path, key, entry)
        return nil unless entry && entry['s'].to_s == 'fit'
        stat = File.stat(path)
        return nil unless soft_thumbnail_fit_key(path, stat) == key
        url = soft_thumbnail_url(path)
        return nil if url.to_s.empty?
        {
          'id' => File.basename(path, '.*').downcase, 'thumbnail_url' => url, 'thumbnail_path' => path,
          'thumbnail_ready' => true, 'thumbnail_finished' => true, 'thumbnail_error' => ''
        }
      rescue StandardError
        nil
      end

      def build_soft_thumbnail_fit!(path, key)
        index = soft_thumbnail_fit_index
        existing = index[key]
        return existing if existing
        return nil unless File.file?(path)
        name = soft_thumbnail_fit_derivative_name(path, key)
        shared_target = File.join(soft_thumbnail_fit_shared_dir(path), name)
        record = nil
        if File.file?(shared_target) && File.size(shared_target).positive?
          # 同事已生成过同一版本原图的派生图：直接复用，不再解码。
          record = { 's' => 'fit', 'f' => name, 'q' => '', 't' => Time.now.to_i }
        else
          return nil unless defined?(Sketchup::ImageRep)
          image = Sketchup::ImageRep.new
          image.load_file(path)
          width = image.width.to_i
          height = image.height.to_i
          bits = image.bits_per_pixel.to_i
          return soft_thumbnail_fit_remember!(key, 's' => 'ok', 'q' => 'format') unless [24, 32].include?(bits)
          channels = bits / 8
          stride = width * channels + image.row_padding.to_i
          data = image.data.to_s.b
          return soft_thumbnail_fit_remember!(key, 's' => 'ok', 'q' => 'short') if data.bytesize < stride * height
          plan = soft_thumbnail_fit_plan(width, height, channels, stride, data)
          if plan[:status] == 'fit'
            side, pixels = soft_thumbnail_fit_crop(width, height, channels, stride, data, plan)
            write_soft_thumbnail_fit_derivative!(path, name, side, pixels)
            record = { 's' => 'fit', 'f' => name, 'q' => Array(plan[:flags]).join(','), 't' => Time.now.to_i }
          else
            record = { 's' => 'ok', 'q' => ([plan[:status]] + Array(plan[:flags])).uniq.join(','), 't' => Time.now.to_i }
          end
        end
        soft_thumbnail_fit_remember!(key, record)
      rescue StandardError => e
        # 本会话不再重试这一版原图（共享盘只读/文件损坏等），也不写入持久索引，下次启动再试。
        (@soft_thumbnail_fit_failed ||= {})[key] = true
        failures = (@soft_thumbnail_fit_failure_logs = @soft_thumbnail_fit_failure_logs.to_i + 1)
        log("缩略图显示适配跳过：#{File.basename(path.to_s)} · #{e.class}: #{e.message}") if failures <= 5
        nil
      end

      def soft_thumbnail_fit_remember!(key, record)
        record = record.merge('t' => Time.now.to_i) unless record.key?('t')
        frozen = record.freeze
        soft_thumbnail_fit_index[key] = frozen
        @soft_thumbnail_fit_index_dirty = true
        frozen
      end

      # 写派生图：先在本机临时目录编码 PNG，再经同目录临时名原子改名到共享目录。
      # 共享目录不可写时直接放弃（不退回本机路径：本机路径一旦写进共享目录缓存，
      # 其他同事会得到打不开的地址）。比当前原图更旧、且已超过 3 天的旧派生图顺手清理；
      # 3 天宽限让其他电脑内存里的旧地址自然过期，而不是立刻失效。
      def write_soft_thumbnail_fit_derivative!(path, name, side, pixels)
        FileUtils.mkdir_p(TEMP_WORK_DIR)
        temp = File.join(TEMP_WORK_DIR, "thumb-fit-#{Process.pid}-#{SecureRandom.hex(4)}.png")
        output = Sketchup::ImageRep.new
        output.set_data(side, side, 24, 0, pixels)
        output.save_file(temp)
        raise '显示适配缩略图编码失败。' unless File.file?(temp) && File.size(temp).positive?
        shared_dir = soft_thumbnail_fit_shared_dir(path)
        FileUtils.mkdir_p(shared_dir)
        target = File.join(shared_dir, name)
        staging = "#{target}.tmp-#{Process.pid}-#{SecureRandom.hex(3)}"
        FileUtils.cp(temp, staging)
        File.rename(staging, target)
        staging = nil
        original_mtime = File.mtime(path)
        grace = Time.now - (3 * 86_400)
        prefix = "#{File.basename(path.to_s, '.*').downcase}-"
        Dir.glob(File.join(shared_dir, "#{prefix}*.png")).each do |old|
          next if File.basename(old) == name
          stamp = File.mtime(old)
          File.delete(old) if stamp < original_mtime && stamp < grace
        rescue StandardError
          nil
        end
        target
      ensure
        File.delete(staging) if defined?(staging) && staging && File.file?(staging)
        File.delete(temp) if defined?(temp) && temp && File.file?(temp)
      end

      # 纯计算：根据像素内容给出适配方案。不依赖 SketchUp，可单独测试。
      # 返回 { status: 'fit'|'ok'|'blank'|'busy', left:, top:, side:, bg:, flags: [] }
      def soft_thumbnail_fit_plan(width, height, channels, stride, data)
        return { status: 'ok', flags: ['small'] } if width < 16 || height < 16
        bg = soft_thumbnail_fit_background(width, height, channels, stride, data)
        return { status: 'busy', flags: [] } unless bg
        rows = soft_thumbnail_fit_row_spans(width, height, channels, stride, data, bg)
        runs = soft_thumbnail_fit_runs(rows, height)
        return { status: 'blank', flags: [], bg: bg } if runs.empty?
        heaviest = runs.map { |run| run[:weight] }.max.to_f
        kept = runs.select { |run| run[:weight] >= heaviest * 0.03 }
        total = kept.sum { |run| run[:weight] }
        return { status: 'blank', flags: [], bg: bg } if total < 8
        x0 = kept.map { |run| run[:x0] }.min
        x1 = kept.map { |run| run[:x1] }.max
        y0 = kept.map { |run| run[:y0] }.min
        y1 = kept.map { |run| run[:y1] }.max
        box_w = x1 - x0 + 1
        box_h = y1 - y0 + 1
        content = [box_w, box_h].max
        margin = [2, (content * SOFT_THUMBNAIL_FIT_MARGIN).round].max
        side = content + margin * 2
        side += (4 - side % 4) % 4 # 24 位行按 4 字节对齐，兼容所有 ImageRep 实现
        frame = [width, height].max
        flags = []
        flags << 'clip' if x0.zero? || y0.zero? || x1 == width - 1 || y1 == height - 1
        flags << 'low' if content < SOFT_THUMBNAIL_FIT_LOW_SIDE
        box = [x0, y0, box_w, box_h]
        return { status: 'ok', flags: flags, bg: bg, box: box } if side >= frame * SOFT_THUMBNAIL_FIT_OK_RATIO
        left = (x0 + box_w / 2.0 - side / 2.0).round
        top = (y0 + box_h / 2.0 - side / 2.0).round
        # 窗口放回画面内：被原图裁切的一边贴边，而不是补一条白边。
        left = [[left, width - side].min, 0].max if side <= width
        top = [[top, height - side].min, 0].max if side <= height
        { status: 'fit', left: left, top: top, side: side, bg: bg, flags: flags, box: box }
      end

      # 以四条边的中位色作为背景；边缘像素里至少 55% 接近该色才认为背景可判定。
      def soft_thumbnail_fit_background(width, height, channels, stride, data)
        samples = []
        step = [1, [width, height].max / 128].max
        (0...width).step(step) do |x|
          samples << soft_thumbnail_fit_pixel(data, x, 0, channels, stride)
          samples << soft_thumbnail_fit_pixel(data, x, height - 1, channels, stride)
        end
        (0...height).step(step) do |y|
          samples << soft_thumbnail_fit_pixel(data, 0, y, channels, stride)
          samples << soft_thumbnail_fit_pixel(data, width - 1, y, channels, stride)
        end
        return nil if samples.empty?
        median = (0...samples.first.length).map do |channel|
          sorted = samples.map { |pixel| pixel[channel] }.sort
          sorted[sorted.length / 2]
        end
        transparent = channels == 4 && median[3] < 128
        near = samples.count do |pixel|
          if transparent
            pixel[3] < 128
          else
            (pixel[0] - median[0]).abs <= 18 && (pixel[1] - median[1]).abs <= 18 && (pixel[2] - median[2]).abs <= 18
          end
        end
        return nil if near < samples.length * 0.55
        { color: median[0, 3], transparent: transparent }
      end

      def soft_thumbnail_fit_pixel(data, x, y, channels, stride)
        offset = y * stride + x * channels
        pixel = [data.getbyte(offset).to_i, data.getbyte(offset + 1).to_i, data.getbyte(offset + 2).to_i]
        pixel << data.getbyte(offset + 3).to_i if channels == 4
        pixel
      end

      # 每行第一个/最后一个“非背景”像素。24 位且背景为中性色时用二进制正则整行扫描
      # （C 实现，256×256 约 1ms）；透明底/彩色底才逐像素比较。
      def soft_thumbnail_fit_row_spans(width, height, channels, stride, data, bg)
        color = bg[:color]
        near_white = color.min >= 235
        tolerance = near_white ? 10 : 18
        spans = Array.new(height)
        low = [color.min - tolerance, 0].max
        high = [color.max + tolerance, 255].min
        neutral = (color.max - color.min) <= 12
        # 32 位不透明图（ImageRep 常把 PNG 读成 BGRA）只在白底时走快路径：Alpha=255
        # 不会命中“低于背景”的字符类，半透明像素按主体处理。
        if neutral && !bg[:transparent] && (channels == 3 || (channels == 4 && high >= 255))
          return spans if high >= 255 && low <= 0
          pattern = if high >= 255
                      Regexp.new(format('[\x00-\x%02X]', [low - 1, 0].max).b, Regexp::NOENCODING)
                    elsif low <= 0
                      Regexp.new(format('[\x%02X-\xFF]', [high + 1, 255].min).b, Regexp::NOENCODING)
                    else
                      Regexp.new(format('[^\x%02X-\x%02X]', low, high).b, Regexp::NOENCODING)
                    end
          row_bytes = width * channels
          height.times do |y|
            row = data.byteslice(y * stride, row_bytes)
            first = row.index(pattern)
            next unless first
            last = row.rindex(pattern)
            spans[y] = [first / channels, last / channels]
          end
          return spans
        end
        height.times do |y|
          base = y * stride
          first = nil
          last = nil
          width.times do |x|
            offset = base + x * channels
            if channels == 4
              alpha = data.getbyte(offset + 3).to_i
              next if alpha <= 24
              unless bg[:transparent]
                next if (data.getbyte(offset).to_i - color[0]).abs <= tolerance &&
                        (data.getbyte(offset + 1).to_i - color[1]).abs <= tolerance &&
                        (data.getbyte(offset + 2).to_i - color[2]).abs <= tolerance
              end
            else
              next if (data.getbyte(offset).to_i - color[0]).abs <= tolerance &&
                      (data.getbyte(offset + 1).to_i - color[1]).abs <= tolerance &&
                      (data.getbyte(offset + 2).to_i - color[2]).abs <= tolerance
            end
            first ||= x
            last = x
          end
          spans[y] = [first, last] if first
        end
        spans
      end

      # 连续有内容的行归为一段（允许 2 行空隙）；权重 = 各行跨度之和。
      # 远离主体的孤立噪点段权重极小，会在 plan 中被丢弃。
      def soft_thumbnail_fit_runs(spans, height)
        runs = []
        current = nil
        gap = 0
        allowed_gap = [2, (height * 0.01).round].max
        spans.each_with_index do |span, y|
          if span.nil?
            next unless current
            gap += 1
            if gap > allowed_gap
              runs << current
              current = nil
              gap = 0
            end
            next
          end
          current ||= { y0: y, y1: y, x0: span[0], x1: span[1], weight: 0 }
          current[:y1] = y
          current[:x0] = span[0] if span[0] < current[:x0]
          current[:x1] = span[1] if span[1] > current[:x1]
          current[:weight] += span[1] - span[0] + 1
          gap = 0
        end
        runs << current if current
        runs
      end

      # 纯计算：按方案裁出正方形 24 位像素串（通道顺序与输入一致），画面外补背景色。
      def soft_thumbnail_fit_crop(width, height, channels, stride, data, plan)
        side = plan[:side].to_i
        left = plan[:left].to_i
        top = plan[:top].to_i
        color = Array(plan.dig(:bg, :color))
        color = [255, 255, 255] if color.length != 3 || plan.dig(:bg, :transparent)
        pad_pixel = color.pack('C3')
        output = String.new(capacity: side * side * 3, encoding: Encoding::BINARY)
        side.times do |oy|
          sy = top + oy
          if sy.negative? || sy >= height
            output << (pad_pixel * side)
            next
          end
          sx0 = [left, 0].max
          sx1 = [left + side, width].min
          lead = [sx0 - left, side].min
          output << (pad_pixel * lead) if lead.positive?
          if sx1 > sx0
            if channels == 3
              output << data.byteslice(sy * stride + sx0 * 3, (sx1 - sx0) * 3)
            else
              base = sy * stride
              (sx0...sx1).each do |sx|
                offset = base + sx * 4
                alpha = data.getbyte(offset + 3).to_i
                3.times do |channel|
                  value = data.getbyte(offset + channel).to_i
                  output << (((value * alpha) + (color[channel] * (255 - alpha)) + 127) / 255).chr
                end
              end
            end
          end
          used = lead + [sx1 - sx0, 0].max
          output << (pad_pixel * (side - used)) if side > used
        end
        [side, output]
      end
    end
  end
end
