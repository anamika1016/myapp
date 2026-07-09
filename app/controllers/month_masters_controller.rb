class MonthMastersController < ApplicationController
  require "axlsx"
  require "roo"

  before_action :require_master_access!
  before_action :set_month_master, only: [ :update, :destroy, :toggle_status ]

  def index
    @month_master = MonthMaster.new
    @month_options = MonthMaster.month_options
    @financial_years = month_master_financial_year_options
    @month_masters = MonthMaster.ordered.order(created_at: :desc)
    @month_masters = @month_masters.where("month_name ILIKE :query OR financial_year ILIKE :query", query: "%#{params[:q]}%") if params[:q].present?
  end

  def create
    @month_master = MonthMaster.new(month_master_params)
    @month_master.active = true if params.dig(:month_master, :active).nil?

    if @month_master.save
      redirect_to month_masters_path, notice: "Month saved successfully."
    else
      redirect_to month_masters_path, alert: @month_master.errors.full_messages.to_sentence
    end
  end

  def update
    if @month_master.update(month_master_params)
      redirect_to month_masters_path, notice: "Month updated successfully."
    else
      redirect_to month_masters_path, alert: @month_master.errors.full_messages.to_sentence
    end
  end

  def destroy
    @month_master.destroy
    redirect_to month_masters_path, notice: "Month deleted successfully."
  end

  def toggle_status
    @month_master.update!(active: !@month_master.active?)
    redirect_to month_masters_path, notice: "#{@month_master.month_name} marked #{@month_master.active? ? 'active' : 'inactive'}."
  end

  def import
    unless params[:file].present?
      redirect_to month_masters_path, alert: "Please choose an Excel file."
      return
    end

    spreadsheet = Roo::Spreadsheet.open(params[:file].path)
    headers = spreadsheet.row(1).map { |header| header.to_s.strip.downcase }
    saved_count = 0

    (2..spreadsheet.last_row).each do |row_number|
      row = Hash[headers.zip(spreadsheet.row(row_number))]
      month_name = row["month name"] || row["month"] || row["month_name"]
      financial_year = row["financial year"] || row["financial_year"]
      status = row["status"].to_s.strip.downcase
      next if month_name.blank? || financial_year.blank?

      month_key = month_name.to_s.strip.downcase
      record = MonthMaster.find_or_initialize_by(
        month_key: month_key,
        financial_year: normalize_financial_year(financial_year)
      )
      record.month_name = month_name
      record.active = status.present? ? status == "active" : true
      saved_count += 1 if record.save
    end

    redirect_to month_masters_path, notice: "#{saved_count} month records uploaded."
  rescue StandardError => e
    redirect_to month_masters_path, alert: "Upload failed: #{e.message}"
  end

  def export
    package = Axlsx::Package.new
    workbook = package.workbook

    workbook.add_worksheet(name: "Month Master") do |sheet|
      sheet.add_row [ "Month Name", "Financial Year", "Status", "Saved At" ]
      MonthMaster.ordered.order(created_at: :desc).each do |record|
        sheet.add_row [
          record.month_name,
          record.financial_year,
          record.active? ? "Active" : "Inactive",
          record.created_at&.strftime("%d-%m-%Y %I:%M %p")
        ]
      end
    end

    tempfile = Tempfile.new([ "month_master", ".xlsx" ])
    package.serialize(tempfile.path)
    send_file tempfile.path, filename: "month_master.xlsx", type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  ensure
    tempfile&.close
    tempfile&.unlink
  end

  private

  def require_master_access!
    return if current_user.hod? || current_user.admin?

    redirect_to dashboard_path, alert: "You are not authorized to access Month Master."
  end

  def set_month_master
    @month_master = MonthMaster.find(params[:id])
  end

  def month_master_params
    params.require(:month_master).permit(:month_name, :financial_year, :active)
  end

  def month_master_financial_year_options
    start_year = Date.current.month >= 4 ? Date.current.year : Date.current.year - 1
    nearby_years = ((start_year - 1)..(start_year + 1)).map { |year| "#{year}-#{year + 1}" }
    (MonthMaster.financial_year_options + nearby_years).uniq.sort.reverse
  end
end
