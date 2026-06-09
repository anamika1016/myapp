class AddPortalActiveToEmployeeDetails < ActiveRecord::Migration[8.0]
  def change
    add_column :employee_details, :portal_active, :boolean, default: true, null: false
  end
end
