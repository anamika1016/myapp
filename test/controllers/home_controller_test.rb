require "test_helper"

class HomeControllerTest < ActionDispatch::IntegrationTest
  test "should get index" do
    get home_index_url
    assert_response :success
  end

  test "annual percentage uses only scored quarters as denominator" do
    controller = HomeController.new

    summaries = [
      { name: "Q1", percentage: 80.0, scored: true },
      { name: "Q2", percentage: 90.0, scored: true },
      { name: "Q3", percentage: 0.0, scored: false },
      { name: "Q4", percentage: 0.0, scored: false }
    ]

    assert_equal 85.0, controller.send(:annual_percentage_for, summaries)
    assert_equal 80.0, controller.send(:annual_percentage_for, [ summaries.first ])
    assert_equal 0.0, controller.send(:annual_percentage_for, [ { name: "Q1", percentage: 0.0, scored: false } ])
  end
end
