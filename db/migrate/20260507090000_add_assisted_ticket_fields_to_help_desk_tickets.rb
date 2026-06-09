class AddAssistedTicketFieldsToHelpDeskTickets < ActiveRecord::Migration[8.0]
  def up
    add_reference :help_desk_tickets, :submitted_by_user, foreign_key: { to_table: :users }
    add_column :help_desk_tickets, :raised_on_behalf, :boolean, null: false, default: false

    execute <<~SQL.squish
      UPDATE help_desk_tickets
      SET submitted_by_user_id = user_id,
          raised_on_behalf = FALSE
      WHERE submitted_by_user_id IS NULL
    SQL
  end

  def down
    remove_reference :help_desk_tickets, :submitted_by_user, foreign_key: { to_table: :users }
    remove_column :help_desk_tickets, :raised_on_behalf
  end
end
