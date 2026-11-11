class CreateAchievementAttachments < ActiveRecord::Migration[8.0]
  def change
    create_table :achievement_attachments do |t|
      t.references :employee_detail, null: false, foreign_key: true
      t.string :financial_year, null: false
      t.string :month, null: false

      t.timestamps
    end

    add_index :achievement_attachments, [ :employee_detail_id, :financial_year, :month ],
              unique: true, name: "index_achievement_attachments_on_employee_fy_month"
  end
end
