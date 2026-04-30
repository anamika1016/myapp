class AddGroupedPulseFieldsToL1PulseAssessments < ActiveRecord::Migration[8.0]
  def up
    add_column :l1_pulse_assessments, :values_alignment, :decimal, precision: 3, scale: 1
    add_column :l1_pulse_assessments, :technical_knowledge, :decimal, precision: 3, scale: 1
    add_column :l1_pulse_assessments, :customer_field_engagement, :decimal, precision: 3, scale: 1
    add_column :l1_pulse_assessments, :execution_accountability, :decimal, precision: 3, scale: 1
    add_column :l1_pulse_assessments, :initiative_leadership, :decimal, precision: 3, scale: 1

    execute <<~SQL.squish
      UPDATE l1_pulse_assessments
      SET
        values_alignment = ROUND((COALESCE(sense_of_purpose, 0) + COALESCE(workload_balance, 0)) / NULLIF(
          (CASE WHEN sense_of_purpose IS NOT NULL THEN 1 ELSE 0 END) +
          (CASE WHEN workload_balance IS NOT NULL THEN 1 ELSE 0 END), 0
        ), 1),
        technical_knowledge = ROUND((COALESCE(manager_effectiveness, 0) + COALESCE(team_collaboration, 0)) / NULLIF(
          (CASE WHEN manager_effectiveness IS NOT NULL THEN 1 ELSE 0 END) +
          (CASE WHEN team_collaboration IS NOT NULL THEN 1 ELSE 0 END), 0
        ), 1),
        customer_field_engagement = ROUND((COALESCE(recognition_growth, 0) + COALESCE(org_communication, 0)) / NULLIF(
          (CASE WHEN recognition_growth IS NOT NULL THEN 1 ELSE 0 END) +
          (CASE WHEN org_communication IS NOT NULL THEN 1 ELSE 0 END), 0
        ), 1),
        execution_accountability = ROUND((COALESCE(learning_development, 0) + COALESCE(role_clarity, 0)) / NULLIF(
          (CASE WHEN learning_development IS NOT NULL THEN 1 ELSE 0 END) +
          (CASE WHEN role_clarity IS NOT NULL THEN 1 ELSE 0 END), 0
        ), 1),
        initiative_leadership = ROUND((COALESCE(work_environment, 0) + COALESCE(commitment_retention, 0)) / NULLIF(
          (CASE WHEN work_environment IS NOT NULL THEN 1 ELSE 0 END) +
          (CASE WHEN commitment_retention IS NOT NULL THEN 1 ELSE 0 END), 0
        ), 1)
    SQL
  end

  def down
    remove_column :l1_pulse_assessments, :initiative_leadership
    remove_column :l1_pulse_assessments, :execution_accountability
    remove_column :l1_pulse_assessments, :customer_field_engagement
    remove_column :l1_pulse_assessments, :technical_knowledge
    remove_column :l1_pulse_assessments, :values_alignment
  end
end
