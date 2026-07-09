class Activity < ApplicationRecord
  belongs_to :department

  alias_attribute :key_result_indicator, :activity_name
  alias_attribute :annual_target_fy, :annual_target_fy_2026_27

  has_many :user_details
end
