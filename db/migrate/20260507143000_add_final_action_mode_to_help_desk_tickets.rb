class AddFinalActionModeToHelpDeskTickets < ActiveRecord::Migration[8.0]
  def change
    add_column :help_desk_tickets, :final_action_mode, :string
  end
end
