# config/routes.rb

Rails.application.routes.draw do

  resources :target_submissions do
    member do
      patch :approve
      patch :reject
    end
    collection do
      get :show
    end
  end

  resources :user_details do
    collection do
      get :get_activities
      post :bulk_create
      get :get_user_detail
      post :submit_achievements
      get :export
      post :import
      get :download_template
      post :bulk_upload
      get :quarterly_edit_all
      patch :update_quarterly_achievements
      get :test_sms
      get :clear_sms_tracking
      get :view_sms_logs
      get :export_department_activity_data

    end
  end

  resources :departments do
    member do
      get :edit_data
      patch :update_employee_activity_data
      post :delete_user_activities  # Changed from delete to post for JSON data
      delete :delete_user_from_department  # New route for deleting user from specific department
    end
    collection do
      post :import
      get :export
      delete :delete_employee_activities
    end
    resources :activities, except: [:show]
  end
  
  # Custom route for updating employee activities
  post 'departments/update_employee_activities', to: 'departments#update_employee_activities'
  
  # Custom route for deleting individual activities
  delete 'departments/delete_activity/:activity_id', to: 'departments#delete_activity'
  
  # Test route to verify routing is working
  get 'departments/test_route', to: 'departments#test_route'
  # This makes the employee list the home page.

  resources :employee_details do
    collection do
      get :export_xlsx
      get :export_quarterly_xlsx  # Export quarterly L1 L2 data
      post :import
      get 'l1'
      get 'l2'  # ➤ this is your sidebar L1 view
    end
     member do
      patch :approve
      patch :return
      patch :l2_approve  # L2 approve
      patch :l2_return  
      patch :edit_l1  # Edit L1 remarks and percentage
      patch :edit_l2  # Edit L2 remarks and percentage
      get :show_l2  # This maps to /employee_details/:id/show_l2
    end
  end

  devise_for :users, controllers: {
    sessions: 'users/sessions',
    registrations: 'users/registrations',
    passwords: "users/passwords"
  }  
  # Add a specific route for the dashboard
  root to: 'home#dashboard'  # 👈 now root goes to dashboard
  get 'dashboard', to: 'home#dashboard'


  # Settings routes
  get 'settings', to: 'settings#show'
  patch 'settings', to: 'settings#update'
  patch 'settings/password', to: 'settings#update_password'

  # Keep your other routes
  devise_scope :user do
    delete '/users/sign_out', to: 'devise/sessions#destroy'
  end
end