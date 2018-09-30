require 'bundler/setup'
require 'sinatra'
require 'haml'
require 'rest_client'
require 'json'
require 'erb'
require 'yaml'
require 'pry'
require './installer'

template = ERB.new File.new('config.yml').read
config = YAML.load template.result(binding)

CALLBACK_URL  = "#{config['this_host']}/auth/callback"
SIGN_UP_URL   = "https://www.digitalocean.com/?refcode=#{config['ref_code']}"
CLIENT_ID     = config['client_id']
CLIENT_SECRET = config['client_secret']

enable :sessions, :logging

enable :show_exceptions if development?

set :session_secret, config['cookie_secret']

def csrf_token_matches?(token)
  token.to_s != '' && token == session[:csrf_token]
end

def authenticate(installer)
  if (installer.auth_token = session[:token])
    begin
      installer.account
    rescue RestClient::Unauthorized
      session[:token] = nil
      redirect "https://cloud.digitalocean.com/v1/oauth/authorize?response_type=code&client_id=#{CLIENT_ID}&redirect_uri=#{CALLBACK_URL}&scope=read+write"
    rescue Installer::NoSSHKeyError
      redirect '/add_ssh_key'
    else
      return true
    end
  else
    redirect "https://cloud.digitalocean.com/v1/oauth/authorize?response_type=code&client_id=#{CLIENT_ID}&redirect_uri=#{CALLBACK_URL}&scope=read+write"
  end
  false
end

get '/' do
  @configured = config['client_id'] != 'your-do-client-id'
  haml :index
end

get '/terms' do
  haml :terms
end

get '/install' do
  begin
    @installer = Installer.new(params[:url])
  rescue Installer::URLParseError
    haml :error_parsing_url
  rescue Installer::ConfigFetchError
    haml :error_getting_config
  rescue Installer::ConfigParseError
    haml :error_parsing_config
  else
    session[:csrf_token] = SecureRandom.hex
    haml :install
  end
end

post '/install' do
  return [400, 'invalid token'] unless csrf_token_matches?(params[:token])
  begin
    if params[:url]
      installer = Installer.new(params[:url])
      installer.region = params[:region]
      installer.size = params[:size]
      session[:config] = installer.as_json
    else
      installer = Installer.from_json(session[:config])
    end
  rescue
    haml :error_generic
  else
    if authenticate(installer)
      begin
        installer.go!
      rescue Installer::NoSSHKeyError
        redirect '/add_ssh_key'
      else
        session[:config] = installer.as_json
        redirect '/status'
      end
    end
  end
end

get '/update_regions_and_sizes' do
  installer = Installer.new('https://github.com/seven1m/do-install-button') # doesn't matter
  if authenticate(installer)
    File.write('regions.json', installer.regions.to_json)
    File.write('sizes.json', installer.sizes.to_json)
    'written'
  end
end

get '/auth/callback' do
  result = RestClient.post 'https://cloud.digitalocean.com/v1/oauth/token',
    { client_id:     CLIENT_ID,
      client_secret: CLIENT_SECRET,
      grant_type:    'authorization_code',
      code:          params[:code],
      redirect_uri:  CALLBACK_URL }
  session[:token] = JSON.parse(result)['access_token']
  unless session[:config]
    redirect '/'
    return
  end
  installer = Installer.from_json(session[:config])
  installer.auth_token = session[:token]
  begin
    installer.go!
  rescue Installer::NoSSHKeyError
    redirect '/add_ssh_key'
  else
    session[:config] = installer.as_json
    redirect '/status'
  end
end

get '/add_ssh_key' do
  @installer = Installer.from_json(session[:config])
  haml :add_ssh_key
end

get '/status' do
  haml :status
end

get '/status.json' do
  installer = Installer.from_json(session[:config])
  installer.auth_token = session[:token]
  status = {
    id:       installer.droplet_id,
    ip:       installer.droplet_ip,
    droplet:  installer.droplet_status,
    status:   installer.install_status
  }
  content_type :json
  status.to_json
end
