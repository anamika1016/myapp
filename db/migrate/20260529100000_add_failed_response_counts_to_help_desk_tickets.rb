class AddFailedResponseCountsToHelpDeskTickets < ActiveRecord::Migration[8.0]
  def change
    add_column :help_desk_tickets, :failed_response_counts, :jsonb, null: false, default: {}
  end
end
