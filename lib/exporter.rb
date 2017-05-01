#!/usr/bin/env ruby

require 'csv'
require 'nkf'
require 'i18n'

I18n.load_path += Dir[
  File.join(File.dirname(__FILE__), 'locale', '*.yml')
]

class Exporter
  def self.gen_csv(data, headers, options = {})
    options[:batch_size] ||= 1001
    options[:nkf] ||= "-s"
    options[:charset] ||= "Shift_JIS"
    headers["Cache-Control"] ||= "no-cache"
    headers["Transfer-Encoding"] = "chunked"
    headers['Content-Type'] = "text/csv; charset=#{options[:charset]}"
    headers['Content-Disposition'] = "attachment; filename=\"#{data.model}_#{Time.now}.csv\""
    mappings = options[:mappings].present? ? options[:mappings] : {}
    mapping_names = mappings.keys
    table = data.model.table_name

    Rack::Chunked::Body.new(Enumerator.new do |y|
      begin
        options[:include_column_names] ||= true
        data.find_each(:batch_size => options[:batch_size]) do |row|
            # gen first csv line contain column name
            if options[:include_column_names]
              first_line = []

              if options[:structure].present?
                options[:structure].each do |col|
                  first_line << I18n.t(col, scope: [:activerecord, :attributes, table.singularize], default: col)
                end
              else
                row.attributes.keys.each do |key|
                  first_line << I18n.t(key, scope: [:activerecord, :attributes, table.singularize], default: key)
                end
              end

              if options[:append].present?
                options[:append].each do |rel|
                  first_line << get_human_name(rel, table)
                end
              end

              options[:include_column_names] = false
              y << NKF.nkf(options[:nkf], CSV.generate_line(first_line))
            end

            # gen data
            next_row = []
            if options[:structure]
              options[:structure].each do |col|
                next_row << gen_output(table, row, col, mappings, mapping_names)
              end
            else
              row.attributes.keys.each do |key|
                next_row << gen_output(table, row, key, mappings, mapping_names)
              end
            end
            if options[:append].present?
              options[:append].each do |rel|
                next_row << gen_append(row, rel, mappings, mapping_names)
              end
            end

            y << NKF.nkf(options[:nkf], CSV.generate_line(next_row))
        end
      rescue => e
        y << NKF.nkf("-s", "データの破損を検知しました、このデータを破棄してください。\n")
        y << "Error : #{e.backtrace.join("\n")}"
      end
    end)
  end

  # example user.post.comment.time will use I18n.t(comment.time) , if not found use input (exp:user.post.comment.time)
  # default table name is data.model.table_name
  def self.get_human_name(relations, table_name)
    return unless relations.present?
    rels = relations.split(".")
    rels.unshift(table_name) if rels.length < 2
    table = 'rels[rels.length - 2].singularize'
    column = 'rels[rels.length - 1]'

    human_name = "I18n.t(#{column}, :scope => [:activerecord, :attributes, #{table}], :default => '#{relations}')"
    eval(human_name)
  end

  # example post.comment.id will call row.send("post").send("comment").send("id")
  def self.gen_append(row, relations, mappings, mapping_names)
    value = "row."
    rels = relations.split(".")
    table = rels[rels.length - 2]
    col  = rels[rels.length - 1]
    rels = rels.map { |rel| "send('#{rel.singularize}')" }.join(".")
    begin
      result = eval((value << rels).to_s)
      if mapping_present?(mapping_names, table, col)
        result = get_mapping(mappings, gen_pluralize_key(table, col), result)
      end
      result
    rescue
      ""
    end
  end

  def self.gen_output(table, row, col, mappings, mapping_names)
    relsult = row.send(col.to_s)
    if mapping_present?(mapping_names, table, col)
      get_mapping(mappings, gen_pluralize_key(table, col), relsult)
    else
      return relsult
    end
  rescue
    ""
  end

  def self.get_mapping(mappings, attr, key)
    mappings[attr][key].present? ? mappings[attr][key] : ""
  end

  def self.mapping_present?(mapping_names, table, col)
    mapping_names.include?(gen_pluralize_key(table, col))
  end

  def self.gen_pluralize_key(tbl_name, column)
    "#{tbl_name.pluralize}_#{column.pluralize}"
  end
end