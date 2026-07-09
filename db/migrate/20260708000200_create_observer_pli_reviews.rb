class CreateObserverPliReviews < ActiveRecord::Migration[8.0]
  def change
    create_table :observer_pli_reviews do |t|
      t.references :employee_detail, null: false, foreign_key: true
      t.string :financial_year, null: false
      t.string :quarter, null: false
      t.string :observer_level, null: false
      t.string :status, default: "approved", null: false
      t.text :final_remarks
      t.references :reviewed_by, foreign_key: { to_table: :users }
      t.datetime :reviewed_at

      t.timestamps
    end

    add_index :observer_pli_reviews,
              [ :employee_detail_id, :financial_year, :quarter, :observer_level ],
              unique: true,
              name: "index_observer_pli_reviews_unique_level"
  end
end
