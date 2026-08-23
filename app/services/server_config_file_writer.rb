# typed: true
# frozen_string_literal: true

# Writes a server's reservation config files. File transport
# (write_configuration/delete_from_server) stays polymorphic on the server.
class ServerConfigFileWriter
  extend T::Sig

  sig { params(server: Server).void }
  def initialize(server)
    @server = server
  end

  sig { params(reservation: Reservation).returns(ReservationStatus) }
  def update_configuration(reservation)
    reservation.status_update("Sending reservation config files")
    @server.write_configuration(server_config_file("reservation.cfg"), generate_config_file(reservation, "reservation.cfg"))
    # The boot map's own config: a server that starts on the default map and
    # was asked for another one switches from here.
    @server.write_configuration(server_config_file("#{Frontress::DEFAULT_MAP}.cfg"), generate_config_file(reservation, "boot_map.cfg"))
    add_motd(reservation)
    write_custom_whitelist(reservation) if reservation.custom_whitelist_id.present?
    write_maplist
    reservation.status_update("Finished sending reservation config files")
  end

  sig { void }
  def write_maplist
    maps_text = Rails.cache.fetch("api_maps_text", expires_in: 10.minutes) do
      MapUpload.available_maps.sort.join("\n")
    end
    @server.write_configuration(server_config_file("maplist_full.txt"), maps_text)
  end

  sig { returns(T.untyped) }
  def enable_plugins
    @server.write_configuration(sourcemod_file, sourcemod_body)
  end

  sig { params(user: User).returns(T.untyped) }
  def add_sourcemod_admin(user)
    T.must(@server.write_configuration(sourcemod_admin_file, sourcemod_admin_body(user)))
  end

  sig { params(reservation: Reservation).returns(T.untyped) }
  def add_motd(reservation)
    T.must(@server.write_configuration(motd_file, motd_body(reservation)))
  end

  sig { returns(T.untyped) }
  def disable_plugins
    @server.delete_from_server([ sourcemod_file, sourcemod_admin_file ])
  end

  sig { returns(String) }
  def sourcemod_file
    "#{@server.tf_dir}/addons/metamod/sourcemod.vdf"
  end

  sig { returns(String) }
  def sourcemod_body
    <<-VDF
    "Metamod Plugin"
    {
      "alias"		"sourcemod"
      "file"		"addons/sourcemod/bin/sourcemod_mm"
    }
    VDF
  end

  sig { params(reservation: Reservation).returns(String) }
  def motd_body(reservation)
    "#{SITE_URL}/reservations/#{reservation.id}/motd?password=#{URI.encode_uri_component(reservation.password)}"
  end

  sig { returns(String) }
  def sourcemod_admin_file
    "#{@server.tf_dir}/addons/sourcemod/configs/admins_simple.ini"
  end

  sig { params(user: User).returns(String) }
  def sourcemod_admin_body(user)
    uid3 = SteamCondenser::Community::SteamId.community_id_to_steam_id3(user.uid.to_i)
    flags = @server.sdr? ? "abcdefghijkln" : "z"
    <<-INI
    "#{uid3}" "99:#{flags}"
    INI
  end

  sig { params(reservation: Reservation).returns(T.untyped) }
  def write_custom_whitelist(reservation)
    content = reservation.custom_whitelist_content
    return unless content

    @server.write_configuration(server_config_file("custom_whitelist_#{reservation.custom_whitelist_id}.txt"), content)
  end

  sig { params(object: Reservation, config_file: String).returns(String) }
  def generate_config_file(object, config_file)
    template = File.read(Rails.root.join("lib/#{config_file}.erb"))
    renderer = ERB.new(template)
    renderer.result(object.get_binding)
  end

  private

  # Config file paths derive from the server's polymorphic tf_dir; computed here
  # rather than calling Server's private server_config_file/motd_file.
  sig { params(config_file: String).returns(String) }
  def server_config_file(config_file)
    "#{@server.tf_dir}/cfg/#{config_file}"
  end

  sig { returns(String) }
  def motd_file
    "#{@server.tf_dir}/motd.txt"
  end
end
