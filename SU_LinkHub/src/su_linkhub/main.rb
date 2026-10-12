# frozen_string_literal: true

require 'sketchup.rb'
require 'json'
require 'fileutils'
require 'tmpdir'
require 'securerandom'
require 'base64'
require 'time'

module GavinTools
  module SULinkHubMultiSpace
    extend self

    EXTENSION_NAME = 'SU LinkHub 多空间联动' unless const_defined?(:EXTENSION_NAME, false)
    BOOTSTRAP_API = 4 unless const_defined?(:BOOTSTRAP_API, false)
    # 每个 SketchUp 进程唯一；热重载保持不变，完整重启后改变。
    RUNTIME_SESSION_ID = "#{Process.pid}-#{SecureRandom.hex(10)}" unless const_defined?(:RUNTIME_SESSION_ID, false)

    @runtime_generation ||= 0
    @runtime_reloading = false if @runtime_reloading.nil?
    @last_runtime_error = nil unless defined?(@last_runtime_error)

    def runtime
      const_defined?(:Runtime, false) ? const_get(:Runtime, false) : nil
    end

    # v0.13.7.5：清单窗口布局整理（诊断菜单、底部提交条、空间胶囊页签、筛选小按钮、模型变化提示条）；合并别名提交到保留模型；朝向相机包装不累积。
    # v0.13.7.4：自动六面代理统一 128px；任务队列显示实际生成用时。
    # v0.13.7.3：缩略图正反两张轴测图（离屏 512/1024px）+ 清单/模型库刷新、反转按钮并共享选择；朝向相机组件不压平不代理、正视图缩略图、清单尺寸稳定。
    # v0.13.7.2：清单同款合并（不同 model_id 同名同尺寸同材质）；模型库“重复模型”合并/撤销；清单刷新僵尸任务自动结束+看门狗续跑。
    # v0.13.7.1：Excel 导出排版——默认边框、按空间分区淡色底、空间名去编号加粗、统一行高、图片随单元格；新增按款汇总表。
    # v0.13.6.192：六面代理——全不透明 RGB 视图视为合格；过期入库轴不再把实体误判为平面；根层远端隔离拍空后本会话改走近原点。
    # v0.13.6.191：发布交接/入库接管不再因个别家具缺代理整单失败（混合包 + 后台补代理）；代理队列中断后自动继续发布。
    # v0.13.6.190：内置只读诊断（选择/双击/联动、家具变形、日志诊断包）；联动空间“调整位置”按钮与右键；原生复制的重复空间根可登记为联动副本；来源同步不再把正在调整的副本弹回；发布前复核协同组件签名。
    # v0.13.6.189：路径规范化免 NAS 查询（FastPath）；后台线程 GVL 让渡；共享盘大块复制/校验；文件替换重试不再被 force 吞掉。
    # v0.13.6.188：清单缩略图显示适配放大；实物图按真实格式识别/结构校验并自动转换；坐高可填说明。
    # v0.13.6.187：入库预览读取实际纹理/UVQ并显示可见边线，不改变项目样式。
    # v0.13.6.186：入库缺图采用只读几何轴测预览，分片加载与点击放大，不借用项目视口。
    # v0.13.6.185：减少无关家具/共享目录读取；发布诊断句柄复用；可延后 I/O 避让正式发布。
    # v0.13.6.184：代理丢失自动从真模型修复；单件缺代理不回滚空间/不拦发布；入库队列可追加；六面截图分片。
    # v0.13.6.104：自动入库禁用原生缩略图强刷，Definition 候选优先 save_copy；
    # v0.13.6.103：待入库家具保持原状并以蓝色半透明框标记，退出空间后统一处理；
    # v0.13.6.102：修复家具入库大模型闪退/无响应及六面代理截图源失效；
    # 文件传输不再占用模型事务，代理只在世界根安全生成且不再主动切换 active_path。
    def proxy_worker_mode?
      false
    end

    # 不把安装目录保存到通用常量。__dir__ 绑定当前 main.rb 的真实目录，
    # 即使其他插件定义了 PLUGIN_DIR / RUNTIME_FILE 也不会影响 LinkHub。
    def runtime_source_file
      File.expand_path('runtime.rb', __dir__)
    end

    def bootstrap_log_path
      root = ENV['TEMP'].to_s.empty? ? Dir.tmpdir : ENV['TEMP'].to_s
      directory = File.join(root, 'SU_LinkHub', 'logs')
      FileUtils.mkdir_p(directory)
      File.join(directory, 'SU_LinkHub_bootstrap.log')
    rescue StandardError
      File.join(root || Dir.tmpdir, 'SU_LinkHub_bootstrap.log')
    end

    def record_runtime_error(error, reason, source = runtime_source_file)
      trace = Array(error.backtrace).first(16)
      @last_runtime_error = {
        error: error,
        reason: reason.to_s,
        source: source.to_s,
        trace: trace
      }
      File.open(bootstrap_log_path, 'ab') do |file|
        file.write("\n[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] #{reason}\n")
        file.write("SketchUp #{Sketchup.version rescue '未知'} / Ruby #{RUBY_VERSION}\n")
        file.write("来源：#{source}\n#{error.class}: #{error.message}\n")
        trace.each { |line| file.write("  #{line}\n") }
      end
      true
    rescue StandardError
      false
    end

    def last_runtime_error_message
      record = @last_runtime_error
      return 'SU LinkHub 运行时尚未加载。' unless record.is_a?(Hash)
      error = record[:error]
      location = Array(record[:trace]).first.to_s
      message = "#{error.class}: #{error.message}"
      message += "\n位置：#{location}" unless location.empty?
      message += "\n运行文件：#{record[:source]}"
      message
    rescue StandardError
      'SU LinkHub 运行时尚未加载。'
    end

    def dispatch(method_name, *args, &block)
      target = runtime
      unless target
        # 初次启动偶发失败后，点击命令会按真实安装目录自动重试一次，
        # 不再让插件在本次 SketchUp 会话中永久失效。
        load_runtime!(show_dialog: false, reason: '按需恢复', notify_failure: false)
        target = runtime
      end
      raise last_runtime_error_message unless target
      raise "SU LinkHub 运行时缺少接口：#{method_name}" unless target.respond_to?(method_name)
      target.public_send(method_name, *args, &block)
    end

    def show_dialog
      dispatch(:show_dialog)
    rescue StandardError => e
      UI.messagebox("SU LinkHub 无法打开抽屉。\n\n#{e.class}: #{e.message}\n\n启动日志：#{bootstrap_log_path}")
      false
    end

    def load_runtime!(show_dialog: false, reason: '启动', notify_failure: true)
      return false if @runtime_reloading
      @runtime_reloading = true
      previous = runtime
      previous_version = previous.const_get(:EXTENSION_VERSION).to_s rescue ''
      previous_snapshot = if previous && previous.respond_to?(:export_runtime_hot_reload_state)
                            previous.export_runtime_hot_reload_state
                          else
                            {}
                          end
      previous.shutdown! if previous && previous.respond_to?(:shutdown!)

      remove_const(:Runtime) if const_defined?(:Runtime, false)
      @runtime_generation = @runtime_generation.to_i + 1
      source = runtime_source_file
      raise LoadError, "LinkHub 运行文件不存在：#{source}" unless File.file?(source)
      Kernel.load(source)
      current = runtime
      raise '更新后的 runtime.rb 未定义 GavinTools::SULinkHubMultiSpace::Runtime。' unless current
      if current.respond_to?(:runtime_contract_check!)
        checked = current.runtime_contract_check!
        raise '新运行时接口契约检查未通过。' unless checked
      end
      if current.respond_to?(:boot!)
        booted = current.boot!(generation: @runtime_generation)
        raise '新运行时未能完整启动，已拒绝保留半初始化状态。' unless booted
      end
      current.import_runtime_hot_reload_state!(previous_snapshot) if current.respond_to?(:import_runtime_hot_reload_state!) && previous_snapshot.is_a?(Hash)
      current.show_dialog if show_dialog && current.respond_to?(:show_dialog)
      current_version = current.const_get(:EXTENSION_VERSION).to_s rescue ''
      current.show_status("插件已重新载入：v#{current_version}（第 #{@runtime_generation} 次运行）", 'success') if show_dialog && current.respond_to?(:show_status)
      @last_runtime_error = nil if !current.respond_to?(:boot!) || booted
      true
    rescue Exception => e # rubocop:disable Lint/RescueException
      source ||= runtime_source_file
      record_runtime_error(e, reason, source)
      begin
        remove_const(:Runtime) if const_defined?(:Runtime, false)
        const_set(:Runtime, previous) if previous
        previous.boot!(generation: @runtime_generation) if previous && previous.respond_to?(:boot!)
        previous.import_runtime_hot_reload_state!(previous_snapshot) if previous && previous.respond_to?(:import_runtime_hot_reload_state!) && previous_snapshot.is_a?(Hash)
        previous.show_dialog if show_dialog && previous.respond_to?(:show_dialog)
      rescue StandardError
        nil
      end
      if notify_failure
        UI.messagebox(
          "SU LinkHub 运行时加载失败，已尝试恢复旧运行时。\n\n" \
          "#{e.class}: #{e.message}\n来源：#{source}\n旧版本：#{previous_version}\n\n" \
          "启动日志：#{bootstrap_log_path}"
        )
      end
      false
    ensure
      @runtime_reloading = false
    end

    def install_archive_and_reload!(archive_path, show_dialog: false)
      path = File.expand_path(archive_path.to_s)
      raise "LinkHub 更新包不存在：#{path}" unless File.file?(path)
      raise '当前 SketchUp 不支持从 RBZ 安装插件。' unless Sketchup.respond_to?(:install_from_archive)
      installed = Sketchup.install_from_archive(path, false)
      raise "SketchUp 未能安装更新包：#{path}" unless installed

      latest_main = File.expand_path('main.rb', __dir__)
      Kernel.load(latest_main) if File.file?(latest_main)
      UI.start_timer(0.08, false) do
        loaded = GavinTools::SULinkHubMultiSpace.load_runtime!(
          show_dialog: show_dialog,
          reason: "安装更新包 #{File.basename(path)}"
        )
        GavinTools::SULinkHubMultiSpace.refresh_toolbar_command_state!
        if loaded
          current = GavinTools::SULinkHubMultiSpace.runtime
          version = current.const_get(:EXTENSION_VERSION).to_s rescue '未知'
          completed_at = Time.now.strftime('%Y-%m-%d-%H:%M')
          message = "你成功更新到#{completed_at}-----(v#{version}版)"
          current.show_status(message, 'success') if current && current.respond_to?(:show_status)
          UI.messagebox(message)
        else
          UI.messagebox("SU LinkHub 更新包已经安装，但新版运行时未能成功载入。\n\n请使用“检查”查看具体问题；必要时重新启动 SketchUp。")
        end
      end
      true
    rescue Interrupt
      false
    rescue Exception => e # rubocop:disable Lint/RescueException
      record_runtime_error(e, '安装项目目录中的 LinkHub 更新包', archive_path)
      UI.messagebox("SU LinkHub 更新失败。\n\n#{e.class}: #{e.message}\n\n启动日志：#{bootstrap_log_path}")
      false
    end

    def schedule_runtime_reload!(show_dialog: false)
      UI.start_timer(0.05, false) do
        load_runtime!(show_dialog: show_dialog, reason: '手动热重载')
        refresh_toolbar_command_state!
      end
      true
    end

    def icon_path(size)
      File.expand_path(File.join('ui', 'icons', "linkhub_#{size}.png"), __dir__)
    end

    def named_icon_path(name, size)
      File.expand_path(File.join('ui', 'icons', "linkhub_#{name}_#{size}.png"), __dir__)
    end

    def assign_command_icon!(command, name = nil)
      small = name ? named_icon_path(name, 24) : icon_path(24)
      large = name ? named_icon_path(name, 32) : icon_path(32)
      command.small_icon = small if File.file?(small)
      command.large_icon = large if File.file?(large)
      true
    rescue StandardError
      false
    end

    def refresh_toolbar_icon!
      return false unless @toggle_command
      assign_command_icon!(@toggle_command)
    end

    def refresh_toolbar_command_state!
      enabled = begin
        target = runtime
        target && target.respond_to?(:linkhub_enabled?) ? target.linkhub_enabled? : true
      rescue StandardError
        true
      end
      if @toggle_command
        @toggle_command.tooltip = enabled ? '关闭 SU LinkHub 悬浮按钮与左侧抽屉' : '启动 SU LinkHub 悬浮按钮与左侧抽屉'
        @toggle_command.status_bar_text = enabled ? '隐藏 LinkHub 视口悬浮按钮；协作数据与当前修改锁不会被删除' : '恢复 LinkHub 视口悬浮按钮和左侧抽屉'
      end
      if @reload_command
        @reload_command.tooltip = '重新载入 SU LinkHub 插件运行时'
        @reload_command.status_bar_text = '用于安装新版本后刷新运行时；不会重新启动 SketchUp'
      end
      true
    rescue StandardError
      false
    end

    def ensure_reload_command!(menu = nil, toolbar = nil)
      return @reload_command if @reload_command
      @reload_command = UI::Command.new('重载 SU LinkHub') { schedule_runtime_reload! }
      assign_command_icon!(@reload_command, 'status')
      (menu || UI.menu('Extensions')).add_item(@reload_command)
      target_toolbar = toolbar || @toolbar
      if target_toolbar
        target_toolbar.add_item(@reload_command)
        target_toolbar.restore
      end
      refresh_toolbar_command_state!
      @reload_command
    rescue StandardError
      nil
    end

    unless proxy_worker_mode?
      unless file_loaded?(__FILE__)
        @toggle_command = UI::Command.new('启动／关闭 SU LinkHub') do
          dispatch(:toggle_linkhub_enabled)
          refresh_toolbar_command_state!
        end
        refresh_toolbar_icon!

        submenu = UI.menu('Extensions').add_submenu('SU LinkHub')
        submenu.add_item(@toggle_command)
        @linkhub_extensions_submenu = submenu

        @toolbar = UI::Toolbar.new('SU LinkHub')
        @toolbar.add_item(@toggle_command)
        ensure_reload_command!(submenu, @toolbar)
        refresh_toolbar_command_state!
        @toolbar.restore

        unless @linkhub_context_menu_handler_installed
          UI.add_context_menu_handler do |context_menu|
            begin
              dispatch(:populate_linkhub_context_menu, context_menu)
            rescue StandardError => e
              record_runtime_error(e, '建立 LinkHub 右键菜单')
            end
          end
          @linkhub_context_menu_handler_installed = true
        end

        file_loaded(__FILE__)
      end

      load_runtime!(show_dialog: false, reason: '初次启动') unless runtime

      # v0.13.6.190：只读诊断菜单。独立于 file_loaded 守卫，使通过“更新包热安装”的会话
      # 也能立刻看到入口；模块实例变量保证同一 SketchUp 进程只添加一次。
      unless @linkhub_diagnostic_menu_installed
        begin
          parent_menu = @linkhub_extensions_submenu || UI.menu('Extensions')
          diagnostic_menu = parent_menu.add_submenu('LinkHub 只读诊断')
          diagnostic_menu.add_item('诊断当前选择（双击 / 联动 / 锁）') { dispatch(:run_linkhub_selection_diagnostic!) rescue UI.messagebox($!.message) }
          diagnostic_menu.add_item('家具变形只读诊断（全模型）') { dispatch(:run_linkhub_furniture_diagnostic!) rescue UI.messagebox($!.message) }
          diagnostic_menu.add_item('导出日志诊断包') { dispatch(:export_linkhub_log_bundle!) rescue UI.messagebox($!.message) }
          diagnostic_menu.add_item('打开诊断输出文件夹') { dispatch(:lh_diag_open_folder, runtime.const_get(:TEMP_DIAGNOSTIC_DIR)) rescue UI.messagebox($!.message) }
          @linkhub_diagnostic_menu_installed = true
        rescue StandardError => e
          record_runtime_error(e, '建立 LinkHub 只读诊断菜单')
        end
      end
    else
      # 保留兼容分支；v0.13.6.85 的 proxy_worker_mode? 恒为 false。
      file_loaded(__FILE__) unless file_loaded?(__FILE__)
    end
  end
end
