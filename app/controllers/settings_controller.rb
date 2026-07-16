class SettingsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_user
  before_action :require_hod_or_admin!, only: [ :toggle_quarterly_pli_menu ]

  def show
    # Settings page - show user profile and settings
  end

  def update
    if @user.update(user_params)
      if request.xhr?
        render json: {
          success: true,
          message: "Profile updated successfully!",
          avatar_url: @user.profile_image.attached? ? url_for(@user.profile_image) : nil
        }
      else
        flash[:notice] = "Profile updated successfully!"
        redirect_to settings_path
      end
    else
      if request.xhr?
        render json: {
          success: false,
          errors: @user.errors.full_messages
        }
      else
        flash[:alert] = "Failed to update profile: #{@user.errors.full_messages.join(', ')}"
        render :show
      end
    end
  end

  def update_password
    if @user.update_with_password(password_params)
      bypass_sign_in(@user)
      flash[:notice] = "Password updated successfully!"
      redirect_to settings_path
    else
      flash[:alert] = "Failed to update password: #{@user.errors.full_messages.join(', ')}"
      render :show
    end
  end

  def toggle_quarterly_pli_menu
    enabled = AppSetting.set_quarterly_pli_menu_enabled(!AppSetting.quarterly_pli_menu_enabled?)
    status_text = enabled ? "visible" : "hidden"

    redirect_back fallback_location: root_path,
                  notice: "Quarterly PLI % menu is now #{status_text} for employee logins."
  end

  private

  def set_user
    @user = current_user
  end

  def user_params
    params.require(:user).permit(:email, :employee_code, :profile_image)
  end

  def password_params
    params.require(:user).permit(:current_password, :password, :password_confirmation)
  end

  def require_hod_or_admin!
    return if current_user.hod? || current_user.admin?

    redirect_to root_path, alert: "You are not authorized to change menu visibility."
  end
end
