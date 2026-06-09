class AddOfficeFieldsToEmployeeDetails < ActiveRecord::Migration[8.0]
  def change
    add_column :employee_details, :office_type, :string
    add_column :employee_details, :office_name, :string
  end
end
