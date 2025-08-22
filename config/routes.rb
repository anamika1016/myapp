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

    end
  end

  resources :departments do
    member do
      get :edit_data
    end
    collection do
      post :import
      get :export
    end
    resources :activities, except: [:show]
  end
  # This makes the employee list the home page.

resources :employee_details do
    collection do
      get :export_xlsx
      post :import
      get 'l1'
      get 'l2'  # ➤ this is your sidebar L1 view
    end
     member do
      patch :approve
      patch :return
      patch :l2_approve  # L2 approve
      patch :l2_return  
      get :show_l2  # This maps to /employee_details/:id/show_l2
    end
  end

  # JSON API endpoints (no email flow)
  namespace :api do
    post 'password/reset_by_code', to: 'passwords#reset_by_code'
    post 'account/change_employee_code', to: 'accounts#change_employee_code'
  end

  devise_for :users, controllers: {
    sessions: 'users/sessions',
    registrations: 'users/registrations'

  }  
  # Add a specific route for the dashboard
  root to: 'home#dashboard'  # 👈 now root goes to dashboard
  get 'dashboard', to: 'home#dashboard'


  # Keep your other routes
  devise_scope :user do
    delete '/users/sign_out', to: 'devise/sessions#destroy'
  end
end