require 'logger'
require 'utilrb/logger'
require 'utilrb/hash/map_value'
require 'syskit/exceptions'
require 'facets/string/snakecase'

class Object
    def short_name
        to_s
    end
end

module Syskit
    extend Logger::Root('Syskit', Logger::WARN)

    # For 1.8 compatibility
    if !defined?(BasicObject)
        BasicObject = Object
    end

    SYSKIT_LIB_DIR = File.expand_path(File.dirname(__FILE__))
    SYSKIT_ROOT_DIR = File.expand_path(File.join("..", '..'), File.dirname(__FILE__))
end

