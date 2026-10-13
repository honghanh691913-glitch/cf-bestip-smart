# frozen_string_literal: true

module GavinTools
  module SULinkHubMultiSpace
    module Runtime
    EXTENSION_NAME = 'SU LinkHub 多空间联动' unless const_defined?(:EXTENSION_NAME, false)
    EXTENSION_VERSION = '0.13.7.7'.freeze
    # 从这一版开始，空间编辑域进一步收口：整个 SKP 根层级不能作为空间修改容器，
    # 空间内部原生锁定会被自动撤销；同时继承 13.5.5 的软装落位、冲突阻止和安全快照。
    # 因此低于 0.13.6.18 的协作者仍可能绕过“编辑前必须最新”和强制恢复隔离规则，当前版本会明确提示团队统一升级。
    COLLAB_DATA_SAFETY_MIN_VERSION = '0.13.6.20'.freeze
    DICT = 'SU_LinkHub'.freeze
    PROJECT_KEY = 'project_json'.freeze
    # v0.13.6.82：所有 LinkHub 临时输出统一收口到 %TEMP%\SU_LinkHub，避免在
    # Windows TEMP 根目录散落大量日志/候选文件。日志、状态和工作文件分别归档，
    # 左上角“日志”按钮直接打开 logs 子目录。
    TEMP_BASE_DIR = (ENV['TEMP'].to_s.empty? ? Dir.tmpdir : ENV['TEMP'].to_s).freeze
    TEMP_ROOT_DIR = File.join(TEMP_BASE_DIR, 'SU_LinkHub').freeze
    TEMP_LOG_DIR = File.join(TEMP_ROOT_DIR, 'logs').freeze
    TEMP_STATE_DIR = File.join(TEMP_ROOT_DIR, 'state').freeze
    TEMP_WORK_DIR = File.join(TEMP_ROOT_DIR, 'work').freeze
    TEMP_DIAGNOSTIC_DIR = File.join(TEMP_ROOT_DIR, 'diagnostics').freeze
    TEMP_VISUAL_PROXY_DIR = File.join(TEMP_ROOT_DIR, 'visual_proxy').freeze
    TEMP_PROXY_WORKER_DIR = File.join(TEMP_ROOT_DIR, 'proxy_worker').freeze
    TEMP_PROXY_WORKER_JOB_DIR = File.join(TEMP_PROXY_WORKER_DIR, 'jobs').freeze
    TEMP_PROXY_WORKER_STATUS_DIR = File.join(TEMP_PROXY_WORKER_DIR, 'status').freeze
    begin
      [TEMP_ROOT_DIR, TEMP_LOG_DIR, TEMP_STATE_DIR, TEMP_WORK_DIR, TEMP_DIAGNOSTIC_DIR, TEMP_VISUAL_PROXY_DIR].each do |path|
        FileUtils.mkdir_p(path)
      end
    rescue StandardError
      nil
    end
    LOG_PATH = File.join(TEMP_LOG_DIR, 'SU_LinkHub_v0.13.7.7.log').freeze
    SCHEDULE_TRACE_PATH = File.join(TEMP_LOG_DIR, 'SU_LinkHub_清单诊断_v0.13.7.7.log').freeze
    SUBMIT_TRACE_PATH = File.join(TEMP_LOG_DIR, 'SU_LinkHub_提交诊断_v0.13.7.7.log').freeze
    BACKGROUND_PUBLISH_QUEUE_PATH = File.join(TEMP_STATE_DIR, 'SU_LinkHub_后台发布队列_v0.13.6.100.json').freeze
    BACKGROUND_PUBLISH_HISTORY_PATH = File.join(TEMP_LOG_DIR, 'SU_LinkHub_后台发布历史.jsonl').freeze
    BACKGROUND_PUBLISH_LAST_STAGE_PATH = File.join(TEMP_LOG_DIR, 'SU_LinkHub_后台发布最后阶段.txt').freeze
    BACKGROUND_PUBLISH_TRACE_PATH = File.join(TEMP_LOG_DIR, 'SU_LinkHub_后台发布诊断_v0.13.7.7.log').freeze
    SPACE_PUBLISH_QUEUE_POLL_INTERVAL = 0.12
    SPACE_PUBLISH_QUEUE_MAX_HISTORY = 12
    TASK_CENTER_TRACE_PATH = File.join(TEMP_LOG_DIR, 'SU_LinkHub_任务队列诊断_v0.13.7.7.log').freeze
    TASK_CENTER_MAX_HISTORY = 18
    # Ruby 后台线程只处理不触碰 SketchUp 模型/视图 API 的文件任务。两个 worker
    # 可以让目录扫描、缓存落盘与 Excel 导出互不阻塞，同时避免机械盘/NAS 上过多
    # 并发反而拖慢。相同 task_key 仍严格串行，防止同一目标文件被同时写入。
    BACKGROUND_IO_WORKER_COUNT = 2
    ENTITY_DICT = 'SU_LinkHub_Entity'.freeze
    MANIFEST_SUFFIX = '.sulink.json'.freeze
    LOCK_SUFFIX = '.sulink.lock.json'.freeze
    LOCK_REMOTE_STALE_SECONDS = 600
    LOCAL_MIRROR_KEEP = 3
    LOCAL_MIRROR_NAMESPACE = 'v6'.freeze
    # 第五轮：本地镜像不能只按单个源文件保留 3 份，还要限制跨项目累计容量。
    # 清理只作用于 LOCALAPPDATA 下的 LinkHub 本地缓存，不碰协同目录和用户模型库。
    LOCAL_MIRROR_MAX_BYTES = 20 * 1024 * 1024 * 1024
    LOCAL_MIRROR_MAX_AGE_DAYS = 45
    LOCAL_MIRROR_TEMP_MAX_AGE_SECONDS = 24 * 60 * 60
    LOCAL_MIRROR_RECENT_PROTECT_SECONDS = 10 * 60
    SPACE_BATCH_PREFETCH_WORKERS = 2
    SPACE_BATCH_PREFETCH_POLL_INTERVAL = 0.08
    SPACE_BATCH_CHECKPOINT_EVERY = 6
    REFERENCE_PACKAGE_SUFFIX = '.sulink.ref.skp'.freeze
    REFERENCE_META_SUFFIX = '.sulink.ref.json'.freeze
    COORD_META_SUFFIX = '.sulink.coord.json'.freeze
    COORD_TRACK_SUFFIX = '.sulink.coord.track.json'.freeze
    COORD_SCHEMA = 2
    WORLD_WRAPPER_SCHEMA = 1
    METADATA_DIR_NAME = '_SU_LinkHub数据'.freeze
    METADATA_NOTICE_NAME = '请勿手动修改.txt'.freeze
    HUD_PREF_SECTION = 'SU_LinkHub'.freeze
    HUD_PREF_KEY = 'viewport_status_card_enabled'.freeze
    LINKHUB_ENABLED_PREF_KEY = 'linkhub_enabled'.freeze
    HUD_OVERLAY_ID = 'gavin_tools_su_linkhub_status_card'.freeze
    HUD_OVERLAY_NAME = 'SU LinkHub 视口状态卡'.freeze
    HUD_REVEAL_DELAY = 0.7
    WORKSPACE_OVERLAY_ID = 'gavin_tools_su_linkhub_workspace_toolbar'.freeze
    WORKSPACE_OVERLAY_NAME = 'SU LinkHub 视口抽屉与快捷工具条'.freeze
    WORKSPACE_LEFT_BUTTON_MASK = defined?(MK_LBUTTON) ? MK_LBUTTON : 1
    COLLAB_CACHE_SCHEMA = 1
    PROJECT_COLLAB_SCHEMA = 1
    PROJECT_COLLAB_FILE = '协同.json'.freeze
    PROJECT_SETTINGS_SCHEMA = 1
    PROJECT_PATH_SETTING_KEYS = {
      'soft_model_root' => '软装模型库',
      'soft_material_root' => '软装材质库',
      'hard_material_root' => '硬装材质库',
      'architecture_model_root' => '建筑模型库',
      'architecture_material_root' => '建筑材质库',
      'landscape_model_root' => '景观模型库',
      'landscape_material_root' => '景观材质库',
      'plugin_release_root' => 'LinkHub 插件发布目录'
    }.freeze
    DEFAULT_PLUGIN_RELEASE_ROOT = '//Smwl-20200923ov/ADR方案所/0000共享ADR素材库/协同插件'.freeze
    PLUGIN_UPDATE_SCAN_INTERVAL = 6.0
    PLUGIN_UPDATE_ARCHIVE_SETTLE_SECONDS = 2.0
    COLLAB_FOLDER_NAME = '_SU_LinkHub协同'.freeze
    SPACE_COLLECTION_KEY = 'hard_finish'.freeze
    SOFT_SPACE_COLLECTION_KEY = 'soft_finish'.freeze
    SPACE_COLLECTION_KEYS = [SPACE_COLLECTION_KEY, SOFT_SPACE_COLLECTION_KEY].freeze
    SPACE_COLLECTION_NAME = '硬装＋软装'.freeze
    WORKSPACE_ROLES = %w[architecture hard_finish soft_finish landscape].freeze
    # 锁定根模型仍使用 SketchUp 原生选择轮廓，只在当前选择期间临时换色。
    # 解锁进入编辑后 SketchUp 会继续使用自己的 HighlightColor（默认蓝色）。
    WORKSPACE_LOCKED_SELECTION_COLORS = {
      'architecture' => [74, 180, 242],
      SPACE_COLLECTION_KEY => [239, 181, 52],
      SOFT_SPACE_COLLECTION_KEY => [164, 103, 232],
      'landscape' => [55, 176, 105]
    }.freeze
    ARCHITECTURE_MODELS_FOLDER = '建筑'.freeze
    ARCHITECTURE_MODELS_MANIFEST = '建筑模型.json'.freeze
    ARCHITECTURE_GROUPS_MANIFEST = '建筑分组.json'.freeze
    ARCHITECTURE_MODELS_SCHEMA = 1
    ARCHITECTURE_GROUPS_SCHEMA = 1
    SPACE_MODELS_FOLDER = '软装+硬装'.freeze
    SPACE_MODELS_MANIFEST = '空间模型.json'.freeze
    # 空间分组使用独立共享清单，避免旧版发布/缓存逻辑覆盖布局。
    SPACE_GROUPS_MANIFEST = '空间分组.json'.freeze
    SPACE_GROUPS_SCHEMA = 1
    SPACE_MODELS_SCHEMA = 8
    # v0.13.6.133：协同组件独立于空间文件发布。普通 SU 组件只有用户明确“定义为协同组件”后
    # 才获得项目级稳定 ID；之后组件内容可以单独发布/更新，不要求所有引用空间一起重发。
    SHARED_COMPONENTS_FOLDER = '协同组件'.freeze
    SHARED_COMPONENTS_ASSETS_FOLDER = '组件'.freeze
    SHARED_COMPONENTS_MANIFEST = '协同组件.json'.freeze
    SHARED_COMPONENTS_SCHEMA = 1
    SHARED_COMPONENT_DICT = 'SU_LinkHub_SharedComponent'.freeze
    SHARED_COMPONENT_MANIFEST_CACHE_TTL = 6.0
    PUBLISH_HISTORY_KEEP = 5
    SPACE_PUBLISH_WRAPPER_SCHEMA = 3
    SPACE_LOAD_VERIFIED_SCHEMA = 3
    SPACE_LOCK_STALE_SECONDS = 300
    SINGLE_SPACE_UPDATE_SAFE_WAIT_SECONDS = 600
    NATIVE_RESOURCE_RECONCILE_DELAY = 0.12
    SOFT_DESIGNER_PREF_SECTION = 'SU_LinkHub_SoftDesigner'.freeze
    SOFT_LIBRARY_ROOT_PREF_KEY = 'library_root'.freeze
    SOFT_LIBRARY_LAST_CATEGORY_PREF_KEY = 'last_ingest_category'.freeze
    ARCHITECTURE_BACKUP_DIR_PREF_KEY = 'architecture_backup_dir'.freeze
    ARCHITECTURE_BACKUP_INTERVAL_PREF_KEY = 'architecture_backup_interval_minutes'.freeze
    WORKING_COPY_BACKUP_RECORDS_PREF_KEY = 'working_copy_backup_records_json'.freeze
    ARCHITECTURE_BACKUP_INTERVAL_DEFAULT = 60
    ARCHITECTURE_BACKUP_INTERVAL_MAX = 525_600
    WORKING_COPY_BACKUP_RECORD_LIMIT = 40
    SOFT_LIBRARY_MANAGER_DIR = '_软装模型管理'.freeze
    SOFT_LIBRARY_INDEX_FILE = '模型记录.json'.freeze
    SOFT_LIBRARY_CATALOG_FILE = '目录缓存.json'.freeze
    SOFT_LIBRARY_THUMB_DIR = '缩略图'.freeze
    SOFT_LIBRARY_THUMB_META_FILE = '缩略图索引.json'.freeze
    SOFT_LIBRARY_THUMBNAIL_RENDER_VERSION = 11
    SOFT_LIBRARY_THUMBNAIL_SIZE = 512
    SOFT_LIBRARY_THUMBNAIL_MARGIN = 1.20
    SOFT_LIBRARY_PROXY_DIR = '代理模型'.freeze
    SOFT_LIBRARY_TRASH_DIR = '回收站'.freeze
    SOFT_LIBRARY_CONTAINER_DIR = '软装模型库'.freeze
    SOFT_LIBRARY_ORGANIZED_DIR = '已整理的模型库'.freeze
    SOFT_LIBRARY_LEGACY_ORGANIZED_DIRS = %w[已入库整理模型库 已整理模型库].freeze
    SOFT_LIBRARY_CATALOG_SCHEMA = 2
    SOFT_LIBRARY_SCHEMA = 2
    LIBRARY_WARMUP_INITIAL_DELAY = 0.85
    LIBRARY_WARMUP_RETRY_DELAY = 0.55
    LIBRARY_WARMUP_MAX_RETRIES = 12
    SOFT_MODEL_DICT = 'SU_LinkHub_SoftModel'.freeze
    SOFT_FURNITURE_TAG = '软装'.freeze
    # 单面图片/面片只承担空间中的视觉指代，不应再生成六面代理。几何上允许
    # 一轴为 0，但采购清单必须由用户另行补齐真实物品的三维规格后才能导出。
    SOFT_PLANAR_REFERENCE_EPSILON_MM = 0.05
    SOFT_SCHEDULE_DIMENSIONS_ATTRIBUTE = 'schedule_dimensions_mm'.freeze
    SOFT_PLANAR_PROXY_KIND = 'native_planar_passthrough'.freeze
    SOFT_AXIS_ALIGNMENT_SCHEMA = 2
    SOFT_AXIS_ALIGNMENT_MIN_SCORE = 0.985
    # 只改轴必须是肉眼与数值上都不移动模型。这里约为 0.000254mm，仅用于
    # 吸收双精度矩阵往返的末位误差，不允许用毫米级容差掩盖真实旋转或位移。
    SOFT_AXIS_WORLD_BOUNDS_TOLERANCE_INCHES = 1.0e-5
    SOFT_LIBRARY_CATEGORIES = %w[家具 灯具 窗帘 地毯 挂画 摆件 其他].freeze
    SOFT_LIBRARY_SUBCATEGORIES = {
      '家具' => %w[沙发 椅子 凳子 桌子 茶几 柜体 床 床头柜 屏风 茶台 置物架 其他家具],
      '灯具' => %w[吊灯 吸顶灯 壁灯 台灯 落地灯 筒灯 射灯 灯带 轨道灯 装饰灯 其他灯具],
      '窗帘' => %w[布帘 纱帘 布帘+纱帘 卷帘 香格里拉帘 百叶帘 罗马帘 垂直帘 帘头 窗帘轨道 其他窗帘],
      '地毯' => %w[客厅地毯 卧室地毯 餐厅地毯 走廊地毯 门垫 满铺地毯 异形地毯 其他地毯],
      '挂画' => %w[装饰画 艺术画 摄影作品 油画 国画 版画 挂毯 镜框画 组合画 其他挂画],
      '摆件' => %w[抱枕 花艺 绿植 雕塑 器皿 烛台 书籍 摆钟 镜子 收纳 装饰品 其他摆件],
      '其他' => %w[其他]
    }.freeze
    SOFT_LIBRARY_CATEGORY_ALIASES = {
      '家具' => '家具', '家私' => '家具', '桌椅' => '家具', '床具' => '家具', '沙发' => '家具', '椅子' => '家具', '凳子' => '家具', '桌子' => '家具',
      '茶几' => '家具', '柜子' => '家具', '柜体' => '家具', '床' => '家具', '床头柜' => '家具',
      '屏风' => '家具', '茶台' => '家具', '置物架' => '家具',
      '灯具' => '灯具', '灯光' => '灯具', '灯饰' => '灯具', '照明' => '灯具', '吊灯' => '灯具', '吸顶灯' => '灯具', '壁灯' => '灯具',
      '台灯' => '灯具', '落地灯' => '灯具', '筒灯' => '灯具', '射灯' => '灯具', '灯带' => '灯具',
      '轨道灯' => '灯具', '装饰灯' => '灯具',
      '窗帘' => '窗帘', '窗饰' => '窗帘', '布帘' => '窗帘', '纱帘' => '窗帘', '卷帘' => '窗帘', '香格里拉帘' => '窗帘',
      '百叶帘' => '窗帘', '罗马帘' => '窗帘', '垂直帘' => '窗帘', '帘头' => '窗帘',
      '地毯' => '地毯', '地垫' => '地毯', '门垫' => '地毯',
      '挂画' => '挂画', '壁画' => '挂画', '画作' => '挂画', '装饰画' => '挂画', '艺术画' => '挂画', '摄影作品' => '挂画',
      '油画' => '挂画', '国画' => '挂画', '版画' => '挂画', '挂毯' => '挂画', '组合画' => '挂画',
      '摆件' => '摆件', '抱枕' => '摆件', '花艺' => '摆件', '绿植' => '摆件', '雕塑' => '摆件',
      '器皿' => '摆件', '烛台' => '摆件', '书籍' => '摆件', '摆钟' => '摆件', '镜子' => '摆件',
      '收纳' => '摆件', '装饰品' => '摆件', '饰品' => '摆件',
      '其他' => '其他', '未分类' => '其他'
    }.freeze
    LANDSCAPE_LIBRARY_PREF_SECTION = 'SU_LinkHub_LandscapeLibrary'.freeze
    LANDSCAPE_LIBRARY_ROOT_PREF_KEY = 'library_root'.freeze
    LANDSCAPE_LIBRARY_MANAGER_DIR = '_景观模型管理'.freeze
    LANDSCAPE_LIBRARY_THUMB_DIR = '缩略图'.freeze
    LANDSCAPE_LIBRARY_THUMB_META_FILE = '缩略图索引.json'.freeze
    LANDSCAPE_LIBRARY_CATALOG_FILE = '目录缓存.json'.freeze
    LANDSCAPE_LIBRARY_SCAN_LIMIT = 800
    LANDSCAPE_MODEL_DICT = 'SU_LinkHub_LandscapeModel'.freeze
    ARCHITECTURE_LIBRARY_PREF_SECTION = 'SU_LinkHub_ArchitectureLibrary'.freeze
    ARCHITECTURE_LIBRARY_ROOT_PREF_KEY = 'library_root'.freeze
    # 建筑、室内、景观分别拥有独立材质库。材质的可见资产以 PNG 存放在分类
    # 文件夹中；颜色、透明度、纹理实际尺寸等恢复信息集中写入隐藏管理目录，
    # 避免在用户分类目录旁散落大量 sidecar 文件。
    MATERIAL_LIBRARY_PREF_SECTION = 'SU_LinkHub_MaterialLibrary'.freeze
    MATERIAL_LIBRARY_ROOT_PREF_KEYS = {
      'architecture' => 'architecture_root',
      SPACE_COLLECTION_KEY => 'interior_root',
      SOFT_SPACE_COLLECTION_KEY => 'soft_root',
      'landscape' => 'landscape_root'
    }.freeze
    MATERIAL_LIBRARY_LAST_CATEGORY_PREF_KEYS = {
      'architecture' => 'architecture_last_category',
      SPACE_COLLECTION_KEY => 'interior_last_category',
      SOFT_SPACE_COLLECTION_KEY => 'soft_last_category',
      'landscape' => 'landscape_last_category'
    }.freeze
    MATERIAL_LIBRARY_MANAGER_DIR = '_材质库管理'.freeze
    MATERIAL_LIBRARY_INDEX_FILE = '材质索引.json'.freeze
    MATERIAL_LIBRARY_SCHEMA = 1
    MATERIAL_LIBRARY_SCAN_LIMIT = 1600
    MATERIAL_LIBRARY_SOLID_IMAGE_SIZE = 256
    MATERIAL_LIBRARY_DICT = 'SU_LinkHub_MaterialLibrary'.freeze
    LIBRARY_USAGE_PREF_SECTION = 'SU_LinkHub_LibraryUsage'.freeze
    LIBRARY_USAGE_PREF_KEY = 'usage_json_v1'.freeze
    LIBRARY_USAGE_SCHEMA = 1
    LIBRARY_USAGE_RECENT_LIMIT = 20
    SOFT_LIBRARY_SCAN_LIMIT = 800
    # v0.13.6.23：严格六视图代理。白盒仅保留历史识别代码，不再允许新建/回退。
    SOFT_REQUIRE_VISUAL_PROXY = true
    # 六面代理映射位于 NAS 时，反复切换不应每款都重新 stat 映射 JSON。
    SOFT_VISUAL_PROXY_REGISTRY_CACHE_TTL = 30.0
    # 模型库并发写基线需要短期保留，但只读调用不能无限堆积深拷贝。
    SOFT_LIBRARY_INDEX_BASE_MAX = 24
    SOFT_LIBRARY_INDEX_BASE_TTL = 300.0
    # v0.13.6.27：软装代/真切换采用“会话驻留 + 生命周期回收”。
    # 交互切回代理时只换实例 Definition，绝不立刻删除高模，避免 0.13.6.22~24
    # 出现的“视觉已切回代理，1~2 秒后 Definition 清理把 SU 卡死”的问题。
    SOFT_SESSION_RESIDENT_FULL_DEFINITIONS = true
    # 发布成功只把当前空间高模标为“可回收”，绝不把回收串进发布事务。
    # v0.13.6.161 现场日志证明，6 秒后立即回收会把刚解析的 43 款高模逐个删掉，
    # 用户下一次切真又要在主线程完整重载约 39 秒。改为保留 20 分钟热窗口；一旦
    # 超过空间数/定义数上限，压力回收仍会立即按 LRU 让出内存，低配电脑不会无限增长。
    SOFT_RESIDENT_CACHE_PUBLISH_GRACE_SECONDS = 20 * 60.0
    SOFT_RESIDENT_CACHE_IDLE_SECONDS = 2.5
    SOFT_RESIDENT_CACHE_STEP_DELAY = 0.45
    SOFT_RESIDENT_CACHE_RETRY_DELAY = 1.0
    SOFT_RESIDENT_CACHE_HEAVY_STEP_MS = 80.0
    SOFT_RESIDENT_CACHE_MAX_REMOVALS_PER_CYCLE = 12
    # 缓存上限按“最近使用空间 + 顶层高模 Definition”控制。超过上限只淘汰
    # 最久未使用、当前没有任何真模型实例的 Definition，不扫描 model.definitions。
    SOFT_RESIDENT_CACHE_MAX_SPACES = 2
    SOFT_RESIDENT_CACHE_MAX_DEFINITIONS = 48
    # v0.13.6.24：代→真时保留“这个实例原来实际正在显示的六视图代理 Definition”。
    # 真→代优先直接复用这份会话代理，不再重新依赖 NAS 映射/索引解析。
    SOFT_SESSION_VISUAL_PROXY_CACHE_MAX = 2048
    # 建筑/景观以参考协调为主，默认坚持家具代理。只有用户明确点击真模型时才加载，
    # 且大规模项目会要求先选中单个空间，避免一次把全部高模灌入当前模型。
    SOFT_PROXY_FIRST_HOSTS = %w[architecture landscape].freeze
    SOFT_GLOBAL_FULL_MAX_INSTANCES = 400
    SOFT_GLOBAL_FULL_MAX_UNIQUE_MODELS = 60
    SOFT_GLOBAL_FULL_MAX_SOURCE_BYTES = 600 * 1024 * 1024
    # 大项目安全阈值。它们不会阻止载入，只用于限制附加扫描并给出明确日志，
    # 避免建筑/景观/室内参考已经很大时，容器标记目录等次要工作再次长时间占用主线程。
    LINK_LARGE_SOURCE_BYTES = 300 * 1024 * 1024
    LINK_VERY_LARGE_SOURCE_BYTES = 800 * 1024 * 1024
    LINK_TAG_SCAN_LIMIT_NORMAL = 120_000
    LINK_TAG_SCAN_LIMIT_LARGE = 60_000
    LINK_TAG_SCAN_LIMIT_VERY_LARGE = 25_000
    SOFT_FULL_DEFINITION_CLEANUP_BATCH = 24
    SOFT_FULL_DEFINITION_CLEANUP_DELAY = 1.2
    # 热重载只替换 Ruby 运行时，SketchUp 模型中的组件定义仍然存在。将经过
    # 有效性校验的代/真切换索引暂存到不会被 remove_const(:Runtime) 删除的
    # 启动命名空间中，下一代运行时直接接回，避免每次升级后的第一次切换重新冷扫描。
    SOFT_HOT_RELOAD_CACHE_SCHEMA = 6
    SOFT_IDENTITY_CLASSIFIER_SCHEMA = 2
    SOFT_HOT_RELOAD_CACHE_MAX_AGE = 600.0
    # 后台预热以“视口流畅优先”为原则：批量更小、间隔更长，并且只有在
    # 最近没有建模、选择、抽屉动画或其他重操作时才运行。预热慢一点没有关系，
    # 不能为了提前几秒填满缓存而持续抢占 SketchUp 主线程。
    SOFT_CACHE_WARMUP_DEFINITION_BATCH = 24
    SOFT_CACHE_WARMUP_BOUNDS_BATCH = 2
    SOFT_CACHE_WARMUP_INTERVAL = 0.16
    # 第四轮：代/真切换缓存从“单次点击临时 Hash”升级为模型级缓存。
    # 同一对代理/真模型定义只做一次有效外包盒核对；模型定义变化或原生清理后失效。
    SOFT_REPRESENTATION_PAIR_CACHE_MAX = 4096
    SOFT_DEFINITION_BOUNDS_ATTRIBUTE_SCHEMA = 1
    # 未使用的受管定义改为空闲分批清理，避免更新/删除/切回代理后同步遍历六轮 definitions。
    SOFT_MANAGED_DEFINITION_CLEANUP_BATCH = 28
    SOFT_MANAGED_DEFINITION_CLEANUP_DELAY = 0.85
    SOFT_MANAGED_DEFINITION_CLEANUP_MAX_PASSES = 10
    # 模型库 SKP/代理 SKP 的 stat 结果只用于资源缓存，不参与协同发布真相判断。
    # 短 TTL 可消除一次代/真切换中反复访问 NAS，同时源文件修改后很快自动失效。
    SOFT_LIBRARY_FILE_SIGNATURE_TTL = 2.0
    # 同一帧内清单、属性面板和缩略图队列经常连续读取同一个 NAS 索引。
    # 一秒以内直接复用已经校验过的数据，避免每个入口都重新 stat 网络文件。
    SOFT_LIBRARY_INDEX_CACHE_TTL = 0.85
    # 模型库目录通常位于 NAS。代/真切换的热路径只需读取索引，不应每次都对
    # 六个目录重复 mkdir/stat；短 TTL 仍能让用户手动删除或切换库路径后快速自愈。
    # 模型库根路径变化时 set_soft_library_root 会明确清空缓存；没有必要让每次
    # 用户改完一项资料、思考几秒后提交时，都重新对 NAS 上十余个目录执行 mkdir/stat。
    # 索引文件本身仍会在每次提交时重新读取并做并发合并，因此延长结构缓存不会
    # 放宽共享盘在线校验或索引安全。
    SOFT_LIBRARY_STRUCTURE_CACHE_TTL = 300.0
    BACKGROUND_WORK_IDLE_SECONDS = 0.38
    BACKGROUND_WORK_RETRY_SECONDS = 0.22
    # Definition#save_as/save_copy 属于 SketchUp 原生主线程接口，放进 Ruby Thread 会有
    # 随机崩溃风险。空间发布先进入可避让的本机候选准备队列：用户处于组件层级、
    # 刚有交互或仍在转动相机时不启动，等世界根视图稳定后再执行唯一一次原生保存。
    NATIVE_SPACE_PUBLISH_PREP_IDLE_SECONDS = 1.25
    # 用户刚点击“发布”后已经由 LinkHub 主动退出并锁回目标空间。只要鼠标工具、
    # 相机和其它重任务都空闲，就使用更短的交接窗口；用户若马上 Orbit/进入其它
    # 空间，后面的硬门禁仍会让出主线程。
    NATIVE_SPACE_PUBLISH_PREP_FAST_IDLE_SECONDS = 0.22
    # ModelObserver transaction 不等同于真实前台交互。插件自己的属性/状态事务也会触发
    # onTransactionCommit；若仍按 1.25s 重新计时，发布候选可能永久停在 2%“等待前台操作停稳”。
    # 对 transaction 只留一个很短的提交后缝隙；若插件事务连续不断，最多等待几秒后自动放行，
    # 真正的 active_path、工具条交互、相机运动和发布/更新临界区仍然是硬门禁。
    NATIVE_SPACE_PUBLISH_PREP_TRANSACTION_IDLE_SECONDS = 0.22
    NATIVE_SPACE_PUBLISH_PREP_TRANSACTION_MAX_WAIT_SECONDS = 4.0
    NATIVE_SPACE_PUBLISH_PREP_WAIT_DIAGNOSTIC_SECONDS = 5.0
    NATIVE_SPACE_PUBLISH_CAMERA_QUIET_SECONDS = 0.55
    NATIVE_SPACE_PUBLISH_PREP_RETRY_SECONDS = 0.16
    # v0.13.6.151：家具编辑退出检测到真实修改后恢复就地“是否立即更新代理”确认。
    # 默认“否”只保存真模型并登记待处理，完全退出空间后统一生成；“是”优先处理当前这一款。
    # 这样工作阶段保持流畅，把 View#write_image 的卡顿集中到明确的“退出工作区”阶段。
    SOFT_VISUAL_PROXY_QUEUE_SCAN_INTERVAL = 0.05
    SOFT_VISUAL_PROXY_EXTERNAL_POLL_INTERVAL = 0.22
    SOFT_VISUAL_PROXY_EXTERNAL_START_TIMEOUT = 45.0
    SOFT_VISUAL_PROXY_EXTERNAL_JOB_TIMEOUT = 360.0
    SOFT_VISUAL_PROXY_EXTERNAL_FINALIZE_IDLE_SECONDS = 0.08
    # 仅用于非 Windows/热重载遗留任务的兼容分片路径。
    SOFT_VISUAL_PROXY_QUEUE_START_IDLE_SECONDS = 0.28
    SOFT_VISUAL_PROXY_QUEUE_ACTIVE_IDLE_SECONDS = 0.08
    SOFT_VISUAL_PROXY_QUEUE_WAIT_RETRY_SECONDS = 0.12
    SOFT_VISUAL_PROXY_QUEUE_SLICE_INTERVAL = 0.08
    # v0.13.6.184：六面截图按时间预算分片。每个 driver tick 至少拍 1 个方向，超过预算就交还主线程；
    # 退出空间的前台批处理允许稍长的片段（此时用户本来就在等待）。
    SOFT_VISUAL_PROXY_CAPTURE_TICK_BUDGET = 0.14
    SOFT_VISUAL_PROXY_CAPTURE_TICK_BUDGET_EXIT_BATCH = 0.60
    # 载入/切代理后自动修复丢失代理：每轮最多自动排队的家具款数（超出部分下次再补）。
    SOFT_LOST_PROXY_AUTO_REPAIR_MAX_MODELS_PER_ROUND = 30
    # v0.13.6.94：六面代理队列只允许一个主线程 driver 定时器推进；watchdog 仅负责
    # 在 timer 丢失/热重载残留状态时重新挂起 driver，不并发执行 SketchUp API。
    SOFT_VISUAL_PROXY_DRIVER_WATCHDOG_INTERVAL = 1.25
    SOFT_VISUAL_PROXY_DRIVER_STALE_SECONDS = 6.0
    SOFT_VISUAL_PROXY_TASK_ORPHAN_GRACE_SECONDS = 3.0
    # 清单页以观察器和事务脏标记为主，只保留低频兜底轮询。旧版每 0.65 秒
    # 递归扫描全部空间，即使没有变化也会制造周期性微卡。
    SOFT_MEASUREMENT_POLL_INTERVAL = 4.5
    SOFT_MEASUREMENT_OBSERVER_RESCAN_INTERVAL = 8.0
    SOFT_MEASUREMENT_REFRESH_BURST_DELAYS = [0.48, 1.20].freeze
    # 多个观察器/定时器在同一事务后经常同时请求完整界面刷新。把 120ms 内的
    # 重复请求合并成一次，既不会让按钮显得迟钝，也能避免连续 public_state 扫描。
    REFRESH_DIALOG_MIN_INTERVAL = 0.12
    # 防止 HtmlDialog / Overlay 在一次鼠标点击中重复派发同名动作。这里只拦截
    # 极短时间内的重复入口，不改变长任务自身的发布、更新和模型库占用判断。
    RUNTIME_ACTION_DEBOUNCE_SECONDS = 0.42
    # Overlay 不经过 HtmlDialog 的 safe_callback。非纯视觉动作增加独立的模型级
    # 占用与短冷却，防止双击造成重复发布、重复更新或连续代/真切换。
    WORKSPACE_ACTION_COOLDOWN_SECONDS = 0.65
    PERFORMANCE_SLOW_OPERATION_MS = 80.0
    # 模型库打开时只提取源 SKP 内已经保存的内置缩略图，不再自动载入模型、
    # 建立临时舞台或计算等轴测视角。固定等轴测缩略图仅由卡片右上角的手动刷新
    # 触发，并直接写回对应源 SKP；因此已处理模型跨窗口、跨 SketchUp 重启复用。
    SOFT_LIBRARY_THUMBNAIL_BATCH = 8
    SOFT_LIBRARY_THUMBNAIL_INTERVAL = 0.18
    SOFT_LIBRARY_THUMBNAIL_IDLE_SECONDS = 0.55
    SOFT_LIBRARY_THUMBNAIL_MODE = 'source_embedded_axis963_native_white_native_codec_v7_batch'.freeze
    # 用户已经在原生确认框中明确选择提交，不再额外等待倒计时。
    PUBLISH_CONFIRM_SECONDS = 0
    # SketchUp 在一次 model.save / definition.save_as 返回后，仍可能有原生资源、
    # 缩略图和观察器回调处于收尾阶段。连续快速发布会把第二次保存叠加到这段
    # 原生收尾窗口，是“第一次成功、第二次短间隔直接闪退”的高风险路径。
    PUBLISH_MIN_INTERVAL_SECONDS = 3.0
    # model.save 与随后的 definition.save_as 之间暂时保留短安全窗口。完整移除该
    # 等待需要把三条发布路径改造成分阶段任务；第一版不以闪退风险换取表面速度。
    PUBLISH_POST_SAVE_SETTLE_SECONDS = 0.45
    # 室内空间发布不再先保存整份工作 SU；仅在存在未保存修改时写本机当前空间恢复快照。
    # 快照只序列化当前空间 Definition，通常远小于整个项目；保留极短原生收尾窗口，
    # 避免 SU 2025/2026 连续 definition.save_copy/save_as 叠加。
    SPACE_PUBLISH_RECOVERY_SETTLE_SECONDS = 0.16
    PUBLISH_POST_QUIET_SECONDS = 2.0
    NATIVE_LOCK_MONITOR_INTERVAL = 3.0
    NATIVE_LOCK_HEARTBEAT_INTERVAL = 45.0
    SPACE_PRESENCE_MONITOR_INTERVAL = 20.0
    # v0.13.6.189：写往网络共享的大文件分块复制（见 linkhub_copy_file）。
    LINKHUB_COPY_CHUNK_BYTES = 8 * 1024 * 1024
    LINKHUB_COPY_MIN_CHUNKED_BYTES = 4 * 1024 * 1024
    LINKHUB_HASH_CHUNK_BYTES = 4 * 1024 * 1024
    # v0.13.6.189：linkhub_mv 对共享盘瞬时占用（EACCES/EBUSY）的短重试间隔。
    LINKHUB_MV_RETRY_DELAYS = [0.04, 0.12, 0.3].freeze
    # v0.13.6.189：自检识别 LinkHub 原子写入遗留的临时文件（name.tmp-<pid>-<hex>[.png|.xlsx]）。
    LINKHUB_WRITE_TEMP_LEFTOVER_PATTERN = /\.tmp-(?:fast-)?\d+-[0-9a-f]{4,10}(?:\.png|\.xlsx)?\z/
    # v0.13.6.189：后台线程 GVL 让渡泵（见 ensure_background_gvl_pump!）。
    # 主线程每 50ms 短暂休眠一次，把 Ruby GVL 交给发布/镜像/后台写入线程；
    # 主线程繁忙或用户刚操作时只让出 3ms，空闲时让出 16ms。
    BACKGROUND_GVL_PUMP_INTERVAL = 0.05
    BACKGROUND_GVL_PUMP_IDLE_SLICE = 0.016
    BACKGROUND_GVL_PUMP_BUSY_SLICE = 0.003
    BACKGROUND_GVL_PUMP_INTERACTION_SECONDS = 0.8
    SOFT_SCHEDULE_IDLE_REFRESH_SECONDS = 1.25
    SOFT_SCHEDULE_THUMBNAIL_BACKGROUND_INTERVAL = 0.90
    # 成功返回后继续保留崩溃追踪数秒，覆盖延迟定义清理和界面恢复窗口。
    PUBLISH_JOURNAL_TAIL_SECONDS = 5.0
    PUBLISH_JOURNAL_SCHEMA = 1
    PUBLISH_DIAGNOSTIC_DIR_NAME = 'SU_LinkHub_诊断'.freeze
    PUBLISH_ACTIVE_JOURNAL_NAME = 'SU_LinkHub_发布进行中.json'.freeze
    PUBLISH_HISTORY_NAME = 'SU_LinkHub_发布历史.jsonl'.freeze
    PUBLISH_LAST_STAGE_NAME = 'SU_LinkHub_发布最后阶段.txt'.freeze
    SPACE_DELETE_CONFIRM_SECONDS = 5
    PROJECT_SCHEMA = 37
    # 编辑状态安全切换与根模型结构保护。所有检测都在 ModelObserver 回调后的
    # 空闲帧执行，不在观察器回调中直接写模型。
    EDIT_STRUCTURE_AUDIT_DELAY = 0.16
    EDIT_TRANSITION_QUIET_SECONDS = 0.28
    EDIT_DEEP_SCAN_LIMIT = 6_000
    EDIT_ROOT_GUARD_LIMIT = 5_000

    # 模型/材质库统一吸管工具。没有预先选择对象时，工具条吸管直接进入
    # 视口取样模式：优先拾取鼠标下最深层组件/群组，若没有组件则拾取裸面材质。
    # 这样无需“先选中 -> 再点吸管”，同时保留原来的预选快速入库路径。
    end
  end
end
