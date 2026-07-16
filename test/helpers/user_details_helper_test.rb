require "test_helper"

class UserDetailsHelperTest < ActionView::TestCase
  test "submitted quarter calculated percentage counts missing achievement target rows as zero" do
    _employee_detail, first_detail, second_detail = create_submitted_progress_source

    assert_equal 50.0, submitted_quarter_calculated_percentage([ first_detail, second_detail ], "Q1")
  end

  test "submitted final pli review is hidden when source changed after final save" do
    employee_detail, = create_submitted_progress_source
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

    assert_nil submitted_current_quarterly_pli_review_for(review, employee_detail.reload, "2026-2027", "Q1")
  end

  private

  def create_submitted_progress_source
    department = Department.create!(department_type: "Submitted Accounts")
    employee_detail = EmployeeDetail.create!(
      employee_name: "Submitted Progress Employee",
      employee_code: "PAPL998",
      department: "Submitted Accounts"
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
    second_detail = UserDetail.create!(
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
      status: "l1_approved"
    )

    [ employee_detail.reload, first_detail, second_detail ]
  end
end
