class CreateMonthMasters < ActiveRecord::Migration[8.0]
  def change
    create_table :month_masters do |t|
      t.string :month_name, null: false
      t.string :month_key, null: false
      t.string :financial_year, null: false
      t.boolean :active, default: true, null: false

      t.timestamps
    end

    add_index :month_masters, [ :financial_year, :month_key ], unique: true
    add_index :month_masters, :active
  end
end
