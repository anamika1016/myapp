class AddRequestReceivedAtToHelpDeskTickets < ActiveRecord::Migration[8.0]
  def up
    add_column :help_desk_tickets, :request_received_at, :datetime

    execute <<~SQL
      UPDATE help_desk_tickets
      SET request_received_at = created_at
      WHERE raised_on_behalf = TRUE
        AND request_received_at IS NULL
    SQL
  end

  def down
    remove_column :help_desk_tickets, :request_received_at
  end
end
