require 'inifile'
require 'singleton'

module HDeploy
  class Config
    include Singleton

    def initialize(path = '/opt/hdeploy/etc')

    # -------------------------------------------------------------------------
    def load_file(conf_type)
    
      # conf_type should be one of these:
      # build, api, node
      # the config file should NOT be writable by any other user than chef - and it will also deny symlinks
      # for general security

      cfile = File.join(@path, "hdeploy_#{conf_type}.ini")
      raise "unable to find conf file #{cfile}" unless File.exists? cfile
      
      st = File.stat(cfile)
      raise "config file #{cfile} must not be a symlink" if File.symlink?(cfile)
      raise "config file #{cfile} must be a regular file" unless st.file?
      raise "config file #{cfile} must have uid 0" unless st.uid == 0
      raise "config file #{cfile} must not allow group/others to write" unless sprintf("%o", st.mode) =~ /^100[46][04][04]/
      
      # Seems we have checked everything. Woohoo!
      @cfile[conf_type] = cfile
      
    end

    # -------------------------------------------------------------------------
    def reload(conf_type = nil)
      if conf_type
        conf[conf_type] = IniFile.load(@cfile[conf_type]).to_h
      else
        # load all
        @cfile.each do |t,f|
          conf[t] = IniFile.load(@cfile).to_h
        end
      end




      @conf[t] = IniFile.load(@cfile).to_h
    end

    def method_missing

  end
end
