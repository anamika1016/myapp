class UserDetailsController < ApplicationController
  require "csv"
  require "nokogiri"
  require "roo"
  require "roo-xls"
  require "ostruct"
  require "set"
  require "zip"
  require "bigdecimal"
  MONTH_ATTRIBUTES = %i[
    april may june july august september october november december january february march
  ].freeze
  REMARKS_MAX_LENGTH = 500
  MANUAL_KRI_THEME = "manual_kri"
  MAX_MANUAL_KRI_ROWS = 3
  SPREADSHEET_ERROR_VALUES = %w[#DIV/0! #N/A #NAME? #NULL! #NUM! #REF! #VALUE!].freeze

  TextImportSpreadsheet = Struct.new(:rows) do
    def row(number)
      rows[number.to_i - 1] || []
    end

    def last_row
      rows.length
    end
  end

  before_action :set_user_detail, only: [ :show, :edit, :update, :destroy ]
  load_and_authorize_resource except: [ :index, :new, :create, :get_user_detail, :get_activities, :bulk_create, :submit_achievements, :export, :import, :quarterly_edit_all, :update_quarterly_achievements, :test_sms, :view_sms_logs, :submitted_achievements ]

  def index
    set_financial_year_context
    scope = target_details_scope

    @user_details = scope.page(params[:page]).per(100).load
  end

  def new
    @user_detail = UserDetail.new
    set_financial_year_context

    # Load unique departments
    @departments = Department.where(financial_year: @selected_financial_year)
                             .order(:department_type)
                             .select("DISTINCT ON (department_type) id, department_type")

    # Filter employees based on selected department
    @selected_department = Department.find_by(id: params[:department_id]) if params[:department_id].present?
    if params[:department_id].present?
      begin
        dept_type = @selected_department&.department_type || Department.find(params[:department_id]).department_type
        @employee_details = EmployeeDetail.where(department: dept_type)
                                          .select(:id, :employee_name, :l1_employer_name, :l2_employer_name, :post, :location, :department)
                                          .order(:employee_name)
      rescue ActiveRecord::RecordNotFound
        flash[:alert] = "Department not found."
        @employee_details = EmployeeDetail.none
      end
    else
      @employee_details = EmployeeDetail.none
    end

    # Find selected employee to show L1/L2
    if params[:employee_detail_id].present?
      begin
        @selected_employee = EmployeeDetail.find_by(id: params[:employee_detail_id])
      rescue ActiveRecord::RecordNotFound
        flash[:alert] = "Employee not found."
        @selected_employee = nil
      end
    end

    @users = User.select(:id, :email, :role) if params[:show_users]

    # Load employee-specific activities when both department and employee are selected
    if params[:department_id].present? && params[:employee_detail_id].present?
      begin
        selected_department_type = @selected_department&.department_type
        user_details_scope = UserDetail.includes(:department, :activity, :employee_detail)
                                       .where(employee_detail_id: params[:employee_detail_id])
                                       .where(financial_year: @selected_financial_year)
                                       .where.not(activity_id: nil)

        if selected_department_type.present?
          user_details_scope = user_details_scope.joins(:department)
                                                 .where(departments: { department_type: selected_department_type })
        else
          user_details_scope = user_details_scope.where(department_id: params[:department_id])
        end

        # Department dropdowns use one row per department name, while imported KRIs are
        # stored on employee-specific department rows. Resolve by department name so the
        # selected employee's actual KRI rows are shown dynamically.
        @user_details = user_details_scope.order("user_details.id ASC").to_a
        @activity_detail_rows = @user_details.filter_map do |detail|
          activity = detail.activity
          activity ? [ activity, detail ] : nil
        end
        @employee_activities = @activity_detail_rows.map(&:first)
        @details_by_activity_id = @user_details.index_by(&:activity_id)
        @resolved_department_id = @user_details.first&.department_id || params[:department_id]
      rescue ActiveRecord::RecordNotFound => e
        flash[:alert] = "Error loading data: #{e.message}"
        @employee_activities = []
        @user_details = UserDetail.none
        @activity_detail_rows = []
        @details_by_activity_id = {}
        @resolved_department_id = params[:department_id]
      rescue => e
        flash[:alert] = "An error occurred while loading data."
        Rails.logger.error "Error in new action: #{e.message}"
        @employee_activities = []
        @user_details = UserDetail.none
        @activity_detail_rows = []
        @details_by_activity_id = {}
        @resolved_department_id = params[:department_id]
      end
    else
      @employee_activities = []
      @user_details = UserDetail.none
      @activity_detail_rows = []
      @details_by_activity_id = {}
      @resolved_department_id = params[:department_id]
    end
  end

  def create
    @user_detail = UserDetail.new(user_detail_params)

    if @user_detail.save
      redirect_to new_user_detail_path, notice: "User detail was successfully created."
    else
      load_form_data
      render :new
    end
  end

  def edit
    @departments = Department.select(:id, :department_type)
    @activities = Activity.select(:id, :activity_name, :unit, :theme_name, :annual_target_fy_2026_27)
                         .where(department_id: @user_detail.department_id)
  end

  def update
    begin
      # Store the current context before update
      department_id = @user_detail.department_id
      employee_detail_id = @user_detail.employee_detail_id

      if @user_detail.update(user_detail_params)
        # Clear any existing flash messages
        flash.clear

        # Role-based redirect
        if current_user.hod?
          # HOD redirects to new user detail form
          redirect_to new_user_detail_path(department_id: department_id, employee_detail_id: employee_detail_id),
                      notice: "User detail was successfully updated."
        else
          # Employee/L1/L2 redirects to HOD TARGET FORM (index page)
          redirect_to user_details_path,
                      notice: "User detail was successfully updated."
        end
      else
        @departments = Department.select(:id, :department_type)
        @activities = Activity.select(:id, :activity_name, :unit, :theme_name, :annual_target_fy_2026_27)
                             .where(department_id: @user_detail.department_id)
        render :edit
      end
    rescue => e
      Rails.logger.error "Error in update action: #{e.message}"

      # Clear any existing flash messages
      flash.clear

      # Role-based error redirect
      if current_user.hod?
        redirect_to new_user_detail_path,
                    alert: "An error occurred while updating the user detail."
      else
        redirect_to user_details_path,
                    alert: "An error occurred while updating the user detail."
      end
    end
  end


  def update_quarterly_achievements
    set_financial_year_context

    # Get the correct parameters
    selected_month = params[:selected_month].to_s.downcase
    selected_quarter = params[:selected_quarter]
    achievement_data = params[:achievements] || {}
    success_count = 0
    errors = []
    updated_activities = []

    if achievement_data.empty?
      flash[:alert] = "No achievement data received. Please try again."
      redirect_to quarterly_edit_all_user_details_path(financial_year: @selected_financial_year)
      return
    end

    # Prefer monthly editing. Keep quarter fallback so old links/forms do not break.
    editable_months = if MONTH_ATTRIBUTES.map(&:to_s).include?(selected_month)
      [ selected_month ]
    else
      case selected_quarter
      when "Q1"
        [ "april", "may", "june" ]
      when "Q2"
        [ "july", "august", "september" ]
      when "Q3"
        [ "october", "november", "december" ]
      when "Q4"
        [ "january", "february", "march" ]
      else
        []
      end
    end

    if editable_months.empty?
      flash[:alert] = "Please select a month first."
      redirect_to quarterly_edit_all_user_details_path(financial_year: @selected_financial_year)
      return
    end

    # Track which employee_details had changes to reset their quarter only
    employee_details_with_changes = Set.new

    user_detail_ids = achievement_data.keys.map(&:to_s)
    user_details_by_id = UserDetail.includes(:activity, :employee_detail)
                                   .where(id: user_detail_ids)
                                   .index_by { |detail| detail.id.to_s }
    achievements_by_detail_month = Achievement.where(user_detail_id: user_detail_ids, month: editable_months)
                                               .index_by { |achievement| [ achievement.user_detail_id.to_s, achievement.month.to_s.downcase ] }

    ActiveRecord::Base.transaction do
      achievement_data.each do |user_detail_id, monthly_data|
        user_detail = user_details_by_id[user_detail_id.to_s]
        next unless user_detail

        activity_updated = false

        monthly_data.each do |month, values|
          # IMPORTANT: Only process selected month/months.
          next unless editable_months.include?(month)

          achievement_value = values[:achievement]
          employee_remarks = values[:employee_remarks]

          # Skip if both achievement and remarks are blank
          next if achievement_value.blank? && employee_remarks.blank?

          if achievement_value.present? && !valid_numeric_value?(achievement_value)
            errors << "Failed to save #{short_month_label(month)} for #{user_detail.activity.activity_name}: Achievement must be a number"
            next
          end

          if employee_remarks.to_s.length > REMARKS_MAX_LENGTH
            errors << "Failed to save #{short_month_label(month)} for #{user_detail.activity.activity_name}: Remarks cannot exceed #{REMARKS_MAX_LENGTH} characters"
            next
          end

          # Find or initialize achievement
          achievement = achievements_by_detail_month[[ user_detail.id.to_s, month.to_s.downcase ]] ||
                        Achievement.new(user_detail: user_detail, month: month)

          # Store old values for comparison
          old_achievement = achievement.achievement
          old_remarks = achievement.employee_remarks

          # Update values
          achievement.achievement = achievement_value.present? ? normalize_numeric_value(achievement_value) : nil
          achievement.employee_remarks = employee_remarks.present? ? employee_remarks.to_s.strip : nil

          # Save if there are changes
          if achievement.achievement != old_achievement || achievement.employee_remarks != old_remarks
            if achievement.save
              success_count += 1
              activity_updated = true
              # Mark this employee_detail as having changes for quarterly status update
              employee_details_with_changes.add(user_detail.employee_detail_id)
            else
              error_msg = "Failed to save #{short_month_label(month)} for #{user_detail.activity.activity_name}: #{achievement.errors.full_messages.join(', ')}"
              errors << error_msg
            end
          end
        end

        if activity_updated
          activity_name = "#{user_detail.employee_detail&.employee_name} - #{user_detail.activity.activity_name}"
          updated_activities << activity_name
        end
      end

      # FIXED: Only set achievements to pending for employees who actually made changes
      # This ensures that only the specific employee's data gets reset to pending
      employee_details_with_changes.each do |employee_detail_id|
        # Get all achievements for this specific employee in the selected month/months
        employee_achievements = Achievement.joins(:user_detail)
                                        .where(user_details: { employee_detail_id: employee_detail_id, financial_year: @selected_financial_year })
                                        .where(month: editable_months)

        # Set status to pending for this employee's achievements only
        updated_count = employee_achievements.update_all(status: "pending")

        # Also reset approval remarks for this employee's achievements
        AchievementRemark.where(achievement_id: employee_achievements.select(:id)).update_all(
          l1_remarks: nil,
          l1_percentage: nil,
          l2_remarks: nil,
          l2_percentage: nil,
          updated_at: Time.current
        )
      end
    end

    # Handle response messages
    if errors.empty?
      if success_count > 0
        flash[:notice] = "✅ Updated #{success_count} records. Pending approval."
      else
        flash[:notice] = "No changes were made to the achievements."
      end
    else
      flash[:alert] = "⚠️ Some updates failed: #{errors.first(2).join('; ')}"
      flash[:alert] += " and #{errors.count - 2} more errors..." if errors.count > 2
    end

    redirect_to quarterly_edit_all_user_details_path(financial_year: @selected_financial_year, month: editable_months.first)

    rescue => e
      Rails.logger.error "Quarterly update error: #{e.message}\n#{e.backtrace.join("\n")}"
      flash[:alert] = "❌ An error occurred while updating achievements: #{e.message}"
      redirect_to quarterly_edit_all_user_details_path(financial_year: @selected_financial_year, month: editable_months&.first)
  end

  # FIXED: Quarterly edit all method
  def quarterly_edit_all
    set_financial_year_context

    if current_user.role == "employee" || current_user.role == "l1_employer" || current_user.role == "l2_employer"
      employee_detail = EmployeeDetail.find_by(employee_email: current_user.email)
      @user_details = if employee_detail
        UserDetail.left_joins(:department, :activity)
                .preload(:department, :activity, :employee_detail, achievements: :achievement_remark)
                .where(employee_detail_id: employee_detail.id)
                .where(financial_year: @selected_financial_year)
                .order("departments.department_type, activities.activity_name")
                .load
      else
        UserDetail.none
      end
    elsif current_user.role == "hod"
      @user_details = UserDetail.left_joins(:department, :activity, :employee_detail)
                              .preload(:department, :activity, :employee_detail, achievements: :achievement_remark)
                              .where(financial_year: @selected_financial_year)
                              .order("departments.department_type, employee_details.employee_name, activities.activity_name")
                              .load
    else
      @user_details = UserDetail.none
    end


    # FIXED: Correct quarter definitions to match the system
    @quarters = [
      { name: "Q1", months: [ "april", "may", "june" ], label: "Q1 (Apr-Jun)" },
      { name: "Q2", months: [ "july", "august", "september" ], label: "Q2 (Jul-Sep)" },
      { name: "Q3", months: [ "october", "november", "december" ], label: "Q3 (Oct-Dec)" },
      { name: "Q4", months: [ "january", "february", "march" ], label: "Q4 (Jan-Mar)" }
    ]
    set_active_month_context(@user_details)
  end


  def destroy
    begin
      @user_detail = UserDetail.find(params[:id])

      # Store the current context before deletion
      department_id = @user_detail.department_id
      employee_detail_id = @user_detail.employee_detail_id

      if @user_detail.destroy
        # Clear any existing flash messages
        flash.clear

        # Role-based redirect
        if current_user.hod?
          # HOD redirects to new user detail form
          redirect_to new_user_detail_path(department_id: department_id, employee_detail_id: employee_detail_id),
                      notice: "User detail was successfully deleted."
        else
          # Employee/L1/L2 redirects to HOD TARGET FORM (index page)
          redirect_to user_details_path,
                      notice: "User detail was successfully deleted."
        end
      else
        # Clear any existing flash messages
        flash.clear

        # Role-based error redirect
        if current_user.hod?
          redirect_to new_user_detail_path,
                      alert: "Failed to delete user detail."
        else
          redirect_to user_details_path,
                      alert: "Failed to delete user detail."
        end
      end
    rescue ActiveRecord::RecordNotFound
      # Clear any existing flash messages
      flash.clear

      # Role-based error redirect
      if current_user.hod?
        redirect_to new_user_detail_path,
                    alert: "User detail not found."
      else
        redirect_to user_details_path,
                    alert: "User detail not found."
      end
    rescue => e
      Rails.logger.error "Error in destroy action: #{e.message}"

      # Clear any existing flash messages
      flash.clear

      # Role-based error redirect
      if current_user.hod?
        redirect_to new_user_detail_path,
                    alert: "An error occurred while deleting the user detail."
      else
        redirect_to user_details_path,
                    alert: "An error occurred while deleting the user detail."
      end
    end
  end

  def test_sms
    # Test SMS functionality directly
    begin
      # Find a real employee detail record that has L1 code and mobile number
      test_employee = EmployeeDetail.joins(:user_detail)
                                   .where.not(l1_code: [ nil, "" ])
                                   .where.not(mobile_number: [ nil, "" ])
                                   .first

      if test_employee.nil?
        flash[:alert] = "❌ No employee found with L1 code and mobile number for testing"
        redirect_to get_user_detail_user_details_path
        return
      end

      # Find the L1 manager
      l1_manager = EmployeeDetail.find_by("employee_code LIKE ?", test_employee.l1_code.strip + "%")

      if l1_manager.nil?
        flash[:alert] = "❌ L1 manager not found with code: #{test_employee.l1_code}"
        redirect_to get_user_detail_user_details_path
        return
      end

      if l1_manager.mobile_number.blank?
        flash[:alert] = "❌ L1 manager #{l1_manager.employee_name} has no mobile number"
        redirect_to get_user_detail_user_details_path
        return
      end

      # Test with Q1 quarter
      result = send_sms_to_l1(test_employee, "Q1 (APR-JUN)", nil)

      if result[:success]
        flash[:notice] = "✅ Test SMS sent successfully! Message ID: #{result[:message_id]}"
      else
        flash[:alert] = "❌ Test SMS failed: #{result[:error]}"
        Rails.logger.error "Test SMS failed: #{result.inspect}"
      end

    rescue => e
      flash[:alert] = "❌ Test SMS error: #{e.message}"
      Rails.logger.error "Test SMS error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    end

    redirect_to get_user_detail_user_details_path
  end

  def get_user_detail
    set_financial_year_context

    if [ "employee", "l1_employer", "l2_employer" ].include?(current_user.role)
      @employee_detail = EmployeeDetail.find_by(employee_email: current_user.email)

      @user_details = if @employee_detail
        UserDetail.includes(:department, :activity, :employee_detail, achievements: :achievement_remark)
                  .where(employee_detail_id: @employee_detail.id)
                  .where(financial_year: @selected_financial_year)
                  .order("user_details.id ASC")
                  .load
      else
        UserDetail.none
      end

    elsif current_user.role == "hod"
      @user_details = UserDetail.includes(:department, :activity, :employee_detail, achievements: :achievement_remark)
                                .where(financial_year: @selected_financial_year)
                                .order("user_details.employee_detail_id ASC, user_details.id ASC")
                                .load
      @employee_detail = nil
    end

    set_active_month_context(@user_details, default_to_first: false)
    set_manual_kri_month_context
    @achievement_entry_locked = current_user.role != "hod" && @selected_month.present? && achievement_entry_locked_for_month?(@user_details, @selected_month)
    @achievement_entry_lock_message = "This month is locked because L1 has approved it." if @achievement_entry_locked
  end

  def submitted_achievements
    set_financial_year_context

    if [ "employee", "l1_employer", "l2_employer" ].include?(current_user.role)
      @employee_detail = EmployeeDetail.find_by(employee_email: current_user.email)

      @user_details = if @employee_detail
        UserDetail.includes(:department, :activity, :employee_detail, achievements: :achievement_remark)
                  .where(employee_detail_id: @employee_detail.id)
                  .where(financial_year: @selected_financial_year)
                  .order("user_details.id ASC")
                  .load
      else
        UserDetail.none
      end

    elsif current_user.role == "hod"
      @user_details = UserDetail.includes(:department, :activity, :employee_detail, achievements: :achievement_remark)
                                .where(financial_year: @selected_financial_year)
                                .order("user_details.employee_detail_id ASC, user_details.id ASC")
                                .load
      @employee_detail = nil
    else
      @employee_detail = nil
      @user_details = UserDetail.none
    end

    set_active_month_context(@user_details, include_all_months: true)
    if params[:month].blank?
      first_month_with_data = MONTH_ATTRIBUTES.find do |month_key|
        @user_details.any? do |detail|
          detail.achievements.any? do |achievement|
            achievement.month.to_s.downcase == month_key.to_s && achievement.achievement.present?
          end
        end
      end
      @selected_month = first_month_with_data.to_s if first_month_with_data.present?
    end
    @selected_quarter = quarter_name_for_month(@selected_month)
    @display_observer_levels = submitted_achievements_observer_levels(@user_details)
    @has_submitted_achievements = @user_details.any? do |detail|
      detail.achievements.any? { |achievement| achievement.achievement.present? }
    end
    @achievement_entry_locked = current_user.role != "hod" && achievement_entry_locked_for_month?(@user_details, @selected_month)
    @achievement_entry_lock_message = "This month is locked because L1 has approved it." if @achievement_entry_locked
  end

  def submit_achievements
    begin
      achievement_data = params[:achievement] || {}
      new_target_data = params[:new_targets] || {}
      target_update_data = params[:target_updates] || {}
      success_count = 0
      target_count = 0
      target_update_count = 0
      sms_results = []
      processed_employees = Set.new
      errors = []


      ActiveRecord::Base.transaction do
        financial_year_for_lock = normalize_financial_year(params[:financial_year]) || @selected_financial_year || current_financial_year
        selected_submission_month = params[:month].to_s.downcase
        submitted_user_detail_ids = (achievement_data.keys + target_update_data.keys).map(&:to_s).uniq
        submitted_months = selected_submission_month.present? ? [ selected_submission_month ] : MONTH_ATTRIBUTES.map(&:to_s)
        user_details_by_id = UserDetail.includes(:activity, :employee_detail)
                                       .where(id: submitted_user_detail_ids)
                                       .index_by { |detail| detail.id.to_s }
        achievements_by_detail_month = Achievement.where(user_detail_id: submitted_user_detail_ids, month: submitted_months)
                                                   .index_by { |achievement| [ achievement.user_detail_id.to_s, achievement.month.to_s.downcase ] }
        locked_month_cache = {}
        achievement_locked = lambda do |employee_detail_id, financial_year, month|
          key = [ employee_detail_id.to_s, financial_year.to_s, month.to_s.downcase ]
          locked_month_cache.fetch(key) do
            locked_month_cache[key] = achievement_locked_for_employee_month?(employee_detail_id, financial_year, month)
          end
        end

        if new_target_data.present?
          employee_detail = current_user_target_employee_detail

          if employee_detail.blank?
            errors << "Employee detail not found for new key result indicator."
          elsif selected_submission_month.present? && achievement_locked.call(employee_detail.id, financial_year_for_lock, selected_submission_month)
            errors << "#{short_month_label(selected_submission_month)}: This month is locked after L1 approval"
          else
            financial_year = financial_year_for_lock
            department = department_for_new_target(employee_detail, financial_year)

            if selected_submission_month.blank?
              errors << "Please select a month before adding key result indicators."
            end

            new_target_entries = new_target_data.values.select do |target_params|
              normalize_import_display_value(target_params[:activity_name] || target_params["activity_name"]).present?
            end

            if selected_submission_month.present?
              existing_manual_kri_count = manual_kri_count_for_month(employee_detail.id, financial_year_for_lock, selected_submission_month)
              if existing_manual_kri_count + new_target_entries.size > MAX_MANUAL_KRI_ROWS
                errors << "You can add only #{MAX_MANUAL_KRI_ROWS} key result indicator rows per month (#{short_month_label(selected_submission_month)})."
              end
            end

            new_target_entries.first(MAX_MANUAL_KRI_ROWS).each do |target_params|
              activity_name = normalize_import_display_value(target_params[:activity_name] || target_params["activity_name"])
              next if activity_name.blank?

              unit = normalize_import_display_value(target_params[:unit] || target_params["unit"])
              annual_target_fy = normalize_import_display_value(target_params[:annual_target_fy] || target_params["annual_target_fy"])
              month_data = manual_kri_month_data_for_submission(target_params, selected_submission_month)
              selected_month_target = month_data[selected_submission_month.to_sym]

              if selected_submission_month.present? && selected_month_target.blank?
                errors << "#{short_month_label(selected_submission_month)}: Target is required for new key result indicator #{activity_name}."
                next
              end

              activity = department.activities.build(
                activity_name: activity_name,
                unit: unit,
                annual_target_fy: annual_target_fy,
                theme_name: MANUAL_KRI_THEME
              )
              activity.save!

              user_detail = UserDetail.create!(
                department_id: department.id,
                activity_id: activity.id,
                employee_detail_id: employee_detail.id,
                financial_year: financial_year,
                **month_data
              )
              target_count += 1

              new_achievements = target_params[:achievements] || target_params["achievements"] || {}
              new_achievements = new_achievements.to_unsafe_h if new_achievements.respond_to?(:to_unsafe_h)
              new_achievements.each do |month, values|
                next if selected_submission_month.present? && month.to_s.downcase != selected_submission_month

                if achievement_locked.call(employee_detail.id, financial_year, month)
                  errors << "#{short_month_label(month)}: This month is locked after L1 approval"
                  next
                end

                achievement_value = values[:achievement] || values["achievement"]
                employee_remarks = values[:employee_remarks] || values["employee_remarks"]
                month_key = month.to_s.downcase
                target_value = month_data[month_key.to_sym]

                next if achievement_value.blank? && employee_remarks.blank? && target_value.blank?

                if target_value.blank?
                  errors << "#{short_month_label(month)}: Target is required before submitting achievement"
                  next
                end

                if achievement_value.blank? && employee_remarks.blank?
                  errors << "#{short_month_label(month)} for #{activity_name}: Remarks are required when Achievement is blank"
                  next
                end

                if achievement_value.present? && !valid_numeric_value?(achievement_value)
                  errors << "#{short_month_label(month)}: Achievement must be a number"
                  next
                end

                if employee_remarks.to_s.length > REMARKS_MAX_LENGTH
                  errors << "#{short_month_label(month)}: Remarks cannot exceed #{REMARKS_MAX_LENGTH} characters"
                  next
                end

                achievement = Achievement.find_or_initialize_by(
                  user_detail: user_detail,
                  month: month
                )
                achievement.achievement = achievement_value.present? ? normalize_numeric_value(achievement_value) : nil
                achievement.employee_remarks = employee_remarks.to_s.strip.presence
                achievement.status = "pending"

                if achievement.save
                  success_count += 1
                end
              end

              unless processed_employees.include?(employee_detail.id)
                quarters_filled = new_achievements.each_with_object(Set.new) do |(month, values), quarters|
                  next if selected_submission_month.present? && month.to_s.downcase != selected_submission_month

                  achievement_value = values[:achievement] || values["achievement"]
                  employee_remarks = values[:employee_remarks] || values["employee_remarks"]
                  target_value = month_data[month.to_s.downcase.to_sym]
                  next if target_value.blank?
                  next unless achievement_submission_ready_for_review?(achievement_value, employee_remarks)

                  quarter = determine_quarter(month)
                  quarters.add(quarter) if quarter.present?
                end

                if quarters_filled.any?
                  processed_employees.add(employee_detail.id)
                  quarters_filled.each do |quarter|
                    sms_result = notify_reviewers_after_submission(employee_detail, quarter, selected_submission_month, user_detail)
                    sms_results << {
                      quarter: quarter,
                      employee: employee_detail.employee_name,
                      success: sms_result[:success],
                      message: sms_result[:success] ? sms_result[:message] || "SMS sent successfully" : sms_result[:error]
                    }
                  end
                end
              end
            end
          end
        end

        if target_update_data.present?
          target_update_data.each do |user_detail_id, monthly_targets|
            user_detail = user_details_by_id[user_detail_id.to_s]
            next unless user_detail

            target_attributes = {}
            monthly_targets.each do |month, target_value|
              month_key = month.to_s.downcase
              next unless MONTH_ATTRIBUTES.map(&:to_s).include?(month_key)
              next if selected_submission_month.present? && month_key != selected_submission_month
              if achievement_locked.call(user_detail.employee_detail_id, user_detail.financial_year, month_key)
                errors << "#{short_month_label(month_key)}: This month is locked after L1 approval"
                next
              end
              next unless target_editable_for_month?(user_detail, month_key)

              normalized_value = normalize_import_display_value(target_value)
              current_value = normalize_import_display_value(user_detail.public_send(month_key))
              next if normalized_value.to_s == current_value.to_s

              target_attributes[month_key] = normalized_value
            end

            if target_attributes.any?
              user_detail.update!(target_attributes)
              target_update_count += target_attributes.size
            end
          end
        end

        achievement_data.each do |user_detail_id, monthly_data|
          user_detail = user_details_by_id[user_detail_id.to_s]
          next unless user_detail

          employee_detail = user_detail.employee_detail
          next unless employee_detail

          monthly_data.each do |month, values|
            next if selected_submission_month.present? && month.to_s.downcase != selected_submission_month

            if achievement_locked.call(employee_detail.id, user_detail.financial_year, month)
              errors << "#{short_month_label(month)}: This month is locked after L1 approval"
              next
            end

            achievement_value = values[:achievement] || values["achievement"]
            employee_remarks = values[:employee_remarks] || values["employee_remarks"]

            target_value = normalize_import_display_value(user_detail.send(month))
            next if achievement_value.blank? && employee_remarks.blank? && target_value.blank?

            if target_value.blank?
              errors << "#{short_month_label(month)} for #{user_detail.activity.activity_name}: Target is required before submitting achievement"
              next
            end

            if achievement_value.blank? && employee_remarks.blank?
              errors << "#{short_month_label(month)} for #{user_detail.activity.activity_name}: Remarks are required when Achievement is blank"
              next
            end

            if achievement_value.present? && !valid_numeric_value?(achievement_value)
              errors << "#{short_month_label(month)}: Achievement must be a number"
              next
            end

            if employee_remarks.to_s.length > REMARKS_MAX_LENGTH
              errors << "#{short_month_label(month)}: Remarks cannot exceed #{REMARKS_MAX_LENGTH} characters"
              next
            end

            achievement = achievements_by_detail_month[[ user_detail.id.to_s, month.to_s.downcase ]] ||
                          Achievement.new(user_detail: user_detail, month: month)

            achievement.achievement = achievement_value.present? ? normalize_numeric_value(achievement_value) : nil
            achievement.employee_remarks = employee_remarks.to_s.strip.presence
            achievement.status = "pending"

            if achievement.save
              success_count += 1
            end
          end

          # Send SMS only once per employee per quarter
          unless processed_employees.include?(employee_detail.id)
            quarters_filled = Set.new
            monthly_data.each do |month, values|
              next if selected_submission_month.present? && month.to_s.downcase != selected_submission_month

              achievement_value = values[:achievement] || values["achievement"]
              employee_remarks = values[:employee_remarks] || values["employee_remarks"]
              next unless achievement_submission_ready_for_review?(achievement_value, employee_remarks)

              quarter = determine_quarter(month)
              quarters_filled.add(quarter) if quarter.present?
            end

            if quarters_filled.any?
              processed_employees.add(employee_detail.id)

              quarters_filled.each do |quarter|
                sms_result = notify_reviewers_after_submission(employee_detail, quarter, selected_submission_month.presence || monthly_data.keys.find { |month| determine_quarter(month) == quarter }, user_detail)
                sms_results << {
                  quarter: quarter,
                  employee: employee_detail.employee_name,
                  success: sms_result[:success],
                  message: sms_result[:success] ? sms_result[:message] || "SMS sent successfully" : sms_result[:error]
                }
              end
            end
          end
        end
      end

      # Prepare response message
      if errors.any? && success_count.zero? && target_count.zero? && target_update_count.zero?
        render json: {
          success: false,
          message: errors.first(5).join(", ")
        }, status: :unprocessable_entity
        return
      end

      response_message = "Achievements submitted successfully. #{success_count} records updated."
      response_message += " #{target_count} new key result indicator target row(s) saved." if target_count.positive?
      response_message += " #{target_update_count} target value(s) updated." if target_update_count.positive?
      response_message += " Warnings: #{errors.first(3).join(', ')}" if errors.any?
      if sms_results.any?
        successful_sms = sms_results.select { |r| r[:success] }
        failed_sms = sms_results.reject { |r| r[:success] }
        if successful_sms.any?
          response_message += " SMS notifications sent for #{successful_sms.count} quarter(s)."
        end

        if failed_sms.any?
          failure_messages = failed_sms.filter_map { |result| result[:message].presence }.uniq.first(3)
          response_message += " SMS not sent: #{failure_messages.join(', ')}." if failure_messages.any?
        end
      end

      render json: {
        success: true,
        count: success_count,
        sms_results: sms_results,
        message: response_message
      }
    rescue => e
      Rails.logger.error "Achievement submission failed: #{e.message}"
      Rails.logger.error "Error class: #{e.class}"
      Rails.logger.error "Backtrace: #{e.backtrace.first(10).join("\n")}"

      error_response = {
        success: false,
        error: "Achievement submission failed: #{e.message}",
        message: "There was an error submitting achievements. Please try again."
      }

      Rails.logger.error "Error response prepared: #{error_response.inspect}"

      render json: error_response, status: :internal_server_error
    end
  end

  def get_activities
    department_id = params[:department_id]

    if department_id.present?
      activities = Activity.select(:id, :activity_name, :unit, :theme_name, :annual_target_fy_2026_27)
                          .where(department_id: department_id)

      activities_data = activities.map do |activity|
        {
          id: activity.id,
          activity_name: activity.activity_name,
          key_result_indicator: activity.activity_name,
          unit: activity.unit,
          annual_target_fy: annual_target_display_value(activity),
          annual_target_fy_2026_27: annual_target_display_value(activity),
          theme_name: activity.theme_name
        }
      end

      render json: activities_data
    else
      render json: { error: "Department ID is required" }, status: :bad_request
    end
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Department not found" }, status: :not_found
  rescue => e
    render json: { error: "An error occurred while fetching activities" }, status: :internal_server_error
  end

  def bulk_create
    department_id = params[:department_id]
    employee_detail_id = params[:employee_detail_id]
    financial_year = normalize_financial_year(params[:financial_year]) || current_financial_year
    user_details_params = params[:user_details]
    redirect_params = {
      department_id: department_id,
      employee_detail_id: employee_detail_id,
      financial_year: financial_year
    }

    # Enhanced validation
    if department_id.blank?
      return bulk_create_error_response("Department ID is required", :bad_request, redirect_params)
    end

    if employee_detail_id.blank?
      return bulk_create_error_response("Employee Detail ID is required", :bad_request, redirect_params)
    end

    if user_details_params.blank?
      return bulk_create_error_response("No user details provided", :bad_request, redirect_params)
    end

    # Validate that department and employee exist
    unless Department.exists?(department_id)
      return bulk_create_error_response("Department not found", :not_found, redirect_params)
    end

    unless EmployeeDetail.exists?(employee_detail_id)
      return bulk_create_error_response("Employee not found", :not_found, redirect_params)
    end

    created_count = 0
    updated_count = 0
    errors = []
    month_keys = MONTH_ATTRIBUTES.map(&:to_s)
    submitted_activity_ids = []
    submitted_user_detail_ids = []
    submitted_department_ids = []

    user_details_params.each do |row_key, details|
      activity_id = details["activity_id"].presence || details[:activity_id].presence || row_key.to_s.delete_prefix("activity_")
      row_department_id = details["department_id"].presence || details[:department_id].presence || department_id
      user_detail_id = details["user_detail_id"].presence || details[:user_detail_id].presence

      submitted_activity_ids << activity_id.to_s if activity_id.present?
      submitted_department_ids << row_department_id.to_s if row_department_id.present?
      submitted_user_detail_ids << user_detail_id.to_s if user_detail_id.present?
    end

    activities_by_id = Activity.where(id: submitted_activity_ids.uniq).index_by { |activity| activity.id.to_s }
    user_details_by_id = UserDetail.where(id: submitted_user_detail_ids.uniq, employee_detail_id: employee_detail_id, financial_year: financial_year)
                                   .index_by { |detail| detail.id.to_s }
    user_details_by_department_activity = UserDetail.where(
      department_id: submitted_department_ids.uniq,
      activity_id: submitted_activity_ids.uniq,
      employee_detail_id: employee_detail_id,
      financial_year: financial_year
    ).index_by { |detail| [ detail.department_id.to_s, detail.activity_id.to_s ] }

    ActiveRecord::Base.transaction do
      user_details_params.each do |row_key, details|
        begin
          activity_id = details["activity_id"].presence || details[:activity_id].presence || row_key.to_s.delete_prefix("activity_")
          row_department_id = details["department_id"].presence || details[:department_id].presence || department_id
          user_detail_id = details["user_detail_id"].presence || details[:user_detail_id].presence

          activity = activities_by_id[activity_id.to_s]
          unless activity
            errors << "Activity with ID #{activity_id} not found"
            next
          end

          # Extract monthly data
          month_data = {}
          invalid_month = false
          month_keys.each do |month|
            month_value = extract_month_value(details, month)
            if month_value.present? && !valid_numeric_percent_value?(month_value)
              errors << "Invalid #{month.upcase} value for #{details['activity_name'] || details[:activity_name] || "activity #{activity_id}"}: only numbers, optional decimal, and optional % are allowed"
              invalid_month = true
            else
              month_data[month.to_sym] = month_value
            end
          end
          next if invalid_month

          # Extract activity metadata (unit and theme_name)
          # Handle blank values properly - convert empty strings to nil for database
          unit_value = details["unit"] || details[:unit]
          theme_value = details["theme_name"] || details[:theme_name]
          annual_target_present = details.key?("annual_target_fy") || details.key?(:annual_target_fy) ||
                                  details.key?("annual_target_fy_2026_27") || details.key?(:annual_target_fy_2026_27)
          annual_target_value = details["annual_target_fy"] || details[:annual_target_fy] || details["annual_target_fy_2026_27"] || details[:annual_target_fy_2026_27]
          if annual_target_value.present? && !valid_numeric_percent_value?(annual_target_value)
            errors << "Invalid annual target for #{details['activity_name'] || details[:activity_name] || "activity #{activity_id}"}: only numbers, optional decimal, and optional % are allowed"
            next
          end

          activity_metadata = {
            unit: unit_value.present? ? unit_value : nil,
            theme_name: theme_value.present? ? theme_value : nil
          }
          activity_metadata[:annual_target_fy] = annual_target_value.present? ? annual_target_value.to_s.strip : nil if annual_target_present

          # Update Activity metadata (always update to handle clearing values)
          activity_update_data = {}

          # Always include unit and theme_name in update (nil values will clear the fields)
          activity_update_data[:unit] = activity_metadata[:unit]
          activity_update_data[:theme_name] = activity_metadata[:theme_name]
          activity_update_data[:annual_target_fy] = activity_metadata[:annual_target_fy] if annual_target_present

          unless activity.update(activity_update_data)
            errors << "Failed to update activity metadata for activity #{activity_id}: #{activity.errors.full_messages.join(', ')}"
          end

          user_detail_record = if user_detail_id.present?
            user_details_by_id[user_detail_id.to_s]
          end

          user_detail_key = [ row_department_id.to_s, activity_id.to_s ]
          user_detail_record ||= user_details_by_department_activity[user_detail_key] || UserDetail.new(
            department_id: row_department_id,
            activity_id: activity_id,
            employee_detail_id: employee_detail_id,
            financial_year: financial_year
          )
          user_detail_record.department_id = row_department_id
          user_detail_record.activity_id = activity_id
          user_detail_record.employee_detail_id = employee_detail_id
          user_detail_record.financial_year = financial_year

          # Update the user_detail record with monthly data
          user_detail_record.assign_attributes(month_data)

          if user_detail_record.save
            if user_detail_record.previously_new_record?
              created_count += 1
            else
              updated_count += 1
            end
            user_details_by_id[user_detail_record.id.to_s] = user_detail_record
            user_details_by_department_activity[user_detail_key] = user_detail_record
          else
            errors << "Failed to save activity #{activity_id}: #{user_detail_record.errors.full_messages.join(', ')}"
          end
        rescue => e
          errors << "Error processing activity #{activity_id}: #{e.message}"
        end
      end

      if errors.present? && (created_count + updated_count) == 0
        raise ActiveRecord::Rollback
      end
    end

    if errors.empty? || (created_count + updated_count) > 0
      message_parts = []
      message_parts << "#{created_count} records created" if created_count > 0
      message_parts << "#{updated_count} records updated" if updated_count > 0
      message_parts = [ "No changes made" ] if message_parts.empty?
      message = message_parts.join(", ")
      message = "#{message}. Warnings: #{errors.first(3).join('; ')}" if errors.present?

      respond_to do |format|
        format.html do
          redirect_to new_user_detail_path(redirect_params), notice: "Data saved successfully. #{message}."
        end
        format.json do
          response_data = {
            success: true,
            message: message,
            created: created_count,
            updated: updated_count
          }
          response_data[:warnings] = errors if errors.present?
          render json: response_data
        end
      end
    else
      error_message = "Failed to save records: #{errors.first(3).join('; ')}"

      respond_to do |format|
        format.html do
          redirect_to new_user_detail_path(redirect_params), alert: error_message
        end
        format.json do
          render json: {
            success: false,
            error: "Failed to save records",
            errors: errors,
            created: created_count,
            updated: updated_count
          }, status: :unprocessable_entity
        end
      end
    end
  end

  def export
    set_financial_year_context
    @user_details = target_details_scope

    respond_to do |format|
      format.xlsx {
        response.headers["Content-Disposition"] = "attachment; filename=\"target_details_#{@selected_financial_year}.xlsx\""
      }
    end
  end

  def import
    set_financial_year_context
    file = params[:file]
    extension = File.extname(file&.original_filename.to_s).downcase

    unless file && [ ".xlsx", ".xls", ".csv" ].include?(extension)
      redirect_to new_user_detail_path(financial_year: @selected_financial_year), alert: "Please upload a valid .xlsx, .xls, or .csv file."
      return
    end

    begin
      import_sheets = user_detail_import_sheets(file, extension)

      errors = []
      success_count = 0
      sheets_processed = 0
      batch_size = 100
      import_row_occurrences = Hash.new(0)
      existing_import_details = {}

      import_sheets.each do |sheet_info|
        spreadsheet = sheet_info[:spreadsheet]
        sheet_name = sheet_info[:name]
        if spreadsheet.respond_to?(:default_sheet=) && spreadsheet.respond_to?(:sheets) && spreadsheet.sheets.include?(sheet_name)
          spreadsheet.default_sheet = sheet_name
        end

        header = import_spreadsheet_row(spreadsheet, 1)
        next if spreadsheet.last_row.to_i < 2

        sheets_processed += 1

        # Process in batches for better performance
        (2..spreadsheet.last_row).each_slice(batch_size) do |rows|
          ActiveRecord::Base.transaction do
            rows.each do |i|
              row_label = import_sheets.size > 1 ? "#{sheet_name} - Row #{i}" : "Row #{i}"
            row_data = import_spreadsheet_row(spreadsheet, i)
            row = {}
            header.each_with_index do |col_name, index|
              next if col_name.nil?
              key = col_name.to_s.strip.downcase.gsub(/\s+/, "_")
              row[key] = row_data[index]
            end



            employee_name = row["employee_name"]
            employee_email = row["employee_email"]
            employee_code = row["employee_code"]
            post = row["post"] || row["designation"]
            location = row["location"] || row["posting_location"] || row["work_location"]

            mobile_number = extract_employee_mobile_number(row)

            l1_code = row["l1_code"] || row["l1_employer_code"] || row["l1_role"]
            l1_employer_name = row["l1_employer_name"] || row["l1_employee_name"]
            l2_code = row["l2_code"] || row["l2_employer_code"]
            l2_employer_name = row["l2_employer_name"]
            obs_code1 = row["obs_code_1"] || row["obs_code1"] || row["observer_code_1"] || row["observer1_code"] || row["observer_1_code"] || row["bw_code_1"] || row["bw_code1"]
            obs_code2 = row["obs_code_2"] || row["obs_code2"] || row["observer_code_2"] || row["observer2_code"] || row["observer_2_code"] || row["bw_code_2"] || row["bw_code2"]
            obs_code3 = row["obs_code_3"] || row["obs_code3"] || row["observer_code_3"] || row["observer3_code"] || row["observer_3_code"] || row["bw_code_3"] || row["bw_code3"]
            obs_code4 = row["obs_code_4"] || row["obs_code4"] || row["observer_code_4"] || row["observer4_code"] || row["observer_4_code"] || row["bw_code_4"] || row["bw_code4"]
            manager_values = normalize_import_manager_values(l1_code, l1_employer_name, l2_code, l2_employer_name)
            l1_code = manager_values[:l1_code]
            l1_employer_name = manager_values[:l1_employer_name]
            l2_code = manager_values[:l2_code]
            l2_employer_name = manager_values[:l2_employer_name]
            department_type = row["department"] || row["department_region"] || row["department_/_region"]
            financial_year_value = row["financial_year"]
            raw_activity_name = row["key_result_indicator"] || row["key_result_indicators"] || row["activity_name"]
            activity_name = import_activity_name_from_columns(financial_year_value, raw_activity_name)
            activity_theme_name = row["theme_name"] || row["theme"] || row["activity_theme"]
            unit = row["unit_of_measurement"] || row["unit"] || row["unit_of_measure"]
            annual_target_fy = normalize_import_display_value(
              extract_annual_target_fy(row),
              percent_context: unit.to_s.strip == "%"
            )



            percent_context = unit.to_s.strip == "%"
            months = MONTH_ATTRIBUTES.index_with do |month|
              normalize_import_display_value(
                import_row_month_value(row, month),
                percent_context: percent_context
              )
            end



            if employee_name.blank?
              errors << "#{row_label}: Employee name is missing"
              next
            end

            if activity_name.blank?
              errors << "#{row_label}: Key result indicator is missing"
              next
            end

            financial_year = normalize_import_financial_year(financial_year_value) ||
                             normalize_import_financial_year(manager_values[:financial_year]) ||
                             normalize_import_financial_year(params[:financial_year]) ||
                             @selected_financial_year ||
                             current_financial_year

            employee_attributes = {
              employee_name: employee_name.to_s.strip,
              employee_email: employee_email.to_s.strip,
              employee_code: employee_code.to_s.strip,
              mobile_number: mobile_number.to_s.strip,
              l1_code: l1_code.to_s.strip,
              l2_code: l2_code.to_s.strip,
              l1_employer_name: l1_employer_name.to_s.strip,
              l2_employer_name: l2_employer_name.to_s.strip,
              obs_code1: obs_code1.to_s.strip,
              obs_code2: obs_code2.to_s.strip,
              obs_code3: obs_code3.to_s.strip,
              obs_code4: obs_code4.to_s.strip,
              post: post.to_s.strip,
              location: location.to_s.strip,
              department: department_type.to_s.strip
            }.reject { |_, value| value.blank? }

            employee = find_employee_for_user_detail_import(employee_attributes)
            department_type = department_type.presence || employee&.department

            if department_type.blank?
              errors << "#{row_label}: Department is missing and could not be found from employee master"
              next
            end

            employee_attributes[:department] = department_type.to_s.strip
            employee = employee || EmployeeDetail.new(employee_id: SecureRandom.uuid, post: "Imported")
            employee.assign_attributes(employee_attributes)
            employee.post = "Imported" if employee.post.blank?
            employee.save!

            department = Department.find_or_create_by!(
              department_type: department_type,
              employee_reference: employee_reference_value_for_import(employee),
              financial_year: financial_year
            )

            normalized_activity_name = activity_name.to_s.strip
            occurrence_key = [ employee.id, department.id, financial_year, normalized_activity_name.downcase ]
            occurrence_index = import_row_occurrences[occurrence_key]
            import_row_occurrences[occurrence_key] += 1

            matching_details = existing_import_details[occurrence_key] ||= UserDetail.joins(:activity)
                                                                                    .includes(:activity)
                                                                                    .where(
                                                                                      employee_detail_id: employee.id,
                                                                                      department_id: department.id,
                                                                                      financial_year: financial_year
                                                                                    )
                                                                                    .where("LOWER(activities.activity_name) = ?", normalized_activity_name.downcase)
                                                                                    .order(:id)
                                                                                    .to_a
            user_detail = matching_details[occurrence_index]
            activity = user_detail&.activity

            activity ||= if occurrence_index.zero?
              department.activities.where("LOWER(activity_name) = ?", normalized_activity_name.downcase)
                        .order(:id)
                        .first_or_initialize(activity_name: normalized_activity_name)
            else
              department.activities.build(activity_name: normalized_activity_name)
            end

            activity_updates = {}
            activity_updates[:theme_name] = activity_theme_name.to_s.strip if activity_theme_name.present? && activity.theme_name != activity_theme_name.strip
            activity_updates[:unit] = unit if unit.present? && activity.unit != unit
            activity_updates[:annual_target_fy] = annual_target_fy if annual_target_fy.present? && activity.annual_target_fy != annual_target_fy
            activity.assign_attributes(activity_updates)
            activity.save! if activity.new_record? || activity.changed?

            begin
              user_detail ||= UserDetail.new(
                employee_detail_id: employee.id,
                department_id: department.id,
                financial_year: financial_year
              )
              user_detail.activity_id = activity.id
              user_detail.department_id = department.id
              user_detail.employee_detail_id = employee.id
              user_detail.financial_year = financial_year
              user_detail.assign_attributes(months)
              user_detail.save!
              success_count += 1
            rescue ActiveRecord::RecordInvalid => e
              errors << "#{row_label}: #{e.message}"
            end
            end
          end
        end
      end

      if errors.any?
        if success_count > 0
          redirect_to new_user_detail_path(financial_year: @selected_financial_year), alert: "Partially imported: #{success_count} records saved from #{sheets_processed} sheet(s), but #{errors.count} errors:\n#{errors.first(10).join("\n")}"
        else
          redirect_to new_user_detail_path(financial_year: @selected_financial_year), alert: "Import failed. Errors:\n#{errors.first(10).join("\n")}"
        end
      else
        sheet_summary = sheets_processed > 1 ? " from #{sheets_processed} sheets" : ""
        redirect_to new_user_detail_path(financial_year: @selected_financial_year), notice: "Excel file imported successfully! #{success_count} records processed#{sheet_summary}."
      end

    rescue => e
      Rails.logger.error "Import error: #{e.message}\n#{e.backtrace.join("\n")}"
      redirect_to new_user_detail_path(financial_year: @selected_financial_year), alert: "Error reading Excel file: #{excel_import_error_message(e, file)}"
    end
  end



  private

  def user_detail_import_sheets(file, extension)
    if extension == ".csv"
      text_spreadsheet = open_text_user_detail_import_spreadsheet(file)
      raise ArgumentError, "CSV file could not be read. Please check the file and upload again." unless text_spreadsheet

      return [ { spreadsheet: text_spreadsheet, name: "CSV" } ]
    end

    reader_extension = detected_spreadsheet_extension(file) || extension.delete_prefix(".")
    begin
      spreadsheet = Roo::Spreadsheet.open(file.tempfile.path, extension: reader_extension)
      if spreadsheet.respond_to?(:sheets) && spreadsheet.sheets.size > 1
        return spreadsheet.sheets.filter_map do |sheet_name|
          spreadsheet.default_sheet = sheet_name
          next if spreadsheet.last_row.to_i < 2

          { spreadsheet: spreadsheet, name: sheet_name }
        end
      end

      return [ { spreadsheet: spreadsheet, name: spreadsheet.sheets&.first || "Sheet1" } ]
    rescue => error
      @user_detail_import_open_error = error
    end

    partial_sheets = open_partial_xlsx_user_detail_import_sheets(file)
    return partial_sheets if partial_sheets.present?

    markup_spreadsheet = open_markup_user_detail_import_spreadsheet(file)
    return [ { spreadsheet: markup_spreadsheet, name: "Import" } ] if markup_spreadsheet

    text_spreadsheet = open_text_user_detail_import_spreadsheet(file)
    return [ { spreadsheet: text_spreadsheet, name: "CSV" } ] if text_spreadsheet

    raise @user_detail_import_open_error
  end

  def open_user_detail_import_spreadsheet(file, extension)
    user_detail_import_sheets(file, extension).first.fetch(:spreadsheet)
  end

  def import_spreadsheet_row(spreadsheet, row_number)
    return spreadsheet.row(row_number) unless spreadsheet.respond_to?(:formatted_value)

    spreadsheet.row(row_number).each_with_index.map do |cell_value, index|
      formatted_value = spreadsheet.formatted_value(row_number, index + 1)
      normalize_import_display_value(formatted_value.presence || cell_value)
    end
  rescue
    spreadsheet.row(row_number).map { |value| normalize_import_display_value(value) }
  end

  def detected_spreadsheet_extension(file)
    signature = File.binread(file.tempfile.path, 8)

    return "xlsx" if signature.start_with?("PK")
    return "xls" if signature.bytes == [ 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1 ]

    nil
  rescue
    nil
  end

  def open_partial_xlsx_user_detail_import_spreadsheet(file)
    open_partial_xlsx_user_detail_import_sheets(file)&.first&.fetch(:spreadsheet)
  end

  def open_partial_xlsx_user_detail_import_sheets(file)
    sheets = []

    Zip::File.open(file.tempfile.path) do |zip_file|
      sheet_names = read_xlsx_sheet_names(zip_file)
      shared_strings = read_xlsx_shared_strings(zip_file)
      percentage_styles = read_xlsx_percentage_styles(zip_file)

      zip_file.glob("xl/worksheets/sheet*.xml").sort_by { |entry| entry.name[/sheet(\d+)\.xml/, 1].to_i }.each_with_index do |worksheet_entry, index|
        worksheet = Nokogiri::XML(worksheet_entry.get_input_stream.read)
        rows = worksheet.xpath("//*[local-name()='sheetData']/*[local-name()='row']").map do |row_node|
          cells = []

          row_node.xpath("./*[local-name()='c']").each do |cell_node|
            column_index = xlsx_column_index(cell_node["r"])
            cells[column_index] = xlsx_cell_value(cell_node, shared_strings, percentage_styles)
          end

          cells.map { |cell| cell.to_s.squish }
        end.reject { |row| row.all?(&:blank?) }

        next if rows.blank? || rows.first.compact.size < 2
        next if rows.length < 2

        sheets << {
          spreadsheet: TextImportSpreadsheet.new(rows),
          name: sheet_names[index].presence || "Sheet#{index + 1}"
        }
      end
    end

    sheets.presence
  rescue Zip::Error, Nokogiri::XML::SyntaxError, NoMethodError
    nil
  end

  def read_xlsx_sheet_names(zip_file)
    workbook_entry = zip_file.find_entry("xl/workbook.xml")
    return [] unless workbook_entry

    document = Nokogiri::XML(workbook_entry.get_input_stream.read)
    document.xpath("//*[local-name()='sheet']").map { |sheet| sheet["name"].to_s }
  end

  def read_xlsx_shared_strings(zip_file)
    shared_strings_entry = zip_file.find_entry("xl/sharedStrings.xml")
    return [] unless shared_strings_entry

    document = Nokogiri::XML(shared_strings_entry.get_input_stream.read)
    document.xpath("//*[local-name()='si']").map do |shared_string|
      shared_string.xpath(".//*[local-name()='t']").map(&:text).join
    end
  end

  def read_xlsx_percentage_styles(zip_file)
    styles_entry = zip_file.find_entry("xl/styles.xml")
    return Set.new([ 9, 10 ]) unless styles_entry

    document = Nokogiri::XML(styles_entry.get_input_stream.read)
    custom_percentage_formats = document.xpath("//*[local-name()='numFmt']").each_with_object(Set.new) do |num_fmt, ids|
      format_code = num_fmt["formatCode"].to_s
      ids << num_fmt["numFmtId"].to_i if format_code.include?("%")
    end
    percentage_format_ids = Set.new([ 9, 10 ]).merge(custom_percentage_formats)

    style_ids = Set.new
    document.xpath("//*[local-name()='cellXfs']/*[local-name()='xf']").each_with_index do |style_node, index|
      style_ids << index if percentage_format_ids.include?(style_node["numFmtId"].to_i)
    end

    style_ids
  rescue
    Set.new([ 9, 10 ])
  end

  def xlsx_column_index(reference)
    letters = reference.to_s[/[A-Z]+/i].to_s.upcase
    return 0 if letters.blank?

    letters.chars.reduce(0) { |sum, letter| (sum * 26) + letter.ord - 64 } - 1
  end

  def xlsx_cell_value(cell_node, shared_strings, percentage_styles)
    if cell_node["t"] == "inlineStr"
      return cell_node.xpath(".//*[local-name()='is']//*[local-name()='t']").map(&:text).join
    end

    value = cell_node.at_xpath("./*[local-name()='v']")&.text.to_s
    return shared_strings[value.to_i].to_s if cell_node["t"] == "s"
    return normalize_import_display_value(value.to_f * 100, suffix: "%") if xlsx_percentage_cell?(cell_node, percentage_styles)

    normalize_import_display_value(value)
  end

  def xlsx_percentage_cell?(cell_node, percentage_styles)
    return false if cell_node["s"].blank?

    percentage_styles.include?(cell_node["s"].to_i)
  end

  def open_text_user_detail_import_spreadsheet(file)
    path = file.tempfile.path
    sample = File.binread(path, 20_000)
    return nil if sample.include?("\x00")

    text_sample = sample.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
    first_line = text_sample.lines.find { |line| line.strip.present? }
    return nil if first_line.blank?

    delimiter_counts = {
      "\t" => first_line.count("\t"),
      "," => first_line.count(","),
      ";" => first_line.count(";")
    }
    delimiter, delimiter_count = delimiter_counts.max_by { |_, count| count }
    return nil if delimiter_count.to_i.zero?

    rows = CSV.read(path, col_sep: delimiter, headers: false, encoding: "bom|utf-8")
              .reject { |row| row.compact.all? { |cell| cell.to_s.strip.blank? } }
    return nil if rows.blank? || rows.first.compact.size < 2

    TextImportSpreadsheet.new(rows)
  rescue CSV::MalformedCSVError, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
    nil
  end

  def open_markup_user_detail_import_spreadsheet(file)
    text = File.binread(file.tempfile.path, 300_000)
               .encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
    normalized_text = text.downcase
    return nil unless normalized_text.include?("<table") || normalized_text.include?("<workbook")

    document = Nokogiri::HTML(text)
    table_rows = document.css("table tr").map do |tr|
      tr.css("th,td").map { |cell| cell.text.to_s.squish }
    end.reject { |row| row.all?(&:blank?) }
    return TextImportSpreadsheet.new(table_rows) if table_rows.present? && table_rows.first.size > 1

    document = Nokogiri::XML(text)
    xml_rows = document.xpath("//*[local-name()='Row']").map do |row|
      row.xpath("./*[local-name()='Cell']").map { |cell| cell.text.to_s.squish }
    end.reject { |row| row.all?(&:blank?) }
    return TextImportSpreadsheet.new(xml_rows) if xml_rows.present? && xml_rows.first.size > 1

    nil
  rescue
    nil
  end

  def excel_import_error_message(error, file = nil)
    message = error.message.to_s
    upload_hint = detect_non_spreadsheet_upload_hint(file)
    return upload_hint if upload_hint

    if message.include?("missing required workbook file")
      "This file is not a readable data workbook. Please upload the actual Excel/CSV file, not a screenshot/PDF/renamed file. Open it in Excel/LibreOffice and save it as Excel Workbook (.xlsx), Excel 97-2003 Workbook (.xls), or CSV, then upload again."
    else
      message
    end
  end

  def detect_non_spreadsheet_upload_hint(file)
    return nil unless file

    signature = File.binread(file.tempfile.path, 8)
    save_as_hint = "Open your spreadsheet in Excel/LibreOffice, choose File → Save As → Excel Workbook (.xlsx), then upload that saved file."

    if signature.start_with?("\x89PNG")
      "This file is a PNG image, not an Excel workbook. #{save_as_hint}"
    elsif signature.start_with?("\xFF\xD8\xFF")
      "This file is a JPEG image, not an Excel workbook. #{save_as_hint}"
    elsif signature.start_with?("%PDF")
      "This file is a PDF, not an Excel workbook. #{save_as_hint}"
    end
  rescue
    nil
  end

  def latest_achievement_updated_at(user_detail)
    user_detail.achievements
               .select { |achievement| achievement.achievement.present? }
               .map(&:updated_at)
               .compact
               .max || user_detail.updated_at
  end

  def extract_employee_mobile_number(row)
    prioritized_keys = %w[
      employee_mobile_number
      employee_mobile
      employee_mobile_no
      mobile_number
      mobile_no
      mobile
      mobile_number.
      mobile_no.
      mobile.
      mobile_number_
      mobile_no_
      mobile_
    ]

    prioritized_keys.each do |key|
      value = row[key]
      return value if value.present?
    end

    row.each do |key, value|
      normalized_key = key.to_s.downcase.gsub(/[^a-z0-9]/, "")
      next unless normalized_key.include?("mobile")
      next if normalized_key.include?("l1") || normalized_key.include?("l2")

      return value if value.present?
    end

    nil
  end

  def extract_annual_target_fy(row)
    return row["annual_target"] if row["annual_target"].present?
    return row["annual_target_fy"] if row["annual_target_fy"].present?
    return row["annual_target_fy_2026_27"] if row["annual_target_fy_2026_27"].present?

    row.each do |key, value|
      normalized_key = key.to_s.downcase.gsub(/[^a-z0-9]/, "")
      next unless normalized_key == "annualtarget" || normalized_key.start_with?("annualtargetfy")

      return value if value.present?
    end

    nil
  end

  def normalize_import_financial_year(value)
    normalized = normalize_financial_year(value)
    return normalized if normalized.to_s.match?(/\A\d{4}-\d{4}\z/)

    nil
  end

  def import_activity_name_from_columns(financial_year_value, activity_name_value)
    cleaned_activity_name = activity_name_value.to_s.strip
    return cleaned_activity_name if cleaned_activity_name.present? && !placeholder_import_value?(cleaned_activity_name)

    possible_activity_name = financial_year_value.to_s.strip
    return possible_activity_name if possible_activity_name.present? && normalize_import_financial_year(possible_activity_name).blank?

    cleaned_activity_name
  end

  def placeholder_import_value?(value)
    value.to_s.strip.downcase.in?([ "-", "no", "n/a", "na" ])
  end

  def normalize_import_manager_values(l1_code, l1_employer_name, l2_code, l2_employer_name)
    values = {
      l1_code: l1_code.to_s.strip,
      l1_employer_name: l1_employer_name.to_s.strip,
      l2_code: l2_code.to_s.strip,
      l2_employer_name: l2_employer_name.to_s.strip,
      financial_year: nil
    }

    if values[:l1_code].present? && values[:l1_employer_name].present? && !employee_code_like?(values[:l1_code]) && employee_code_like?(values[:l1_employer_name])
      values[:l1_code], values[:l1_employer_name] = values[:l1_employer_name], values[:l1_code]
    end

    if values[:l2_employer_name].present? && normalize_import_financial_year(values[:l2_employer_name]).present? && !employee_code_like?(values[:l2_code])
      values[:financial_year] = values[:l2_employer_name]
      values[:l2_employer_name] = values[:l2_code]
      values[:l2_code] = ""
    elsif values[:l2_code].present? && values[:l2_employer_name].present? && !employee_code_like?(values[:l2_code]) && employee_code_like?(values[:l2_employer_name])
      values[:l2_code], values[:l2_employer_name] = values[:l2_employer_name], values[:l2_code]
    end

    values
  end

  def employee_code_like?(value)
    value.to_s.strip.match?(/\A[A-Z]{2,}\s*-?\s*\d+\z/i)
  end

  def annual_target_display_value(activity_or_value, unit = nil)
    value = if activity_or_value.respond_to?(:annual_target_fy)
      unit ||= activity_or_value.respond_to?(:unit) ? activity_or_value.unit : nil
      activity_or_value.annual_target_fy
    else
      activity_or_value
    end

    normalize_import_display_value(value, percent_context: unit.to_s.strip == "%").presence || "-"
  end

  def normalize_import_display_value(value, suffix: nil, percent_context: false)
    return nil if value.nil?

    cleaned_value = if value.is_a?(Numeric)
      value.to_f.finite? && value.to_f == value.to_i ? value.to_i.to_s : value.to_s
    else
      value.to_s.strip
    end

    return nil if cleaned_value.blank?
    return nil if spreadsheet_error_value?(cleaned_value)

    cleaned_value = cleaned_value.sub(/\A(-?\d+)\.0+\z/, "\\1")
    return "100%" if percent_context && cleaned_value.match?(/\A1(?:\.0+)?\z/)

    suffix.present? && !cleaned_value.end_with?(suffix) ? "#{cleaned_value}#{suffix}" : cleaned_value
  end

  def spreadsheet_error_value?(value)
    SPREADSHEET_ERROR_VALUES.include?(value.to_s.strip.upcase)
  end

  def find_employee_for_user_detail_import(employee_attributes)
    if employee_attributes[:employee_code].present?
      employee = EmployeeDetail.find_by(employee_code: employee_attributes[:employee_code])
      return employee if employee
    end

    if employee_attributes[:employee_email].present?
      employee = EmployeeDetail.find_by(employee_email: employee_attributes[:employee_email])
      return employee if employee
    end

    if employee_attributes[:employee_name].present? && employee_attributes[:department].present?
      employee = EmployeeDetail.find_by(
        employee_name: employee_attributes[:employee_name],
        department: employee_attributes[:department]
      )
      return employee if employee
    end

    nil
  end

  def employee_reference_value_for_import(employee)
    employee.employee_id.presence || employee.employee_code.presence
  end

  def set_user_detail
    @user_detail = UserDetail.includes(:department, :activity, :employee_detail).find(params[:id])
  end

  def user_detail_params
    params.require(:user_detail).permit(:department_id, :activity_id, :april, :may, :june,
                                        :july, :august, :september, :october, :november,
                                        :december, :january, :february, :march, :employee_detail_id, :employee_detail_email,
                                        :financial_year)
  end

  def bulk_create_params
    params.permit(:department_id, :employee_detail_id, :financial_year, user_details: {})
  end

  def bulk_create_error_response(message, status, redirect_params = {})
    respond_to do |format|
      format.html do
        redirect_to new_user_detail_path(redirect_params.compact), alert: message
      end
      format.json do
        render json: { error: message }, status: status
      end
    end
  end

  def set_financial_year_context
    @financial_years = financial_year_options
    requested_financial_year = normalize_financial_year(params[:financial_year])
    @selected_financial_year = requested_financial_year || @financial_years.first || current_financial_year
    @financial_years |= [ @selected_financial_year ] if requested_financial_year.present? || @financial_years.empty?
    @financial_years.sort!.reverse!
  end

  def target_details_scope
    base = UserDetail.includes(:department, :activity, :employee_detail)
                     .where(financial_year: @selected_financial_year)

    if current_user.role == "employee" || current_user.role == "l1_employer" || current_user.role == "l2_employer"
      employee_detail = EmployeeDetail.find_by(employee_email: current_user.email)
      if employee_detail
        base.where(employee_detail_id: employee_detail.id).order("user_details.id ASC")
      else
        base.none
      end
    elsif current_user.role == "hod"
      base.order("user_details.employee_detail_id ASC, user_details.id ASC")
    else
      base.none
    end
  end

  def set_active_month_context(user_details, include_all_months: false, default_to_first: true)
    if include_all_months
      @active_month_options = MONTH_ATTRIBUTES.map { |month| [ short_month_label(month), month.to_s ] }
      requested_month = params[:month].to_s.downcase
      active_month_values = @active_month_options.map(&:last)
      @selected_month = active_month_values.include?(requested_month) ? requested_month : active_month_values.first
      return
    end

    use_month_master = month_master_available?
    @active_month_options = active_month_master_options(@selected_financial_year)

    if @active_month_options.empty? && !use_month_master
      details = Array(user_details)
      @active_month_options = MONTH_ATTRIBUTES.each_with_object([]) do |month, options|
        has_target = details.any? do |detail|
          value = detail.respond_to?(month) ? detail.public_send(month) : nil
          value.present? && !spreadsheet_error_value?(value) && value.to_s.strip != "0"
        end
        options << [ short_month_label(month), month.to_s ] if has_target
      end
    end

    if @active_month_options.empty?
      @active_month_options = use_month_master ? [ [ "No Active Month", "" ] ] : MONTH_ATTRIBUTES.map { |month| [ short_month_label(month), month.to_s ] }
    end

    requested_month = params[:month].to_s.downcase
    active_month_values = @active_month_options.map(&:last)
    @selected_month = if active_month_values.include?(requested_month)
      requested_month
    elsif default_to_first
      active_month_values.first
    end
  end

  def financial_year_options
    start_year = Date.current.month >= 4 ? Date.current.year : Date.current.year - 1
    nearby_years = ((start_year - 1)..(start_year + 1)).map { |year| "#{year}-#{year + 1}" }

    persisted_years = if UserDetail.column_names.include?("financial_year")
      UserDetail.where.not(financial_year: [ nil, "" ]).distinct.pluck(:financial_year)
    else
      []
    end

    master_years = if month_master_available?
      MonthMaster.financial_year_options
    else
      []
    end

    normalized_master_years = master_years.filter_map { |year| normalize_financial_year(year) }.uniq
    return normalized_master_years if normalized_master_years.any?

    (persisted_years + nearby_years).filter_map { |year| normalize_financial_year(year) }.uniq
  end

  def active_month_master_options(financial_year)
    return [] unless month_master_available?

    MonthMaster.active.where(financial_year: financial_year).ordered.map do |record|
      [ short_month_label(record.month_key.presence || record.month_name), record.month_key ]
    end
  end

  def month_master_available?
    defined?(MonthMaster) && ActiveRecord::Base.connection.data_source_exists?("month_masters")
  end

  def short_month_label(month)
    {
      "april" => "APR",
      "may" => "MAY",
      "june" => "JUN",
      "july" => "JUL",
      "august" => "AUG",
      "september" => "SEP",
      "october" => "OCT",
      "november" => "NOV",
      "december" => "DEC",
      "january" => "JAN",
      "february" => "FEB",
      "march" => "MAR"
    }[month.to_s.downcase] || month.to_s.upcase
  end

  def month_master_configured?(financial_year)
    month_master_available? && MonthMaster.where(financial_year: financial_year).exists?
  end

  def current_financial_year
    start_year = Date.current.month >= 4 ? Date.current.year : Date.current.year - 1
    "#{start_year}-#{start_year + 1}"
  end

  def extract_month_value(details, month)
    return nil if details.blank?

    value = details[month] || details[month.to_sym] || details[month.to_s]

    return nil if value.blank?
    return nil if spreadsheet_error_value?(value)

    value.to_s.strip
  end

  def valid_numeric_percent_value?(value)
    value.to_s.strip.match?(/\A-?\d+(?:\.\d+)?%?\z/)
  end

  def normalize_percentage(value)
    normalize_import_display_value(value)
  end

  # Excel export uses APR/JUN/…; import must also accept full names (april/june/…).
  MONTH_HEADER_ALIASES = {
    "april" => %w[april apr],
    "may" => %w[may],
    "june" => %w[june jun],
    "july" => %w[july jul],
    "august" => %w[august aug],
    "september" => %w[september sep sept],
    "october" => %w[october oct],
    "november" => %w[november nov],
    "december" => %w[december dec],
    "january" => %w[january jan],
    "february" => %w[february feb],
    "march" => %w[march mar]
  }.freeze

  def import_row_month_value(row, month)
    aliases = MONTH_HEADER_ALIASES[month.to_s] || [ month.to_s ]
    aliases.each do |key|
      value = row[key]
      return value unless value.nil? || (value.respond_to?(:blank?) && value.blank?)
    end
    nil
  end

  def valid_numeric_value?(value)
    value.to_s.strip.match?(/\A-?\d+(?:\.\d+)?\z/)
  end

  def normalize_numeric_value(value)
    number = BigDecimal(value.to_s.strip)
    number.frac.zero? ? number.to_i.to_s : number.to_s("F")
  rescue ArgumentError
    value.to_s.strip
  end

  def achievement_submission_ready_for_review?(achievement_value, employee_remarks)
    return valid_numeric_value?(achievement_value) if achievement_value.present?

    employee_remarks.present?
  end

  def load_form_data
    @departments = Department.select(:id, :department_type)
    @activities = @user_detail.department_id.present? ?
                  Activity.select(:id, :activity_name, :unit, :theme_name, :annual_target_fy_2026_27)
                         .where(department_id: @user_detail.department_id) : []
    @user_details = UserDetail.includes(:department, :activity).limit(100)
  end

  def filter_conditions
    conditions = {}

    if params[:department_id].present?
      conditions[:department_id] = params[:department_id]
    end

    if params[:employee_detail_id].present?
      conditions[:employee_detail_id] = params[:employee_detail_id]
    end

    conditions
  end

  # SMS functionality for quarterly notifications
  def send_sms_to_l1(employee_detail, quarter, user_detail)
    begin
      # Get L1 manager's mobile number (not the employee's mobile number)
      l1_code = employee_detail.l1_code
      return { success: false, error: "L1 code not found for employee" } unless l1_code.present?

      # Find the L1 manager's employee detail record
      l1_manager = EmployeeDetail.find_by("employee_code LIKE ?", l1_code.strip + "%")
      return { success: false, error: "L1 manager not found with code: #{l1_code}" } unless l1_manager.present?

      l1_mobile = l1_manager.mobile_number
      return { success: false, error: "L1 manager mobile number not found" } unless l1_mobile.present?

      message = "Emp-Code: #{employee_detail.employee_code}, Emp-Name: #{employee_detail.employee_name} has submitted his #{quarter} Qtr KRA MIS. Please review and approve in the system. Ploughman Agro Private Limited"

      SmsNotificationService.send_message(l1_mobile, message)

    rescue => e
      Rails.logger.error "SMS service error: #{e.message}"
      Rails.logger.error "Backtrace: #{e.backtrace.first(5).join("\n")}"
      { success: false, error: "SMS service error: #{e.message}" }
    end
  end

  def notify_reviewers_after_submission(employee_detail, quarter, month, user_detail)
    observer_levels = observer_levels_for_employee(employee_detail)
    if observer_levels.any?
      send_sms_to_observers(employee_detail, quarter, month, observer_levels)
    else
      return { success: true, message: "L1 SMS already sent" } if check_sms_already_sent(employee_detail.id, quarter, month)

      result = send_sms_to_l1(employee_detail, quarter, user_detail)
      mark_sms_as_sent(employee_detail.id, quarter, month) if result[:success]
      result
    end
  end

  def observer_levels_for_employee(employee_detail)
    ApplicationHelper::OBSERVER_LEVELS.select do |observer_level|
      employee_detail.public_send(observer_level).to_s.strip.present?
    end
  end

  def send_sms_to_observers(employee_detail, quarter, month, observer_levels)
    results = observer_levels.map do |observer_level|
      send_sms_to_observer(employee_detail, quarter, month, observer_level)
    end
    sent_count = results.count { |result| result[:success] && !result[:already_sent] }
    already_sent_count = results.count { |result| result[:success] && result[:already_sent] }
    failed_results = results.reject { |result| result[:success] }

    if sent_count.positive? || already_sent_count.positive?
      message_parts = []
      message_parts << "Observer SMS sent to #{sent_count} reviewer(s)" if sent_count.positive?
      message_parts << "Observer SMS already sent to #{already_sent_count} reviewer(s)" if already_sent_count.positive?

      {
        success: true,
        message: message_parts.join(", "),
        observer_results: results
      }
    else
      {
        success: false,
        error: failed_results.map { |result| result[:error] }.compact.first || "Observer SMS could not be sent",
        observer_results: results
      }
    end
  end

  def send_sms_to_observer(employee_detail, quarter, month, observer_level)
    observer_code = employee_detail.public_send(observer_level).to_s.strip
    return { success: false, error: "#{observer_level} code not found" } if observer_code.blank?
    if observer_sms_already_sent?(employee_detail.id, quarter, month, observer_level)
      return {
        success: true,
        already_sent: true,
        message: "#{observer_label(observer_level)} SMS already sent",
        observer_level: observer_level,
        observer_code: observer_code
      }
    end

    observer = employee_detail_for_code(observer_code)
    unless observer
      error = "#{observer_label(observer_level)} not found with code: #{observer_code}"
      Rails.logger.warn "Observer SMS skipped: #{error} for employee_detail_id=#{employee_detail.id}"
      return { success: false, error: error, observer_level: observer_level, observer_code: observer_code }
    end

    if observer.mobile_number.blank?
      error = "#{observer_label(observer_level)} mobile number not found for code: #{observer_code}"
      Rails.logger.warn "Observer SMS skipped: #{error} for employee_detail_id=#{employee_detail.id}"
      return { success: false, error: error, observer_level: observer_level, observer_code: observer_code, observer_name: observer.employee_name }
    end

    month_text = month.present? ? " #{short_month_label(month)}" : ""
    message = "Emp-Code: #{employee_detail.employee_code}, Emp-Name: #{employee_detail.employee_name} has submitted his#{month_text} #{quarter} Qtr KRA MIS. Please review and approve in the system. Ploughman Agro Private Limited"
    result = SmsNotificationService.send_message(observer.mobile_number, message)

    if result[:success]
      mark_sms_as_sent(
        employee_detail.id,
        quarter,
        month,
        recipient_role: "observer",
        recipient_employee_detail_id: observer.id,
        observer_level: observer_level
      )
    else
      Rails.logger.warn "Observer SMS failed for employee_detail_id=#{employee_detail.id}, #{observer_level}=#{observer_code}: #{result[:error]}"
    end

    result.merge(observer_level: observer_level, observer_code: observer_code, observer_name: observer.employee_name)
  end

  def observer_label(observer_level)
    "OB#{observer_level.to_s.gsub(/\D/, '')}"
  end

  def employee_detail_for_code(employee_code)
    code = employee_code.to_s.strip
    return nil if code.blank?

    EmployeeDetail.where("LOWER(TRIM(employee_code)) = ?", code.downcase).first ||
      EmployeeDetail.find_by("employee_code LIKE ?", "#{code}%")
  end

  def determine_quarter(month)
    case month.to_s.downcase
    when "april", "may", "june"
      "Q1 (APR-JUN)"
    when "july", "august", "september"
      "Q2 (JUL-SEP)"
    when "october", "november", "december"
      "Q3 (OCT-DEC)"
    when "january", "february", "march"
      "Q4 (JAN-MAR)"
    else
      nil
    end
  end

  def current_user_target_employee_detail
    EmployeeDetail.find_by(employee_email: current_user.email) ||
      EmployeeDetail.find_by(id: params[:employee_detail_id])
  end

  def achievement_entry_locked_for_month?(user_details, month)
    return false if month.blank?

    details = Array(user_details)
    employee_ids = details.map(&:employee_detail_id).compact.uniq
    financial_years = details.map(&:financial_year).compact.uniq
    return false if employee_ids.empty? || financial_years.empty?

    achievement_locked_scope(employee_ids, financial_years, month).exists?
  end

  def achievement_locked_for_employee_month?(employee_detail_id, financial_year, month)
    return false if employee_detail_id.blank? || financial_year.blank? || month.blank?

    achievement_locked_scope([ employee_detail_id ], [ financial_year ], month).exists?
  end

  def achievement_locked_scope(employee_detail_ids, financial_years, month)
    Achievement.joins(:user_detail)
               .where(user_details: { employee_detail_id: employee_detail_ids, financial_year: financial_years })
               .where(month: month.to_s.downcase)
               .where(status: [ "l1_approved", "l2_approved" ])
  end

  def manual_kri_target_editable?(user_detail)
    activity = user_detail.activity
    return false unless activity

    activity.theme_name.to_s == MANUAL_KRI_THEME
  end

  def manual_kri_has_target_for_month?(user_detail, month_key)
    value = normalize_import_display_value(user_detail.public_send(month_key))
    return false if value.blank?

    target_text = value.to_s.delete(",").strip
    return false if target_text.match?(/\A-?\d+(?:\.\d+)?\z/) && target_text.to_f <= 0

    true
  end

  def manual_kri_count_for_month(employee_detail_id, financial_year, month)
    month_key = month.to_s.downcase
    return 0 if employee_detail_id.blank? || financial_year.blank? || month_key.blank?
    return 0 unless MONTH_ATTRIBUTES.map(&:to_s).include?(month_key)

    UserDetail.joins(:activity)
              .where(employee_detail_id: employee_detail_id, financial_year: financial_year)
              .where(activities: { theme_name: MANUAL_KRI_THEME })
              .select(:id, month_key)
              .count { |user_detail| manual_kri_has_target_for_month?(user_detail, month_key) }
  end

  def manual_kri_month_data_for_submission(target_params, selected_month)
    selected_month_key = selected_month.to_s.downcase

    MONTH_ATTRIBUTES.each_with_object({}) do |month, data|
      data[month] = if selected_month_key.present? && month.to_s == selected_month_key
        normalize_import_display_value(target_params[month] || target_params[month.to_s])
      end
    end
  end

  def set_manual_kri_month_context
    @remaining_manual_kri_slots = 0

    return unless @employee_detail.present? && @selected_month.present?

    existing_count = manual_kri_count_for_month(@employee_detail.id, @selected_financial_year, @selected_month)
    @remaining_manual_kri_slots = [ MAX_MANUAL_KRI_ROWS - existing_count, 0 ].max
  end

  def target_editable_for_month?(user_detail, month_key)
    return false unless manual_kri_target_editable?(user_detail)

    current_value = normalize_import_display_value(user_detail.public_send(month_key))
    current_value.blank? || current_value.to_s == "0"
  end

  def department_for_new_target(employee_detail, financial_year)
    existing_department = Department.joins(:user_details)
                                    .where(user_details: { employee_detail_id: employee_detail.id, financial_year: financial_year })
                                    .order("user_details.id ASC")
                                    .first

    department_type = existing_department&.department_type.presence || employee_detail.department.presence || "General"

    Department.find_or_create_by!(
      department_type: department_type,
      employee_reference: employee_reference_value_for_import(employee_detail),
      financial_year: financial_year
    )
  end

  def clear_sms_tracking
    # Clear SMS tracking for a fresh start
    # Clear all SMS logs since we're tracking per employee
    SmsLog.destroy_all
    flash[:notice] = "SMS tracking cleared. New SMS will be sent for each quarter."
    redirect_to get_user_detail_user_details_path
  end

  def view_sms_logs
    # View SMS logs to see which SMS have been sent
    @sms_logs = SmsLog.includes(:employee_detail).order(created_at: :desc).limit(50)
    render :view_sms_logs
  end

  def check_sms_already_sent(employee_detail_id, quarter, month = nil)
    # Check if SMS was already sent for this quarter using database
    # Use employee_detail_id to track per employee, not per activity
    SmsLog.exists?(employee_detail_id: employee_detail_id, quarter: quarter, month: month, recipient_role: "l1", sent: true)
  end

  def observer_sms_already_sent?(employee_detail_id, quarter, month, observer_level)
    SmsLog.exists?(
      employee_detail_id: employee_detail_id,
      quarter: quarter,
      month: month,
      recipient_role: "observer",
      observer_level: observer_level,
      sent: true
    )
  end

  def mark_sms_as_sent(employee_detail_id, quarter, month = nil, recipient_role: "l1", recipient_employee_detail_id: nil, observer_level: nil)
    # Mark SMS as sent in database to prevent duplicates
    # Use employee_detail_id to track per employee, not per activity
    SmsLog.create!(
      employee_detail_id: employee_detail_id,
      quarter: quarter,
      month: month,
      recipient_role: recipient_role,
      recipient_employee_detail_id: recipient_employee_detail_id,
      observer_level: observer_level,
      sent: true,
      sent_at: Time.current
    )
  rescue => e
    Rails.logger.error "Failed to mark SMS as sent: #{e.message}"
  end

  def quarter_name_for_month(month)
    {
      "april" => "Q1", "may" => "Q1", "june" => "Q1",
      "july" => "Q2", "august" => "Q2", "september" => "Q2",
      "october" => "Q3", "november" => "Q3", "december" => "Q3",
      "january" => "Q4", "february" => "Q4", "march" => "Q4"
    }[month.to_s.downcase]
  end

  def submitted_achievements_observer_levels(user_details)
    ApplicationHelper::OBSERVER_LEVELS.select do |observer_level|
      user_details.any? do |detail|
        employee = detail.employee_detail
        employee.present? && employee.public_send(observer_level).to_s.strip.present?
      end
    end
  end
end
