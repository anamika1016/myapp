class L1PulseAssessment < ApplicationRecord
  belongs_to :employee_detail
  belongs_to :l1_user, class_name: "User"

  validates :employee_detail_id, uniqueness: { scope: :l1_user_id }
  validates :values_alignment, :technical_knowledge, :customer_field_engagement,
            :execution_accountability, :initiative_leadership,
            :professionalism_conduct, :work_quality_accuracy, :initiative_problem_solving,
            :time_management_reliability, :growth_mindset_development,
            numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 5 },
            allow_nil: true
  validates :remark_score,
            numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 10 },
            allow_nil: true
end
