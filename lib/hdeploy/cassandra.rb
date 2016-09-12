require 'cassandra'

# This is a WRAPPER for cassandra
# It just uses the proxy pattern to retry / reconnect before throwing an error
# - and also auto creates the hdeploy tables and keyspace if needed

module HDeploy
  class Cassandra

    def initialize
      @cc = ::Cassandra.cluster
      @keyspace = 'hdeploy'

      @table_create = {
        'distribute_state' => '(app text, env text, hostname text, current text, artifacts text, primary key(app,env,hostname))',
        'srv_keepalive' => '(hostname text, primary key (hostname))',
        'distribute' => '(artifact text, app text, env text, primary key(artifact,app,env))',
        'artifacts' => '(artifact text, app text, source text, altsource text, checksum text, primary key (artifact,app))',
        'target' => '(app text, env text, artifact text, primary key (app,env))',
        'active_env' => '(app text, env text, primary key (app,env))',
      }
    end

    def _cass_connect()
      @cass = @cc.connect(@keyspace)
    end

    def _cass_create_tables()
      tables = @table_create.clone
      @cass.execute('SELECT table_name FROM system_schema.tables WHERE keyspace_name = ?', arguments: [ @keyspace ]).each do |row|
        tables.delete(row['table_name'])
      end

      tables.each do |table, cql|
        puts "Creating table #{table}"
        @cass.execute("CREATE TABLE #{table} #{cql}")
      end
    end

    def method_missing(method, *args, &block)

      begin
        _cass_connect() if @cass.nil?
      rescue ::Cassandra::Errors::InvalidError => e
        if e.to_s == "Keyspace '#{@keyspace}' does not exist"
          @cass = @cc.connect()
          @cass.execute("CREATE KEYSPACE #{@keyspace} WITH REPLICATION = { 'class': 'SimpleStrategy', 'replication_factor': 3 }")
          @cass.execute("USE #{@keyspace}")
        else
          raise e
        end
      end

      if method == :prepare or method == :execute

        begin
          r = @cass.send(method, *args, &block)
        rescue ::Cassandra::Errors::InvalidError => e
          if e.to_s =~ /^unconfigured table (.*)/
            if @table_create.keys.include? $1
              # We are missing tables! Create and re-send
              _cass_create_tables()
              r = @cass.send(method, *args, &block)
            else
              # Nah this is just an normal error. no retry
              raise e
            end
          else
            raise e
          end
        
        rescue Exception => e
          _cass_connect()
          r = @cass.send(method, *args, &block) # This second run will raise an error if there is a problem
        end

        r # And return stuff.

      elsif @cass.respond_to? method
        @cass.send(method, *args, &block)
      else
        raise "no such method #{method} for #{@cass}"
      end
    end
  end
end
