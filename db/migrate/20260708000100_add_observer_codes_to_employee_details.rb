class AddObserverCodesToEmployeeDetails < ActiveRecord::Migration[8.0]
  def change
    add_column :employee_details, :obs_code1, :string
    add_column :employee_details, :obs_code2, :string

    add_index :employee_details, :obs_code1
    add_index :employee_details, :obs_code2
  end
end
