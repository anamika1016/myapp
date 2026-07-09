class AddObserverCodes3And4 < ActiveRecord::Migration[8.0]
  def change
    add_column :employee_details, :obs_code3, :string
    add_column :employee_details, :obs_code4, :string
    add_index :employee_details, :obs_code3
    add_index :employee_details, :obs_code4

    add_column :achievement_remarks, :obs_code3_remarks, :text
    add_column :achievement_remarks, :obs_code4_remarks, :text
  end
end
