class CompaniesController < ApplicationController
  include PaginationUtility
  include ImagesUtility

  before_action :set_company, only: [:show, :edit, :update, :destroy,
                                     :edit_payment, :fetch_from_dinkurs,
                                     :company_h_brand]
  before_action :authorize_company, only: [:update, :show, :edit, :destroy]
  before_action :set_app_config, only: [:company_h_brand]
  before_action :allow_iframe_request, only: [:company_h_brand]

  def index
    authorize Company

    self.params = fix_FB_changed_q_params(self.params)

    action_params, @items_count, items_per_page = process_pagination_params('company')

    @search_params = Company.ransack(action_params)

    # only select companies that are 'complete'; see the Company.complete scope

    @all_companies = @search_params.result(distinct: true)
                         .includes(:business_categories)
                         .includes(addresses: [:region, :kommun])
                         .joins(addresses: [:region, :kommun])
    # The last qualifier ("joins") on above statement ("addresses: :region") is
    # to get around a problem with DISTINCT queries used with ransack when also
    # allowing sorting on an associated table column ("region" in this case)
    # https://github.com/activerecord-hackery/ransack#problem-with-distinct-selects

    @all_companies = @all_companies.searchable unless current_user.admin?

    @all_visible_companies = @all_companies.address_visible

    @all_visible_companies.each { |co| geocode_if_needed co }

    @companies = @all_companies.page(params[:page]).per_page(items_per_page)

    render partial: 'companies_list', locals: { companies: @companies,
                    search_params: @search_params } if request.xhr?
  end

  def show
    setup_events_and_events_pagination

    show_events_list if request.xhr? 
  end

  def company_h_brand
    image_html = image_html('company_h_brand', @app_configuration, @company)
    if params[:render_to] == 'jpg'
      download_image('company_h_brand', 300, image_html)
    else
      show_image(image_html)
    end
  end

  def fetch_from_dinkurs
    raise 'Unsupported request' unless request.xhr?

    @company.fetch_dinkurs_events
    @company.reload

    setup_events_and_events_pagination

    show_events_list
  end

  def setup_events_and_events_pagination

    entity = "company_#{@company.id}_events"
    __, @items_count, items_per_page = process_pagination_params(entity)

    @events = @company.events.order(:start_date)
                .page(params[:page])
                .per_page(items_per_page)
  end

  def show_events_list
    render partial: 'events/teaser_list',
           locals: { events: @events, company: @company, items_count: @items_count }
  end

  def new
    authorize Company
    @company = Company.new

    @all_business_categories = BusinessCategory.all
  end


  def edit
    @all_business_categories = BusinessCategory.all

    Ckeditor::Picture.images_category = 'company_' + @company.id.to_s
    Ckeditor::Picture.for_company_id = @company.id

  end


  def create
    authorize Company

    @company = Company.new(sanitize_params(company_params))

    saved = @company.save

    unless request.xhr?
      if saved
        if @company.validate_key_and_fetch_dinkurs_events(on_update: false)
          redirect_to @company, notice: t('.success')
        else
          helpers.flash_message(:notice, t('.success_with_dinkurs_problem'))
          render :edit
        end
      else
        flash.now[:alert] = t('.error')
        render :new
      end
      return
    end

    # XHR request from modal in ShfApplication create view (to create company)
    if saved
      status = 'success'
      id = 'shf_application_company_number'
      value = @company.company_number
    else
      status = 'errors'
      id = 'company-create-errors'
      value = helpers.model_errors_helper(@company)
    end

    render json: { status: status, id: id, value: value }
  end


  def update
    cmpy_params = sanitize_params(company_params)

    @company.assign_attributes(cmpy_params)

    if (company_valid = @company.valid?)
      # Will add model error if key is not blank and not valid:
      dinkurs_key_ok = @company.validate_key_and_fetch_dinkurs_events
    else
      dinkurs_key_ok = true
    end

    if company_valid && dinkurs_key_ok
      @company.update(cmpy_params)
      redirect_to @company, notice: t('.success')
    else
      flash.now[:alert] = t('.error')
      render :edit
    end
  end


  def destroy
    if @company.destroy
      redirect_to companies_url, notice: t('companies.destroy.success')
    else
      translated_errors = helpers.translate_and_join(@company.errors.full_messages)
      helpers.flash_message(:alert, "#{t('companies.destroy.error')}: #{translated_errors}")
      redirect_to @company
    end
  end


  def edit_payment
    raise 'Unsupported request' unless request.xhr?
    authorize Company

    payment = @company.most_recent_branding_payment
    payment.update!(payment_params) if payment

    render partial: 'branding_payment_status', locals: { company: @company }

  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved
    render partial: 'branding_payment_status',
           locals: { company: @company, error: t('companies.update.error') }
  end


  private
  # Use callbacks to share common setup or constraints between actions.
  def set_company
    @company = Company.includes(:addresses).find(params[:id])
    geocode_if_needed @company
  end


  def geocode_if_needed(company)
    needs_geocoding = company.addresses.reject(&:geocoded?)
    needs_geocoding.each(&:geocode_best_possible)
    company.save! if needs_geocoding.count > 0
  end

  # Never trust parameters from the scary internet, only allow the white list through.
  def company_params
    params.require(:company).permit(:name, :company_number, :phone_number,
                                    :email,
                                    :website,
                                    :description,
                                    :dinkurs_company_id,
                                    :show_dinkurs_events,
                                    addresses_attributes: [:id,
                                                           :street_address,
                                                           :post_code,
                                                           :kommun_id,
                                                           :city,
                                                           :region_id,
                                                           :country,
                                                           :visibility])
  end


  def payment_params
    params.require(:payment).permit(:expire_date, :notes)
  end


  def authorize_company
    authorize @company
  end


  def sanitize_params(params)
    params['website'] = InputSanitizer.sanitize_url(params.fetch('website', ''))
    params['description'] = InputSanitizer.sanitize_html(params.fetch('description', ''))
    params
  end

end
