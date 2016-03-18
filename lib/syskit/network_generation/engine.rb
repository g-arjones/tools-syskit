module Syskit
    module NetworkGeneration
        # The main deployment algorithm
        #
        # Engine instances are the objects that actually get deployment
        # requirements and produce a deployment, possibly dynamically.
        #
        # The main entry point for the algorithm is Engine#resolve
        class Engine
            extend Logger::Hierarchy
            include Logger::Hierarchy
            include Roby::DRoby::EventLogging

            # The actual plan we are modifying
            attr_reader :real_plan
            # The plan we are modifying. It is usually a transaction on top of
            # #plan
            #
            # This is valid only during resolution
            #
            # It is alised to {#plan} for backward compatibility reasons
            attr_reader :work_plan
            # A mapping from requirement tasks in the real plan to the tasks
            # that have been instantiated in the working plan
            #
            # This is only valid during resolution
            attr_reader :required_instances
            # A mapping from task context models to deployment models that
            # contain such a task.
            # @return [Hash{Model<TaskContext>=>Model<Deployment>}]
            attr_reader :task_context_deployment_candidates
            # The merge solver instance used during resolution
            #
            # @return [MergeSolver]
            attr_reader :merge_solver

            class << self
                # If false (the default), {Engine#resolve} will clear the data
                # structures built during resoltuion such as
                # {#required_instances} and {#merge_solver}. This improves
                # performance by reducing the required garbage collection times
                # quite a lot. 
                #
                # Set to true only for debugging reasons
                attr_predicate :keep_internal_data_structures?, true
            end
            @keep_internal_data_structures = false

            # The set of tasks that represent the running deployments
            attr_reader :deployment_tasks

            # The DataFlowDynamics instance that has been used to compute
            # +port_dynamics+. It is only valid at the postprocesing stage of
            # the deployed network
            #
            # It can be used to compute some connection policy by calling
            # DataFlowDynamics#policy_for
            attr_reader :dataflow_dynamics

            # A mapping of type
            #
            #   task_name => port_name => PortDynamics instance
            #
            # that represent the dynamics of the given ports. The PortDynamics
            # instance might be nil, in which case it means some of the ports'
            # dynamics could not be computed
            attr_reader :port_dynamics

            class << self
                # The buffer size used to create connections to the logger in
                # case the dataflow dynamics can't be computed
                #
                # Defaults to 25
                attr_accessor :default_logging_buffer_size
            end
            @default_logging_buffer_size = 25

            attr_reader :event_logger

            def initialize(plan, event_logger: plan.event_logger)
                @real_plan = plan
                @work_plan = plan
                @event_logger = event_logger

                @merge_solver = NetworkGeneration::MergeSolver.new(real_plan)
                @required_instances = Hash.new
            end

            def update_task_context_deployment_candidates
                @task_context_deployment_candidates = compute_task_context_deployment_candidates
            end

            # Returns the set of deployments that are available for this network
            # generation
            def available_deployments
                Syskit.conf.deployments
            end

            # Computes the set of task context models that are available in
            # deployments
            def compute_deployed_models
                deployed_models = Set.new

                new_models = Set.new
                available_deployments.each do |machine_name, deployment_models|
                    deployment_models.each do |model|
                        model.each_orogen_deployed_task_context_model do |deployed_task|
                            new_models << TaskContext.model_for(deployed_task.task_model)
                        end
                    end
                end

                while !new_models.empty?
                    deployed_models.merge(new_models)

                    # First, add everything the new models fullfill
                    fullfilled_models = Set.new
                    new_models.each do |m|
                        m.each_fullfilled_model do |fullfilled_m|
                            next if !(fullfilled_m <= Syskit::Component) && !(fullfilled_m.kind_of?(Models::DataServiceModel))
                            if !deployed_models.include?(fullfilled_m)
                                fullfilled_models << fullfilled_m
                            end
                        end
                    end
                    deployed_models.merge(fullfilled_models)

                    # No new fullfilled models, finish
                    break if fullfilled_models.empty?

                    # Look into which compositions we are able to instantiate
                    # with the newly added fullfilled models
                    new_models.clear
                    Composition.each_submodel do |composition_m|
                        next if deployed_models.include?(composition_m)
                        available = composition_m.each_child.all? do |child_name, child_m|
                            child_m.each_fullfilled_model.all? do |fullfilled_m|
                                if !(fullfilled_m <= Syskit::Component) && !(fullfilled_m.kind_of?(Models::DataServiceModel))
                                    true
                                else
                                    deployed_models.include?(fullfilled_m)
                                end
                            end
                        end
                        if available
                            new_models << composition_m
                        end
                    end
                end

                deployed_models.delete(Syskit::TaskContext)
                deployed_models.delete(Syskit::DataService)
                deployed_models.delete(Syskit::Composition)
                deployed_models.delete(Syskit::Component)

                deployed_models
            end

            # Resets the state of the solver to be ready for another call to
            # #resolve
            #
            # It should be called as soon as #prepare has been called
            def finalize
                if work_plan && (work_plan != real_plan)
                    if !work_plan.finalized?
                        work_plan.discard_transaction
                    end
                    @work_plan = real_plan
                end

                if !Engine.keep_internal_data_structures?
                    merge_solver.task_replacement_graph.clear
                    @merge_solver = NetworkGeneration::MergeSolver.new(work_plan)
                    @required_instances.clear if @required_instances
                end
            end

            def find_selected_device_in_hierarchy(argument_name, leaf_task, requirements)
                _, model, _ = leaf_task.requirements.resolved_dependency_injection.selection_for(nil, requirements)
                if model && dev = model.arguments[argument_name]
                    return dev
                else
                    devices = Set.new
                    leaf_task.each_parent_task do |parent|
                        if sel = find_selected_device_in_hierarchy(argument_name, parent, requirements)
                            devices << sel
                        end
                    end
                    if devices.size == 1
                        return devices.first
                    end
                end
            end

            # Try to autoallocate the devices in +task+ based on the information
            # in the instance requirements in the task's hierarchy
            def allocate_devices(task)
                Engine.debug do
                    Engine.debug "allocating devices on #{task} using"
                    break
                end
                    
                task.model.each_master_driver_service do |srv|
                    next if task.find_device_attached_to(srv)
                    if dev = find_selected_device_in_hierarchy("#{srv.name}_dev", task, srv.model.to_instance_requirements)
                        Engine.debug do
                            Engine.debug "  selected #{dev} for #{srv.name}"
                        end
                        task.arguments["#{srv.name}_dev"] = dev
                    end
                end
            end

            # Computes the set of requirement tasks that should be used for
            # deployment within the given plan
            def discover_requirement_tasks_from_plan(plan)
                req_tasks = plan.find_local_tasks(InstanceRequirementsTask).
                    find_all do |req_task|
                    !req_task.failed? && !req_task.pending? &&
                        req_task.planned_task && !req_task.planned_task.finished?
                end
                not_needed = plan.unneeded_tasks
                req_tasks.delete_if do |t|
                    not_needed.include?(t)
                end
                req_tasks
            end

            # Create on {#work_plan} the task instances that are currently
            # required in {#real_plan}
            #
            # It does not try to merge the result, {#work_plan} is probably full
            # of redundancies after this call
            #
            # @return [void]
            def instanciate(requirement_tasks = discover_requirement_tasks_from_plan(real_plan))
                log_timepoint "instanciate_requirements"
                requirement_tasks.each_with_index do |req_task, i|
                    req = req_task.requirements
                    task = req.instanciate(work_plan).
                        to_task
                    # We add all these tasks as permanent tasks, to use
                    # #static_garbage_collect to cleanup #work_plan.
                    work_plan.add_permanent_task(task)

                    fullfilled_task_m, fullfilled_modules, fullfilled_args = req.fullfilled_model
                    fullfilled_args = fullfilled_args.each_key.inject(Hash.new) do |h, arg_name|
                        if task.arguments.set?(arg_name)
                            h[arg_name] = task.arguments[arg_name]
                        end
                        h
                    end
                    task.fullfilled_model = [fullfilled_task_m, fullfilled_modules, fullfilled_args]
                    required_instances[req_task] = task
                    log_timepoint "task-#{i}"
                end
                work_plan.each_task do |task|
                    if task.respond_to?(:each_master_driver_service)
                        allocate_devices(task)
                    end
                end
                log_timepoint 'device_allocation'
                Engine.instanciation_postprocessing.each do |block|
                    block.call(self, work_plan)
                    log_timepoint "postprocessing:#{block}"
                end
            end

            # Creates communication busses and links the tasks to them
            def link_to_busses
                # Get all the tasks that need at least one communication bus
                candidates = work_plan.find_local_tasks(Syskit::Device).
                    inject(Hash.new) do |h, t|
                        required_busses = t.each_master_device.inject(Array.new) do |list, dev|
                            list + dev.com_busses
                        end.to_set
                        if !required_busses.empty?
                            h[t] = required_busses
                        end
                        h
                    end

                bus_tasks = Hash.new
                candidates.each do |task, needed_busses|
                    needed_busses.each do |bus_device|
                        com_bus_task = bus_tasks[bus_device] ||
                            bus_device.instanciate(work_plan)
                        bus_tasks[bus_device] ||= com_bus_task

                        com_bus_task = com_bus_task.component
                        com_bus_task.attach(task)
                        task.depends_on com_bus_task
                        task.should_configure_after com_bus_task.start_event
                    end
                end
                nil
            end

            # Compute in #plan the network needed to fullfill the requirements
            #
            # This network is neither validated nor tied to actual deployments
            def compute_system_network(requirement_tasks, garbage_collect: true,
                                       validate_abstract_network: true,
                                       validate_generated_network: true)
                log_timepoint_group 'instanciate' do
                    instanciate(requirement_tasks)
                end

                merge_solver.merge_identical_tasks
                log_timepoint 'merge'
                Engine.instanciated_network_postprocessing.each do |block|
                    block.call(self, work_plan)
                    log_timepoint "postprocessing:#{block}"
                end
                link_to_busses
                log_timepoint 'link_to_busses'
                merge_solver.merge_identical_tasks
                log_timepoint 'merge'

                # Now remove the optional, non-resolved children of compositions
                work_plan.find_local_tasks(Syskit::Component).abstract.each do |task|
                    parent_tasks = task.each_parent_task.to_a
                    parent_tasks.each do |parent_task|
                        next if !parent_task.kind_of?(Syskit::Composition)
                        next if parent_task.abstract?

                        roles = parent_task.roles_of(task).dup
                        remaining_roles = roles.find_all do |child_role|
                            !(child_model = parent_task.model.find_child(child_role)) || !child_model.optional?
                        end
                        if remaining_roles.empty?
                            parent_task.remove_child(task)
                        else
                            parent_task.remove_roles(task, *(roles - remaining_roles))
                        end
                    end
                end
                log_timepoint 'remove-optional'

                # Finally, select 'default' as configuration for all
                # remaining tasks that do not have a 'conf' argument set
                work_plan.find_local_tasks(Component).
                    each do |task|
                        task.freeze_delayed_arguments
                    end
                log_timepoint 'default_conf'

                # Cleanup the remainder of the tasks that are of no use right
                # now (mostly devices)
                if garbage_collect
                    work_plan.static_garbage_collect do |obj|
                        debug { "  removing #{obj}" }
                        # Remove tasks that we just added and are not
                        # useful anymore
                        work_plan.remove_task(obj)
                    end
                    log_timepoint 'static_garbage_collect'
                end

                # And get rid of the 'permanent' marking we use to be able to
                # run static_garbage_collect
                work_plan.each_task do |task|
                    work_plan.unmark_permanent_task(task)
                end

                Engine.system_network_postprocessing.each do |block|
                    block.call(self)
                end
                log_timepoint 'postprocessing'

                if validate_abstract_network
                    validate_abstract_network(work_plan)
                    log_timepoint 'validate_abstract_network'
                end
                if validate_generated_network
                    validate_generated_network(work_plan)
                    log_timepoint 'validate_generated_network'
                end
            end

            def compute_deployed_network(compute_policies: true, validate_deployed_network: true)
                log_timepoint_group 'deploy_system_network' do
                    deploy_system_network(validate: validate_deployed_network)
                end

                # Now that we have a deployed network, we can compute the
                # connection policies and the port dynamics
                if compute_policies
                    @dataflow_dynamics = DataFlowDynamics.new(work_plan)
                    @port_dynamics = dataflow_dynamics.compute_connection_policies
                    log_timepoint 'compute_connection_policies'
                end

                # Finally, we map the deployed network to the currently
                # running tasks
                @deployment_tasks =
                    log_timepoint_group 'finalize_deployed_tasks' do
                        finalize_deployed_tasks
                    end

                if @dataflow_dynamics
                    @dataflow_dynamics.apply_merges(merge_solver)
                    log_timepoint 'apply_merged_to_dataflow_dynamics'
                end
                Engine.deployment_postprocessing.each do |block|
                    block.call(self, work_plan)
                    log_timepoint "postprocessing:#{block}"
                end
            end

            # Verifies that the task allocation is complete
            #
            # @param [Roby::Plan] plan the plan on which we are working
            # @raise [TaskAllocationFailed] if some abstract tasks are still in
            #   the plan
            def verify_task_allocation(plan)
                components = plan.find_local_tasks(Component).to_a
                still_abstract = components.find_all(&:abstract?)
                if !still_abstract.empty?
                    raise TaskAllocationFailed.new(self, still_abstract),
                        "could not find implementation for the following abstract tasks: #{still_abstract}"
                end
            end

            # Verifies that there are no multiple output - single input
            # connections towards ports that are not multiplexing ports
            #
            # @param [Roby::Plan] plan the plan on which we are working
            # @raise [SpecError] if some abstract tasks are still in
            #   the plan
            def self.verify_no_multiplexing_connections(plan)
                task_contexts = plan.find_local_tasks(TaskContext).to_a
                task_contexts.each do |task|
                    seen = Hash.new
                    task.each_concrete_input_connection do |source_task, source_port, sink_port, _|
                        if (port_model = task.model.find_input_port(sink_port)) && port_model.multiplexes?
                            next
                        elsif seen[sink_port]
                            seen_task, seen_port = seen[sink_port]
                            if [source_task, source_port] != [seen_task, seen_port]
                                raise SpecError, "#{task}.#{sink_port} is connected multiple times, at least to #{source_task}.#{source_port} and #{seen_task}.#{seen_port}"
                            end
                        end
                        seen[sink_port] = [source_task, source_port]
                    end
                end
            end
            
            # Verifies that all tasks that are device drivers have at least one
            # device attached, and that the same device is not attached to more
            # than one task in the plan
            #
            # @param [Roby::Plan] plan the plan on which we are working
            # @raise [DeviceAllocationFailed] if some device drivers are not
            #   attached to any device
            # @raise [SpecError] if some devices are assigned to more than one
            #   task
            def self.verify_device_allocation(plan)
                components = plan.find_local_tasks(Syskit::Device).to_a

                # Check that all devices are properly assigned
                missing_devices = components.find_all do |t|
                    t.model.each_master_driver_service.
                        any? { |srv| !t.find_device_attached_to(srv) }
                end
                if !missing_devices.empty?
                    raise DeviceAllocationFailed.new(plan, missing_devices),
                        "could not allocate devices for the following tasks: #{missing_devices}"
                end

                devices = Hash.new
                components.each do |task|
                    task.each_master_device do |dev|
                        device_name = dev.full_name
                        if old_task = devices[device_name]
                            raise ConflictingDeviceAllocation.new(dev, task, old_task)
                        else
                            devices[device_name] = task
                        end
                    end
                end
            end
            
            # Validates the network generated by {#compute_system_network}
            #
            # It performs the tests that are only needed on an abstract network,
            # i.e. on a network in which some tasks are still abstract
            def validate_abstract_network(plan)
                self.class.verify_no_multiplexing_connections(plan)
                super if defined? super
            end

            # Validates the network generated by {#compute_system_network}
            def validate_generated_network(plan)
                verify_task_allocation(plan)
                self.class.verify_device_allocation(plan)
                super if defined? super
            end

            # Computes a mapping from task models to the set of registered
            # deployments that apply on these task models
            #
            # @return [{Model<TaskContext>=>[(String,Model<Deployment>,String)]}]
            #   mapping from task context models to a set of
            #   (machine_name,deployment_model,task_name) tuples representing
            #   the known ways this task context model could be deployed
            def compute_task_context_deployment_candidates
                deployed_models = Hash.new
                available_deployments.each do |machine_name, deployment_models|
                    deployment_models.each do |model|
                        model.each_orogen_deployed_task_context_model do |deployed_task|
                            task_model = TaskContext.model_for(deployed_task.task_model)
                            deployed_models[task_model] ||= Set.new
                            deployed_models[task_model] << [machine_name, model, deployed_task.name]
                        end
                    end
                end
                deployed_models
            end

            # Try to resolve a set of deployment candidates for a given task
            #
            # @param [Array<(String,Model<Deployment>,String)>] candidates set
            #   of deployment candidates as
            #   (machine_name,deployment_model,task_name) tuples
            # @param [Syskit::TaskContext] task the task context for which
            #   candidates are possible deployments
            # @return [(String,Model<Deployment>,String),nil] the resolved
            #   deployment, if finding a single best candidate was possible, or
            #   nil otherwise.
            def resolve_deployment_ambiguity(candidates, task)
                if task.orocos_name
                    debug { "#{task} requests orocos_name to be #{task.orocos_name}" }
                    resolved = candidates.find { |_, _, task_name| task_name == task.orocos_name }
                    if !resolved
                        debug { "cannot find requested orocos name #{task.orocos_name}" }
                    end
                    return resolved
                end
                hints = task.deployment_hints
                debug { "#{task}.deployment_hints: #{hints.map(&:to_s).join(", ")}" }
                # Look to disambiguate using deployment hints
                resolved = candidates.find_all do |_, deployment_model, task_name|
                    task.deployment_hints.any? do |rx|
                        rx == deployment_model || rx === task_name
                    end
                end
                if resolved.size != 1
                    info do
                        info { "ambiguous deployment for #{task} (#{task.model})" }
                        candidates.each do |machine, deployment_model, task_name|
                            info { "  #{task_name} of #{deployment_model.short_name} on #{machine}" }
                        end
                        break
                    end
                    return
                end
                return resolved.first
            end

            def find_suitable_deployment_for(task)
                # task.model would be wrong here as task.model could be the
                # singleton class (if there are dynamic services)
                candidates = task_context_deployment_candidates[task.model]
                if !candidates || candidates.empty?
                    candidates = task_context_deployment_candidates[task.concrete_model]
                    if !candidates || candidates.empty?
                        debug { "no deployments found for #{task} (#{task.concrete_model})" }
                        return
                    end
                end

                if candidates.size > 1
                    debug { "#{candidates.size} deployments available for #{task} (#{task.concrete_model}), trying to resolve" }
                    selected = log_nest(2) do
                        resolve_deployment_ambiguity(candidates, task)
                    end
                    if selected
                        debug { "  selected #{selected}" }
                        return selected
                    else
                        debug { "  deployment of #{task} (#{task.concrete_model}) is ambiguous" }
                        return
                    end
                else
                    return candidates.first
                end
            end

            def select_deployments(tasks)
                used_deployments = Set.new
                missing_deployments = Set.new
                selected_deployments = Hash.new

                all_tasks = work_plan.find_local_tasks(TaskContext).to_a
                all_tasks.each do |task|
                    next if task.execution_agent
                    if !(selected = find_suitable_deployment_for(task))
                        missing_deployments << task
                    elsif used_deployments.include?(selected)
                        debug do
                            machine, configured_deployment, task_name = *selected
                            "#{task} resolves to #{configured_deployment}.#{task_name} on #{machine} for its deployment, but it is already used"
                        end
                        missing_deployments << task
                    else
                        used_deployments << selected
                        selected_deployments[task] = selected
                    end
                end
                return selected_deployments, missing_deployments
            end

            def apply_selected_deployments(selected_deployments)
                deployment_tasks = Hash.new
                selected_deployments.each do |task, selected|
                    machine, configured_deployment, task_name = *selected

                    deployment_task =
                        (deployment_tasks[[machine, configured_deployment]] ||= configured_deployment.new(on: machine))
                    work_plan.add(deployment_task)
                    deployed_task = deployment_task.task(task_name)
                    debug { "deploying #{task} with #{task_name} of #{configured_deployment.short_name} (#{deployed_task})" }
                    merge_solver.apply_merge_group(task => deployed_task)
                    debug { "  => #{deployed_task}" }
                end
            end

            # Called after compute_system_network to map the required component
            # network to deployments
            #
            # We are still purely within {#work_plan}, the mapping to
            # {#real_plan} is done by calling {#finalize_deployed_tasks}
            def deploy_system_network(validate: true)
                update_task_context_deployment_candidates

                debug do
                    debug "Deploying the system network"
                    debug "Available deployments"
                    log_nest(2) do
                        task_context_deployment_candidates.each do |model, deployments|
                            if !deployments
                                debug "#{model}: no deployments"
                            elsif deployments.size == 1
                                debug "#{model}: #{deployments.first}"
                            else
                                debug "#{model}"
                                log_nest(2) do
                                    deployments.each do |deployment|
                                        debug deployment.to_s
                                    end
                                end
                            end
                        end
                    end
                    break
                end

                all_tasks = work_plan.find_local_tasks(TaskContext).to_a
                selected_deployments, missing_deployments = select_deployments(all_tasks)
                log_timepoint 'select_deployments'

                apply_selected_deployments(selected_deployments)
                log_timepoint 'apply_selected_deployments'

                if validate
                    validate_deployed_network
                    log_timepoint 'validate_deployed_network'
                end

                return missing_deployments
            end

            # Sanity checks to verify that the result of #deploy_system_network
            # is valid
            #
            # @raise [MissingDeployments] if some tasks could not be deployed
            def validate_deployed_network
                verify_all_tasks_deployed
            end

            class << self
                # Set of blocks registered with
                # register_instanciation_postprocessing
                attr_reader :instanciation_postprocessing

                # Set of blocks registered with
                # register_instanciated_network_postprocessing
                attr_reader :instanciated_network_postprocessing

                # Set of blocks registered with
                # register_system_network_postprocessing
                attr_reader :system_network_postprocessing

                # Set of blocks registered with
                # register_deployment_postprocessing
                attr_reader :deployment_postprocessing

                # Set of blocks registered with
                # register_final_network_postprocessing
                attr_reader :final_network_postprocessing
            end
            @instanciation_postprocessing = Array.new
            @instanciated_network_postprocessing = Array.new
            @system_network_postprocessing = Array.new
            @deployment_postprocessing = Array.new
            @final_network_postprocessing = Array.new

            # Registers a system-wide post-processing stage for the instanciation
            # stage. This post-processing block is meant to add new tasks and
            # new relations in the graph. It runs after the instanciation, but
            # before the first merge pass has been performed. I.e. in this
            # graph, there will be present some duplicate tasks, devices won't
            # be assigned properly, ... Use the
            # instanciated_network_postprocessing hook to be called after this
            # first merge pass.
            #
            # Use it to instanciate/annotate the graph early, i.e. before some
            # system-wide processing is done
            #
            # Postprocessing stages that configures the task(s) automatically
            # should be registered with #register_system_network_postprocessing
            def self.register_instanciation_postprocessing(&block)
                instanciation_postprocessing << block
            end

            # Registers a system-wide post-processing stage for augmenting the
            # system network instanciation. Unlike the instanciation
            # postprocessing stage, a first merge pass has been done on the
            # graph and it is therefore not final but well-formed.
            #
            # Postprocessing stages that configures the task(s) automatically
            # should be registered with #register_system_network_postprocessing
            def self.register_instanciated_network_postprocessing(&block)
                instanciated_network_postprocessing << block
            end

            # Registers a system-wide post-processing stage for the system
            # network (i.e. the complete network before it gets merged with
            # deployed tasks). This post-processing block is meant to
            # automatically configure the tasks and/or dataflow, but not change
            # the task graph
            #
            # Postprocessing stages that change the task graph should be
            # registered with #register_instanciation_postprocessing
            def self.register_system_network_postprocessing(&block)
                system_network_postprocessing << block
            end

            # Registers a system-wide post-processing stage for the deployed
            # network. This post-processing block is meant to automatically
            # configure the tasks and/or dataflow, but not change the task
            # graph. Unlike in #register_system_network_postprocessing, it has
            # access to information that deployment provides (as e.g. port
            # dynamics).
            #
            # Postprocessing stages that change the task graph should be
            # registered with #register_instanciation_postprocessing
            def self.register_deployment_postprocessing(&block)
                deployment_postprocessing << block
            end

            # Registers a system-wide post-processing stage for the final
            # network. This is the last stage before the last validation
            def self.register_final_network_postprocessing(&block)
                final_network_postprocessing << block
            end

            # Updates the tasks stored in {#required_instances} and in
            # {#dataflow_dynamics} with the tasks that will replace them in
            # {#real_plan} once the {#work_plan} transaction is committed.
            #
            # It also updates the merge graph in {#merge_solver} so that
            # it points to tasks in {#real_plan}
            def apply_merge_to_stored_instances
                work_plan.each_task do |task|
                    if task.transaction_proxy?
                        merge_solver.register_replacement(task, task.__getobj__)
                    end
                end

                @required_instances = required_instances.map_value do |_, task|
                    merge_solver.replacement_for(task)
                end
                if @dataflow_dynamics
                    @dataflow_dynamics.apply_merges(merge_solver)
                end
            end

            # Replaces the toplevel tasks (i.e. tasks planned by the
            # InstanceRequirementsTask tasks) by their computed implementation.
            #
            # Also updates the permanent and mission flags for these tasks.
            def fix_toplevel_tasks
                required_instances.each do |req_task, actual_task|
                    placeholder_task = work_plan.wrap_task(req_task.planned_task)
                    req_task         = work_plan.wrap_task(req_task)
                    actual_task      = work_plan.wrap_task(actual_task)

                    if placeholder_task != actual_task
                        work_plan.replace(placeholder_task, actual_task)
                        # Need to switch the planning relation as well, it is
                        # not done by #replace
                        placeholder_task.remove_planning_task req_task
                        actual_task.add_planning_task req_task
                    end
                end
            end

            # Given the network with deployed tasks, this method looks at how we
            # could adapt the running network to the new one
            def finalize_deployed_tasks
                debug "finalizing deployed tasks"

                used_deployments = work_plan.find_local_tasks(Deployment).to_set
                used_tasks       = work_plan.find_local_tasks(Component).to_set
                log_timepoint 'used_tasks'

                all_tasks = work_plan.find_tasks(Component).to_set
                log_timepoint 'import_all_tasks_from_plan'
                all_tasks.delete_if do |t|
                    if !t.reusable?
                        debug { "  clearing the relations of the finished task #{t}" }
                        t.remove_relations(Syskit::Flows::DataFlow)
                        t.remove_relations(Roby::TaskStructure::Dependency)
                        true
                    elsif t.transaction_proxy? && t.abstract?
                        work_plan.remove_task(t)
                        true
                    end
                end
                log_timepoint 'all_tasks_cleanup'

                # Remove connections that are not forwarding connections (e.g.
                # composition exports)
                dataflow_graph = work_plan.task_relation_graph_for(Syskit::Flows::DataFlow)
                all_tasks.each do |t|
                    next if used_tasks.include?(t)
                    dataflow_graph.in_neighbours(t).dup.each do |source_t|
                        connections = dataflow_graph.edge_info(source_t, t).dup
                        connections.delete_if do |(source_port, sink_port), policy|
                            !(source_t.find_output_port(source_port) && t.find_output_port(sink_port)) &&
                                !(source_t.find_input_port(source_port) && t.find_input_port(sink_port))
                        end
                        if !connections.empty?
                            dataflow_graph.set_edge_info(source_t, t, connections)
                        else
                            dataflow_graph.remove_edge(source_t, t)
                        end
                    end
                end
                log_timepoint 'dataflow_graph_cleanup'

                deployments = work_plan.find_tasks(Syskit::Deployment).not_finished
                finishing_deployments, existing_deployments = Hash.new, Set.new
                deployments.each do |task|
                    if task.finishing?
                        finishing_deployments[task.process_name] = task
                    elsif !used_deployments.include?(task)
                        existing_deployments << task
                    end
                end
                log_timepoint 'existing_and_finished_deployments'

                debug do
                    debug "  Mapping deployments in the network to the existing ones"
                    debug "    Network deployments:"
                    used_deployments.each { |dep| debug "      #{dep}" }
                    debug "    Existing deployments:"
                    existing_deployments.each { |dep| debug "      #{dep}" }
                    break
                end

                merged_tasks = Set.new
                result = Set.new
                used_deployments.each do |deployment_task|
                    existing_candidates = work_plan.find_local_tasks(deployment_task.model).
                        not_finishing.not_finished.to_set

                    # Check for the corresponding task in the plan
                    existing_deployment_tasks = (existing_candidates & existing_deployments).
                        find_all do |t|
                            t.process_name == deployment_task.process_name
                        end

                    debug do
                        debug "  looking to reuse a deployment for #{deployment_task.process_name} (#{deployment_task})"
                        debug "  #{existing_deployment_tasks.size} candidates:"
                        existing_deployment_tasks.each do |candidate_task|
                            debug "    #{candidate_task}"
                        end
                        break
                    end

                    selected_deployment = nil
                    if existing_deployment_tasks.empty?
                        debug { "  deployment #{deployment_task.process_name} is not yet represented in the plan" }
                        # Nothing to do, we leave the plan as it is
                        selected_deployment = deployment_task
                    elsif existing_deployment_tasks.size != 1
                        raise InternalError, "more than one task for #{deploment_task.process_name} present in the plan: #{existing_deployment_tasks}"
                    else
                        selected_deployment = existing_deployment_tasks.first
                        new_merged_tasks = adapt_existing_deployment(
                            deployment_task,
                            selected_deployment)
                        merged_tasks.merge(new_merged_tasks)
                    end
                    if finishing = finishing_deployments[selected_deployment.process_name]
                        selected_deployment.should_start_after finishing.stop_event
                    end
                    result << selected_deployment
                end
                log_timepoint 'select_deployments'

                merged_tasks = reconfigure_tasks_on_static_port_modification(merged_tasks)
                log_timepoint 'reconfigure_tasks_on_static_port_modification'

                debug do
                    debug "#{merged_tasks.size} tasks merged during deployment"
                    merged_tasks.each do |t|
                        debug "  #{t}"
                    end
                    break
                end

                # This is required to merge the already existing compositions
                # with the ones in the plan
                merge_solver.merge_identical_tasks
                log_timepoint 'merge'

                result
            end

            def reconfigure_tasks_on_static_port_modification(deployed_tasks)
                final_deployed_tasks = deployed_tasks.dup

                already_setup_tasks = work_plan.find_tasks(Syskit::TaskContext).not_finished.not_finishing.
                    find_all { |t| deployed_tasks.include?(t) && t.setup? }

                already_setup_tasks.each do |t|
                    next if !t.transaction_proxy?
                    if t.transaction_modifies_static_ports?
                        debug { "#{t} was selected as deployment, but it would require modifications on static ports, spawning a new deployment" }
                        
                        new_task = t.execution_agent.task(t.orocos_name, t.concrete_model)
                        merge_solver.apply_merge_group(t => new_task)
                        new_task.should_configure_after t.stop_event
                        final_deployed_tasks.delete(t)
                        final_deployed_tasks << new_task
                    end
                end
                final_deployed_tasks
            end

            # Given a required deployment task in {#work_plan} and a proxy
            # representing an existing deployment task in {#real_plan}, modify
            # the plan to reuse the existing deployment
            #
            # @return [Array<Syskit::TaskContext>] the set of TaskContext
            #   instances that have been used to replace the task contexts
            #   generated during network generation. They are all deployed by
            #   existing_deployment_task, and some of them might be transaction
            #   proxies.
            def adapt_existing_deployment(deployment_task, existing_deployment_task)
                existing_tasks = Hash.new
                existing_deployment_task.each_executed_task do |t|
                    next if t.finished? || t.finishing?
                    if t.running?
                        existing_tasks[t.orocos_name] = t
                    elsif t.pending?
                        existing_tasks[t.orocos_name] ||= t
                    end
                end

                applied_merges = Set.new
                deployed_tasks = deployment_task.each_executed_task.to_a
                deployed_tasks.each do |task|
                    existing_task = existing_tasks[task.orocos_name]
                    if !existing_task || !task.can_be_deployed_by?(existing_task)
                        debug do
                            if !existing_task
                                "  task #{task.orocos_name} has not yet been deployed"
                            else
                                "  task #{task.orocos_name} has been deployed, but I can't merge with the existing deployment (#{existing_task})"
                            end
                        end

                        new_task = existing_deployment_task.task(task.orocos_name, task.concrete_model)
                        debug { "  creating #{new_task} for #{task} (#{task.orocos_name})" }
                        if existing_task
                            debug { "  #{new_task} needs to wait for #{existing_task} to finish before reconfiguring" }
                            parent_task_contexts = existing_task.each_parent_task.
                                find_all { |t| t.kind_of?(Syskit::TaskContext) }
                            parent_task_contexts.each do |t|
                                t.remove_child(existing_task)
                            end
                            new_task.should_configure_after(existing_task.stop_event)
                        end
                        existing_task = new_task
                    end

                    merge_solver.apply_merge_group(task => existing_task)
                    applied_merges << existing_task
                    debug { "  using #{existing_task} for #{task} (#{task.orocos_name})" }
                end
                work_plan.remove_task(deployment_task)
                applied_merges
            end

            def create_work_plan_transaction
                @work_plan = Roby::Transaction.new(real_plan)
                @merge_solver = NetworkGeneration::MergeSolver.new(work_plan)
            end

            def self.resolve(plan, **options)
                new(plan).resolve(**options)
            end

            # Generate the deployment according to the current requirements, and
            # merges it into the current plan
            #
            # The following options are understood:
            #
            # compute_policies::
            #   if false, it will not compute the policies between ports. Mainly
            #   useful for offline testing
            # compute_deployments::
            #   if false, it will not do the deployment allocation. Mainly
            #   useful for testing/debugging purposes. It obviously turns off
            #   the policy computation as well.
            # garbage_collect::
            #   if false, it will not clean up the plan from all tasks that are
            #   not useful. Mainly useful for testing/debugging purposes
            # on_error::
            #   by default, #resolve will generate a dot file containing the
            #   current plan state if an error occurs. This corresponds to a
            #   :save value for this option. It can also be set to :commit, in
            #   which case the current state of the transaction is committed to
            #   the plan, allowing to display it anyway (for debugging of models
            #   for instance). Set it to false to do no special action (i.e.
            #   drop the currently generated plan)
            def resolve(requirement_tasks: discover_requirement_tasks_from_plan(real_plan),
                        on_error: nil,
                        compute_deployments: true,
                        compute_policies: true,
                        garbage_collect: true,
                        save_plans: false,
                        validate_abstract_network: true,
                        validate_generated_network: true,
                        validate_deployed_network: true,
                        validate_final_network: true)
                log_timepoint_group_start 'syskit-engine-resolve'

                create_work_plan_transaction

                # We first generate a non-deployed network that fits all
                # requirements.
                log_timepoint_group 'compute_system_network' do
                    compute_system_network(requirement_tasks,
                                           garbage_collect: garbage_collect,
                                           validate_abstract_network: validate_abstract_network,
                                           validate_generated_network: validate_generated_network)
                end

                # Now, deploy the network by matching the available
                # deployments to the one in the generated network. Note that
                # these deployments are *not* yet the running tasks.
                #
                # The mapping from this deployed network to the running
                # tasks is done in #finalize_deployed_tasks
                if compute_deployments
                    log_timepoint_group 'compute_deployed_network' do
                        compute_deployed_network(compute_policies: compute_policies,
                                                 validate_deployed_network: validate_deployed_network)
                    end
                end

                apply_merge_to_stored_instances
                log_timepoint 'apply_merge_to_stored_instances'
                fix_toplevel_tasks
                log_timepoint 'fix_toplevel_tasks'

                Engine.final_network_postprocessing.each do |block|
                    block.call(self, work_plan)
                    log_timepoint "final_network_postprocessing:#{block}"
                end

                # Finally, we should now only have deployed tasks. Verify it
                # and compute the connection policies
                if garbage_collect && validate_final_network
                    validate_final_network(work_plan, compute_deployments: compute_deployments)
                    log_timepoint 'validate_final_network'
                end

                if save_plans
                    dataflow_path, hierarchy_path = Engine.autosave_plan_to_dot(work_plan, Roby.app.log_dir)
                    info "saved generated plan into #{dataflow_path} and #{hierarchy_path}"
                end
                work_plan.commit_transaction
                log_timepoint 'commit_transaction'

                # Reset the oroGen model on all already-running tasks
                real_plan.find_tasks(Syskit::TaskContext).each do |task|
                    if (orocos_task = task.orocos_task) && orocos_task.respond_to?(:model=)
                        task.orocos_task.model = task.model.orogen_model
                    end
                end

            rescue Exception => e
                if !work_plan.finalized? && (work_plan != real_plan) # we started processing, look at what the user wants to do with the partial transaction
                    if on_error == :save
                        log_pp(:fatal, e)
                        fatal "Engine#resolve failed"
                        begin
                            dataflow_path, hierarchy_path = Engine.autosave_plan_to_dot(work_plan, Roby.app.log_dir)
                            fatal "the generated plan has been saved"
                            fatal "use dot -Tsvg #{dataflow_path} > #{dataflow_path}.svg to convert the dataflow to SVG"
                            fatal "use dot -Tsvg #{hierarchy_path} > #{hierarchy_path}.svg to convert to SVG"
                        rescue Exception => e
                            Roby.log_exception_with_backtrace(e, self, :fatal)
                        end
                    end

                    if on_error == :commit
                        work_plan.commit_transaction
                    else
                        work_plan.discard_transaction
                    end
                end
                raise

            ensure
                finalize
                log_timepoint_group_end 'syskit-engine-resolve'
            end

            # Validates the state of the network at the end of #resolve
            def validate_final_network(plan, compute_deployments: true)
                # Check that all device instances are proper tasks (not proxies)
                required_instances.each do |req_task, task|
                    if task.transaction_proxy?
                        raise InternalError, "instance definition #{instance} contains a transaction proxy: #{instance.task}"
                    elsif !task.plan
                        raise InternalError, "instance definition #{task} has been removed from plan"
                    end
                end

                if compute_deployments
                    # Check for the presence of non-deployed tasks
                    verify_all_tasks_deployed
                end

                super if defined? super
            end

            def verify_all_tasks_deployed
                not_deployed = work_plan.find_local_tasks(TaskContext).
                    not_finished.not_abstract.
                    find_all { |t| !t.execution_agent }

                if !not_deployed.empty?
                    tasks_with_candidates = Hash.new
                    not_deployed.each do |task|
                        candidates = task_context_deployment_candidates[task.concrete_model] || []
                        candidates = candidates.map do |host, deployment, task_name|
                            existing = work_plan.find_local_tasks(task.model).
                                find_all { |t| t.orocos_name == task_name }
                            [host, deployment, task_name, existing]
                        end

                        tasks_with_candidates[task] = candidates
                    end
                    raise MissingDeployments.new(tasks_with_candidates),
                        "there are tasks for which it exists no deployed equivalent: #{not_deployed.map { |m| "#{m}(#{m.orogen_model.name})" }}"
                end
            end

            @@dot_index = 0
            def self.autosave_plan_to_dot(plan, dir = Roby.app.log_dir, prefix: nil, suffix: nil, **dot_options)
                dot_index = (@@dot_index += 1)
                dataflow_path = File.join(dir, "syskit-plan-#{prefix}%04i#{suffix}.%s.dot" %
                                          [dot_index, 'dataflow'])
                hierarchy_path = File.join(dir, "syskit-plan-#{prefix}%04i#{suffix}.%s.dot" %
                                           [dot_index, 'hierarchy'])
                File.open(dataflow_path, 'w') do |io|
                    io.write Graphviz.new(plan).dataflow(dot_options)
                end
                File.open(hierarchy_path, 'w') do |io|
                    io.write Graphviz.new(plan).hierarchy(dot_options)
                end
                return dataflow_path, hierarchy_path
            end

            # Generate a svg file representing the current state of the
            # deployment
            def to_svg(kind, filename = nil, *additional_args)
                Graphviz.new(work_plan).to_file(kind, 'svg', filename, *additional_args)
            end

            def to_dot_dataflow(remove_compositions = false, excluded_models = Set.new, annotations = ["connection_policy"])
                gen = Graphviz.new(work_plan)
                gen.dataflow(remove_compositions, excluded_models, annotations)
            end

            def to_dot(options); to_dot_dataflow(options) end

            def pretty_print(pp) # :nodoc:
                pp.text "-- Tasks"
                pp.nest(2) do
                    pp.breakable
                    work_plan.each_task do |task|
                        pp.text "#{task}"
                        pp.nest(4) do
                            pp.breakable
                            pp.seplist(task.children.to_a) do |t|
                                pp.text "#{t}"
                            end
                        end
                        pp.breakable
                    end
                end

                pp.breakable
                pp.text "-- Connections"
                pp.nest(4) do
                    pp.breakable
                    work_plan.task_relation_graph_for(Flows::DataFlow).each_edge do |from, to, info|
                        pp.text "#{from}"
                        pp.breakable
                        pp.text "  => #{to} (#{info})"
                        pp.breakable
                    end
                end
            end
        end
    end
end


