# frozen_string_literal: true

module GavinTools
  module SULinkHubMultiSpace
    # v0.13.6.189：Windows 上 File.expand_path / File.absolute_path 并不是纯字符串运算。
    # Ruby（win32/file.c replace_to_long_name）在“最后一段 ≤12 个字符、扩展名 ≤3”时，
    # 会对完整路径调用一次 FindFirstFileW 把 8.3 短名换成长名。中文文件名/文件夹名
    # 几乎都满足这个长度，于是每一次 expand_path 都是一次 SMB 往返（本项目 NAS 实测
    # 约 0.95ms/次）。启动时软装模型库预热一轮就有约 2,900 次，正好对应日志里每次
    # 2.4~3.3 秒的卡顿；空间状态、锁、缩略图、清单、发布前检查也都在反复付这笔钱。
    #
    # FastPath.expand 对“已经是绝对路径”的 Windows 路径（盘符路径、UNC 路径）用纯
    # Ruby 完成与 GetFullPathNameW 相同的规范化：统一为 /、合并重复分隔符、处理 . 与 ..、
    # 去掉结尾分隔符。凡是可能有歧义的写法（~ 短名/家目录、盘符相对路径、结尾点或空格、
    # 备用数据流冒号、设备名、通配符、非 UTF-8 编码）一律交回 File.expand_path，
    # 保证结果与旧实现一致。唯一的差别：不再为了“最后一段的大小写/短名”去访问磁盘；
    # 插件内部比较路径本来就按小写键（normalize_soft_library_key）进行。
    # 非 Windows 平台上 File.expand_path 本身不访问磁盘，直接沿用。
    module FastPath
      WINDOWS = !!(RUBY_PLATFORM =~ /mswin|mingw|cygwin/i) unless const_defined?(:WINDOWS, false)
      DRIVE_PATTERN = %r{\A([A-Za-z]:)/}.freeze unless const_defined?(:DRIVE_PATTERN, false)
      UNC_PATTERN = %r{\A//([^/]+)/([^/]+)(?:/|\z)}.freeze unless const_defined?(:UNC_PATTERN, false)
      UNSAFE_PATTERN = /[~*?"<>|\x00]/.freeze unless const_defined?(:UNSAFE_PATTERN, false)
      DEVICE_PATTERN = /\A(?:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9]|CONIN\$|CONOUT\$)(?:\.[^.]*)?\z/i.freeze unless const_defined?(:DEVICE_PATTERN, false)
      UTF8 = Encoding::UTF_8 unless const_defined?(:UTF8, false)
      ASCII = Encoding::US_ASCII unless const_defined?(:ASCII, false)

      @windows_mode = WINDOWS

      class << self
        # 测试用：在非 Windows 环境强制走 Windows 规范化分支。
        attr_accessor :windows_mode

        def expand(path, dir = nil)
          return File.expand_path(path, dir) unless @windows_mode
          text = path.is_a?(String) ? path : nil
          return File.expand_path(path, dir) unless text
          fast = windows_absolute(text)
          if fast.nil? && !dir.nil? && windows_simple_relative?(text)
            base = dir.is_a?(String) ? windows_absolute(dir) : nil
            fast = windows_absolute("#{base}/#{text}") if base
          end
          return fast if fast
          File.expand_path(path, dir)
        rescue ArgumentError, EncodingError
          File.expand_path(path, dir)
        end

        # 返回规范化后的绝对路径；不能 100% 确定与 Windows 结果一致时返回 nil。
        def windows_absolute(text)
          return nil if text.empty?
          encoding = text.encoding
          return nil unless encoding == UTF8 || encoding == ASCII
          return nil unless text.valid_encoding?
          return nil if text.match?(UNSAFE_PATTERN)
          normalized = text.tr('\\', '/')
          if (drive = normalized[DRIVE_PATTERN, 1])
            prefix = drive
            rest = normalized[3..].to_s
          elsif (match = UNC_PATTERN.match(normalized))
            return nil if match[1] == '.' || match[1] == '?' || match[2] == '.' || match[2] == '..'
            return nil if match[1].include?(':') || match[2].include?(':')
            prefix = "//#{match[1]}/#{match[2]}"
            rest = normalized[match[0].length..].to_s
          else
            return nil
          end
          return nil if rest.include?(':')
          parts = []
          rest.split('/').each do |segment|
            next if segment.empty? || segment == '.'
            if segment == '..'
              parts.pop
              next
            end
            # Windows 会静默去掉组件结尾的点/空格、把 ... 当作 .；这些罕见写法交回原实现。
            return nil if segment.end_with?('.', ' ')
            return nil if segment.match?(DEVICE_PATTERN)
            parts << segment
          end
          result = if parts.empty?
                     drive ? "#{prefix}/" : prefix.dup
                   else
                     "#{prefix}/#{parts.join('/')}"
                   end
          result.force_encoding(encoding)
        end

        def windows_simple_relative?(text)
          return false if text.empty?
          return false if text.start_with?('/', '\\', '~')
          return false if text.match?(/\A[A-Za-z]:/)
          true
        end
      end
    end
  end
end
