require 'inifile'

module HDeploy
  class Config

    @@instance = nil

    def initialize(path)
      @path = path
      @conf = {}
    end

    def self.instance(path = '/opt/hdeploy/etc')
      @@instance ||= new(path)
    end

    # -------------------------------------------------------------------------
    def _load_file(ctype)
    
      # conf type should be one of these:
      raise "No such file authorized to load '#{ctype}'" unless [:node, :build, :api].include? ctype
      # the config file should NOT be writable by any other user than chef - and it will also deny symlinks
      # for general security

      cfile = File.join(@path, "hdeploy_#{ctype}.conf")
      raise "unable to find conf file #{cfile}" unless File.exists? cfile
      
      st = File.stat(cfile)
      raise "config file #{cfile} must not be a symlink" if File.symlink?(cfile)
      raise "config file #{cfile} must be a regular file" unless st.file?
      raise "config file #{cfile} must have uid 0" unless st.uid == 0 or Process.uid != 0
      raise "config file #{cfile} must not allow group/others to write" unless sprintf("%o", st.mode) =~ /^100[46][04][04]/
      
      # Seems we have checked everything. Woohoo!
      @conf[ctype.to_sym] = IniFile.load(cfile).to_h
    end

    # -------------------------------------------------------------------------
    def reload
      @conf.keys.each do |t|
        _load_file(t)
      end
    end

    # -------------------------------------------------------------------------
    def method_missing(method, *args, &block)
      @conf[method] ||= _load_file(method)  
    end
  end
end
