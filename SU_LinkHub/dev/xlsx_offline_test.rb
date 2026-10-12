# frozen_string_literal: true

# Offline harness for the soft-schedule Excel exporter (no SketchUp needed).
# It extracts the exporter methods from src/su_linkhub/runtime.rb, stubs the few
# SketchUp/plugin dependencies, builds sample rows and writes an .xlsx.
#
# Usage: ruby SU_LinkHub/dev/xlsx_offline_test.rb [output.xlsx]
# Sample images are generated with ImageMagick `convert` into /tmp.

require 'json'
require 'fileutils'
require 'pathname'
require 'securerandom'
require 'zlib'
require 'rexml/document'

RUNTIME = File.expand_path('../src/su_linkhub/runtime.rb', __dir__)
CONSTANTS = File.expand_path('../src/su_linkhub/constants.rb', __dir__)

def extract_methods(path, name_pattern)
  lines = File.readlines(path, encoding: 'UTF-8')
  out = []
  i = 0
  while i < lines.length
    m = lines[i].match(/\A(\s*)def ([a-z_0-9!?]+)/)
    if m && m[2].match?(name_pattern)
      indent = m[1]
      j = i + 1
      j += 1 until j >= lines.length || lines[j].rstrip == "#{indent}end"
      out << lines[i..j].join
      i = j + 1
    else
      i += 1
    end
  end
  out
end

def extract_constants(path, name_pattern)
  File.readlines(path, encoding: 'UTF-8').select { |l| l.match?(/\A\s*(#{name_pattern})\s*=/) }.join
end

module ExportHarness
  extend self
  EXTENSION_VERSION = 'offline'
  SOFT_LIBRARY_CATEGORIES = %w[家具 灯具 窗帘 地毯 挂画 摆件 其他].freeze

  module FastPath
    def self.expand(path) = File.expand_path(path.to_s)
  end

  def log_exception(message, error) = warn("#{message}: #{error.class}: #{error.message}\n#{error.backtrace&.first(5)&.join("\n")}")
  def linkhub_mv(src, dst) = FileUtils.mv(src, dst)
  def soft_thumbnail_display_path(path) = path.to_s
  def soft_library_default_subcategory(_category) = '其他'
  def soft_library_canonical_top_category(category) = category.to_s
  def soft_schedule_seat_height_value(row) = row['seat_height'].to_s
  def soft_schedule_compose_remark(remark, manufacturer, contact) = [remark, manufacturer, contact].map(&:to_s).reject(&:empty?).join(' / ')
  def soft_schedule_round_dimension_mm(value) = value.to_f
  def image_media_embeddable_info(path)
    return nil unless File.file?(path)
    head = File.binread(path, 8)
    return { extension: 'png', content_type: 'image/png' } if head.start_with?("\x89PNG".b)
    return { extension: 'jpg', content_type: 'image/jpeg' } if head.start_with?("\xFF\xD8".b)
    nil
  end
end

src = extract_constants(RUNTIME, 'XLSX_[A-Z_]+')
methods = extract_methods(RUNTIME, /\A(xlsx_|soft_schedule_(export|expand|sort|apply_unique|summary|category|supplemental|append|dimension_text|numeric_price|total_price|measure_export)|write_stored_zip|validate_xlsx|validate_soft_schedule_xlsx|write_soft_schedule_xlsx)/)
ExportHarness.module_eval(src + methods.join("\n"), RUNTIME)

# When loaded by another test only the helpers above are needed.
return unless File.expand_path($PROGRAM_NAME) == File.expand_path(__FILE__)

def sample_image(path, label, color, w = 512, h = 512)
  return path if File.file?(path)
  system('convert', '-size', "#{w}x#{h}", 'xc:white', '-fill', color, '-draw', "roundrectangle #{w / 6},#{h / 4} #{w * 5 / 6},#{h * 3 / 4} 30,30",
         '-fill', 'black', '-pointsize', (w / 10).to_s, '-gravity', 'center', '-annotate', '+0+0', label, path) || raise('convert failed')
  path
end

out = ARGV[0] || '/tmp/linkhub_export_test.xlsx'
img_dir = '/tmp/linkhub_xlsx_imgs'
FileUtils.mkdir_p(img_dir)
images = {
  bed: sample_image("#{img_dir}/bed.png", 'BED', '#a58d6f'),
  cab: sample_image("#{img_dir}/cab.png", 'CAB', '#5b4636'),
  lamp: sample_image("#{img_dir}/lamp.png", 'LAMP', '#d9c7a7', 256, 512),
  wide: sample_image("#{img_dir}/wide.png", 'SOFA', '#9f9a8f', 800, 300)
}

def row(name, category, sub, dims, quantity, spaces, variant, image, extra = {})
  {
    'name' => name, 'display_name' => name, 'base_name' => name, 'category' => category, 'subcategory' => sub,
    'length_mm' => dims[0], 'width_mm' => dims[1], 'height_mm' => dims[2], 'quantity' => quantity,
    'spaces' => spaces.map { |s| s[1] }, 'space_ids' => spaces.map { |s| s[0] }, 'space_names' => spaces.map { |s| s[1] }.join('、'),
    'variant_key' => variant, 'model_id' => variant, 'thumbnail_path' => image.to_s, 'price' => extra.delete('price').to_s,
    'remark' => extra.delete('remark').to_s, 'extra_fields' => extra
  }
end

s17 = ['s17', '17:三层大客房']
s23 = ['s23', '23:三层标间3']
s25 = ['s25', '25:三层标间4']
total_rows = [
  row('柜子（行李柜）', '家具', '柜子', [1400, 500, 420], 3, [s17, s23], 'v1', images[:cab], 'color' => '深棕色', 'price' => '1200'),
  row('床头柜（大客房）', '家具', '柜子', [450, 450, 450], 2, [s17], 'v2', images[:cab], 'color' => '黑色做旧'),
  row('沙发（沙发垫1）', '家具', '沙发', [2045, 1055, 600], 1, [s17], 'v3', images[:wide], 'remark' => '面料需提供小样确认，颜色以样板为准，靠包另配'),
  row('台灯（蓝色陶瓷底座）', '灯具', '台灯', [420, 420, 405], 4, [s17, s23, s25], 'v4', images[:lamp]),
  row('编织吊灯', '灯具', '吊灯', [5, 5, 1150], 1, [s25], 'v5', ''),
  row('床', '家具', '床', [1800, 2000, 1100], 2, [s23, s25], 'v6', images[:bed], 'price' => '3500')
]
spaces = [
  { 'id' => 's17', 'label' => '17:三层大客房', 'rows' => [
    { 'variant_key' => 'v1', 'quantity' => 2 }, { 'variant_key' => 'v2', 'quantity' => 2 }, { 'variant_key' => 'v3', 'quantity' => 1 },
    { 'variant_key' => 'v4', 'quantity' => 2 }
  ] },
  { 'id' => 's23', 'label' => '23:三层标间3', 'rows' => [
    { 'variant_key' => 'v1', 'quantity' => 1 }, { 'variant_key' => 'v4', 'quantity' => 1 }, { 'variant_key' => 'v6', 'quantity' => 1 }
  ] },
  { 'id' => 's25', 'label' => '25:三层标间4', 'rows' => [
    { 'variant_key' => 'v4', 'quantity' => 1 }, { 'variant_key' => 'v5', 'quantity' => 1 }, { 'variant_key' => 'v6', 'quantity' => 1 }
  ] }
]
total_rows[2]['supplemental_photos'] = [{ 'path' => images[:bed], 'name' => '实物1' }]

h = ExportHarness
space_rows = h.soft_schedule_expand_rows_by_space(total_rows, spaces)
raise 'quantity lost in expansion' unless space_rows.sum { |r| r['quantity'] } == total_rows.sum { |r| r['quantity'] }
sheets = []
title, headers, rows, groups = h.soft_schedule_summary_table(space_rows, project_name: '测试项目')
sheets << { name: '总表', title: title, headers: headers, rows: rows, row_groups: groups }
h::SOFT_LIBRARY_CATEGORIES.first(2).each do |category|
  t, hd, r, g = h.soft_schedule_category_table(space_rows, category, project_name: '测试项目')
  sheets << { name: category, title: t, headers: hd, rows: r, row_groups: g }
end
t, hd, r, = h.soft_schedule_summary_table(total_rows, project_name: '测试项目', title_override: '软装按款汇总（测试项目，跨空间合并数量）')
sheets << { name: '按款汇总', title: t, headers: hd, rows: r }
sheets = Marshal.load(Marshal.dump(sheets))
FileUtils.rm_f(out)
h.write_soft_schedule_xlsx!(out, sheets, progress: ->(pct, stage, detail = '') { puts "#{pct}% #{stage} #{detail}" if ENV['VERBOSE'] })
puts "wrote #{out} (#{File.size(out)} bytes)"
puts "space labels: #{rows.map { |cells| cells[1] }.uniq.join(' | ')}"
puts "groups: #{groups.inspect}"
