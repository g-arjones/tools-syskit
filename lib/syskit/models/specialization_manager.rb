module Syskit
    module Models
        # Management of the specializations of a particular composition model
        class SpecializationManager
            # The composition model
            #
            # @return [Model<Composition>] 
            attr_reader :composition_model

            def initialize(composition_model)
                @composition_model = composition_model
            end

            # The set of specializations defined on {#composition_model}
            #
            # @return [{{String => # Array<Model<DataService>,Model<Component>>}=>CompositionSpecialization}]
            attribute(:specializations) { Hash.new }

            # Registers the given specialization on this manager
            #
            # @param [CompositionSpecialization] the new specialization
            # @return [void]
            def register(specialization)
                specializations[specialization.specialized_children] = specialization
            end

            # Returns true if no specializations are registered on this manager
            #
            # @return [Boolean]
            def empty?
                specializations.empty?
            end

            # Enumerates all specializations defined on {#composition_model}
            #
            # @yield [CompositionSpecialization]
            def each_specialization
                return enum_for(:each_specialization) if !block_given?
                specializations.each_value do |spec|
                    yield(spec)
                end
            end

            ##
            # If true, any ambiguity in the selection of composition
            # specializations will lead to an error. If false, the common parent
            # of all the possible specializations will be instanciated. One can
            # note that it is less dangerous that it sounds, as this parent is
            # most likely abstract and will therefore be rejected later in the
            # system deployment process.
            #
            # However, don't set this to false unless you know what you are
            # doing
            attr_predicate :strict_specialization_selection, true

            # Specifies a modification that should be applied on
            # {#composition_model} when select children fullfill some specific
            # models. 
            #
            # @param (see #normalize_specialization_mappings)
            # @raise (see #normalize_specialization_mappings)
            #
            # @option options [Boolean] not
            #   If it is known that a specialization is in conflict with another,
            #   the :not option can be used. For instance, in the following code,
            #   only two specialization will exist: the one in which the Control
            #   child is a SimpleController and the one in which it is a
            #   FourWheelController.
            #   
            #   In the example below, if the :not option had not been
            #   used, three specializations would have been added: the same two
            #   than above, and the one case where 'Control' fullfills both the
            #   SimpleController and FourWheelController data services.
            #
            #   @example 
            #
            #     specialize 'Control', SimpleController, :not => FourWheelController do
            #     end
            #     specialize 'Control', FourWheelController, :not => SimpleController do
            #     end
            #
            def specialize(options = Hash.new, &block)
                Models.debug do
                    Models.debug "trying to specialize #{composition_model.short_name}"
                    Models.log_nest 2
                    Models.debug "with"
                    options.map do |name, models|
                        Models.debug "  #{name} => #{models}"
                    end

                    Models.debug ""
                    break
                end

                options, mappings = Kernel.filter_options options, :not => []
                if !options[:not].respond_to?(:to_ary)
                    options[:not] = [options[:not]]
                end

                mappings = normalize_specialization_mappings(mappings)

                # validate it
                validate_specialization_mappings(mappings)

                # register it
                if !(specialization = specializations[mappings])
                    register(specialization = CompositionSpecialization.new)
                end
                specialization.add(mappings, block)

                # ... and update compatibilities
                #
                # NOTE: this code does NOT updates compatibilities based on
                # whether two specialization selection models are compatible as,
                # by definition, the system should never try to instantiate one
                # of these (since the models that would trigger this
                # instantiation cannot be represented)
                each_specialization do |spec|
                    next if spec == specialization
                    if compatible_specializations?(spec, specialization)
                        spec.compatibilities << specialization
                        specialization.compatibilities << spec
                    else
                        spec.compatibilities.delete(specialization)
                        specialization.compatibilities.delete(spec)
                    end
                end
                specialization

            ensure
                Models.debug do
                    Models.log_nest -2
                    break
                end
            end

            # Transforms specialization specifications given to #specialize into
            # a name => model_set mapping
            #
            # @param [{String,Model<DataService>,Model<Component>=>Model<DataService>,Model<Component>}] mappings
            #   specialization mappings. The mapping maps an object that selects
            #   a composition child, maps it to a model or set of models. The
            #   created specialization will be applied only when the selected
            #   child fullfills the models.
            # @return [{String=>Model<Component>,Model<DataService>}] the
            #   normalized specification
            # @raise [ArgumentError] if a data service type is given as child
            #   specification and none of the children matches
            # @raise [ArgumentError] if a data service type is given as child
            #   specification, but more than one child matches this service
            def normalize_specialization_mappings(mappings)
                # Normalize the user-provided specialization mapping
                new_spec = Hash.new
                mappings.each do |child, child_model|
                    if Models.is_model?(child)
                        children = composition_model.each_child.
                            find_all { |name, child_definition| child_definition.fullfills?(child) }.
                            map { |name, _| name }

                        if children.empty?
                            raise ArgumentError, "invalid specialization #{child.short_name} => #{child_model.short_name}: no child of #{composition_model.short_name} fullfills #{child.short_name}"
                        elsif children.size > 1
                            children = children.map do |child_name|
                                child_models = composition_model.find_child(child_name).
                                    models.map(&:short_name).sort.join(",")
                                "#{child_name}: #{child_models}"
                            end
                            raise ArgumentError, "invalid specialization #{child.short_name} => #{child_model.short_name}: more than one child of #{composition_model.short_name} fullfills #{child.short_name} (#{children.sort.join("; ")}). You probably want to select one specifically by name"
                        end
                        child = children.first
                    elsif !child.respond_to?(:to_str)
                        raise ArgumentError, "invalid child selector #{child}"
                    end

                    if !child_model.respond_to?(:each)
                        child_model = [child_model]
                    end

                    child_model.each do |m|
                        if !Syskit::Models.is_model?(m)
                            raise ArgumentError, "invalid specialization selector #{child} => #{child_model}: #{m} is not a component model or a data service model"
                        end
                    end

                    new_spec[child.to_str] = child_model.to_set
                end
                return new_spec
            end

            # Verifies that the child selection in +new_spec+ is valid
            #
            # @param (see #normalize_specialization_mappings)
            # @return [void]
            # @raise [ArgumentError] if the spec refers to a child that does not
            #   exist
            # @raise [ArgumentError] if the spec either selects on a model that
            #   is already provided by the corresponding child
            # @raise [IncompatibleComponentModels] if the new model contains a
            #   component model that is incompatible with the current child's
            #   model
            def validate_specialization_mappings(new_spec)
                new_spec.each do |child_name, child_models|
                    if !composition_model.has_child?(child_name)
                        raise ArgumentError, "there is no child called #{child_name} in #{composition_model.short_name}"
                    end

                    parent_models = composition_model.find_child(child_name).models
                    result = Models.merge_model_lists(parent_models, child_models)
                    if result == parent_models
                        raise ArgumentError, "#{child_models.map(&:short_name).sort.join(",")} does not specify a specialization of #{parent_models.map(&:short_name)}"
                    end
                end
            end

            # A set of blocks that are used to evaluate if two specializations
            # can be applied at the same time
            #
            # The block should take as input two Specialization instances and
            # return true if it is compatible and false otherwise
            attribute(:specialization_constraints) { Array.new }

            # Registers a block that will be able to tell the system that two
            # specializations are not compatible (i.e. should never be applied
            # at the same time).
            #
            # @param [#[a,b]] a proc object given explicitly if the block form
            #   is not desired
            # @yieldparam spec0 [CompositionSpecialization] the first
            #   specialization
            # @yieldparam spec1 [CompositionSpecialization] the second
            #   specialization
            # @yieldreturn [Boolean] true if the two specializations are
            #   compatible, and false otherwise
            # @return [void]
            def add_specialization_constraint(explicit = nil, &as_block)
                specialization_constraints << (explicit || as_block)
            end

            # Returns true if the two given specializations are compatible, as
            # given by the registered specialization constraints
            #
            # This method also checks that the values returned by the
            # constraints are symmetric
            #
            # @return [Boolean] false if at least one specialization constraint
            #   block returns false, and true otherwise
            # @raise [NonSymmetricSpecializationConstraint] if a specialization
            #   constraint does not return the same value with (spec1, spec2)
            #   than with (spec2, spec1)
            # @see #add_specialization_constraint
            def compatible_specializations?(spec1, spec2)
                specialization_constraints.all? do |validator|
                    # This is potentially expensive, but the specialization
                    # compatibilities are done at modelling time, so that's not
                    # an issue given the added robustness -- designing properly
                    # symmetric constraint blocks can be a bit tricky
                    result = validator[spec1, spec2]
                    sym_result = validator[spec2, spec1]
                    if result != sym_result
                        raise NonSymmetricSpecializationConstraint.new(validator, [spec1, spec2]), "#{validator} returned #{!!result} on (#{spec1},#{spec2}) and #{!!sym_result} on (#{spec2},#{spec1}). Specialization constraints must be symmetric"
                    end
                    result
                end
            end

            define_inherited_enumerable(:default_specialization, :default_specializations, :map => true) { Hash.new }

            # Declares a preferred specialization in case two specializations
            # match that are not related to each other.
            #
            # In the following case:
            #
            #  composition 'ManualDriving' do
            #    specialize 'Control', SimpleController, :not => FourWheelController do
            #    end
            #    specialize 'Control', FourWheelController, :not => SimpleController do
            #    end
            #  end
            #
            # If a Control model is selected that fullfills both
            # SimpleController and FourWheelController, then there is an
            # ambiguity as both specializations apply and one cannot be
            # preferred w.r.t. the other.
            #
            # By using
            #   default_specialization 'Control', SimpleController
            #
            # the first one will be preferred by default. The second one can
            # then be selected at instanciation time with
            #
            #   add 'ManualDriving',
            #       'Control' => controller_model.as(FourWheelController)
            def default_specialization(child, child_model)
                raise NotImplementedError

                child = if child.respond_to?(:to_str)
                            child.to_str
                        else child.name.gsub(/.*::/, '')
                        end

                default_specializations[child] = child_model
            end

            def instanciate_all_possible_specializations
                all = partition_specializations(specializations.values)

                done_subsets = Set.new

                result = []
                all.each do |merged, set|
                    (1..set.size).each do |subset_size|
                        set.to_a.combination(subset_size) do |subset|
                            subset = subset.to_set
                            if !done_subsets.include?(subset)
                                merged = Specialization.new
                                subset.each { |spec| merged.merge(spec) }
                                result << specialized_model(merged, subset)
                                done_subsets << subset
                            end
                        end
                    end
                end
                result
            end

            # [Hash{Hash{String=>Model} => CompositionSpecialization}] set of
            # specialized composition models already instantiated with
            # {#specialized_model}. The key is the specialization selectors and
            # the value the composite specialization, in which
            # {CompositionSpecialization#composition_model} returns the
            # composition model
            attribute(:instanciated_specializations) { Hash.new }

            # Returns the composition model that is a specialization of
            # {#composition_model}, applying the set of specializations in
            # 'applied_specializations' +composite_spec+ is a Specialization
            # object in which all the required specializations have been merged
            # and +applied_specializations+ the list of the specializations,
            # separate.
            def specialized_model(composite_spec, applied_specializations = [composite_spec])
                Models.debug do
                    Models.debug "instanciating specializations: #{applied_specializations.map(&:to_s).sort.join(", ")}"
                    Models.log_nest(2)
                    break
                end

                if composite_spec.specialized_children.empty?
                    return composition_model
                elsif current_model = instanciated_specializations[composite_spec.specialized_children]
                    return current_model.composition_model
                end

                # There's no composition with that spec. Create a new one
                child_composition = composition_model.new_submodel
                child_composition.parent_models << composition_model
                child_composition.extend Models::CompositionSpecialization::Extension
                child_composition.specialized_children.merge!(composite_spec.specialized_children)
                child_composition.applied_specializations = applied_specializations
                composite_spec.compatibilities.each do |single_spec|
                    child_composition.specializations.register(single_spec)
                end
                child_composition.private_model
                child_composition.root_model = composition_model.root_model
                composite_spec.specialized_children.each do |child_name, child_models|
                    child_composition.overload child_name, child_models
                end
                composite_spec.specialization_blocks.each do |block|
                    child_composition.apply_specialization_block(block)
                end
                composite_spec.composition_model = child_composition
                instanciated_specializations[composite_spec.specialized_children] = composite_spec

                child_composition
            ensure
                Models.debug do
                    Models.log_nest -2
                    break
                end
            end

            # Partitions a set of specializations into the smallest number of
            # partitions, where all the specializations in a subset of the
            # partition can be applied together
            #
            # @param [Array<CompositionSpecialization>] specialization_set the
            #   set of specializations to be partitioned
            # @return [[(CompositionSpecialization,Array<CompositionSpecialization>)]]
            #   the partitioned subsets, where the second element of each pair is
            #   the set of specializations that can be applied together and the
            #   first element the CompositionSpecialization object that is created
            #   by merging all the specialization specifications from the second
            #   element
            def partition_specializations(specialization_set)
                if specialization_set.empty?
                    return []
                end

                # What we have to do here is:
                #
                #   for each S0 in specialization_set
                #     for each S1 in compatibilities(S0)
                #       there exists C in result which contain S0 and S1
                #     end
                #   end
                #
                # We gather all the capabilities and iteratively remove the ones
                # for which this property is fullfilled
                result = []
                specialization_set = specialization_set.to_value_set

                compatibilities = Hash.new
                specialization_set.each do |s0|
                    compatibilities[s0] = (s0.compatibilities.to_value_set & specialization_set) << s0
                end
                compatibilities.each do |s0, remaining|
                    # Iterate over the existing elements
                    result.each do |merged, all|
                        if all.include?(s0)
                            remaining.difference!(all.to_value_set)
                        elsif merged.compatible_with?(s0)
                            # not there yet and compatible, add it
                            merged.merge(s0)
                            all << s0
                            remaining.difference!(all.to_value_set)
                        end
                    end

                    # Now, add new elements for what is left
                    merged, all = nil
                    while !remaining.empty?
                        if !merged
                            merged = CompositionSpecialization.new
                            merged.merge(s0)
                            all = [s0].to_set
                        end

                        remaining.delete(s1 = remaining.first)
                        next if s0 == s1 # possible if the iteration on 'result' above did not find anything
                        if merged.compatible_with?(s1)
                            merged.merge(s1)
                            all << s1
                        else
                            result << [merged, all]
                            merged = nil
                        end
                    end
                    if merged
                        result << [merged, all]
                    end
                end
                result
            end

            # Find the sets of specializations that match +selection+
            #
            # @return [[CompositionSpecialization,Array<CompositionSpecialization>]] set
            #   of (merged_specialization,atomic_specializations) pairs, in which:
            #   * merged_specialization is the Specialization instance
            #     representing the desired composite specialization
            #   * atomic_specializations is the set of single specializations
            #     that have been merged to obtain +merged_specialization+
            # 
            # Further disambiguation would, for instance, have to pick one of
            # these sets and call
            #
            #   specialized_model(*candidates[selected_element])
            #
            # to get the corresponding composition model
            def find_matching_specializations(selection)
                if specializations.empty? || selection.empty?
                    return []
                end

                Models.debug do
                    Models.debug "looking for specialization of #{short_name} on"
                    selection.each do |k, v|
                        Models.debug "  #{k} => #{v}"
                    end
                    break
                end

                matching_specializations = each_specialization.find_all do |spec_model|
                    spec_model.weak_match?(selection)
                end

                Models.debug do
                    Models.debug "  #{matching_specializations.size} matching specializations found"
                    matching_specializations.each do |m|
                        Models.debug "    #{m.specialized_children}"
                    end
                    break
                end

                if matching_specializations.empty?
                    return []
                end

                return partition_specializations(matching_specializations)
            end

            # Looks for a single composition model that matches the given
            # selection
            #
            # @param [{String=>SelectionModel}] selection the selections, as a
            #   mapping from a child name to a suitable selection in
            #   DependencyInjection
            # @return [Model<Composition>] the specialized model, or
            #   {#composition_model} if no specializations match
            # @raise [AmbiguousSpecialization] if multiple models match
            def matching_specialized_model(selection)
                candidates = find_matching_specializations(selection)
                if candidates.empty?
                    return composition_model
                elsif candidates.size > 1
                    if strict_specialization_selection?
                        raise AmbiguousSpecialization.new(composition_model, selection, candidates)
                    else
                        candidates = [find_common_specialization_subset(candidates)]
                    end
                end

                specialized_model = specialized_model(candidates.first)
                Models.debug do
                    if specialized_model != composition_model
                        Models.debug "using specialization #{specialized_model.short_name} of #{composition_model.short_name}"
                    end
                    break
                end
                return specialized_model
            end

            # Returns a single composition that can be used as a base model for
            # +selection+. Returns +self+ if the possible specializations are
            # ambiguous, or if no specializations apply. 
            def find_suitable_specialization(selection)
                all = find_matching_specializations(selection)
                if all.size != 1
                    return composition_model
                else
                    return specialized_model(*all.first)
                end
            end

            # Given a set of specialization sets, returns subset common to all
            # of the contained sets
            def find_common_specialization_subset(candidates)
                result = candidates[0][1].to_set
                candidates[1..-1].each do |merged, subset|
                    result &= subset.to_set
                end

                merged = result.inject(Specialization.new) do |merged, spec|
                    merged.merge(spec)
                end
                [merged, result]
            end
        end
    end
end