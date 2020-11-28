class CustomWizard::StepUpdater
  include ActiveModel::Model

  # Added wizard to the list of accessors because now that the CWP UI no longer
  # allows the direct editing of field.id and instead generates field_id values that are
  # potentially identical in each wizard (step_1_field_1), the field_validator routine
  # (which is sent a step_updated) can no longer uniquely identify the field it is
  # working with. Only my looking across wizard.id and field.id can you identify the
  # field specifically.
  #
  attr_accessor :refresh_required, :submission, :result, :step. :wizard

  def initialize(current_user, wizard, step, submission)
    @current_user = current_user
    @wizard = wizard
    @step = step
    @refresh_required = false
    @submission = submission.to_h.with_indifferent_access
    @result = {}
  end

  def update
    if SiteSetting.custom_wizard_enabled &&
       @step.present? &&
       @step.updater.present? &&
       success?
      
      @step.updater.call(self)
      
      UserHistory.create(
        action: UserHistory.actions[:custom_wizard_step],
        acting_user_id: @current_user.id,
        context: @wizard.id,
        subject: @step.id
      )
    else
      false
    end
  end

  def success?
    @errors.blank?
  end

  def refresh_required?
    @refresh_required
  end
  
  def validate
    CustomWizard::UpdateValidator.new(self).perform
  end
end
