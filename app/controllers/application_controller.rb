class ApplicationController < ActionController::Base
  before_action :authenticate_user!
  before_action :sign_out_inactive_portal_user
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

  def sign_out_inactive_portal_user
    return unless user_signed_in?
    return if devise_controller?
    return if current_user.hod? || current_user.admin?

    employee_detail = portal_employee_detail_for(current_user)
    return unless employee_detail.present? && !employee_detail.portal_active?

    sign_out(current_user)
    redirect_to new_user_session_path, alert: "Your account is inactive. Please contact HOD."
  end

  def portal_employee_detail_for(user)
    user.employee_detail ||
      EmployeeDetail.find_by("lower(employee_email) = ?", user.email.to_s.downcase) ||
      EmployeeDetail.find_by("lower(employee_code) = ?", user.employee_code.to_s.downcase)
  end

  def current_user_identity_code
    current_user&.employee_code.to_s.strip.presence
  end

  def current_user_identity_email
    current_user&.email.to_s.strip.presence
  end

  def has_l1_responsibilities?
    return true if current_user.hod? || current_user.admin?

    code = current_user_identity_code
    email = current_user_identity_email
    return false if code.blank? && email.blank?

    EmployeeDetail.where(
      "(:code != '' AND TRIM(COALESCE(l1_code, '')) = :code) OR (:email != '' AND TRIM(COALESCE(l1_employer_name, '')) = :email)",
      code: code.to_s,
      email: email.to_s
    ).exists?
  end

  def has_l2_responsibilities?
    return true if current_user.hod? || current_user.admin?

    code = current_user_identity_code
    email = current_user_identity_email
    return false if code.blank? && email.blank?

    EmployeeDetail.where(
      "(:code != '' AND TRIM(COALESCE(l2_code, '')) = :code) OR (:email != '' AND TRIM(COALESCE(l2_employer_name, '')) = :email)",
      code: code.to_s,
      email: email.to_s
    ).exists?
  end

  def has_quarterly_pli_responsibilities?
    has_l1_responsibilities?
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

  def l1_pending_reviews_count
    return 0 unless user_signed_in? && has_l1_responsibilities?

    employee_scope = if current_user.hod? || current_user.admin?
      EmployeeDetail.all
    else
      code = current_user_identity_code
      return 0 if code.blank?

      EmployeeDetail.where(l1_code: code)
    end

    Achievement.joins(user_detail: :employee_detail)
      .merge(employee_scope)
      .where.not(achievement: [ nil, "" ])
      .where(status: [ nil, "pending", "submitted" ])
      .count
  rescue StandardError
    0
  end

  def l1_pending_reviews?
    l1_pending_reviews_count.positive?
  end

  helper_method :has_l1_responsibilities?, :has_l2_responsibilities?, :has_quarterly_pli_responsibilities?,
                :l1_pending_reviews_count, :l1_pending_reviews?
end
