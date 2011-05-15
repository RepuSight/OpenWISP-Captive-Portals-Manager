module OsUtils

  IP = "/sbin/ip"
  TC = "/sbin/tc"
  
  public

  # Test to see if a string contains a valid linux interface name
  def is_interface_name?(interface_name)
    (interface_name =~ /\A[a-z_][a-z0-9_\.\-]*\Z/i) != nil
  end

  # Returns the client mac address associated with the passed ipv4/v6 address
  def get_host_mac_address(address)
    mac = nil

    if IPAddr.new(address).ipv4? or IPAddr.new(address).ipv6?
      res = /lladdr\s+(([0-9a-fA-F]{1,2}:){5}[0-9a-fA-F]{1,2})\s+/.match(%x[#{IP} neighbor show #{address}])
      mac = res[1] unless res.nil?
    end

    mac
  end

  # Returns the interface that will be used to reach the passed ip address
  def get_interface(address)
    interface = nil

    if IPAddr.new(address).ipv4? or IPAddr.new(address).ipv6?
      res = /dev\s+([a-zA-Z_][a-zA-Z0-9_\.\-]*)\s+src/.match(%x[#{IP} route get #{address}])
      interface = res[1] unless res.nil?
    end

    interface
  end

  # Returns the first ipv4 address assigned to the passed interface name
  def get_interface_ipv4_address(interface)
    ipv4_address = nil
    if is_interface_name?(interface)
      res = /\s+inet\s+([0-9a-fA-F:\.]+)\/\d+\s+/.match(%x[#{IP} -f inet addr show #{interface} | grep "scope global" | head -1])
      ipv4_address = res[1] unless res.nil?
    end

    ipv4_address
  end

  # Returns the first non-link-local ipv6 address assigned to the passed interface name
  def get_interface_ipv6_address(interface)
    ipv6_address = nil
    if is_interface_name?(interface)
      res = /inet6\s+([0-9a-fA-F:]+)\/\d+\s+scope/.match(%x[#{IP} -f inet6 addr show #{interface} | grep "scope global | head -1"])
      ipv6_address = res[1] unless res.nil?
    end

    ipv6_address
  end

end

module IpTablesUtils
  IPTABLES = "/sbin/iptables"

  def execute_actions(actions, options = {})
    options[:blind] ||= false
    actions.each do |action|
      action << " >/dev/null 2>&1" if options[:blind]
      unless system(action)
        raise "#{caller[2]} - problem executing action: '#{action}'" unless options[:blind]
      end
    end
  end
end

class OsCaptivePortal

  include OsUtils
  include IpTablesUtils

  MARK          = 0x10000000
  MARK_MASK     = 0x10000000

  private
  
  MARK_USER_MOD = 0x0FFFFFFC

  def get_mark_from_client_id(client_id)
    # this mark is used for both classid and iptables mark target/match
    # 0, 1, 2 are reserved:
    #  0x10000000 is used to mark the unclasified traffic
    #  1:0 is the root tc handle
    #  1:1 is the first htb class id
    #  1:2 is default htb class id
    
    (client_id % MARK_USER_MOD) + 3
  end
  
  public

  # Adds a new captive portal
  def start

    @sync.lock(:EX)

    #TO DO: ip6tables rules!

    cp_ip = get_interface_ipv4_address(@cp_interface)

    firewall_create_actions = [
        # creating_cp_chains
    "#{IPTABLES} -t nat    -N '_REDIR_#{@cp_interface}'",
    "#{IPTABLES} -t nat    -N '_DNAT_#{@cp_interface}'",
    "#{IPTABLES} -t filter -N '_FINP_#{@cp_interface}'",
    "#{IPTABLES} -t filter -N '_FOUT_#{@cp_interface}'",
    "#{IPTABLES} -t mangle -N '_XCPT_IN_#{@cp_interface}'",
    "#{IPTABLES} -t mangle -N '_XCPT_OUT_#{@cp_interface}'",
    "#{IPTABLES} -t mangle -N '_AUTH_IN_#{@cp_interface}'",
    "#{IPTABLES} -t mangle -N '_AUTH_OUT_#{@cp_interface}'",
    # creating_http_redirections
    "#{IPTABLES} -t nat -A '_REDIR_#{@cp_interface}' -p tcp --dport 80  -j DNAT --to-destination '#{cp_ip}:#{@local_http_port}'",
    "#{IPTABLES} -t nat -A '_REDIR_#{@cp_interface}' -p tcp --dport 443 -j DNAT --to-destination '#{cp_ip}:#{@local_https_port}'",
    # creating_dns_redirections
    "#{IPTABLES} -t nat -A '_DNAT_#{@cp_interface}'  -p udp --dport 53  -j DNAT --to-destination '#{cp_ip}:#{DNS_PORT}'",
    "#{IPTABLES} -t nat -A '_DNAT_#{@cp_interface}'  -p tcp --dport 53  -j DNAT --to-destination '#{cp_ip}:#{DNS_PORT}'",
    # creating_redirection_rules
    "#{IPTABLES} -t nat    -A _PRER_NAT -i '#{@cp_interface}' -j '_DNAT_#{@cp_interface}'",
    # creating_auth_users_rules
    "#{IPTABLES} -t mangle -A _PRER_MAN -i '#{@cp_interface}' -j '_AUTH_IN_#{@cp_interface}'",
    "#{IPTABLES} -t mangle -A _POSR_MAN -o '#{@cp_interface}' -j '_AUTH_OUT_#{@cp_interface}'",
    # creating_exceptions_rules
    "#{IPTABLES} -t mangle -A _PRER_MAN -i '#{@cp_interface}' -j '_XCPT_IN_#{@cp_interface}'",
    "#{IPTABLES} -t mangle -A _POSR_MAN -o '#{@cp_interface}' -j '_XCPT_OUT_#{@cp_interface}'",
    # creating_main_filtering
    "#{IPTABLES} -t filter -A _FORW_FIL -i '#{@cp_interface}' -o '#{@wan_interface}' -m mark --mark '#{MARK}/#{MARK_MASK}' -j RETURN",
    "#{IPTABLES} -t filter -A _FORW_FIL -i '#{@cp_interface}' -j DROP",
    # creating_redirection_skip_rules
    "#{IPTABLES} -t nat    -A _PRER_NAT -i '#{@cp_interface}' -m mark --mark '#{MARK}/#{MARK_MASK}' -j RETURN",
    "#{IPTABLES} -t nat    -A _PRER_NAT -i '#{@cp_interface}' -j '_REDIR_#{@cp_interface}'",
    # creating_filtering
    "#{IPTABLES} -t filter -A _INPU_FIL -i '#{@cp_interface}' -j '_FINP_#{@cp_interface}'",
    "#{IPTABLES} -t filter -A _OUTP_FIL -o '#{@cp_interface}' -j '_FOUT_#{@cp_interface}'",
    # basic_service_filtering_rules
    "#{IPTABLES} -t filter -A '_FINP_#{@cp_interface}' -p tcp --dport #{@local_http_port}  -m state --state NEW,ESTABLISHED -j ACCEPT",
    "#{IPTABLES} -t filter -A '_FINP_#{@cp_interface}' -p tcp --dport #{@local_https_port} -m state --state NEW,ESTABLISHED -j ACCEPT",
    "#{IPTABLES} -t filter -A '_FINP_#{@cp_interface}' -p tcp --dport #{DNS_PORT}          -m state --state NEW,ESTABLISHED -j ACCEPT",
    "#{IPTABLES} -t filter -A '_FINP_#{@cp_interface}' -p udp --dport #{DNS_PORT}          -m state --state NEW,ESTABLISHED -j ACCEPT",
    "#{IPTABLES} -t filter -A '_FINP_#{@cp_interface}' -p udp --sport #{DHCP_SRC_PORT} --dport #{DHCP_DST_PORT} -j ACCEPT",
    "#{IPTABLES} -t filter -A '_FOUT_#{@cp_interface}' -p udp --dport #{DHCP_SRC_PORT} --sport #{DHCP_DST_PORT} -j ACCEPT",
    "#{IPTABLES} -t filter -A '_FOUT_#{@cp_interface}' -m state --state ESTABLISHED -j ACCEPT",
    "#{IPTABLES} -t filter -A '_FOUT_#{@cp_interface}' -j DROP",
    # user_defined_nat_rules
    "#{IPTABLES} -t nat -A _POSR_NAT -i '#{@cp_interface}' -j RETURN"
    ]

    execute_actions(firewall_create_actions)

    unless @total_upload_bandwidth.blank?
      shaping_up_create_actions = [
      # root handle and class for clients upload
      "#{TC} qdisc add dev '#{@cp_interface}' root handle 1: htb default 2 r2q 6",
      "#{TC} class add dev '#{@cp_interface}' parent 1 classid 1:1 htb rate #{@total_upload_bandwidth}kbit ceil #{@total_upload_bandwidth}kbit burst 30k",
      # unclassified upload traffic bandwith
      "#{TC} class add dev '#{@cp_interface}' parent 1:1 classid 1:2 htb rate #{@total_upload_bandwidth/10}kbit ceil #{@total_upload_bandwidth}kbit burst 20k prio 1",
      "#{TC} qdisc add dev '#{@cp_interface}' parent 1:2 handle 12: sfq perturb 10",
      ]
      
      execute_actions(shaping_up_create_actions)
    end

    unless @total_download_bandwidth.blank?
      shaping_down_create_actions = [
      # root handle and class for clients download
      "#{TC} qdisc add dev '#{@wan_interface}' root handle 1: htb default 2 r2q 6",
      "#{TC} class add dev '#{@wan_interface}' parent 1 classid 1:1 htb rate #{@total_download_bandwidth}kbit ceil #{@total_download_bandwidth}kbit burst 30k",
      # unclassified download traffic bandwith
      "#{TC} class add dev '#{@wan_interface}' parent 1:1 classid 1:2 htb rate #{@total_download_bandwidth/10}kbit ceil #{@total_download_bandwidth}kbit burst 20k prio 1",
      "#{TC} qdisc add dev '#{@wan_interface}' parent 1:2 handle 12: sfq perturb 10",
      ]
      
      execute_actions(shaping_down_create_actions)
    end

  ensure
    @sync.unlock
  end

  # Removes a captive portal
  # cp_interface is the name of the interface directly connected the clients
  def stop

    @sync.lock(:EX)

    #TO DO: ip6tables rules!

    firewall_destroy_actions = [
        # flushing_chains
    "#{IPTABLES} -t mangle -F '_XCPT_IN_#{@cp_interface}'",
    "#{IPTABLES} -t mangle -F '_XCPT_OUT_#{@cp_interface}'",
    "#{IPTABLES} -t mangle -F '_AUTH_IN_#{@cp_interface}'",
    "#{IPTABLES} -t mangle -F '_AUTH_OUT_#{@cp_interface}'",
    "#{IPTABLES} -t nat    -F '_REDIR_#{@cp_interface}'",
    "#{IPTABLES} -t nat    -F '_DNAT_#{@cp_interface}'",
    "#{IPTABLES} -t filter -F '_FINP_#{@cp_interface}'",
    "#{IPTABLES} -t filter -F '_FOUT_#{@cp_interface}'",
    # deleting_rules
    "#{IPTABLES} -t nat    -D _PRER_NAT -i '#{@cp_interface}' -j '_DNAT_#{@cp_interface}'",
    "#{IPTABLES} -t nat    -D _PRER_NAT -i '#{@cp_interface}' -m mark --mark '#{MARK}/#{MARK_MASK}' -j RETURN",
    "#{IPTABLES} -t nat    -D _PRER_NAT -i '#{@cp_interface}' -j '_REDIR_#{@cp_interface}'",
    "#{IPTABLES} -t nat    -D _POSR_NAT -i '#{@cp_interface}' -j RETURN",
    "#{IPTABLES} -t filter -D _INPU_FIL -i '#{@cp_interface}' -j '_FINP_#{@cp_interface}'",
    "#{IPTABLES} -t filter -D _OUTP_FIL -o '#{@cp_interface}' -j '_FOUT_#{@cp_interface}'",
    "#{IPTABLES} -t filter -D _FORW_FIL -i '#{@cp_interface}' -o '#{@wan_interface}' -m mark --mark '#{MARK}/#{MARK_MASK}' -j RETURN",
    "#{IPTABLES} -t filter -D _FORW_FIL -i '#{@cp_interface}' -j DROP",
    "#{IPTABLES} -t mangle -D _PRER_MAN -i '#{@cp_interface}' -j '_AUTH_IN_#{@cp_interface}'",
    "#{IPTABLES} -t mangle -D _POSR_MAN -o '#{@cp_interface}' -j '_AUTH_OUT_#{@cp_interface}'",
    "#{IPTABLES} -t mangle -D _PRER_MAN -i '#{@cp_interface}' -j '_XCPT_IN_#{@cp_interface}'",
    "#{IPTABLES} -t mangle -D _POSR_MAN -o '#{@cp_interface}' -j '_XCPT_OUT_#{@cp_interface}'",
    # destroying_chains
    "#{IPTABLES} -t mangle -X '_XCPT_IN_#{@cp_interface}'",
    "#{IPTABLES} -t mangle -X '_XCPT_OUT_#{@cp_interface}'",
    "#{IPTABLES} -t mangle -X '_AUTH_IN_#{@cp_interface}'",
    "#{IPTABLES} -t mangle -X '_AUTH_OUT_#{@cp_interface}'",
    "#{IPTABLES} -t nat    -X '_REDIR_#{@cp_interface}'",
    "#{IPTABLES} -t nat    -X '_DNAT_#{@cp_interface}'",
    "#{IPTABLES} -t filter -X '_FINP_#{@cp_interface}'",
    "#{IPTABLES} -t filter -X '_FOUT_#{@cp_interface}'"
    ]

    execute_actions(firewall_destroy_actions)

    unless @total_upload_bandwidth.blank?
      shaping_upload_destroy_actions = [
      # root handle and class for clients upload
      "#{TC} qdisc del dev '#{@cp_interface}' root handle 1: htb default 2 r2q 6",
      ]
      
      execute_actions(shaping_upload_destroy_actions)
    end

    unless @total_download_bandwidth.blank?
      shaping_down_destroy_actions = [
      # root handle and class for clients download
      "#{TC} qdisc del dev '#{@wan_interface}' root handle 1: htb default 2 r2q 6",
      ]
      
      execute_actions(shaping_down_destroy_actions)
    end

  ensure
    @sync.unlock
  end

  # Creates/Removes an iptables rule parameters for allowed traffic
  def add_remove_allowed_traffic(action = :add, options = {})

    # Determine source host type (if any)
    if options[:source_host].blank?
      source_host_type = nil
    else
      begin
        source_host_type = IPAddr.new(options[:source_host]).is_ipv4? ? :ipv4 : :ipv6
      rescue
        # If the previous fails with an exception, assume source_host is an hostname
        source_host_type = :hostname
      end
    end

    # Determine destination host type (if any)
    if options[:destination_host].blank?
      destination_host_type = nil
    else
      begin
        destination_host_type = IPAddr.new(options[:destination_host]).is_ipv4? ? :ipv4 : :ipv6
      rescue
        # If the previous fails with an exception, assume destination_host is an hostname
        destination_host_type = :hostname
      end
    end

    if !source_host_type.nil? and !destination_host_type.nil? and
        source_host_type != :hostname and destination_host_type != :hostname and
        source_host_type != destination_host_type
      raise("BUG: source and destination host must belong to the same family (#{options[:source_host]} is " +
                "'#{source_host_type}' and #{options[:destination_host]} is '#{destination_host_type}')")
    end

    if !(source_host_type == :ipv6 or destination_host_type == :ipv6)
      # IPv4 rule
      ipv4_exception_rule =  "#{IPTABLES} -t mangle " + (action == :add ? "-A" : "-D") + " '_XCPT_IN_#{@cp_interface}' -i '#{@cp_interface}'"
      ipv4_exception_rule += " -m mac --mac-source '#{options[:source_mac]}'" unless options[:source_mac].blank?
      ipv4_exception_rule += " -s #{options[:source_host]}" unless options[:source_host].blank?
      ipv4_exception_rule += " -d #{options[:destination_host]}" unless options[:destination_host].blank?
      ipv4_exception_rule += " -p #{options[:protocol]}" unless options[:protocol].blank?
      ipv4_exception_rule += " --sport #{options[:source_port]}" unless options[:source_port].blank? or options[:protocol].blank?
      ipv4_exception_rule += " --dport #{options[:destination_port]}" unless options[:destination_port].blank? or options[:protocol].blank?
      ipv4_exception_rule += " -j MARK --set-mark '#{MARK}'"

      execute_actions([ipv4_exception_rule])

    end

    if !(source_host_type == :ipv4 and destination_host_type == :ipv4)
      # TO DO: IPv6 rule
      not_implemented
    end

  end

  # Add an iptables rule for allowed traffic
  def add_allowed_traffic(options = {})
    add_remove_allowed_traffic(:add, options)
  end

  # Removes an iptables rule for allowed traffic
  def remove_allowed_traffic(options = {})
    add_remove_allowed_traffic(:remove, options)
  end

  # Allows a client through the captive portal
  def add_user(client_address, client_mac_address, client_id, options = {})
    raise("BUG: Invalid mac address '#{client_mac_address}'") unless is_mac_address?(client_mac_address)
    raise("BUG: Invalid numeric id '#{client_id}'") unless (Integer(client_id) != nil rescue false)

    upload_bandwidth   = options[:max_upload_bandwidth] || @default_upload_bandwidth
    download_bandwidth = options[:max_download_bandwidth] || @default_download_bandwidth
    mark = get_mark_from_client_id(client_id)

    @sync.lock(:EX)
    
    firewall_paranoid_remove_user_actions = []
    firewall_add_user_actions = []

    if is_ipv4_address?(client_address)
      firewall_paranoid_remove_user_actions = [
          # paranoid_rules
        "#{IPTABLES} -t mangle -D '_AUTH_IN_#{@cp_interface}' -s '#{client_address}' -m mac --mac-source '#{client_mac_address}' -j MARK --set-mark '#{mark}'",
        "#{IPTABLES} -t mangle -D '_AUTH_OUT_#{@cp_interface}' -d '#{client_address}' -j MARK --set-mark '#{mark}'",
      ]
      firewall_add_user_actions = [
          # adding_user_marking_rule
        "#{IPTABLES} -t mangle -A '_AUTH_IN_#{@cp_interface}' -s '#{client_address}' -m mac --mac-source '#{client_mac_address}' -j MARK --set-mark '#{mark}'",
        "#{IPTABLES} -t mangle -A '_AUTH_OUT_#{@cp_interface}' -d '#{client_address}' -j MARK --set-mark '#{mark}'",
      ]

    elsif is_ipv6_address?(client_address)
      #TO DO: ip6tables rules!
      not_implemented
    else
      raise("BUG: unexpected address type '#{client_address}'")
    end

    execute_actions(firewall_paranoid_remove_user_actions, :blind => true)
    execute_actions(firewall_add_user_actions)

    unless @total_upload_bandwidth.blank? or upload_bandwidth.blank?
      shaping_up_paranoid_remove_user_actions = [
        # upload class, qdisc and filter
        "#{TC} class  del dev '#{@cp_interface}' parent 1:1 classid 1:#{mark} htb rate #{upload_bandwidth}kbit ceil #{upload_bandwidth}kbit burst 20k prio 1",
        "#{TC} qdisc  del dev '#{@cp_interface}' parent 1:#{mark} handle #{mark}: sfq perturb 10",
        "#{TC} filter del dev '#{@cp_interface}' parent 1: prio 1 protocol ip handle #{mark} fw classid 1:#{mark}",
      ]
      shaping_up_add_user_actions = [
        # upload class, qdisc and filter
        "#{TC} class  add dev '#{@cp_interface}' parent 1:1 classid 1:#{mark} htb rate #{upload_bandwidth}kbit ceil #{upload_bandwidth}kbit burst 20k prio 1",
        "#{TC} qdisc  add dev '#{@cp_interface}' parent 1:#{mark} handle #{mark}: sfq perturb 10",
        "#{TC} filter add dev '#{@cp_interface}' parent 1: prio 1 protocol ip handle #{mark} fw classid 1:#{mark}",
      ]
      
      execute_actions(shaping_up_paranoid_remove_user_actions, :blind => true)
      execute_actions(shaping_up_add_user_actions)
    end

    unless @total_download_bandwidth.blank? or download_bandwidth.blank?
      shaping_down_paranoid_remove_user_actions = [
        # dowload class, qdisc and filter
        "#{TC} class  del dev '#{@wan_interface}' parent 1:1 classid 1:#{mark} htb rate #{download_bandwidth}kbit ceil #{download_bandwidth}kbit burst 20k prio 1",
        "#{TC} qdisc  del dev '#{@wan_interface}' parent 1:#{mark} handle #{mark}: sfq perturb 10",
        "#{TC} filter del dev '#{@wan_interface}' parent 1: prio 1 protocol ip handle #{mark} fw classid 1:#{mark}",
      ]
      shaping_down_add_user_actions = [
        # dowload class, qdisc and filter
        "#{TC} class  add dev '#{@wan_interface}' parent 1:1 classid 1:#{mark} htb rate #{download_bandwidth}kbit ceil #{download_bandwidth}kbit burst 20k prio 1",
        "#{TC} qdisc  add dev '#{@wan_interface}' parent 1:#{mark} handle #{mark}: sfq perturb 10",
        "#{TC} filter add dev '#{@wan_interface}' parent 1: prio 1 protocol ip handle #{mark} fw classid 1:#{mark}",
      ]
      
      execute_actions(shaping_down_paranoid_remove_user_actions, :blind => true)
      execute_actions(shaping_down_add_user_actions)
    end
    
  ensure
    @sync.unlock
  end

  # Removes a client
  def remove_user(client_address, client_mac_address, client_id, options = {})
    raise("BUG: Invalid mac address '#{client_mac_address}'") unless is_mac_address?(client_mac_address)
    raise("BUG: Invalid numeric id '#{client_id}'") unless (Integer(client_id) != nil rescue false)

    upload_bandwidth   = options[:max_upload_bandwidth] || @default_upload_bandwidth
    download_bandwidth = options[:max_download_bandwidth] || @default_download_bandwidth
    mark = get_mark_from_client_id(client_id)

    @sync.lock(:EX)

    firewall_remove_user_actions = []

    if is_ipv4_address?(client_address)
      firewall_remove_user_actions = [
          # removing_user_marking_rule
        "#{IPTABLES} -t mangle -D '_AUTH_IN_#{@cp_interface}' -s '#{client_address}' -m mac --mac-source '#{client_mac_address}' -j MARK --set-mark '#{mark}'",
        "#{IPTABLES} -t mangle -D '_AUTH_OUT_#{@cp_interface}' -d '#{client_address}' -j MARK --set-mark '#{mark}'",
      ]

    elsif is_ipv6_address?(client_address)
      #TO DO: ip6tables rules!
      not_implemented
    else
      raise("BUG: unexpected address type '#{client_address}'")
    end

    execute_actions(firewall_remove_user_actions)

    unless @total_upload_bandwidth.blank? or upload_bandwidth.blank?
      shaping_up_paranoid_remove_user_actions = [
        # upload class, qdisc and filter
        "#{TC} class  del dev '#{@cp_interface}' parent 1:1 classid 1:#{mark} htb rate #{upload_bandwidth}kbit ceil #{upload_bandwidth}kbit burst 20k prio 1",
        "#{TC} qdisc  del dev '#{@cp_interface}' parent 1:#{mark} handle #{mark}: sfq perturb 10",
        "#{TC} filter del dev '#{@cp_interface}' parent 1: prio 1 protocol ip handle #{mark} fw classid 1:#{mark}",
      ]
      shaping_up_add_user_actions = [
        # upload class, qdisc and filter
        "#{TC} class  add dev '#{@cp_interface}' parent 1:1 classid 1:#{mark} htb rate #{upload_bandwidth}kbit ceil #{upload_bandwidth}kbit burst 20k prio 1",
        "#{TC} qdisc  add dev '#{@cp_interface}' parent 1:#{mark} handle #{mark}: sfq perturb 10",
        "#{TC} filter add dev '#{@cp_interface}' parent 1: prio 1 protocol ip handle #{mark} fw classid 1:#{mark}",
      ]
      
      execute_actions(shaping_up_paranoid_remove_user_actions, :blind => true)
      execute_actions(shaping_up_add_user_actions)
    end

    unless @total_download_bandwidth.blank? or download_bandwidth.blank?
       shaping_down_paranoid_remove_user_actions = [
         # dowload class, qdisc and filter
         "#{TC} class  del dev '#{@wan_interface}' parent 1:1 classid 1:#{mark} htb rate #{download_bandwidth}kbit ceil #{download_bandwidth}kbit burst 20k prio 1",
         "#{TC} qdisc  del dev '#{@wan_interface}' parent 1:#{mark} handle #{mark}: sfq perturb 10",
         "#{TC} filter del dev '#{@wan_interface}' parent 1: prio 1 protocol ip handle #{mark} fw classid 1:#{mark}",
       ]
       shaping_down_add_user_actions = [
         # dowload class, qdisc and filter
         "#{TC} class  add dev '#{@wan_interface}' parent 1:1 classid 1:#{mark} htb rate #{download_bandwidth}kbit ceil #{download_bandwidth}kbit burst 20k prio 1",
         "#{TC} qdisc  add dev '#{@wan_interface}' parent 1:#{mark} handle #{mark}: sfq perturb 10",
         "#{TC} filter add dev '#{@wan_interface}' parent 1: prio 1 protocol ip handle #{mark} fw classid 1:#{mark}",
       ]

       execute_actions(shaping_down_paranoid_remove_user_actions, :blind => true)
       execute_actions(shaping_down_add_user_actions)
     end

  ensure
    @sync.unlock
  end

  # Returns uploaded and downloaded bytes (respectively) for a given client
  def get_user_bytes_counters(client_address)

    @sync.lock(:SH)

    ret = [0, 0]
    if is_ipv4_address?(client_address)
      up_match = /\A\s*(\d+)\s+(\d+)\s+/.match(%x[#{IPTABLES} -t mangle -vnx -L '_AUTH_IN_#{@cp_interface}' | grep '#{client_address}'])
      dn_match = /\A\s*(\d+)\s+(\d+)\s+/.match(%x[#{IPTABLES} -t mangle -vnx -L '_AUTH_OUT_#{@cp_interface}' | grep '#{client_address}'])
      ret = [up_match[2].to_i, dn_match[2].to_i]
    elsif is_ipv6_address?(client_address)
      #TO DO: ip6tables rules!
      not_implemented
    else
      raise("BUG: unexpected address type '#{client_address}'")
    end

    ret

  ensure
    @sync.unlock
  end

  # Returns uploaded and downloaded packets (respectively) for a given client
  def get_user_packets_counters(client_address)

    @sync.lock(:SH)

    ret = [0, 0]
    if is_ipv4_address?(client_address)
      up_match = /\A\s*(\d+)\s+(\d+)\s+/.match(%x[#{IPTABLES} -t mangle -vnx -L '_AUTH_IN_#{@cp_interface}' | grep '#{client_address}'])
      dn_match = /\A\s*(\d+)\s+(\d+)\s+/.match(%x[#{IPTABLES} -t mangle -vnx -L '_AUTH_OUT_#{@cp_interface}' | grep '#{client_address}'])
      ret = [up_match[1].to_i, dn_match[1].to_i]
    elsif is_ipv6_address?(client_address)
      #TO DO: ip6tables rules!
      not_implemented
    else
      raise("BUG: unexpected address type '#{client_address}'")
    end

    ret

  ensure
    @sync.unlock
  end

end

# This class implements a singleton object that control main Linux OS commands for
# the captive portals
class OsControl

  include OsUtils
  include IpTablesUtils

  public

  # Initializes captive portal firewalling infrastructure
  def start

    #TO DO: ip6tables rules!

    start_actions = [
        # creating_main_chains
    "#{IPTABLES} -t nat    -N _PRER_NAT",
    "#{IPTABLES} -t nat    -N _POSR_NAT",
    "#{IPTABLES} -t filter -N _FORW_FIL",
    "#{IPTABLES} -t filter -N _INPU_FIL",
    "#{IPTABLES} -t filter -N _OUTP_FIL",
    "#{IPTABLES} -t mangle -N _PRER_MAN",
    "#{IPTABLES} -t mangle -N _POSR_MAN",
    # creating_filtering
    "#{IPTABLES} -t filter -I FORWARD     1 -j _FORW_FIL",
    "#{IPTABLES} -t filter -I INPUT       1 -j _INPU_FIL",
    "#{IPTABLES} -t filter -I OUTPUT      1 -j _OUTP_FIL",
    # creating_nat
    "#{IPTABLES} -t nat    -I PREROUTING  1 -j _PRER_NAT",
    "#{IPTABLES} -t nat    -I POSTROUTING 1 -j _POSR_NAT",
    # creating_mangle
    "#{IPTABLES} -t mangle -I PREROUTING  1 -j _PRER_MAN",
    "#{IPTABLES} -t mangle -I POSTROUTING 1 -j _POSR_MAN"
    ]

    execute_actions(start_actions)

  end

  # Finalize captive portal firewalling infrastructure
  def stop

    @captive_portals.each_value do |cp|
      cp.stop
    end

    @captive_portals = Hash.new

    #TO DO: ip6tables rules!

    stop_actions = [
        # destroying_redirections
    "#{IPTABLES} -t nat    -D PREROUTING  -j _PRER_NAT",
    "#{IPTABLES} -t nat    -F _PRER_NAT",
    "#{IPTABLES} -t nat    -X _PRER_NAT",
    # destroying_filtering
    "#{IPTABLES} -t filter -D FORWARD     -j _FORW_FIL",
    "#{IPTABLES} -t filter -F _FORW_FIL",
    "#{IPTABLES} -t filter -X _FORW_FIL",
    "#{IPTABLES} -t filter -D INPUT       -j _INPU_FIL",
    "#{IPTABLES} -t filter -F _INPU_FIL",
    "#{IPTABLES} -t filter -X _INPU_FIL",
    "#{IPTABLES} -t filter -D OUTPUT      -j _OUTP_FIL",
    "#{IPTABLES} -t filter -F _OUTP_FIL",
    "#{IPTABLES} -t filter -X _OUTP_FIL",
    # destroying_nat
    "#{IPTABLES} -t nat    -D POSTROUTING -j _POSR_NAT",
    "#{IPTABLES} -t nat    -F _POSR_NAT",
    "#{IPTABLES} -t nat    -X _POSR_NAT",
    # destroying_mangle
    "#{IPTABLES} -t mangle -D PREROUTING  -j _PRER_MAN",
    "#{IPTABLES} -t mangle -F _PRER_MAN",
    "#{IPTABLES} -t mangle -X _PRER_MAN",
    "#{IPTABLES} -t mangle -D POSTROUTING -j _POSR_MAN",
    "#{IPTABLES} -t mangle -F _POSR_MAN",
    "#{IPTABLES} -t mangle -X _POSR_MAN"
    ]

    execute_actions(stop_actions)

  end

  def add_captive_portal(cp_interface, wan_interface, local_http_port, local_https_port, options = {})
    raise("[BUG] Captive portal for #{cp_interface} already exists!") unless @captive_portals[cp_interface].nil?

    @captive_portals[cp_interface] = OsCaptivePortal.new(
        cp_interface,
        wan_interface,
        local_http_port,
        local_https_port,
        options
    )
  end

end
