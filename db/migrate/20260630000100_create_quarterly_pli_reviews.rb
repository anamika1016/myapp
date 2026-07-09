class CreateQuarterlyPliReviews < ActiveRecord::Migration[8.0]
  def change
    create_table :quarterly_pli_reviews do |t|
      t.references :employee_detail, null: false, foreign_key: true
      t.string :financial_year, null: false
      t.string :quarter, null: false
      t.text :final_remarks
      t.float :final_percentage
      t.references :reviewed_by, foreign_key: { to_table: :users }
      t.datetime :reviewed_at

      t.timestamps
    end

    add_index :quarterly_pli_reviews,
              [ :employee_detail_id, :financial_year, :quarter ],
              unique: true,
              name: "index_quarterly_pli_reviews_unique_quarter"
  end
end
