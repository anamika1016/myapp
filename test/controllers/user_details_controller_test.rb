require "test_helper"

class UserDetailsControllerTest < ActionDispatch::IntegrationTest
  test "should get new" do
    get user_details_new_url
    assert_response :success
  end

  test "should get show" do
    get user_details_show_url
    assert_response :success
  end

  test "should get index" do
    get user_details_index_url
    assert_response :success
  end

  test "submission sms message keeps quarter template with submitted month when month is present" do
    employee_detail = EmployeeDetail.new(
      employee_code: "PAPL126",
      employee_name: "Anamika Vishwakarma"
    )

    message = UserDetailsController.new.send(
      :kra_submission_sms_message,
      employee_detail,
      "Q2 (JUL-SEP)",
      "july"
    )

    assert_includes message, "has submitted his Q2 (JUL) Qtr KRA MIS"
    assert_not_includes message, "Q2 (JUL-SEP) Qtr KRA MIS"
    assert_not_includes message, "Monthly KRA MIS"
  end

  test "submission sms message falls back to quarter wording without month" do
    employee_detail = EmployeeDetail.new(
      employee_code: "PAPL126",
      employee_name: "Anamika Vishwakarma"
    )

    message = UserDetailsController.new.send(
      :kra_submission_sms_message,
      employee_detail,
      "Q2 (JUL-SEP)",
      nil
    )

    assert_includes message, "has submitted his Q2 (JUL-SEP) Qtr KRA MIS"
  end
end
