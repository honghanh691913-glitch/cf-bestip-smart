# frozen_string_literal: true

require 'sketchup.rb'
require 'extensions.rb'

module GavinTools
  # 使用插件独占命名空间。旧的 GavinTools::SULinkHub 曾被其他插件复制使用，
  # 会导致常量和启动方法互相覆盖，并把 runtime.rb 错指到其他插件目录。
  module SULinkHubMultiSpace
    EXTENSION_NAME = 'SU LinkHub 多空间联动' unless const_defined?(:EXTENSION_NAME, false)
    EXTENSION_VERSION = '0.13.7.4' unless const_defined?(:EXTENSION_VERSION, false)

    unless file_loaded?(__FILE__)
      extension = SketchupExtension.new(EXTENSION_NAME, 'su_linkhub/main')
      extension.description = '建筑、硬装、软装、景观四工作区多空间协同。支持后缀自动归类、楼层代码自动分组、局域网镜像、模型/材质库、家具代理与采购清单。'
      extension.version = EXTENSION_VERSION
      extension.creator = 'Gavin Tools'
      extension.copyright = '2026 Gavin Tools'
      Sketchup.register_extension(extension, true)
      file_loaded(__FILE__)
    end
  end
end
