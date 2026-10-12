# frozen_string_literal: true

# Offline test for same-item merging in the soft schedule (no SketchUp needed).
# Usage: ruby SU_LinkHub/dev/schedule_merge_test.rb
require 'json'
require 'digest'
load File.expand_path('xlsx_offline_test.rb', __dir__) unless defined?(extract_methods)

module MergeHarness
  extend self
  def log_exception(message, error) = raise("#{message}: #{error.message}")
  def soft_library_canonical_top_category(category) = category.to_s
  def soft_schedule_sort_rows(rows) = rows
  def merge_soft_material_groups!(target, source)
    Hash(source).each { |k, v| target[k] = (Array(target[k]) + Array(v)).uniq }
  end
end
runtime = File.expand_path('../src/su_linkhub/runtime.rb', __dir__)
src = File.readlines(runtime, encoding: 'UTF-8').each_with_index.select { |l, _| l.match?(/\A\s*SOFT_SCHEDULE_PRIMARY_FIELDS = /) }.map(&:last).first
lines = File.readlines(runtime, encoding: 'UTF-8')
const = lines[src..(src + 4)].join
MergeHarness.module_eval(const + extract_methods(runtime, /\A(soft_schedule_(merge|row_member|absorb|apply_unique)|soft_model_name_key|merge_soft_measurement_space_rows)/).join("\n"))

def r(id, name, qty, space, dims = [1400, 500, 420], mats = { '木' => ['深棕'] })
  { 'model_id' => id, 'variant_key' => "#{id}|#{dims.join('|')}", 'name' => name, 'base_name' => name, 'category' => '家具',
    'subcategory' => '柜子', 'length_mm' => dims[0], 'width_mm' => dims[1], 'height_mm' => dims[2], 'quantity' => qty,
    'materials' => mats, 'spaces' => [space], 'space_ids' => [space] }
end
h = MergeHarness
a = h.soft_schedule_merge_equivalent_rows([r('m2', '柜子（行李柜）', 1, 's17'), r('m1', '柜子(行李柜)#2', 1, 's17'), r('m3', '床头柜', 2, 's17')])
raise "expected 2 rows, got #{a.length}" unless a.length == 2
cab = a.find { |row| row['merged_model_count'] == 2 }
raise 'merged row missing' unless cab && cab['quantity'] == 2 && cab['model_id'] == 'm1' && cab['variant_keys'].sort == ['m1|1400|500|420', 'm2|1400|500|420']
raise 'display name should drop #N' unless cab['display_name'] == cab['base_name']
b = h.soft_schedule_merge_equivalent_rows([r('m2', '柜子（行李柜）', 3, 's23'), r('m2', '柜子（行李柜）', 1, 's23', [1400, 500, 421])])
raise 'different size must not merge' unless b.length == 2
c = h.soft_schedule_merge_equivalent_rows([r('m4', '柜子（行李柜）', 1, 's25', [1400, 500, 420], { '木' => ['黑'] })])
total = h.merge_soft_measurement_space_rows([a, b, c])
cab_total = total.find { |row| row['merge_key'] == cab['merge_key'] }
raise "total merge wrong: #{cab_total.inspect}" unless cab_total['quantity'] == 5 && cab_total['merged_model_ids'] == %w[m1 m2] && cab_total['spaces'].sort == %w[s17 s23]
raise 'different material must not merge' unless total.length == 4
puts 'schedule merge test: OK'
