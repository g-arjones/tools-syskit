module Syskit
    module Actions
        # Action representation for syskit-specific objects
        class Action < Roby::Actions::Action
            # Return an InstanceRequirements that is equivalent to this action
            #
            # @return [InstanceRequirements]
            def to_instance_requirements
                model.to_instance_requirements(arguments)
            end

            # Create a new action with the same arguments but the requirements
            # rebound to a new profile
            #
            # @param [Profile] the profile onto which definitions should be
            #   rebound
            # @return [Action]
            def rebind_requirements(profile)
                model.requirements.rebind(profile).to_action_model.
                    new(arguments)
            end

            def method_missing(m, *args, &block)
                if model.requirements.respond_to?(m)
                    Action.new(model.send(m, *args, &block), arguments)
                else super
                end
            end
        end
    end
end
