class AddStatusToQuarterlyPliReviews < ActiveRecord::Migration[8.0]
  def change
    add_column :quarterly_pli_reviews, :status, :string, default: "approved", null: false
  end
end
