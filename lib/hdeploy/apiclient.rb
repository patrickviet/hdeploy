require 'curb'
require 'singleton'

module HDeploy
  class APIClient
    include Singleton

    def initialize
      @config = Config.instance

      @c = Curl::Easy.new()
      @c.http_auth_types = :basic
      @c.username = @config.conf['api']['http_user']
      @c.password = @config.conf['api']['http_password']
    end

    def get(url)
      @c.url = @config.conf['global']['endpoint'] + url
      @c.perform
      raise "response code for #{url} was not 200 : #{@c.response_code}" unless @c.response_code == 200
      return @c.body_str
    end

    def put(url,data)
      @c.url = @config.conf['global']['endpoint'] + url
      @c.http_put(data)
      raise "response code for #{url} was not 200 : #{@c.response_code} - #{@c.body_str}" unless @c.response_code == 200
      return @c.body_str      
    end

    def delete(url)
      @c.url = @config.conf['global']['endpoint'] + url
      @c.http_delete
      raise "response code for #{url} was not 200 : #{@c.response_code} - #{@c.body_str}" unless @c.response_code == 200
      return @c.body_str    
    end
  end
end
