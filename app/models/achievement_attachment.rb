class AchievementAttachment < ApplicationRecord
  MAX_FILES = 1
  ALLOWED_EXTENSIONS = %w[xlsx xls].freeze

  belongs_to :employee_detail
  has_many_attached :files

  validates :financial_year, :month, presence: true
  validate :files_within_limit
  validate :files_have_allowed_extension

  private

  def files_within_limit
    return unless files.attached?

    errors.add(:files, "can have at most #{MAX_FILES} file".pluralize(MAX_FILES)) if files.count > MAX_FILES
  end

  def files_have_allowed_extension
    return unless files.attached?

    files.each do |file|
      extension = File.extname(file.filename.to_s).delete(".").downcase
      next if ALLOWED_EXTENSIONS.include?(extension)

      errors.add(:files, "#{file.filename}: file type .#{extension} is not allowed")
    end
  end
end
