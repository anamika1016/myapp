class AddObserverRemarksToAchievementRemarks < ActiveRecord::Migration[7.1]
  def change
    add_column :achievement_remarks, :obs_code1_remarks, :text
    add_column :achievement_remarks, :obs_code2_remarks, :text
  end
end
