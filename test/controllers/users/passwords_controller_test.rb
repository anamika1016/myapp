require "test_helper"

class Users::PasswordsControllerTest < ActionDispatch::IntegrationTest
  test "employee code reset updates the same account used by login" do
    user = User.create!(
      email: "portal.employee@example.com",
      employee_code: "EMP900",
      role: "employee",
      password: "123456",
      password_confirmation: "123456"
    )

    post user_password_path, params: { user: { employee_code: " emp900 " } }

    user.reload
    reset_token = Rack::Utils.parse_query(URI.parse(response.location).query)["reset_password_token"]
    assert_redirected_to edit_user_password_path(reset_password_token: reset_token)
    assert user.valid_password?("123456")

    put user_password_path, params: {
      user: {
        reset_password_token: reset_token,
        password: "654321",
        password_confirmation: "654321"
      }
    }

    user.reload
    assert_not user.valid_password?("123456")
    assert user.valid_password?("654321")

    delete destroy_user_session_path
    post user_session_path, params: { user: { employee_code: "EMP900", password: "654321" } }

    assert_redirected_to settings_path
  end
end
