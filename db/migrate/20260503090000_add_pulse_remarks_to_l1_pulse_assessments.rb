class AddPulseRemarksToL1PulseAssessments < ActiveRecord::Migration[8.0]
  def change
    add_column :l1_pulse_assessments, :pulse_remarks, :text
  end
end
