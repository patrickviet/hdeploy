require 'curb'
require 'json'
require 'fileutils'
require 'pathname'
require 'inifile'
require 'pry'
module HDeploy
  class Node

    def initialize
      @conf = HDeploy::Conf.instance('./hdeploy.conf.json')
      @conf.add_defaults({
        'node' => {
          'keepalive_delay' => 60,
          'check_deploy_delay' => 60,
          'max_run_duration' => 3600,
          'hostname' => `/bin/hostname`.chomp,
        }
      })

      # Check for needed configuration parameters
      # API
      api_params = %w[http_user http_password endpoint]
      raise "#{@conf.file}: you need 'api' section for hdeploy node (#{api_params.join(', ')})" unless @conf['api']
      api_params.each do |p|
        raise "#{@conf.file}: you need param for hdeploy node: api/#{p}" unless @conf['api'][p]
      end

      # Deploy
      raise "#{@conf.file}: you need 'deploy' section for hdeploy node" unless @conf['deploy']
      @conf['deploy'].keys.each do |k|
        raise "#{@conf.file}: deploy key must be in the format app:env - found #{k}" unless k =~ /^[a-z0-9\-\_]+:[a-z0-9\-\_]+$/
      end

      default_user = Process.uid == 0 ? 'www-data' : Process.uid
      default_group = Process.gid == 0 ? 'www-data' : Process.gid

      @conf['deploy'].each do |k,c|
        raise "#{@conf.file}: deploy section '#{k}': missing symlink param" unless c['symlink']
        c['symlink'] = File.expand_path(c['symlink'])

        # FIXME: throw exception if user/group are root and/or don't exist
        {
          'relpath' => File.expand_path('../releases', c['symlink']),
          'tgzpath' => File.expand_path('../tarballs', c['symlink']),
          'user' => default_user,
          'group' => default_group,
        }.each do |k2,v|
          c[k2] ||= v
        end

        # It's not a mistake to check for uid in the gid section: only root can change gid.
        raise "You must run node as uid root if you want a different user for deploy #{k}" if Process.uid != 0 and c['user'] != Process.uid
        raise "You must run node as gid root if you want a different group for deploy #{k}" if Process.uid != 0 and c['group'] != Process.gid
      end
    end

    # -------------------------------------------------------------------------
    def run
      # Performance: require here so that launching other stuff doesn't load the library
      require 'eventmachine'

      # FIXME: This is super dirty...
      hdn = File.expand_path '../../../bin/hdeploy_node',__FILE__

      EM.run do
        # FIXME: change the absolute path to something found from stack trace or other.
        repeat_action("#{hdn} keepalive",   @conf['node']['keepalive_delay'].to_i,0)
        repeat_action("#{hdn} check_deploy",@conf['node']['check_deploy_delay'].to_i,100)
        EM.add_timer(@conf['node']['max_run_duration'].to_i) do
          puts "has run long enough"
          EM.stop
        end
      end
    end

    def repeat_action(cmd,delay,splay=0)
      EM.system(cmd,proc do |output,status|
        puts "CMD END: #{cmd} #{status} #{output.strip}"
        EM.add_timer(((status.success?) ? delay+rand(splay+1) : 5),proc{repeat_action(cmd,delay,splay)})
      end
      )
    end

    # -------------------------------------------------------------------------
    def keepalive
      hostname = @conf['node']['hostname']
      c = Curl::Easy.new(@conf['api']['endpoint'] + '/srv/keepalive/' + hostname)
      c.http_auth_types = :basic
      c.username = @conf['api']['http_user']
      c.password = @conf['api']['http_password']
      c.put((@conf['node']['keepalive_delay'].to_i * 2).to_s)
    end

    def put_state
      hostname = @conf['node']['hostname']

      c = Curl::Easy.new(@conf['api']['endpoint'] + '/distribute_state/' + hostname)
      c.http_auth_types = :basic
      c.username = @conf['api']['http_user']
      c.password = @conf['api']['http_password']

      r = []

      # Will look at directories and figure out current state
      @conf['deploy'].each do |section,conf|
        app,env = section.split(':')

        relpath,tgzpath,symlink = conf.values_at('relpath','tgzpath','symlink')

        # could be done with ternary operator but I find it more readable like that.
        current = "unknown"
        if File.symlink? symlink and Dir.exists? symlink
          current = File.basename(File.readlink(symlink))
        end

        # For artifacts, what we want is a directory, that contains the file "READY"
        artifacts = Dir.glob(File.join(relpath, '*', 'READY')).map{|x| File.basename(File.expand_path(File.join(x,'..'))) }

        r << {
          app: app,
          env: env,
          current: current,
          artifacts: artifacts.sort,
        }

      end

      puts JSON.pretty_generate(r) if ENV.has_key?'DEBUG'
      c.put(JSON.generate(r))
    end

    def find_executable(name)
      %w[
        /opt/hdeploy/embedded/bin
        /opt/hdeploy/bin
        /usr/local/bin
        /usr/bin
      ].each do |p|
        e = File.join p,name
        next unless File.exists? e
        st = File.stat(e)
        next unless st.uid == 0
        next unless st.gid == 0
        if sprintf("%o", st.mode) == '100755'
          return e
        else
          warn "file #{file} does not have permissions 100755"
        end
      end
      return nil
    end

    def check_deploy
      put_state

      c = Curl::Easy.new()
      c.http_auth_types = :basic
      c.username = @conf['api']['http_user']
      c.password = @conf['api']['http_password']

      # Now this is the big stuff
      @conf['deploy'].each do |section,conf|
        app,env = section.split(':') #it's already checked for syntax higher in the code

        # Here we get the info.
        # FIXME: double check that config is ok
        relpath,tgzpath,symlink,user,group = conf.values_at('relpath','tgzpath','symlink','user','group')

        # Now the release info from the server
        c.url = @conf['api']['endpoint'] + '/distribute/' + app + '/' + env
        c.perform

        # prepare directories
        FileUtils.mkdir_p(relpath)
        FileUtils.mkdir_p(tgzpath)

        artifacts = JSON.parse(c.body_str)
        puts "found #{artifacts.keys.length} artifacts for #{app} / #{env}"

        dir_to_keep = []
        tgz_to_keep = []

        artifacts.each do |artifact,artdata|
          puts "checking artifact #{artifact}"
          destdir   = File.join relpath,artifact
          tgzfile   = File.join tgzpath,(artifact+'.tar.gz')
          readyfile = File.join destdir,'READY'

          if !(File.exists?readyfile)
            # we have to release. let's cleanup.
            FileUtils.rm_rf(destdir) if File.exists?(destdir)
            count = 0
            while count < 5 and !(File.exists?tgzfile and Digest::MD5.file(tgzfile) == artdata['checksum'])
              count += 1
              File.unlink tgzfile if File.exists?tgzfile
              # FIXME: add altsource and BREAK
              # FIXME: don't run download as root!!
              #####
              if f = find_executable('aria2')
                system("#{f} -x 5 -d #{tgzpath} -o #{artifact}.tar.gz #{artdata['source']}")

              elsif f = find_executable('wget')
                system("#{f} -o #{tgzfile} #{artdata['source']}")

              elsif f = find_executable('curl')
                system("#{f} -o #{tgzfile} #{artdata['source']}")                

              else
                raise "no aria2c, wget or curl available. please install one of them."
              end
            end

            raise "unable to download artifact" unless File.exists?tgzfile
            raise "incorrect checksum for #{tgzfile}" unless Digest::MD5.file(tgzfile) == artdata['checksum']


            FileUtils.mkdir_p destdir
            FileUtils.chown user, group, destdir
            Dir.chdir destdir

            chpst = ''
            if Process.uid == 0
              chpst = find_executable('chpst') or raise "unable to find chpst binary"
              chpst += " -u #{user}:#{group} "
            end

            tar = find_executable('tar')
            system("#{chpst}#{tar} xzf #{tgzfile}") or raise "unable to extract #{tgzfile} as #{user}:#{group}"
            File.chmod 0755, destdir

            # Post distribute hook
            run_hook('post_distribute', {'app' => app, 'env' => env, 'artifact' => artifact})
            FileUtils.touch(File.join(destdir,'READY')) #FIXME: root?
          end

          # we only get here if previous step worked.
          tgz_to_keep << File.expand_path(tgzfile)
          dir_to_keep << File.expand_path(destdir)            
        end

        # check for symlink
        symlink({'app' => app,'env' => env, 'force' => false})

        # cleanup
        if Dir.exists? conf['symlink']
          dir_to_keep << File.expand_path(File.join(File.join(conf['symlink'],'..'),File.readlink(conf['symlink'])))
        end

        (Dir.glob(File.join conf['relpath'], '*') - dir_to_keep).each do |d|
          puts "cleanup dir #{d}"
          FileUtils.rm_rf d
        end

        (Dir.glob(File.join conf['tgzpath'],'*') - tgz_to_keep).each do |f|
          puts "cleanup file #{f}"
          File.unlink f
        end

      end
      put_state
    end

    def run_hook(hook,params)
      # This is a generic function to run the hooks defined in hdeploy.ini.
      # Standard hooks are

      app,env,artifact = params.values_at('app','env','artifact')

      oldpwd = Dir.pwd

      raise "no such app/env #{app} / #{env}" unless @conf['deploy'].has_key? "#{app}:#{env}"

      relpath,user,group = @conf['deploy']["#{app}:#{env}"].values_at('relpath','user','group')
      destdir = File.join relpath,artifact

      # It's OK if the file doesn't exist
      hdeployini = File.join destdir, 'hdeploy.ini'
      return unless File.exists? hdeployini

      # It's also OK if that hook doesn't exist
      hdc = IniFile.load(hdeployini)['hooks']
      return unless hdc.has_key? hook

      hfile = hdc[hook]

      # But if it is defined, we're gonna scream if it's defined incorrectly.
      raise "no such file #{hfile} for hook #{hook}" unless File.exists? (File.join destdir,hfile)
      raise "non-executable file #{hfile} for hook #{hook}" unless File.executable? (File.join destdir,hfile)

      # OK let's run the hook
      Dir.chdir destdir

      chpst = ''
      if Process.uid == 0
        chpst = find_executable('chpst') or raise "unable to find chpst binary"
        chpst += " -u #{user}:#{group} "
      end

      system("#{chpst}#{hfile} '#{JSON.generate(params)}'")
      if $?.success?
        puts "Successfully run #{hook} hook / #{hfile}"
        Dir.chdir oldpwd
      else
        Dir.chdir oldpwd
        raise "Error while running file #{hfile} hook #{hook} : #{$?} - (DEBUG: (pwd: #{destdir}): #{chpst}#{hfile} '#{JSON.generate(params)}'"
      end
    end

    def symlink(params)

      app,env = params.values_at('app','env')
      force = true
      if params.has_key? 'force'
        force = params['force']
      end

      raise "no such app/env #{app} / #{env}" unless @conf['deploy'].has_key? "#{app}:#{env}"

      conf = @conf['deploy']["#{app}:#{env}"]
      link,relpath = conf.values_at('symlink','relpath')

      if force or !(File.exists?link)
        FileUtils.rm_rf(link) unless File.symlink?link

        c = Curl::Easy.new(@conf['api']['endpoint'] + '/target/' + app + '/' + env)
        c.http_auth_types = :basic
        c.username = @conf['api']['http_user']
        c.password = @conf['api']['http_password']
        c.perform

        target = c.body_str
        target_relative_path = Pathname.new(File.join relpath,target).relative_path_from(Pathname.new(File.join(link,'..')))

        if File.symlink?(link) and (File.readlink(link) == target_relative_path)
          puts "symlink for app #{app} is already OK (#{target_relative_path})"
        else
          # atomic symlink override
          puts "setting symlink for app #{app} to #{target_relative_path}"
          File.symlink(target_relative_path,link + '.tmp') #FIXME: should this belong to root?
          File.rename(link + '.tmp', link)
          put_state
        end

        run_hook('post_symlink', {'app' => app, 'env' => env, 'artifact' => target})
      else
        puts "not changing symlink for app #{app}"
      end
    end

  end
end
