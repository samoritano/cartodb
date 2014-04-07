#encoding: UTF-8

require_relative '../../../../services/datasources/lib/datasources'

class Api::Json::ImportsController < Api::ApplicationController
  ssl_required :index, :show, :create

  INVALID_TOKEN_MESSAGE = 'OAuth token invalid or expired'

  def index
    imports = current_user.importing_jobs
    render json: { imports: imports.map(&:id), success: true }
  end

  def show
    data_import = DataImport[params[:id]]
    data_import.mark_as_failed_if_stuck!
    render json: data_import.reload.public_values
  end

  def create
    file_uri = params[:url].present? ? params[:url] : _upload_file

    service_name = params[:service_name].present? ? params[:service_name] : CartoDB::Datasources::Url::PublicUrl::DATASOURCE_NAME
    service_item_id = params[:service_item_id].present? ? params[:service_item_id] : params[:url].presence

    options = {
        user_id:          current_user.id,
        table_name:       params[:table_name].presence,
        data_source:      file_uri.presence,
        table_id:         params[:table_id].presence,
        append:           (params[:append].presence == 'true'),
        table_copy:       params[:table_copy].presence,
        from_query:       params[:sql].presence,
        service_name:     service_name.presence,
        service_item_id:  service_item_id.presence
    }
      
    data_import = DataImport.create(options)
    Resque.enqueue(Resque::ImporterJobs, job_id: data_import.id)

    render_jsonp({ item_queue_id: data_import.id, success: true })
  end

  # ----------- OAuths -----------

  def service_token_valid?
    oauth = current_user.oauths.select(params[:id])

    return render_jsonp({ oauth_valid: valid, success: true }) if oauth.nil?
    datasource = oauth.get_service_datasource
    return render_jsonp({ oauth_valid: valid, success: true }) if datasource.nil?
    raise CartoDB::Datasources::InvalidServiceError.new("Datasource #{params[:id]} does not support OAuth") unless datasource.kind_of? CartoDB::Datasources::BaseOAuth

    begin
      valid = datasource.token_valid?
    rescue CartoDB::Datasources::DataDownloadError
      valid = false
    end

    render_jsonp({ oauth_valid: valid, success: true })
  rescue CartoDB::Datasources::TokenExpiredOrInvalidError
    current_user.oauts.remove(oauth.service)
    render_jsonp({ errors: { imports: INVALID_TOKEN_MESSAGE } }, 401)
  rescue => ex
    render_jsonp({ errors: { imports: ex } }, 400)
  end #service_token_valid?

  def list_files_for_service
    oauth = current_user.oauths.select(params[:id])
    raise CartoDB::Datasources::AuthError.new("No oauth set for service #{params[:id]}") if oauth.nil?
    datasource = oauth.get_service_datasource
    raise CartoDB::Datasources::AuthError.new("Couldn't fetch datasource for service #{params[:id]}") if datasource.nil?

    render_jsonp({ files: datasource.get_resources_list, success: true })
  rescue CartoDB::Datasources::TokenExpiredOrInvalidError
    current_user.oauts.remove(oauth.service)
    render_jsonp({ errors: { imports: INVALID_TOKEN_MESSAGE } }, 401)
  rescue => ex
    render_jsonp({ errors: { imports: ex } }, 400)
  end #list_files_for_service

  def get_service_auth_url
    oauth = current_user.oauths.select(params[:id])
    raise CartoDB::Datasources::AuthError.new("No oauth set for service #{params[:id]}") if oauth.nil?
    datasource = oauth.get_service_datasource
    raise CartoDB::Datasources::AuthError.new("Couldn't fetch datasource for service #{params[:id]}") if datasource.nil?
    raise CartoDB::Datasources::InvalidServiceError.new("Datasource #{params[:id]} does not support OAuth") unless datasource.kind_of? CartoDB::Datasources::BaseOAuth

    render_jsonp({ url: datasource.get_auth_url, success: true })
  rescue CartoDB::Datasources::TokenExpiredOrInvalidError
    current_user.oauts.remove(oauth.service)
    render_jsonp({ errors: { imports: INVALID_TOKEN_MESSAGE } }, 401)
  rescue => ex
    render_jsonp({ errors: { imports: ex.to_s } }, 400)
  end #get_service_auth_url

  # Only of use if service is set to work in authorization code mode. Ignore for callback-based oauths
  def validate_service_oauth_code
    success = false

    oauth = current_user.oauths.select(params[:id])
    raise CartoDB::Datasources::AuthError.new("No oauth set for service #{params[:id]}") if oauth.nil?
    datasource = oauth.get_service_datasource
    raise CartoDB::Datasources::AuthError.new("Couldn't fetch datasource for service #{params[:id]}") if datasource.nil?
    raise CartoDB::Datasources::InvalidServiceError.new("Datasource #{params[:id]} does not support OAuth") unless datasource.kind_of? CartoDB::Datasources::BaseOAuth

    raise "Missing oauth verification code for service #{params[:id]}" unless params[:code].present?

    begin
      auth_token = datasource.validate_auth_code(params[:code])
      current_user.oauths.add(params[:id],auth_token)
      success = true
    rescue CartoDB::Datasources::AuthError
      # No need to re-raise
    end

    render_jsonp({ success: success })
  rescue CartoDB::Datasources::TokenExpiredOrInvalidError
    current_user.oauts.remove(oauth.service)
    render_jsonp({ errors: { imports: INVALID_TOKEN_MESSAGE } }, 401)
  rescue => ex
    render_jsonp({ errors: { imports: ex.to_s } }, 400)
  end #validate_service_oauth_code

  def service_oauth_callback
    # TODO
  end #service_oauth_callback

  protected

  def synchronous_import?
    params[:synchronous].present?
  end

  def _upload_file
    case
    when params[:filename].present? && request.body.present?
      filename = params[:filename].original_filename rescue params[:filename].to_s
      filedata = params[:filename].read.force_encoding('utf-8') rescue request.body.read.force_encoding('utf-8')
    when params[:file].present?
      filename = params[:file].original_filename rescue params[:file].to_s
      filedata = params[:file].read.force_encoding('utf-8')
    else
      return
    end

    random_token = Digest::SHA2.hexdigest("#{Time.now.utc}--#{filename.object_id.to_s}").first(20)

    s3_config = Cartodb.config[:importer]['s3']
    if s3_config && s3_config['access_key_id'] && s3_config['secret_access_key']
      AWS.config(access_key_id: Cartodb.config[:importer]['s3']['access_key_id'], secret_access_key: Cartodb.config[:importer]['s3']['secret_access_key'])
      s3 = AWS::S3.new
      s3_bucket = s3.buckets[s3_config['bucket_name']]

      path = "#{random_token}/#{File.basename(filename)}"
      o = s3_bucket.objects[path]
      o.write(filedata, { acl: :public_read })

      o.url_for(:get, expires: s3_config['url_ttl']).to_s
    else
      FileUtils.mkdir_p(Rails.root.join('public/uploads').join(random_token))

      file = File.new(Rails.root.join('public/uploads').join(random_token).join(File.basename(filename)), 'w')
      file.write filedata
      file.close
      file.path[/(\/uploads\/.*)/, 1]
    end
  end
end
