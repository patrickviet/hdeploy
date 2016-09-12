require 'curb'
require 'json'
require 'fileutils'
require 'pathname'
require 'inifile'

module HDeploy
  class Node

    def initialize
      @config = HDeploy::Config.instance
    end

    # -------------------------------------------------------------------------
    def run
      # Performance: require here so that launching other stuff doesn't load the library
      require 'eventmachine'

      EM.run do
        repeat_action('/usr/local/bin/hdeploy_node keepalive',   @config.conf['node']['keepalive_delay'].to_i,0)
        repeat_action('/usr/local/bin/hdeploy_node check_deploy',@config.conf['node']['check_deploy_delay'].to_i,100)
        EM.add_timer(@config.conf['node']['max_run_duration'].to_i) do
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
      hostname = @config.conf['node']['hostname']
      c = Curl::Easy.new(@config.conf['global']['endpoint'] + '/srv/keepalive/' + hostname)
      c.http_auth_types = :basic
      c.username = @config.conf['api']['http_user']
      c.password = @config.conf['api']['http_password']
      c.put((@config.conf['node']['keepalive_delay'].to_i * 2).to_s)
    end

    def put_state
      hostname = @config.conf['node']['hostname']

      c = Curl::Easy.new(@config.conf['global']['endpoint'] + '/distribute_state/' + hostname)
      c.http_auth_types = :basic
      c.username = @config.conf['api']['http_user']
      c.password = @config.conf['api']['http_password']

      r = []

      # Will look at directories and figure out current state
      @config.conf.each do |section,conf|
        next unless section =~ /^deploy\:(.*)\:(.*)/
        app,env = $1,$2

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

    def check_deploy
      put_state

      c = Curl::Easy.new()
      c.http_auth_types = :basic
      c.username = @config.conf['api']['http_user']
      c.password = @config.conf['api']['http_password']

      # Now this is the big stuff
      @config.conf.each do |section,conf|
        next unless section =~ /^deploy\:(.*)\:(.*)/
        app,env = $1,$2

        # Here we get the info.
        # FIXME: double check that config is ok
        relpath,tgzpath,symlink,user,group = conf.values_at('relpath','tgzpath','symlink','user','group')

        # Now the release info from the server
        c.url = @config.conf['global']['endpoint'] + '/distribute/' + app + '/' + env
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
          tgzfile   = File.join tgzpath,artifact+'.tar.gz'
          readyfile = File.join destdir,'READY'

          if !(File.exists?readyfile)
            # we have to release. let's cleanup.
            FileUtils.rm_rf(destdir) if File.exists?destdir
            count = 0
            while count < 5 and !(File.exists?tgzfile and Digest::MD5.file(tgzfile) == artdata['checksum'])
              count += 1
              File.unlink tgzfile if File.exists?tgzfile
              # FIXME: add altsource and BREAK
              if File.exists?('/usr/local/bin/aria2c') or File.exists?('/usr/bin/aria2c')
                system("aria2c -x 5 -d #{tgzpath} -o #{artifact}.tar.gz #{artdata['source']}")

              elsif File.exists?('/usr/bin/wget') or File.exists?('/usr/local/bin/wget')
                system("wget -o #{tgzfile} #{artdata['source']}")

              elsif File.exists?('/usr/bin/curl') or File.exists?('/usr/local/bin/curl')
                system("curl -o #{tgzfile} #{artdata['source']}")                

              else
                raise "no aria2c, wget or curl available. please install one of them."
              end
            end

            raise "unable to download artifact" unless File.exists?tgzfile
            raise "incorrect checksum for #{tgzfile}" unless Digest::MD5.file(tgzfile) == artdata['checksum']


            FileUtils.mkdir_p destdir
            FileUtils.chown user, group, destdir
            Dir.chdir destdir
            system("chpst -u #{user}:#{group} tar xzf #{tgzfile}") or raise "unable to extract #{tgzfile} as #{user}:#{group}"
            File.chmod 0755, destdir

            # Post distribute hook
            run_hook('post_distribute', {'app' => app, 'env' => env, 'artifact' => artifact})
            FileUtils.touch(File.join(destdir,'READY'))
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

      raise "no such app/env #{app} / #{env}" unless @config.conf.has_key? "deploy:#{app}:#{env}"

      relpath,user,group = @config.conf["deploy:#{app}:#{env}"].values_at('relpath','user','group')
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
      system("chpst -u #{user}:#{group} #{hfile} '#{JSON.generate(params)}'")
      if $?.success?
        puts "Successfully run #{hook} hook / #{hfile}"
        Dir.chdir oldpwd
      else
        Dir.chdir oldpwd
        raise "Error while running file #{hfile} hook #{hook} : #{$?} - (DEBUG Full command - pwd: #{destdir}): chpst -u #{user}:#{group} #{hfile} '#{JSON.generate(params)}'"
      end
    end

    def symlink(params)

      app,env = params.values_at('app','env')
      force = true
      if params.has_key? 'force'
        force = params['force']
      end

      raise "no such app/env #{app} / #{env}" unless @config.conf.has_key? "deploy:#{app}:#{env}"

      conf = @config.conf["deploy:#{app}:#{env}"]
      link,relpath = conf.values_at('symlink','relpath')

      if force or !(File.exists?link)
        FileUtils.rm_rf(link) unless File.symlink?link

        c = Curl::Easy.new(@config.conf['global']['endpoint'] + '/target/' + app + '/' + env)
        c.http_auth_types = :basic
        c.username = @config.conf['api']['http_user']
        c.password = @config.conf['api']['http_password']
        c.perform

        target = c.body_str
        target_relative_path = Pathname.new(File.join relpath,target).relative_path_from(Pathname.new(File.join(link,'..')))

        if File.symlink?(link) and (File.readlink(link) == target_relative_path)
          puts "symlink for app #{app} is already OK (#{target_relative_path})"
        else
          # atomic symlink override
          puts "setting symlink for app #{app} to #{target_relative_path}"
          File.symlink(target_relative_path,link + '.tmp')
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
