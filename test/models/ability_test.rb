require "test_helper"

class AbilityTest < ActiveSupport::TestCase
  test "administrator can edit and delete target records" do
    ability = Ability.new(User.new(role: "admin"))
    detail = UserDetail.new

    assert ability.can?(:edit, detail)
    assert ability.can?(:update, detail)
    assert ability.can?(:destroy, detail)
  end

  test "employee cannot delete another employee's target record" do
    user = User.new(id: 101, role: "employee", email: "employee@example.com", employee_code: "PAPL101")
    detail = UserDetail.new(employee_detail: EmployeeDetail.new(
      user_id: 102, employee_email: "other@example.com", employee_code: "PAPL102"
    ))

    assert_not Ability.new(user).can?(:destroy, detail)
  end
end
