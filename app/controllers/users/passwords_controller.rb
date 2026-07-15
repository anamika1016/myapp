class Users::PasswordsController < Devise::PasswordsController
  def create
    employee_code = params.dig(resource_name, :employee_code).to_s.strip
    self.resource = find_or_provision_employee_user(employee_code)

    if resource
      token = set_reset_password_token(resource)
      redirect_to edit_user_password_path(reset_password_token: token)
    else
      self.resource = resource_class.new(employee_code: employee_code)
      flash.now[:alert] = "Employee code not found"
      render :new
    end
  end

  private

  def find_or_provision_employee_user(employee_code)
    return if employee_code.blank?

    resource_class.find_by("LOWER(TRIM(employee_code)) = ?", employee_code.downcase) ||
      provision_employee_account(employee_code)
  end

  def provision_employee_account(employee_code)
    employee = EmployeeDetail.find_by("LOWER(TRIM(employee_code)) = ?", employee_code.downcase)
    return unless employee&.portal_active?

    employee.ensure_portal_user!
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.error("Password reset auto-provision failed for #{employee_code}: #{e.message}")
    nil
  end

  def set_reset_password_token(user)
    raw, enc = Devise.token_generator.generate(User, :reset_password_token)
    user.reset_password_token   = enc
    user.reset_password_sent_at = Time.now.utc
    user.save(validate: false)
    raw
  end
end
