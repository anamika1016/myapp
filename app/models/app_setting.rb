class AppSetting < ApplicationRecord
  QUARTERLY_PLI_MENU_ENABLED_KEY = "quarterly_pli_menu_enabled"
  SIDEBAR_MENU_KEYS = {
    "observer_menu_1" => "observer_menu_1_enabled",
    "observer_menu_2" => "observer_menu_2_enabled",
    "observer_menu_3" => "observer_menu_3_enabled",
    "observer_menu_4" => "observer_menu_4_enabled",
    "l1_employee_details" => "l1_employee_details_menu_enabled"
  }.freeze

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

  def self.sidebar_menu_key_for(menu_key)
    SIDEBAR_MENU_KEYS.fetch(menu_key.to_s)
  end

  def self.sidebar_menu_enabled?(menu_key)
    boolean_value(sidebar_menu_key_for(menu_key), default: true)
  end

  def self.set_sidebar_menu_enabled(menu_key, value)
    set_boolean(sidebar_menu_key_for(menu_key), value)
  end

  def self.toggle_sidebar_menu_enabled(menu_key)
    set_sidebar_menu_enabled(menu_key, !sidebar_menu_enabled?(menu_key))
  end
end
