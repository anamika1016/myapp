class AddRequesterResolutionFlowToHelpDeskTickets < ActiveRecord::Migration[8.0]
  def change
    add_column :help_desk_tickets, :requester_response_due_at, :datetime
    add_column :help_desk_tickets, :requester_remark, :text
    add_column :help_desk_tickets, :closed_at, :datetime
    add_column :help_desk_tickets, :closed_automatically, :boolean, null: false, default: false
    add_reference :help_desk_tickets, :closed_by_user, foreign_key: { to_table: :users }

    add_index :help_desk_tickets, :requester_response_due_at
  end
end
