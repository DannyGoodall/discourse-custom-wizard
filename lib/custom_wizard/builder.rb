class CustomWizard::Builder
  attr_accessor :wizard, :updater, :submissions

  def initialize(wizard_id, user=nil)
    template = CustomWizard::Template.find(wizard_id)
    return nil if template.blank?
    
    @wizard = CustomWizard::Wizard.new(template, user)
    @steps = template['steps'] || []
    @actions = template['actions'] || []
    @submissions = @wizard.submissions
  end

  def self.sorted_handlers
    @sorted_handlers ||= []
  end

  def self.step_handlers
    sorted_handlers.map { |h| { wizard_id: h[:wizard_id], block: h[:block] } }
  end

  def self.add_step_handler(priority = 0, wizard_id, &block)
    sorted_handlers << { priority: priority, wizard_id: wizard_id, block: block }
    @sorted_handlers.sort_by! { |h| -h[:priority] }
  end

  def self.sorted_content_providers
    @sorted_content_providers ||= []
  end

  def self.content_providers
    sorted_content_providers.map { |h| { field_id: h[:field_id], wizard_id: h[:wizard_id], value: h[:value],  block: h[:block] } }
  end

  def self.add_content_provider(priority = 0, wizard_id: nil, field_id: nil, value: nil,  &block)
    sorted_content_providers << { priority: priority, wizard_id: wizard_id, field_id: field_id, value: value,  block: block }
    @sorted_content_providers.sort_by! { |h| -h[:priority] }
  end
  
  def mapper
    CustomWizard::Mapper.new(
      user: @wizard.user,
      data: @submissions.last
    )
  end

  def build(build_opts = {}, params = {})
    return nil if !SiteSetting.custom_wizard_enabled || !@wizard
    return @wizard if !@wizard.can_access?
    
    build_opts[:reset] = build_opts[:reset] || @wizard.restart_on_revisit

    @steps.each do |step_template|
      @wizard.append_step(step_template['id']) do |step|
        step.permitted = true
        
        if step_template['required_data']
          step = ensure_required_data(step, step_template)
        end
              
        if !step.permitted
          if step_template['required_data_message']
            step.permitted_message = step_template['required_data_message'] 
          end
          next
        end
        
        step.title = step_template['title'] if step_template['title']
        step.banner = step_template['banner'] if step_template['banner']
        step.key = step_template['key'] if step_template['key']
        
        if step_template['description']
          step.description = mapper.interpolate(
            step_template['description'],
            user: true,
            value: true
          ) 
        end
        
        if permitted_params = step_template['permitted_params']
          save_permitted_params(permitted_params, params)
        end

        if step_template['fields'] && step_template['fields'].length
          step_template['fields'].each do |field_template|
            append_field(step, step_template, field_template, build_opts)
          end
        end

        step.on_update do |updater|
          @updater = updater
          user = @wizard.user
          
          updater.validate
                              
          next if updater.errors.any?

          CustomWizard::Builder.step_handlers.each do |handler|
            if handler[:wizard_id] == @wizard.id
              handler[:block].call(self)
            end
          end

          next if updater.errors.any?

          submission = updater.submission

          if current_submission = @wizard.current_submission
            submission = current_submission.merge(submission)
          end
          
          final_step = updater.step.next.nil?
                    
          if @actions.present?
            @actions.each do |action|
                            
              if (action['run_after'] === updater.step.id) ||
                 (final_step && (!action['run_after'] || (action['run_after'] === 'wizard_completion')))
                        
                CustomWizard::Action.new(
                  wizard: @wizard,
                  action: action,
                  user: user,
                  data: submission
                ).perform
              end
            end
          end
          
          if updater.errors.empty?
            if route_to = submission['route_to']
              submission.delete('route_to')
            end
            
            if @wizard.save_submissions
              save_submissions(submission, final_step)
            end
            
            if final_step
              if @wizard.id == @wizard.user.custom_fields['redirect_to_wizard']
                @wizard.user.custom_fields.delete('redirect_to_wizard');
                @wizard.user.save_custom_fields(true)
              end
              
              redirect_url = route_to || submission['redirect_on_complete'] || submission["redirect_to"]
              updater.result[:redirect_on_complete] = redirect_url
            elsif route_to
              updater.result[:redirect_on_next] = route_to
            end
            
            true
          else
            false
          end
        end
      end
    end
    
    @wizard
  end

  def append_field(step, step_template, field_template, build_opts)
    params = {
      id: field_template['id'],
      type: field_template['type'],
      required: field_template['required']
    }
    
    params[:label] = field_template['label'] if field_template['label']
    params[:description] = field_template['description'] if field_template['description']
    params[:image] = field_template['image'] if field_template['image']
    params[:key] = field_template['key'] if field_template['key']
    params[:min_length] = field_template['min_length'] if field_template['min_length']
    params[:value] = prefill_field(field_template, step_template)
    
    if !build_opts[:reset] && (submission = @wizard.current_submission)
      params[:value] = submission[field_template['id']] if submission[field_template['id']]
    end
    
    if field_template['type'] === 'group' && params[:value].present?
      params[:value] = params[:value].first
    end

    if field_template['type'] === 'checkbox'
      params[:value] = standardise_boolean(params[:value])
    end

    if field_template['type'] === 'upload'
      params[:file_types] = field_template['file_types']
    end
    
    if ['date', 'time', 'date_time'].include?(field_template['type'])
      params[:format] = field_template['format']
    end
        
    if field_template['type'] === 'category' || field_template['type'] === 'tag'
      params[:limit] = field_template['limit']
    end
    
    if field_template['type'] === 'category'
      params[:property] = field_template['property']
    end
        
    if field_template['type'] === 'category'
      @wizard.needs_categories = true
    end
    
    if field_template['type'] === 'group'
      @wizard.needs_groups = true
    end
    
    if (content_inputs = field_template['content']).present?
      content = CustomWizard::Mapper.new(
        inputs: content_inputs,
        user: @wizard.user,
        data: @submissions.last,
        opts: {
          with_type: true
        }
      ).perform
            
      if content.present? &&
         content[:result].present?
         
        if content[:type] == 'association'
          content[:result] = content[:result].map do |item|
            { 
              id: item[:key],
              name: item[:value] 
            }
          end
        end
        
        if content[:type] == 'assignment' && field_template['type'] === 'dropdown'
          content[:result] = content[:result].map do |item|
            { 
              id: item,
              name: item
            }
          end
        end
        
        params[:content] = content[:result]
      end
    end

    CustomWizard::Builder.content_providers.each do |content_provider|
      # The add_content_provider method above registers a block to run as well as the conditions
      # that, if met, will decide if the block is run for a given field.
      #
      # Those conditions are specified in the wizard_id, field_id and value parameters. If any of those
      # parameters are specified as nil (the default), then their value is ignored in deciding whether
      # the dynamic content block is executed.
      #
      # If any of these values is specified at block registration time, then the field being created has
      # to match all of them before the dynamic content block is executed.
      #
      # for example. If a block is registered like so
      #
      # add_content_provider(wizard_id: "get_important_details") do...
      #
      # then the block will be executed for every field in the named wizard. If the block is registered
      # like so
      #
      # add_content_provider(wizard_id: "get_important_details", "step_1_field_1") do...
      #
      # then the block will only be executed for the step_1_field_1 field of the get_important_details wizard
      #
      # Finally, the 'value' field, which comes from the wizard "prefill" value (for dropdown boxes), can also
      # be used as the arbiter of whether dynamic content is needed. For example, if the block is registered as
      #
      # add_content_provider(value: "dyn_populate_currencies") do...
      #
      # Then the block will be executed every time a field value of "dyn_populate_currencies" is found
      #
      # When the block is called below, it is passed a hash containing some useful context variables...
      #
      # {
      #   wizard: wizard,
      #   step: step,
      #   params: params,
      #   step_template: step_template,
      #   field_template: field_template,
      #   build_opts: build_opts
      # }
      #
      # The block is expected to manipulate the params value and to return any dynamic content in the
      # params[:content] and params[:value] elements (at least for dropdown menu choices.)
      #
      # check for an exact match for the identifier wizard/field/value
      if (content_provider[:wizard_id].nil? or (content_provider[:wizard_id] === @wizard.id)) and
          (content_provider[:field_id].nil? or (content_provider[:field_id] === params[:id])) and
          (content_provider[:value].nil? or (content_provider[:value] === params[:value]))
        content_provider_params = {
            wizard: wizard,
            step: step,
            params: params,
            step_template: step_template,
            field_template: field_template,
            build_opts: build_opts
        }
        params = content_provider[:block].call(content_provider_params)
      end
    end
    field = step.add_field(params)
  end
  
  def prefill_field(field_template, step_template)
    if (prefill = field_template['prefill']).present?
      CustomWizard::Mapper.new(
        inputs: prefill,
        user: @wizard.user,
        data: @submissions.last
      ).perform
    end
  end

  def standardise_boolean(value)
    ActiveRecord::Type::Boolean.new.cast(value)
  end

  def save_submissions(submission, final_step)
    if final_step
      submission['submitted_at'] = Time.now.iso8601
    end

    if submission.present?
      @submissions.pop(1) if @wizard.unfinished?
      @submissions.push(submission)
      @wizard.set_submissions(@submissions)
    end
  end
  
  def save_permitted_params(permitted_params, params)
    permitted_data = {}

    permitted_params.each do |pp|
      pair = pp['pairs'].first
      params_key = pair['key'].to_sym
      submission_key = pair['value'].to_sym
      permitted_data[submission_key] = params[params_key] if params[params_key]
    end

    if permitted_data.present?
      current_data = @submissions.last || {}
      save_submissions(current_data.merge(permitted_data), false)
    end
  end
  
  def ensure_required_data(step, step_template)
    step_template['required_data'].each do |required|
      pairs = required['pairs'].select do |pair|
        pair['key'].present? && pair['value'].present?
      end
      
      if pairs.any? && !@submissions.last
        step.permitted = false
        break
      end
      
      pairs.each do |pair| 
        pair['key'] = @submissions.last[pair['key']]
      end
            
      if !mapper.validate_pairs(pairs)
        step.permitted = false
        break
      end
    end
    
    step
  end
end
