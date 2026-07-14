class AddPerformanceIndexesForUserDetails < ActiveRecord::Migration[8.0]
  def change
    add_index :employee_details, :employee_email, if_not_exists: true
    add_index :employee_details, :employee_code, if_not_exists: true
    add_index :employee_details, [ :employee_name, :department ], if_not_exists: true

    add_index :departments, [ :department_type, :employee_reference, :financial_year ],
              name: "index_departments_on_type_reference_year",
              if_not_exists: true

    add_index :activities, [ :department_id, :activity_name ],
              name: "index_activities_on_department_id_and_name",
              if_not_exists: true

    add_index :user_details, [ :financial_year, :employee_detail_id, :id ],
              name: "index_user_details_on_year_employee_id",
              if_not_exists: true
    add_index :user_details, [ :employee_detail_id, :financial_year, :department_id, :activity_id ],
              name: "index_user_details_on_employee_year_department_activity",
              if_not_exists: true
  end
end
