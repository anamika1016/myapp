class CreateHelpDeskSupportUpdates < ActiveRecord::Migration[8.0]
  def change
    create_table :help_desk_support_updates do |t|
      t.references :help_desk_ticket, null: false, foreign_key: true, index: { name: "index_help_desk_support_updates_on_ticket_id" }
      t.references :user, null: true, foreign_key: true, index: { name: "index_help_desk_support_updates_on_user_id" }
      t.text :message, null: false

      t.timestamps
    end

    add_index :help_desk_support_updates, [ :help_desk_ticket_id, :created_at ], name: "index_help_desk_support_updates_on_ticket_and_created_at"
  end
end
