class AddMonthToObserverPliReviews < ActiveRecord::Migration[8.0]
  def change
    add_column :observer_pli_reviews, :month, :string

    remove_index :observer_pli_reviews, name: "index_observer_pli_reviews_unique_level", if_exists: true
    add_index :observer_pli_reviews,
              [ :employee_detail_id, :financial_year, :quarter, :month, :observer_level ],
              unique: true,
              name: "index_observer_pli_reviews_unique_month_level"
  end
end
