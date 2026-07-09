class Api::PasswordsController < Api::BaseController
	# POST /api/password/reset_by_code
	# Params: { email, employee_code, password, password_confirmation }
	def reset_by_code
		email = params[:email].to_s.strip.downcase
		code = params[:employee_code].to_s.strip
		new_password = params[:password].to_s
		password_confirmation = params[:password_confirmation].to_s

		if new_password.blank? || password_confirmation.blank?
			return render json: { error: "password and password_confirmation are required" }, status: :unprocessable_entity
		end

		unless new_password == password_confirmation
			return render json: { error: "password confirmation does not match" }, status: :unprocessable_entity
		end

		user = User.where("lower(email) = ?", email).where(employee_code: code).first

		unless user
			return render json: { error: "Invalid email or employee code" }, status: :unauthorized
		end

		if user.reset_password(new_password, password_confirmation)
			render json: { success: true }, status: :ok
		else
			render json: { error: user.errors.full_messages }, status: :unprocessable_entity
		end
	end
end