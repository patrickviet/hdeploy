require 'curb'
require 'singleton'

module HDeploy
  class APIClient
    include Singleton

    def initialize
      @conf = Conf.instance

      @c = Curl::Easy.new()
      @c.http_auth_types = :basic
      @c.username = @conf.api['http_user']
      @c.password = @conf.api['http_password']
    end

    def get(url)
      @c.url = @conf.api['endpoint'] + url
      @c.perform
      raise "response code for #{url} was not 200 : #{@c.response_code}" unless @c.response_code == 200
      return @c.body_str
    end

    def put(uri,data)
      @c.url = @config.api['endpoint'] + uri
      @c.http_put(data)
      raise "response code for #{url} was not 200 : #{@c.response_code} - #{@c.body_str}" unless @c.response_code == 200
      return @c.body_str      
    end

    def delete(uri)
      @c.url = @config.conf['global']['endpoint'] + uri
      @c.http_delete
      raise "response code for #{url} was not 200 : #{@c.response_code} - #{@c.body_str}" unless @c.response_code == 200
      return @c.body_str    
    end
  end
end
