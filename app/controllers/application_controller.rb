class ApplicationController < ActionController::Base
  before_action :authenticate_user!
  before_action :configure_permitted_parameters, if: :devise_controller?

  protected

  def configure_permitted_parameters
    devise_parameter_sanitizer.permit(:sign_in, keys: [ :employee_code, :role ])
    devise_parameter_sanitizer.permit(:sign_up, keys: [ :employee_code, :role ])
  end

  # Override Devise's after_sign_in_path_for to always redirect to dashboard
  def after_sign_in_path_for(resource)
    dashboard_path
  end

  def has_l1_responsibilities?
    return true if current_user.hod?
    EmployeeDetail.exists?(l1_code: current_user.employee_code)
  end

  def has_l2_responsibilities?
    return true if current_user.hod?
    EmployeeDetail.exists?(l2_code: current_user.employee_code) ||
    EmployeeDetail.exists?(l2_employer_name: current_user.email)
  end

  def normalize_financial_year(value)
    year = value.to_s.strip
    return nil if year.blank?

    match = year.match(/\A(\d{4})\s*-\s*(\d{2}|\d{4})\z/)
    return year unless match

    start_year = match[1].to_i
    end_year = match[2].length == 2 ? ((start_year / 100) * 100) + match[2].to_i : match[2].to_i
    end_year += 100 if end_year <= start_year

    "#{start_year}-#{end_year}"
  end

  helper_method :has_l1_responsibilities?, :has_l2_responsibilities?
end
