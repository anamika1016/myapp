class TrainingsController < ApplicationController
  before_action :authenticate_user!

  def index
    if current_user.role == "hod"
      @trainings = Training.includes(:user_training_progresses)
    else
      @trainings = Training.active.includes(:user_training_progresses)
    end

    # Month & Year filter (separate check better hai)
    if params[:month].present?
      @trainings = @trainings.where(month: params[:month])
    end

    if params[:year].present?
      @trainings = @trainings.where(year: params[:year])
    end

    # ✅ NEW: Title Filter
    if params[:training_id].present?
      @trainings = @trainings.where(id: params[:training_id])
    end

    @trainings = @trainings.order(created_at: :desc)
  end

  def edit
    @training = Training.find(params[:id])
  end

  def update
    @training = Training.find(params[:id])

    # Prevent existing files from being cleared if no new ones are uploaded
    update_params = training_params
    if update_params[:files].blank? || (update_params[:files].is_a?(Array) && update_params[:files].all?(&:blank?))
      update_params.delete(:files)
    end

    if @training.update(update_params)
      redirect_to trainings_path, notice: "Training updated successfully"
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @training = Training.find(params[:id])
    @training.destroy
    redirect_to trainings_path, notice: "Training deleted successfully"
  end

  def toggle_status
    @training = Training.find(params[:id])
    @training.update(status: !@training.status)
    redirect_to trainings_path, notice: "Training status updated"
  end

  def new
    @training = Training.new
  end

  def create
    @training = Training.new(training_params)
    @training.created_by = current_user.id

    if @training.save
      redirect_to trainings_path, notice: "Training uploaded successfully"
    else
      render :new, status: :unprocessable_entity
    end
  end

  def show
    @training = Training.find(params[:id])

    # Load current user's progress for this training
    @progress = UserTrainingProgress.find_or_initialize_by(
      training: @training,
      user: current_user
    )

    @files = @training.files.map do |file|
      {
        name: file.filename.to_s,
        url: rails_blob_url(file, only_path: false)
      }
    end
  end

  # POST /trainings/:id/start_training
  # Called by JS when user opens the training page — records started_at
  def start_training
    @training = Training.find(params[:id])
    @progress = UserTrainingProgress.find_or_initialize_by(
      training: @training,
      user: current_user
    )

    unless @progress.status == "completed"
      @progress.status     = "started"
      @progress.started_at ||= Time.current
      @progress.financial_year = financial_year_for(@training.month, @training.year)
      @progress.save!
    end

    render json: {
      status: @progress.status,
      started_at: @progress.started_at
    }
  end

  # POST /trainings/:id/complete_training
  # Called by JS when the full required duration has elapsed
  def complete_training
    @training = Training.find(params[:id])
    @progress = UserTrainingProgress.find_or_initialize_by(
      training: @training,
      user: current_user
    )

    @progress.status     = "completed"
    @progress.started_at ||= Time.current
    @progress.ended_at   = Time.current
    @progress.time_spent = params[:time_spent].to_i   # seconds spent (sent from JS)
    @progress.financial_year = financial_year_for(@training.month, @training.year)
    @progress.save!

    render json: {
      status:     @progress.status,
      started_at: @progress.started_at,
      ended_at:   @progress.ended_at,
      time_spent: @progress.time_spent
    }
  end

  # Converts PPT/DOCX to PDF using LibreOffice and streams it for inline preview
  def preview
    @training = Training.find(params[:id])
    file = @training.files.find { |f| f.id == params[:file_id].to_i }

    return head :not_found unless file

    # If it's already a PDF, just redirect
    if file.content_type.include?("pdf")
      redirect_to rails_blob_path(file, disposition: "inline")
      return
    end

    # For PPT/DOCX: download to temp, convert with LibreOffice, stream back
    tmp_dir = Dir.mktmpdir("training_preview_")

    original_ext = File.extname(file.filename.to_s)
    tmp_input = File.join(tmp_dir, "input#{original_ext}")

    # Write file content to temp location
    File.open(tmp_input, "wb") do |f|
      f.write(file.download)
    end

    # Convert to PDF using LibreOffice headless
    system("libreoffice --headless --convert-to pdf --outdir #{Shellwords.escape(tmp_dir)} #{Shellwords.escape(tmp_input)} 2>/dev/null")

    pdf_path = File.join(tmp_dir, "input.pdf")

    if File.exist?(pdf_path)
      pdf_data = File.read(pdf_path)
      FileUtils.remove_entry_secure(tmp_dir) rescue nil
      send_data pdf_data,
        type: "application/pdf",
        disposition: "inline",
        filename: "#{File.basename(file.filename.to_s, original_ext)}.pdf"
    else
      FileUtils.remove_entry_secure(tmp_dir) rescue nil
      head :unprocessable_entity
    end
  end

  def certificate
    @training = Training.find(params[:id])
    @progress = UserTrainingProgress.find_by(training: @training, user: current_user, status: "completed")

    unless @progress
      redirect_to training_path(@training), alert: "Please complete the training first."
      return
    end

    # Use employee_name from employee_detail if available, else search by email, else fallback to email
    @employee_detail = current_user.employee_detail || EmployeeDetail.find_by(employee_email: current_user.email)
    @user_name = @employee_detail&.employee_name || current_user.email
    @completion_date = @progress.ended_at&.strftime("%d %b %Y") || Time.current.strftime("%d %b %Y")

    respond_to do |format|
      format.pdf do
        render pdf: "Certificate_#{@training.title}",
               template: "trainings/certificate",
               layout: "pdf",
               orientation: "Landscape",
               page_size: "A4",
               margin: { top: 0, bottom: 0, left: 0, right: 0 },
               no_background: false,
               print_media_type: true,
               disable_smart_shrinking: true,
               zoom: 1
      end
    end
  end

  private

  def training_params
    params.require(:training)
          .permit(:title, :description, :duration, :month, :year, :status, files: [])
  end

  # Returns financial year string like "2025-26" based on training month & year
  def financial_year_for(month, year)
    month = month.to_i
    year  = year.to_i
    if month >= 4
      "#{year}-#{(year + 1).to_s.last(2)}"
    else
      "#{year - 1}-#{year.to_s.last(2)}"
    end
  end
end
