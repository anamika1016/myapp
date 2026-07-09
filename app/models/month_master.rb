class MonthMaster < ApplicationRecord
  attribute :active, :boolean, default: true

  MONTHS = %w[
    april may june july august september october november december january february march
  ].freeze

  before_validation :normalize_values

  validates :month_name, :month_key, :financial_year, presence: true
  validates :month_key, inclusion: { in: MONTHS }
  validates :month_key, uniqueness: { scope: :financial_year, message: "already exists for this financial year" }

  scope :active, -> { where(active: true) }
  scope :ordered, -> {
    order(
      Arel.sql(
        "CASE month_key #{MONTHS.each_with_index.map { |month, index| "WHEN '#{month}' THEN #{index}" }.join(' ')} ELSE 99 END"
      )
    )
  }

  def self.month_options
    labels = {
      "april" => "APR",
      "may" => "MAY",
      "june" => "JUN",
      "july" => "JUL",
      "august" => "AUG",
      "september" => "SEP",
      "october" => "OCT",
      "november" => "NOV",
      "december" => "DEC",
      "january" => "JAN",
      "february" => "FEB",
      "march" => "MAR"
    }

    MONTHS.map { |month| [ labels.fetch(month, month.upcase), month ] }
  end

  def self.financial_year_options
    distinct.where.not(financial_year: [ nil, "" ]).order(financial_year: :desc).pluck(:financial_year)
  end

  private

  def normalize_values
    self.month_key = month_name.to_s.strip.downcase if month_key.blank?
    self.month_key = month_key.to_s.strip.downcase
    self.month_name = month_key.titleize if month_key.present?
    self.financial_year = normalize_financial_year(financial_year)
  end

  def normalize_financial_year(value)
    year = value.to_s.strip
    return year if year.blank?

    match = year.match(/\A(\d{4})\s*-\s*(\d{2}|\d{4})\z/)
    return year unless match

    start_year = match[1].to_i
    end_year = match[2].length == 2 ? ((start_year / 100) * 100) + match[2].to_i : match[2].to_i
    end_year += 100 if end_year <= start_year

    "#{start_year}-#{end_year}"
  end
end
