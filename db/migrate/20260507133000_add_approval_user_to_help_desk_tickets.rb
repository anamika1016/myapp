class AddApprovalUserToHelpDeskTickets < ActiveRecord::Migration[8.0]
  def change
    add_reference :help_desk_tickets, :approval_user, foreign_key: { to_table: :users }, index: true
  end
end
