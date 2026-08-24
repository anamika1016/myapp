require "test_helper"

class EmployeeDetailsControllerTest < ActionDispatch::IntegrationTest
  test "should get index" do
    get employee_details_index_url
    assert_response :success
  end

  test "should get new" do
    get employee_details_new_url
    assert_response :success
  end

  test "should get edit" do
    get employee_details_edit_url
    assert_response :success
  end

  test "quarterly pli review is stale when quarter source data changes after final save" do
    employee_detail = create_quarterly_pli_source.first
    review = QuarterlyPliReview.create!(
      employee_detail: employee_detail,
      financial_year: "2026-2027",
      quarter: "Q1",
      final_percentage: 90,
      final_remarks: "Old final remarks",
      status: "approved",
      reviewed_at: 2.days.ago,
      created_at: 2.days.ago,
      updated_at: 2.days.ago
    )

    assert_nil EmployeeDetailsController.new.send(
      :current_quarterly_pli_review_for,
      review,
      employee_detail.reload,
      "2026-2027",
      "Q1"
    )
  end

  test "quarterly pli review remains current when saved after quarter source data" do
    employee_detail = create_quarterly_pli_source(source_time: 2.days.ago).first
    review = QuarterlyPliReview.create!(
      employee_detail: employee_detail,
      financial_year: "2026-2027",
      quarter: "Q1",
      final_percentage: 90,
      final_remarks: "Current final remarks",
      status: "approved",
      reviewed_at: 1.day.ago,
      created_at: 1.day.ago,
      updated_at: 1.day.ago
    )

    assert_equal review, EmployeeDetailsController.new.send(
      :current_quarterly_pli_review_for,
      review,
      employee_detail.reload,
      "2026-2027",
      "Q1"
    )
  end

  test "l1 monthly progress includes target rows without achievement as zero" do
    employee_detail = create_partial_month_submission_source

    rows = EmployeeDetailsController.new.send(
      :build_monthly_employee_data,
      [ employee_detail.reload ],
      approval_level: "l1",
      month: "april",
      financial_year: "2026-2027",
      include_unsubmitted_target_rows: true
    )

    assert_equal "50.00", rows.values.first[:progress]
  end

  test "observer calculated percentage matches monthly submission footer" do
    employee_detail = create_partial_month_submission_source
    controller = EmployeeDetailsController.new

    observer_rows = controller.send(
      :build_observer_pli_rows,
      [ employee_detail.reload ],
      observer_level: "obs_code1",
      financial_year: "2026-2027",
      quarter: "Q1",
      month: "april"
    )

    assert_equal "50.00", observer_rows.first[:calculated_percentage]
  end

  test "quarterly pli rows include target rows without achievement as zero" do
    employee_detail = create_partial_month_submission_source(status: "l1_approved", observer_code: nil)

    rows = EmployeeDetailsController.new.send(
      :build_quarterly_pli_rows,
      [ employee_detail.reload ],
      financial_year: "2026-2027",
      quarter: "Q1"
    )

    assert_equal "50.00", rows.first[:calculated_percentage]
    assert_equal "50.00", rows.first.dig(:detail_payload, :months, 0, :achievement_percentage)
  end

  test "quarterly pli scope only includes employees mapped to current users l1 code" do
    matching_employee = EmployeeDetail.create!(
      employee_name: "Mapped Employee",
      employee_code: "PAPL032",
      l1_code: "PAPL063",
      l1_employer_name: "nishchal@ploughmanagro.com"
    )
    EmployeeDetail.create!(
      employee_name: "L2 Only Employee",
      employee_code: "PAPL040",
      l2_code: "PAPL063",
      l2_employer_name: "nishchal@ploughmanagro.com"
    )

    controller = EmployeeDetailsController.new
    current_user = User.new(employee_code: "PAPL063", email: "nishchal@ploughmanagro.com", role: "employee")
    controller.define_singleton_method(:current_user) { current_user }
    controller.define_singleton_method(:quarterly_pli_menu_enabled?) { true }
    controller.define_singleton_method(:current_user_identity_code) { current_user.employee_code }
    controller.define_singleton_method(:current_user_identity_email) { current_user.email }

    scoped_ids = controller.send(:quarterly_pli_employee_scope).pluck(:id)

    assert_equal [ matching_employee.id ], scoped_ids
  end

  test "quarterly pli authorization does not allow l2-only mapping" do
    EmployeeDetail.create!(
      employee_name: "L2 Only Employee",
      employee_code: "PAPL040",
      l2_code: "PAPL063",
      l2_employer_name: "nishchal@ploughmanagro.com"
    )

    controller = EmployeeDetailsController.new
    current_user = User.new(employee_code: "PAPL063", email: "nishchal@ploughmanagro.com", role: "employee")
    controller.define_singleton_method(:current_user) { current_user }
    controller.define_singleton_method(:quarterly_pli_menu_enabled?) { true }
    controller.define_singleton_method(:current_user_identity_code) { current_user.employee_code }
    controller.define_singleton_method(:current_user_identity_email) { current_user.email }

    assert_not controller.send(:quarterly_pli_authorized?)
  end

  test "pli dashboard rows compare calculated and final pli percentages" do
    employee_detail = create_partial_month_submission_source(status: "l1_approved", observer_code: nil)
    QuarterlyPliReview.create!(
      employee_detail: employee_detail,
      financial_year: "2026-2027",
      quarter: "Q1",
      final_percentage: 40,
      final_remarks: "Needs correction",
      status: "approved",
      reviewed_at: Time.current
    )

    rows = EmployeeDetailsController.new.send(
      :build_pli_dashboard_rows,
      [ employee_detail.reload ],
      financial_year: "2026-2027",
      quarter: "Q1"
    )

    assert_equal "less", rows.first[:comparison_key]
    assert_equal -10.0, rows.first[:difference_value]
    assert_equal "Final PLI is 10.00% below the calculated percentage.", rows.first[:dashboard_remarks]
  end

  test "pli dashboard summary counts equal more less and pending rows" do
    controller = EmployeeDetailsController.new
    rows = [
      { comparison_key: "equal" },
      { comparison_key: "more" },
      { comparison_key: "less" },
      { comparison_key: "pending" },
      { comparison_key: "returned" }
    ]

    summary = controller.send(:summarize_pli_dashboard_rows, rows)

    assert_equal 5, summary[:total]
    assert_equal 1, summary[:equal]
    assert_equal 1, summary[:more]
    assert_equal 1, summary[:less]
    assert_equal 1, summary[:pending]
    assert_equal 1, summary[:returned]
  end

  test "l1 sms after observer approval keeps quarter template with submitted month" do
    employee_detail = EmployeeDetail.create!(
      employee_name: "Anamika Vishwakarma",
      employee_code: "PAPL126-SMS",
      l1_code: "PAPL999-SMS"
    )
    EmployeeDetail.create!(
      employee_name: "L1 Manager",
      employee_code: "PAPL999-SMS",
      mobile_number: "9999999999"
    )
    captured_message = nil

    SmsNotificationService.stub(:send_message, ->(_mobile_number, message) {
      captured_message = message
      { success: true }
    }) do
      EmployeeDetailsController.new.send(
        :send_sms_to_l1_after_observers,
        employee_detail,
        "Q2 (JUL-SEP)",
        "july"
      )
    end

    assert_includes captured_message, "has submitted his Q2 (JUL) Qtr KRA MIS"
    assert_not_includes captured_message, "Q2 (JUL-SEP) Qtr KRA MIS"
    assert_not_includes captured_message, "Monthly KRA MIS"
  end

  private

  def create_quarterly_pli_source(source_time: 1.day.ago)
    department = Department.create!(department_type: "HR")
    activity = Activity.create!(department: department, activity_name: "Hiring", unit: "Count", weight: 1)
    employee_detail = EmployeeDetail.create!(
      employee_name: "Nishchal Poundrik",
      employee_code: "PAPL063",
      department: "HR"
    )
    user_detail = UserDetail.create!(
      department: department,
      activity: activity,
      employee_detail: employee_detail,
      financial_year: "2026-2027",
      april: "100"
    )
    achievement = Achievement.create!(
      user_detail: user_detail,
      month: "april",
      achievement: "97",
      status: "l1_approved"
    )
    remark = AchievementRemark.create!(
      achievement: achievement,
      l1_remarks: "Approved",
      l1_percentage: 97
    )

    [ user_detail, achievement, remark ].each do |record|
      record.update_columns(created_at: source_time, updated_at: source_time)
    end
    employee_detail.reload

    [ employee_detail, user_detail, achievement, remark ]
  end

  def create_partial_month_submission_source(status: "pending", observer_code: "OBS001")
    department = Department.create!(department_type: "Accounts")
    employee_detail = EmployeeDetail.create!(
      employee_name: "Partial Progress Employee",
      employee_code: "PAPL999",
      department: "Accounts",
      obs_code1: observer_code
    )

    first_activity = Activity.create!(department: department, activity_name: "Submitted KRI", unit: "Count", weight: 1)
    second_activity = Activity.create!(department: department, activity_name: "Blank KRI", unit: "Count", weight: 1)

    first_detail = UserDetail.create!(
      department: department,
      activity: first_activity,
      employee_detail: employee_detail,
      financial_year: "2026-2027",
      april: "100"
    )
    UserDetail.create!(
      department: department,
      activity: second_activity,
      employee_detail: employee_detail,
      financial_year: "2026-2027",
      april: "100"
    )

    Achievement.create!(
      user_detail: first_detail,
      month: "april",
      achievement: "100",
      status: status
    )

    employee_detail.reload
  end
end
