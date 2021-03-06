require File.join(File.dirname(__FILE__), '../f5_virtualserver')

Puppet::Type.type(:f5_virtualserver).provide(:performance_l4, parent: Puppet::Provider::F5Virtualserver) do

  has_feature :irules
  has_feature :default_pool
  has_feature :connection_limit
  has_feature :persistence
  has_feature :fallback_persistence
  has_feature :connection_mirroring
  has_feature :protocol_client
  has_feature :source_translation
  has_feature :bandwidth_control
  has_feature :traffic_class
  has_feature :source_port
  has_feature :clone_pool
  has_feature :last_hop_pool

  def self.instances
    instances = []
    virtualservers = Puppet::Provider::F5.call_items('/mgmt/tm/ltm/virtual')
    return [] if virtualservers.nil?

    # empty profile type cache once
    clear_profile_type_cache

    virtualservers = virtualservers.select do |vs|
      vs['profilesReference']['items'].find do |x|
        find_profile_type(x['fullPath']) == 'fastl4'
      end
    end

    virtualservers.each do |vserver|
      destination_address, destination_port = address_and_port(vserver['destination'])

      if vserver["vlansEnabled"]
        vlan_and_tunnel_traffic = { "enabled" => vserver["vlans"], }
      elsif vserver["vlansDisabled"] and vserver["vlans"]
        vlan_and_tunnel_traffic = { "disabled" => vserver["vlans"], }
      else
        # And vlansDisable is always true here anyway
        vlan_and_tunnel_traffic = "all"
      end

      clone_pool_client = Array(vserver["clonePools"]).collect do |pool|
        "/#{pool["partition"]}/#{pool["name"]}" if pool["context"] == "clientside"
      end.first
      clone_pool_server = Array(vserver["clonePools"]).collect do |pool|
        "/#{pool["partition"]}/#{pool["name"]}" if pool["context"] == "serverside"
      end.first

      default_persistence_profile = Array(vserver['persist']).collect do |persist|
        "/#{persist["partition"]}/#{persist["name"]}" if persist["tmDefault"]
      end.first

      applied_profiles = vserver["profilesReference"]["items"].inject({}) do |memo,profile|
        warning "Can't find #{profile.inspect}" if find_profile_type(profile["fullPath"]).nil?
        memo.merge!({ find_profile_type(profile["fullPath"]) => Array(memo[find_profile_type(profile["fullPath"])]) << profile })
      end
      #client protocol profile must be a fastl4 type profile
      protocol_profile_client = applied_profiles["fastl4"].first["fullPath"]

      rate_limit_mode = {
        'object'                    => :per_virtual_server,
        'object-source'             => :per_virtual_server_and_source_address,
        'object-destination'        => :per_virtual_server_and_destination_address,
        'object-source-destination' => :per_virtual_server_destination_and_source_address,
        'source'                    => :per_source_address,
        'destination'               => :per_destination_address,
        'source-destination'        => :per_source_and_destination_address,
      }
      connection_rate_limit_mode = rate_limit_mode[vserver["rateLimitMode"]] || vserver["rateLimitMode"]
      case vserver["sourceAddressTranslation"]["type"]
      when 'automap'
        source_address_translation = 'automap'
      when 'lsn'
        source_address_translation = { 'lsn' => vserver["sourceAddressTranslation"]["pool"] }
      when 'snat'
        source_address_translation = { 'snat' => vserver["sourceAddressTranslation"]["pool"] }
      else
        source_address_translation = 'none'
      end

      case vserver["sourcePort"]
      when 'preserve-strict'
        source_port = :preserve_strict
      else
        source_port = vserver["sourcePort"]
      end

      instances << new(
        name:                                   vserver["fullPath"],
        ensure:                                 :present,
        address_status:                         vserver["addressStatus"],
        auto_last_hop:                          vserver["autoLasthop"],
        #vserver["cmpEnabled"],
        connection_limit:                       vserver["connectionLimit"],
        description:                            vserver["description"],
        destination_address:                    destination_address,
        destination_mask:                       vserver["mask"],
        service_port:                           destination_port,
        fallback_persistence_profile:           vserver["fallbackPersistence"] || "none",
        #vserver["enabled"]
        vs_score:                               vserver["gtmScore"],
        protocol:                               vserver["ipProtocol"],
        last_hop_pool:                          vserver["lastHopPool"] || "none",
        #vserver["mobileAppTunnel"]
        nat64:                                  vserver["nat64"],
        connection_rate_limit:                  vserver["rateLimit"],
        connection_rate_limit_destination_mask: vserver["rateLimitDstMask"],
        connection_rate_limit_source_mask:      vserver["rateLimitSrcMask"],
        connection_rate_limit_mode:             connection_rate_limit_mode,
        source:                                 vserver["source"],
        source_address_translation:             source_address_translation,
        source_port:                            source_port,
        #vserver["synCookieStatus"]
        address_translation:                    vserver["translateAddress"],
        port_translation:                       vserver["translatePort"],
        vlan_and_tunnel_traffic:                vlan_and_tunnel_traffic,
        clone_pool_client:                      clone_pool_client,
        clone_pool_server:                      clone_pool_server,
        default_persistence_profile:            default_persistence_profile || "none",
        #definition:                             vserver["apiAnonymous"],
        protocol_profile_client:                protocol_profile_client,
        statistics_profile:                     ((applied_profiles["statistics"]||[]).first || {})["fullPath"] || "none",
        irules:                                 vserver["rules"] || "none",
        #analytics_profile:                      aoeu,
        bandwidth_controller:                   vserver["bwcPolicy"],
        state:                                  vserver["disabled"] == true ? "disabled" : "enabled",
        traffic_class:                          vserver["trafficClasses"],
        rate_class:                             vserver["rateClass"],
        default_pool:                           vserver["pool"] || "none",
      )
    end

    instances
  end

  def message(object)
    super(object)
  end

  mk_resource_methods
end
