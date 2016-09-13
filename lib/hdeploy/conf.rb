require 'json'

module HDeploy
  class Conf

    @@instance = nil

    def initialize(file)
      @file = file
      reload
    end

    def self.instance(path = '/opt/hdeploy/etc/hdeploy.conf.json')
      @@instance ||= new(path)
    end

    # -------------------------------------------------------------------------

    def reload
      raise "unable to find conf file #{@file}" unless File.exists? @file
      
      st = File.stat(@file)
      raise "config file #{@file} must not be a symlink" if File.symlink?(@file)
      raise "config file #{@file} must be a regular file" unless st.file?
      raise "config file #{@file} must have uid 0" unless st.uid == 0 or Process.uid != 0
      raise "config file #{@file} must not allow group/others to write" unless sprintf("%o", st.mode) =~ /^100[46][04][04]/
      
      # Seems we have checked everything. Woohoo!
      @conf = JSON.parse(File.read(@file))
    end

    # -------------------------------------------------------------------------
    def [](k)
      @conf[k] 
    end
    
  end
end
