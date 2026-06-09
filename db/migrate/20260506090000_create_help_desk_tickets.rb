class CreateHelpDeskTickets < ActiveRecord::Migration[8.0]
  def change
    create_table :help_desk_tickets do |t|
      t.references :user, null: false, foreign_key: true
      t.references :department, null: false, foreign_key: true
      t.string :request_type, null: false
      t.string :status, null: false, default: "submitted"
      t.string :requester_name, null: false
      t.string :requester_email, null: false
      t.string :requester_employee_code
      t.text :message, null: false

      t.timestamps
    end

    add_index :help_desk_tickets, :request_type
    add_index :help_desk_tickets, :status
    add_index :help_desk_tickets, [ :user_id, :created_at ]
  end
end
