require "roo"
require "axlsx"
require "securerandom"
require "set"

class EmployeeDetailsController < ApplicationController
  before_action :set_employee_detail, only: [ :edit, :update, :destroy, :toggle_portal_status ]
  load_and_authorize_resource except: [ :approve, :return, :l2_approve, :l2_return, :edit_l1, :edit_l2, :toggle_portal_status, :bulk_update_portal_status, :bulk_destroy, :quarterly_pli, :export_quarterly_pli_xlsx, :quarterly_pli_detail, :save_quarterly_pli, :observer_1, :observer_2, :observer_3, :observer_4, :observer_pli_detail, :save_observer_pli ]

  def index
    @employee_detail = EmployeeDetail.new
    @q = EmployeeDetail.ransack(params[:q])
    @employee_details = @q.result.order(Arel.sql("LOWER(employee_name) ASC")).page(params[:page]).per(10)
    load_observer_names_for_employee_list
  end

  def create
    @employee_detail = EmployeeDetail.new(employee_detail_params)

    @q = EmployeeDetail.ransack(params[:q])
    if @employee_detail.save
      redirect_to employee_details_path, notice: "Employee created successfully."
    else
      @employee_details = @q.result.order(Arel.sql("LOWER(employee_name) ASC")).page(params[:page]).per(10)
      load_observer_names_for_employee_list
      flash.now[:alert] = "Failed to create employee."
      render :index, status: :unprocessable_entity
    end
  end

  def update
    if @employee_detail.update(employee_detail_params)
      redirect_to employee_details_path, notice: "Employee updated successfully."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    begin
      @employee_detail.destroy

      # Check if the request came from L2 view and redirect appropriately
      if request.referer&.include?("/employee_details/l2")
        redirect_to l2_employee_details_path, notice: "Employee deleted successfully."
      else
        redirect_to employee_details_path, notice: "Employee deleted successfully."
      end
    rescue => e
      Rails.logger.error "Error deleting employee detail: #{e.message}"

      # Check if the request came from L2 view and redirect appropriately
      if request.referer&.include?("/employee_details/l2")
        redirect_to l2_employee_details_path, alert: "Failed to delete employee. Please try again."
      else
        redirect_to employee_details_path, alert: "Failed to delete employee. Please try again."
      end
    end
  end

  def toggle_portal_status
    authorize! :manage, EmployeeDetail

    @employee_detail.update!(portal_active: !@employee_detail.portal_active?)
    redirect_to employee_details_path(anchor: "employee-list"),
                notice: "#{@employee_detail.employee_name} marked #{@employee_detail.portal_status_label}."
  end

  def bulk_update_portal_status
    authorize! :manage, EmployeeDetail

    employees = bulk_selected_employee_scope
    if employees.none?
      redirect_to employee_details_path(anchor: "employee-list"), alert: "Please select at least one employee."
      return
    end

    portal_active = ActiveModel::Type::Boolean.new.cast(params[:portal_active])
    updated_count = employees.update_all(portal_active: portal_active, updated_at: Time.current)
    status_label = portal_active ? "Active" : "Inactive"

    redirect_to employee_details_path(anchor: "employee-list"),
                notice: "#{updated_count} employee(s) marked #{status_label}."
  end

  def bulk_destroy
    authorize! :manage, EmployeeDetail

    employees = bulk_selected_employee_scope
    if employees.none?
      redirect_to employee_details_path(anchor: "employee-list"), alert: "Please select at least one employee."
      return
    end

    deleted_count = 0
    employees.find_each do |employee|
      deleted_count += 1 if employee.destroy
    end

    redirect_to employee_details_path(anchor: "employee-list"),
                notice: "#{deleted_count} employee(s) deleted successfully."
  rescue => e
    Rails.logger.error "Bulk employee delete failed: #{e.message}"
    redirect_to employee_details_path(anchor: "employee-list"), alert: "Failed to delete selected employees. Please try again."
  end

  def export_xlsx
    @employee_details = EmployeeDetail.all

    package = Axlsx::Package.new
    workbook = package.workbook

    workbook.add_worksheet(name: "Employees") do |sheet|
      sheet.add_row [
        "Name", "Email", "Employee Code",
        "L1 Code", "L1 Name",
        "OBS Code 1", "OBS Name 1", "OBS Code 2", "OBS Name 2",
        "OBS Code 3", "OBS Name 3", "OBS Code 4", "OBS Name 4",
        "Post", "Location", "Department"
      ]

      observer_names_by_code = observer_names_by_code_for(@employee_details)

      @employee_details.each do |emp|
        sheet.add_row [
          emp.employee_name,
          emp.employee_email,
          emp.employee_code,
          emp.l1_code,
          emp.l1_employer_name,
          emp.obs_code1,
          observer_names_by_code[emp.obs_code1.to_s.strip.downcase],
          emp.obs_code2,
          observer_names_by_code[emp.obs_code2.to_s.strip.downcase],
          emp.obs_code3,
          observer_names_by_code[emp.obs_code3.to_s.strip.downcase],
          emp.obs_code4,
          observer_names_by_code[emp.obs_code4.to_s.strip.downcase],
          emp.post,
          emp.location,
          emp.department
        ]
      end
    end

    tempfile = Tempfile.new([ "employee_details", ".xlsx" ])
    package.serialize(tempfile.path)
    send_file tempfile.path, filename: "employee_details.xlsx", type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  end

  def export_quarterly_xlsx
    @employee_details = EmployeeDetail.includes(user_details: [ :activity, :department, :achievements ]).all

    package = Axlsx::Package.new
    workbook = package.workbook

    workbook.add_worksheet(name: "Quarterly L1 Data") do |sheet|
      # Add header row
      sheet.add_row [
        "Employee Name", "Employee Code", "Department", "Quarter End Month",
        "L1 Name", "L1 Employee Code", "L1 Remarks", "L1 Percentage"
      ]

      # Define quarters - Fixed sequence as per requirement with display names
      quarters = {
        "Q1" => { months: [ "april", "may", "june" ], display: "Apr-Jun" },
        "Q2" => { months: [ "july", "august", "september" ], display: "Jul-Sep" },
        "Q3" => { months: [ "october", "november", "december" ], display: "Oct-Dec" },
        "Q4" => { months: [ "january", "february", "march" ], display: "Jan-Mar" }
      }

      # Process each employee and quarter
      @employee_details.each do |emp|
        quarters.each do |quarter_name, quarter_data|
          quarter_months = quarter_data[:months]
          quarter_display = quarter_data[:display]

          # Get all achievements for this employee in this quarter
          all_quarter_achievements = emp.user_details.flat_map(&:achievements).select { |ach| quarter_months.include?(ach.month) }

          # Only add row if there are achievements in this quarter
          if all_quarter_achievements.any?
            # Get L1 and L2 data from achievement remarks
            l1_remarks = []
            l1_percentages = []
            l2_remarks = []
            l2_percentages = []

            all_quarter_achievements.each do |achievement|
              if achievement.achievement_remark.present?
                if achievement.achievement_remark.l1_remarks.present?
                  l1_remarks << achievement.achievement_remark.l1_remarks
                end
                if achievement.achievement_remark.l1_percentage.present?
                  l1_percentages << achievement.achievement_remark.l1_percentage.to_f
                end
                if achievement.achievement_remark.l2_remarks.present?
                  l2_remarks << achievement.achievement_remark.l2_remarks
                end
                if achievement.achievement_remark.l2_percentage.present?
                  l2_percentages << achievement.achievement_remark.l2_percentage.to_f
                end
              end
            end

            # Calculate averages
            l1_avg = l1_percentages.any? ? (l1_percentages.sum / l1_percentages.size).round(1) : 0.0
            l2_avg = l2_percentages.any? ? (l2_percentages.sum / l2_percentages.size).round(1) : 0.0

            # Join remarks with semicolons
            l1_remarks_text = l1_remarks.uniq.join("; ")
            l2_remarks_text = l2_remarks.uniq.join("; ")

            sheet.add_row [
              emp.employee_name || "N/A",
              emp.employee_code || "N/A",
              emp.department || "N/A",
              quarter_display,
              emp.l1_employer_name || "N/A",
              emp.l1_code || "N/A",
              l1_remarks_text.presence || "N/A",
              l1_avg > 0 ? "#{l1_avg}%" : "N/A"
            ]
          end
        end
      end
    end

    tempfile = Tempfile.new([ "quarterly_l1_data", ".xlsx" ])
    package.serialize(tempfile.path)
    send_file tempfile.path, filename: "quarterly_l1_data.xlsx", type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  end

  def import
    file = params[:file]

    if file.nil?
      redirect_to employee_details_path, alert: "Please upload a file."
      return
    end

    header_map = {
      "employeeid" => "employee_id",
      "name" => "employee_name",
      "employeename" => "employee_name",
      "email" => "employee_email",
      "employeeemail" => "employee_email",
      "employeecode" => "employee_code",
      "empcode" => "employee_code",
      "mobile" => "mobile_number",
      "mobilenumber" => "mobile_number",
      "mobile no" => "mobile_number",
      "mobileno" => "mobile_number",
      "mobile#" => "mobile_number",
      "l1code" => "l1_code",
      "l2code" => "l2_code",
      "obscode1" => "obs_code1",
      "obs1code" => "obs_code1",
      "observercode1" => "obs_code1",
      "observer1code" => "obs_code1",
      "obscode2" => "obs_code2",
      "obs2code" => "obs_code2",
      "observercode2" => "obs_code2",
      "observer2code" => "obs_code2",
      "obscode3" => "obs_code3",
      "obs3code" => "obs_code3",
      "observercode3" => "obs_code3",
      "observer3code" => "obs_code3",
      "obscode4" => "obs_code4",
      "obs4code" => "obs_code4",
      "observercode4" => "obs_code4",
      "observer4code" => "obs_code4",
      "l1name" => "l1_employer_name",
      "l1employername" => "l1_employer_name",
      "l2name" => "l2_employer_name",
      "l2employername" => "l2_employer_name",
      "post" => "post",
      "designation" => "post",
      "location" => "location",
      "postinglocation" => "location",
      "worklocation" => "location",
      "department" => "department",
      "departmentregion" => "department",
      "financialyear" => "financial_year",
      "theme" => "theme_name",
      "themename" => "theme_name",
      "activitytheme" => "theme_name",
      "activityname" => "activity_name",
      "keyresultindicator" => "activity_name",
      "keyresultindicators" => "activity_name",
      "unit" => "unit",
      "unitofmeasurement" => "unit",
      "annualtarget" => "annual_target_fy",
      "annualtargetfy" => "annual_target_fy",
      "annualtargetfy202627" => "annual_target_fy",
      "april" => "april",
      "apr" => "april",
      "may" => "may",
      "june" => "june",
      "jun" => "june",
      "july" => "july",
      "jul" => "july",
      "august" => "august",
      "aug" => "august",
      "september" => "september",
      "sep" => "september",
      "sept" => "september",
      "october" => "october",
      "oct" => "october",
      "november" => "november",
      "nov" => "november",
      "december" => "december",
      "dec" => "december",
      "january" => "january",
      "jan" => "january",
      "february" => "february",
      "feb" => "february",
      "march" => "march",
      "mar" => "march"
    }

    employee_count = 0
    target_count = 0
    import_errors = []
    processed_employee_ids = Set.new
    sheets_processed = 0
    spreadsheet = Roo::Spreadsheet.open(file.path)
    sheet_names = spreadsheet.respond_to?(:sheets) && spreadsheet.sheets.present? ? spreadsheet.sheets : [ spreadsheet.default_sheet || "Sheet1" ]

    sheet_names.each do |sheet_name|
      if spreadsheet.respond_to?(:default_sheet=) && spreadsheet.respond_to?(:sheets) && spreadsheet.sheets.include?(sheet_name)
        spreadsheet.default_sheet = sheet_name
      end

      next if spreadsheet.last_row.to_i < 2

      sheets_processed += 1
      header = spreadsheet.row(1).map { |value| normalize_import_header(value) }

      (2..spreadsheet.last_row).each do |i|
        row_label = sheet_names.size > 1 ? "#{sheet_name} Row #{i}" : "Row #{i}"
        row = Hash[[ header, spreadsheet.row(i) ].transpose]
        mapped_row = row.each_with_object({}) do |(key, value), mapped|
          attribute_name = header_map[key.to_s]
          next unless attribute_name
          next if value.nil?

          cleaned_value = value.is_a?(String) ? value.strip : value
          next if cleaned_value.respond_to?(:blank?) ? cleaned_value.blank? : cleaned_value.nil?

          mapped[attribute_name] = cleaned_value
        end

        begin
          next if mapped_row.empty?

          normalize_import_manager_attributes!(mapped_row)
          employee_attributes = mapped_row.slice(
            "employee_id", "employee_name", "employee_email", "employee_code", "mobile_number",
            "l1_code", "l1_employer_name", "l2_code", "l2_employer_name",
            "obs_code1", "obs_code2", "obs_code3", "obs_code4",
            "post", "location", "department"
          )
          employee_detail = find_existing_employee_detail(employee_attributes) || EmployeeDetail.new(employee_id: mapped_row["employee_id"].presence || mapped_row["employee_code"].presence || SecureRandom.uuid)
          employee_detail.assign_attributes(employee_attributes)
          employee_detail.post = "Imported" if employee_detail.post.blank?
          employee_detail.save!
          employee_count += 1 if processed_employee_ids.add?(employee_detail.id)
          target_count += sync_imported_department_target_data!(employee_detail, mapped_row)
        rescue => e
          Rails.logger.error "Employee import failed for #{row_label}: #{e.message}"
          import_errors << "#{row_label}: #{e.message}"
          next
        end
      end
    end

    message = "✅ #{employee_count} employee(s) imported successfully!"
    message += " #{target_count} department/KRI row(s) updated." if target_count.positive?
    message += " Processed #{sheets_processed} sheet(s)." if sheets_processed.positive?

    if import_errors.any?
      redirect_to employee_details_path, alert: "#{message} Some rows failed: #{import_errors.first(10).join(', ')}"
    else
      redirect_to employee_details_path, notice: message
    end
  end

  # L1 Dashboard - Show quarterly data
  def l1
    authorize! :l1, EmployeeDetail

    if current_user.hod?
      # PERFORMANCE FIX: Optimize includes to preload all necessary associations
      @employee_details = EmployeeDetail.includes(
        user_details: [
          :activity,
          :department,
          achievements: :achievement_remark
        ]
      ).all
    else
      # PERFORMANCE FIX: Optimize includes to preload all necessary associations
      @employee_details = EmployeeDetail
                            .where(status: [ "pending", "l1_returned", "l1_approved", "l2_returned", "l2_approved" ])
                            .where("LOWER(TRIM(COALESCE(l1_code, ''))) = ?", current_user.employee_code.to_s.strip.downcase)
                            .includes(
                              user_details: [
                                :activity,
                                :department,
                                achievements: :achievement_remark
                              ]
                            )
    end

    prepare_review_filters(@employee_details)

    @monthly_employee_data = build_monthly_employee_data(
      @employee_details,
      approval_level: "l1",
      month: @selected_review_month,
      financial_year: @selected_financial_year
    )
    @monthly_employee_data = filter_l1_rows_by_observer_chain(@monthly_employee_data)
  end

  # Show employee details with quarterly view
  def show
    begin
      @employee_detail = EmployeeDetail.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      redirect_to employee_details_path, alert: "❌ Employee detail not found. The record may have been deleted."
      return
    end

    authorize! :read, @employee_detail
    prepare_employee_detail_show
  end

  # Quarterly approval - approve all activities for a quarter
  def approve
    begin
      @employee_detail = EmployeeDetail.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      if request.xhr?
        render json: { success: false, message: "❌ Employee detail not found. The record may have been deleted." }, status: :not_found
      else
        redirect_to employee_details_path, alert: "❌ Employee detail not found. The record may have been deleted."
      end
      return
    end

    # Skip authorization check for AJAX requests to prevent CanCan errors
    if request.xhr? || params[:action_type].present?
      # For AJAX requests, we'll handle authorization in the processing method
    else
      unless can_act_as_l1?(@employee_detail)
        redirect_back fallback_location: root_path, alert: "❌ You are not authorized to approve this record"
        return
      end
    end

    if can_act_as_l1?(@employee_detail)
      Rails.logger.debug "PROCESSING L1 QUARTERLY APPROVAL"
      # Pass action_type parameter to indicate this is an approval action
      params[:action_type] = "approve"
      result = process_quarterly_l1_approval

      if result[:success]
        if request.format.json? || request.xhr? || params[:action_type].present?
          render json: {
            success: true,
            count: result[:count],
            message: "✅ Successfully approved #{result[:count]} activities for #{params[:selected_quarter] || 'all quarters'} by L1",
            updated_status: "l1_approved"
          }
        else
          redirect_to employee_detail_path(@employee_detail, review_redirect_params),
                      notice: "✅ Successfully approved #{result[:count]} activities for #{params[:selected_quarter] || 'all quarters'} by L1"
        end
      else
        if request.xhr? || params[:action_type].present?
          render json: { success: false, message: result[:message] }, status: :unprocessable_entity
        else
          redirect_back fallback_location: root_path, alert: result[:message]
        end
      end

    elsif can_act_as_l2?(@employee_detail)
      Rails.logger.debug "PROCESSING L2 QUARTERLY APPROVAL"
      # Pass action_type parameter to indicate this is an approval action
      params[:action_type] = "approve"
      result = process_quarterly_l2_approval

      if result[:success]
        if request.xhr? || params[:action_type].present?
          render json: {
            success: true,
            count: result[:count],
            message: "✅ Successfully approved #{result[:count]} activities for #{params[:selected_quarter] || 'all quarters'} by L2"
          }
        else
          redirect_to employee_detail_path(@employee_detail, review_redirect_params),
                      notice: "✅ Successfully approved #{result[:count]} activities for #{params[:selected_quarter] || 'all quarters'} by L2"
        end
      else
        if request.xhr? || params[:action_type].present?
          render json: { success: false, message: result[:message] }
        else
          redirect_back fallback_location: root_path, alert: result[:message]
        end
      end
    else
      Rails.logger.debug "AUTHORIZATION FAILED"
      if request.xhr? || params[:action_type].present?
        render json: { success: false, message: "❌ You are not authorized to approve this record" }
      else
        redirect_back fallback_location: root_path, alert: "❌ You are not authorized to approve this record"
      end
    end
  end

  # Quarterly return - return all activities for a quarter
  def return
    begin
      @employee_detail = EmployeeDetail.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      if request.xhr?
        render json: { success: false, message: "❌ Employee detail not found. The record may have been deleted." }, status: :not_found
      else
        redirect_to employee_details_path, alert: "❌ Employee detail not found. The record may have been deleted."
      end
      return
    end

    # Skip authorization check for AJAX requests to prevent CanCan errors
    if request.xhr? || params[:action_type].present?
      # For AJAX requests, we'll handle authorization in the processing method
    else
      unless can_act_as_l1?(@employee_detail)
        redirect_back fallback_location: root_path, alert: "❌ You are not authorized to return this record"
        return
      end
    end

    if can_act_as_l1?(@employee_detail)
      Rails.logger.debug "PROCESSING L1 QUARTERLY RETURN"
      # Pass action_type parameter to indicate this is a return action
      params[:action_type] = "return"
      result = process_quarterly_l1_return

      if result[:success]
        if request.format.json? || request.xhr? || params[:action_type].present?
          render json: {
            success: true,
            count: result[:count],
            message: "⚠️ Successfully returned #{result[:count]} activities for #{params[:selected_quarter] || 'all quarters'} by L1",
            updated_status: "l1_returned"
          }
        else
          redirect_to employee_detail_path(@employee_detail, review_redirect_params),
                      alert: "⚠️ Successfully returned #{result[:count]} activities for #{params[:selected_quarter] || 'all quarters'} by L1"
        end
      else
        if request.xhr? || params[:action_type].present?
          render json: { success: false, message: result[:message] }, status: :unprocessable_entity
        else
          redirect_back fallback_location: root_path, alert: result[:message]
        end
      end

    elsif can_act_as_l2?(@employee_detail)
      Rails.logger.debug "PROCESSING L2 QUARTERLY RETURN"
      # Pass action_type parameter to indicate this is a return action
      params[:action_type] = "return"
      result = process_quarterly_l2_return

      if result[:success]
        if request.xhr? || params[:action_type].present?
          render json: {
            success: true,
            count: result[:count],
            message: "⚠️ Successfully returned #{result[:count]} activities for #{params[:selected_quarter] || 'all quarters'} by L2"
          }
        else
          redirect_to employee_detail_path(@employee_detail, review_redirect_params),
                      alert: "⚠️ Successfully returned #{result[:count]} activities for #{params[:selected_quarter] || 'all quarters'} by L2"
        end
      else
        if request.xhr? || params[:action_type].present?
          render json: { success: false, message: result[:message] }
        else
          redirect_back fallback_location: root_path, alert: result[:message]
        end
      end
    else
      Rails.logger.debug "AUTHORIZATION FAILED"
      if request.xhr? || params[:action_type].present?
        render json: { success: false, message: "❌ You are not authorized to return this record" }
      else
        redirect_back fallback_location: root_path, alert: result[:message]
      end
    end
  end

def l2
  if current_user.hod?
    # HOD can see all employee details, but only those with L1+ approved achievements
    # PERFORMANCE FIX: Optimize includes to preload all necessary associations
    employee_details = EmployeeDetail.includes(
      user_details: [
        :activity,
        :department,
        achievements: :achievement_remark
      ]
    ).order(created_at: :desc)
  else
    # L2 managers can only see their assigned employees with L1+ approved achievements
    # PERFORMANCE FIX: Optimize includes to preload all necessary associations
    employee_details = EmployeeDetail.where("l2_code = ? OR l2_employer_name = ?",
                                           current_user.employee_code,
                                           current_user.email)
                                   .includes(
                                     user_details: [
                                       :activity,
                                       :department,
                                       achievements: :achievement_remark
                                     ]
                                   )
                                   .order(created_at: :desc)
  end

  # Filter to only include employees who have at least one L1+ approved achievement
  @employee_details = employee_details.select do |emp|
    next false unless l2_reviewer_assigned?(emp)

    emp.user_details.any? do |ud|
      ud.achievements.any? do |achievement|
        # Only show records with L1 approved, L2 approved, or L2 returned status
        [ "l1_approved", "l2_approved", "l2_returned" ].include?(achievement.status)
      end
    end
  end
  prepare_review_filters(@employee_details)
  @monthly_employee_data = build_monthly_employee_data(
    @employee_details,
    approval_level: "l2",
    month: @selected_review_month,
    financial_year: @selected_financial_year
  )
end

  def show_l2
    begin
      @employee_detail = EmployeeDetail.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      redirect_to employee_details_path, alert: "❌ Employee detail not found. The record may have been deleted."
      return
    end

    unless l2_reviewer_assigned?(@employee_detail)
      redirect_to l2_employee_details_path, alert: "❌ L2 reviewer is not assigned for this employee."
      return
    end

    unless current_user.hod? || can_act_as_l2?(@employee_detail)
      redirect_to root_path, alert: "❌ You are not authorized to access this page."
      return
    end

    @user_detail_id = params[:user_detail_id]
    @selected_month = normalize_month_param(params[:month])
    @selected_quarter = params[:quarter].presence || quarter_for_month(@selected_month)
    @selected_financial_year = selected_financial_year.presence || infer_review_financial_year(@employee_detail, @selected_month, @selected_quarter)

    # FIXED: Get ALL user details, not just those with achievements
    @user_details = @employee_detail.user_details
                      .includes(:activity, :department, achievements: :achievement_remark)
    @user_details = @user_details.where(financial_year: @selected_financial_year) if @selected_financial_year.present?

    # If quarter is selected, filter achievements by quarter
    if @selected_quarter.present?
      @quarterly_activities = get_quarterly_activities(@user_details, @selected_quarter)
    else
      @quarterly_activities = get_all_quarterly_activities(@user_details)
    end

    @can_l2_approve_or_return = can_act_as_l2?(@employee_detail)
    @can_l2_act = @can_l2_approve_or_return
  end

  def quarterly_pli
    unless quarterly_pli_authorized?
      redirect_to root_path, alert: "You are not authorized to access Quarterly PLI %."
      return
    end

    @selected_quarterly_pli_quarter = params[:quarter].presence
    @selected_financial_year = selected_financial_year || current_financial_year
    @quarter_options = get_all_quarters.map do |quarter|
      [ "#{quarter} (#{get_quarter_months(quarter).map { |month| month_label(month) }.join('-')})", quarter ]
    end

    employee_details = quarterly_pli_employee_scope.includes(
      quarterly_pli_reviews: :reviewed_by,
      user_details: [
        :activity,
        :department,
        achievements: :achievement_remark
      ]
    )

    @financial_year_options = employee_details.flat_map { |employee|
      employee.user_details.map(&:financial_year)
    }.compact.reject(&:blank?).uniq.sort.reverse

    @selected_financial_year ||= @financial_year_options.first || current_financial_year
    @financial_year_options |= [ @selected_financial_year ]
    @financial_year_options.compact!
    @financial_year_options.sort!.reverse!
    @quarterly_pli_rows = build_quarterly_pli_rows(
      employee_details,
      financial_year: @selected_financial_year,
      quarter: @selected_quarterly_pli_quarter
    )
  end

  def export_quarterly_pli_xlsx
    unless quarterly_pli_authorized?
      redirect_to root_path, alert: "You are not authorized to export Quarterly PLI %."
      return
    end

    selected_quarter = params[:quarter].presence
    selected_year = selected_financial_year || current_financial_year
    employee_details = quarterly_pli_employee_scope.includes(
      quarterly_pli_reviews: :reviewed_by,
      user_details: [
        :activity,
        :department,
        achievements: :achievement_remark
      ]
    )

    financial_year_options = employee_details.flat_map { |employee|
      employee.user_details.map(&:financial_year)
    }.compact.reject(&:blank?).uniq.sort.reverse
    selected_year ||= financial_year_options.first || current_financial_year

    rows = build_quarterly_pli_rows(
      employee_details,
      financial_year: selected_year,
      quarter: selected_quarter
    )

    package = Axlsx::Package.new
    workbook = package.workbook
    styles = workbook.styles
    header_style = styles.add_style(
      bg_color: "1F2937",
      fg_color: "FFFFFF",
      b: true,
      alignment: { horizontal: :center, vertical: :center, wrap_text: true },
      border: { style: :thin, color: "CBD5E1" }
    )
    cell_style = styles.add_style(
      alignment: { vertical: :top, wrap_text: true },
      border: { style: :thin, color: "E5E7EB" }
    )

    workbook.add_worksheet(name: "Quarterly PLI") do |sheet|
      sheet.add_row [
        "Employee Code",
        "Name",
        "Department",
        "Financial Year",
        "Quarter",
        "Calculated %",
        "Final PLI %",
        "Final L1 Remarks"
      ], style: header_style

      rows.each do |row|
        employee = row[:employee]
        review = row[:review]

        sheet.add_row [
          employee.employee_code.presence || "-",
          employee.employee_name.presence || "-",
          employee.department.presence || "-",
          row[:financial_year].presence || "-",
          row[:quarter_label].presence || row[:quarter].presence || "-",
          quarterly_pli_export_percentage(row[:calculated_percentage]),
          review&.final_percentage.present? ? "#{format('%.2f', review.final_percentage.to_f)}%" : "-",
          quarterly_pli_export_l1_remarks(row)
        ], style: cell_style
      end

      sheet.column_widths 18, 28, 24, 18, 24, 16, 16, 60
    end

    filename_parts = [ "quarterly_pli", selected_year, selected_quarter.presence ].compact
    tempfile = Tempfile.new([ filename_parts.join("_"), ".xlsx" ])
    package.serialize(tempfile.path)
    send_file tempfile.path,
              filename: "#{filename_parts.join('_')}.xlsx",
              type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  end

  def quarterly_pli_detail
    unless quarterly_pli_authorized?
      redirect_to root_path, alert: "You are not authorized to access Quarterly PLI %."
      return
    end

    financial_year = params[:financial_year].to_s.strip
    quarter = params[:quarter].to_s.strip
    @employee_detail = quarterly_pli_employee_scope.includes(
      user_details: [ :activity, :department, achievements: :achievement_remark ]
    ).find_by(id: params[:id])

    if @employee_detail.blank? || financial_year.blank? || !get_all_quarters.include?(quarter)
      redirect_to quarterly_pli_employee_details_path, alert: "Invalid Quarterly PLI record."
      return
    end

    @detail_payload = quarter_pli_payload_for(@employee_detail, financial_year, quarter)
    unless @detail_payload
      redirect_to quarterly_pli_employee_details_path(financial_year: financial_year, quarter: quarter), alert: quarterly_pli_review_complete_message(@employee_detail)
      return
    end

    @financial_year = financial_year
    @quarter = quarter
    @quarter_label = "#{quarter} (#{@detail_payload[:months].map { |month| month[:label] }.join('-')})"
    @review = QuarterlyPliReview.find_by(
      employee_detail: @employee_detail,
      financial_year: financial_year,
      quarter: quarter
    )
    @review = current_quarterly_pli_review_for(@review, @employee_detail, financial_year, quarter)
  end

  def save_quarterly_pli
    unless quarterly_pli_authorized?
      redirect_to root_path, alert: "You are not authorized to save Quarterly PLI %."
      return
    end

    financial_year = params[:financial_year].to_s.strip
    quarter = params[:quarter].to_s.strip
    employee_detail = quarterly_pli_employee_scope.find_by(id: params[:employee_detail_id])
    percentage = params[:final_percentage].to_s.strip
    remarks = params[:final_remarks].to_s.strip
    action_type = params[:action_type].to_s.strip == "return" ? "return" : "approve"
    final_percentage = parse_pli_percentage(percentage)

    if employee_detail.blank? || financial_year.blank? || !get_all_quarters.include?(quarter)
      redirect_to quarterly_pli_employee_details_path(financial_year: financial_year, quarter: quarter), alert: "Invalid Quarterly PLI record."
      return
    end

    if remarks.blank? || (action_type == "approve" && percentage.blank?)
      redirect_to quarterly_pli_employee_details_path(financial_year: financial_year, quarter: quarter), alert: action_type == "approve" ? "Remarks and Percentage are required." : "Remarks are required."
      return
    end

    if action_type == "approve" && final_percentage.nil?
      redirect_to quarterly_pli_employee_details_path(financial_year: financial_year, quarter: quarter), alert: "Percentage must be a valid number between 0 and 100."
      return
    end

    unless quarter_ready_for_pli?(employee_detail, financial_year, quarter)
      redirect_to quarterly_pli_employee_details_path(financial_year: financial_year, quarter: quarter), alert: quarterly_pli_review_complete_message(employee_detail)
      return
    end

    review = QuarterlyPliReview.find_or_initialize_by(
      employee_detail: employee_detail,
      financial_year: financial_year,
      quarter: quarter
    )
    review.final_remarks = bounded_review_text(remarks)
    review.final_percentage = action_type == "approve" ? final_percentage : nil
    review.status = action_type == "return" ? "returned" : "approved"
    review.reviewed_by = current_user
    review.reviewed_at = Time.current

    if review.save
      notice_message = if review.status == "returned"
        "Quarterly PLI returned for #{employee_detail.employee_name}."
      else
        "Quarterly PLI % saved for #{employee_detail.employee_name}."
      end
      redirect_to quarterly_pli_employee_details_path(financial_year: financial_year, quarter: quarter), notice: notice_message
    else
      redirect_to quarterly_pli_employee_details_path(financial_year: financial_year, quarter: quarter), alert: review.errors.full_messages.to_sentence
    end
  end

  def observer_1
    build_observer_pli_index("obs_code1")
  end

  def observer_2
    build_observer_pli_index("obs_code2")
  end

  def observer_3
    build_observer_pli_index("obs_code3")
  end

  def observer_4
    build_observer_pli_index("obs_code4")
  end

  def observer_pli_detail
    observer_level = observer_level_param
    unless observer_pli_authorized?(observer_level)
      redirect_to root_path, alert: "You are not authorized to access this observer menu."
      return
    end

    financial_year = params[:financial_year].to_s.strip
    quarter = params[:quarter].to_s.strip
    month = normalize_month_param(params[:month])
    @employee_detail = observer_pli_employee_scope(observer_level).includes(
      observer_pli_reviews: :reviewed_by,
      user_details: [ :activity, :department, achievements: :achievement_remark ]
    ).find_by(id: params[:id])

    if @employee_detail.blank? || financial_year.blank? || month.blank? || !get_all_quarters.include?(quarter) || !get_quarter_months(quarter).include?(month)
      redirect_to observer_pli_redirect_path(observer_level, financial_year: financial_year, quarter: quarter), alert: "Invalid observer PLI record."
      return
    end

    unless observer_level_available_for_month?(@employee_detail, financial_year, quarter, month, observer_level)
      redirect_to observer_pli_redirect_path(observer_level, financial_year: financial_year, quarter: quarter), alert: "#{observer_menu_title(observer_level)} is not ready for this month yet."
      return
    end

    unless submitted_month_payload_available?(@employee_detail, financial_year, quarter, month)
      redirect_to observer_pli_redirect_path(observer_level, financial_year: financial_year, quarter: quarter), alert: quarterly_pli_review_complete_message(@employee_detail)
      return
    end

    @observer_context = true
    @observer_level = observer_level
    @observer_title = observer_menu_title(observer_level)
    @observer_review = ObserverPliReview.find_by(
      employee_detail: @employee_detail,
      financial_year: financial_year,
      quarter: quarter,
      month: month,
      observer_level: observer_level
    )

    prepare_employee_detail_show(
      financial_year: financial_year,
      month: month,
      quarter: quarter
    )

    render :show
  end

  def save_observer_pli
    observer_level = observer_level_param
    unless observer_pli_authorized?(observer_level)
      redirect_to root_path, alert: "You are not authorized to save this observer review."
      return
    end

    financial_year = params[:financial_year].to_s.strip
    quarter = params[:quarter].to_s.strip
    month = normalize_month_param(params[:month])
    employee_detail = observer_pli_employee_scope(observer_level).find_by(id: params[:employee_detail_id])
    remarks = params[:final_remarks].to_s.strip
    action_type = params[:action_type].to_s.strip == "return" ? "return" : "approve"

    if employee_detail.blank? || financial_year.blank? || month.blank? || !get_all_quarters.include?(quarter) || !get_quarter_months(quarter).include?(month)
      redirect_to observer_pli_redirect_path(observer_level, financial_year: financial_year, quarter: quarter), alert: "Invalid observer PLI record."
      return
    end

    if remarks.blank? && !observer_activity_remarks_present?(employee_detail, month, observer_level)
      redirect_to observer_pli_detail_employee_detail_path(employee_detail, observer_level: observer_level, financial_year: financial_year, quarter: quarter, month: month), alert: "Activity-wise observer remarks are required."
      return
    end

    unless observer_level_available_for_month?(employee_detail, financial_year, quarter, month, observer_level)
      redirect_to observer_pli_redirect_path(observer_level, financial_year: financial_year, quarter: quarter), alert: "#{observer_menu_title(observer_level)} is not ready for this month yet."
      return
    end

    review = ObserverPliReview.find_or_initialize_by(
      employee_detail: employee_detail,
      financial_year: financial_year,
      quarter: quarter,
      month: month,
      observer_level: observer_level
    )
    review.final_remarks = bounded_review_text(remarks) if remarks.present?
    review.status = action_type == "return" ? "returned" : "approved"
    review.reviewed_by = current_user
    review.reviewed_at = Time.current

    if review.save
      save_observer_activity_remarks(employee_detail, month, observer_level)
      l1_sms_result = review.status == "approved" ? notify_l1_after_observer_chain_approval(employee_detail, financial_year, quarter, month) : nil
      notice_message = review.status == "returned" ? "#{observer_menu_title(observer_level)} returned #{month_label(month)} for #{employee_detail.employee_name}." : "#{observer_menu_title(observer_level)} approved #{month_label(month)} for #{employee_detail.employee_name}."
      notice_message = "#{notice_message} L1 SMS sent." if l1_sms_result&.dig(:success) && l1_sms_result[:sent]
      redirect_to observer_pli_redirect_path(observer_level, financial_year: financial_year, quarter: quarter), notice: notice_message
    else
      redirect_to observer_pli_detail_employee_detail_path(employee_detail, observer_level: observer_level, financial_year: financial_year, quarter: quarter, month: month), alert: review.errors.full_messages.to_sentence
    end
  end

  def l2_approve
    begin
      @employee_detail = EmployeeDetail.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      Rails.logger.error "Employee detail not found: #{params[:id]}"
      if request.xhr?
        render json: { success: false, message: "❌ Employee detail not found. The record may have been deleted." }, status: :not_found
      else
        redirect_to employee_details_path, alert: "❌ Employee detail not found. The record may have been deleted."
      end
      return
    end

    unless l2_reviewer_assigned?(@employee_detail)
      if request.xhr? || params[:action_type].present?
        render json: { success: false, message: "❌ L2 reviewer is not assigned for this employee." }, status: :unprocessable_entity
      else
        redirect_to l2_employee_details_path, alert: "❌ L2 reviewer is not assigned for this employee."
      end
      return
    end

    # Skip authorization check for AJAX requests to prevent CanCan errors
    if request.xhr? || params[:action_type].present?
      # For AJAX requests, we'll handle authorization in the processing method
    else
      unless current_user.hod? || can_act_as_l2?(@employee_detail)
        redirect_to show_l2_employee_detail_path(@employee_detail), alert: "❌ You are not authorized to approve at L2 level"
        return
      end
    end

    # Pass action_type parameter to indicate this is an approval action
    params[:action_type] = "approve"
    result = process_quarterly_l2_approval

    if result[:success]
      if request.xhr? || params[:action_type].present?
        render json: {
          success: true,
          count: result[:count],
          message: "✅ Successfully approved #{result[:count]} activities for #{params[:selected_quarter] || 'all quarters'} by L2",
          updated_status: "l2_approved"
        }
      else
        redirect_to show_l2_employee_detail_path(@employee_detail, review_redirect_params),
                    notice: "✅ Successfully approved #{result[:count]} activities for #{params[:selected_quarter] || 'all quarters'} by L2"
      end
    else
      if request.xhr? || params[:action_type].present?
        render json: { success: false, message: result[:message] }, status: :unprocessable_entity
      else
        redirect_to show_l2_employee_detail_path(@employee_detail, review_redirect_params),
                    alert: result[:message]
      end
    end
  end

  def l2_return
    begin
      @employee_detail = EmployeeDetail.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      Rails.logger.error "Employee detail not found: #{params[:id]}"
      if request.xhr?
        render json: { success: false, message: "❌ Employee detail not found. The record may have been deleted." }, status: :not_found
      else
        redirect_to employee_details_path, alert: "❌ Employee detail not found. The record may have been deleted."
      end
      return
    end

    unless l2_reviewer_assigned?(@employee_detail)
      if request.xhr? || params[:action_type].present?
        render json: { success: false, message: "❌ L2 reviewer is not assigned for this employee." }, status: :unprocessable_entity
      else
        redirect_to l2_employee_details_path, alert: "❌ L2 reviewer is not assigned for this employee."
      end
      return
    end

    # Skip authorization check for AJAX requests to prevent CanCan errors
    if request.xhr? || params[:action_type].present?
      # For AJAX requests, we'll handle authorization in the processing method
    else
      unless current_user.hod? || can_act_as_l2?(@employee_detail)
        redirect_to show_l2_employee_detail_path(@employee_detail), alert: "❌ You are not authorized to return at L2 level"
        return
      end
    end

    # Add debugging

    # Pass action_type parameter to indicate this is a return action
    params[:action_type] = "return"
    result = process_quarterly_l2_return


    if result[:success]
      if request.xhr? || params[:action_type].present?
        render json: {
          success: true,
          count: result[:count],
          message: "⚠️ Successfully returned #{result[:count]} activities for #{params[:selected_quarter] || 'all quarters'} by L2",
          updated_status: "l2_returned"
        }
      else
        redirect_to show_l2_employee_detail_path(@employee_detail, review_redirect_params),
                    notice: "⚠️ Successfully returned #{result[:count]} activities for #{params[:selected_quarter] || 'all quarters'} by L2"
      end
    else
      if request.xhr? || params[:action_type].present?
        render json: { success: false, message: result[:message] }, status: :unprocessable_entity
      else
        redirect_to show_l2_employee_detail_path(@employee_detail, review_redirect_params),
                    alert: result[:message]
      end
    end
  end

  # Edit L1 remarks and percentage
  def edit_l1
    begin
      @employee_detail = EmployeeDetail.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      Rails.logger.error "Employee detail not found: #{params[:id]}"
      if request.xhr?
        render json: { success: false, message: "❌ Employee detail not found. The record may have been deleted." }, status: :not_found
      else
        redirect_to employee_details_path, alert: "❌ Employee detail not found. The record may have been deleted."
      end
      return
    end

    # Only HOD can edit L1 data
    unless current_user.hod?
      if request.xhr?
        render json: { success: false, message: "❌ You are not authorized to edit L1 data" }, status: :forbidden
      else
        redirect_to root_path, alert: "❌ You are not authorized to edit L1 data."
      end
      return
    end

    result = process_l1_edit

    if result[:success]
      if request.xhr?
        render json: {
          success: true,
          message: "✅ Successfully updated L1 data for #{params[:selected_quarter] || 'all quarters'}",
          percentage: result[:percentage],
          remarks: result[:remarks]
        }
      else
        redirect_to employee_detail_path(@employee_detail, review_redirect_params),
                    notice: "✅ Successfully updated L1 data for #{params[:selected_quarter] || 'all quarters'}"
      end
    else
      if request.xhr?
        render json: { success: false, message: result[:message] }, status: :unprocessable_entity
      else
        redirect_to employee_detail_path(@employee_detail, review_redirect_params),
                    alert: result[:message]
      end
    end
  end

  # Edit L2 remarks and percentage
  def edit_l2
    begin
      @employee_detail = EmployeeDetail.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      Rails.logger.error "Employee detail not found: #{params[:id]}"
      if request.xhr?
        render json: { success: false, message: "❌ Employee detail not found. The record may have been deleted." }, status: :not_found
      else
        redirect_to employee_details_path, alert: "❌ Employee detail not found. The record may have been deleted."
      end
      return
    end

    # Only HOD can edit L2 data
    unless current_user.hod?
      if request.xhr?
        render json: { success: false, message: "❌ You are not authorized to edit L2 data" }, status: :forbidden
      else
        redirect_to root_path, alert: "❌ You are not authorized to edit L2 data."
      end
      return
    end

    result = process_l2_edit

    if result[:success]
      if request.xhr?
        render json: {
          success: true,
          message: "✅ Successfully updated L2 data for #{params[:selected_quarter] || 'all quarters'}",
          percentage: result[:percentage],
          remarks: result[:remarks]
        }
      else
        redirect_to show_l2_employee_detail_path(@employee_detail, review_redirect_params),
                    notice: "✅ Successfully updated L2 data for #{params[:selected_quarter] || 'all quarters'}"
      end
    else
      if request.xhr?
        render json: { success: false, message: result[:message] }, status: :unprocessable_entity
      else
        redirect_to show_l2_employee_detail_path(@employee_detail, review_redirect_params),
                    alert: result[:message]
      end
    end
  end

  private

  def load_observer_names_for_employee_list
    @observer_names_by_code = observer_names_by_code_for(@employee_details)
  end

  def observer_names_by_code_for(employee_details)
    observer_codes = Array(employee_details).flat_map do |employee|
      ApplicationHelper::OBSERVER_LEVELS.map { |observer_level| employee.public_send(observer_level).to_s.strip }
    end.reject(&:blank?).map(&:downcase).uniq

    return {} if observer_codes.empty?

    EmployeeDetail
      .where("LOWER(TRIM(employee_code)) IN (?)", observer_codes)
      .pluck(:employee_code, :employee_name)
      .each_with_object({}) do |(code, name), names_by_code|
        names_by_code[code.to_s.strip.downcase] = name
      end
  end

  def notify_l1_after_observer_chain_approval(employee_detail, financial_year, quarter, month)
    return { success: true, sent: false, message: "Observer approval chain is still pending" } unless observer_chain_approved_for_month?(employee_detail, financial_year, quarter, month)

    quarter_label = quarter_sms_label(quarter)
    return { success: true, sent: false, message: "L1 SMS already sent" } if l1_sms_already_sent?(employee_detail.id, quarter_label, month)

    result = send_sms_to_l1_after_observers(employee_detail, quarter_label, month)
    mark_l1_sms_as_sent(employee_detail.id, quarter_label, month) if result[:success]
    result.merge(sent: result[:success])
  end

  def send_sms_to_l1_after_observers(employee_detail, quarter_label, month)
    l1_code = employee_detail.l1_code.to_s.strip
    return { success: false, error: "L1 code not found for employee" } if l1_code.blank?

    l1_manager = employee_detail_for_code(l1_code)
    return { success: false, error: "L1 manager not found with code: #{l1_code}" } unless l1_manager
    return { success: false, error: "L1 manager mobile number not found" } if l1_manager.mobile_number.blank?

    month_text = month.present? ? " #{month_label(month)}" : ""
    message = "Emp-Code: #{employee_detail.employee_code}, Emp-Name: #{employee_detail.employee_name} has submitted his#{month_text} #{quarter_label} Qtr KRA MIS. Please review and approve in the system. Ploughman Agro Private Limited"

    SmsNotificationService.send_message(l1_manager.mobile_number, message)
  end

  def l1_sms_already_sent?(employee_detail_id, quarter, month)
    SmsLog.exists?(
      employee_detail_id: employee_detail_id,
      quarter: quarter,
      month: month,
      recipient_role: "l1",
      sent: true
    )
  end

  def mark_l1_sms_as_sent(employee_detail_id, quarter, month)
    SmsLog.create!(
      employee_detail_id: employee_detail_id,
      quarter: quarter,
      month: month,
      recipient_role: "l1",
      sent: true,
      sent_at: Time.current
    )
  rescue => e
    Rails.logger.error "Failed to mark L1 SMS as sent: #{e.message}"
  end

  def quarter_sms_label(quarter)
    case quarter.to_s
    when "Q1" then "Q1 (APR-JUN)"
    when "Q2" then "Q2 (JUL-SEP)"
    when "Q3" then "Q3 (OCT-DEC)"
    when "Q4" then "Q4 (JAN-MAR)"
    else quarter.to_s
    end
  end

  def employee_detail_for_code(employee_code)
    code = employee_code.to_s.strip
    return nil if code.blank?

    EmployeeDetail.where("LOWER(TRIM(employee_code)) = ?", code.downcase).first ||
      EmployeeDetail.find_by("employee_code LIKE ?", "#{code}%")
  end

  def prepare_employee_detail_show(financial_year: nil, month: nil, quarter: nil)
    @user_detail_id = params[:user_detail_id]
    @selected_month = normalize_month_param(month || params[:month])
    @selected_quarter = quarter.presence || params[:quarter].presence || quarter_for_month(@selected_month)
    @selected_financial_year = financial_year.presence || selected_financial_year.presence ||
                               current_financial_year ||
                               infer_review_financial_year(@employee_detail, @selected_month, @selected_quarter)

    @user_details = @employee_detail.user_details
                      .includes(:activity, :department, achievements: :achievement_remark)
    @user_details = @user_details.where(financial_year: @selected_financial_year) if @selected_financial_year.present?

    if @selected_quarter.present?
      @quarterly_activities = get_quarterly_activities(@user_details, @selected_quarter)
    else
      @quarterly_activities = get_all_quarterly_activities(@user_details)
    end

    @can_approve_or_return = !@observer_context &&
                              can_act_as_l1?(@employee_detail) &&
                              observer_chain_approved_for_selection?(@employee_detail, @selected_financial_year, @selected_quarter, @selected_month)
    @can_observer_approve_or_return = @observer_context && @observer_review&.status != "approved"
    load_observer_summary_reviews
  end

  def load_observer_summary_reviews
    @observer_summary_reviews = {}
    return @observer_summary_reviews if @employee_detail.blank? || @selected_financial_year.blank?

    review_months = if @selected_month.present?
                      [ @selected_month ]
                    elsif @selected_quarter.present?
                      get_quarter_months(@selected_quarter)
                    else
                      []
                    end
    return @observer_summary_reviews if review_months.empty?

    assigned_levels = observer_levels_for(@employee_detail)
    levels_to_load = if @observer_context && @observer_level.present?
                       [ @observer_level ] & assigned_levels
                     else
                       assigned_levels
                     end

    levels_to_load.each do |observer_level|

      activity_remarks = review_months.flat_map do |month|
        observer_activity_remarks_for(@user_details, month, observer_level)
      end.uniq
      activity_remark_entries = review_months.flat_map do |month|
        observer_activity_remark_entries_for(@user_details, month, observer_level)
      end.uniq { |entry| [ entry[:activity_name], entry[:remark] ] }

      reviews = ObserverPliReview.where(
        employee_detail: @employee_detail,
        financial_year: @selected_financial_year,
        quarter: @selected_quarter,
        month: review_months,
        observer_level: observer_level
      ).order(reviewed_at: :desc)

      review = if @selected_month.present?
                 reviews.find { |record| record.month == @selected_month } || reviews.first
               else
                 reviews.first
               end

      final_remarks = review&.final_remarks.presence

      @observer_summary_reviews[observer_level] = {
        review: review,
        activity_remarks: activity_remarks,
        activity_remark_entries: activity_remark_entries,
        final_remarks: final_remarks,
        observer_code: @employee_detail.public_send(observer_level),
        observer_name: observer_employee_name_for(@employee_detail, observer_level)
      }
    end

    @observer_summary_reviews
  end

  def observer_activity_remarks_for(user_details, month, observer_level)
    observer_activity_remark_entries_for(user_details, month, observer_level).map { |entry| entry[:remark] }
  end

  def observer_activity_remark_entries_for(user_details, month, observer_level)
    remark_column = observer_remark_column_for(observer_level)

    user_details.filter_map do |detail|
      achievement = detail.achievements.find { |record| record.month.to_s.downcase == month.to_s.downcase }
      remark_text = achievement&.achievement_remark&.public_send(remark_column)
      next if remark_text.blank?

      {
        activity_name: detail.activity&.activity_name.presence || "Activity",
        remark: remark_text.to_s.strip
      }
    end
  end

  def observer_month_remarks_for(employee_detail, financial_year, quarter, month, observer_level)
    return [] unless observer_levels_for(employee_detail).include?(observer_level)

    review = ObserverPliReview.find_by(
      employee_detail: employee_detail,
      financial_year: financial_year,
      quarter: quarter,
      month: month,
      observer_level: observer_level
    )
    review&.final_remarks.present? ? [ review.final_remarks ] : []
  end

  def month_final_remarks_for(month_remarks, remark_column)
    latest_remark = month_remarks
                      .select { |remark| remark.public_send(remark_column).present? }
                      .max_by(&:updated_at)
    final_remark = latest_remark&.public_send(remark_column).to_s.strip
    final_remark.present? ? [ final_remark ] : []
  end

  def normalize_import_header(value)
    value.to_s.strip.downcase.gsub(/[^a-z0-9#]+/, "")
  end

  def find_existing_employee_detail(mapped_row)
    if mapped_row["employee_code"].present?
      employee = EmployeeDetail.find_by(employee_code: mapped_row["employee_code"])
      return employee if employee
    end

    if mapped_row["employee_email"].present?
      employee = EmployeeDetail.find_by(employee_email: mapped_row["employee_email"])
      return employee if employee
    end

    if mapped_row["employee_name"].present? && mapped_row["mobile_number"].present?
      employee = EmployeeDetail.find_by(
        employee_name: mapped_row["employee_name"],
        mobile_number: mapped_row["mobile_number"]
      )
      return employee if employee
    end

    if mapped_row["employee_id"].present?
      employee = EmployeeDetail.find_by(employee_id: mapped_row["employee_id"])
      return employee if employee
    end

    nil
  end

  def sync_imported_department_target_data!(employee_detail, mapped_row)
    activity_name = import_activity_name_from_columns(mapped_row["financial_year"], mapped_row["activity_name"])
    return 0 if activity_name.blank?

    department_type = mapped_row["department"].to_s.strip.presence || employee_detail.department.to_s.strip.presence
    raise "Department is required for KRI import" if department_type.blank?

    financial_year = normalize_import_financial_year(mapped_row["financial_year"]) ||
                     normalize_import_financial_year(params[:financial_year]) ||
                     current_financial_year
    unit = mapped_row["unit"].to_s.strip
    annual_target_fy = normalize_import_display_value(
      mapped_row["annual_target_fy"],
      percent_context: unit == "%"
    )

    if employee_detail.department != department_type
      employee_detail.update!(department: department_type)
    end

    department = Department.find_or_initialize_by(
      department_type: department_type,
      employee_reference: employee_reference_value(employee_detail),
      financial_year: financial_year
    )
    department.theme_name ||= ""
    department.save!

    activity = department.activities.find_or_initialize_by(activity_name: activity_name)
    activity.theme_name = mapped_row["theme_name"].to_s.strip if mapped_row["theme_name"].present?
    activity.unit = unit if unit.present?
    activity.annual_target_fy = annual_target_fy if annual_target_fy.present?
    activity.save!

    user_detail = UserDetail.find_or_initialize_by(
      department_id: department.id,
      activity_id: activity.id,
      employee_detail_id: employee_detail.id,
      financial_year: financial_year
    )
    user_detail.assign_attributes(monthly_target_values_from_import_row(mapped_row))
    user_detail.save!

    1
  end

  def monthly_target_values_from_import_row(mapped_row)
    review_months.index_with do |month|
      normalize_import_display_value(mapped_row[month])
    end.compact
  end

  def normalize_import_display_value(value, percent_context: false)
    return nil if value.nil?

    cleaned_value = if value.is_a?(Numeric)
      value.to_f.finite? && value.to_f == value.to_i ? value.to_i.to_s : value.to_s
    else
      value.to_s.strip
    end

    return nil if cleaned_value.blank?

    cleaned_value = cleaned_value.sub(/\A(-?\d+)\.0+\z/, "\\1")
    return "100%" if percent_context && cleaned_value.match?(/\A1(?:\.0+)?\z/)

    cleaned_value
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

  def normalize_import_manager_attributes!(mapped_row)
    if mapped_row["l1_code"].present? && mapped_row["l1_employer_name"].present? && !employee_code_like?(mapped_row["l1_code"]) && employee_code_like?(mapped_row["l1_employer_name"])
      mapped_row["l1_code"], mapped_row["l1_employer_name"] = mapped_row["l1_employer_name"], mapped_row["l1_code"]
    end

    if mapped_row["l2_employer_name"].present? && normalize_import_financial_year(mapped_row["l2_employer_name"]).present? && !employee_code_like?(mapped_row["l2_code"])
      mapped_row["financial_year"] = mapped_row["l2_employer_name"] if normalize_import_financial_year(mapped_row["financial_year"]).blank?
      mapped_row["l2_employer_name"] = mapped_row["l2_code"]
      mapped_row["l2_code"] = nil
    elsif mapped_row["l2_code"].present? && mapped_row["l2_employer_name"].present? && !employee_code_like?(mapped_row["l2_code"]) && employee_code_like?(mapped_row["l2_employer_name"])
      mapped_row["l2_code"], mapped_row["l2_employer_name"] = mapped_row["l2_employer_name"], mapped_row["l2_code"]
    end
  end

  def employee_code_like?(value)
    value.to_s.strip.match?(/\A[A-Z]{2,}\s*-?\s*\d+\z/i)
  end

  def employee_reference_value(employee_detail)
    employee_detail.employee_id.presence || employee_detail.employee_code.presence
  end

  def current_financial_year
    start_year = Date.current.month >= 4 ? Date.current.year : Date.current.year - 1
    "#{start_year}-#{start_year + 1}"
  end

  def set_employee_detail
    @employee_detail = EmployeeDetail.find(params[:id])
  end

  def employee_detail_params
    params.require(:employee_detail).permit(
      :employee_id, :employee_name, :employee_email, :employee_code, :mobile_number,
      :l1_code, :l1_employer_name, :l2_code, :l2_employer_name,
      :obs_code1, :obs_code2, :obs_code3, :obs_code4,
      :post, :location, :department, :l1_remarks, :l1_percentage, :l2_remarks, :l2_percentage
    )
  end

  def bulk_selected_employee_scope
    if params[:selection_scope].to_s == "all_matching"
      EmployeeDetail.ransack(params[:q]).result
    else
      employee_ids = Array(params[:employee_detail_ids]).reject(&:blank?)
      EmployeeDetail.where(id: employee_ids)
    end
  end

  def quarterly_pli_authorized?
    current_user.hod? ||
      current_user.admin? ||
      EmployeeDetail.where(
        "LOWER(TRIM(COALESCE(l1_code, ''))) = ? OR LOWER(TRIM(COALESCE(l1_employer_name, ''))) = ?",
        current_user.employee_code.to_s.strip.downcase,
        current_user.email.to_s.strip.downcase
      ).exists? ||
      EmployeeDetail.where(
        "LOWER(TRIM(COALESCE(l2_code, ''))) = ? OR LOWER(TRIM(COALESCE(l2_employer_name, ''))) = ?",
        current_user.employee_code.to_s.strip.downcase,
        current_user.email.to_s.strip.downcase
      ).exists?
  end

  def quarterly_pli_employee_scope
    scope = EmployeeDetail.order(Arel.sql("LOWER(employee_name) ASC"))
    return scope if current_user.hod? || current_user.admin?

    scope.where(
      "LOWER(TRIM(COALESCE(l1_code, ''))) = :code OR LOWER(TRIM(COALESCE(l1_employer_name, ''))) = :email OR LOWER(TRIM(COALESCE(l2_code, ''))) = :code OR LOWER(TRIM(COALESCE(l2_employer_name, ''))) = :email",
      code: current_user.employee_code.to_s.strip.downcase,
      email: current_user.email.to_s.strip.downcase
    )
  end

  def build_observer_pli_index(observer_level)
    unless observer_pli_authorized?(observer_level)
      redirect_to root_path, alert: "You are not authorized to access #{observer_menu_title(observer_level)}."
      return
    end

    @observer_level = observer_level
    @observer_title = observer_menu_title(observer_level)
    @selected_observer_pli_quarter = params[:quarter].presence
    @selected_observer_pli_month = normalize_month_param(params[:month])
    @selected_financial_year = selected_financial_year || current_financial_year
    @quarter_options = get_all_quarters.map do |quarter|
      [ "#{quarter} (#{get_quarter_months(quarter).map { |month| month_label(month) }.join('-')})", quarter ]
    end
    @month_options = review_months.map { |month| [ month_label(month), month ] }

    employee_details = observer_pli_employee_scope(observer_level).includes(
      observer_pli_reviews: :reviewed_by,
      user_details: [
        :activity,
        :department,
        achievements: :achievement_remark
      ]
    )

    @financial_year_options = employee_details.flat_map { |employee|
      employee.user_details.map(&:financial_year)
    }.compact.reject(&:blank?).uniq.sort.reverse

    @selected_financial_year ||= @financial_year_options.first || current_financial_year
    @financial_year_options |= [ @selected_financial_year ]
    @financial_year_options.compact!
    @financial_year_options.sort!.reverse!
    @observer_pli_rows = build_observer_pli_rows(
      employee_details,
      observer_level: observer_level,
      financial_year: @selected_financial_year,
      quarter: @selected_observer_pli_quarter,
      month: @selected_observer_pli_month
    )

    render :observer_pli
  end

  def build_observer_pli_rows(employee_details, observer_level:, financial_year:, quarter: nil, month: nil)
    return [] if financial_year.blank?

    quarters = quarter.present? ? [ quarter ] : get_all_quarters
    months_by_quarter = quarters.to_h do |quarter_name|
      months = get_quarter_months(quarter_name)
      months = months.select { |quarter_month| quarter_month == month } if month.present?
      [ quarter_name, months ]
    end
    employee_ids = employee_details.map(&:id)
    observer_reviews = ObserverPliReview
                         .where(employee_detail_id: employee_ids, financial_year: financial_year, quarter: quarters, observer_level: observer_level)
                         .includes(:reviewed_by)
                         .index_by { |review| [ review.employee_detail_id, review.quarter, review.month ] }

    rows = []
    employee_details.each do |employee|
      quarters.each do |quarter_name|
        (months_by_quarter[quarter_name] || []).each do |month_name|
          next unless observer_level_available_for_month?(employee, financial_year, quarter_name, month_name, observer_level)

          payload = quarter_pli_payload_for(employee, financial_year, quarter_name, require_ready: false, month: month_name)
          next unless payload

          rows << {
            employee: employee,
            financial_year: financial_year,
            quarter: quarter_name,
            month: month_name,
            month_label: month_label(month_name),
            quarter_label: "#{quarter_name} (#{payload[:months].map { |payload_month| payload_month[:label] }.join('-')})",
            calculated_percentage: payload[:quarter_percentage],
            observer_review: observer_reviews[[ employee.id, quarter_name, month_name ]],
            detail_payload: payload
          }
        end
      end
    end

    rows.sort_by do |row|
      [
        row[:observer_review]&.status == "approved" ? 1 : 0,
        row[:employee].employee_name.to_s.downcase,
        row[:quarter],
        row[:month]
      ]
    end
  end

  def observer_level_param
    level = params[:observer_level].presence || params[:level].presence
    ApplicationHelper::OBSERVER_LEVELS.include?(level) ? level : "obs_code1"
  end

  def observer_menu_title(observer_level)
    number = observer_level.to_s.gsub(/\D/, "").to_i
    number = 1 if number.zero?
    "Observer Menu #{number}"
  end

  def observer_pli_authorized?(observer_level)
    helpers.observer_level_assigned_to_user?(observer_level, current_user)
  end

  def observer_pli_employee_scope(observer_level)
    scope = EmployeeDetail.order(Arel.sql("LOWER(employee_name) ASC"))
    return scope.where("TRIM(COALESCE(#{observer_level}, '')) != ''") if current_user.admin? || current_user.hod?

    code = helpers.resolved_observer_identity_code(current_user)
    return scope.none if code.blank?

    scope.where(
      "LOWER(TRIM(COALESCE(#{observer_level}, ''))) = ?",
      code.downcase
    )
  end

  def observer_pli_redirect_path(observer_level, options = {})
    path_helper = {
      "obs_code1" => :observer_1_employee_details_path,
      "obs_code2" => :observer_2_employee_details_path,
      "obs_code3" => :observer_3_employee_details_path,
      "obs_code4" => :observer_4_employee_details_path
    }[observer_level.to_s] || :observer_1_employee_details_path
    public_send(path_helper, options)
  end

  def observer_levels_for(employee_detail)
    ApplicationHelper::OBSERVER_LEVELS.select do |observer_level|
      employee_detail.public_send(observer_level).to_s.strip.present?
    end
  end

  def observer_review_approved?(employee_detail, financial_year, quarter, month, observer_level)
    ObserverPliReview.exists?(
      employee_detail: employee_detail,
      financial_year: financial_year,
      quarter: quarter,
      month: month,
      observer_level: observer_level,
      status: "approved"
    )
  end

  def observer_level_available_for_month?(employee_detail, financial_year, quarter, month, observer_level)
    levels = observer_levels_for(employee_detail)
    return false unless levels.include?(observer_level)

    submitted_month_payload_available?(employee_detail, financial_year, quarter, month)
  end

  def observer_chain_approved_for_month?(employee_detail, financial_year, quarter, month)
    assigned_levels = observer_levels_for(employee_detail)
    return true if assigned_levels.empty?

    assigned_levels.all? do |observer_level|
      observer_review_approved?(employee_detail, financial_year, quarter, month, observer_level)
    end
  end

  def observer_chain_pending_message(employee_detail)
    assigned_levels = observer_levels_for(employee_detail)
    if assigned_levels.empty?
      "Observer approval is not required for this employee."
    else
      labels = assigned_levels.map { |level| observer_menu_title(level) }.join(", ")
      "Observer approval is pending. Complete #{labels} before L1 action."
    end
  end

  def submitted_month_payload_available?(employee_detail, financial_year, quarter, month)
    quarter_pli_payload_for(employee_detail, financial_year, quarter, require_ready: false, month: month).present?
  end

  def filter_l1_rows_by_observer_chain(monthly_employee_data)
    rows = monthly_employee_data.values
    return monthly_employee_data if rows.empty?

    employee_ids = rows.map { |data| data[:employee]&.id }.compact.uniq
    financial_years = rows.map { |data| data[:financial_year] }.compact.uniq
    quarters = rows.map { |data| data[:quarter_name] }.compact.uniq
    months = rows.map { |data| data[:month] }.compact.uniq

    approved_observer_keys = ObserverPliReview
      .where(
        employee_detail_id: employee_ids,
        financial_year: financial_years,
        quarter: quarters,
        month: months,
        status: "approved"
      )
      .pluck(:employee_detail_id, :financial_year, :quarter, :month, :observer_level)
      .to_set

    monthly_employee_data.select do |_key, data|
      employee = data[:employee]
      assigned_levels = observer_levels_for(employee)
      next true if assigned_levels.empty?

      assigned_levels.all? do |observer_level|
        approved_observer_keys.include?([
          employee.id,
          data[:financial_year],
          data[:quarter_name],
          data[:month],
          observer_level
        ])
      end
    end
  end

  def observer_chain_approved_for_selection?(employee_detail, financial_year, quarter, month)
    financial_year = financial_year.presence || infer_review_financial_year(employee_detail, month, quarter)
    return false if financial_year.blank?

    months = if month.present?
               [ month ]
             elsif quarter.present?
               get_quarter_months(quarter)
             else
               review_months
             end

    months.select! do |review_month|
      selected_quarter = quarter_for_month(review_month)
      submitted_month_payload_available?(employee_detail, financial_year, selected_quarter, review_month)
    end
    return true if months.empty?

    months.all? do |review_month|
      selected_quarter = quarter_for_month(review_month)
      observer_chain_approved_for_month?(employee_detail, financial_year, selected_quarter, review_month)
    end
  end

  def build_quarterly_pli_rows(employee_details, financial_year:, quarter: nil)
    return [] if financial_year.blank?

    quarters = quarter.present? ? [ quarter ] : get_all_quarters
    employee_ids = employee_details.map(&:id)
    reviews = QuarterlyPliReview
                .where(employee_detail_id: employee_ids, financial_year: financial_year, quarter: quarters)
                .includes(:reviewed_by)
                .index_by { |review| [ review.employee_detail_id, review.quarter ] }

    employee_details.flat_map do |employee|
      quarters.filter_map do |quarter_name|
        payload = quarter_pli_payload_for(employee, financial_year, quarter_name)
        next unless payload

        review = current_quarterly_pli_review_for(
          reviews[[ employee.id, quarter_name ]],
          employee,
          financial_year,
          quarter_name
        )
        {
          employee: employee,
          financial_year: financial_year,
          quarter: quarter_name,
          quarter_label: "#{quarter_name} (#{payload[:months].map { |month| month[:label] }.join('-')})",
          calculated_percentage: payload[:quarter_percentage],
          review: review,
          detail_payload: payload
        }
      end
    end.sort_by do |row|
      [
        row[:review].present? ? 1 : 0,
        row[:employee].employee_name.to_s.downcase,
        row[:quarter]
      ]
    end
  end

  def current_quarterly_pli_review_for(review, employee_detail, financial_year, quarter)
    return nil if review.blank?

    reviewed_at = review.reviewed_at || review.updated_at || review.created_at
    source_updated_at = quarterly_pli_source_updated_at(employee_detail, financial_year, quarter)

    return review if source_updated_at.blank?
    return review if reviewed_at.present? && reviewed_at >= source_updated_at

    nil
  end

  def quarterly_pli_source_updated_at(employee_detail, financial_year, quarter)
    quarter_months = get_quarter_months(quarter)
    return nil if quarter_months.empty?

    timestamps = []

    employee_detail.user_details.each do |detail|
      next unless detail.financial_year.to_s == financial_year.to_s && detail.activity.present?
      next unless quarter_months.any? { |month| target_present_for_review_month?(detail, month) }

      timestamps << detail.updated_at

      detail.achievements.each do |achievement|
        next unless quarter_months.include?(achievement.month.to_s.downcase)

        timestamps << achievement.updated_at
        timestamps << achievement.achievement_remark&.updated_at
      end
    end

    timestamps.compact.max
  end

  def quarterly_pli_export_percentage(value)
    return "-" if value.blank? || value.to_s == "-"

    numeric_value = value.to_s.delete_suffix("%").to_f
    "#{format('%.2f', numeric_value)}%"
  end

  def quarterly_pli_export_l1_remarks(row)
    remarks = Array(row.dig(:detail_payload, :months)).flat_map do |month_payload|
      Array(month_payload[:l1_remarks])
    end.map { |remark| remark.to_s.strip }.reject(&:blank?).uniq

    remarks.any? ? remarks.join("; ") : "-"
  end

  def quarter_ready_for_pli?(employee_detail, financial_year, quarter)
    quarter_pli_payload_for(employee_detail, financial_year, quarter).present?
  end

  def quarter_pli_payload_for(employee_detail, financial_year, quarter, require_ready: true, month: nil)
    quarter_months = get_quarter_months(quarter)
    quarter_months = quarter_months.select { |quarter_month| quarter_month == month } if month.present?
    return nil if quarter_months.empty?

    user_details = employee_detail.user_details.select do |detail|
      detail.financial_year.to_s == financial_year.to_s && detail.activity.present?
    end
    return nil if user_details.empty?

    reviewable_months = quarter_months.select do |quarter_month|
      submitted_target_achievements_for_pli_month(user_details, quarter_month).any?
    end
    return nil if reviewable_months.empty?

    if require_ready
      ready_months = reviewable_months.select do |quarter_month|
        month_ready_for_quarterly_pli?(employee_detail, user_details, quarter_month, financial_year)
      end
      return nil if ready_months.empty? || ready_months.size != reviewable_months.size
    end

    quarter_target_total = 0.0
    quarter_achievement_total = 0.0

    month_payloads = reviewable_months.filter_map do |month|
      detail_achievements = submitted_target_achievements_for_pli_month(user_details, month)
      next if require_ready && !month_ready_for_quarterly_pli?(employee_detail, user_details, month, financial_year)

      items = user_details.filter_map do |detail|
        next unless target_present_for_review_month?(detail, month)

        target_number = numeric_review_value(detail.public_send(month))
        next unless target_number.positive?

        achievement = detail.achievements.find do |record|
          record.month.to_s.downcase == month && record.achievement.present?
        end
        achievement_number = achievement.present? ? numeric_review_value(achievement.achievement) : 0.0
        progress_value = truncated_percentage(achievement_number, target_number)
        remark = achievement&.achievement_remark

        {
          kri: detail.activity&.activity_name.to_s,
          unit: detail.activity&.unit.to_s,
          annual_target: normalize_import_display_value(
            detail.activity&.annual_target_fy,
            percent_context: detail.activity&.unit.to_s.strip == "%"
          ).presence || "-",
          target: display_review_number(target_number),
          achievement: display_review_number(achievement_number),
          progress_value: progress_value,
          progress: format_pli_percentage(progress_value),
          employee_remarks: achievement&.employee_remarks.to_s.presence || remark&.employee_remarks.to_s.presence || "-",
          reporting_manager_remarks: remark&.reporting_manager_remarks.to_s.presence || "-",
          l1_remarks: remark&.l1_remarks.to_s.presence || "-",
          l1_percentage: format_pli_percentage(remark&.l1_percentage),
          obs_code1_remarks: remark&.obs_code1_remarks.to_s.presence || "-",
          obs_code2_remarks: remark&.obs_code2_remarks.to_s.presence || "-",
          obs_code3_remarks: remark&.obs_code3_remarks.to_s.presence || "-",
          obs_code4_remarks: remark&.obs_code4_remarks.to_s.presence || "-",
          l2_remarks: remark&.l2_remarks.to_s.presence || "-",
          l2_percentage: format_pli_percentage(remark&.l2_percentage),
          status: achievement&.status.to_s,
          target_number: target_number,
          achievement_number: achievement_number
        }
      end

      return nil if items.empty?

      target_total = items.sum { |item| item[:target_number] }
      achievement_total = items.sum { |item| item[:achievement_number] }
      quarter_target_total += target_total
      quarter_achievement_total += achievement_total

      month_progress_values = items.filter_map { |item| item[:progress_value] }
      month_progress = average_review_percentage(month_progress_values)

      l1_percentages = items.filter_map { |item| item[:l1_percentage] == "-" ? nil : item[:l1_percentage].to_f }
      l2_percentages = items.filter_map { |item| item[:l2_percentage] == "-" ? nil : item[:l2_percentage].to_f }
      month_remarks = detail_achievements.filter_map { |_detail, achievement| achievement.achievement_remark }

      {
        key: month,
        label: month_label(month),
        target_total: display_review_number(target_total),
        achievement_total: display_review_number(achievement_total),
        progress_value: month_progress,
        progress: format_pli_percentage(month_progress),
        achievement_percentage_value: month_progress,
        achievement_percentage: format_pli_percentage(month_progress),
        employee_remarks: items.map { |item| item[:employee_remarks] }.reject { |text| text == "-" }.uniq,
        l1_remarks: month_final_remarks_for(month_remarks, :l1_remarks),
        l1_percentage: format_pli_percentage(average_review_percentage(l1_percentages)),
        obs_code1_remarks: observer_month_remarks_for(employee_detail, financial_year, quarter, month, "obs_code1"),
        obs_code2_remarks: observer_month_remarks_for(employee_detail, financial_year, quarter, month, "obs_code2"),
        obs_code3_remarks: observer_month_remarks_for(employee_detail, financial_year, quarter, month, "obs_code3"),
        obs_code4_remarks: observer_month_remarks_for(employee_detail, financial_year, quarter, month, "obs_code4"),
        l2_remarks: month_final_remarks_for(month_remarks, :l2_remarks),
        l2_percentage: format_pli_percentage(average_review_percentage(l2_percentages)),
        items: items.map { |item| item.except(:target_number, :achievement_number) }
      }
    end
    return nil if month_payloads.empty?
    return nil if require_ready && month_payloads.size != reviewable_months.size

    quarter_progress_values = month_payloads.filter_map { |month_payload| month_payload[:progress_value]&.to_f }
    quarter_percentage = average_review_percentage(quarter_progress_values)

    {
      employee_name: employee_detail.employee_name,
      employee_code: employee_detail.employee_code,
      financial_year: financial_year,
      quarter: quarter,
      quarter_percentage: format_pli_percentage(quarter_percentage),
      quarter_percentage_value: quarter_percentage,
      quarter_month_count: month_payloads.size,
      target_total: display_review_number(quarter_target_total),
      achievement_total: display_review_number(quarter_achievement_total),
      months: month_payloads
    }
  end

  def numeric_review_value(value)
    value.to_s.delete(",").to_f
  end

  def parse_pli_percentage(value)
    normalized_value = value.to_s.strip.delete(",").delete_suffix("%").strip
    return nil unless normalized_value.match?(/\A\d+(?:\.\d+)?\z/)

    percentage = normalized_value.to_f
    percentage.between?(0, 100) ? percentage : nil
  end

  def truncated_percentage(numerator, denominator)
    return nil unless denominator.to_f.positive?

    (((numerator.to_f / denominator.to_f) * 100.0 * 100).floor / 100.0)
  end

  def average_review_percentage(values)
    values = values.compact
    return nil if values.empty?

    ((values.sum / values.size) * 100).floor / 100.0
  end

  def format_pli_percentage(value)
    return "-" if value.nil?

    format("%.2f", value.to_f)
  end

  def display_review_number(value)
    number = value.to_f
    number % 1 == 0 ? number.to_i.to_s : format("%.2f", number)
  end

  def can_act_as_l1?(employee_detail)
    code = current_user.employee_code.to_s.strip.downcase
    email = current_user.email.to_s.strip.downcase

    current_user.hod? ||
    code == employee_detail.l1_code.to_s.strip.downcase ||
    email == employee_detail.l1_employer_name.to_s.strip.downcase
  end

  def can_act_as_l2?(employee_detail)
    return false unless l2_reviewer_assigned?(employee_detail)
    code = current_user.employee_code.to_s.strip.downcase
    email = current_user.email.to_s.strip.downcase

    current_user.hod? ||
    code == employee_detail.l2_code.to_s.strip.downcase ||
    email == employee_detail.l2_employer_name.to_s.strip.downcase
  end

  def l2_reviewer_assigned?(employee_detail)
    false
  end

  def achievement_ready_for_quarterly_pli?(achievement, employee_detail)
    return false unless achievement&.achievement.present?

    remark = achievement.achievement_remark

    achievement.status == "l1_approved" ||
      achievement.status == "l2_approved" ||
      remark&.l1_percentage.present? ||
      remark&.l1_remarks.present?
  end

  def month_ready_for_quarterly_pli?(employee_detail, user_details, month, financial_year = nil)
    detail_achievements = submitted_target_achievements_for_pli_month(user_details, month)
    return false if detail_achievements.empty?
    review_financial_year = financial_year.presence || user_details.find { |detail| detail.financial_year.present? }&.financial_year
    return false unless observer_chain_approved_for_month?(employee_detail, review_financial_year, quarter_for_month(month), month)

    month_achievements = detail_achievements.map { |_detail, achievement| achievement }
    statuses = month_achievements.map { |achievement| achievement.status || "pending" }
    approval_level = "l1"
    required_status = required_quarterly_pli_status(employee_detail)
    calculated_status = calculate_month_status(statuses, month_achievements, approval_level)
    required_status == "l1_approved" ? %w[l1_approved l2_approved].include?(calculated_status) : calculated_status == required_status
  end

  def submitted_target_achievements_for_pli_month(user_details, month)
    user_details.filter_map do |detail|
      next unless target_present_for_review_month?(detail, month)

      achievement = detail.achievements.find do |record|
        record.month.to_s.downcase == month && record.achievement.present?
      end
      next unless achievement.present?

      [ detail, achievement ]
    end
  end

  def required_quarterly_pli_status(employee_detail)
    "l1_approved"
  end

  def quarter_approved_for_pli?(employee_detail, financial_year, quarter)
    quarter_months = get_quarter_months(quarter)
    return false if quarter_months.empty?

    user_details = employee_detail.user_details.select do |detail|
      detail.financial_year.to_s == financial_year.to_s && detail.activity.present?
    end
    return false if user_details.empty?

    reviewable_months = quarter_months.select do |month|
      submitted_target_achievements_for_pli_month(user_details, month).any?
    end
    return false if reviewable_months.empty?

    reviewable_months.all? do |month|
      month_ready_for_quarterly_pli?(employee_detail, user_details, month, financial_year)
    end
  end

  def quarterly_pli_review_complete_message(employee_detail)
    assigned_levels = observer_levels_for(employee_detail)
    if assigned_levels.any?
      labels = assigned_levels.map { |level| observer_menu_title(level) }.join(", ")
      return "Quarter is not ready yet. Submitted months must be approved by #{labels} and L1 before Quarterly PLI."
    end

    "Quarter is not fully approved yet. Submitted months in the quarter must be L1-approved before Quarterly PLI."
  end

  def review_redirect_params
    {
      quarter: params[:selected_quarter].presence || params[:quarter],
      month: normalize_month_param(params[:selected_month] || params[:month]),
      financial_year: selected_financial_year
    }.compact
  end

  def selected_financial_year
    params[:financial_year].presence || params[:selected_financial_year].presence
  end

  def infer_review_financial_year(employee_detail, selected_month, selected_quarter)
    months = if selected_month.present?
               [ selected_month ]
             elsif selected_quarter.present?
               get_quarter_months(selected_quarter)
             else
               review_months
             end

    matching_years = employee_detail.user_details.includes(:achievements).filter_map do |detail|
      next if detail.financial_year.blank?

      has_matching_achievement = detail.achievements.any? do |achievement|
        months.include?(achievement.month.to_s.downcase) && achievement.achievement.present?
      end

      detail.financial_year if has_matching_achievement
    end

    matching_years = employee_detail.user_details.filter_map(&:financial_year) if matching_years.empty?
    matching_years.compact.reject(&:blank?).uniq.sort.reverse.first
  end

  def get_quarter_months(quarter)
    case quarter
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

  def get_all_quarters
    [ "Q1", "Q2", "Q3", "Q4" ]
  end

  def review_months
    %w[april may june july august september october november december january february march]
  end

  def normalize_month_param(month)
    normalized_month = month.to_s.downcase.strip
    review_months.include?(normalized_month) ? normalized_month : nil
  end

  def quarter_for_month(month)
    return nil if month.blank?

    get_all_quarters.find { |quarter| get_quarter_months(quarter).include?(month) }
  end

  def month_label(month)
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

  def prepare_review_filters(employee_details)
    @month_options = review_months.map { |month| [ month_label(month), month ] }
    @selected_review_month = normalize_month_param(params[:month])
    @selected_financial_year = selected_financial_year || current_financial_year
    @financial_year_options = employee_details.flat_map { |employee|
      employee.user_details.map(&:financial_year)
    }.compact.reject(&:blank?).uniq.sort.reverse
    @financial_year_options |= [ @selected_financial_year ]
    @financial_year_options.compact!
    @financial_year_options.sort!.reverse!
  end

  def review_user_details_for(employee_detail)
    details = employee_detail.user_details.includes(:achievements)
    selected_financial_year.present? ? details.where(financial_year: selected_financial_year) : details
  end

  def bounded_review_text(value)
    value.to_s.strip.first(500)
  end

  def manager_remark_for(user_detail_id, month)
    remarks = params[:manager_remarks]
    return nil unless remarks.respond_to?(:[])

    detail_remarks = remarks[user_detail_id.to_s]
    return nil unless detail_remarks.respond_to?(:[])

    detail_remarks[month.to_s].to_s.strip.presence
  end

  def observer_remark_for(user_detail_id, month)
    remarks = params[:observer_remarks]
    return nil unless remarks.respond_to?(:[])

    detail_remarks = remarks[user_detail_id.to_s]
    return nil unless detail_remarks.respond_to?(:[])

    detail_remarks[month.to_s].to_s.strip.presence
  end

  def observer_remark_column_for(observer_level)
    "#{observer_level}_remarks".to_sym
  end

  def observer_employee_name_for(employee_detail, observer_level)
    code = employee_detail.public_send(observer_level).to_s.strip
    return nil if code.blank?

    EmployeeDetail.find_by(employee_code: code)&.employee_name
  end

  def observer_activity_remarks_present?(employee_detail, month, observer_level)
    employee_detail.user_details.any? do |detail|
      observer_remark_for(detail.id, month).present?
    end
  end

  def save_observer_activity_remarks(employee_detail, month, observer_level)
    remark_column = observer_remark_column_for(observer_level)

    employee_detail.user_details.each do |detail|
      remark_text = observer_remark_for(detail.id, month)
      next unless remark_text.present?

      achievement = detail.achievements.find { |record| record.month.to_s.downcase == month.to_s.downcase } ||
                    detail.achievements.build(month: month.to_s, status: "pending")
      achievement.status ||= "pending"
      achievement.save! if achievement.new_record? || achievement.changed?

      remark = achievement.achievement_remark || achievement.build_achievement_remark
      remark.public_send("#{remark_column}=", bounded_review_text(remark_text))
      remark.save!
    end
  end

  def save_l1_manager_remark_without_achievement(detail, month)
    manager_remark = manager_remark_for(detail.id, month)
    return unless manager_remark.present?

    achievement = detail.achievements.find { |record| record.month == month.to_s } ||
                  detail.achievements.build(month: month.to_s, status: "pending")
    achievement.status ||= "pending"
    achievement.save! if achievement.new_record? || achievement.changed?

    remark = achievement.achievement_remark || achievement.build_achievement_remark
    remark.reporting_manager_remarks = bounded_review_text(manager_remark)
    remark.save!
  end

  def selected_review_months
    selected_month = normalize_month_param(params[:selected_month] || params[:month])
    return [ selected_month ] if selected_month.present?

    params[:selected_quarter].present? ? get_quarter_months(params[:selected_quarter]) : []
  end

  def build_monthly_employee_data(employee_details, approval_level:, month: nil, financial_year: nil)
    monthly_employee_data = {}
    months_to_review = month.present? ? [ month ] : review_months

    employee_details.each do |emp|
      next if approval_level == "l2" && !l2_reviewer_assigned?(emp)

      detail_groups = if financial_year.present?
                        { financial_year => emp.user_details.select { |detail| detail.financial_year == financial_year } }
                      else
                        emp.user_details.group_by { |detail| detail.financial_year.presence || "No Financial Year" }
                      end

      detail_groups.each do |group_financial_year, details_for_review|
        achievements_by_detail_and_month = details_for_review.each_with_object({}) do |detail, lookup|
          lookup[detail.id] = detail.achievements
                             .select { |achievement| achievement.achievement.present? }
                             .group_by { |achievement| achievement.month.to_s.downcase }
        end

        months_to_review.each do |review_month|
          details_with_month_data = details_for_review.select do |detail|
            target_present_for_review_month?(detail, review_month) &&
              achievements_by_detail_and_month.dig(detail.id, review_month).present?
          end
          month_achievements = details_with_month_data.flat_map do |detail|
            achievements_by_detail_and_month.dig(detail.id, review_month) || []
          end.select do |achievement|

            if approval_level == "l2"
              [ "l1_approved", "l2_approved", "l2_returned" ].include?(achievement.status)
            else
              true
            end
          end
          next if (approval_level == "l2" ? month_achievements.empty? : details_with_month_data.empty?)

          statuses = month_achievements.map { |achievement| achievement.status || "pending" }
          current_status = calculate_month_status(statuses, month_achievements, approval_level)
          progress_values = details_with_month_data.filter_map do |detail|
            target_number = numeric_review_value(detail.public_send(review_month))
            next unless target_number.positive?

            achievement = (achievements_by_detail_and_month.dig(detail.id, review_month) || []).find { |record| record.achievement.present? }
            next unless achievement

            truncated_percentage(numeric_review_value(achievement.achievement), target_number)
          end
          progress_value = average_review_percentage(progress_values)
          key = [ emp.id, review_month, group_financial_year ].join("_")

          monthly_employee_data[key] = {
            employee: emp,
            month: review_month,
            month_label: month_label(review_month),
            quarter_name: quarter_for_month(review_month),
            financial_year: group_financial_year == "No Financial Year" ? nil : group_financial_year,
            status: current_status,
            status_config: approval_level == "l2" ? get_l2_status_config(current_status) : get_status_config(current_status),
            achievements_count: month_achievements.size,
            progress_value: progress_value,
            progress: format_pli_percentage(progress_value)
          }
        end
      end
    end

    monthly_employee_data.sort_by do |_key, data|
      review_pending_rank =
        if approval_level == "l2"
          data[:status] == "l1_approved" ? 0 : 1
        else
          data[:status] == "pending" ? 0 : 1
        end

      [
        review_pending_rank,
        data[:employee]&.employee_name.to_s.downcase,
        data[:month].to_s,
        data[:financial_year].to_s
      ]
    end.to_h
  end

  def submitted_review_detail_for_month?(detail, month)
    return false unless target_present_for_review_month?(detail, month)

    detail.achievements.any? do |achievement|
      achievement.month == month && achievement.achievement.present?
    end
  end

  def target_present_for_review_month?(detail, month)
    return false unless detail.respond_to?(month)

    target_value = normalize_import_display_value(detail.public_send(month))
    target_text = target_value.to_s.delete(",").strip
    target_is_numeric = target_text.match?(/\A-?\d+(?:\.\d+)?\z/)
    target_value.present? && (!target_is_numeric || target_text.to_f.positive?)
  end

  def calculate_month_status(statuses, achievements, approval_level = "l1")
    return "pending" if statuses.empty?

    has_l1_approval = achievements.any? { |achievement| achievement.achievement_remark&.l1_percentage.present? || achievement.achievement_remark&.l1_remarks.present? }
    has_l2_approval = achievements.any? { |achievement| achievement.achievement_remark&.l2_percentage.present? || achievement.achievement_remark&.l2_remarks.present? }

    if statuses.any? { |status| status == "l2_returned" }
      "l2_returned"
    elsif statuses.all? { |status| status == "l2_approved" } || has_l2_approval
      "l2_approved"
    elsif statuses.any? { |status| status == "l1_returned" }
      "l1_returned"
    elsif statuses.all? { |status| status == "l1_approved" } || has_l1_approval
      "l1_approved"
    elsif approval_level == "l2"
      "l1_approved"
    else
      "pending"
    end
  end

  # Group employees by quarters based on their activities (FIXED to show ALL activities)
  def group_employees_by_quarters(employee_details)
    quarterly_data = {}

    get_all_quarters.each do |quarter|
      quarterly_data[quarter] = {
        employees: [],
        total_activities: 0,
        pending_activities: 0,
        approved_activities: 0,
        quarter_months: get_quarter_months(quarter)
      }
    end

    employee_details.each do |employee|
      get_all_quarters.each do |quarter|
        quarter_months = get_quarter_months(quarter)

        # FIXED: Get ALL activities for this quarter, not just those with achievements
        quarter_activities = employee.user_details
                                    .where(activity_id: Activity.joins(:department)
                                                               .where(departments: { department_type: employee.department })
                                                               .select(:id))

        if quarter_activities.any?
          employee_quarter_data = {
            employee: employee,
            activities: [],
            total_count: 0,
            pending_count: 0,
            approved_count: 0,
            overall_status: "pending"
          }

          # PERFORMANCE FIX: Preload achievements to avoid N+1 queries
          quarter_activities.includes(:achievements, :activity, :department).each do |user_detail|
            # PERFORMANCE FIX: Create a hash of achievements by month for fast lookup
            achievements_by_month = user_detail.achievements.index_by(&:month)

            # Check each month in the quarter for targets
            quarter_months.each do |month|
              target_value = get_target_for_month(user_detail, month)
              achievement = achievements_by_month[month]
              next unless achievement&.achievement.present?

              # PERFORMANCE FIX: Use in-memory hash lookup instead of database query

              activity_data = {
                user_detail: user_detail,
                achievement: achievement,
                month: month,
                activity_name: user_detail.activity&.activity_name,
                department: user_detail.department&.department_type,
                target: target_value,
                achievement_value: achievement&.achievement || "",
                status: achievement&.status || "pending",
                has_target: target_value.present? && target_value.to_s != "0"
              }

              employee_quarter_data[:activities] << activity_data
              employee_quarter_data[:total_count] += 1

              case achievement&.status
              when "l1_approved", "l2_approved"
                employee_quarter_data[:approved_count] += 1
              else
                employee_quarter_data[:pending_count] += 1
              end
            end
          end

          # Determine overall status for this employee in this quarter
          if employee_quarter_data[:approved_count] == employee_quarter_data[:total_count] && employee_quarter_data[:total_count] > 0
            employee_quarter_data[:overall_status] = "approved"
          elsif employee_quarter_data[:pending_count] > 0
            employee_quarter_data[:overall_status] = "pending"
          end

          quarterly_data[quarter][:employees] << employee_quarter_data
          quarterly_data[quarter][:total_activities] += employee_quarter_data[:total_count]
          quarterly_data[quarter][:pending_activities] += employee_quarter_data[:pending_count]
          quarterly_data[quarter][:approved_activities] += employee_quarter_data[:approved_count]
        end
      end
    end

    quarterly_data
  end

  # Get quarterly activities for a specific quarter
  def get_quarterly_activities(user_details, quarter)
    # Use the new comprehensive method
    get_all_activities_for_quarter(user_details, quarter)
  end

  # Get all quarterly activities grouped by quarter - FIXED to show ALL activities
  def get_all_quarterly_activities(user_details)
    all_activities = {}

    get_all_quarters.each do |quarter|
      all_activities[quarter] = get_quarterly_activities(user_details, quarter)
    end

    all_activities
  end

  # NEW: Get all activities for a specific quarter (including those without achievements)
  def get_all_activities_for_quarter(user_details, quarter)
    quarter_months = get_quarter_months(quarter)
    activities = []

    user_details.each do |user_detail|
      # PERFORMANCE FIX: Create a hash of achievements by month for fast lookup
      achievements_by_month = user_detail.achievements.index_by(&:month)

      quarter_months.each do |month|
        # Check if there's a target for this month
        target_value = get_target_for_month(user_detail, month)
        achievement = achievements_by_month[month]
        next unless achievement&.achievement.present?

        # PERFORMANCE FIX: Use in-memory hash lookup instead of database query

        # Create activity data regardless of whether achievement exists
        activity_data = {
          user_detail: user_detail,
          achievement: achievement,
          month: month,
          activity_name: user_detail.activity&.activity_name,
          department: user_detail.department&.department_type,
          target: target_value,
          achievement_value: achievement&.achievement || "",
          status: achievement&.status || "pending",
          employee_remarks: achievement&.employee_remarks || "",
          has_target: target_value.present? && target_value.to_s != "0",
          can_approve: can_approve_activity?(achievement),
          can_return: can_return_activity?(achievement)
        }

        activities << activity_data
      end
    end

    activities.sort_by { |a| [ a[:month], a[:activity_name] ] }
  end

  # Helper method to check if an activity can be approved
  def can_approve_activity?(achievement)
    return false unless achievement
    [ "pending", "l1_returned", "l2_returned" ].include?(achievement.status)
  end

  # Helper method to check if an activity can be returned
  def can_return_activity?(achievement)
    return false unless achievement
    [ "pending", "l1_approved", "l2_approved" ].include?(achievement.status)
  end

  # Helper method to get overall quarter status
  def get_quarter_overall_status(activities)
    return "no_data" if activities.empty?

    statuses = activities.map { |a| a[:status] }

    # FIXED: L2 statuses should take highest priority
    # If ANY activity has L2 approved, the quarter is L2 approved
    if statuses.include?("l2_approved")
      "l2_approved"
    # If ANY activity has L2 returned, the quarter is L2 returned
    elsif statuses.include?("l2_returned")
      "l2_returned"
    # If ALL activities are L1 approved, the quarter is L1 approved
    elsif statuses.all? { |s| [ "l1_approved" ].include?(s) }
      "l1_approved"
    # If ANY activity has L1 returned, the quarter is L1 returned
    elsif statuses.any? { |s| [ "l1_returned" ].include?(s) }
      "l1_returned"
    # If ANY activity has submitted status, the quarter is submitted
    elsif statuses.any? { |s| [ "submitted" ].include?(s) }
      "submitted"
    else
      "pending"
    end
  end

  # Get all activities that can be approved/returned for a specific quarter
  def get_approvable_activities_for_quarter(user_details, quarter, approval_level = "l1")
    quarter_months = get_quarter_months(quarter)
    approvable_activities = []

    user_details.each do |user_detail|
      # PERFORMANCE FIX: Create a hash of achievements by month for fast lookup
      achievements_by_month = user_detail.achievements.index_by(&:month)

      quarter_months.each do |month|
        # Check if there's a target for this month
        target_value = get_target_for_month(user_detail, month)
        achievement = achievements_by_month[month]
        next unless achievement&.achievement.present?

        # PERFORMANCE FIX: Use in-memory hash lookup instead of database query

        # Check if this activity can be approved/returned at the specified level
        can_act = case approval_level
        when "l1"
          can_approve_activity?(achievement) || can_return_activity?(achievement)
        when "l2"
          achievement && [ "l1_approved", "l2_returned" ].include?(achievement.status)
        else
          false
        end

        next unless can_act

        approvable_activities << {
          user_detail: user_detail,
          achievement: achievement,
          month: month,
          activity_name: user_detail.activity&.activity_name,
          department: user_detail.department&.department_type,
          target: target_value,
          achievement_value: achievement&.achievement || "",
          status: achievement&.status || "pending",
          employee_remarks: achievement&.employee_remarks || "",
          can_approve: can_approve_activity?(achievement),
          can_return: can_return_activity?(achievement)
        }
      end
    end

    approvable_activities.sort_by { |a| [ a[:month], a[:activity_name] ] }
  end

  # Get target value for a specific month
  def get_target_for_month(user_detail, month)
    return nil unless user_detail.respond_to?(month.to_sym)
    user_detail.send(month.to_sym)
  end

  def process_quarterly_l1_approval
    # Add authorization check here for AJAX requests
    unless can_act_as_l1?(@employee_detail)
      return { success: false, message: "❌ You are not authorized to perform L1 actions on this record" }
    end

    review_month = normalize_month_param(params[:selected_month] || params[:month])
    review_quarter = params[:selected_quarter].presence || params[:quarter].presence || quarter_for_month(review_month)
    review_financial_year = selected_financial_year.presence || infer_review_financial_year(@employee_detail, review_month, review_quarter)
    unless observer_chain_approved_for_selection?(@employee_detail, review_financial_year, review_quarter, review_month)
      return { success: false, message: "❌ #{observer_chain_pending_message(@employee_detail)}" }
    end

    approved_count = 0

    # Determine if this is an approval or return action
    action_type = params[:action_type] || "approve"
    is_approval = action_type.include?("approve")
    new_status = is_approval ? "l1_approved" : "l1_returned"
    review_months_for_action = selected_review_months

    if review_months_for_action.one?
      month = review_months_for_action.first

      review_user_details_for(@employee_detail).each do |detail|
        achievement = detail.achievements.find { |record| record.month == month }
        unless achievement&.achievement.present?
          save_l1_manager_remark_without_achievement(detail, month)
          next
        end

        achievement.update!(status: new_status)

        remark = achievement.achievement_remark || achievement.build_achievement_remark
        manager_remark = manager_remark_for(detail.id, month)
        remark.reporting_manager_remarks = bounded_review_text(manager_remark) if manager_remark.present?
        remark.l1_remarks = bounded_review_text(params[:remarks]) if params[:remarks].present?
        remark.l1_percentage = params[:percentage] if params[:percentage].present?
        remark.save!

        approved_count += 1
      end

      if approved_count > 0
        return { success: true, count: approved_count }
      end

      action_text = is_approval ? "approve" : "return"
      return { success: false, message: "❌ No #{month_label(month)} KRA found to #{action_text}" }
    end

    if params[:selected_quarter].present?
      # FIXED: Approve/Return specific quarter as a single unit
      quarter_months = get_quarter_months(params[:selected_quarter])

      review_user_details_for(@employee_detail).each do |detail|
        quarter_months.each do |month|
          achievement = detail.achievements.find { |record| record.month == month }
          save_l1_manager_remark_without_achievement(detail, month) unless achievement&.achievement.present?
        end

        # FIXED: Process the entire quarter as one unit, not month by month
        quarter_achievements = detail.achievements.select do |achievement|
          quarter_months.include?(achievement.month) && achievement.achievement.present?
        end

        # FIXED: Now process the entire quarter as one unit
        if quarter_achievements.any?

          # FIXED: Update ALL achievements in the quarter to the same status
          quarter_achievements.each do |achievement|
            old_status = achievement.status
            achievement.update!(status: new_status)

            # Create or update achievement remark with COMMON remarks for quarter
            remark = achievement.achievement_remark || achievement.build_achievement_remark
            manager_remark = manager_remark_for(detail.id, achievement.month)
            remark.reporting_manager_remarks = bounded_review_text(manager_remark) if manager_remark.present?
            remark.l1_remarks = bounded_review_text(params[:remarks]) if params[:remarks].present?
            remark.l1_percentage = params[:percentage] if params[:percentage].present?
            remark.save!

            approved_count += 1
          end

        else
          Rails.logger.warn "No achievements found for quarter #{params[:selected_quarter]} in activity #{detail.activity.activity_name}"
        end
      end
    else
      # Approve/Return all quarters
      review_user_details_for(@employee_detail).each do |detail|
        get_all_quarters.each do |quarter|
          quarter_months = get_quarter_months(quarter)
          quarter_months.each do |month|
            achievement = detail.achievements.find { |record| record.month == month }
            save_l1_manager_remark_without_achievement(detail, month) unless achievement&.achievement.present?
          end

          submitted_achievements = detail.achievements.select do |achievement|
            quarter_months.include?(achievement.month) && achievement.achievement.present?
          end

          submitted_achievements.each do |achievement|
            # Update achievement status
            achievement.update!(status: new_status)

            remark = achievement.achievement_remark || achievement.build_achievement_remark
            manager_remark = manager_remark_for(detail.id, achievement.month)
            remark.reporting_manager_remarks = bounded_review_text(manager_remark) if manager_remark.present?
            remark.l1_remarks = bounded_review_text(params[:remarks]) if params[:remarks].present?
            remark.l1_percentage = params[:percentage] if params[:percentage].present?
            remark.save!

            approved_count += 1
          end
        end
      end
    end

    if approved_count > 0
      { success: true, count: approved_count }
    else
      action_text = is_approval ? "approve" : "return"
      { success: false, message: "❌ No activities found to #{action_text} for the selected quarter" }
    end
  end

# Process L1 quarterly return - FIXED
def process_quarterly_l1_return
  # This method now delegates to the approval method since it handles both approve and return
  process_quarterly_l1_approval
end

# Process L2 quarterly approval - FIXED
def process_quarterly_l2_approval
  # Add authorization check here for AJAX requests
  unless l2_reviewer_assigned?(@employee_detail)
    return { success: false, message: "❌ L2 reviewer is not assigned for this employee." }
  end

  unless current_user.hod? || can_act_as_l2?(@employee_detail)
    return { success: false, message: "❌ You are not authorized to perform L2 actions on this record" }
  end

  approved_count = 0

  # Determine if this is an approval or return action
  action_type = params[:action_type] || "approve"
  is_approval = action_type.include?("approve")
  new_status = is_approval ? "l2_approved" : "l2_returned"
  review_months_for_action = selected_review_months

  if review_months_for_action.one?
    month = review_months_for_action.first

    review_user_details_for(@employee_detail).each do |detail|
      achievement = detail.achievements.find { |record| record.month == month }
      next unless achievement&.achievement.present?

      eligible_statuses = is_approval ? [ "l1_approved", "l2_returned" ] : [ "l1_approved", "l2_approved" ]
      next unless eligible_statuses.include?(achievement.status)

      achievement.update!(status: new_status)

      remark = achievement.achievement_remark || achievement.build_achievement_remark
      month_level_l2_remark = manager_remark_for(detail.id, achievement.month)
      if month_level_l2_remark.present?
        remark.l2_remarks = bounded_review_text(month_level_l2_remark)
      elsif params[:l2_remarks].present? || params[:remarks].present?
        remark.l2_remarks = bounded_review_text(params[:l2_remarks].presence || params[:remarks])
      end
      remark.l2_percentage = params[:l2_percentage] || params[:percentage] if params[:l2_percentage].present? || params[:percentage].present?
      remark.save!

      approved_count += 1
    end

    if approved_count > 0
      return { success: true, count: approved_count }
    end

    action_text = is_approval ? "approve" : "return"
    return { success: false, message: "❌ No L1 approved #{month_label(month)} activities found to #{action_text}" }
  end

  if params[:selected_quarter].present?
    # FIXED: Approve/Return specific quarter as a single unit
    quarter_months = get_quarter_months(params[:selected_quarter])

    review_user_details_for(@employee_detail).each do |detail|
      # FIXED: Process the entire quarter as one unit, not month by month
      quarter_achievements = detail.achievements.select do |achievement|
        quarter_months.include?(achievement.month) && achievement.achievement.present?
      end

      # FIXED: Now process the entire quarter as one unit
      if quarter_achievements.any?

        # Update ALL achievements in the quarter to the same status
        quarter_achievements.each do |achievement|
          # For L2 return, we should be able to return L1 approved achievements
          # For L2 approve, we need L1 approved or L2 returned achievements
          if is_approval
            # For approval, check eligibility
            eligible_statuses = [ "l1_approved", "l2_returned" ]
            if eligible_statuses.include?(achievement.status)
              old_status = achievement.status
              achievement.update!(status: new_status)

              # Create or update achievement remark with COMMON remarks for quarter
              remark = achievement.achievement_remark || achievement.build_achievement_remark
              month_level_l2_remark = manager_remark_for(detail.id, achievement.month)
              if month_level_l2_remark.present?
                remark.l2_remarks = bounded_review_text(month_level_l2_remark)
              elsif params[:l2_remarks].present? || params[:remarks].present?
                remark.l2_remarks = bounded_review_text(params[:l2_remarks].presence || params[:remarks])
              end
              remark.l2_percentage = params[:l2_percentage] || params[:percentage] if params[:l2_percentage].present? || params[:percentage].present?
              remark.save!

              approved_count += 1
            else
            end
          else
            # For return, process ALL achievements regardless of current status
            old_status = achievement.status
            achievement.update!(status: new_status)

            # Create or update achievement remark with COMMON remarks for quarter
            remark = achievement.achievement_remark || achievement.build_achievement_remark
            month_level_l2_remark = manager_remark_for(detail.id, achievement.month)
            if month_level_l2_remark.present?
              remark.l2_remarks = bounded_review_text(month_level_l2_remark)
            elsif params[:l2_remarks].present? || params[:remarks].present?
              remark.l2_remarks = bounded_review_text(params[:l2_remarks].presence || params[:remarks])
            end
            remark.l2_percentage = params[:l2_percentage] || params[:percentage] if params[:l2_percentage].present? || params[:percentage].present?
            remark.save!

            approved_count += 1
          end
        end

      else
        Rails.logger.warn "No achievements found for quarter #{params[:selected_quarter]} in activity #{detail.activity.activity_name}"
      end
    end
  else
    # Approve/Return all quarters
    review_user_details_for(@employee_detail).each do |detail|
      get_all_quarters.each do |quarter|
        quarter_months = get_quarter_months(quarter)
        submitted_achievements = detail.achievements.select do |achievement|
          quarter_months.include?(achievement.month) && achievement.achievement.present?
        end

        submitted_achievements.each do |achievement|
          # For L2 return, we should be able to return L1 approved achievements
          # For L2 approve, we need L1 approved or L2 returned achievements
          eligible_statuses = is_approval ? [ "l1_approved", "l2_returned" ] : [ "l1_approved" ]

          if eligible_statuses.include?(achievement.status)
            # Update achievement status
            achievement.update!(status: new_status)

            remark = achievement.achievement_remark || achievement.build_achievement_remark
            month_level_l2_remark = manager_remark_for(detail.id, achievement.month)
            if month_level_l2_remark.present?
              remark.l2_remarks = bounded_review_text(month_level_l2_remark)
            elsif params[:l2_remarks].present? || params[:remarks].present?
              remark.l2_remarks = bounded_review_text(params[:l2_remarks].presence || params[:remarks])
            end
            remark.l2_percentage = params[:l2_percentage] || params[:percentage] if params[:l2_percentage].present? || params[:percentage].present?
            remark.save!

            approved_count += 1
          end
        end
      end
    end
  end

  if approved_count > 0
    { success: true, count: approved_count }
  else
    action_text = is_approval ? "approve" : "return"
    { success: false, message: "❌ No L1 approved activities found to #{action_text} for the selected quarter" }
  end
end

  # Process L2 quarterly return - FIXED
  def process_quarterly_l2_return
    # This method now delegates to the approval method since it handles both approve and return
    process_quarterly_l2_approval
  end


  # PERFORMANCE FIX: Pre-calculate summary data to avoid processing in view
  def calculate_summary_data(employee_details)
    summary_data = {
      total_quarterly_records: 0,
      l1_approved_count: 0,
      l2_approved_count: 0,
      pending_count: 0,
      returned_count: 0,
      submitted_count: 0,
      employee_quarter_statuses: {}
    }

    quarters = {
      "Q1" => [ "april", "may", "june" ],
      "Q2" => [ "july", "august", "september" ],
      "Q3" => [ "october", "november", "december" ],
      "Q4" => [ "january", "february", "march" ]
    }

    employee_details.each do |emp|
      quarters.each do |quarter_name, quarter_months|
        # PERFORMANCE FIX: Use preloaded associations instead of flat_map
        all_quarter_achievements = emp.user_details.flat_map(&:achievements).select { |ach| quarter_months.include?(ach.month) }

        next if all_quarter_achievements.empty?

        summary_data[:total_quarterly_records] += 1

        # PERFORMANCE FIX: Optimize status calculation
        quarter_statuses = all_quarter_achievements.map { |ach| ach.status || "pending" }

        # Check for actual approval data in achievement remarks
        has_l1_approval = all_quarter_achievements.any? { |ach| ach.achievement_remark&.l1_percentage.present? && ach.achievement_remark&.l1_remarks.present? }
        has_l2_approval = all_quarter_achievements.any? { |ach| ach.achievement_remark&.l2_percentage.present? && ach.achievement_remark&.l2_remarks.present? }

        # PERFORMANCE FIX: More efficient status calculation
        current_status = calculate_quarter_status(quarter_statuses, has_l1_approval, has_l2_approval)

        # Store status for this employee-quarter combination
        summary_data[:employee_quarter_statuses]["#{emp.id}_#{quarter_name}"] = current_status

        # Update counters
        case current_status
        when "l1_approved"
          summary_data[:l1_approved_count] += 1
        when "l2_approved"
          summary_data[:l2_approved_count] += 1
        when "l1_returned", "l2_returned"
          summary_data[:returned_count] += 1
        when "submitted"
          summary_data[:submitted_count] += 1
        else
          summary_data[:pending_count] += 1
        end
      end
    end

    summary_data
  end

  # PERFORMANCE FIX: Optimized status calculation method
  def calculate_quarter_status(quarter_statuses, has_l1_approval, has_l2_approval)
    if quarter_statuses.any? { |s| s == "l2_returned" }
      "l2_returned"
    elsif quarter_statuses.all? { |s| s == "l2_approved" } || has_l2_approval
      "l2_approved"
    elsif quarter_statuses.any? { |s| s == "l1_returned" }
      "l1_returned"
    elsif quarter_statuses.all? { |s| s == "l1_approved" } || has_l1_approval
      "l1_approved"
    elsif quarter_statuses.any? { |s| s == "submitted" }
      "submitted"
    else
      "pending"
    end
  end

  # Build the quarterly employee data structure expected by the view
  def build_quarterly_employee_data(employee_details)
    quarterly_employee_data = {}

    quarters = {
      "Q1" => [ "april", "may", "june" ],
      "Q2" => [ "july", "august", "september" ],
      "Q3" => [ "october", "november", "december" ],
      "Q4" => [ "january", "february", "march" ]
    }

    employee_details.each do |emp|
      quarters.each do |quarter_name, quarter_months|
        # Get all achievements for this employee in this quarter
        all_quarter_achievements = emp.user_details.flat_map(&:achievements).select { |ach| quarter_months.include?(ach.month) }

        # Only include if there are achievements in this quarter
        if all_quarter_achievements.any?
          # Calculate quarter status
          quarter_statuses = all_quarter_achievements.map { |ach| ach.status || "pending" }
          has_l1_approval = all_quarter_achievements.any? { |ach| ach.achievement_remark&.l1_percentage.present? && ach.achievement_remark&.l1_remarks.present? }
          has_l2_approval = all_quarter_achievements.any? { |ach| ach.achievement_remark&.l2_percentage.present? && ach.achievement_remark&.l2_remarks.present? }

          current_status = calculate_quarter_status(quarter_statuses, has_l1_approval, has_l2_approval)
          status_config = get_status_config(current_status)

          # Create unique key for this employee-quarter combination
          key = "#{emp.id}_#{quarter_name}"

          quarterly_employee_data[key] = {
            employee: emp,
            quarter_name: quarter_name,
            quarter_months: quarter_months,
            status: current_status,
            status_config: status_config
          }
        end
      end
    end

    quarterly_employee_data
  end

  # Get status configuration for display
  def get_status_config(status)
    case status
    when "l1_approved"
      { color: "bg-green-100 text-green-800 border-green-300", text: "L1 Approved", icon: "fas fa-check-circle" }
    when "l2_approved"
      { color: "bg-green-600 text-white border-green-700", text: "L2 Approved", icon: "fas fa-check-double" }
    when "l1_returned"
      { color: "bg-red-100 text-red-800 border-red-300", text: "L1 Returned", icon: "fas fa-exclamation-triangle" }
    when "l2_returned"
      { color: "bg-orange-100 text-orange-800 border-orange-300", text: "L2 Returned", icon: "fas fa-exclamation-triangle" }
    when "submitted"
      { color: "bg-blue-100 text-blue-800 border-blue-300", text: "Submitted", icon: "fas fa-paper-plane" }
    else
      { color: "bg-yellow-100 text-yellow-800 border-yellow-300", text: "Pending", icon: "fas fa-clock" }
    end
  end

  def get_l2_status_config(status)
    return { color: "bg-yellow-100 text-yellow-800 border-yellow-300", text: "Pending L2", icon: "fas fa-clock" } if status == "l1_approved"

    get_status_config(status)
  end

  # Process L1 edit - update L1 remarks and percentage for a quarter
  def process_l1_edit
    updated_count = 0

    if params[:selected_quarter].present?
      # Update specific quarter
      quarter_months = get_quarter_months(params[:selected_quarter])

      review_user_details_for(@employee_detail).each do |detail|
        quarter_months.each do |month|
          # Find or create achievement for this month
          achievement = detail.achievements.find_or_create_by(month: month)
          achievement.save! if achievement.new_record?

          # Create or update achievement remark with L1 data
          remark = achievement.achievement_remark || achievement.build_achievement_remark
          remark.l1_remarks = bounded_review_text(params[:l1_remarks]) if params[:l1_remarks].present?
          remark.l1_percentage = params[:l1_percentage] if params[:l1_percentage].present?
          remark.save!

          updated_count += 1
        end
      end
    else
      # Update all quarters
      review_user_details_for(@employee_detail).each do |detail|
        get_all_quarters.each do |quarter|
          quarter_months = get_quarter_months(quarter)

          quarter_months.each do |month|
            # Find or create achievement for this month
            achievement = detail.achievements.find_or_create_by(month: month)
            achievement.save! if achievement.new_record?

            # Create or update achievement remark with L1 data
            remark = achievement.achievement_remark || achievement.build_achievement_remark
            remark.l1_remarks = bounded_review_text(params[:l1_remarks]) if params[:l1_remarks].present?
            remark.l1_percentage = params[:l1_percentage] if params[:l1_percentage].present?
            remark.save!

            updated_count += 1
          end
        end
      end
    end

    if updated_count > 0
      { success: true, count: updated_count, percentage: params[:l1_percentage], remarks: params[:l1_remarks] }
    else
      { success: false, message: "❌ No activities found to update for the selected quarter" }
    end
  end

  # Process L2 edit - update L2 remarks and percentage for a quarter
  def process_l2_edit
    updated_count = 0

    if params[:selected_quarter].present?
      # Update specific quarter
      quarter_months = get_quarter_months(params[:selected_quarter])

      review_user_details_for(@employee_detail).each do |detail|
        quarter_months.each do |month|
          # Find or create achievement for this month
          achievement = detail.achievements.find_or_create_by(month: month)
          achievement.save! if achievement.new_record?

          # Create or update achievement remark with L2 data
          remark = achievement.achievement_remark || achievement.build_achievement_remark
          remark.l2_remarks = bounded_review_text(params[:l2_remarks]) if params[:l2_remarks].present?
          remark.l2_percentage = params[:l2_percentage] if params[:l2_percentage].present?
          remark.save!

          updated_count += 1
        end
      end
    else
      # Update all quarters
      review_user_details_for(@employee_detail).each do |detail|
        get_all_quarters.each do |quarter|
          quarter_months = get_quarter_months(quarter)

          quarter_months.each do |month|
            # Find or create achievement for this month
            achievement = detail.achievements.find_or_create_by(month: month)
            achievement.save! if achievement.new_record?

            # Create or update achievement remark with L2 data
            remark = achievement.achievement_remark || achievement.build_achievement_remark
            remark.l2_remarks = bounded_review_text(params[:l2_remarks]) if params[:l2_remarks].present?
            remark.l2_percentage = params[:l2_percentage] if params[:l2_percentage].present?
            remark.save!

            updated_count += 1
          end
        end
      end
    end

    if updated_count > 0
      { success: true, count: updated_count, percentage: params[:l2_percentage], remarks: params[:l2_remarks] }
    else
      { success: false, message: "❌ No activities found to update for the selected quarter" }
    end
  end
end
