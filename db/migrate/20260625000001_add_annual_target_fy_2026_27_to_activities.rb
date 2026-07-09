class AddAnnualTargetFy202627ToActivities < ActiveRecord::Migration[8.0]
  def change
    add_column :activities, :annual_target_fy_2026_27, :string
  end
end
