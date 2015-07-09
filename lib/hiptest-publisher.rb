require 'colorize'
require 'yaml'

require 'hiptest-publisher/formatters/reporter'
require 'hiptest-publisher/string'
require 'hiptest-publisher/utils'
require 'hiptest-publisher/options_parser'
require 'hiptest-publisher/xml_parser'
require 'hiptest-publisher/parent_adder'
require 'hiptest-publisher/parameter_type_adder'
require 'hiptest-publisher/call_arguments_adder'
require 'hiptest-publisher/signature_exporter'
require 'hiptest-publisher/signature_differ'

module Hiptest
  class Publisher
    attr_reader :reporter

    def initialize(args, listeners: nil)
      @reporter = Reporter.new(listeners)
      @options = OptionsParser.parse(args, reporter)
    end

    def run
      unless @options.push.nil? || @options.push.empty?
        post_results
        return
      end

      xml = fetch_xml_file
      return if xml.nil?

      @project = get_project(xml)

      if @options.actionwords_signature
        export_actionword_signature
        return
      end

      if @options.actionwords_diff || @options.aw_deleted|| @options.aw_created|| @options.aw_renamed|| @options.aw_signature_changed
        show_actionwords_diff
        return
      end

      export
    end

    def fetch_xml_file
      show_status_message "Fetching data from Hiptest"
      xml = fetch_project_export(@options)
      show_status_message "Fetching data from Hiptest", :success

      return xml
    rescue Exception => err
      show_status_message "Fetching data from Hiptest", :failure
      puts "Unable to open the file, please check that the token is correct".red
      reporter.dump_error(err)
    end

    def get_project(xml)
      show_status_message "Extracting data"
      parser = Hiptest::XMLParser.new(xml, reporter)
      show_status_message "Extracting data", :success

      return parser.build_project
    end

    def write_to_file(path, message)
      status_message = "#{message}: #{path}"
      begin
        show_status_message status_message
        File.open(path, 'w') do |file|
          file.write(yield)
        end

        show_status_message status_message, :success
      rescue Exception => err
        show_status_message status_message, :failure
        reporter.dump_error(err)
      end
    end

    def add_listener(listener)
      reporter.add_listener(listener)
    end

    def write_node_to_file(path, node, context, message)
      write_to_file(path, message) do
        language = context[:language] || @options.language
        Hiptest::Renderer.render(node, language, context)
      end
    end

    def export_files
      @language_config.language_group_configs.each do |language_group_config|
        next if @options.actionwords_stubs && language_group_config[:category] != "actionwords_stubs"
        next if @options.test_code && language_group_config[:category] != "test_code"
        language_group_config.each_node_rendering_context(@project) do |node_rendering_context|
          write_node_to_file(
            node_rendering_context.path,
            node_rendering_context.node,
            node_rendering_context,
            "Exporting #{node_rendering_context.description}",
          )
        end
      end
    end

    def export_actionword_signature
      write_to_file(
        "#{@options.output_directory}/actionwords_signature.yaml",
        "Exporting actionword signature"
      ) { Hiptest::SignatureExporter.export_actionwords(@project).to_yaml }
    end

    def show_actionwords_diff
      begin
        show_status_message("Loading previous definition")
        old = YAML.load_file("#{@options.output_directory}/actionwords_signature.yaml")
        show_status_message("Loading previous definition", :success)
      rescue Exception => err
        show_status_message("Loading previous definition", :failure)
        reporter.dump_error(err)
      end

      @language_config = LanguageConfigParser.new(@options)
      Hiptest::Nodes::ParentAdder.add(@project)
      Hiptest::Nodes::ParameterTypeAdder.add(@project)
      Hiptest::DefaultArgumentAdder.add(@project)
      Hiptest::GherkinAdder.add(@project)

      current = Hiptest::SignatureExporter.export_actionwords(@project, true)
      diff =  Hiptest::SignatureDiffer.diff( old, current)

      if @options.aw_deleted
        return if diff[:deleted].nil?

        diff[:deleted].map {|deleted|
          puts @language_config.name_action_word(deleted[:name])
        }
        return
      end

      if @options.aw_created
        return if diff[:created].nil?

        @language_config.language_group_configs.select { |language_group_config|
          language_group_config[:category] == "actionwords_stubs"
        }.each do |language_group_config|
          diff[:created].each do |created|
            node_rendering_context = language_group_config.build_node_rendering_context(created[:node])
            puts Hiptest::Renderer.render(node_rendering_context[:node], node_rendering_context.language, node_rendering_context)
            puts ""
          end
        end
        return
      end

      if @options.aw_renamed
        return if diff[:renamed].nil?

        diff[:renamed].map {|renamed|
          puts "#{@language_config.name_action_word(renamed[:name])}\t#{@language_config.name_action_word(renamed[:new_name])}"
        }
        return
      end

      if @options.aw_signature_changed
        return if diff[:signature_changed].nil?

        @language_config.language_group_configs.select { |language_group_config|
          language_group_config[:category] == "actionwords_stubs"
        }.each do |language_group_config|
          diff[:signature_changed].each do |signature_changed|
            node_rendering_context = language_group_config.build_node_rendering_context(signature_changed[:node])
            puts Hiptest::Renderer.render(signature_changed[:node], node_rendering_context.language, node_rendering_context)
            puts ""
          end
        end
        return
      end

      unless diff[:deleted].nil?
        puts "#{pluralize(diff[:deleted].length, "action word")} deleted:"
        puts diff[:deleted].map {|d| "- #{d[:name]}"}.join("\n")
        puts ""
      end

      unless diff[:created].nil?
        puts "#{pluralize(diff[:created].length, "action word")} created:"
        puts diff[:created].map {|c| "- #{c[:name]}"}.join("\n")
        puts ""
      end

      unless diff[:renamed].nil?
        puts "#{pluralize(diff[:renamed].length, "action word")} renamed:"
        puts diff[:renamed].map {|r| "- #{r[:name]} => #{r[:new_name]}"}.join("\n")
        puts ""
      end

      unless diff[:signature_changed].nil?
        puts "#{pluralize(diff[:signature_changed].length, "action word")} which signature changed:"
        puts diff[:signature_changed].map {|c| "- #{c[:name]}"}.join("\n")
        puts ""
      end

      if diff.empty?
        puts "No action words changed"
        puts ""
      end
    end

    def export
      return if @project.nil?

      @language_config = LanguageConfigParser.new(@options)
      Hiptest::Nodes::ParentAdder.add(@project)
      Hiptest::Nodes::ParameterTypeAdder.add(@project)
      Hiptest::DefaultArgumentAdder.add(@project)
      Hiptest::GherkinAdder.add(@project)

      export_files
      export_actionword_signature unless @options.test_code
    end

    def post_results
      status_message = "Posting #{@options.push} to #{@options.site}"
      show_status_message(status_message)

      begin
        push_results(@options)
        show_status_message(status_message, :success)
      rescue Exception => err
        show_status_message(status_message, :failure)
        reporter.dump_error(err)
      end
    end
  end
end
