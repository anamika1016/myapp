class ObserverPliReview < ApplicationRecord
  belongs_to :employee_detail
  belongs_to :reviewed_by, class_name: "User", optional: true

  validates :financial_year, :quarter, :observer_level, presence: true
  validates :quarter, inclusion: { in: %w[Q1 Q2 Q3 Q4] }
  validates :month, inclusion: { in: %w[april may june july august september october november december january february march] }, allow_blank: true
  validates :observer_level, inclusion: { in: ApplicationHelper::OBSERVER_LEVELS }
  validates :status, inclusion: { in: %w[approved returned] }
end
