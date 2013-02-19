require 'Qt'
require 'qtwebkit'
require 'metaruby/gui/html/page'
module Syskit
    module GUI
        class Page < MetaRuby::GUI::HTML::Page
            def link_to(obj, text = nil)
                super
            end

            # Adds a PlanDisplay widget with the given title and parameters
            def push_plan(title, mode, plan, options)
                view_options, options = Kernel.filter_options options,
                    :buttons => [],
                    :id => nil

                svg_io = Tempfile.open(mode)
                Syskit::Graphviz.new(plan, self).
                    to_file(mode, 'svg', svg_io, options)
                svg_io.flush
                svg_io.rewind
                svg = svg_io.read
                if match = /svg width=\"(\d+)(\w+)\" height=\"(\d+)(\w+)\"/.match(svg)
                    width, w_unit, height, h_unit = *match.captures
                    svg = match.pre_match + "svg width=\"#{(Float(width) * 0.6)}#{w_unit}\" height=\"#{(Float(height) * 0.6)}#{h_unit}\"" + match.post_match
                end
                push(title, svg, view_options)
            rescue Exception => e
                pp e
                pp e.backtrace
                Roby.app.register_exception(e)
                emit :updated
            end
        end
    end
end

