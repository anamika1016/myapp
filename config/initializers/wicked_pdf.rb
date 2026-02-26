WickedPdf.config = {}

# Correct way to include WickedPdf helpers in modern Rails
ActiveSupport.on_load(:action_view) do
  include WickedPdf::WickedPdfHelper::Assets
end
