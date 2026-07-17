require "test_helper"

class EmployeeDetailTest < ActiveSupport::TestCase
  test "portal role update syncs matching user by employee code when employee email is blank" do
    user = User.create!(
      email: "neeraj.mansharamani@ploughmanagro.com",
      employee_code: "PAPL073",
      role: "hod",
      password: "123456",
      password_confirmation: "123456"
    )
    employee = EmployeeDetail.create!(
      employee_name: "Neeraj mansharamani",
      employee_code: "PAPL073",
      portal_active: true
    )

    assert_equal user, employee.reload.user
    assert_equal "hod", employee.portal_role

    employee.update!(portal_role: "employee")

    assert_equal "employee", user.reload.role
    assert_equal user, employee.reload.user
    assert_equal "employee", employee.portal_role
  end

  test "code only employee without matching user does not create invalid portal account" do
    assert_no_difference("User.count") do
      EmployeeDetail.create!(
        employee_name: "Code Only Employee",
        employee_code: "PAPL999",
        portal_active: true
      )
    end
  end
end
