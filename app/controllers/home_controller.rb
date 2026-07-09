require "axlsx"

class HomeController < ApplicationController
  before_action :authenticate_user!
  before_action :ensure_l1_pulse_access!, only: [ :l1_pulse_360, :save_l1_pulse_360 ]
  helper_method :composite_category_details, :pulse_category_details, :score_rating_details, :score_rating_text, :pulse_group_rows_for, :pulse_dimension_rows_for, :pulse_team_average, :score_range_rows, :employee_role_label, :pulse_formula_text, :composite_formula_text, :whole_number_score, :composite_display_total, :compact_number

  def index
  end

  def dashboard
    set_financial_year_context

    if admin_dashboard_user?
      load_admin_dashboard
    else
      load_employee_dashboard
    end
  end

  def l1_pulse_360
    @dashboard_mode = :l1_pulse
    load_l1_pulse_rows
  end

  def export_dashboard_xlsx
    set_financial_year_context

    if admin_dashboard_user?
      load_admin_dashboard
    else
      load_employee_dashboard
    end

    package = Axlsx::Package.new
    workbook = package.workbook

    workbook.add_worksheet(name: "Annual Review") do |sheet|
      if @dashboard_mode == :admin
        sheet.add_row [ "Employee", "Code", "Department", "Q1", "Q2", "Q3", "Q4", "Annual %" ]
        @employee_rows.each do |row|
          sheet.add_row [
            row[:employee_name], row[:employee_code], row[:department],
            formatted_percent(row[:quarter_summaries][0][:percentage]), formatted_percent(row[:quarter_summaries][1][:percentage]),
            formatted_percent(row[:quarter_summaries][2][:percentage]), formatted_percent(row[:quarter_summaries][3][:percentage]),
            formatted_percent(row[:annual_percentage])
          ]
        end
      else
        sheet.add_row [ "Quarter", "KRA Score" ]
        @quarter_summaries.each do |quarter|
          sheet.add_row [ quarter[:name], formatted_percent(quarter[:percentage]) ]
        end
        sheet.add_row [ "Annual Average", formatted_percent(@annual_percentage) ]
      end
    end

    workbook.add_worksheet(name: "Score Range") do |sheet|
      sheet.add_row [ "Total / 25 Range", "Band", "Rating", "Recommended Action" ]
      score_range_rows.each do |row|
        sheet.add_row [ row[:score_range], row[:band], row[:rating], row[:action] ]
      end
    end

    workbook.add_worksheet(name: @dashboard_mode == :admin ? "Pulse 360 Score" : "Pulse Check") do |sheet|
      if @dashboard_mode == :admin
        sheet.add_row [
          "Staff Name", "Role", "Wt %", "Values Alignment (1-5)", "Technical Knowledge (1-5)",
          "Customer & Field Engagement (1-5)", "Execution & Accountability (1-5)", "Initiative & Leadership (1-5)",
          "Total /25", "25% Computed", "Category & Action"
        ]
        @employee_rows.each do |row|
          category = row[:pulse_category]
          grouped_scores = pulse_group_rows_for(row[:pulse_scores])
          sheet.add_row [
            row[:employee_name], row[:role], row[:summary_scores][:pulse_score],
            grouped_scores[0][:score], grouped_scores[1][:score], grouped_scores[2][:score],
            grouped_scores[3][:score], grouped_scores[4][:score],
            row[:pulse_scores][:total_score],
            row[:summary_scores][:pulse_score],
            category.present? ? "#{category[:category]} - #{category[:action]}" : ""
          ]
        end
        if (team_average = pulse_team_average(@employee_rows))
          sheet.add_row [
            "TEAM AVERAGE", "",
            team_average[:pulse_score],
            team_average[:grouped_scores][0][:score], team_average[:grouped_scores][1][:score], team_average[:grouped_scores][2][:score],
            team_average[:grouped_scores][3][:score], team_average[:grouped_scores][4][:score],
            team_average[:total_score],
            team_average[:pulse_score],
            "#{team_average[:category][:category]} - #{team_average[:category][:action]}"
          ]
        end
      else
        sheet.add_row [ "Pulse Dimension", "Wt %", "Score (1-5)", "Wtd Score", "Rating" ]
        pulse_dimension_rows_for(@dashboard_pulse_scores).each do |dimension|
          sheet.add_row [
            dimension[:label], "#{dimension[:weight]}%", dimension[:score],
            dimension[:weighted_score].present? ? "#{dimension[:weighted_score]}%" : "-",
            dimension[:rating_text]
          ]
        end
        pulse_raw = pulse_raw_percentage(@dashboard_pulse_scores[:total_score])
        sheet.add_row [ "PULSE TOTAL", "100%", "", pulse_raw.present? ? "Pulse Raw -> #{pulse_raw}%" : "Pending assessment", @dashboard_pulse_category&.dig(:category) || "Pending" ]
      end
    end

    workbook.add_worksheet(name: "Composite Score") do |sheet|
      if @dashboard_mode == :admin
        sheet.add_row [ "User", "KRA %", "Pulse %", "Final Total" ]
        @employee_rows.each do |row|
          sheet.add_row [
            row[:employee_name], formatted_percent(row[:annual_percentage]), formatted_percent(row[:pulse_raw_percentage]),
            formatted_percent(row[:summary_scores][:final_total])
          ]
        end
        if @employee_rows.any?
          sheet.add_row [
            "TEAM AVERAGE",
            formatted_percent((@employee_rows.sum { |r| r[:annual_percentage].to_f } / @employee_rows.size)),
            formatted_percent((@employee_rows.sum { |r| r[:pulse_raw_percentage].to_f } / @employee_rows.size)),
            formatted_percent((@employee_rows.sum { |r| r[:summary_scores][:final_total].to_f } / @employee_rows.size))
          ]
        end
      else
        sheet.add_row [ "Section", "Raw Score", "Section Weight", "Weighted Contribution" ]
        employee_summary_rows.each do |row|
          sheet.add_row row
        end
        composite = composite_category_details(@dashboard_summary_scores[:final_total])
        sheet.add_row []
        sheet.add_row [ "Final Composite Score", "#{@dashboard_summary_scores[:final_total]}%", composite[:band] ]
      end
    end

    tempfile = Tempfile.new([ "dashboard_export", ".xlsx" ])
    package.serialize(tempfile.path)
    send_file tempfile.path, filename: "dashboard_export_#{Date.current}.xlsx", type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  end

  def export_dashboard_section_xlsx
    set_financial_year_context

    if admin_dashboard_user?
      load_admin_dashboard
    else
      load_employee_dashboard
    end

    package = Axlsx::Package.new
    workbook = package.workbook
    case params[:section]
    when "annual"
      workbook.add_worksheet(name: "Annual Review") do |sheet|
        if @dashboard_mode == :admin
          sheet.add_row [ "Employee", "Code", "Department", "Q1", "Q2", "Q3", "Q4", "Annual %" ]
          @employee_rows.each do |row|
            sheet.add_row [ row[:employee_name], row[:employee_code], row[:department], formatted_percent(row[:quarter_summaries][0][:percentage]), formatted_percent(row[:quarter_summaries][1][:percentage]), formatted_percent(row[:quarter_summaries][2][:percentage]), formatted_percent(row[:quarter_summaries][3][:percentage]), formatted_percent(row[:annual_percentage]) ]
          end
        else
          sheet.add_row [ "Quarter", "KRA Score" ]
          @quarter_summaries.each do |quarter|
            sheet.add_row [ quarter[:name], formatted_percent(quarter[:percentage]) ]
          end
          sheet.add_row [ "Annual Average", formatted_percent(@annual_percentage) ]
        end
      end
    when "pulse"
      workbook.add_worksheet(name: "Pulse Score") do |sheet|
        if @dashboard_mode == :admin
          sheet.add_row [ "Staff Name", "Role", "Wt %", "Values Alignment (1-5)", "Technical Knowledge (1-5)", "Customer & Field Engagement (1-5)", "Execution & Accountability (1-5)", "Initiative & Leadership (1-5)", "Total /25", "25% Computed", "Category & Action" ]
          @employee_rows.each do |row|
            category = row[:pulse_category]
            grouped_scores = pulse_group_rows_for(row[:pulse_scores])
            sheet.add_row [ row[:employee_name], row[:role], row[:summary_scores][:pulse_score], grouped_scores[0][:score], grouped_scores[1][:score], grouped_scores[2][:score], grouped_scores[3][:score], grouped_scores[4][:score], row[:pulse_scores][:total_score], row[:summary_scores][:pulse_score], category.present? ? "#{category[:category]} - #{category[:action]}" : "" ]
          end
          if (team_average = pulse_team_average(@employee_rows))
            sheet.add_row [ "TEAM AVERAGE", "", team_average[:pulse_score], team_average[:grouped_scores][0][:score], team_average[:grouped_scores][1][:score], team_average[:grouped_scores][2][:score], team_average[:grouped_scores][3][:score], team_average[:grouped_scores][4][:score], team_average[:total_score], team_average[:pulse_score], "#{team_average[:category][:category]} - #{team_average[:category][:action]}" ]
          end
        else
          sheet.add_row [ "Pulse Dimension", "Wt %", "Score (1-5)", "Wtd Score", "Rating" ]
          pulse_dimension_rows_for(@dashboard_pulse_scores).each do |dimension|
            sheet.add_row [ dimension[:label], "#{dimension[:weight]}%", dimension[:score], dimension[:weighted_score].present? ? "#{dimension[:weighted_score]}%" : "-", dimension[:rating_text] ]
          end
          pulse_raw = pulse_raw_percentage(@dashboard_pulse_scores[:total_score])
          sheet.add_row [ "PULSE TOTAL", "100%", "", pulse_raw.present? ? "Pulse Raw -> #{pulse_raw}%" : "Pending assessment", @dashboard_pulse_category&.dig(:category) || "Pending" ]
        end
      end
    when "summary"
      workbook.add_worksheet(name: "Composite Score") do |sheet|
        if @dashboard_mode == :admin
          sheet.add_row [ "User", "KRA %", "Pulse %", "Final Total" ]
          @employee_rows.each do |row|
            sheet.add_row [ row[:employee_name], formatted_percent(row[:annual_percentage]), formatted_percent(row[:pulse_raw_percentage]), formatted_percent(row[:summary_scores][:final_total]) ]
          end
          if @employee_rows.any?
            sheet.add_row [ "TEAM AVERAGE", formatted_percent((@employee_rows.sum { |r| r[:annual_percentage].to_f } / @employee_rows.size)), formatted_percent((@employee_rows.sum { |r| r[:pulse_raw_percentage].to_f } / @employee_rows.size)), formatted_percent((@employee_rows.sum { |r| r[:summary_scores][:final_total].to_f } / @employee_rows.size)) ]
          end
        else
          sheet.add_row [ "Section", "Raw Score", "Section Weight", "Weighted Contribution" ]
          employee_summary_rows.each do |row|
            sheet.add_row row
          end
          composite = composite_category_details(@dashboard_summary_scores[:final_total])
          sheet.add_row []
          sheet.add_row [ "Final Composite Score", "#{@dashboard_summary_scores[:final_total]}%", composite[:band] ]
        end
      end
    end
    tempfile = Tempfile.new([ "dashboard_#{params[:section]}", ".xlsx" ])
    package.serialize(tempfile.path)
    send_file tempfile.path, filename: "dashboard_#{params[:section]}_#{Date.current}.xlsx", type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  end

  def save_l1_pulse_360
    submitted_rows = params[:pulse_assessments] || {}
    employee_details = l1_managed_employee_details.index_by { |employee_detail| employee_detail.id.to_s }

    submitted_rows.each do |employee_detail_id, assessment_params|
      employee_detail = employee_details[employee_detail_id]
      next unless employee_detail
      next if assessment_blank?(assessment_params)

      assessment = if current_user.hod? || current_user.admin?
        latest_filled_l1_assessment_for(employee_detail) ||
          employee_detail.l1_pulse_assessments.max_by(&:updated_at) ||
          L1PulseAssessment.new(employee_detail_id: employee_detail.id, l1_user_id: current_user.id)
      else
        L1PulseAssessment.find_or_initialize_by(employee_detail_id: employee_detail.id, l1_user_id: current_user.id)
      end
      values_alignment = assessment_params[:values_alignment].presence
      technical_knowledge = assessment_params[:technical_knowledge].presence
      customer_field_engagement = assessment_params[:customer_field_engagement].presence
      execution_accountability = assessment_params[:execution_accountability].presence
      initiative_leadership = assessment_params[:initiative_leadership].presence

      assessment.assign_attributes(
        values_alignment: values_alignment,
        technical_knowledge: technical_knowledge,
        customer_field_engagement: customer_field_engagement,
        execution_accountability: execution_accountability,
        initiative_leadership: initiative_leadership,
        pulse_remarks: assessment_params[:pulse_remarks].presence,
        remarks: assessment_params[:remarks].presence, professionalism_conduct: assessment_params[:professionalism_conduct].presence,
        work_quality_accuracy: assessment_params[:work_quality_accuracy].presence, initiative_problem_solving: assessment_params[:initiative_problem_solving].presence,
        papl_values_culture: nil, collaboration: nil,
        time_management_reliability: assessment_params[:time_management_reliability].presence, growth_mindset_development: assessment_params[:growth_mindset_development].presence
      )
      manager_feedback = manager_feedback_summary_for(assessment)
      assessment.remark_score = manager_feedback[:score_on_ten]
      assessment.save!
    end

    redirect_to l1_pulse_360_path, notice: "Scores saved successfully."
  rescue ActiveRecord::RecordInvalid => e
    @dashboard_mode = :l1_pulse
    @pulse_error_message = e.record.errors.full_messages.to_sentence
    load_l1_pulse_rows
    render :l1_pulse_360, status: :unprocessable_entity
  end

  private

  def admin_dashboard_user?
    current_user.hod? || current_user.admin?
  end

  def set_financial_year_context
    @financial_years = financial_year_options
    @selected_financial_year = normalize_financial_year(params[:financial_year]) || current_financial_year
    @financial_years |= [ @selected_financial_year ]
    @financial_years.sort!.reverse!
  end

  def financial_year_options
    start_year = Date.current.month >= 4 ? Date.current.year : Date.current.year - 1
    nearby_years = ((start_year - 1)..(start_year + 1)).map { |year| "#{year}-#{year + 1}" }
    persisted_years = if user_details_financial_year_available?
      UserDetail.where.not(financial_year: [ nil, "" ]).distinct.pluck(:financial_year)
    else
      []
    end

    (persisted_years + nearby_years).filter_map { |year| normalize_financial_year(year) }.uniq
  end

  def user_details_financial_year_available?
    UserDetail.column_names.include?("financial_year")
  end

  def current_financial_year
    start_year = Date.current.month >= 4 ? Date.current.year : Date.current.year - 1
    "#{start_year}-#{start_year + 1}"
  end

  def quarter_map
    { "Q1" => %w[april may june], "Q2" => %w[july august september], "Q3" => %w[october november december], "Q4" => %w[january february march] }
  end

  def quarter_summaries_for(user_details)
    quarter_map.map do |name, months|
      quarter_achievements = user_details.flat_map do |detail|
        detail.achievements.select do |achievement|
          months.include?(achievement.month.to_s.downcase) && achievement.achievement_remark.present?
        end
      end

      progress_values = user_details.flat_map do |detail|
        achievements_by_month = detail.achievements.index_by { |achievement| achievement.month.to_s.downcase }

        months.filter_map do |month|
          target = detail.public_send(month).to_s.delete(",").to_f
          achievement = achievements_by_month[month]
          next unless target.positive? && achievement&.achievement.present? && achievement.achievement_remark.present?

          achievement_value = achievement.achievement.to_s.delete(",").to_f
          (((achievement_value / target) * 100.0 * 100).floor / 100.0)
        end
      end
      l1_rems = quarter_achievements.filter_map { |achievement| achievement.achievement_remark&.l1_remarks }.uniq.compact

      {
        name: name,
        percentage: progress_values.any? ? ((progress_values.sum / progress_values.size) * 100).floor / 100.0 : 0.0,
        scored: progress_values.any?,
        l1_remarks: l1_rems,
        remarks: l1_rems
      }
    end
  end

  def scored_quarter_summaries(quarter_summaries)
    quarter_summaries.select { |quarter| quarter[:scored] }
  end

  def annual_percentage_for(quarter_summaries)
    scored_quarters = scored_quarter_summaries(quarter_summaries)
    return 0.0 if scored_quarters.empty?

    (scored_quarters.sum { |quarter| quarter[:percentage].to_f } / scored_quarters.size).round(2)
  end

  def pulse_category_details(ts)
    return nil if ts.blank?

    category_details_from_percentage(pulse_raw_percentage(ts).to_f)
  end

  def manager_feedback_category_details(raw_percentage)
    return nil if raw_percentage.blank?

    category_details_from_percentage(raw_percentage.to_f)
  end

  def category_details_from_percentage(raw_percentage)
    raw_percentage = raw_percentage.to_f

    if raw_percentage > 92
      { stars: "★★★★★", category: "Exceptional", action: "Accelerated growth track / highest increment", className: "stars-5" }
    elsif raw_percentage >= 76
      { stars: "★★★★", category: "Outstanding", action: "Merit increment / recognition award", className: "stars-4" }
    elsif raw_percentage >= 60
      { stars: "★★★", category: "Meets Expectations", action: "Standard increment as per policy", className: "stars-3" }
    elsif raw_percentage >= 44
      { stars: "★★", category: "Needs Improvement", action: "PIP / structured coaching plan", className: "stars-2" }
    else { stars: "★", category: "Unsatisfactory", action: "Formal PIP / disciplinary review", className: "stars-1" }
    end
  end

  def score_rating_details(score)
    return nil if score.blank?

    case score.to_i
    when 5 then { rating: 5, stars: "★★★★★", className: "stars-5", band: "Exceptional" }
    when 4 then { rating: 4, stars: "★★★★", className: "stars-4", band: "Outstanding" }
    when 3 then { rating: 3, stars: "★★★", className: "stars-3", band: "Meets Expectations" }
    when 2 then { rating: 2, stars: "★★", className: "stars-2", band: "Needs Improvement" }
    else { rating: 1, stars: "★", className: "stars-1", band: "Unsatisfactory" }
    end
  end

  def score_rating_text(score)
    details = score_rating_details(score)
    details ? "#{details[:rating]} (#{details[:stars]})" : "-"
  end

  def score_range_rows
    [
      { score_range: "> 23", band: "Exceptional", rating: "5 (★★★★★)", rating_value: 5, stars: "★★★★★", className: "stars-5", action: "Accelerated growth track / highest increment" },
      { score_range: "19 - 22.9", band: "Outstanding", rating: "4 (★★★★)", rating_value: 4, stars: "★★★★", className: "stars-4", action: "Merit increment / recognition award" },
      { score_range: "15 - 18.9", band: "Meets Expectations", rating: "3 (★★★)", rating_value: 3, stars: "★★★", className: "stars-3", action: "Standard increment as per policy" },
      { score_range: "11 - 14.9", band: "Needs Improvement", rating: "2 (★★)", rating_value: 2, stars: "★★", className: "stars-2", action: "PIP / structured coaching plan" },
      { score_range: "< 11", band: "Unsatisfactory", rating: "1 (★)", rating_value: 1, stars: "★", className: "stars-1", action: "Formal PIP / disciplinary review" }
    ]
  end

  def employee_role_label(employee_detail, user_details = employee_detail.user_details)
    role = employee_detail.post.to_s.strip
    return role if role.present? && role.casecmp("Imported") != 0

    user_department = Array(user_details).first&.department&.department_type.to_s.strip
    return user_department if user_department.present?

    department = employee_detail.department.to_s.strip
    return department if department.present?

    "Employee"
  end

  def pulse_raw_percentage(total_score)
    return nil if total_score.blank?

    ((total_score.to_f / 25.0) * 100.0).round(2)
  end

  def pulse_weighted_score(total_score)
    return 0.0 if total_score.blank?

    ((total_score.to_f / 25.0) * 25.0).round(2)
  end

  def pulse_formula_text(total_score)
    return "Pending pulse assessment" if total_score.blank?

    raw_percentage = pulse_raw_percentage(total_score)
    "#{whole_number_score(total_score)}/25 x 100 = #{whole_number_score(raw_percentage)}"
  end

  def pulse_dimension_rows_for(pulse_scores)
    pulse_group_rows_for(pulse_scores).map do |dimension|
      score = dimension[:score]
      weighted_score = score.present? ? ((score.to_f / 5.0) * dimension[:weight]).round(2) : nil

      dimension.merge(weighted_score: weighted_score, rating_text: score_rating_text(score))
    end
  end

  def pulse_group_rows_for(pulse_scores)
    [
      { label: "Values Alignment", weight: 20, score: pulse_scores&.dig(:values_alignment) },
      { label: "Technical Knowledge", weight: 20, score: pulse_scores&.dig(:technical_knowledge) },
      { label: "Customer & Field Engagement", weight: 20, score: pulse_scores&.dig(:customer_field_engagement) },
      { label: "Execution & Accountability", weight: 20, score: pulse_scores&.dig(:execution_accountability) },
      { label: "Initiative & Leadership", weight: 20, score: pulse_scores&.dig(:initiative_leadership) }
    ]
  end

  def employee_summary_rows
    pulse_raw = pulse_raw_percentage(@dashboard_pulse_scores[:total_score])

    [
      [ "A - KRA", @annual_percentage.present? ? "#{compact_number(@annual_percentage)}%" : "-", "75%", @dashboard_summary_scores[:annual_score].present? ? "#{compact_number(@dashboard_summary_scores[:annual_score])}%" : "-" ],
      [ "B - Pulse Check", pulse_raw.present? ? "#{compact_number(pulse_raw)}%" : "Pending", "25%", @dashboard_summary_scores[:pulse_score].present? ? "#{compact_number(@dashboard_summary_scores[:pulse_score])}%" : "-" ]
    ]
  end

  def manager_feedback_raw_percentage(a)
    return 0.0 if a.blank? || assessment_blank?(a)
    criteria = manager_feedback_criteria_for(a)
    return 0.0 unless criteria.any?

    raw_total = criteria.sum { |criterion| criterion[:weighted_score].to_f }
    total_weight = criteria.sum { |criterion| criterion[:weight].to_f }
    ((raw_total / total_weight) * 10.0).round(2)
  end

  def manager_feedback_criteria_for(assessment)
    [
      { key: :professionalism_conduct, label: "Professionalism & Conduct", weight: 20 },
      { key: :work_quality_accuracy, label: "Quality & Accuracy of Work Output", weight: 20 },
      { key: :initiative_problem_solving, label: "Initiative & Problem-Solving", weight: 20 },
      { key: :time_management_reliability, label: "Time Management & Reliability", weight: 20 },
      { key: :growth_mindset_development, label: "Growth Mindset & Development", weight: 20 }
    ].map do |criterion|
      score = assessment&.public_send(criterion[:key])
      weighted_score = score.present? ? ((score.to_f / 5.0) * criterion[:weight]).round(2) : nil

      criterion.merge(score: score, weighted_score: weighted_score)
    end
  end

  def manager_feedback_summary_for(assessment)
    criteria = manager_feedback_criteria_for(assessment)
    raw_weighted_total = criteria.sum { |criterion| criterion[:weighted_score].to_f }.round(2)
    total_weight = criteria.sum { |criterion| criterion[:weight].to_f }.round(2)
    has_scores = criteria.any? { |criterion| criterion[:score].present? }
    raw_total = has_scores && total_weight.positive? ? ((raw_weighted_total / total_weight) * 100.0).round(2) : 0.0
    score_on_ten = has_scores ? (raw_total / 10.0).round(1) : nil

    {
      criteria: criteria,
      raw_weighted_total: raw_weighted_total,
      raw_total: raw_total,
      total_weight: total_weight,
      score_on_ten: score_on_ten,
      weighted_score: score_on_ten.present? ? ((score_on_ten / 10.0) * 10.0).round(2) : nil,
      available: has_scores
    }
  end

  def weighted_summary_scores(annual_percentage:, pulse_total_score:, remark_score: nil)
    annual_score = annual_percentage.to_f
    pulse_score = pulse_raw_percentage(pulse_total_score).to_f
    ws_annual = (annual_score * 0.75).round(2)
    ws_pulse = (pulse_score * 0.25).round(2)

    { annual_score: ws_annual, pulse_score: ws_pulse, remarks_score: 0.0, final_total: (ws_annual + ws_pulse).round(2) }
  end

  def composite_formula_text(annual_percentage:, pulse_total_score:)
    ap = annual_percentage.to_f
    pulse_percentage = pulse_raw_percentage(pulse_total_score).to_f
    annual_contribution = (ap * 0.75).round(2)
    pulse_contribution = (pulse_percentage * 0.25).round(2)
    final_total = (annual_contribution + pulse_contribution).round(2)

    "(#{compact_number(ap)} x 75%) + (#{compact_number(pulse_percentage)} x 25%) = #{compact_number(annual_contribution)} + #{compact_number(pulse_contribution)} = #{compact_number(final_total)}"
  end

  def whole_number_score(value)
    number = value.to_f
    base = number.floor

    (number - base) >= 0.5 ? base + 1 : base
  end

  def composite_display_total(annual_percentage:, pulse_total_score:)
    ap = annual_percentage.to_f
    pulse_percentage = pulse_raw_percentage(pulse_total_score).to_f

    ((ap * 0.75) + (pulse_percentage * 0.25)).round(2)
  end

  def pulse_scores_from_assessment(a)
    {
      values_alignment: numeric_score_or_nil(a.values_alignment),
      technical_knowledge: numeric_score_or_nil(a.technical_knowledge),
      customer_field_engagement: numeric_score_or_nil(a.customer_field_engagement),
      execution_accountability: numeric_score_or_nil(a.execution_accountability),
      initiative_leadership: numeric_score_or_nil(a.initiative_leadership),
      total_score: pulse_total_for_assessment(a)
    }
  end

  def blank_pulse_scores
    { values_alignment: nil, technical_knowledge: nil, customer_field_engagement: nil, execution_accountability: nil, initiative_leadership: nil, total_score: nil }
  end

  def composite_category_details(ft)
    ft = ft.to_f

    if ft >= 95
      { band: "Exceptional", rating: 5, stars: "★★★★★", className: "stars-5", action: "" }
    elsif ft >= 90
      { band: "Outstanding", rating: 4, stars: "★★★★", className: "stars-4", action: "" }
    elsif ft >= 85
      { band: "Meets Expectations", rating: 3, stars: "★★★", className: "stars-3", action: "" }
    elsif ft >= 45
      { band: "Needs Improvement", rating: 2, stars: "★★", className: "stars-2", action: "PIP" }
    else { band: "Unsatisfactory", rating: 1, stars: "★", className: "stars-1", action: "Formal PIP" }
    end
  end

  def assessment_blank?(p)
    [ :values_alignment, :technical_knowledge, :customer_field_engagement, :execution_accountability, :initiative_leadership, :pulse_remarks, :remarks, :professionalism_conduct, :work_quality_accuracy, :initiative_problem_solving, :time_management_reliability, :growth_mindset_development ].all? { |f| p[f].blank? }
  end

  def numeric_score_or_nil(value)
    return nil if value.blank?

    numeric = value.to_f
    (numeric % 1).zero? ? numeric.to_i : numeric.round(1)
  end

  def build_employee_dashboard_row(ed)
    ud = if user_details_financial_year_available?
      ed.user_details.select { |detail| detail.financial_year == @selected_financial_year }
    else
      ed.user_details
    end
    qs = quarter_summaries_for(ud)
    ap = annual_percentage_for(qs)
    pa = ed.l1_pulse_assessments.max_by(&:updated_at)
    ps = pa ? pulse_scores_from_assessment(pa) : blank_pulse_scores
    manager_feedback = manager_feedback_summary_for(pa)
    ts = ps[:total_score]
    pulse_available = ts.present?
    ws_pulse = pulse_available ? pulse_weighted_score(ts) : 0.0
    {
      employee_detail_id: ed.id, employee_name: ed.employee_name || "N/A", employee_code: ed.employee_code || "N/A",
      role: employee_role_label(ed, ud),
      department: ud.first&.department&.department_type || ed.department || "N/A",
      quarter_summaries: qs, annual_percentage: ap,
      total: qs.sum { |q| q[:percentage] }.round(1),
      l1_remarks: qs.flat_map { |q| q[:l1_remarks] }.uniq,
      remarks: qs.flat_map { |q| q[:l1_remarks] }.uniq,
      pulse_scores: ps, pulse_available: pulse_available, pulse_weighted: ws_pulse,
      pulse_raw_percentage: pulse_raw_percentage(ts) || 0.0,
      pulse_category: pulse_category_details(ts),
      pulse_remarks: pa&.pulse_remarks,
      pulse_assessment_remarks: pa&.remarks, pulse_assessment_score: manager_feedback[:score_on_ten] || pa&.remark_score,
      manager_feedback_total: manager_feedback_total_for_assessment(pa),
      manager_feedback: manager_feedback,
      manager_feedback_raw: pa ? manager_feedback_raw_percentage(pa) : 0.0,
      manager_raw_percentage: manager_feedback[:raw_total].to_f,
      summary_scores: weighted_summary_scores(annual_percentage: ap, pulse_total_score: ts, remark_score: manager_feedback[:score_on_ten] || pa&.remark_score)
    }
  end

  def latest_filled_l1_assessment_for(ed)
    ed.l1_pulse_assessments.reject { |assessment| assessment_blank?(assessment) }.max_by(&:updated_at) ||
      ed.l1_pulse_assessments.max_by(&:updated_at)
  end

  def l1_assessment_for(ed)
    if current_user.hod? || current_user.admin?
      latest_filled_l1_assessment_for(ed) ||
        ed.l1_pulse_assessments.max_by(&:updated_at) ||
        ed.l1_pulse_assessments.build(l1_user_id: current_user.id)
    else
      ed.l1_pulse_assessments.find { |assessment| assessment.l1_user_id == current_user.id } ||
        ed.l1_pulse_assessments.build(l1_user_id: current_user.id)
    end
  end

  def pulse_total_for_assessment(a)
    scores = [ a.values_alignment, a.technical_knowledge, a.customer_field_engagement, a.execution_accountability, a.initiative_leadership ]
    return nil if scores.all?(&:blank?)

    scores.compact.sum(&:to_f).round(1)
  end

  def manager_feedback_total_for_assessment(assessment)
    criteria = manager_feedback_criteria_for(assessment)
    return nil if criteria.all? { |criterion| criterion[:score].blank? }

    criteria.sum { |criterion| criterion[:score].to_f }.round(1)
  end

  def build_l1_pulse_row(ed)
    a = l1_assessment_for(ed)
    ts = pulse_total_for_assessment(a)
    manager_summary = manager_feedback_summary_for(a)
    manager_raw = manager_feedback_raw_percentage(a)
    { employee_detail_id: ed.id, employee_name: ed.employee_name, employee_code: ed.employee_code, department: ed.user_details.first&.department&.department_type || ed.department, assessment: a, total_score: ts, pulse_weighted: pulse_weighted_score(ts), pulse_category: pulse_category_details(ts), pulse_remarks: a.pulse_remarks, manager_feedback_total: manager_feedback_total_for_assessment(a), manager_feedback_raw: manager_raw, manager_feedback_category: manager_summary[:available] ? manager_feedback_category_details(manager_summary[:raw_total]) : nil }
  end

  def pulse_team_average(rows)
    scored_rows = rows.select { |row| row.dig(:pulse_scores, :total_score).present? }
    return nil if scored_rows.empty?

    average_total = (scored_rows.sum { |row| row[:pulse_scores][:total_score].to_f } / scored_rows.size).round(1)

    {
      pulse_score: (scored_rows.sum { |row| row[:summary_scores][:pulse_score].to_f } / scored_rows.size).round(1),
      total_score: average_total,
      grouped_scores: pulse_group_rows_for(
        values_alignment: (scored_rows.sum { |row| row[:pulse_scores][:values_alignment].to_f } / scored_rows.size).round(1),
        technical_knowledge: (scored_rows.sum { |row| row[:pulse_scores][:technical_knowledge].to_f } / scored_rows.size).round(1),
        customer_field_engagement: (scored_rows.sum { |row| row[:pulse_scores][:customer_field_engagement].to_f } / scored_rows.size).round(1),
        execution_accountability: (scored_rows.sum { |row| row[:pulse_scores][:execution_accountability].to_f } / scored_rows.size).round(1),
        initiative_leadership: (scored_rows.sum { |row| row[:pulse_scores][:initiative_leadership].to_f } / scored_rows.size).round(1)
      ),
      category: pulse_category_details(average_total)
    }
  end

  def formatted_percent(value)
    "#{format('%.2f', value.to_f)}%"
  end

  def compact_number(value)
    number = value.to_f
    (number % 1).zero? ? number.to_i.to_s : format("%.2f", number).sub(/\.?0+$/, "")
  end

  def load_l1_pulse_rows
    @pulse_rows = l1_managed_employee_details.map { |ed| build_l1_pulse_row(ed) }
  end

  def l1_managed_employee_details
    EmployeeDetail.includes(:l1_pulse_assessments, user_details: [ :department, achievements: :achievement_remark ]).order(Arel.sql("LOWER(employee_name) ASC")).then { |s| (current_user.hod? || current_user.admin?) ? s : s.where("l1_code = :c OR l1_employer_name = :e", c: current_user.employee_code, e: current_user.email) }
  end

  def ensure_l1_pulse_access!
    unless current_user.hod? || current_user.admin? || EmployeeDetail.exists?(l1_code: current_user.employee_code) || EmployeeDetail.exists?(l1_employer_name: current_user.email)
      redirect_to dashboard_path, alert: "Denied."
    end
  end

  def load_admin_dashboard
    @dashboard_mode = :admin
    scope = EmployeeDetail.joins(:user_details)
    scope = scope.where(user_details: { financial_year: @selected_financial_year }) if user_details_financial_year_available?

    @employee_rows = scope.includes(:l1_pulse_assessments, user_details: [ :department, achievements: :achievement_remark ])
                          .distinct
                          .order(:employee_name)
                          .map { |ed| build_employee_dashboard_row(ed) }
  end

  def load_employee_dashboard
    @dashboard_mode = :employee
    @employee_detail = current_user.employee_detail || EmployeeDetail.find_by(employee_email: current_user.email)
    @user_details = if @employee_detail
      scope = UserDetail.includes(:department, achievements: :achievement_remark).where(employee_detail_id: @employee_detail.id)
      scope = scope.where(financial_year: @selected_financial_year) if user_details_financial_year_available?
      scope
    else
      UserDetail.none
    end
    qs = quarter_summaries_for(@user_details)
    ap = annual_percentage_for(qs)
    pa = @employee_detail&.l1_pulse_assessments&.max_by(&:updated_at)
    ps = pa ? pulse_scores_from_assessment(pa) : blank_pulse_scores
    manager_feedback = manager_feedback_summary_for(pa)

    @quarter_summaries = qs
    @annual_total = qs.sum { |q| q[:percentage] }.round(1)
    @annual_percentage = ap
    @dashboard_employee_department = @user_details.first&.department&.department_type || @employee_detail&.department || "N/A"
    @dashboard_pulse_scores = ps
    @dashboard_pulse_category = pulse_category_details(ps[:total_score])
    @dashboard_pulse_available = ps[:total_score].present?
    @dashboard_pulse_section_remarks = pa&.pulse_remarks
    @dashboard_pulse_remarks = pa&.remarks
    @dashboard_pulse_remark_score = manager_feedback[:score_on_ten] || pa&.remark_score
    @dashboard_manager_feedback = manager_feedback
    @annual_l1_remarks = qs.flat_map { |q| q[:l1_remarks] }.uniq
    @annual_remarks = qs.flat_map { |q| q[:l1_remarks] }.uniq
    @dashboard_summary_scores = weighted_summary_scores(annual_percentage: ap, pulse_total_score: ps[:total_score], remark_score: @dashboard_pulse_remark_score)
  end
end
