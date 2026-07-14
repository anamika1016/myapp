class AddRecipientTrackingToSmsLogs < ActiveRecord::Migration[8.0]
  def change
    add_column :sms_logs, :month, :string unless column_exists?(:sms_logs, :month)
    add_column :sms_logs, :recipient_role, :string, default: "l1" unless column_exists?(:sms_logs, :recipient_role)
    add_column :sms_logs, :recipient_employee_detail_id, :bigint unless column_exists?(:sms_logs, :recipient_employee_detail_id)
    add_column :sms_logs, :observer_level, :string unless column_exists?(:sms_logs, :observer_level)

    add_index :sms_logs,
              [ :employee_detail_id, :quarter, :month, :recipient_role, :observer_level ],
              name: "index_sms_logs_on_review_notification",
              if_not_exists: true
    add_index :sms_logs, :recipient_employee_detail_id, if_not_exists: true
  end
end
