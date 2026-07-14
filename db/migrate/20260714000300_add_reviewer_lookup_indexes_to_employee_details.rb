class AddReviewerLookupIndexesToEmployeeDetails < ActiveRecord::Migration[8.0]
  def change
    add_index :employee_details,
              "LOWER(TRIM(COALESCE(l1_code, '')))",
              name: "index_employee_details_on_normalized_l1_code",
              if_not_exists: true
    add_index :employee_details,
              "LOWER(TRIM(COALESCE(l1_employer_name, '')))",
              name: "index_employee_details_on_normalized_l1_name",
              if_not_exists: true
    add_index :employee_details,
              "LOWER(TRIM(COALESCE(l2_code, '')))",
              name: "index_employee_details_on_normalized_l2_code",
              if_not_exists: true
    add_index :employee_details,
              "LOWER(TRIM(COALESCE(l2_employer_name, '')))",
              name: "index_employee_details_on_normalized_l2_name",
              if_not_exists: true
  end
end
