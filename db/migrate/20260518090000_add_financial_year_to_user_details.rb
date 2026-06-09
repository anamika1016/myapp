class AddFinancialYearToUserDetails < ActiveRecord::Migration[8.0]
  def up
    add_column :user_details, :financial_year, :string

    legacy_financial_year = "2025-2026"

    user_detail_model = Class.new(ActiveRecord::Base) do
      self.table_name = "user_details"
    end

    user_detail_model.reset_column_information
    user_detail_model.where(financial_year: [ nil, "" ]).update_all(financial_year: legacy_financial_year)

    add_index :user_details, :financial_year
    add_index :user_details, [ :employee_detail_id, :activity_id, :financial_year ],
              name: "index_user_details_on_employee_activity_financial_year"
  end

  def down
    remove_index :user_details, name: "index_user_details_on_employee_activity_financial_year"
    remove_index :user_details, :financial_year
    remove_column :user_details, :financial_year
  end
end
