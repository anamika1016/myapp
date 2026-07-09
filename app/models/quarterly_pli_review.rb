class QuarterlyPliReview < ApplicationRecord
  belongs_to :employee_detail
  belongs_to :reviewed_by, class_name: "User", optional: true

  validates :financial_year, :quarter, presence: true
  validates :quarter, inclusion: { in: %w[Q1 Q2 Q3 Q4] }
  validates :status, inclusion: { in: %w[approved returned] }
  validates :final_percentage,
            numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 },
            allow_nil: true
end
