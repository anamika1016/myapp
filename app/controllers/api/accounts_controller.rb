class Api::AccountsController < Api::BaseController
	# POST /api/account/change_employee_code
	# Params: { email, current_password, new_employee_code }
	def change_employee_code
		email = params[:email].to_s.strip.downcase
		current_password = params[:current_password].to_s
		new_code = params[:new_employee_code].to_s.strip

		if new_code.blank?
			return render json: { error: "new_employee_code is required" }, status: :unprocessable_entity
		end

		user = User.where("lower(email) = ?", email).first
		unless user&.valid_password?(current_password)
			return render json: { error: "Invalid email or password" }, status: :unauthorized
		end

		user.employee_code = new_code
		if user.save
			render json: { success: true, employee_code: user.employee_code }, status: :ok
		else
			render json: { error: user.errors.full_messages }, status: :unprocessable_entity
		end
	end
end