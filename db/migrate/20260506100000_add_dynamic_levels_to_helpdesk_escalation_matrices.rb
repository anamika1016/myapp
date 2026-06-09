class AddDynamicLevelsToHelpdeskEscalationMatrices < ActiveRecord::Migration[8.0]
  def up
    change_column_null :helpdesk_escalation_matrices, :l1_user_id, true
    change_column_null :helpdesk_escalation_matrices, :l2_user_id, true
    change_column_null :helpdesk_escalation_matrices, :l3_user_id, true

    create_table :helpdesk_escalation_levels do |t|
      t.references :helpdesk_escalation_matrix, null: false, foreign_key: true, index: { name: "index_helpdesk_levels_on_matrix_id" }
      t.references :user, null: false, foreign_key: true
      t.integer :position, null: false

      t.timestamps
    end

    add_index :helpdesk_escalation_levels,
              [ :helpdesk_escalation_matrix_id, :position ],
              unique: true,
              name: "index_helpdesk_levels_on_matrix_and_position"

    migrate_existing_escalation_users
  end

  def down
    drop_table :helpdesk_escalation_levels

    change_column_null :helpdesk_escalation_matrices, :l1_user_id, false
    change_column_null :helpdesk_escalation_matrices, :l2_user_id, false
    change_column_null :helpdesk_escalation_matrices, :l3_user_id, false
  end

  private

  def migrate_existing_escalation_users
    matrix_class = Class.new(ActiveRecord::Base) do
      self.table_name = "helpdesk_escalation_matrices"
    end

    level_class = Class.new(ActiveRecord::Base) do
      self.table_name = "helpdesk_escalation_levels"
    end

    matrix_class.find_each do |matrix|
      [
        [ 1, matrix.l1_user_id ],
        [ 2, matrix.l2_user_id ],
        [ 3, matrix.l3_user_id ]
      ].each do |position, user_id|
        next if user_id.blank?

        level_class.create!(
          helpdesk_escalation_matrix_id: matrix.id,
          user_id: user_id,
          position: position
        )
      end
    end
  end
end
