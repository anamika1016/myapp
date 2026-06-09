class CreateHelpDeskQuestionMastersAndAddQuestionFields < ActiveRecord::Migration[8.0]
  def change
    create_table :help_desk_question_masters do |t|
      t.references :department, null: false, foreign_key: true
      t.string :request_type, null: false
      t.text :question_text, null: false
      t.integer :position, null: false, default: 1
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :help_desk_question_masters, [ :department_id, :request_type, :position ], name: "index_help_desk_question_masters_on_context_and_position"
    add_index :help_desk_question_masters, [ :department_id, :request_type, :active ], name: "index_help_desk_question_masters_on_context_and_active"

    add_reference :help_desk_tickets, :help_desk_question_master, foreign_key: { on_delete: :nullify }
    add_column :help_desk_tickets, :question_subject, :text
  end
end
