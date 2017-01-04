require 'rest_client'
require 'json'

class Installer
  GITHUB_PROJECT_REGEX = /github\.com\/([a-z0-9_-]+)\/([a-z0-9_-]+)/i

  MEMORY = %w(512mb 1gb 2gb 4gb 8gb)
  REGIONS = {
    'AMS2' => 'Amsterdam 2',
    'AMS3' => 'Amsterdam 3',
    'BLR1' => 'Bangalore 1',
    'FRA1' => 'Frankfurt 1',
    'LON1' => 'London 1',
    'NYC1' => 'New York 1',
    'NYC2' => 'New York 2',
    'NYC3' => 'New York 3',
    'SFO1' => 'San Francisco 1',
    'SFO2' => 'San Francisco 2',
    'SGP1' => 'Singapore 1',
    'TOR1' => 'Toronto 1'
  }

  class URLParseError    < StandardError; end
  class ConfigFetchError < StandardError; end
  class ConfigParseError < StandardError; end
  class NoSSHKeyError    < StandardError; end

  attr_reader :raw_config, :droplet
  attr_accessor :url, :config, :size, :region, :auth_token, :droplet_id

  def initialize(url=nil)
    return if url.to_s.strip == ''
    (_, @user, @project) = GITHUB_PROJECT_REGEX.match(url).to_a
    unless @user and @project
      raise URLParseError.new("could not parse as a GitHub project url: #{url}")
    end
    @url = "https://raw.githubusercontent.com/#{@user}/#{@project}/master/app.yml"
    get_config
  end

  def self.from_json(json)
    json = JSON.parse(json) if json.is_a?(String)
    Installer.new.tap do |installer|
      config = json['config'].dup
      installer.url        = json['url']
      installer.region     = config.delete('region')
      installer.size       = config.delete('size')
      installer.config     = config
      installer.droplet_id = json['droplet_id']
    end
  end

  def as_json
    {
      'url'        => @url,
      'config'     => merged_config,
      'droplet_id' => @droplet_id
    }
  end

  def merged_config
    config.merge(
      'region' => @region,
      'size' => @size
    )
  end

  def memory_options
    MEMORY[MEMORY.index(@config['min_size'] || '512mb')..-1]
  end

  def region_options
    REGIONS
  end

  def repo
    "https://github.com/#{@user}/#{@project}"
  end

  def go!
    url = 'https://api.digitalocean.com/v2/droplets'
    response = post(url, payload_for_deploy)
    @droplet_id = response['droplet']['id']
  end

  def keys
    @keys ||= get("https://api.digitalocean.com/v2/account/keys")['ssh_keys'] || []
  end

  def droplet_info
    @droplet_info ||= get("https://api.digitalocean.com/v2/droplets/#{@droplet_id}")['droplet']
  rescue RestClient::ResourceNotFound
    {}
  end

  def droplet_status
    droplet_info['status'] || 'deleted'
  end

  def droplet_active?
    droplet_status == 'active'
  end

  def droplet_ip
    droplet_info['networks']['v4'].first['ip_address']
  end

  private

  def get(url)
    JSON.parse(RestClient.get(url, headers))
  end

  def post(url, body)
    JSON.parse(RestClient.post(url, body.to_json, headers))
  end

  def headers
    {
      authorization: "Bearer #{auth_token}",
      content_type:  'application/json'
    }
  end

  def payload_for_deploy
    merged_config.dup.tap do |payload|
      do_config = payload.delete('config')
      do_config['runcmd'] = commands_with_status(do_config['runcmd'])
      payload['user_data'] = "#cloud-config\n" + YAML.dump(do_config)
      fail NoSSHKeyError, 'You must create an SSH key on DigitalOcean first.' if keys.empty?
      payload['ssh_keys'] = [keys.first['id']] if keys.one? # TODO give the user a chance to select one if they have multiple keys
    end
  end

  def get_config
    return if @url.to_s.strip == ''
    @raw_config = RestClient.get(url)
    begin
      @config = YAML.load(@raw_config)
    rescue
      raise ConfigParseError.new("could not parse config from:\n\n#{@raw_config}")
    else
      @region = 'NYC3'
    end
  rescue RestClient::ResourceNotFound
    raise ConfigFetchError.new("could not fetch config from #{@url}")
  end

  def set_status(status)
    "echo '{\"status\":\"#{status}\"}' > /tmp/do-install-button-status.json"
  end

  def commands_with_status(commands)
    commands ||= []
    [
      set_status('installing'),
      "apt-get install -y -q ruby || #{set_status('error')}",
      'ruby -rwebrick -e "server=WEBrick::HTTPServer.new(:Port => 33333, :DocumentRoot => %(/tmp/non-existent-fake-path)); server.mount_proc(%(/status.jsonp)) { |req, res| res.body = %(#{req.query_string.match(/callback=(\w+)/)[1]}(#{File.read(%(/tmp/do-install-button-status.json))})) }; server.start" &',
    ] +
    commands.map { |c| c =~ /&\s*$/ ? c : "#{c} || #{set_status('error')}" } +
    [
      "! grep 'error' /tmp/do-install-button-status.json && #{set_status('complete')}",
      'sleep 60; kill -9 $(ps aux | grep "[w]ebrick.*33333" | awk "{ print $2 }")'
    ]
  end

end
