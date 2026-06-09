class AddEscalationFlowToHelpDeskTickets < ActiveRecord::Migration[8.0]
  def up
    add_reference :help_desk_tickets, :assigned_to_user, foreign_key: { to_table: :users }
    add_reference :help_desk_tickets, :responded_by_user, foreign_key: { to_table: :users }
    add_column :help_desk_tickets, :current_escalation_position, :integer, null: false, default: 1
    add_column :help_desk_tickets, :assigned_at, :datetime
    add_column :help_desk_tickets, :escalation_due_at, :datetime
    add_column :help_desk_tickets, :response_message, :text
    add_column :help_desk_tickets, :responded_at, :datetime

    add_index :help_desk_tickets, :escalation_due_at
    add_index :help_desk_tickets,
              [ :assigned_to_user_id, :status ],
              name: "index_help_desk_tickets_on_assignee_and_status"

    backfill_existing_help_desk_tickets
  end

  def down
    remove_index :help_desk_tickets, name: "index_help_desk_tickets_on_assignee_and_status"
    remove_index :help_desk_tickets, :escalation_due_at

    remove_column :help_desk_tickets, :responded_at
    remove_column :help_desk_tickets, :response_message
    remove_column :help_desk_tickets, :escalation_due_at
    remove_column :help_desk_tickets, :assigned_at
    remove_column :help_desk_tickets, :current_escalation_position
    remove_reference :help_desk_tickets, :responded_by_user, foreign_key: { to_table: :users }
    remove_reference :help_desk_tickets, :assigned_to_user, foreign_key: { to_table: :users }
  end

  private

  def backfill_existing_help_desk_tickets
    ticket_class = Class.new(ActiveRecord::Base) do
      self.table_name = "help_desk_tickets"
    end

    matrix_class = Class.new(ActiveRecord::Base) do
      self.table_name = "helpdesk_escalation_matrices"
    end

    level_class = Class.new(ActiveRecord::Base) do
      self.table_name = "helpdesk_escalation_levels"
    end

    matrices_by_department = matrix_class.all.index_by(&:department_id)

    ticket_class.where(assigned_to_user_id: nil).find_each do |ticket|
      next if ticket.status == "resolved"

      matrix = matrices_by_department[ticket.department_id]
      next if matrix.blank?

      first_level = level_class.where(helpdesk_escalation_matrix_id: matrix.id).order(:position).first
      next if first_level.blank?

      assignment_time = ticket.created_at || Time.current

      ticket.update_columns(
        assigned_to_user_id: first_level.user_id,
        current_escalation_position: first_level.position,
        assigned_at: assignment_time,
        escalation_due_at: assignment_time + 2.days
      )
    end
  end
end
