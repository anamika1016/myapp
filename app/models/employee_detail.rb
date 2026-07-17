class EmployeeDetail < ApplicationRecord
  DEFAULT_PORTAL_PASSWORD = "123456".freeze
  DEFAULT_PORTAL_ROLE = "employee".freeze
  PORTAL_ROLE_OPTIONS = %w[employee hod].freeze
  PORTAL_ROLE_LABELS = {
    "employee" => "Employee",
    "hod" => "HOD"
  }.freeze

  has_many :user_details, dependent: :destroy
  has_many :target_submissions, dependent: :destroy
  has_many :sms_logs, dependent: :destroy
  has_many :quarterly_pli_reviews, dependent: :destroy
  has_many :observer_pli_reviews, dependent: :destroy
  belongs_to :user, optional: true
  has_many :l1_pulse_assessments, dependent: :destroy
  has_many :user_training_assignments, dependent: :destroy
  has_many :assigned_trainings, through: :user_training_assignments, source: :training
  after_initialize :set_default_status, if: :new_record?
  after_commit :sync_portal_account, on: [ :create, :update ]
  # belongs_to :department  # only if you have a departments table and department_id column

  # Mobile number validation removed as requested

  def name
    employee_name
  end

  def self.ransackable_attributes(auth_object = nil)
    %w[
      employee_id
      employee_name
      employee_email
      employee_code
      mobile_number
      l1_code
      l1_employer_name
      l2_code
      l2_employer_name
      obs_code1
      obs_code2
      obs_code3
      obs_code4
      post
      location
      department
      portal_active
      created_at
      updated_at
    ]
  end


  enum :status, {
  pending: "pending",
  l1_approved: "l1_approved",
  l1_rejected: "l1_returned",
  l2_approved: "l2_approved",
  l2_returned: "l2_returned"
}

# app/models/employee_detail.rb
scope :l1_pending_records, -> { where(status: [ "pending", "returned" ]) }



  # ✅ Allow only safe associations (empty if none)
  def self.ransackable_associations(auth_object = nil)
    []
  end

  def set_default_status
   self.status ||= "pending"
  end

  def portal_status_label
    portal_active? ? "Active" : "Inactive"
  end

  def self.portal_role_options_for_select
    PORTAL_ROLE_OPTIONS.map { |role| [ PORTAL_ROLE_LABELS.fetch(role), role ] }
  end

  def portal_role
    role = @portal_role.presence || matching_portal_user_for_current_identifiers&.role.presence || DEFAULT_PORTAL_ROLE
    PORTAL_ROLE_OPTIONS.include?(role) ? role : DEFAULT_PORTAL_ROLE
  end

  def portal_role=(value)
    @portal_role = value
    @portal_role_assigned = true
  end

  def ensure_portal_user!
    return unless portal_lookup_ready?

    normalized_email = employee_email.to_s.strip.downcase
    normalized_code = employee_code.to_s.strip
    account = matching_portal_user(normalized_email, normalized_code)

    if account
      account.email = normalized_email if normalized_email.present?
      account.employee_code = normalized_code if normalized_code.present?
      account.role = normalized_portal_role if portal_role_assigned?
      account.role = DEFAULT_PORTAL_ROLE if account.role.blank?
      account.password = DEFAULT_PORTAL_PASSWORD if account.encrypted_password.blank?
      account.password_confirmation = DEFAULT_PORTAL_PASSWORD if account.encrypted_password.blank?
      account.save! if account.changed?
    else
      return unless portal_account_create_ready?(normalized_email, normalized_code)

      account = User.create!(
        email: normalized_email,
        employee_code: normalized_code,
        role: portal_role_assigned? ? normalized_portal_role : DEFAULT_PORTAL_ROLE,
        password: DEFAULT_PORTAL_PASSWORD,
        password_confirmation: DEFAULT_PORTAL_PASSWORD
      )
    end

    update_column(:user_id, account.id) if persisted? && user_id != account.id
    account
  end

  private

  def sync_portal_account
    ensure_portal_user!
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.error("EmployeeDetail##{id} portal account sync failed: #{e.message}")
  end

  def portal_lookup_ready?
    employee_email.present? || employee_code.present?
  end

  def portal_account_create_ready?(normalized_email, normalized_code)
    normalized_email.present? && normalized_code.present?
  end

  def portal_role_assigned?
    @portal_role_assigned == true
  end

  def normalized_portal_role
    role = @portal_role.to_s.strip.downcase.tr(" ", "_")
    return DEFAULT_PORTAL_ROLE if role.blank?

    PORTAL_ROLE_OPTIONS.include?(role) ? role : DEFAULT_PORTAL_ROLE
  end

  def matching_portal_user(normalized_email, normalized_code)
    linked_user = user

    if linked_user.present? && linked_user_matches?(linked_user, normalized_email, normalized_code)
      return linked_user
    end

    user_by_email = User.find_by("lower(email) = ?", normalized_email) if normalized_email.present?
    user_by_email ||
      (User.find_by("lower(employee_code) = ?", normalized_code.downcase) if normalized_code.present?)
  end

  def linked_user_matches?(linked_user, normalized_email, normalized_code)
    (normalized_email.present? && linked_user.email.to_s.strip.downcase == normalized_email) ||
      (normalized_code.present? && linked_user.employee_code.to_s.strip.downcase == normalized_code.downcase)
  end

  def matching_portal_user_for_current_identifiers
    return unless portal_lookup_ready?

    matching_portal_user(employee_email.to_s.strip.downcase, employee_code.to_s.strip)
  end
end
