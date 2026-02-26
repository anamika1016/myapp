class Training < ApplicationRecord
  has_many_attached :files
  has_many :user_training_progresses, dependent: :destroy

  validates :title, presence: true
  validates :duration, presence: true
  validates :month, presence: true
  validates :year, presence: true

  def month_name
    Date::MONTHNAMES[month.to_i]
  end

  scope :active, -> { where(status: true) }
  scope :inactive, -> { where(status: false) }
end
