module ApplicationHelper
  def current_user_detail
    current_user&.user_detail
  end

  def asset_to_base64(asset_name)
    path = Rails.root.join("app", "assets", "images", asset_name)
    if File.exist?(path)
      content = File.binread(path)
      ext = File.extname(asset_name).downcase.delete(".")
      mime_type = case ext
      when "jpg", "jpeg" then "image/jpeg"
      when "png" then "image/png"
      else "image/#{ext}"
      end
      "data:#{mime_type};base64,#{Base64.strict_encode64(content)}"
    else
      Rails.logger.error "ASSET NOT FOUND: #{path}"
      ""
    end
  end

  def user_display_name(user)
    user&.display_name.presence || user&.email.presence || "User"
  end

  def help_desk_status_label(ticket)
    return "Overdue" if ticket.respond_to?(:overdue_for_response?) && ticket.overdue_for_response?

    case ticket.status.to_s
    when "submitted"
      "Submitted"
    when "in_review"
      "In Review"
    when "reopened"
      "Reopened"
    when "resolved"
      ticket.respond_to?(:final_action_mode_label) ? ticket.final_action_mode_label : "Awaiting User"
    when "closed"
      ticket.respond_to?(:closed_automatically?) && ticket.closed_automatically? ? "Auto Closed" : "Closed"
    else
      ticket.status.to_s.humanize.presence || "Pending"
    end
  end

  def help_desk_status_badge_tone(ticket)
    return "helpdesk-badge--danger" if ticket.respond_to?(:overdue_for_response?) && ticket.overdue_for_response?

    case ticket.status.to_s
    when "submitted"
      "helpdesk-badge--info"
    when "in_review"
      "helpdesk-badge--warning"
    when "reopened"
      "helpdesk-badge--danger"
    when "resolved"
      "helpdesk-badge--blue"
    when "closed"
      "helpdesk-badge--success"
    else
      "helpdesk-badge--neutral"
    end
  end

  def help_desk_format_text(text)
    simple_format(h(text.to_s), {}, sanitize: false)
  end
end
