  # class Department < ApplicationRecord
  #   has_many :activities, dependent: :destroy
  #   has_many :user_details

  #   accepts_nested_attributes_for :activities, allow_destroy: true, reject_if: :all_blank
  # end



  class Department < ApplicationRecord
  has_many :activities
  has_many :user_details

  accepts_nested_attributes_for :activities, allow_destroy: true, reject_if: :all_blank

  validates :department_type, presence: true
  # validates :employee_reference, presence: true

  # Callback to create UserDetail records when activities are created
  after_save :create_user_details_for_activities

  # Callback to handle activity updates and deletions
  after_update :sync_user_details_with_activities

  private

  def create_user_details_for_activities
    return unless employee_reference.present?

    # Find the employee
    employee = find_employee_by_reference(employee_reference)
    return unless employee

    year = financial_year.presence || current_financial_year

    # Create UserDetail records for each activity
    activities.each do |activity|
      # Check if UserDetail already exists to avoid duplicates
      existing_user_detail = UserDetail.find_by(
        department_id: id,
        activity_id: activity.id,
        employee_detail_id: employee.id,
        financial_year: year
      )

      unless existing_user_detail
        UserDetail.create!(
          department_id: id,
          activity_id: activity.id,
          employee_detail_id: employee.id,
          financial_year: year
        )
      end
    end
  end

  def sync_user_details_with_activities
    return unless employee_reference.present?

    # Find the employee
    employee = find_employee_by_reference(employee_reference)
    return unless employee

    year = financial_year.presence || current_financial_year

    # Get current activity IDs
    current_activity_ids = activities.pluck(:id)

    # Remove UserDetail records for activities that no longer exist
    UserDetail.where(
      department_id: id,
      employee_detail_id: employee.id,
      financial_year: year
    ).where.not(activity_id: current_activity_ids).destroy_all

    # Create UserDetail records for new activities
    current_activity_ids.each do |activity_id|
      existing_user_detail = UserDetail.find_by(
        department_id: id,
        activity_id: activity_id,
        employee_detail_id: employee.id,
        financial_year: year
      )

      unless existing_user_detail
        UserDetail.create!(
          department_id: id,
          activity_id: activity_id,
          employee_detail_id: employee.id,
          financial_year: year
        )
      end
    end
  end

  def current_financial_year
    start_year = Date.current.month >= 4 ? Date.current.year : Date.current.year - 1
    "#{start_year}-#{start_year + 1}"
  end

  # Get employee name from employee_reference (which stores employee_id)
  def employee_name
    employee = find_employee_by_reference(employee_reference)
    employee&.employee_name || "N/A"
  end

  # Get employee details
  def employee_detail
    find_employee_by_reference(employee_reference)
  end

  # Get employee code
  def employee_code
    employee = find_employee_by_reference(employee_reference)
    employee&.employee_code || "N/A"
  end

  # Get full employee display name with code
  def employee_display_name
    employee = find_employee_by_reference(employee_reference)
    if employee
      display_code = employee.employee_code.presence || employee.employee_id.presence
      "#{employee.employee_name} (#{display_code})"
    else
      "N/A"
    end
  end

  def find_employee_by_reference(reference)
    normalized_reference = reference.to_s.strip
    return nil if normalized_reference.blank?

    EmployeeDetail.find_by(employee_id: normalized_reference) ||
      EmployeeDetail.find_by(employee_code: normalized_reference)
  end
  end
