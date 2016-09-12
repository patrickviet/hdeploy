require 'sinatra/base'
require 'json'
require 'hdeploy/config'
require 'hdeploy/cassandra'

module HDeploy
  class API < Sinatra::Base

    def initialize
      super

      @cass = HDeploy::Cassandra.new
      @config = HDeploy::Config.instance
    end

    # -----------------------------------------------------------------------------
    # Some Auth stuff
    def protected!
      return if authorized?
      headers['WWW-Authenticate'] = 'Basic realm="Restricted Area"'
      halt 401, "Not authorized\n"
    end

    def authorized?
      @auth ||=  Rack::Auth::Basic::Request.new(request.env)
      @auth.provided? and @auth.basic? and @auth.credentials and @auth.credentials == @config.conf['api'].values_at('http_user','http_password')
    end

    get '/health' do
      "OK"
    end

    get '/ping' do
      "OK"
    end

    # -----------------------------------------------------------------------------
    get '/srv_by_recipe/:recipe' do |recipe|
      if @env['REMOTE_ADDR'] != '127.0.0.1'
        protected!
      end

      srvlist = {}
      srvraw = @kv.getkeys('hdeploy/servers/')

      unless srvraw
        status 404
        body "unable to find recipe #{recipe}"
        return
      end

      srvraw.each do |path,data|
        data = JSON.parse(data)
        if (data['update'].to_i < Time.new.to_i + 20) and (data['chef_recipes'].include? recipe)
            srvlist[data['hostname']] = true
        end
      end

      srvlist.keys.to_json
    end
    # -----------------------------------------------------------------------------
    get '/srv_by_env/:myenv' do |myenv|
      if @env['REMOTE_ADDR'] != '127.0.0.1'
        protected!
      end

      srvlist = {}
      srvraw = @kv.getkeys('hdeploy/servers/')

      unless srvraw
        status 404
        body "unable to find recipe #{recipe}"
        return
      end

      srvraw.each do |path,data|
        data = JSON.parse(data)
        if (data['update'].to_i < Time.new.to_i + 20) and (data['chef_env'] == myenv)
            srvlist[data['hostname']] = true
        end
      end

      srvlist.keys.to_json
    end

    # -----------------------------------------------------------------------------
    put '/distribute_state/:hostname' do |hostname|
      if @env['REMOTE_ADDR'] != '127.0.0.1'
        protected!
      end

      data = JSON.parse(request.body.read)

      # each line contains an artifact or a target.
      # I expect a hash containing app, which in turn contain envs, contains current and a list of artifacts
      statement = @cass.prepare("INSERT INTO distribute_state (app,env,hostname,current,artifacts) VALUES(?,?,?,?,?) USING TTL 1800")

      data.each do |row|
        @cass.execute(statement, arguments: [row['app'], row['env'], hostname, row['current'], row['artifacts'].sort.join(',')])
      end
      "OK - Updated server #{hostname}"
    end

    # -----------------------------------------------------------------------------

    put '/srv/keepalive/:hostname' do |hostname|
      protected! if @env['REMOTE_ADDR'] != '127.0.0.1'
      ttl = request.body.read || '20'
      @cass.execute("INSERT INTO srv_keepalive (hostname) VALUES ('#{hostname}') USING TTL #{ttl}")
      "OK - Updated server #{hostname}"
    end


    # -----------------------------------------------------------------------------
    put '/artifact/:app/:artifact' do |app,artifact|
      protected! if @env['REMOTE_ADDR'] != '127.0.0.1'

      data = request.body.read
      data = JSON.parse(data)
      data['altsource'] ||= ''

      statement = @cass.prepare("INSERT INTO artifacts (artifact,app,source,altsource,checksum) VALUES(?,?,?,?,?)")
      @cass.execute(statement, arguments: [artifact, app, data['source'], data['altsource'], data['checksum']])

      "OK - registered artifact #{artifact} for app #{app}"
    end

    delete '/artifact/:app/:artifact' do |app,artifact|
      protected! if @env['REMOTE_ADDR'] != '127.0.0.1'

      # FIXME: don't allow to delete a target artifact.
      # FIXME: add a doesn't exist warning?
      @cass.execute("DELETE FROM artifacts WHERE app = '#{app}' AND artifact='#{artifact}'")
      "OK - delete artifact #{artifact} for app #{app}"
    end


    # -----------------------------------------------------------------------------
    put '/target/:app/:myenv' do |app,myenv|
      protected! if @env['REMOTE_ADDR'] != '127.0.0.1'

      artifact = request.body.read
      statement = @cass.prepare("INSERT INTO target (app,env,artifact) VALUES(?,?,?)")
      @cass.execute(statement, arguments: [app,myenv,artifact])

      "OK set target for app #{app} in environment #{myenv} to be #{artifact}"
    end

    get '/target/:app/:myenv' do |app,myenv|
      protected! if @env['REMOTE_ADDR'] != '127.0.0.1'
      statement = @cass.prepare("SELECT artifact FROM target WHERE app = ? AND env = ?")
      artifact = "unknown"
      @cass.execute(statement,arguments: [app,myenv]).each do |row|
        artifact = row['artifact']
      end

      artifact
    end

    get '/target/:app' do |app|
      protected! if @env['REMOTE_ADDR'] != '127.0.0.1'
      statement = @cass.prepare("SELECT env,artifact FROM target WHERE app = ?")
      targets = {}
      @cass.execute(statement,arguments: [app]).each do |row|
        targets[row['env']] = row['artifact']
      end

      JSON.pretty_generate(targets)
    end

    # -----------------------------------------------------------------------------
    get '/distribute/:app/:env' do |app,myenv|
      protected! if @env['REMOTE_ADDR'] != '127.0.0.1'

      #FIXME: denormalize data for better speed?
      distribute = {}

      statement = @cass.prepare("SELECT artifact FROM distribute WHERE app = ? AND env = ? ALLOW FILTERING")
      @cass.execute(statement,arguments:[app,myenv]).each do |row|
        distribute[row['artifact']] = true
      end

      r = {}
      k4cql = distribute.keys.collect{|k| "'#{k}'"}.join(',')

      @cass.execute("SELECT artifact,source,altsource,checksum FROM artifacts WHERE app = '#{app}' AND artifact IN (#{k4cql})").each do |row|
        distribute.delete row['artifact']
        artifact = row.delete 'artifact'
        r[artifact] = row
      end

      #FIXME: cleanup what's still in distribute

      # set the env as active for 24hrs. this is a trick since we don't have joins...
      @cass.execute("INSERT INTO active_env (app,env) VALUES('#{app}','#{myenv}') USING TTL 86400") if r.length > 0

      JSON.pretty_generate(r)
    end


    # -----------------------------------------------------------------------------
    get '/distribute/:app' do |app|
      protected! if @env['REMOTE_ADDR'] != '127.0.0.1'

      #FIXME: denormalize data for better speed?
      distribute = {}

      env_exists = {}
      @cass.execute("SELECT env FROM active_env WHERE app = '#{app}'").each do |row|
        env_exists[row['env']] = true
      end

      art_exists = {}
      @cass.execute("SELECT artifact FROM artifacts WHERE app = '#{app}'").each do |row|
        art_exists[row['artifact']] = false
      end

      r = { 'nowhere' => [] }
      env_exists.keys.each do |k|
        r[k] = []
      end

      statement = @cass.prepare("SELECT env,artifact FROM distribute WHERE app = ?")
      @cass.execute(statement,arguments:[app]).each do |row|

        next unless art_exists.has_key? row['artifact']
        next unless env_exists.has_key? row['env']

        art_exists[row['artifact']] = true
        r[row['env']] << row['artifact']
      end

      # any art that isn't marked as distributed a couple lines earlier (true) is put in "nowhere" list
      art_exists.each do |art,is_distributed|
        r['nowhere'] << art unless is_distributed
      end

      JSON.pretty_generate(r)
    end

    # -----------------------------------------------------------------------------
    # This call is just a big dump. The client can handle the sorting / formatting.
    get '/distribute_state/:app' do |app|
      protected! if @env['REMOTE_ADDR'] != '127.0.0.1'

      r = []
      @cass.execute("select env,hostname,artifacts,current FROM distribute_state WHERE app = '#{app}'").each do |row|
        row['artifacts'] = row['artifacts'].split(',')
        r << row
      end

      JSON.pretty_generate(r)
    end

    # -----------------------------------------------------------------------------
    get '/artifact/:app' do |app|
      protected! if @env['REMOTE_ADDR'] != '127.0.0.1'
      r = {}
      statement = @cass.prepare("SELECT artifact,source,altsource,checksum FROM artifacts WHERE app = ?")
      @cass.execute(statement, arguments: [app]).each do |row|
        artifact = row.delete 'artifact'
        r[artifact] = row
      end

      JSON.pretty_generate(r)
    end

    # -----------------------------------------------------------------------------
    put '/distribute/:app/:env' do |app,env|
      artifact = request.body.read

      # check that this artifact exists for this app first
      if @cass.execute("SELECT artifact FROM artifacts WHERE artifact = '#{artifact}' AND app = '#{app}'").length == 1
        statement = @cass.prepare("INSERT INTO distribute (artifact,app,env) VALUES(?,?,?)")
        @cass.execute(statement,artifact,app,env)
        "OK set artifact #{artifact} for app #{app} to be distributed in environment #{env}"
      else
        "No such artifact #{artifact} for app #{app}"
      end
    end

    delete '/distribute/:app/:env/:artifact' do |app,env,artifact|
      statement = @cass.prepare("DELETE FROM distribute WHERE artifact = ? AND app = ? AND env = ?")
      @cass.execute(statement,arguments: [artifact,app,env])
      "OK don't distribute artifact #{artifact} for app #{app} in environment #{env}"
    end

    # -----------------------------------------------------------------------------
    get '/srv/by_app/:app/:env' do |app,env|
      # this gets the list that SHOULD have things distributed to them...
      r = {}
      @cass.execute("SELECT hostname,current,artifacts FROM distribute_state WHERE app = '#{app}' AND env = '#{env}'").each do |row|
        r[row['hostname']] = {
          'current' => row['current'],
          'artifacts' => row['artifacts'].split(','),
        }
      end

      JSON.pretty_generate(r)
    end
  end
end
