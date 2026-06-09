class AddReopenCountToHelpDeskTickets < ActiveRecord::Migration[8.0]
  def change
    add_column :help_desk_tickets, :reopen_count, :integer, default: 0, null: false
  end
end
