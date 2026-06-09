class AddUniqueIndexToUsersEmployeeCode < ActiveRecord::Migration[8.0]
  def change
    # Add unique index only if not already present
    unless index_exists?(:users, :employee_code, unique: true)
      add_index :users, :employee_code, unique: true
    end
  end
end