class SmsNotificationService
  API_URL = "https://sms.yoursmsbox.com/api/sendhttp.php".freeze
  AUTH_KEY = "37317061706c39353312".freeze
  SENDER = "PLOAPL".freeze
  DLT_TE_ID = "1707175594432371766".freeze

  def self.send_message(mobile_number, message)
    mobile = mobile_number.to_s.strip.gsub(/\D/, "")
    return { success: false, error: "Mobile number not found" } if mobile.blank?
    return { success: false, error: "Invalid mobile number format" } if mobile.length < 10

    require "httparty"

    response = HTTParty.get(
      API_URL,
      query: {
        authkey: AUTH_KEY,
        mobiles: mobile,
        message: message,
        sender: SENDER,
        route: "2",
        country: "0",
        DLT_TE_ID: DLT_TE_ID,
        unicode: "1"
      }
    )

    return { success: false, error: "SMS API HTTP error: #{response.code}" } unless response.success?

    response_data = JSON.parse(response.body)
    if response_data["Status"] == "Success" && response_data["Code"] == "000"
      {
        success: true,
        message: "SMS sent successfully",
        message_id: response_data["Message-Id"],
        response: response_data
      }
    else
      { success: false, error: "SMS API error: #{response_data['Description'] || response_data['Status']}" }
    end
  rescue JSON::ParserError => e
    Rails.logger.error "Failed to parse SMS API response: #{e.message}"
    { success: false, error: "Invalid SMS API response format" }
  rescue => e
    Rails.logger.error "SMS service error: #{e.message}"
    Rails.logger.error "Backtrace: #{e.backtrace.first(5).join("\n")}"
    { success: false, error: "SMS service error: #{e.message}" }
  end
end
