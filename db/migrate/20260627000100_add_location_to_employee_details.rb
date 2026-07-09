class AddLocationToEmployeeDetails < ActiveRecord::Migration[8.0]
  def change
    add_column :employee_details, :location, :string
  end
end
