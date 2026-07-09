# app/helpers/user_details_helper.rb
module UserDetailsHelper
  def status_badge_config(status)
    case status
    when "pending"
      { color: "bg-yellow-100 text-yellow-800", text: "Pending", icon: "fas fa-clock" }
    when "l1_approved"
      { color: "bg-green-100 text-green-800", text: "L1 Approved", icon: "fas fa-check-circle" }
    when "l1_returned"
      { color: "bg-red-100 text-red-800", text: "L1 Returned", icon: "fas fa-exclamation-triangle" }
    when "l2_approved"
      { color: "bg-emerald-100 text-emerald-800", text: "L2 Approved", icon: "fas fa-check-double" }
    when "l2_returned"
      { color: "bg-orange-100 text-orange-800", text: "L2 Returned", icon: "fas fa-exclamation-triangle" }
    when "submitted"
      { color: "bg-blue-100 text-blue-800", text: "Submitted", icon: "fas fa-paper-plane" }
    else
      { color: "bg-gray-100 text-gray-600", text: "No Status", icon: "fas fa-question-circle" }
    end
  end

  def achievement_percentage_class(percentage)
    if percentage >= 100
      "bg-green-100 text-green-800"
    elsif percentage >= 75
      "bg-blue-100 text-blue-800"
    elsif percentage >= 50
      "bg-yellow-100 text-yellow-800"
    else
      "bg-red-100 text-red-800"
    end
  end

  def quarter_background_class(quarter)
    case quarter
    when "Q1"
      "bg-orange-50"
    when "Q2"
      "bg-purple-50"
    when "Q3"
      "bg-blue-50"
    when "Q4"
      "bg-green-50"
    else
      "bg-gray-50"
    end
  end

  def quarter_header_class(quarter)
    case quarter
    when "Q1"
      "bg-orange-700"
    when "Q2"
      "bg-purple-700"
    when "Q3"
      "bg-blue-700"
    when "Q4"
      "bg-green-700"
    else
      "bg-gray-700"
    end
  end

  def format_achievement_value(value)
    return "-" if value.blank?

    # Format numbers with appropriate precision
    if value.is_a?(Numeric)
      value % 1 == 0 ? value.to_i.to_s : value.round(2).to_s
    else
      value.to_s
    end
  end

  def calculate_quarter_status(months, existing_achievements)
    statuses = months.map { |month| existing_achievements[month]&.status }.compact

    # FIXED: L2 statuses should take highest priority
    # If ANY month has L2 approved, the quarter is L2 approved
    if statuses.include?("l2_approved")
      return "l2_approved"
    end

    # If ANY month has L2 returned, the quarter is L2 returned
    if statuses.include?("l2_returned")
      return "l2_returned"
    end

    # If ALL months are L1 approved, the quarter is L1 approved
    if statuses.all? { |s| s == "l1_approved" }
      return "l1_approved"
    end

    # If ANY month has L1 returned, the quarter is L1 returned
    if statuses.include?("l1_returned")
      return "l1_returned"
    end

    # If ANY month has submitted status, the quarter is submitted
    if statuses.include?("submitted")
      return "submitted"
    end

    # Default to pending
    "pending"
  end

  def quarter_summary(user_detail, months)
    existing_achievements = user_detail.achievements.index_by(&:month)

    rows = months.filter_map do |month|
      target = user_detail.send(month.to_sym).to_s.delete(",").to_f
      next unless target.positive?

      achievement = existing_achievements[month]&.achievement.to_s.delete(",").to_f
      ((achievement / target) * 100.0 * 100).floor / 100.0
    end

    targets = months.map { |month| user_detail.send(month.to_sym).to_f }.sum
    achievements = months.map { |month| existing_achievements[month]&.achievement.to_f || 0 }.sum
    percentage = rows.any? ? ((rows.sum / rows.size) * 100).floor / 100.0 : 0

    {
      total_target: targets,
      total_achievement: achievements,
      percentage: percentage,
      status: calculate_quarter_status(months, existing_achievements)
    }
  end

  def submitted_month_row_visible?(detail, month)
    return false if detail.blank? || month.blank?

    month_key = month.to_s.downcase
    target_value = clean_spreadsheet_display_value(detail.send(month_key.to_sym))
    achievement_record = detail.achievements.find { |record| record.month.to_s.downcase == month_key }

    target_value_present?(target_value) ||
      achievement_record&.achievement.present? ||
      achievement_record&.employee_remarks.present?
  end

  def submitted_month_review_summary(employee_detail, user_details, month, financial_year)
    return {} if employee_detail.blank? || month.blank? || financial_year.blank?

    quarter = {
      "april" => "Q1", "may" => "Q1", "june" => "Q1",
      "july" => "Q2", "august" => "Q2", "september" => "Q2",
      "october" => "Q3", "november" => "Q3", "december" => "Q3",
      "january" => "Q4", "february" => "Q4", "march" => "Q4"
    }[month.to_s.downcase]

    employee_details = user_details.select { |detail| detail.employee_detail_id == employee_detail.id }
    month_achievements = employee_details.flat_map(&:achievements).select do |achievement|
      achievement.month.to_s.downcase == month.to_s.downcase
    end

    latest_l1_remark = month_achievements
      .filter_map(&:achievement_remark)
      .select { |remark| remark.l1_remarks.present? || remark.reporting_manager_remarks.present? }
      .max_by(&:updated_at)

    observer_summaries = ApplicationHelper::OBSERVER_LEVELS.filter_map do |observer_level|
      next unless observer_assigned?(employee_detail, observer_level)

      review = ObserverPliReview.find_by(
        employee_detail: employee_detail,
        financial_year: financial_year,
        quarter: quarter,
        month: month,
        observer_level: observer_level
      )

      {
        level: observer_level,
        label: observer_column_label(observer_level),
        final_remarks: review&.final_remarks,
        status: review&.status
      }
    end

    quarterly_pli = QuarterlyPliReview.find_by(
      employee_detail: employee_detail,
      financial_year: financial_year,
      quarter: quarter
    )

    {
      month_label: short_month_label(month),
      quarter: quarter,
      l1_name: employee_detail.l1_employer_name,
      l1_final_remarks: latest_l1_remark&.l1_remarks.presence || latest_l1_remark&.reporting_manager_remarks,
      l1_percentage: latest_l1_remark&.l1_percentage,
      observer_summaries: observer_summaries,
      quarterly_pli: {
        quarter: quarter,
        final_percentage: quarterly_pli&.final_percentage,
        final_remarks: quarterly_pli&.final_remarks,
        status: quarterly_pli&.status
      }
    }
  end
end
