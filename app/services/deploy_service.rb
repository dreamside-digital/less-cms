require 'open-uri'
require 'zip'

class DeploymentError < StandardError
  def initialize(msg="There was an error deploying the website.")
    super
  end
end

class DeployService

  def initialize(website, editor_info)
    @website = website
    @editor_info = editor_info
    @timestamp = Time.now
  end

  def deploy
    p "Deploy started for #{@website.project_name} by #{@editor_info['displayName']} at #{@timestamp}"
    Rails.logger.info "Deploy started for #{@website.project_name} by #{@editor_info['displayName']} at #{@timestamp}"
    Delayed::Worker.logger.info "Deploy started for #{@website.project_name} by #{@editor_info['displayName']} at #{@timestamp}"
    begin
      download_source_repo
      write_firebase_config_files
      write_env_file
      set_node_version
      install_website_dependencies
      build_website
      deploy_to_hosting
      purge_cloudflare_cache
      remove_project_files
      notify_editor_success
    rescue StandardError => e
      remove_project_files
      notify_editor_failure
      raise StandardError, "An error occurred while deploying the website: #{e}"
    end
  end

  private

  def download_source_repo
    p "Dowloading source code from #{@website.source_repo}"
    Rails.logger.info "Dowloading source code from #{@website.source_repo}"
    Delayed::Worker.logger.info "Dowloading source code from #{@website.source_repo}"
    content = open(@website.source_repo)
    dest_dir = File.path("#{Rails.root}/tmp/website_root/")

    if File.directory?(dest_dir)
      FileUtils.rm_rf(dest_dir)
    end

    FileUtils.mkdir(dest_dir)

    p "dest_dir: #{dest_dir}"
    Rails.logger.info "dest_dir: #{dest_dir}"
    Delayed::Worker.logger.info "dest_dir: #{dest_dir}"

    entry_name = ""
    Zip::File.open_buffer(content) do |zip_file|
      zip_file.each do |entry|
        entry_name = entry.name
        fpath = File.join(dest_dir, entry.name)
        entry.extract(fpath)
      end
    end

    p "entry_name: #{entry_name}"
    Rails.logger.info "entry_name: #{entry_name}"
    Delayed::Worker.logger.info "entry_name: #{entry_name}"

    dir_name = entry_name.split("/")[0]
    p "Extracted files to #{dir_name}"
    Rails.logger.info "Extracted files to #{dir_name}"
    Delayed::Worker.logger.info "Extracted files to #{dir_name}"
    @website_root_dir = File.path("#{Rails.root}/tmp/website_root/#{dir_name}/")
  end

  def set_node_version
    Dir.chdir(@website_root_dir) do
      package_json = JSON.parse(File.read("package.json"))
      node_version = package_json["engines"] ? package_json["engines"]["node"] : nil
      if node_version
        p "Switching to node version #{node_version}"
        Rails.logger.info "Switching to node version #{node_version}"
        Delayed::Worker.logger.info "Switching to node version #{node_version}"

        result = `nvm use #{node_version}`

        if $?.exitstatus != 0
          result = system("nvm use #{node_version}")
        end

        if $?.exitstatus != 0
          p "Failed to set node version (nvm use #{node_version}) with exit status code #{$?}. Attempting to continue."
          Rails.logger.info "Failed to set node version (nvm use #{node_version}) with exit status code #{$?}. Attempting to continue."
          Delayed::Worker.logger.info "Failed to set node version (nvm use #{node_version}) with exit status code #{$?}. Attempting to continue."
        end
      end
    end
  end

  def install_website_dependencies
    Dir.chdir(@website_root_dir) do
      p "Installing dependencies in #{@website_root_dir}"
      Rails.logger.info "Installing dependencies in #{@website_root_dir}"
      Delayed::Worker.logger.info "Installing dependencies in #{@website_root_dir}"

      result = `yarn`
      p "Result of 'yarn' => #{result}"
      Rails.logger.info "Result of 'yarn' => #{result}"
      Delayed::Worker.logger.info "Result of 'yarn' => #{result}"

      if $?.exitstatus != 0
        result = system("yarn")
        p "Result of system('yarn') => #{result}"
        Rails.logger.info "Result of system('yarn') => #{result}"
        Delayed::Worker.logger.info "Result of system('yarn') => #{result}"
      end

      if $?.exitstatus != 0
        result = %x(yarn)
        p "Result of %x(yarn) => #{result}"
        Rails.logger.info "Result of %x(yarn) => #{result}"
        Delayed::Worker.logger.info "Result of %x(yarn) => #{result}"
      end

      if $?.exitstatus != 0
        raise StandardError, "Failed to install dependencies (yarn) with exit status code #{$?}"
      end
    end
  end

  def build_website
    Dir.chdir(@website_root_dir) do
      env_vars = @website.gatsby_env.blank? ? "" : "GATSBY_ACTIVE_ENV=#{@website.gatsby_env}"

      p "Building website with command yarn build #{env_vars}"
      Rails.logger.info "Building website with command yarn build #{env_vars}"
      Delayed::Worker.logger.info "Building website with command yarn build #{env_vars}"

      success = system("yarn build #{env_vars}")
      if !success
        raise StandardError, "Failed to build website (yarn build #{env_vars}) with exit status code #{$?}"
      end
    end
  end

  def deploy_to_hosting
    if !ENV["RAILS_ENV"] == "production"
      p "Skipping deployment on development environment"
      return
    end

    Dir.chdir(@website_root_dir) do
      if @website.custom_deploy_command.blank?
        deploy_to_firebase
      else
        result = system(@website.custom_deploy_command)
        p "Result of system('#{@website.custom_deploy_command}') => #{result}"
        Rails.logger.info "Result of system('#{@website.custom_deploy_command}') => #{result}"
        Delayed::Worker.logger.info "Result of system('#{@website.custom_deploy_command}') => #{result}"

        if $?.exitstatus != 0
          raise StandardError, "Failed to deploy #{@website.custom_deploy_command} with exit status code #{$?}"
        end
      end
    end
  end

  def write_firebase_config_files
    if @website.firebase_config_staging
      filename = "firebase-config.staging.json"
      filepath = File.join(@website_root_dir, 'config', filename)

      p "Writing firebase config file to #{filepath}"
      Rails.logger.info "Writing firebase config file to #{filepath}"
      Delayed::Worker.logger.info "Writing firebase config file to #{filepath}"

      File.open(filepath, "w+") do |f|
        f.write(@website.firebase_config_staging)
      end
    end

    filename = @website.firebase_env.blank? ? "firebase-config.json" : "firebase-config.#{@website.firebase_env}.json"
    filepath = File.join(@website_root_dir, 'config', filename)

    p "Writing firebase config file to #{filepath}"
    Rails.logger.info "Writing firebase config file to #{filepath}"
    Delayed::Worker.logger.info "Writing firebase config file to #{filepath}"

    File.open(filepath, "w+") do |f|
      f.write(@website.firebase_config)
    end
  end

  def write_env_file
    filepath = File.join(@website_root_dir, '.env.production')
    host = "localhost"
    protocol ="http"

    if ENV["RAILS_ENV"] == "production"
      host = "www.lesscms.ca"
      protocol ="https"
    end

    File.open(filepath, "a+") do |f|
      deploy_endpoint = Rails.application.routes.url_helpers.deploy_website_url(@website, host: host, protocol: protocol)
      p "Writing deploy endpoint environment variable to file: #{deploy_endpoint}"
      Rails.logger.info "Writing deploy endpoint environment variable to file: #{deploy_endpoint}"
      Delayed::Worker.logger.info "Writing deploy endpoint environment variable to file: #{deploy_endpoint}"
      f.write("GATSBY_DEPLOY_ENDPOINT=#{deploy_endpoint}\n")

      if !@website.firebase_env.blank?
        p "Writing Firebase environment variables to file: #{@website.firebase_env}"
        Rails.logger.info "Writing Firebase environment variables to file: #{@website.firebase_env}"
        Delayed::Worker.logger.info "Writing Firebase environment variables to file: #{@website.firebase_env}"
        f.write("GATSBY_FIREBASE_ENVIRONMENT=#{@website.firebase_env}\n")
      end

      if @website.environment_variables
        p "Writing additional environment variables to file"
        Rails.logger.info "Writing additional environment variables to file"
        Delayed::Worker.logger.info "Writing additional environment variables to file"
        f.write(@website.environment_variables)
      end

    end
  end

  def deploy_to_firebase
    p "Deploying to firebase hosting on #{@website.firebase_project_id}"
    Rails.logger.info "Deploying to firebase hosting on #{@website.firebase_project_id}"
    Delayed::Worker.logger.info "Deploying to firebase hosting on #{@website.firebase_project_id}"
    project_result = %x(firebase use #{@website.firebase_project_id})

    Rails.logger.info project_result
    Delayed::Worker.logger.info project_result

    success = system("firebase deploy --debug")
    Rails.logger.info "Build completed => #{success}"
    Delayed::Worker.logger.info "Build completed => #{success}"
    if !success
      raise StandardError, "Failed to deploy to firebase (firebase deploy --debug) with exit status code #{$?}"
    end
  end

  def purge_cloudflare_cache
    client = CloudflareService.new(@website)
    client.purge_cache
  end

  def remove_project_files
    p "Removing project root folder"
    Rails.logger.info "Removing project root folder"
    Delayed::Worker.logger.info "Removing project root folder"
    FileUtils.rm_rf(@website_root_dir) if File.directory?(@website_root_dir)
  end

  def notify_editor_success
    p "Sending success notification to: #{@editor_info['displayName']} at #{@editor_info['email']}"
    Rails.logger.info "Sending success notification to: #{@editor_info['displayName']} at #{@editor_info['email']}"
    Delayed::Worker.logger.info "Sending success notification to: #{@editor_info['displayName']} at #{@editor_info['email']}"

    EditorMailer.with(website: @website, editor_info: @editor_info).website_published_email.deliver_now
  end

  def notify_editor_failure
    p "Sending failure notification to: #{@editor_info['displayName']} at #{@editor_info['email']}"
    Rails.logger.info "Sending failure notification to: #{@editor_info['displayName']} at #{@editor_info['email']}"
    Delayed::Worker.logger.info "Sending failure notification to: #{@editor_info['displayName']} at #{@editor_info['email']}"

    EditorMailer.with(website: @website, editor_info: @editor_info).deploy_failed_email.deliver_now
  end
end