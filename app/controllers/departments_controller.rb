require "roo"
require "securerandom"

class DepartmentsController < ApplicationController
  SPREADSHEET_ERROR_VALUES = %w[#DIV/0! #N/A #NAME? #NULL! #NUM! #REF! #VALUE!].freeze

  before_action :set_department, only: [ :show, :edit, :update, :destroy, :delete_user_activities, :delete_user_from_department ]
  helper_method :employee_reference_value, :employee_display_code

  def index
    set_financial_year_context

    if params[:employee_id].present?
      @selected_employee = find_employee_by_reference(params[:employee_id])
      if @selected_employee
        # Get activities for the selected employee using UserDetail
        @employee_activities = get_employee_activities(@selected_employee, @selected_financial_year)
      else
        @employee_activities = {}
      end
    elsif params[:employee_code].present?
      @selected_employee = EmployeeDetail.find_by(employee_code: params[:employee_code])
      if @selected_employee
        # Get activities for the selected employee using UserDetail
        @employee_activities = get_employee_activities(@selected_employee, @selected_financial_year)
      else
        @employee_activities = {}
      end
    else
      # Show all employees with their activities grouped by employee
      @employee_activities = get_all_employee_activities(@selected_financial_year)
    end

    # Debug logging - simplified to avoid database errors
    Rails.logger.info "Employee activities loaded successfully"

    @department = Department.new(financial_year: @selected_financial_year)
    # Only build one activity by default to prevent duplicates
    @department.activities.build

    # Set variables needed for the form dropdowns
    @employee_departments = EmployeeDetail.distinct.pluck(:department).compact.reject(&:blank?)
    # @employees = EmployeeDetail.where("employee_name IS NOT NULL AND employee_id IS NOT NULL AND department IS NOT NULL")
    #                           .order(:employee_name)
    @employees = employees_for_department_form

    respond_to do |format|
      format.html
      format.json do
        render json: @employee_activities.values
      end
    end
  end

  def new
    set_financial_year_context

    @department = Department.new(financial_year: @selected_financial_year)
    @employee_departments = EmployeeDetail.distinct.pluck(:department).compact.reject(&:blank?)
    @employees = employees_for_department_form
    # Only build one activity by default to prevent duplicates
    @department.activities.build
  end

  def create
    set_financial_year_context

    @department = Department.new(department_params)
    @department.financial_year = @selected_financial_year if @department.financial_year.blank?

    if @department.save
      respond_to do |format|
        format.html { redirect_to departments_path(financial_year: @department.financial_year), notice: "Department was successfully created." }
        format.json { render json: { success: true, message: "Department created successfully!" } }
      end
    else
      respond_to do |format|
        format.html {
          @department = Department.new(financial_year: @selected_financial_year)
          @department.activities.build
          @departments = Department.includes(:activities).all
          @employee_departments = EmployeeDetail.distinct.pluck(:department).compact.reject(&:blank?)
          @employees = employees_for_department_form
          # Set employee_activities to avoid nil error in view
          @employee_activities = get_all_employee_activities(@selected_financial_year)
          flash.now[:alert] = "Failed to create department: #{@department.errors.full_messages.join(', ')}"
          render :index, status: :unprocessable_entity
        }
        format.json { render json: { success: false, errors: @department.errors.full_messages } }
      end
    end
  end

  def edit
    @department = Department.find(params[:id])
    @employee_departments = EmployeeDetail.distinct.pluck(:department).compact
    @employees = employees_for_department_form
  end

  def edit_data
    set_financial_year_context

    # Disable caching to ensure fresh data is always returned
    response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
    response.headers["Pragma"] = "no-cache"
    response.headers["Expires"] = "0"

    # The frontend is actually trying to edit employee activities, not departments
    # We need to find the employee and their activities based on the department ID

    # First try to find the department
    department = Department.find_by(id: params[:id])

    if department
      # If department exists, get its activities and employee info
      # But activities are actually linked through UserDetail records
      employee = find_employee_by_reference(department.employee_reference) ||
                 EmployeeDetail.find_by(department: department.department_type)

      if employee
        # FIXED: Get only activities that are specific to this employee
        # Instead of showing all department activities, show only user-specific activities

        # Get activities from UserDetail records for this specific employee
        user_details = UserDetail.includes(:activity, :department)
                                .where(employee_detail_id: employee.id)
                                .where(financial_year: @selected_financial_year)
                                .where("activity_id IS NOT NULL")

        # Map activities from user_details (employee-specific activities)
        activities = user_details.map do |user_detail|
          activity = user_detail.activity
          {
            id: activity.id,
            theme_name: activity.theme_name,
            activity_name: activity.activity_name,
            key_result_indicator: activity.activity_name,
            unit: activity.unit,
            annual_target_fy: annual_target_display_value(activity),
            annual_target_fy_2026_27: annual_target_display_value(activity)
          }
        end.uniq { |activity| activity[:id] } # Remove duplicates

        employee_name = employee.employee_name
        employee_code = employee_display_code(employee)

        render json: {
          id: department.id,
          department_type: department.department_type,
          theme_name: department.theme_name,
          employee_reference: employee_reference_value(employee),
          employee_name: employee_name,
          employee_code: employee_code,
          employee_display_name: employee ? "#{employee_name} (#{employee_display_code(employee)})" : "N/A",
          financial_year: department.financial_year.presence || @selected_financial_year,
          activities: activities,
          timestamp: Time.current.to_i
        }
      else
        # No employee found for this department
        render json: { error: "No employee found for this department" }, status: :not_found
      end
    else
      # If department doesn't exist, try to find employee activities by employee ID
      # This handles the case where the ID might actually be an employee ID
      employee = find_employee_by_reference(params[:id])

      if employee
        # Get activities for this employee using UserDetail
        user_details = UserDetail.includes(:activity, :department)
                                .where(employee_detail_id: employee.id)
                                .where(financial_year: @selected_financial_year)
                                .where("activity_id IS NOT NULL")

        activities = user_details.map do |user_detail|
          activity = user_detail.activity
          {
            id: activity.id,
            theme_name: activity.theme_name,
            activity_name: activity.activity_name,
            key_result_indicator: activity.activity_name,
            unit: activity.unit,
            annual_target_fy: annual_target_display_value(activity),
            annual_target_fy_2026_27: annual_target_display_value(activity)
          }
        end

        # Find the department type from the first activity
        department_type = user_details.first&.department&.department_type || employee.department

        render json: {
          id: employee_reference_value(employee), # Use employee ID/code as the identifier
          department_type: department_type,
          theme_name: "", # No theme name for employee activities
          employee_reference: employee_reference_value(employee),
          employee_name: employee.employee_name,
          employee_code: employee_display_code(employee),
          employee_display_name: "#{employee.employee_name} (#{employee_display_code(employee)})",
          financial_year: @selected_financial_year,
          activities: activities,
          timestamp: Time.current.to_i
        }
      else
        # Neither department nor employee found
        render json: { error: "Department or employee not found" }, status: :not_found
      end
    end
  end

  # Handle employee-specific activity updates
  def handle_employee_activity_update(employee)
    Rails.logger.info "=== handle_employee_activity_update called for employee #{employee.employee_id} ==="
    year = normalize_financial_year(params.dig(:department, :financial_year)) || current_financial_year

    if params[:department] && params[:department][:activities_attributes].present?
      Rails.logger.info "Processing employee activity updates for #{employee.employee_name}"

      begin
        ActiveRecord::Base.transaction do
          # Get existing UserDetail records for this employee
          existing_user_details = UserDetail.where(employee_detail_id: employee.id, financial_year: year)
          Rails.logger.info "Found #{existing_user_details.count} existing user_details for employee"

          # Process activities marked for destruction (remove from employee)
          activities_to_remove_from_employee = []
          params[:department][:activities_attributes].each do |index, activity_attrs|
            if (activity_attrs[:_destroy] == "true" || activity_attrs[:_destroy] == true) && activity_attrs[:id].present? && activity_attrs[:id] != ""
              Rails.logger.info "Activity #{activity_attrs[:id]} marked for removal from employee #{employee.employee_id}"
              activities_to_remove_from_employee << activity_attrs[:id]
            end
          end

          # Remove UserDetail records for activities marked for destruction
          activities_to_remove_from_employee.each do |activity_id|
            user_details_to_remove = existing_user_details.where(activity_id: activity_id)
            if user_details_to_remove.any?
              Rails.logger.info "Removing #{user_details_to_remove.count} user_details for activity #{activity_id} from employee #{employee.employee_id}"
              user_details_to_remove.destroy_all
            end
          end

          # Process remaining activities (update existing or create new UserDetail records)
          params[:department][:activities_attributes].each do |index, activity_attrs|
            # Skip if marked for destruction
            next if activity_attrs[:_destroy] == "true" || activity_attrs[:_destroy] == true

            # Skip if incomplete
            next if activity_attrs[:activity_name].blank?

            activity_id = activity_attrs[:id]
            if activity_id.present?
              # Update the Activity record with new data
              activity = Activity.find(activity_id)
              Rails.logger.info "Updating activity #{activity_id} with new data"
              activity.update!(
                theme_name: activity_attrs[:theme_name].presence || "",
                activity_name: activity_attrs[:activity_name],
                unit: activity_attrs[:unit],
                annual_target_fy: annual_target_value(activity_attrs)
              )
              Rails.logger.info "Updated activity #{activity_id}: theme=#{activity.theme_name}, name=#{activity.activity_name}"

              # Update existing UserDetail record
              user_detail = existing_user_details.find_by(activity_id: activity_id)
              if user_detail
                Rails.logger.info "Updating existing user_detail for activity #{activity_id}"
                # UserDetail relationship already exists, no need to update
              else
                Rails.logger.info "Creating new user_detail for activity #{activity_id}"
                # Create new UserDetail record
                department = activity.department
                UserDetail.create!(
                  employee_detail_id: employee.id,
                  activity_id: activity_id,
                  department_id: department.id,
                  financial_year: year
                )
              end
            end
          end

          Rails.logger.info "Successfully updated employee activities for #{employee.employee_name}"
          render json: { success: true, message: "Employee activities updated successfully!" }
        end
      rescue => e
        Rails.logger.error "Error updating employee activities: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        render json: { success: false, message: "Error updating employee activities: #{e.message}" }, status: :unprocessable_entity
      end
    else
      Rails.logger.warn "No activities attributes found in params"
      render json: { success: false, message: "No activities data provided" }, status: :unprocessable_entity
    end
  end

  def update
    set_financial_year_context

    # Handle nested attributes with proper foreign key constraint handling
    begin
      ActiveRecord::Base.transaction do
        # First, handle activities marked for destruction
        if department_params[:activities_attributes].present?
          department_params[:activities_attributes].each do |index, activity_attrs|
            if activity_attrs[:_destroy] == "true" && activity_attrs[:id].present?
              activity = Activity.find(activity_attrs[:id])

              # First delete dependent user_details records to avoid foreign key constraint violation
              user_details = UserDetail.where(activity_id: activity.id)
              if user_details.any?
                Rails.logger.info "Found #{user_details.count} user_details for activity #{activity.id}, deleting them first"
                user_details.destroy_all
              end

              # Now delete the activity
              activity.destroy
              Rails.logger.info "Successfully deleted activity #{activity.id}"
            end
          end
        end

    # Now update the department with the remaining activities
    if @department.update(department_params)
      respond_to do |format|
        format.html { redirect_to departments_path(financial_year: @selected_financial_year), notice: "Department was successfully updated." }
        format.json { render json: { success: true, message: "Department updated successfully!" } }
      end
    else
      respond_to do |format|
        format.html {
          @employee_departments = EmployeeDetail.distinct.pluck(:department).compact
          @employees = employees_for_department_form
          render :edit, status: :unprocessable_entity
        }
        format.json { render json: { success: false, errors: @department.errors.full_messages } }
          end
    end
      end
    rescue => e
      Rails.logger.error "Error updating department: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")

      respond_to do |format|
        format.html {
          @employee_departments = EmployeeDetail.distinct.pluck(:department).compact
          @employees = employees_for_department_form
          flash.now[:alert] = "Failed to update department: #{e.message}"
          render :edit, status: :unprocessable_entity
        }
        format.json { render json: { success: false, errors: [ e.message ] } }
      end
    end
  end

  def update_employee_activities
    Rails.logger.info "=== update_employee_activities method called ==="
    Rails.logger.info "Request method: #{request.method}"
    Rails.logger.info "Request path: #{request.path}"
    Rails.logger.info "Request headers: #{request.headers.to_h.select { |k, v| k.start_with?('HTTP_') }}"

    employee_id = params[:employee_id]

    Rails.logger.info "Updating activities for employee: #{employee_id}"
    Rails.logger.info "Received params: #{params.inspect}"

    # Find all departments for this employee
    departments = Department.where(employee_reference: employee_id)
    Rails.logger.info "Found #{departments.count} departments for employee #{employee_id}"

    if departments.any?
      begin
        ActiveRecord::Base.transaction do
          # Update each department's activities
          departments.each do |dept|
            Rails.logger.info "Processing department #{dept.id} with #{dept.activities.count} existing activities"

                                      if params[:activities].present?
               Rails.logger.info "Processing #{params[:activities].count} activities for update"

               # Get existing activity IDs for this department
               existing_activity_ids = dept.activities.pluck(:id)
               Rails.logger.info "Existing activity IDs: #{existing_activity_ids}"

               # Find activities that are no longer in the form (deleted by user)
               # We'll need to check by content since the form doesn't send IDs for new activities
               activities_to_delete = []

               dept.activities.each do |existing_activity|
                 # Check if this activity still exists in the form data
                 activity_still_exists = params[:activities].any? do |form_activity|
                   form_activity[:activity_name] == existing_activity.activity_name &&
                   form_activity[:unit] == existing_activity.unit &&
                   annual_target_value(form_activity).to_s == existing_activity.annual_target_fy.to_s
                 end

                 unless activity_still_exists
                   activities_to_delete << existing_activity
                   Rails.logger.info "Activity #{existing_activity.id} (#{existing_activity.activity_name}) will be deleted"
                 end
               end

               # Delete activities that are no longer in the form
               activities_to_delete.each do |activity|
                 Rails.logger.info "Deleting activity #{activity.id} (#{activity.activity_name})"

                 # First delete dependent user_details records to avoid foreign key constraint violation
                 user_details = UserDetail.where(activity_id: activity.id)
                 if user_details.any?
                   Rails.logger.info "Found #{user_details.count} user_details for activity #{activity.id}, deleting them first"
                 user_details.destroy_all
                 end

                 # Now delete the activity
                 activity.destroy
                 Rails.logger.info "Successfully deleted activity #{activity.id}"
               end

               # Update or create activities
               params[:activities].each do |activity_params|
                 # Try to find existing activity by content
                 existing_activity = dept.activities.find_by(
                   activity_name: activity_params[:activity_name],
                   unit: activity_params[:unit]
                 )

                 if existing_activity
                   # Update existing activity
                   Rails.logger.info "Updating existing activity #{existing_activity.id}"
                   existing_activity.update!(
                     theme_name: activity_params[:theme_name].presence || "",
                     activity_name: activity_params[:activity_name],
                     unit: activity_params[:unit],
                     annual_target_fy: annual_target_value(activity_params)
                   )
                 else
                   # Create new activity
                   Rails.logger.info "Creating new activity for department #{dept.id}"
                   new_activity = dept.activities.create!(
                     theme_name: activity_params[:theme_name].presence || "",
                     activity_name: activity_params[:activity_name],
                     unit: activity_params[:unit],
                     annual_target_fy: annual_target_value(activity_params)
                   )
                   Rails.logger.info "Created new activity #{new_activity.id}"
                 end
               end
                                      end
          end

          Rails.logger.info "Successfully updated activities for employee #{employee_id}"
          render json: { success: true, message: "Employee activities updated successfully!" }
        end
      rescue => e
        Rails.logger.error "Error updating employee activities: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        render json: { success: false, message: "Error updating activities: #{e.message}" }, status: :unprocessable_entity
      end
    else
      Rails.logger.warn "No departments found for employee #{employee_id}"
      render json: { success: false, message: "No departments found for this employee" }, status: :not_found
    end
  end

  # New action to handle updating employee activity data from the edit form
  def update_employee_activity_data
    set_financial_year_context

    # The ID could be either a department ID or employee ID
    id = params[:id]

    # First try to find the department
    department = Department.find_by(id: id)

    # If not a department, try to find an employee
    if !department
      employee = find_employee_by_reference(id)
      if employee
        Rails.logger.info "Found employee: #{employee.employee_id} - #{employee.employee_name}"
        handle_employee_activity_update(employee)
        return
      end
    end

    if department
      # Update department activities using the nested attributes structure
      if params[:department] && params[:department][:activities_attributes].present?
        begin
          ActiveRecord::Base.transaction do
            # Get existing activity IDs for this department
            existing_activity_ids = department.activities.pluck(:id)

            # Count valid activities first (excluding those marked for destruction)
            valid_activities_count = 0
            activities_to_process = []

            params[:department][:activities_attributes].each do |index, activity_attrs|
              # Skip if marked for destruction
              next if activity_attrs[:_destroy] == "true" || activity_attrs[:_destroy] == true

              # Check if all required fields are present (unit is now optional)
              if activity_attrs[:activity_name].present?
                valid_activities_count += 1
                activities_to_process << index
              end
            end

            if valid_activities_count == 0
              raise "At least one complete key result indicator is required. Please fill key result indicators for at least one row. Unit of measurement is optional."
            end

            # First, handle activities marked for destruction
            activities_to_delete = []
            params[:department][:activities_attributes].each do |index, activity_attrs|
              if (activity_attrs[:_destroy] == "true" || activity_attrs[:_destroy] == true) && activity_attrs[:id].present? && activity_attrs[:id] != ""
                activity = department.activities.find_by(id: activity_attrs[:id])
                if activity
                  activities_to_delete << activity
                end
              end
            end

            # Delete activities marked for destruction
            activities_to_delete.each do |activity|
              # First delete dependent user_details records to avoid foreign key constraint violation
              user_details = UserDetail.where(activity_id: activity.id)
              if user_details.any?
                user_details.destroy_all
              end

              # Now delete the activity
              activity.destroy
            end

            # Process each activity from the form (only valid ones)
            params[:department][:activities_attributes].each do |index, activity_attrs|
              # Skip if marked for destruction
              if activity_attrs[:_destroy] == "true" || activity_attrs[:_destroy] == true
                next
              end

              # Skip if any required field is blank (incomplete activity) - unit is now optional
              if activity_attrs[:activity_name].blank?
                next
              end

              # Check if this is an existing activity (has an ID)
              if activity_attrs[:id].present? && activity_attrs[:id] != ""
                # Update existing activity
                existing_activity = department.activities.find_by(id: activity_attrs[:id])
                if existing_activity
                  existing_activity.update!(
                    theme_name: activity_attrs[:theme_name].presence || "",
                    activity_name: activity_attrs[:activity_name],
                    unit: activity_attrs[:unit],
                    annual_target_fy: annual_target_value(activity_attrs)
                  )

                  # Ensure UserDetail record exists for this activity
                  if department.employee_reference.present?
                    employee = find_employee_by_reference(department.employee_reference)
                    if employee
                      existing_user_detail = UserDetail.find_by(
                        department_id: department.id,
                        activity_id: existing_activity.id,
                        employee_detail_id: employee.id,
                        financial_year: @selected_financial_year
                      )

                      unless existing_user_detail
                        UserDetail.create!(
                          department_id: department.id,
                          activity_id: existing_activity.id,
                          employee_detail_id: employee.id,
                          financial_year: @selected_financial_year
                        )
                      end
                    end
                  end
                else
                  Rails.logger.warn "Activity with ID #{activity_attrs[:id]} not found, skipping"
                end
              else
                # Create new activity
                Rails.logger.info "Creating new activity for department #{department.id}"
                new_activity = department.activities.create!(
                  theme_name: activity_attrs[:theme_name].presence || "",
                  activity_name: activity_attrs[:activity_name],
                  unit: activity_attrs[:unit],
                  annual_target_fy: annual_target_value(activity_attrs)
                )
                Rails.logger.info "Created new activity #{new_activity.id}"

                # Create UserDetail record to link activity to employee
                if department.employee_reference.present?
                  employee = find_employee_by_reference(department.employee_reference)
                  if employee
                    UserDetail.create!(
                      department_id: department.id,
                      activity_id: new_activity.id,
                      employee_detail_id: employee.id,
                      financial_year: @selected_financial_year
                    )
                    Rails.logger.info "Created UserDetail linking activity #{new_activity.id} to employee #{employee.employee_id}"
                  end
                end
              end
            end

            # Find activities that are no longer in the form and delete them
            form_activity_ids = params[:department][:activities_attributes].values
              .select { |attrs| attrs[:id].present? && attrs[:id] != "" && attrs[:_destroy] != "true" && attrs[:_destroy] != true }
              .map { |attrs| attrs[:id].to_i }

            Rails.logger.info "Form activity IDs (not marked for destruction): #{form_activity_ids}"
            Rails.logger.info "Current department activities: #{department.activities.pluck(:id)}"

            activities_to_delete = department.activities.where.not(id: form_activity_ids)

            if activities_to_delete.any?
              Rails.logger.info "Found #{activities_to_delete.count} activities to delete that are no longer in form"
              activities_to_delete.each do |activity|
                Rails.logger.info "Deleting activity #{activity.id} (#{activity.activity_name}) - no longer in form"

                # First delete dependent user_details records to avoid foreign key constraint violation
                user_details = UserDetail.where(activity_id: activity.id)
                if user_details.any?
                  Rails.logger.info "Found #{user_details.count} user_details for activity #{activity.id}, deleting them first"
                  user_details.destroy_all
                end

                # Now delete the activity
                if activity.destroy
                  Rails.logger.info "Successfully deleted activity #{activity.id} that was no longer in form"
                else
                  Rails.logger.error "Failed to delete activity #{activity.id}: #{activity.errors.full_messages.join(', ')}"
                end
              end
            else
              Rails.logger.info "No activities to delete that are no longer in form"
            end
          end

          Rails.logger.info "Successfully updated department activities"
          render json: { success: true, message: "Department activities updated successfully!" }
        rescue => e
          Rails.logger.error "Error updating department activities: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
          render json: { success: false, message: "Error updating activities: #{e.message}" }, status: :unprocessable_entity
        end
      else
        Rails.logger.warn "No activities provided in params"
        Rails.logger.warn "params[:department]: #{params[:department].inspect}"
        Rails.logger.warn "params[:department][:activities_attributes]: #{params[:department]&.dig(:activities_attributes).inspect}"
        Rails.logger.warn "All params keys: #{params.keys.inspect}"
        Rails.logger.warn "Form data structure: #{params.inspect}"
        render json: { success: false, message: "No activities provided. Please check the form data structure." }, status: :unprocessable_entity
      end
    else
      # Try to find employee by ID
      employee = find_employee_by_reference(id)

      if employee
        # This would require a different approach since we're dealing with UserDetail records
        # For now, return an error suggesting to use the regular update method
        render json: { success: false, message: "Employee activities should be updated through the regular update method" }, status: :unprocessable_entity
      else
        render json: { success: false, message: "Department or employee not found" }, status: :not_found
      end
    end
  end

  def import
    set_financial_year_context

    file = params[:file]

    if file.nil?
      redirect_to departments_path, alert: "Please upload a file."
      return
    end

    spreadsheet = Roo::Spreadsheet.open(file.path)
    header = import_spreadsheet_row(spreadsheet, 1)

    header_map = {
      "Financial Year" => "financial_year",
      "Department" => "department_type",
      "Department / Region" => "department_type",
      "Mobile No." => "mobile_number",
      "Mobile Number" => "mobile_number",
      "Employee Name" => "employee_name",
      "Employee Email" => "employee_email",
      "Employee Code" => "employee_code",
      "L1 Code" => "l1_code",
      "L1 Employer Name" => "l1_employer_name",
      "L2 Code" => "l2_code",
      "L2 Employer Name" => "l2_employer_name",
      "Theme Name" => "theme_name",
      "Activity Name" => "activity_name",
      "Key Result Indicator" => "activity_name",
      "Key Result Indicators" => "activity_name",
      "Unit" => "unit",
      "Unit of Measurement" => "unit",
      "Annual Target" => "annual_target_fy",
      "Annual Target FY" => "annual_target_fy",
      annual_target_fy_label(@selected_financial_year) => "annual_target_fy",
      "Annual Target FY 2026-27" => "annual_target_fy"
    }

    departments_hash = {}
    import_errors = []
    success_count = 0

    (2..spreadsheet.last_row).each do |i|
      row_data = import_spreadsheet_row(spreadsheet, i)
      row = Hash[[ header, row_data ].transpose]
      mapped = {}
      row.each do |column_name, value|
        mapped_key = header_map[column_name]
        normalized_column = column_name.to_s.strip.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_|_\z/, "")
        mapped_key ||= {
          "mobile_no" => "mobile_number",
          "mobile_number" => "mobile_number",
          "employee_name" => "employee_name",
          "employee_email" => "employee_email",
          "employee_code" => "employee_code",
          "l1_code" => "l1_code",
          "l1_employer_name" => "l1_employer_name",
          "l2_code" => "l2_code",
          "l2_employer_name" => "l2_employer_name",
          "unit_of_measurement" => "unit",
          "annual_target" => "annual_target_fy",
          "department_region" => "department_type"
        }[normalized_column]
        mapped_key ||= "activity_name" if %w[key_result_indicator key_result_indicators].include?(normalized_column)
        mapped_key ||= "annual_target_fy" if normalized_column.start_with?("annual_target_fy")
        mapped_key ||= normalized_column if %w[april may june july august september october november december january february march].include?(normalized_column)
        mapped[mapped_key] = value if mapped_key.present?
      end
      financial_year = normalize_financial_year(mapped["financial_year"]) || @selected_financial_year

      # Skip empty rows
      next if mapped["department_type"].blank? && mapped["employee_name"].blank? && mapped["activity_name"].blank?

      # Validate required fields
      if mapped["employee_name"].blank?
        import_errors << "Row #{i}: Employee name is required"
        next
      end

      if mapped["activity_name"].blank?
        import_errors << "Row #{i}: Key result indicator is required"
        next
      end

      employee = find_or_initialize_department_import_employee(mapped)
      department_type = mapped["department_type"].presence || employee.department
      if department_type.blank?
        import_errors << "Row #{i}: Department is required when employee department is not already available"
        next
      end
      employee.assign_attributes(
        employee_name: mapped["employee_name"].to_s.strip,
        employee_email: mapped["employee_email"].to_s.strip.presence || employee.employee_email,
        employee_code: mapped["employee_code"].to_s.strip.presence || employee.employee_code,
        mobile_number: mapped["mobile_number"].to_s.strip.presence || employee.mobile_number,
        l1_code: mapped["l1_code"].to_s.strip.presence || employee.l1_code,
        l1_employer_name: mapped["l1_employer_name"].to_s.strip.presence || employee.l1_employer_name,
        l2_code: mapped["l2_code"].to_s.strip.presence || employee.l2_code,
        l2_employer_name: mapped["l2_employer_name"].to_s.strip.presence || employee.l2_employer_name,
        department: department_type.to_s.strip
      )
      employee.post = "Imported" if employee.post.blank?
      employee.save!

      months = monthly_target_values_from_mapped_row(mapped)

      # Create unique key for each department-employee combination
      employee_reference = employee_reference_value(employee)
      key = "#{financial_year}-#{department_type}-#{employee_reference}"
      departments_hash[key] ||= {
        financial_year: financial_year,
        department_type: department_type,
        employee_reference: employee_reference,
        employee_detail_id: employee.id,
        theme_name: "",
        activities: []
      }

      # Only add activity if activity data is present
      if mapped["activity_name"].present?
        departments_hash[key][:activities] << {
          theme_name: mapped["theme_name"].presence || "",
          activity_name: mapped["activity_name"],
          unit: mapped["unit"],
          annual_target_fy: normalize_import_display_value(
            mapped["annual_target_fy"],
            percent_context: mapped["unit"].to_s.strip == "%"
          ),
          monthly_targets: months
        }
      end
    end

    if import_errors.any?
      redirect_to departments_path, alert: "❌ Import failed: #{import_errors.join(', ')}"
      return
    end

    # Create departments and activities
    ActiveRecord::Base.transaction do
      departments_hash.each_value do |dept_data|
        department = Department.find_or_initialize_by(
          department_type: dept_data[:department_type],
          employee_reference: dept_data[:employee_reference],
          theme_name: dept_data[:theme_name],
          financial_year: dept_data[:financial_year]
        )
        department.save!

        dept_data[:activities].each do |act|
          activity = department.activities.find_or_initialize_by(activity_name: act[:activity_name])
          activity.assign_attributes(act.except(:monthly_targets))
          activity.save!

          user_detail = UserDetail.find_or_initialize_by(
            department_id: department.id,
            activity_id: activity.id,
            employee_detail_id: dept_data[:employee_detail_id],
            financial_year: dept_data[:financial_year]
          )
          user_detail.assign_attributes(act[:monthly_targets]) if act[:monthly_targets].present?
          user_detail.save!
        end

        success_count += 1
      end
    end

    redirect_to departments_path(financial_year: @selected_financial_year), notice: "✅ Successfully imported #{success_count} department(s) with activities!"
  rescue => e
    redirect_to departments_path(financial_year: params[:financial_year].presence), alert: "❌ Import failed: #{e.message}"
  end

  def export
    set_financial_year_context

    @employee_activities = get_all_employee_activities(@selected_financial_year)

    respond_to do |format|
      format.xlsx {
        response.headers["Content-Disposition"] = 'attachment; filename="departments_export.xlsx"'
        render xlsx: "export", template: "departments/export"
      }
    end
  end

  def destroy
    begin
      # Check if this is a request to delete a specific user's activities
      if params[:user_id].present?
        # Delete only specific user's activities from this department
        delete_user_activities_from_department(params[:user_id])
        message = "User activities deleted successfully from this department."
      else
        # Delete the entire department (existing behavior)
        ActiveRecord::Base.transaction do
          # First, delete all records that reference activities in this department
          @department.activities.each do |activity|
            # Delete user_details that reference this activity
            user_details = UserDetail.where(activity_id: activity.id)
            user_details.destroy_all
          end

          # Now delete the activities
          @department.activities.destroy_all

          # Finally delete the department
          @department.destroy
        end
        message = "Department was successfully deleted."
      end

      respond_to do |format|
        format.html { redirect_to departments_path, notice: message }
        format.json { render json: { success: true, message: message } }
      end
    rescue => e
      Rails.logger.error "Error deleting department: #{e.message}"
      respond_to do |format|
        format.html { redirect_to departments_path, alert: "Error deleting department: #{e.message}" }
        format.json { render json: { success: false, message: "Error deleting department: #{e.message}" }, status: :unprocessable_entity }
      end
    end
  end

  # New method to delete specific user's activities from a department
  def delete_user_activities_from_department(user_id)
    Rails.logger.info "=== delete_user_activities_from_department method called ==="
    Rails.logger.info "Deleting activities for user: #{user_id} from department: #{@department.id}"

    begin
      ActiveRecord::Base.transaction do
        # Find the employee detail for this user
        employee_detail = find_employee_by_reference(user_id)

        if employee_detail
          Rails.logger.info "Found employee: #{employee_detail.employee_name}"

          # Find all user_details for this specific employee in this department
          user_details = UserDetail.where(
            department_id: @department.id,
            employee_detail_id: employee_detail.id
          )

          user_details_count = user_details.count
          Rails.logger.info "Found #{user_details_count} user_details for employee #{employee_detail.employee_name} in department #{@department.id}"

          if user_details_count > 0
            # Delete the user_details (achievements and achievement_remarks will be deleted automatically due to dependent: :destroy)
            user_details.destroy_all
            Rails.logger.info "Deleted #{user_details_count} user_details for employee #{employee_detail.employee_name}"

            # Check if this was the only employee in this department
            remaining_user_details = UserDetail.where(department_id: @department.id)

            if remaining_user_details.count == 0
              Rails.logger.info "No more user_details in department #{@department.id}, deleting department and activities"
              # If no more user_details, delete the department and activities
              @department.activities.destroy_all
              @department.destroy
            else
              Rails.logger.info "Department #{@department.id} still has #{remaining_user_details.count} other user_details, keeping department"
            end
          else
            Rails.logger.info "No user_details found for employee #{employee_detail.employee_name} in department #{@department.id}"
          end
        else
          Rails.logger.error "Employee detail not found for user_id: #{user_id}"
          raise "Employee not found"
        end
      end
    rescue => e
      Rails.logger.error "Error deleting user activities: #{e.message}"
      raise e
    end
  end

  # New method to handle the delete_user_activities route
  def delete_user_activities
    # Handle both form data and JSON parameters
    user_id = params[:employee_id] || params[:user_id]

    if user_id.blank?
      respond_to do |format|
        format.html { redirect_to departments_path, alert: "Employee ID is required" }
        format.json { render json: { success: false, message: "Employee ID is required" }, status: :bad_request }
      end
      return
    end

    Rails.logger.info "delete_user_activities called with user_id: #{user_id}"

    begin
      delete_user_activities_from_department(user_id)

      respond_to do |format|
        format.html { redirect_to departments_path, notice: "User activities deleted successfully from this department!" }
        format.json { render json: { success: true, message: "User activities deleted successfully from this department!" } }
      end
    rescue => e
      Rails.logger.error "Error in delete_user_activities: #{e.message}"

      respond_to do |format|
        format.html { redirect_to departments_path, alert: "Error deleting user activities: #{e.message}" }
        format.json { render json: { success: false, message: "Error deleting user activities: #{e.message}" }, status: :unprocessable_entity }
      end
    end
  end

  # New method to handle the delete_user_from_department route
  def delete_user_from_department
    user_id = params[:user_id] || params[:employee_id]

    if user_id.blank?
      render json: { success: false, message: "User ID is required" }, status: :bad_request
      return
    end

    begin
      delete_user_activities_from_department(user_id)
      render json: { success: true, message: "User deleted successfully from this department!" }
    rescue => e
      Rails.logger.error "Error in delete_user_from_department: #{e.message}"
      render json: { success: false, message: "Error deleting user from department: #{e.message}" }, status: :unprocessable_entity
    end
  end

  def delete_employee_activities
    employee_id = params[:employee_id]

    Rails.logger.info "=== delete_employee_activities method called ==="
    Rails.logger.info "Deleting activities for employee: #{employee_id}"

    # Find all departments for this employee
    departments = Department.where(employee_reference: employee_id)
    Rails.logger.info "Found #{departments.count} departments for employee #{employee_id}"

    if departments.any?
      begin
        # Delete all activities and departments for this employee
        ActiveRecord::Base.transaction do
          departments.each do |dept|
            Rails.logger.info "Processing department #{dept.id} with #{dept.activities.count} activities"

           # First, delete all records that reference these activities
           dept.activities.each do |activity|
             Rails.logger.info "Deleting references for activity #{activity.id}"

             # Delete user_details that reference this activity
             # This will automatically delete associated achievements and achievement_remarks due to dependent: :destroy
             user_details = UserDetail.where(activity_id: activity.id)
             user_details_count = user_details.count
             Rails.logger.info "Found #{user_details_count} user_details for activity #{activity.id}"

             # Delete the user_details (achievements and achievement_remarks will be deleted automatically)
             user_details.destroy_all
             Rails.logger.info "Deleted #{user_details_count} user_details for activity #{activity.id}"
           end

            # Now delete the activities
            activities_count = dept.activities.count
            dept.activities.destroy_all
            Rails.logger.info "Deleted #{activities_count} activities from department #{dept.id}"

            # Finally delete the department
            dept.destroy
            Rails.logger.info "Deleted department #{dept.id}"
          end
        end

        render json: { success: true, message: "Employee activities deleted successfully!" }
      rescue => e
        Rails.logger.error "Error deleting employee activities: #{e.message}"
        Rails.logger.error "Backtrace: #{e.backtrace.join("\n")}"
        render json: { success: false, message: "Error deleting activities: #{e.message}" }, status: :unprocessable_entity
      end
    else
      render json: { success: false, message: "No activities found for this employee" }
    end
  end

  def test_route
    Rails.logger.info "=== test_route method called ==="
    render json: { success: true, message: "Test route working!" }
  end

  def delete_activity
    activity_id = params[:activity_id]

    Rails.logger.info "=== delete_activity method called ==="
    Rails.logger.info "Deleting activity: #{activity_id}"

    begin
      activity = Activity.find(activity_id)

             ActiveRecord::Base.transaction do
         # First, delete all records that reference this activity
         user_details = UserDetail.where(activity_id: activity_id)
         user_details_count = user_details.count
         Rails.logger.info "Found #{user_details_count} user_details for activity #{activity_id}"

         # Delete the user_details (achievements and achievement_remarks will be deleted automatically due to dependent: :destroy)
         user_details.destroy_all
         Rails.logger.info "Deleted #{user_details_count} user_details for activity #{activity_id}"

         # Now delete the activity
         activity.destroy
         Rails.logger.info "Deleted activity #{activity_id}"
       end

      render json: { success: true, message: "Activity deleted successfully!" }
    rescue ActiveRecord::RecordNotFound
      render json: { success: false, message: "Activity not found" }, status: :not_found
    rescue => e
      Rails.logger.error "Error deleting activity: #{e.message}"
      Rails.logger.error "Backtrace: #{e.backtrace.join("\n")}"
      render json: { success: false, message: "Error deleting activity: #{e.message}" }, status: :unprocessable_entity
    end
  end

  # Debug method to show current data structure
  def debug_data
    @departments = Department.includes(:activities).all
    @employee_details = EmployeeDetail.all

    render json: {
      departments: @departments.map do |dept|
        {
          id: dept.id,
          department_type: dept.department_type,
          theme_name: dept.theme_name,
          employee_reference: dept.employee_reference,
          employee_name: dept.employee_name,
          activities_count: dept.activities.count,
          activities: dept.activities.map do |act|
            {
              id: act.id,
              theme_name: act.theme_name,
              activity_name: act.activity_name,
              key_result_indicator: act.activity_name,
              unit: act.unit,
              annual_target_fy: act.annual_target_fy,
              annual_target_fy_2026_27: act.annual_target_fy_2026_27,
            }
          end
        }
      end,
      employee_details: @employee_details.map do |emp|
        {
          id: emp.id,
          employee_id: employee_reference_value(emp),
          employee_name: emp.employee_name,
          employee_code: emp.employee_code,
          department: emp.department
        }
      end
    }
  end

  private

  def set_department
    @department = Department.find(params[:id])
  end

  def employees_for_department_form
    EmployeeDetail
      .where("employee_name IS NOT NULL AND TRIM(employee_name) <> ''")
      .where("department IS NOT NULL AND TRIM(department) <> ''")
      .where("(employee_id IS NOT NULL AND TRIM(employee_id) <> '') OR (employee_code IS NOT NULL AND TRIM(employee_code) <> '')")
      .order(:employee_name)
  end

  def employee_reference_value(employee)
    employee.employee_id.presence || employee.employee_code.presence
  end

  def employee_display_code(employee)
    employee.employee_code.presence || employee.employee_id.presence
  end

  def find_employee_by_reference(reference)
    normalized_reference = reference.to_s.strip
    return nil if normalized_reference.blank?

    EmployeeDetail.find_by(employee_id: normalized_reference) ||
      EmployeeDetail.find_by(employee_code: normalized_reference)
  end

  def find_or_initialize_department_import_employee(mapped)
    employee_code = mapped["employee_code"].to_s.strip
    employee_email = mapped["employee_email"].to_s.strip
    employee_name = mapped["employee_name"].to_s.strip
    department_type = mapped["department_type"].to_s.strip

    employee = EmployeeDetail.find_by(employee_code: employee_code) if employee_code.present?
    employee ||= EmployeeDetail.find_by(employee_email: employee_email) if employee_email.present?
    employee ||= EmployeeDetail.find_by(employee_name: employee_name, department: department_type) if employee_name.present? && department_type.present?

    employee || EmployeeDetail.new(employee_id: employee_code.presence || SecureRandom.uuid)
  end

  def monthly_target_values_from_mapped_row(mapped)
    %w[april may june july august september october november december january february march].index_with do |month|
      normalize_import_target_value(mapped[month])
    end.compact
  end

  def normalize_import_target_value(value)
    cleaned_value = normalize_import_display_value(value)
    return nil if cleaned_value.blank?

    cleaned_value
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

  def normalize_import_display_value(value, percent_context: false)
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

    cleaned_value
  end

  def spreadsheet_error_value?(value)
    SPREADSHEET_ERROR_VALUES.include?(value.to_s.strip.upcase)
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

  def department_params
    params.require(:department).permit(:department_type, :employee_reference, :theme_name, :financial_year,
    activities_attributes: [ :id, :theme_name, :activity_name, :unit, :annual_target_fy, :annual_target_fy_2026_27, :_destroy ])
  end

  def annual_target_value(attributes)
    return attributes[:annual_target_fy] if attributes.key?(:annual_target_fy)
    return attributes["annual_target_fy"] if attributes.key?("annual_target_fy")
    return attributes[:annual_target_fy_2026_27] if attributes.key?(:annual_target_fy_2026_27)
    return attributes["annual_target_fy_2026_27"] if attributes.key?("annual_target_fy_2026_27")

    nil
  end

  def annual_target_fy_label(financial_year)
    year = normalize_financial_year(financial_year) || current_financial_year
    start_year, end_year = year.split("-", 2)
    "Annual target FY #{start_year}-#{end_year.to_s.last(2)}"
  end

  def set_financial_year_context
    @financial_years = financial_year_options
    @selected_financial_year = normalize_financial_year(params[:financial_year]) ||
                               normalize_financial_year(params.dig(:department, :financial_year)) ||
                               current_financial_year
    @financial_years |= [ @selected_financial_year ]
    @financial_years.sort!.reverse!
  end

  def financial_year_options
    start_year = Date.current.month >= 4 ? Date.current.year : Date.current.year - 1
    nearby_years = ((start_year - 1)..(start_year + 1)).map { |year| "#{year}-#{year + 1}" }

    persisted_years = []
    persisted_years += Department.where.not(financial_year: [ nil, "" ]).distinct.pluck(:financial_year) if Department.column_names.include?("financial_year")
    persisted_years += UserDetail.where.not(financial_year: [ nil, "" ]).distinct.pluck(:financial_year) if UserDetail.column_names.include?("financial_year")

    (persisted_years + nearby_years).filter_map { |year| normalize_financial_year(year) }.uniq
  end

  def current_financial_year
    start_year = Date.current.month >= 4 ? Date.current.year : Date.current.year - 1
    "#{start_year}-#{start_year + 1}"
  end

  # Get activities for a specific employee using UserDetail
  def get_employee_activities(employee, financial_year = current_financial_year)
    activities_hash = {}

    # Get all user_details for this employee and deduplicate
    user_details = UserDetail.includes(:activity, :department)
                            .where(employee_detail_id: employee.id)
                            .where(financial_year: financial_year)
                            .where("activity_id IS NOT NULL")

    # Deduplicate by keeping the most recent record for each activity
    deduplicated_details = user_details.group_by(&:activity_id).map do |activity_id, records|
      records.max_by(&:updated_at)
    end

    deduplicated_details.each do |user_detail|
      activity = user_detail.activity
      department = user_detail.department

      # Group by employee ONLY - no department grouping
      key = "#{employee_reference_value(employee)}"

      activities_hash[key] ||= {
        id: department.id, # Use department.id for Edit functionality
        employee_id: employee_reference_value(employee),
        employee_name: employee.employee_name,
        employee_code: employee_display_code(employee),
        department: employee.department, # Employee's department
        department_type: department.department_type, # Activity's department
        financial_year: user_detail.financial_year,
        total_activities: 0,
        activities: []
      }

      activities_hash[key][:activities] << {
        id: activity.id,
        theme_name: activity.theme_name,
        activity_name: activity.activity_name,
        unit: activity.unit,
        annual_target_fy: annual_target_display_value(activity),
        department_type: department.department_type
      }
      activities_hash[key][:total_activities] += 1
    end

    activities_hash
  end

  # Get all employees with their activities grouped by employee
  def get_all_employee_activities(financial_year = current_financial_year)
    activities_hash = {}

    # Get all employees who have user_details
    employees_with_activities = EmployeeDetail.joins(:user_details)
                                             .where(user_details: { financial_year: financial_year })
                                             .distinct
                                             .includes(:user_details)

    employees_with_activities.each do |employee|
      # Get activities for this employee and deduplicate
      user_details = UserDetail.includes(:activity, :department)
                              .where(employee_detail_id: employee.id)
                              .where(financial_year: financial_year)
                              .where("activity_id IS NOT NULL")

      # Deduplicate by keeping the most recent record for each activity
      deduplicated_details = user_details.group_by(&:activity_id).map do |activity_id, records|
        records.max_by(&:updated_at)
      end

      deduplicated_details.each do |user_detail|
        activity = user_detail.activity
        department = user_detail.department

        # Group by employee ONLY - no department grouping
        key = "#{employee_reference_value(employee)}"

        activities_hash[key] ||= {
          id: department.id, # Use department.id for Edit functionality
          employee_id: employee_reference_value(employee),
          employee_name: employee.employee_name,
          employee_code: employee_display_code(employee),
          department: employee.department, # Employee's department
          department_type: department.department_type, # Activity's department
          financial_year: user_detail.financial_year,
          total_activities: 0,
          activities: []
        }

        activities_hash[key][:activities] << {
          id: activity.id,
          theme_name: activity.theme_name,
          activity_name: activity.activity_name,
          unit: activity.unit,
          annual_target_fy: annual_target_display_value(activity),
          department_type: department.department_type
        }
        activities_hash[key][:total_activities] += 1
      end
    end

    # Sort by employee name
    activities_hash.sort_by { |key, data| data[:employee_name] }.to_h
  end
end
