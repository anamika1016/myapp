module ApplicationHelper
  OBSERVER_LEVELS = %w[obs_code1 obs_code2 obs_code3 obs_code4].freeze
  SPREADSHEET_ERROR_VALUES = %w[#DIV/0! #N/A #NAME? #NULL! #NUM! #REF! #VALUE!].freeze
  MONTH_SHORT_LABELS = {
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
  }.freeze

  def current_user_detail
    current_user&.user_detail
  end

  def asset_to_base64(asset_name)
    path = Rails.root.join("app", "assets", "images", asset_name)
    if File.exist?(path)
      content = File.binread(path)
      ext = File.extname(asset_name).downcase.delete(".")
      mime_type = case ext
      when "jpg", "jpeg" then "image/jpeg"
      when "png" then "image/png"
      else "image/#{ext}"
      end
      "data:#{mime_type};base64,#{Base64.strict_encode64(content)}"
    else
      Rails.logger.error "ASSET NOT FOUND: #{path}"
      ""
    end
  end

  def annual_target_fy_label(financial_year)
    year = financial_year.to_s.presence
    start_year, end_year = year.to_s.split("-", 2)

    if start_year.present? && end_year.present?
      "Annual target FY #{start_year}-#{end_year.last(2)}"
    else
      "Annual target FY"
    end
  end

  def short_month_label(month)
    MONTH_SHORT_LABELS[month.to_s.downcase] || month.to_s.upcase
  end

  def annual_target_display(activity_or_value, unit = nil)
    value = if activity_or_value.respond_to?(:annual_target_fy)
      unit ||= activity_or_value.respond_to?(:unit) ? activity_or_value.unit : nil
      activity_or_value.annual_target_fy
    else
      activity_or_value
    end

    cleaned_value = clean_spreadsheet_display_value(value)
    return "-" if cleaned_value.blank?

    if unit.to_s.strip == "%" && cleaned_value.match?(/\A1(?:\.0+)?\z/)
      return "100%"
    end

    cleaned_value.sub(/\A(-?\d+)\.0+\z/, "\\1")
  end

  def clean_spreadsheet_display_value(value)
    return nil if value.nil?

    cleaned_value = value.to_s.strip
    return nil if cleaned_value.blank?
    return nil if SPREADSHEET_ERROR_VALUES.include?(cleaned_value.upcase)

    cleaned_value
  end

  def target_display_value(value)
    clean_spreadsheet_display_value(value).presence || "-"
  end

  def target_value_present?(value)
    cleaned_value = clean_spreadsheet_display_value(value)
    cleaned_value.present? && cleaned_value != "0"
  end

  def l2_reviewer_assigned?(employee_detail)
    false
  end

  def observer_assigned?(employee_detail, observer_level)
    return false if employee_detail.blank?
    return false unless OBSERVER_LEVELS.include?(observer_level.to_s)

    employee_detail.public_send(observer_level).to_s.strip.present?
  end

  def observer_level_number(observer_level)
    observer_level.to_s.gsub(/\D/, "").to_i
  end

  def observer_column_label(observer_level)
    "OBS#{observer_level_number(observer_level)}"
  end

  def observer_menu_title_for(observer_level)
    "Observer Menu #{observer_level_number(observer_level)}"
  end

  def observer_remark_column(observer_level)
    "#{observer_level}_remarks".to_sym
  end

  def observer_levels_for_display(employee_detail)
    assigned_levels = OBSERVER_LEVELS.select { |level| observer_assigned?(employee_detail, level) }

    if defined?(@observer_context) && @observer_context && @observer_level.present?
      assigned_levels & [ @observer_level ]
    else
      assigned_levels
    end
  end

  def observer_assigned_for_display?(employee_detail, observer_level)
    observer_assigned?(employee_detail, observer_level)
  end

  def portal_employee_detail_for(user = current_user)
    return if user.blank?

    user.employee_detail ||
      EmployeeDetail.find_by("LOWER(employee_email) = ?", user.email.to_s.downcase) ||
      EmployeeDetail.find_by("LOWER(employee_code) = ?", user.employee_code.to_s.downcase)
  end

  def resolved_observer_identity_code(user = current_user)
    return nil if user.blank?

    code = user.employee_code.to_s.strip.presence
    code ||= portal_employee_detail_for(user)&.employee_code.to_s.strip.presence
    code
  end

  def observer_level_assigned_to_user?(observer_level, user = current_user)
    return false if user.blank?
    return true if user.admin? || user.hod?
    return false unless OBSERVER_LEVELS.include?(observer_level.to_s)

    code = resolved_observer_identity_code(user)
    return false if code.blank?

    EmployeeDetail.where(
      "LOWER(TRIM(COALESCE(#{observer_level}, ''))) = ?",
      code.downcase
    ).exists?
  end

  def observer_levels_for_user(user = current_user)
    return [] if user.blank?
    return OBSERVER_LEVELS if user.admin? || user.hod?

    OBSERVER_LEVELS.select { |level| observer_level_assigned_to_user?(level, user) }
  end

  def observer_levels_for_current_user
    observer_levels_for_user(current_user)
  end

  def has_observer_pli_responsibilities?(observer_level = nil)
    return observer_levels_for_user(current_user).any? if observer_level.blank?

    observer_level_assigned_to_user?(observer_level, current_user)
  end

  def observer_menu_active?(observer_level)
    return true if current_page?(observer_pli_index_path(observer_level))
    return false unless controller_name == "employee_details"

    case action_name
    when "observer_1", "observer_2", "observer_3", "observer_4"
      OBSERVER_LEVELS[action_name.gsub(/\D/, "").to_i - 1] == observer_level
    when "observer_pli_detail"
      params[:observer_level].to_s == observer_level
    else
      false
    end
  end

  def observer_employee_name_for(employee_detail, observer_level)
    code = employee_detail.public_send(observer_level).to_s.strip
    return nil if code.blank?

    EmployeeDetail.where("LOWER(employee_code) = ?", code.downcase).pick(:employee_name)
  end

  def observer_pli_index_path(observer_level, **options)
    case observer_level.to_s
    when "obs_code2" then observer_2_employee_details_path(options)
    when "obs_code3" then observer_3_employee_details_path(options)
    when "obs_code4" then observer_4_employee_details_path(options)
    else observer_1_employee_details_path(options)
    end
  end

  def observer_pending_reviews?(observer_level)
    observer_pending_reviews_count(observer_level).positive?
  end

  def observer_pending_reviews_count(observer_level)
    return 0 unless observer_level_assigned_to_user?(observer_level, current_user)

    employees = observer_employees_for_pending_count(observer_level)
    return 0 if employees.none?

    employee_ids = employees.map(&:id)
    approved_keys = ObserverPliReview
      .where(employee_detail_id: employee_ids, observer_level: observer_level, status: "approved")
      .pluck(:employee_detail_id, :financial_year, :quarter, :month)
      .to_set

    pending_keys = Set.new
    employees.each do |employee|
      financial_years = employee.user_details.map(&:financial_year).compact.uniq
      financial_years.each do |financial_year|
        details = employee.user_details.select { |detail| detail.financial_year == financial_year }
        details.flat_map(&:achievements).each do |achievement|
          next if achievement.achievement.blank?

          month = achievement.month.to_s.downcase
          quarter = quarter_name_for_month(month)
          next if quarter.blank?
          next unless observer_month_ready_for_review?(employee, observer_level, details, month)

          key = [ employee.id, financial_year, quarter, month ]
          pending_keys.add(key) unless approved_keys.include?(key)
        end
      end
    end

    pending_keys.size
  rescue StandardError
    0
  end

  def observer_employees_for_pending_count(observer_level)
    scope = EmployeeDetail.order(Arel.sql("LOWER(employee_name) ASC"))
    scope = scope.where("TRIM(COALESCE(#{observer_level}, '')) != ''")

    if current_user.admin? || current_user.hod?
      scope.includes(user_details: :achievements).to_a
    else
      code = resolved_observer_identity_code(current_user)
      return [] if code.blank?

      scope.where(
        "LOWER(TRIM(COALESCE(#{observer_level}, ''))) = ?",
        code.downcase
      ).includes(user_details: :achievements).to_a
    end
  end

  def observer_month_ready_for_review?(employee_detail, observer_level, user_details, month)
    return false unless observer_assigned?(employee_detail, observer_level)

    submitted_target_achievements_for_month(user_details, month).any?
  end

  def quarter_name_for_month(month)
    {
      "april" => "Q1", "may" => "Q1", "june" => "Q1",
      "july" => "Q2", "august" => "Q2", "september" => "Q2",
      "october" => "Q3", "november" => "Q3", "december" => "Q3",
      "january" => "Q4", "february" => "Q4", "march" => "Q4"
    }[month.to_s.downcase]
  end

  def submitted_target_achievements_for_month(user_details, month)
    user_details.flat_map(&:achievements).select do |achievement|
      achievement.month.to_s.downcase == month.to_s.downcase && achievement.achievement.present?
    end
  end

  def manager_remarks_column_label(level, _month_name = nil)
    "#{level} RM"
  end

  def employee_remarks_column_label(_month = nil)
    "EMP REMARKS"
  end
end
