class AppSetting < ApplicationRecord
  QUARTERLY_PLI_MENU_ENABLED_KEY = "quarterly_pli_menu_enabled"

  validates :key, presence: true, uniqueness: true

  def self.boolean_value(key, default: true)
    value = find_by(key: key)&.value
    return default if value.nil?

    ActiveModel::Type::Boolean.new.cast(value)
  end

  def self.set_boolean(key, value)
    setting = find_or_initialize_by(key: key)
    setting.value = value ? "true" : "false"
    setting.save!
    value
  end

  def self.quarterly_pli_menu_enabled?
    boolean_value(QUARTERLY_PLI_MENU_ENABLED_KEY, default: true)
  end

  def self.set_quarterly_pli_menu_enabled(value)
    set_boolean(QUARTERLY_PLI_MENU_ENABLED_KEY, value)
  end
end
