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
end
