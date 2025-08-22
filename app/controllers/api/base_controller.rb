class Api::BaseController < ApplicationController
	protect_from_forgery with: :null_session
	skip_before_action :verify_authenticity_token

	before_action :force_json_format

	private

	def force_json_format
		request.format = :json
	end
end