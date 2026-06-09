class AddFinancialYearToDepartments < ActiveRecord::Migration[8.0]
  def up
    add_column :departments, :financial_year, :string
    add_index :departments, :financial_year

    department_model = Class.new(ActiveRecord::Base) do
      self.table_name = "departments"
    end

    department_model.reset_column_information
    department_model.where(financial_year: [ nil, "" ]).update_all(financial_year: "2025-2026")
  end

  def down
    remove_index :departments, :financial_year
    remove_column :departments, :financial_year
  end
end
