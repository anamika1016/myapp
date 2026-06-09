class CreateHelpdeskEscalationMatrices < ActiveRecord::Migration[8.0]
  def change
    create_table :helpdesk_escalation_matrices do |t|
      t.references :department, null: false, foreign_key: true, index: { unique: true }
      t.references :l1_user, null: false, foreign_key: { to_table: :users }
      t.references :l2_user, null: false, foreign_key: { to_table: :users }
      t.references :l3_user, null: false, foreign_key: { to_table: :users }

      t.timestamps
    end
  end
end
