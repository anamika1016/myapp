class NormalizeFinancialYearFormats < ActiveRecord::Migration[8.0]
  def up
    normalize_table_financial_years("user_details")
    normalize_table_financial_years("departments")
  end

  def down
    # No-op: full financial-year format is the canonical stored format.
  end

  private

  def normalize_table_financial_years(table_name)
    return unless column_exists?(table_name, :financial_year)

    model = Class.new(ActiveRecord::Base) do
      self.table_name = table_name
    end

    model.reset_column_information
    model.where.not(financial_year: [ nil, "" ]).distinct.pluck(:financial_year).each do |year|
      normalized_year = normalize_financial_year(year)
      next if normalized_year.blank? || normalized_year == year

      model.where(financial_year: year).update_all(financial_year: normalized_year)
    end
  end

  def normalize_financial_year(value)
    year = value.to_s.strip
    match = year.match(/\A(\d{4})\s*-\s*(\d{2}|\d{4})\z/)
    return year unless match

    start_year = match[1].to_i
    end_year = match[2].length == 2 ? ((start_year / 100) * 100) + match[2].to_i : match[2].to_i
    end_year += 100 if end_year <= start_year

    "#{start_year}-#{end_year}"
  end
end
