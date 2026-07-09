class AddReportingManagerRemarksToAchievementRemarks < ActiveRecord::Migration[8.0]
  def change
    add_column :achievement_remarks, :reporting_manager_remarks, :text
  end
end
